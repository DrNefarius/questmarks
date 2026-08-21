"""What the editor is allowed to offer as a name, and how sure it is.

Items, key items and zones live in `res/`, so a name either resolves to an id or
it does not. `dump_pick.lua` builds the picker from `normalize.make_item_index`,
the same function `resolve.lua` uses, so it cannot offer an unresolvable name.

NPCs, objects and monsters are in no res table; the addon matches them against
get_mob_list() at runtime. A wikilink in local `bgwiki-rest-cache/` proves one.

Presence proves valid; absence depends on type. 2820 of 2890 npc targets are
linked on their own quest page (98%); for objects it is 225 of 867 (26%), and
500 link nowhere at all. Doors, `???`, altars and furniture never got an
article, so flagging unlinked objects would shout through most of the corpus
and block adding the very object a correction exists to add.

Build-time only. Reads only.
"""

import glob
import io
import json
import os
import re
import subprocess

from corpus import ADDON, CACHE, LUAJIT

CACHE_DIR = os.path.join(ADDON, "bgwiki-rest-cache", "pages")
MANIFEST = os.path.join(ADDON, "bgwiki-rest-cache", "manifest.json")

#[[ Parsoid emits `rel="mw:WikiLink"` on internal links, with the target in
#   `title=`. Attribute order is not guaranteed, so both orderings are matched.
#   A single-ordering regex silently loses a slice of the links, and the
#   number would still look plausible. ]]
RE_LINK_A = re.compile(r'rel="mw:WikiLink"[^>]*?title="([^"]+)"')
RE_LINK_B = re.compile(r'title="([^"]+)"[^>]*?rel="mw:WikiLink"')

ENT_HTML = (("&amp;", "&"), ("&quot;", '"'), ("&#39;", "'"), ("&lt;", "<"),
            ("&gt;", ">"), ("&nbsp;", " "))


def _unescape(s):
    for a, b in ENT_HTML:
        s = s.replace(a, b)
    return s


def fold(s):
    """normalize.lua's `fold`: collapse whitespace, trim, lowercase.

    Punctuation is deliberately NOT stripped. `res/key_items.lua` 214 is
    literally `"Final Fantasy"`, quotes included, and a picker that folded them
    away would offer a name that cannot resolve.
    """
    return " ".join((s or "").split()).lower()


def _stamp():
    files = glob.glob(os.path.join(CACHE_DIR, "*.json"))
    newest = max((os.path.getmtime(p) for p in files), default=0)
    return "%d-%d" % (len(files), newest)


class Entities(object):
    """Wikilink targets per page, and in aggregate."""

    def __init__(self):
        self.by_page = {}
        self.all = set()
        self._all_fold = {}
        self._load()

    def _load(self):
        if not os.path.isdir(CACHE_DIR):
            return
        stamp = _stamp()
        path = os.path.join(CACHE, "entities.json")
        spath = os.path.join(CACHE, "entities.stamp")
        if os.path.exists(path) and os.path.exists(spath):
            with io.open(spath, encoding="utf-8") as f:
                if f.read().strip() == stamp:
                    with io.open(path, encoding="utf-8") as g:
                        d = json.load(g)
                    self.by_page = {int(k): set(v)
                                    for k, v in d["by_page"].items()}
                    self.all = set(d["all"])
                    self._index()
                    return
        self._harvest()
        if not os.path.isdir(CACHE):
            os.makedirs(CACHE)
        with io.open(path, "w", encoding="utf-8", newline="\n") as f:
            json.dump({"by_page": {str(k): sorted(v)
                                   for k, v in self.by_page.items()},
                       "all": sorted(self.all)}, f, ensure_ascii=False)
        with io.open(spath, "w", encoding="utf-8", newline="\n") as f:
            f.write(stamp)
        self._index()

    def _harvest(self):
        """~1 second over 1382 pages, then cached. Cheap enough not to be clever."""
        for p in sorted(glob.glob(os.path.join(CACHE_DIR, "*.json"))):
            try:
                with io.open(p, encoding="utf-8") as f:
                    d = json.load(f)
            except Exception:
                continue
            html = d.get("html") or ""
            pid = (d.get("page") or {}).get("id")
            if pid is None:
                continue
            titles = {_unescape(t) for t in RE_LINK_A.findall(html)}
            titles |= {_unescape(t) for t in RE_LINK_B.findall(html)}
            self.by_page[pid] = titles
            self.all |= titles

    def _index(self):
        self._all_fold = {}
        for t in self.all:
            self._all_fold.setdefault(fold(t), t)
        self._page_fold = {pid: {fold(t) for t in ts}
                           for pid, ts in self.by_page.items()}

    # ------------------------------------------------------------ queries

    def tier(self, name, page_id, target_type="npc"):
        """-> (tier, evidence) where tier is 'page' | 'wiki' | 'unknown'.

        A SIGNAL, never a gate. The 2% of NPCs and the 58% of objects that miss
        are real targets that appear as plain text or have no article at all:
        `abandoned mineshaft`, `acid-eaten door`, `altar of rancor` are all
        legitimate marker targets. A field that refused them would make it
        impossible to add the missing target a correction exists to add.
        """
        f = fold(name)
        if not f:
            return "unknown", None
        own = self._page_fold.get(page_id) or set()
        if f in own:
            return "page", "linked on this quest's own page"
        if f in self._all_fold:
            return "wiki", "BG Wiki has a page titled %r" % self._all_fold[f]
        #[[ Objects are EXPECTED to be unlinked (58% of them are), so the
        #   absence carries no information there and must not read as a
        #   warning. For an NPC it is 20 cases in 2890 and worth a look. ]]
        return "unknown", ("objects usually have no wiki page -- this is normal"
                           if target_type == "object"
                           else "not linked anywhere in the page cache")

    #[[ The link set is a SUPERSET: a quest page links its category, its
    #   reward items, its zones and its sibling quests as well as its NPCs.
    #   That is fine for VALIDATION (a hit proves BG Wiki has a page with this
    #   title, which is exactly enough to catch a typo or an invented name) and
    #   noisy for SUGGESTION. These prefixes are namespaces, never entities. ]]
    NAMESPACE = ("category:", "file:", "template:", "help:", "special:",
                 "talk:", "user:", "mediawiki:", "module:", "bg:")

    def _entity_like(self, title):
        f = fold(title)
        return not any(f.startswith(p) for p in self.NAMESPACE)

    def suggest(self, page_id, prefix="", limit=40, target_type="npc",
                demote=()):
        """Candidates for a target field, best evidence first.

        The default list is what THIS quest's page links. That is not merely
        validation but autocomplete drawn from the evidence, the same
        discipline the dataset was built on: the page is what you read.

        `demote` carries names the caller already knows are something else
        (the step's own zone, the items it requires), so a page's zone link
        stops sitting at the top of its NPC picker. They are pushed down rather
        than removed, because an NPC and a zone genuinely can share a name.
        """
        f = fold(prefix)
        dem = {fold(d) for d in demote if d}
        own, low = [], []
        seen = set()
        for t in sorted(self.by_page.get(page_id) or []):
            if not self._entity_like(t) or f not in fold(t):
                continue
            seen.add(fold(t))
            (low if fold(t) in dem else own).append({"name": t, "tier": "page"})
        out = own + low
        if f:
            for k, t in sorted(self._all_fold.items()):
                if len(out) >= limit:
                    break
                if k.startswith(f) and k not in seen and self._entity_like(t):
                    out.append({"name": t, "tier": "wiki"})
                    seen.add(k)
        return out[:limit]


class Picks(object):
    """Prefix search over items, key items and zones."""

    def __init__(self):
        self.data = {"item": [], "ki": [], "zone": []}
        self._load()

    def _load(self):
        path = os.path.join(CACHE, "pick.json")
        res_dir = os.path.join(os.path.dirname(os.path.dirname(ADDON)), "res")
        stamp = "1"
        for t in ("items", "key_items", "zones"):
            p = os.path.join(res_dir, t + ".lua")
            if os.path.exists(p):
                stamp += "-%d" % os.path.getmtime(p)
        spath = os.path.join(CACHE, "pick.stamp")
        if os.path.exists(path) and os.path.exists(spath):
            with io.open(spath, encoding="utf-8") as f:
                if f.read().strip() == stamp:
                    with io.open(path, encoding="utf-8") as g:
                        self.data = json.load(g)
                    return
        if not os.path.exists(LUAJIT):
            return
        proc = subprocess.Popen(
            [LUAJIT, os.path.join("tools", "questgraph", "dump_pick.lua")],
            cwd=ADDON, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        out, _err = proc.communicate()
        if proc.returncode != 0:
            return
        self.data = json.loads(out.decode("utf-8"))
        if not os.path.isdir(CACHE):
            os.makedirs(CACHE)
        with io.open(path, "wb") as f:
            f.write(out)
        with io.open(spath, "w", encoding="utf-8", newline="\n") as f:
            f.write(stamp)

    def search(self, kind, q, limit=30):
        rows = self.data.get(kind) or []
        f = fold(q)
        if not f:
            return []
        starts, contains = [], []
        for r in rows:
            if r["f"].startswith(f):
                starts.append(r)
            elif f in r["f"]:
                contains.append(r)
            if len(starts) >= limit:
                break
        out = (starts + contains)[:limit]
        #[[ `differs` is the whole reason a duplicate name is shown rather than
        #   silently bound. An empty dict means the ids are indistinguishable in
        #   res: "one key item per unit carried", a disjunction validate.py
        #   already handles. A non-empty dict means genuinely different things
        #   sharing a name (Nodal Wand: damage 129/131/133), where the resolver
        #   picks one over an unordered pairs() and the winner is not stable
        #   between runs. Only the second needs a human. ]]
        return [{
            "name": r["n"], "id": r["id"],
            "ids": r.get("ids"),
            "differs": r.get("differs"),
            "ambiguous": bool(r.get("differs")),
            "or_group": "ids" in r and not r.get("differs"),
        } for r in out]

    def exact(self, kind, name):
        f = fold(name)
        for r in (self.data.get(kind) or []):
            if r["f"] == f:
                return r
        return None
