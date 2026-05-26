#!/usr/bin/env python3
"""
insert-appcast-entry.py — 기존 appcast.xml의 <channel> 안에 새 <item> 블록을
가장 첫 자리(newest first)로 삽입한다.

사용:
    insert-appcast-entry.py appcast.xml entry.xml > new-appcast.xml

이렇게 분리한 이유:
  Sparkle은 같은 sparkle:version(=build number)이 두 번 등장하면 안 됨.
  appcast 갱신을 그냥 텍스트 append로 처리하면 build number 충돌 시 사용자에게
  같은 업데이트가 또 안내됨. 여기서는 build number 동일 entry는 dedupe.
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

    # entry.xml은 <item>...</item> 한 덩어리만 있음. 파싱 위해 root로 wrap.
    entry_raw = entry_path.read_text(encoding="utf-8").strip()
    if not entry_raw.startswith("<item"):
        # 들여쓰기로 시작할 수도 있으므로 그냥 lstrip 후 다시 체크.
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

    # dedupe — 같은 build number의 기존 item 제거.
    for existing in list(channel.findall("item")):
        if _build_number_of(existing) == new_build:
            channel.remove(existing)

    # <channel> 메타데이터 child들 (title/link/description/language)을 보존하고,
    # 새 item을 첫 item 자리에 삽입 (newest first).
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
