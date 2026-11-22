#!/usr/bin/env python3
"""Check documentation consistency: links, anchors, guide page registration and module coverage."""

import glob
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
REPO_BLOB = "https://github.com/tizoc/shen-jit/blob/main/"
NON_RENDERED_DOCS = {"guide", "development-log", "overrides"}


def slugify(heading: str) -> str:
    """GFM / Pandoc heading identifier."""
    s = heading.strip().lower()
    s = re.sub(r"`([^`]*)`", r"\1", s)
    s = re.sub(r"\[([^\]]+)\]\([^\)]+\)", r"\1", s)
    s = re.sub(r"[^\w\s-]", "", s)
    s = re.sub(r"\s+", "-", s)
    return s


def extract_anchors(path: str) -> set[str]:
    anchors: set[str] = set()
    counts: dict[str, int] = {}
    in_code = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.strip().startswith("```"):
                in_code = not in_code
                continue
            if in_code:
                continue
            m = re.match(r"^(#+)\s+(.*)$", line)
            if m:
                slug = slugify(m.group(2))
                if slug in counts:
                    counts[slug] += 1
                    anchors.add(f"{slug}-{counts[slug]}")
                else:
                    counts[slug] = 0
                    anchors.add(slug)
            for aid in re.findall(r'id="([^"]+)"', line):
                anchors.add(aid)
    return anchors


def strip_fenced_code(text: str) -> str:
    return re.sub(r"```.*?```", "", text, flags=re.S)


def main() -> int:
    errors: list[str] = []

    # 1. Guide page registration across docs/, Makefile, site/guide.lua, and pages.yml.
    docs_pages = {
        os.path.basename(p)[:-3]
        for p in glob.glob(os.path.join(ROOT, "docs", "*.md"))
    }
    expected_pages = docs_pages - NON_RENDERED_DOCS

    with open(os.path.join(ROOT, "Makefile"), encoding="utf-8") as f:
        mk = f.read()
    m = re.search(r"^GUIDE_PAGES\s*:=\s*(.+)$", mk, re.M)
    if not m:
        errors.append("Makefile: could not find GUIDE_PAGES")
        makefile_pages: set[str] = set()
    else:
        makefile_list = m.group(1).split()
        makefile_pages = set(makefile_list)
        if len(makefile_list) != len(makefile_pages):
            errors.append("Makefile: duplicate entries in GUIDE_PAGES")

    with open(os.path.join(ROOT, "site", "guide.lua"), encoding="utf-8") as f:
        lua = f.read()
    pages_m = re.search(r"local PAGES = \{(.*?)\n\}", lua, re.S)
    if not pages_m:
        errors.append("site/guide.lua: could not find PAGES table")
        lua_pages: set[str] = set()
    else:
        entries = re.findall(r"(?:\['([^']+)'\]|(\w+))\s*=", pages_m.group(1))
        lua_list = [a or b for a, b in entries]
        lua_pages = set(lua_list)
        if len(lua_list) != len(lua_pages):
            errors.append("site/guide.lua: duplicate entries in PAGES")

    groups_m = re.search(r"local GROUPS = \{(.*?)\n\}", lua, re.S)
    if groups_m:
        group_list = re.findall(r"'([\w-]+)'", "\n".join(
            re.findall(r"pages\s*=\s*\{([^}]+)\}", groups_m.group(1))
        ))
        group_pages = set(group_list)
        if len(group_list) != len(group_pages):
            errors.append("site/guide.lua: duplicate entries in GROUPS")
        for p in sorted(makefile_pages - group_pages):
            errors.append(f"site/guide.lua: page '{p}' missing from GROUPS")
        for p in sorted(group_pages - makefile_pages):
            errors.append(f"site/guide.lua: unknown page '{p}' in GROUPS")

    with open(os.path.join(ROOT, ".github", "workflows", "pages.yml"), encoding="utf-8") as f:
        yml = f.read()
    yml_pages = set(re.findall(r"-\s*docs/([\w-]+)\.md", yml)) - {"guide"}

    for p in sorted(expected_pages - makefile_pages):
        errors.append(f"docs/{p}.md: missing from Makefile GUIDE_PAGES")
    for p in sorted(makefile_pages - expected_pages):
        errors.append(f"Makefile GUIDE_PAGES: docs/{p}.md does not exist")
    for p in sorted(makefile_pages - lua_pages):
        errors.append(f"site/guide.lua: page '{p}' missing from PAGES")
    for p in sorted(lua_pages - makefile_pages):
        errors.append(f"site/guide.lua: unknown page '{p}' in PAGES")
    for p in sorted(makefile_pages - yml_pages):
        errors.append(f".github/workflows/pages.yml: docs/{p}.md missing from paths")
    for p in sorted(yml_pages - makefile_pages):
        errors.append(f".github/workflows/pages.yml: docs/{p}.md not in GUIDE_PAGES")

    # 2. Every rendered sub-page must be linked from docs/guide.md.
    guide_path = os.path.join(ROOT, "docs", "guide.md")
    with open(guide_path, encoding="utf-8") as f:
        guide_text = f.read()
    for p in sorted(makefile_pages):
        if f"{p}.md" not in guide_text:
            errors.append(f"docs/guide.md: does not link to {p}.md")

    # 3. Check all links and anchors in markdown docs.
    md_files = sorted(
        glob.glob(os.path.join(ROOT, "docs", "*.md"))
        + [
            os.path.join(ROOT, "README.md"),
            os.path.join(ROOT, "AGENTS.md"),
            os.path.join(ROOT, "src", "lowerer", "README.md"),
        ]
        + glob.glob(os.path.join(ROOT, "example-apps", "*", "README.md"))
    )
    anchor_cache = {p: extract_anchors(p) for p in md_files}
    rendered_paths = {
        os.path.join(ROOT, "docs", f"{p}.md") for p in (makefile_pages | {"guide"})
    }

    for md in md_files:
        rel_md = os.path.relpath(md, ROOT)
        with open(md, encoding="utf-8") as f:
            cleaned = strip_fenced_code(f.read())

        for m in re.finditer(r"(?<!\!)\[([^\]]+)\]\(([^)]+)\)", cleaned):
            target = m.group(2).strip()
            if target.startswith(("http://", "https://", "mailto:")):
                if target.startswith(REPO_BLOB):
                    sub = target[len(REPO_BLOB):]
                    path_part, _, frag = sub.partition("#")
                    full = os.path.normpath(os.path.join(ROOT, path_part))
                    if not os.path.exists(full):
                        errors.append(f"{rel_md}: broken repo link '{target}'")
                    elif frag and full in anchor_cache and frag not in anchor_cache[full]:
                        errors.append(f"{rel_md}: broken anchor '#{frag}' in '{path_part}'")
                continue

            path_part, _, frag = target.partition("#")
            if path_part == "":
                full = md
            else:
                full = os.path.normpath(os.path.join(os.path.dirname(md), path_part))
            if not os.path.exists(full):
                errors.append(f"{rel_md}: broken link '{target}'")
            elif frag and full in anchor_cache and frag not in anchor_cache[full]:
                rel_target = os.path.relpath(full, ROOT)
                errors.append(f"{rel_md}: broken anchor '#{frag}' in '{rel_target}'")

        if md in rendered_paths:
            if re.search(r"development-log\.md|overrides\.md", cleaned):
                errors.append(
                    f"{rel_md}: rendered document must not mention development-log.md or overrides.md"
                )

    # 4. Check docs/development-log.md Topics line covers every ## heading.
    devlog_path = os.path.join(ROOT, "docs", "development-log.md")
    with open(devlog_path, encoding="utf-8") as f:
        devlog_lines = f.readlines()
    topics_block = ""
    h2_slugs: list[str] = []
    in_code = False
    for line in devlog_lines:
        if line.strip().startswith("```"):
            in_code = not in_code
            continue
        if in_code:
            continue
        if line.startswith("## "):
            h2_slugs.append(slugify(line[3:]))
    for idx, line in enumerate(devlog_lines):
        if line.startswith("Topics:"):
            j = idx
            while j < len(devlog_lines) and devlog_lines[j].strip():
                topics_block += devlog_lines[j]
                j += 1
            break
    if not topics_block:
        errors.append("docs/development-log.md: missing Topics line")
    else:
        linked_topics = set(re.findall(r"\(#([\w-]+)\)", topics_block))
        for slug in h2_slugs:
            if slug not in linked_topics:
                errors.append(
                    f"docs/development-log.md: Topics line missing '#{slug}'"
                )

    # 5. Check every .shenmod module in lib/ is mentioned somewhere in docs/.
    all_docs_text = ""
    for p in glob.glob(os.path.join(ROOT, "docs", "*.md")):
        if os.path.basename(p) == "development-log.md":
            continue
        with open(p, encoding="utf-8") as f:
            all_docs_text += "\n" + f.read()

    for mod_path in sorted(glob.glob(os.path.join(ROOT, "lib", "**", "*.shenmod"), recursive=True)):
        with open(mod_path, encoding="utf-8") as f:
            m = re.search(r"\(name\s+([^\s)]+)\)", f.read())
        if not m:
            continue
        mod_name = m.group(1)
        if mod_name not in all_docs_text:
            errors.append(f"docs/: module '{mod_name}' ({os.path.relpath(mod_path, ROOT)}) is not mentioned")

    if errors:
        for err in errors:
            print(f"check-docs: {err}", file=sys.stderr)
        print(f"check-docs: {len(errors)} error(s)", file=sys.stderr)
        return 1

    print(
        f"check-docs: ok ({len(md_files)} markdown files, {len(makefile_pages)} guide pages)"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
