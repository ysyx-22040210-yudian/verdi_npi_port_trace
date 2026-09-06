#!/usr/bin/env python3
"""Keep multidimensional scalar constant projection correct while fixing loads."""
import argparse
import hashlib
import json
import re
from pathlib import Path

from driver_semantics import REPO, read_groups, run, trace
from validate_xiangshan_stress import log_fields


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    case = args.out.resolve()
    case.mkdir(parents=True, exist_ok=False)
    literals = {'fill_one': ("'1", '11111111'), 'fill_zero': ("'0", '00000000'),
                'sized_one': ("1'b1", '00000001'), 'signed_one': ("1'sb1", '11111111'),
                'fill_x': ("'x", 'xxxxxxxx'), 'fill_z': ("'z", 'zzzzzzzz'),
                'mixed': ("8'b10010110", '10010110')}
    lines = ['module MDTie(input [1:0][3:0] a); wire sink=^a; endmodule', 'module MDTieTop;']
    for name, (literal, bits) in literals.items():
        lines.append('MDTie {}(.a({}));'.format(name, literal))
    lines.append('initial begin #1;')
    for name, (_, bits) in literals.items():
        lines.append('if({0}.a !== 8\'b{1}) $fatal(1,"CONSTANT_ORACLE {0}");'.format(name, bits))
    lines += ['$display("MULTIDIM_CONSTANT_ORACLE_PASS"); $finish; end', 'endmodule']
    source = case/'constants.sv'
    original = '\n'.join(lines)+'\n'
    source.write_text(original)
    build = case/'build'
    build.mkdir()
    assert run(case, 'compile', ['vcs', '-full64', '-sverilog', '-lca', '-kdb', '-top', 'MDTieTop',
                               source, '-Mdir='+str(build/'csrc'), '-o', build/'simv'])['rc'] == 0
    assert run(case, 'oracle', [build/'simv'])['rc'] == 0
    assert 'MULTIDIM_CONSTANT_ORACLE_PASS' in (case/'oracle.stdout').read_text()
    kdb = build/'simv.daidir/kdb.elab++'
    ports = ['a[{}][{}]'.format(i//4, i%4) for i in range(8)]
    results = {}
    try:
        for mode in ('visible', 'hidden'):
            if mode == 'hidden':
                source.rename(case/'constants.hidden')
            metrics = trace(case, kdb, mode, 'MDTie', ','.join(ports))
            assert metrics['rc'] == 0, metrics
            rows, groups = read_groups(case, mode)
            assert not any(r['signal_full_name'].startswith(('ERROR:', 'TRACE_INCOMPLETE:', 'TRACE_LIMIT_REACHED:')) for r in rows)
            evidence = {}
            for line in (case/(mode+'.log')).read_text().splitlines():
                if 'const_driver_source_detail ' in line:
                    fields = log_fields(line)
                    evidence.setdefault((fields.get('port_path'), fields.get('value')), []).append(fields)
            for name, (_, bits) in literals.items():
                for i, port in enumerate(ports):
                    expected = {"Const:1'b" + bits[7-i]}
                    actual = groups.get(('MDTieTop.'+name, port, 'driver'), set())
                    assert actual == expected, (mode, name, port, actual, expected)
                    loads = groups.get(('MDTieTop.'+name, port, 'load'), set())
                    assert len(loads) == 1, (mode, name, port, loads)
                    load = next(iter(loads))
                    assert load.startswith('MDTieTop.'+name+'.') and re.search(
                        r'/(?:Combo\.I0|XorRedu\.a)\['+str(7-i)+r'\]$', load), (mode, name, port, load)
                    target = 'MDTieTop.'+name+'.'+port
                    value = next(iter(expected))
                    assert any(fields.get('const_full_path') == target+'<-'+value and
                               fields.get('source_file') == str(source) and
                               fields.get('source_line', '').isdigit() and
                               fields.get('evidence_source') == 'elaborated_port_bit' and
                               fields.get('rhs_offset') == str(i) and fields.get('formal_width') == '8'
                               for fields in evidence.get((target, value), [])), (mode, target, 'missing exact constant provenance')
            count = len(ports)*len(literals)
            results[mode] = dict(metrics, status='PASS', scalar_queries=count, exact_loaders=count,
                                 source_backed_constant_groups=count)
    finally:
        if (case/'constants.hidden').exists():
            (case/'constants.hidden').rename(source)
        source.write_text(original)
    summary = {'cases': results, 'tool_sha256': {
        p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in
        [REPO/'npi_port_trace.tcl', REPO/'npi_elaborated.tcl', REPO/'trace_support.tcl', REPO/'annotate_trace_xlsx.py']}}
    (case/'summary.json').write_text(json.dumps(summary, indent=2)+'\n')
    print('PASS multidim_constants queries={}'.format(2*len(ports)*len(literals)))


if __name__ == '__main__':
    main()
