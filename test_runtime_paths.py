import tempfile
import csv
import io
import unittest
from pathlib import Path

from runtime_paths import bounded_component, bounded_derived_path, derived_glob_prefixes, fixed_temp_prefix, configure_csv_field_limit


class RuntimePathTests(unittest.TestCase):
    def test_partial_merge_does_not_replace_previous_output(self):
        from filter_trace import merge_csvs
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            output, first, second = (root/name for name in ('out.csv', 'one.csv', 'two.csv'))
            output.write_text('previous good output\n')
            first.write_text('a,b\n1,2\n')
            second.write_text('wrong,header\n3,4\n')
            with self.assertRaises(ValueError):
                merge_csvs(str(output), [str(first), str(second)])
            self.assertEqual(output.read_text(), 'previous good output\n')
            self.assertEqual(list(root.glob('.trace-*.tmp')), [])

    def test_csv_field_larger_than_default_limit(self):
        configure_csv_field_limit()
        value = "a" * (2 * 1024 * 1024)
        self.assertEqual(next(csv.reader(io.StringIO(value + "\n"))), [value])

    def test_short_safe_names_remain_compatible(self):
        self.assertEqual(bounded_component("report.csv", ".csv"), "report.csv")
        self.assertEqual(bounded_derived_path(Path("report.csv"), "__", "Top.key").name, "report__Top.key.csv")

    def test_long_unicode_names_and_suffixes_are_bounded(self):
        for text in ["a" * 10000, "层次" * 5000]:
            name = bounded_component(text, ".xlsx")
            self.assertLessEqual(len(name.encode("utf-8")), 255)
            self.assertTrue(name.endswith(".xlsx"))
            self.assertEqual(name, bounded_component(text, ".xlsx"))

    def test_lossy_identities_never_share_a_file(self):
        base = Path("report.csv")
        identities = ["Top.gen[0].u", "Top.gen_0_.u", "Top.gen/0.u", "Top.gen:0.u"]
        paths = [bounded_derived_path(base, "__", identity) for identity in identities]
        self.assertEqual(len(set(paths)), len(identities))
        for path in paths:
            self.assertTrue(path.name.startswith(derived_glob_prefixes(base, "__")))

    def test_long_base_identity_and_actual_files(self):
        with tempfile.TemporaryDirectory() as root:
            base = Path(root) / (("base" * 60) + ".csv")
            paths = [bounded_derived_path(base, "__", ("Top.wrap." * 1000) + str(i)) for i in range(4)]
            for path in paths:
                path.touch()
                self.assertLessEqual(len(path.name.encode()), 255)
                self.assertTrue(path.name.startswith(derived_glob_prefixes(base, "__")))
            self.assertEqual(len(list(Path(root).iterdir())), 4)
            self.assertLess(len(fixed_temp_prefix("purpose")), 64)


if __name__ == "__main__":
    unittest.main()
