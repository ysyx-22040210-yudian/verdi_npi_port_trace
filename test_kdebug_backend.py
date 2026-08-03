import contextlib
import csv
import io
import json
import os
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


class KDebugBackendContractTest(unittest.TestCase):
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

    def test_normalize_nested_kdb_to_daidir(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            daidir = Path(tmpdir) / "simv.daidir"
            kdb = daidir / "kdb.elab++"
            kdb.mkdir(parents=True)
            self.assertEqual(backend.normalize_daidir(kdb), daidir.resolve())
            self.assertEqual(backend.normalize_daidir(daidir), daidir.resolve())

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
