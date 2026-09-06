#!/usr/bin/env python3
"""Require source-backed full-path evidence for every emitted scalar 0/1 driver."""
import argparse
import csv
import json
from pathlib import Path

from driver_semantics import REPO
from trace_identity import scalar_constant_value
from validate_xiangshan_stress import log_fields


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--case', required=True, type=Path, help='completed driver_semantics case directory')
    args = parser.parse_args()
    case = args.case.resolve()
    summary = json.loads((case/'summary.json').read_text())
    assert len(summary['cases']) == 9 and all(v['status'] == 'PASS' and v['metrics']['rc'] == 0 for v in summary['cases'].values())
    report = {'status': 'PASS', 'cases': {}}
    for name in summary['cases']:
        with (case/(name+'.stdout')).open(newline='') as stream:
            required = {(row['inst_full_name']+'.'+row['port_name'], row['signal_full_name'])
                        for row in csv.DictReader(stream)
                        if row['role'] == 'driver' and row['signal_full_name'].startswith('Const:')
                        and scalar_constant_value(row['signal_full_name']) is not None}
        found = set()
        with (case/(name+'.log')).open() as stream:
            for line in stream:
                if 'const_driver_source_detail ' not in line: continue
                fields = log_fields(line)
                key = (fields.get('port_path',''), fields.get('value',''))
                if key not in required: continue
                full = fields.get('const_full_path','')
                has_source = any(fields.get(field) not in (None,'','<empty>') for field in ('source_file','source_handle_path'))
                if (full.startswith(key[0]+'<-') and full.endswith(key[1]) and has_source and
                        fields.get('evidence_source') not in (None,'','<empty>','trace_result_fallback')):
                    found.add(key)
        missing = sorted(required-found)
        report['cases'][name] = {'required_constant_groups': len(required), 'source_backed_groups': len(found), 'missing': missing}
        if missing: report['status'] = 'FAIL'
    report['constant_groups'] = sum(v['required_constant_groups'] for v in report['cases'].values())
    (case/'constant_evidence.validation.json').write_text(json.dumps(report,indent=2)+'\n')
    assert report['status'] == 'PASS', 'missing source-backed constant evidence; inspect constant_evidence.validation.json'
    print('PASS constant evidence groups={}'.format(report['constant_groups']),flush=True)


if __name__ == '__main__':
    main()
