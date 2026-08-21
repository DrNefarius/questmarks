"""Stage A: select quest pages, bind their identity, render them for reading.

    python tools/pipeline/prepass.py [--force] [--only <title>] [--limit N]

Deterministic. No interpretation happens here: this stage decides WHICH pages
are quests and turns their markup into readable prose, and nothing else. Every
judgement about what a step is belongs to the reading pass.

Inputs
    bgwiki-rest-cache/manifest.json     which pages are quests (status == "ok")
    bgwiki-rest-cache/pages/*.json      normalized.source = raw wikitext
    build/res.json                      the client's DAT name tables

Outputs
    build/rendered/<basename>.md        front matter + the text a reader sees
    build/reports/quarantine.jsonl      everything excluded, with its reason

Resumable: a page is skipped when its rendered file already records the same
source_sha256. That beats a timestamp: re-fetching a page without a content
change must not invalidate work, while a real wiki edit must.

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
BUILD = os.path.join(ADDON, "build")
RENDERED = os.path.join(BUILD, "rendered")
REPORTS = os.path.join(BUILD, "reports")

# Fields the reader is shown. `Image` is the only one deliberately dropped:
# it is a filename and says nothing about the quest.
HEADER_FIELDS = [
    "Start", "Description", "Fame", "FLevel", "Quest Reqs", "Item Reqs",
    "Level", "Repeatable", "Previous", "Next", "Title", "Reward", "Expansion",
]


def load_json(path):
    with io.open(path, encoding="utf-8") as f:
        return json.load(f)


def basename_of(cache_file):
    return os.path.basename(cache_file.replace("\\", "/"))


def render_field(raw):
    text, _ = W.render(raw or "", numbered=False)
    if "\n" not in text:
        return " ".join(text.split())
    # Keep a field's own list structure, but indented under its label so it
    # cannot be mistaken for the walkthrough.
    return "\n" + "\n".join("            " + l for l in text.splitlines() if l.strip())


def build_document(page, rec, fields, walkthrough, flags, after=None, rule=None):
    cat, area, qid, dat_name = rec
    n = page["normalized"]
    #[[ On a redirect, cite the article, not the stub.
    #
    #   `/page/X` on a redirect returns the stub, but the cache record stores the
    #   TARGET's wikitext in `normalized.source` while `title`/`page_id`/
    #   `revision_id` still describe the stub. Taking that first triple gives a
    #   record whose provenance contradicts itself: re-fetching revision 151931
    #   of page 67217 yields the one line
    #   "#REDIRECT [[The Soul of the Matter]]", whose hash is nothing like the
    #   `source_sha256` beside it. Such a record cannot be reproduced from its
    #   own citation, which is the single property the audit trail exists for.
    #
    #   check_authored.py cannot catch that either: it compares the record
    #   against this front matter, which would carry the same wrong fields, and
    #   it compares the sha against `integrity.source_sha256`. That is the
    #   TARGET's hash, so it matches whichever triple was cited.
    #
    #   The right values are already in the record, one key away, because the
    #   fetcher resolved the chain: content_title / content_page_id /
    #   content_revision_id. mission_identity.load_cache meets the same hazard
    #   from the other side and flags such records so its callers drop them.
    #   Here they are usable, so they are cited correctly instead.
    #   `redirect_from` keeps the stub visible: it is how the DAT name was
    #   matched, so it is part of the binding. ]]
    is_redirect = bool(n.get("is_redirect")) and n.get("content_page_id")
    front = {
        "cat": cat, "area": area, "id": qid, "dat_name": dat_name,
        "wiki_title": (n.get("content_title") if is_redirect else n["title"]),
        "page_id": (n.get("content_page_id") if is_redirect else n["page_id"]),
        "revision_id": (n.get("content_revision_id") if is_redirect
                        else n["revision_id"]),
        "redirect_from": (n["title"] if is_redirect else None),
        "source_sha256": page["integrity"]["source_sha256"],
        "categories": page["normalized"].get("categories") or [],
        "flags": sorted(flags),
        #[[ How the title was bound to a DAT id, carried through so the reading
        #   pass can copy it instead of guessing. Without it every authored file
        #   claims "exact_verbatim", which is true for 946 of 1003 pages and a
        #   quiet lie for the rest. ]]
        "match_rule": rule or "unknown",
        "match_conf": "high" if rule in ("exact_verbatim", "exact") else "medium",
    }
    out = ["---", json.dumps(front, ensure_ascii=False, indent=1, sort_keys=True), "---", ""]
    out.append("# %s" % front["wiki_title"])
    out.append("")
    out.append("The game knows this quest as: %s   (%s/%s #%d)"
               % (dat_name, cat, area, qid))
    out.append("")
    out.append("## Quest Header")
    for k in HEADER_FIELDS:
        v = fields.get(k)
        if v is None:
            continue
        v = render_field(v)
        out.append("%-11s %s" % (k + ":", v if v.strip() else "(empty)"))
    out.append("")
    out.append("## Walkthrough")
    out.append("")
    out.append(walkthrough if walkthrough.strip() else "(the page has no walkthrough)")
    out.append("")

    #[[ Sections that FOLLOW the walkthrough, rendered rather than judged.
    #
    #   Some of them are the rest of the quest. `Hitting the Marquisate` hides
    #   its last four steps (including the only use of the Pickaxe its own
    #   header demands) under "Afterwards", so cutting at that heading loses
    #   them silently. Most are `Notes`, `Related Links` or `References` and are
    #   not steps at all. Which is which is a reading decision, so both arrive
    #   and the reader decides; nothing here guesses.
    #
    #   The bullets restart at [1] under each heading, and the heading says
    #   plainly that this is after the walkthrough, so a step read out of one
    #   can never be mistaken for a walkthrough bullet in `source_bullets`. ]]
    for title, body in (after or []):
        if not body.strip():
            continue
        out.append("## After the walkthrough: %s" % title)
        out.append("")
        out.append(body)
        out.append("")
    return "\n".join(out)


def already_done(path, sha):
    if not os.path.exists(path):
        return False
    try:
        with io.open(path, encoding="utf-8") as f:
            head = f.read(4096)
        return ('"source_sha256": "%s"' % sha) in head
    except Exception:
        return False


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--only", default=None, help="single wiki title")
    ap.add_argument("--limit", type=int, default=0)
    args = ap.parse_args()

    res_path = os.path.join(BUILD, "res.json")
    if not os.path.exists(res_path):
        sys.exit("missing %s -- run: luajit tools/pipeline/dump_res.lua --res" % res_path)
    res = load_json(res_path)
    index = N.DatIndex(res["dat"], "quest")

    ov_path = os.path.join(HERE, "lib", "title_overrides.json")
    overrides = {k: v for k, v in load_json(ov_path).items()
                 if not k.startswith("_")} if os.path.exists(ov_path) else {}

    #[[ The directory is the authority, not any manifest.
    #
    #   manifest.json alone is the QUEST run's enumeration: 1025 pages. Every
    #   manifest together reaches 3056. The directory holds 3398. The ~340
    #   difference is pages fetched by a run whose manifest recorded them under
    #   a different key, or written by redirect-following after the manifest's
    #   page list was assembled. Whatever the cause, a page on disk that no
    #   manifest lists is INVISIBLE to a manifest-driven loop: not quarantined,
    #   not reported, never considered, because the loop never sees it.
    #
    #   A page can sit in pages/ and appear in no manifest at all, and then
    #   quarantine names it nowhere: the report looks clean because the work
    #   never started, which is the signature of a silent skip.
    #   mission_prepass.py takes the same route, through
    #   mission_identity.load_cache, which scans the directory.
    #
    #   Title comes from the page record and cache_file from the filename on
    #   disk, so no manifest is needed to interpret what is there. ]]
    ok_pages = []
    pages_dir = os.path.join(CACHE, "pages")
    for fn in sorted(os.listdir(pages_dir)):
        if not fn.endswith(".json"):
            continue
        try:
            rec = load_json(os.path.join(pages_dir, fn))
        except ValueError:
            continue
        n = rec.get("normalized") or {}
        title = n.get("title") or rec.get("canonical_title") or rec.get("requested_title")
        if not title:
            continue
        ok_pages.append({"title": title, "cache_file": os.path.join("pages", fn)})
    print("stage A considering %d cached page(s) scanned from pages/" % len(ok_pages))

    for d in (RENDERED, REPORTS):
        if not os.path.isdir(d):
            os.makedirs(d)

    quarantine = []
    stats = {
        "considered": 0, "no_quest_header": 0, "rendered": 0, "skipped": 0,
        "no_dat_id": 0, "ambiguous_dat_id": 0, "no_walkthrough": 0,
    }
    rules = {}
    flag_counts = {}

    for entry in ok_pages:
        title = entry["title"]
        if args.only and title != args.only:
            continue
        base = basename_of(entry["cache_file"])
        page_path = os.path.join(CACHE, "pages", base)
        if not os.path.exists(page_path):
            quarantine.append({"title": title, "stage": "prepass",
                               "reason": "cache_file_missing", "detail": base})
            continue

        page = load_json(page_path)
        source = page["normalized"].get("source") or ""
        stats["considered"] += 1

        # Search ANYWHERE, not at position 0: 51 pages open with a
        # disambiguation hatnote before the infobox.
        if "{{Quest Header" not in source:
            stats["no_quest_header"] += 1
            quarantine.append({"title": title, "stage": "prepass",
                               "reason": "not_a_quest_page", "detail": ""})
            continue

        rec, rule, err = index.bind(title, overrides)
        if not rec:
            stats[err] = stats.get(err, 0) + 1
            #[[ Most of these SHOULD stay out. Records of Eminence content is a
            #   menu-driven achievement list, never accepted from an NPC, and
            #   the game does not track it in the quest log. It therefore has no
            #   DAT id and excludes itself. That is the right mechanism: it keys
            #   on what the addon can actually observe, not on a wiki tag. ]]
            cats = page["normalized"].get("categories") or []
            quarantine.append({
                "title": title, "stage": "prepass", "reason": err,
                "detail": "roe" if any("Records of Eminence" in c for c in cats) else "",
            })
            continue
        rules[rule] = rules.get(rule, 0) + 1

        sha = page["integrity"]["source_sha256"]
        out_path = os.path.join(RENDERED, base.replace(".json", ".md"))
        if not args.force and already_done(out_path, sha):
            stats["skipped"] += 1
            continue

        flags = set()
        header = W.infobox(source, "Quest Header")
        fields = W.infobox_fields(header)
        body = W.section(source, "Walkthrough")
        if body is None:
            stats["no_walkthrough"] += 1
            flags.add("no_walkthrough")
            body = ""
        walk, wflags = W.render(body)
        flags |= wflags

        #[[ Rendered, not dropped: see build_document. Flagged too, so the
        #   reading pass is told to look rather than having to notice. ]]
        after = []
        for title, raw in W.sections_after(source, "Walkthrough"):
            text, aflags = W.render(raw)
            if text.strip():
                after.append((title, text))
                flags |= aflags
        if after:
            flags.add("sections_after_walkthrough")
            stats["with_after"] = stats.get("with_after", 0) + 1

        for f in flags:
            flag_counts[f] = flag_counts.get(f, 0) + 1

        doc = build_document(page, rec, fields, walk, flags, after, rule)
        with io.open(out_path, "w", encoding="utf-8", newline="\n") as f:
            f.write(doc)
        stats["rendered"] += 1

        if args.limit and stats["rendered"] >= args.limit:
            break

    qpath = os.path.join(REPORTS, "quarantine.jsonl")
    with io.open(qpath, "w", encoding="utf-8", newline="\n") as f:
        for q in sorted(quarantine, key=lambda x: (x["reason"], x["title"])):
            f.write(json.dumps(q, ensure_ascii=False) + "\n")

    print("cached pages scanned         : %d" % len(ok_pages))
    for k in ("considered", "no_quest_header", "no_dat_id", "ambiguous_dat_id",
              "no_walkthrough", "rendered", "skipped"):
        print("  %-22s %5d" % (k, stats.get(k, 0)))
    print("  bound by rule          : %s"
          % " ".join("%s=%d" % kv for kv in sorted(rules.items())))
    print("  flags                  : %s"
          % " ".join("%s=%d" % kv for kv in sorted(flag_counts.items())))
    print("  quarantine             : %d -> %s" % (len(quarantine), qpath))


if __name__ == "__main__":
    main()
