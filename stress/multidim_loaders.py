#!/usr/bin/env python3
"""Build real multidimensional RTL; check exact terminal sets, not just exit codes.

The independently simulated oracle walks every stimulus bit. Expected load sets
come from the generated wiring specification, never from NPI trace results.
"""
import argparse
import csv
import hashlib
import json
from pathlib import Path
import re
import sys

from driver_semantics import REPO, read_groups, run, trace
from annotate_trace_xlsx import PortSummary, TraceRow
from trace_identity import InstanceMatcher

SHAPES = {
    'D2': ((1, 0), (3, 0)),
    'A2': ((0, 1), (0, 3)),
    'Mixed': ((-1, -2), (2, 4)),
    'D3': ((2, 1), (0, 1), (5, 3)),
    'Singleton': ((7, 7), (-2, -2), (0, 2)),
    'Unpacked': ((1, 0), (3, 0)),
    'MixedArray': ((-1, -2), (1, 0), (0, 2)),
    'Unpacked2': ((1, 0), (0, 2), (2, 0)),
    'UnpackedBits': ((2, 0), (-1, -2)),
}
UNPACKED_DIMS = {'Unpacked': 1, 'MixedArray': 1, 'Unpacked2': 2, 'UnpackedBits': 2}


def declaration(kind, name):
    shape = SHAPES[kind]
    split = UNPACKED_DIMS.get(kind, 0)
    return '{} {} {}'.format(''.join('[{}:{}]'.format(*r) for r in shape[split:]), name,
                            ''.join('[{}:{}]'.format(*r) for r in shape[:split]))


def connection(kind, name):
    if kind in UNPACKED_DIMS:
        return name
    # The module's high-side expression is a concat of sub-vectors, not a
    # single declared net. Covers both input RHS and output LHS projection.
    left, right = SHAPES[kind][0]
    step = 1 if right >= left else -1
    return '{' + ','.join(name+'[{}]'.format(i) for i in range(left, right+step, step)) + '}'


def coordinates(shape):
    # Cartesian declaration order (MSB first), deliberately independent of
    # the Tcl offset/range arithmetic. Reverse once for stimulus bit order.
    values = ['']
    for left, right in shape:
        step = 1 if right >= left else -1
        values = [prefix + '[{}]'.format(i) for prefix in values
                  for i in range(left, right + step, step)]
    return list(reversed(values))


def queries(shape):
    bits = coordinates(shape)
    outer = '[{}]'.format(shape[0][1])
    result = {'': list(range(len(bits))), outer: [i for i, bit in enumerate(bits) if bit.startswith(outer)]}
    result.update({bit: [i] for i, bit in enumerate(bits)})
    # A genuine multidimensional part-select (not only a partial sub-vector).
    if len(shape) == 2:
        lo, hi = sorted(shape[1])
        if hi > lo:
            part = outer + '[{}:{}]'.format(lo, lo + 1)
            if shape[1][0] > shape[1][1]:
                part = outer + '[{}:{}]'.format(lo + 1, lo)
            result[part] = [i for i, bit in enumerate(bits)
                            if bit in {outer+'[{}]'.format(lo), outer+'[{}]'.format(lo+1)}]
    return result


def generate(lanes):
    lines = ['module MDLeaf(input i); wire observe=i; endmodule']
    cases = []
    assertions = []
    for kind, shape in SHAPES.items():
        bits = coordinates(shape)
        width = len(bits)
        # q[k] = a[(k+3) mod width], a nontrivial permutation for most shapes.
        perm = [(k + 3) % width for k in range(width)]
        lines.append('module MDPass_{0}(input {1}, output {2});'.format(kind, declaration(kind, 'a'), declaration(kind, 'q')))
        if kind in UNPACKED_DIMS:
            lines += ['assign q{} = a{};'.format(bits[k], bits[perm[k]]) for k in range(width)]
        else:
            lines.append('assign q = {' + ','.join('a'+bits[perm[k]] for k in reversed(range(width))) + '};')
        lines.append('endmodule')
        lines.append('module MDTarget_{0}(input {1}, output {2});'.format(kind, declaration(kind, 'a'), declaration(kind, 'q')))
        lines.append('MDPass_{} pass(.a(a), .q(q));'.format(kind))
        for j, bit in enumerate(bits):
            lines.append('MDLeaf named_{0}(.i(a{1})); MDLeaf positional_{0}(a{1});'.format(j, bit))
        lines += ['wire reduction=^{' + ','.join('a'+bit for bit in bits) + '};', 'endmodule']
        cases.append('wire {}; wire {};'.format(declaration(kind, 'in_'+kind), declaration(kind, 'out_'+kind)))
        cases += ['assign in_{}{} = stim[{}];'.format(kind, bit, j) for j, bit in enumerate(bits)]
        cases.append('MDTarget_{0} t_{0}(.a({1}), .q({2}));'.format(kind, connection(kind, 'in_'+kind), connection(kind, 'out_'+kind)))
        for k, bit in enumerate(bits):
            cases.append('MDLeaf out_{0}_{1}(.i(out_{0}{2}));'.format(kind, k, bit))
            assertions.append('if (out_{0}_{1}.i !== stim[{2}]) $fatal(1,"output {0} bit {1}");'.format(kind, k, perm[k]))
        for j, bit in enumerate(bits):
            for role in ('named', 'positional'):
                assertions.append('if (t_{0}.{1}_{2}.i !== stim[{2}]) $fatal(1,"input {0} bit {2}");'.format(kind, role, j))
    lines += ['module MDLane(input [31:0] stim);'] + cases
    lines += ['always @(stim) begin #1;'] + assertions + ['end', 'endmodule']
    lines += ['module MDTop;', 'reg [31:0] stim=0;',
              'for(genvar i=0;i<{};i=i+1) begin:g MDLane lane(.stim(stim)); end'.format(lanes),
              'initial begin #3; for(integer k=0;k<32;k=k+1) begin stim=32\'b1<<k; #3; end',
              '$display("MULTIDIM_ORACLE_PASS"); $finish; end', 'endmodule']
    return '\n'.join(lines)+'\n'


def validate(case, name, kind, lanes):
    rows, groups = read_groups(case, name)
    errors = [{'diagnostic': row} for row in rows if row['signal_full_name'].startswith(
        ('ERROR:', 'TRACE_INCOMPLETE:', 'TRACE_LIMIT_REACHED:'))]
    shape = SHAPES[kind]
    bits = coordinates(shape)
    width = len(bits)
    checked = 0
    for lane in range(lanes):
        parent = 'MDTop.g[{}].lane'.format(lane)
        target = parent+'.t_'+kind
        for select, offsets in queries(shape).items():
            for role in ('a', 'q'):
                port = role+select
                values = groups.get((target, port, 'load'), set())
                actual = {v for v in values if re.search(r'\.(?:named_\d+|positional_\d+|out_\w+_\d+)\.i$', v)}
                if role == 'a':
                    expected = {target+'.'+r+'_{}.i'.format(j) for r in ('named', 'positional') for j in offsets}
                    expected |= {parent+'.out_{}_{}.i'.format(kind, k) for k in range(width) if (k+3)%width in offsets}
                else:
                    expected = {parent+'.out_{}_{}.i'.format(kind, k) for k in offsets}
                if actual != expected:
                    errors.append({'query': target+'.'+port, 'missing': sorted(expected-actual), 'extra': sorted(actual-expected)})
                # Input driver is dynamic; no operand/literal may become a tie.
                drivers = groups.get((target, port, 'driver'), set())
                if not drivers or any(v.startswith('Const:') for v in drivers):
                    errors.append({'driver': target+'.'+port, 'actual': sorted(drivers)})
                expected_driver_bits = set(offsets if role == 'a' else [(k+3)%width for k in offsets])
                driver_bits = {int(m.group(1)) for v in drivers for m in [re.search(r'/Init\.O0\[(\d+)\]$', v)] if m}
                if driver_bits != expected_driver_bits:
                    errors.append({'driver_bit_mapping': target+'.'+port, 'expected': sorted(expected_driver_bits),
                                   'actual': sorted(driver_bits)})
                checked += 1
                if role == 'q' and len(offsets) == 1:
                    true_match = parent+'.out_{}_{}'.format(kind, offsets[0])
                    false_match = parent+'.out_{}_{}'.format(kind, (offsets[0]+1)%width)
                    for keyword, expected_yes in ((true_match, True), (false_match, False)):
                        summary = PortSummary()
                        matcher = InstanceMatcher([keyword])
                        for value in values:
                            summary.observe_row(TraceRow(target, port, 'output', 'load', value), matcher)
                        if summary.result().startswith('yes') != expected_yes or summary.diagnostics:
                            errors.append({'annotation': target+'.'+port, 'keyword': keyword, 'result': summary.result()})
                        checked += 1
    expected_groups = lanes * len(queries(shape)) * 4
    if len(groups) != expected_groups:
        errors.append({'expected_groups': expected_groups, 'actual_groups': len(groups)})
    boundary = []
    if (case/(name+'.boundary.csv')).exists():
        with (case/(name+'.boundary.csv')).open(newline='') as stream:
            boundary = list(csv.DictReader(stream))
        for row in boundary:
            row['signal_full_name'] = row.get('signal_full_name', row.get('module_signal_full_name', ''))
    else:
        errors.append({'boundary_missing': True})
    terminals = lambda values: {(r['inst_full_name'], r['port_name'], r['role'], r['signal_full_name']) for r in values
                               if r['role'] == 'load' and re.search(r'\.(?:named_\d+|positional_\d+|out_\w+_\d+)\.i$', r['signal_full_name'])}
    if terminals(rows) != terminals(boundary):
        errors.append({'boundary_terminals_differ': True})
    result = {'status': 'PASS' if not errors else 'FAIL', 'checks': checked,
              'rows': len(rows), 'errors': errors}
    (case/(name+'.validation.json')).write_text(json.dumps(result, indent=2)+'\n')
    return result


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--out', type=Path, required=True)
    p.add_argument('--lanes', type=int, default=8)
    p.add_argument('--modes', nargs='+', default=['visible', 'hidden', 'stale'])
    p.add_argument('--kinds', nargs='+', choices=list(SHAPES), default=list(SHAPES))
    args = p.parse_args()
    case = args.out.resolve()
    case.mkdir(parents=True, exist_ok=False)
    source = case/'multidim.sv'
    original = generate(args.lanes)
    source.write_text(original)
    build = case/'build'
    build.mkdir()
    assert run(case, 'compile', ['vcs', '-full64', '-sverilog', '-lca', '-kdb', '-top', 'MDTop',
                               source, '-Mdir='+str(build/'csrc'), '-o', build/'simv'])['rc'] == 0
    assert run(case, 'oracle', [build/'simv'])['rc'] == 0
    assert 'MULTIDIM_ORACLE_PASS' in (case/'oracle.stdout').read_text()
    kdb = build/'simv.daidir/kdb.elab++'
    summary = {'lanes': args.lanes, 'cases': {}, 'tool_sha256': {
        p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
        [REPO/'npi_port_trace.tcl', REPO/'npi_elaborated.tcl', REPO/'trace_support.tcl', REPO/'annotate_trace_xlsx.py']}}
    try:
        for mode in args.modes:
            if mode == 'hidden':
                source.rename(case/'multidim.hidden')
            else:
                if (case/'multidim.hidden').exists():
                    (case/'multidim.hidden').rename(source)
                if mode == 'stale':
                    modified = original
                    for shape in SHAPES.values():
                        a, b = coordinates(shape)[:2]
                        modified = modified.replace('named_0(.i(a'+a+'))', 'named_0(.i(a'+b+'))')
                    assert modified != original
                    source.write_text(modified)
            for kind in args.kinds:
                shape = SHAPES[kind]
                name = mode+'_'+kind
                ports = ','.join(role+select for role in ('a', 'q') for select in queries(shape))
                metrics = trace(case, kdb, name, 'MDTarget_'+kind, ports)
                result = validate(case, name, kind, args.lanes)
                summary['cases'][name] = dict(metrics, **result)
                (case/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    finally:
        if (case/'multidim.hidden').exists():
            (case/'multidim.hidden').rename(source)
        source.write_text(original)
    failures = [key for key, result in summary['cases'].items() if result['status'] != 'PASS' or result['rc']]
    if failures:
        sys.exit('FAIL: '+', '.join(failures))
    print('PASS multidim lanes={} checks={}'.format(args.lanes, sum(x['checks'] for x in summary['cases'].values())))


if __name__ == '__main__':
    main()
