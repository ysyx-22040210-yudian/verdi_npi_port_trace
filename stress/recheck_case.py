#!/usr/bin/env python3
"""Recheck retained generated KDB without overwriting earlier evidence."""
import argparse
import json
from pathlib import Path
from scale_suite import trace, assert_oracle


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("case", type=Path)
    parser.add_argument("--name", required=True)
    parser.add_argument("--module", default="STProbe")
    parser.add_argument("--timeout", type=int, default=900)
    args = parser.parse_args()
    case = args.case.resolve()
    if list(case.glob(args.name + ".*")):
        raise RuntimeError("refusing to overwrite previous evidence")
    expected = json.loads((case / "oracle.json").read_text())
    if isinstance(expected, dict):
        expected = expected["expected"]
    ports = (case / "trace.ports.list").read_text().splitlines()
    stops = (case / "trace.stops.list").read_text().splitlines()
    trace(case, case / "build/simv.daidir/kdb.elab++", args.module, ports, stops, args.timeout, name=args.name)
    assert_oracle(case, expected, name=args.name)


if __name__ == "__main__":
    main()
