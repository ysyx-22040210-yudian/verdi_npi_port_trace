#!/usr/bin/env python3
from __future__ import print_function

import errno
import json
import math
import os
import re
import shutil
import signal
import socket
import stat
import subprocess
import sys
import tempfile
import time

try:
    import fcntl
except ImportError:  # pragma: no cover - Windows is not a supported runtime for the engine.
    fcntl = None


INTERNAL_API_VERSION = "kdebug.internal.v1"
PUBLIC_API_VERSION = "kdebug.v1"
TOOL_VERSION = "0.1.0-tcl"
FILE_RPC_VERSION = "kdebug-file-rpc-v1"


def home_dir():
    return os.environ.get("HOME") or "/tmp"


def kdebug_home():
    return os.path.join(home_dir(), ".kdebug")


def engine_home():
    return os.path.join(kdebug_home(), "engine")


def sessions_root():
    return os.path.join(engine_home(), "sessions")


def registry_path():
    return os.path.join(engine_home(), "registry.json")


def fnv1a_hex(value):
    h = 1469598103934665603
    for ch in value:
        h ^= ord(ch)
        h = (h * 1099511628211) & 0xFFFFFFFFFFFFFFFF
    return "%016x" % h


def session_dir_name(session_id):
    prefix = session_id[:16]
    safe = []
    for ch in prefix:
        if ch.isalnum() or ch == "_":
            safe.append(ch)
        else:
            safe.append("_")
    if not safe:
        safe = ["adhoc"]
    return "%s_%s" % ("".join(safe), fnv1a_hex(session_id))


def session_dir(session_id):
    return os.path.join(sessions_root(), session_dir_name(session_id))


def socket_path(session_id):
    nominal = os.path.join(session_dir(session_id), "socket")
    if len(nominal) < 104:
        return nominal
    return "/tmp/kdebug-%s-%s.sock" % (os.getuid(), fnv1a_hex(nominal))


def endpoint_path(session_id):
    return os.path.join(session_dir(session_id), "endpoint.json")


def session_json_path(session_id):
    return os.path.join(session_dir(session_id), "session.json")


def mkdir_p(path):
    if path:
        try:
            os.makedirs(path)
        except OSError as exc:
            if exc.errno != errno.EEXIST:
                raise


def atomic_write_json(path, payload):
    mkdir_p(os.path.dirname(path))
    fd, tmp = tempfile.mkstemp(prefix=".tmp.", dir=os.path.dirname(path))
    try:
        with os.fdopen(fd, "w") as fp:
            json.dump(payload, fp, indent=2, sort_keys=True)
            fp.write("\n")
        os.rename(tmp, path)
    finally:
        if os.path.exists(tmp):
            try:
                os.unlink(tmp)
            except OSError:
                pass


def read_json_file(path, default=None):
    try:
        with open(path, "r") as fp:
            return json.load(fp)
    except Exception:
        return default


def now_us():
    return int(time.time() * 1000000)


def current_host_name():
    try:
        return socket.gethostname()
    except Exception:
        return "localhost"


def log_path(session_id, name):
    return os.path.join(session_dir(session_id), "logs", name + ".ndjson")


def append_log(session_id, name, event):
    path = log_path(session_id, name)
    mkdir_p(os.path.dirname(path))
    event.setdefault("ts", time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()))
    event.setdefault("session_id", session_id)
    event.setdefault("pid", os.getpid())
    with open(path, "a") as fp:
        fp.write(json.dumps(event, sort_keys=True) + "\n")


def log_lifecycle(session_id, phase, ok, context=None):
    append_log(session_id, "lifecycle", {
        "layer": "backend",
        "component": "engine",
        "phase": phase,
        "ok": bool(ok),
        "context": context or {},
    })


def env_snapshot(server_args):
    ctx = {
        "hostname": current_host_name(),
        "cwd_path": os.getcwd(),
        "argv_count": 1 + len(server_args),
        "argv0_path": sys.argv[0],
    }
    eda = {}
    if os.environ.get("VERDI_HOME"):
        eda["verdi_home_path"] = os.environ.get("VERDI_HOME")
    if os.environ.get("VCS_HOME"):
        eda["vcs_home_path"] = os.environ.get("VCS_HOME")
    if eda:
        ctx["eda"] = eda
    lsf = {}
    if os.environ.get("LSB_JOBID"):
        lsf["job_id"] = os.environ.get("LSB_JOBID")
    if os.environ.get("LSB_QUEUE"):
        lsf["queue"] = os.environ.get("LSB_QUEUE")
    if lsf:
        ctx["lsf"] = lsf
    if os.environ.get("LD_LIBRARY_PATH"):
        ctx["paths"] = {"ld_library_path_hash": fnv1a_hex(os.environ.get("LD_LIBRARY_PATH"))}
    return ctx


def write_crash_marker(session_id):
    mkdir_p(os.path.dirname(log_path(session_id, "crash_marker")))
    action = os.environ.get("KDEBUG_ENGINE_TEST_CRASH_ACTION", "")
    request_id = os.environ.get("KDEBUG_ENGINE_TEST_CRASH_REQUEST_ID", "")
    sig = signal.SIGABRT
    line = "signal_exit pid=%d session_id=%s" % (os.getpid(), session_id)
    if action:
        line += " current_action=%s" % action
    if request_id:
        line += " request_id=%s" % request_id
    line += " sig=%d\n" % sig
    with open(log_path(session_id, "crash_marker"), "a") as fp:
        fp.write(line)


def valid_session_name(name):
    if not name or len(name) > 64:
        return False
    if not (("A" <= name[0] <= "Z") or ("a" <= name[0] <= "z")):
        return False
    for ch in name:
        if not (ch.isalnum() or ch == "_"):
            return False
    return True


def session_name_rule():
    return ("session name must start with an ASCII letter and contain only "
            "ASCII letters, digits, and underscores, with maximum length 64")


class Registry(object):
    def __init__(self):
        self.path = registry_path()

    def _read_locked(self, fp):
        fp.seek(0)
        text = fp.read()
        if not text.strip():
            return {"version": 1, "sessions": []}
        try:
            root = json.loads(text)
        except Exception:
            root = {"version": 1, "sessions": []}
        if not isinstance(root, dict):
            root = {"version": 1, "sessions": []}
        if not isinstance(root.get("sessions"), list):
            root["sessions"] = []
        root.setdefault("version", 1)
        return root

    def _with_lock(self, mutator=None):
        mkdir_p(engine_home())
        with open(self.path, "a+") as fp:
            if fcntl is not None:
                fcntl.flock(fp.fileno(), fcntl.LOCK_EX)
            root = self._read_locked(fp)
            result = None
            if mutator is not None:
                result = mutator(root)
                fp.seek(0)
                fp.truncate()
                json.dump(root, fp, indent=2, sort_keys=True)
                fp.write("\n")
                fp.flush()
                os.fsync(fp.fileno())
            if fcntl is not None:
                fcntl.flock(fp.fileno(), fcntl.LOCK_UN)
            return result if mutator is not None else root

    def list(self):
        return list(self._with_lock().get("sessions", []))

    def get(self, session_id):
        for item in self.list():
            if item.get("session_id") == session_id:
                return item
        return None

    def upsert(self, record):
        def mutate(root):
            sessions = []
            replaced = False
            for item in root.get("sessions", []):
                if item.get("session_id") == record.get("session_id"):
                    sessions.append(record)
                    replaced = True
                else:
                    sessions.append(item)
            if not replaced:
                sessions.append(record)
            root["sessions"] = sessions
            return True
        return self._with_lock(mutate)

    def remove(self, session_id):
        def mutate(root):
            before = len(root.get("sessions", []))
            root["sessions"] = [s for s in root.get("sessions", []) if s.get("session_id") != session_id]
            return len(root["sessions"]) != before
        return self._with_lock(mutate)


def target_mode(target):
    daidir = target.get("daidir") or target.get("dbdir")
    fsdb = target.get("fsdb")
    if daidir and fsdb:
        return "combined"
    if daidir:
        return "design"
    if fsdb:
        return "waveform"
    return ""


def session_record_json(record):
    mode = target_mode({"daidir": record.get("dbdir_path") or record.get("design_file"),
                        "fsdb": record.get("fsdb_file")})
    out = {
        "id": record.get("session_id", ""),
        "session_id": record.get("session_id", ""),
        "mode": record.get("mode", mode),
        "transport": record.get("transport") or "uds",
    }
    if record.get("dbdir_path"):
        out["daidir"] = record.get("dbdir_path")
    if record.get("fsdb_file"):
        out["fsdb"] = record.get("fsdb_file")
    for key in ("socket_path", "file_dir", "host", "bind_host", "server_host"):
        if record.get(key):
            out[key] = record[key]
    if record.get("port"):
        out["port"] = record["port"]
    return out


def make_public_response(request, action, ok=True, data=None, summary=None, error=None, session=None):
    truncated = False
    if isinstance(data, dict):
        truncated = bool(data.get("truncated", False))
        if isinstance(data.get("summary"), dict):
            truncated = truncated or bool(data["summary"].get("truncated", False))
        if isinstance(data.get("meta"), dict):
            truncated = truncated or bool(data["meta"].get("truncated", False))
    if isinstance(summary, dict):
        truncated = truncated or bool(summary.get("truncated", False))
    response = {
        "api_version": INTERNAL_API_VERSION,
        "ok": bool(ok),
        "action": action,
        "tool": {"name": "kdebug-engine", "version": TOOL_VERSION},
        "session": session,
        "summary": summary or {},
        "data": data if ok else None,
        "findings": [],
        "suggested_next_actions": [],
        "warnings": [],
        "error": None,
        "meta": {"truncated": truncated},
    }
    if request.get("request_id"):
        response["request_id"] = request.get("request_id")
    if not ok:
        response["error"] = error or {
            "code": "ACTION_FAILED",
            "message": "action failed",
            "recoverable": True,
            "candidates": [],
            "suggested_actions": [],
        }
    return response


def make_error_response(request, action, code, message, recoverable=True):
    return make_public_response(request, action, False, error={
        "code": code,
        "message": message,
        "recoverable": recoverable,
        "candidates": [],
        "suggested_actions": [],
    })


def make_action_error_response(request, action, error, recoverable=True):
    payload = {
        "code": error.get("code", "ACTION_FAILED"),
        "message": error.get("message", "action failed"),
        "recoverable": recoverable,
        "candidates": error.get("candidates", []),
        "suggested_actions": error.get("suggested_actions", []),
    }
    details = {k: v for k, v in error.items()
               if k not in {"code", "message", "recoverable", "candidates", "suggested_actions"}}
    if details:
        payload["details"] = details
    response = make_public_response(request, action, False, error=payload)
    response["details"] = {"error": payload}
    return response


def internal_ok(data=None):
    return {"api_version": INTERNAL_API_VERSION, "ok": True, "data": data or {}, "error": None}


def internal_error(code, message, details=None):
    response = {
        "api_version": INTERNAL_API_VERSION,
        "ok": False,
        "status": "server_error",
        "data": None,
        "error": {"code": code, "message": message},
    }
    if details:
        response["details"] = details
    return response


def parse_json_stdin():
    text = sys.stdin.read()
    try:
        req = json.loads(text)
    except Exception as exc:
        return None, str(exc)
    if not isinstance(req, dict):
        return None, "request must be a JSON object"
    return req, None


def script_dir():
    return os.path.dirname(os.path.abspath(__file__))


def tcl_script_path():
    return os.path.join(script_dir(), "kdebug_npi.tcl")


def find_verdi():
    verdi_home = os.environ.get("VERDI_HOME")
    if verdi_home:
        candidate = os.path.join(verdi_home, "bin", "verdi")
        if os.path.exists(candidate):
            return candidate
    return shutil.which("verdi")


def parse_timeout_ms(request, default_ms):
    limits = request.get("limits") if isinstance(request.get("limits"), dict) else {}
    try:
        value = int(limits.get("timeout_ms", 0))
    except Exception:
        value = 0
    return value if value > 0 else default_ms


def classify_verdi_no_response(stdout, stderr, exit_code):
    text = ((stdout or "") + "\n" + (stderr or "")).lower()
    if "not generated with the -kdb option" in text:
        return {
            "code": "KDB_REQUIRED",
            "message": "Verdi design queries require simv.daidir or kdb.elab++ generated with VCS -kdb",
            "exit_code": exit_code,
            "stdout": (stdout or "")[-4000:],
            "stderr": (stderr or "")[-4000:],
        }
    access_text = "\n".join(line for line in text.splitlines() if "novas.conf" not in line)
    if "cannot open" in access_text and "read access" in access_text:
        return {
            "code": "DESIGN_DB_ACCESS_FAILED",
            "message": "Verdi could not read one or more design database files",
            "exit_code": exit_code,
            "stdout": (stdout or "")[-4000:],
            "stderr": (stderr or "")[-4000:],
        }
    return {
        "code": "TCL_NPI_NO_RESPONSE",
        "message": "Verdi Tcl action did not produce a valid JSON response",
        "exit_code": exit_code,
        "stdout": (stdout or "")[-4000:],
        "stderr": (stderr or "")[-4000:],
    }


def classify_verdi_license_error(stdout, stderr, exit_code):
    text = (stdout or "") + "\n" + (stderr or "")
    lowered = text.lower()
    markers = (
        "failed to check out features",
        "failed to obtain license",
        "does not exist in the license file",
        "licensed number of users already reached",
    )
    if not any(marker in lowered for marker in markers):
        return None
    match = re.search(r"failed to check out features?\s+([^,\n]+)", text, re.IGNORECASE)
    feature = match.group(1).strip() if match else ""
    message = "required Synopsys license feature is unavailable"
    if feature:
        message += ": %s" % feature
    return {
        "code": "LICENSE_UNAVAILABLE",
        "message": message,
        "feature": feature,
        "exit_code": exit_code,
        "stdout": (stdout or "")[-4000:],
        "stderr": (stderr or "")[-4000:],
    }


STANDALONE_TCL_ACTIONS = {
    "npi.capabilities",
    "vcs.summary",
    "crdb.resolve",
    "crdb.correlates",
    "transaction.writer.create",
    "fsdb.writer.create_scope",
}


class DesignDatabaseError(ValueError):
    def __init__(self, code, message):
        ValueError.__init__(self, message)
        self.code = code


def resolve_design_database(target):
    value = target.get("daidir") or target.get("dbdir")
    path = normalized_path(value)
    if not path:
        return {"kind": "", "path": ""}

    normalized = os.path.normpath(path)
    resolved = os.path.realpath(normalized) if os.path.lexists(normalized) else normalized
    is_elab = (os.path.basename(normalized).endswith(".elab++") or
               os.path.basename(resolved).endswith(".elab++"))
    if not is_elab:
        return {"kind": "daidir", "path": normalized}

    try:
        path_stat = os.stat(normalized)
    except OSError as exc:
        if exc.errno in (errno.ENOENT, errno.ENOTDIR):
            raise DesignDatabaseError(
                "KDB_NOT_FOUND", "kdb.elab++ path does not exist: %s" % normalized)
        raise DesignDatabaseError(
            "DESIGN_DB_ACCESS_FAILED", "cannot access kdb.elab++ path %s: %s" %
            (normalized, exc))
    if not stat.S_ISDIR(path_stat.st_mode):
        raise DesignDatabaseError(
            "INVALID_KDB_PATH", "kdb.elab++ must be a directory: %s" % normalized)
    try:
        with os.scandir(normalized) as entries:
            next(entries)
    except StopIteration:
        raise DesignDatabaseError(
            "INVALID_KDB_PATH", "kdb.elab++ directory is empty: %s" % normalized)
    except OSError as exc:
        raise DesignDatabaseError(
            "DESIGN_DB_ACCESS_FAILED", "cannot read kdb.elab++ directory %s: %s" %
            (normalized, exc))
    # Verdi 2018 can silently import no design objects when debImport receives a
    # symlink whose basename does not retain the .elab++ suffix.  Canonicalize
    # only after validating the user-facing path so native import sees the real
    # database directory and vcs.summary derives the real .daidir parent.
    return {"kind": "elab", "path": resolved}


def vcs_database_path(design_database):
    path = design_database.get("path", "")
    if design_database.get("kind") == "elab":
        return os.path.dirname(path)
    return path


def design_args_for_target(target, action=""):
    args = []
    if action in STANDALONE_TCL_ACTIONS:
        return args
    filelist = normalized_path(target.get("filelist"))
    if filelist:
        if not os.path.isfile(filelist):
            raise ValueError("target.filelist does not exist: %s" % filelist)
        defines = target.get("defines", [])
        if isinstance(defines, str):
            defines = [defines]
        if not isinstance(defines, list) or any(
            not isinstance(item, str) or not item for item in defines
        ):
            raise ValueError("target.defines must be a string or an array of non-empty strings")
        args.extend("+define+%s" % item for item in defines)
        args.extend(["-sv", "-f", filelist])
        upf = normalized_path(target.get("upf"))
        if upf:
            if not os.path.isfile(upf):
                raise ValueError("target.upf does not exist: %s" % upf)
            upf_version = str(target.get("upf_version", "2.0"))
            if upf_version not in ("1.0", "2.0"):
                raise ValueError("target.upf_version must be 1.0 or 2.0")
            args.extend(["-upf2.0" if upf_version == "2.0" else "-upf", upf])
        top = target.get("top")
        if top:
            args.extend(["-top", str(top)])
        return args
    design_database = resolve_design_database(target)
    daidir = design_database.get("path")
    fsdb = target.get("fsdb")
    if daidir and design_database.get("kind") != "elab":
        args.extend(["-dbdir", daidir])
    if fsdb and daidir:
        args.extend(["-ssf", fsdb])
    return args


def design_workdir_for_target(target, action, fallback):
    if action in STANDALONE_TCL_ACTIONS or not target.get("filelist"):
        return fallback
    workdir = normalized_path(target.get("workdir"))
    if not workdir:
        workdir = os.path.dirname(normalized_path(target.get("filelist")))
    if not os.path.isdir(workdir):
        raise ValueError("target.workdir does not exist: %s" % workdir)
    return workdir


def bool_arg(value):
    if isinstance(value, bool):
        return value
    return str(value).strip().lower() in ("1", "true", "yes", "on")


def normalized_path(value):
    if value is None or str(value) == "":
        return ""
    return os.path.abspath(os.path.expanduser(str(value)))


def integer_arg(value, name, minimum=None):
    if isinstance(value, bool):
        raise ValueError("args.%s must be an integer" % name)
    try:
        number = int(value)
    except (TypeError, ValueError):
        raise ValueError("args.%s must be an integer" % name)
    if str(value).strip() != str(number):
        raise ValueError("args.%s must be an integer" % name)
    if minimum is not None and number < minimum:
        raise ValueError("args.%s must be >= %d" % (name, minimum))
    return number


def hex_plan_field(value):
    if value is None or str(value) == "":
        return "-"
    return str(value).encode("utf-8").hex()


def write_tsv_plan(path, rows):
    with open(path, "w", encoding="utf-8", newline="\n") as fp:
        for row in rows:
            fp.write("\t".join(str(field) for field in row))
            fp.write("\n")


def prepare_transaction_plans(args, tmpdir):
    transactions = args.get("transactions")
    if not isinstance(transactions, list) or not transactions:
        raise ValueError("args.transactions must be a non-empty array")
    transaction_rows = []
    tag_rows = []
    for index, item in enumerate(transactions):
        if not isinstance(item, dict):
            raise ValueError("args.transactions[%d] must be an object" % index)
        start_delta = integer_arg(item.get("start_delta", 0), "transactions[%d].start_delta" % index, 0)
        duration = integer_arg(item.get("duration"), "transactions[%d].duration" % index, 1)
        transaction_type = str(item.get("type", "npiFsdbwTransTransaction"))
        if not re.match(r"^npiFsdbwTrans[A-Za-z0-9_]+$", transaction_type):
            raise ValueError("args.transactions[%d].type must be an npiFsdbwTrans* enum" % index)
        transaction_rows.append((start_delta, duration, transaction_type,
                                 hex_plan_field(item.get("label", ""))))
        tags = item.get("tags", [])
        if isinstance(tags, str):
            tags = [tags]
        if not isinstance(tags, list):
            raise ValueError("args.transactions[%d].tags must be an array" % index)
        for tag in tags:
            if not isinstance(tag, str) or not tag:
                raise ValueError("transaction tags must be non-empty strings")
            tag_rows.append((index, hex_plan_field(tag)))

    relations = args.get("relations", [])
    if not isinstance(relations, list):
        raise ValueError("args.relations must be an array")
    relation_rows = []
    for index, item in enumerate(relations):
        if not isinstance(item, dict):
            raise ValueError("args.relations[%d] must be an object" % index)
        relation = item.get("relation", item.get("type", ""))
        if not isinstance(relation, str) or not relation:
            raise ValueError("args.relations[%d].relation is required" % index)
        master = integer_arg(item.get("master"), "relations[%d].master" % index, 0)
        slave = integer_arg(item.get("slave"), "relations[%d].slave" % index, 0)
        if master >= len(transactions) or slave >= len(transactions) or master == slave:
            raise ValueError("args.relations[%d] indexes must select two different transactions" % index)
        relation_rows.append((hex_plan_field(relation), master, slave))

    transaction_path = os.path.join(tmpdir, "transactions.tsv")
    write_tsv_plan(transaction_path, transaction_rows)
    tag_path = ""
    if tag_rows:
        tag_path = os.path.join(tmpdir, "transaction-tags.tsv")
        write_tsv_plan(tag_path, tag_rows)
    relation_path = ""
    if relation_rows:
        relation_path = os.path.join(tmpdir, "transaction-relations.tsv")
        write_tsv_plan(relation_path, relation_rows)
    return transaction_path, tag_path, relation_path


def prepare_scope_plan(args, tmpdir):
    operations = args.get("operations")
    if operations is None:
        scopes = args.get("scopes")
        if not isinstance(scopes, list):
            raise ValueError("args.operations or args.scopes must be an array")
        operations = [dict(scope, op="scope") if isinstance(scope, dict) else scope for scope in scopes]
    if not isinstance(operations, list) or not operations:
        raise ValueError("args.operations or args.scopes must be a non-empty array")
    rows = []
    depth = 0
    scope_count = 0
    for index, item in enumerate(operations):
        if not isinstance(item, dict):
            raise ValueError("FSDB hierarchy operation %d must be an object" % index)
        op = str(item.get("op", "scope"))
        if op == "up":
            if depth <= 0:
                raise ValueError("FSDB hierarchy operation %d moves above the root" % index)
            rows.append(("up", "-", "-", "-"))
            depth -= 1
            continue
        if op != "scope":
            raise ValueError("FSDB hierarchy operation %d has unsupported op: %s" % (index, op))
        object_type = str(item.get("type", "npiFsdbScopeSvModule"))
        name = item.get("name", "")
        if not re.match(r"^npiFsdbScope[A-Za-z0-9_]+$", object_type):
            raise ValueError("FSDB hierarchy operation %d type must be an npiFsdbScope* enum" % index)
        if not isinstance(name, str) or not name:
            raise ValueError("FSDB hierarchy operation %d name is required" % index)
        rows.append(("scope", object_type, hex_plan_field(name),
                     hex_plan_field(item.get("def_name", ""))))
        depth += 1
        scope_count += 1
    if scope_count == 0:
        raise ValueError("FSDB hierarchy plan must create at least one scope")
    path = os.path.join(tmpdir, "fsdb-hierarchy.tsv")
    write_tsv_plan(path, rows)
    return path


def prepare_string_batch_plan(args, field, tmpdir, filename):
    values = args.get(field)
    if not isinstance(values, list) or not values:
        raise ValueError("args.%s must be a non-empty array" % field)
    rows = []
    for index, value in enumerate(values):
        if not isinstance(value, str) or not value:
            raise ValueError("args.%s[%d] must be a non-empty string" % (field, index))
        rows.append((hex_plan_field(value),))
    path = os.path.join(tmpdir, filename)
    write_tsv_plan(path, rows)
    return path


def prepare_optional_string_plan(args, field, tmpdir, filename):
    values = args.get(field, [])
    if not isinstance(values, list):
        raise ValueError("args.%s must be an array" % field)
    rows = []
    for index, value in enumerate(values):
        if not isinstance(value, str) or not value:
            raise ValueError("args.%s[%d] must be a non-empty string" % (field, index))
        rows.append((hex_plan_field(value),))
    path = os.path.join(tmpdir, filename)
    write_tsv_plan(path, rows)
    return path


def strict_bool_option(options, name, default):
    if name not in options:
        return default
    value = options.get(name)
    if not isinstance(value, bool):
        raise ValueError("args.options.%s must be a boolean" % name)
    return value


def nonnegative_limit(limits, name, default):
    if name not in limits:
        return default
    value = limits.get(name)
    if isinstance(value, bool) or not isinstance(value, int):
        raise ValueError("limits.%s must be an integer" % name)
    if value < 0:
        raise ValueError("limits.%s must be >= 0" % name)
    return value


def prepare_port_trace_environment(args, limits, target, tmpdir):
    module = args.get("module")
    if not isinstance(module, str) or not module:
        raise ValueError("args.module must be a non-empty string")
    daidir = target.get("daidir") or target.get("dbdir")
    if not isinstance(daidir, str) or not daidir:
        raise ValueError("target.daidir is required for port.trace_batch")

    supported_args = {"module", "ports", "source", "stop_instances", "options"}
    unknown_args = sorted(set(args) - supported_args)
    if unknown_args:
        raise ValueError("unsupported args field: %s" % unknown_args[0])
    ports = args.get("ports", [])
    if not isinstance(ports, list):
        raise ValueError("args.ports must be an array")
    if len(ports) > 4096:
        raise ValueError("args.ports must contain at most 4096 items")
    port_pattern = re.compile(r"^[A-Za-z_][A-Za-z0-9_$]*(\[[0-9]+(:[0-9]+)?\])?$")
    for index, port in enumerate(ports):
        if not isinstance(port, str) or not port_pattern.match(port):
            raise ValueError("args.ports[%d] is not a valid port or bit-select" % index)
    if len(set(ports)) != len(ports):
        raise ValueError("args.ports must not contain duplicates")

    stop_instances = args.get("stop_instances", [])
    if not isinstance(stop_instances, list):
        raise ValueError("args.stop_instances must be an array")
    if len(stop_instances) > 4096:
        raise ValueError("args.stop_instances must contain at most 4096 items")
    for index, instance in enumerate(stop_instances):
        if not isinstance(instance, str) or not instance:
            raise ValueError("args.stop_instances[%d] must be a non-empty string" % index)
    if len(set(stop_instances)) != len(stop_instances):
        raise ValueError("args.stop_instances must not contain duplicates")

    options = args.get("options", {})
    if not isinstance(options, dict):
        raise ValueError("args.options must be an object")
    supported_options = {
        "source_fallback", "include_full", "include_boundary", "debug"
    }
    unknown_options = sorted(set(options) - supported_options)
    if unknown_options:
        raise ValueError("unsupported args.options field: %s" % unknown_options[0])
    source_fallback = strict_bool_option(options, "source_fallback", True)
    include_full = strict_bool_option(options, "include_full", True)
    include_boundary = strict_bool_option(options, "include_boundary", True)
    debug_enabled = strict_bool_option(options, "debug", False)
    if not include_full and not include_boundary:
        raise ValueError("args.options must enable include_full or include_boundary")

    source = args.get("source", "")
    if not isinstance(source, str):
        raise ValueError("args.source must be a string")
    source = normalized_path(source)
    if source and not os.path.isfile(source):
        raise ValueError("args.source does not exist: %s" % source)

    supported_limits = {
        "timeout_ms", "max_parent_depth", "max_assign_depth", "max_expr_depth",
        "max_nodes", "max_edges", "max_api_results", "max_rows"
    }
    unknown_limits = sorted(set(limits) - supported_limits)
    if unknown_limits:
        raise ValueError("unsupported limits field: %s" % unknown_limits[0])
    if "timeout_ms" in limits:
        timeout_ms = nonnegative_limit(limits, "timeout_ms", 0)
        if timeout_ms == 0:
            raise ValueError("limits.timeout_ms must be >= 1")

    port_plan = prepare_optional_string_plan(args, "ports", tmpdir, "port-trace-ports.tsv")
    stop_plan = prepare_optional_string_plan(
        args, "stop_instances", tmpdir, "port-trace-stop-instances.tsv")
    return {
        "KDEBUG_TCL_MODULE": module,
        "KDEBUG_TCL_PORT_PLAN": port_plan,
        "KDEBUG_TCL_STOP_INSTANCE_PLAN": stop_plan,
        "KDEBUG_TCL_SOURCE": source,
        "KDEBUG_TCL_SOURCE_FALLBACK": "1" if source_fallback else "0",
        "KDEBUG_TCL_INCLUDE_FULL": "1" if include_full else "0",
        "KDEBUG_TCL_INCLUDE_BOUNDARY": "1" if include_boundary else "0",
        "KDEBUG_TCL_TRACE_DEBUG": "1" if debug_enabled else "0",
        "KDEBUG_TCL_MAX_PARENT_DEPTH": str(nonnegative_limit(
            limits, "max_parent_depth", 16)),
        "KDEBUG_TCL_MAX_ASSIGN_DEPTH": str(nonnegative_limit(
            limits, "max_assign_depth", 2)),
        "KDEBUG_TCL_MAX_EXPR_DEPTH": str(nonnegative_limit(
            limits, "max_expr_depth", 1)),
        "KDEBUG_TCL_MAX_NODES": str(nonnegative_limit(limits, "max_nodes", 20000)),
        "KDEBUG_TCL_MAX_EDGES": str(nonnegative_limit(limits, "max_edges", 100000)),
        "KDEBUG_TCL_MAX_API_RESULTS": str(nonnegative_limit(
            limits, "max_api_results", 20000)),
        "KDEBUG_TCL_MAX_ROWS": str(nonnegative_limit(limits, "max_rows", 20000)),
    }


def cleanup_tcl_tmp(tmpdir):
    if not os.environ.get("KDEBUG_KEEP_TCL_TMP"):
        shutil.rmtree(tmpdir, ignore_errors=True)


def process_ids_with_run_token(run_token):
    if not run_token or not sys.platform.startswith("linux") or not os.path.isdir("/proc"):
        return []
    marker = ("KDEBUG_RUN_TOKEN=" + run_token).encode("utf-8")
    result = []
    try:
        entries = os.listdir("/proc")
    except OSError:
        return result
    for entry in entries:
        if not entry.isdigit():
            continue
        pid = int(entry)
        if pid == os.getpid():
            continue
        try:
            with open(os.path.join("/proc", entry, "environ"), "rb") as fp:
                environment = fp.read()
        except (IOError, OSError):
            continue
        if marker in environment.split(b"\0"):
            result.append(pid)
    return result


def signal_run_token_processes(run_token, signum):
    signaled = []
    for pid in process_ids_with_run_token(run_token):
        try:
            os.kill(pid, signum)
            signaled.append(pid)
        except OSError:
            pass
    return signaled


def signal_process_group(proc, signum):
    pid = getattr(proc, "pid", None)
    if pid is None or not hasattr(os, "killpg"):
        return False
    try:
        os.killpg(pid, signum)
        return True
    except OSError:
        return False


def cleanup_run_token_orphans(run_token, grace_seconds=0.5):
    pids = signal_run_token_processes(run_token, signal.SIGTERM)
    if not pids:
        return
    deadline = time.time() + max(0.0, grace_seconds)
    while time.time() < deadline:
        if not process_ids_with_run_token(run_token):
            return
        time.sleep(0.05)
    signal_run_token_processes(run_token, signal.SIGKILL)
    deadline = time.time() + max(0.0, grace_seconds)
    while time.time() < deadline and process_ids_with_run_token(run_token):
        time.sleep(0.05)


def terminate_tcl_process_run(proc, run_token, grace_seconds=2.0):
    signal_process_group(proc, signal.SIGTERM)
    try:
        proc.terminate()
    except (AttributeError, OSError):
        pass
    signal_run_token_processes(run_token, signal.SIGTERM)
    try:
        stdout, stderr = proc.communicate(timeout=max(0.1, grace_seconds))
    except subprocess.TimeoutExpired as exc:
        signal_process_group(proc, signal.SIGKILL)
        try:
            proc.kill()
        except (AttributeError, OSError):
            pass
        signal_run_token_processes(run_token, signal.SIGKILL)
        try:
            stdout, stderr = proc.communicate(timeout=1.0)
        except subprocess.TimeoutExpired as final_exc:
            stdout = final_exc.stdout or exc.stdout or ""
            stderr = final_exc.stderr or exc.stderr or ""
    cleanup_run_token_orphans(run_token, grace_seconds=0.5)
    return stdout or "", stderr or ""


def run_tcl_npi(request, state):
    action = request.get("action", "")
    target = {}
    target.update(state.get("target", {}))
    if isinstance(request.get("target"), dict):
        target.update(request.get("target"))
    args = request.get("args") if isinstance(request.get("args"), dict) else {}

    database_override = normalized_path(args.get("database"))
    design_database = {"kind": "", "path": ""}
    resolve_target_database = (
        (action == "vcs.summary" and not database_override) or
        (action not in STANDALONE_TCL_ACTIONS and not target.get("filelist"))
    )
    if resolve_target_database:
        try:
            design_database = resolve_design_database(target)
        except DesignDatabaseError as exc:
            return False, {"code": exc.code, "message": str(exc)}

    verdi = find_verdi()
    if not verdi:
        return False, {"code": "VERDI_NOT_FOUND", "message": "verdi is not in PATH; set VERDI_HOME"}

    tmpdir = tempfile.mkdtemp(prefix="kdebug-tcl-npi-")
    req_path = os.path.join(tmpdir, "request.json")
    rsp_path = os.path.join(tmpdir, "response.json")
    with open(req_path, "w") as fp:
        json.dump(request, fp)

    env = dict(os.environ)
    # This is an internal per-request selector.  Never inherit a stale value
    # into a daidir, filelist, or standalone action.
    env.pop("KDEBUG_TCL_ELAB", None)
    env["KDEBUG_TCL_REQUEST_JSON"] = req_path
    env["KDEBUG_TCL_RESPONSE_JSON"] = rsp_path
    env["KDEBUG_TCL_ACTION"] = action
    run_token = "%s:%s" % (tmpdir, fnv1a_hex("%s:%s" % (os.getpid(), time.time())))
    env["KDEBUG_RUN_TOKEN"] = run_token
    if target.get("fsdb"):
        env["KDEBUG_TCL_FSDB"] = str(target.get("fsdb"))
    if args.get("signal"):
        env["KDEBUG_TCL_SIGNAL"] = str(args.get("signal"))
    if args.get("path"):
        env["KDEBUG_TCL_SCOPE"] = str(args.get("path"))
    elif args.get("scope"):
        env["KDEBUG_TCL_SCOPE"] = str(args.get("scope"))
    env["KDEBUG_TCL_TIME"] = str(args.get("time", args.get("at", args.get("requested_time", ""))))
    env["KDEBUG_TCL_FORMAT"] = str(args.get("format", "hex"))
    tr = args.get("time_range") if isinstance(args.get("time_range"), dict) else {}
    env["KDEBUG_TCL_BEGIN"] = str(args.get("begin", args.get("start", tr.get("begin", tr.get("start", "")))))
    env["KDEBUG_TCL_END"] = str(args.get("end", args.get("stop", tr.get("end", tr.get("stop", "")))))
    if action == "trace.query":
        env["KDEBUG_TCL_TRACE_MODE"] = str(args.get("mode", "driver"))
    if action == "trace.load":
        env["KDEBUG_TCL_TRACE_MODE"] = "load"
    if action == "trace.driver":
        env["KDEBUG_TCL_TRACE_MODE"] = "driver"
    signals = args.get("signals")
    if isinstance(signals, list):
        env["KDEBUG_TCL_SIGNALS"] = "\n".join([str(s) for s in signals])
    limits = request.get("limits") if isinstance(request.get("limits"), dict) else {}
    env["KDEBUG_TCL_MAX_ROWS"] = str(limits.get("max_rows", limits.get("max_results", 200)))
    env["KDEBUG_TCL_MAX_DEPTH"] = str(args.get("max_depth", limits.get("max_depth", 3)))
    env["KDEBUG_TCL_NAME"] = str(args.get("name", ""))
    env["KDEBUG_TCL_OBJECT_TYPE"] = str(args.get("object_type", ""))
    env["KDEBUG_TCL_RELATION_TYPE"] = str(args.get("relation_type", ""))
    env["KDEBUG_TCL_VALUE_FORMAT"] = str(args.get("format", ""))
    env["KDEBUG_TCL_KIND"] = str(args.get("kind", ""))
    env["KDEBUG_TCL_DEFINITION"] = str(args.get("definition", ""))
    sections = args.get("sections", [])
    if isinstance(sections, list):
        env["KDEBUG_TCL_SECTIONS"] = "\n".join(str(item) for item in sections)
    env["KDEBUG_TCL_FILE"] = str(args.get("file", ""))
    env["KDEBUG_TCL_LINE"] = str(args.get("line", ""))
    env["KDEBUG_TCL_CONTENT"] = str(args.get("content", ""))
    env["KDEBUG_TCL_OUTPUT"] = normalized_path(args.get("output", ""))
    env["KDEBUG_TCL_OUTPUT_DIR"] = normalized_path(args.get("output_dir", ""))
    env["KDEBUG_TCL_OVERWRITE"] = "1" if bool_arg(args.get("overwrite", False)) else "0"
    database = database_override
    if not database:
        database = vcs_database_path(design_database)
    env["KDEBUG_TCL_DATABASE"] = database
    if design_database.get("kind") == "elab" and action not in STANDALONE_TCL_ACTIONS:
        env["KDEBUG_TCL_ELAB"] = design_database.get("path")
    env["KDEBUG_TCL_CRDB"] = normalized_path(args.get("crdb", ""))
    env["KDEBUG_TCL_LEVEL"] = str(args.get("level", "RTL"))
    env["KDEBUG_TCL_MODULE"] = str(args.get("module", ""))
    env["KDEBUG_TCL_NEW_NAME"] = str(args.get("new_name", ""))
    env["KDEBUG_TCL_NET_TYPE"] = str(args.get("net_type", "npiDmNetWire"))
    env["KDEBUG_TCL_PACKED_LEFT"] = str(args.get("packed_left", ""))
    env["KDEBUG_TCL_PACKED_RIGHT"] = str(args.get("packed_right", ""))
    env["KDEBUG_TCL_UNIT"] = str(args.get("unit", "1ns"))
    env["KDEBUG_TCL_BEGIN_TIME"] = str(args.get("begin_time", 0))
    env["KDEBUG_TCL_END_TIME_DELTA"] = str(args.get("end_time_delta", 0))
    env["KDEBUG_TCL_STREAM"] = str(args.get("stream", ""))
    try:
        if action == "port.trace_batch":
            env.update(prepare_port_trace_environment(args, limits, target, tmpdir))
        elif action == "module.inspect_batch":
            env["KDEBUG_TCL_BATCH_PLAN"] = prepare_string_batch_plan(
                args, "modules", tmpdir, "inspect-modules.tsv")
        elif action == "transaction.writer.create":
            transaction_plan, tag_plan, relation_plan = prepare_transaction_plans(args, tmpdir)
            env["KDEBUG_TCL_TRANSACTION_PLAN"] = transaction_plan
            env["KDEBUG_TCL_TAG_PLAN"] = tag_plan
            env["KDEBUG_TCL_RELATION_PLAN"] = relation_plan
        elif action == "fsdb.writer.create_scope":
            env["KDEBUG_TCL_OPERATION_PLAN"] = prepare_scope_plan(args, tmpdir)
    except DesignDatabaseError as exc:
        cleanup_tcl_tmp(tmpdir)
        return False, {"code": exc.code, "message": str(exc)}
    except ValueError as exc:
        cleanup_tcl_tmp(tmpdir)
        return False, {"code": "INVALID_ARGUMENT", "message": str(exc)}
    if os.environ.get("VERDI_HOME") and not os.environ.get("NPIL1_PATH"):
        env["NPIL1_PATH"] = os.path.join(os.environ["VERDI_HOME"], "share", "NPI", "L1", "TCL")

    try:
        design_cli_args = design_args_for_target(target, action)
        verdi_cwd = design_workdir_for_target(target, action, tmpdir)
    except ValueError as exc:
        cleanup_tcl_tmp(tmpdir)
        return False, {"code": "INVALID_ARGUMENT", "message": str(exc)}

    cmd = [verdi, "-batch", "-nologo", "-play", tcl_script_path()]
    cmd.extend(design_cli_args)
    timeout_sec = max(0.001, parse_timeout_ms(request, 120000) / 1000.0)
    try:
        proc = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                env=env, cwd=verdi_cwd, universal_newlines=True,
                                start_new_session=True)
        try:
            stdout, stderr = proc.communicate(timeout=timeout_sec)
        except subprocess.TimeoutExpired:
            stdout, stderr = terminate_tcl_process_run(proc, run_token)
            cleanup_tcl_tmp(tmpdir)
            return False, {"code": "TCL_NPI_TIMEOUT", "message": "Verdi Tcl action timed out",
                           "stdout": stdout[-4000:], "stderr": stderr[-4000:]}
    except OSError as exc:
        cleanup_tcl_tmp(tmpdir)
        return False, {"code": "VERDI_EXEC_FAILED", "message": str(exc)}

    cleanup_run_token_orphans(run_token)
    license_error = classify_verdi_license_error(stdout, stderr, proc.returncode)
    if license_error:
        cleanup_tcl_tmp(tmpdir)
        return False, license_error

    payload = read_json_file(rsp_path)
    if not isinstance(payload, dict):
        error = classify_verdi_no_response(stdout, stderr, proc.returncode)
        cleanup_tcl_tmp(tmpdir)
        return False, error
    if not payload.get("ok"):
        err = payload.get("error") or {}
        error = {"code": err.get("code", "TCL_NPI_ERROR"),
                 "message": err.get("message", "Tcl NPI action failed"),
                 "stdout": stdout[-2000:],
                 "stderr": stderr[-2000:]}
        cleanup_tcl_tmp(tmpdir)
        return False, error
    data = payload.get("data") or {}
    data.setdefault("verdi", {"exit_code": proc.returncode})
    cleanup_tcl_tmp(tmpdir)
    return True, data


def clean_lower(text):
    return "".join(ch.lower() for ch in text if ch not in ("_", " ", "\t", "\n", "\r"))


def hex_to_bits(text):
    out = []
    for ch in clean_lower(text):
        if ch == "x" or ch == "z":
            out.extend([ch] * 4)
            continue
        try:
            value = int(ch, 16)
        except Exception:
            return ""
        for bit in (3, 2, 1, 0):
            out.append("1" if (value & (1 << bit)) else "0")
    return "".join(out) or "0"


def bin_to_bits(text):
    out = []
    for ch in clean_lower(text):
        if ch not in ("0", "1", "x", "z"):
            return ""
        out.append(ch)
    return "".join(out) or "0"


def bits_to_hex(bits):
    bits = clean_lower(bits)
    if not bits:
        return "0"
    pad = (4 - len(bits) % 4) % 4
    bits = "0" * pad + bits
    out = []
    for i in range(0, len(bits), 4):
        chunk = bits[i:i + 4]
        if "x" in chunk:
            out.append("x")
        elif "z" in chunk:
            out.append("z")
        else:
            out.append("%x" % int(chunk, 2))
    return "".join(out) or "0"


def logic_value_json(raw, radix):
    raw = (raw or "").strip()
    body = raw
    r = (radix or "h").lower()[0]
    width = None
    if "'" in body:
        left, right = body.split("'", 1)
        if left:
            try:
                width = int(left)
            except Exception:
                width = None
        if right:
            r = right[0].lower()
            body = right[1:]
    bits = bin_to_bits(body) if r == "b" else hex_to_bits(body)
    has_x = "x" in bits or "x" in body.lower()
    has_z = "z" in bits or "z" in body.lower()
    if width is not None and bits:
        if len(bits) < width:
            bits = "0" * (width - len(bits)) + bits
        elif len(bits) > width:
            bits = bits[-width:]
    value = ("%d'h%s" % (width, bits_to_hex(bits))) if width else ("'h%s" % bits_to_hex(bits))
    out = {"value": value, "known": not (has_x or has_z)}
    if width:
        out["width"] = width
    if bits:
        out["bits"] = bits
    if has_x or has_z:
        out["has_x"] = has_x
        out["has_z"] = has_z
    return out


def normalize_line(value):
    try:
        return int(value)
    except Exception:
        return 0


def driver_kind_from_text(text):
    lower = str(text or "").lower()
    if "force" in lower:
        return "force"
    if "npiifelse" in lower or "npiif" in lower or "if " in lower or lower.startswith("if"):
        return "if"
    if "npicaseitem" in lower or "npicase" in lower or "case" in lower:
        return "case"
    if "npieventcontrol" in lower or "event" in lower or "posedge" in lower or "negedge" in lower:
        return "event"
    if "npiassignment" in lower or "npicontassign" in lower or "assign" in lower or "<=" in lower or "=" in lower:
        return "assignment"
    if "npiconstant" in lower or "constant" in lower:
        return "constant"
    if "input" in lower or "port" in lower:
        return "primary_input"
    return "unknown"


def schema_driver_kind(kind):
    if kind in ("assignment", "force", "constant", "primary_input"):
        return kind
    return "unknown"


def parse_signal_tokens(text):
    out = []
    seen = set()
    for token in re.findall(r"[A-Za-z_][A-Za-z0-9_$]*(?:\.[A-Za-z_][A-Za-z0-9_$]*(?:\[[^\]]+\])?)+", str(text or "")):
        if token not in seen:
            seen.add(token)
            out.append(token)
    return out


def parse_active_dump_items(text):
    items = []
    current = None
    lines = str(text or "").splitlines()
    active_time = ""
    header_re = re.compile(r"The active time is at\s+([^.\s]+(?:\.[^.\s]+)?[fpnum]?s?|[^.]+?)\.", re.I)
    stmt_re = re.compile(r"<D>\s*(npi[A-Za-z0-9_]+),\s*(.*?),\s*\{(.*?)\s*:\s*([0-9]+)\}")
    sig_re = re.compile(r"^\s*(npi[A-Za-z0-9_]+),\s*([^,{}]+),\s*\{(.*?)\s*:\s*([0-9]+)\}\s*$")
    for line in lines:
        m = header_re.search(line)
        if m and not active_time:
            active_time = m.group(1).strip()
        m = stmt_re.search(line)
        if m:
            if current is not None:
                items.append(current)
            text_part = m.group(2).strip()
            if text_part == "(null)":
                text_part = ""
            current = {
                "type": m.group(1),
                "kind": driver_kind_from_text(m.group(1)),
                "text": text_part,
                "file": m.group(3).strip(),
                "line": normalize_line(m.group(4)),
                "signals": [],
                "raw": line.strip(),
            }
            continue
        m = sig_re.match(line)
        if m and current is not None:
            sig_type = m.group(1)
            sig_name = m.group(2).strip()
            if sig_name and sig_name != "(null)" and sig_type != "npiConstant":
                if sig_name not in current["signals"]:
                    current["signals"].append(sig_name)
            continue
    if current is not None:
        items.append(current)
    return active_time, items


def active_dump_source_file(text):
    m = re.search(r"/[^{}\n\r]+?\.s?vh?\s*:\s*[0-9]+", str(text or ""))
    if not m:
        return ""
    value = m.group(0)
    return value.rsplit(":", 1)[0].strip()


def signal_force_suffixes(signal):
    parts = [p for p in str(signal or "").split(".") if p]
    suffixes = []
    if parts:
        suffixes.append(".".join(parts))
        if len(parts) >= 2:
            suffixes.append(".".join(parts[-2:]))
        suffixes.append(parts[-1])
    out = []
    for item in suffixes:
        if item and item not in out:
            out.append(item)
    return out


def source_force_candidate(signal, active_dump):
    path = active_dump_source_file(active_dump)
    if not path or not os.path.exists(path):
        return None
    suffixes = signal_force_suffixes(signal)
    try:
        with open(path, "r") as fp:
            for idx, line in enumerate(fp, 1):
                if "force" not in line:
                    continue
                m = re.search(r"\bforce\s+([^=;\s]+)\s*=", line)
                if not m:
                    continue
                lhs = m.group(1).strip()
                if any(lhs == s or lhs.endswith("." + s) or s.endswith("." + lhs) for s in suffixes):
                    return {
                        "kind": "force",
                        "type": "npiForce",
                        "text": line.strip(),
                        "file": path,
                        "line": idx,
                        "signals": [],
                        "raw": line.strip(),
                    }
    except Exception:
        return None
    return None


def split_assignment_text(text):
    s = str(text or "")
    for op in ("<=", "="):
        idx = s.find(op)
        if idx >= 0:
            return s[:idx], s[idx + len(op):]
    return "", s


def best_next_signal(text, current_signal):
    lhs, rhs = split_assignment_text(text)
    current_leaf = str(current_signal or "").split(".")[-1]
    for token in parse_signal_tokens(rhs):
        if token != current_signal and token.split(".")[-1] != current_leaf:
            return token
    for token in parse_signal_tokens(text):
        if token != current_signal and token.split(".")[-1] != current_leaf:
            return token
    return ""


def parse_active_item(item, signal):
    if isinstance(item, dict):
        raw = item.get("raw") or item.get("text") or item.get("decompiled") or item.get("handle") or ""
        if item.get("decompiled"):
            text = str(item.get("decompiled"))
        elif "text" in item:
            text = str(item.get("text") or "")
        else:
            text = str(raw or "")
        file_name = str(item.get("file") or item.get("filename") or "")
        line = normalize_line(item.get("line") or item.get("line_no") or item.get("lineno"))
        kind = str(item.get("kind") or "") or driver_kind_from_text(item.get("type") or text or raw)
        signals = item.get("signals") if isinstance(item.get("signals"), list) else parse_signal_tokens(text or raw)
        next_source = text
    else:
        raw = str(item or "")
        text = raw
        file_name = ""
        line = 0
        m = re.search(r"([^,\s:]+\.s?vh?)[:(]([0-9]+)", raw)
        if m:
            file_name = m.group(1)
            line = normalize_line(m.group(2))
        else:
            m = re.search(r"\bline(?:No)?\s*[:= ]\s*([0-9]+)", raw, re.I)
            if m:
                line = normalize_line(m.group(1))
        kind = driver_kind_from_text(raw)
        signals = parse_signal_tokens(raw)
        next_source = text or raw
    next_signal = best_next_signal(next_source, signal)
    if not next_signal:
        for candidate in signals:
            if candidate != signal and str(candidate).split(".")[-1] != str(signal or "").split(".")[-1]:
                next_signal = candidate
                break
    return {
        "kind": kind,
        "file": file_name,
        "line": line,
        "text": text,
        "raw": raw,
        "signals": signals,
        "next_signal": next_signal,
    }


def active_time_from_scan(request, state, signal, requested_time):
    if not signal or not requested_time:
        return ""
    try:
        limits = dict(request.get("limits") if isinstance(request.get("limits"), dict) else {})
        max_rows = int(limits.get("max_trace_signals", limits.get("max_rows", 4096)) or 4096)
    except Exception:
        max_rows = 4096
    ok, scan = signal_scan(request, state, signal, "", requested_time, max_rows, "bin")
    if not ok:
        return ""
    changes = scan.get("changes", [])
    if not changes:
        return requested_time
    last_time = changes[-1].get("time")
    end_fsdb = scan.get("end_fsdb")
    parsed = parse_time_number(requested_time)
    if parsed and end_fsdb:
        value, unit = parsed
        try:
            scaled = float(last_time) * float(value) / float(end_fsdb)
            suffix = {"fs": "f", "ps": "p", "ns": "n", "us": "u", "ms": "m"}.get(unit, unit)
            return "%.1f%s" % (scaled, suffix)
        except Exception:
            pass
    return str(last_time)


def parse_time_number(text):
    m = re.match(r"^\s*([0-9]+(?:\.[0-9]+)?)(fs|ps|ns|us|ms|s|f|p|n|u|m)\s*$", str(text or ""), re.I)
    if not m:
        return None
    value = float(m.group(1))
    unit = m.group(2).lower()
    unit = {"f": "fs", "p": "ps", "n": "ns", "u": "us", "m": "ms"}.get(unit, unit)
    return value, unit


def normalize_active_driver_data(data, requested_signal="", requested_time="", state=None, request=None):
    signal = requested_signal or data.get("signal", "")
    requested_time = requested_time or data.get("requested_time", data.get("time", ""))
    raw_items = data.get("raw", [])
    if not isinstance(raw_items, list):
        raw_items = [raw_items]
    handle_items = data.get("handles", [])
    dump_active_time, dump_items = parse_active_dump_items(data.get("active_dump", ""))
    items = handle_items if isinstance(handle_items, list) and handle_items else raw_items
    if dump_items:
        items = dump_items
    elif data.get("active_dump"):
        items = []
    parsed = [parse_active_item(item, signal) for item in items]
    if not parsed:
        force = source_force_candidate(signal, data.get("active_dump", ""))
        if force:
            parsed = [parse_active_item(force, signal)]
    statement_items = [p for p in parsed if p.get("kind") not in ("if", "case", "event")]
    control_items = [p for p in parsed if p.get("kind") in ("if", "case", "event")]
    root = statement_items[0] if statement_items else None
    if root:
        driver_status = "resolved"
    elif control_items:
        driver_status = "control_only"
    else:
        driver_status = "unresolved"
    active_time = data.get("active_time", "") or dump_active_time
    if not active_time and request is not None and state is not None:
        active_time = active_time_from_scan(request, state, signal, requested_time)
    if not active_time:
        active_time = requested_time
    driver = None
    root_driver = None
    if root:
        driver = {
            "kind": schema_driver_kind(root.get("kind")),
            "file": root.get("file", ""),
            "line": normalize_line(root.get("line")),
            "text": root.get("text", ""),
            "signals": root.get("signals", []),
        }
        root_driver = {
            "kind": schema_driver_kind(root.get("kind")),
            "file": root.get("file", ""),
            "line": normalize_line(root.get("line")),
        }
    nodes = []
    edges = []
    selected = []
    for idx, item in enumerate(parsed):
        node_id = "n%d" % idx
        selected.append(node_id)
        nodes.append({
            "id": node_id,
            "role": "control" if item.get("kind") in ("if", "case", "event") else "driver",
            "kind": schema_driver_kind(item.get("kind")) if item.get("kind") not in ("if", "case", "event") else item.get("kind"),
            "signal": signal,
            "signals": item.get("signals", []),
            "file": item.get("file", ""),
            "line": normalize_line(item.get("line")),
            "text": item.get("text", ""),
            "active_time": active_time,
            "next_signal": item.get("next_signal", ""),
            "alias_kind": "none",
        })
        if idx > 0:
            edges.append({"from": "n%d" % (idx - 1), "to": node_id, "relation": "control", "confidence": "medium"})
    termination = "assignment" if root else "unresolved"
    if driver_status == "control_only":
        termination = "unresolved"
    elif root and schema_driver_kind(root.get("kind")) in ("force", "constant", "primary_input"):
        termination = schema_driver_kind(root.get("kind"))
    normalized = dict(data)
    normalized.update({
        "signal": signal,
        "requested_time": requested_time,
        "active_time": active_time,
        "driver_status": driver_status,
        "driver": driver,
        "root_driver": root_driver,
        "controls": [
            {"kind": c.get("kind", "unknown"), "file": c.get("file", ""), "line": normalize_line(c.get("line")),
             "text": c.get("text", ""), "signals": c.get("signals", [])}
            for c in control_items
        ],
        "events": [],
        "values": {"requested": {}, "active": {}},
        "trace": {"nodes": nodes, "edges": edges, "selected_path": selected, "termination": termination},
        "alias_candidates": [],
        "limitations": [] if parsed else ["Tcl active trace returned no structured driver evidence"],
        "statements": parsed,
        "statement_count": len(parsed),
        "trace_node_count": len(nodes),
        "next_signal": root.get("next_signal", "") if root else "",
    })
    normalized["summary"] = {
        "signal": signal,
        "requested_time": requested_time,
        "active_time": active_time,
        "driver_status": driver_status,
        "statement_count": len(parsed),
        "trace_node_count": len(nodes),
        "root_driver": root_driver or {"kind": "unknown", "file": "", "line": 0},
        "truncated": bool(normalized.get("truncated", False)),
    }
    return normalized


def active_driver_action(request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    signal = args.get("signal", "")
    requested_time = args.get("requested_time", args.get("time", args.get("at", "")))
    if not signal or not requested_time:
        return False, {"code": "MISSING_FIELD", "message": "args.signal and args.requested_time are required"}
    ok, data = run_tcl_npi(request, state)
    if not ok:
        return ok, data
    normalized = normalize_active_driver_data(data, signal, requested_time, state, request)
    node_limit = int((request.get("limits") if isinstance(request.get("limits"), dict) else {}).get(
        "max_nodes", args.get("limits", {}).get("max_nodes", 0) if isinstance(args.get("limits"), dict) else 0) or 0)
    if node_limit and normalized.get("trace_node_count", 0) >= node_limit:
        normalized["truncated"] = True
        normalized["summary"]["truncated"] = True
    return True, normalized


def active_driver_chain_action(request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    signal = args.get("signal", "")
    requested_time = args.get("requested_time", args.get("time", args.get("at", "")))
    if not signal or not requested_time:
        return False, {"code": "MISSING_FIELD", "message": "args.signal and args.requested_time are required"}
    limits = request.get("limits") if isinstance(request.get("limits"), dict) else {}
    arg_limits = args.get("limits") if isinstance(args.get("limits"), dict) else {}
    max_depth = int(limits.get("max_depth", arg_limits.get("max_depth", 8)) or 8)
    max_nodes = int(limits.get("max_nodes", arg_limits.get("max_nodes", 50)) or 50)
    current = signal
    current_time = requested_time
    chain = []
    visited = set()
    truncated = False
    termination = "unresolved"
    for hop in range(max_depth + 1):
        if len(chain) >= max_nodes:
            truncated = True
            termination = "limit"
            break
        child = dict(request)
        child["action"] = "trace.active_driver"
        child_args = dict(args)
        child_args["signal"] = current
        child_args["requested_time"] = current_time
        child["args"] = child_args
        ok, data = active_driver_action(child, state)
        if not ok:
            termination = "unresolved"
            break
        root = data.get("root_driver") or {}
        node = {
            "index": len(chain),
            "hop": len(chain),
            "signal": current,
            "time": current_time,
            "active_time": data.get("active_time", current_time),
            "driver_kind": (data.get("driver") or {}).get("kind", root.get("kind", "unknown")),
            "driver": (data.get("driver") or {}).get("text", ""),
            "file": root.get("file", ""),
            "line": normalize_line(root.get("line")),
            "next": data.get("next_signal", ""),
            "next_signal": data.get("next_signal", ""),
            "hop_type": "same_time",
        }
        node["hop"] = "->" if node["next_signal"] else "[]"
        chain.append(node)
        if data.get("truncated"):
            truncated = True
            termination = "limit"
            break
        next_signal = data.get("next_signal", "")
        if not next_signal or next_signal == current or next_signal in visited:
            status = data.get("driver_status", "unresolved")
            if status == "control_only":
                termination = "control_only"
            elif root.get("kind") in ("primary_input", "constant", "force"):
                termination = root.get("kind")
            elif status == "resolved":
                termination = "primary_input"
            else:
                termination = "unresolved"
            break
        visited.add(current)
        current = next_signal
        current_time = data.get("active_time", current_time)
    else:
        truncated = True
        termination = "limit"
    driver_status = "resolved" if termination in ("primary_input", "assignment", "force", "constant") else (
        "control_only" if termination == "control_only" else "unresolved")
    data = {
        "signal": signal,
        "requested_time": requested_time,
        "active_time": chain[0].get("active_time", requested_time) if chain else requested_time,
        "driver_status": driver_status,
        "chain": {"chain": chain},
        "stats": {"calls": len(chain), "edgecheck_direct": 0, "fallback": 0, "temporal_boundaries": 0},
        "limitations": [],
        "termination": termination,
        "truncated": truncated,
        "summary": {
            "signal": signal,
            "requested_time": requested_time,
            "start_time": requested_time,
            "active_time": chain[0].get("active_time", requested_time) if chain else requested_time,
            "chain_length": len(chain),
            "driver_status": driver_status,
            "termination": termination,
            "temporal_boundaries": 0,
            "truncated": truncated,
        },
    }
    return True, data


def port_trace_is_constant(value):
    value = str(value or "").strip()
    if value.startswith("Const:"):
        return True
    return bool(
        re.match(r"^'[01xXzZ?]$", value)
        or re.match(r"^'[bBoOdDhH][0-9a-fA-F_xXzZ?]+$", value)
        or re.match(r"^[0-9]+'[sS]?[bBoOdDhH][0-9a-fA-F_xXzZ?]+$", value)
        or re.match(r"^-?[0-9]+$", value)
    )


def port_trace_constant_semantics(value):
    text = str(value or "").strip()
    if text.startswith("Const:"):
        text = text[len("Const:"):]
    text = text.replace("_", "").lower()
    if text in ("0", "'0"):
        return "bit:0"
    if text in ("1", "'1"):
        return "bit:1"
    match = re.match(r"^(?:[0-9]+)?'s?([bodh])([0-9a-f]+)$", text)
    if match:
        try:
            base = {"b": 2, "o": 8, "d": 10, "h": 16}[match.group(1)]
            number = int(match.group(2), base)
            if number in (0, 1):
                return "bit:%d" % number
        except (KeyError, ValueError):
            pass
    return "literal:" + text


def normalize_port_trace_evidence(evidence):
    normalized = []
    for item in evidence if isinstance(evidence, list) else []:
        if not isinstance(item, dict):
            continue
        item = dict(item)
        fields = item.get("fields") if isinstance(item.get("fields"), dict) else {}
        role = item.get("role") or fields.get("role", "")
        value = item.get("value", "")
        candidate = bool(item.get("effective_candidate", False)) and role == "driver"
        provenance = item.get("provenance") if isinstance(item.get("provenance"), dict) else {}
        provenance = dict(provenance)
        path = provenance.get("path")
        if not isinstance(path, list):
            path = [part for part in str(item.get("const_full_path", "")).split("<-") if part]
        provenance["path"] = path
        provenance["origin"] = provenance.get("origin", item.get("method", ""))
        provenance["unconditional"] = candidate
        item["provenance"] = provenance
        constant = item.get("constant") if isinstance(item.get("constant"), dict) else {}
        constant = dict(constant)
        constant["value"] = constant.get("value", value)
        constant["effective"] = candidate
        item["constant"] = constant
        item["role"] = role
        item["value"] = value
        item["effective"] = candidate
        item["effective_candidate"] = candidate
        item["port_path"] = item.get("port_path") or fields.get("port_path", "")
        normalized.append(item)
    return normalized


def guard_port_trace_surfaces(full_rows, boundary_rows, evidence_by_key, errors, rejected):
    surfaces = {
        "full": [dict(row) for row in full_rows if isinstance(row, dict)],
        "boundary": [dict(row) for row in boundary_rows if isinstance(row, dict)],
    }
    groups = {}
    for surface, rows in surfaces.items():
        for index, row in enumerate(rows):
            if row.get("role") != "driver":
                continue
            key = (str(row.get("inst_full_name", "")), str(row.get("port_name", "")))
            group = groups.setdefault(key, {"constants": [], "signals": []})
            signal_name = str(row.get("signal_full_name", ""))
            if port_trace_is_constant(signal_name):
                group["constants"].append((surface, index, signal_name, row))
            elif (signal_name and signal_name != "NO_DRIVER"
                  and not signal_name.startswith("TRACE_LIMIT_REACHED:")
                  and not signal_name.startswith("TRACE_STOP:")):
                group["signals"].append(signal_name)

    rejected_indexes = {"full": set(), "boundary": set()}
    marker_rows = {"full": [], "boundary": []}
    error_keys = set(
        (error.get("code"), error.get("instance"), error.get("port"))
        for error in errors if isinstance(error, dict)
    )

    def add_error(code, instance, port, message, values=None):
        error_key = (code, instance, port)
        if error_key in error_keys:
            return
        error_keys.add(error_key)
        error = {
            "scope": "port",
            "code": code,
            "message": message,
            "instance": instance,
            "port": port,
        }
        if values:
            error["values"] = sorted(values)
        errors.append(error)

    for (instance, port), group in groups.items():
        port_path = "%s.%s" % (instance, port)
        verified = []
        rejected_reason = ""
        for surface, index, value, row in group["constants"]:
            candidates = evidence_by_key.get((port_path, value), [])
            if not any(item.get("effective_candidate") for item in candidates):
                rejected_indexes[surface].add(index)
                rejected[(port_path, value)] = "unverified_provenance"
                rejected_reason = "CONSTANT_PROVENANCE_UNVERIFIED"
                add_error(
                    "CONSTANT_PROVENANCE_UNVERIFIED", instance, port,
                    "constant endpoint was suppressed because no unconditional provenance was found",
                    [value])
            else:
                verified.append((surface, index, value, row))

        semantic_values = set(port_trace_constant_semantics(value) for _, _, value, _ in verified)
        conflict = len(semantic_values) > 1
        mixed = bool(verified and group["signals"])
        if conflict or mixed:
            code = "CONSTANT_DRIVER_CONFLICT" if conflict else "CONSTANT_DRIVER_AMBIGUOUS"
            message = (
                "conflicting constant endpoints were suppressed"
                if conflict else
                "constant endpoints mixed with non-constant drivers and were suppressed"
            )
            values = [value for _, _, value, _ in verified] + group["signals"]
            add_error(code, instance, port, message, values)
            reason = "conflicting_constants" if conflict else "mixed_driver_kinds"
            rejected_reason = code
            for surface, index, value, row in verified:
                rejected_indexes[surface].add(index)
                rejected[(port_path, value)] = reason
        if rejected_reason:
            for surface, rows in surfaces.items():
                remaining_driver = any(
                    index not in rejected_indexes[surface]
                    and row.get("role") == "driver"
                    and str(row.get("inst_full_name", "")) == instance
                    and str(row.get("port_name", "")) == port
                    for index, row in enumerate(rows)
                )
                removed_rows = [
                    row for removed_surface, index, value, row in group["constants"]
                    if removed_surface == surface and index in rejected_indexes[surface]
                ]
                if not remaining_driver and removed_rows:
                    marker = dict(removed_rows[0])
                    marker["signal_full_name"] = "TRACE_LIMIT_REACHED:%s" % rejected_reason.lower()
                    marker_rows[surface].append(marker)

    filtered = {}
    for surface, rows in surfaces.items():
        filtered[surface] = [
            row for index, row in enumerate(rows) if index not in rejected_indexes[surface]
        ] + marker_rows[surface]
    return filtered["full"], filtered["boundary"], sum(
        len(indexes) for indexes in rejected_indexes.values()), sum(
        len(rows) for rows in marker_rows.values())


def postprocess_port_trace_data(data):
    evidence = normalize_port_trace_evidence(data.get("evidence", []))
    evidence_by_key = {}
    for item in evidence:
        key = (str(item.get("port_path", "")), str(item.get("value", "")))
        evidence_by_key.setdefault(key, []).append(item)

    errors = [dict(item) for item in data.get("errors", []) if isinstance(item, dict)]
    rejected = {}
    full_rows, boundary_rows, suppressed_count, guard_marker_count = guard_port_trace_surfaces(
        data.get("full_rows", []), data.get("boundary_rows", []),
        evidence_by_key, errors, rejected)

    published_constants = set()
    for row in full_rows + boundary_rows:
        if row.get("role") != "driver":
            continue
        value = str(row.get("signal_full_name", ""))
        if port_trace_is_constant(value):
            published_constants.add((
                "%s.%s" % (
                    str(row.get("inst_full_name", "")),
                    str(row.get("port_name", "")),
                ),
                value,
            ))

    for item in evidence:
        key = (str(item.get("port_path", "")), str(item.get("value", "")))
        rejection = rejected.get(key)
        if item.get("effective_candidate") and key not in published_constants and not rejection:
            rejection = "row_not_published"
        effective = bool(item.get("effective_candidate")) and not rejection
        item["effective"] = effective
        item["constant"]["effective"] = effective
        item["provenance"]["unconditional"] = effective
        if rejection:
            item["rejection_reason"] = rejection

    data["full_rows"] = full_rows
    data["boundary_rows"] = boundary_rows
    data["evidence"] = evidence
    data["errors"] = errors
    trace_limit_marker_count = sum(
        1 for row in full_rows + boundary_rows
        if str(row.get("signal_full_name", "")).startswith("TRACE_LIMIT_REACHED:")
    )
    data["truncated"] = bool(
        data.get("truncated", False) or guard_marker_count or trace_limit_marker_count)
    requested_ports = data.get("requested_ports", [])
    if not isinstance(requested_ports, list):
        requested_ports = []
    traced_pairs = set()
    traced_ports = set()
    for row in full_rows + boundary_rows:
        instance = str(row.get("inst_full_name", ""))
        port = str(row.get("port_name", ""))
        if port:
            traced_pairs.add((instance, port))
            traced_ports.add(port)
    data["requested_ports"] = requested_ports
    data["traced_ports"] = sorted(traced_ports)
    data["selection_mode"] = "explicit" if requested_ports else "all"
    stats = data.get("stats") if isinstance(data.get("stats"), dict) else {}
    stats.update({
        "full_row_count": len(full_rows),
        "boundary_row_count": len(boundary_rows),
        "evidence_count": len(evidence),
        "error_count": len(errors),
        "suppressed_constant_count": suppressed_count,
        "constant_guard_marker_count": guard_marker_count,
        "trace_limit_marker_count": trace_limit_marker_count,
        "requested_port_count": len(requested_ports),
        "traced_port_count": len(traced_pairs),
    })
    data["stats"] = stats
    data["summary"] = {
        "module": data.get("module", ""),
        "selection_mode": data["selection_mode"],
        "requested_port_count": len(requested_ports),
        "traced_port_count": len(traced_pairs),
        "processed_instances": stats.get("processed_instances", 0),
        "full_row_count": len(full_rows),
        "boundary_row_count": len(boundary_rows),
        "evidence_count": len(evidence),
        "error_count": len(errors),
        "truncated": data["truncated"],
    }
    return data


def postprocess_npi_data(action, data):
    if action == "value.at":
        raw = data.get("raw", "")
        radix = data.get("radix", "h")
        data["raw_value"] = raw
        data["value"] = logic_value_json(raw, radix)
        data["known"] = data["value"].get("known", False)
        data["summary"] = {
            "signal": data.get("signal", ""),
            "time": data.get("time", ""),
            "known": data.get("known", False),
            "status": data.get("status", "ok"),
        }
    elif action == "value.batch_at":
        missing = 0
        unknown = 0
        for item in data.get("values", []):
            if item.get("status") == "ok":
                item["raw_value"] = item.get("raw", "")
                item["value"] = logic_value_json(item.get("raw", ""), item.get("radix", "h"))
                if not item["value"].get("known", False):
                    unknown += 1
            else:
                missing += 1
                item.setdefault("value", None)
        data["summary"] = {
            "time": data.get("time", ""),
            "signal_count": len(data.get("values", [])),
            "missing_count": missing,
            "unknown_count": unknown,
            "x_or_z_count": unknown,
        }
    elif action in ("trace.driver", "trace.load", "trace.query"):
        mode = data.get("mode", "driver")
        signal = data.get("signal", "")
        edges = []
        for h in data.get("handles", []):
            name = h.get("full_name") or h.get("name") or h.get("handle")
            name = str(name) if name is not None else ""
            edge = {
                "from": name if mode == "driver" else signal,
                "to": signal if mode == "driver" else name,
                "relation": mode,
                "object_type": h.get("type", ""),
                "location": {"file": h.get("file", ""), "line": h.get("line", "")},
            }
            if h.get("decompiled"):
                edge["source"] = h.get("decompiled")
            edges.append(edge)
        data["query"] = signal
        data["dependency_edges"] = edges
        data["driver_status"] = data.get("status", "ok")
        data["statement_count"] = len(edges)
        data["summary"] = {
            "query": signal,
            "mode": mode,
            "edge_count": len(edges),
            "status": data.get("status", "ok"),
        }
    elif action == "port.trace_batch":
        data = postprocess_port_trace_data(data)
    elif action == "module.inspect_batch":
        inspections = data.get("inspections", [])
        error_count = sum(1 for item in inspections if not item.get("ok"))
        any_truncated = any(
            bool((item.get("data") or {}).get("truncated", False))
            for item in inspections if isinstance(item, dict)
        )
        data["truncated"] = any_truncated
        data["summary"] = {
            "module_count": len(inspections),
            "success_count": len(inspections) - error_count,
            "error_count": error_count,
            "truncated": any_truncated,
        }
    elif action == "signal.scan":
        unknown = 0
        for item in data.get("changes", []):
            item["raw_value"] = item.get("raw", "")
            item["value"] = logic_value_json(item.get("raw", ""), item.get("radix", data.get("radix", "h")))
            if not item["value"].get("known", False):
                unknown += 1
        data["summary"] = {
            "signal": data.get("signal", ""),
            "change_count": len(data.get("changes", [])),
            "unknown_count": unknown,
            "truncated": bool(data.get("truncated", False)),
        }
    elif action == "signal.info":
        data["summary"] = {
            "signal": data.get("signal", ""),
            "full_name": data.get("full_name", data.get("signal", "")),
        }
    elif action == "trace.active_driver":
        data = normalize_active_driver_data(data)
    return data


def storage_dir_for_session(state):
    sid = state.get("session_id") or "adhoc"
    path = os.path.join(session_dir(sid), "state")
    mkdir_p(path)
    return path


def read_state_json(state, name, default):
    path = os.path.join(storage_dir_for_session(state), name + ".json")
    return read_json_file(path, default)


def write_state_json(state, name, payload):
    path = os.path.join(storage_dir_for_session(state), name + ".json")
    atomic_write_json(path, payload)


def cursor_action(action, request, state):
    cursors = read_state_json(state, "cursors", {})
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    name = args.get("name", "default")
    if action == "cursor.set":
        cursors[name] = {"name": name, "time": args.get("time", args.get("at", ""))}
        write_state_json(state, "cursors", cursors)
        return True, {"name": name, "time": cursors[name]["time"], "summary": {"name": name, "status": "set"}}
    if action == "cursor.get" or action == "cursor.use":
        item = cursors.get(name)
        if not item:
            return False, {"code": "CURSOR_NOT_FOUND", "message": name}
        return True, dict(item, summary={"name": name, "time": item.get("time")})
    if action == "cursor.list":
        arr = list(cursors.values())
        return True, {"cursors": arr, "summary": {"cursor_count": len(arr)}}
    if action == "cursor.delete":
        existed = name in cursors
        if existed:
            del cursors[name]
            write_state_json(state, "cursors", cursors)
        return True, {"name": name, "deleted": existed, "summary": {"name": name, "deleted": existed}}
    return False, {"code": "UNKNOWN_ACTION", "message": action}


def list_action(action, request, state):
    lists = read_state_json(state, "lists", {})
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    name = args.get("name", "")
    if not name and action == "list.show":
        arr = [{"name": key, "count": len(value)} for key, value in sorted(lists.items())]
        return True, {"lists": arr, "summary": {"list_count": len(arr)}}
    if not name:
        return False, {"code": "MISSING_FIELD", "message": "args.name is required"}
    if action == "list.create":
        signals = args.get("signals") if isinstance(args.get("signals"), list) else []
        lists[name] = [str(s) for s in signals]
        write_state_json(state, "lists", lists)
        return True, {"name": name, "created": True, "summary": {"name": name, "status": "created"}}
    if action == "list.add":
        sigs = []
        if isinstance(args.get("signals"), list):
            sigs = [str(s) for s in args.get("signals")]
        elif args.get("signal"):
            sigs = [str(args.get("signal"))]
        if not sigs:
            return False, {"code": "MISSING_FIELD", "message": "args.signal or args.signals[] is required"}
        lists.setdefault(name, [])
        added = []
        for sig in sigs:
            if sig not in lists[name]:
                lists[name].append(sig)
                added.append(sig)
        write_state_json(state, "lists", lists)
        return True, {"name": name, "signals": added, "added": len(added),
                      "summary": {"name": name, "added_count": len(added)}}
    if action == "list.delete":
        sig = args.get("signal", args.get("index", ""))
        if name not in lists:
            if sig == "":
                return True, {"name": name, "deleted": False,
                              "summary": {"name": name, "removed": ""}}
            return False, {"code": "LIST_NOT_FOUND", "message": name}
        if sig == "":
            del lists[name]
            write_state_json(state, "lists", lists)
            return True, {"name": name, "deleted": True,
                          "summary": {"name": name, "removed": "list"}}
        removed = None
        if isinstance(sig, int) or (isinstance(sig, str) and sig.isdigit()):
            idx = int(sig) - 1
            if 0 <= idx < len(lists[name]):
                removed = lists[name].pop(idx)
        elif sig in lists[name]:
            lists[name].remove(sig)
            removed = sig
        write_state_json(state, "lists", lists)
        return True, {"name": name, "deleted": removed is not None, "removed": removed,
                      "summary": {"name": name, "removed": removed or ""}}
    if action == "list.show":
        if name not in lists:
            return False, {"code": "LIST_NOT_FOUND", "message": name}
        arr = [{"index": i + 1, "signal": sig} for i, sig in enumerate(lists[name])]
        return True, {"name": name, "signals": arr, "count": len(arr),
                      "summary": {"name": name, "signal_count": len(arr)}}
    if action == "list.value_at":
        if name not in lists:
            return False, {"code": "LIST_NOT_FOUND", "message": name}
        child = dict(request)
        child["action"] = "value.batch_at"
        child["args"] = dict(args)
        child["args"]["signals"] = lists[name]
        return run_action(child, state)
    if action == "list.validate":
        if name not in lists:
            return False, {"code": "LIST_NOT_FOUND", "message": name}
        arr = []
        all_found = True
        for sig in lists[name]:
            child = dict(request)
            child["action"] = "signal.info"
            child["args"] = {"signal": sig}
            ok, data = run_tcl_npi(child, state)
            status = "ok" if ok else "not_found"
            if not ok:
                all_found = False
            arr.append({"signal": sig, "status": status})
        return True, {"name": name, "signals": arr, "summary": {"name": name, "all_found": all_found}}
    if action == "list.diff":
        if name not in lists:
            return False, {"code": "LIST_NOT_FOUND", "message": name}
        time_a = args.get("time_a", args.get("begin", ""))
        time_b = args.get("time_b", args.get("end", ""))
        if not time_a or not time_b:
            return False, {"code": "MISSING_FIELD", "message": "args.time_a/time_b are required"}
        changed = []
        for sig in lists[name]:
            ra = {"api_version": request.get("api_version", PUBLIC_API_VERSION), "action": "value.at",
                  "target": request.get("target", {}), "args": {"signal": sig, "time": time_a, "format": args.get("format", "hex")}}
            rb = {"api_version": request.get("api_version", PUBLIC_API_VERSION), "action": "value.at",
                  "target": request.get("target", {}), "args": {"signal": sig, "time": time_b, "format": args.get("format", "hex")}}
            oka, da = run_action(ra, state)
            okb, db = run_action(rb, state)
            va = da.get("raw_value", da.get("raw", "")) if oka else None
            vb = db.get("raw_value", db.get("raw", "")) if okb else None
            if va != vb:
                changed.append({"signal": sig, "time_a": time_a, "value_a": va,
                                "time_b": time_b, "value_b": vb})
        return True, {"name": name, "time_a": time_a, "time_b": time_b,
                      "diff_found": bool(changed), "changed": changed,
                      "summary": {"name": name, "changed_count": len(changed), "diff_found": bool(changed)}}
    return False, {"code": "NOT_IMPLEMENTED", "message": "Tcl backend does not implement " + action}


def source_context(request):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    path = args.get("file", "")
    line = int(args.get("line", 0) or 0)
    if not path or line <= 0:
        return False, {"code": "MISSING_FIELD", "message": "args.file and args.line are required"}
    try:
        with open(path, "r") as fp:
            lines = fp.read().splitlines()
    except Exception:
        return False, {"code": "SOURCE_NOT_FOUND", "message": path}
    if line > len(lines):
        return False, {"code": "INVALID_REQUEST", "message": "line out of range"}
    ctx_lines = int(args.get("context_lines", 8) or 8)
    begin = max(1, line - ctx_lines)
    end = min(len(lines), line + ctx_lines)
    context = [{"line": i, "text": lines[i - 1], "hit": i == line} for i in range(begin, end + 1)]
    return True, {"file": path, "line": line, "context": context,
                  "summary": {"file": path, "line": line}}


def expr_normalize(request):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    expr = args.get("expr", "")
    if not expr:
        return False, {"code": "MISSING_FIELD", "message": "args.expr is required"}
    signals = sorted(set(re.findall(r"[A-Za-z_][A-Za-z0-9_.$]*(?:\[[^\]]+\])?", expr)))
    ops = []
    for token in ("&&", "||", "!", "==", "!=", "<=", ">=", "<", ">", "&", "|", "^", "+", "-"):
        if token in expr:
            ops.append(token)
    return True, {
        "expr": {"text": expr, "signals": signals, "operators": ops},
        "confidence": "low",
        "confidence_reason": "parsed from raw string without NPI handle",
        "summary": {"expr": expr, "source": "string_fallback", "confidence": "low"},
    }


def rc_dot_path_to_slash(path):
    if not path or path.startswith("/") or re.search(r"\s", path):
        raise ValueError("signal path must use dot hierarchy without whitespace: " + path)
    return "/" + path.replace(".", "/")


def render_rc_group(group, out):
    name = group.get("name")
    if not name:
        raise ValueError("group requires name")
    out.append('addGroup "%s"' % str(name).replace('"', '\\"'))
    for sig in group.get("signals", []):
        path = sig if isinstance(sig, str) else sig.get("path", sig.get("signal", ""))
        out.append("addSignal %s" % rc_dot_path_to_slash(path))
    for sub in group.get("subgroups", []):
        render_rc_group(sub, out)


def rc_generate(request):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    config_path = args.get("config_path", "")
    rc_path = args.get("rc_path", "")
    if not config_path or not rc_path:
        return False, {"code": "MISSING_FIELD", "message": "args.config_path and args.rc_path are required"}
    try:
        cfg = read_json_file(config_path)
        if not isinstance(cfg, dict):
            raise ValueError("rc config JSON must be an object")
        lines = ["; Generated by kdebug rc.generate", "fileTimeScale %s" % cfg.get("file_time_scale", "1ns")]
        for group in cfg.get("groups", []):
            render_rc_group(group, lines)
        mkdir_p(os.path.dirname(os.path.abspath(rc_path)))
        with open(rc_path, "w") as fp:
            fp.write("\n".join(lines) + "\n")
    except Exception as exc:
        return False, {"code": "RC_GENERATE_FAILED", "message": str(exc)}
    return True, {"config_path": config_path, "rc_path": rc_path, "written": True,
                  "summary": {"written": True, "config_path": config_path, "rc_path": rc_path}}


def edge_neighbor(edge, direction):
    if direction == "load":
        return edge.get("to")
    return edge.get("from")


def looks_like_signal_path(value):
    text = str(value or "")
    if not text or text.isdigit():
        return False
    return bool(re.match(r"^[A-Za-z_][A-Za-z0-9_.$\[\]:]*$", text))


def run_trace_once(request, state, signal, direction):
    child = dict(request)
    child["action"] = "trace.load" if direction == "load" else "trace.driver"
    args = dict(request.get("args") if isinstance(request.get("args"), dict) else {})
    args["signal"] = signal
    child["args"] = args
    ok, data = run_tcl_npi(child, state)
    if not ok:
        return ok, data
    return True, postprocess_npi_data(child["action"], data)


def trace_expand_action(action, request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    limits = request.get("limits") if isinstance(request.get("limits"), dict) else {}
    root = args.get("root_signal", args.get("signal", ""))
    if not root:
        return False, {"code": "MISSING_FIELD", "message": "args.signal is required"}
    direction = args.get("direction", args.get("mode", "driver"))
    if direction not in ("driver", "load"):
        direction = "driver"
    max_depth = int(args.get("max_depth", limits.get("max_depth", 1)) or 1)
    max_nodes = int(limits.get("max_nodes", 64) or 64)
    max_edges = int(limits.get("max_edges", limits.get("max_results", 256)) or 256)
    queue = [(root, 0)]
    visited = set()
    nodes = {}
    edges = []
    expanded = []
    warnings = []
    truncated = False
    while queue and not truncated:
        signal, depth = queue.pop(0)
        if signal in visited or depth > max_depth:
            continue
        visited.add(signal)
        nodes.setdefault(signal, {"id": signal, "label": signal})
        ok, data = run_trace_once(request, state, signal, direction)
        if not ok:
            warnings.append({"signal": signal, "code": data.get("code", "TRACE_FAILED"),
                             "message": data.get("message", "")})
            continue
        expanded.append(signal)
        for edge in data.get("dependency_edges", []):
            src = edge.get("from", "")
            dst = edge.get("to", "")
            if not src or not dst:
                continue
            nodes.setdefault(src, {"id": src, "label": src})
            nodes.setdefault(dst, {"id": dst, "label": dst})
            edges.append(edge)
            if len(edges) >= max_edges:
                truncated = True
                break
            nxt = edge_neighbor(edge, direction)
            if looks_like_signal_path(nxt) and nxt not in visited and depth + 1 <= max_depth and len(nodes) < max_nodes:
                queue.append((nxt, depth + 1))
    graph = {"nodes": list(nodes.values()), "edges": edges}
    summary = {
        "root_signal": root,
        "direction": direction,
        "node_count": len(nodes),
        "edge_count": len(edges),
        "truncated": truncated,
    }
    data = {"root_signal": root, "direction": direction, "graph": graph,
            "dependency_edges": edges, "expanded_queries": expanded,
            "truncated": truncated, "summary": summary}
    if warnings:
        data["warnings"] = warnings
    if action == "trace.graph":
        data["summary"]["graph"] = "dependency"
    if action == "trace.explain":
        data["explanations"] = [
            {"from": e.get("from", ""), "to": e.get("to", ""),
             "relation": e.get("relation", direction), "source": e.get("source", "")}
            for e in edges
        ]
        data["summary"]["explanation_count"] = len(data["explanations"])
    return True, data


def trace_path_action(request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    from_sig = args.get("from_signal", "")
    to_sig = args.get("to_signal", "")
    if not from_sig or not to_sig:
        return False, {"code": "MISSING_FIELD", "message": "args.from_signal and args.to_signal are required"}
    expand_req = dict(request)
    expand_req["action"] = "trace.expand"
    expand_args = dict(args)
    expand_args["signal"] = to_sig
    expand_args["direction"] = "driver"
    expand_req["args"] = expand_args
    ok, data = trace_expand_action("trace.expand", expand_req, state)
    if not ok:
        return ok, data
    adj = {}
    for edge in data.get("dependency_edges", []):
        adj.setdefault(edge.get("from", ""), []).append(edge)
    paths = []
    queue = [(from_sig, [])]
    seen = set()
    while queue and len(paths) < int((request.get("limits") or {}).get("max_paths", 8) or 8):
        sig, path = queue.pop(0)
        if sig == to_sig:
            paths.append(path)
            continue
        if sig in seen:
            continue
        seen.add(sig)
        for edge in adj.get(sig, []):
            nxt = edge.get("to")
            if nxt:
                queue.append((nxt, path + [edge]))
    return True, {
        "from_signal": from_sig,
        "to_signal": to_sig,
        "found": bool(paths),
        "paths": paths,
        "summary": {"from_signal": from_sig, "to_signal": to_sig,
                    "found": bool(paths), "path_count": len(paths)},
    }


def design_semantic_action(action, request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    signal = args.get("signal", "")
    if not signal:
        return False, {"code": "MISSING_FIELD", "message": "args.signal is required"}
    ok, trace = run_trace_once(request, state, signal, "driver")
    if not ok:
        return ok, trace
    edges = trace.get("dependency_edges", [])
    deps = [e.get("from", "") for e in edges if e.get("from")]
    assignment = {
        "target": signal,
        "rhs_signals": deps,
        "source": edges[0].get("source", "") if edges else "",
        "location": edges[0].get("location", {}) if edges else {},
    }
    if action == "control.explain":
        data = {"signal": signal, "control_dependencies": edges,
                "summary": {"signal": signal, "control_dependency_count": len(edges)}}
    elif action == "procedural.assignment":
        data = {"procedural_assignment": {"target": signal, "assignments": [assignment],
                                          "dependency_edges": edges, "confidence": "medium"},
                "summary": {"signal": signal, "assignment_count": 1 if edges else 0}}
    elif action == "sequential.update":
        data = {"sequential_update": {"target": signal, "rules": [assignment] if edges else [],
                                      "clock": None, "reset": None, "confidence": "low"},
                "summary": {"signal": signal, "rule_count": 1 if edges else 0, "confidence": "low"}}
    elif action == "fsm.explain":
        data = {"fsm": {"state_signal": signal, "transitions": [], "rules": [assignment] if edges else [],
                        "confidence": "low"},
                "summary": {"signal": signal, "transition_count": 0, "confidence": "low"}}
    else:
        counter_like = any(("+" in e.get("source", "") or "-" in e.get("source", "")) for e in edges)
        data = {"counter": {"signal": signal, "counter_like": counter_like,
                            "rules": [assignment] if edges else [], "confidence": "low"},
                "summary": {"signal": signal, "counter_like": counter_like,
                            "rule_count": 1 if edges else 0, "confidence": "low"}}
    return True, data


def design_mapping_action(action, request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    query = args.get("path", args.get("instance", args.get("interface", args.get("port", ""))))
    if not query:
        return False, {"code": "MISSING_FIELD", "message": "args.path/instance/interface/port is required"}
    child = dict(request)
    child["action"] = "signal.resolve"
    child["args"] = {"signal": query}
    ok, data = run_tcl_npi(child, state)
    if ok:
        data = postprocess_npi_data("signal.resolve", data)
    else:
        data = {"query": query, "status": "not_resolved", "reason": data.get("message", "")}
    data["summary"] = {"query": query, "status": data.get("status", "ok")}
    return True, data


def time_range_args(args):
    tr = args.get("time_range") if isinstance(args.get("time_range"), dict) else {}
    begin = args.get("begin", args.get("start", tr.get("begin", tr.get("start", ""))))
    end = args.get("end", args.get("stop", tr.get("end", tr.get("stop", ""))))
    return begin, end


def signal_scan(request, state, signal, begin="", end="", max_rows=None, fmt="bin"):
    child = dict(request)
    child["action"] = "signal.scan"
    child_args = dict(request.get("args") if isinstance(request.get("args"), dict) else {})
    child_args["signal"] = signal
    child_args["begin"] = begin
    child_args["end"] = end
    child_args["format"] = fmt
    child["args"] = child_args
    if max_rows is not None:
        limits = dict(request.get("limits") if isinstance(request.get("limits"), dict) else {})
        limits["max_rows"] = max_rows
        child["limits"] = limits
    ok, data = run_tcl_npi(child, state)
    if not ok:
        return ok, data
    return True, postprocess_npi_data("signal.scan", data)


def as_int_value(raw, radix=None):
    if raw is None:
        return None
    text = str(raw).strip().lower().replace("_", "")
    if "'" in text:
        left, right = text.split("'", 1)
        base = right[:1]
        body = right[1:]
        text = body
    else:
        base = (radix or "h").lower()[:1]
    if any(ch in text for ch in ("x", "z")):
        return None
    try:
        if base == "b":
            return int(text or "0", 2)
        if base == "d":
            return int(text or "0", 10)
        return int(text or "0", 16)
    except Exception:
        return None


def raw_known(raw):
    text = str(raw or "").lower()
    return "x" not in text and "z" not in text


def waveform_signal_action(action, request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    signal = args.get("signal", args.get("cnt", ""))
    if not signal:
        return False, {"code": "MISSING_FIELD", "message": "args.signal is required"}
    begin, end = time_range_args(args)
    max_rows = int((request.get("limits") if isinstance(request.get("limits"), dict) else {}).get("max_rows", args.get("max_items", 200)) or 200)
    ok, scan = signal_scan(request, state, signal, begin, end, max_rows, args.get("format", "bin"))
    if not ok:
        return ok, scan
    changes = scan.get("changes", [])
    values = [as_int_value(item.get("raw"), item.get("radix")) for item in changes]
    known = [raw_known(item.get("raw")) for item in changes]
    if action == "signal.changes":
        return True, {"signal": signal, "changes": changes, "truncated": scan.get("truncated", False),
                      "summary": {"signal": signal, "change_count": len(changes),
                                  "truncated": scan.get("truncated", False)}}
    if action == "signal.statistics":
        nums = [v for v in values if v is not None]
        summary = {"signal": signal, "sample_count": len(changes), "known_count": len(nums),
                   "unknown_count": len(changes) - len(nums)}
        if nums:
            summary.update({"min": min(nums), "max": max(nums), "first": nums[0], "last": nums[-1]})
        return True, {"signal": signal, "changes": changes, "statistics": summary, "summary": summary}
    if action == "signal.stability":
        first = changes[0].get("raw") if changes else None
        stable = all(item.get("raw") == first for item in changes)
        return True, {"signal": signal, "stable": stable, "changes": changes,
                      "summary": {"signal": signal, "stable": stable, "change_count": len(changes)}}
    if action == "signal.trend":
        nums = [v for v in values if v is not None]
        trend = "unknown"
        if len(nums) >= 2:
            trend = "up" if nums[-1] > nums[0] else "down" if nums[-1] < nums[0] else "flat"
        return True, {"signal": signal, "trend": trend, "values": nums, "changes": changes,
                      "summary": {"signal": signal, "trend": trend, "sample_count": len(nums)}}
    if action == "sampled_pulse.inspect":
        pulses = []
        last = None
        for item in changes:
            cur = as_int_value(item.get("raw"), item.get("radix"))
            if last == 0 and cur == 1:
                pulses.append({"time": item.get("time"), "edge": "rise"})
            last = cur
        return True, {"signal": signal, "pulses": pulses, "changes": changes,
                      "summary": {"signal": signal, "pulse_count": len(pulses)}}
    return unsupported(action)


def detect_anomaly_action(request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    signals = args.get("signals") if isinstance(args.get("signals"), list) else []
    if not signals and args.get("signal"):
        signals = [args.get("signal")]
    if not signals:
        return False, {"code": "MISSING_FIELD", "message": "args.signal or args.signals[] is required"}
    begin, end = time_range_args(args)
    findings = []
    rows = []
    for sig in signals:
        ok, scan = signal_scan(request, state, str(sig), begin, end, args.get("max_items", 128), args.get("format", "bin"))
        if not ok:
            findings.append({"signal": sig, "severity": "error", "code": scan.get("code", "SCAN_FAILED"),
                             "message": scan.get("message", "")})
            continue
        unknown = [c for c in scan.get("changes", []) if not raw_known(c.get("raw"))]
        if unknown:
            findings.append({"signal": sig, "severity": "warning", "code": "UNKNOWN_VALUE",
                             "count": len(unknown), "message": "signal contains X/Z values"})
        rows.append({"signal": sig, "change_count": len(scan.get("changes", [])),
                     "unknown_count": len(unknown), "truncated": scan.get("truncated", False)})
    return True, {"signals": rows, "findings": findings,
                  "summary": {"signal_count": len(signals), "finding_count": len(findings)}}


def compare_value(actual_raw, op, expected):
    actual = as_int_value(actual_raw)
    exp = as_int_value(expected)
    if op in ("==", "eq", "="):
        if actual is not None and exp is not None:
            return actual == exp
        return str(actual_raw).strip().lower() == str(expected).strip().lower()
    if op in ("!=", "ne"):
        if actual is not None and exp is not None:
            return actual != exp
        return str(actual_raw).strip().lower() != str(expected).strip().lower()
    if actual is None or exp is None:
        return False
    if op == ">":
        return actual > exp
    if op == ">=":
        return actual >= exp
    if op == "<":
        return actual < exp
    if op == "<=":
        return actual <= exp
    return False


def verify_conditions_action(request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    conditions = args.get("conditions") if isinstance(args.get("conditions"), list) else []
    time_at = args.get("time", args.get("at", ""))
    if not conditions or not time_at:
        return False, {"code": "MISSING_FIELD", "message": "args.conditions[] and args.time are required"}
    checks = []
    all_pass = True
    for cond in conditions:
        if not isinstance(cond, dict):
            continue
        sig = cond.get("signal", "")
        op = cond.get("op", "==")
        expected = cond.get("value", cond.get("expected", ""))
        child = {"api_version": request.get("api_version", PUBLIC_API_VERSION), "action": "value.at",
                 "target": request.get("target", {}),
                 "args": {"signal": sig, "time": time_at, "format": cond.get("format", "hex")}}
        ok, data = run_action(child, state)
        passed = ok and compare_value(data.get("raw_value", data.get("raw", "")), op, expected)
        all_pass = all_pass and passed
        checks.append({"signal": sig, "op": op, "expected": expected, "passed": passed,
                       "actual": data.get("raw_value", data.get("raw", None)) if ok else None,
                       "status": "ok" if ok else data.get("code", "failed")})
    return True, {"time": time_at, "checks": checks, "passed": all_pass,
                  "summary": {"time": time_at, "passed": all_pass, "check_count": len(checks)}}


def window_verify_action(request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    begin, end = time_range_args(args)
    conditions = args.get("conditions") if isinstance(args.get("conditions"), list) else []
    if not conditions:
        return False, {"code": "MISSING_FIELD", "message": "args.conditions[] is required"}
    checks = []
    all_pass = True
    for cond in conditions:
        if not isinstance(cond, dict):
            continue
        sig = cond.get("signal", "")
        ok, scan = signal_scan(request, state, sig, begin, end, 512, cond.get("format", "hex"))
        if not ok:
            all_pass = False
            checks.append({"signal": sig, "passed": False, "status": scan.get("code", "failed")})
            continue
        failed = []
        for item in scan.get("changes", []):
            if not compare_value(item.get("raw"), cond.get("op", "=="), cond.get("value", cond.get("expected", ""))):
                failed.append(item)
        passed = len(failed) == 0
        all_pass = all_pass and passed
        checks.append({"signal": sig, "passed": passed, "change_count": len(scan.get("changes", [])),
                       "failures": failed[:16]})
    return True, {"begin": begin, "end": end, "checks": checks, "passed": all_pass,
                  "summary": {"begin": begin, "end": end, "passed": all_pass, "check_count": len(checks)}}


def expr_eval_at_action(request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    expr = args.get("expr", "")
    time_at = args.get("time", args.get("at", ""))
    if not expr or not time_at:
        return False, {"code": "MISSING_FIELD", "message": "args.expr and args.time are required"}
    signals = args.get("signals") if isinstance(args.get("signals"), dict) else {}
    if not signals:
        names = sorted(set(re.findall(r"[A-Za-z_][A-Za-z0-9_.$]*", expr)))
        signals = dict((n, n) for n in names if n not in ("and", "or", "not"))
    values = {}
    for alias, sig in signals.items():
        child = {"api_version": request.get("api_version", PUBLIC_API_VERSION), "action": "value.at",
                 "target": request.get("target", {}), "args": {"signal": sig, "time": time_at, "format": "bin"}}
        ok, data = run_action(child, state)
        if ok:
            values[alias] = {"signal": sig, "raw": data.get("raw_value", data.get("raw", "")),
                             "int": as_int_value(data.get("raw_value", data.get("raw", "")), "b")}
    py_expr = expr.replace("&&", " and ").replace("||", " or ")
    py_expr = re.sub(r"(?<![=!<>])!(?!=)", " not ", py_expr)
    env = dict((k, bool(v.get("int"))) for k, v in values.items())
    result = None
    status = "ok"
    try:
        result = bool(eval(py_expr, {"__builtins__": {}}, env))
    except Exception as exc:
        status = "unsupported_expr"
        result = None
    return True, {"expr": expr, "time": time_at, "values": values, "result": result, "status": status,
                  "summary": {"expr": expr, "time": time_at, "status": status, "result": result}}


def handshake_inspect_action(request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    valid = args.get("valid", args.get("vld", ""))
    ready = args.get("ready", args.get("rdy", ""))
    if not valid or not ready:
        return False, {"code": "MISSING_FIELD", "message": "args.valid and args.ready are required"}
    begin, end = time_range_args(args)
    max_rows = int((request.get("limits") if isinstance(request.get("limits"), dict) else {}).get("max_rows", 256) or 256)
    okv, sv = signal_scan(request, state, valid, begin, end, max_rows, "bin")
    okr, sr = signal_scan(request, state, ready, begin, end, max_rows, "bin")
    if not okv:
        return okv, sv
    if not okr:
        return okr, sr
    times = sorted(set([c.get("time") for c in sv.get("changes", [])] + [c.get("time") for c in sr.get("changes", [])]))
    vmap = dict((c.get("time"), c.get("raw")) for c in sv.get("changes", []))
    rmap = dict((c.get("time"), c.get("raw")) for c in sr.get("changes", []))
    vcur = None
    rcur = None
    transfers = []
    stalls = []
    for t in times:
        if t in vmap:
            vcur = as_int_value(vmap[t], "b")
        if t in rmap:
            rcur = as_int_value(rmap[t], "b")
        if vcur:
            if rcur:
                transfers.append({"time": t})
            else:
                stalls.append({"time": t})
    return True, {"valid": valid, "ready": ready, "transfers": transfers, "stalls": stalls,
                  "summary": {"valid": valid, "ready": ready, "transfer_count": len(transfers),
                              "stall_count": len(stalls)}}


def inspect_signal_action(request, state):
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    sig = args.get("signal", "")
    if not sig:
        return False, {"code": "MISSING_FIELD", "message": "args.signal is required"}
    child = dict(request)
    child["action"] = "signal.info"
    child["args"] = {"signal": sig}
    ok, info = run_tcl_npi(child, state)
    if not ok:
        return ok, info
    scan_ok, scan = signal_scan(request, state, sig, "", "", 32, args.get("format", "bin"))
    data = postprocess_npi_data("signal.info", info)
    if scan_ok:
        data["changes_preview"] = scan.get("changes", [])
        data["summary"]["change_count_preview"] = len(scan.get("changes", []))
    return True, data


def config_store_action(prefix, action, request, state):
    store_name = prefix + "_configs"
    configs = read_state_json(state, store_name, {})
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    if action.endswith(".config.load"):
        name = args.get("name", "")
        if not name:
            return False, {"code": "MISSING_FIELD", "message": "args.name is required"}
        config = dict(args)
        if args.get("config") and isinstance(args.get("config"), dict):
            config.update(args.get("config"))
        configs[name] = config
        write_state_json(state, store_name, configs)
        return True, {"name": name, "status": "loaded", "config": config,
                      "summary": {"name": name, "status": "loaded"}}
    if action.endswith(".config.list"):
        name = args.get("name", "")
        if name:
            if name not in configs:
                return False, {"code": "CONFIG_NOT_FOUND", "message": name}
            return True, {"name": name, "config": configs[name], "summary": {"name": name}}
        return True, {"configs": [{"name": k, "config": v} for k, v in sorted(configs.items())],
                      "summary": {"count": len(configs)}}
    return unsupported(action)


def protocol_query_action(prefix, action, request, state):
    if action.endswith(".config.load") or action.endswith(".config.list"):
        return config_store_action(prefix, action, request, state)
    return unsupported(action)


def stream_action(action, request, state):
    streams = read_state_json(state, "stream_configs", {})
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    if action == "stream.config.load":
        items = args.get("streams") if isinstance(args.get("streams"), list) else []
        if not items and isinstance(args.get("config"), dict):
            items = [args.get("config")]
        if not items:
            return False, {"code": "MISSING_FIELD", "message": "args.streams[] is required"}
        mode = args.get("mode", "replace")
        if mode == "replace":
            streams = {}
        for item in items:
            if isinstance(item, dict) and item.get("name"):
                streams[item.get("name")] = item
        write_state_json(state, "stream_configs", streams)
        return True, {"streams": list(streams.keys()), "summary": {"loaded": len(items), "mode": mode}}
    if action == "stream.config.list":
        return True, {"streams": [{"name": k, "config": v} for k, v in sorted(streams.items())],
                      "summary": {"count": len(streams)}}
    name = args.get("stream", args.get("name", ""))
    if not name or name not in streams:
        return False, {"code": "STREAM_NOT_FOUND", "message": name}
    cfg = streams[name]
    if action == "stream.show":
        return True, {"stream": name, "config": cfg, "summary": {"stream": name}}
    return unsupported(action)


def unsupported(action):
    return False, {
        "code": "NOT_IMPLEMENTED",
        "message": "Tcl NPI backend does not yet implement action: " + action,
    }


def run_action(request, state):
    action = request.get("action", "")
    if action in ("server.ping",):
        return True, {"pong": True}
    if action == "server.version":
        return True, {"api_version": INTERNAL_API_VERSION}
    if action in ("source.context",):
        return source_context(request)
    if action == "expr.normalize":
        args = request.get("args") if isinstance(request.get("args"), dict) else {}
        if args.get("signal"):
            ok, data = run_trace_once(request, state, args.get("signal"), "driver")
            if ok:
                deps = [e.get("from", "") for e in data.get("dependency_edges", []) if e.get("from")]
                return True, {"expr": {"text": data.get("dependency_edges", [{}])[0].get("source", "")
                                        if data.get("dependency_edges") else "",
                                        "signals": deps},
                              "assignment": data.get("dependency_edges", [{}])[0] if data.get("dependency_edges") else {},
                              "confidence": "medium" if deps else "low",
                              "summary": {"signal": args.get("signal"), "source": "npi_trace_assignment"}}
        return expr_normalize(request)
    if action == "rc.generate":
        return rc_generate(request)
    if action.startswith("cursor."):
        return cursor_action(action, request, state)
    if action.startswith("list."):
        return list_action(action, request, state)
    if action == "trace.active_driver":
        return active_driver_action(request, state)
    if action == "trace.active_driver_chain":
        return active_driver_chain_action(request, state)
    if action in ("trace.driver", "trace.load", "trace.query", "port.trace_batch", "signal.resolve",
                  "signal.canonicalize", "signal.info", "signal.scan",
                  "value.at", "value.batch_at", "scope.list",
                  "npi.capabilities", "language.resolve", "language.iterate",
                  "language.relate", "language.value", "module.objects",
                  "module.find_instances", "module.inspect", "module.inspect_batch",
                  "netlist.resolve", "netlist.iterate",
                  "text.line", "text.words", "text.replace_line",
                  "dm.add_net", "dm.clone_module", "vcs.summary",
                  "power.resolve", "power.list", "crdb.resolve",
                  "crdb.correlates", "transaction.writer.create",
                  "fsdb.writer.create_scope"):
        ok, data = run_tcl_npi(request, state)
        if not ok:
            return False, data
        return True, postprocess_npi_data(action, data)
    if action in ("trace.expand", "trace.graph", "trace.explain"):
        return trace_expand_action(action, request, state)
    if action == "trace.path":
        return trace_path_action(request, state)
    if action in ("control.explain", "procedural.assignment", "sequential.update",
                  "fsm.explain", "counter.explain"):
        return design_semantic_action(action, request, state)
    if action in ("port.trace", "instance.map", "interface.resolve"):
        return design_mapping_action(action, request, state)
    if action in ("signal.changes", "signal.stability", "signal.trend", "signal.statistics",
                  "counter.statistics", "sampled_pulse.inspect"):
        return waveform_signal_action("signal.statistics" if action == "counter.statistics" else action, request, state)
    if action == "detect_anomaly":
        return detect_anomaly_action(request, state)
    if action == "inspect_signal":
        return inspect_signal_action(request, state)
    if action == "verify.conditions":
        return verify_conditions_action(request, state)
    if action == "window.verify":
        return window_verify_action(request, state)
    if action == "expr.eval_at":
        return expr_eval_at_action(request, state)
    if action == "handshake.inspect":
        return handshake_inspect_action(request, state)
    if action.startswith("event."):
        return config_store_action("event", action, request, state) if ".config." in action else unsupported(action)
    if action.startswith("axi."):
        return protocol_query_action("axi", action, request, state)
    if action.startswith("apb."):
        return protocol_query_action("apb", action, request, state)
    if action.startswith("stream."):
        return stream_action(action, request, state)
    return False, {"code": "UNKNOWN_ACTION", "message": "unknown action: " + action}


def wrap_public_action_response(request, ok, data_or_err, state=None):
    action = request.get("action", "")
    if ok:
        data = data_or_err or {}
        summary = data.get("summary") if isinstance(data.get("summary"), dict) else {}
        return make_public_response(request, action, True, data=data, summary=summary,
                                    session=session_record_json(state["record"]) if state and state.get("record") else None)
    return make_action_error_response(request, action, data_or_err)


def write_endpoint(record):
    endpoint = {"version": 1, "endpoint": {
        "transport": record.get("transport", "uds"),
        "socket_path": record.get("socket_path", ""),
        "file_dir": record.get("file_dir", ""),
        "host": record.get("host", ""),
        "bind_host": record.get("bind_host", ""),
        "port": record.get("port", 0),
        "server_host": record.get("server_host", current_host_name()),
        "auth_token": record.get("auth_token", ""),
    }}
    atomic_write_json(endpoint_path(record["session_id"]), endpoint)


def write_session_file(record):
    atomic_write_json(session_json_path(record["session_id"]), {"version": 1, "session": record})


def public_session_manifest(record):
    pub_dir = os.path.join(kdebug_home(), "sessions", session_dir_name(record["session_id"]))
    mkdir_p(pub_dir)
    manifest = {
        "session_id": record["session_id"],
        "mode": record.get("mode", target_mode({"daidir": record.get("dbdir_path"),
                                                "fsdb": record.get("fsdb_file")})),
        "created_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()),
        "last_log_at": time.strftime("%Y-%m-%dT%H:%M:%S%z", time.localtime()),
    }
    if record.get("dbdir_path"):
        manifest["daidir"] = record.get("dbdir_path")
    if record.get("fsdb_file"):
        manifest["fsdb"] = record.get("fsdb_file")
    atomic_write_json(os.path.join(pub_dir, "session.json"), manifest)


def parse_server_options(argv):
    session_id = argv[0] if argv else ""
    opts = {"session_id": session_id, "transport": "uds", "bind_host": "", "host": "",
            "port": 0, "auth_token": "", "daidir": "", "fsdb": ""}
    i = 1
    while i < len(argv):
        arg = argv[i]
        if arg == "--transport" and i + 1 < len(argv):
            opts["transport"] = argv[i + 1]; i += 2
        elif arg == "--bind" and i + 1 < len(argv):
            opts["bind_host"] = argv[i + 1]; i += 2
        elif arg == "--host" and i + 1 < len(argv):
            opts["host"] = argv[i + 1]; i += 2
        elif arg == "--port" and i + 1 < len(argv):
            opts["port"] = int(argv[i + 1] or 0); i += 2
        elif arg == "--auth" and i + 1 < len(argv):
            opts["auth_token"] = argv[i + 1]; i += 2
        elif arg == "-dbdir" and i + 1 < len(argv):
            opts["daidir"] = argv[i + 1]; i += 2
        elif arg in ("-fsdb", "-ssf") and i + 1 < len(argv):
            opts["fsdb"] = argv[i + 1]; i += 2
        else:
            i += 1
    return opts


def make_record(opts):
    sid = opts["session_id"]
    mode = target_mode({"daidir": opts.get("daidir"), "fsdb": opts.get("fsdb")})
    transport = opts.get("transport") or "uds"
    record = {
        "session_id": sid,
        "transport": transport,
        "socket_path": socket_path(sid),
        "file_dir": "",
        "host": opts.get("host", ""),
        "bind_host": opts.get("bind_host", ""),
        "port": int(opts.get("port", 0) or 0),
        "server_host": current_host_name(),
        "auth_token": opts.get("auth_token", ""),
        "design_file": opts.get("daidir", ""),
        "dbdir_path": opts.get("daidir", ""),
        "fsdb_file": opts.get("fsdb", ""),
        "server_pid": os.getpid(),
        "created_at": int(time.time()),
        "last_active": int(time.time()),
        "mode": mode,
    }
    if transport == "file":
        record["file_dir"] = os.path.join(session_dir(sid), "transport")
    return record


def open_session(request):
    target = request.get("target") if isinstance(request.get("target"), dict) else {}
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    name = args.get("name") or target.get("name") or ""
    if not name:
        return make_error_response(request, "session.open", "MISSING_FIELD", "args.name is required")
    if not valid_session_name(name):
        return make_error_response(request, "session.open", "INVALID_SESSION_NAME", session_name_rule())
    mode = target_mode(target)
    if not mode:
        return make_error_response(request, "session.open", "RESOURCE_REQUIRED", "target.daidir or target.fsdb is required")
    opts = {
        "session_id": name,
        "transport": args.get("transport", target.get("transport", "uds")),
        "bind_host": args.get("bind_host", args.get("bind", target.get("bind_host", ""))),
        "host": args.get("host", target.get("host", "")),
        "port": int(args.get("port", target.get("port", 0)) or 0),
        "auth_token": args.get("auth_token", ""),
        "daidir": target.get("daidir", target.get("dbdir", "")),
        "fsdb": target.get("fsdb", ""),
    }
    if opts["daidir"]:
        try:
            design_database = resolve_design_database({"daidir": opts["daidir"]})
            opts["daidir"] = design_database.get("path", opts["daidir"])
        except DesignDatabaseError as exc:
            return make_error_response(request, "session.open", exc.code, str(exc))
    engine_exe = os.environ.get("KDEBUG_ENGINE_EXE") or os.path.abspath(sys.argv[0])
    cmd = [engine_exe, "--server", name]
    if opts["transport"]:
        cmd.extend(["--transport", opts["transport"]])
    if opts["bind_host"]:
        cmd.extend(["--bind", opts["bind_host"]])
    if opts["host"]:
        cmd.extend(["--host", opts["host"]])
    if opts["port"]:
        cmd.extend(["--port", str(opts["port"])])
    if opts["auth_token"]:
        cmd.extend(["--auth", opts["auth_token"]])
    if opts["daidir"]:
        cmd.extend(["-dbdir", opts["daidir"]])
    if opts["fsdb"]:
        cmd.extend(["-fsdb", opts["fsdb"]])

    mkdir_p(session_dir(name))
    stdout = open(os.path.join(session_dir(name), "server.out"), "a")
    stderr = open(os.path.join(session_dir(name), "server.err"), "a")
    proc = subprocess.Popen(cmd, stdin=open(os.devnull), stdout=stdout, stderr=stderr,
                            close_fds=True, cwd=os.getcwd())
    deadline = time.time() + 20
    endpoint = None
    while time.time() < deadline:
        if proc.poll() is not None:
            return make_error_response(request, "session.open", "SESSION_START_FAILED",
                                       "engine server exited with code %s" % proc.returncode)
        endpoint = read_json_file(endpoint_path(name))
        if isinstance(endpoint, dict):
            break
        time.sleep(0.05)
    if not isinstance(endpoint, dict):
        try:
            proc.terminate()
        except Exception:
            pass
        return make_error_response(request, "session.open", "SESSION_START_TIMEOUT",
                                   "engine server did not publish endpoint")
    rec = make_record(opts)
    rec["server_pid"] = proc.pid
    ep = endpoint.get("endpoint", {})
    for key in ("transport", "socket_path", "file_dir", "host", "bind_host", "port",
                "server_host", "auth_token"):
        if key in ep:
            rec[key] = ep[key]
    Registry().upsert(rec)
    write_session_file(rec)
    public_session_manifest(rec)
    session_json = session_record_json(rec)
    return make_public_response(request, "session.open", True,
                                data={"session": session_json},
                                summary={"session_id": name, "id": name, "status": "opened"},
                                session=session_json)


def pid_alive(pid):
    try:
        if not pid:
            return False
        os.kill(int(pid), 0)
        return True
    except Exception:
        return False


def diagnose_session(session_id):
    rec = Registry().get(session_id)
    if not rec:
        return False, None, "session not found: " + session_id
    transport = rec.get("transport") or "uds"
    endpoint_exists = True
    if transport == "uds":
        endpoint_exists = os.path.exists(rec.get("socket_path", ""))
    elif transport == "file":
        endpoint_exists = os.path.isdir(rec.get("file_dir", ""))
    healthy = pid_alive(rec.get("server_pid")) and endpoint_exists
    return healthy, rec, "healthy" if healthy else "session endpoint or process is not alive"


def session_doctor(request):
    target = request.get("target") if isinstance(request.get("target"), dict) else {}
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    sid = target.get("session_id") or args.get("session_id") or args.get("id") or ""
    if not sid:
        return make_error_response(request, "session.doctor", "MISSING_FIELD", "target.session_id is required")
    healthy, rec, message = diagnose_session(sid)
    session_json = session_record_json(rec) if rec else None
    resp = make_public_response(request, "session.doctor", healthy,
                                data={"health": {"session_id": sid, "healthy": healthy, "message": message}},
                                summary={"session_id": sid, "healthy": healthy, "message": message},
                                session=session_json)
    if not healthy:
        resp["error"] = {"code": "SESSION_UNHEALTHY", "message": message,
                         "recoverable": True, "candidates": [], "suggested_actions": []}
    return resp


def send_quit(record):
    transport = record.get("transport") or "uds"
    req = {"api_version": INTERNAL_API_VERSION, "action": "server.quit", "args": {}}
    try:
        if transport == "uds":
            s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            s.settimeout(1.0)
            s.connect(record.get("socket_path"))
            s.sendall((json.dumps(req) + "\n").encode("utf-8"))
            s.close()
            return True
        if transport == "tcp":
            s = socket.create_connection((record.get("host") or "127.0.0.1", int(record.get("port"))), timeout=1.0)
            req["auth_token"] = record.get("auth_token", "")
            s.sendall((json.dumps(req) + "\n").encode("utf-8"))
            s.close()
            return True
    except Exception:
        return False
    return False


def session_kill(request):
    target = request.get("target") if isinstance(request.get("target"), dict) else {}
    args = request.get("args") if isinstance(request.get("args"), dict) else {}
    sid = target.get("session_id") or args.get("session_id") or args.get("id") or ""
    if sid == "all":
        removed = 0
        for rec in Registry().list():
            child = {"api_version": request.get("api_version", PUBLIC_API_VERSION),
                     "action": "session.kill",
                     "target": {"session_id": rec.get("session_id")}}
            r = session_kill(child)
            if r.get("ok"):
                removed += 1
        return make_public_response(request, request.get("action", "session.kill"), True,
                                    data={"removed_count": removed},
                                    summary={"target": "all", "removed_count": removed})
    if not sid:
        return make_error_response(request, request.get("action", "session.kill"),
                                   "MISSING_FIELD", "target.session_id is required")
    rec = Registry().get(sid)
    if not rec:
        return make_error_response(request, request.get("action", "session.kill"),
                                   "SESSION_NOT_FOUND", "session not found: " + sid)
    send_quit(rec)
    pid = rec.get("server_pid")
    if pid_alive(pid):
        try:
            os.kill(int(pid), signal.SIGTERM)
        except Exception:
            pass
    if rec.get("socket_path") and os.path.exists(rec.get("socket_path")):
        try:
            os.unlink(rec.get("socket_path"))
        except Exception:
            pass
    Registry().remove(sid)
    for p in (endpoint_path(sid), session_json_path(sid)):
        try:
            os.unlink(p)
        except OSError:
            pass
    return make_public_response(request, request.get("action", "session.kill"), True,
                                data={"session": session_record_json(rec), "removed": True},
                                summary={"session_id": sid, "mode": rec.get("mode", ""), "removed": True})


def session_list(request):
    records = [session_record_json(r) for r in Registry().list()]
    return make_public_response(request, "session.list", True, data={"sessions": records},
                                summary={"session_count": len(records)})


def one_shot_session_action(request):
    action = request.get("action", "")
    if action == "session.open":
        return open_session(request)
    if action == "session.list":
        return session_list(request)
    if action == "session.doctor":
        return session_doctor(request)
    if action in ("session.kill", "session.close"):
        return session_kill(request)
    return make_error_response(request, action, "UNKNOWN_ACTION", "unknown session action: " + action)


def send_to_uds(record, request, timeout_ms):
    s = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        s.settimeout(timeout_ms / 1000.0 if timeout_ms > 0 else None)
        s.connect(record.get("socket_path"))
        s.sendall((json.dumps(request) + "\n").encode("utf-8"))
        chunks = []
        while True:
            data = s.recv(65536)
            if not data:
                break
            chunks.append(data)
        return json.loads(b"".join(chunks).decode("utf-8"))
    finally:
        s.close()


def ensure_file_layout(path):
    for sub in ("requests", "claims", "responses", "done", "failed", "tmp", "heartbeat"):
        mkdir_p(os.path.join(path, sub))


def file_exchange_send(record, request, timeout_ms):
    root = record.get("file_dir")
    ensure_file_layout(root)
    rid = "req-%d-%d" % (now_us(), os.getpid())
    req_path = os.path.join(root, "requests", rid + ".json")
    rsp_path = os.path.join(root, "responses", rid + ".json")
    wrapper = {
        "version": FILE_RPC_VERSION,
        "id": rid,
        "created_at_us": now_us(),
        "deadline_us": now_us() + timeout_ms * 1000,
        "client": {"host": current_host_name(), "pid": os.getpid()},
        "request": request,
    }
    atomic_write_json(req_path, wrapper)
    deadline = time.time() + timeout_ms / 1000.0
    while time.time() < deadline:
        rsp = read_json_file(rsp_path)
        if isinstance(rsp, dict):
            try:
                os.rename(rsp_path, os.path.join(root, "done", rid + ".response.json"))
            except Exception:
                pass
            return rsp.get("response", {})
        time.sleep(0.02)
    return internal_error("SESSION_TRANSPORT_FAILED", "file transport request timed out")


def route_to_session(record, request):
    timeout_ms = parse_timeout_ms(request, 30000)
    transport = record.get("transport") or "uds"
    rpc = dict(request)
    rpc["api_version"] = INTERNAL_API_VERSION
    if transport == "file":
        return file_exchange_send(record, rpc, timeout_ms)
    if transport == "uds":
        return send_to_uds(record, rpc, timeout_ms)
    return internal_error("SESSION_TRANSPORT_FAILED", "unsupported transport in Tcl backend: " + transport)


def one_shot_engine_action(request):
    target = request.get("target") if isinstance(request.get("target"), dict) else {}
    sid = target.get("session_id")
    if sid:
        record = Registry().get(sid)
        if not record:
            return make_error_response(request, request.get("action", ""), "SESSION_NOT_FOUND", "session not found: " + sid)
        try:
            engine_resp = route_to_session(record, request)
        except Exception as exc:
            return make_error_response(request, request.get("action", ""), "SESSION_TRANSPORT_FAILED", str(exc))
        if engine_resp.get("ok"):
            data = engine_resp.get("data") or {}
            return make_public_response(request, request.get("action", ""), True,
                                        data=data,
                                        summary=data.get("summary", {}),
                                        session=session_record_json(record))
        err = engine_resp.get("error") or {}
        return make_error_response(request, request.get("action", ""),
                                   err.get("code", "INTERNAL_ENGINE_FAILED"),
                                   err.get("message", "engine session action failed"))
    state = {"session_id": "adhoc", "target": target, "record": None}
    ok, data = run_action(request, state)
    return wrap_public_action_response(request, ok, data, state)


def handle_one_shot_query():
    request, err = parse_json_stdin()
    if request is None:
        response = make_error_response({"api_version": PUBLIC_API_VERSION}, "", "INVALID_JSON", err, False)
        print(json.dumps(response))
        return 0
    action = request.get("action", "")
    if action.startswith("session."):
        response = one_shot_session_action(request)
    else:
        response = one_shot_engine_action(request)
    print(json.dumps(response))
    return 0


def read_line(conn):
    chunks = []
    while True:
        data = conn.recv(1)
        if not data:
            break
        if data == b"\n":
            break
        chunks.append(data)
    if not chunks:
        return ""
    return b"".join(chunks).decode("utf-8")


def handle_server_request(request, state):
    action = request.get("action", "")
    if action == "server.quit":
        return internal_ok({}), True
    if action == "server.ping":
        return internal_ok({"pong": True}), False
    if action == "server.version":
        return internal_ok({"api_version": INTERNAL_API_VERSION}), False
    if action == "session.list":
        rec = state.get("record") or {}
        return internal_ok({"sessions": [session_record_json(rec)],
                            "summary": {"session_count": 1}}), False
    if action == "session.doctor":
        rec = state.get("record") or {}
        return internal_ok({"session_id": state.get("session_id"), "healthy": True,
                            "has_design": bool(rec.get("dbdir_path")),
                            "has_waveform": bool(rec.get("fsdb_file")),
                            "summary": {"session_id": state.get("session_id"), "healthy": True}}), False
    ok, data = run_action(request, state)
    if ok:
        return internal_ok(data), False
    return internal_error(data.get("code", "ACTION_FAILED"), data.get("message", "action failed"), data), False


def serve_uds(record, state):
    path = record.get("socket_path")
    mkdir_p(os.path.dirname(path))
    try:
        os.unlink(path)
    except OSError:
        pass
    srv = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    srv.bind(path)
    os.chmod(path, 0o600)
    srv.listen(8)
    write_endpoint(record)
    Registry().upsert(record)
    write_session_file(record)
    log_lifecycle(record["session_id"], "transport.listen_ok", True, {"transport": "uds", "socket_path": path})
    should_quit = False
    while not should_quit:
        conn, _ = srv.accept()
        with conn:
            try:
                line = read_line(conn)
                request = json.loads(line)
                response, should_quit = handle_server_request(request, state)
            except Exception as exc:
                response = internal_error("INVALID_REQUEST", str(exc))
            conn.sendall((json.dumps(response) + "\n").encode("utf-8"))
    srv.close()
    try:
        os.unlink(path)
    except OSError:
        pass


def serve_file(record, state):
    root = record.get("file_dir")
    ensure_file_layout(root)
    write_endpoint(record)
    Registry().upsert(record)
    write_session_file(record)
    agent_id = current_host_name() + "-" + str(os.getpid())
    should_quit = False
    while not should_quit:
        atomic_write_json(os.path.join(root, "heartbeat", agent_id + ".json"), {
            "version": FILE_RPC_VERSION,
            "ok": True,
            "session_id": record["session_id"],
            "transport": "file",
            "worker": {"agent_id": agent_id, "host": current_host_name(), "pid": os.getpid()},
            "updated_at_us": now_us(),
        })
        claimed = False
        req_dir = os.path.join(root, "requests")
        for name in sorted(os.listdir(req_dir)):
            if not name.endswith(".json"):
                continue
            rid = name[:-5]
            src = os.path.join(req_dir, name)
            claim = os.path.join(root, "claims", rid + "." + agent_id + ".json")
            try:
                os.rename(src, claim)
            except OSError:
                continue
            claimed = True
            wrapper = read_json_file(claim, {})
            request = wrapper.get("request", {})
            response, should_quit = handle_server_request(request, state)
            rsp = {
                "version": FILE_RPC_VERSION,
                "id": rid,
                "ok": bool(response.get("ok")),
                "status": "ok" if response.get("ok") else "server_error",
                "message": "",
                "created_at_us": wrapper.get("created_at_us", now_us()),
                "finished_at_us": now_us(),
                "worker": {"agent_id": agent_id, "host": current_host_name(), "pid": os.getpid()},
                "response": response,
            }
            atomic_write_json(os.path.join(root, "responses", rid + ".json"), rsp)
            try:
                os.rename(claim, os.path.join(root, "done", rid + ".claim.json"))
            except OSError:
                pass
            break
        if not claimed:
            time.sleep(0.02)


def server_main(argv):
    if not argv:
        print("Server mode requires session_id argument", file=sys.stderr)
        return 1
    opts = parse_server_options(argv)
    sid = opts.get("session_id")
    mkdir_p(session_dir(sid))
    log_lifecycle(sid, "server.start", True, {"argc": 1 + len(argv)})
    log_lifecycle(sid, "env.snapshot", True, env_snapshot(argv))
    if os.environ.get("KDEBUG_ENGINE_TEST_CRASH_MARKER"):
        write_crash_marker(sid)
        return 128 + signal.SIGABRT
    if not opts.get("daidir") and not opts.get("fsdb"):
        print("Server requires at least -dbdir or -fsdb", file=sys.stderr)
        return 1
    record = make_record(opts)
    state = {
        "session_id": sid,
        "target": {"daidir": record.get("dbdir_path", ""), "fsdb": record.get("fsdb_file", "")},
        "record": record,
    }
    try:
        if record.get("transport") == "file":
            serve_file(record, state)
        else:
            serve_uds(record, state)
        log_lifecycle(sid, "server.normal_exit", True)
        return 0
    except KeyboardInterrupt:
        return 0
    except Exception as exc:
        log_lifecycle(sid, "server.failed", False, {"message": str(exc)})
        print(str(exc), file=sys.stderr)
        return 1


def main(argv):
    if len(argv) >= 2 and argv[0] == "--server":
        return server_main(argv[1:])
    if len(argv) == 3 and argv[0] == "ai" and argv[1] == "query" and argv[2] == "-":
        return handle_one_shot_query()
    print("ERROR: kdebug Tcl internal engine accepts JSON requests only", file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
