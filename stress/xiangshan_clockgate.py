#!/usr/bin/env python3
"""Check repeated real clock-gate connections against their RTL definitions."""
import argparse
import json
import re
from pathlib import Path
from scale_suite import trace, rows_for, save_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--instances", type=Path, required=True)
    parser.add_argument("--rtl", type=Path, default=Path("/root/XiangShan-build/build/rtl"))
    parser.add_argument("--kdb", type=Path, default=Path("/root/XiangShan-build/build/xverif_xiangshan/kdb/simv.daidir/kdb.elab++"))
    args = parser.parse_args()
    case = args.out.resolve()
    case.mkdir(parents=True, exist_ok=False)
    instances = args.instances.read_text().splitlines()
    if len(instances) != 279 or len(set(instances)) != 279:
        raise AssertionError("expected 279 distinct ClockGate instances")
    sources, bindings = {}, {}
    parent_leaves = {inst.rsplit(".", 2)[-2] for inst in instances}
    parent_modules = {name: set() for name in parent_leaves}
    # Independent source inventory: module type is recovered from RTL instance
    # declarations, never from trace result signal names.
    for path in sorted(args.rtl.glob("*.sv")):
        text = path.read_text()
        module_match = re.search(r"\bmodule\s+(\w+)", text)
        if not module_match:
            continue
        module = module_match.group(1)
        for child_module, child_instance in re.findall(r"^\s*(\w+)\s+(\w+)\s*\(", text, re.M):
            if child_instance in parent_modules:
                parent_modules[child_instance].add(child_module)
        for child, block in re.findall(r"\bClockGate\s+(\w+)\s*\((.*?)\);", text, re.S):
            match = re.search(r"\.TE\s*\((.*?)\)\s*,\s*\.E\s*\((.*?)\)\s*,\s*\.CK\s*\((.*?)\)\s*,", block, re.S)
            if not match:
                raise AssertionError("unsupported clock-gate declaration in " + str(path))
            bindings[(module, child)] = dict(zip(("TE", "E", "CK"), (x.strip() for x in match.groups())))
            sources[module] = str(path)
    expected = []
    parents = []
    for instance in instances:
        parent = instance.rsplit(".", 1)[0]
        child = instance.rsplit(".", 1)[1]
        candidates = [bindings[(module, child)] for module in parent_modules[parent.rsplit(".", 1)[-1]] if (module, child) in bindings]
        if not candidates:
            raise AssertionError("cannot independently resolve RTL parent for " + instance)
        parents.append(parent)
        for port in ("TE", "CK"):
            signals = {candidate[port] for candidate in candidates}
            if len(signals) != 1 or not re.fullmatch(r"\w+", next(iter(signals))):
                raise AssertionError("ambiguous RTL connection: " + instance + "." + port)
            signal = next(iter(signals))
            expected.append({"instance": instance, "port": port, "signal": parent + "." + signal})
        enables = {candidate["E"] for candidate in candidates}
        if all("?" in value for value in enables):
            expected.append({"instance": instance, "port": "E", "signal": "COMBO_EXPR:port_connection"})
        elif len(enables) == 1 and re.fullmatch(r"1'[bh]1", next(iter(enables))):
            expected.append({"instance": instance, "port": "E", "signal": "Const:1'b1"})
        elif all("|" in value and "'" not in value for value in enables):
            operands = {tuple(sorted(set(re.findall(r"\b[A-Za-z_]\w*\b", value)))) for value in enables}
            if len(operands) != 1:
                raise AssertionError("ambiguous enable operands for " + instance)
            expected.append({"instance": instance, "port": "E", "signal": "COMBO_EXPR:port_connection"})
        else:
            raise AssertionError("unmodeled enable expression for " + instance + ": " + repr(enables))
    save_json(case / "oracle.json", {"sources": sources, "expected": expected})
    metrics = trace(case, args.kdb, "ClockGate", ["TE", "E", "CK"], parents, 900, depth=0)
    groups = {}
    for row in rows_for(case):
        if row["role"] == "driver":
            groups.setdefault((row["inst_full_name"], row["port_name"]), set()).add(row["signal"])
        if row["port_dir"] != "input":
            raise AssertionError("incorrect input direction")
    errors = []
    for item in expected:
        actual = groups.get((item["instance"], item["port"]), set())
        if "signal" in item:
            correct = actual == {item["signal"]}
        else:
            # Computation is a boundary, not a set of transparent connections.
            correct = actual == set(item["signals"])
        if not correct:
            errors.append({"expected": item, "actual": sorted(actual)})
    if set(groups) != {(x["instance"], x["port"]) for x in expected}:
        errors.append({"error": "missing or extra queries"})
    result = {"status": "FAIL" if errors else "PASS", "instances": len(instances), "queries": len(expected), "errors": errors, "metrics": metrics}
    save_json(case / "validation.json", result)
    if errors:
        raise AssertionError("{} ClockGate oracle mismatches; see {}".format(len(errors), case / "validation.json"))
    print("PASS ClockGate instances=279 exact_driver_queries=837", flush=True)


if __name__ == "__main__":
    main()
