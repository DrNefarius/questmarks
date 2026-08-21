"""The prev DAG over quests AND missions, and the things nothing else checks.

`prev` links form a directed graph over every indexed entry: 1115 quest records
and 438 mission records. It genuinely crosses the two, because a quest can
require a mission and a mission can require a quest. Nothing in the pipeline or
the addon looks for a cycle, a dangling prerequisite or a subtree that can never
be entered, because nothing ever walks the whole graph.

The addon does not need to: core/prereq.lua asks only "is THIS entry's
immediate prerequisite complete", which is a one-hop question and is answered
correctly whatever the global shape. The failures below are therefore invisible
in play except as a quest that never becomes available, which is
indistinguishable from one you simply have not reached.

Reads only. Build-time only.
"""

import collections


def key(rec):
    return "%s/%s/%s" % (rec["cat"], rec["area"], rec["id"])


def prev_key(p):
    return "%s/%s/%s" % (p.get("cat"), p.get("area"), p.get("id"))


class Graph(object):
    def __init__(self, index):
        self.nodes = {}          # key -> a representative record
        self.dupes = collections.defaultdict(list)
        for kind in ("quests", "missions"):
            for rec in (index.get(kind) or []):
                if not rec:
                    continue
                k = key(rec)
                if k in self.nodes:
                    self.dupes[k].append(rec)
                else:
                    self.nodes[k] = rec

        self.prev = {}           # key -> [prerequisite keys], resolved only
        self.dangling = []       # (key, unresolved prerequisite key)
        self.succ = collections.defaultdict(list)
        for k, rec in self.nodes.items():
            ps = []
            for p in (rec.get("prev") or []):
                pk = prev_key(p)
                if pk in self.nodes:
                    ps.append(pk)
                    self.succ[pk].append(k)
                else:
                    self.dangling.append((k, pk))
            self.prev[k] = ps

    # --------------------------------------------------------------- shape

    def cycles(self):
        """Every cycle, via Tarjan. A cycle is unconditionally a data error:
        every member requires, transitively, its own completion."""
        index = {}
        low = {}
        on = {}
        stack = []
        counter = [0]
        found = []

        #[[ Iterative, not recursive. The longest chain here is short, but a
        #   Python recursion limit blowing up inside a maintenance tool is a
        #   silent "no cycles found" if anyone ever wraps this in a try. ]]
        for root in sorted(self.nodes):
            if root in index:
                continue
            work = [(root, iter(self.prev.get(root, ())))]
            index[root] = low[root] = counter[0]
            counter[0] += 1
            stack.append(root)
            on[root] = True
            while work:
                node, it = work[-1]
                advanced = False
                for nxt in it:
                    if nxt not in index:
                        index[nxt] = low[nxt] = counter[0]
                        counter[0] += 1
                        stack.append(nxt)
                        on[nxt] = True
                        work.append((nxt, iter(self.prev.get(nxt, ()))))
                        advanced = True
                        break
                    elif on.get(nxt):
                        low[node] = min(low[node], index[nxt])
                if advanced:
                    continue
                work.pop()
                if work:
                    low[work[-1][0]] = min(low[work[-1][0]], low[node])
                if low[node] == index[node]:
                    comp = []
                    while True:
                        m = stack.pop()
                        on[m] = False
                        comp.append(m)
                        if m == node:
                            break
                    if len(comp) > 1 or node in self.prev.get(node, ()):
                        found.append(sorted(comp))
        return found

    def unreachable(self):
        """Entries stranded behind a CYCLE. Nothing else strands an entry.

        The obvious second cause is a `prev` naming an entry the index does not
        contain. It is not a cause at all. The measurement looks alarming and
        is not:

            prereq.evaluate   asks state.status_of(p.cat, p.area, p.id), which
                              reads the GAME's completion bitfield.
            quest_name        labels it from data/dat_names.lua.

        Both live in core/prereq.lua.

        Neither consults the index. So an out-of-index prerequisite still gates
        correctly and still prints its real name; the index simply does not
        enumerate that entry as something you can be sent to. 60 edges are like
        that, almost all of them mission ids that mission_index.lua does not
        carry, and treating them as breakage would strand 181 entries in a
        report and send someone chasing a bug that does not exist.

        Same discipline as `placeholder_target` in validate.py: a report where
        the bulk of the rows are the intended outcome is not a signal.
        """
        bad = set()
        for comp in self.cycles():
            bad.update(comp)
        reason = {k: "in a prerequisite cycle" for k in bad}
        frontier = list(bad)
        while frontier:
            k = frontier.pop()
            for s in self.succ.get(k, ()):
                if s not in reason:
                    reason[s] = "behind a cycle at %s" % k
                    frontier.append(s)
        return reason

    def out_of_index(self):
        """`prev` edges naming an entry the index does not contain.

        INFORMATION, not breakage: see unreachable(). Split two ways, because
        the two halves mean different things:

            unresolved   the builder could not map the wiki's `Previous` string
                         to any DAT id at all (build_index reports these as
                         `prev_unresolved`, and the `p.unresolved` branch of
                         `prereq.evaluate` gives them an honest "could not be
                         resolved" rather than a block).
            not_indexed  it resolved to a real (cat, area, id) that the index
                         does not enumerate. Gating and naming both still work.
        """
        unresolved, not_indexed = [], []
        for k, pk in self.dangling:
            (unresolved if pk.startswith("None/") else not_indexed).append((k, pk))
        return {"unresolved": sorted(unresolved),
                "not_indexed": sorted(not_indexed)}

    def depths(self):
        """Longest prerequisite chain ending at each node."""
        memo = {}

        def depth(k, seen):
            if k in memo:
                return memo[k]
            if k in seen:                 # inside a cycle; do not recurse
                return 0
            seen = seen | {k}
            d = 0
            for p in self.prev.get(k, ()):
                d = max(d, 1 + depth(p, seen))
            memo[k] = d
            return d

        return {k: depth(k, frozenset()) for k in self.nodes}

    def cross_category(self):
        """Edges between a quest and a mission, in both directions."""
        out = []
        for k, ps in self.prev.items():
            for p in ps:
                if self.nodes[k]["cat"] != self.nodes[p]["cat"]:
                    out.append((k, p))
        return sorted(out)

    def report(self):
        cycles = self.cycles()
        unreachable = self.unreachable()
        ooi = self.out_of_index()
        depths = self.depths()
        edges = sum(len(v) for v in self.prev.values())
        roots = [k for k in self.nodes if not self.prev.get(k)]
        isolated = [k for k in roots if not self.succ.get(k)]
        deepest = sorted(depths.items(), key=lambda kv: -kv[1])[:15]
        return {
            "nodes": len(self.nodes),
            "edges": edges,
            "duplicate_records": {k: len(v) + 1 for k, v in self.dupes.items()},
            "cycles": cycles,
            "unreachable": unreachable,
            "out_of_index": ooi,
            "roots": len(roots),
            "isolated": len(isolated),
            "cross_category": self.cross_category(),
            "max_depth": max(depths.values()) if depths else 0,
            "deepest": deepest,
            "depths": depths,
        }

    # --------------------------------------------------------------- views

    def neighbourhood(self, k, up=3, down=3):
        """The subgraph a human actually wants: this entry, what it needs, and
        what needs it. The whole 1553-node graph is a hairball and answers no
        question; three hops in each direction answers "why can I not start
        this" and "what does breaking this cost"."""
        seen = {k: 0}
        frontier = [(k, 0)]
        while frontier:
            n, d = frontier.pop()
            if d < up:
                for p in self.prev.get(n, ()):
                    if p not in seen or seen[p] > d + 1:
                        seen[p] = d + 1
                        frontier.append((p, d + 1))
        frontier = [(k, 0)]
        while frontier:
            n, d = frontier.pop()
            if d < down:
                for s in self.succ.get(n, ()):
                    if s not in seen:
                        seen[s] = -(d + 1)
                        frontier.append((s, d + 1))
        nodes = sorted(seen)
        edges = [(p, n) for n in nodes for p in self.prev.get(n, ())
                 if p in seen]
        return {"center": k, "nodes": nodes, "edges": edges,
                "levels": seen,
                "labels": {n: self.nodes[n].get("snpc") for n in nodes}}
