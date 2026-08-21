"""Stage E: validated quests -> data/quest_steps.lua.

    python tools/pipeline/emit_lua.py

Writes a plain Lua table keyed 'cat/area/id'. tools/build_index.lua dofiles it
and merges it onto the DAT id list: a row with a ladder here gets it, and a row
with none falls back to a synthetic single step at its giver. As of the last
measurement no shipped row takes that fallback.

Why a separate file rather than emitting quest_index.lua straight from here:
build_index.lua stays the ONE emitter, so //qm rebuild keeps working in game
and there is never a JSON parser inside the addon. It also means the reading
can land quest by quest, without the index ever being half-built.

Deterministic output: keys sorted, no timestamp in the body, \\n endings, so a
diff between runs shows data changes and nothing else.

Build-time only.
"""

import argparse
import io
import subprocess
import sys
import json
import os

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, "..", ".."))
BUILD = os.path.join(ADDON, "build")

TIER = {3: "full", 2: "assisted", 1: "start"}


def lua_str(s):
    s = str(s).replace("\\", "\\\\").replace("'", "\\'")
    s = s.replace("\n", "\\n").replace("\r", "\\r")
    return "'" + s + "'"


def lua_val(v):
    if v is None:
        return "nil"
    if v is True:
        return "true"
    if v is False:
        return "false"
    if isinstance(v, (int, float)):
        return "%d" % v if float(v).is_integer() else str(v)
    return lua_str(v)


#[[ Quests whose item requirement means EQUIPPED, not merely carried.
#
#   The twenty `Unlocking a Myth` pages say "a Vigil Weapon equipped" and
#   nothing else: no weapon name, no alternative wording. Every note in the
#   authored data records the caveat that the addon can only see that you
#   HOLD one. `windower.ffxi.get_items()` carries a per-slot Status byte, and
#   fields.lua enumerates 0x05 as 'Equipped', so the caveat is closeable.
#
#   Keyed on the `vigil_weapon_pinned` flag that the resolver already wrote,
#   NOT on the word "equipped" appearing in the prose. Scanning notes for a verb
#   is precisely the pattern-matching this pipeline exists to avoid, and the
#   flag is a recorded fact about what was done to those twenty quests. Exactly
#   20 quests carry it, with exactly 20 requirements between them, all on
#   step 1. Assert that rather than trusting it. ]]
EQUIP_FLAG = "vigil_weapon_pinned"


def emit_step(s, equip=False):
    p = ["k=" + lua_str(s["k"])]
    if s.get("npc"):
        p.append("npc=" + lua_str(s["npc"]))
    if s.get("z") is not None:
        p.append("z=" + lua_val(s["z"]))
    if s.get("g"):
        p.append("g=" + lua_str(s["g"]))
    if s.get("group"):
        p.append("grp=" + lua_str(s["group"]))
    if s.get("optional"):
        p.append("optional=true")
    if s.get("items_partial"):
        p.append("reqs_partial=true")
    if s.get("reqs"):
        p.append("reqs={" + ",".join(
            "{kind=%s,rid=%d,n=%d%s}" % (
                lua_str(r["kind"]), r["rid"], r["n"],
                ",eq=true" if (equip and r["kind"] == "item") else "")
            for r in s["reqs"]) + "}")
    #[[ `reqs_alt` / `ev_alt`: a SECOND way to satisfy the step, not an extra
    #   condition (four Gobbiebag items OR one Goblin Stew). See
    #   core/inventory.lua's `meets`. ]]
    if s.get("reqs_alt"):
        p.append("reqs_alt={" + ",".join(
            "{kind=%s,rid=%d,n=%d}" % (lua_str(r["kind"]), r["rid"], r["n"])
            for r in s["reqs_alt"]) + "}")
    if s.get("ev_alt"):
        p.append("ev_alt={" + ",".join(
            "{kind=%s,rid=%d,n=%d}" % (lua_str(r["kind"]), r["rid"], r["n"])
            for r in s["ev_alt"]) + "}")
    if s.get("ev"):
        p.append("ev={" + ",".join(
            "{kind=%s,rid=%d,n=%d}" % (lua_str(r["kind"]), r["rid"], r["n"])
            for r in s["ev"]) + "}")
    #[[ Monsters carry no resource id. They are matched live by name against
    #   get_mob_list, which returns every entity and not only NPCs. `role`
    #   decides the glyph: sword to kill it, bag because it drops what this
    #   step needs. ]]
    if s.get("mobs"):
        p.append("mobs={" + ",".join(
            "{name=%s,role=%s%s}" % (lua_str(m["name"]), lua_str(m["role"]),
                                     ",n=%d" % m["n"] if m.get("n") else "")
            for m in s["mobs"]) + "}")
    return "{" + ",".join(p) + "}"


#[[ The mission NUMBER -> mission NAME table, emitted as Lua for the builder.
#
#   Some pages write a prerequisite as "Promathia Mission 3-2" rather than as
#   the mission's name, and nothing in the install can resolve one: the wiki
#   numbering is NOT the DAT id (Zilart Mission 7 "The Chamber of Oracles" is
#   DAT id 14). So the mapping is wiki-derived reference data, and it lives with
#   its provenance in bgwiki-rest-cache/supplemental/mission_numbers.json.
#
#   Generated from that file rather than duplicated: one source of truth, one
#   generated artifact, exactly like every other Lua table in this build.
#
#   It has to reach the LUA side because resolve_prev_name in build_index.lua is
#   where prerequisite names are finally matched. De-number every copy of a
#   prerequisite or none: a row carrying a resolved entry and an unresolved twin
#   is pinned at nil forever, a black "!" that never clears. ]]
NUMBERS_SRC = os.path.join(ADDON, "bgwiki-rest-cache", "supplemental",
                           "mission_numbers.json")
NUMBERS_OUT = os.path.join(ADDON, "tools", "lib", "mission_numbers.lua")


def emit_mission_numbers():
    """-> (lines, entries) written, or (0, 0) if the source is absent."""
    if not os.path.exists(NUMBERS_SRC):
        return 0, 0
    with io.open(NUMBERS_SRC, encoding="utf-8") as f:
        d = json.load(f)
    aliases = d.get("aliases") or {}
    lines = d.get("lines") or {}
    out = [
        "-- questmarks mission number -> mission name -- GENERATED FILE.\n",
        "-- Regenerate: python tools/pipeline/emit_lua.py\n",
        "-- Source, with provenance and the fetch URLs:\n",
        "--   bgwiki-rest-cache/supplemental/mission_numbers.json\n",
        "--\n",
        "-- Read by tools/build_index.lua (resolve_prev_name) so that a\n",
        "-- prerequisite written as a NUMBER resolves like any other name.\n",
        "-- BUILD-TIME ONLY: nothing under tools/ ships.\n",
        "--\n",
        "-- Derived from BG Wiki (CC BY-NC-SA 3.0). See NOTICE.\n\n",
        "return {\n  aliases = {\n",
    ]
    for k in sorted(aliases):
        out.append("    [%s] = %s,\n" % (lua_str(k), lua_str(aliases[k])))
    out.append("  },\n  lines = {\n")
    n = 0
    for line in sorted(lines):
        out.append("    [%s] = {\n" % lua_str(line))
        for num in sorted(lines[line], key=lambda s: [int(x) for x in s.split("-")]):
            out.append("      [%s] = %s,\n"
                       % (lua_str(num), lua_str(lines[line][num])))
            n += 1
        out.append("    },\n")
    out.append("  },\n}\n")
    with io.open(NUMBERS_OUT, "w", encoding="utf-8", newline="\n") as f:
        f.write("".join(out))
    return len(out), n


def run_gates():
    """Refuse to emit if the authored corpus has a NEW provenance, grounding or
    voice problem.

    The gates run here because this is the last point a bad record can be
    stopped: after it the values are in data/quest_steps.lua and then the
    index, where nothing checks provenance again.

    NEW matters. The corpus already carries 26 provenance problems and 202
    ungrounded values, listed in tools/pipeline/baseline-*.txt; the voice
    baseline is empty, so any build term in a player-facing note fails the
    build outright. Failing on the known set means a gate nobody can
    switch on, ignoring them means a gate nobody reads, so the baseline prints
    every run and anything outside it fails. The counts drift; trust the files.

    check_voice.py is the only gate that reads notes; check_grounded skips them
    on purpose. Notes are player-facing: questmarks-ui draws `steps[].note`
    under its step, expanded by default.
    """
    ok = True
    for tool in ("check_authored.py", "check_grounded.py", "check_voice.py"):
        print("--- %s" % tool, flush=True)
        rc = subprocess.call([sys.executable, os.path.join(HERE, tool)])
        if rc != 0:
            ok = False
    if not ok:
        sys.exit("\nREFUSING TO EMIT: the authored corpus has a problem that is "
                 "not in the baseline.\nFix the record, or -- if it is genuinely "
                 "acceptable -- rerun the tool with --write-baseline and say why "
                 "in the commit.")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="src",
                    default=os.path.join(BUILD, "validated", "quests.json"))
    ap.add_argument("--out", dest="out",
                    default=os.path.join(ADDON, "data", "quest_steps.lua"))
    ap.add_argument("--no-gates", action="store_true",
                    help="skip the provenance and grounding gates. For "
                         "diagnosing an emit problem only -- never for a build "
                         "whose output is going to be shipped.")
    args = ap.parse_args()

    if not args.no_gates:
        run_gates()

    with io.open(args.src, encoding="utf-8") as f:
        quests = json.load(f)

    rows, tiers, n_steps, n_mob = [], {3: 0, 2: 0, 1: 0}, 0, 0
    skipped = []
    n_equip_q, n_equip_r = 0, 0
    n_sz, n_rep_u = 0, 0
    n_fame, n_fame_nolvl = 0, 0
    for q in sorted(quests, key=lambda x: (x["cat"], x["area"], x["id"])):
        key = "%s/%s/%d" % (q["cat"], q["area"], q["id"])

        #[[ A quest with NO steps is a legitimate reading, not a failure.
        #
        #   `Ad Infinitum` marks the end of the Voidwatch storyline, cannot be
        #   completed, and stays in the Current Quests menu forever; its single
        #   bullet is a statement ABOUT the quest rather than an instruction, so
        #   the correct ladder is empty. A verb-scanner would have manufactured
        #   a step here, which is the whole failure mode this pipeline exists to
        #   avoid. The reading stands and the EMITTER gives way.
        #
        #   Skipped rather than emitted empty. A record skipped here has no
        #   other source, so the quest simply does not appear. That is a loss,
        #   not a no-op, and it should read like one. It is still the right
        #   call: an empty ladder cannot carry a marker either.
        #   One record today: quest/crystal_war/98.
        #
        #   Never emit `steps={\n    ,\n  }`. One bare comma makes the whole
        #   file unparseable and every ladder in it fails to load. Guarded
        #   below as well. ]]
        if not q["steps"]:
            skipped.append(key)
            continue
        tiers[q["conf"]] += 1
        n_steps += len(q["steps"])
        n_mob += sum(len(s.get("mobs") or []) for s in q["steps"])

        p = ["conf=%d" % q["conf"]]
        if q.get("start_npc"):
            p.append("snpc=" + lua_str(q["start_npc"]))
        #[[ ...and the OTHER givers, as a list, when the page named a role
        #   rather than a person. `snpc` above is one name because the record
        #   prints one name; `snpcs` is the whole set the marker may draw on.
        #   Kept as separate fields on purpose. Do not fold the set into the
        #   string field; see validate.py's note on `start_npcs`. Emitted only
        #   when it differs from `snpc` alone. ]]
        if q.get("start_npcs"):
            p.append("snpcs={"
                     + ",".join(lua_str(k) for k in q["start_npcs"]) + "}")
        if q.get("lvl"):
            p.append("lvl=%d" % q["lvl"])
        if q.get("jobs"):
            p.append("jobs={" + ",".join(lua_str(j) for j in q["jobs"]) + "}")
        #[[ Prerequisites, from `validate.py`'s gates.prev. A prerequisite can
        #   be a MISSION as well as a quest, so every one it forwards is
        #   emitted; drop the field here and the quest ships with no
        #   prerequisite at all and goes yellow too early.
        #
        #   NAMES, not ids, exactly like everything else the authoring layer
        #   writes. build_index.lua resolves them through resolve_prev, which
        #   already indexes 15 mission areas alongside the 11 quest ones,
        #   already prefers the quest's own area on a collision, and already has
        #   the relaxed matcher that punctuation differences need. Resolving
        #   here would be a second implementation of all of that. ]]
        if q.get("prev"):
            p.append("prev={" + ",".join(lua_str(t) for t in q["prev"]) + "}")
        #[[ The craft gate: {sk, rank, lvl, nm, rk, pts}. An AND-list, so it is
        #   emitted as a list even at length one. See validate.py's note on
        #   `jobs` for why that one is the cautionary tale.
        #
        #   `rank=0` is a REAL threshold (Amateur), which is why every test here
        #   is `is not None` rather than truthiness. A "rank Amateur or higher"
        #   gate is vacuous and would be better not authored, but silently
        #   turning it into "no rank required" by dropping a falsy zero is the
        #   kind of quiet transformation this pipeline exists to refuse. ]]
        if q.get("craft"):
            p.append("craft={" + ",".join(
                "{sk=%d%s%s%s%s%s}" % (
                    c["sk"],
                    ",rank=%d" % c["rank"] if c.get("rank") is not None else "",
                    ",lvl=%d" % c["lvl"] if c.get("lvl") is not None else "",
                    ",pts=%d" % c["pts"] if c.get("pts") is not None else "",
                    ",nm=" + lua_str(c["nm"]) if c.get("nm") else "",
                    ",rk=" + lua_str(c["rk_nm"]) if c.get("rk_nm") else "")
                for c in q["craft"]) + "}")
        #[[ Fame and `repeatable` come from the wiki record, and from nowhere
        #   else. This is the only place they are decided.
        #
        #   Region and level are separate fields but must be read as a pair; a
        #   level without a region is an invented pair nothing downstream
        #   catches. An absent `fame` is LOSSY: validate.py folds "no fame
        #   named", "named Abyssea, which is not a fame system" and "the page
        #   did not say" into one None, so nil is never evidence against a gate,
        #   only missing evidence for one.
        #
        #   `rep` is a THIRD state: absent means the page did not say, and
        #   build_index.lua keeps it nil rather than inventing false. Emit it
        #   whenever validate.py computed one (it does on 1227 of the 1546
        #   records), and never fold the unknown into false. ]]
        if q.get("repeatable") is not None:
            p.append("rep=" + lua_val(q["repeatable"]))
        #[[ `fame_lvl` is emitted only INSIDE a region, never beside one, because
        #   a level with no region is not a weaker fact: it is not a fact. "3"
        #   answers nothing without "of what". Region present with level absent
        #   is a real and common reading, and it is permanent: nothing completes
        #   such a row later, so those gates stay inert (core/prereq.lua tests
        #   `fame_lvl and fame_lvl > 0`). 183 of the 480 emitted regions are in
        #   that state. Inert shows the quest slightly early, which is the
        #   failure this project prefers. ]]
        if q.get("fame"):
            p.append("fame=" + lua_str(q["fame"]))
            n_fame += 1
            if q.get("fame_lvl") is not None:
                p.append("fame_lvl=%d" % q["fame_lvl"])
            else:
                n_fame_nolvl += 1
        #[[ The start ZONE as an id, for `past_era_twin` in build_index.lua.
        #   "Bastok Markets (S)" and "Bastok Markets" are two zones, not two
        #   spellings, so the suffix has to survive into the lookup. Only
        #   emitted when it resolved to a real id. ]]
        if isinstance(q.get("start_zone"), int) and not isinstance(
                q.get("start_zone"), bool):
            p.append("sz=%d" % q["start_zone"])
            n_sz += 1
        if q.get("repeatable") is None:
            n_rep_u += 1
        equip = EQUIP_FLAG in (q.get("flags") or [])
        if equip:
            n_equip_q += 1
            n_equip_r += sum(len([r for r in (s.get("reqs") or [])
                                  if r["kind"] == "item"])
                             for s in q["steps"])
        # Belt and braces: never a bare comma, whatever gets past the skip above.
        body = ",\n    ".join(emit_step(s, equip) for s in q["steps"])
        p.append("steps={\n    " + body + ",\n  }" if body else "steps={}")
        rows.append("  [%s] = {%s},\n" % (lua_str(key), ", ".join(p)))

    with io.open(args.out, "w", encoding="utf-8", newline="\n") as f:
        f.write("-- questmarks quest step ladders -- GENERATED FILE, DO NOT EDIT BY HAND.\n")
        f.write("-- Regenerate: python tools/pipeline/emit_lua.py\n")
        f.write("--\n")
        f.write("-- Read by tools/build_index.lua, which merges these ladders onto the\n")
        f.write("-- client's own DAT id list. A quest absent from here would keep a\n")
        f.write("-- synthetic single step at its giver, so the file can grow quest by quest.\n")
        f.write("--\n")
        f.write("-- Derived first-hand from the BG Wiki page cache (CC BY-NC-SA 3.0),\n")
        f.write("-- read rather than pattern-matched. See NOTICE.\n")
        f.write("--\n")
        #[[ `rows`, not `quests`. The header describes the FILE, and the file
        #   holds only the records that survived the skip above: a record with
        #   no steps is dropped entirely. Count the validated set here and the
        #   header contradicts the `tiers:` line below it, which sums the
        #   emitted set. A generated header that contradicts its own file is
        #   worse than no header: it is the number a reader quotes. ]]
        f.write("-- %d ladders, %d steps, %d monster targets"
                " (%d validated record(s) had no steps and were skipped).\n"
                % (len(rows), n_steps, n_mob, len(quests) - len(rows)))
        f.write("-- tiers: full=%d assisted=%d start-only=%d\n\n"
                % (tiers[3], tiers[2], tiers[1]))
        f.write("return {\n")
        for r in rows:
            f.write(r)
        f.write("}\n")

    _nl, n_nums = emit_mission_numbers()
    if n_nums:
        print("wrote %s  (%d mission numbers)" % (NUMBERS_OUT, n_nums))
    else:
        print("  NOTE: no supplemental/mission_numbers.json -- a prerequisite "
              "written as 'Promathia Mission 3-2' will stay unresolved")

    print("wrote %s" % args.out)
    print("  %d quests, %d steps, %d monster targets" % (len(quests), n_steps, n_mob))
    print("  tiers: full=%d assisted=%d start-only=%d" % (tiers[3], tiers[2], tiers[1]))
    #[[ Both are silent-loss shapes: a `rep` that stops being emitted and a `sz`
    #   that stops resolving each leave a file that parses, loads and looks
    #   right while an era-wrong or unknown-as-false answer ships. Numbers a
    #   human reads on every build are the only guard either one has. ]]
    print("  repeatable: %d rows carry it, %d left unknown (page did not say)"
          % (len(rows) - n_rep_u, n_rep_u))
    print("  start zone ids emitted: %d" % n_sz)
    #[[ Same silent-loss shape as `rep` above. Nothing stands behind this field:
    #   the first number is the whole of the addon's fame data, so a fall in it
    #   is data actually going missing. The second number is rows with a region
    #   and no threshold; they ship as inert gates. Allowed, and not a
    #   temporary state. ]]
    print("  fame: %d regions emitted, %d of them with no level on the page"
          % (n_fame, n_fame_nolvl))
    #[[ Reported and BOUNDED. This flag turns a "carry it" requirement into a
    #   stricter "wear it" one, so it can only ever make a marker later, never
    #   earlier. If it ever spread beyond the Vigil Weapon family, that would
    #   be a silent, invisible tightening across the whole index. ]]
    print("  equipped-not-merely-held: %d quests, %d requirements"
          % (n_equip_q, n_equip_r))
    if n_equip_q != 20 or n_equip_r != 20:
        print("  WARNING: expected exactly 20 quests / 20 requirements "
              "(the Unlocking a Myth family) -- check %s" % EQUIP_FLAG)
    if skipped:
        print("  skipped, no steps at all, so this row ships no ladder: %s"
              % ", ".join(skipped))


if __name__ == "__main__":
    main()
