import tempfile
import unittest
from pathlib import Path

import openpyxl

from annotate_trace_xlsx import (
    ModuleTrace,
    ParamRow,
    TraceRow,
    create_minimal_template,
    select_subsystem_modules,
    write_annotation_results_workbook,
    write_annotation_workbook,
)


def inventory(module: str, instance: str) -> ParamRow:
    return ParamRow(
        module=module,
        inst_full_name=instance,
        param_name="",
        param_value="",
        param_kind="instance",
        param_info="INSTANCE_INVENTORY",
    )


class SparseSubsystemAnnotationTest(unittest.TestCase):
    modules = ["Only0", "Only1"]
    ports = ["p"]
    subsystem0 = "top.subsys0"
    subsystem1 = "top.subsys1"
    instance0 = "top.subsys0.u_only0"
    instance1 = "top.subsys1.u_only1"

    def setUp(self) -> None:
        self.params_by_subsystem = {
            "Only0": {self.subsystem0: [inventory("Only0", self.instance0)]},
            "Only1": {self.subsystem1: [inventory("Only1", self.instance1)]},
        }

    def test_selects_only_modules_present_in_subsystem(self) -> None:
        module_data = {
            "Only0": {self.subsystem0: object()},
            "Only1": {self.subsystem1: object()},
        }
        self.assertEqual(
            select_subsystem_modules(
                self.modules,
                self.subsystem0,
                module_data,
                self.params_by_subsystem,
                {},
            ),
            ["Only0"],
        )
        self.assertEqual(
            select_subsystem_modules(
                self.modules,
                self.subsystem1,
                module_data,
                self.params_by_subsystem,
                {},
            ),
            ["Only1"],
        )

    def test_stream_and_nonstream_writers_omit_absent_module(self) -> None:
        with tempfile.TemporaryDirectory() as tmpdir:
            root = Path(tmpdir)
            template = root / "template.xlsx"
            create_minimal_template(template, self.modules, self.ports, "Trace")

            stream_data = {
                "Only0": {
                    self.subsystem0: {self.instance0: {"p": "yes"}},
                },
                "Only1": {
                    self.subsystem1: {self.instance1: {"p": "yes"}},
                },
            }
            selected = select_subsystem_modules(
                self.modules,
                self.subsystem0,
                stream_data,
                self.params_by_subsystem,
                {},
            )
            stream_output = root / "stream.xlsx"
            write_annotation_results_workbook(
                template=template,
                sheet_name="Trace",
                output=stream_output,
                modules=selected,
                ports=self.ports,
                module_port_results={
                    module: stream_data[module][self.subsystem0]
                    for module in selected
                },
                module_params={
                    module: self.params_by_subsystem[module][self.subsystem0]
                    for module in selected
                },
                missing_marker="NO_TRACE",
            )
            self.assert_sparse_workbook(stream_output)

            trace_row = TraceRow(
                inst_full_name=self.instance0,
                port_name="p",
                port_dir="input",
                role="driver",
                signal_full_name="top.subsys0.u_key.out",
            )
            nonstream_data = {
                "Only0": {self.subsystem0: [trace_row]},
                "Only1": {
                    self.subsystem1: [
                        TraceRow(
                            inst_full_name=self.instance1,
                            port_name="p",
                            port_dir="input",
                            role="driver",
                            signal_full_name="top.subsys1.u_key.out",
                        )
                    ]
                },
            }
            selected = select_subsystem_modules(
                self.modules,
                self.subsystem0,
                nonstream_data,
                self.params_by_subsystem,
                {},
            )
            nonstream_output = root / "nonstream.xlsx"
            write_annotation_workbook(
                template=template,
                sheet_name="Trace",
                output=nonstream_output,
                modules=selected,
                ports=self.ports,
                module_traces={
                    module: ModuleTrace(nonstream_data[module][self.subsystem0])
                    for module in selected
                },
                module_params={
                    module: self.params_by_subsystem[module][self.subsystem0]
                    for module in selected
                },
                filter_instances=["top.subsys0.u_key"],
                missing_marker="NO_TRACE",
            )
            self.assert_sparse_workbook(nonstream_output)

    def assert_sparse_workbook(self, path: Path) -> None:
        workbook = openpyxl.load_workbook(path, data_only=False)
        sheet = workbook["Trace"]
        headers = [cell.value for cell in sheet[1]]
        rows = [
            dict(zip(headers, values))
            for values in sheet.iter_rows(min_row=2, values_only=True)
        ]
        self.assertEqual(len(rows), 1)
        self.assertEqual(rows[0]["module"], "Only0")
        self.assertEqual(rows[0]["instance"], self.instance0)
        self.assertEqual(rows[0]["parameters"], "NO_PARAMETER")
        self.assertNotIn("NO_SUBSYSTEM_INSTANCE", " ".join(map(str, rows[0].values())))


if __name__ == "__main__":
    unittest.main()
