"""Check a proposed authored record before it goes anywhere near disk.

Build-time only. The verdict is not reimplemented here: `gate_check` imports
validate.py and calls it, so it cannot drift from the shipped code. Nothing
here writes; only validate.py's `main()` does. Every gate in `validate()` is
per-quest, so a one-quest corpus gives exactly the full build's answer.

`schema_check` below IS a second implementation, on purpose: validate.py
answers a malformed record with a traceback, not a verdict. Two rules (dense
`n`, empty AND-evidence) live in both files. Change both.

A FATAL flag does less than validate.py's messages claim. Its `validate()`
only sets conf="low"; the row still comes back with every step, emit_lua.py's
`main()` skips just the zero-step quests, and no runtime code reads `conf`.
19 conf=1 rows ship in data/quest_steps.lua today with ladders and givers
intact. Nothing is "demoted to start-NPC only"; CONSEQUENCE says which two
bite.
"""

import copy
import os
import sys

from corpus import (CONFIDENCE, KINDS, PLACEHOLDERS, QUEST_KEYS, STEP_KEYS,
                    TARGET_TYPES, ADDON)

PIPELINE = os.path.join(ADDON, "tools", "pipeline")
if PIPELINE not in sys.path:
    sys.path.insert(0, PIPELINE)

import validate as _validate            # noqa: E402  the real thing, not a copy

#[[ validate.py's own list, bound rather than copied, so a future divergence is
#   a NameError at import time rather than a gate that silently stopped being
#   checked. Seven members; two of them (`no_dat_id`, `ambiguous_dat_id`) are
#   produced at PREPASS by tools/pipeline/lib/names.py, which quarantines the
#   page before it is ever authored: 0 of the 1546 authored records carry
#   either,
#   so five are reachable from here. ]]
FATAL = _validate.FATAL

#[[ What each flag actually costs downstream, traced through emit_lua.py and
#   build_index.lua rather than taken from validate.py's message strings. The
#   editor shows this instead of "quest demoted", which is not true. ]]
CONSEQUENCE = {
    "ambiguous_npc_no_zone":
        "REAL: validate.py drops npc_key on this shape, so the step keeps its rung "
        "and loses its marker. This is the 'every Moogle in Vana'diel' gate.",
    "start_npc_unresolved":
        "REAL. The ladder still ships, but this record is the only thing that "
        "supplies a start NPC, so an unresolved start means the quest draws no "
        "start marker at all.",
    "evidence_duplicate":
        "LABEL ONLY: both entries still emit. The real hazard is unchanged -- "
        "obtaining the item jumps the high-water mark to the LATER step and "
        "skips everything between. Fix it; nothing downstream will.",
    "evidence_empty":
        "LABEL ONLY: an empty list emits as nil either way. Harmless as data, "
        "but it means the reading says something it did not mean.",
    "steps_not_dense":
        "LABEL ONLY: validate.py renumbers `n` from the array index, so it "
        "repairs the problem and then flags it. Nothing ships wrong.",
    "no_dat_id": "unreachable from here -- produced at prepass.",
    "ambiguous_dat_id": "unreachable from here -- produced at prepass.",
}

#[[ `basis` is provenance for a person, and one machine reads it:
#   tools/pipeline/worklist.py refuses to schedule either kind for re-reading,
#   and tools/pipeline/enforce_verify.py refuses to revert either kind.
#   Nothing branches on reading vs game today. It is there so a later reader
#   can decide whether a better reading of the same page may supersede this
#   record. ]]
BASES = ("reading", "game")

#[[ Quarantine reasons whose flag the FATAL loop already reports, accurately,
#   against the same step. Passing the raw row through as well would print
#   validate.py's "quest demoted" / "quest NOT emitted" beside a message
#   saying the opposite, and the operator would believe the scarier one. ]]
ANCHORED_REASONS = {
    "ambiguous_npc_without_zone", "unresolved_and_no_markable_step",
    "not_dense", "unknown_kind", "unknown_target_type", "empty_and_list",
}


class Problem(object):
    __slots__ = ("level", "where", "text")

    def __init__(self, level, where, text):
        self.level = level              # 'error' | 'warn' | 'note'
        self.where = where
        self.text = text

    def as_dict(self):
        return {"level": self.level, "where": self.where, "text": self.text}


def _req_keys(obj, keys, where, out, what):
    missing = [k for k in keys if k not in obj]
    if missing:
        out.append(Problem(
            "error", where,
            "%s is missing %s. Every key is required on every object and every "
            "step: an omitted key is indistinguishable from a truncated "
            "response, so explicit null is the way to say \"nothing here\"."
            % (what, ", ".join(missing))))


def schema_check(q):
    """Structure only. The gates that decide whether it BUILDS come later."""
    out = []
    _req_keys(q, QUEST_KEYS, "quest", out, "the record")

    if q.get("schema") != "questmarks-authoring/1":
        out.append(Problem("error", "schema",
                           "schema must stay 'questmarks-authoring/1', got %r"
                           % q.get("schema")))
    if q.get("confidence") not in CONFIDENCE:
        out.append(Problem("error", "confidence",
                           "confidence must be one of %s" % (CONFIDENCE,)))

    for k in ("review_flags",):
        if not isinstance(q.get(k), list):
            out.append(Problem("error", k, "%s must be a list, never null" % k))

    g = q.get("gates")
    if not isinstance(g, dict):
        out.append(Problem("error", "gates", "gates must be an object"))
    else:
        if not isinstance(g.get("jobs"), list):
            #[[ `jobs` is a LIST and must stay one the whole way down. A scalar
            #   `job` resolves to None in validate.py, so every job gate is
            #   dropped silently: a three-way disagreement where each end looks
            #   locally correct. `Old Wounds` gates on seven. ]]
            out.append(Problem("error", "gates.jobs",
                               "gates.jobs must be a LIST (Old Wounds gates on "
                               "seven jobs); a scalar is the bug that made "
                               "every job gate vanish"))
        if not isinstance(g.get("prev"), list):
            out.append(Problem("error", "gates.prev",
                               "gates.prev must be a list"))
        #[[ `craft` is OPTIONAL (one quest in a thousand carries one), so
        #   absence is fine and only a present-but-wrong shape is an error.
        #   Checked here for the same reason `jobs` is: it is a LIST, and the
        #   scalar form is what makes every job gate vanish silently between
        #   the schema and validate.py.
        #
        #   A gate naming neither a rank nor a level is refused rather than
        #   dropped quietly. validate.py drops such a gate, correctly, since a
        #   gate it cannot read must not grey a marker. But a gate that
        #   disappears between the editor and the build is a three-way
        #   disagreement where each end looks locally right. ]]
        craft = g.get("craft")
        if craft is not None:
            if not isinstance(craft, list):
                out.append(Problem("error", "gates.craft",
                                   "gates.craft must be a LIST (it is an "
                                   "AND-list of craft requirements); a scalar "
                                   "is the shape that made every job gate "
                                   "vanish"))
            else:
                for i, c in enumerate(craft):
                    w = "gates.craft[%d]" % i
                    if not isinstance(c, dict):
                        out.append(Problem("error", w, "each craft gate must "
                                                       "be an object"))
                        continue
                    if not c.get("skill"):
                        out.append(Problem("error", w + ".skill",
                                           "a craft gate must name a skill"))
                    if c.get("rank") is None and c.get("level") is None:
                        out.append(Problem("error", w,
                                           "a craft gate must give a rank or a "
                                           "level; one with neither is dropped "
                                           "by validate.py and the gate would "
                                           "silently stop existing"))

    steps = q.get("steps")
    if not isinstance(steps, list):
        out.append(Problem("error", "steps", "steps must be a list"))
        return out

    for i, s in enumerate(steps, 1):
        w = "steps[%d]" % i
        _req_keys(s, STEP_KEYS, w, out, "step %d" % i)
        if s.get("n") != i:
            out.append(Problem("error", w + ".n",
                               "n must be dense 1..N in array order; step at "
                               "position %d says n=%r" % (i, s.get("n"))))
        if s.get("kind") not in KINDS:
            #[[ The count is derived, never typed. It read "nine, not
            #   twenty-four" while KINDS held ten, so the message a reader
            #   trusts was the one thing in the check that was wrong. ]]
            out.append(Problem("error", w + ".kind",
                               "kind must be one of these %d, and the "
                               "vocabulary is closed: %s" % (len(KINDS), KINDS)))
        t = s.get("target") or {}
        if t.get("type") not in TARGET_TYPES:
            out.append(Problem("error", w + ".target.type",
                               "target.type must be one of %s" % (TARGET_TYPES,)))
        if t.get("type") in ("npc", "object") and not t.get("name"):
            out.append(Problem("error", w + ".target.name",
                               "an npc/object target needs a name; if the page "
                               "does not name it, the type is 'none' and the "
                               "note says so"))
        if t.get("type") == "none" and t.get("name"):
            out.append(Problem("warn", w + ".target.name",
                               "target.type is 'none' but a name is set -- one "
                               "of the two is wrong"))
        if s.get("confidence") not in CONFIDENCE:
            out.append(Problem("error", w + ".confidence",
                               "step confidence must be one of %s" % (CONFIDENCE,)))
        for k in ("items", "items_alt", "mobs", "source_bullets"):
            if not isinstance(s.get(k), list):
                out.append(Problem("error", "%s.%s" % (w, k),
                                   "%s must be a list, never null" % k))
        ev = s.get("evidence")
        if ev is not None:
            if not isinstance(ev, dict):
                out.append(Problem("error", w + ".evidence",
                                   "evidence is null or {all:[], alt:[]}"))
            elif not ((ev.get("all") or []) or (ev.get("alt") or [])):
                #[[ Hard gate: an empty AND-list is vacuously true, so it would
                #   advance the high-water mark on nothing at all. ]]
                out.append(Problem("error", w + ".evidence",
                                   "{\"all\": []} with no alt is illegal -- an "
                                   "empty AND-list is vacuously true and would "
                                   "advance the mark on nothing"))
        if not isinstance(s.get("items_partial"), bool):
            out.append(Problem("error", w + ".items_partial",
                               "items_partial must be a boolean"))
        if not isinstance(s.get("optional"), bool):
            out.append(Problem("error", w + ".optional",
                               "optional must be a boolean"))
        for m in (s.get("mobs") or []):
            if m.get("role") not in ("kill", "drop", "spawn"):
                out.append(Problem("error", w + ".mobs",
                                   "mob role must be kill | drop | spawn, got %r"
                                   % m.get("role")))
    return out


def identity_check(old, new):
    """Things a correction may never change.

    Identity is how every downstream layer joins; provenance is the record of
    which page was read. A correction changes the READING, never which quest
    this is or which revision it came from. If the page itself has changed,
    that is a re-read, not a correction, and it needs a different
    conversation.
    """
    out = []
    for block, keys in (("identity", ("cat", "area", "id", "dat_name")),
                        ("source", ("wiki_title", "page_id", "revision_id",
                                    "source_sha256", "cache_file"))):
        o, n = (old.get(block) or {}), (new.get(block) or {})
        for k in keys:
            if o.get(k) != n.get(k):
                out.append(Problem(
                    "error", "%s.%s" % (block, k),
                    "%s.%s is provenance and may not be edited (%r -> %r). "
                    "If the wiki page genuinely changed, that is a re-read "
                    "against a new revision, not a correction to this one."
                    % (block, k, o.get(k), n.get(k))))
    #[[ The stage-D verifier's record. The `extraction` block is NOT where a
    #   human marker goes. Most records already carry `extraction.verify` =
    #   {verdict, changes}, and overwriting `extraction.reader` would destroy
    #   the only evidence that the adversarial pass ever ran on this quest.
    #   The human marker is the `human` block; see edits.human_block. ]]
    oe, ne = (old.get("extraction") or {}), (new.get("extraction") or {})
    if oe != ne:
        out.append(Problem(
            "error", "extraction",
            "the extraction block records how the MACHINE read this page, "
            "including the stage-D verifier's verdict. A human correction is "
            "recorded in the `human` block instead, so both survive."))
    return out


def human_block_check(new, basis, reason):
    out = []
    if basis not in BASES:
        out.append(Problem("error", "human.basis",
                           "basis must be one of %s" % (BASES,)))
    if not (reason or "").strip():
        out.append(Problem("error", "human.reason",
                           "a correction with no reason cannot be reviewed "
                           "later, and reviewing it later is the entire point"))
    elif len((reason or "").strip()) < 12:
        out.append(Problem("warn", "human.reason",
                           "the reason is very short -- a future session reads "
                           "this to decide whether to trust the record"))
    return out


# ------------------------------------------------------------------ the gates

def run_validate(q):
    """The REAL validate.py, over a one-quest corpus. Returns (row, quarantine).

    All five hard gates are per-quest, so this is exactly what the full build
    would decide about this record: no approximation.
    """
    q = copy.deepcopy(q)
    quarantine = []
    res = _validate.resolve_batch(_validate.collect([q]))
    row = _validate.validate(q, res, quarantine)
    return row, quarantine


def gate_check(q):
    """Gate verdict for a proposed record, from validate.py itself."""
    out = []
    try:
        row, quarantine = run_validate(q)
    #[[ BaseException, not Exception. validate.py's `resolve_batch` answers a
    #   failed resolve.lua with sys.exit(), which raises SystemExit. SystemExit
    #   inherits BaseException, so `except Exception` lets it through and the
    #   editor dies mid-preview instead of showing a reviewable problem. A
    #   missing LuaJIT or a broken res/ table is not hypothetical; corpus.py
    #   already degrades gracefully for exactly that. ]]
    except BaseException as e:
        return [Problem("error", "validate",
                        "validate.py could not read this record: %s" % e)], None, []

    #[[ Anchor each flag to the STEP it is about. A problem shown in a list at
    #   the bottom of the page is a problem about the page; a problem shown on
    #   step 22 is a problem about step 22, and only the second is actionable.
    #   validate.py already knows which step: it wrote a quarantine row with
    #   the field on it. The flag is matched back to that row rather than
    #   guessed at. ]]
    anchor = {}
    for f, patterns in (("evidence_duplicate", ("duplicate_of_step_",)),
                        ("ambiguous_npc_no_zone", ("ambiguous_npc_without_zone",)),
                        ("start_npc_unresolved", ("unresolved_and_no_markable_step",)),
                        ("steps_not_dense", ("not_dense", "unknown_kind",
                                             "unknown_target_type")),
                        ("evidence_empty", ("empty_and_list",))):
        for r in quarantine:
            if any(r["reason"].startswith(p) for p in patterns):
                anchor[f] = r["field"]
                break

    fatal = set(row["flags"]) & FATAL
    for f in sorted(fatal):
        #[[ One problem per flag, each carrying what it ACTUALLY costs. Do not
        #   fold them back into one "demoted to start-NPC only" message: that
        #   penalty is false (see the module docstring), and a false penalty
        #   is one the operator learns to click past. ]]
        out.append(Problem(
            "error", anchor.get(f, "gate: " + f),
            CONSEQUENCE.get(f, "flagged by validate.py")))

    for r in quarantine:
        if r["reason"] == "placeholder_target":
            #[[ By design: '???' keeps its rung and loses only its marker.
            #   Reported as a note so the editor can say "yes, that is what
            #   you asked for" rather than staying silent about it. ]]
            out.append(Problem("note", r["field"],
                               "%s (%s) -- by design, the step keeps its rung "
                               "and loses only its marker"
                               % (r["reason"], r["raw"])))
        elif (r["reason"] in ANCHORED_REASONS
                or r["reason"].startswith("duplicate_of_step_")):
            #[[ Already stated, accurately, by the FATAL loop above. Repeating
            #   it here with validate.py's own "quest demoted" wording would
            #   put a claim on screen that is false; see the docstring. ]]
            continue
        else:
            out.append(Problem("warn", r["field"],
                               "%s: %r -> %s" % (r["reason"], r["raw"],
                                                 r["action"])))
    return out, row, quarantine


def reachability_check(row):
    """The hard rule on evidence, which no other code enforces.

    "Evidence must be obtained AT that step. A key item granted at step 1 is
    step 1's evidence, not step 2's."

    Breaking it looks like a fix. Somebody reports "the marker sits on step 2
    forever", a human moves the key item down to step 5's evidence, and the
    mark does advance: straight to step 6. core/steps.lua takes `best` as
    the highest evidenced step and the walk-back only goes backwards, so steps
    2 through 5 become unreachable for every player, permanently. The
    duplicate-evidence gate stays quiet: the id appears exactly once.

    Detectable offline: an item REQUIRED at an earlier step (you already hold
    it) that is EVIDENCE at a later one (obtaining it proves the later step is
    done). Both cannot be true. Zero hits over all 1003 shipped quests, so it
    is an error, not a warning.
    """
    out = []
    req_at = {}
    for s in row["steps"]:
        for r in (s.get("reqs") or []) + (s.get("reqs_alt") or []):
            req_at.setdefault((r["kind"], r["rid"]), s["n"])
    for s in row["steps"]:
        for e in (s.get("ev") or []) + (s.get("ev_alt") or []):
            k = (e["kind"], e["rid"])
            first = req_at.get(k)
            if first is not None and first < s["n"]:
                out.append(Problem(
                    "error", "steps[%d].evidence" % s["n"],
                    "%s %d is already REQUIRED at step %d, so you hold it "
                    "before step %d. Making it step %d's evidence sends the "
                    "high-water mark straight past steps %d-%d and those "
                    "markers become unreachable for every player. Evidence "
                    "must be obtained AT its own step."
                    % (e["kind"], e["rid"], first, s["n"], s["n"],
                       first, s["n"] - 1)))
    return out


# --------------------------------------------------------- the one invariant

def marker_positions(row):
    """Every place this quest could ever put a marker, from a validated row.

    core/steps.lua's `markable()` accepts a step with an NPC key OR with
    monsters. A fight step whose only target is a monster is a real marker
    position, and testing `s.npc` alone keeps 49 of 54 monster rows from ever
    drawing. Step 0, the giver, is carried beside the ladder.
    """
    pos = set()
    if row.get("start_npc"):
        pos.add(("start", row["start_npc"], None))
    for s in row["steps"]:
        if s.get("npc"):
            pos.add(("npc", s["npc"], s.get("z")))
        for m in (s.get("mobs") or []):
            pos.add(("mob", m["name"], s.get("z")))
    return pos


def marker_delta(before_row, after_row):
    """The governing invariant: bad data may MOVE a marker, never DELETE one.

    Every cautious branch in core/steps.lua serves that sentence, so an editor
    that lets a human quietly delete one has undone the project's governing
    rule from the other end. This does not forbid the edit. Sometimes a marker
    really was on an NPC who is not there, so the check makes the human say so
    out loud.
    """
    if before_row is None or after_row is None:
        return [], set(), set()
    b, a = marker_positions(before_row), marker_positions(after_row)
    removed, added = b - a, a - b

    #[[ A zone change is a move, not a deletion, and conflating the two is
    #   worse than missing it. Correcting a wrong zone is the commonest real
    #   correction there is; reporting it as "this REMOVES a marker" and
    #   demanding an acknowledgement for every one teaches the operator to
    #   tick the box without reading it. That box is the only thing standing
    #   between them and a genuine deletion. Matched on (kind, name) so an
    #   entity that merely moved zone drops out of both sets. ]]
    moved = {(k, n) for k, n, _z in removed} & {(k, n) for k, n, _z in added}
    removed = {(k, n, z) for k, n, z in removed if (k, n) not in moved}
    added = {(k, n, z) for k, n, z in added if (k, n) not in moved}

    out = []
    if moved:
        out.append(Problem("note", "markers",
                           "%d marker(s) change zone: %s"
                           % (len(moved), ", ".join(sorted("%s %s" % (k, n)
                                                   for k, n in moved)))))
    if removed:
        out.append(Problem(
            "warn", "markers",
            "this edit REMOVES %d marker position(s): %s. The project's first "
            "invariant is that bad data may move a marker but may never delete "
            "one -- if that is what you mean, say so in the reason."
            % (len(removed), ", ".join(sorted("%s %s" % (k, n)
                                              for k, n, _ in removed)))))
    if added:
        out.append(Problem("note", "markers",
                           "adds %d marker position(s): %s"
                           % (len(added), ", ".join(sorted("%s %s" % (k, n)
                                                   for k, n, _ in added)))))
    return out, removed, added


def check_edit(old, new, basis, reason):
    """Everything, in one call. Returns (problems, validated_row, quarantine)."""
    problems = []
    problems += schema_check(new)
    if old is not None:
        problems += identity_check(old, new)
    problems += human_block_check(new, basis, reason)

    #[[ Only run the resolver if the shape is sound. validate.py assumes its
    #   input is well-formed: it is stage C of a pipeline whose stage B is
    #   governed by a schema. Feeding it a malformed record produces a
    #   traceback rather than a verdict, and a traceback is not a review. ]]
    if any(p.level == "error" for p in problems):
        return problems, None, []

    gate_problems, row, quarantine = gate_check(new)
    problems += gate_problems
    if row is not None:
        problems += reachability_check(row)
    if old is not None and row is not None:
        try:
            before_row, _ = run_validate(old)
        except BaseException:
            before_row = None
        delta, _, _ = marker_delta(before_row, row)
        problems += delta
        problems += ladder_moves(before_row, row)
    return problems, row, quarantine


def ladder_moves(before_row, after_row):
    """Which RUNG each marker sits on, which the position set cannot see.

    `marker_positions` is a set, so moving an NPC from rung 3 to rung 7 leaves
    it identical: same markers, completely different ladder. Since the mark
    advances by high-water evidence and the walk-back only goes backwards, a
    rung change decides when a marker appears, which is most of what a player
    experiences. Reported as a note: legitimate corrections reorder steps.
    """
    if before_row is None or after_row is None:
        return []
    def rungs(row):
        out = {}
        for s in row["steps"]:
            if s.get("npc"):
                out.setdefault(s["npc"], []).append(s["n"])
        return out
    b, a = rungs(before_row), rungs(after_row)
    changed = ["%s %s -> %s" % (k, b[k], a[k])
               for k in sorted(set(b) & set(a)) if b[k] != a[k]]
    if not changed:
        return []
    return [Problem("note", "ladder",
                    "the same marker(s) now sit on different rungs: %s"
                    % "; ".join(changed))]
