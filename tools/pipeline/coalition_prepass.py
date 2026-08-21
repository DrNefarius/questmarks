#!/usr/bin/env python3
"""coalition_prepass.py: stage A for Adoulin coalition assignments.

    python tools/pipeline/coalition_prepass.py [--out build/rendered]

The third stage-A tool, and it exists for the same reason mission_prepass.py
does: the gate. prepass.py requires `{{Quest Header}}` and mission_prepass.py
requires `{{Mission Header}}`; a coalition assignment carries neither. It
carries one of SIX per-coalition templates (Inventors, Pioneers, Couriers,
Scouts, Peacekeepers, Mummers), each `{{<Name> Assignment Table}}`, so both
existing tools reject all 95 pages and they have never been rendered.

They are quest/coalition rows to the index, all 96 of them.

The giver is not on the assignment page. The walkthrough says "NPC asks you to
obtain..." and never names anyone. The giver is the Task Delegator, and there
are SIX of them, one per coalition, at six different squares; which one offers
a given assignment is determined by the `Coalition=` field.

So the location is resolved from the COALITION's own page, each of which states
it in an `<onlyinclude>` line:

    Assigned by [[Task Delegator]] in [[Western Adoulin]] (J-10) near Waypoint #4.

That is a look-up to RESOLVE a name the assignment page assumes you know, which
is allowed where importing content would not be, and it is cross-checked: the
six squares recovered this way are exactly the six the `Task Delegator` NPC
page lists in its own template.

Mummers is the one disagreement. Its table cell says (G-10) and its own
onlyinclude says (G-11). The NPC page lists G-10 and not G-11, so G-10 wins and
the conflict is recorded in the rendered page for the author to see.

Build-time only.
"""

import argparse
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

from lib import names as N          # noqa: E402
from lib import wikitext as W       # noqa: E402

ADDON = os.path.normpath(os.path.join(HERE, "..", ".."))
CACHE = os.path.join(ADDON, "bgwiki-rest-cache")
PAGES = os.path.join(CACHE, "pages")
BUILD = os.path.join(ADDON, "build")

ASSIGNMENT_RE = re.compile(r"\{\{\s*([A-Za-z][A-Za-z0-9 _'-]*?)\s*Assignment Table")
COALITION_CAT = "Category:Coalition Assignments"

HEADER_ORDER = ["Coalition", "Rank", "Type", "Zone", "Objective", "Treasure",
                "IMP1", "IMP2", "IMP3"]


def load(p):
    with io.open(p, encoding="utf-8") as f:
        return json.load(f)


def infobox_fields(src):
    """`|Key=value` pairs from the assignment template, markup rendered off."""
    m = ASSIGNMENT_RE.search(src)
    if not m:
        return None, None
    start = m.start()
    depth, i = 0, start
    while i < len(src):
        if src.startswith("{{", i):
            depth += 1
            i += 2
            continue
        if src.startswith("}}", i):
            depth -= 1
            i += 2
            if depth == 0:
                break
            continue
        i += 1
    body = src[start:i]
    out = {}
    for line in body.splitlines():
        fm = re.match(r"\s*\|\s*([A-Za-z0-9 _]+?)\s*=\s*(.*)$", line)
        if fm:
            text, _ = W.render(fm.group(2), numbered=False)
            out[fm.group(1).strip()] = " ".join(text.split())
    return m.group(1).strip(), out


def delegator_table():
    """coalition name -> (zone, grid), read from each coalition's own page.

    Prefers the `<onlyinclude>` sentence, which is the page stating where the
    assignment is handed out, and falls back to the infobox row. Cross-checked
    against the Task Delegator NPC page: a square that page does not list is
    reported rather than used.
    """
    npc_squares, coalitions = set(), {}
    for fn in os.listdir(PAGES):
        if not fn.endswith(".json"):
            continue
        n = load(os.path.join(PAGES, fn)).get("normalized") or {}
        title, src = n.get("title") or "", n.get("source") or ""
        if title == "Task Delegator":
            for zm in re.finditer(r"\|\s*((?:Western|Eastern) Adoulin)\s*\|\s*([A-Z]-\d+)", src):
                npc_squares.add((zm.group(1), zm.group(2)))
        if title.endswith("Coalition"):
            m = re.search(r"Assigned by \[\[Task Delegator\]\] in \[\[([^\]]+)\]\]\s*\(([A-Z]-\d+)\)", src)
            alt = re.search(r"\|\s*\[\[((?:Western|Eastern) Adoulin)\]\]\s*\(([A-Z]-\d+)\)", src)
            if m:
                coalitions[title] = (m.group(1), m.group(2),
                                     (alt.group(1), alt.group(2)) if alt else None)
    out = {}
    for name, (zone, grid, alt) in sorted(coalitions.items()):
        note = None
        if (zone, grid) not in npc_squares and alt and alt in npc_squares:
            note = ("page says %s but the Task Delegator NPC page lists %s; "
                    "using the NPC page" % (grid, alt[1]))
            zone, grid = alt
        elif (zone, grid) not in npc_squares:
            note = "NOT listed on the Task Delegator NPC page"
        out[name] = (zone, grid, note)
    return out, npc_squares


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(BUILD, "rendered"))
    ap.add_argument("--force", action="store_true")
    args = ap.parse_args()

    res_path = os.path.join(BUILD, "res.json")
    if not os.path.exists(res_path):
        sys.exit("missing %s -- run: luajit tools/pipeline/dump_res.lua --res" % res_path)
    index = N.DatIndex(load(res_path)["dat"], "quest")

    deleg, npc_squares = delegator_table()
    print("Task Delegator squares on the NPC page: %d" % len(npc_squares))
    for k, (z, g, note) in sorted(deleg.items()):
        print("  %-26s %s (%s)%s" % (k, z, g, "  [%s]" % note if note else ""))

    os.makedirs(args.out, exist_ok=True)
    written, skipped = 0, []
    for fn in sorted(os.listdir(PAGES)):
        if not fn.endswith(".json"):
            continue
        page = load(os.path.join(PAGES, fn))
        n = page.get("normalized") or {}
        if COALITION_CAT not in (n.get("categories") or []):
            continue
        title, src = n.get("title") or "", n.get("source") or ""
        tmpl, fields = infobox_fields(src)
        if not fields:
            skipped.append((title, "no assignment template"))
            continue

        rec, rule, err = index.bind(title, None)
        if not rec:
            skipped.append((title, err or "unbound"))
            continue
        cat, area, qid, dat_name = rec
        if area != "coalition":
            skipped.append((title, "bound to %s/%s, not coalition" % (cat, area)))
            continue

        coal = fields.get("Coalition") or ""
        loc = deleg.get(coal.strip())
        base = fn[:-5]
        front = {
            "cat": cat, "area": area, "id": qid, "dat_name": dat_name,
            "wiki_title": title, "page_id": n.get("page_id"),
            "revision_id": n.get("revision_id"),
            "source_sha256": page["integrity"]["source_sha256"],
            "categories": n.get("categories") or [],
            "cache_file": base,
            "match_rule": rule, "match_conf": "high" if "verbatim" in (rule or "") else "medium",
            "source_template": "%s Assignment Table" % tmpl,
            "giver_zone": loc[0] if loc else None,
            "giver_grid": loc[1] if loc else None,
            "giver_source": ("%s page" % coal) if loc else None,
            "giver_conflict": loc[2] if loc else None,
        }
        out = ["---", json.dumps(front, ensure_ascii=False, indent=1, sort_keys=True),
               "---", "", "# %s" % title, "",
               "The game knows this assignment as: %s   (%s/%s #%d)"
               % (dat_name, cat, area, qid), ""]
        out.append("## Giver")
        if loc:
            out.append("Task Delegator - %s (%s)" % (loc[0], loc[1]))
            out.append("  (resolved from the %s page; the assignment page names no NPC)" % coal)
            if loc[2]:
                out.append("  CONFLICT: %s" % loc[2])
        else:
            out.append("UNRESOLVED - no coalition page matched %r" % coal)
        out.append("")
        out.append("## %s Assignment Table" % tmpl)
        for k in HEADER_ORDER:
            if fields.get(k):
                out.append("%-12s %s" % (k + ":", fields[k]))
        out.append("")
        body = W.section(src, "Walkthrough")
        walk, _ = W.render(body or "")
        out.append("## Walkthrough")
        out.append(walk.strip() if walk.strip() else "(the page has no walkthrough)")
        out.append("")
        for head, raw in W.sections_after(src, "Walkthrough"):
            text, _ = W.render(raw)
            if text.strip():
                out.append("## After the walkthrough: %s" % head)
                out.append(text.strip())
                out.append("")

        with io.open(os.path.join(args.out, base + ".md"), "w",
                     encoding="utf-8", newline="\n") as f:
            f.write("\n".join(out) + "\n")
        written += 1

    print("\nwrote %d rendered coalition page(s) to %s"
          % (written, os.path.relpath(args.out, ADDON)))
    if skipped:
        print("skipped %d:" % len(skipped))
        for t, why in skipped[:20]:
            print("  %-44s %s" % (t, why))


if __name__ == "__main__":
    main()
