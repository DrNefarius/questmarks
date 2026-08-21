"""Tests for the questgraph editor.

    python tools/questgraph/test_questgraph.py

The write path is the risky part of this tool, so it is the part that is
tested hardest. Every write test runs against a THROWAWAY copy of the tree,
never the real build/authored/. A test that exercised the real directory would
be a test that could destroy the thing it tests.

Name resolution still runs against the real res/ tables through the real
validate.py, which is the point: the gates under test are the shipped ones.

Build-time only.
"""

import copy
import io
import json
import os
import shutil
import sys
import tempfile

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

import corpus as C
import edits
import gates
import graph as G
import playlog
import triage

PASS = [0]
FAIL = []


#[[ Collects rather than raises, so one bad check does not hide the twenty
#   after it. Run this file directly and you get the whole picture at once.
#
#   Under pytest it DOES raise, and that is not a style choice. Collecting
#   silently means every `def test_` returns normally whatever it found, so
#   pytest counts the run green while a check inside it is failing. A green
#   run that is not green is worse than no run. ]]
def check(name, ok, detail=""):
    if ok:
        PASS[0] += 1
        print("  PASS  %-58s %s" % (name, detail))
        return
    FAIL.append(name)
    print("  FAIL  %-58s %s" % (name, detail))
    if "pytest" in sys.modules:
        raise AssertionError("%s   %s" % (name, detail))


def section(t):
    print("\n=== %s ===" % t)


# ---------------------------------------------------------------- fixtures

def a_quest(qid=("quest", "bastok", 65)):
    cat, area, num = qid
    return {
        "schema": "questmarks-authoring/1",
        "source": {"wiki_title": "Test Quest", "page_id": 1,
                   "revision_id": 2, "source_sha256": "deadbeef",
                   "cache_file": "0000001_test_quest"},
        "identity": {"cat": cat, "area": area, "id": num,
                     "dat_name": "Test Quest", "match_rule": "exact_verbatim",
                     "match_conf": "high"},
        "extraction": {"reader": "automated", "reader_version": "extract/2",
                       "extracted_at": "2026-08-04",
                       "verify": {"verdict": "pass", "changes": 0}},
        "confidence": "high",
        "review_flags": [],
        "notes": "a fixture",
        "gates": {"fame": None, "prev": [], "level": None, "jobs": [],
                  "repeatable": False, "expansion": None},
        "start": {"npc": "Raifa", "zone": "Port Bastok", "grid": "D-6",
                  "raw": "Raifa - Port Bastok (D-6)"},
        #[[ Three steps with a DISTINCT middle target, deliberately.
        #
        #   Do not put Raifa on the middle step. Consecutive steps on the same
        #   NPC in the same zone are ONE marker position, so the set would
        #   never have two entries to lose and every marker-delta assertion
        #   below would pass vacuously. ]]
        "steps": [step(1, "talk", "Raifa", "Port Bastok"),
                  step(2, "talk", "Degga", "Gusgen Mines"),
                  step(3, "turnin", "Raifa", "Port Bastok")],
    }


def step(n, kind, target, zone, **kw):
    s = {"n": n, "kind": kind,
         "target": {"type": "npc" if target else "none", "name": target},
         "zone": zone, "grid": None, "items": [], "items_alt": [],
         "items_partial": False, "evidence": None, "mobs": [], "group": None,
         "optional": False, "confidence": "high", "note": None,
         "source_bullets": [n]}
    s.update(kw)
    return s


def make_tree():
    """A throwaway corpus root holding exactly one authored file."""
    root = tempfile.mkdtemp(prefix="qg-test-")
    for d in (("build", "authored"), ("build", "validated"),
              ("build", "reports"), ("build", "rendered"), ("data",)):
        os.makedirs(os.path.join(root, *d))
    with io.open(os.path.join(root, "build", "authored", "_t.json"), "w",
                 encoding="utf-8", newline="") as f:
        f.write(json.dumps([a_quest()], ensure_ascii=False, indent=1))
    with io.open(os.path.join(root, "build", "validated", "quests.json"), "w",
                 encoding="utf-8", newline="") as f:
        f.write("[]")
    return root


def load(root):
    return C.Corpus(root=root, want_index=False)


def mk(c, record, basis="reading", reason="a good enough reason to test with",
       **kw):
    return edits.Edit(c, "quest/bastok/65", record, basis, reason, "tester",
                      **kw)


def errors_of(problems):
    return [p for p in problems if p.level == "error"]


# ------------------------------------------------------------------- tests

def test_roundtrip_real_corpus():
    section("the real corpus round-trips byte-identically")
    c = C.Corpus(want_index=False)
    bad = [n for n, f in c.files.items() if not f.round_trips()]
    check("every authored file re-serialises to the exact bytes on disk",
          not bad, "%d files, %d differ" % (len(c.files), len(bad)))
    check("no authored file failed to parse", not c.errors, str(c.errors)[:80])
    check("no quest id appears in two places", not c.dupes,
          "%d duplicates" % len(c.dupes))
    #[[ No return value. Nothing consumes one, and pytest treats a test that
    #   returns non-None as a mistake: it warns today and is scheduled to
    #   fail. Build the corpus you need inside your own test, as the other
    #   tests here do. ]]


def test_schema():
    section("schema -- every key is required, and null is an answer")
    q = a_quest()
    check("a clean fixture has no schema errors",
          not errors_of(gates.schema_check(q)))

    bad = copy.deepcopy(q); del bad["notes"]
    check("a missing quest key is an error", errors_of(gates.schema_check(bad)))

    bad = copy.deepcopy(q); del bad["steps"][0]["source_bullets"]
    check("a missing step key is an error", errors_of(gates.schema_check(bad)))

    bad = copy.deepcopy(q); bad["steps"][0]["kind"] = "speak"
    check("kind must be one of the closed set in corpus.KINDS",
          any("kind" in p.where for p in errors_of(gates.schema_check(bad))))

    bad = copy.deepcopy(q); bad["steps"][1]["n"] = 3
    check("n must be dense 1..N in array order",
          any(".n" in p.where for p in errors_of(gates.schema_check(bad))))

    bad = copy.deepcopy(q); bad["steps"][0]["evidence"] = {"all": [], "alt": []}
    check("{'all': []} with no alt is illegal -- vacuously true",
          any("evidence" in p.where for p in errors_of(gates.schema_check(bad))))

    bad = copy.deepcopy(q); bad["gates"]["jobs"] = "PLD"
    check("gates.jobs must stay a LIST (Old Wounds gates on seven)",
          any("jobs" in p.where for p in errors_of(gates.schema_check(bad))))

    bad = copy.deepcopy(q)
    bad["steps"][0]["target"] = {"type": "npc", "name": None}
    check("an npc target with no name is an error",
          any("target.name" in p.where for p in errors_of(gates.schema_check(bad))))

    #[[ The craft gate. Optional, so its ABSENCE must stay clean: 1002 of the
    #   1003 records have no craft key at all and would fail every build if a
    #   missing optional key were an error. ]]
    ok = copy.deepcopy(q); ok["gates"]["craft"] = [
        {"skill": "Fishing", "rank": "Adept", "level": None, "raw": "..."}]
    check("a well-formed craft gate is clean",
          not errors_of(gates.schema_check(ok)))
    check("...and so is having no craft gate at all",
          "craft" not in q["gates"]
          and not errors_of(gates.schema_check(q)))

    bad = copy.deepcopy(ok); bad["gates"]["craft"] = {"skill": "Fishing"}
    check("gates.craft must be a LIST, like jobs",
          any("craft" in p.where for p in errors_of(gates.schema_check(bad))))

    #[[ Neither a rank nor a level means validate.py drops it. Refused HERE so
    #   the gate cannot disappear silently between the editor and the build. ]]
    bad = copy.deepcopy(ok)
    bad["gates"]["craft"] = [{"skill": "Fishing", "rank": None, "level": None}]
    check("a craft gate with neither rank nor level is refused, not dropped",
          any("craft" in p.where for p in errors_of(gates.schema_check(bad))))

    bad = copy.deepcopy(ok)
    bad["gates"]["craft"] = [{"rank": "Adept", "level": None}]
    check("...and one naming no skill is refused too",
          any("skill" in p.where for p in errors_of(gates.schema_check(bad))))


def test_identity_is_provenance():
    section("provenance may not be edited")
    q = a_quest()
    for block, key, val in (("identity", "id", 66),
                            ("identity", "cat", "mission"),
                            ("source", "revision_id", 999),
                            ("source", "source_sha256", "cafe")):
        bad = copy.deepcopy(q); bad[block][key] = val
        check("%s.%s is refused" % (block, key),
              errors_of(gates.identity_check(q, bad)))

    bad = copy.deepcopy(q); bad["extraction"]["model"] = "a person's name"
    errs = errors_of(gates.identity_check(q, bad))
    check("the extraction block may not become the human marker", errs,
          errs[0].text[:56] if errs else "")

    bad = copy.deepcopy(q); bad["extraction"]["verify"] = None
    check("the stage-D verify verdict cannot be wiped",
          errors_of(gates.identity_check(q, bad)))


def test_hard_gates_are_the_real_ones():
    section("hard gates -- validate.py itself, not a copy")
    check("gates.FATAL IS validate.py's FATAL",
          gates.FATAL is gates._validate.FATAL,
          "identity, so it cannot drift")

    q = a_quest()
    q["steps"][0]["evidence"] = {"all": [{"kind": "ki", "name": "Indigested ore",
                                          "count": 1}], "alt": []}
    q["steps"][1]["evidence"] = {"all": [{"kind": "ki", "name": "Indigested ore",
                                          "count": 1}], "alt": []}
    problems, row, _q = gates.gate_check(q)
    #[[ Anchored to the STEP, not to a "gate:" bucket. A problem in a list at
    #   the bottom of the page is a problem about the page; the same problem
    #   on step 2 is a problem about step 2, and only the second is
    #   actionable. ]]
    dup = [p for p in problems if p.level == "error"
           and "jumps the high-water mark" in p.text]
    check("the same evidence on two steps trips the duplicate gate", dup,
          "the mark would jump to the later step")
    check("...and the problem is anchored to the step it is about",
          dup and dup[0].where.startswith("steps["), dup and dup[0].where)
    check("...and validate.py's false 'quest demoted' line is not repeated",
          not any("quest demoted" in p.text for p in problems),
          "conf is read by no runtime code")
    #[[ NOT "demoted to start-NPC only". validate.py's validate() only sets
    #   conf = low, and `conf` is read by no runtime code. The quest still
    #   ships with every step. Asserting the real effect. ]]
    check("... and validate.py drops conf to low (a LABEL, nothing reads it)",
          row and row["conf"] == 1, "conf=%s" % (row and row["conf"]))
    check("... and the editor reports what the flag actually costs",
          any("still emit" in p.text for p in problems),
          "the real hazard, not a false penalty")

    ok = a_quest()
    _p, row, _ = gates.gate_check(ok)
    check("a clean quest keeps its tier", row and row["conf"] == 3,
          "conf=%s" % (row and row["conf"]))
    check("... and resolves its start NPC", row and row["start_npc"] == "raifa",
          str(row and row["start_npc"]))


def test_marker_invariant():
    section("invariant 1 -- bad data may MOVE a marker, never DELETE one")
    before, _q = gates.run_validate(a_quest())
    check("the fixture really has two distinct NPC positions to lose",
          len([1 for k, _n, _z in gates.marker_positions(before)
               if k == "npc"]) == 2,
          "otherwise every assertion below passes vacuously")

    gone = a_quest()
    gone["steps"][1]["target"] = {"type": "none", "name": None}
    after, _q = gates.run_validate(gone)
    problems, removed, added = gates.marker_delta(before, after)
    check("removing a target is reported as a removed marker position",
          any(p.where == "markers" and p.level == "warn" for p in problems),
          "%d removed" % len(removed))

    moved = a_quest()
    moved["steps"][1]["target"] = {"type": "npc", "name": "Amaura"}
    moved["steps"][1]["zone"] = "Southern San d'Oria"
    after2, _q = gates.run_validate(moved)
    problems2, removed2, added2 = gates.marker_delta(before, after2)
    check("a MOVE is reported as both a removal and an addition",
          removed2 and added2, "%d out, %d in" % (len(removed2), len(added2)))

    same = a_quest()
    same["steps"][1]["target"] = {"type": "npc", "name": "Raifa"}
    same["steps"][1]["zone"] = "Port Bastok"
    after_same, _q = gates.run_validate(same)
    _p, removed_same, _a = gates.marker_delta(before, after_same)
    check("collapsing a step onto the SAME npc+zone removes that position",
          len(removed_same) == 1,
          "consecutive steps on one NPC are one marker")

    mob = a_quest()
    mob["steps"][1]["target"] = {"type": "none", "name": None}
    mob["steps"][1]["kind"] = "fight"
    mob["steps"][1]["mobs"] = [{"name": "Pudding", "count": None, "role": "kill"}]
    after3, _q = gates.run_validate(mob)
    check("a mob-only step still counts as a marker position",
          any(k == "mob" for k, _n, _z in gates.marker_positions(after3)),
          "markable() accepts monsters, not just NPCs")


def test_write_path():
    section("the write path")
    root = make_tree()
    edits.BACKUPS = os.path.join(root, "backups")
    edits.LEDGER = os.path.join(root, "edits.jsonl")
    try:
        c = load(root)
        path = os.path.join(root, "build", "authored", "_t.json")
        before_bytes = io.open(path, encoding="utf-8", newline="").read()

        # -- refuses an edit with no reason ---------------------------------
        rec = copy.deepcopy(c.by_qid["quest/bastok/65"])
        rec["notes"] = "corrected"
        e = mk(c, rec, reason="")
        check("an edit with no reason is refused",
              any(p.where == "human.reason" for p in errors_of(e.check()[0])))

        # -- preview does not touch disk ------------------------------------
        e = mk(c, rec)
        pv = e.preview()
        check("preview writes nothing",
              io.open(path, encoding="utf-8", newline="").read() == before_bytes)
        check("preview names the changed field AND the flag it adds itself",
              pv["fields"] == ["notes", "review_flags[1]"], str(pv["fields"]))
        check("preview produces a diff", "+" in pv["diff"] and "notes" in pv["diff"])
        #[[ The property that matters is not "few lines" (the human block is a
        #   legitimate ten of them) but that nothing unrelated moved. A writer
        #   that reformatted would touch every step; this asserts that no
        #   changed line mentions one. ]]
        touched = [l for l in pv["diff"].splitlines()
                   if l[:1] in "+-" and not l.startswith(("+++", "---"))]
        stray = [l for l in touched
                 if l[1:].strip(' \t[]{},')                 # pure structure
                 and not any(k in l for k in
                             ('"notes"', '"human"', '"review_flags"',
                              '"edited_at"', '"by"', '"basis"', '"reason"',
                              '"fields"', '"history"', '"source_at_edit"',
                              '"revision_id"', '"source_sha256"',
                              'human_corrected', 'review_flags['))]
        check("a one-field edit touches nothing unrelated", not stray,
              "%d changed lines, %d stray: %s"
              % (len(touched), len(stray), (stray[:1] or [""])[0][:40]))

        # -- commit ---------------------------------------------------------
        entry = mk(c, rec).commit()
        after = json.loads(io.open(path, encoding="utf-8").read())
        check("the record is written", after[0]["notes"] == "corrected")
        check("a human block is attached", "human" in after[0])
        check("... naming the basis", after[0]["human"]["basis"] == "reading")
        check("... and pinning the revision it was made against",
              after[0]["human"]["source_at_edit"]["revision_id"] == 2)
        check("the extraction block is untouched",
              after[0]["extraction"]["verify"] == {"verdict": "pass", "changes": 0})
        check("review_flags gains human_corrected",
              "human_corrected" in after[0]["review_flags"])
        check("a backup was taken first", os.path.exists(
            os.path.join(root, entry["backup"].replace("build/authored", "")
                         .replace("/", os.sep).lstrip(os.sep))
            ) or os.path.exists(os.path.join(root, "backups")))
        check("the ledger records it", os.path.exists(edits.LEDGER))
        check("the file still round-trips", C.AuthoredFile(path).round_trips())

        # -- basis: game also sets verified_in_game -------------------------
        c2 = load(root)
        rec2 = copy.deepcopy(c2.by_qid["quest/bastok/65"])
        rec2["notes"] = "the page is wrong; play says otherwise"
        mk(c2, rec2, basis="game",
           reason="confirmed in game, the page does not say this").commit()
        after2 = json.loads(io.open(path, encoding="utf-8").read())
        check("basis=game sets verified_in_game",
              "verified_in_game" in after2[0]["review_flags"],
              "the flag already means: treat it as ground truth")
        check("the previous correction is kept in history",
              len(after2[0]["human"]["history"]) == 1)

        # -- revert ---------------------------------------------------------
        #[[ ledger() is newest-first, so rows[0] is the second edit and
        #   rows[-1] the first. Reverting the LATEST is safe; reverting an
        #   older one would also un-do everything written since, and an
        #   authored file holds 2-10 quests. ]]
        rows = [r for r in edits.ledger() if not r.get("reverted")]
        try:
            edits.revert(rows[-1])
            check("reverting a superseded edit is refused", False)
        except edits.Refused as r:
            check("reverting a superseded edit is refused",
                  "written since" in str(r),
                  "it would silently un-do the later ones too")

        edits.revert(rows[0])                  # the most recent edit
        restored = json.loads(io.open(path, encoding="utf-8").read())
        check("reverting the latest edit puts the previous file back",
              restored[0]["notes"] == "corrected"
              and "verified_in_game" not in restored[0]["review_flags"])

        check("...and forcing past the guard reaches the original",
              edits.revert(rows[-1], force=True) and
              json.loads(io.open(path, encoding="utf-8").read())[0]["notes"]
              == "a fixture")

        # -- concurrency ----------------------------------------------------
        c3 = load(root)
        rec3 = copy.deepcopy(c3.by_qid["quest/bastok/65"])
        rec3["notes"] = "third"
        with io.open(path, "a", encoding="utf-8", newline="") as f:
            f.write(" ")                       # something else writes
        try:
            mk(c3, rec3).commit()
            check("a file changed on disk is refused", False)
        except edits.Refused as r:
            check("a file changed on disk is refused", "changed on disk" in str(r))
    finally:
        shutil.rmtree(root, ignore_errors=True)
        edits.BACKUPS = os.path.join(HERE, "backups")
        edits.LEDGER = os.path.join(HERE, "edits.jsonl")


def test_diff_on_a_real_file():
    section("a real file -- preview only, nothing is written")
    c = C.Corpus(want_index=False)
    #[[ The biggest file in the corpus, so "the diff is small" means something.
    #   Never committed: this is the live corpus and the pipeline's own agents
    #   are writing to it. ]]
    fname = max(c.files, key=lambda n: len(c.files[n].raw))
    af = c.files[fname]
    qid = next(q for q, (f, _i) in c.loc.items() if f == fname)
    before = af.raw
    rec = copy.deepcopy(c.by_qid[qid])
    rec["notes"] = (rec.get("notes") or "") + " [test]"
    e = edits.Edit(c, qid, rec, "reading",
                   "checking that a diff stays readable", "tester")
    pv = e.preview()
    lines = len(pv["diff"].splitlines())
    check("one note changed in a %d-line file gives a %d-line diff"
          % (len(before.splitlines()), lines),
          lines < 40, "%s" % fname)
    check("the file on disk is untouched",
          io.open(af.path, encoding="utf-8", newline="").read() == before)


def test_never_writes_generated():
    section("never write a generated file")
    for rel in ("data/quest_index.lua", "data/quest_steps.lua",
                "data/mission_index.lua", "build/validated/quests.json"):
        check("%s is refused" % rel,
              C.is_generated(os.path.join(C.ADDON, rel)))
    for rel in ("build/authored/_batch1.json", "data/npc_overrides.lua"):
        check("%s is editable" % rel,
              not C.is_generated(os.path.join(C.ADDON, rel)))


def test_graph():
    section("the prev DAG")
    idx = {"quests": [
        {"cat": "quest", "area": "a", "id": 1, "prev": []},
        {"cat": "quest", "area": "a", "id": 2,
         "prev": [{"cat": "quest", "area": "a", "id": 1}]},
        {"cat": "quest", "area": "a", "id": 3,
         "prev": [{"cat": "quest", "area": "a", "id": 2}]},
    ], "missions": []}
    g = G.Graph(idx)
    check("a clean chain has no cycles", not g.cycles())
    check("depth is the longest chain", g.depths()["quest/a/3"] == 2)

    idx["quests"][0]["prev"] = [{"cat": "quest", "area": "a", "id": 3}]
    g = G.Graph(idx)
    cy = g.cycles()
    check("a 3-cycle is found", len(cy) == 1 and len(cy[0]) == 3, str(cy))
    check("everything in it is unreachable", len(g.unreachable()) == 3)

    idx2 = {"quests": [{"cat": "quest", "area": "a", "id": 1,
                        "prev": [{"cat": "quest", "area": "a", "id": 9}]}],
            "missions": []}
    g2 = G.Graph(idx2)
    check("a prev outside the index is NOT called unreachable",
          not g2.unreachable(),
          "prereq reads the game's bitfield, not the index")
    check("... it is reported as out-of-index instead",
          len(g2.out_of_index()["not_indexed"]) == 1)

    real = C.Corpus(want_index=True)
    if real.index:
        gr = G.Graph(real.index)
        check("the shipped graph is acyclic", not gr.cycles(),
              "%d nodes, %d edges" % (len(gr.nodes),
                                      sum(len(v) for v in gr.prev.values())))


def test_playlog():
    section("//qm why and questmarks.log")
    block = (
        "2026-08-04 13:00:51| Zalsuhm -- 20 indexed entries\n"
        "2026-08-04 13:00:51|    [quest/jeuno #111] Unlocking a Myth (Bard)\n"
        "2026-08-04 13:00:51|      state: available   marker: grey ! blocked\n"
        "2026-08-04 13:00:51|      x BRD only, you are RDM\n"
        "2026-08-04 13:00:51|      ladder: step 1 of 3 (not_started)\n"
        "2026-08-04 13:00:51|       >*  1 talk     zalsuhm, Lower Jeuno (H-9)\n"
        "2026-08-04 13:00:51|           2 fight    (nothing to mark)\n")
    p = playlog.parse(block)
    check("the entry is identified", p["entries"] == ["quest/jeuno/111"],
          str(p["entries"]))
    b = p["blocks"][0]
    check("the NPC that was asked about is carried", b["npc"] == "Zalsuhm")
    check("state and marker are read", b["state"] == "available")
    check("the ladder position is read", b["step"]["idx"] == 1 and b["step"]["n"] == 3)
    check("the marked step is identified",
          b["ladder"][0]["current"] and b["ladder"][0]["marker"])
    check("a failed reason is read as false",
          b["reasons"] and b["reasons"][0]["ok"] is False)

    check("the OLD boot line parses (no version stamp)",
          playlog.parse("2026-08-04 14:20:34| loaded 1504 entries over 1946 "
                        "NPCs at 2.00 marker height. //qm for help."
                        )["boots"][0]["stamped"] is False)
    nb = playlog.parse("questmarks: v0.2 loaded 1504 entries over 1950 NPCs "
                       "(995 step ladders) at 2.30 marker height.")["boots"]
    check("the NEW boot line parses, with version and ladders",
          nb and nb[0]["version"] == "0.2" and nb[0]["ladders"] == "995",
          str(nb[0] if nb else None))


def test_triage_excludes_by_design():
    section("triage -- a bucket of intended outcomes is not a signal")
    c = C.Corpus(want_index=True)
    t = triage.build(c, G.Graph(c.index))
    keys = [b["key"] for b in t["buckets"]]
    check("placeholder_target is NOT a bucket",
          not any("placeholder" in k for k in keys))
    check("... it is reported as by-design instead",
          t["placeholder_note"]["count"] > 300,
          "%d rows" % t["placeholder_note"]["count"])
    check("real quarantine reasons ARE buckets",
          any(k.startswith("quarantine:item_unresolved") for k in keys))
    check("buckets are ordered broken-first",
          keys[0].startswith("quarantine:"), keys[0])
    check("human-corrected records get their own bucket",
          any(k == "human" for k in keys))


def test_reachability():
    section("evidence must be obtained AT its own step")
    q = a_quest()
    #[[ The failure this catches looks like a fix. "The marker sits on step 2
    #   forever" -> move the key item down to a later step's evidence -> the
    #   mark leaps past every step between, permanently, for every player. ]]
    q["steps"][0]["items"] = [{"kind": "ki", "name": "Indigested ore", "count": 1}]
    q["steps"][2]["evidence"] = {"all": [{"kind": "ki", "name": "Indigested ore",
                                          "count": 1}], "alt": []}
    row, _qn = gates.run_validate(q)
    probs = gates.reachability_check(row)
    check("evidence for a step you already hold at an earlier one is an error",
          probs and probs[0].level == "error",
          probs[0].text[:60] if probs else "nothing reported")
    check("the duplicate-evidence gate does NOT catch this",
          not any("evidence_duplicate" in f for f in row["flags"]),
          "the id appears exactly once, so the existing gate is blind to it")

    ok, _qn = gates.run_validate(a_quest())
    check("a clean ladder reports nothing", not gates.reachability_check(ok))

    real = C.Corpus(want_index=False)
    hits = 0
    import json as _json
    vp = os.path.join(C.ADDON, "build", "validated", "quests.json")
    if os.path.exists(vp):
        with io.open(vp, encoding="utf-8") as f:
            for v in _json.load(f):
                if gates.reachability_check(v):
                    hits += 1
    check("no shipped quest trips it, so it is safe as an error",
          hits == 0, "%d of the shipped corpus" % hits)


def test_enforce_verify_protects_humans():
    section("enforce_verify.py may not revert a human correction")
    sys.path.insert(0, os.path.join(C.ADDON, "tools", "pipeline"))
    import enforce_verify as EV

    draft = a_quest()
    #[[ A basis="game" correction is by construction a strengthening: it
    #   renames the target the page got wrong, adds the evidence the page
    #   omitted. Every one of those is on violations()' forbidden list, so
    #   without the guard the enforcer deletes exactly the most trustworthy
    #   records in the corpus and calls it "REVERTED to the draft". ]]
    corrected = copy.deepcopy(draft)
    corrected["steps"][1]["target"] = {"type": "npc", "name": "Hagain"}
    corrected["steps"][1]["kind"] = "trade"
    corrected["human"] = {"basis": "game", "reason": "seen in play",
                          "by": "tester"}
    corrected["review_flags"] = ["human_corrected", "verified_in_game"]

    bad = EV.violations(draft, corrected)
    check("the correction IS a violation by the verifier's rules", bad, str(bad))
    check("...so without the guard it would be reverted wholesale", bool(bad))
    check("human_marked() sees the `human` block", EV.human_marked(corrected))
    check("human_marked() also sees the older verified_in_game flag",
          EV.human_marked({"review_flags": ["verified_in_game"]}))
    check("an ordinary verified record is not protected",
          not EV.human_marked(draft))

    #[[ Absent and unparseable must stay different answers: the recovery for
    #   "absent" overwrites the file. ]]
    root = tempfile.mkdtemp(prefix="qg-ev-")
    try:
        p = os.path.join(root, "broken.json")
        with io.open(p, "w", encoding="utf-8") as f:
            f.write("{not json")
        check("a missing file reads as None",
              EV.load(os.path.join(root, "nope.json")) is None)
        try:
            EV.load(p)
            check("an unparseable file raises instead of reading as missing",
                  False)
        except EV.Unreadable:
            check("an unparseable file raises instead of reading as missing",
                  True, "so the draft is never promoted over real data")
    finally:
        shutil.rmtree(root, ignore_errors=True)


def test_resolver_pins():
    section("resolver pins -- the third place a correction can live")
    V = gates._validate
    check("validate.py reads the pin file", hasattr(V, "PINS"))
    check("it is EMPTY by default, so the build is unchanged",
          len(V.PINS) == 0, "%d pins" % len(V.PINS))
    check("_README and _candidates are documentation, not pins",
          not any(k[0].startswith("_") for k in V.PINS))

    #[[ The pin has to reach the resolver, not merely load. Injected around one
    #   call so the real corpus is never validated with it in place. ]]
    saved = dict(V.PINS)
    try:
        V.PINS[("item", "Definitely Not A Real Item")] = {
            "id": 4242, "why": "a test"}
        q = a_quest()
        q["steps"][1]["items"] = [{"kind": "item",
                                   "name": "Definitely Not A Real Item",
                                   "count": 1}]
        row, quarantine = gates.run_validate(q)
        reqs = row["steps"][1].get("reqs") or []
        check("a pinned name resolves to the pinned id",
              reqs and reqs[0]["rid"] == 4242, str(reqs))
        check("...and so is NOT quarantined as unresolved",
              not any(r["reason"] == "item_unresolved" for r in quarantine))
    finally:
        V.PINS.clear()
        V.PINS.update(saved)

    unpinned, quarantine = gates.run_validate(
        dict(a_quest(), steps=[
            a_quest()["steps"][0],
            dict(a_quest()["steps"][1],
                 items=[{"kind": "item", "name": "Definitely Not A Real Item",
                         "count": 1}]),
            a_quest()["steps"][2]]))
    check("without the pin the same name is quarantined",
          any(r["reason"] == "item_unresolved" for r in quarantine))


def test_grounding_exempts_in_game_corrections():
    section("check_grounded.py accepts an in-game correction, and only that field")
    sys.path.insert(0, os.path.join(C.ADDON, "tools", "pipeline"))
    import check_grounded as G

    #[[ The rule a community correction depends on: "I checked in game" is the
    #   one claim the wiki page can never support, so the gate has to let it
    #   through. It must NOT let anything else through on the same record. ]]
    played = G.in_game_fields({"human": {
        "basis": "game", "fields": ["steps[3].grid", "steps[4].target.name",
                                    "steps[5].mobs[1].name"], "history": []}})
    check("a game-basis field is exempt", G.covered("steps[3].grid", played))
    check("target.name folds onto the gate's steps[N].target",
          G.covered("steps[4].target", played))
    check("mobs[i].name folds onto the gate's steps[N].mob",
          G.covered("steps[5].mob", played))
    check("a field the human did NOT name stays grounded",
          not G.covered("steps[3].zone", played))
    check("another step stays grounded", not G.covered("steps[9].grid", played))

    reading = G.in_game_fields({"human": {
        "basis": "reading", "fields": ["steps[3].grid"], "history": []}})
    check("basis 'reading' exempts nothing", not G.covered("steps[3].grid", reading))
    check("no human block exempts nothing", not G.in_game_fields({}))

    hist = G.in_game_fields({"human": {
        "basis": "reading", "fields": ["notes"],
        "history": [{"basis": "game", "fields": ["steps[2].grid"]}]}})
    check("an earlier in-game correction still counts",
          G.covered("steps[2].grid", hist))

    whole = G.in_game_fields({"human": {
        "basis": "game", "fields": ["steps[7]"], "history": []}})
    check("a whole-step change covers that step's values",
          G.covered("steps[7].grid", whole) and not G.covered("steps[8].grid", whole))


def test_worklist_guard():
    section("worklist.py refuses to re-read a human-corrected quest")
    sys.path.insert(0, os.path.join(C.ADDON, "tools", "pipeline"))
    import worklist

    root = tempfile.mkdtemp(prefix="qg-wl-")
    old = (worklist.AUTHORED, worklist.RENDERED, worklist.PLAN)
    try:
        auth = os.path.join(root, "authored")
        rend = os.path.join(root, "rendered")
        os.makedirs(auth); os.makedirs(rend)
        worklist.AUTHORED, worklist.RENDERED = auth, rend
        worklist.PLAN = os.path.join(root, "worklist.json")

        corrected = a_quest()
        corrected["source"]["cache_file"] = "0000001_corrected"
        corrected["human"] = {"basis": "game", "reason": "seen in play",
                              "by": "tester"}
        plain = a_quest(("quest", "bastok", 66))
        plain["source"] = dict(plain["source"], cache_file="0000002_plain")
        old_flag = a_quest(("quest", "bastok", 67))
        old_flag["source"] = dict(old_flag["source"], cache_file="0000003_oldflag")
        old_flag["review_flags"] = ["verified_in_game"]

        with io.open(os.path.join(auth, "_a.json"), "w", encoding="utf-8",
                     newline="") as f:
            json.dump([corrected, old_flag], f, ensure_ascii=False, indent=1)
        for cf in ("0000001_corrected", "0000002_plain", "0000003_oldflag"):
            with io.open(os.path.join(rend, cf + "_0123456789.md"), "w",
                         encoding="utf-8", newline="") as f:
                f.write("# page\n")

        prot = worklist.protected_cache_files()
        check("a `human` block protects a quest", "0000001_corrected" in prot)
        check("the older `verified_in_game` flag protects one too",
              "0000003_oldflag" in prot,
              "records that predate the editor are covered")
        check("an ordinary record is not protected", "0000002_plain" not in prot)

        worklist.snapshot()
        with io.open(worklist.PLAN, encoding="utf-8") as f:
            plan = json.load(f)
        scheduled = [p for b in plan["batches"] for p in b["pages"]]
        check("the unauthored page IS scheduled",
              any("0000002_plain" in p for p in scheduled), str(scheduled))
        check("no protected page is scheduled",
              not any("corrected" in p or "oldflag" in p for p in scheduled))
        check("the plan records what it refused",
              len(plan.get("protected") or []) == 2)

        #[[ The guard that cannot go stale: a hand-written plan naming a
        #   protected page must still be refused when the batch is handed out. ]]
        with io.open(worklist.PLAN, "w", encoding="utf-8", newline="") as f:
            json.dump({"batches": [{"batch": 0,
                                    "pages": ["0000001_corrected_0123456789"],
                                    "chars": 1}]}, f)
        argv = sys.argv
        try:
            sys.argv = ["worklist.py", "--batch", "0"]
            worklist.main()
            check("a stale plan naming a protected page is refused", False)
        except SystemExit as e:
            check("a stale plan naming a protected page is refused",
                  "REFUSED" in str(e), str(e).splitlines()[0][:52])
        finally:
            sys.argv = argv
    finally:
        worklist.AUTHORED, worklist.RENDERED, worklist.PLAN = old
        shutil.rmtree(root, ignore_errors=True)


def main():
    print("=== questgraph ===")
    test_roundtrip_real_corpus()
    test_schema()
    test_identity_is_provenance()
    test_hard_gates_are_the_real_ones()
    test_marker_invariant()
    test_write_path()
    test_diff_on_a_real_file()
    test_never_writes_generated()
    test_graph()
    test_playlog()
    test_triage_excludes_by_design()
    test_reachability()
    test_enforce_verify_protects_humans()
    test_resolver_pins()
    test_grounding_exempts_in_game_corrections()
    test_worklist_guard()
    print("\n%d passed, %d failed" % (PASS[0], len(FAIL)))
    for f in FAIL:
        print("   FAILED: %s" % f)
    return 1 if FAIL else 0


if __name__ == "__main__":
    sys.exit(main())
