#!/usr/bin/env python3
"""Check invalid query failures, supported signed indices, NPI limitations and large parameter transport."""
import argparse
import csv
import json
import os
import re
from pathlib import Path
from types import SimpleNamespace

from driver_semantics import trace, read_groups
from annotate_trace_xlsx import find_module_parameters, PortSummary, TraceRow
from trace_identity import InstanceMatcher
from trace_identity import scalar_constant_value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--kdb', required=True, type=Path)
    parser.add_argument('--lanes', type=int, default=8)
    args = parser.parse_args()
    case = args.out.resolve()
    case.mkdir(parents=True, exist_ok=False)
    results = {}
    for name, module, ports, marker in [
        ('missing', 'SemProbe', 'a,missing_port', 'ERROR:PORT_NOT_FOUND'),
        ('out_of_range', 'SemWide', 'a[08]', 'ERROR:PORT_SELECT_INVALID'),
    ]:
        metrics = trace(case, args.kdb, name, module, ports)
        assert metrics['rc'] != 0, name+' was silently accepted'
        assert marker in (case/(name+'.log')).read_text()
        assert not (case/(name+'.boundary.csv')).exists(), 'failed result was published'
        results[name] = dict(metrics, status='PASS', diagnostic=marker)
    for name, module, ports, expected in [
        ('negative', 'SemNegative', 'a[-4],a[-1]', {'a[-4]': '0', 'a[-1]': '1'}),
        ('packed', 'SemPacked', 'a[0][1],a[1][1]', {'a[0][1]': '1', 'a[1][1]': '1'}),
    ]:
        metrics = trace(case, args.kdb, name, module, ports)
        assert metrics['rc'] == 0
        rows, groups = read_groups(case, name)
        queries = [(key, values) for key, values in groups.items() if key[2] == 'driver']
        assert len(queries) == args.lanes*len(expected)
        for key, values in queries:
            assert {scalar_constant_value(x) for x in values} == {expected[key[1]]}, (key, values)
        if name == 'packed':
            # Both directions must now succeed. Retained and newly compiled
            # KDBs label the same reduction input XorRedu.a / Combo.I0;
            # preserve exact owner and MSB-first flattened bit validation.
            load_queries = [(key, values) for key, values in groups.items() if key[2] == 'load']
            assert len(load_queries) == len(queries)
            for key, values in load_queries:
                index = {'a[0][1]': 2, 'a[1][1]': 0}[key[1]]
                assert len(values) == 1, (key, values)
                value = next(iter(values))
                assert value.startswith(key[0]+'.') and re.search(
                    r'/(?:XorRedu\.a|Combo\.I0)\['+str(index)+r'\]$', value), (key, values)
            assert not any(row['signal_full_name'].startswith(('TRACE_INCOMPLETE:', 'ERROR:', 'TRACE_LIMIT_REACHED:')) for row in rows)
        results[name] = dict(metrics, status='PASS', driver_queries=len(queries),
                             loader_status='COMPLETE')
    metrics = trace(case, args.kdb, 'packed_subvector', 'SemPacked', 'a[0]')
    assert metrics['rc'] == 0
    rows, groups = read_groups(case, 'packed_subvector')
    driver_groups = {key: values for key, values in groups.items() if key[2] == 'driver'}
    assert len(driver_groups) == args.lanes
    for key, values in driver_groups.items():
        assert values == {"Const:1'b0", "Const:1'b1"}, (key, values)
        summary = PortSummary()
        for value in values:
            summary.observe_row(TraceRow(key[0], key[1], 'input', 'driver', value), InstanceMatcher([]))
        assert not summary.result().startswith('error;'), summary.result()
    results['packed_subvector'] = dict(metrics, status='PASS', driver_queries=len(driver_groups),
                                      invariant='two-bit packed selection is not a scalar conflict')
    # The adapter's union-column contract must preserve each absent selected
    # bit, while keeping known valid columns. The strict negatives above use
    # the same queries without opting in and must still fail.
    absent = case/'union_absent_ports.csv'
    absent.write_text('inst_full_name,port_name\n')
    prior = os.environ.get('NPI_ABSENT_PORTS_FILE')
    try:
        os.environ['NPI_ABSENT_PORTS_FILE'] = str(absent)
        metrics = trace(case, args.kdb, 'union', 'SemWide', 'a[7],a[8],missing[0],missing[7]')
    finally:
        if prior is None: os.environ.pop('NPI_ABSENT_PORTS_FILE', None)
        else: os.environ['NPI_ABSENT_PORTS_FILE'] = prior
    assert metrics['rc'] == 0
    rows, groups = read_groups(case, 'union')
    assert not any(row['signal_full_name'].startswith(('ERROR:', 'TRACE_INCOMPLETE:', 'TRACE_LIMIT_REACHED:')) for row in rows)
    instances = {key[0] for key in groups}
    assert len(instances) == 7*args.lanes
    assert {key[1] for key in groups} == {'a[7]'}
    with absent.open(newline='') as stream: absent_rows = list(csv.DictReader(stream))
    absent_keys = {(row['inst_full_name'], row['port_name']) for row in absent_rows}
    assert len(absent_rows) == len(absent_keys)
    assert absent_keys == {(instance, port) for instance in instances for port in ('a[8]', 'missing[0]', 'missing[7]')}
    results['union_columns'] = dict(metrics, status='PASS', valid_queries=len(instances), absent_queries=len(absent_keys))
    modules = ['NoSuchLongParameterModule_{:05d}'.format(i) for i in range(10000)] + ['SemLane']
    param_args = SimpleNamespace(no_params=False, lib=str(args.kdb), verdi_timeout_sec=180, strict_params=True)
    rows, output, error = find_module_parameters(param_args, modules, case)
    assert error is None
    assert len([row for row in rows if row.param_name == 'ID']) == args.lanes
    results['parameters'] = {'status': 'PASS', 'modules': len(modules),
                             'list_bytes': (case/'parameter_modules.list').stat().st_size,
                             'parameter_ID_rows': args.lanes,
                             'completion': (case/'module_parameters.status').read_text().strip()}
    (case/'summary.json').write_text(json.dumps(results, indent=2)+'\n')
    print('PASS diagnostics and parameter file transport', flush=True)


if __name__ == '__main__':
    main()
