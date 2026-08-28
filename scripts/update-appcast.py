#!/usr/bin/env python3
"""Sparkle appcast.xml에 이번 릴리즈 항목을 끼워 넣는다.

## 왜 generate_appcast를 안 쓰나

Sparkle이 주는 generate_appcast는 zip이 전부 한 폴더에 있고 다운로드 주소가 하나의
접두사로 끝난다고 가정한다. 우리는 zip을 버전마다 다른 GitHub 릴리즈 태그 아래 두므로
주소 접두사가 버전마다 다르다. 그래서 항목 하나만 직접 만들어 앞에 붙이고, 서명은
Sparkle의 sign_update에 맡긴다.

기존 항목은 지우지 않는다. 옛 버전에서 건너뛰며 올라오는 사용자가 있기 때문이다.
"""

import argparse
import pathlib
import sys
import xml.etree.ElementTree as ET

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE_NS)

EMPTY = """<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="{ns}">
  <channel>
    <title>{title}</title>
    <link>{feed}</link>
    <description>{title} 업데이트</description>
    <language>ko</language>
  </channel>
</rss>
"""


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--appcast", required=True, help="appcast.xml 경로 (없으면 만든다)")
    ap.add_argument("--title", required=True, help="앱 이름")
    ap.add_argument("--feed", required=True, help="이 피드의 공개 주소")
    ap.add_argument("--version", required=True, help="CFBundleShortVersionString")
    ap.add_argument("--build", required=True, help="CFBundleVersion — Sparkle이 비교하는 값")
    ap.add_argument("--url", required=True, help="zip 다운로드 주소")
    ap.add_argument("--length", required=True, help="zip 바이트 수")
    ap.add_argument("--signature", required=True, help="sign_update가 준 EdDSA 서명")
    ap.add_argument("--min-system", required=True, help="LSMinimumSystemVersion")
    ap.add_argument("--notes-url", required=True, help="릴리즈 노트 페이지 주소")
    ap.add_argument("--pub-date", required=True, help="RFC 822 형식 날짜")
    args = ap.parse_args()

    path = pathlib.Path(args.appcast)
    if not path.exists():
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(EMPTY.format(ns=SPARKLE_NS, title=args.title, feed=args.feed))

    tree = ET.parse(path)
    channel = tree.getroot().find("channel")
    if channel is None:
        print(f"channel이 없다: {path}", file=sys.stderr)
        return 1

    # 같은 build가 이미 있으면 갈아끼운다. 같은 버전을 두 번 올리면 Sparkle이 혼란스러워한다.
    for existing in channel.findall("item"):
        if existing.findtext(f"{{{SPARKLE_NS}}}version") == args.build:
            channel.remove(existing)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = f"{args.title} {args.version}"
    ET.SubElement(item, "pubDate").text = args.pub_date
    ET.SubElement(item, f"{{{SPARKLE_NS}}}version").text = args.build
    ET.SubElement(item, f"{{{SPARKLE_NS}}}shortVersionString").text = args.version
    ET.SubElement(item, f"{{{SPARKLE_NS}}}minimumSystemVersion").text = args.min_system
    ET.SubElement(item, f"{{{SPARKLE_NS}}}releaseNotesLink").text = args.notes_url
    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", args.url)
    enclosure.set("length", args.length)
    enclosure.set("type", "application/octet-stream")
    enclosure.set(f"{{{SPARKLE_NS}}}edSignature", args.signature)

    # 최신이 맨 위. Sparkle은 순서를 요구하지 않지만 사람이 읽을 때 편하다.
    channel.insert(len(list(channel.findall("*"))) - len(channel.findall("item")), item)

    ET.indent(tree, space="  ")
    tree.write(path, encoding="utf-8", xml_declaration=True)
    print(f"appcast 갱신: {path} ← {args.title} {args.version} (build {args.build})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
