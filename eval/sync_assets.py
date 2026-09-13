#!/usr/bin/env python3
"""Extract the app's on-device fault-code library into eval/dtc_knowledge.json.

The grounding grader needs to know what the model was legitimately told about a
code (title, detail, causes). Rather than duplicating that table, this script
reads the Swift source, so the eval corpus can never drift from the app.

    python3 eval/sync_assets.py
"""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
SOURCE = ROOT / "OBDiag" / "OBD" / "DTCKnowledge.swift"
DEST = Path(__file__).with_name("dtc_knowledge.json")

ENTRY = re.compile(r'"([A-Z][0-9A-Z]{4})":\s*e\(\s*"([^"]*)",\s*"([^"]*)",\s*\.(\w+)')
ARRAY = re.compile(r"\[(.*?)\]", re.S)
STRING = re.compile(r'"([^"]*)"')


def extract() -> dict[str, dict[str, object]]:
    text = SOURCE.read_text()
    table: dict[str, dict[str, object]] = {}
    for match in ENTRY.finditer(text):
        code, title, detail, severity = match.group(1), match.group(2), match.group(3), match.group(4)
        tail = text[match.end():match.end() + 1400]
        causes: list[str] = []
        arrays = ARRAY.findall(tail)
        for block in arrays:
            values = [v for v in STRING.findall(block) if len(v) > 2]
            if len(values) >= 2:
                causes = values
                break
        table[code] = {"title": title, "detail": detail, "severity": severity, "causes": causes}
    return table


def main() -> int:
    if not SOURCE.exists():
        print(f"DTC source not found: {SOURCE}", file=sys.stderr)
        return 1
    table = extract()
    DEST.write_text(json.dumps(table, indent=2, sort_keys=True) + "\n")
    print(f"wrote {len(table)} codes to {DEST.relative_to(ROOT)}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
