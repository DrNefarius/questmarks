"""Load every layer of the questmarks pipeline at once, and keep them joined.

The editor's whole job is to answer "why does the data say this?", and that
question spans four layers that are normally only ever seen one at a time:

    build/rendered/*.md          what the wiki actually says      (evidence)
    build/authored/*.json        what a reader made of it         (reasoning)
    build/validated/quests.json  what survived name resolution    (facts)
    data/quest_index.lua         what the addon actually loads    (shipped)

Nothing here writes. `edits.py` owns the only write path in this tool.

Build-time only.
"""

import glob
import hashlib
import io
import json
import os
import re
import subprocess
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, "..", ".."))

LUAJIT = os.path.expandvars(
    r"%LOCALAPPDATA%\Programs\LuaJIT\LuaJIT\bin\luajit.exe")

AUTHORED = os.path.join(ADDON, "build", "authored")
RENDERED = os.path.join(ADDON, "build", "rendered")
VALIDATED = os.path.join(ADDON, "build", "validated", "quests.json")
QUARANTINE = os.path.join(ADDON, "build", "reports", "validate.jsonl")
CACHE = os.path.join(HERE, "cache")

#[[ The files this tool must NEVER write. Each is regenerated from something
#   above it, so the next build destroys a hand edit here. It does so
#   silently, with no way to tell afterwards that it ever happened.
#   `edits.py` enforces this list; it is not documentation. ]]
GENERATED = (
    os.path.join("data", "quest_index.lua"),
    os.path.join("data", "mission_index.lua"),
    os.path.join("data", "quest_steps.lua"),
    os.path.join("data", "dat_names.lua"),
    os.path.join("build", "validated", "quests.json"),
    os.path.join("build", "res.json"),
)

KINDS = ("talk", "trade", "turnin", "examine", "fight", "travel", "obtain",
         "wait", "cutscene", "other")
TARGET_TYPES = ("npc", "object", "zone", "none")
CONFIDENCE = ("high", "medium", "low")

#[[ Every key is required on every object and every step. Explicit `null` is a
#   positive assertion: it says "I read the page and there is nothing here".
#   An omitted key is indistinguishable from a truncated response, so absence
#   is an error and never a default. ]]
QUEST_KEYS = ("schema", "source", "identity", "extraction", "confidence",
              "review_flags", "notes", "gates", "start", "steps")
STEP_KEYS = ("n", "kind", "target", "zone", "grid", "items", "items_alt",
             "items_partial", "evidence", "mobs", "group", "optional",
             "confidence", "note", "source_bullets")

#[[ The placeholder family. validate.py quarantines these as
#   `placeholder_target` rather than `npc_unresolved` because they are the
#   INTENDED outcome: the step keeps its rung and loses only its marker.
#   340 of 356 quarantine rows are these, and a report where 95% of the rows
#   are the intended outcome is not a signal. Kept in sync with the same
#   tuple inside validate.py's `validate()`; grep for `blank spot`. ]]
PLACEHOLDERS = ("???", "blank target", "blank spot", "none",
                "full moon fountain", "glowing hearth")


def qid_of(identity):
    return "%s/%s/%s" % (identity["cat"], identity["area"], identity["id"])


def sha256_text(s):
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


class AuthoredFile(object):
    """One build/authored/*.json, held as text AND as parsed records.

    The text matters. A diff is the review a correction gets, and a writer that
    reformats the file turns a one-line correction into a 400-line diff nobody
    will read. All 179 files round-trip byte-identically through
    `json.dumps(d, ensure_ascii=False, indent=1)`; 49 of them carry a trailing
    newline and 130 do not, so that is carried per file rather than
    normalised.
    """

    def __init__(self, path):
        self.path = path
        self.name = os.path.basename(path)
        with io.open(path, encoding="utf-8", newline="") as f:
            self.raw = f.read()
        self.trailing_nl = self.raw.endswith("\n")
        self.records = json.loads(self.raw)
        if not isinstance(self.records, list):
            self.records = [self.records]
        self.sha = sha256_text(self.raw)

    def render(self, records=None):
        """Serialise back to the exact on-disk shape."""
        body = json.dumps(records if records is not None else self.records,
                          ensure_ascii=False, indent=1)
        return body + ("\n" if self.trailing_nl else "")

    def round_trips(self):
        return self.render() == self.raw


class Corpus(object):
    def __init__(self, root=ADDON, want_index=True):
        #[[ Every path derives from `root`, so a test can run the whole tool
        #   against a throwaway copy of the tree. That matters more than usual
        #   here: the write path is the risky part, and the pipeline's own
        #   agents write to build/authored/ at the same time. A test that
        #   exercised the real directory would be a test that could destroy
        #   the thing it tests. ]]
        self.root = root
        self.authored_dir = os.path.join(root, "build", "authored")
        self.rendered_dir = os.path.join(root, "build", "rendered")
        self.validated_path = os.path.join(root, "build", "validated",
                                           "quests.json")
        self.quarantine_path = os.path.join(root, "build", "reports",
                                            "validate.jsonl")
        self.errors = []
        self._rendered_cache = {}
        self._load_authored()
        self._load_validated()
        self._load_quarantine()
        self.index = self._load_index() if want_index else {}
        self._link()

    # ---------------------------------------------------------------- load

    def _load_authored(self):
        self.files = {}
        self.quests = []
        self.by_qid = {}
        self.loc = {}          # qid -> (file name, index within that file)
        self.dupes = []        # qid recorded in more than one place
        for p in sorted(glob.glob(os.path.join(self.authored_dir, "*.json"))):
            try:
                af = AuthoredFile(p)
            except Exception as e:              # a corrupt file must not hide
                self.errors.append("%s: %s" % (os.path.basename(p), e))
                continue
            self.files[af.name] = af
            for i, q in enumerate(af.records):
                ident = q.get("identity") or {}
                qid = qid_of(ident) if ident.get("cat") else "?/%s/%d" % (af.name, i)
                if qid in self.by_qid:
                    self.dupes.append((qid, self.loc[qid], (af.name, i)))
                    continue
                self.by_qid[qid] = q
                self.loc[qid] = (af.name, i)
                self.quests.append(q)

    def _load_validated(self):
        self.validated = {}
        if not os.path.exists(self.validated_path):
            return
        with io.open(self.validated_path, encoding="utf-8") as f:
            for v in json.load(f):
                self.validated["%s/%s/%s" % (v["cat"], v["area"], v["id"])] = v

    def _load_quarantine(self):
        self.quarantine = []
        if not os.path.exists(self.quarantine_path):
            return
        with io.open(self.quarantine_path, encoding="utf-8") as f:
            for line in f:
                line = line.strip()
                if line:
                    self.quarantine.append(json.loads(line))

    def _load_index(self):
        """data/quest_index.lua + mission_index.lua, via Lua's own loadfile.

        Cached against the two files' mtimes, because dumping 750 KB of Lua
        costs about a second and the editor reloads on every request.
        """
        qi = os.path.join(self.root, "data", "quest_index.lua")
        mi = os.path.join(self.root, "data", "mission_index.lua")
        if not os.path.exists(qi):
            self.errors.append("data/quest_index.lua is missing")
            return {}
        stamp = "%d-%d" % (os.path.getmtime(qi),
                           os.path.getmtime(mi) if os.path.exists(mi) else 0)
        if not os.path.isdir(CACHE):
            os.makedirs(CACHE)
        cached = os.path.join(CACHE, "index.json")
        stampf = os.path.join(CACHE, "index.stamp")
        if os.path.exists(cached) and os.path.exists(stampf):
            with io.open(stampf, encoding="utf-8") as f:
                if f.read().strip() == stamp:
                    with io.open(cached, encoding="utf-8") as g:
                        return json.load(g)
        if not os.path.exists(LUAJIT):
            self.errors.append("luajit not found at %s -- index views disabled"
                               % LUAJIT)
            return {}
        proc = subprocess.Popen(
            [LUAJIT, os.path.join("tools", "questgraph", "dump_index.lua"),
             self.root],
            cwd=self.root, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, err = proc.communicate()
        if proc.returncode != 0:
            self.errors.append("dump_index.lua failed: "
                               + err.decode("utf-8", "replace")[:400])
            return {}
        data = json.loads(out.decode("utf-8"))
        with io.open(cached, "w", encoding="utf-8", newline="\n") as f:
            json.dump(data, f, ensure_ascii=False)
        with io.open(stampf, "w", encoding="utf-8", newline="\n") as f:
            f.write(stamp)
        return data

    def _link(self):
        """Join the layers, and record where they disagree.

        The index is keyed by (cat, area, id) like everything else, but it
        holds 16 records that share a key with another, all of them
        `quest/coalition`. So the join keeps a LIST per key rather than the
        first hit. A join that silently kept one would make the editor show a
        different half of a coalition quest depending on iteration order.
        """
        self.index_by_qid = {}
        for kind in ("quests", "missions"):
            for rec in (self.index.get(kind) or []):
                if not rec:
                    continue
                k = "%s/%s/%s" % (rec["cat"], rec["area"], rec["id"])
                self.index_by_qid.setdefault(k, []).append(rec)

    # ------------------------------------------------------------- reading

    def rendered_path(self, q):
        """build/rendered/<cache_file>_<10 hex>.md for an authored record.

        The authored record stores `cache_file` WITHOUT the content hash the
        rendered filename carries, so this is a prefix match rather than a join.
        """
        cf = (q.get("source") or {}).get("cache_file")
        if not cf:
            return None
        if not self._rendered_cache:
            for p in glob.glob(os.path.join(self.rendered_dir, "*.md")):
                base = os.path.basename(p)[:-3]
                self._rendered_cache[re.sub(r"_[0-9a-f]{10}$", "", base)] = p
        return self._rendered_cache.get(cf)

    def rendered_text(self, q):
        p = self.rendered_path(q)
        if not p or not os.path.exists(p):
            return None
        with io.open(p, encoding="utf-8") as f:
            return f.read()

    # ------------------------------------------------------------ derived

    def human_edited(self):
        """Every record carrying a human correction, newest first."""
        out = []
        for qid, q in self.by_qid.items():
            h = q.get("human")
            if h:
                out.append((qid, q))
        out.sort(key=lambda kv: (kv[1]["human"].get("edited_at") or ""),
                 reverse=True)
        return out

    def real_quarantine(self):
        """Quarantine minus the placeholder family.

        340 of 356 rows are `placeholder_target`, which is the intended
        outcome. A report that presents the intended outcome as a problem
        is not a signal.
        """
        return [r for r in self.quarantine if r["reason"] != "placeholder_target"]

    def flag_counts(self):
        counts = {}
        for q in self.quests:
            for f in (q.get("review_flags") or []):
                counts[f] = counts.get(f, 0) + 1
        return counts

    def coverage(self, layer="validated"):
        """The observability numbers, computed the way the README computes them.

        Two things have to match or the tool contradicts the shipped docs:

        * it is measured on the VALIDATED layer, because a piece of evidence
          whose name did not resolve is evidence the addon never sees;
        * consecutive steps sharing a `group` collapse to ONE position, because
          a 20-NPC wildcat group draws all at once and counting it as 20
          unobservable rungs would invent a lag that no player experiences.

        Measured on `authored` instead, the same function gives the reading's
        intent rather than the addon's reach. The DIFFERENCE between the two is
        the interesting number: evidence that was read off the page and then
        lost to name resolution.
        """
        rows = []
        if layer == "validated":
            for v in self.validated.values():
                rows.append([(s.get("group"), bool(s.get("ev") or s.get("ev_alt")),
                              bool(s.get("reqs") or s.get("reqs_alt")))
                             for s in v["steps"]])
        else:
            for q in self.quests:
                out = []
                for s in q["steps"]:
                    e = s.get("evidence") or {}
                    out.append((s.get("group"),
                                bool(e.get("all") or e.get("alt")),
                                bool(s.get("items") or s.get("items_alt"))))
                rows.append(out)

        positions = ev = readable = 0
        no_ev = stretch = longest = 0
        final_readable = 0
        for steps in rows:
            collapsed = []
            for grp, has_ev, has_req in steps:
                if grp is not None and collapsed and collapsed[-1][0] == grp:
                    #[[ One position, but it still counts as observable if ANY
                    #   member is. A group's evidence sits on its last member
                    #   by design: in An Explorer's Footsteps (quest/other/19)
                    #   the `monuments` group runs steps 2 to 18 and only step
                    #   18 carries evidence. Folding with `or` is what keeps
                    #   it. ]]
                    p = collapsed[-1]
                    collapsed[-1] = (grp, p[1] or has_ev, p[2] or has_req)
                else:
                    collapsed.append((grp, has_ev, has_req))
            positions += len(collapsed)
            have = sum(1 for c in collapsed if c[1])
            ev += have
            readable += sum(1 for c in collapsed if c[1] or c[2])
            if have == 0:
                no_ev += 1
            if collapsed and (collapsed[-1][1] or collapsed[-1][2]):
                final_readable += 1
            run = best = 0
            for c in collapsed:
                run = 0 if c[1] else run + 1
                best = max(best, run)
            if best >= 2:
                stretch += 1
            longest = max(longest, best)
        return {
            "layer": layer,
            "quests": len(rows),
            "positions": positions,
            "positions_with_evidence": ev,
            "positions_readable": readable,
            "quests_no_evidence": no_ev,
            "quests_with_2plus_stretch": stretch,
            "longest_stretch": longest,
            "quests_final_readable": final_readable,
        }

    def freshness(self):
        """Is what the addon ships still what the reasoning says?

        Everything below build/authored/ is a pure function of it, so the
        moment an authored file is newer than build/validated/quests.json the
        shipped index describes a reading that no longer exists. Nothing else
        in the project notices: validate, emit and build_index are all happy to
        run late, and the index carries no stamp of the authored data it came
        from.

        This is the check that makes a correction real. A human can edit,
        commit, and walk away believing the game will behave differently. It
        will not, until the build runs.
        """
        def newest(paths):
            best = 0
            for p in paths:
                if os.path.exists(p):
                    best = max(best, os.path.getmtime(p))
            return best

        authored = newest(glob.glob(os.path.join(self.authored_dir, "*.json")))
        validated = newest([self.validated_path])
        steps = newest([os.path.join(self.root, "data", "quest_steps.lua")])
        index = newest([os.path.join(self.root, "data", "quest_index.lua")])
        stale = []
        if authored and validated and authored > validated + 1:
            stale.append("build/validated/quests.json is older than "
                         "build/authored/ -- run validate.py")
        if validated and steps and validated > steps + 1:
            stale.append("data/quest_steps.lua is older than "
                         "build/validated/ -- run emit_lua.py")
        if steps and index and steps > index + 1:
            stale.append("data/quest_index.lua is older than "
                         "data/quest_steps.lua -- run build_index.lua")
        return {"stale": stale,
                "authored": authored, "validated": validated,
                "quest_steps": steps, "quest_index": index}

    def stats(self):
        conf = {}
        for q in self.quests:
            c = q.get("confidence")
            conf[c] = conf.get(c, 0) + 1
        vconf = {}
        for v in self.validated.values():
            vconf[v["conf"]] = vconf.get(v["conf"], 0) + 1
        qcounts = {}
        for r in self.quarantine:
            qcounts[r["reason"]] = qcounts.get(r["reason"], 0) + 1
        shipped = self.coverage("validated")
        read = self.coverage("authored")
        return {
            "quests": len(self.quests),
            "files": len(self.files),
            "steps": sum(len(q["steps"]) for q in self.quests),
            "authored_confidence": conf,
            "validated_tiers": {"full": vconf.get(3, 0),
                                "assisted": vconf.get(2, 0),
                                "start_only": vconf.get(1, 0)},
            "coverage_shipped": shipped,
            "coverage_read": read,
            #[[ Evidence a reader found on the page and the resolver then lost.
            #   Nothing else reports this: validate.py counts what survived and
            #   the README quotes the survivor. The gap is a worklist. ]]
            "evidence_lost_to_resolution":
                read["positions_with_evidence"] - shipped["positions_with_evidence"],
            "quarantine": qcounts,
            "quarantine_real": len(self.real_quarantine()),
            "review_flags_distinct": len(self.flag_counts()),
            "human_edited": len(self.human_edited()),
            "index_quests": len(self.index.get("quests") or []),
            "index_missions": len(self.index.get("missions") or []),
            "index_ladders_applied": (self.index.get("meta") or {}).get("steps"),
            "authored_duplicates": len(self.dupes),
            "freshness": self.freshness(),
            "errors": self.errors,
        }


def relpath(p):
    return os.path.relpath(p, ADDON).replace("\\", "/")


def is_generated(path, root=ADDON):
    """True if `path` is a file this tool must never write.

    Compared as a path relative to the corpus root, so it holds for a test
    tree as well as the real one. A guard that only worked on the real tree
    would be a guard no test could prove.
    """
    rp = os.path.normpath(os.path.relpath(os.path.abspath(path), root))
    return rp.replace("\\", "/") in tuple(g.replace("\\", "/") for g in GENERATED)


if __name__ == "__main__":
    c = Corpus()
    json.dump(c.stats(), sys.stdout, indent=1, sort_keys=True)
    sys.stdout.write("\n")
