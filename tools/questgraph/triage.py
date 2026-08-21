"""What to look at first, ranked by how likely it is to be wrong.

The ordering is the product. A list of 1003 quests helps nobody; the value is
in knowing that 16 rows are real failures and 340 are the intended outcome, and
that `unnamed_target` on 125 quests is a judgement call somebody made on
purpose while `item_unresolved` on 11 is a marker that silently is not there.

One rule governs every bucket: a bucket whose rows are mostly the intended
outcome is not a signal, and is either excluded or labelled as such. That rule
is why quarantine is split by reason rather than reported as one list: 340 of
its 400 rows are `???`, which is working exactly as designed.

Reads only. Build-time only.
"""

import collections

#[[ Flags that most often mean "a human should look at this", as opposed to
#   flags that record a decision already made. `or_branch_modelled` (128) and
#   `unordered_group` (117) are both frequent and both mean the reader HANDLED
#   something. Surfacing them would bury the ones that mean they could not. ]]
ACTIONABLE_FLAGS = [
    ("unnamed_target", "the page never named the entity, so the step cannot "
                       "carry a marker"),
    ("generic_npc_name", "the name is a category ('the protocrystal'), not an "
                         "entity"),
    ("or_branch_unmodelled", "the page offers a choice the schema could not "
                             "express"),
    ("walkthrough_incomplete", "the page does not contain the whole quest"),
    ("start_disagrees_with_header", "the header's giver is not who the "
                                    "walkthrough sends you to"),
    ("consumed_key_item", "evidence that disappears again, so the mark can "
                          "walk backwards"),
    ("mission_gate_unmodelled", "gated on a mission the schema cannot state"),
    ("no_evidence", "nothing observable anywhere in the quest"),
    ("rank_gate_unmodelled", "gated on nation rank, which is not modelled"),
    ("walkthrough_in_table", "the walkthrough rendered as one bullet, so "
                             "source_bullets is worthless for this page"),
    ("latent_unmodelled", "a precondition the reader could not express"),
    ("count_unobservable", "'defeat 5 of X' -- no packet carries the tally"),
    ("grid_conflict", "the page gives two different grid references"),
    ("repeating_loop", "a step that repeats, which a ladder cannot express"),
]

#[[ Known collisions, reported but never actioned. Named here so the tool asks
#   about them rather than waiting to be asked. ]]
KNOWN_COLLISIONS = {
    "items bind arbitrarily": ["Nodal Wand", "Lexeme Blade"],
    "key items needing their literal double quotes": [
        '"Foe Finder Mk. I"', '"Fragmenting"', '"Ephemeral Endeavor"',
        '"Enlightened Endeavor"', '"Secrets of Runic Enhancement"'],
    "non-unique key items, correctly refused": [
        "star ring", "Traverser stone", "Breath of dawn"],
}


def _quests_with_flag(c, flag):
    return [qid for qid, q in c.by_qid.items()
            if flag in (q.get("review_flags") or [])]


def quarantine_groups(c):
    by = collections.defaultdict(list)
    for r in c.real_quarantine():
        by[r["reason"]].append(r)
    return by


def coverage_rows(c):
    """Quests whose marker cannot move, and how far it cannot move.

    Not bugs. The README says so at length, and it also says this is where a
    stale marker comes from, which makes this the right place to look when one
    is reported.
    """
    rows = []
    for qid, v in c.validated.items():
        collapsed = []
        for s in v["steps"]:
            g = s.get("group")
            ev = bool(s.get("ev") or s.get("ev_alt"))
            if g is not None and collapsed and collapsed[-1][0] == g:
                collapsed[-1] = (g, collapsed[-1][1] or ev)
            else:
                collapsed.append((g, ev))
        run = best = 0
        for _g, ev in collapsed:
            run = 0 if ev else run + 1
            best = max(best, run)
        have = sum(1 for _g, ev in collapsed if ev)
        if not collapsed:
            continue
        rows.append({"qid": qid, "positions": len(collapsed),
                     "with_evidence": have, "longest_dark": best,
                     "title": ((c.by_qid.get(qid) or {}).get("source") or {})
                              .get("wiki_title")})
    return rows


def build(c, g):
    """The triage list. Order is the point."""
    qg = quarantine_groups(c)
    graph = g.report()
    cov = coverage_rows(c)
    flags = c.flag_counts()

    buckets = []

    def add(key, title, count, why, level, rows=None):
        buckets.append({"key": key, "title": title, "count": count,
                        "why": why, "level": level, "rows": rows or []})

    # 1: things that are outright broken ----------------------------------
    for reason, rows in sorted(qg.items(), key=lambda kv: -len(kv[1])):
        add("quarantine:" + reason,
            "quarantine: " + reason, len(rows),
            {"item_unresolved":
                "the name is not in res/ -- the step's requirement or evidence "
                "is silently absent",
             "unresolved_and_no_markable_step":
                "no start NPC and no markable step: the quest is NOT emitted",
             "ambiguous_npc_without_zone":
                "a name shared across zones with no zone to pin it -- "
                "structurally forbidden, the step loses its marker",
             }.get(reason, "validate.py could not resolve this"),
            "error",
            [{"qid": r["quest"], "title": r["title"], "field": r["field"],
              "raw": r["raw"], "action": r["action"]} for r in rows])

    if graph["cycles"]:
        add("graph:cycles", "prerequisite cycles", len(graph["cycles"]),
            "every member requires its own completion, so none can ever start",
            "error",
            [{"qid": k} for cy in graph["cycles"] for k in cy])

    # 2: confidence the reader itself flagged -----------------------------
    tiers = collections.defaultdict(list)
    for qid, v in c.validated.items():
        tiers[v["conf"]].append(qid)
    add("tier:start_only", "confidence: start-NPC only", len(tiers[1]),
        "the page could not be read into steps at all, or a hard gate demoted "
        "it -- these carry a giver and nothing else",
        "warn", [{"qid": q} for q in sorted(tiers[1])])
    add("tier:assisted", "confidence: assisted", len(tiers[2]),
        "the page was unclear, contradicted itself, or a gate was unmodellable",
        "warn", [{"qid": q} for q in sorted(tiers[2])])

    # 3: judgement calls the reader recorded ------------------------------
    for flag, why in ACTIONABLE_FLAGS:
        n = flags.get(flag, 0)
        if n:
            add("flag:" + flag, "flag: " + flag, n, why, "info",
                [{"qid": q} for q in sorted(_quests_with_flag(c, flag))])

    # 4: reach, which is where a stale marker comes from ------------------
    dark = [r for r in cov if r["with_evidence"] == 0]
    add("cov:no_evidence", "no observable evidence at all", len(dark),
        "the marker settles one step past the giver and stays there for the "
        "whole quest. Not a bug -- but it is where a stale marker comes from",
        "info", [{"qid": r["qid"], "title": r["title"],
                  "positions": r["positions"]} for r in
                 sorted(dark, key=lambda r: -r["positions"])[:400]])

    long_dark = [r for r in cov if r["longest_dark"] >= 5]
    add("cov:long_dark", "5+ consecutive unobservable positions",
        len(long_dark),
        "the longest stretch the marker cannot move through. The worst are the "
        "quests most likely to be reported as wrong",
        "info", [{"qid": r["qid"], "title": r["title"],
                  "longest_dark": r["longest_dark"],
                  "positions": r["positions"]} for r in
                 sorted(long_dark, key=lambda r: -r["longest_dark"])[:400]])

    # 5: what a human already decided -------------------------------------
    he = c.human_edited()
    add("human", "human-corrected records", len(he),
        "a person decided these rather than the reading pass. Each row's "
        "`basis` says on what: 'game' means checked in-game, 'reading' means "
        "re-read from the page. The most trustworthy records here, and they "
        "must survive every rebuild",
        "good", [{"qid": qid, "basis": q["human"].get("basis"),
                  "at": q["human"].get("edited_at"),
                  "reason": q["human"].get("reason")} for qid, q in he])

    return {
        "buckets": buckets,
        "known_collisions": KNOWN_COLLISIONS,
        "placeholder_note": {
            "count": sum(1 for r in c.quarantine
                         if r["reason"] == "placeholder_target"),
            "text": "'???' and the blank-target family are OBJECT_DENY by "
                    "design: the step keeps its rung and loses only its "
                    "marker. They are the intended outcome and are not listed "
                    "as problems.",
        },
    }


#[[ How much a single quest is worth looking at, and WHY. The buckets above
#   answer "show me everything with problem X"; this answers "which of these
#   184 quests should my eye go to", which is the question the map view asks.
#
#   Weighted, not counted. A quarantine row means a marker is silently absent
#   right now; `unnamed_target` means a reader made a judgement call and said
#   so. Treating those as one point each would bury the first under the
#   second: there are 16 of the one and 126 of the other. ]]
SIGNAL_WEIGHTS = {
    "quarantine": 50,          # per row: something does not resolve
    "start_only": 40,          # the page could not be read into steps at all
    "assisted": 8,             # the reading itself is hedged
    "flag": 6,                 # per actionable review flag
    "no_evidence": 5,          # the mark can never move
    "dark_run": 2,             # per position in the longest unobservable run
}


#[[ The severity bands. A quest lands in exactly the first one it matches, and
#   the ORDER is the claim: `broken` is a marker that is silently absent right
#   now, `dark` is a marker that is correct and simply cannot move.
#
#   Splitting `dark` out from `flagged` is the single most important line here.
#   379 quests have no observable evidence at all and most of them are FINE.
#   The marker sits one past the giver for the whole quest and that is the
#   right answer. Ranking "unfalsifiable" as "suspicious" would send somebody
#   to inspect several hundred records with nothing to fix, and would burn the
#   credibility of every other signal on the screen. It gets its own band with
#   its own sentence saying so. ]]
BANDS = [
    ("broken", "cannot be trusted",
     "a name does not resolve, so a marker is silently absent right now"),
    ("stalls", "stalls mid-quest",
     "observable, then five or more positions dark -- the marker visibly stops"),
    ("flagged", "awaiting judgement",
     "a reader recorded a call they could not make with confidence"),
    ("dark", "never moves",
     "no observable evidence anywhere. USUALLY CORRECT -- the mark sits one "
     "past the giver for the whole quest, which is the honest answer"),
    ("quiet", "nothing found", "no signal of any kind"),
]


def collapse(vsteps):
    """Validated steps -> the positions a player actually experiences.

    On the VALIDATED layer, because evidence whose name did not resolve is
    evidence the addon never sees. Consecutive steps sharing a `group` are one
    position and their evidence is OR'd. The group's evidence sits on its last
    member by design, so folding any other way loses it.
    """
    out = []
    for s in vsteps:
        g = s.get("group")
        lit = bool(s.get("ev") or s.get("ev_alt"))
        opt = bool(s.get("optional"))
        if g is not None and out and out[-1]["group"] == g:
            out[-1]["lit"] = out[-1]["lit"] or lit
            out[-1]["members"] += 1
            continue
        if opt and out:
            out[-1]["spurs"] += 1
            continue
        out.append({"group": g, "lit": lit, "members": 1, "spurs": 0,
                    "opt": opt})
    return out


def quest_signals(c):
    """-> {qid: {score, reasons[], tier, trace, band, ...}} per authored quest."""
    quarantine = collections.Counter(r["quest"] for r in c.real_quarantine())
    actionable = {k for k, _ in ACTIONABLE_FLAGS}
    cov = {r["qid"]: r for r in coverage_rows(c)}
    out = {}
    for qid, q in c.by_qid.items():
        v = c.validated.get(qid)
        reasons, score = [], 0

        n = quarantine.get(qid, 0)
        if n:
            score += SIGNAL_WEIGHTS["quarantine"] * n
            reasons.append("%d unresolved name%s" % (n, "" if n == 1 else "s"))

        tier = (v or {}).get("conf")
        if tier == 1:
            score += SIGNAL_WEIGHTS["start_only"]
            reasons.append("start-NPC only")
        elif tier == 2:
            score += SIGNAL_WEIGHTS["assisted"]
            reasons.append("assisted")

        hit = sorted(set(q.get("review_flags") or []) & actionable)
        if hit:
            score += SIGNAL_WEIGHTS["flag"] * len(hit)
            reasons.append(", ".join(hit))

        cr = cov.get(qid)
        if cr and cr["with_evidence"] == 0 and cr["positions"] > 1:
            score += SIGNAL_WEIGHTS["no_evidence"]
            reasons.append("no observable evidence")
        if cr and cr["longest_dark"] >= 5:
            score += SIGNAL_WEIGHTS["dark_run"] * cr["longest_dark"]
            reasons.append("%d dark positions in a row" % cr["longest_dark"])

        #[[ The trace: one mark per collapsed position, filled where the addon
        #   can observe it. The same object is drawn at all three zooms, so
        #   "why is my marker wrong" is answerable before a word is read: a
        #   long hollow run IS the answer. ]]
        trace = collapse((v or {}).get("steps") or [])
        lit = sum(1 for t in trace if t["lit"])
        run = dark_run = 0
        for t in trace:
            run = 0 if t["lit"] else run + 1
            dark_run = max(dark_run, run)

        if n:
            band = "broken"
        elif lit and dark_run >= 5:
            band = "stalls"
        elif hit:
            band = "flagged"
        elif not lit and len(trace) > 1:
            band = "dark"
        else:
            band = "quiet"

        out[qid] = {
            "score": score,
            "reasons": reasons,
            "tier": tier,
            "band": band,
            "trace": trace,
            "lit": lit,
            "dark_run": dark_run,
            "flags": hit,
            "quarantine": n,
            "steps": len(q["steps"]),
            "positions": len(trace) or (cr or {}).get("positions", 1),
            "zones": len({s.get("zone") for s in q["steps"] if s.get("zone")}),
            "human": bool(q.get("human")),
            "title": (q.get("source") or {}).get("wiki_title"),
            "start": (q.get("start") or {}).get("npc"),
        }
    return out


def areas(c, sig=None):
    """Level 1. The 10 areas the data actually has, with their weather."""
    sig = sig if sig is not None else quest_signals(c)
    by = collections.defaultdict(lambda: {
        "quests": 0, "score": 0, "worst": 0, "human": 0,
        "tiers": {1: 0, 2: 0, 3: 0}, "flagged": 0, "steps": 0,
        "bands": collections.Counter(), "lit_at": collections.Counter(),
        "have_at": collections.Counter()})
    for qid, s in sig.items():
        a = qid.split("/")[1]
        r = by[a]
        r["quests"] += 1
        r["score"] += s["score"]
        r["worst"] = max(r["worst"], s["score"])
        r["steps"] += s["steps"]
        r["human"] += 1 if s["human"] else 0
        r["bands"][s["band"]] += 1
        if s["tier"]:
            r["tiers"][s["tier"]] += 1
        if s["score"] > 0:
            r["flagged"] += 1
        #[[ The aggregate trace: at position k, what fraction of this area's
        #   quests can the addon observe? A left-loaded profile that collapses
        #   fast is the corpus's normal shape. A flat hollow line from k=1 is
        #   an extraction failure at AREA scale, which no per-quest view can
        #   show you. ]]
        for k, t in enumerate(s["trace"]):
            r["have_at"][k] += 1
            if t["lit"]:
                r["lit_at"][k] += 1
    out = []
    for a, r in by.items():
        width = max(r["have_at"]) + 1 if r["have_at"] else 0
        agg = [round(r["lit_at"][k] / r["have_at"][k], 3) if r["have_at"][k]
               else 0.0 for k in range(min(width, 24))]
        out.append(dict(area=a, cat="quest",
                        quests=r["quests"], score=r["score"],
                        worst=r["worst"], human=r["human"],
                        flagged=r["flagged"], steps=r["steps"],
                        bands=dict(r["bands"]),
                        aggregate=agg,
                        tiers={"start_only": r["tiers"][1],
                               "assisted": r["tiers"][2],
                               "full": r["tiers"][3]},
                        mean=round(r["score"] / max(r["quests"], 1), 1)))
    #[[ Sorted by what needs a human, not by size. The area with the most
    #   quests is not the area with the most wrong. ]]
    out.sort(key=lambda r: -(r["bands"].get("broken", 0) * 100
                             + r["bands"].get("stalls", 0) * 10
                             + r["bands"].get("flagged", 0)))
    return out


def area_detail(c, g, area, sig=None):
    """Level 2. Every quest in one area, plus the prev edges among them.

    Edges are restricted to BOTH ends being in this area on purpose: 671 edges
    span 1537 nodes and most quests are isolated, so drawing cross-area stubs
    would add lines that lead nowhere visible and imply structure that is not
    there. Cross-area links are reported separately as a count per quest.
    """
    sig = sig if sig is not None else quest_signals(c)
    mine = {qid: s for qid, s in sig.items() if qid.split("/")[1] == area}
    edges, external = [], collections.Counter()
    for qid in mine:
        for p in g.prev.get(qid, ()):
            if p in mine:
                edges.append([p, qid])
            else:
                external[qid] += 1
    quests = []
    for qid, s in mine.items():
        quests.append(dict(s, qid=qid, external_prev=external.get(qid, 0)))
    quests.sort(key=lambda r: (-r["score"], r["title"] or ""))

    #[[ Chains and singletons are separated because the DAG is SPARSE and
    #   pretending otherwise produces a bad picture. 671 edges span 1537 nodes;
    #   914 entries are roots and 740 have no edge at all. A force layout over
    #   that is a cloud of floating dots with a few threads in it. The
    #   structure that does exist gets lost among the structure that does not.
    #
    #   So the quests that ARE in a chain get a layout that reads as a chain,
    #   and the rest get a layout that ranks them. Two honest pictures beat one
    #   dishonest one. ]]
    adj = collections.defaultdict(set)
    for a, b in edges:
        adj[a].add(b)
        adj[b].add(a)
    seen, chains = set(), []
    for qid in sorted(mine):
        if qid in seen or qid not in adj:
            continue
        comp, stack = [], [qid]
        seen.add(qid)
        while stack:
            n = stack.pop()
            comp.append(n)
            for m in adj[n]:
                if m not in seen:
                    seen.add(m)
                    stack.append(m)
        #[[ Depth within the component, so a chain can be drawn left to right
        #   in prerequisite order rather than in whatever order the walk hit. ]]
        depth = {}

        def d(n, guard):
            if n in depth:
                return depth[n]
            if n in guard:
                return 0
            best = 0
            for p in g.prev.get(n, ()):
                if p in mine:
                    best = max(best, 1 + d(p, guard | {n}))
            depth[n] = best
            return best

        for n in comp:
            d(n, frozenset())
        chains.append({
            "nodes": sorted(comp, key=lambda n: (depth[n], n)),
            "depth": {n: depth[n] for n in comp},
            "edges": [e for e in edges if e[0] in set(comp) and e[1] in set(comp)],
            "score": max(mine[n]["score"] for n in comp),
        })
    chains.sort(key=lambda ch: (-ch["score"], -len(ch["nodes"])))
    singles = [q["qid"] for q in quests if q["qid"] not in adj]
    return {"area": area, "quests": quests, "edges": edges,
            "chains": chains, "singles": singles}


def flag_table(c):
    counts = c.flag_counts()
    actionable = {k for k, _ in ACTIONABLE_FLAGS}
    return sorted(
        ({"flag": k, "count": v, "actionable": k in actionable}
         for k, v in counts.items()),
        key=lambda r: (-r["count"], r["flag"]))


def search(c, q, limit=80):
    """Title, DAT name, start NPC, flag, or a qid. One box, because a human
    arriving from a wrong marker has a name and nothing else."""
    q = (q or "").strip().lower()
    if not q:
        return []
    out = []
    for qid, rec in c.by_qid.items():
        src = rec.get("source") or {}
        ident = rec.get("identity") or {}
        start = (rec.get("start") or {}).get("npc") or ""
        hay = " ".join([
            qid, src.get("wiki_title") or "", ident.get("dat_name") or "",
            start, " ".join(rec.get("review_flags") or []),
        ]).lower()
        if q in hay:
            npcs = {s["target"]["name"] for s in rec["steps"]
                    if (s.get("target") or {}).get("name")}
            out.append({
                "qid": qid,
                "title": src.get("wiki_title"),
                "dat_name": ident.get("dat_name"),
                "start": start,
                "confidence": rec.get("confidence"),
                "steps": len(rec["steps"]),
                "flags": rec.get("review_flags") or [],
                "human": bool(rec.get("human")),
                "matched_npc": q in " ".join(npcs).lower(),
            })
    #[[ Exact title first: somebody typing a full quest name wants that quest,
    #   not the twenty whose notes happen to mention it. ]]
    out.sort(key=lambda r: (0 if (r["title"] or "").lower() == q else 1,
                            0 if q in (r["title"] or "").lower() else 1,
                            r["title"] or ""))
    return out[:limit]


def graph_report(g):
    r = g.report()
    r.pop("depths", None)                 # 1537 entries nobody reads at once
    return r
