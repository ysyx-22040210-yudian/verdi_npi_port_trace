import csv
import contextlib
import io
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import openpyxl

import annotate_trace_xlsx as annotate
import filter_trace
import find_instances_batched
import kdebug_backend as backend
import trace_gui


def large_names(prefix, count=5000, padding=24):
    return ["{}_{:05d}_{}".format(prefix, index, "x" * padding) for index in range(count)]


class CsvAndXlsxLimitTest(unittest.TestCase):
    def test_200k_csv_field_is_read_without_default_csv_limit(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source = root / "trace.csv"
            output = root / "filtered.csv"
            instances = root / "instances.txt"
            signal = "top.u_key." + "n" * (200 * 1024)
            with source.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.writer(handle)
                writer.writerow(backend.TRACE_HEADER)
                writer.writerow(["top.u_target", "a", "input", "driver", signal])
            instances.write_text("top.u_key\n", encoding="utf-8")

            rows = annotate.read_trace_rows([source])
            filter_trace.filter_csv_by_instances(str(source), str(output), str(instances))

            self.assertEqual(rows[0].signal_full_name, signal)
            with output.open("r", encoding="utf-8", newline="") as handle:
                filtered = list(csv.DictReader(handle))
            self.assertEqual(filtered[0]["signal_full_name"], signal)

    def test_xlsx_cell_limit_has_explicit_csv_marker(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            template = root / "template.xlsx"
            output = root / "result.xlsx"
            result = "yes; " + "top.deep.signal; " * 3000
            annotate.create_minimal_template(template, ["Target"], ["a"], "Trace")
            with contextlib.redirect_stderr(io.StringIO()):
                annotate.write_annotation_results_workbook(
                    template=template,
                    sheet_name="Trace",
                    output=output,
                    modules=["Target"],
                    ports=["a"],
                    module_port_results={"Target": {"top.u0": {"a": result}}},
                    module_params={},
                )

            workbook = openpyxl.load_workbook(output, data_only=False)
            try:
                value = workbook["Trace"].cell(row=2, column=4).value
            finally:
                workbook.close()
            self.assertEqual(len(value), annotate.EXCEL_CELL_TEXT_LIMIT)
            self.assertTrue(value.endswith(annotate.EXCEL_CELL_LIMIT_MARKER))

    def test_xlsx_dimension_limits_fail_early_and_point_to_raw_csv(self):
        ports = ["p{}".format(index) for index in range(annotate.EXCEL_MAX_PORT_COLUMNS + 1)]
        with self.assertRaisesRegex(ValueError, "XLSX_COLUMN_LIMIT.*raw CSV"):
            annotate.validate_xlsx_capacity(1, ports)
        with self.assertRaisesRegex(ValueError, "XLSX_ROW_LIMIT.*raw CSV"):
            annotate.validate_xlsx_capacity(annotate.EXCEL_MAX_DATA_ROWS + 1, ["a"])


class ListFileArgumentLimitTest(unittest.TestCase):
    def test_list_files_keep_gui_separator_and_comment_semantics(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            path = Path(tmpdir) / "names.list"
            path.write_text(
                "a,b c;d\uff0ce\uff1bf # trailing comment\n# full comment\ng\n",
                encoding="utf-8",
            )
            expected = ["a", "b", "c", "d", "e", "f", "g"]
            self.assertEqual(annotate.load_name_list(str(path)), expected)
            self.assertEqual(find_instances_batched.load_name_list(str(path)), expected)
            self.assertEqual(backend.read_port_file(str(path)), expected)
            self.assertEqual(trace_gui.read_list_file(str(path)), ",".join(expected))

    def test_backend_sends_5000_ports_from_over_128k_file(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            kdb = root / "simv.daidir" / "kdb.elab++"
            kdb.mkdir(parents=True)
            ports = large_names("port")
            port_file = root / "ports.list"
            port_file.write_text("\n".join(ports + ports[:3]) + "\n", encoding="utf-8")
            self.assertGreater(port_file.stat().st_size, 128 * 1024)
            full = root / "full.csv"
            boundary = root / "boundary.csv"
            args = backend.build_parser().parse_args([
                "trace", "--lib", str(kdb), "--module", "Target",
                "--ports-file", str(port_file), "--full-out", str(full),
                "--module-out", str(boundary),
            ])

            def response(_action, action_args, _limits, **_kwargs):
                return {"data": {
                    "module": "Target",
                    "requested_ports": action_args["ports"],
                    "traced_ports": [],
                    "selection_mode": "explicit",
                    "full_rows": [],
                    "boundary_rows": [],
                    "evidence": [],
                    "errors": [],
                    "truncated": False,
                    "stats": {"processed_instances": 1},
                }}

            with mock.patch.object(backend, "resolve_kdebug", return_value="fake"), mock.patch.object(
                backend.KDebugClient, "request", side_effect=response
            ) as request:
                backend.run_trace(args)

            sent_ports = request.call_args[0][1]["ports"]
            self.assertEqual(sent_ports, ports)
            self.assertEqual(len(sent_ports), 5000)
            self.assertTrue(full.is_file())
            self.assertTrue(boundary.is_file())

    def test_annotate_internal_commands_keep_large_lists_in_files(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            ports = large_names("port")
            keywords = large_names("Keyword")
            self.assertGreater(len(",".join(ports)), 128 * 1024)
            self.assertGreater(len(",".join(keywords)), 128 * 1024)
            trace_args = SimpleNamespace(
                lib="kdb.elab++",
                const_source_fallback=1,
                const_trace_depth=16,
                assign_trace_depth=2,
                assign_expr_trace_depth=1,
                load_trace_node_limit=20000,
                load_trace_edge_limit=100000,
                load_trace_api_list_limit=20000,
                trace_max_rows=0,
                verdi_timeout_sec=0,
                trace_debug=0,
            )
            captured_trace = []

            def complete_trace(cmd, **kwargs):
                captured_trace.extend(str(item) for item in cmd)
                kwargs["stdout_path"].write_text("full\n", encoding="utf-8")
                module_out = Path(cmd[cmd.index("-module-out") + 1])
                module_out.write_text("boundary\n", encoding="utf-8")

            with mock.patch("annotate_trace_xlsx.run_checked", side_effect=complete_trace):
                annotate.trace_module(trace_args, "Target", ports, root)
            port_plan = root / "requested_ports.list"
            self.assertGreater(port_plan.stat().st_size, 128 * 1024)
            self.assertIn("-ports-file", captured_trace)
            self.assertNotIn("-ports", captured_trace)
            self.assertLess(sum(len(item) for item in captured_trace), 16 * 1024)

            keyword_args = SimpleNamespace(
                keywords=",".join(keywords),
                lib="kdb.elab++",
                keyword_batch_size=8,
                keyword_continue_on_error=False,
                keyword_log_instances=False,
                verdi_timeout_sec=0,
            )
            captured_find = []

            def complete_find(cmd, **_kwargs):
                captured_find.extend(str(item) for item in cmd)
                output = Path(cmd[cmd.index("-output") + 1])
                output.write_text("top.u_key\n", encoding="utf-8")

            with mock.patch("annotate_trace_xlsx.run_checked", side_effect=complete_find):
                annotate.find_filter_instances(keyword_args, root)
            keyword_plan = root / "requested_keywords.list"
            self.assertGreater(keyword_plan.stat().st_size, 128 * 1024)
            self.assertIn("--keywords-file", captured_find)
            self.assertNotIn("-keywords", captured_find)
            self.assertLess(sum(len(item) for item in captured_find), 16 * 1024)

    def test_find_instances_keywords_file_loads_large_collection(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            kdb = root / "kdb.elab++"
            kdb.mkdir()
            keywords = large_names("Keyword")
            keyword_file = root / "keywords.list"
            keyword_file.write_text("\n".join(keywords + keywords[:2]) + "\n", encoding="utf-8")
            output = root / "instances.txt"
            argv = [
                "find_instances_batched.py", "-lib", str(kdb),
                "--keywords-file", str(keyword_file), "-output", str(output),
            ]
            with mock.patch("sys.argv", argv):
                args = find_instances_batched.parse_args()
            self.assertEqual(args.modules, keywords)
            self.assertGreater(keyword_file.stat().st_size, 128 * 1024)

    def test_find_instances_batch_uses_definition_plan_even_when_batch_is_unlimited(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / "batch.txt"
            modules = large_names("Keyword")
            captured = []

            class CompletedProcess:
                pid = 123

                def wait(self, timeout=None):
                    return 0

            def launch(cmd, **_kwargs):
                captured.extend(str(item) for item in cmd)
                plan = Path(cmd[cmd.index("--definitions-file") + 1])
                self.assertEqual(
                    plan.read_text(encoding="utf-8").splitlines(),
                    modules,
                )
                return CompletedProcess()

            args = SimpleNamespace(
                lib=root / "kdb.elab++",
                kdebug_bin="",
                log_instances=False,
                verdi_timeout_sec=0,
                keep_batch_files=False,
            )
            with mock.patch("find_instances_batched.subprocess.Popen", side_effect=launch):
                self.assertEqual(
                    find_instances_batched.run_kdebug_find(args, modules, "all", output),
                    [],
                )
            self.assertIn("--definitions-file", captured)
            self.assertNotIn("--definitions", captured)
            self.assertLess(sum(len(item) for item in captured), 16 * 1024)
            self.assertEqual(list(root.glob("*definitions.list")), [])


class RowLimitFailureTest(unittest.TestCase):
    def test_row_limit_marker_fails_closed_without_overwriting_old_csv(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            kdb = root / "simv.daidir" / "kdb.elab++"
            kdb.mkdir(parents=True)
            full = root / "full.csv"
            boundary = root / "boundary.csv"
            full.write_text("old full\n", encoding="utf-8")
            boundary.write_text("old boundary\n", encoding="utf-8")
            args = backend.build_parser().parse_args([
                "trace", "--lib", str(kdb), "--module", "Target", "--ports", "a",
                "--full-out", str(full), "--module-out", str(boundary),
            ])
            marker = {
                "inst_full_name": "top.u0", "port_name": "a", "port_dir": "input",
                "role": "driver", "signal_full_name": "TRACE_LIMIT_REACHED:row_limit",
            }
            response = {"data": {
                "module": "Target", "requested_ports": ["a"], "traced_ports": ["a"],
                "selection_mode": "explicit", "full_rows": [marker], "boundary_rows": [],
                "evidence": [], "errors": [], "truncated": False,
                "stats": {"processed_instances": 1},
            }}
            with mock.patch.object(backend, "resolve_kdebug", return_value="fake"), mock.patch.object(
                backend.KDebugClient, "request", return_value=response
            ), self.assertRaises(backend.KDebugError) as caught:
                backend.run_trace(args)
            self.assertEqual(caught.exception.code, "KDEBUG_ROW_LIMIT_REACHED")
            self.assertEqual(full.read_text(encoding="utf-8"), "old full\n")
            self.assertEqual(boundary.read_text(encoding="utf-8"), "old boundary\n")


class TraceGuiListFileTest(unittest.TestCase):
    class FakeVar:
        def __init__(self, value=""):
            self.value = value

        def get(self):
            return self.value

        def set(self, value):
            self.value = value

    def base_config(self, mode):
        return {
            "mode": mode,
            "lib": "design/kdb.elab++",
            "module": "Target",
            "module_file": "",
            "keywords": "",
            "keywords_file": "lists/keywords.list",
            "ports": "",
            "ports_file": "lists/ports.list",
            "template": "template.xlsx",
            "xlsx_output": "result.xlsx",
            "csv_output": "result.csv",
            "raw_full_output": "full.csv",
        }

    def test_build_command_forwards_list_files_in_all_modes(self):
        for mode in ("xlsx", "csv", "raw"):
            with self.subTest(mode=mode):
                cmd, _ = trace_gui.build_command(self.base_config(mode))
                self.assertIn("-ports-file", cmd)
                self.assertEqual(cmd[cmd.index("-ports-file") + 1], "lists/ports.list")
                self.assertNotIn("-ports", cmd)
                if mode != "raw":
                    self.assertIn("-keywords-file", cmd)
                    self.assertEqual(
                        cmd[cmd.index("-keywords-file") + 1], "lists/keywords.list"
                    )
                    self.assertNotIn("-keywords", cmd)

    def test_inline_legacy_config_and_file_plus_inline_remain_supported(self):
        legacy = self.base_config("csv")
        legacy.update({"keywords": "KeyA,KeyB", "keywords_file": "", "ports": "a,b", "ports_file": ""})
        cmd, _ = trace_gui.build_command(legacy)
        self.assertEqual(cmd[cmd.index("-keywords") + 1], "KeyA,KeyB")
        self.assertEqual(cmd[cmd.index("-ports") + 1], "a,b")

        combined = self.base_config("csv")
        combined.update({"keywords": "ExtraKey", "ports": "extra_port"})
        cmd, _ = trace_gui.build_command(combined)
        self.assertIn("-keywords", cmd)
        self.assertIn("-keywords-file", cmd)
        self.assertIn("-ports", cmd)
        self.assertIn("-ports-file", cmd)

    def test_load_list_retains_path_and_does_not_expand_inline_argument(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            port_file = Path(tmpdir) / "ports.list"
            ports = large_names("port")
            port_file.write_text("\n".join(ports) + "\n", encoding="utf-8")
            gui = object.__new__(trace_gui.TraceGui)
            gui.vars = {
                "ports": self.FakeVar("stale_inline"),
                "ports_file": self.FakeVar(""),
            }
            gui.filedialog = SimpleNamespace(
                askopenfilename=lambda **_kwargs: str(port_file)
            )
            gui.messagebox = SimpleNamespace(
                showerror=lambda *_args, **_kwargs: self.fail("unexpected load error")
            )

            trace_gui.TraceGui._load_ports_list(gui)

            self.assertEqual(gui.vars["ports"].get(), "")
            self.assertEqual(gui.vars["ports_file"].get(), str(port_file.resolve()))
            cfg = self.base_config("raw")
            cfg.update({
                "ports": gui.vars["ports"].get(),
                "ports_file": gui.vars["ports_file"].get(),
            })
            cmd, _ = trace_gui.build_command(cfg)
            self.assertNotIn("-ports", cmd)
            self.assertEqual(cmd[cmd.index("-ports-file") + 1], str(port_file.resolve()))
            self.assertLess(sum(len(item) for item in cmd), 16 * 1024)

    def test_load_module_list_retains_path_for_xlsx_mode(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            module_file = Path(tmpdir) / "modules.list"
            module_file.write_text(
                "\n".join(large_names("module")) + "\n", encoding="utf-8"
            )
            gui = object.__new__(trace_gui.TraceGui)
            gui.vars = {
                "module": self.FakeVar("stale_inline"),
                "module_file": self.FakeVar(""),
            }
            gui.filedialog = SimpleNamespace(
                askopenfilename=lambda **_kwargs: str(module_file)
            )
            gui.messagebox = SimpleNamespace(
                showerror=lambda *_args, **_kwargs: self.fail("unexpected load error")
            )

            trace_gui.TraceGui._load_module_list(gui)

            self.assertEqual(gui.vars["module"].get(), "")
            self.assertEqual(gui.vars["module_file"].get(), str(module_file.resolve()))
            cfg = self.base_config("xlsx")
            cfg.update({
                "module": gui.vars["module"].get(),
                "module_file": gui.vars["module_file"].get(),
            })
            cmd, _ = trace_gui.build_command(cfg)
            self.assertNotIn("-module", cmd)
            self.assertEqual(
                cmd[cmd.index("-module-file") + 1], str(module_file.resolve())
            )
            self.assertLess(sum(len(item) for item in cmd), 16 * 1024)


if __name__ == "__main__":
    unittest.main()
