#!/usr/bin/env python3
"""Build a compact client-side search index (search-index.js) for the rendered guide."""

import json
import os
import re
import sys


def slugify(heading: str) -> str:
    s = heading.strip().lower()
    s = re.sub(r"`([^`]*)`", r"\1", s)
    s = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", s)
    s = re.sub(r"[^\w\s-]", "", s)
    s = re.sub(r"\s+", "-", s)
    return s


def plain_title(heading: str) -> str:
    s = heading.strip()
    s = re.sub(r"`([^`]*)`", r"\1", s)
    s = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", s)
    return s


def extract_terms(body: str) -> str:
    """Collect notable inline-code symbols and terms for search without bloating the index."""
    cleaned = re.sub(r"```.*?```", "", body, flags=re.S)
    codes = re.findall(r"`([^`]{2,48})`", cleaned)
    seen: list[str] = []
    seen_set: set[str] = set()
    for c in codes:
        # Take the first token of an s-expression like "(isolate.scope F)" -> "isolate.scope"
        token = c.strip().lstrip("(").split()[0] if c.strip() else ""
        token = token.strip("()[]{}.,;:'\"")
        if len(token) < 2 or len(token) > 40:
            continue
        low = token.lower()
        if low not in seen_set:
            seen_set.add(low)
            seen.append(token)
        if len(seen) >= 24:
            break
    return " ".join(seen)


def index_file(path: str) -> list[dict[str, str]]:
    base = os.path.basename(path)[:-3]
    html = "index.html" if base == "guide" else f"{base}.html"
    with open(path, encoding="utf-8") as f:
        lines = f.readlines()

    page_title = base
    sections: list[tuple[str, str, list[str]]] = []
    counts: dict[str, int] = {}
    in_code = False
    cur_title = ""
    cur_anchor = ""
    cur_lines: list[str] = []

    def flush() -> None:
        if cur_title:
            sections.append((cur_title, cur_anchor, list(cur_lines)))

    for line in lines:
        if line.strip().startswith("```"):
            in_code = not in_code
            cur_lines.append(line)
            continue
        if in_code:
            cur_lines.append(line)
            continue
        m = re.match(r"^(#{1,4})\s+(.*)$", line)
        if m:
            level = len(m.group(1))
            raw = m.group(2)
            slug = slugify(raw)
            if slug in counts:
                counts[slug] += 1
                anchor = f"{slug}-{counts[slug]}"
            else:
                counts[slug] = 0
                anchor = slug
            title = plain_title(raw)
            if level == 1 and page_title == base:
                page_title = title
                cur_title = ""
                cur_anchor = ""
                cur_lines = []
                continue
            flush()
            cur_title = title
            cur_anchor = anchor
            cur_lines = []
        else:
            cur_lines.append(line)
    flush()

    entries: list[dict[str, str]] = [
        {"u": html, "p": page_title, "t": page_title, "k": base}
    ]
    for title, anchor, body_lines in sections:
        terms = extract_terms("".join(body_lines))
        entry = {"u": f"{html}#{anchor}", "p": page_title, "t": title}
        if terms:
            entry["k"] = terms
        entries.append(entry)
    return entries


def main(argv: list[str]) -> int:
    if len(argv) < 3:
        print("usage: guide-index.py OUTPUT docs/guide.md [docs/PAGE.md ...]", file=sys.stderr)
        return 2
    out_path = argv[1]
    entries: list[dict[str, str]] = []
    for path in argv[2:]:
        entries.extend(index_file(path))
    os.makedirs(os.path.dirname(os.path.abspath(out_path)), exist_ok=True)
    with open(out_path, "w", encoding="utf-8") as f:
        f.write("window.SHEN_JIT_SEARCH=")
        json.dump(entries, f, separators=(",", ":"), ensure_ascii=False)
        f.write(";\n")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
