#!/usr/bin/env python3
"""mission_prepass.py: stage A for MISSIONS. Cached wikitext -> readable prose.

prepass.py can't be reused: it gates on `if "{{Quest Header" not in source:`, which
rejects every mission page. Output matches `build/rendered/*.md` field for field so
stage B needs no second shape, plus two extras. `indexed_snpc` is the giver
data/mission_index.lua already has; build_index silently prefers an authored Start
over it, so both are shown and the author decides. `Mission Name` binds the record
where the page title does not: "Aht Urhgan Mission 2" is mission/toau/1.

Files go in build/rendered/, not a mission-only directory.
questmarks-ui/notes.lua:scan_desc reads only that directory, and only the first
READER_PREFIX bytes, giving up silently when `Description:` is not among them, so
every file's offset is checked before writing.

Campaign Ops are 185 of the index's 438 rows but carry `{{Campaign Header}}`, which
the mission regex excludes; mission_identity.build_campaign_bindings() binds them.
Nothing is synthesised: an empty wiki field gets no line, just a run-report entry.
"""

import argparse
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.abspath(os.path.join(HERE, "..", ".."))

sys.path.insert(0, HERE)
import mission_identity  # noqa: E402
from mission_identity import load_cache, parse_template  # noqa: E402
from fetch_wiki import read_dat_names, slugify  # noqa: E402

HEADER_ORDER = ["Mission Name", "Start", "Description", "Fame", "FLevel", "Quest Reqs",
                "Item Reqs", "Level", "Repeatable", "Previous", "Next", "Title",
                "Reward", "Expansion"]

#[[ Campaign Ops have their own field set and none of it overlaps the mission one
#   except `Description` and `Level`. `Description` is placed SECOND deliberately: the
#   reader only sees a prefix of the file, and `Rewards` on a campaign page can run to
#   a dozen templated item lines, so anything long has to sit after it. ]]
CAMPAIGN_HEADER_ORDER = ["Campaign Type", "Description", "Orders", "NPC Name", "Zone",
                         "pos", "Campaign Rank", "Unit Requirement", "Time", "Level",
                         "Rewards"]

#[[ questmarks-ui/notes.lua:scan_desc reads `local raw = f:read(1600)`. Mirrored
#   rather than guessed, and main() asserts the offset of every file it writes. ]]
READER_PREFIX = 1600


def clean(s):
    """Wikitext -> prose. Same intent as prepass.py: keep the words, drop the markup."""
    if s is None:
        return ""
    s = re.sub(r"\{\{!\}\}", " | ", s)
    s = re.sub(r"\{\{\s*KI\s*\}\}", "[KI] ", s, flags=re.I)
    s = re.sub(r"\{\{\s*ItemIcon\s*\|([^|}]*)(?:\|[^}]*)?\}\}", r"\1", s, flags=re.I)
    s = re.sub(r"\[\[[^\]|]*\|([^\]]*)\]\]", r"\1", s)
    s = re.sub(r"\[\[([^\]]*)\]\]", r"\1", s)
    s = re.sub(r"'''''|'''|''", "", s)
    s = re.sub(r"<br\s*/?>", " ", s, flags=re.I)
    s = re.sub(r"<[^>]+>", "", s)
    s = re.sub(r"&nbsp;", " ", s)
    s = re.sub(r"\{\{[^}]*\}\}", "", s)
    s = re.sub(r"[ \t]+", " ", s)
    return s.strip()


def header_line(label, value):
    """`Label:       value`, with any continuation line INDENTED.

    Column zero is a TERMINATOR to questmarks-ui/notes.lua:scan_desc. It ends the
    Description block at "a line that does not begin with whitespace", which is how
    `Fame:` and `Repeatable:` stop it. So a field value that spans lines must never put
    one there: it would truncate its own description at the first break, and a fragment
    that reads like a label would be worse than that. prepass.py:render_field indents
    for quests for exactly this reason; this is the same rule.

    No mission Description contains a newline today. Measured across all 497 bound
    pages, zero do. The failure mode is silent truncation, and a wiki edit is enough
    to introduce one, so the guarantee is structural rather than observed."""
    parts = [l.strip() for l in (value or "").splitlines() if l.strip()]
    if not parts:
        return "%-12s %s" % (label + ":", "(empty)")
    out = ["%-12s %s" % (label + ":", parts[0])]
    out += ["            " + p for p in parts[1:]]
    return "\n".join(out)


def split_sections(src):
    """-> [(heading, body)] with heading None for anything before the first one."""
    out, cur, buf = [], None, []
    for line in src.splitlines():
        m = re.match(r"^\s*(={2,6})\s*(.*?)\s*\1\s*$", line)
        if m:
            out.append((cur, "\n".join(buf)))
            cur, buf = m.group(2).strip(), []
        else:
            buf.append(line)
    out.append((cur, "\n".join(buf)))
    return out


def render_bullets(body):
    """Wiki bullets -> `[n]` at top level, indented `-` below, as stage B expects.

    Non-bullet lines are kept. Skipping every line that does not start with `*` is
    tempting and wrong: it drops 5791 lines across 575 of the 704 mission/campaign
    docs. They are not boilerplate. "San d'Oria Mission 2-1" carries the sentence
    telling you to trade crystals to a Conquest Overseer, and every Campaign Op
    writing

        *List of Gate Sentries:
        [[East Ronfaure (S)]]: (J-11)

    has only that unbulleted line to name the zone and grid ref. With no zone to
    record, a step inherits the giver's, which puts three markers in Rasdinice's room
    for NPCs who are not in it. Continuation lines are indented, never numbered.

    Cost: `clean()` has no wikitable rule, so `{|`, `|-` and `| style=` rows reach the
    reader as raw markup (3850 of the kept lines). Ugly but visible. The quest side
    strips tables in lib/wikitext.py first; doing that here is the next step."""
    lines, n = [], 0
    for raw in body.splitlines():
        m = re.match(r"^(\*+)\s*(.*)$", raw.rstrip())
        if not m:
            text = clean(raw.strip())
            if text:
                lines.append("    %s" % text if n else text)
            continue
        depth, text = len(m.group(1)), clean(m.group(2))
        if not text:
            continue
        if depth == 1:
            n += 1
            lines.append("[%d] %s" % (n, text))
        else:
            lines.append("%s- %s" % ("    " * (depth - 1), text))
    return lines


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", default=os.path.join(ADDON, "build", "rendered"))
    ap.add_argument("--index", help="also write a JSON worklist here")
    ap.add_argument("--only-indexed", action="store_true",
                    help="render only missions that already have a row in "
                         "data/mission_index.lua (a ladder for a mission with no row "
                         "is silently dropped by build_index)")
    ap.add_argument("--no-campaign", action="store_true",
                    help="skip Campaign Ops ({{Campaign Header}} pages)")
    args = ap.parse_args()

    # The giver the shipped index currently has, straight out of it.
    idx = {}
    mi = os.path.join(ADDON, "data", "mission_index.lua")
    txt = open(mi, encoding="utf-8", errors="replace").read()
    #[[ The rows, and ONLY the rows. A `prev={{cat='mission',area='x',id=N}}` link has
    #   the same shape as a row and is a REFERENCE to another mission, so an unanchored
    #   pattern reads 481 "rows" out of a file whose own header says 438. Anchoring on
    #   `Q[n] = {` is what separates a row from a link to one. ]]
    index_rows = set()
    for m in re.finditer(r"^Q\[\d+\]\s*=\s*\{cat='mission',area='([a-z_]+)',id=(\d+)",
                         txt, re.M):
        index_rows.add((m.group(1), int(m.group(2))))
    dump = os.environ.get("QM_INDEX_DUMP")
    if dump and os.path.isfile(dump):
        for line in open(dump, encoding="utf-8"):
            a, i, s = line.rstrip("\n").split("\t")
            idx[(a, int(i))] = s

    #[[ One binder, not two. Re-implementing the join here is tempting and wrong. A
    #   loop that takes the first dat name matching the page picks a side, where
    #   mission_identity refuses an ambiguous match outright, so the two disagree on
    #   exactly the rows where the answer matters. The RoV pair "Eddies of Despair"
    #   (rov/130 and rov/232) binds under such a loop and is refused by
    #   mission_identity.build_bindings(). Consuming build_bindings() directly makes
    #   divergence impossible. ]]
    rows, _redirects, dat = mission_identity.build_bindings()
    by_page = {r["page_id"]: r for r in rows}
    pages = [(p, "Mission Header", HEADER_ORDER)
             for p in load_cache(only_missions=True) if not p["redirect_record"]]

    if not args.no_campaign:
        crows, _cred, _camp = mission_identity.build_campaign_bindings()
        by_page.update({r["page_id"]: r for r in crows})
        pages += [(p, "Campaign Header", CAMPAIGN_HEADER_ORDER)
                  for p in load_cache(only_campaign=True)
                  if not p["redirect_record"]]

    os.makedirs(args.out, exist_ok=True)
    written, skipped, worklist = 0, [], []
    no_description, offsets, over_budget = [], [], []
    for p, template, order in pages:
        hdr = parse_template(p["source"], template) or {}
        mname = hdr.get("Mission Name") or ""
        b = by_page.get(p["page_id"])
        if not b or b["area"] is None:
            skipped.append((p["title"], mname,
                            "ambiguous -- refused" if b and b.get("match_conf") == "ambiguous"
                            else "unbound"))
            continue
        area, mid, dat_name = b["area"], b["id"], b["dat_name"]
        if args.only_indexed and (area, mid) not in index_rows:
            skipped.append((p["title"], mname, "no index row"))
            continue

        secs = split_sections(p["source"])
        walk, after = [], []
        for head, body in secs:
            if head is None:
                continue
            if head.lower().startswith("walkthrough"):
                walk = render_bullets(body)
            else:
                bl = render_bullets(body)
                if bl:
                    after.append((head, bl))

        #[[ The CACHE basename, hash and all, rather than a name rebuilt from the page
        #   id and title. Two reasons, both about not lying: `cache_file` is a
        #   provenance field and must name a file that exists in bgwiki-rest-cache/
        #   (a rebuilt form drops the `_<sha1[:10]>` suffix and names nothing), and
        #   the quest half of build/rendered/ is named this way already, so anything
        #   reading the directory sees one convention instead of two. ]]
        base = re.sub(r"\.json$", "", p["file"])
        fm = {
            "cat": "mission", "area": area, "id": mid, "dat_name": dat_name,
            "wiki_title": p["title"], "page_id": p["page_id"],
            "revision_id": p["revision_id"], "source_sha256": p["source_sha256"],
            "match_rule": b["match_rule"],
            "match_conf": b["match_conf"],
            "categories": p["categories"],
            "cache_file": base,
            "source_template": template,
            "indexed_snpc": idx.get((area, mid)),
            "in_mission_index": (area, mid) in index_rows,
        }
        lines = ["---", json.dumps(fm, indent=1, sort_keys=True), "---", "",
                 "# %s" % p["title"], "",
                 "The game knows this mission as: %s   (mission/%s #%d)"
                 % (dat_name, area, mid), ""]
        if fm["indexed_snpc"] is not None:
            lines += ["the shipped index's giver for this row: %r  -- if your reading "
                      "names a DIFFERENT start NPC, say so explicitly in `notes`; the "
                      "builder prefers YOURS and moves the marker without a word."
                      % fm["indexed_snpc"], ""]
        lines += ["## %s" % template]
        #[[ An ABSENT Description gets no line at all, rather than `(empty)`. scan_desc
        #   keys on the label, so `Description: (empty)` would put the literal string
        #   "(empty)" in the detail pane where the game's words belong. That is a
        #   worse outcome than the blank the reader already handles correctly. ]]
        desc = clean(hdr.get("Description") or "")
        if not desc:
            no_description.append((area, mid, p["title"]))
        for k in order:
            if k not in hdr:
                continue
            if k == "Description" and not desc:
                continue
            lines.append(header_line(k, clean(hdr[k])))
        for k, v in hdr.items():
            if k not in order and k != "Image":
                lines.append(header_line(k, clean(v)))
        lines += ["", "## Walkthrough", ""]
        lines += walk or ["(the page has no Walkthrough section)"]
        for head, bl in after:
            lines += ["", "## After the walkthrough: %s" % head, ""] + bl
        lines.append("")

        doc = "\n".join(lines)

        #[[ The prefix budget, checked per file. scan_desc reads READER_PREFIX bytes and
        #   silently gives up if `Description:` is not among them, so a file that
        #   overruns looks perfectly correct on disk and shows nothing in game. Refusing
        #   to write it turns the one silent failure mode into a loud one. ]]
        if desc:
            off = doc.encode("utf-8").find(b"Description:")
            if off < 0 or off >= READER_PREFIX:
                over_budget.append((off, area, mid, p["title"]))
                skipped.append((p["title"], mname,
                                "Description: at byte %d, past the reader's %d-byte "
                                "prefix -- REFUSED" % (off, READER_PREFIX)))
                continue
            offsets.append((off, p["title"]))

        #[[ LF, not CRLF. Python's text mode would translate on Windows, and the reader
        #   spends its prefix budget in BYTES, so every line before `Description:`
        #   would quietly cost one more of them. prepass.py pins the same newline for
        #   the quest half; this keeps one convention in the directory. ]]
        with open(os.path.join(args.out, base + ".md"), "w",
                  encoding="utf-8", newline="\n") as f:
            f.write(doc)
        written += 1
        worklist.append({"file": base + ".md", "cat": "mission", "area": area,
                         "id": mid, "dat_name": dat_name, "wiki_title": p["title"],
                         "page_id": p["page_id"], "steps_hint": len(walk),
                         "in_mission_index": fm["in_mission_index"],
                         "source_template": template,
                         "has_description": bool(desc),
                         "revision_id": p["revision_id"],
                         "source_sha256": p["source_sha256"],
                         "indexed_snpc": fm["indexed_snpc"]})

    print("rendered %d mission page(s) -> %s" % (written, args.out))
    print("skipped  %d" % len(skipped))
    for t, n, why in skipped[:20]:
        print("   %-44s %-28r %s" % (t, n, why))

    #[[ The coverage report. The description is the game's own words or it is nothing,
    #   so a page whose field is empty is reported by name rather than filled in, and
    #   the per-area table is what makes a partial expansion visible instead of
    #   averaging into a headline percentage. ]]
    print("\n`Description:` byte offset (reader budget %d)" % READER_PREFIX)
    if offsets:
        offsets.sort()
        print("   min %d   max %d   over budget %d"
              % (offsets[0][0], offsets[-1][0], len(over_budget)))
        for off, a, i, t in over_budget[:10]:
            print("   REFUSED mission/%s/%s at %d  %s" % (a, i, off, t))
    print("\npages with NO description in the wiki header: %d" % len(no_description))
    for a, i, t in no_description[:20]:
        print("   mission/%-9s %-5s %s" % (a, i, t))

    emitted = {(w["area"], w["id"]) for w in worklist if w["has_description"]}
    print("\ncoverage of data/mission_index.lua (%d rows)" % len(index_rows))
    print("   %-10s %6s %6s %7s" % ("area", "rows", "desc", "pct"))
    for a in sorted({x for x, _ in index_rows}):
        tot = sum(1 for x, _ in index_rows if x == a)
        got = sum(1 for x, i in emitted if x == a and (x, i) in index_rows)
        print("   %-10s %6d %6d %6.0f%%" % (a, tot, got, 100.0 * got / tot))
    hit = len(emitted & index_rows)
    print("   %-10s %6d %6d %6.0f%%" % ("TOTAL", len(index_rows), hit,
                                        100.0 * hit / max(1, len(index_rows))))

    if args.index:
        with open(args.index, "w", encoding="utf-8") as f:
            json.dump(worklist, f, ensure_ascii=False, indent=1)
        print("wrote worklist %s" % args.index)


if __name__ == "__main__":
    main()
