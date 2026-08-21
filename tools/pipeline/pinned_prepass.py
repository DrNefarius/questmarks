#!/usr/bin/env python3
"""pinned_prepass.py: build-time stage A for DAT ids no binder can reach.

    python tools/pipeline/pinned_prepass.py [--out build/rendered]

prepass.py needs {{Quest Header}}, mission_prepass.py a {{Mission Header}} plus
a `Mission Name` binding to one DAT id, coalition_prepass.py an Assignment
Table. Ten ids have none of those; lib/pinned_pages.json holds pin and reason.

Two pins share a page. "Bastok Mission 2-3" documents "The Emissary" once, but
the client has separate San d'Oria and Windurst ids, and mission_identity
refuses that as ambiguous. A binder picking one would silently drop the other,
so the split is made by hand and the pin names the branch the author writes.

`Start = Any Bastok Gate Guard` is a role; no NPC has that name, so it can
never draw. This tool prints that nation's guards, from the cached roster in
supplemental/gate_guards.json, under "## Giver". Nothing here is synthesised.
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

HEADER_ORDER = ["Mission Name", "Start", "Description", "Fame", "FLevel",
                "Quest Reqs", "Item Reqs", "Level", "Repeatable", "Previous",
                "Next", "Title", "Reward", "Expansion"]

#[[ "Any Bastok Gate Guard" -> the nation whose guards to list. Keyed on the
#   nation word rather than on the whole phrase, because the pages write it
#   three ways ("Any Bastok [[Gate Guard]]", "Any Windurst Gate Guard"). ]]
NATION_ZONES = {
    "bastok": ("Bastok Mines", "Bastok Markets", "Metalworks", "Port Bastok"),
    "windurst": ("Port Windurst", "Windurst Walls", "Windurst Waters",
                 "Windurst Woods"),
    "san d'oria": ("Southern San d'Oria", "Northern San d'Oria",
                   "Port San d'Oria"),
}


def load(p):
    with io.open(p, encoding="utf-8") as f:
        return json.load(f)


def cache_index():
    out = {}
    for fn in sorted(os.listdir(PAGES)):
        if not fn.endswith(".json"):
            continue
        try:
            rec = load(os.path.join(PAGES, fn))
        except ValueError:
            continue
        n = rec.get("normalized") or {}
        t = n.get("title")
        if t:
            out[N.norm(t)] = (rec, fn[:-5])
    return out


def field(src, name):
    m = re.search(r"\|\s*%s\s*=\s*([^\n|]*)" % re.escape(name), src)
    return m.group(1).strip() if m else None


def guards_for(start_text, roster):
    """-> (nation, [(name, zone, grid)]) when Start names the gate-guard ROLE."""
    if not start_text:
        return None, []
    low = start_text.lower()
    if "gate guard" not in low:
        return None, []
    for nation, zones in NATION_ZONES.items():
        if nation in low:
            hits = [(g, v["zone"], v["grid"]) for g, v in sorted(roster.items())
                    if v.get("zone") in zones]
            return nation, hits
    return None, []


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--out", default=os.path.join(BUILD, "rendered"))
    args = ap.parse_args()

    pins = load(os.path.join(HERE, "lib", "pinned_pages.json"))["pins"]
    roster_doc = load(os.path.join(CACHE, "supplemental", "gate_guards.json"))
    roster = roster_doc["guards"]
    dat = load(os.path.join(BUILD, "res.json"))["dat"]
    idx = cache_index()

    os.makedirs(args.out, exist_ok=True)
    written, skipped = 0, []
    for pin in pins:
        hit = idx.get(N.norm(pin["page"]))
        if not hit:
            skipped.append((pin, "page not cached"))
            continue
        rec, base = hit
        n = rec["normalized"]
        src = n.get("source") or ""
        dat_name = ((dat.get(pin["cat"]) or {}).get(pin["area"]) or {}).get(str(pin["id"]))
        if dat_name is None:
            skipped.append((pin, "no DAT name for that id"))
            continue

        #[[ One rendered file per PIN, not per page, because two pins can share
        #   a page. The id goes in the filename so the split pair cannot
        #   overwrite each other. Keying on the cache basename, the way the
        #   other stage-A tools do, is exactly what would let them. ]]
        out_base = "pin_%s_%s_%03d" % (pin["cat"], pin["area"], pin["id"])
        nation, guards = guards_for(field(src, "Start"), roster)

        front = {
            "cat": pin["cat"], "area": pin["area"], "id": pin["id"],
            "dat_name": dat_name,
            "wiki_title": n.get("title"),
            "page_id": n.get("page_id"),
            "revision_id": n.get("revision_id"),
            "source_sha256": rec["integrity"]["source_sha256"],
            "categories": n.get("categories") or [],
            "cache_file": base,
            "match_rule": "pinned_by_hand",
            "match_conf": "medium",
            "pin_reason": pin["why"],
            "branch": pin.get("branch"),
            "gate_guard_nation": nation,
        }
        out = ["---", json.dumps(front, ensure_ascii=False, indent=1, sort_keys=True),
               "---", "", "# %s" % n.get("title"), "",
               "The game knows this as: %s   (%s/%s #%d)"
               % (dat_name, pin["cat"], pin["area"], pin["id"]), ""]
        out.append("## Why this page was pinned")
        out.append(pin["why"])
        if pin.get("branch"):
            out.append("")
            out.append("THIS RECORD IS %s. The page documents both; write only "
                       "the half named here, and say in `notes` which bullets "
                       "belong to the other." % pin["branch"].upper())
        out.append("")
        if guards:
            out.append("## Giver")
            out.append("The page's Start field names a ROLE, not an NPC: %r."
                       % field(src, "Start"))
            out.append("Category:Gate Guard names these %s guards:" % nation)
            for g, z, grid in guards:
                out.append("  %-20s %-24s %s" % (g, z, grid))
            out.append("")
            out.append("  (roster from bgwiki-rest-cache/supplemental/gate_guards.json;")
            out.append("   each guard's zone and square come from that guard's own page)")
            out.append("")
        out.append("## Header")
        for k in HEADER_ORDER:
            v = field(src, k)
            if v:
                text, _ = W.render(v, numbered=False)
                out.append("%-13s %s" % (k + ":", " ".join(text.split())))
        out.append("")
        body = W.section(src, "Walkthrough")
        walk, _ = W.render(body or "")
        out.append("## Walkthrough")
        out.append(walk.strip() if walk.strip() else "(the page has no Walkthrough section)")
        out.append("")
        for head, raw in W.sections_after(src, "Walkthrough"):
            text, _ = W.render(raw)
            if text.strip():
                out.append("## After the walkthrough: %s" % head)
                out.append(text.strip())
                out.append("")

        with io.open(os.path.join(args.out, out_base + ".md"), "w",
                     encoding="utf-8", newline="\n") as f:
            f.write("\n".join(out) + "\n")
        written += 1
        print("  %-24s <- %-34s %s"
              % ("%s/%s/%d" % (pin["cat"], pin["area"], pin["id"]),
                 n.get("title"), pin.get("branch") or ""))

    print("\nwrote %d pinned page(s) to %s"
          % (written, os.path.relpath(args.out, ADDON)))
    for pin, why in skipped:
        print("  SKIPPED %s/%s/%d: %s" % (pin["cat"], pin["area"], pin["id"], why))


if __name__ == "__main__":
    main()
