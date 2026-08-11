#!/usr/bin/env python3

import re
from pathlib import Path
from typing import List


NAME_LIST_SEPARATOR = re.compile(r"[\s,;\uFF0C\uFF1B]+")


def split_name_list_text(text: str) -> List[str]:
    """Parse list-file text with the same separators accepted by the GUI."""
    items: List[str] = []
    for line in text.splitlines():
        content = line.split("#", 1)[0].strip()
        if not content:
            continue
        items.extend(item for item in NAME_LIST_SEPARATOR.split(content) if item)
    return items


def read_name_list_file(path: Path) -> List[str]:
    return split_name_list_text(path.read_text(encoding="utf-8-sig"))
