#!/usr/bin/env python3
"""
insert-appcast-entry.py — inserts a new <item> block into the existing
appcast.xml's <channel>, at the first position (newest first).

Usage:
    insert-appcast-entry.py appcast.xml entry.xml > new-appcast.xml

Why this is a separate script:
  Sparkle must never see the same sparkle:version (= build number) twice.
  If the appcast update were a plain text append, a build-number collision
  would re-announce the same update to users. Here, entries with the same
  build number are deduped.
"""

import sys
import xml.etree.ElementTree as ET
from pathlib import Path


SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", "http://purl.org/dc/elements/1.1/")


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: insert-appcast-entry.py appcast.xml entry.xml", file=sys.stderr)
        return 2

    appcast_path = Path(sys.argv[1])
    entry_path = Path(sys.argv[2])

    if not appcast_path.exists():
        print(f"error: {appcast_path} not found", file=sys.stderr)
        return 2
    if not entry_path.exists():
        print(f"error: {entry_path} not found", file=sys.stderr)
        return 2

    # entry.xml holds a single <item>...</item> chunk. Wrap in a root to parse.
    entry_raw = entry_path.read_text(encoding="utf-8").strip()
    if not entry_raw.startswith("<item"):
        # It may start with indentation, so just lstrip and check again.
        entry_raw = entry_raw.lstrip()
    wrapped = (
        '<wrapper xmlns:sparkle="' + SPARKLE_NS + '">'
        + entry_raw
        + "</wrapper>"
    )
    new_item = ET.fromstring(wrapped).find("item")
    if new_item is None:
        print("error: entry.xml does not contain <item>", file=sys.stderr)
        return 2

    new_build = _build_number_of(new_item)

    tree = ET.parse(appcast_path)
    rss = tree.getroot()
    channel = rss.find("channel")
    if channel is None:
        print("error: appcast.xml has no <channel>", file=sys.stderr)
        return 2

    # dedupe — remove existing items with the same build number.
    for existing in list(channel.findall("item")):
        if _build_number_of(existing) == new_build:
            channel.remove(existing)

    # Preserve the <channel> metadata children (title/link/description/language)
    # and insert the new item where the first item sits (newest first).
    children = list(channel)
    items = [c for c in children if c.tag == "item"]
    insert_at = 0
    for i, c in enumerate(children):
        if c.tag != "item":
            insert_at = i + 1
        else:
            break
    for it in items:
        channel.remove(it)
    channel.insert(insert_at, new_item)
    for offset, it in enumerate(items, start=1):
        channel.insert(insert_at + offset, it)

    # xml declaration + utf-8.
    ET.indent(tree, space="    ", level=0)
    out = ET.tostring(rss, encoding="unicode")
    sys.stdout.write('<?xml version="1.0" encoding="utf-8"?>\n')
    sys.stdout.write(out)
    sys.stdout.write("\n")
    return 0


def _build_number_of(item: ET.Element) -> str:
    el = item.find(f"{{{SPARKLE_NS}}}version")
    return el.text.strip() if el is not None and el.text else ""


if __name__ == "__main__":
    sys.exit(main())
