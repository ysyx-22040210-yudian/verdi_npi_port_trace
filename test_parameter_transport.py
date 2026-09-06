import os
from pathlib import Path
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch

import annotate_trace_xlsx as annotate


class ParameterTransportTests(unittest.TestCase):
    def test_xlsx_union_mode_is_explicit_and_does_not_leak_to_strict_trace(self):
        args = SimpleNamespace(lib='/kdb', const_source_fallback=1, const_trace_depth=8,
                               assign_trace_depth=8, assign_expr_trace_depth=4,
                               load_trace_node_limit=1000, load_trace_edge_limit=5000,
                               load_trace_api_list_limit=1000, verdi_timeout_sec=90, trace_debug=0)
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            for union in (True, False):
                def fake_run(command, **kwargs):
                    self.assertEqual('NPI_ABSENT_PORTS_FILE' in kwargs['env'], union)
                    Path(kwargs['stdout_path']).write_text('full header\n')
                    Path(command[command.index('-module-out')+1]).write_text('boundary header\n')
                with patch.dict(os.environ, {'NPI_ABSENT_PORTS_FILE': '/unrelated/stale.csv'}), patch.object(annotate, 'run_checked', side_effect=fake_run):
                    annotate.trace_module(args, 'Target', ['a', 'not_on_this_module'], root, allow_absent_ports=union)

    def test_large_module_inventory_uses_file_and_completion(self):
        modules = ['VeryLongModuleName_{}'.format(i) for i in range(10000)]
        args = SimpleNamespace(no_params=False, lib='/kdb', verdi_timeout_sec=10, strict_params=True)
        with tempfile.TemporaryDirectory() as directory:
            def fake_run(command, **kwargs):
                env = kwargs['env']
                self.assertNotIn('NPI_PARAM_MODULES', env)
                self.assertEqual(Path(env['NPI_PARAM_MODULES_FILE']).read_text().splitlines(), modules)
                Path(env['NPI_PARAM_OUTFILE']).write_text('module,inst_full_name,param_name,param_value,param_kind,param_info\n')
                Path(env['NPI_PARAM_STATUS_FILE']).write_text('COMPLETE 10000 0 0\n')

            with patch.dict(os.environ, {'NPI_PARAM_MODULES': 'STALE_REQUEST'}), patch.object(annotate, 'run_checked', side_effect=fake_run):
                rows, output, error = annotate.find_module_parameters(args, modules, Path(directory))
            self.assertEqual(rows, [])
            self.assertIsNone(error)

    def test_header_without_completion_is_not_success(self):
        args = SimpleNamespace(no_params=False, lib='/kdb', verdi_timeout_sec=10, strict_params=False)
        with tempfile.TemporaryDirectory() as directory:
            def fake_run(command, **kwargs):
                Path(kwargs['env']['NPI_PARAM_OUTFILE']).write_text('module,inst_full_name,param_name,param_value,param_kind,param_info\n')
            with patch.object(annotate, 'run_checked', side_effect=fake_run):
                rows, output, error = annotate.find_module_parameters(args, ['Target'], Path(directory))
            self.assertIn('did not confirm complete collection', error)
            self.assertFalse(output.exists())


if __name__ == '__main__':
    unittest.main()
