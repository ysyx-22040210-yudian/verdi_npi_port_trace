#!/usr/bin/env python3
"""Generate deterministic RTL and verify trace output against an independent oracle.

The oracle is computed from permutations and instance identities before invoking
the tracer. No expected endpoint is copied from a previous trace run.
"""

import argparse
import csv
import hashlib
import json
import os
import random
import re
import shutil
import signal
import subprocess
import sys
import time
from pathlib import Path

REPO = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(REPO))

PORTS = ["data[0]", "data[7]", "data[08]", "data[15]", "ascending[0]", "ascending[15]",
         "offset[16]", "offset[31]", "id[0]", "id[1]", "id[2]", "id[3]",
         "mixed[6]", "mixed[7]", "mixed[8]", "emit[7]", "emit[8]"]
DECL = "input [15:0] data, input [0:15] ascending, input [31:16] offset, input [3:0] id, input [10:0] mixed, output [15:0] emit"
CONNS = ".data(data),.ascending(ascending),.offset(offset),.id(id),.mixed(mixed),.emit(emit)"


def save_json(path, value):
    path.write_text(json.dumps(value, indent=2, sort_keys=True) + "\n", encoding="utf-8")


def run_step(case, name, command, timeout):
    started = time.monotonic()
    timefile = case / (name + ".time")
    argv = ["/usr/bin/time", "-v", "-o", str(timefile)] + [str(value) for value in command]
    print("START {} {}".format(case.name, name), flush=True)
    with (case / (name + ".stdout")).open("w") as stdout, (case / (name + ".log")).open("w") as stderr:
        proc = subprocess.Popen(argv, cwd=str(case), stdout=stdout, stderr=stderr, start_new_session=True)
        try:
            rc = proc.wait(timeout=timeout)
        except subprocess.TimeoutExpired:
            os.killpg(proc.pid, signal.SIGTERM)
            try:
                proc.wait(timeout=10)
            except subprocess.TimeoutExpired:
                os.killpg(proc.pid, signal.SIGKILL)
                proc.wait()
            raise RuntimeError("{}: harness timeout after {} seconds".format(name, timeout))
    result = {"command": [str(x) for x in command], "rc": rc, "seconds": round(time.monotonic() - started, 3)}
    if timefile.exists():
        match = re.search(r"Maximum resident set size \(kbytes\):\s*(\d+)", timefile.read_text())
        if match:
            result["rss_kib"] = int(match.group(1))
    save_json(case / (name + ".metrics.json"), result)
    if rc:
        raise RuntimeError("{} failed rc={}: {}".format(name, rc, case / (name + ".log")))
    print("DONE {} {} seconds={} rss_kib={}".format(case.name, name, result["seconds"], result.get("rss_kib")), flush=True)
    return result


def write_design(case, files):
    rtl = case / "rtl"
    rtl.mkdir()
    for name, content in files.items():
        (rtl / name).write_text(content + "\n", encoding="utf-8")
    filelist = case / "rtl.f"
    filelist.write_text("\n".join(str(rtl / name) for name in files) + "\n")
    return filelist


def compile_design(case, files, top, timeout):
    filelist = write_design(case, files)
    build = case / "build"
    build.mkdir()
    run_step(case, "compile", ["vcs", "-full64", "-sverilog", "-lca", "-kdb", "-top", top,
             "-f", filelist, "-Mdir=" + str(build / "csrc"), "-o", build / "simv"], timeout)
    kdb = build / "simv.daidir" / "kdb.elab++"
    if not kdb.is_dir():
        raise RuntimeError("VCS did not produce KDB: " + str(kdb))
    return kdb


def trace(case, kdb, module, ports, stops, timeout, name="trace", node_limit=100000, depth=12):
    save_json(case / (name + ".tool_sha256.json"), {
        path.name: hashlib.sha256(path.read_bytes()).hexdigest()
        for path in [REPO / "npi_port_trace.tcl", REPO / "npi_elaborated.tcl", REPO / "trace_support.tcl",
                     REPO / "npi_trace.sh", REPO / "annotate_trace_xlsx.py", REPO / "trace_identity.py"]})
    ports_file = case / (name + ".ports.list")
    ports_file.write_text("\n".join(ports) + "\n")
    stop_file = case / (name + ".stops.list")
    stop_file.write_text("\n".join(stops) + "\n")
    command = ["bash", REPO / "npi_trace.sh", "-lib", kdb, "-module", module,
               "-ports-file", ports_file, "-load-stop-instance-file", stop_file,
               "-module-out", case / (name + ".boundary.csv"), "-const-trace-depth", "16",
               "-assign-trace-depth", str(depth), "-assign-expr-trace-depth", "4",
               "-load-trace-node-limit", str(node_limit), "-load-trace-edge-limit", "500000",
               "-load-trace-api-list-limit", "100000", "-verdi-timeout-sec", str(timeout), "-trace-debug", "0"]
    metrics = run_step(case, name, command, timeout + 30)
    (case / (name + ".stdout")).rename(case / (name + ".full.csv"))
    return metrics


def rows_for(case, name="trace"):
    rows = []
    for suffix in ("full", "boundary"):
        path = case / (name + "." + suffix + ".csv")
        with path.open(newline="") as handle:
            reader = csv.DictReader(handle)
            expected = ["inst_full_name", "port_name", "port_dir", "role",
                        "signal_full_name" if suffix == "full" else "module_signal_full_name"]
            if reader.fieldnames != expected:
                raise AssertionError("bad CSV header: {} {}".format(path, reader.fieldnames))
            for row in reader:
                if None in row or any(value is None for value in row.values()):
                    raise AssertionError("malformed CSV record: " + str(path))
                row["signal"] = row[expected[-1]]
                rows.append(row)
    return rows


def scalar_value(signal_text):
    match = re.fullmatch(r"Const:(?:1)?'b([01])", signal_text)
    return int(match.group(1)) if match else None


def assert_oracle(case, expected, name="trace"):
    groups = {}
    errors = []
    for row in rows_for(case, name):
        key = (row["inst_full_name"], row["port_name"], row["role"])
        groups.setdefault(key, set()).add(row["signal"])
        if row["signal"].startswith(("ERROR:", "TRACE_LIMIT_REACHED:", "TRACE_INCOMPLETE:")):
            errors.append({"unexpected_diagnostic": row})
    for item in expected:
        key = (item["instance"], item["port"], item["role"])
        signals = groups.get(key, set())
        diagnostics = sorted(s for s in signals if s.startswith(("ERROR:", "TRACE_LIMIT_REACHED:", "TRACE_INCOMPLETE:")))
        if diagnostics:
            errors.append({"key": key, "diagnostics": diagnostics})
        if "constant" in item:
            actual = {scalar_value(s) for s in signals if s.startswith("Const:")}
            if actual != {item["constant"]}:
                errors.append({"key": key, "expected_constant": item["constant"], "signals": sorted(signals)})
        else:
            # Only real keyword ports are compared; intermediate alias rows do
            # not count as endpoint coverage. Bit positions must match exactly.
            actual = {s for s in signals if re.search(r"\.(?:u_key\.out|sink_[A-Za-z0-9_]+\.in)(?:\[\d+\])?$", s)}
            if actual != set(item["endpoints"]):
                errors.append({"key": key, "expected": item["endpoints"], "actual": sorted(actual), "all_signals": sorted(signals)[:40]})
            if item["role"] == "driver" and any(s.startswith("Const:") for s in signals):
                errors.append({"key": key, "unexpected_constant": sorted(signals)})
    expected_groups = {(x["instance"], x["port"]) for x in expected}
    actual_groups = {(x[0], x[1]) for x in groups}
    if actual_groups != expected_groups:
        errors.append({"missing_queries": sorted(expected_groups - actual_groups), "unexpected_queries": sorted(actual_groups - expected_groups)})
    result = {"status": "FAIL" if errors else "PASS", "queries": len(expected), "instances": len({x["instance"] for x in expected}),
              "errors": errors, "csv_rows": len(rows_for(case, name))}
    save_json(case / (name + ".validation.json"), result)
    if errors:
        raise AssertionError("{}: {} oracle failures; see {}".format(case.name, len(errors), case / (name + ".validation.json")))
    print("PASS {} queries={} instances={}".format(case.name, len(expected), result["instances"]), flush=True)
    return result


def mesh_design(tiles, seed):
    files = {
        "STSource.sv": "module STSource(input clk, output reg [15:0] out); initial out=16'h951d; always @(posedge clk) out <= {out[14:0],out[15]^out[2]}; endmodule",
        "STSink.sv": "module STSink #(parameter W=8)(input [W-1:0] in, output used); assign used=^in; endmodule",
        "STProbe.sv": "module STProbe(" + DECL + "); assign emit=data; endmodule",
    }
    for level in range(4):
        child = "STProbe" if level == 0 else "STWrap" + str(level - 1)
        name = "probe" if level == 0 else "w" + str(level - 1)
        files["STWrap{}.sv".format(level)] = "module STWrap{}({}); {} {}({}); endmodule".format(level, DECL, child, name, CONNS)
    expected, stops, top = [], [], ["module STTop; reg clk; initial clk=0; always #5 clk=~clk;"]
    for i in range(tiles):
        rng = random.Random(seed + i)
        permutation = list(range(16))
        rng.shuffle(permutation)
        # A second slice/concat swap is independent of the first permutation.
        mapped = permutation[8:] + permutation[:8]
        tile = "STTop.cluster{}.t{}".format(i % 4, i)
        instance = tile + ".w3.w2.w1.w0.probe"
        source = tile + ".u_key.out"
        stops.extend([tile + ".u_key", tile + ".sink_lo", tile + ".sink_hi", tile + ".sink_mix"])
        code = ["module STTile{}(input clk); wire [15:0] keybus,p0,data,emit; wire used0,used1,used2;".format(i),
                "STSource u_key(.clk(clk),.out(keybus));",
                "assign p0={" + ",".join("keybus[{}]".format(k) for k in reversed(permutation)) + "};",
                "assign data={p0[7:0],p0[15:8]};",
                "STWrap3 w3(.data(data),.ascending(data),.offset(data),.id(4'd{}),.mixed({{3'b101,keybus[5],7'b0101010}}),.emit(emit));".format(i % 16),
                "STSink #(.W(8)) sink_lo(.in(emit[7:0]),.used(used0));",
                "STSink #(.W(8)) sink_hi(.in(emit[15:8]),.used(used1));",
                "STSink #(.W(4)) sink_mix(.in({emit[0],emit[7],emit[8],emit[15]}),.used(used2));", "endmodule"]
        files["STTile{}.sv".format(i)] = "\n".join(code)
        for port, bit in [("data[0]", mapped[0]), ("data[7]", mapped[7]), ("data[8]", mapped[8]), ("data[15]", mapped[15]),
                          ("ascending[0]", mapped[15]), ("ascending[15]", mapped[0]), ("offset[16]", mapped[0]), ("offset[31]", mapped[15]), ("mixed[7]", 5)]:
            expected.append({"instance": instance, "port": port, "role": "driver", "endpoints": [source + "[{}]".format(bit)]})
        for bit in range(4):
            expected.append({"instance": instance, "port": "id[{}]".format(bit), "role": "driver", "constant": (i >> bit) & 1})
        for bit, value in [(6, 0), (8, 1)]:
            expected.append({"instance": instance, "port": "mixed[{}]".format(bit), "role": "driver", "constant": value})
        for bit, sinks in [(7, ["sink_lo.in[7]", "sink_mix.in[2]"]), (8, ["sink_hi.in[0]", "sink_mix.in[1]"])]:
            expected.append({"instance": instance, "port": "emit[{}]".format(bit), "role": "load", "endpoints": [tile + "." + s for s in sinks]})
    for cluster in range(4):
        top.append("if (1) begin : cluster{}".format(cluster))
        for i in range(cluster, tiles, 4):
            top.append("STTile{} t{}(.clk(clk));".format(i, i))
        top.append("end")
    top.append("endmodule")
    files["STTop.sv"] = "\n".join(top)
    return files, expected, stops


def cleanup_build(case, keep):
    build = case / "build"
    if not keep and build.is_dir():
        build.resolve().relative_to(case.resolve())
        shutil.rmtree(str(build))


def run_mesh(root, tiles, seed, timeout, keep):
    case = root / ("mesh_{}".format(tiles))
    case.mkdir()
    files, expected, stops = mesh_design(tiles, seed)
    save_json(case / "oracle.json", {"seed": seed, "tiles": tiles, "expected": expected})
    kdb = compile_design(case, files, "STTop", timeout)
    trace(case, kdb, "STProbe", PORTS, stops, timeout)
    result = assert_oracle(case, expected)
    result["elaborated_instances_expected"] = 1 + tiles * 10
    save_json(case / "result.json", result)
    cleanup_build(case, keep)
    return result


def run_fanout(root, count, timeout, keep):
    case = root / ("fanout_{}".format(count))
    case.mkdir()
    files = {"Fanout.sv": "\n".join([
        "module FanoutProbe(output reg [7:0] emit); initial emit=8'ha5; endmodule",
        "module FanoutSink(input [7:0] in, output used); assign used=^in; endmodule",
        "module FanoutTop; wire [7:0] bus; FanoutProbe probe(.emit(bus));",
    ] + ["wire used{0}; FanoutSink sink_{0}(.in(bus),.used(used{0}));".format(i) for i in range(count)] + ["endmodule"])}
    expected = [{"instance": "FanoutTop.probe", "port": "emit[7]", "role": "load", "endpoints": ["FanoutTop.sink_{}.in[7]".format(i) for i in range(count)]}]
    save_json(case / "oracle.json", expected)
    kdb = compile_design(case, files, "FanoutTop", timeout)
    stops = ["FanoutTop.sink_{}".format(i) for i in range(count)]
    trace(case, kdb, "FanoutProbe", ["emit[7]"], stops, timeout, depth=2)
    result = assert_oracle(case, expected)
    trace(case, kdb, "FanoutProbe", ["emit[7]"], stops, timeout, name="limited", node_limit=1, depth=2)
    rows = rows_for(case, "limited")
    if not any(r["signal"].startswith("TRACE_LIMIT_REACHED:") for r in rows):
        raise AssertionError("low budget did not produce a limit diagnostic")
    from annotate_trace_xlsx import InstanceMatcher, PortSummary, TraceRow
    summary = PortSummary()
    matcher = InstanceMatcher(stops)
    for row in rows:
        summary.observe_row(TraceRow(row["inst_full_name"], row["port_name"], row["port_dir"], row["role"], row["signal"]), matcher)
    if not summary.result().startswith("incomplete;"):
        raise AssertionError("limit was not preserved by annotation: " + summary.result())
    result["limited_annotation"] = summary.result()
    save_json(case / "result.json", result)
    cleanup_build(case, keep)
    return result


def run_wide(root, count, timeout, keep):
    case = root / ("ports_{}".format(count))
    case.mkdir()
    ports = ["input_signal_with_long_identifier_{:05d}".format(i) for i in range(count)]
    files = {"Wide.sv": "module WideProbe(" + ",".join("input " + p for p in ports) + "); endmodule\nmodule WideTop; WideProbe probe(" + ",".join(".{}(1'b{})".format(p, i % 2) for i, p in enumerate(ports)) + "); endmodule"}
    expected = [{"instance": "WideTop.probe", "port": p, "role": "driver", "constant": i % 2} for i, p in enumerate(ports)]
    save_json(case / "oracle.json", expected)
    kdb = compile_design(case, files, "WideTop", timeout)
    trace(case, kdb, "WideProbe", ports, [], timeout, depth=0)
    result = assert_oracle(case, expected)
    evidence_ports = set()
    for line in (case / "trace.log").read_text().splitlines():
        if "const_driver_source_detail method=elaborated_port_bit " not in line:
            continue
        if "const_full_path=" not in line or "Wide.sv" not in line or "rhs_offset=0" not in line:
            raise AssertionError("constant evidence is missing its full path / KDB source / bit offset")
        match = re.search(r"\bport_path=WideTop\.probe\.(\w+)(?:\s|$)", line)
        if match:
            evidence_ports.add(match.group(1))
    if evidence_ports != set(ports):
        raise AssertionError("wide-port constant provenance coverage: {}/{}".format(len(evidence_ports), len(ports)))
    result["constant_provenance_ports"] = len(evidence_ports)
    result["port_request_bytes"] = (case / "trace.ports.list").stat().st_size
    save_json(case / "result.json", result)
    cleanup_build(case, keep)
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--out", type=Path, required=True)
    parser.add_argument("--tiles", type=int, nargs="*", default=[4, 64, 512])
    parser.add_argument("--seed", type=int, default=20260905)
    parser.add_argument("--fanout", type=int, default=4096)
    parser.add_argument("--wide-ports", type=int, default=8192)
    parser.add_argument("--timeout", type=int, default=1200)
    parser.add_argument("--keep-kdb", action="store_true")
    args = parser.parse_args()
    root = args.out.resolve()
    root.mkdir(parents=True, exist_ok=False)
    report = {"status": "RUNNING", "seed": args.seed, "cases": {}, "sources": {}}
    for path in [REPO / "npi_port_trace.tcl", REPO / "trace_support.tcl", REPO / "trace_identity.py", Path(__file__)]:
        report["sources"][path.name] = hashlib.sha256(path.read_bytes()).hexdigest()
    save_json(root / "summary.json", report)
    try:
        for tiles in args.tiles:
            report["cases"]["mesh_{}".format(tiles)] = run_mesh(root, tiles, args.seed, args.timeout, args.keep_kdb)
            save_json(root / "summary.json", report)
        if args.fanout:
            report["cases"]["fanout"] = run_fanout(root, args.fanout, args.timeout, args.keep_kdb)
            save_json(root / "summary.json", report)
        if args.wide_ports:
            report["cases"]["wide_ports"] = run_wide(root, args.wide_ports, args.timeout, args.keep_kdb)
        report["status"] = "PASS"
    except Exception as exc:
        report["status"] = "FAIL"
        report["error"] = str(exc)
        raise
    finally:
        save_json(root / "summary.json", report)
    print("PASS scale suite " + str(root), flush=True)


if __name__ == "__main__":
    main()
