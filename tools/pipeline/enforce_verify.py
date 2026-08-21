"""Stage D's safety property, enforced deterministically.

    python tools/pipeline/enforce_verify.py [--apply]

The adversarial pass is allowed to remove, null and downgrade. It is not allowed
to add a step, add evidence, add an item, add a monster, rename a target or
raise a confidence. A verifier that can add is just a second, less careful
author, and nothing downstream would know which claims came from a careful
reading of the page and which from a sceptic's guess.

That property is enforced HERE rather than in the prompt. A prompt is a request;
this is a diff. Any quest whose verified form is not a strict weakening of its
draft is REVERTED to the draft wholesale and counted. So stage D is structurally
incapable of making the dataset worse, which is what lets it run unattended over
a thousand quests.

    build/preverify/_runNNN.json    what the reading pass wrote
    build/authored/_runNNN.json     what the adversary wrote  (authoritative)

A missing verified file is not a failure either: the draft is promoted
unchanged, because losing a batch to a dead verifier would be a far worse
outcome than skipping one batch's scepticism. A verified file that exists and
will not parse is the opposite case and stops the run, because the promotion
path would write over it.

Build-time only.
"""

import argparse
import glob
import io
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, "..", ".."))
BUILD = os.path.join(ADDON, "build")
DRAFTS = os.path.join(BUILD, "preverify")
FINAL = os.path.join(BUILD, "authored")

RANK = {"low": 1, "medium": 2, "high": 3}


class Unreadable(Exception):
    """The file is THERE and will not parse. Not the same as absent."""


def load(path):
    #[[ Absent and unparseable must stay different answers. `None` means "no
    #   verified file yet", and main() responds by promoting the draft over it.
    #   That is right for a verifier that died before writing, and catastrophic
    #   for a file that exists and is merely corrupt, because the promotion
    #   overwrites it, and each file holds 2-10 quests. ]]
    if not os.path.exists(path):
        return None
    try:
        with io.open(path, encoding="utf-8") as f:
            d = json.load(f)
        return d if isinstance(d, list) else [d]
    except Exception as e:
        raise Unreadable("%s: %s" % (os.path.basename(path), e))


def human_marked(q):
    """True if a person decided this record, by either marker.

    `human`            written by tools/questgraph: who, when, why, basis.
    `verified_in_game` the older flag, on records that predate the editor.
    """
    return bool(q.get("human")) or \
        "verified_in_game" in (q.get("review_flags") or [])


def key_of(q):
    i = q.get("identity") or {}
    return (i.get("cat"), i.get("area"), i.get("id"))


def names(lst, *fields):
    out = set()
    for it in (lst or []):
        out.add(tuple(it.get(f) for f in fields))
    return out


def ev_names(step):
    ev = step.get("evidence") or {}
    return names((ev.get("all") or []) + (ev.get("alt") or []), "kind", "name")


def item_names(step):
    return names((step.get("items") or []) + (step.get("items_alt") or []),
                 "kind", "name")


def mark_reverted(draft, reasons):
    """The draft, stamped so a REVERT is distinguishable from a never-check.

    A revert writes the draft back wholesale, and the draft's `verify` is null.
    That is also what a quest nobody ever verified looks like: quest/abyssea/28,
    the single revert of the 963-quest full run, was indistinguishable from the
    40 pilot quests stage D had never been pointed at. One of those needs
    re-reading and the other needs nothing, and without a stamp nothing in the
    data says which is which.

    'reverted' is not 'unverified': the quest WAS checked, the sceptic
    over-reached, and the careful reading stands. Recording that costs one
    field and removes an ambiguity that hides a real gap.
    """
    q = json.loads(json.dumps(draft))
    q.setdefault("extraction", {})["verify"] = {
        "verdict": "reverted",
        "changes": 0,
        "reasons": reasons[:5],
    }
    return q


def violations(draft, ver):
    """-> list of reasons the verified quest is NOT a weakening of the draft."""
    bad = []
    if RANK.get(ver.get("confidence"), 0) > RANK.get(draft.get("confidence"), 0):
        bad.append("raised quest confidence")

    ds, vs = draft.get("steps") or [], ver.get("steps") or []
    if len(vs) > len(ds):
        bad.append("added %d step(s)" % (len(vs) - len(ds)))

    dg = draft.get("gates") or {}
    vg = ver.get("gates") or {}
    if set(vg.get("jobs") or []) - set(dg.get("jobs") or []):
        bad.append("added a job gate")
    if len(vg.get("prev") or []) > len(dg.get("prev") or []):
        bad.append("added a prerequisite")

    #[[ Compared by POSITION. A verifier that deletes step 3 shifts everything
    #   after it, which reads here as several steps changing at once. That is
    #   correct: a deletion that also rewrites the tail is not a removal, and
    #   the quest goes back. The honest way to drop a step is to drop it. ]]
    for i, (d, v) in enumerate(zip(ds, vs), 1):
        if RANK.get(v.get("confidence"), 0) > RANK.get(d.get("confidence"), 0):
            bad.append("step %d: raised confidence" % i)
        if ev_names(v) - ev_names(d):
            bad.append("step %d: added evidence" % i)
        if item_names(v) - item_names(d):
            bad.append("step %d: added items" % i)
        if names(v.get("mobs"), "name") - names(d.get("mobs"), "name"):
            bad.append("step %d: added monsters" % i)
        if d.get("optional") and not v.get("optional"):
            bad.append("step %d: un-marked optional" % i)
        dt = (d.get("target") or {}).get("name")
        vt = (v.get("target") or {}).get("name")
        if vt is not None and vt != dt:
            bad.append("step %d: renamed the target" % i)
        if v.get("kind") != d.get("kind"):
            bad.append("step %d: changed kind" % i)
    return bad


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true",
                    help="write the reverts; without it, only report")
    args = ap.parse_args()

    stats = {"batches": 0, "quests": 0, "kept": 0, "reverted": 0,
             "promoted_draft": 0, "missing_in_verified": 0,
             "human_protected": 0}
    reasons = {}
    reverted_quests = []
    protected_quests = []

    #[[ `_run*` AND `_batch*`, and both halves matter.
    #
    #   A pattern that decides which files are subject to a safety property is
    #   itself part of that property. Narrow it and the excluded files are
    #   exempt without anything saying so. main() prints the unverified count
    #   for the same reason: a gap of that shape should be loud. ]]
    drafts = sorted(glob.glob(os.path.join(DRAFTS, "_run*.json"))
                    + glob.glob(os.path.join(DRAFTS, "_batch*.json")))
    for dpath in drafts:
        base = os.path.basename(dpath)
        vpath = os.path.join(FINAL, base)
        try:
            draft = load(dpath)
        except Unreadable as e:
            print("  UNREADABLE DRAFT %s -- skipped" % e)
            continue
        if draft is None:
            print("  MISSING DRAFT %s -- skipped" % base)
            continue
        stats["batches"] += 1
        #[[ An authored file that exists and will not parse must ABORT, never
        #   fall through to the draft-promotion branch below. That branch
        #   writes over vpath, so a transient corruption would be made
        #   permanent and reported as the benign "drafts promoted whole N". ]]
        try:
            ver = load(vpath)
        except Unreadable as e:
            raise SystemExit(
                "ABORTED: %s exists and will not parse.\n"
                "Refusing to continue: the recovery path for a missing file is "
                "to promote the draft over it,\nwhich would overwrite %d "
                "quest(s) of real authored data with the pre-verify version.\n"
                "Fix or restore the file first." % (e, len(draft)))

        if ver is None:
            stats["promoted_draft"] += 1
            stats["quests"] += len(draft)
            stats["kept"] += len(draft)
            if args.apply:
                with io.open(vpath, "w", encoding="utf-8", newline="\n") as f:
                    json.dump(draft, f, ensure_ascii=False, indent=1)
            continue

        by_key = {}
        for q in ver:
            by_key[key_of(q)] = q

        out = []
        for q in draft:
            k = key_of(q)
            v = by_key.get(k)
            stats["quests"] += 1
            if v is None:
                #[[ The adversary may not make a quest vanish. Dropping one
                #   entirely is not a downgrade, it is a deletion. ]]
                stats["missing_in_verified"] += 1
                stats["reverted"] += 1
                out.append(mark_reverted(q, ["dropped by the verifier"]))
                continue

            #[[ A human correction is not a verifier edit, and this check has
            #   to come before violations().
            #
            #   Everything below assumes the authored file is what the stage-D
            #   adversary wrote, and that the only legitimate direction of
            #   travel is weakening. It therefore reverts an added target, an
            #   added piece of evidence, a changed kind or a raised confidence
            #   back to the pre-verify draft, replacing the WHOLE quest.
            #
            #   A correction made against the GAME is, by construction, a
            #   strengthening: it renames the target the page got wrong, adds
            #   the evidence the page omitted, raises confidence because
            #   somebody went and looked. Every one of those is on the forbidden
            #   list. Without this branch the enforcer would delete exactly the
            #   most trustworthy records in the corpus (along with the `human`
            #   block recording who made them and why) and report it as
            #   "REVERTED to the draft N", indistinguishable from verifier
            #   overreach.
            #
            #   The verifier's remit is the MACHINE's second opinion on the
            #   MACHINE's reading. It has no standing over a person who checked
            #   the game. ]]
            if human_marked(v):
                stats["human_protected"] += 1
                protected_quests.append(
                    "%s/%s/%s  %s" % (k[0], k[1], k[2],
                                      (v.get("human") or {}).get("reason")
                                      or "verified_in_game"))
                stats["kept"] += 1
                out.append(v)
                continue

            bad = violations(q, v)
            if bad:
                stats["reverted"] += 1
                for b in bad:
                    kind = b.split(":")[-1].strip()
                    reasons[kind] = reasons.get(kind, 0) + 1
                reverted_quests.append("%s/%s/%s  %s"
                                       % (k[0], k[1], k[2], "; ".join(bad[:3])))
                out.append(mark_reverted(q, bad))
            else:
                stats["kept"] += 1
                out.append(v)

        if args.apply:
            with io.open(vpath, "w", encoding="utf-8", newline="\n") as f:
                json.dump(out, f, ensure_ascii=False, indent=1)

    #[[ The count nothing else here can produce.
    #
    #   Everything below reports on what the enforcer processed. None of it
    #   reports on what the enforcer never saw, so a whole batch can sit
    #   unverified while the summary still reads as complete.
    #
    #   This counts `extraction.verify == null` across the WHOLE authored
    #   corpus, independently of drafts and globs. It is the only line here that
    #   can notice a batch the enforcer was never pointed at. ]]
    unverified, total = [], 0
    for apath in sorted(glob.glob(os.path.join(FINAL, "*.json"))):
        for q in (load(apath) or []):
            total += 1
            if ((q.get("extraction") or {}).get("verify")) is None:
                unverified.append("%s  %s" % (os.path.basename(apath),
                                              (q.get("identity") or {}).get("dat_name")))

    print("stage D monotone check%s" % ("" if args.apply else "  (dry run)"))
    print("  batches                 %d" % stats["batches"])
    print("  quests                  %d" % stats["quests"])
    print("  authored corpus         %d quests, %d WITH NO VERIFY RECORD"
          % (total, len(unverified)))
    for u in unverified[:10]:
        print("      unverified: %s" % u)
    if len(unverified) > 10:
        print("      ... and %d more" % (len(unverified) - 10))
    print("  verifier edits kept     %d" % stats["kept"])
    print("  REVERTED to the draft   %d" % stats["reverted"])
    #[[ Printed unconditionally, including the zero. "0 human corrections were
    #   in scope" and "this enforcer does not know about human corrections"
    #   look identical if the line only appears when the count is non-zero.
    #   A silent omission is the same shape of gap as a too-narrow glob. ]]
    print("  HUMAN-CORRECTED, left alone  %d  (a correction is made against "
          "the game; the verifier has no standing over it)"
          % stats["human_protected"])
    for r in protected_quests[:15]:
        print("     kept: %s" % r)
    print("  drafts promoted whole   %d  (verifier produced nothing)"
          % stats["promoted_draft"])
    print("  quests the verifier dropped entirely  %d"
          % stats["missing_in_verified"])
    for k in sorted(reasons, key=lambda x: -reasons[x]):
        print("     %-34s %d" % (k, reasons[k]))
    for r in reverted_quests[:15]:
        print("     e.g. %s" % r)


if __name__ == "__main__":
    main()
