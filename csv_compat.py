#!/usr/bin/env python3

import csv
import sys


def configure_csv_field_size_limit() -> int:
    """Raise Python's small default CSV field limit to the platform maximum."""
    candidate = sys.maxsize
    while candidate > 0:
        try:
            csv.field_size_limit(candidate)
            return candidate
        except OverflowError:
            candidate //= 10
    raise RuntimeError("could not configure CSV field size limit")
