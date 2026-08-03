#!/usr/bin/env python3
"""Public kdebug JSON adapter for the port trace tool.

The rest of this repository consumes stable CSV files.  This module keeps that
contract while moving all design access behind the public kdebug executable.
"""

from __future__ import print_function

import argparse
import csv
import json
import os
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional, Sequence, Tuple


API_VERSION = "kdebug.v1"
TRACE_HEADER = ["inst_full_name", "port_name", "port_dir", "role", "signal_full_name"]
BOUNDARY_HEADER = [
    "inst_full_name",
    "port_name",
    "port_dir",
    "role",
    "module_signal_full_name",
]
PARAM_HEADER = [
    "module",
    "inst_full_name",
    "param_name",
    "param_value",
    "param_kind",
    "param_info",
]
UNKNOWN_ACTION_CODES = {"UNKNOWN_ACTION", "NOT_IMPLEMENTED", "ACTION_NOT_FOUND"}
TIMEOUT_CODES = {
    "ACTION_TIMEOUT",
    "INTERNAL_ENGINE_TIMEOUT",
    "KDEBUG_TIMEOUT",
    "TCL_NPI_TIMEOUT",
    "TIMEOUT",
}
NONFATAL_PORT_TRACE_ERROR_CODES = {
    "CONSTANT_DRIVER_AMBIGUOUS",
    "CONSTANT_DRIVER_CONFLICT",
    "CONSTANT_PROVENANCE_UNVERIFIED",
    "PORT_NOT_FOUND",
    "TRACE_LIMIT_REACHED",
}


class KDebugError(RuntimeError):
    def __init__(self, message: str, code: str = "KDEBUG_ERROR", response: Any = None):
        super().__init__(message)
        self.code = code
        self.response = response


def log_step(message: str) -> None:
    print("[kdebug_backend] {}".format(message), file=sys.stderr, flush=True)


def split_csv_arg(text: Optional[str]) -> List[str]:
    if not text:
        return []
    return [item.strip() for item in text.split(",") if item.strip()]


def unique_csv_arg(text: Optional[str]) -> List[str]:
    return list(dict.fromkeys(split_csv_arg(text)))


def nonnegative_int(text: str) -> int:
    try:
        value = int(text)
    except (TypeError, ValueError):
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    if value < 0:
        raise argparse.ArgumentTypeError("must be a non-negative integer")
    return value


def executable_path(command: str) -> Optional[str]:
    expanded = os.path.abspath(os.path.expanduser(command))
    if os.path.isfile(expanded) and (os.name == "nt" or os.access(expanded, os.X_OK)):
        return expanded
    return shutil.which(command)


def resolve_kdebug(explicit: Optional[str]) -> str:
    configured = explicit or os.environ.get("KDEBUG_BIN")
    if configured:
        resolved = executable_path(configured)
        if not resolved:
            raise KDebugError(
                "configured kdebug is not executable: {}".format(configured),
                "KDEBUG_NOT_FOUND",
            )
        return resolved

    home = os.environ.get("KVERIF_HOME")
    candidates = []
    if home:
        candidates.append(os.path.join(home, "tools", "kdebug"))
    candidates.extend(
        [
            os.path.join(str(Path(__file__).resolve().parent), "tools", "kdebug"),
            "kdebug",
        ]
    )
    for candidate in candidates:
        resolved = executable_path(candidate)
        if resolved:
            return resolved
    raise KDebugError(
        "cannot find kdebug; use --kdebug-bin, KDEBUG_BIN, KVERIF_HOME, or PATH",
        "KDEBUG_NOT_FOUND",
    )


def tool_prefix(path: str) -> List[str]:
    if os.name != "nt":
        return [path]
    try:
        with open(path, "rb") as handle:
            is_script = handle.read(2) == b"#!"
    except OSError:
        is_script = False
    if not is_script:
        return [path]
    bash = os.environ.get("BASH") or shutil.which("bash")
    if not bash:
        raise KDebugError("bash is required to launch the kdebug wrapper on Windows")
    return [bash, path]


def normalize_daidir(lib: Path) -> Path:
    path = lib.expanduser().resolve()
    if not path.exists():
        raise KDebugError("KDB path does not exist: {}".format(path), "KDB_NOT_FOUND")
    if path.name == "kdb.elab++":
        path = path.parent
    elif path.name.endswith(".daidir"):
        pass
    else:
        for parent in [path] + list(path.parents):
            if parent.name.endswith(".daidir"):
                path = parent
                break
        else:
            raise KDebugError(
                "kdebug expects a simv.daidir directory; cannot normalize {}".format(lib),
                "INVALID_KDB_PATH",
            )
    if not path.is_dir():
        raise KDebugError("kdebug daidir is not a directory: {}".format(path))
    return path


def _kill_process_group(proc: subprocess.Popen) -> None:
    if proc.poll() is not None:
        return
    if os.name == "posix":
        try:
            os.killpg(proc.pid, signal.SIGTERM)
        except ProcessLookupError:
            return
        try:
            proc.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            try:
                os.killpg(proc.pid, signal.SIGKILL)
            except ProcessLookupError:
                pass
    else:
        proc.terminate()
        try:
            proc.wait(timeout=2)
            return
        except subprocess.TimeoutExpired:
            proc.kill()
    try:
        proc.wait(timeout=2)
    except subprocess.TimeoutExpired:
        pass


def _response_truncated(response: Dict[str, Any]) -> bool:
    for container_name in ("meta", "summary", "data"):
        container = response.get(container_name)
        if isinstance(container, dict) and container.get("truncated") is True:
            return True
    return False


def is_timeout_code(code: Any) -> bool:
    normalized = str(code or "").strip().upper()
    return normalized in TIMEOUT_CODES or normalized.endswith("_TIMEOUT")


class KDebugClient:
    def __init__(self, binary: str, daidir: Path, timeout_sec: int = 0, debug: bool = False):
        self.binary = binary
        self.daidir = daidir
        self.timeout_sec = timeout_sec
        self.debug = debug

    def request(
        self,
        action: str,
        args: Optional[Dict[str, Any]] = None,
        limits: Optional[Dict[str, Any]] = None,
        allow_truncated: bool = False,
    ) -> Dict[str, Any]:
        request: Dict[str, Any] = {
            "api_version": API_VERSION,
            "action": action,
            "target": {"daidir": str(self.daidir)},
            "args": args or {},
        }
        effective_limits = dict(limits or {})
        if "timeout_ms" not in effective_limits:
            if self.timeout_sec > 0:
                effective_limits["timeout_ms"] = self.timeout_sec * 1000
            else:
                effective_limits["timeout_ms"] = int(
                    os.environ.get("KDEBUG_ACTION_TIMEOUT_MS", "3600000")
                )
        request["limits"] = effective_limits
        command = tool_prefix(self.binary) + ["--json", "-"]
        if self.debug:
            log_step("request action={} args={}".format(action, json.dumps(args or {}, sort_keys=True)))
        proc = subprocess.Popen(
            command,
            stdin=subprocess.PIPE,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            universal_newlines=True,
            start_new_session=(os.name == "posix" and self.timeout_sec > 0),
        )
        payload = json.dumps(request, separators=(",", ":")) + "\n"
        try:
            cleanup_grace = max(
                0.0, float(os.environ.get("KDEBUG_CLIENT_CLEANUP_GRACE_SEC", "5"))
            )
        except ValueError:
            cleanup_grace = 5.0
            log_step("warning invalid KDEBUG_CLIENT_CLEANUP_GRACE_SEC; using 5s")
        communicate_timeout = None
        if self.timeout_sec > 0:
            communicate_timeout = self.timeout_sec + cleanup_grace
        try:
            stdout, stderr = proc.communicate(
                payload,
                timeout=communicate_timeout,
            )
        except subprocess.TimeoutExpired as exc:
            _kill_process_group(proc)
            raise KDebugError(
                "kdebug action {} exceeded the {}s action timeout and {}s cleanup grace".format(
                    action, self.timeout_sec, cleanup_grace
                ),
                "KDEBUG_TIMEOUT",
            ) from exc
        if stderr.strip() and self.debug:
            for line in stderr.rstrip().splitlines():
                log_step("kdebug_stderr {}".format(line))
        response = None
        parse_error = None
        if stdout.strip():
            try:
                response = json.loads(stdout)
            except (TypeError, ValueError) as exc:
                parse_error = exc
        if proc.returncode != 0:
            if isinstance(response, dict) and response.get("ok") is False:
                error = response.get("error") if isinstance(response.get("error"), dict) else {}
                code = str(error.get("code") or "KDEBUG_ACTION_FAILED")
                message = str(error.get("message") or "kdebug action failed")
                raise KDebugError(
                    "{}: {} (kdebug rc={})".format(code, message, proc.returncode),
                    code,
                    response,
                )
            detail = stderr.strip() or stdout.strip()
            raise KDebugError(
                "kdebug action {} exited with rc={}: {}".format(
                    action, proc.returncode, detail[-2000:]
                ),
                "KDEBUG_PROCESS_FAILED",
            )
        if parse_error is not None or response is None:
            raise KDebugError(
                "kdebug action {} returned invalid JSON: {}".format(action, stdout[-2000:]),
                "KDEBUG_INVALID_JSON",
            ) from parse_error
        if not isinstance(response, dict):
            raise KDebugError("kdebug response is not an object", "KDEBUG_INVALID_JSON", response)
        if response.get("api_version") != API_VERSION:
            raise KDebugError(
                "kdebug response api_version mismatch: expected {}, got {}".format(
                    API_VERSION, response.get("api_version")
                ),
                "KDEBUG_PROTOCOL_ERROR",
                response,
            )
        if response.get("ok") is not True:
            error = response.get("error") if isinstance(response.get("error"), dict) else {}
            code = str(error.get("code") or "KDEBUG_ACTION_FAILED")
            message = str(error.get("message") or "kdebug action failed")
            raise KDebugError("{}: {}".format(code, message), code, response)
        if response.get("action") != action:
            raise KDebugError(
                "kdebug response action mismatch: expected {}, got {}".format(
                    action, response.get("action")
                ),
                "KDEBUG_PROTOCOL_ERROR",
                response,
            )
        if _response_truncated(response) and not allow_truncated:
            raise KDebugError(
                "kdebug action {} returned truncated data".format(action),
                "KDEBUG_TRUNCATED",
                response,
            )
        warnings = response.get("warnings")
        if isinstance(warnings, list):
            for warning in warnings:
                log_step("warning action={} detail={}".format(action, warning))
        return response


def response_data(response: Dict[str, Any]) -> Dict[str, Any]:
    data = response.get("data")
    return data if isinstance(data, dict) else {}


def object_data(item: Any) -> Dict[str, Any]:
    if not isinstance(item, dict):
        return {}
    obj = item.get("object")
    return obj if isinstance(obj, dict) else item


def find_instances(client: KDebugClient, definitions: Sequence[str]) -> Dict[str, List[str]]:
    found: Dict[str, List[str]] = {}
    for definition in definitions:
        response = client.request(
            "module.find_instances",
            {"definition": definition},
            {"max_rows": 1000000},
        )
        instances = []
        for item in response_data(response).get("instances", []):
            obj = object_data(item)
            full_name = obj.get("full_name") or obj.get("name")
            if full_name:
                instances.append(str(full_name))
        found[definition] = sorted(set(instances))
        log_step("module={} instances={}".format(definition, len(found[definition])))
    return found


def inspect_instance(client: KDebugClient, instance: str, sections: Sequence[str]) -> Dict[str, Any]:
    response = client.request(
        "module.inspect",
        {"module": instance, "sections": list(sections)},
        {"max_rows": 1000000},
    )
    return response_data(response)


def inspect_many(
    client: KDebugClient, instances: Sequence[str], sections: Sequence[str]
) -> List[Dict[str, Any]]:
    try:
        response = client.request(
            "module.inspect_batch",
            {"modules": list(instances), "sections": list(sections)},
            {"max_rows": 1000000},
        )
        data = response_data(response)
        items = data.get("modules") or data.get("results") or data.get("inspections")
        if not isinstance(items, list):
            raise KDebugError(
                "module.inspect_batch response is missing data.modules[]",
                "KDEBUG_PROTOCOL_ERROR",
                response,
            )
        normalized = []
        for item in items:
            if isinstance(item, dict) and item.get("ok") is False:
                error = item.get("error") if isinstance(item.get("error"), dict) else {}
                raise KDebugError(
                    "module.inspect_batch failed for {}: {}".format(
                        item.get("module", "<unknown>"),
                        error.get("message", "module inspection failed"),
                    ),
                    str(error.get("code") or "MODULE_INSPECT_FAILED"),
                    item,
                )
            if isinstance(item, dict) and isinstance(item.get("data"), dict):
                item = item["data"]
            if isinstance(item, dict):
                normalized.append(item)
        return normalized
    except KDebugError as exc:
        if exc.code not in UNKNOWN_ACTION_CODES:
            raise
        log_step("module.inspect_batch unavailable; falling back to individual module.inspect")
        return [inspect_instance(client, instance, sections) for instance in instances]


def log_field(value: Any) -> str:
    text = str(value if value is not None else "")
    if not text or any(char.isspace() for char in text):
        return "{" + text.replace("}", "\\}") + "}"
    return text


def existing_mode(path: Path) -> Optional[int]:
    try:
        return stat.S_IMODE(path.stat().st_mode)
    except FileNotFoundError:
        return None


def atomic_write_csv(path: Path, header: Sequence[str], rows: Iterable[Sequence[Any]]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = existing_mode(path)
    fd, temp_name = tempfile.mkstemp(dir=str(path.parent), prefix="." + path.name + ".", suffix=".tmp")
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            fd = -1
            writer = csv.writer(handle)
            writer.writerow(header)
            writer.writerows(rows)
        if mode is not None:
            temp_path.chmod(mode)
        os.replace(str(temp_path), str(path))
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass


def _prepare_csv_temp(
    path: Path, header: Sequence[str], rows: Iterable[Sequence[Any]]
) -> Path:
    path.parent.mkdir(parents=True, exist_ok=True)
    mode = existing_mode(path)
    fd, temp_name = tempfile.mkstemp(
        dir=str(path.parent), prefix="." + path.name + ".", suffix=".tmp"
    )
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as handle:
            fd = -1
            writer = csv.writer(handle)
            writer.writerow(header)
            writer.writerows(rows)
        if mode is not None:
            temp_path.chmod(mode)
        return temp_path
    except BaseException:
        if fd >= 0:
            os.close(fd)
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
        raise


def atomic_write_csv_pair(
    first_path: Path,
    first_header: Sequence[str],
    first_rows: Iterable[Sequence[Any]],
    second_path: Path,
    second_header: Sequence[str],
    second_rows: Iterable[Sequence[Any]],
) -> None:
    first_path = first_path.resolve()
    second_path = second_path.resolve()
    if first_path == second_path:
        raise KDebugError(
            "full and boundary CSV outputs must use different paths",
            "OUTPUT_PATH_COLLISION",
        )

    paths = [first_path, second_path]
    staged: List[Path] = []
    try:
        staged.append(_prepare_csv_temp(first_path, first_header, first_rows))
        staged.append(_prepare_csv_temp(second_path, second_header, second_rows))
    except BaseException:
        for temp_path in staged:
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass
        raise
    backups: Dict[Path, Optional[Path]] = {}
    committed: List[Path] = []
    try:
        for path in paths:
            if not path.exists():
                backups[path] = None
                continue
            fd, backup_name = tempfile.mkstemp(
                dir=str(path.parent), prefix="." + path.name + ".", suffix=".rollback"
            )
            os.close(fd)
            backup_path = Path(backup_name)
            try:
                shutil.copy2(str(path), str(backup_path))
            except BaseException:
                try:
                    backup_path.unlink()
                except FileNotFoundError:
                    pass
                raise
            backups[path] = backup_path

        for path, temp_path in zip(paths, staged):
            os.replace(str(temp_path), str(path))
            committed.append(path)
    except BaseException:
        rollback_errors = []
        for path in reversed(committed):
            backup_path = backups.get(path)
            try:
                if backup_path is None:
                    path.unlink()
                else:
                    os.replace(str(backup_path), str(path))
                    backups[path] = None
            except BaseException as rollback_error:
                rollback_errors.append("{}: {}".format(path, rollback_error))
        if rollback_errors:
            raise KDebugError(
                "CSV publish failed and rollback was incomplete: {}".format(
                    "; ".join(rollback_errors)
                ),
                "OUTPUT_ROLLBACK_FAILED",
            )
        raise
    finally:
        for temp_path in staged:
            try:
                temp_path.unlink()
            except FileNotFoundError:
                pass
        for backup_path in backups.values():
            if backup_path is None:
                continue
            try:
                backup_path.unlink()
            except FileNotFoundError:
                pass


def read_instance_file(path_text: str) -> List[str]:
    if not path_text:
        return []
    path = Path(path_text).expanduser().resolve()
    if not path.is_file():
        raise KDebugError(
            "stop-instance file does not exist: {}".format(path),
            "STOP_INSTANCE_FILE_NOT_FOUND",
        )
    instances = []
    with path.open(encoding="utf-8-sig") as handle:
        for line in handle:
            value = line.split("#", 1)[0].strip()
            if value:
                instances.append(value)
    return sorted(set(instances))


def normalize_port_trace_rows(items: Any, surface: str) -> List[List[str]]:
    if not isinstance(items, list):
        raise KDebugError(
            "port.trace_batch response is missing data.{}_rows[]".format(surface),
            "KDEBUG_PROTOCOL_ERROR",
        )
    rows = []
    for index, item in enumerate(items):
        if not isinstance(item, dict):
            raise KDebugError(
                "port.trace_batch {} row {} is not an object".format(surface, index),
                "KDEBUG_PROTOCOL_ERROR",
            )
        instance = item.get("inst_full_name")
        port = item.get("port_name")
        direction = item.get("port_dir")
        role = item.get("role")
        endpoint = item.get("signal_full_name")
        if (
            not isinstance(instance, str)
            or not instance
            or not isinstance(port, str)
            or not port
            or direction not in ("input", "output", "inout", "unknown")
            or role not in ("driver", "load")
            or not isinstance(endpoint, str)
            or not endpoint
        ):
            raise KDebugError(
                "port.trace_batch {} row {} is incomplete".format(surface, index),
                "KDEBUG_PROTOCOL_ERROR",
                item,
            )
        rows.append([instance, port, direction, role, endpoint])
    return rows


def validate_port_trace_constants(
    full_rows: Sequence[Sequence[str]],
    boundary_rows: Sequence[Sequence[str]],
    evidence_items: Any,
) -> None:
    if not isinstance(evidence_items, list):
        raise KDebugError(
            "port.trace_batch response is missing data.evidence[]",
            "KDEBUG_PROTOCOL_ERROR",
        )
    evidence_by_key: Dict[Tuple[str, str, str], List[Dict[str, Any]]] = {}
    for index, item in enumerate(evidence_items):
        if not isinstance(item, dict):
            raise KDebugError(
                "port.trace_batch evidence item {} is not an object".format(index),
                "KDEBUG_PROTOCOL_ERROR",
            )
        value = item.get("value")
        method = item.get("method")
        role = item.get("role")
        port_path = item.get("port_path")
        full_path = item.get("const_full_path")
        effective = item.get("effective")
        constant = item.get("constant")
        provenance = item.get("provenance")
        if (
            item.get("kind") != "constant"
            or not isinstance(value, str)
            or not value.startswith("Const:")
            or not isinstance(method, str)
            or not method
            or role != "driver"
            or not isinstance(port_path, str)
            or not port_path
            or not isinstance(full_path, str)
            or not full_path
            or not isinstance(effective, bool)
            or not isinstance(constant, dict)
            or not isinstance(provenance, dict)
        ):
            raise KDebugError(
                "port.trace_batch evidence item {} is incomplete".format(index),
                "KDEBUG_PROTOCOL_ERROR",
                item,
            )
        path = provenance.get("path")
        source = provenance.get("source")
        if (
            constant.get("value") != value
            or constant.get("effective") is not effective
            or not isinstance(provenance.get("origin"), str)
            or not provenance.get("origin")
            or provenance.get("unconditional") is not effective
            or not isinstance(path, list)
            or len(path) < 2
            or any(not isinstance(node, str) or not node for node in path)
            or path[0] != port_path
            or path[-1] != value
            or "<-".join(path) != full_path
            or not isinstance(source, dict)
        ):
            raise KDebugError(
                "port.trace_batch evidence item {} has inconsistent provenance".format(index),
                "KDEBUG_PROTOCOL_ERROR",
                item,
            )
        if effective:
            key = (port_path, role, value)
            evidence_by_key.setdefault(key, []).append(item)

    final_constants = set()
    for surface, rows in (("full", full_rows), ("boundary", boundary_rows)):
        groups: Dict[Tuple[str, str, str], Dict[str, set]] = {}
        for instance, port, _direction, role, endpoint in rows:
            key = (instance, port, role)
            group = groups.setdefault(key, {"constants": set(), "signals": set()})
            if endpoint.startswith("Const:"):
                group["constants"].add(endpoint)
                final_constants.add(("{}.{}".format(instance, port), role, endpoint))
            elif not endpoint.startswith(("NO_", "TRACE_LIMIT_REACHED:", "TRACE_STOP:")):
                group["signals"].add(endpoint)
        for (instance, port, role), group in groups.items():
            if len(group["constants"]) > 1 or (group["constants"] and group["signals"]):
                raise KDebugError(
                    "port.trace_batch published ambiguous constants on {} surface for {}.{} {}".format(
                        surface, instance, port, role
                    ),
                    "KDEBUG_AMBIGUOUS_CONSTANT",
                )

    for port_path, role, value in sorted(final_constants):
        if role != "driver":
            raise KDebugError(
                "port.trace_batch published a constant {} endpoint for {}".format(
                    role, port_path
                ),
                "KDEBUG_UNVERIFIED_CONSTANT",
            )
        candidates = evidence_by_key.get((port_path, role, value), [])
        if not candidates:
            raise KDebugError(
                "port.trace_batch published {} for {} without effective provenance".format(
                    value, port_path
                ),
                "KDEBUG_UNVERIFIED_CONSTANT",
            )
        evidence = candidates[0]
        full_path = str(evidence.get("const_full_path") or "")
        if not full_path:
            raise KDebugError(
                "port.trace_batch constant evidence has no const_full_path for {}".format(
                    port_path
                ),
                "KDEBUG_UNVERIFIED_CONSTANT",
            )
        provenance = (
            evidence.get("provenance")
            if isinstance(evidence.get("provenance"), dict)
            else {}
        )
        source = (
            provenance.get("source")
            if isinstance(provenance.get("source"), dict)
            else {}
        )
        fields = evidence.get("fields") if isinstance(evidence.get("fields"), dict) else {}
        log_step(
            "const_driver_source_detail method={} value={} evidence_source=kdebug.port.trace_batch "
            "const_full_path={} role={} port_path={} source_file={} source_line={} raw_handle={}".format(
                log_field(evidence.get("method") or provenance.get("origin") or "port_trace"),
                log_field(value),
                log_field(full_path),
                role,
                log_field(port_path),
                log_field(source.get("file") or fields.get("source_file") or ""),
                log_field(source.get("line") or fields.get("source_line") or ""),
                log_field(source.get("raw_handle") or fields.get("source_handle_path") or ""),
            )
        )

    unused_evidence = sorted(set(evidence_by_key) - final_constants)
    if unused_evidence:
        raise KDebugError(
            "port.trace_batch returned effective constant evidence without a published row: {}".format(
                unused_evidence[:3]
            ),
            "KDEBUG_PROTOCOL_ERROR",
        )


def validate_port_trace_errors(errors: Any) -> List[Dict[str, Any]]:
    if not isinstance(errors, list):
        raise KDebugError(
            "port.trace_batch response is missing data.errors[]",
            "KDEBUG_PROTOCOL_ERROR",
        )
    normalized = []
    for index, error in enumerate(errors):
        if (
            not isinstance(error, dict)
            or not isinstance(error.get("scope"), str)
            or not error.get("scope")
            or not isinstance(error.get("code"), str)
            or not error.get("code")
            or not isinstance(error.get("message"), str)
            or not error.get("message")
        ):
            raise KDebugError(
                "port.trace_batch error item {} is incomplete".format(index),
                "KDEBUG_PROTOCOL_ERROR",
                error,
            )
        normalized.append(error)
    return normalized


def run_trace(args: argparse.Namespace) -> int:
    daidir = normalize_daidir(Path(args.lib))
    binary = resolve_kdebug(args.kdebug_bin)
    client = KDebugClient(binary, daidir, args.timeout_sec, bool(args.trace_debug))
    requested_ports = unique_csv_arg(args.ports)
    action_args: Dict[str, Any] = {
        "module": args.module,
        "ports": requested_ports,
        "stop_instances": read_instance_file(args.stop_instance_file),
        "options": {
            "source_fallback": bool(args.source_fallback),
            "include_full": True,
            "include_boundary": True,
            "debug": bool(args.trace_debug),
        },
    }
    if args.source:
        action_args["source"] = str(Path(args.source).expanduser().resolve())
    limits = {
        "max_parent_depth": args.max_parent_depth,
        "max_assign_depth": args.max_assign_depth,
        "max_expr_depth": args.max_expr_depth,
        "max_nodes": args.max_nodes,
        "max_edges": args.max_edges,
        "max_api_results": args.max_api_results,
        "max_rows": args.max_rows,
    }
    response = client.request(
        "port.trace_batch",
        action_args,
        limits,
        allow_truncated=True,
    )
    data = response_data(response)
    response_ports = data.get("requested_ports")
    traced_ports = data.get("traced_ports")
    expected_selection_mode = "explicit" if requested_ports else "all"
    if (
        data.get("module") != args.module
        or response_ports != requested_ports
        or data.get("selection_mode") != expected_selection_mode
        or not isinstance(traced_ports, list)
        or any(not isinstance(port, str) or not port for port in traced_ports)
        or not isinstance(data.get("stats"), dict)
        or not isinstance(data.get("truncated"), bool)
    ):
        raise KDebugError(
            "port.trace_batch response metadata does not match the request",
            "KDEBUG_PROTOCOL_ERROR",
            response,
        )
    errors = validate_port_trace_errors(data.get("errors"))
    fatal_errors = []
    for error in errors:
        code = str(error.get("code") or "PORT_TRACE_ERROR") if isinstance(error, dict) else "PORT_TRACE_ERROR"
        if code in NONFATAL_PORT_TRACE_ERROR_CODES:
            log_step("warning action=port.trace_batch detail={}".format(error))
        else:
            fatal_errors.append(error)
    if fatal_errors:
        raise KDebugError(
            "port.trace_batch reported {} fatal error(s): {}".format(
                len(fatal_errors), fatal_errors[:3]
            ),
            "PORT_TRACE_FAILED",
            response,
        )

    full_rows = normalize_port_trace_rows(data.get("full_rows"), "full")
    boundary_rows = normalize_port_trace_rows(data.get("boundary_rows"), "boundary")
    if requested_ports:
        unexpected_rows = [
            row for row in full_rows + boundary_rows if row[1] not in requested_ports
        ]
        if unexpected_rows:
            raise KDebugError(
                "port.trace_batch returned rows outside the requested port filter",
                "KDEBUG_PROTOCOL_ERROR",
                unexpected_rows[:3],
            )
    if _response_truncated(response):
        endpoints = [row[4] for row in full_rows + boundary_rows]
        if not any(endpoint.startswith("TRACE_LIMIT_REACHED:") for endpoint in endpoints):
            raise KDebugError(
                "port.trace_batch returned truncated data without a limit marker",
                "KDEBUG_TRUNCATED",
                response,
            )
    validate_port_trace_constants(full_rows, boundary_rows, data.get("evidence"))
    atomic_write_csv_pair(
        Path(args.full_out),
        TRACE_HEADER,
        full_rows,
        Path(args.module_out),
        BOUNDARY_HEADER,
        boundary_rows,
    )
    stats = data.get("stats") if isinstance(data.get("stats"), dict) else {}
    log_step(
        "trace_done module={} instances={} ports={} full_rows={} boundary_rows={}".format(
            args.module,
            stats.get("processed_instances", 0),
            len(action_args["ports"]),
            len(full_rows),
            len(boundary_rows),
        )
    )
    return 0


def run_find_instances(args: argparse.Namespace) -> int:
    daidir = normalize_daidir(Path(args.lib))
    client = KDebugClient(resolve_kdebug(args.kdebug_bin), daidir, args.timeout_sec, args.debug)
    definitions = split_csv_arg(args.definitions)
    found = find_instances(client, definitions)
    merged = sorted({instance for instances in found.values() for instance in instances})
    output = Path(args.output)
    output.parent.mkdir(parents=True, exist_ok=True)
    mode = existing_mode(output)
    fd, temp_name = tempfile.mkstemp(dir=str(output.parent), prefix="." + output.name + ".", suffix=".tmp")
    temp_path = Path(temp_name)
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="\n") as handle:
            fd = -1
            for instance in merged:
                handle.write(instance + "\n")
        if mode is not None:
            temp_path.chmod(mode)
        os.replace(str(temp_path), str(output))
    finally:
        if fd >= 0:
            os.close(fd)
        try:
            temp_path.unlink()
        except FileNotFoundError:
            pass
    log_step("find_instances_done definitions={} instances={}".format(len(definitions), len(merged)))
    return 0


def parameter_value(item: Dict[str, Any]) -> str:
    values = item.get("values") if isinstance(item.get("values"), dict) else {}
    for key in ("decompiled", "value", "dec", "hex", "bin", "string", "real"):
        if values.get(key) not in (None, ""):
            return str(values[key])
        if item.get(key) not in (None, ""):
            return str(item[key])
    return "UNKNOWN_VALUE"


def run_find_parameters(args: argparse.Namespace) -> int:
    daidir = normalize_daidir(Path(args.lib))
    client = KDebugClient(resolve_kdebug(args.kdebug_bin), daidir, args.timeout_sec, args.debug)
    definitions = split_csv_arg(args.modules)
    instances_by_module = find_instances(client, definitions)
    owner_by_instance = {
        instance: definition
        for definition, instances in instances_by_module.items()
        for instance in instances
    }
    all_instances = sorted(owner_by_instance)
    inspections = inspect_many(client, all_instances, ["parameters"]) if all_instances else []
    inspected_by_name = {}
    for item in inspections:
        module_name = item.get("module")
        if module_name:
            inspected_by_name[str(module_name)] = item
    rows = []
    for instance in all_instances:
        definition = owner_by_instance[instance]
        rows.append([definition, instance, "", "", "instance", "INSTANCE_INVENTORY"])
        inspected = inspected_by_name.get(instance, {})
        sections = inspected.get("sections") if isinstance(inspected.get("sections"), dict) else {}
        for item in sections.get("parameters", []):
            obj = object_data(item)
            name = str(obj.get("name") or "UNKNOWN_PARAM")
            kind = (
                "localparam"
                if obj.get("localparam")
                or obj.get("local_param")
                or "localparam" in str(obj.get("type", "")).lower()
                else "parameter"
            )
            info = str(obj.get("full_name") or obj.get("type") or "")
            rows.append([definition, instance, name, parameter_value(item), kind, info])
    atomic_write_csv(Path(args.output), PARAM_HEADER, rows)
    log_step(
        "find_parameters_done modules={} instances={} rows={}".format(
            len(definitions), len(all_instances), len(rows)
        )
    )
    return 0


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Adapt public kdebug JSON actions to port-trace CSV contracts")
    # argparse did not support required subparsers until Python 3.7.  Keep the
    # backend runnable on the Python 3.6 installation used by older EDA VMs.
    subparsers = parser.add_subparsers(dest="command")

    trace = subparsers.add_parser("trace")
    trace.add_argument("--lib", required=True)
    trace.add_argument("--module", required=True)
    trace.add_argument("--ports", default="")
    trace.add_argument("--source", "--srcfile", default="")
    trace.add_argument(
        "--source-fallback",
        "--const-source-fallback",
        dest="source_fallback",
        type=int,
        choices=(0, 1),
        default=1,
    )
    trace.add_argument(
        "--max-parent-depth",
        "--const-trace-depth",
        dest="max_parent_depth",
        type=nonnegative_int,
        default=16,
    )
    trace.add_argument(
        "--max-assign-depth",
        "--assign-trace-depth",
        dest="max_assign_depth",
        type=nonnegative_int,
        default=2,
    )
    trace.add_argument(
        "--max-expr-depth",
        "--assign-expr-trace-depth",
        dest="max_expr_depth",
        type=nonnegative_int,
        default=1,
    )
    trace.add_argument(
        "--max-nodes",
        "--load-trace-node-limit",
        dest="max_nodes",
        type=nonnegative_int,
        default=20000,
    )
    trace.add_argument(
        "--max-edges",
        "--load-trace-edge-limit",
        dest="max_edges",
        type=nonnegative_int,
        default=100000,
    )
    trace.add_argument(
        "--max-api-results",
        "--load-trace-api-list-limit",
        dest="max_api_results",
        type=nonnegative_int,
        default=20000,
    )
    trace.add_argument("--max-rows", type=nonnegative_int, default=20000)
    trace.add_argument(
        "--stop-instance-file", "--load-stop-instance-file", default=""
    )
    trace.add_argument("--full-out", required=True)
    trace.add_argument("--module-out", required=True)
    trace.add_argument("--kdebug-bin")
    trace.add_argument("--timeout-sec", type=nonnegative_int, default=0)
    trace.add_argument("--trace-debug", type=int, choices=(0, 1), default=0)
    trace.set_defaults(func=run_trace)

    instances = subparsers.add_parser("find-instances")
    instances.add_argument("--lib", required=True)
    instances.add_argument("--definitions", required=True)
    instances.add_argument("--output", required=True)
    instances.add_argument("--kdebug-bin")
    instances.add_argument("--timeout-sec", type=int, default=0)
    instances.add_argument("--debug", action="store_true")
    instances.set_defaults(func=run_find_instances)

    parameters = subparsers.add_parser("find-parameters")
    parameters.add_argument("--lib", required=True)
    parameters.add_argument("--modules", required=True)
    parameters.add_argument("--output", required=True)
    parameters.add_argument("--kdebug-bin")
    parameters.add_argument("--timeout-sec", type=int, default=0)
    parameters.add_argument("--debug", action="store_true")
    parameters.set_defaults(func=run_find_parameters)
    return parser


def main(argv: Optional[Sequence[str]] = None) -> int:
    parser = build_parser()
    args = parser.parse_args(argv)
    if not args.command:
        parser.error("a command is required")
    if args.timeout_sec < 0:
        parser.error("--timeout-sec must be non-negative")
    return int(args.func(args))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KDebugError as exc:
        log_step("ERROR code={} message={}".format(exc.code, exc))
        raise SystemExit(124 if is_timeout_code(exc.code) else 1)
