#!/usr/bin/env python3
"""Negative oracle: keep real multiple drivers, distinguish sized/fill/X/Z literals."""
import argparse
import json
from pathlib import Path

from driver_semantics import run, trace, read_groups

RTL = r"""
module FSWide(input [7:0] a); wire sink=^a; endmodule
module FSScalar(input a); wire sink=a; endmodule
module FSTop;
  wire conflict;
  wire signed [1:0] signed_net=2'sb10;
  wire [1:0] unsigned_net=2'b10;
  assign conflict=1'b0;
  assign conflict=1'b1;
  FSScalar real_conflict(.a(conflict));
  FSScalar truncate({1'b1,1'b0});
  FSWide fill_one(.a('1));
  FSWide sized_one(.a(1'b1));
  FSWide fill_x(.a('x));
  FSWide fill_z(.a('z));
  FSWide sized_x(.a(1'bx));
  FSWide signed_one(.a(1'sb1));
  FSWide signed_wire(.a(signed_net));
  FSWide unsigned_wire(.a(unsigned_net));
  initial begin
    #1;
    if (conflict !== 1'bx || truncate.a !== 1'b0 || fill_one.a !== 8'hff ||
        sized_one.a !== 8'h01 || fill_x.a !== 8'hxx || fill_z.a !== 8'hzz ||
        sized_x.a !== 8'b0000000x || signed_one.a !== 8'hff ||
        signed_wire.a !== 8'hfe || unsigned_wire.a !== 8'h02)
      $fatal(1,"FOUR_STATE_ORACLE_FAILED");
    $display("FOUR_STATE_ORACLE_PASS"); $finish;
  end
endmodule
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    args = parser.parse_args()
    case = args.out.resolve()
    case.mkdir(parents=True, exist_ok=False)
    (case/'design.sv').write_text(RTL)
    (case/'build').mkdir()
    assert run(case, 'compile', ['vcs','-full64','-sverilog','-lca','-kdb','-top','FSTop',
               case/'design.sv','-Mdir='+str(case/'build/csrc'),'-o',case/'build/simv'])['rc'] == 0
    assert run(case, 'oracle', [case/'build/simv'])['rc'] == 0
    assert 'FOUR_STATE_ORACLE_PASS' in (case/'oracle.stdout').read_text()
    kdb = case/'build/simv.daidir/kdb.elab++'
    metrics = trace(case, kdb, 'scalar', 'FSScalar', 'a')
    assert metrics['rc'] == 0
    _, groups = read_groups(case, 'scalar')
    true_drivers = groups[('FSTop.real_conflict','a','driver')]
    assert {"Const:1'b0", "Const:1'b1", 'ERROR:CONST_DRIVER_CONFLICT:0,1'} <= true_drivers, true_drivers
    assert groups[('FSTop.truncate','a','driver')] == {"Const:1'b0"}
    expected = {'fill_one': ('1','1'), 'sized_one': ('1','0'), 'fill_x': ('x','x'),
                'fill_z': ('z','z'), 'sized_x': ('x','0'), 'signed_one': ('1','1'),
                'signed_wire': ('0','1'), 'unsigned_wire': ('0','0')}
    result = {'true_conflict': sorted(true_drivers), 'modes': {}}
    for mode in ('visible','hidden'):
        source = case/'design.sv'
        if mode == 'hidden': source.rename(case/'design.hidden')
        try:
            metrics = trace(case, kdb, mode, 'FSWide', 'a[0],a[7]')
            assert metrics['rc'] == 0
            _, groups = read_groups(case, mode)
            for instance, values in expected.items():
                for bit, value in zip((0,7),values):
                    actual = groups[('FSTop.'+instance,'a[{}]'.format(bit),'driver')]
                    assert actual == {"Const:1'b"+value}, (instance,bit,actual)
                    assert not any(v.startswith(('ERROR:', 'TRACE_INCOMPLETE:', 'TRACE_LIMIT_REACHED:')) for v in actual), (instance,bit,actual)
            result['modes'][mode] = dict(metrics,status='PASS',queries=len(expected)*2)
        finally:
            if (case/'design.hidden').exists(): (case/'design.hidden').rename(source)
    (case/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS four-state literals and true-vs-false constant conflict',flush=True)


if __name__ == '__main__':
    main()
