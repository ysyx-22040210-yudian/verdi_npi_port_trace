#!/usr/bin/env python3
"""Portable helpers for bounded runtime-generated file names.

The helpers in this module deliberately leave short names unchanged.  When a
generated component is too large for the target filesystem, only its readable
prefix is shortened; a digest of the original identity keeps the result stable
and collision resistant.
"""

import argparse
import hashlib
import os
import re
import sys
from pathlib import Path


DEFAULT_COMPONENT_LIMIT = 255
HASH_MARKER = "__h_"
HASH_HEX_LENGTH = 16
BASE_HASH_MARKER = "__b_"
BASE_HASH_HEX_LENGTH = 12
DERIVED_BASE_PREFIX_BYTES = 96


def sanitize_component(text):
    """Return an ASCII filename token compatible with the legacy sanitizers."""

    value = str(text if text is not None else "")
    value = re.sub(r"[^A-Za-z0-9_.-]+", "_", value)
    return value.strip("._") or "unnamed"


def component_name_limit(parent=None):
    """Return the parent's NAME_MAX, capped at the portable 255-byte limit."""

    pathconf = getattr(os, "pathconf", None)
    if pathconf is None:
        return DEFAULT_COMPONENT_LIMIT

    target = Path(os.curdir if parent is None else parent)
    while True:
        try:
            value = int(pathconf(str(target), "PC_NAME_MAX"))
        except (AttributeError, OSError, TypeError, ValueError):
            parent_target = target.parent
            if parent_target == target:
                return DEFAULT_COMPONENT_LIMIT
            target = parent_target
            continue
        if value <= 0:
            return DEFAULT_COMPONENT_LIMIT
        return min(value, DEFAULT_COMPONENT_LIMIT)


def _candidate_with_suffix(candidate, suffix):
    candidate = str(candidate)
    suffix = str(suffix or "")
    if suffix and candidate.endswith(suffix):
        return candidate[:-len(suffix)], candidate
    return candidate, candidate + suffix


def _utf8_prefix(text, byte_budget):
    if byte_budget <= 0:
        return ""
    encoded = text.encode("utf-8")
    if len(encoded) <= byte_budget:
        return text
    return encoded[:byte_budget].decode("utf-8", errors="ignore")


def bounded_component(candidate, suffix="", parent=None, identity=None):
    """Build one filename component without exceeding the parent's NAME_MAX.

    ``candidate`` may include ``suffix`` already; passing the same suffix is
    idempotent.  The suffix is always preserved when shortening is required.
    Hashing includes the original candidate plus ``identity`` when supplied;
    otherwise the candidate is used in both hash domains.  This distinguishes
    different output bases as well as identities that sanitize to one token.
    """

    candidate = str(candidate)
    suffix = str(suffix or "")
    stem, full_name = _candidate_with_suffix(candidate, suffix)
    limit = component_name_limit(parent)
    if len(full_name.encode("utf-8")) <= limit:
        return full_name

    identity_text = str(identity) if identity not in (None, "") else candidate
    digest_source = candidate + "\0" + identity_text
    digest = hashlib.sha256(digest_source.encode("utf-8")).hexdigest()[:HASH_HEX_LENGTH]
    hash_part = HASH_MARKER + digest
    fixed_bytes = len(hash_part.encode("utf-8")) + len(suffix.encode("utf-8"))
    if fixed_bytes > limit:
        raise ValueError(
            "filename suffix and hash require {} bytes but NAME_MAX is {}".format(
                fixed_bytes, limit
            )
        )

    readable = _utf8_prefix(stem, limit - fixed_bytes)
    return readable + hash_part + suffix


def bounded_path(path, suffix="", identity=None):
    """Return ``path`` with its final component bounded for its parent."""

    result = Path(path)
    if not result.name:
        raise ValueError("path must contain a filename component")
    name = bounded_component(
        result.name,
        suffix=suffix,
        parent=result.parent,
        identity=identity,
    )
    return result.with_name(name)


def _derived_anchor(base, marker, suffix):
    limit = component_name_limit(base.parent)
    base_digest = hashlib.sha256(base.name.encode("utf-8")).hexdigest()[
        :BASE_HASH_HEX_LENGTH
    ]
    base_key = BASE_HASH_MARKER + base_digest
    fixed = base_key + marker + HASH_MARKER + ("0" * HASH_HEX_LENGTH) + suffix
    base_budget = max(0, limit - len(fixed.encode("utf-8")))
    base_budget = min(base_budget, DERIVED_BASE_PREFIX_BYTES)
    return _utf8_prefix(base.stem, base_budget) + base_key + marker


def bounded_derived_path(
    base,
    marker,
    identity,
    suffix=None,
    readable_identity=None,
):
    """Build a bounded sibling name while preserving its discovery marker."""

    base = Path(base)
    suffix = base.suffix if suffix is None else str(suffix)
    readable = sanitize_component(
        identity if readable_identity is None else readable_identity
    )
    requested_name = base.stem + marker + readable + suffix
    requested = base.with_name(requested_name)
    limit = component_name_limit(base.parent)
    if len(requested_name.encode("utf-8")) <= limit:
        return requested

    digest_source = requested_name + "\0" + str(identity)
    digest = hashlib.sha256(digest_source.encode("utf-8")).hexdigest()[:HASH_HEX_LENGTH]
    hash_part = HASH_MARKER + digest
    anchor = _derived_anchor(base, marker, suffix)
    readable_budget = (
        limit
        - len(anchor.encode("utf-8"))
        - len(hash_part.encode("utf-8"))
        - len(suffix.encode("utf-8"))
    )
    result_name = anchor + _utf8_prefix(readable, readable_budget) + hash_part + suffix
    if len(result_name.encode("utf-8")) > limit:
        raise ValueError("derived filename cannot fit within NAME_MAX")
    return base.with_name(result_name)


def derived_glob_prefixes(base, marker, suffix=None):
    """Return legacy and shortened prefixes used to discover derived siblings."""

    base = Path(base)
    suffix = base.suffix if suffix is None else str(suffix)
    legacy = base.stem + marker
    shortened = _derived_anchor(base, marker, suffix)
    return (legacy,) if legacy == shortened else (legacy, shortened)


def fixed_temp_prefix(purpose="write"):
    """Return a short mkstemp prefix independent of the destination basename."""

    token = sanitize_component(purpose or "write")
    token = _utf8_prefix(token, 32) or "write"
    return ".kdebug-{}-".format(token)


def _unbounded_path(path, suffix):
    path = Path(path)
    if not path.name:
        raise ValueError("path must contain a filename component")
    _, full_name = _candidate_with_suffix(path.name, suffix)
    return path.with_name(full_name)


def parse_args(argv=None):
    parser = argparse.ArgumentParser(
        description="Bound the final component of a runtime-generated path."
    )
    parser.add_argument("--path", required=True, help="path or path stem to bound")
    parser.add_argument("--suffix", default="", help="suffix to preserve, such as .csv")
    parser.add_argument(
        "--identity",
        default=None,
        help="stable unsanitized identity used to distinguish shortened names",
    )
    return parser.parse_args(argv)


def main(argv=None):
    args = parse_args(argv)
    original = _unbounded_path(args.path, args.suffix)
    result = bounded_path(args.path, suffix=args.suffix, identity=args.identity)
    if result != original:
        print("[runtime_paths] original={}".format(original), file=sys.stderr)
        print("[runtime_paths] bounded={}".format(result), file=sys.stderr)
    print(str(result))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
