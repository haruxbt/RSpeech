#!/usr/bin/env python3
"""Apply one owner-submitted pronunciation issue as a new dictionary entry."""
import json
import re
from pathlib import Path
import sys
import unicodedata

TITLE = "[R辞書] 共有読み方の追加"


def submission(event):
    issue = event["issue"]
    owner = event["repository"]["owner"]
    if issue["title"] != TITLE or issue["user"]["id"] != owner["id"] or event["sender"]["id"] != owner["id"]:
        raise ValueError("Only the repository owner can automatically add entries")
    raw = issue["body"]
    if not isinstance(raw, str) or len(raw) > 1024:
        raise ValueError("Expected one short dictionary entry")
    row = json.loads(raw)
    if not isinstance(row, dict) or set(row) != {"word", "reading", "accent", "priority"}:
        raise ValueError("Expected word, reading, accent and priority")
    word, reading = row["word"], row["reading"]
    if (not isinstance(word, str) or not 1 <= len(word) <= 64 or word != word.strip()
            or not any(c.isalpha() for c in word)
            or re.search(r"https?://|[\w.+-]+@[\w.-]+\.[a-z]{2,}|(?:sk-|gh[pousr]_)[A-Za-z0-9]{20,}", word, re.I)
            or not all(unicodedata.category(c)[0] in "LMN" or c in " ._+-@&'" for c in word)):
        raise ValueError("Word has an unsupported form")
    small = "ァィゥェォャュョヮ"
    if (not isinstance(reading, str) or not re.fullmatch("[ァ-ヴー]{1,64}", reading)
            or reading[0] in small + "ー" or re.search(f"[{small}]{{2}}", reading)):
        raise ValueError("Reading must be katakana")
    mora_count = sum(c not in small for c in reading)
    for key, maximum in (("accent", mora_count), ("priority", 10)):
        if type(row[key]) is not int or not 0 <= row[key] <= maximum:
            raise ValueError(f"Invalid {key}")
    return row


def apply(event, dictionary):
    row = submission(event)
    table = dictionary / "readings.tsv"
    overrides = dictionary / "pronunciation-overrides.json"
    version_file = dictionary / "version.txt"
    text = table.read_text()
    entries = [line.split("\t", 1) for line in text.splitlines() if line.strip()]
    if any(word.casefold() == row["word"].casefold() for word, _ in entries):
        return False
    if len(entries) >= 2000:
        raise ValueError("Common dictionary is full")
    values = json.loads(overrides.read_text())
    key = row["word"].lower()
    if key in values:
        raise ValueError("An override already exists for this word")
    version = version_file.read_text().strip()
    if not re.fullmatch(r"[0-9]{4}(?:\.[0-9]+){3}", version):
        raise ValueError("Invalid dictionary version")
    head, revision = version.rsplit(".", 1)
    if (row["accent"], row["priority"]) != (0, 5):
        values[key] = {"accent": row["accent"], "priority": row["priority"]}
        overrides.write_text(json.dumps(values, ensure_ascii=False, indent=2) + "\n")
    table.write_text(text.rstrip("\n") + f"\n{row['word']}\t{row['reading']}\n")
    version_file.write_text(f"{head}.{int(revision) + 1}\n")
    return True


if __name__ == "__main__":
    changed = apply(json.loads(Path(sys.argv[1]).read_text()), Path(__file__).resolve().parent)
    print("Added a new dictionary entry" if changed else "Already present; no changes")
