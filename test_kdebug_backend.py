import contextlib
import csv
import hashlib
import importlib.util
import io
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

import kdebug_backend as backend


def load_bundled_kdebug_engine():
    engine_path = (
        Path(__file__).resolve().parent
        / "kdebug"
        / "libexec"
        / "tcl_engine"
        / "kdebug_engine.py"
    )
    spec = importlib.util.spec_from_file_location(
        "bundled_kdebug_engine_for_test", str(engine_path)
    )
    if spec is None or spec.loader is None:
        raise RuntimeError("could not load bundled kdebug engine: {}".format(engine_path))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def make_fake_kdebug_bundle(root: Path, omit=(), executable: bool = True) -> Path:
    launcher = root / "tools" / "kdebug"
    manifest_path = root / "kdebug" / "BUNDLE_MANIFEST.json"
    files = {
        launcher: b"#!/usr/bin/env bash\nexit 0\n",
        root / "kdebug" / "kdebug": b"\x7fELFfake",
        root / "kdebug" / "help.txt": b"help\n",
        root / "kdebug" / "libexec" / "kdebug-engine": b"#!/usr/bin/env bash\nexit 0\n",
        root / "kdebug" / "libexec" / "tcl_engine" / "kdebug_engine.py": b"pass\n",
        root / "kdebug" / "libexec" / "tcl_engine" / "kdebug_npi.tcl": b"# npi\n",
        root / "kdebug" / "libexec" / "tcl_engine" / "kdebug_port_trace.tcl": b"# trace\n",
        root / "kdebug" / "schemas" / "v1" / "actions"
        / "port.trace_batch.request.schema.json": b"{}\n",
        root / "kdebug" / "schemas" / "v1" / "actions"
        / "port.trace_batch.response.schema.json": b"{}\n",
        root / "LICENSES" / "kdebug-MIT.txt": b"MIT\n",
        root / "LICENSES" / "nlohmann-json-MIT.txt": b"MIT\n",
    }
    omitted = set(omit)
    for path, content in files.items():
        if path.relative_to(root).as_posix() in omitted:
            continue
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(content)

    def entry(path, text=False):
        content = path.read_bytes().replace(b"\r\n", b"\n") if text else path.read_bytes()
        result = {
            "path": path.relative_to(root).as_posix(),
            "sha256": hashlib.sha256(content).hexdigest(),
            "size_bytes": len(content),
        }
        if text:
            result["text_eol"] = "lf"
        return result

    if manifest_path.relative_to(root).as_posix() not in omitted:
        runtime_paths = [
            launcher,
            root / "kdebug" / "help.txt",
            root / "kdebug" / "libexec" / "kdebug-engine",
            root / "kdebug" / "libexec" / "tcl_engine" / "kdebug_engine.py",
            root / "kdebug" / "libexec" / "tcl_engine" / "kdebug_npi.tcl",
            root / "kdebug" / "libexec" / "tcl_engine" / "kdebug_port_trace.tcl",
        ]
        manifest = {
            "bundle_format": 1,
            "binary": entry(root / "kdebug" / "kdebug"),
            "runtime_files": [entry(path, text=True) for path in runtime_paths if path.exists()],
            "schemas": {
                "path": "kdebug/schemas/v1",
                "file_count": 2,
                "tree_sha256": backend.schema_tree_sha256(root / "kdebug" / "schemas" / "v1"),
            },
            "licenses": [
                entry(root / "LICENSES" / "kdebug-MIT.txt", text=True),
                entry(root / "LICENSES" / "nlohmann-json-MIT.txt", text=True),
            ],
        }
        manifest_path.parent.mkdir(parents=True, exist_ok=True)
        manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
    mode = stat.S_IRUSR | stat.S_IWUSR
    if executable:
        mode |= stat.S_IXUSR
    launcher.chmod(mode)
    for path in (root / "kdebug" / "kdebug", root / "kdebug" / "libexec" / "kdebug-engine"):
        if path.exists():
            path.chmod(stat.S_IRUSR | stat.S_IWUSR | stat.S_IXUSR)
    return launcher


class KDebugBackendContractTest(unittest.TestCase):
    def test_resolve_kdebug_prefers_complete_repo_bundle(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            launcher = make_fake_kdebug_bundle(root)
            fake_module = root / "kdebug_backend.py"
            fake_module.write_text("# location marker\n", encoding="utf-8")
            with mock.patch.object(backend, "__file__", str(fake_module)), mock.patch.dict(
                os.environ, {"KDEBUG_BIN": "", "KVERIF_HOME": str(root / "external")}
            ), mock.patch.object(backend.shutil, "which", return_value="/usr/bin/kdebug"):
                self.assertEqual(backend.resolve_kdebug(None), str(launcher.resolve()))

    def test_incomplete_repo_bundle_fails_without_path_fallback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            make_fake_kdebug_bundle(
                root, omit={"kdebug/libexec/tcl_engine/kdebug_npi.tcl"}
            )
            fake_module = root / "kdebug_backend.py"
            fake_module.write_text("# location marker\n", encoding="utf-8")
            with mock.patch.object(backend, "__file__", str(fake_module)), mock.patch.dict(
                os.environ, {"KDEBUG_BIN": "", "KVERIF_HOME": ""}
            ), mock.patch.object(backend.shutil, "which", return_value="/usr/bin/kdebug"):
                with self.assertRaises(backend.KDebugError) as caught:
                    backend.resolve_kdebug(None)
            self.assertEqual(caught.exception.code, "KDEBUG_BUNDLE_INCOMPLETE")
            self.assertIn("kdebug_npi.tcl", str(caught.exception))

    def test_corrupt_repo_bundle_fails_without_path_fallback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            make_fake_kdebug_bundle(root)
            (root / "kdebug" / "help.txt").write_text("changed\n", encoding="utf-8")
            fake_module = root / "kdebug_backend.py"
            fake_module.write_text("# location marker\n", encoding="utf-8")
            with mock.patch.object(backend, "__file__", str(fake_module)), mock.patch.dict(
                os.environ, {"KDEBUG_BIN": "", "KVERIF_HOME": ""}
            ), mock.patch.object(backend.shutil, "which", return_value="/usr/bin/kdebug"):
                with self.assertRaises(backend.KDebugError) as caught:
                    backend.resolve_kdebug(None)
            self.assertEqual(caught.exception.code, "KDEBUG_BUNDLE_INVALID")
            self.assertIn("integrity check failed", str(caught.exception))

    def test_manifest_cannot_omit_a_required_runtime_hash(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            make_fake_kdebug_bundle(root)
            manifest_path = root / "kdebug" / "BUNDLE_MANIFEST.json"
            manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
            manifest["runtime_files"] = manifest["runtime_files"][1:]
            manifest_path.write_text(json.dumps(manifest), encoding="utf-8")
            fake_module = root / "kdebug_backend.py"
            fake_module.write_text("# location marker\n", encoding="utf-8")
            with mock.patch.object(backend, "__file__", str(fake_module)), mock.patch.dict(
                os.environ, {"KDEBUG_BIN": "", "KVERIF_HOME": ""}
            ):
                with self.assertRaises(backend.KDebugError) as caught:
                    backend.resolve_kdebug(None)
            self.assertEqual(caught.exception.code, "KDEBUG_BUNDLE_INVALID")
            self.assertIn("path set", str(caught.exception))

    @unittest.skipUnless(os.name == "posix", "executable mode is a POSIX contract")
    def test_nonexecutable_repo_bundle_fails_without_path_fallback(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            launcher = make_fake_kdebug_bundle(root, executable=False)
            fake_module = root / "kdebug_backend.py"
            fake_module.write_text("# location marker\n", encoding="utf-8")
            with mock.patch.object(backend, "__file__", str(fake_module)), mock.patch.dict(
                os.environ, {"KDEBUG_BIN": "", "KVERIF_HOME": ""}
            ), mock.patch.object(backend.shutil, "which", return_value="/usr/bin/kdebug"):
                with self.assertRaises(backend.KDebugError) as caught:
                    backend.resolve_kdebug(None)
            self.assertEqual(caught.exception.code, "KDEBUG_BUNDLE_NOT_EXECUTABLE")
            self.assertIn(str(launcher.resolve()), str(caught.exception))

    def test_checked_in_bundle_matches_manifest(self):
        root = Path(__file__).resolve().parent
        manifest = json.loads(
            (root / "kdebug" / "BUNDLE_MANIFEST.json").read_text(encoding="utf-8")
        )
        binary = root / manifest["binary"]["path"]
        digest = hashlib.sha256(binary.read_bytes()).hexdigest()
        self.assertEqual(digest, manifest["binary"]["sha256"])
        self.assertEqual(binary.stat().st_size, manifest["binary"]["size_bytes"])
        self.assertEqual(binary.read_bytes()[:4], b"\x7fELF")
        for kind in ("runtime_files", "licenses"):
            for entry in manifest[kind]:
                path = root / entry["path"]
                content = backend.canonical_bundle_bytes(path, entry.get("text_eol"))
                self.assertEqual(hashlib.sha256(content).hexdigest(), entry["sha256"])
                self.assertEqual(len(content), entry["size_bytes"])
        schemas = list((root / "kdebug" / "schemas" / "v1").rglob("*.json"))
        self.assertEqual(len(schemas), manifest["schemas"]["file_count"])
        self.assertEqual(
            backend.schema_tree_sha256(root / manifest["schemas"]["path"]),
            manifest["schemas"]["tree_sha256"],
        )
        with mock.patch.dict(os.environ, {"KDEBUG_BIN": "", "KVERIF_HOME": ""}):
            self.assertEqual(
                backend.resolve_kdebug(None), str((root / "tools" / "kdebug").resolve())
            )

    @unittest.skipUnless(os.name == "posix", "bundled Linux CLI smoke requires POSIX")
    def test_checked_in_bundled_cli_actions_and_schema(self):
        root = Path(__file__).resolve().parent
        launcher = root / "tools" / "kdebug"
        env = dict(os.environ)
        for name in ("KDEBUG_BIN", "KVERIF_HOME", "PYTHONPATH", "PYTHON"):
            env.pop(name, None)
        with tempfile.TemporaryDirectory() as tmpdir:
            linked_launcher = Path(tmpdir) / "kdebug-link"
            linked_launcher.symlink_to(launcher)
            actions_run = subprocess.run(
                [str(linked_launcher), "--json", "actions"],
                cwd=tmpdir,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                timeout=30,
            )
            self.assertEqual(actions_run.returncode, 0, actions_run.stderr)
            actions = json.loads(actions_run.stdout)
            implemented = actions.get("data", {}).get("implemented", [])
            self.assertTrue(
                {"port.trace_batch", "module.find_instances", "module.inspect_batch"}
                .issubset(set(implemented))
            )
            schema_run = subprocess.run(
                [
                    str(launcher), "--json", "schema", "--action",
                    "port.trace_batch", "--kind", "request",
                ],
                cwd=tmpdir,
                env=env,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
                timeout=30,
            )
            self.assertEqual(schema_run.returncode, 0, schema_run.stderr)
            schema = json.loads(schema_run.stdout)
            self.assertEqual(schema.get("data", {}).get("action"), "port.trace_batch")

    def test_timeout_codes_include_engine_and_tcl_timeouts(self):
        self.assertTrue(backend.is_timeout_code("KDEBUG_TIMEOUT"))
        self.assertTrue(backend.is_timeout_code("TCL_NPI_TIMEOUT"))
        self.assertTrue(backend.is_timeout_code("vendor_timeout"))
        self.assertFalse(backend.is_timeout_code("TRACE_QUERY_FAILED"))

    def test_cli_requires_a_subcommand_without_argparse_required_keyword(self):
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr), self.assertRaises(SystemExit) as caught:
            backend.main([])
        self.assertEqual(caught.exception.code, 2)
        self.assertIn("a command is required", stderr.getvalue())

    def test_preserves_elab_and_normalizes_other_nested_kdb_paths(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            daidir = Path(tmpdir) / "simv.daidir"
            kdb = daidir / "kdb.elab++"
            kdb.mkdir(parents=True)
            nested = daidir / "nested" / "marker"
            nested.mkdir(parents=True)
            standalone = Path(tmpdir) / "standalone.elab++"
            standalone.mkdir()
            self.assertEqual(backend.normalize_design_input(kdb), kdb.resolve())
            self.assertEqual(backend.normalize_design_input(standalone), standalone.resolve())
            self.assertEqual(backend.normalize_design_input(daidir), daidir.resolve())
            self.assertEqual(backend.normalize_design_input(nested), daidir.resolve())
            invalid = Path(tmpdir) / "invalid.elab++"
            invalid.write_text("not a directory", encoding="utf-8")
            with self.assertRaises(backend.KDebugError) as caught:
                backend.normalize_design_input(invalid)
            self.assertEqual(caught.exception.code, "INVALID_KDB_PATH")

    def test_trace_parser_maps_legacy_semantics_to_port_batch_limits(self):
        args = backend.build_parser().parse_args(
            [
                "trace", "--lib", "simv.daidir", "--module", "Target",
                "--full-out", "full.csv", "--module-out", "boundary.csv",
                "--srcfile", "rtl/top.sv", "--const-source-fallback", "0",
                "--const-trace-depth", "7", "--assign-trace-depth", "3",
                "--assign-expr-trace-depth", "2", "--load-trace-node-limit", "11",
                "--load-trace-edge-limit", "12", "--load-trace-api-list-limit", "13",
                "--load-stop-instance-file", "stop.txt", "--max-rows", "14",
            ]
        )
        self.assertEqual(args.source, "rtl/top.sv")
        self.assertEqual(args.source_fallback, 0)
        self.assertEqual(
            (
                args.max_parent_depth, args.max_assign_depth, args.max_expr_depth,
                args.max_nodes, args.max_edges, args.max_api_results, args.max_rows,
            ),
            (7, 3, 2, 11, 12, 13, 14),
        )
        self.assertEqual(args.stop_instance_file, "stop.txt")

    def test_constant_rows_require_effective_full_path_evidence(self):
        rows = [["top.u0", "a", "input", "driver", "Const:1'b1"]]
        evidence = [{
            "kind": "constant",
            "value": "Const:1'b1",
            "method": "source_port_connection",
            "role": "driver",
            "port_path": "top.u0.a",
            "const_full_path": "top.u0.a<-top.tie<-Const:1'b1",
            "effective": True,
            "constant": {"value": "Const:1'b1", "effective": True},
            "provenance": {
                "origin": "source_port_connection",
                "unconditional": True,
                "path": ["top.u0.a", "top.tie", "Const:1'b1"],
                "source": {"file": "rtl/top.sv", "line": "42", "raw_handle": "7"},
            },
        }]
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            backend.validate_port_trace_constants(rows, [], evidence)
        log = stderr.getvalue()
        self.assertIn("evidence_source=kdebug.port.trace_batch", log)
        self.assertIn("const_full_path=top.u0.a<-top.tie<-Const:1'b1", log)
        self.assertIn("source_file=rtl/top.sv", log)

    def test_constant_row_without_evidence_fails_closed(self):
        rows = [["top.u0", "a", "input", "driver", "Const:1'b1"]]
        with self.assertRaises(backend.KDebugError) as caught:
            backend.validate_port_trace_constants(rows, [], [])
        self.assertEqual(caught.exception.code, "KDEBUG_UNVERIFIED_CONSTANT")

    def test_conflicting_constants_across_surfaces_fail_closed(self):
        def evidence(value):
            port_path = "top.u0.a"
            return {
                "kind": "constant",
                "value": value,
                "method": "source_port_connection",
                "role": "driver",
                "port_path": port_path,
                "const_full_path": "{}<-{}".format(port_path, value),
                "effective": True,
                "constant": {"value": value, "effective": True},
                "provenance": {
                    "origin": "source_port_connection",
                    "unconditional": True,
                    "path": [port_path, value],
                    "source": {},
                },
            }

        full = [["top.u0", "a", "input", "driver", "Const:1'b0"]]
        boundary = [["top.u0", "a", "input", "driver", "Const:1'b1"]]
        with self.assertRaises(backend.KDebugError) as caught:
            backend.validate_port_trace_constants(
                full, boundary, [evidence("Const:1'b0"), evidence("Const:1'b1")]
            )
        self.assertEqual(caught.exception.code, "KDEBUG_AMBIGUOUS_CONSTANT")

    def test_equivalent_constants_across_surfaces_are_allowed(self):
        def evidence(value):
            port_path = "top.u0.a"
            return {
                "kind": "constant",
                "value": value,
                "method": "source_port_connection",
                "role": "driver",
                "port_path": port_path,
                "const_full_path": "{}<-{}".format(port_path, value),
                "effective": True,
                "constant": {"value": value, "effective": True},
                "provenance": {
                    "origin": "source_port_connection",
                    "unconditional": True,
                    "path": [port_path, value],
                    "source": {},
                },
            }

        full = [["top.u0", "a", "input", "driver", "Const:1'b0"]]
        boundary = [["top.u0", "a", "input", "driver", "Const:'b0"]]
        stderr = io.StringIO()
        with contextlib.redirect_stderr(stderr):
            backend.validate_port_trace_constants(
                full, boundary, [evidence("Const:1'b0"), evidence("Const:'b0")]
            )
        self.assertEqual(stderr.getvalue().count("const_driver_source_detail"), 2)

    def test_parameter_csv_always_contains_instance_inventory(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            daidir = root / "simv.daidir"
            (daidir / "kdb.elab++").mkdir(parents=True)
            output = root / "params.csv"
            args = SimpleNamespace(
                lib=str(daidir / "kdb.elab++"),
                kdebug_bin="fake-kdebug",
                timeout_sec=0,
                debug=False,
                modules="Target",
                output=str(output),
            )
            inspections = [
                {
                    "module": "top.u0",
                    "sections": {
                        "parameters": [
                            {
                                "object": {
                                    "name": "WIDTH",
                                    "full_name": "top.u0.WIDTH",
                                    "type": "npiParameter",
                                },
                                "values": {"dec": "8"},
                            }
                        ]
                    },
                },
                {"module": "top.u1", "sections": {"parameters": []}},
            ]
            with mock.patch.object(backend, "resolve_kdebug", return_value="fake"), mock.patch.object(
                backend, "find_instances", return_value={"Target": ["top.u0", "top.u1"]}
            ), mock.patch.object(backend, "inspect_many", return_value=inspections):
                backend.run_find_parameters(args)
            with output.open(encoding="utf-8") as handle:
                rows = list(csv.DictReader(handle))
            inventory = [row for row in rows if row["param_kind"] == "instance"]
            self.assertEqual([row["inst_full_name"] for row in inventory], ["top.u0", "top.u1"])
            self.assertEqual(inventory[0]["param_info"], "INSTANCE_INVENTORY")
            width = next(row for row in rows if row["param_name"] == "WIDTH")
            self.assertEqual(width["param_value"], "8")

    def test_trace_maps_all_options_to_one_port_trace_batch_request(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            kdb = root / "simv.daidir" / "kdb.elab++"
            kdb.mkdir(parents=True)
            source = root / "top.sv"
            source.write_text("module top; endmodule\n", encoding="utf-8")
            stops = root / "stops.txt"
            stops.write_text("top.u_stop1\n# ignored\ntop.u_stop0\n", encoding="utf-8")
            full = root / "full.csv"
            boundary = root / "boundary.csv"
            args = backend.build_parser().parse_args(
                [
                    "trace", "--lib", str(kdb), "--module", "Target",
                    "--ports", "a,a", "--source", str(source), "--source-fallback", "0",
                    "--max-parent-depth", "7", "--max-assign-depth", "3",
                    "--max-expr-depth", "2", "--max-nodes", "11", "--max-edges", "12",
                    "--max-api-results", "13", "--max-rows", "14",
                    "--stop-instance-file", str(stops), "--full-out", str(full),
                    "--module-out", str(boundary),
                ]
            )
            response = {
                "data": {
                    "module": "Target", "requested_ports": ["a"], "traced_ports": ["a"],
                    "selection_mode": "explicit",
                    "full_rows": [{
                        "inst_full_name": "top.u0", "port_name": "a", "port_dir": "input",
                        "role": "driver", "signal_full_name": "NO_DRIVER",
                    }],
                    "boundary_rows": [], "evidence": [], "errors": [],
                    "truncated": False, "stats": {"processed_instances": 1},
                }
            }
            with mock.patch.object(backend, "resolve_kdebug", return_value="fake"), mock.patch.object(
                backend.KDebugClient, "request", return_value=response
            ) as request:
                backend.run_trace(args)
            action, action_args, limits = request.call_args[0][:3]
            self.assertEqual(action, "port.trace_batch")
            self.assertEqual(action_args["ports"], ["a"])
            self.assertEqual(action_args["stop_instances"], ["top.u_stop0", "top.u_stop1"])
            self.assertEqual(action_args["source"], str(source.resolve()))
            self.assertFalse(action_args["options"]["source_fallback"])
            self.assertEqual(
                limits,
                {
                    "max_parent_depth": 7, "max_assign_depth": 3, "max_expr_depth": 2,
                    "max_nodes": 11, "max_edges": 12, "max_api_results": 13,
                    "max_rows": 14,
                },
            )

    def test_trace_sends_5000_deduplicated_stop_instances_in_one_request(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            kdb = root / "simv.daidir" / "kdb.elab++"
            kdb.mkdir(parents=True)
            unique_stops = ["top.tile{}.u_stop".format(index) for index in range(5000)]
            stops = root / "stops.txt"
            stops.write_text(
                "\n".join(list(reversed(unique_stops)) + unique_stops[:100]) + "\n",
                encoding="utf-8",
            )
            full = root / "full.csv"
            boundary = root / "boundary.csv"
            args = backend.build_parser().parse_args(
                [
                    "trace", "--lib", str(kdb), "--module", "Target",
                    "--ports", "a", "--stop-instance-file", str(stops),
                    "--full-out", str(full), "--module-out", str(boundary),
                ]
            )
            response = {
                "meta": {"truncated": False},
                "summary": {"truncated": False},
                "data": {
                    "module": "Target",
                    "requested_ports": ["a"],
                    "traced_ports": ["a"],
                    "selection_mode": "explicit",
                    "full_rows": [{
                        "inst_full_name": "top.u0",
                        "port_name": "a",
                        "port_dir": "input",
                        "role": "driver",
                        "signal_full_name": "NO_DRIVER",
                    }],
                    "boundary_rows": [],
                    "evidence": [],
                    "errors": [],
                    "truncated": False,
                    "stats": {"processed_instances": 1},
                },
            }
            with mock.patch.object(
                backend, "resolve_kdebug", return_value="fake"
            ), mock.patch.object(
                backend.KDebugClient, "request", return_value=response
            ) as request:
                backend.run_trace(args)

            self.assertEqual(request.call_count, 1)
            action, action_args, _ = request.call_args[0]
            self.assertEqual(action, "port.trace_batch")
            self.assertEqual(action_args["stop_instances"], sorted(unique_stops))
            self.assertEqual(len(action_args["stop_instances"]), 5000)
            self.assertEqual(request.call_args[1], {"allow_truncated": True})
            self.assertFalse(response["data"]["truncated"])
            self.assertFalse(backend._response_truncated(response))
            self.assertTrue(full.is_file())
            self.assertTrue(boundary.is_file())

    def test_bundled_engine_accepts_large_stop_plan_without_weakening_validation(self):
        engine = load_bundled_kdebug_engine()
        schema_path = (
            Path(__file__).resolve().parent
            / "kdebug"
            / "schemas"
            / "v1"
            / "actions"
            / "port.trace_batch.request.schema.json"
        )
        schema = json.loads(schema_path.read_text(encoding="utf-8"))
        args_schema = schema["properties"]["args"]["properties"]
        self.assertNotIn("maxItems", args_schema["stop_instances"])
        self.assertTrue(args_schema["stop_instances"]["uniqueItems"])
        self.assertEqual(args_schema["ports"]["maxItems"], 4096)
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            daidir = root / "simv.daidir"
            daidir.mkdir()
            plan_dir = root / "plans"
            plan_dir.mkdir()
            stops = ["top.tile{}.u_stop".format(index) for index in range(50000)]
            args = {
                "module": "Target",
                "ports": ["a"],
                "stop_instances": stops,
                "options": {},
            }
            environment = engine.prepare_port_trace_environment(
                args, {}, {"daidir": str(daidir)}, str(plan_dir)
            )
            stop_plan = Path(environment["KDEBUG_TCL_STOP_INSTANCE_PLAN"])
            encoded_rows = stop_plan.read_text(encoding="utf-8").splitlines()
            self.assertEqual(len(encoded_rows), 50000)
            self.assertEqual(bytes.fromhex(encoded_rows[0]).decode("utf-8"), stops[0])
            self.assertEqual(bytes.fromhex(encoded_rows[-1]).decode("utf-8"), stops[-1])

            duplicate_args = dict(args)
            duplicate_args["stop_instances"] = ["top.u_stop", "top.u_stop"]
            with self.assertRaisesRegex(ValueError, "must not contain duplicates"):
                engine.prepare_port_trace_environment(
                    duplicate_args, {}, {"daidir": str(daidir)}, str(plan_dir)
                )

            empty_args = dict(args)
            empty_args["stop_instances"] = [""]
            with self.assertRaisesRegex(ValueError, "must be a non-empty string"):
                engine.prepare_port_trace_environment(
                    empty_args, {}, {"daidir": str(daidir)}, str(plan_dir)
                )

            too_many_ports_args = dict(args)
            too_many_ports_args["ports"] = [
                "p{}".format(index) for index in range(4097)
            ]
            too_many_ports_args["stop_instances"] = []
            with self.assertRaisesRegex(ValueError, "at most 4096 items"):
                engine.prepare_port_trace_environment(
                    too_many_ports_args, {}, {"daidir": str(daidir)}, str(plan_dir)
                )

    @unittest.skipUnless(
        os.name == "posix" and shutil.which("tclsh") is not None,
        "large stop-instance semantics require POSIX tclsh",
    )
    def test_bundled_tcl_indexes_50000_stop_instances_with_stable_semantics(self):
        root = Path(__file__).resolve().parent
        trace_tcl = root / "kdebug" / "libexec" / "tcl_engine" / "kdebug_port_trace.tcl"
        script = r'''
source $::env(KDEBUG_PORT_TRACE_TCL)

proc assert_stop_match {label expected signal_name} {
    set actual [signal_belongs_to_stop_instance $signal_name]
    if {$actual != $expected} {
        puts stderr "FAILED $label signal={$signal_name} expected=$expected actual=$actual"
        exit 2
    }
}

set stops {}
for {set index 0} {$index < 50000} {incr index} {
    lappend stops "Top.tile${index}.u_stop"
}
configure_load_trace_stop_instances $stops
if {[dict size $load_trace_stop_instance_set] != 50000} {
    puts stderr "FAILED configured stop count"
    exit 2
}

set current_trace_instance Top.tile7.u_stop
assert_stop_match exact 1 Top.tile0.u_stop
assert_stop_match exact_last 1 Top.tile49999.u_stop
assert_stop_match direct 1 Top.tile0.u_stop.out
assert_stop_match direct_child_port 1 Top.tile0.u_stop.child.out
assert_stop_match deep 0 Top.tile0.u_stop.child.deep.out
assert_stop_match slash 1 Top.tile0.u_stop/net/deep
assert_stop_match current_exact 0 Top.tile7.u_stop
assert_stop_match current_direct 0 Top.tile7.u_stop.out
assert_stop_match current_deep 0 Top.tile7.u_stop.child.out
assert_stop_match bit_select 1 {Top.tile0.u_stop.out[3]}
assert_stop_match missing 0 Top.missing.u_stop.out
assert_stop_match constant 0 {Const:1'b0}

set started [clock milliseconds]
for {set index 0} {$index < 2000} {incr index} {
    if {[signal_belongs_to_stop_instance "Top.missing${index}.net"]} {
        puts stderr "FAILED scaled miss query index=$index"
        exit 2
    }
}
puts "OK stops=50000 misses=2000 elapsed_ms=[expr {[clock milliseconds] - $started}]"
'''
        env = dict(os.environ)
        env["KDEBUG_PORT_TRACE_TCL"] = str(trace_tcl)
        completed = subprocess.run(
            [shutil.which("tclsh")],
            input=script,
            cwd=str(root),
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            timeout=60,
            check=False,
        )
        self.assertEqual(completed.returncode, 0, completed.stderr)
        self.assertIn("OK stops=50000 misses=2000", completed.stdout)

    def test_missing_requested_port_is_nonfatal_and_publishes_empty_csv(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            kdb = root / "simv.daidir" / "kdb.elab++"
            kdb.mkdir(parents=True)
            full = root / "full.csv"
            boundary = root / "boundary.csv"
            args = backend.build_parser().parse_args(
                [
                    "trace", "--lib", str(kdb), "--module", "Target",
                    "--ports", "missing", "--full-out", str(full),
                    "--module-out", str(boundary),
                ]
            )
            response = {"data": {
                "module": "Target", "requested_ports": ["missing"], "traced_ports": [],
                "selection_mode": "explicit", "full_rows": [], "boundary_rows": [],
                "evidence": [], "errors": [{
                    "scope": "port", "code": "PORT_NOT_FOUND",
                    "message": "requested port was not found on traced instance",
                    "instance": "top.u0", "port": "missing",
                }],
                "truncated": False, "stats": {"processed_instances": 1},
            }}
            stderr = io.StringIO()
            with contextlib.redirect_stderr(stderr), mock.patch.object(
                backend, "resolve_kdebug", return_value="fake"
            ), mock.patch.object(backend.KDebugClient, "request", return_value=response):
                backend.run_trace(args)

            with full.open(encoding="utf-8") as handle:
                self.assertEqual(list(csv.DictReader(handle)), [])
            with boundary.open(encoding="utf-8") as handle:
                self.assertEqual(list(csv.DictReader(handle)), [])
            self.assertIn("PORT_NOT_FOUND", stderr.getvalue())

    def test_unknown_port_trace_batch_does_not_fall_back(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            kdb = root / "simv.daidir" / "kdb.elab++"
            kdb.mkdir(parents=True)
            full = root / "full.csv"
            boundary = root / "boundary.csv"
            args = backend.build_parser().parse_args(
                [
                    "trace", "--lib", str(kdb), "--module", "Target",
                    "--full-out", str(full), "--module-out", str(boundary),
                ]
            )
            with mock.patch.object(backend, "resolve_kdebug", return_value="fake"), mock.patch.object(
                backend.KDebugClient, "request",
                side_effect=backend.KDebugError("not installed", "UNKNOWN_ACTION"),
            ) as request, self.assertRaises(backend.KDebugError):
                backend.run_trace(args)
            self.assertEqual(request.call_count, 1)
            self.assertEqual(request.call_args[0][0], "port.trace_batch")
            self.assertFalse(full.exists())
            self.assertFalse(boundary.exists())

    def test_csv_pair_rolls_back_when_second_publish_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            full = root / "full.csv"
            boundary = root / "boundary.csv"
            full.write_text("old full\n", encoding="utf-8")
            boundary.write_text("old boundary\n", encoding="utf-8")
            real_replace = os.replace

            def fail_boundary_publish(source, destination):
                source_path = Path(source)
                destination_path = Path(destination)
                if destination_path == boundary.resolve() and source_path.suffix == ".tmp":
                    raise OSError("injected boundary publish failure")
                return real_replace(source, destination)

            with mock.patch.object(backend.os, "replace", side_effect=fail_boundary_publish):
                with self.assertRaises(OSError):
                    backend.atomic_write_csv_pair(
                        full,
                        ["kind"],
                        [["new full"]],
                        boundary,
                        ["kind"],
                        [["new boundary"]],
                    )

            self.assertEqual(full.read_text(encoding="utf-8"), "old full\n")
            self.assertEqual(boundary.read_text(encoding="utf-8"), "old boundary\n")
            self.assertEqual(list(root.glob("*.tmp")), [])
            self.assertEqual(list(root.glob("*.rollback")), [])

    def test_csv_pair_preserves_recovery_copy_when_rollback_fails(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            full = root / "full.csv"
            boundary = root / "boundary.csv"
            full.write_text("old full\n", encoding="utf-8")
            boundary.write_text("old boundary\n", encoding="utf-8")
            real_replace = os.replace

            def fail_publish_and_rollback(source, destination):
                source_path = Path(source)
                destination_path = Path(destination)
                if destination_path == boundary.resolve() and source_path.suffix == ".tmp":
                    raise OSError("injected boundary publish failure")
                if destination_path == full.resolve() and source_path.suffix == ".rollback":
                    raise OSError("injected full rollback failure")
                return real_replace(source, destination)

            with mock.patch.object(
                backend.os, "replace", side_effect=fail_publish_and_rollback
            ), self.assertRaises(backend.KDebugError) as caught:
                backend.atomic_write_csv_pair(
                    full,
                    ["kind"],
                    [["new full"]],
                    boundary,
                    ["kind"],
                    [["new boundary"]],
                )

            self.assertEqual(caught.exception.code, "OUTPUT_ROLLBACK_FAILED")
            self.assertEqual(boundary.read_text(encoding="utf-8"), "old boundary\n")
            recovery = list(root.glob("*.rollback"))
            self.assertEqual(len(recovery), 1)
            self.assertEqual(recovery[0].read_text(encoding="utf-8"), "old full\n")
            self.assertIn(str(recovery[0]), str(caught.exception))

    def test_csv_pair_rejects_output_path_collision(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "same.csv"
            with self.assertRaises(backend.KDebugError) as caught:
                backend.atomic_write_csv_pair(
                    output, ["a"], [["1"]], output, ["b"], [["2"]]
                )
            self.assertEqual(caught.exception.code, "OUTPUT_PATH_COLLISION")


@unittest.skipUnless(os.name == "posix", "executable fake kdebug test requires POSIX")
class KDebugClientProcessTest(unittest.TestCase):
    def make_fake(self, root: Path, body: str) -> Path:
        executable = root / "fake_kdebug.py"
        executable.write_text("#!/usr/bin/env python3\n" + body, encoding="utf-8")
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
        return executable

    def make_client(self, root: Path, body: str) -> backend.KDebugClient:
        daidir = root / "simv.daidir"
        daidir.mkdir()
        return backend.KDebugClient(str(self.make_fake(root, body)), daidir)

    def test_rejects_ok_false_even_with_process_rc_zero(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            client = self.make_client(
                Path(tmpdir),
                "import json, sys\n"
                "request = json.load(sys.stdin)\n"
                "json.dump({'api_version':'kdebug.v1','action':request['action'],'ok':False,'error':{'code':'BROKEN','message':'bad'}}, sys.stdout)\n",
            )
            with self.assertRaises(backend.KDebugError) as caught:
                client.request("module.find_instances", {"definition": "M"})
            self.assertEqual(caught.exception.code, "BROKEN")

    def test_preserves_structured_error_from_nonzero_process(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            client = self.make_client(
                Path(tmpdir),
                "import json, sys\n"
                "request = json.load(sys.stdin)\n"
                "json.dump({'api_version':'kdebug.v1','action':request['action'],'ok':False,'error':{'code':'UNKNOWN_ACTION','message':'not installed'}}, sys.stdout)\n"
                "raise SystemExit(2)\n",
            )
            with self.assertRaises(backend.KDebugError) as caught:
                client.request("port.trace_batch", {"module": "Target"})
            self.assertEqual(caught.exception.code, "UNKNOWN_ACTION")
            self.assertIn("kdebug rc=2", str(caught.exception))

    def test_nonzero_process_reports_stdout_when_stderr_is_empty(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            client = self.make_client(
                Path(tmpdir),
                "import sys\n"
                "sys.stdout.write('launcher diagnostic')\n"
                "raise SystemExit(1)\n",
            )
            with self.assertRaises(backend.KDebugError) as caught:
                client.request("module.find_instances", {"definition": "M"})
            self.assertEqual(caught.exception.code, "KDEBUG_PROCESS_FAILED")
            self.assertIn("launcher diagnostic", str(caught.exception))

    def test_rejects_truncated_success(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            client = self.make_client(
                Path(tmpdir),
                "import json, sys\n"
                "request = json.load(sys.stdin)\n"
                "json.dump({'api_version':'kdebug.v1','action':request['action'],'ok':True,'summary':{'truncated':True},'data':{}}, sys.stdout)\n",
            )
            with self.assertRaises(backend.KDebugError) as caught:
                client.request("module.find_instances", {"definition": "M"})
            self.assertEqual(caught.exception.code, "KDEBUG_TRUNCATED")

    def test_trace_cli_publishes_csv_and_constant_evidence(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            daidir = root / "simv.daidir"
            kdb = daidir / "kdb.elab++"
            kdb.mkdir(parents=True)
            (kdb / "marker").write_text("kdb", encoding="utf-8")
            fake = self.make_fake(
                root,
                "import json, sys\n"
                "r = json.load(sys.stdin)\n"
                f"assert r['target']['daidir'] == {str(kdb.resolve())!r}\n"
                "a = r['action']\n"
                "if a != 'port.trace_batch':\n"
                " json.dump({'api_version':'kdebug.v1','action':a,'ok':False,'error':{'code':'UNKNOWN_ACTION','message':a}},sys.stdout); raise SystemExit(2)\n"
                "row = {'inst_full_name':'top.u0','port_name':'a','port_dir':'input','role':'driver','signal_full_name':\"Const:1'b1\"}\n"
                "ev = {'kind':'constant','value':\"Const:1'b1\",'method':'source_port_connection','role':'driver','port_path':'top.u0.a','const_full_path':\"top.u0.a<-Const:1'b1\",'effective':True,'constant':{'value':\"Const:1'b1\",'effective':True},'provenance':{'origin':'source_port_connection','unconditional':True,'path':['top.u0.a',\"Const:1'b1\"],'source':{'file':'rtl/top.sv','line':'9','raw_handle':'7'}}}\n"
                "data = {'module':'Target','requested_ports':['a'],'traced_ports':['a'],'selection_mode':'explicit','full_rows':[row],'boundary_rows':[row],'evidence':[ev],'errors':[],'truncated':False,'stats':{'processed_instances':1}}\n"
                "json.dump({'api_version':'kdebug.v1','action':a,'ok':True,'summary':{'truncated':False},'data':data,'meta':{'truncated':False}},sys.stdout)\n",
            )
            full = root / "full.csv"
            boundary = root / "boundary.csv"
            proc = subprocess.run(
                [
                    sys.executable,
                    str(Path(backend.__file__).resolve()),
                    "trace",
                    "--lib",
                    str(kdb),
                    "--module",
                    "Target",
                    "--ports",
                    "a",
                    "--full-out",
                    str(full),
                    "--module-out",
                    str(boundary),
                    "--kdebug-bin",
                    str(fake),
                ],
                universal_newlines=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                check=False,
            )
            self.assertEqual(proc.returncode, 0, proc.stderr)
            with full.open(encoding="utf-8") as handle:
                rows = list(csv.DictReader(handle))
            self.assertIn(
                {
                    "inst_full_name": "top.u0",
                    "port_name": "a",
                    "port_dir": "input",
                    "role": "driver",
                    "signal_full_name": "Const:1'b1",
                },
                rows,
            )
            self.assertIn("evidence_source=kdebug.port.trace_batch", proc.stderr)
            self.assertIn("const_full_path=top.u0.a<-Const:1'b1", proc.stderr)
            self.assertTrue(boundary.stat().st_size > 0)

    def test_client_timeout_kills_its_process_group(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            pidfile = root / "child.pid"
            client = self.make_client(
                root,
                "import os, signal, time\n"
                "pid = os.fork()\n"
                "if pid == 0:\n"
                " signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                " open(%r, 'w').write(str(os.getpid()))\n"
                " while True: time.sleep(1)\n"
                "signal.signal(signal.SIGTERM, signal.SIG_IGN)\n"
                "while True: time.sleep(1)\n" % str(pidfile),
            )
            client.timeout_sec = 1
            with mock.patch.dict(
                os.environ, {"KDEBUG_CLIENT_CLEANUP_GRACE_SEC": "0.1"}
            ), self.assertRaises(backend.KDebugError) as caught:
                client.request("module.find_instances", {"definition": "M"})
            self.assertEqual(caught.exception.code, "KDEBUG_TIMEOUT")
            deadline = time.monotonic() + 3
            while not pidfile.exists() and time.monotonic() < deadline:
                time.sleep(0.05)
            self.assertTrue(pidfile.exists())
            child_pid = int(pidfile.read_text(encoding="utf-8"))
            deadline = time.monotonic() + 3
            while time.monotonic() < deadline:
                try:
                    os.kill(child_pid, 0)
                except ProcessLookupError:
                    break
                stat_path = Path("/proc") / str(child_pid) / "stat"
                if stat_path.exists() and ") Z " in stat_path.read_text(errors="replace"):
                    break
                time.sleep(0.05)
            else:
                self.fail("fake kdebug child survived timeout cleanup")


if __name__ == "__main__":
    unittest.main()
