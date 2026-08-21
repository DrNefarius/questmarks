#!/usr/bin/env python3
"""mission_identity.py: bind cached BG Wiki mission pages to `mission/<area>/<id>`.

The addon keys by cat/area/id, so a mis-bound page writes one mission's ladder onto
another mission's marker. The join is exact, never fuzzy.

Mission pages open with `{{Mission Header}}`, which carries a field quests lack:
`|Mission Name=Immortal Sentries`. That proper name is what the client's DAT tables
hold (data/dat_names.lua, `mission` namespace, 843 ids). Don't map the wiki's mission
NUMBER onto a DAT id: ToAU wiki mission 2 is DAT id 1, and Zilart ids run
0,2,4,...,22,23,24,26 with gaps. That's why prerequisites like "Zilart Mission 17"
need the hand-built tools/lib/mission_numbers.lua.

Pages titled with the mission name ("Welcome t'Norg") fall back to their title. A name
hitting more than one DAT id, or none, is reported, never guessed. The same string can
appear in both the `quest` and `mission` DAT namespaces, so matches carry their
cross-namespace collisions.
"""

import argparse
import json
import os
import re
import sys
from collections import Counter, defaultdict

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.abspath(os.path.join(HERE, "..", ".."))
CACHE = os.path.join(ADDON, "bgwiki-rest-cache")

sys.path.insert(0, HERE)
from fetch_wiki import read_dat_names  # noqa: E402  (same package, shared parser)

MISSION_HEADER_RE = re.compile(r"\{\{\s*Mission\s+Header\b", re.IGNORECASE)
QUEST_HEADER_RE = re.compile(r"\{\{\s*Quest\s+Header\b", re.IGNORECASE)
#[[ Campaign Ops are missions to the INDEX (data/mission_index.lua carries 185 rows at
#   area='campaign') but not to the wiki's template scheme: they carry
#   `{{Campaign Header}}` and, measured over the whole cache, ZERO of the 217 pages in
#   Category:Campaign Ops carry `{{Mission Header}}`. So MISSION_HEADER_RE excludes
#   every one of them. build_bindings() loads only mission-header pages, so it cannot
#   see them at all. build_campaign_bindings() below is the separate join. ]]
CAMPAIGN_HEADER_RE = re.compile(r"\{\{\s*Campaign\s+Header\b", re.IGNORECASE)

#[[ Category -> area. The wiki's own mission category is what separates lines that
#   share a mission NAME, and they do share them: all three nations run the same
#   rank-5 story, so "Magicite" is bastok/13 AND sandoria/13 AND windurst/13, and
#   "Bastok Mission 4-1" cannot be bound by name alone. The category is the page's own
#   statement about which line it belongs to, so it is evidence rather than a guess.
#
#   It is also used the other way round, as a CROSS-CHECK: when the name binds to
#   exactly one id but the category says a different area, that is a mis-bind and is
#   reported rather than accepted. A silent mis-bind writes one mission's ladder onto
#   another mission's marker, which is the wrong-destination failure this project
#   forbids outright. ]]
CATEGORY_AREA = {
    "Category:Bastok Missions": "bastok",
    "Category:Windurst Missions": "windurst",
    "Category:San d'Oria Missions": "sandoria",
    "Category:Zilart Missions": "zilart",
    "Category:Promathia Missions": "cop",
    "Category:Aht Urhgan Missions": "toau",
    "Category:Wings of the Goddess Missions": "wotg",
    "Category:Seekers of Adoulin Missions": "adoulin",
    "Category:Rhapsodies of Vanadiel Missions": "rov",
    "Category:Crystalline Missions": "acp",
    "Category:A Moogle Kupo d'Etat Missions": "mkd",
    "Category:A Shantotto Ascension Missions": "asa",
    "Category:The Voracious Resurgence Missions": "tvr",
    "Category:Assault": "assault",
    "Category:Campaign Ops": "campaign",
}


def areas_from_categories(cats):
    return sorted({CATEGORY_AREA[c] for c in cats if c in CATEGORY_AREA})


#[[ Title prefix -> area. A page whose title positionally names its line is stating which
#   line it belongs to, and that outranks its category list when the two disagree.
#   "Promathia Mission 8-5" carries BOTH Category:Promathia Missions and
#   Category:Zilart Missions (the two lines share a finale NAME: cop/850 and zilart/31
#   are both "The Last Verse"), so the categories cannot separate them and the title can. ]]
TITLE_PREFIX_AREA = [
    ("Promathia Mission", "cop"),
    ("Aht Urhgan Mission", "toau"),
    ("Crystalline Mission", "acp"),
    ("Kupo Mission", "mkd"),
    ("A Shantotto Ascension Mission", "asa"),
    ("Seekers of Adoulin Mission", "adoulin"),
    ("Rhapsodies of Vanadiel Mission", "rov"),
    ("The Voracious Resurgence Mission", "tvr"),
    ("Bastok Mission", "bastok"),
    ("Windurst Mission", "windurst"),
    ("San d'Oria Mission", "sandoria"),
]


def area_from_title(title):
    for pre, area in TITLE_PREFIX_AREA:
        if (title or "").startswith(pre):
            return area
    return None


def dat_truncated_match(cand, m_by_name):
    """Bind a DAT name the client itself TRUNCATED with a trailing ellipsis.

    The client cuts its own string off: `data/dat_names.lua` carries mission/adoulin/294
    as 'The Light of Dawn Comes...' where the wiki page is 'The Light of Dawn Comes from
    the East'. No amount of name folding joins those, because one really is a prefix of
    the other rather than a spelling variant of it.

    Restricted to DAT names that literally end in '...', and still required to land on
    exactly one id, so it cannot fire on an ordinary short name."""
    out = []
    for k, v in m_by_name.items():
        if k and k.endswith("...") and cand and cand.startswith(k[:-3].rstrip()):
            out.extend(v)
    return out


def parse_template(src, name):
    """Return {field: value} for the first {{name ...}} template in src.

    Hand-written rather than delegated to a wikitext library because the cache is the
    only input this tree has and adding a parser dependency to a build tool that must
    run offline is not worth it. Brace and link depth are tracked so a `|` inside
    [[a|b]], {{!}} or a nested template does not split a field."""
    m = re.search(r"\{\{\s*%s\b" % name, src, re.IGNORECASE)
    if not m:
        return None
    i = m.end()
    depth, link, fields, buf = 2, 0, [], []
    while i < len(src):
        c2 = src[i:i + 2]
        if c2 == "{{":
            depth += 2
            buf.append(c2)
            i += 2
            continue
        if c2 == "}}":
            depth -= 2
            if depth <= 0:
                fields.append("".join(buf))
                break
            buf.append(c2)
            i += 2
            continue
        if c2 == "[[":
            link += 1
            buf.append(c2)
            i += 2
            continue
        if c2 == "]]":
            link = max(0, link - 1)
            buf.append(c2)
            i += 2
            continue
        if src[i] == "|" and depth == 2 and link == 0:
            fields.append("".join(buf))
            buf = []
            i += 1
            continue
        buf.append(src[i])
        i += 1
    out = {}
    for f in fields:
        if "=" not in f:
            continue
        k, v = f.split("=", 1)
        out[k.strip()] = v.strip()
    return out


def norm_name(s):
    """Fold a name for comparison only, never for output.

    The DAT strings and the wiki disagree on apostrophe glyph and on incidental
    whitespace, and on one systematic spelling: the client writes
    "Kazham's Chieftainess" where the wiki writes "Chieftainness"."""
    if s is None:
        return None
    s = re.sub(r"\{\{!\}\}", "|", s)
    s = re.sub(r"\[\[([^\]|]*)\|([^\]]*)\]\]", r"\2", s)
    s = re.sub(r"\[\[([^\]]*)\]\]", r"\1", s)
    s = re.sub(r"<[^>]+>", "", s)
    s = s.replace("’", "'").replace("‘", "'")
    s = s.replace("–", "-").replace("—", "-")
    s = re.sub(r"\s+", " ", s).strip().casefold()
    s = s.replace("chieftainness", "chieftainess")
    return s


def relax_name(s):
    """Last-resort fold: articles and punctuation gone entirely.

    Only a second chance, after an exact match has failed, and only when it lands on
    exactly one id whose area the page's own category agrees with. The client and the
    wiki disagree in two small, systematic ways that are not different missions:

        apostrophe position   DAT "Sentinel's Honor"        wiki "Sentinels' Honor"
        a leading/inner article
                              DAT "The Call of the Wyrmking" wiki "Call of the Wyrmking"
                              DAT "A Vessel Without a Captain" wiki "Vessel Without a Captain"
                              DAT "Affairs of State"         wiki "Affairs of the State"

    Folding all 843 DAT mission names this way produces zero collisions within any
    area, so no two missions in one line become the same string. `relax_key` in
    tools/build_index.lua already does the punctuation half."""
    s = norm_name(s) or ""
    s = re.sub(r"\b(the|a|an)\b", "", s)
    return re.sub(r"[^a-z0-9]+", "", s)


def load_cache(only_missions=True, only_campaign=False):
    out = []
    d = os.path.join(CACHE, "pages")
    for fn in sorted(os.listdir(d)):
        if not fn.endswith(".json"):
            continue
        with open(os.path.join(d, fn), encoding="utf-8") as f:
            rec = json.load(f)
        n = rec.get("normalized") or {}
        src = n.get("source") or ""
        has_mh = bool(MISSION_HEADER_RE.search(src))
        has_ch = bool(CAMPAIGN_HEADER_RE.search(src))
        if only_campaign:
            if not has_ch:
                continue
        elif only_missions and not has_mh:
            continue
        #[[ Redirect records, and why they have to be dropped by identity rather than
        #   by content.
        #
        #   `/page/X` returns the redirect STUB but `/page/X/with_html` FOLLOWS the
        #   redirect and returns the TARGET. Combine the two without noticing and the
        #   cache gains a record whose `page` block is the redirect while
        #   `normalized.source` is the target's full wikitext. The cache holds such
        #   records: 0016324_immortal_sentries_f3f2d7f4ab.json is page id 16324,
        #   "Immortal Sentries", rev 39043. It looks exactly like a real mission page
        #   and binds to the same DAT id as the real one, so without this filter
        #   mission/toau/1 is claimed by both "Aht Urhgan Mission 2" (13662) and
        #   "Immortal Sentries" (16324). Authoring both would write two records for
        #   one identity, and the addon keys by cat/area/id, so both would draw.
        #
        #   The record carries its own tell: on a genuine page the source and the html
        #   describe the SAME page id. On a redirect record they differ. That is a fact
        #   already in the cache, so no re-fetch is needed to detect it. ]]
        pid = (rec.get("page") or {}).get("id")
        hid = (rec.get("html_page") or {}).get("id")
        redirect_record = (pid is not None and hid is not None and pid != hid)
        out.append({
            "redirect_record": redirect_record, "html_page_id": hid,
            "file": fn, "page_id": n.get("page_id"), "title": n.get("title"),
            "revision_id": n.get("revision_id"),
            "source_sha256": (rec.get("integrity") or {}).get("source_sha256"),
            "categories": n.get("categories") or [],
            "source": src,
            "has_mission_header": has_mh,
            "has_campaign_header": has_ch,
            "has_quest_header": bool(QUEST_HEADER_RE.search(src)),
        })
    return out


def build_campaign_bindings():
    """Campaign Ops pages -> `mission/campaign/<id>`. -> rows, same shape as
    build_bindings().

    The join is the full page title matched exactly against the DAT name. A Campaign
    Op page is titled with the op's own name including its nation suffix, "Stock and
    Awe I (S)", and data/dat_names.lua spells the campaign namespace the same way:
    246 DAT campaign ids, 207 cached pages, 207 of 207 titles hitting exactly one DAT
    name, no ambiguity.

    Do NOT strip that suffix. The same op runs for all three nations, so dropping
    "(S)/(W)/(B)" collapses 207 titles onto 83, and 76 of those get claimed by more
    than one page. The match has to be exact on the whole string.

    `{{Campaign Header}}` has no `Mission Name` field, so the title is the only
    evidence here and it is checked, not trusted: a title matching no DAT name, or a
    DAT name carried by two pages, stays unbound. The nation suffix is what
    separates them: 'Aegis Scream I (B)' is 191 and '(S)' is 21."""
    dat_m = read_dat_names("mission")
    camp = dat_m.get("campaign") or {}

    #[[ Built both ways so a DAT name carried by two ids, or a title carried by two
    #   pages, is REFUSED rather than silently resolved to whichever came last. ]]
    by_name = defaultdict(list)
    for i, nm in camp.items():
        by_name[nm].append(i)

    allpages = load_cache(only_campaign=True)
    redirects = [p for p in allpages if p["redirect_record"]]
    pages = [p for p in allpages if not p["redirect_record"]]
    title_count = Counter(p["title"] for p in pages)

    rows = []
    for p in pages:
        hits = by_name.get(p["title"], [])
        row = {
            "page_id": p["page_id"], "title": p["title"],
            "revision_id": p["revision_id"], "source_sha256": p["source_sha256"],
            "cache_file": p["file"], "categories": p["categories"],
            "mission_name": None,
            "match_rule": "campaign_page_title",
            "match_conf": None,
            "cat": "mission", "area": None, "id": None, "dat_name": None,
            "also_quest_header": p["has_quest_header"],
        }
        if len(hits) == 1 and title_count[p["title"]] == 1:
            row.update({"area": "campaign", "id": hits[0], "dat_name": p["title"],
                        "match_conf": "exact"})
        elif hits:
            row["candidates"] = [{"area": "campaign", "id": i, "name": p["title"]}
                                 for i in hits]
            row["match_conf"] = "ambiguous"
        rows.append(row)
    return rows, redirects, camp


def build_bindings():
    """The one binder. -> (rows, redirects, dat_mission)

    A function rather than inline in main() so mission_prepass.py consumes this result
    instead of re-implementing the join. Do not re-implement it with a first-hit loop:
    taking "the first hit" where this binder refuses an ambiguous match is a second,
    different answer for the same page.

    Every row carries `area`/`id` when bound and `None` when not. Nothing is guessed:
    ambiguous stays ambiguous and unmatched stays unmatched, because a mis-bind writes
    one mission's ladder onto another mission's marker."""
    dat_m = read_dat_names("mission")
    dat_q = read_dat_names("quest")

    m_by_name = defaultdict(list)
    for area, ids in dat_m.items():
        for i, nm in ids.items():
            m_by_name[norm_name(nm)].append((area, i, nm))
    q_by_name = defaultdict(list)
    for area, ids in dat_q.items():
        for i, nm in ids.items():
            q_by_name[norm_name(nm)].append((area, i, nm))

    allpages = load_cache(only_missions=True)
    redirects = [p for p in allpages if p["redirect_record"]]
    pages = [p for p in allpages if not p["redirect_record"]]

    rows = []
    for p in pages:
        hdr = parse_template(p["source"], "Mission Header") or {}
        mname = hdr.get("Mission Name") or ""
        used = "header_mission_name"
        cand = norm_name(mname)
        if not cand or cand not in m_by_name:
            cand2 = norm_name(p["title"])
            if cand2 in m_by_name:
                cand, used = cand2, "page_title"

        hits = m_by_name.get(cand or "", [])
        cat_areas = areas_from_categories(p["categories"])
        # A positional title states its own line, and outranks the category list when
        # the page is filed under two lines that share a mission name.
        t_area = area_from_title(p["title"])
        if t_area and len(hits) > 1 and any(h[0] == t_area for h in hits):
            cat_areas = [t_area]
        # Narrow by the page's own category before calling anything ambiguous.
        narrowed = [h for h in hits if h[0] in cat_areas] if cat_areas else []
        disambiguated = len(hits) > 1 and len(narrowed) == 1
        mismatch = None
        if len(hits) == 1 and cat_areas and hits[0][0] not in cat_areas:
            mismatch = {"name_area": hits[0][0], "category_areas": cat_areas}
        if narrowed:
            hits = narrowed

        #[[ Second chance, relaxed fold. ONLY after an exact match has failed, must land
        #   on exactly one id, and the page's own category must agree with that id's
        #   area. All three, or it stays unmatched. See relax_name() for why the fold is
        #   safe (measured: zero within-area collisions over all 843 DAT names). ]]
        relaxed_used = truncated_used = False
        if not hits:
            want = relax_name(cand)
            alt = [h for k, v in m_by_name.items() if relax_name(k) == want for h in v]
            alt = [h for h in alt if not cat_areas or h[0] in cat_areas]
            if len(alt) == 1:
                hits, relaxed_used = alt, True
        if not hits:
            alt = dat_truncated_match(cand, m_by_name)
            alt = [h for h in alt if not cat_areas or h[0] in cat_areas]
            if len(alt) == 1:
                hits, truncated_used = alt, True

        row = {
            "page_id": p["page_id"], "title": p["title"],
            "revision_id": p["revision_id"], "source_sha256": p["source_sha256"],
            "cache_file": p["file"], "categories": p["categories"],
            "mission_name": mname or None,
            "match_rule": used if hits else None,
            "match_conf": None,
            "cat": "mission", "area": None, "id": None, "dat_name": None,
            "start_raw": hdr.get("Start") or None,
            "previous_raw": hdr.get("Previous") or None,
            "next_raw": hdr.get("Next") or None,
            "expansion": hdr.get("Expansion") or None,
            "repeatable_raw": hdr.get("Repeatable") or None,
            "level_raw": hdr.get("Level") or None,
            "category_areas": cat_areas,
            "area_category_mismatch": mismatch,
            "also_quest_header": p["has_quest_header"],
            "quest_namespace_collisions": [
                {"area": a, "id": i, "name": nm}
                for a, i, nm in q_by_name.get(cand or "", [])
            ],
        }
        if not hits:
            pass                                   # unmatched; area/id stay None
        elif len(hits) > 1:
            row["candidates"] = [{"area": a, "id": i, "name": nm} for a, i, nm in hits]
            row["match_conf"] = "ambiguous"
        else:
            a, i, nm = hits[0]
            row.update({"area": a, "id": i, "dat_name": nm,
                        "match_conf": ("dat_name_truncated" if truncated_used
                                       else "relaxed_name" if relaxed_used
                                       else "category_disambiguated" if disambiguated
                                       else "exact")})
            if disambiguated:
                row["match_rule"] = (row["match_rule"] or "") + "+category"
            if relaxed_used:
                row["match_rule"] = (row["match_rule"] or "header_mission_name") + "+relaxed"
            if truncated_used:
                row["match_rule"] = (row["match_rule"] or "header_mission_name") + "+dat_truncated"
        rows.append(row)

    return rows, redirects, dat_m


def main():
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--out", help="write the full mapping as JSON")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    rows, redirects, dat_m = build_bindings()
    ambiguous = [r for r in rows if r["match_conf"] == "ambiguous"]
    unmatched = [r for r in rows if r["area"] is None and r["match_conf"] != "ambiguous"]
    matched = [r for r in rows if r["area"] is not None]
    seen_ident = {}
    dupe_bindings = []
    for r in matched:
        k = (r["area"], r["id"])
        if k in seen_ident:
            dupe_bindings.append((k, seen_ident[k], r))
        else:
            seen_ident[k] = r
    if not args.quiet:
        print("cached pages carrying {{Mission Header}}: %d" % (len(rows) + len(redirects)))
        print("  redirect records dropped   %d  (page.id != html_page.id)" % len(redirects))
        for r in redirects:
            print("     %-40s page %s -> html %s" % (r["title"], r["page_id"], r["html_page_id"]))
        print("  real mission pages         %d" % len(rows))
        print("  bound exactly            %d" % len(matched))
        print("  ambiguous (>1 DAT id)    %d" % len(ambiguous))
        print("  unmatched (no DAT name)  %d" % len(unmatched))
        print("  also carry {{Quest Header}}: %d"
              % sum(1 for r in rows if r["also_quest_header"]))
        print("  name ALSO in the quest DAT namespace: %d"
              % sum(1 for r in rows if r["quest_namespace_collisions"]))
        mism = [r for r in rows if r["area_category_mismatch"]]
        print("  AREA/CATEGORY MISMATCH (possible mis-bind): %d" % len(mism))
        for r in mism[:20]:
            print("    %-44s name->%s but category says %s" % (
                r["title"], r["area_category_mismatch"]["name_area"],
                ",".join(r["area_category_mismatch"]["category_areas"])))
        by_area = defaultdict(int)
        by_rule = defaultdict(int)
        for r in matched:
            by_area[r["area"]] += 1
            by_rule[r["match_rule"]] += 1
        print("\n  bound per area:")
        for a in sorted(by_area):
            print("    %-10s %4d of %4d DAT ids" % (a, by_area[a], len(dat_m.get(a, {}))))
        print("\n  by match rule: " + ", ".join("%s=%d" % kv for kv in sorted(by_rule.items())))
        if ambiguous:
            print("\n  AMBIGUOUS (must be resolved by hand, never guessed):")
            for r in ambiguous[:25]:
                print("    %-44s -> %s" % (r["title"],
                      ", ".join("%s/%s" % (c["area"], c["id"]) for c in r["candidates"])))
        if unmatched:
            print("\n  UNMATCHED (first 30):")
            for r in unmatched[:30]:
                print("    %-44s Mission Name=%r" % (r["title"], r["mission_name"]))

    if args.out:
        with open(args.out, "w", encoding="utf-8") as f:
            json.dump({"rows": rows,
                       "summary": {"pages": len(rows), "matched": len(matched),
                                   "ambiguous": len(ambiguous),
                                   "unmatched": len(unmatched)}},
                      f, ensure_ascii=False, indent=1)
        print("\nwrote %s" % args.out)


if __name__ == "__main__":
    main()
