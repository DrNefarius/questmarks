"""questgraph -- a visualisation and correction tool for the questmarks data.

    python tools/questgraph/qg.py                 serve on 127.0.0.1:8787
    python tools/questgraph/qg.py --port 9000
    python tools/questgraph/qg.py report          the triage, as text
    python tools/questgraph/qg.py coverage        the observability numbers
    python tools/questgraph/qg.py graph           the DAG analysis, as text
    python tools/questgraph/qg.py why <file>      parse a //qm why block
    python tools/questgraph/qg.py verify          run the whole build + suite

This is a separate program from the addon. It lives under tools/ because that
is where the build-time tools live and because every path it needs is relative
to the addon root. tools/ ships with nothing, is excluded from
test_standalone.lua's SHIPPED set and from check.lua's tree, and no shipped
file may ever require anything in here.

It binds to loopback only and it is not authenticated. It can write to
build/authored/, so it must not be reachable off this machine.

Build-time only.
"""

import argparse
import glob
import io
import json
import os
import subprocess
import sys
import threading
import webbrowser

HERE = os.path.dirname(os.path.abspath(__file__))
if HERE not in sys.path:
    sys.path.insert(0, HERE)

from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from urllib.parse import urlparse, parse_qs, unquote

import corpus as C
import edits
import entities as E
import gates
import graph as G
import playlog
import triage

WEB = os.path.join(HERE, "web")

LUAJIT = C.LUAJIT


# ------------------------------------------------------------------ corpus

class Live(object):
    """The corpus, reloaded when build/authored/ changes underneath us.

    It does change underneath us: the pipeline's own agents write to
    build/authored/ too. Holding a snapshot for the life of the process would
    show a human stale reasoning and let them "correct" something that had
    already been corrected.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._c = None
        self._stamp = None
        self._graph = None
        self._sig = None

    def _current_stamp(self):
        out = []
        for p in sorted(glob.glob(os.path.join(C.AUTHORED, "*.json"))):
            out.append((os.path.basename(p), os.path.getmtime(p),
                        os.path.getsize(p)))
        for p in (C.VALIDATED, os.path.join(C.ADDON, "data", "quest_index.lua")):
            out.append((p, os.path.getmtime(p) if os.path.exists(p) else 0, 0))
        return tuple(out)

    def get(self):
        with self._lock:
            stamp = self._current_stamp()
            if self._c is None or stamp != self._stamp:
                self._c = C.Corpus()
                self._graph = None
                self._sig = None
                self._stamp = stamp
            return self._c

    def signals(self):
        #[[ Derived from all 1003 quests, so it is computed once per corpus
        #   reload rather than once per request. The quest view needs one entry
        #   from it; the map view needs all of them. ]]
        c = self.get()
        with self._lock:
            if self._sig is None:
                self._sig = triage.quest_signals(c)
            return self._sig

    def graph(self):
        c = self.get()
        with self._lock:
            if self._graph is None:
                self._graph = G.Graph(c.index)
            return self._graph

    def invalidate(self):
        with self._lock:
            self._stamp = None


LIVE = Live()


class Lookups(object):
    """The wikilink evidence and the res name index, both built lazily once.

    Lazily because the harvest is ~1.6 s cold and the triage view does not need
    it: only the editor does. Cached to disk after that, so a restart is
    ~0.1 s.
    """

    def __init__(self):
        self._lock = threading.Lock()
        self._ent = None
        self._pick = None

    def entities(self):
        with self._lock:
            if self._ent is None:
                self._ent = E.Entities()
            return self._ent

    def picks(self):
        with self._lock:
            if self._pick is None:
                self._pick = E.Picks()
            return self._pick


LOOK = Lookups()


# -------------------------------------------------------------- quest view

def ladder_view(q, row, index_rows):
    """One row per step, with every layer beside every other.

    This is the answer to "why does the data say this?". Read across, not down:
    the authored step, the validated step it became, and whether it can carry a
    marker at all.
    """
    out = []
    vsteps = {s["n"]: s for s in (row or {}).get("steps", [])}
    for s in q["steps"]:
        v = vsteps.get(s["n"]) or {}
        t = s.get("target") or {}
        ev = s.get("evidence") or {}
        name = t.get("name")
        placeholder = (name or "").strip().lower() in C.PLACEHOLDERS
        #[[ markable() accepts an NPC key OR monsters. Testing s.npc alone
        #   keeps 49 of 54 monster rows from ever drawing. ]]
        markable = bool(v.get("npc")) or bool(v.get("mobs"))
        out.append({
            "n": s["n"],
            "kind": s["kind"],
            "target_type": t.get("type"),
            "target": name,
            "zone": s.get("zone"),
            "grid": s.get("grid"),
            "group": s.get("group"),
            "optional": bool(s.get("optional")),
            "confidence": s.get("confidence"),
            "note": s.get("note"),
            "source_bullets": s.get("source_bullets") or [],
            "items": s.get("items") or [],
            "items_alt": s.get("items_alt") or [],
            "items_partial": bool(s.get("items_partial")),
            "evidence": ev.get("all") or [],
            "evidence_alt": ev.get("alt") or [],
            "mobs": s.get("mobs") or [],
            # ---- what survived resolution
            "v_npc": v.get("npc"),
            "v_zone": v.get("z"),
            "v_reqs": v.get("reqs") or [],
            "v_reqs_alt": v.get("reqs_alt") or [],
            "v_ev": v.get("ev") or [],
            "v_ev_alt": v.get("ev_alt") or [],
            "v_mobs": v.get("mobs") or [],
            "markable": markable,
            "placeholder": placeholder,
            #[[ Named for what it is: the reading found a target, resolution
            #   did not, and it is NOT the by-design placeholder case. That is
            #   a lost marker and the single most actionable row here. ]]
            "target_lost": bool(name) and not v.get("npc") and not placeholder,
            "zone_lost": bool(s.get("zone")) and v.get("z") is None,
        })
    return out


def positions(ladder):
    """The ladder as the player experiences it: RUNGS, not steps.

    Three transformations, each of them a measured fact about the data rather
    than a presentation preference:

    1. A `group` is ONE rung with N members. 668 steps belong to a group, and
       `Lure of the Wildcat` is 22 steps of which 20 are a single group visited
       in any order, all of them drawn at once by the addon. Rendering that as
       a 22-long chain is not a simplification, it is a false statement about
       what the player has to do.

    2. `optional` steps are not part of the spine. 194 of them: a cutscene you
       may watch, a precondition, an extra reward. Inline they read as work you
       must do.

    3. A zone change is the interesting transition. It is where the marker
       goes quiet and where a reader's mistake shows. Rungs are banded by zone
       so a hop is visible without any extra ink.

    Group members keep their own zone: one step, one zone, always. A group whose
    members span zones therefore lands in the band of its first member and says
    how many others it touches.
    """
    rungs = []
    for s in ladder:
        if s["optional"]:
            #[[ Attached to the rung before it, or to the first if it leads. ]]
            if rungs:
                rungs[-1]["spurs"].append(s)
            else:
                rungs.append({"kind": "spur-lead", "zone": s["zone"],
                              "members": [], "spurs": [s], "group": None})
            continue
        g = s["group"]
        if g is not None and rungs and rungs[-1]["group"] == g:
            rungs[-1]["members"].append(s)
            continue
        rungs.append({"group": g, "zone": s["zone"], "members": [s],
                      "spurs": [], "kind": None})

    out = []
    for i, r in enumerate(rungs):
        zs = [m["zone"] for m in r["members"] if m["zone"]]
        out.append({
            "i": i + 1,
            "group": r["group"],
            "zone": r["zone"] or (zs[0] if zs else None),
            "zones_touched": len(set(zs)),
            "members": r["members"],
            "spurs": r["spurs"],
            "parallel": len(r["members"]) > 1,
            "markable": any(m["markable"] for m in r["members"]),
            "evidence": any(m["evidence"] or m["evidence_alt"]
                            for m in r["members"]),
            "needs": any(m["items"] or m["items_alt"] for m in r["members"]),
            "mobs": [x for m in r["members"] for x in m["mobs"]],
            "problem": any(m["target_lost"] or m["zone_lost"]
                           for m in r["members"]),
        })
    #[[ A band is a maximal run of rungs in one zone. Computed here rather than
    #   in the browser so the two views cannot disagree about where a hop is. ]]
    bands = []
    for r in out:
        if bands and bands[-1]["zone"] == r["zone"]:
            bands[-1]["rungs"].append(r["i"])
        else:
            bands.append({"zone": r["zone"], "rungs": [r["i"]]})
    return out, bands


def zone_chain(steps):
    """The ladder as a sequence of zone hops.

    `Waking the Colossus` is 14 steps across 6 zones; a flat list of 14 rows
    hides that entirely, and crossing a zone is the thing that makes a stale
    marker expensive rather than merely wrong.
    """
    chain = []
    for s in steps:
        z = s.get("zone")
        if not chain or chain[-1]["zone"] != z:
            chain.append({"zone": z, "steps": [s["n"]]})
        else:
            chain[-1]["steps"].append(s["n"])
    return chain


def quest_payload(c, qid, want_page=True):
    q = c.by_qid.get(qid)
    if q is None:
        return None
    row = c.validated.get(qid)
    index_rows = c.index_by_qid.get(qid) or []
    quarantine = [r for r in c.quarantine if r["quest"] == qid]
    page = c.rendered_text(q) if want_page else None
    g = LIVE.graph()
    ladder = ladder_view(q, row, index_rows)
    rungs, bands = positions(ladder)
    return {
        "qid": qid,
        "authored": q,
        "validated": row,
        "index": index_rows,
        "quarantine": quarantine,
        "ladder": ladder,
        "rungs": rungs,
        "bands": bands,
        #[[ The editor's pickers key on this: candidates are what THIS quest's
        #   own cached page links, matched on page_id. `source.cache_file`
        #   omits the content hash the filenames carry, so it is the wrong
        #   key. ]]
        "page_id": (q.get("source") or {}).get("page_id"),
        #[[ Carried on the QUEST payload, not only on the landing page. A stale
        #   index is invisible exactly where it matters: you are looking at the
        #   record you just corrected, and the game is still loading the
        #   version from before it. ]]
        "freshness": c.freshness(),
        "signal": LIVE.signals().get(qid),
        "zone_chain": zone_chain(q["steps"]),
        "page": page,
        "page_path": (C.relpath(c.rendered_path(q))
                      if c.rendered_path(q) else None),
        "file": "build/authored/" + c.loc[qid][0],
        "neighbourhood": g.neighbourhood(qid) if qid in g.nodes else None,
        "human": q.get("human"),
    }


# ------------------------------------------------------------------ server

class Handler(BaseHTTPRequestHandler):
    server_version = "questgraph"

    def log_message(self, fmt, *args):
        pass                                  # the console is for the build

    # -- helpers ---------------------------------------------------------
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        if isinstance(body, (dict, list)):
            body = json.dumps(body, ensure_ascii=False).encode("utf-8")
        elif isinstance(body, str):
            body = body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        try:
            self.wfile.write(body)
        except (BrokenPipeError, ConnectionAbortedError):
            pass

    def _body(self):
        n = int(self.headers.get("Content-Length") or 0)
        return json.loads(self.rfile.read(n).decode("utf-8")) if n else {}

    def _static(self, name):
        path = os.path.join(WEB, name)
        if not os.path.abspath(path).startswith(os.path.abspath(WEB)) \
                or not os.path.exists(path):
            return self._send(404, {"error": "not found"})
        ctype = ("text/html; charset=utf-8" if name.endswith(".html")
                 else "application/javascript; charset=utf-8"
                 if name.endswith(".js")
                 else "text/css; charset=utf-8" if name.endswith(".css")
                 else "application/octet-stream")
        with io.open(path, "rb") as f:
            self._send(200, f.read(), ctype)

    # -- routes ----------------------------------------------------------
    def do_GET(self):
        u = urlparse(self.path)
        p, qs = u.path, parse_qs(u.query)
        try:
            if p == "/":
                return self._static("index.html")
            if p.startswith("/static/"):
                return self._static(p[len("/static/"):])

            c = LIVE.get()

            if p == "/api/stats":
                return self._send(200, c.stats())
            if p == "/api/triage":
                return self._send(200, triage.build(c, LIVE.graph()))
            if p == "/api/areas":
                return self._send(200, {"areas": triage.areas(c, LIVE.signals()),
                                        "stats": c.stats()})
            if p.startswith("/api/area/"):
                return self._send(200, triage.area_detail(
                    c, LIVE.graph(), unquote(p[len("/api/area/"):]),
                    LIVE.signals()))
            if p == "/api/flags":
                return self._send(200, triage.flag_table(c))
            if p == "/api/search":
                return self._send(200, triage.search(c, qs.get("q", [""])[0],
                                                     int(qs.get("n", ["80"])[0])))
            if p.startswith("/api/quest/"):
                qid = unquote(p[len("/api/quest/"):])
                payload = quest_payload(c, qid)
                if payload is None:
                    return self._send(404, {"error": "no authored record",
                                            "qid": qid,
                                            "index": c.index_by_qid.get(qid)})
                return self._send(200, payload)
            if p == "/api/graph":
                return self._send(200, triage.graph_report(LIVE.graph()))
            if p.startswith("/api/graph/"):
                qid = unquote(p[len("/api/graph/"):])
                g = LIVE.graph()
                if qid not in g.nodes:
                    return self._send(404, {"error": "not in the index"})
                return self._send(200, g.neighbourhood(qid))
            if p == "/api/play":
                text = playlog.read_log()
                if text is None:
                    return self._send(200, {"error": "questmarks.log not found",
                                            "entries": [], "boots": []})
                parsed = playlog.parse(text)
                return self._send(200, {"boots": parsed["boots"],
                                        "entries": playlog.summarise(parsed, c),
                                        "blocks": parsed["blocks"]})
            if p == "/api/ledger":
                return self._send(200, edits.ledger())
            if p == "/api/resolve":
                return self._send(200, resolve_probe(
                    qs.get("kind", ["npc"])[0], qs.get("name", [""])[0],
                    qs.get("area", [None])[0]))

            #[[ Prefix search over res/, for the item / key item / zone
            #   pickers. Nobody types a resource id: 17742 is not something a
            #   human should ever see, let alone enter. ]]
            if p == "/api/pick":
                return self._send(200, LOOK.picks().search(
                    qs.get("kind", ["item"])[0], qs.get("q", [""])[0],
                    int(qs.get("n", ["30"])[0])))

            #[[ Candidates for an NPC / object / monster field, drawn from what
            #   THIS quest's own cached page links. There is no entity table in
            #   res/, so the wiki cache is the only offline evidence there is,
            #   and it is the same source the reading pass read. ]]
            if p == "/api/entities":
                pid = int(qs.get("page_id", ["0"])[0] or 0)
                return self._send(200, LOOK.entities().suggest(
                    pid, qs.get("q", [""])[0],
                    int(qs.get("n", ["40"])[0]),
                    qs.get("type", ["npc"])[0],
                    qs.get("demote", [])))

            if p == "/api/entity_tier":
                pid = int(qs.get("page_id", ["0"])[0] or 0)
                tier, why = LOOK.entities().tier(
                    qs.get("name", [""])[0], pid, qs.get("type", ["npc"])[0])
                return self._send(200, {"tier": tier, "why": why})
            return self._send(404, {"error": "no such route", "path": p})
        except Exception as e:
            import traceback
            return self._send(500, {"error": str(e),
                                    "traceback": traceback.format_exc()})

    def do_POST(self):
        u = urlparse(self.path)
        try:
            body = self._body()
            c = LIVE.get()

            if u.path == "/api/preview":
                e = edits.Edit(c, body["qid"], body["record"],
                               body.get("basis", "reading"),
                               body.get("reason", ""), body.get("author", ""))
                return self._send(200, e.preview())

            if u.path == "/api/commit":
                try:
                    e = edits.Edit(c, body["qid"], body["record"],
                                   body.get("basis", "reading"),
                                   body.get("reason", ""), body.get("author", ""),
                                   body.get("ack_marker_removal", False))
                    entry = e.commit()
                except edits.Refused as r:
                    return self._send(409, {"refused": str(r)})
                LIVE.invalidate()
                out = {"ok": True, "entry": entry}
                #[[ The rebuild is part of the commit, not a thing the UI has
                #   to remember to offer.
                #
                #   The addon reads data/quest_index.lua and never
                #   build/authored/, so a correction that is written but not
                #   compiled has changed nothing the game will ever see. A
                #   front-end affordance is not enough: a banner offering the
                #   rebuild is one re-render away from being destroyed before
                #   anyone clicks it, and the index then sits behind the
                #   reasoning with nothing on screen saying so.
                #
                #   Doing it server-side means no front-end mistake can lose
                #   it. The write still happens first and independently:
                #   build/authored/ is the source of truth and must be saved
                #   even if a later stage fails. ]]
                if body.get("build", True):
                    out["build"] = run_build(False)
                return self._send(200, out)

            if u.path == "/api/revert":
                try:
                    out = edits.revert(body["entry"], body.get("force", False))
                except edits.Refused as r:
                    return self._send(409, {"refused": str(r)})
                LIVE.invalidate()
                return self._send(200, out)

            if u.path == "/api/play/parse":
                parsed = playlog.parse(body.get("text", ""))
                return self._send(200, {"boots": parsed["boots"],
                                        "entries": playlog.summarise(parsed, c),
                                        "blocks": parsed["blocks"]})

            if u.path == "/api/build":
                return self._send(200, run_build(body.get("full", False)))

            return self._send(404, {"error": "no such route"})
        except edits.Refused as r:
            return self._send(409, {"refused": str(r)})
        except Exception as e:
            import traceback
            return self._send(500, {"error": str(e),
                                    "traceback": traceback.format_exc()})


# ------------------------------------------------------------------- build

BUILD_STEPS = [
    ("validate", [sys.executable, "tools/pipeline/validate.py"]),
    ("emit", [sys.executable, "tools/pipeline/emit_lua.py"]),
    ("index", [LUAJIT, "tools/build_index.lua", "--all-areas"]),
]
SUITE = [
    ("check", [LUAJIT, "tools/check.lua"]),
    ("test_project", [LUAJIT, "tools/test_project.lua"]),
    ("test_state", [LUAJIT, "tools/test_state.lua"]),
    ("test_core", [LUAJIT, "tools/test_core.lua"]),
    ("test_standalone", [LUAJIT, "tools/test_standalone.lua"]),
    ("smoke", [LUAJIT, "tools/smoke.lua"]),
]


def run_build(full=False):
    """Rebuild, and optionally run the whole suite. Stops at the first failure.

    Stopping matters. build_index.lua writes data/quest_index.lua
    incrementally, so a later stage that fails after an earlier one has written
    leaves a truncated index sitting behind a success line.
    """
    out = []
    for name, cmd in BUILD_STEPS + (SUITE if full else []):
        if not os.path.exists(cmd[0]) and cmd[0] != sys.executable:
            out.append({"step": name, "rc": -1,
                        "out": "not found: %s" % cmd[0]})
            break
        proc = subprocess.Popen(cmd, cwd=C.ADDON, stdout=subprocess.PIPE,
                                stderr=subprocess.STDOUT)
        text = proc.communicate()[0].decode("utf-8", "replace")
        out.append({"step": name, "rc": proc.returncode, "out": text})
        if proc.returncode != 0 or " 0 failed" not in text and name.startswith("test") \
                and "0 failed" not in text:
            if proc.returncode != 0:
                break
    LIVE.invalidate()
    return {"steps": out,
            "ok": all(s["rc"] == 0 for s in out)}


def resolve_probe(kind, name, area=None):
    """The same resolver the runtime uses. Never a second implementation."""
    if not name:
        return {"error": "no name"}
    res = gates._validate.resolve_batch(
        [{"kind": kind, "name": name, "area": area}])
    for v in res.values():
        return v
    return {"id": None}


# ---------------------------------------------------------------- coverage

#[[ The observability numbers, and the two units they come in.
#
#   The README's Coverage section is the consumer, and it is the reason this
#   exists at all: without a CLI path for
#   `corpus.coverage()` and `corpus.stats()["coverage_shipped"]`, the only way
#   to see them is the JSON that `python tools/questgraph/corpus.py` prints.
#
#   The numbers come in two units, and README mixes both inside one paragraph
#   without naming either:
#
#     steps      one row per ladder step.                        5061 of them.
#     positions  consecutive steps sharing a `group` folded to
#                ONE rung, because the addon draws a 20-NPC
#                wildcat group all at once.                      4534 of them.
#
#   "1032 of 5061 steps carry evidence" is steps; "the longest such stretch is
#   14" three lines later is positions. A bare number here that a reader can
#   carry across that boundary invites exactly that mistake. So every number
#   printed below carries the word `steps`, `positions` or `quests`, and every
#   percentage names its denominator. ]]

COVERAGE_LAYERS = (
    ("SHIPPED", "validated",
     "build/validated/quests.json -- what the addon can actually see"),
    ("READ", "authored",
     "build/authored/*.json -- what the reading found on the page"),
)


def step_rows(c, layer):
    """(group, has_evidence, has_requirement) per step, per quest, one layer.

    The SAME predicate `Corpus.coverage()` in corpus.py applies: evidence is
    `ev` or `ev_alt`, a requirement is `reqs` or `reqs_alt`, and on the
    authored side `evidence.all`/`evidence.alt` and `items`/`items_alt`.

    Duplicated here for one reason only: coverage() folds groups away before
    anything can count raw steps, and README quotes raw steps. `collapse_drift`
    below re-folds these rows and compares against coverage(), so the copy
    cannot quietly diverge from the original. It is a second reader of one
    rule, not a second rule.
    """
    rows = []
    if layer == "validated":
        for v in c.validated.values():
            rows.append([(s.get("group"),
                          bool(s.get("ev") or s.get("ev_alt")),
                          bool(s.get("reqs") or s.get("reqs_alt")))
                         for s in v["steps"]])
    else:
        for q in c.quests:
            out = []
            for s in q["steps"]:
                e = s.get("evidence") or {}
                out.append((s.get("group"),
                            bool(e.get("all") or e.get("alt")),
                            bool(s.get("items") or s.get("items_alt"))))
            rows.append(out)
    return rows


def raw_steps(rows):
    """Counts in raw steps, with groups NOT collapsed. README's unit for two
    of its six figures, and the one `corpus.coverage()` cannot express."""
    total = ev = readable = 0
    for steps in rows:
        for _, has_ev, has_req in steps:
            total += 1
            if has_ev:
                ev += 1
            if has_ev or has_req:
                readable += 1
    return {"steps": total, "steps_with_evidence": ev,
            "steps_readable": readable}


def collapse_drift(rows, cov):
    """Re-fold `rows` the corpus way and report any disagreement.

    This is the guard that lets `step_rows` exist. If corpus.coverage() ever
    changes which fields count as evidence, the raw-step counts above would go
    on answering the old question in silence, and the lead would regenerate
    README from two different definitions. A mismatch is printed, loudly, in
    the report itself rather than raised, because the rest of the numbers are
    still worth seeing.
    """
    positions = ev = 0
    for steps in rows:
        collapsed = []
        for grp, has_ev, has_req in steps:
            if grp is not None and collapsed and collapsed[-1][0] == grp:
                p = collapsed[-1]
                collapsed[-1] = (grp, p[1] or has_ev, p[2] or has_req)
            else:
                collapsed.append((grp, has_ev, has_req))
        positions += len(collapsed)
        ev += sum(1 for x in collapsed if x[1])
    bad = []
    if positions != cov["positions"]:
        bad.append("positions %d != corpus.coverage() %d"
                   % (positions, cov["positions"]))
    if ev != cov["positions_with_evidence"]:
        bad.append("positions_with_evidence %d != corpus.coverage() %d"
                   % (ev, cov["positions_with_evidence"]))
    return bad


def pct(n, d, unit):
    return "n/a" if not d else "%.1f%% of %d %s" % (100.0 * n / d, d, unit)


def coverage_lines(c):
    """The block `report` and `coverage` both print. One text, one truth."""
    out = []
    got = {}
    for title, layer, what in COVERAGE_LAYERS:
        cov = c.coverage(layer)
        rows = step_rows(c, layer)
        raw = raw_steps(rows)
        got[layer] = (cov, raw)
        drift = collapse_drift(rows, cov)
        q, st_, po = cov["quests"], raw["steps"], cov["positions"]
        out.append("  coverage -- %s   (%s)" % (title, what))
        out.append("    ladders                              %5d quests" % q)
        out.append("    raw steps -- one row per step, groups NOT collapsed")
        out.append("      total                              %5d steps" % st_)
        out.append("      carrying observable evidence       %5d steps   %s"
                   % (raw["steps_with_evidence"],
                      pct(raw["steps_with_evidence"], st_, "steps")))
        out.append("      readable (evidence or requirement) %5d steps   %s"
                   % (raw["steps_readable"],
                      pct(raw["steps_readable"], st_, "steps")))
        out.append("    positions -- consecutive steps sharing a `group` "
                   "folded to ONE")
        out.append("      total                              %5d positions" % po)
        out.append("      carrying observable evidence       %5d positions   %s"
                   % (cov["positions_with_evidence"],
                      pct(cov["positions_with_evidence"], po, "positions")))
        out.append("      readable (evidence or requirement) %5d positions   %s"
                   % (cov["positions_readable"],
                      pct(cov["positions_readable"], po, "positions")))
        out.append("    per quest")
        out.append("      no observable evidence anywhere    %5d quests   %s"
                   % (cov["quests_no_evidence"],
                      pct(cov["quests_no_evidence"], q, "quests")))
        out.append("      a dark stretch of 2+ POSITIONS     %5d quests   %s"
                   % (cov["quests_with_2plus_stretch"],
                      pct(cov["quests_with_2plus_stretch"], q, "quests")))
        out.append("      final position readable            %5d quests   %s"
                   % (cov["quests_final_readable"],
                      pct(cov["quests_final_readable"], q, "quests")))
        #[[ Spelled out because this is the number README states in a sentence
        #   about steps: "the longest such stretch is 14". It is positions. ]]
        out.append("    longest dark stretch                 %5d positions   "
                   "(POSITIONS, not steps)" % cov["longest_stretch"])
        for d in drift:
            out.append("    !! DRIFT from corpus.coverage(): %s" % d)
        out.append("")

    (sh, shraw) = got["validated"]
    (rd, rdraw) = got["authored"]
    #[[ Evidence a reader found on the page and the resolver then lost. Nothing
    #   else reports it: validate.py counts what survived and README quotes the
    #   survivor. Printed in both units so neither can be quoted as the other. ]]
    out.append("  evidence lost to name resolution (READ minus SHIPPED)")
    out.append("      %5d steps       %5d positions"
               % (rdraw["steps_with_evidence"] - shraw["steps_with_evidence"],
                  rd["positions_with_evidence"] - sh["positions_with_evidence"]))
    out.append("")
    out.append("  UNITS: `steps` are raw ladder rows; `positions` fold a group "
               "to one rung;")
    out.append("         `quests` are ladders. README's \"What that feels "
               "like, honestly\" quotes some")
    out.append("         of each -- never carry a number across units. "
               "The same figures as JSON: "
               "`python tools/questgraph/corpus.py`")
    out.append("         (keys coverage_shipped / coverage_read).")
    return out


# --------------------------------------------------------------------- CLI

def cmd_report(args):
    c = LIVE.get()
    t = triage.build(c, LIVE.graph())
    st = c.stats()
    #[[ Say "authored steps", not just "steps". This is the raw step count and
    #   the coverage block below prints positions beside it: two numbers over
    #   the same ladders, so each has to name its unit. ]]
    print("questgraph -- %d authored quests in %d files, %d authored steps"
          % (st["quests"], st["files"], st["steps"]))
    print("  tiers          full=%d assisted=%d start-only=%d"
          % (st["validated_tiers"]["full"], st["validated_tiers"]["assisted"],
             st["validated_tiers"]["start_only"]))
    print("  human-edited   %d" % st["human_edited"])
    #[[ The shipped index, in rows. This is the command that prints the ladder
    #   count and the remainder, so the prose that states them elsewhere can be
    #   re-derived rather than guessed at. `index_ladders_applied` is
    #   build_index.lua's own `meta.steps`: rows carrying a real, first-hand
    #   ladder. ]]
    nq = st["index_quests"]
    nl = st["index_ladders_applied"] or 0
    print("  index          %d quest rows, %d mission rows" % (nq, st["index_missions"]))
    print("                 %d quest rows carry a first-hand ladder, "
          "%d do not" % (nl, nq - nl))
    print()
    for line in coverage_lines(c):
        print(line)
    #[[ The coverage block and the triage bucket below it both count quests
    #   with no observable evidence, and they do NOT agree: triage's
    #   coverage_rows() drops a quest whose validated ladder is empty and
    #   corpus.coverage() keeps it. One quest, quest/crystal_war/98,
    #   which has zero validated steps. Two numbers a line apart with no
    #   explanation is how a reader stops trusting the whole page, so the gap
    #   is reconciled here rather than left to be noticed. Computed, not
    #   asserted: if the gap changes, the sentence changes. ]]
    dark = next((b for b in t["buckets"] if b["key"] == "cov:no_evidence"), None)
    n_dark = st["coverage_shipped"]["quests_no_evidence"]
    gap = (n_dark - dark["count"]) if dark else 0
    if gap:
        print("  NOTE the bucket below counts %d, the coverage block above %d: "
              "%d quest(s)" % (dark["count"], n_dark, gap))
        print("       carry an EMPTY validated ladder, which "
              "triage.coverage_rows drops and coverage() keeps.")
        print()
    for b in t["buckets"]:
        print("  %-34s %5d   %s" % (b["title"], b["count"], b["why"]))
    print()
    print("  (%d quarantine rows are placeholder_target and are BY DESIGN)"
          % st["quarantine"].get("placeholder_target", 0))


def cmd_coverage(args):
    """`report` without the triage, for when the numbers are all you want.

    `report` builds the triage and the prev DAG to print its buckets; this
    needs neither, so it is the cheap way to re-measure the README's Coverage
    section.
    """
    for line in coverage_lines(LIVE.get()):
        print(line)


def cmd_graph(args):
    r = triage.graph_report(LIVE.graph())
    print("prev DAG: %d nodes, %d edges, %d roots, max depth %d"
          % (r["nodes"], r["edges"], r["roots"], r["max_depth"]))
    print("  cycles                      %d" % len(r["cycles"]))
    for cy in r["cycles"]:
        print("     " + " -> ".join(cy))
    print("  unreachable behind a cycle  %d" % len(r["unreachable"]))
    print("  prev naming an entry the index does not hold:")
    print("     unresolved by the builder  %d" % len(r["out_of_index"]["unresolved"]))
    print("     resolved but not indexed   %d   (NOT breakage -- prereq reads"
          " the game's bitfield, not the index)"
          % len(r["out_of_index"]["not_indexed"]))
    print("  quest <-> mission edges     %d" % len(r["cross_category"]))
    for a, b in r["cross_category"]:
        print("     %s needs %s" % (a, b))
    print("  duplicate index records     %d" % len(r["duplicate_records"]))


def cmd_why(args):
    with io.open(args.file, encoding="utf-8", errors="replace") as f:
        text = f.read()
    c = LIVE.get()
    parsed = playlog.parse(text)
    for b in parsed["boots"]:
        print("boot %s  version %s  entries %s  ladders %s%s"
              % (b["at"], b["version"], b["entries"], b["ladders"],
                 "" if b["stamped"] else "   (predates the version stamp)"))
    for r in playlog.summarise(parsed, c):
        print("  %-24s %-38s %s%s"
              % (r["qid"], (r["name"] or "")[:36], r["state"] or "",
                 "" if r["authored"] else "   [NO AUTHORED RECORD]"))


def cmd_verify(args):
    res = run_build(full=True)
    for s in res["steps"]:
        tail = [l for l in s["out"].strip().splitlines() if l.strip()][-3:]
        print("=== %s  rc=%d" % (s["step"], s["rc"]))
        for l in tail:
            print("    " + l)
    print("\n%s" % ("ALL GREEN" if res["ok"] else "FAILED"))
    return 0 if res["ok"] else 1


def cmd_serve(args):
    srv = ThreadingHTTPServer(("127.0.0.1", args.port), Handler)
    url = "http://127.0.0.1:%d/" % args.port
    print("questgraph on %s   (loopback only; Ctrl-C to stop)" % url)
    c = LIVE.get()
    st = c.stats()
    print("  %d authored quests, %d human-edited, %d real quarantine rows"
          % (st["quests"], st["human_edited"], st["quarantine_real"]))
    for e in st["errors"]:
        print("  ! %s" % e)
    if not args.no_browser:
        threading.Timer(0.5, lambda: webbrowser.open(url)).start()
    try:
        srv.serve_forever()
    except KeyboardInterrupt:
        print("\nstopped")
    return 0


def main():
    ap = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    sub = ap.add_subparsers(dest="cmd")
    s = sub.add_parser("serve")
    s.add_argument("--port", type=int, default=8787)
    s.add_argument("--no-browser", action="store_true")
    s.set_defaults(fn=cmd_serve)
    sub.add_parser("report").set_defaults(fn=cmd_report)
    sub.add_parser("coverage").set_defaults(fn=cmd_coverage)
    sub.add_parser("graph").set_defaults(fn=cmd_graph)
    w = sub.add_parser("why")
    w.add_argument("file", nargs="?", default=playlog.LOG)
    w.set_defaults(fn=cmd_why)
    sub.add_parser("verify").set_defaults(fn=cmd_verify)
    ap.add_argument("--port", type=int, default=8787)
    ap.add_argument("--no-browser", action="store_true")
    args = ap.parse_args()
    if not getattr(args, "fn", None):
        args.fn = cmd_serve
    return args.fn(args) or 0


if __name__ == "__main__":
    sys.exit(main())
