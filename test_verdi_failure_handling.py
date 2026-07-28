import importlib.util
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


SCRIPT_DIR = Path(__file__).resolve().parent


def load_find_instances_module():
    spec = importlib.util.spec_from_file_location(
        "find_instances_batched_under_test",
        SCRIPT_DIR / "find_instances_batched.py",
    )
    module = importlib.util.module_from_spec(spec)
    assert spec.loader is not None
    spec.loader.exec_module(module)
    return module


@unittest.skipUnless(os.name == "posix", "fake Verdi process tests require POSIX signals")
class VerdiFailureHandlingTest(unittest.TestCase):
    def make_fake_verdi(self, root: Path, body: str) -> Path:
        bindir = root / "bin"
        bindir.mkdir()
        executable = bindir / "verdi"
        executable.write_text("#!/bin/sh\n" + body, encoding="utf-8")
        executable.chmod(executable.stat().st_mode | stat.S_IXUSR)
        return bindir

    def base_env(self, bindir: Path) -> dict:
        env = os.environ.copy()
        env["PATH"] = f"{bindir}{os.pathsep}{env.get('PATH', '')}"
        env["VERDI_HOME"] = str(bindir.parent)
        env["FAKE_CHILD_PIDFILE"] = str(bindir.parent / "child.pid")
        return env

    def assert_pid_disappears(self, pid: int, timeout: float = 3) -> None:
        deadline = time.monotonic() + timeout
        while time.monotonic() < deadline:
            try:
                os.kill(pid, 0)
            except ProcessLookupError:
                return
            time.sleep(0.05)
        self.fail(f"child pid {pid} survived Verdi session cleanup")

    def run_npi_trace(
        self,
        root: Path,
        bindir: Path,
        *extra_args: str,
    ) -> subprocess.CompletedProcess:
        kdb = root / "kdb.elab++"
        kdb.write_text("fake kdb\n", encoding="utf-8")
        module_output = root / "module.csv"
        return subprocess.run(
            self.npi_trace_command(root, kdb, module_output, *extra_args),
            cwd=root,
            env=self.base_env(bindir),
            text=True,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            timeout=15,
            check=False,
        )

    def npi_trace_command(
        self,
        root: Path,
        kdb: Path,
        module_output: Path,
        *extra_args: str,
    ) -> list:
        return [
            "bash",
            str(SCRIPT_DIR / "npi_trace.sh"),
            "-module",
            "FakeModule",
            "-lib",
            str(kdb),
            "-module-out",
            str(module_output),
            *extra_args,
        ]

    def test_npi_trace_rejects_exit_9_and_removes_partial_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                'printf "header\\npartial\\n" > "$NPI_OUTFILE"\n'
                'printf "module partial\\n" > "$NPI_MODULE_OUTFILE"\n'
                "exit 9\n",
            )

            proc = self.run_npi_trace(root, bindir)

            self.assertEqual(proc.returncode, 9, proc.stderr)
            self.assertEqual(proc.stdout, "")
            self.assertIn("failed with exit code 9", proc.stderr)
            self.assertFalse((root / "module.csv").exists())
            self.assertEqual(list(root.glob("npi_trace_out.*.csv")), [])
            self.assertEqual(list(root.glob("npi_trace_timeout.*")), [])

    def test_npi_trace_keeps_successful_outputs(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                'printf "header\\ncomplete\\n" > "$NPI_OUTFILE"\n'
                'printf "module complete\\n" > "$NPI_MODULE_OUTFILE"\n'
                "exit 0\n",
            )

            proc = self.run_npi_trace(root, bindir)

            self.assertEqual(proc.returncode, 0, proc.stderr)
            self.assertEqual(proc.stdout, "header\ncomplete\n")
            self.assertEqual((root / "module.csv").read_text(), "module complete\n")
            self.assertEqual(list(root.glob("npi_trace_out.*.csv")), [])
            self.assertEqual(list(root.glob("npi_trace_timeout.*")), [])

    def test_npi_trace_rejects_stdout_write_failure_and_cleans_outputs(self) -> None:
        dev_full = Path("/dev/full")
        if not dev_full.exists():
            self.skipTest("/dev/full is required for stdout failure injection")

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                'printf "header\\ncomplete\\n" > "$NPI_OUTFILE"\n'
                'printf "module complete\\n" > "$NPI_MODULE_OUTFILE"\n'
                "exit 0\n",
            )
            kdb = root / "kdb.elab++"
            kdb.write_text("fake kdb\n", encoding="utf-8")
            module_output = root / "module.csv"

            with dev_full.open("wb") as full_sink:
                proc = subprocess.run(
                    self.npi_trace_command(root, kdb, module_output),
                    cwd=root,
                    env=self.base_env(bindir),
                    stdout=full_sink,
                    stderr=subprocess.PIPE,
                    text=True,
                    timeout=15,
                    check=False,
                )

            self.assertNotEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("failed to write full trace CSV", proc.stderr)
            self.assertFalse(module_output.exists())
            self.assertEqual(list(root.glob("npi_trace_out.*.csv")), [])
            self.assertEqual(list(root.glob("npi_trace_timeout.*")), [])

    def test_npi_trace_force_kills_verdi_that_ignores_term(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                "trap '' TERM\n"
                'printf "header\\npartial\\n" > "$NPI_OUTFILE"\n'
                'printf "module partial\\n" > "$NPI_MODULE_OUTFILE"\n'
                "while :; do sleep 1; done\n",
            )

            started = time.monotonic()
            proc = self.run_npi_trace(root, bindir, "--verdi-timeout-sec", "1")
            elapsed = time.monotonic() - started

            self.assertEqual(proc.returncode, 124, proc.stderr)
            self.assertLess(elapsed, 10)
            self.assertEqual(proc.stdout, "")
            self.assertIn("timed out after 1s", proc.stderr)
            self.assertFalse((root / "module.csv").exists())
            self.assertEqual(list(root.glob("npi_trace_out.*.csv")), [])
            self.assertEqual(list(root.glob("npi_trace_timeout.*")), [])

    def test_npi_trace_does_not_misclassify_verdi_exit_124_as_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                'printf "header\\npartial\\n" > "$NPI_OUTFILE"\n'
                'printf "module partial\\n" > "$NPI_MODULE_OUTFILE"\n'
                "exit 124\n",
            )

            proc = self.run_npi_trace(root, bindir, "--verdi-timeout-sec", "5")

            self.assertEqual(proc.returncode, 125, proc.stderr)
            self.assertIn("failed with exit code 124", proc.stderr)
            self.assertNotIn("timed out", proc.stderr)
            self.assertFalse((root / "module.csv").exists())
            self.assertEqual(list(root.glob("npi_trace_out.*.csv")), [])
            self.assertEqual(list(root.glob("npi_trace_timeout.*")), [])

    def test_npi_trace_does_not_misclassify_verdi_sigkill_137_as_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                'printf "header\\npartial\\n" > "$NPI_OUTFILE"\n'
                'printf "module partial\\n" > "$NPI_MODULE_OUTFILE"\n'
                "kill -KILL $$\n",
            )

            proc = self.run_npi_trace(root, bindir, "--verdi-timeout-sec", "5")

            self.assertEqual(proc.returncode, 125, proc.stderr)
            self.assertIn("failed with exit code 137", proc.stderr)
            self.assertNotIn("timed out", proc.stderr)
            self.assertFalse((root / "module.csv").exists())
            self.assertEqual(list(root.glob("npi_trace_out.*.csv")), [])
            self.assertEqual(list(root.glob("npi_trace_timeout.*")), [])

    def test_npi_trace_kills_child_after_leader_exits_on_term(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                "(trap '' TERM; while :; do sleep 1; done) "
                "</dev/null >/dev/null 2>&1 &\n"
                'printf "%s\\n" "$!" > "$FAKE_CHILD_PIDFILE"\n'
                'printf "header\\npartial\\n" > "$NPI_OUTFILE"\n'
                'printf "module partial\\n" > "$NPI_MODULE_OUTFILE"\n'
                "trap 'exit 23' TERM\n"
                "while :; do sleep 1; done\n",
            )

            proc = self.run_npi_trace(root, bindir, "--verdi-timeout-sec", "1")
            child_pid = int((root / "child.pid").read_text(encoding="utf-8").strip())

            self.assertNotEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("timed out after 1s", proc.stderr)
            self.assertIn("cleaning Verdi session", proc.stderr)
            self.assert_pid_disappears(child_pid)
            self.assertEqual(proc.stdout, "")
            self.assertFalse((root / "module.csv").exists())
            self.assertEqual(list(root.glob("npi_trace_out.*.csv")), [])

    def test_npi_trace_exit_trap_kills_session_on_external_timeout(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                "(trap '' TERM; while :; do sleep 1; done) "
                "</dev/null >/dev/null 2>&1 &\n"
                'printf "%s\\n" "$!" > "$FAKE_CHILD_PIDFILE"\n'
                "trap '' TERM\n"
                "while :; do sleep 1; done\n",
            )
            kdb = root / "kdb.elab++"
            kdb.write_text("fake kdb\n", encoding="utf-8")
            module_output = root / "module.csv"
            inner_command = self.npi_trace_command(
                root,
                kdb,
                module_output,
                "--verdi-timeout-sec",
                "30",
            )

            proc = subprocess.run(
                ["timeout", "--kill-after=8s", "1s", *inner_command],
                cwd=root,
                env=self.base_env(bindir),
                text=True,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=12,
                check=False,
            )
            child_pid = int((root / "child.pid").read_text(encoding="utf-8").strip())

            self.assertNotEqual(proc.returncode, 0, proc.stderr)
            self.assertIn("exit cleanup for Verdi session", proc.stderr)
            self.assert_pid_disappears(child_pid)
            self.assertEqual(proc.stdout, "")
            self.assertFalse(module_output.exists())
            self.assertEqual(list(root.glob("npi_trace_out.*.csv")), [])

    def test_instance_finder_force_kills_verdi_that_ignores_term(self) -> None:
        module = load_find_instances_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                "trap '' TERM\n"
                'printf "partial.instance\\n" > "$NPI_INSTANCE_OUTFILE"\n'
                "while :; do sleep 1; done\n",
            )
            outfile = root / "instances.txt"
            args = SimpleNamespace(
                lib=root / "kdb.elab++",
                log_instances=False,
                verdi_timeout_sec=1,
            )

            with mock.patch.dict(os.environ, self.base_env(bindir), clear=True), mock.patch.object(
                module,
                "VERDI_KILL_AFTER_SEC",
                0.2,
            ):
                started = time.monotonic()
                with self.assertRaises(subprocess.TimeoutExpired):
                    module.run_verdi_find(args, ["FakeModule"], "1", outfile)
                elapsed = time.monotonic() - started

            self.assertLess(elapsed, 3)
            self.assertEqual(module.read_instances(outfile), ["partial.instance"])

    def test_instance_finder_kills_child_after_leader_exits_on_term(self) -> None:
        module = load_find_instances_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                "(trap '' TERM; while :; do sleep 1; done) "
                "</dev/null >/dev/null 2>&1 &\n"
                'printf "%s\\n" "$!" > "$FAKE_CHILD_PIDFILE"\n'
                'printf "partial.instance\\n" > "$NPI_INSTANCE_OUTFILE"\n'
                "trap 'exit 23' TERM\n"
                "while :; do sleep 1; done\n",
            )
            outfile = root / "instances.txt"
            args = SimpleNamespace(
                lib=root / "kdb.elab++",
                log_instances=False,
                verdi_timeout_sec=1,
            )

            with mock.patch.dict(os.environ, self.base_env(bindir), clear=True), mock.patch.object(
                module,
                "VERDI_KILL_AFTER_SEC",
                0.2,
            ):
                with self.assertRaises(subprocess.TimeoutExpired):
                    module.run_verdi_find(args, ["FakeModule"], "1", outfile)

            child_pid = int((root / "child.pid").read_text(encoding="utf-8").strip())
            self.assert_pid_disappears(child_pid)

    def test_instance_finder_cleans_child_after_successful_leader_exit(self) -> None:
        module = load_find_instances_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                "(trap '' HUP TERM; while :; do sleep 1; done) "
                "</dev/null >/dev/null 2>&1 &\n"
                'printf "%s\\n" "$!" > "$FAKE_CHILD_PIDFILE"\n'
                'printf "top.u0\\n" > "$NPI_INSTANCE_OUTFILE"\n'
                "exit 0\n",
            )
            outfile = root / "instances.txt"
            args = SimpleNamespace(
                lib=root / "kdb.elab++",
                log_instances=False,
                verdi_timeout_sec=1,
            )

            with mock.patch.dict(os.environ, self.base_env(bindir), clear=True), mock.patch.object(
                module,
                "VERDI_KILL_AFTER_SEC",
                0.2,
            ):
                instances = module.run_verdi_find(args, ["FakeModule"], "1", outfile)

            child_pid = int((root / "child.pid").read_text(encoding="utf-8").strip())
            self.assertEqual(instances, ["top.u0"])
            self.assert_pid_disappears(child_pid)

    def test_instance_finder_zero_timeout_keeps_legacy_behavior(self) -> None:
        module = load_find_instances_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                'printf "top.u0\\ntop.u1\\n" > "$NPI_INSTANCE_OUTFILE"\n'
                "exit 0\n",
            )
            outfile = root / "instances.txt"
            args = SimpleNamespace(
                lib=root / "kdb.elab++",
                log_instances=False,
                verdi_timeout_sec=0,
            )

            with mock.patch.dict(os.environ, self.base_env(bindir), clear=True):
                instances = module.run_verdi_find(args, ["FakeModule"], "1", outfile)

            self.assertEqual(instances, ["top.u0", "top.u1"])

    def test_annotate_runner_kills_child_after_leader_exits_on_term(self) -> None:
        from annotate_trace_xlsx import run_checked

        module = load_find_instances_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                "(trap '' TERM; while :; do sleep 1; done) "
                "</dev/null >/dev/null 2>&1 &\n"
                'printf "%s\\n" "$!" > "$FAKE_CHILD_PIDFILE"\n'
                "trap 'exit 23' TERM\n"
                "while :; do sleep 1; done\n",
            )

            with mock.patch.object(module, "VERDI_KILL_AFTER_SEC", 0.2), mock.patch(
                "annotate_trace_xlsx.terminate_timed_out_process",
                side_effect=module.terminate_timed_out_process,
            ):
                with self.assertRaises(subprocess.TimeoutExpired):
                    run_checked(
                        [str(bindir / "verdi")],
                        root,
                        env=self.base_env(bindir),
                        timeout_sec=1,
                    )

            child_pid = int((root / "child.pid").read_text(encoding="utf-8").strip())
            self.assert_pid_disappears(child_pid)

    def test_annotate_runner_cleans_child_after_successful_leader_exit(self) -> None:
        from annotate_trace_xlsx import run_checked

        module = load_find_instances_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            bindir = self.make_fake_verdi(
                root,
                "(trap '' HUP TERM; while :; do sleep 1; done) "
                "</dev/null >/dev/null 2>&1 &\n"
                'printf "%s\\n" "$!" > "$FAKE_CHILD_PIDFILE"\n'
                "exit 0\n",
            )

            with mock.patch.object(module, "VERDI_KILL_AFTER_SEC", 0.2), mock.patch(
                "annotate_trace_xlsx.cleanup_completed_process_session",
                side_effect=module.cleanup_completed_process_session,
            ):
                run_checked(
                    [str(bindir / "verdi")],
                    root,
                    env=self.base_env(bindir),
                    timeout_sec=1,
                )

            child_pid = int((root / "child.pid").read_text(encoding="utf-8").strip())
            self.assert_pid_disappears(child_pid)


class ErrorLogCleanupTest(unittest.TestCase):
    def test_empty_error_list_removes_stale_log(self) -> None:
        module = load_find_instances_module()
        with tempfile.TemporaryDirectory() as tmpdir:
            output = Path(tmpdir) / "instances.txt"
            error_log = Path(tmpdir) / "instances_errors.log"
            error_log.write_text("stale failure\n", encoding="utf-8")

            module.write_errors(output, [])

            self.assertFalse(error_log.exists())


if __name__ == "__main__":
    unittest.main()
