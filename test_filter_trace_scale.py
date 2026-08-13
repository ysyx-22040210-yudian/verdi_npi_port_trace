#!/usr/bin/env python3

import csv
import tempfile
import time
import unittest
from pathlib import Path

import filter_trace


def reference_strip_instance_prefix(signal_name, inst):
    if signal_name == inst:
        return ""
    if signal_name.startswith(inst + "."):
        return signal_name[len(inst) + 1:]
    if signal_name.startswith(inst + "/"):
        return signal_name[len(inst) + 1:]
    return None


def reference_is_direct_instance_node(rest):
    if rest is None:
        return False
    if rest == "":
        return True
    if rest.startswith("_ExprInst__:"):
        return False
    if "/" in rest:
        head = rest.split("/", 1)[0]
        return "." not in head
    return rest.count(".") <= 1


def reference_signal_belongs(signal_name, instances):
    if not signal_name or signal_name.startswith("Const:"):
        return False
    if signal_name.startswith("TRACE_LIMIT_REACHED:"):
        return True

    for inst in instances:
        if reference_is_direct_instance_node(
            reference_strip_instance_prefix(signal_name, inst)
        ):
            return True
        parts = inst.split(".")
        for idx in range(1, len(parts)):
            suffix = ".".join(parts[idx:])
            if reference_is_direct_instance_node(
                reference_strip_instance_prefix(signal_name, suffix)
            ):
                return True
    return False


class InstanceMatcherTests(unittest.TestCase):
    def test_error_marker_is_preserved_for_failed_trace_instance(self):
        matcher = filter_trace.InstanceMatcher(["top.u_keyword"])
        self.assertTrue(matcher.belongs("ERROR:INSTANCE_TRACE_FAILED"))

    def test_indexed_matcher_is_equivalent_to_legacy_predicate(self):
        instances = [
            "tb.top.u_keyword",
            "chip.tile_0.core.u_filter",
            "solo",
            "root.gen.block",
            "slash/scope.u_leaf",
        ]
        signals = [
            "",
            "Const:1'b0",
            "TRACE_LIMIT_REACHED:row_limit",
            "tb.top.u_keyword",
            "tb.top.u_keyword.net",
            "tb.top.u_keyword.child.net",
            "tb.top.u_keyword.child.module.net",
            "tb.top.u_keyword/_ExprInst__:17",
            "tb.top.u_keyword/Always0:17.net",
            "tb.top.u_keyword/child.module/net",
            "top.u_keyword.net",
            "u_keyword.net",
            "chip.tile_0.core.u_filter.out",
            "tile_0.core.u_filter.out",
            "core.u_filter.out",
            "u_filter.out",
            "chip.tile_1.core.u_filter.out",
            "solo.value",
            "solo.deep.value.more",
            "root.gen.block/Always1:3.value",
            "slash/scope.u_leaf.value",
            "unrelated.path.signal",
        ]
        for index in range(200):
            signals.extend(
                [
                    "tb.top.noise_{}.signal".format(index),
                    "chip.tile_{}.core.u_noise.signal".format(index),
                    "root.gen.block_{}.child.module.signal".format(index),
                ]
            )

        matcher = filter_trace.InstanceMatcher(instances)
        for signal in signals:
            with self.subTest(signal=signal):
                expected = reference_signal_belongs(signal, instances)
                self.assertEqual(matcher.belongs(signal), expected)
                self.assertEqual(
                    filter_trace.signal_belongs_to_instance(signal, matcher),
                    expected,
                )

    def test_filter_scales_to_50000_instances_and_2000_misses(self):
        instances = [
            "tb.soc.tile_{:05d}.u_keyword".format(index)
            for index in range(50000)
        ]
        misses = [
            "tb.soc.noise_{:05d}.u_other.signal".format(index)
            for index in range(2000)
        ]
        hits = [
            "tb.soc.tile_{:05d}.u_keyword.signal".format(index)
            for index in (0, 25000, 49999)
        ]

        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            instance_file = root / "instances.txt"
            input_csv = root / "trace.csv"
            output_csv = root / "filtered.csv"
            instance_file.write_text("\n".join(instances) + "\n", encoding="utf-8")
            with input_csv.open("w", encoding="utf-8", newline="") as handle:
                writer = csv.writer(handle)
                writer.writerow(
                    ["inst_full_name", "port_name", "port_dir", "role", "signal_full_name"]
                )
                for index, signal in enumerate(misses + hits):
                    writer.writerow(["tb.target", "p{}".format(index), "input", "driver", signal])

            started = time.perf_counter()
            filter_trace.filter_csv_by_instances(
                str(input_csv),
                str(output_csv),
                str(instance_file),
            )
            elapsed = time.perf_counter() - started

            with output_csv.open("r", encoding="utf-8", newline="") as handle:
                rows = list(csv.DictReader(handle))
            self.assertEqual([row["signal_full_name"] for row in rows], hits)
            self.assertEqual(len(instances) * len(misses), 100000000)
            self.assertLess(elapsed, 5.0)


if __name__ == "__main__":
    unittest.main()
