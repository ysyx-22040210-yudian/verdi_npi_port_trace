#!/usr/bin/env python3
"""
Filter NPI trace CSV output by driver/load ownership.

Usage:
    python filter_trace.py <input.csv> <output.csv> --instances <instances.txt>

Example:
    python filter_trace.py trace.csv filtered.csv --instances module_instances.txt

The script copies rows whose signal_full_name belongs to any instance listed in the
instance file. This is intended for filtering driver/load rows that come from a
given module's instantiated instances.
"""

import sys
import csv
import os
from pathlib import Path

from csv_compat import configure_csv_field_size_limit
from runtime_paths import bounded_derived_path, bounded_path, sanitize_component

configure_csv_field_size_limit()

def log_step(message):
    print("[filter_trace] {}".format(message), file=sys.stderr)

def load_instances(instance_file):
    log_step("loading instance list: {}".format(instance_file))
    instances = []
    with open(instance_file, 'r', encoding='utf-8') as infile:
        for line in infile:
            inst = line.strip().lstrip('\ufeff')
            if inst:
                instances.append(inst)
    log_step("loaded {} instances".format(len(instances)))
    for idx, inst in enumerate(instances[:5], start=1):
        log_step("instance[{}]={}".format(idx, inst))
    if len(instances) > 5:
        log_step("instance list truncated in log: {} more".format(len(instances) - 5))
    return instances

def strip_instance_prefix(signal_name, inst):
    if signal_name == inst:
        return ""
    if signal_name.startswith(inst + "."):
        return signal_name[len(inst) + 1:]
    if signal_name.startswith(inst + "/"):
        return signal_name[len(inst) + 1:]
    return None

def is_direct_instance_node(rest):
    if rest is None:
        return False
    if rest == "":
        return True

    # Expression instances are generated for port-connection expressions. They
    # are not a concrete signal owned by the filter module, so do not report
    # them as module-origin driver/load rows.
    if rest.startswith("_ExprInst__:"):
        return False

    # Keep logic generated in the filter instance itself, such as:
    #   ysyx_22050058_gshare/Always0:...
    if "/" in rest:
        head = rest.split("/", 1)[0]
        if "." in head:
            return False
        return True

    # Plain nets/ports directly under the instance are acceptable, but a deeper
    # hierarchy like child_inst.child_module.signal belongs to the child instance.
    return rest.count(".") <= 1

def candidate_signal_prefixes(signal_name):
    start = 0
    while True:
        dot = signal_name.find(".", start)
        slash = signal_name.find("/", start)
        positions = [pos for pos in (dot, slash) if pos != -1]
        if not positions:
            break
        pos = min(positions)
        if pos > 0:
            yield signal_name[:pos]
        start = pos + 1
    if signal_name:
        yield signal_name


class InstanceMatcher:
    """Match trace endpoints against instance paths through hashed prefixes."""

    def __init__(self, instances):
        self.prefixes = set()
        for inst in instances:
            self.prefixes.add(inst)
            parts = inst.split(".")
            for idx in range(1, len(parts)):
                self.prefixes.add(".".join(parts[idx:]))

    def belongs(self, signal_name):
        if not signal_name or signal_name.startswith("Const:"):
            return False
        if signal_name.startswith("TRACE_LIMIT_REACHED:"):
            return True
        if signal_name.startswith("ERROR:"):
            return True

        for prefix in candidate_signal_prefixes(signal_name):
            if prefix not in self.prefixes:
                continue
            if is_direct_instance_node(strip_instance_prefix(signal_name, prefix)):
                return True
        return False


def signal_belongs_to_instance(signal_name, instances):
    matcher = instances if isinstance(instances, InstanceMatcher) else InstanceMatcher(instances)
    return matcher.belongs(signal_name)

def get_signal_column(header):
    if "signal_full_name" in header:
        return header.index("signal_full_name")
    return header.index("module_signal_full_name")

def normalize_port_dir(port_dir):
    text = (port_dir or "").strip().lower()
    if text in {"input", "npiinput", "1"}:
        return "input"
    if text in {"output", "npioutput", "2"}:
        return "output"
    if text in {"inout", "npiinout", "3"}:
        return "inout"
    return "unknown"

def role_matches_port_direction(port_dir, role):
    direction = normalize_port_dir(port_dir)
    role = (role or "").strip().lower()
    if direction == "input":
        return role == "driver"
    if direction == "output":
        return role == "load"
    if direction == "inout":
        return role in {"driver", "load"}
    return role in {"driver", "load"}

def normalized_header(header):
    header = list(header)
    if "module_signal_full_name" in header and "signal_full_name" not in header:
        header[header.index("module_signal_full_name")] = "signal_full_name"
    return header

def filter_csv_by_instances(input_file, output_file, instance_file, normalize_header=False):
    log_step("mode=instances")
    matched_count = 0
    total_count = 0
    instances = load_instances(instance_file)
    matcher = InstanceMatcher(instances)
    log_step("indexed_instance_prefixes={}".format(len(matcher.prefixes)))

    log_step("opening input CSV: {}".format(input_file))
    log_step("opening output CSV: {}".format(output_file))
    with open(input_file, 'r', encoding='utf-8') as infile, \
         open(output_file, 'w', encoding='utf-8', newline='') as outfile:

        reader = csv.reader(infile)
        writer = csv.writer(outfile)

        header = next(reader)
        log_step("input_header={}".format(",".join(header)))
        writer.writerow(normalized_header(header) if normalize_header else header)
        signal_idx = get_signal_column(header)
        port_dir_idx = header.index("port_dir") if "port_dir" in header else -1
        role_idx = header.index("role") if "role" in header else -1
        log_step("signal_column={} index={}".format(header[signal_idx], signal_idx))
        log_step("role_direction_filter=enabled port_dir_index={} role_index={}".format(port_dir_idx, role_idx))
        if normalize_header:
            log_step("normalizing module_signal_full_name header to signal_full_name")

        for row in reader:
            total_count += 1
            if role_idx >= 0 and port_dir_idx >= 0:
                port_dir = row[port_dir_idx] if len(row) > port_dir_idx else ""
                role = row[role_idx] if len(row) > role_idx else ""
                if not role_matches_port_direction(port_dir, role):
                    continue
            if len(row) > signal_idx and signal_belongs_to_instance(row[signal_idx], matcher):
                writer.writerow(row)
                matched_count += 1

    log_step("filtered_rows={} total_rows={}".format(matched_count, total_count))
    log_step("output_written={}".format(output_file))

def merge_csvs(output_file, input_files):
    log_step("mode=merge")
    log_step("merge_output={}".format(output_file))
    log_step("merge_inputs={}".format(",".join(input_files)))
    header = None
    seen = set()
    written = 0

    with open(output_file, 'w', encoding='utf-8', newline='') as outfile:
        writer = csv.writer(outfile)
        for input_file in input_files:
            log_step("reading merge input: {}".format(input_file))
            with open(input_file, 'r', encoding='utf-8') as infile:
                reader = csv.reader(infile)
                input_header = next(reader)
                input_header = normalized_header(input_header)
                log_step("merge_input_header={}".format(",".join(input_header)))
                if header is None:
                    header = input_header
                    writer.writerow(header)
                elif input_header != header:
                    raise ValueError("CSV headers do not match: {}".format(input_file))

                for row in reader:
                    key = tuple(row)
                    if key in seen:
                        continue
                    seen.add(key)
                    writer.writerow(row)
                    written += 1

    log_step("merged_rows={} output={}".format(written, output_file))

def safe_filename(text):
    return sanitize_component(text)

def split_csv_by_trace_instance(input_file):
    log_step("mode=split-by-trace-instance input={}".format(input_file))
    with open(input_file, 'r', encoding='utf-8') as infile:
        reader = csv.reader(infile)
        header = next(reader)
        rows_by_inst = {}
        inst_idx = header.index("inst_full_name")

        for row in reader:
            if len(row) <= inst_idx:
                continue
            inst = row[inst_idx]
            rows_by_inst.setdefault(inst, []).append(row)

    if len(rows_by_inst) <= 1:
        log_step("split_skipped trace_instance_count={}".format(len(rows_by_inst)))
        return []

    base, ext = os.path.splitext(input_file)
    if not ext:
        ext = ".csv"

    outputs = []
    for inst in sorted(rows_by_inst):
        requested_file = Path("{}__{}{}".format(base, safe_filename(inst), ext))
        output_path = bounded_derived_path(
            Path(base + ext),
            "__",
            inst,
            suffix=ext,
            readable_identity=safe_filename(inst),
        )
        out_file = str(output_path)
        if output_path != requested_file:
            log_step("filename_shortened original={} bounded={} identity={}".format(
                requested_file.name, output_path.name, inst))
        log_step("writing split output: {} rows={} inst={}".format(
            out_file, len(rows_by_inst[inst]), inst))
        with open(out_file, 'w', encoding='utf-8', newline='') as outfile:
            writer = csv.writer(outfile)
            writer.writerow(header)
            writer.writerows(rows_by_inst[inst])
        outputs.append(out_file)

    log_step("split_outputs={}".format(len(outputs)))
    return outputs

def filter_csv_by_keywords(input_file, output_file, keywords):
    log_step("mode=keywords")
    log_step("keywords={}".format(",".join(keywords)))
    matched_count = 0
    total_count = 0

    log_step("opening input CSV: {}".format(input_file))
    log_step("opening output CSV: {}".format(output_file))
    with open(input_file, 'r', encoding='utf-8') as infile, \
         open(output_file, 'w', encoding='utf-8', newline='') as outfile:
        reader = csv.reader(infile)
        writer = csv.writer(outfile)
        header = next(reader)
        log_step("input_header={}".format(",".join(header)))
        writer.writerow(header)
        for row in reader:
            total_count += 1
            if any(keyword in ','.join(row) for keyword in keywords):
                writer.writerow(row)
                matched_count += 1

    log_step("filtered_rows={} total_rows={}".format(matched_count, total_count))
    log_step("output_written={}".format(output_file))

def main():
    if len(sys.argv) < 4:
        print("Usage: python filter_trace.py <input.csv> <output.csv> --instances <instances.txt>")
        print("\nExample:")
        print("  python filter_trace.py trace.csv filtered.csv --instances module_instances.txt")
        sys.exit(1)

    input_file = sys.argv[1]
    requested_output_file = sys.argv[2]
    requested_output_path = Path(requested_output_file)
    output_path = bounded_path(
        requested_output_path,
        suffix=requested_output_path.suffix,
        identity=requested_output_file,
    )
    output_file = str(output_path)
    if output_path != requested_output_path:
        log_step("filename_shortened original={} bounded={} identity={}".format(
            requested_output_path.name,
            output_path.name,
            requested_output_file,
        ))

    log_step("argv={}".format(" ".join(sys.argv)))
    log_step("input_file={}".format(input_file))
    log_step("output_file={}".format(output_file))

    try:
        split_by_trace_instance = False
        args = sys.argv[3:]
        if "--split-by-trace-instance" in args:
            split_by_trace_instance = True
            args.remove("--split-by-trace-instance")
            log_step("option split_by_trace_instance=true")

        normalize_header = False
        if "--normalize-signal-column" in args:
            normalize_header = True
            args.remove("--normalize-signal-column")
            log_step("option normalize_signal_column=true")

        if args[0] == "--instances" and len(args) == 2:
            instance_file = args[1]
            log_step("instance_file={}".format(instance_file))
            filter_csv_by_instances(input_file, output_file, instance_file, normalize_header)
        elif args[0] == "--merge" and len(args) >= 2:
            log_step("merge_inputs={}".format(args[1:]))
            merge_csvs(output_file, args[1:])
        elif args[0] == "--keywords" and len(args) >= 2:
            keywords = args[1:]
            log_step("keywords={}".format(keywords))
            filter_csv_by_keywords(input_file, output_file, keywords)
        else:
            print("Error: expected --instances <instances.txt> or --keywords <keyword...>")
            sys.exit(1)

        if split_by_trace_instance:
            split_csv_by_trace_instance(output_file)
    except FileNotFoundError:
        log_step("ERROR: input file '{}' not found".format(input_file))
        sys.exit(1)
    except Exception as e:
        log_step("ERROR: {}".format(e))
        sys.exit(1)

if __name__ == "__main__":
    main()
