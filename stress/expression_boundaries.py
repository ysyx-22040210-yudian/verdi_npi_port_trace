#!/usr/bin/env python3
"""Real KDB regression for computed inputs versus constituent constants."""
import argparse
from pathlib import Path
from scale_suite import compile_design, trace, rows_for, save_json


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--instances", type=int, default=64)
    args = parser.parse_args()
    case = args.out.resolve()
    case.mkdir(parents=True, exist_ok=False)
    expressions = {
        "nested": "(sel ? a : b) & ~hold",
        "invert_mux": "~(sel ? a : b)",
        "and_one": "a & one",
        "or_zero": "a | hold",
        "inverted": "~hold",
        "xor_one": "a ^ one",
        "reduction": "&{a,b,one}",
        "casted": "logic'(a | hold)",
        "call": "choose(a,b)",
        "assigned": "assigned_net",
        "direct": "a",
        "tie0": "1'b0",
        "tie1": "1'b1",
    }
    ports = list(expressions) + ["mixed[0]", "mixed[1]", "vector"]
    declarations = ",".join("input " + p for p in expressions) + ",input [1:0] mixed,input [3:0] vector"
    conns = ",".join(".{}({})".format(p, expr) for p, expr in expressions.items())
    files = {
        "ExprProbe.sv": "module ExprProbe(" + declarations + "); endmodule",
        "ExprSource.sv": "module ExprSource(output reg a,b,sel); initial begin a=0;b=1;sel=0;end always #1 begin a=~a;b=~b;sel=~sel;end endmodule",
        "ExprWrap.sv": """module ExprWrap(input hold,one);
wire a,b,sel; ExprSource key(.a(a),.b(b),.sel(sel));
function automatic logic choose(input logic x,y); choose=x|y; endfunction
wire assigned_net; assign assigned_net=(sel ? a : b) & ~hold;
ExprProbe probe(""" + conns + ",.mixed({(sel ? a : b),1'b1}),.vector({4{a}} & {4{~hold}})); endmodule",
        "ExprTop.sv": "module ExprTop; " +
            " ".join("ExprWrap u{}(.hold(1'b0),.one(1'b1));".format(i) for i in range(args.instances)) + " endmodule",
    }
    expected = []
    for i in range(args.instances):
        for port in ports:
            signal = "COMBO_EXPR:port_connection"
            if port == "assigned":
                signal = "COMBO_EXPR:ternary"
            elif port == "direct":
                signal = "ExprTop.u{}.key.a".format(i)
            elif port in ("tie0", "tie1", "mixed[0]"):
                signal = "Const:1'b" + ("0" if port == "tie0" else "1")
            expected.append({"instance": "ExprTop.u{}.probe".format(i), "port": port, "signal": signal})
    save_json(case / "oracle.json", expected)
    kdb = compile_design(case, files, "ExprTop", 120)
    metrics = trace(case, kdb, "ExprProbe", ports, ["ExprTop.u{}.key".format(i) for i in range(args.instances)], 900, depth=8)
    groups = {}
    for row in rows_for(case):
        if row["role"] == "driver":
            groups.setdefault((row["inst_full_name"], row["port_name"]), set()).add(row["signal"])
    errors = []
    for item in expected:
        actual = groups.get((item["instance"], item["port"]), set())
        correct = actual == {item["signal"]}
        if item["port"] == "direct":
            # Full traces also expose implementation nodes inside the source
            # instance. Only its declared output port is the connection oracle;
            # accept scalar [0] spelling, never another instance or a constant.
            root = item["signal"].rsplit(".", 1)[0]
            correct = bool(actual & {item["signal"], item["signal"] + "[0]"}) and all(
                value.startswith(root + ".") and not value.startswith(("Const:", "ERROR:")) for value in actual)
        if not correct:
            errors.append({"expected": item, "actual": sorted(actual)})
    if set(groups) != {(x["instance"], x["port"]) for x in expected}:
        errors.append({"error": "missing or extra groups"})
    result = {"status": "FAIL" if errors else "PASS", "queries": len(expected), "instances": args.instances, "errors": errors, "metrics": metrics}
    save_json(case / "validation.json", result)
    if errors:
        raise AssertionError("{} expression failures: {}".format(len(errors), case / "validation.json"))
    print("PASS expression boundaries queries={}".format(len(expected)), flush=True)


if __name__ == "__main__":
    main()
