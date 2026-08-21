"""Stage C: resolve every surface string, and quarantine what will not resolve.

    python tools/pipeline/validate.py [--in build/authored] [--out build/validated]

The reading pass writes NAMES, never resource ids. It can never invent a
number, and every failure lands here where it is visible and repairable rather
than silently wrong in the shipped index.

Resolution is delegated to tools/pipeline/resolve.lua, which is a thin CLI over
tools/lib/normalize.lua (the SAME code the mission builder uses). There is
deliberately no second implementation: reading res/*.lua with a Python regex
mis-parses en="\\"Final Fantasy\\"" and silently loses the key items that
"A Question of Taste" depends on.

Degradation is narrowest-first. An unresolved evidence entry costs that entry;
an unresolved zone costs that step its zone; an unresolved target costs that
step its marker but keeps its ladder position; an unresolved START is fatal,
because a quest with nowhere to begin cannot be marked at all.

Build-time only.
"""

import argparse
import glob
import io
import json
import os
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, "..", ".."))
BUILD = os.path.join(ADDON, "build")
REPORTS = os.path.join(BUILD, "reports")

LUAJIT = os.path.expandvars(
    r"%LOCALAPPDATA%\Programs\LuaJIT\LuaJIT\bin\luajit.exe")

KINDS = ("talk", "trade", "turnin", "examine", "fight", "travel", "obtain",
         "wait", "cutscene", "other")
TARGETS = ("npc", "object", "zone", "none")
CONF = ("high", "medium", "low")

# Flags that force a quest down to start-NPC only, whatever it claimed.
FATAL = {"no_dat_id", "ambiguous_dat_id", "start_npc_unresolved",
         "ambiguous_npc_no_zone", "evidence_duplicate", "evidence_empty",
         "steps_not_dense"}

PINS_PATH = os.path.join(HERE, "resolve_overrides.json")


def load_pins():
    """Hand-curated name -> id pins. See resolve_overrides.json.

    The third place a correction can live, and the only one for a name that
    resolves to the WRONG id: the authored layer holds names and never ids, so
    the reading cannot express it, and it is not a reading error anyway.

    Applied HERE, inside stage C, which puts it upstream of every gate below,
    including the duplicate-evidence gate. That gate keys on the resolved id,
    so a pin changes which duplicates are detected. An override applied after
    the build could not reproduce that.

    Exact names only, no patterns. Empty by default; with no pins the output is
    byte-identical to a build that never read the file.
    """
    if not os.path.exists(PINS_PATH):
        return {}
    with io.open(PINS_PATH, encoding="utf-8") as f:
        raw = json.load(f)
    pins = {}
    for kind, entries in raw.items():
        if kind.startswith("_") or not isinstance(entries, dict):
            continue          # _README and _candidates are documentation
        for name, spec in entries.items():
            if not isinstance(spec, dict) or spec.get("id") is None:
                continue
            if not (spec.get("why") or "").strip():
                sys.exit("resolve_overrides.json: %s/%s has no `why`. A pin "
                         "without a derivation is a guess, and a wrong pin is "
                         "a silently wrong marker." % (kind, name))
            pins[(kind, name)] = spec
    return pins


PINS = load_pins()

def resolve_batch(requests):
    """One subprocess for the whole run, not one per name."""
    if not requests:
        return {}
    payload = "\n".join(json.dumps(r, ensure_ascii=False) for r in requests)
    proc = subprocess.Popen(
        [LUAJIT, os.path.join("tools", "pipeline", "resolve.lua")],
        cwd=ADDON, stdin=subprocess.PIPE, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE)
    out, err = proc.communicate(payload.encode("utf-8"))
    if proc.returncode != 0:
        sys.exit("resolve.lua failed:\n" + err.decode("utf-8", "replace"))
    res = {}
    for line in out.decode("utf-8").splitlines():
        line = line.strip()
        if not line:
            continue
        r = json.loads(line)
        res[(r["kind"], r["name"], r.get("area") or "")] = r
    return res


def collect(quests):
    """Every string that needs a resource id, gathered before any subprocess."""
    reqs, seen = [], set()

    def add(kind, name, area=None):
        if not name:
            return
        key = (kind, name, area or "")
        if key not in seen:
            seen.add(key)
            reqs.append({"kind": kind, "name": name, "area": area})

    for q in quests:
        area = q["identity"]["area"]
        add("fame", ((q.get("gates") or {}).get("fame") or {}).get("region"), area)
        #[[ The craft gate holds NAMES like everything else in the authored
        #   layer ("Fishing", "Adept"), so it resolves here with the rest and
        #   a reading pass can never invent a skill id. ]]
        for c in ((q.get("gates") or {}).get("craft") or []):
            add("skill", c.get("skill"), area)
            add("srank", c.get("rank"), area)
        add("zone", (q.get("start") or {}).get("zone"), area)
        add("npc", (q.get("start") or {}).get("npc"), area)
        #[[ ...and the page's own words for the same field, which is a different
        #   string on the rows that matter. `start.raw` is the Start= value
        #   verbatim; `start.npc` is the author's reading of it. Those agree
        #   almost everywhere and diverge exactly where the page names a ROLE:
        #   the San d'Oria nation missions are authored as "Ambrotien" over a
        #   raw of "Any San d'Oria Gate Guard", while the Bastok and Windurst
        #   ones keep the role. Queued so `start_npcs` below can read it. ]]
        add("npc", (q.get("start") or {}).get("raw"), area)
        for s in q["steps"]:
            add("zone", s.get("zone"), area)
            if (s.get("target") or {}).get("type") in ("npc", "object"):
                add("npc", s["target"].get("name"), area)
            for it in (s.get("items") or []) + (s.get("items_alt") or []):
                add(it["kind"], it["name"], area)
            ev = s.get("evidence") or {}
            for it in (ev.get("all") or []) + (ev.get("alt") or []):
                add(it["kind"], it["name"], area)
    return reqs


def validate(q, res, quarantine):
    flags = set(q.get("review_flags") or [])
    area = q["identity"]["area"]
    qid = "%s/%s/%s" % (q["identity"]["cat"], area, q["identity"]["id"])

    def q_add(field, raw, reason, action):
        quarantine.append({"quest": qid, "title": q["source"]["wiki_title"],
                           "stage": "validate", "field": field,
                           "raw": raw, "reason": reason, "action": action})

    def look(kind, name):
        #[[ A hand pin wins over the resolver, and only ever for an exact
        #   (kind, name) somebody wrote down with a derivation. ]]
        p = PINS.get((kind, name))
        if p is not None:
            return {"kind": kind, "name": name, "id": p["id"], "pinned": True}
        return res.get((kind, name, area or "")) or res.get((kind, name, ""))

    # --- structural gates: these are build failures, not degradations -----
    for i, s in enumerate(q["steps"], 1):
        if s.get("n") != i:
            flags.add("steps_not_dense")
            q_add("steps[%d].n" % i, str(s.get("n")), "not_dense", "quest demoted")
        if s.get("kind") not in KINDS:
            q_add("steps[%d].kind" % i, str(s.get("kind")), "unknown_kind", "quest demoted")
            flags.add("steps_not_dense")
        if (s.get("target") or {}).get("type") not in TARGETS:
            q_add("steps[%d].target.type" % i, str((s.get("target") or {}).get("type")),
                  "unknown_target_type", "quest demoted")
            flags.add("steps_not_dense")
        ev = s.get("evidence")
        if ev is not None and not ((ev.get("all") or []) or (ev.get("alt") or [])):
            # Vacuously true: it would advance the mark on nothing at all.
            flags.add("evidence_empty")
            q_add("steps[%d].evidence" % i, "{}", "empty_and_list", "quest demoted")

    #[[ The duplicate gate covers ALTERNATES as well. The hazard is identical:
    #   if the same item can satisfy step 3 and step 6, obtaining it jumps the
    #   high-water mark straight to 6 and skips everything between. ]]
    seen_ev = {}
    for i, s in enumerate(q["steps"], 1):
        _ev = s.get("evidence") or {}
        for it in (_ev.get("all") or []) + (_ev.get("alt") or []):
            r = look(it["kind"], it["name"])
            k = (it["kind"], r["id"]) if r and r.get("id") else None
            if k:
                if k in seen_ev:
                    # The mark would jump to the later step the instant you
                    # obtain it, skipping everything between.
                    flags.add("evidence_duplicate")
                    q_add("steps[%d].evidence" % i, it["name"],
                          "duplicate_of_step_%d" % seen_ev[k], "quest demoted")
                seen_ev[k] = i

    # --- resolution, narrowest degradation first --------------------------
    out_steps = []
    for i, s in enumerate(q["steps"], 1):
        z = look("zone", s.get("zone")) if s.get("zone") else None
        zid = z["id"] if z and z.get("id") is not None else None
        #[[ 'moghouse' is one of the zone field's FOUR values, not a failure to
        #   resolve: number | false (any zone) | 'moghouse' | nil (unknown).
        #   resolve.lua reports it as a flag rather than an id, so without this
        #   every Mog House step loses its zone and becomes a nil that matches
        #   everywhere, which is the opposite of what the sentinel means. ]]
        if zid is None and z and z.get("moghouse"):
            zid = "moghouse"
        if s.get("zone") and zid is None:
            flags.add("step_zone_unresolved")
            q_add("steps[%d].zone" % i, s["zone"], "zone_unresolved", "step zone -> nil")

        npc_key, tt = None, (s.get("target") or {}).get("type")
        if tt in ("npc", "object"):
            r = look("npc", (s["target"] or {}).get("name"))
            if r and r.get("keys"):
                npc_key = r["keys"][0]
                if r.get("ambiguous") and zid is None:
                    # The "every Moogle in Vana'diel" shape. Structurally
                    # forbidden, not merely discouraged.
                    flags.add("ambiguous_npc_no_zone")
                    q_add("steps[%d].target" % i, s["target"]["name"],
                          "ambiguous_npc_without_zone", "quest demoted")
                    npc_key = None
            else:
                #[[ '???' and the blank-target family are OBJECT_DENY by design:
                #   they keep their rung and lose only their marker, which is the
                #   intended outcome and not a failure. Counted separately so
                #   they stop drowning the report: most quarantine entries are
                #   a literal '???', and an undifferentiated total is useless
                #   as a signal. ]]
                nm = str((s["target"] or {}).get("name") or "")
                expected = nm.strip().lower() in (
                    "???", "blank target", "blank spot", "none",
                    "full moon fountain", "glowing hearth")
                q_add("steps[%d].target" % i, nm,
                      "placeholder_target" if expected else "npc_unresolved",
                      "step keeps its place, loses its marker")

        def resolve_items(lst, field):
            """-> resolved, partial, spread

            `spread` is the OR case: a key item whose name covers several
            consecutive ids because the game stores one per unit carried
            (traverser stone is 1271-1276). Holding ANY of them is holding it,
            so the entry becomes an alternatives list rather than being dropped.
            Only done when it is the list's ONLY entry. Inside a real AND-list
            the schema cannot say "A and (B or C)", and guessing which id to
            pick would be a silently wrong marker."""
            lst = lst or []
            out, partial, spread = [], False, []
            for it in lst:
                r = look(it["kind"], it["name"])
                n = int(it.get("count") or 1)
                if r and r.get("id") is not None:
                    out.append({"kind": it["kind"], "rid": r["id"], "n": n})
                elif r and r.get("ids") and len(lst) == 1:
                    spread = [{"kind": it["kind"], "rid": rid, "n": n}
                              for rid in r["ids"]]
                else:
                    partial = True
                    q_add("steps[%d].%s" % (i, field), it["name"],
                          "%s_unresolved" % it["kind"], "entry dropped")
            return out, partial, spread

        items, ip, items_spread = resolve_items(s.get("items"), "items")
        items_alt, ipa, ia_spread = resolve_items(s.get("items_alt"), "items_alt")
        _ev = s.get("evidence") or {}
        ev_list, evp, ev_spread = resolve_items(_ev.get("all"), "evidence")
        ev_alt, eva, eva_spread = resolve_items(_ev.get("alt"), "evidence_alt")
        # A spread AND-entry becomes the alternatives list: any one id satisfies.
        items_alt = items_alt + items_spread + ia_spread
        ev_alt = ev_alt + ev_spread + eva_spread
        if evp or eva:
            flags.add("evidence_unresolved")

        #[[ Monsters are matched LIVE against get_mob_list, which returns every
        #   entity and not just NPCs, so there is no resource table to resolve
        #   them against. They get the same fold the NPC keys use. Carried
        #   through verbatim, with the role, because the role picks the glyph:
        #   sword to kill it, bag because it drops what this step needs. ]]
        mobs = []
        for m in (s.get("mobs") or []):
            if m.get("name"):
                mobs.append({"name": " ".join(m["name"].split()).lower(),
                             "n": m.get("count"),
                             "role": m.get("role") or "kill"})

        out_steps.append({
            "n": i, "k": s["kind"], "npc": npc_key, "z": zid,
            "g": s.get("grid"), "reqs": items or None,
            "reqs_alt": items_alt or None,
            "ev": ev_list or None,
            "ev_alt": ev_alt or None,
            "mobs": mobs or None,
            "group": s.get("group"),
            "optional": bool(s.get("optional")),
            "items_partial": bool(s.get("items_partial")) or ip or ipa,
        })

    # --- the start NPC is the one hard requirement ------------------------
    start = q.get("start") or {}
    sr = look("npc", start.get("npc")) if start.get("npc") else None
    #[[ Two fields, two questions: one name to print, and the whole set to draw
    #   on. resolve.lua returns a LIST because a giver really can be several
    #   NPCs: data/npc_overrides.lua maps "any bastok gate guard" to Argus,
    #   Cleades, Rashid and Malduc with zone=false, and any of them starts the
    #   mission. `start_npc` keeps keys[0] for build_index's `snpc` column,
    #   which takes one name. Do not join the list into that column with
    #   " or ": one string becomes one by_npc key, it matches no entity, and
    #   all four guards get no marker instead of one. Carry the list, just not
    #   through a field the pipeline reads as a name.
    #
    #   That is `start_npcs`, emitted as `snpcs={...}`. Every key joins
    #   build_index's scan set, and if the whole set matches an npc_overrides
    #   entry it is also the role, the only thing `giver_keys` widens the s=0
    #   giver row across. 65 rows carry it: 61 nation missions whose page states
    #   the giver as "Any <nation> Gate Guard", a real role, and 4 crystal_war
    #   rows where a `(S)` name expands to both spellings the client might use
    #   (`wahid [s]` and `wahid`), which only widens the scan set. Without
    #   this field the nation rows reach only one of their guards.
    #
    #   Not gated on `role`, unlike the raw branch below, because the `(S)`
    #   pairs are a real second spelling and refusing them would cost data now
    #   for a hypothetical. The hole that leaves is real: this takes any
    #   multi-key reading of `start.npc`, including normalize_npc's split on
    #   `or`/`and`/`&`/`/`, which is how a grid-reference fragment reaches
    #   `snpcs`. That is the fragment the raw branch's `role` guard below
    #   exists to keep out. Measured: 0 of 1546 records have a split token in
    #   `start.npc`; if that moves, gate this the way the raw branch is
    #   gated. ]]
    start_key = sr["keys"][0] if sr and sr.get("keys") else None
    start_keys = sr["keys"] if sr and len(sr.get("keys") or []) > 1 else None

    #[[ The role the page actually wrote, where the author resolved it away.
    #   `start.raw` is the Start= field verbatim, `start.npc` the reading of it.
    #   Nineteen San d'Oria nation-mission records say "Ambrotien" over a raw
    #   of "Any San d'Oria Gate Guard", one guard for a role that names three;
    #   Bastok and Windurst keep the role. Recovering the role here is what
    #   keeps the other two by_npc keys.
    #
    #   Gated on `rr["role"]`, which is resolve.lua saying the string hit a
    #   multi-name override. Do not weaken that to "the raw resolves to more
    #   keys than the authored name and contains it": it lets normalize_npc's
    #   split on `or`, `and`, `&` and `/` through. The raw of `quest/toau/21`
    #   is "Waoud/Raubahn, Aht Urhgan Whitegate - (J-10)", so the row would
    #   ship `snpcs={'waoud','raubahn, aht urhgan whitegate -'}` and that
    #   fragment would become a real by_npc key.
    #
    #   Union, not replacement. Assigning `start_keys = raw_keys` after testing
    #   containment on `keys[0]` alone lets an authored [a, b] against a raw
    #   [a, c, d] pass, and drops b. The role guard makes that unreachable, but
    #   the direction it fails in is losing a giver. `raw` is this record's own
    #   Start field, expanded by data/npc_overrides.lua, so nothing here comes
    #   from a sibling page. ]]
    raw_start = start.get("raw")
    rr = look("npc", raw_start) if raw_start else None
    if start_key and rr and rr.get("role"):
        merged = list(start_keys or ([start_key] if start_key else []))
        for k in rr.get("keys") or []:
            if k not in merged:
                merged.append(k)
        if len(merged) > 1 and start_key in merged:
            start_keys = merged
    #[[ The start zone, and the era it is in.
    #
    #   Resolve it here rather than trusting a second reading of the same
    #   field, because the two can name different zones rather than the same
    #   zone differently.
    #
    #   Wings of the Goddess is the case that matters. The page writes
    #   "Bastok Markets (S)"; drop the suffix and it resolves to 235, the
    #   present-day city, while zone 87 is where Klara stands. A marker in 235
    #   is not slightly off, it is in a town the NPC is not in, on the far side
    #   of a time portal.
    #
    #   Not quarantined when it fails to resolve. This value is corroborative:
    #   build_index.lua consults it only to correct an era mismatch, so an
    #   unresolved start zone costs nothing and a quarantine line for it would
    #   be noise in a report that exists to be read. ]]
    sz = look("zone", start.get("zone")) if start.get("zone") else None
    start_zone = sz["id"] if sz and sz.get("id") is not None else None
    if not start_key and not any(s["npc"] for s in out_steps):
        flags.add("start_npc_unresolved")
        q_add("start.npc", str(start.get("npc")), "unresolved_and_no_markable_step",
              "quest NOT emitted")

    # --- gates ------------------------------------------------------------
    g = q.get("gates") or {}
    fame = g.get("fame") or {}
    fr = look("fame", fame.get("region")) if fame.get("region") else None
    fame_region = fr.get("id") if fr else None

    #[[ --- the craft gate ---------------------------------------------------
    #
    #   "Fishing rank Adept or higher" -> {sk: 48, rank: 8}. Both halves come
    #   from res/ through resolve.lua, never from a table written here.
    #
    #   A LIST, and an AND-list, from the first day it exists. The cost of
    #   guessing wrong is asymmetric: a list that only ever holds one entry
    #   costs a pair of brackets, while a scalar that meets its second entry
    #   silently drops one. `jobs` is a list for the same reason: `Old Wounds`
    #   gates on seven of them. (`jobs` is an OR: any of these
    #   jobs may do it. This is an AND: every craft named must be met. They
    #   are different questions and the difference is documented here so nobody
    #   copies the wrong precedent.)
    #
    #   Every failure below drops the entry rather than emitting something
    #   approximate. A dropped gate leaves the marker exactly as it is today: a
    #   yellow "!" that may be a false yellow, which is the status quo. A gate
    #   built on a name that did not resolve would instead grey a marker on our
    #   own data being broken. Those are not symmetric and the project's rule
    #   is explicit: bad data may move a marker, never delete one. ]]
    craft = []
    for c in (g.get("craft") or []):
        if not isinstance(c, dict):
            continue
        raw = c.get("raw") or c.get("skill") or "?"
        sr = look("skill", c.get("skill")) if c.get("skill") else None
        if not sr or sr.get("id") is None:
            flags.add("craft_gate_unresolved")
            q_add("gates.craft.skill", str(c.get("skill")), "skill_unresolved",
                  "gate dropped, marker unchanged")
            continue
        #[[ Rank exists only on the Synthesis block. types.craft_skill carries
        #   {Rank, Level, Capped} and types.combat_skill carries
        #   {Level, Capped}. There is no rank to compare a combat skill
        #   against, so a rank threshold on one is a misreading, not a gate.
        #   Refused loudly rather than quietly compared against the level,
        #   which would fire at a wildly wrong point. ]]
        want_rank = None
        if c.get("rank") is not None:
            if sr.get("category") != "Synthesis":
                flags.add("craft_gate_unresolved")
                q_add("gates.craft.rank", raw, "rank_on_non_synthesis_skill",
                      "gate dropped, marker unchanged")
                continue
            rr = look("srank", c.get("rank"))
            #[[ `is None`, not falsiness: Amateur is rank 0 and a truthiness
            #   test would throw away the only rank that means "no rank at
            #   all". ]]
            if not rr or rr.get("id") is None:
                flags.add("craft_gate_unresolved")
                q_add("gates.craft.rank", str(c.get("rank")), "rank_unresolved",
                      "gate dropped, marker unchanged")
                continue
            want_rank = rr["id"]
        want_lvl = c.get("level")
        #[[ Guild points, packet 0x113. Nine guilds only (ids 48..56), and
        #   Synergy (57) has none, so a points gate on it would read whatever
        #   sits past the block. Refused rather than emitted. ]]
        want_pts = c.get("points")
        if want_pts is not None and not (48 <= sr["id"] <= 56):
            flags.add("craft_gate_unresolved")
            q_add("gates.craft.points", raw, "no_guild_point_economy",
                  "gate dropped, marker unchanged")
            continue
        if want_rank is None and want_lvl is None and want_pts is None:
            flags.add("craft_gate_unresolved")
            q_add("gates.craft", raw, "no_rank_level_or_points",
                  "gate dropped, marker unchanged")
            continue
        craft.append({"sk": sr["id"], "rank": want_rank, "lvl": want_lvl,
                      "pts": want_pts,
                      #[[ The NAMES ride along for the same reason `nm` does on
                      #   an `eq` requirement: this gate is one of the few that
                      #   greys a marker on sight, so "//qm why" has to be able
                      #   to say "Fishing rank Adept" rather than "skill 48
                      #   rank 8". res/skills.lua is 58 rows, but the addon
                      #   still must not read res at runtime. ]]
                      "nm": sr.get("en") or c.get("skill"),
                      "rk_nm": (look("srank", c["rank"]) or {}).get("en")
                               if c.get("rank") is not None else None})

    conf = q.get("confidence") or "low"
    if flags & FATAL:
        conf = "low"
    elif "verifier_disagreed" in flags or "evidence_is_reward" in flags:
        conf = "low" if conf == "medium" else "medium"

    return {
        "cat": q["identity"]["cat"], "area": area, "id": q["identity"]["id"],
        "dat_name": q["identity"]["dat_name"],
        "conf": {"high": 3, "medium": 2, "low": 1}[conf],
        #[[ TRI-STATE, and `bool()` is exactly what collapses it.
        #
        #   `bool(None)` is False, so wrapping this value makes a page that
        #   never said whether the quest repeats claim it definitely does not.
        #   Downstream that is not a cosmetic loss: prereq.marker_state draws a
        #   'repeat' marker on a completed repeatable and NOTHING on a
        #   completed one-shot, so an unknown recorded as False is a marker
        #   that can never appear.
        #
        #   None means unknown and must survive as None all the way to
        #   quest_index.lua, where nil is the third state the whole addon is
        #   built around. Missing key and explicit null are the same reading
        #   (the page did not say), and both land here as None.
        #
        #   The consumer needs no change: a completed quest whose `repeatable`
        #   is nil still draws nothing, because `if entry.repeatable then` is
        #   false for nil exactly as it is for false. What this buys is that
        #   the DATA does not lie about knowing. ]]
        "repeatable": (None if g.get("repeatable") is None
                       else bool(g.get("repeatable"))),
        "start_zone": start_zone,
        "fame": fame_region, "fame_lvl": fame.get("level"),
        #[[ `jobs`, PLURAL, and it must stay plural the whole way down.
        #   The authoring schema writes a LIST because `Old Wounds` gates on
        #   seven jobs; emit_lua.py reads q["jobs"]; build_index.lua reads
        #   L.jobs. Read `jobs`, never `job`: a key the schema does not have
        #   resolves to None and every job gate is dropped here silently, with
        #   nothing downstream able to notice. ]]
        "lvl": g.get("level"), "jobs": g.get("jobs") or [],
        "craft": craft,
        #[[ Kept VERBATIM as the page wrote it, including the numbered form
        #   ("Promathia Mission 3-2"). build_index.lua's resolve_prev_name is
        #   where every prerequisite name is finally matched, so de-number
        #   there and nowhere else. De-number in one place only and a row can
        #   carry a resolved entry beside an unresolved twin, which pins it at
        #   nil forever. ]]
        "prev": [p["title"] for p in (g.get("prev") or [])],
        "start_npc": start_key,
        "start_npcs": start_keys,
        "steps": out_steps,
        "flags": sorted(flags),
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="indir", default=os.path.join(BUILD, "authored"))
    ap.add_argument("--out", dest="outdir", default=os.path.join(BUILD, "validated"))
    args = ap.parse_args()

    quests = []
    origin = {}
    for p in sorted(glob.glob(os.path.join(args.indir, "*.json"))):
        with io.open(p, encoding="utf-8") as f:
            d = json.load(f)
        for q in (d if isinstance(d, list) else [d]):
            quests.append(q)
            origin[id(q)] = os.path.basename(p)
    if not quests:
        sys.exit("no authored quests found in %s\n"
                 "Every *.json there parsed but held no quest record. Check\n"
                 "that --in names the authored corpus (build/authored), not\n"
                 "a rendered or validated directory." % args.indir)

    #[[ One record per quest, and the corpus is whatever *.json is in the
    #   directory, so a stray file is silently a stray quest.
    #
    #   The shape to watch for: a scratch file `_t.json` holding a synthetic
    #   "Test Quest" that reuses the real key quest/bastok/65. The duplicate
    #   goes through resolution, and the only outward sign is the count moving
    #   by one. Downstream, `emit_lua` keys by cat/area/id and last-wins, so a
    #   scratch record can silently REPLACE a real ladder.
    #
    #   Fatal rather than a quarantine: a duplicate identity means the corpus
    #   is not what it claims to be, and nothing after this point can be
    #   trusted to have used the right copy. ]]
    seen_id = {}
    dupes = []
    for q in quests:
        i = q.get("identity") or {}
        k = (i.get("cat"), i.get("area"), i.get("id"))
        if k in seen_id:
            dupes.append("%s/%s/%s in %s and %s  (%r / %r)"
                         % (k[0], k[1], k[2], seen_id[k], origin[id(q)],
                            seen_id.get(("name", k)), i.get("dat_name")))
        else:
            seen_id[k] = origin[id(q)]
            seen_id[("name", k)] = i.get("dat_name")
    if dupes:
        sys.exit("DUPLICATE QUEST IDENTITY -- the authored corpus has %d "
                 "collision(s), refusing to build:\n  %s"
                 % (len(dupes), "\n  ".join(dupes)))

    res = resolve_batch(collect(quests))

    quarantine, out = [], []
    for q in quests:
        out.append(validate(q, res, quarantine))

    for d in (args.outdir, REPORTS):
        if not os.path.isdir(d):
            os.makedirs(d)
    with io.open(os.path.join(args.outdir, "quests.json"), "w",
                 encoding="utf-8", newline="\n") as f:
        json.dump(out, f, ensure_ascii=False, indent=1, sort_keys=True)
    qp = os.path.join(REPORTS, "validate.jsonl")
    with io.open(qp, "w", encoding="utf-8", newline="\n") as f:
        for r in quarantine:
            f.write(json.dumps(r, ensure_ascii=False) + "\n")

    tiers = {3: 0, 2: 0, 1: 0}
    steps = ev = marked = 0
    for q in out:
        tiers[q["conf"]] += 1
        steps += len(q["steps"])
        #[[ `ev_alt` counts. core/steps.lua judges a step with
        #   `inventory.meets(s.ev, s.ev_alt)`: an alternative is a second way
        #   to satisfy the SAME step, not an extra condition. Counting only
        #   `ev` here under-reports the addon's real reach and makes a headline
        #   number disagree with the code it describes. ]]
        ev += sum(1 for s in q["steps"] if s["ev"] or s.get("ev_alt"))
        marked += sum(1 for s in q["steps"] if s["npc"])
    print("validated %d quests" % len(out))
    #[[ Printed unconditionally, including the zero, so "no pins" and "the pin
    #   file stopped being read" cannot look the same. A count that moves
    #   without somebody editing the file is a bug. ]]
    print("  name pins      %d  (tools/pipeline/resolve_overrides.json)"
          % len(PINS))
    print("  tiers          full=%d assisted=%d start-only=%d"
          % (tiers[3], tiers[2], tiers[1]))
    print("  steps          %d total, %d markable, %d carrying evidence"
          % (steps, marked, ev))
    #[[ The tri-state, counted on every build. `unknown` collapsing to zero
    #   means the None branch above has been "simplified" back into a bool.
    #   Nothing downstream can detect that: a false and an unknown draw the
    #   same marker, so only this number can tell them apart. ]]
    n_rep_t = sum(1 for q in out if q["repeatable"] is True)
    n_rep_f = sum(1 for q in out if q["repeatable"] is False)
    n_rep_u = sum(1 for q in out if q["repeatable"] is None)
    print("  repeatable     true=%d false=%d unknown=%d" % (n_rep_t, n_rep_f, n_rep_u))
    print("  start zones    %d resolved of %d stated"
          % (sum(1 for q in out if q["start_zone"] is not None),
             sum(1 for q in (quests) if (q.get("start") or {}).get("zone"))))
    #[[ Printed unconditionally, including the zero. This gate is one of the
    #   very few that can grey a marker on sight, so its blast radius must be a
    #   number somebody reads on every build rather than something that grows
    #   quietly. Same reasoning as the equipped-not-merely-held line in
    #   emit_lua.py. ]]
    n_cq = sum(1 for q in out if q.get("craft"))
    n_cg = sum(len(q.get("craft") or []) for q in out)
    n_cbad = sum(1 for q in out if "craft_gate_unresolved" in (q.get("flags") or []))
    print("  craft gates    %d quest(s), %d gate(s), %d dropped as unresolvable"
          % (n_cq, n_cg, n_cbad))
    print("  quarantine     %d -> %s" % (len(quarantine), qp))
    seen = {}
    for r in quarantine:
        seen[r["reason"]] = seen.get(r["reason"], 0) + 1
    expected = seen.pop("placeholder_target", 0)
    for k in sorted(seen):
        print("     %-34s %d" % (k, seen[k]))
    if expected:
        print("     %-34s %d  (by design, not a failure)"
              % ("placeholder_target", expected))


if __name__ == "__main__":
    main()
