import tempfile
import unittest
from pathlib import Path

from trace_gui import TraceGui, resolve_subsystem_result_file


class FakeVar:
    def __init__(self, value: str) -> None:
        self.value = value

    def get(self) -> str:
        return self.value


def make_headless_gui(**values: str) -> TraceGui:
    gui = TraceGui.__new__(TraceGui)
    gui.vars = {key: FakeVar(value) for key, value in values.items()}
    return gui


class TraceGuiResultResolutionTest(unittest.TestCase):
    def test_subsystem_xlsx_ignores_existing_base_workbook(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            base = root / "result.xlsx"
            split_b = root / "result__subsys_top.b.xlsx"
            split_a = root / "result__subsys_top.a.xlsx"
            base.touch()
            split_b.touch()
            split_a.touch()

            gui = make_headless_gui(
                mode="xlsx",
                xlsx_output=str(base),
                subsystem_level="2",
            )

            self.assertEqual(resolve_subsystem_result_file(str(base)), split_a)
            self.assertEqual(gui._current_result_path(), str(split_a))
            self.assertNotEqual(gui._current_result_path(), str(base))

    def test_subsystem_xlsx_never_falls_back_to_existing_base(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            base = Path(tmpdir) / "result.xlsx"
            base.touch()
            gui = make_headless_gui(
                mode="xlsx",
                xlsx_output=str(base),
                subsystem_level="1",
            )

            self.assertIsNone(resolve_subsystem_result_file(str(base)))
            self.assertEqual(gui._current_result_path(), "")

    def test_nonsplit_xlsx_and_csv_keep_base_file_behavior(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            xlsx_base = root / "result.xlsx"
            xlsx_split = root / "result__subsys_top.a.xlsx"
            csv_base = root / "result.csv"
            csv_split = root / "result__instance.csv"
            for path in (xlsx_base, xlsx_split, csv_base, csv_split):
                path.touch()

            xlsx_gui = make_headless_gui(
                mode="xlsx",
                xlsx_output=str(xlsx_base),
                subsystem_level="0",
            )
            csv_gui = make_headless_gui(mode="csv", csv_output=str(csv_base))

            self.assertEqual(xlsx_gui._current_result_path(), str(xlsx_base))
            self.assertEqual(csv_gui._current_result_path(), str(csv_base))

            csv_base.unlink()
            self.assertEqual(csv_gui._current_result_path(), str(csv_split))

    def test_raw_result_behavior_is_unchanged(self) -> None:
        full = "full.csv"
        module = "module.csv"
        gui = make_headless_gui(
            mode="raw",
            raw_full_output=full,
            raw_module_output=module,
        )
        self.assertEqual(gui._current_result_path(), full)

        gui = make_headless_gui(
            mode="raw",
            raw_full_output="",
            raw_module_output=module,
        )
        self.assertEqual(gui._current_result_path(), module)


if __name__ == "__main__":
    unittest.main()
