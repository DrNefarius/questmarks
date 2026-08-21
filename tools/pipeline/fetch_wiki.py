#!/usr/bin/env python3
"""fetch_wiki.py: BG Wiki page cache builder (MediaWiki core REST v1 only).

This is the enumerator/fetcher that built bgwiki-rest-cache/. The original run was
quest-scoped and its tool was not kept; this one reproduces its record schema exactly
so that prepass.py and tools/questgraph/entities.py keep reading the cache unchanged.

Transport. Core REST v1 and nothing else, matching manifest.json's
`"transport": "mediawiki_core_rest_v1_only"`:

    GET /page/{Title}            -> .source, raw wikitext
    GET /page/{Title}/with_html  -> .html, Parsoid render

The Action API (api.php) is NOT used, and neither is the category-members endpoint.
manifest.json records `"normal_html_category_requests_used": false` and that stays true.
Category enumeration is a directory-graph walk: fetch the category page itself, parse
the hand-maintained tables and links out of its rendered HTML, and recurse into child
categories. Membership is then confirmed per page from that page's own categories, which
is why no members query is needed.

Candidates come from two places, exactly as the quest run's manifest records them:
  * `rest_directory_*`: links parsed out of a directory page's tables
  * a SEED list: the quest run used a bundled title snapshot that is not in this
    tree. For missions we seed from data/dat_names.lua's `mission` namespace
    instead, which is strictly better: those names come from the game client's
    own DAT files, so they are authoritative about what exists rather than about
    what somebody wrote down.

Do not point this at manifest.json. That file is quest-scoped
(`"category": "Category:Quests"`) and carries the full provenance of the quest corpus.
--manifest is required and must name a separate file.

pages/ is shared and keyed by page id. A page already cached by the quest run is reused
untouched. That sharing is exactly how cross-category duplicates are detected.

Cache policy is `resume_missing_only`: a page already on disk is not refetched unless
--refresh is given, and even then the stored revision_id/ETag are sent so an unchanged
page costs a 304 and no rewrite.
"""

import argparse
import hashlib
import json
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone

CACHE_SCHEMA = "bgwiki-core-rest-page-cache-v1"
MANIFEST_SCHEMA = "bgwiki-quest-cache-manifest-v4-rest-directory"
TRANSPORT = "mediawiki_core_rest_v1"
TRANSPORT_RUN = "mediawiki_core_rest_v1_only"
HTML_MODE = "page_with_html_plus_source"
REST_BASE = "https://www.bg-wiki.com/rest.php/v1"
USER_AGENT = (
    "questmarks-cache/1.0 (FFXI questmarks addon build tool; "
    "bg-wiki MediaWiki core REST v1; polite, cached, conditional)"
)

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.abspath(os.path.join(HERE, "..", ".."))
CACHE = os.path.join(ADDON, "bgwiki-rest-cache")

# Namespaces that are never content pages we want.
SKIP_NS = (
    "File:", "Template:", "Special:", "Help:", "Talk:", "User:", "MediaWiki:",
    "Module:", "Media:", "Property:", "Form:",
)

_SLUG_RE = re.compile(r"[^a-z0-9]+")
# Parsoid emits categories as <link rel="mw:PageProp/Category" href="./Category:X">.
# The href may carry a #fragment (sort key), so the fragment is optional here rather
# than excluded. Demanding a quote straight after the title silently drops every
# sort-keyed category, and "Repeatable Quests" is always sort-keyed.
_CAT_RE = re.compile(r'<link rel="mw:PageProp/Category" href="\./([^"#]+)(?:#[^"]*)?"')
_HREF_RE = re.compile(r'href="\./([^"]+)"')


def utcnow():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


def slugify(title):
    return _SLUG_RE.sub("_", title.lower()).strip("_")


def cache_filename(page_id, title):
    """<pageid zero-padded to 7>_<slugified title>_<first 10 of sha1(title)>.json

    Verified against the whole page cache: 3414/3414 filenames reproduce."""
    h = hashlib.sha1(title.encode("utf-8")).hexdigest()[:10]
    return "%07d_%s_%s.json" % (page_id, slugify(title), h)


def categories_from_html(html):
    """Canonical category titles, sorted case-insensitively.

    Measured against the existing cache: 3336 of the 3373 records with a
    category list reproduce exactly, and 37 differ. 16 of those are records
    where the original run also recorded a raw-wikitext case or bidi-mark
    variant beside the canonical name ('Category:characters' next to
    'Category:Characters'); this extractor keeps only the canonical form, so
    the new list is a subset in duplicate spellings only.

    The other 21 go the other way and are worth knowing about: the cached
    record's own list is short and this extractor finds categories it does not
    carry, `Category:Quests` and `Category:Disambiguation` on the
    `Unlocking a Myth` pages among them. Every consumer keys off the canonical
    name, so neither direction loses a category that was ever read, but a
    record's stored list is not a complete one."""
    if not html:
        return []
    seen = {urllib.parse.unquote(m.group(1)).replace("_", " ") for m in _CAT_RE.finditer(html)}
    return sorted(seen, key=lambda s: s.casefold())


def links_from_html(html):
    """Every ./Title link in render order, de-duplicated, minus obvious non-content."""
    out = []
    seen = set()
    for m in _HREF_RE.finditer(html or ""):
        raw = m.group(1)
        raw = raw.split("#", 1)[0].split("?", 1)[0]
        if not raw:
            continue
        title = urllib.parse.unquote(raw).replace("_", " ")
        if title in seen:
            continue
        seen.add(title)
        out.append(title)
    return out


def api_title(title):
    """Title -> REST path segment. Spaces become underscores, then percent-encode.

    `safe` keeps the characters BG Wiki titles use literally in the endpoint strings
    recorded in the existing cache (apostrophes, parens, commas, colons), so a re-fetch
    of an already-cached page produces a byte-identical source_endpoint.

    "/" is deliberately not among them. A literal slash is a path separator to
    the REST router, so "The Rivalry/The Competition" would ask for
    /page/The_Rivalry/The_Competition, which the router reads as the page
    "The_Rivalry" with a trailing segment and answers 404. That title is real:
    it is what quest/sandoria/75's DAT name points at, via two redirect stubs.
    Percent-encoding costs nothing on titles without a slash, and those are the
    ones the byte-identical-endpoint argument is about."""
    return urllib.parse.quote(title.replace(" ", "_"), safe=":'\"(),!-*")


class Fetcher:
    def __init__(self, delay=1.0, timeout=45, dry_run=False):
        self.delay = delay
        self.timeout = timeout
        self.dry_run = dry_run
        self.requests = 0
        self.last = 0.0

    def _sleep(self):
        gap = time.time() - self.last
        if gap < self.delay:
            time.sleep(self.delay - gap)
        self.last = time.time()

    def get(self, url, etag=None):
        """-> (parsed_json | None, status, headers). None body on 304."""
        if self.dry_run:
            raise RuntimeError("network access attempted under --dry-run: " + url)
        self._sleep()
        req = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
        if etag:
            req.add_header("If-None-Match", etag)
        self.requests += 1
        try:
            with urllib.request.urlopen(req, timeout=self.timeout) as r:
                body = r.read().decode("utf-8")
                return json.loads(body), r.status, dict(r.headers)
        except urllib.error.HTTPError as e:
            if e.code == 304:
                return None, 304, dict(e.headers)
            raise


def build_cache_index(subdir):
    """Existing cache, indexed by page id and by canonical title.

    Reads only the small identity fields; the html blobs make these records large and
    there are well over a thousand of them."""
    by_id, by_title = {}, {}
    d = os.path.join(CACHE, subdir)
    if not os.path.isdir(d):
        return by_id, by_title
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json"):
            continue
        path = os.path.join(d, fn)
        try:
            with open(path, encoding="utf-8") as f:
                rec = json.load(f)
        except Exception:
            continue
        n = rec.get("normalized") or {}
        pid, title = n.get("page_id"), n.get("title")
        entry = {
            "file": fn, "path": path, "page_id": pid, "title": title,
            "revision_id": n.get("revision_id"),
            "categories": n.get("categories") or [],
            "source_len": len(n.get("source") or ""),
            "etag_source": ((rec.get("http") or {}).get("source_etag")),
            "etag_html": ((rec.get("http") or {}).get("html_etag")),
        }
        if pid is not None:
            by_id[pid] = entry
        if title:
            by_title[title] = entry
        if n.get("key"):
            by_title.setdefault(n["key"].replace("_", " "), entry)
    return by_id, by_title


def make_record(requested_title, page, html_page, http, fetched_at, checked_at):
    """Assemble a cache record in bgwiki-core-rest-page-cache-v1 shape."""
    title = page.get("title") or requested_title
    source = page.get("source") or ""
    # html_page is None when Parsoid 404s on a redirect stub. The source is
    # present and is what every downstream stage reads. See fetch_page.
    html_page = html_page or {}
    html = html_page.get("html") or ""
    latest = page.get("latest") or {}
    hlatest = html_page.get("latest") or {}
    rev = latest.get("id")
    hrev = hlatest.get("id")
    rec = {
        "cache_schema": CACHE_SCHEMA,
        "transport": TRANSPORT,
        "requested_title": requested_title,
        "canonical_title": title,
        "fetched_at_utc": fetched_at,
        "checked_at_utc": checked_at,
        "source_endpoint": "%s/page/%s" % (REST_BASE, api_title(requested_title)),
        "html_endpoint": "%s/page/%s/with_html" % (REST_BASE, api_title(requested_title)),
        "html_mode": HTML_MODE,
        "page": page,
        "html_page": html_page,
        "html": html,
        "normalized": {
            "title": title,
            "key": page.get("key") or title.replace(" ", "_"),
            "page_id": page.get("id"),
            "revision_id": rev,
            "revision_timestamp": latest.get("timestamp"),
            "content_model": page.get("content_model"),
            "license": page.get("license") or {"url": None, "title": None},
            "source": source,
            "html": html,
            "canonical_url": "https://www.bg-wiki.com/ffxi/%s" % api_title(title),
            "categories": categories_from_html(html),
        },
        "http": http,
        "integrity": {
            "page_id": page.get("id"),
            "revision_id": rev,
            "revision_timestamp": latest.get("timestamp"),
            "html_revision_id": hrev,
            "revision_match": (rev == hrev),
            "content_model": page.get("content_model"),
            "source_sha256": hashlib.sha256(source.encode("utf-8")).hexdigest(),
            "html_sha256": hashlib.sha256(html.encode("utf-8")).hexdigest(),
        },
    }
    return rec


def fetch_page(fetcher, title, subdir, by_id, by_title, refresh=False):
    """-> (record, status_str). status_str in fetched|cached|refreshed|not_found|error."""
    hit = by_title.get(title)
    if hit and not refresh:
        try:
            with open(hit["path"], encoding="utf-8") as f:
                return json.load(f), "cached"
        except Exception:
            pass

    t = api_title(title)
    src_url = "%s/page/%s" % (REST_BASE, t)
    html_url = "%s/page/%s/with_html" % (REST_BASE, t)
    now = utcnow()
    try:
        page, s_status, s_hdr = fetcher.get(src_url, etag=(hit or {}).get("etag_source") if refresh else None)
        if page is None and hit:          # 304, nothing changed
            with open(hit["path"], encoding="utf-8") as f:
                rec = json.load(f)
            rec["checked_at_utc"] = now
            rec["http"]["source_status"] = 304
            rec["http"]["logical_source_status"] = 304
            return rec, "cached"
    except urllib.error.HTTPError as e:
        if e.code == 404:
            return None, "not_found"
        return None, "error:%d" % e.code
    except Exception as e:
        return None, "error:%s" % type(e).__name__

    #[[ The HTML fetch needs its OWN guard, separate from the source fetch
    #   above. Keep it that way.
    #
    #   Parsoid answers 404 on a redirect stub while /page answers 200, so a
    #   shared try would report the whole page as `not_found` when only the
    #   html is missing. A redirect stub is normal rather than a dead end, and
    #   the redirect-follow pass in main() depends on the record existing.
    #   "The Rivalry" (22609), "The Competition" (22608) and "Flames for the
    #   Dead" (147235) are all in that shape.
    #
    #   The source is what every downstream stage reads; html is used only for
    #   directory-graph link extraction. So a missing html body degrades the
    #   record, it does not invalidate it. ]]
    try:
        html_page, h_status, h_hdr = fetcher.get(html_url)
    except urllib.error.HTTPError as e:
        if e.code != 404:
            return None, "error:%d" % e.code
        html_page, h_status, h_hdr = None, 404, {}
    except Exception as e:
        return None, "error:%s" % type(e).__name__

    http = {
        "integrated_etag": h_hdr.get("ETag"),
        "source_etag": s_hdr.get("ETag"),
        "html_etag": h_hdr.get("ETag"),
        "integrated_last_modified": h_hdr.get("Last-Modified"),
        "source_last_modified": s_hdr.get("Last-Modified"),
        "html_last_modified": h_hdr.get("Last-Modified"),
        "integrated_status": h_status,
        "source_status": s_status,
        "html_status": h_status,
        "logical_source_status": s_status,
    }
    rec = make_record(title, page, html_page, http, now, now)
    pid = rec["normalized"]["page_id"]
    if pid is None:
        return None, "error:no_page_id"

    # Shared cache, keyed by page id: if the quest run already has this page under a
    # different requested title, keep THAT file and do not write a second copy.
    if pid in by_id and not refresh:
        with open(by_id[pid]["path"], encoding="utf-8") as f:
            return json.load(f), "cached"

    fn = cache_filename(pid, rec["normalized"]["title"])
    path = os.path.join(CACHE, subdir, fn)
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as f:
        json.dump(rec, f, ensure_ascii=False, indent=1)
    entry = {
        "file": fn, "path": path, "page_id": pid,
        "title": rec["normalized"]["title"],
        "revision_id": rec["normalized"]["revision_id"],
        "categories": rec["normalized"]["categories"],
        "source_len": len(rec["normalized"]["source"] or ""),
        "etag_source": http["source_etag"], "etag_html": http["html_etag"],
    }
    by_id[pid] = entry
    by_title[rec["normalized"]["title"]] = entry
    by_title.setdefault(title, entry)
    return rec, ("refreshed" if refresh and hit else "fetched")


def read_dat_names(namespace):
    """data/dat_names.lua -> {area: {id: name}} for one namespace.

    The file is a GENERATED Lua table, `names[cat][area][id] = 'Name'`, and its own
    header says it must stay COMPLETE regardless of wiki coverage because
    core/quests.lua feeds these ids to state.set_area_ids. That makes it the right seed
    for a mission enumeration: it is the client's own list of what exists.

    Names are single-quoted in the generated file and may contain an escaped quote,
    so both quote styles are accepted here rather than assuming one."""
    txt = open(os.path.join(ADDON, "data", "dat_names.lua"),
               encoding="utf-8", errors="replace").read()
    m = re.search(r"\b%s\s*=\s*\{" % re.escape(namespace), txt)
    if not m:
        return {}
    depth, i = 0, m.end() - 1
    while i < len(txt):
        if txt[i] == "{":
            depth += 1
        elif txt[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    block = txt[m.end():i]
    out, area = {}, None
    entry = re.compile(r"""\[(\d+)\]\s*=\s*(['"])((?:\\.|(?!\2).)*)\2""")
    header = re.compile(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{", re.M)
    marks = [(mm.start(), mm.group(1)) for mm in header.finditer(block)]
    for idx, (pos, name) in enumerate(marks):
        end = marks[idx + 1][0] if idx + 1 < len(marks) else len(block)
        area = name
        rows = {}
        for e in entry.finditer(block[pos:end]):
            rows[int(e.group(1))] = e.group(3).replace("\\'", "'").replace('\\"', '"')
        if rows:
            out[area] = rows
    return out


def is_redirect(rec):
    src = ((rec.get("normalized") or {}).get("source") or "").lstrip()
    return src[:9].upper().startswith("#REDIRECT")


def redirect_target(rec):
    src = ((rec.get("normalized") or {}).get("source") or "")
    m = re.search(r"#REDIRECT\s*\[\[([^\]|#]+)", src, re.IGNORECASE)
    return m.group(1).strip() if m else None


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--category", help='root, e.g. "Category:Missions". '
                                       "Required unless --titles-file is given.")
    #[[ A named list, for the tail the directory walks never reach.
    #
    #   Both existing runs enumerate a category graph, which is right for building a
    #   corpus and wrong for the handful of pages left over once one exists: a
    #   category walk to recover 14 known titles would re-fetch hundreds of directory
    #   pages to rediscover names we can already write down. The gap is real. These
    #   are titles the DAT names and the walks did not, e.g. "Journey to Bastok".
    #
    #   Same fetch path, same record schema, same cache policy as every other
    #   candidate; only the source of the candidate list differs, and that source is
    #   recorded per page as `explicit_title` evidence so the manifest still says
    #   where each page came from. ]]
    ap.add_argument("--titles-file",
                    help="file of page titles, one per line, '#' comments allowed. "
                         "Skips the directory walk entirely and fetches exactly "
                         "these. Use for known-missing pages rather than re-walking "
                         "a category to rediscover them.")
    ap.add_argument("--manifest", required=True,
                    help="manifest filename under bgwiki-rest-cache/ "
                         "(MUST NOT be manifest.json -- that one is quest-scoped)")
    ap.add_argument("--seed-dat-names", action="store_true",
                    help="seed candidates from data/dat_names.lua's mission namespace")
    ap.add_argument("--seed-namespace", default="mission")
    ap.add_argument("--max-depth", type=int, default=3)
    ap.add_argument("--descend-pattern", default=r"(?i)mission|assault|campaign",
                    help="only recurse into child categories matching this regex. "
                         "A category page links to every item and mob its members "
                         "mention, so an unfiltered depth-3 walk reaches Category:"
                         "Bestiary (220 children) and returns thousands of candidates "
                         "that are not missions. Non-matching children are still "
                         "RECORDED, just not walked.")
    ap.add_argument("--no-quest-fence", action="store_true",
                    help="descend into categories the quest run already walked "
                         "(default: record them as children but do not re-walk)")
    ap.add_argument("--delay", type=float, default=1.0, help="seconds between requests")
    ap.add_argument("--limit", type=int, default=0, help="stop after N candidate fetches (0 = all)")
    ap.add_argument("--refresh", action="store_true", help="conditional re-fetch of cached pages")
    ap.add_argument("--enumerate-only", action="store_true",
                    help="walk directories and write the manifest, fetch no content pages")
    ap.add_argument("--dry-run", action="store_true", help="no network at all; prove the plan")
    args = ap.parse_args()

    if os.path.basename(args.manifest) == "manifest.json":
        sys.exit("refusing to write manifest.json -- it is quest-scoped and holds the "
                 "quest corpus provenance. Use e.g. manifest-missions.json.")
    if not args.category and not args.titles_file:
        sys.exit("need --category (directory walk) or --titles-file (explicit list)")

    fetcher = Fetcher(delay=args.delay, dry_run=args.dry_run)
    started = utcnow()

    print("indexing existing cache ...", flush=True)
    p_by_id, p_by_title = build_cache_index("pages")
    d_by_id, d_by_title = build_cache_index("directories")
    print("  pages/ %d records, directories/ %d records" % (len(p_by_id), len(d_by_id)), flush=True)

    # --- probe -------------------------------------------------------------------
    probe = {"ok": False, "endpoint": "%s/page/Recollections" % REST_BASE}
    if not args.dry_run:
        try:
            d, st, _ = fetcher.get(probe["endpoint"])
            probe.update({
                "ok": True, "trailing_slash_used": False,
                "page_id": d.get("id"), "key": d.get("key"), "title": d.get("title"),
                "revision_id": (d.get("latest") or {}).get("id"),
                "revision_timestamp": (d.get("latest") or {}).get("timestamp"),
                "content_model": d.get("content_model"),
                "has_source": bool(d.get("source")),
                "source_length": len(d.get("source") or ""),
            })
            print("probe ok: page_id=%s rev=%s" % (probe["page_id"], probe["revision_id"]), flush=True)
        except Exception as e:
            sys.exit("probe FAILED (%s): refusing to start a bulk run" % e)

    # --- directory-graph walk ----------------------------------------------------
    #[[ The quest fence. Category:Missions lists Category:Missions and Quests among its
    #   children, and that one leads straight into Category:Quests and all 55 of its
    #   child directories. Descending would re-walk the entire quest corpus to rediscover
    #   1447 titles that are already cached, for nothing.
    #
    #   The fence is taken from the quest run's OWN manifest rather than from a hand-typed
    #   denylist, so it cannot drift: whatever that run walked, this one does not re-walk.
    #   Fenced children are still RECORDED in child_directories. Category:Missions
    #   reaching quest territory is exactly the duplicate hazard the collision report
    #   has to answer, so it must stay visible in the manifest. ]]
    quest_fence = set()
    if not args.no_quest_fence:
        qm = os.path.join(CACHE, "manifest.json")
        if os.path.isfile(qm):
            with open(qm, encoding="utf-8") as f:
                qman = json.load(f)
            for e in qman.get("directory_pages") or []:
                for t in (e.get("requested_title"), e.get("title")):
                    if t:
                        quest_fence.add(t.lstrip(":"))
            print("quest fence: %d directories already walked by the quest run"
                  % len(quest_fence), flush=True)

    root = args.category
    descend_re = re.compile(args.descend_pattern)
    #[[ An empty queue when only --titles-file was given, so the whole walk below
    #   runs zero iterations rather than being wrapped in a conditional. The seed
    #   and fetch stages after it are shared verbatim. ]]
    queue = [(root, 0)] if root else []
    seen_dirs = set()
    fenced = []
    off_topic = []
    directory_pages = []
    candidate_evidence = {}

    def add_candidate(title, ev):
        candidate_evidence.setdefault(title, []).append(ev)

    while queue:
        title, depth = queue.pop(0)
        if title in seen_dirs:
            continue
        seen_dirs.add(title)
        rec, status = fetch_page(fetcher, title, "directories", d_by_id, d_by_title,
                                 refresh=args.refresh)
        if rec is None:
            directory_pages.append({"requested_title": title, "title": title,
                                    "status": status, "analysis": {}})
            print("  DIR %-52s %s" % (title, status), flush=True)
            continue
        n = rec["normalized"]
        html = n.get("html") or ""
        links = links_from_html(html)
        children, members = [], []
        for l in links:
            if l.startswith(":Category:"):
                children.append(l)
            elif l.startswith("Category:"):
                children.append(l)
            elif l.startswith(SKIP_NS):
                continue
            else:
                members.append(l)
        for l in members:
            add_candidate(l, {"source": "rest_directory_link",
                              "directory": n["title"], "depth": depth})
        directory_pages.append({
            "requested_title": title, "title": n["title"], "pageid": n["page_id"],
            "revision_id": n["revision_id"], "revision_timestamp": n["revision_timestamp"],
            "cache_file": os.path.join("directories", d_by_title.get(n["title"], {}).get("file", "")),
            "status": "ok",
            "analysis": {
                "title": n["title"],
                "child_directories": sorted(set(children)),
                "mission_candidates": members,
                "table_count": html.count("<table"),
                "direct_link_count": len(members),
            },
        })
        print("  DIR %-52s %-9s children=%-3d candidates=%d"
              % (title, status, len(set(children)), len(members)), flush=True)
        if depth < args.max_depth:
            for c in sorted(set(children)):
                c = c.lstrip(":")
                if c in seen_dirs:
                    continue
                if c in quest_fence:
                    fenced.append({"category": c, "reached_from": n["title"]})
                    continue
                if not descend_re.search(c):
                    off_topic.append({"category": c, "reached_from": n["title"]})
                    continue
                queue.append((c, depth + 1))

    # --- seeds -------------------------------------------------------------------
    seeds = []
    if args.titles_file:
        n_titles = 0
        with open(args.titles_file, encoding="utf-8") as f:
            for line in f:
                #[[ '#' is a comment only in column one. It is also a legal and
                #   load-bearing character inside a title ("VW Op. #050: Aht
                #   Urhgan Assault"), so an inline-comment rule silently
                #   truncates that to "VW Op." and fetches a page that does not
                #   exist. ]]
                t = line.strip()
                if not t or t.startswith("#"):
                    continue
                add_candidate(t, {"source": "explicit_title",
                                  "titles_file": os.path.basename(args.titles_file)})
                n_titles += 1
        print("seeded %d title(s) from %s" % (n_titles, args.titles_file), flush=True)
    if args.seed_dat_names:
        seed_rows = read_dat_names(args.seed_namespace)
        for area, ids in sorted(seed_rows.items()):
            for mid, nm in sorted(ids.items()):
                add_candidate(nm, {"source": "dat_names_seed",
                                   "namespace": args.seed_namespace,
                                   "area": area, "dat_id": mid})
                seeds.append(nm)
        seeds = sorted(set(seeds))
        print("seeded %d unique titles (%d ids) from dat_names.%s across %d areas"
              % (len(seeds), sum(len(v) for v in seed_rows.values()),
                 args.seed_namespace, len(seed_rows)), flush=True)

    candidates = sorted(candidate_evidence)
    print("candidates: %d unique" % len(candidates), flush=True)

    # --- fetch candidates --------------------------------------------------------
    results = []
    counts = {"fetched": 0, "cached": 0, "refreshed": 0, "not_found": 0, "error": 0}
    if not args.enumerate_only:
        todo = candidates[: args.limit] if args.limit else candidates
        for i, title in enumerate(todo, 1):
            rec, status = fetch_page(fetcher, title, "pages", p_by_id, p_by_title,
                                     refresh=args.refresh)
            base = status.split(":", 1)[0]
            counts[base if base in counts else "error"] = counts.get(base, 0) + 1
            entry = {"requested_title": title, "status": status,
                     "evidence": candidate_evidence[title]}
            if rec:
                n = rec["normalized"]
                entry.update({
                    "title": n["title"], "pageid": n["page_id"],
                    "revision_id": n["revision_id"],
                    "revision_timestamp": n["revision_timestamp"],
                    "content_model": n["content_model"],
                    "cache_file": os.path.join("pages", cache_filename(n["page_id"], n["title"])),
                    "categories": n["categories"],
                    "is_redirect": is_redirect(rec),
                    "redirect_target": redirect_target(rec),
                    "source_length": len(n["source"] or ""),
                })
            results.append(entry)
            if i % 25 == 0 or i == len(todo):
                print("  [%4d/%4d] %s" % (i, len(todo), status), flush=True)

        # Follow redirects one hop. "#REDIRECT [[X]] means fetch X next" is normal,
        # not a dead end.
        hops = [e["redirect_target"] for e in results
                if e.get("is_redirect") and e.get("redirect_target")]
        hops = [h for h in sorted(set(hops)) if h not in candidate_evidence]
        if hops:
            print("following %d redirect targets ..." % len(hops), flush=True)
            for title in hops:
                rec, status = fetch_page(fetcher, title, "pages", p_by_id, p_by_title)
                base = status.split(":", 1)[0]
                counts[base if base in counts else "error"] = counts.get(base, 0) + 1
                entry = {"requested_title": title, "status": status,
                         "evidence": [{"source": "redirect_target"}]}
                if rec:
                    n = rec["normalized"]
                    entry.update({
                        "title": n["title"], "pageid": n["page_id"],
                        "revision_id": n["revision_id"],
                        "cache_file": os.path.join("pages", cache_filename(n["page_id"], n["title"])),
                        "categories": n["categories"],
                        "is_redirect": is_redirect(rec),
                        "redirect_target": redirect_target(rec),
                        "source_length": len(n["source"] or ""),
                    })
                results.append(entry)

    ok = [e for e in results if e.get("pageid")]
    #[[ A titles-file run has no root category, so "is this page in the root"
    #   is not a question that has an answer. `None in categories` is False for
    #   every page, which would be a confident answer to a question nobody
    #   asked. Report it as empty and let the manifest's category_enumeration
    #   record the run's actual basis instead. ]]
    in_root = ([e for e in ok if args.category in (e.get("categories") or [])]
               if args.category else [])
    manifest = {
        "schema": MANIFEST_SCHEMA,
        "started_at_utc": started,
        "updated_at_utc": utcnow(),
        "completed_at_utc": utcnow(),
        "transport": TRANSPORT_RUN,
        "rest_base_url": REST_BASE,
        "category": args.category,
        "probe": probe,
        "category_enumeration": {
            "source": ("rest_directory_graph_walk" if args.category
                       else "explicit_titles_file"),
            "root_category": args.category,
            "titles_file": (os.path.basename(args.titles_file)
                            if args.titles_file else None),
            "root_endpoint": ("%s/page/%s/with_html"
                              % (REST_BASE, api_title(args.category))
                              if args.category else None),
            "normal_html_category_requests_used": False,
            "directory_page_count": len(directory_pages),
            "candidate_title_count": len(candidates),
            "seed_candidate_count": len(seeds),
            "seed_source": ("data/dat_names.lua:%s" % args.seed_namespace) if seeds else None,
            "descend_pattern": args.descend_pattern,
            "quest_fenced_directories": fenced,
            "off_topic_directories": sorted({d["category"] for d in off_topic}),
            "candidate_evidence": candidate_evidence,
        },
        "directory_pages": directory_pages,
        "candidate_results": results,
        "pages": ok,
        "summary": {
            "cache_policy": "resume_missing_only",
            "candidate_title_count": len(candidates),
            "processed_candidate_count": len(results),
            "discovered_page_count": len(ok),
            "direct_category_member_count": len(in_root),
            "fetched_count": counts["fetched"],
            "refreshed_count": counts["refreshed"],
            "cached_count": counts["cached"],
            "not_found_candidate_count": counts["not_found"],
            "failed_count": counts["error"],
            "request_count": fetcher.requests,
            "normal_html_category_requests_used": False,
        },
    }
    path = os.path.join(CACHE, os.path.basename(args.manifest))
    with open(path, "w", encoding="utf-8") as f:
        json.dump(manifest, f, ensure_ascii=False, indent=1)
    print("\nwrote %s" % path)
    print("  directories %d  candidates %d  pages %d  (fetched %d, cached %d, "
          "refreshed %d, 404 %d, err %d)  requests %d"
          % (len(directory_pages), len(candidates), len(ok), counts["fetched"],
             counts["cached"], counts["refreshed"], counts["not_found"],
             counts["error"], fetcher.requests))


if __name__ == "__main__":
    main()
