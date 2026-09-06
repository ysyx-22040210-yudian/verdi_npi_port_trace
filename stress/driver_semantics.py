#!/usr/bin/env python3
"""VM regression for scalar ties, expression boundaries and width conversion.

Builds new RTL/KDB and runs a VCS simulation oracle, then checks source-visible,
source-hidden and stale-source traces from the same KDB. No existing project
source or KDB is changed. Run serially on the EDA VM.
"""
import argparse
import csv
import hashlib
import json
import os
from pathlib import Path
import re
import subprocess
import sys
import time

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))
from annotate_trace_xlsx import PortSummary, TraceRow
from trace_identity import InstanceMatcher, scalar_constant_value

RTL = r"""
module SemProbe(input a); wire sink = a; endmodule
module SemWide(input [7:0] a); wire sink = ^a; endmodule
module SemPacked(input [1:0][1:0] a); wire sink = ^a; endmodule
module SemNegative(input [-1:-4] a); wire sink = ^a; endmodule
module SemProducer(output [1:0] q); assign q=2'b10; endmodule
module SemLane #(parameter integer ID=0)(input sel);
  wire [1:0] bus=2'b10;
  wire a=1'b1;
  wire mux=sel ? 1'b1 : 1'b0;
  wire [1:0] emit;
  SemProbe named0(.a(bus[0]));
  SemProbe named1(.a(bus[1]));
  SemProbe positional0(bus[0]);
  SemProbe positional1(bus[1]);
  SemProbe truncate({1'b1,1'b0});
  SemProbe nested_concat(.a({{2{1'b1}},{1'b1,1'b0}}));
  SemProbe parameter_tie(.a(ID%2));
  SemProbe implicit(.a);
  SemProbe wildcard_inst(.*);
  SemProbe direct_mux(.a(sel ? 1'b1 : 1'b0));
  SemProbe assigned_mux(.a(mux));
  SemProbe bit_and(.a(sel & 1'b1));
  SemProducer producer(.q(emit));
  SemProbe load_named(.a(emit[0]));
  SemProbe load_pos(emit[0]);
  SemWide signed_ext(.a(2'sb10));
  SemWide unsigned_ext(.a(2'b10));
  SemWide decimal08(.a(8'd08));
  SemWide decimal09(.a(8'd09));
  SemWide fill_one(.a('1));
  SemWide fill_zero(.a('0));
  SemWide repeat_one(.a({4{2'b10}}));
  SemPacked packed_conn(.a(4'b1010));
  SemNegative negative_conn(.a(4'b1010));
  initial begin
    #1;
    if (truncate.a !== 1'b0 || nested_concat.a !== 1'b0 ||
        signed_ext.a !== 8'hfe || unsigned_ext.a !== 8'h02 ||
        decimal08.a !== 8'd8 || decimal09.a !== 8'd9 ||
        fill_one.a !== 8'hff || fill_zero.a !== 8'h00 ||
        parameter_tie.a !== (ID%2) || packed_conn.a[0][1] !== 1'b1 ||
        negative_conn.a[-4] !== 1'b0) $fatal(1,"SEMANTICS_ORACLE_FAILED lane=%0d",ID);
  end
endmodule
module SemTop;
  reg sel=0;
  for (genvar i=0; i<LANES; i=i+1) begin:g
    SemLane #(.ID(i)) lane(.sel(sel));
  end
  initial begin #2; sel=1; #2; $display("SEMANTICS_ORACLE_PASS lanes=LANES"); $finish; end
endmodule
"""


def run(case, name, command, timeout=300):
    started = time.monotonic()
    with (case / (name + '.stdout')).open('w') as stdout, (case / (name + '.log')).open('w') as stderr:
        result = subprocess.run([str(x) for x in command], cwd=str(case), stdout=stdout,
                                stderr=stderr, timeout=timeout)
    metrics = {'rc': result.returncode, 'seconds': round(time.monotonic()-started, 3)}
    print(name, metrics, flush=True)
    return metrics


def trace(case, kdb, name, module, ports):
    return run(case, name, ['bash', REPO / 'npi_trace.sh', '-lib', kdb, '-module', module,
                '-ports', ports, '-module-out', case / (name + '.boundary.csv'),
                '-assign-trace-depth', '12', '-assign-expr-trace-depth', '4',
                '-load-trace-node-limit', '100000', '-load-trace-edge-limit', '500000',
                '-verdi-timeout-sec', '300', '-trace-debug', '0'], 340)


def read_groups(case, name):
    with (case / (name + '.stdout')).open(newline='') as stream:
        rows = list(csv.DictReader(stream))
    groups = {}
    for row in rows:
        groups.setdefault((row['inst_full_name'], row['port_name'], row['role']), set()).add(row['signal_full_name'])
    return rows, groups


def validate(case, name, lanes, kind):
    rows, groups = read_groups(case, name)
    errors = [{'unexpected_diagnostic': row} for row in rows
              if row['signal_full_name'].startswith(('ERROR:', 'TRACE_INCOMPLETE:', 'TRACE_LIMIT_REACHED:'))]
    checked = 0
    for lane in range(lanes):
        prefix = 'SemTop.g[{}].lane.'.format(lane)
        if kind == 'scalar':
            expected = {'named0': 0, 'named1': 1, 'positional0': 0, 'positional1': 1,
                        'truncate': 0, 'nested_concat': 0, 'implicit': 1, 'wildcard_inst': 1,
                        'load_named': 0, 'load_pos': 0}
            for child, value in expected.items():
                actual = groups.get((prefix+child, 'a', 'driver'), set())
                constants = {scalar_constant_value(x) for x in actual if x.startswith('Const:')}
                if constants != {str(value)} or any(x.startswith(('ERROR:', 'TRACE_INCOMPLETE:')) for x in actual):
                    errors.append({'query': prefix+child+'.a', 'expected': value, 'actual': sorted(actual)})
                checked += 1
            for child in ('direct_mux', 'assigned_mux', 'bit_and', 'parameter_tie'):
                actual = groups.get((prefix+child, 'a', 'driver'), set())
                # parameter_tie may be elaborated as a constant or a constant
                # arithmetic operation; neither may falsely tie to the wrong bit.
                if child == 'parameter_tie':
                    valid = actual and all(not x.startswith('Const:') or scalar_constant_value(x) == str(lane%2) for x in actual)
                else:
                    valid = actual and not any(x.startswith('Const:') for x in actual)
                if not valid:
                    errors.append({'query': prefix+child+'.a', 'actual': sorted(actual)})
                checked += 1
        elif kind == 'wide':
            expected = {'signed_ext': 254, 'unsigned_ext': 2, 'decimal08': 8, 'decimal09': 9,
                        'fill_one': 255, 'fill_zero': 0, 'repeat_one': 170}
            for child, value in expected.items():
                for bit in (0, 1, 3, 7):
                    actual = groups.get((prefix+child, 'a[{}]'.format(bit), 'driver'), set())
                    constants = {scalar_constant_value(x) for x in actual if x.startswith('Const:')}
                    if constants != {str((value >> bit) & 1)}:
                        errors.append({'query': prefix+child+'.a[{}]'.format(bit), 'expected': (value>>bit)&1, 'actual': sorted(actual)})
                    checked += 1
        elif kind == 'loader':
            actual = groups.get((prefix+'producer', 'q[0]', 'load'), set())
            for child in ('load_named', 'load_pos'):
                if not any(x in {prefix+child+'.a', prefix+child+'.a[0]'} for x in actual):
                    errors.append({'query': prefix+'producer.q[0]', 'missing': child, 'actual': sorted(actual)})
                checked += 1
    # Also exercise the actual annotation aggregation, including scalar names
    # with no [0] suffix and dynamic expressions mixed with constants.
    summaries = {}
    for row in rows:
        key = row['inst_full_name'], row['port_name']
        summaries.setdefault(key, PortSummary()).observe_row(TraceRow(**row), InstanceMatcher([]))
    for key, summary in summaries.items():
        if key[0].endswith(('.direct_mux', '.bit_and')) and 'Const:' in summary.result():
            errors.append({'annotation': key, 'actual': summary.result()})
    result = {'status': 'FAIL' if errors else 'PASS', 'queries_checked': checked,
              'rows': len(rows), 'errors': errors,
              'annotations': {'.'.join(key): value.result() for key, value in summaries.items()}}
    (case / (name + '.validation.json')).write_text(json.dumps(result, indent=2) + '\n')
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--lanes', type=int, default=64)
    args = parser.parse_args()
    case = args.out.resolve()
    case.mkdir(parents=True, exist_ok=False)
    source = case / 'semantics.sv'
    original = RTL.replace('LANES', str(args.lanes))
    source.write_text(original)
    build = case / 'build'
    build.mkdir()
    assert run(case, 'compile', ['vcs', '-full64', '-sverilog', '-lca', '-kdb', '-top', 'SemTop',
                               source, '-Mdir='+str(build/'csrc'), '-o', build/'simv'])['rc'] == 0
    assert run(case, 'oracle', [build/'simv'])['rc'] == 0
    assert 'SEMANTICS_ORACLE_PASS' in (case/'oracle.stdout').read_text()
    kdb = build/'simv.daidir/kdb.elab++'
    summary = {'lanes': args.lanes, 'cases': {}, 'tool_sha256': {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [REPO/'npi_port_trace.tcl', REPO/'npi_elaborated.tcl', REPO/'trace_support.tcl',
                     REPO/'annotate_trace_xlsx.py', REPO/'trace_identity.py']}}
    try:
        for mode in ('visible', 'hidden', 'stale'):
            if mode == 'hidden':
                source.rename(case/'semantics.hidden')
            elif mode == 'stale':
                (case/'semantics.hidden').rename(source)
                source.write_text(original.replace("wire [1:0] bus=2'b10", "wire [1:0] bus=2'b01"))
            for kind, module, ports in [('scalar', 'SemProbe', 'a'), ('wide', 'SemWide', 'a[0],a[1],a[3],a[7]'),
                                        ('loader', 'SemProducer', 'q[0]')]:
                name = mode+'_'+kind
                metrics = trace(case, kdb, name, module, ports)
                result = validate(case, name, args.lanes, kind)
                summary['cases'][name] = {'metrics': metrics, 'status': result['status'],
                                         'queries_checked': result['queries_checked'], 'errors': result['errors']}
                (case/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    finally:
        if (case/'semantics.hidden').exists():
            (case/'semantics.hidden').rename(source)
        source.write_text(original)
    failures = [name for name, value in summary['cases'].items() if value['status'] != 'PASS' or value['metrics']['rc']]
    if failures:
        raise AssertionError('semantic regressions failed: '+', '.join(failures))
    print('PASS driver_semantics lanes={} cases={}'.format(args.lanes, len(summary['cases'])), flush=True)


if __name__ == '__main__':
    main()
