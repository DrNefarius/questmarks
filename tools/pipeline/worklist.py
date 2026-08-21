"""Split the unauthored rendered pages into stable, size-balanced batches.

    python tools/pipeline/worklist.py --snapshot     # freeze the plan
    python tools/pipeline/worklist.py --batch 7      # what batch 7 must author

The full run fans out over more than a hundred readers at once, so the split has
to be decided ONCE and written down. Recomputing "what is still unauthored" per
agent would reshuffle every batch as files land, and two agents would read the
same page while a third read none.

Batching is by SIZE, not count: pages run from 300 characters to 10,000, so a
flat ten-per-agent would hand one reader four short trades and another 60
bullets of Abyssea routing. Balanced batches keep the slowest agent close to the
median one, which is what decides how long the whole run takes.

Snapshotting is also what makes the run resumable. Re-snapshot after a partial
run and the finished quests drop out; the remaining ones re-batch and the
workflow can be pointed at them again.

Build-time only.
"""

import argparse
import glob
import io
import json
import os
import re

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, "..", ".."))
BUILD = os.path.join(ADDON, "build")
RENDERED = os.path.join(BUILD, "rendered")
AUTHORED = os.path.join(BUILD, "authored")
PLAN = os.path.join(BUILD, "reports", "worklist.json")

MAX_CHARS = 20000
MAX_PAGES = 10


def authored_cache_files():
    done = set()
    for f in glob.glob(os.path.join(AUTHORED, "*.json")):
        try:
            with io.open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception:
            continue
        for q in (d if isinstance(d, list) else [d]):
            cf = (q.get("source") or {}).get("cache_file")
            if cf:
                done.add(cf)
    return done


def protected_cache_files():
    """Quests a HUMAN corrected. These may never be scheduled for re-reading.

    A correction is made against the GAME. Re-reading the page and overwriting
    it destroys a decision that outranks the page, and nothing downstream would
    notice or complain: validate, emit and build_index all read from
    build/authored/ downward and invent nothing, so a clobbered correction just
    quietly stops being true.

    Two markers, and both are checked because they mean different things:

      `human` block      written by tools/questgraph. Carries who, when, why
                         and a `basis` of "reading" or "game".
      `verified_in_game` the older flag, already on records that predate the
                         editor (Mandragora-Mad and friends). It means the
                         same thing and is treated as ground truth.

    Belt and braces: these are excluded EXPLICITLY rather than relying on the
    fact that an authored quest is already skipped as "done". The two rules
    look identical today, and they are still not the same rule: "already read"
    is an efficiency, "corrected by a human" is a prohibition, and only one of
    them should survive somebody deciding to re-read a batch on purpose.
    """
    prot = {}
    for f in glob.glob(os.path.join(AUTHORED, "*.json")):
        try:
            with io.open(f, encoding="utf-8") as fh:
                d = json.load(fh)
        except Exception:
            continue
        for q in (d if isinstance(d, list) else [d]):
            cf = (q.get("source") or {}).get("cache_file")
            if not cf:
                continue
            h = q.get("human")
            flags = q.get("review_flags") or []
            if h or "verified_in_game" in flags:
                ident = q.get("identity") or {}
                prot[cf] = {
                    "quest": "%s/%s/%s" % (ident.get("cat"), ident.get("area"),
                                           ident.get("id")),
                    "title": (q.get("source") or {}).get("wiki_title"),
                    "basis": (h or {}).get("basis")
                             or ("game" if "verified_in_game" in flags else None),
                    "reason": (h or {}).get("reason"),
                    "by": (h or {}).get("by"),
                    "file": os.path.basename(f),
                }
    return prot


def front_cat(path):
    """The `cat` a rendered document CLAIMS, defaulting to "quest".

    Reads a prefix rather than the whole file: the front matter is the first block and
    these documents run to 10 KB.

    The default is the point. This gate exists to keep MISSION documents out of the
    quest plan, and every one of them says `"cat": "mission"` in its own front matter,
    so positive evidence is enough to catch all 704. Inverting that (scheduling only
    what proves itself a quest) would mean a quest whose front matter was truncated
    or malformed drops silently out of the plan and is never authored by anyone. That
    is the worse and quieter failure of the two, so an unreadable header stays in."""
    try:
        with io.open(path, encoding="utf-8") as f:
            head = f.read(4096)
        m = re.match(r"^---\n(.*?)\n---\n", head, re.S)
        if not m:
            return "quest"
        return json.loads(m.group(1)).get("cat") or "quest"
    except Exception:
        return "quest"


def snapshot():
    done = authored_cache_files()
    protected = protected_cache_files()
    rows = []
    refused = []
    for p in sorted(glob.glob(os.path.join(RENDERED, "*.md"))):
        #[[ Quests only, stated by the file rather than assumed from the directory.
        #
        #   build/rendered/ is not quests only. mission_prepass.py writes its 704
        #   mission and Campaign Ops documents here too, because
        #   questmarks-ui/notes.lua:scan_desc reads THIS directory to find a
        #   mission's in-game description, and a file anywhere else is a
        #   description the detail pane never shows.
        #
        #   Without this gate every one of those missions would enter the quest
        #   authoring plan: none of them appears in `done` (that set is built from
        #   quest cache_files), so all 704 would look like unauthored quests and be
        #   batched out to readers. The failure would be silent and expensive, which
        #   is why the check is here and not left to the reader to notice. ]]
        if front_cat(p) != "quest":
            continue
        base = os.path.basename(p)[:-3]
        #[[ Both spellings, because the corpus genuinely contains both.
        #
        #   Matching only the short form is tempting and wrong. The older
        #   convention stripped the trailing content hash, and the
        #   `_run`/`_batch`/`_mission`/`_straggler` records do, but prepass.py
        #   emits the REAL basename and the `_campaign`/`_coalition` batches
        #   copy it verbatim: 290 records with the hash intact.
        #
        #   Match one spelling and every record written in the other is
        #   invisible here, so an already-authored page is offered as new work.
        #   That would batch out 99 pages, 97 of which already have a record:
        #   the whole 95-page coalition batch plus two redirect stubs. It is
        #   not silent for long, because validate.py is fatal on a duplicate
        #   identity, but the cost is a wasted authoring pass ending in a hard
        #   build failure.
        #
        #   check_authored.py accepts either spelling for the same reason, so
        #   the two tools agree. ]]
        cache_file = re.sub(r"_[0-9a-f]{10}$", "", base)
        for spelling in (cache_file, base):
            if spelling in protected or spelling in done:
                cache_file = spelling
                break
        if cache_file in protected:
            #[[ Checked BEFORE `done`, and reported separately, so the refusal
            #   is visible rather than hiding inside a skip count. ]]
            refused.append(protected[cache_file])
            continue
        if cache_file in done:
            continue
        rows.append({"page": base, "cache_file": cache_file,
                     "chars": os.path.getsize(p)})

    #[[ Largest first, then greedily filled: bin-packing the long tail of
    #   10,000-character pages first stops them all landing in the last batch. ]]
    rows.sort(key=lambda r: -r["chars"])
    batches, cur, cur_chars = [], [], 0
    order = []
    while rows:
        r = rows.pop(0)
        if cur and (len(cur) >= MAX_PAGES or cur_chars + r["chars"] > MAX_CHARS):
            batches.append(cur)
            cur, cur_chars = [], 0
        cur.append(r)
        cur_chars += r["chars"]
    if cur:
        batches.append(cur)
    for i, b in enumerate(batches):
        order.append({"batch": i, "pages": [x["page"] for x in b],
                      "chars": sum(x["chars"] for x in b)})

    d = os.path.dirname(PLAN)
    if not os.path.isdir(d):
        os.makedirs(d)
    with io.open(PLAN, "w", encoding="utf-8", newline="\n") as f:
        json.dump({"batches": order, "authored_already": len(done),
                   "protected": refused}, f, ensure_ascii=False, indent=1)
    n = sum(len(b["pages"]) for b in order)
    print("snapshot: %d unauthored page(s) -> %d batch(es)" % (n, len(order)))
    if refused:
        print("  PROTECTED, and deliberately not scheduled: %d human-corrected "
              "quest(s)" % len(refused))
        for r in refused:
            print("     %-22s %-38s basis=%s"
                  % (r["quest"], (r["title"] or "")[:36], r["basis"]))
        print("     A correction is made against the GAME. Re-reading the page"
              " would overwrite it")
        print("     and nothing downstream would notice. Use tools/questgraph"
              " to review or revert one.")
    if order:
        cs = sorted(b["chars"] for b in order)
        print("  pages/batch  min %d  max %d"
              % (min(len(b["pages"]) for b in order),
                 max(len(b["pages"]) for b in order)))
        print("  chars/batch  min %d  median %d  max %d"
              % (cs[0], cs[len(cs) // 2], cs[-1]))
    print("  wrote %s" % PLAN)
    return order


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--snapshot", action="store_true")
    ap.add_argument("--batch", type=int)
    ap.add_argument("--count", action="store_true")
    ap.add_argument("--protected", action="store_true",
                    help="list the human-corrected quests that may never be "
                         "re-read")
    args = ap.parse_args()

    if args.protected:
        prot = protected_cache_files()
        if not prot:
            print("no human-corrected records -- the corpus is purely "
                  "machine-authored")
            return
        print("%d human-corrected quest(s), protected from re-reading:"
              % len(prot))
        for cf, r in sorted(prot.items()):
            print("  %-22s %-38s basis=%-8s %s"
                  % (r["quest"], (r["title"] or "")[:36], r["basis"],
                     r["by"] or ""))
            if r["reason"]:
                print("     %s" % r["reason"])
        return

    if args.snapshot:
        snapshot()
        return

    with io.open(PLAN, encoding="utf-8") as f:
        plan = json.load(f)

    if args.count:
        print(len(plan["batches"]))
        return

    if args.batch is None:
        raise SystemExit("need --snapshot, --count, --protected or --batch N")
    b = plan["batches"][args.batch]

    #[[ Re-derived here rather than trusted from the plan, and this is the
    #   guard that actually matters. The plan is a SNAPSHOT: it is written
    #   once and reused across a run that takes hours, so a correction made
    #   after the snapshot would not be in it. Checking the live authored data
    #   at the moment a batch is handed out is the only check that cannot go
    #   stale. A hand-edited plan cannot get past it either. ]]
    protected = protected_cache_files()
    hits = []
    for p in b["pages"]:
        cf = re.sub(r"_[0-9a-f]{10}$", "", p)
        if cf in protected:
            hits.append(protected[cf])
    if hits:
        raise SystemExit(
            "REFUSED: batch %d contains %d human-corrected quest(s):\n%s\n\n"
            "A correction is made against the GAME; the page is what the human "
            "was correcting.\nRe-reading it would overwrite that decision and "
            "nothing downstream would notice.\nRe-run --snapshot to rebuild "
            "the plan without them."
            % (args.batch, len(hits),
               "\n".join("  %s  %s  (basis=%s) %s"
                         % (h["quest"], h["title"], h["basis"],
                            h["reason"] or "") for h in hits)))

    for p in b["pages"]:
        print(os.path.join("build", "rendered", p + ".md"))


if __name__ == "__main__":
    main()
