#!/usr/bin/env python3

import csv
import hashlib
import importlib.util
import os
import subprocess
import sys
import tempfile
import unittest
from contextlib import contextmanager
from pathlib import Path
from unittest import mock

import annotate_trace_xlsx
import filter_trace
import find_instances_batched
import kdebug_backend
import runtime_paths
import trace_gui


@contextmanager
def practical_component_limit(parent):
    """Use the real POSIX NAME_MAX and stay below legacy Windows MAX_PATH."""

    limit = runtime_paths.component_name_limit(parent)
    if os.name != "nt":
        yield limit
        return

    parent_bytes = len(os.fsencode(str(parent)))
    adjusted = max(80, min(limit, 240 - parent_bytes - 1))
    with mock.patch.object(runtime_paths, "component_name_limit", return_value=adjusted):
        yield adjusted


def name_max_path(parent, prefix, suffix):
    limit = int(os.pathconf(str(parent), "PC_NAME_MAX"))
    fixed = len((prefix + suffix).encode("utf-8"))
    if fixed >= limit:
        raise AssertionError("test prefix and suffix leave no NAME_MAX payload budget")
    return parent / (prefix + ("x" * (limit - fixed)) + suffix)


def assert_no_temp_files(testcase, parent, *prefixes):
    leftovers = [
        path.name
        for path in parent.iterdir()
        if any(path.name.startswith(prefix) for prefix in prefixes)
    ]
    testcase.assertEqual(leftovers, [])


class RuntimePathTests(unittest.TestCase):
    @staticmethod
    def expected_digest(candidate, identity=None):
        identity_text = candidate if identity in (None, "") else identity
        material = candidate + "\0" + identity_text
        return hashlib.sha256(material.encode("utf-8")).hexdigest()[:16]

    def bounded_at(self, limit, candidate, suffix="", identity=None):
        with mock.patch.object(runtime_paths, "component_name_limit", return_value=limit):
            return runtime_paths.bounded_component(
                candidate,
                suffix=suffix,
                identity=identity,
            )

    def test_sanitize_component_matches_legacy_ascii_names(self):
        self.assertEqual(runtime_paths.sanitize_component("top/u key[0]"), "top_u_key_0")
        self.assertEqual(runtime_paths.sanitize_component("..."), "unnamed")

    def test_short_names_remain_unchanged(self):
        self.assertEqual(self.bounded_at(255, "result.csv"), "result.csv")
        self.assertEqual(self.bounded_at(255, "result", suffix=".csv"), "result.csv")
        self.assertEqual(
            self.bounded_at(255, "result.csv", suffix=".csv"),
            "result.csv",
        )

    def test_ascii_boundary_uses_exact_byte_limit(self):
        self.assertEqual(self.bounded_at(64, "a" * 60, suffix=".csv"), "a" * 60 + ".csv")

        shortened = self.bounded_at(64, "a" * 61, suffix=".csv")
        digest = self.expected_digest("a" * 61)
        self.assertEqual(len(shortened.encode("utf-8")), 64)
        self.assertTrue(shortened.endswith("__h_{}{}".format(digest, ".csv")))

    def test_unicode_is_truncated_on_utf8_boundary(self):
        candidate = "\u6d4b" * 20
        shortened = self.bounded_at(33, candidate, suffix=".csv")
        digest = self.expected_digest(candidate)
        self.assertEqual(shortened, "\u6d4b" * 3 + "__h_{}{}".format(digest, ".csv"))
        self.assertEqual(len(shortened.encode("utf-8")), 33)

    def test_shortening_is_stable_and_long_tails_do_not_collide(self):
        shared = "top.subsystem." + "instance_" * 20
        first = self.bounded_at(80, shared + "first")
        first_again = self.bounded_at(80, shared + "first")
        second = self.bounded_at(80, shared + "second")
        self.assertEqual(first, first_again)
        self.assertNotEqual(first, second)
        self.assertLessEqual(len(first.encode("utf-8")), 80)
        self.assertLessEqual(len(second.encode("utf-8")), 80)

    def test_explicit_identity_controls_digest(self):
        identity = "original/full/design/path"
        shortened = self.bounded_at(48, "x" * 100, suffix=".xlsx", identity=identity)
        digest = self.expected_digest("x" * 100, identity)
        self.assertTrue(shortened.endswith("__h_{}.xlsx".format(digest)))

    def test_digest_includes_candidate_and_raw_identity(self):
        identity = "same/raw/subsystem"
        first = self.bounded_at(48, "first_" + "x" * 100, identity=identity)
        second = self.bounded_at(48, "second_" + "x" * 100, identity=identity)
        self.assertNotEqual(first, second)

        candidate = "same_sanitized_" + "x" * 100
        raw_first = self.bounded_at(48, candidate, identity="raw/first")
        raw_second = self.bounded_at(48, candidate, identity="raw:first")
        self.assertNotEqual(raw_first, raw_second)

    def test_bounded_path_only_changes_final_component(self):
        with mock.patch.object(runtime_paths, "component_name_limit", return_value=48):
            result = runtime_paths.bounded_path(
                Path("parent") / ("x" * 100),
                suffix=".csv",
            )
        self.assertEqual(result.parent, Path("parent"))
        self.assertTrue(result.name.endswith(".csv"))
        self.assertLessEqual(len(result.name.encode("utf-8")), 48)

    def test_component_limit_caps_pathconf_and_falls_back(self):
        with mock.patch.object(runtime_paths.os, "pathconf", return_value=1024, create=True):
            self.assertEqual(runtime_paths.component_name_limit("."), 255)
        with mock.patch.object(runtime_paths.os, "pathconf", return_value=143, create=True):
            self.assertEqual(runtime_paths.component_name_limit("."), 143)
        with mock.patch.object(runtime_paths.os, "pathconf", side_effect=OSError, create=True):
            self.assertEqual(runtime_paths.component_name_limit("."), 255)

    def test_component_limit_uses_nearest_existing_ancestor(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            requested_parent = root / "not-created" / "nested"
            calls = []

            def fake_pathconf(path, key):
                calls.append(Path(path))
                if Path(path) == root:
                    return 143
                raise OSError("not found")

            with mock.patch.object(
                runtime_paths.os,
                "pathconf",
                side_effect=fake_pathconf,
                create=True,
            ):
                self.assertEqual(
                    runtime_paths.component_name_limit(requested_parent),
                    143,
                )

            self.assertEqual(calls[:3], [requested_parent, requested_parent.parent, root])

    def test_fixed_temp_prefix_is_short_and_destination_independent(self):
        self.assertEqual(runtime_paths.fixed_temp_prefix(), ".kdebug-write-")
        self.assertEqual(runtime_paths.fixed_temp_prefix("roll back"), ".kdebug-roll_back-")

    def test_derived_path_preserves_marker_when_base_is_already_at_limit(self):
        base = Path("b" * 59 + ".xlsx")
        with mock.patch.object(runtime_paths, "component_name_limit", return_value=64):
            result = runtime_paths.bounded_derived_path(
                base,
                "__subsys_",
                "top." + ("deep." * 30),
            )
            prefixes = runtime_paths.derived_glob_prefixes(base, "__subsys_")

        self.assertEqual(len(result.name.encode("utf-8")), 64)
        self.assertTrue(result.name.startswith(prefixes), result.name)
        self.assertIn("__subsys_", result.name)
        self.assertTrue(result.name.endswith(".xlsx"))

    def test_derived_discovery_prefix_isolated_for_shared_long_base_prefixes(self):
        shared = "result_" + ("shared_" * 20)
        first_base = Path(shared + "alpha.xlsx")
        second_base = Path(shared + "beta.xlsx")
        identity = "top." + ("deep." * 30)
        with mock.patch.object(runtime_paths, "component_name_limit", return_value=80):
            first = runtime_paths.bounded_derived_path(
                first_base, "__subsys_", identity
            )
            second = runtime_paths.bounded_derived_path(
                second_base, "__subsys_", identity
            )
            first_prefixes = runtime_paths.derived_glob_prefixes(
                first_base, "__subsys_"
            )
            second_prefixes = runtime_paths.derived_glob_prefixes(
                second_base, "__subsys_"
            )

        self.assertNotEqual(first, second)
        self.assertTrue(first.name.startswith(first_prefixes))
        self.assertTrue(second.name.startswith(second_prefixes))
        self.assertFalse(second.name.startswith(first_prefixes))
        self.assertFalse(first.name.startswith(second_prefixes))

    def test_cli_prints_only_path_to_stdout_and_reports_shortening(self):
        script = Path(runtime_paths.__file__).resolve()
        with tempfile.TemporaryDirectory() as tmpdir:
            original = Path(tmpdir) / ("instance_" * 40)
            proc = subprocess.run(
                [
                    sys.executable,
                    str(script),
                    "--path",
                    str(original),
                    "--suffix",
                    ".csv",
                    "--identity",
                    "full.instance.identity",
                ],
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                universal_newlines=True,
            )

        self.assertEqual(proc.returncode, 0, proc.stderr)
        actual = Path(proc.stdout.strip())
        self.assertEqual(proc.stdout, str(actual) + "\n")
        self.assertEqual(actual.parent, original.parent)
        self.assertTrue(actual.name.endswith(".csv"))
        self.assertLessEqual(len(actual.name.encode("utf-8")), 255)
        self.assertIn("[runtime_paths] original=", proc.stderr)
        self.assertIn("[runtime_paths] bounded=", proc.stderr)

    def test_cli_short_path_has_quiet_stderr(self):
        script = Path(runtime_paths.__file__).resolve()
        proc = subprocess.run(
            [sys.executable, str(script), "--path", "short", "--suffix", ".csv"],
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
        )
        self.assertEqual(proc.returncode, 0, proc.stderr)
        self.assertEqual(proc.stdout, str(Path("short.csv")) + "\n")
        self.assertEqual(proc.stderr, "")


class LongFilenameIntegrationTests(unittest.TestCase):
    def test_near_limit_subsystem_output_is_discoverable_and_cleaned(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / ("b" * 59 + ".xlsx")
            template = root / "template.xlsx"
            template.write_bytes(b"template")
            output.write_bytes(b"base")
            subsystem = "top." + ("deep." * 30)

            with mock.patch.object(runtime_paths, "component_name_limit", return_value=64):
                split = annotate_trace_xlsx.split_output_path(output, subsystem)
                split.write_bytes(b"split")
                resolved = trace_gui.resolve_subsystem_result_file(str(output))
                self.assertEqual(resolved, split)
                annotate_trace_xlsx.cleanup_subsystem_outputs(template, output)

            self.assertFalse(output.exists())
            self.assertFalse(split.exists())
            self.assertTrue(template.exists())

    def test_split_csv_bounds_long_instances_without_losing_identity(self):
        shared = "top." + ("shared_hierarchy." * 22)
        instances = [shared + "tail_alpha", shared + "tail_beta"]
        self.assertTrue(all(len(instance) > 300 for instance in instances))

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            source = root / "filtered.csv"
            with source.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.writer(handle)
                writer.writerow(["inst_full_name", "port_name", "role"])
                writer.writerow([instances[0], "a", "driver"])
                writer.writerow([instances[1], "b", "load"])

            with practical_component_limit(root) as limit:
                outputs = [Path(path) for path in filter_trace.split_csv_by_trace_instance(str(source))]

            self.assertEqual(len(outputs), 2)
            self.assertEqual(len({path.name for path in outputs}), 2)
            self.assertTrue(all(len(path.name.encode("utf-8")) <= limit for path in outputs))

            actual_instances = set()
            for output in outputs:
                with output.open("r", encoding="utf-8", newline="") as handle:
                    rows = list(csv.DictReader(handle))
                self.assertEqual(len(rows), 1)
                actual_instances.add(rows[0]["inst_full_name"])
            self.assertEqual(actual_instances, set(instances))

    def test_split_output_path_is_stable_bounded_and_collision_resistant(self):
        shared = "top." + ("subsystem_level." * 22)
        first_subsystem = shared + "tail_alpha"
        second_subsystem = shared + "tail_beta"
        self.assertTrue(len(first_subsystem) > 300)

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = root / "annotated.xlsx"
            with practical_component_limit(root) as limit:
                first = annotate_trace_xlsx.split_output_path(output, first_subsystem)
                first_again = annotate_trace_xlsx.split_output_path(output, first_subsystem)
                second = annotate_trace_xlsx.split_output_path(output, second_subsystem)

            self.assertEqual(first, first_again)
            self.assertNotEqual(first.name, second.name)
            self.assertEqual(first.suffix, ".xlsx")
            self.assertEqual(second.suffix, ".xlsx")
            self.assertLessEqual(len(first.name.encode("utf-8")), limit)
            self.assertLessEqual(len(second.name.encode("utf-8")), limit)

    @unittest.skipUnless(os.name == "posix", "real NAME_MAX atomic-write coverage requires POSIX")
    def test_atomic_write_csv_accepts_name_max_destination(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = name_max_path(root, "csv_", ".csv")

            kdebug_backend.atomic_write_csv(output, ["name", "value"], [["alpha", "1"]])

            with output.open("r", encoding="utf-8", newline="") as handle:
                self.assertEqual(list(csv.reader(handle)), [["name", "value"], ["alpha", "1"]])
            assert_no_temp_files(self, root, ".kdebug-csv-")

    @unittest.skipUnless(os.name == "posix", "real NAME_MAX atomic-write coverage requires POSIX")
    def test_atomic_write_csv_pair_accepts_name_max_destinations(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            first = name_max_path(root, "first_", ".csv")
            second = name_max_path(root, "second_", ".csv")
            first.write_text("old first\n", encoding="utf-8")
            second.write_text("old second\n", encoding="utf-8")

            kdebug_backend.atomic_write_csv_pair(
                first,
                ["surface", "value"],
                [["full", "1"]],
                second,
                ["surface", "value"],
                [["boundary", "2"]],
            )

            with first.open("r", encoding="utf-8", newline="") as handle:
                self.assertEqual(list(csv.reader(handle))[-1], ["full", "1"])
            with second.open("r", encoding="utf-8", newline="") as handle:
                self.assertEqual(list(csv.reader(handle))[-1], ["boundary", "2"])
            assert_no_temp_files(self, root, ".kdebug-csv-", ".kdebug-rollback-")

    @unittest.skipUnless(os.name == "posix", "real NAME_MAX atomic-write coverage requires POSIX")
    def test_atomic_write_lines_accepts_name_max_destination(self):
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = name_max_path(root, "instances_", ".txt")

            find_instances_batched.atomic_write_lines(output, ["top.u0", "top.u1"])

            self.assertEqual(output.read_text(encoding="utf-8"), "top.u0\ntop.u1\n")
            assert_no_temp_files(self, root, ".kdebug-instances-")

    @unittest.skipUnless(os.name == "posix", "real NAME_MAX atomic-write coverage requires POSIX")
    def test_atomic_save_workbook_accepts_name_max_destination(self):
        class Workbook:
            @staticmethod
            def save(path):
                Path(path).write_bytes(b"complete workbook")

        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            output = name_max_path(root, "workbook_", ".xlsx")

            annotate_trace_xlsx.atomic_save_workbook(Workbook(), output)

            self.assertEqual(output.read_bytes(), b"complete workbook")
            assert_no_temp_files(self, root, ".kdebug-xlsx-")

    def test_bundled_engine_socket_path_uses_encoded_home_length(self):
        engine_path = (
            Path(__file__).resolve().parent
            / "kdebug"
            / "libexec"
            / "tcl_engine"
            / "kdebug_engine.py"
        )
        spec = importlib.util.spec_from_file_location("bundled_kdebug_engine_long_path_test", engine_path)
        self.assertIsNotNone(spec)
        self.assertIsNotNone(spec.loader)
        engine = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(engine)

        home = "/tmp/" + ("\u6d4b" * 20)
        with mock.patch.dict(os.environ, {"HOME": home}):
            nominal = os.path.join(engine.session_dir("session_a"), "socket")
            self.assertLess(len(nominal), 104)
            self.assertGreaterEqual(len(os.fsencode(nominal)), 104)
            with mock.patch.object(engine.os, "getuid", return_value=12345, create=True):
                actual = engine.socket_path("session_a")

        self.assertTrue(actual.startswith("/tmp/kdebug-12345-"), actual)
        self.assertTrue(actual.endswith(".sock"), actual)
        self.assertLess(len(os.fsencode(actual)), 104)


if __name__ == "__main__":
    unittest.main()
