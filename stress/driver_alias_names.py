#!/usr/bin/env python3
"""Legal Init/Always/Combo/SigTap names must not become generated-node stops."""
import argparse
import hashlib
import json
from pathlib import Path

from driver_semantics import REPO, run, trace, read_groups

RTL = r"""
module NameSrc(output [7:0] q); assign q=8'h5a; endmodule
module NamePass(input [7:0] i, output [7:0] o); assign o=i; endmodule
module NameSink(input [7:0] a); wire used=^a; endmodule
module NameLane;
  wire [7:0] s0,s1,s2,s3,s4;
  NameSrc src(.q(s0));
  NamePass InitialPath(.i(s0),.o(s1));
  NamePass AlwaysController(.i(s1),.o(s2));
  NamePass u_ComboLogic(.i(s2),.o(s3));
  NamePass SigTapMonitor(.i(s3),.o(s4));
  NameSink sink(.a(s4));
  initial begin #1; if (sink.a !== 8'h5a) $fatal(1,"ALIAS_NAME_ORACLE_FAILED"); end
endmodule
module NameTop;
  for (genvar i=0; i<LANES; i=i+1) begin:g
    NameLane lane();
  end
  initial begin #2; $display("ALIAS_NAME_ORACLE_PASS"); $finish; end
endmodule
"""


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--out', required=True, type=Path)
    parser.add_argument('--lanes', type=int, default=64)
    args = parser.parse_args()
    case = args.out.resolve()
    case.mkdir(parents=True, exist_ok=False)
    source = case/'design.sv'
    source.write_text(RTL.replace('LANES', str(args.lanes)))
    build = case/'build'
    build.mkdir()
    assert run(case, 'compile', ['vcs','-full64','-sverilog','-lca','-kdb','-top','NameTop',
                source, '-Mdir='+str(build/'csrc'),'-o',build/'simv'])['rc'] == 0
    assert run(case, 'oracle', [build/'simv'])['rc'] == 0
    assert 'ALIAS_NAME_ORACLE_PASS' in (case/'oracle.stdout').read_text()
    kdb = build/'simv.daidir/kdb.elab++'
    bits = (0,1,3,7)
    result = {'lanes': args.lanes, 'cases': {}, 'tool_sha256': {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [REPO/'npi_port_trace.tcl', REPO/'npi_elaborated.tcl', REPO/'annotate_trace_xlsx.py']}}
    for name, module, port, role in [('driver','NameSink','a','driver'), ('loader','NameSrc','q','load')]:
        metrics = trace(case, kdb, name, module, ','.join('{}[{}]'.format(port,b) for b in bits))
        assert metrics['rc'] == 0
        rows, groups = read_groups(case, name)
        assert not any(row['signal_full_name'].startswith(('ERROR:', 'TRACE_INCOMPLETE:', 'TRACE_LIMIT_REACHED:')) for row in rows)
        for lane in range(args.lanes):
            prefix = 'NameTop.g[{}].lane.'.format(lane)
            for bit in bits:
                target = prefix + ('sink' if name == 'driver' else 'src')
                values = groups[(target,'{}[{}]'.format(port,bit),role)]
                if name == 'driver':
                    assert {v for v in values if v.startswith('Const:')} == {"Const:1'b{}".format((0x5a>>bit)&1)}, values
                else:
                    assert {v for v in values if v.startswith(prefix+'sink.a[')} == {prefix+'sink.a[{}]'.format(bit)}, values
        result['cases'][name] = dict(metrics, status='PASS', queries=args.lanes*len(bits))
    (case/'summary.json').write_text(json.dumps(result,indent=2)+'\n')
    print('PASS alias names lanes={} checks={}'.format(args.lanes,args.lanes*len(bits)*2),flush=True)


if __name__ == '__main__':
    main()
