"""Shared, scope-aware identity rules for CSV filtering and XLSX annotation.

New traces retain full hierarchy. Legacy shortened endpoints can be resolved
only against the trace row's instance, never against arbitrary keyword suffixes.
"""

import re


def strip_instance_prefix(signal, instance):
    if signal == instance:
        return ""
    if signal.startswith(instance + ".") or signal.startswith(instance + "/"):
        return signal[len(instance) + 1:]
    return None


def is_direct_instance_node(rest):
    if rest is None or rest.startswith("_ExprInst__:"):
        return False
    if "/" in rest:
        return "." not in rest.split("/", 1)[0]
    return "." not in rest or (rest.count(".") == 1 and ":" in re.sub(r"\[[^]]*\]", "", rest))


def candidate_signal_prefixes(signal):
    for match in re.finditer(r"[./]", signal):
        if match.start():
            yield signal[:match.start()]
    if signal:
        yield signal


def is_diagnostic(signal):
    return signal.startswith(("TRACE_LIMIT_REACHED:", "ERROR:", "TRACE_INCOMPLETE:"))


def resolve_legacy_endpoint(signal, trace_instance):
    """Reverse the historical grandparent-prefix elision using row context."""
    if not trace_instance or not signal or signal.startswith("Const:") or is_diagnostic(signal):
        return signal
    parts = trace_instance.split(".")
    if signal == parts[0] or signal.startswith(parts[0] + ".") or signal.startswith(parts[0] + "/"):
        return signal
    prefix = ".".join(parts[:-2])
    return prefix + "." + signal if prefix else signal


class InstanceMatcher:
    def __init__(self, instances, cache_size=200000, legacy_short_names=False):
        self.prefixes = set()
        self.roots = set()
        self.cache = {}
        self.cache_size = max(0, cache_size)
        self.legacy_short_names = legacy_short_names
        for instance in instances:
            self.add_instance(instance)

    def add_instance(self, instance):
        instance = instance.strip().lstrip("\ufeff")
        if instance and instance not in self.prefixes:
            self.prefixes.add(instance)
            self.roots.add(instance.split(".", 1)[0])
            self.cache.clear()

    def belongs(self, signal_name, trace_instance=""):
        if not signal_name or signal_name.startswith("Const:") or is_diagnostic(signal_name):
            return False
        # A fully qualified endpoint can belong to another elaborated top.
        # Never prepend the traced instance's scope to a known top name.
        signal = (signal_name if not self.legacy_short_names or signal_name.split(".", 1)[0] in self.roots
                  else resolve_legacy_endpoint(signal_name, trace_instance))
        cached = self.cache.get(signal)
        if cached is not None:
            return cached
        result = any(
            prefix in self.prefixes and is_direct_instance_node(strip_instance_prefix(signal, prefix))
            for prefix in candidate_signal_prefixes(signal)
        )
        if self.cache_size and len(self.cache) < self.cache_size:
            self.cache[signal] = result
        return result


def signal_belongs_to_instance(signal_name, instances, trace_instance=""):
    return InstanceMatcher(instances, cache_size=0).belongs(signal_name, trace_instance)


def scalar_constant_value(signal):
    """Recognize equivalent scalar 0/1 literals; wider vectors stay distinct."""
    raw = signal[6:] if signal.startswith("Const:") else signal
    raw = raw.strip().lower().replace("_", "")
    if raw in {"'0", "'1", "0", "1"}:
        return raw[-1]
    match = re.fullmatch(r"(?:1)?'s?([bodh])([0-9a-f]+)", raw)
    if match:
        try:
            value = int(match.group(2), {"b": 2, "o": 8, "d": 10, "h": 16}[match.group(1)])
        except ValueError:
            return None
        if value in (0, 1):
            return str(value)
    return None
