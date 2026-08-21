#!/usr/bin/env python3
"""check_authored.py: prove every authored record's provenance is copied.

    python tools/pipeline/check_authored.py [--in build/authored] [glob]

Identity and source are copied verbatim from the rendered front matter, and
this gate is what enforces it. A `source_sha256` typed from
memory rather than copied is invisible: validate.py, emit_lua.py and the Lua
build carry the field and never check it. A wrong `identity.id` puts a real
reading on the wrong quest.

Per record, against build/rendered/<cache_file>.md: every key in SOURCE_KEYS
and IDENTITY_KEYS below, plus steps numbered 1..N with no gaps. source_sha256
is also checked against the cached page's own integrity block, so a stale
rendered file cannot launder a wrong hash. Build-time only; exit 1 on any
mismatch.
"""

import argparse
import glob
import gatelib
import re
import io
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, "..", ".."))
RENDERED = os.path.join(ADDON, "build", "rendered")
CACHE_PAGES = os.path.join(ADDON, "bgwiki-rest-cache", "pages")

SOURCE_KEYS = ["wiki_title", "page_id", "revision_id", "source_sha256", "cache_file"]
IDENTITY_KEYS = ["cat", "area", "id", "dat_name", "match_rule", "match_conf"]


def load(path):
    with io.open(path, encoding="utf-8") as f:
        return json.load(f)


_BY_IDENTITY = None


def _identity_index():
    """(cat, area, id) -> rendered path, for every rendered page.

    The identity is the real key. cache_file is only a usually-adequate proxy
    for it, because two rendered pages can share one: the destination splits
    render "Bastok Mission 2-3" once per DAT id, so mission/bastok/8 and /9
    both point at cache 0012758, and mission_prepass renders that same cached
    page a third time under its own header-derived identity. Look up by
    cache_file and you get whichever file the directory listed first, compared
    against a DIFFERENT quest's front matter. That reports as "identity.id = 9
    but the rendered page says 5" against a record that is correct.
    """
    global _BY_IDENTITY
    if _BY_IDENTITY is None:
        _BY_IDENTITY = {}
        for f in sorted(os.listdir(RENDERED)):
            if not f.endswith(".md"):
                continue
            try:
                with io.open(os.path.join(RENDERED, f), encoding="utf-8") as fh:
                    fm = json.loads(fh.read(6000).split("---")[1])
            except (ValueError, IndexError):
                continue
            k = (fm.get("cat"), fm.get("area"), fm.get("id"))
            if None in k:
                continue
            #[[ RANKED, because one identity can be rendered up to three ways
            #   and the wrong pick fails a correct record.
            #
            #     2  a hand PIN. It exists because the automatic rendering was
            #        inadequate, and it is the one carrying a resolved Giver
            #        block the author actually read.
            #     1  a CANONICAL article, reached directly, with no redirect.
            #     0  a redirect stub rendering. Same content, but its front
            #        matter records the hop, so its match_rule differs.
            #
            #   Without the rank, "Trial Size Trial by Ice" resolves to the stub
            #   purely because 0000520 sorts before 0038688. The record cites the
            #   canonical page correctly and is failed for the wrong
            #   match_rule. ]]
            rank = 2 if f.startswith("pin_") else (0 if fm.get("redirect_from") else 1)
            prev = _BY_IDENTITY.get(k)
            if prev is None or rank > prev[0]:
                _BY_IDENTITY[k] = (rank, os.path.join(RENDERED, f))
    return {k: v[1] for k, v in _BY_IDENTITY.items()}


def _rendered_path(cache_file, ident=None):
    """Locate the rendered .md for a record, by identity first.

    Falls back to the cache_file conventions below when the identity is not
    rendered at all. That is the legacy corpus, written before any page carried
    more than one.

    Two live conventions, and this tool is useless as a gate unless it accepts
    both. The older authoring convention was to strip the trailing 10-hex hash
    (`0000025_a_smudge_..._76e41bd6c3` -> `0000025_a_smudge_...`), and
    worklist.py's snapshot() still strips it, but prepass.py emits the REAL
    basename with the hash intact. So the 1256 records written under the older
    convention carry the stripped form, and every record written against
    current front matter carries the full one. Demanding either spelling fails
    1256 records or the 290 newer ones. The hash is redundant with the page id
    in front of it, so accepting both loses nothing.
    """
    if ident:
        hit = _identity_index().get(ident)
        if hit:
            return hit
    exact = os.path.join(RENDERED, cache_file + ".md")
    if os.path.isfile(exact):
        return exact
    key = _stem(cache_file)
    hits = [f for f in os.listdir(RENDERED)
            if f.endswith(".md") and _stem(f[:-3]) == key]
    return os.path.join(RENDERED, hits[0]) if len(hits) == 1 else None


def front_matter(cache_file, ident=None):
    """The rendered .md whose front matter the author was told to copy."""
    p = _rendered_path(cache_file, ident)
    if not p:
        return None, "no rendered file for cache_file %r" % cache_file
    with io.open(p, encoding="utf-8") as f:
        text = f.read()
    parts = text.split("---")
    if len(parts) < 3:
        return None, "rendered file has no front matter"
    try:
        return json.loads(parts[1]), None
    except ValueError as e:
        return None, "front matter is not JSON: %s" % e


#[[ EXACTLY a trailing _<10 hex>, anchored. A charset rstrip cannot do this:
#   "0000500_starting_a_flame" ends in 'e', which is a hex digit, so rstrip eats
#   into the title and "flame" becomes "flam". The stripped and hashed forms
#   then key differently, and every legacy record reports "no rendered file".
#   Anchor the pattern; do not strip a charset. ]]
_HASH_RE = re.compile(r"_[0-9a-f]{10}$")


def _stem(name):
    return _HASH_RE.sub("", name)


_CACHE_INDEX = None


def cache_sha(cache_file):
    """Same two-convention problem as _rendered_path, so the same tolerance.

    Built once and keyed on the hash-stripped stem, because the stripped form
    is the lossy one and is what the legacy corpus carries."""
    global _CACHE_INDEX
    p = os.path.join(CACHE_PAGES, cache_file + ".json")
    if not os.path.isfile(p):
        if _CACHE_INDEX is None:
            _CACHE_INDEX = {}
            for f in os.listdir(CACHE_PAGES):
                if f.endswith(".json"):
                    _CACHE_INDEX.setdefault(_stem(f[:-5]), []).append(f)
        hits = _CACHE_INDEX.get(_stem(cache_file), [])
        if len(hits) != 1:
            return None
        p = os.path.join(CACHE_PAGES, hits[0])
    try:
        return (load(p).get("integrity") or {}).get("source_sha256")
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser()
    gatelib.add_args(ap, "baseline-authored.txt")
    args = ap.parse_args()

    files = sorted(glob.glob(os.path.join(args.indir, args.pattern)))
    if not files:
        sys.exit("no authored files matched %s in %s\n"
                 "build/authored/ is committed, so an empty result usually\n"
                 "means --in points somewhere else. Pass --in with the\n"
                 "corpus directory, or drop the pattern to check all of it."
                 % (args.pattern, args.indir))

    #[[ The page cache is not in the repository. It is ~293 MB and .gitignore
    #   excludes bgwiki-rest-cache/pages/, so a fresh clone reaches this line
    #   with nothing to hash against. Say so and SKIP, rather than dying on a
    #   FileNotFoundError that emit_lua.py would report as "the authored corpus
    #   has a problem". That is a lie, and it blocks the whole contributor loop
    #   README's Contributing section describes.
    #
    #   Skipping is loud on purpose. This gate is the only thing standing
    #   between a hand-edited `source_sha256` and a broken audit trail, so a
    #   run without it must never be mistaken for a run that passed. ]]
    if not os.path.isdir(CACHE_PAGES):
        print("SKIPPED -- no page cache at %s"
              % os.path.relpath(CACHE_PAGES, ADDON))
        print("  This gate hashes each record's cached page to prove its "
              "provenance was COPIED,")
        print("  and cannot run without it. Your edit is NOT provenance-checked.")
        print("  Regenerate the cache with tools/pipeline/fetch_wiki.py to "
              "enable it (see README).")
        return

    n_rec, bad, warn = 0, [], []
    for path in files:
        rel = os.path.relpath(path, ADDON)
        try:
            recs = load(path)
        except ValueError as e:
            bad.append("%s: not valid JSON -- %s" % (rel, e))
            continue
        if not isinstance(recs, list):
            bad.append("%s: top level must be a LIST of records" % rel)
            continue
        for i, r in enumerate(recs):
            n_rec += 1
            src = r.get("source") or {}
            ident = r.get("identity") or {}
            cf = src.get("cache_file")
            where = "%s[%d] %s/%s/%s" % (rel, i, ident.get("cat"),
                                         ident.get("area"), ident.get("id"))
            if not cf:
                bad.append("%s: no source.cache_file" % where)
                continue
            fm, err = front_matter(
                cf, (ident.get("cat"), ident.get("area"), ident.get("id")))
            if err:
                bad.append("%s: %s" % (where, err))
                continue
            for k in SOURCE_KEYS:
                if k == "cache_file":
                    # spelled two ways on purpose; see _rendered_path
                    continue
                if src.get(k) != fm.get(k):
                    bad.append("%s: source.%s = %r but the rendered page says %r"
                               % (where, k, src.get(k), fm.get(k)))
            for k in IDENTITY_KEYS:
                if ident.get(k) != fm.get(k):
                    bad.append("%s: identity.%s = %r but the rendered page says %r"
                               % (where, k, ident.get(k), fm.get(k)))
            csha = cache_sha(cf)
            if csha is None:
                bad.append("%s: no cached page for %s" % (where, cf))
            elif src.get("source_sha256") != csha:
                bad.append("%s: source_sha256 does not match the CACHED page "
                           "(%r vs %r)" % (where, src.get("source_sha256"), csha))
            steps = r.get("steps")
            if not isinstance(steps, list) or not steps:
                bad.append("%s: no steps" % where)
                continue
            for j, s in enumerate(steps, 1):
                if s.get("n") != j:
                    bad.append("%s: step %d has n=%r" % (where, j, s.get("n")))
                #[[ ADVISORY, not fatal. A step with no source_bullets cannot be
                #   traced back to the sentence it was read from, which is worth
                #   knowing. The existing corpus has them, and this tool is a
                #   provenance gate, not a retro-active style rule. Counted so
                #   a NEW batch that stops citing bullets is visible without
                #   failing the whole corpus.
                #
                #   `[0]` means "not from a walkthrough bullet" and is the right
                #   answer, not a missing one. prepass.py numbers walkthrough
                #   bullets from 1, so 0 cannot collide with one. A coalition
                #   assignment's accept and turn-in steps genuinely come from the
                #   rendered Giver block: stage A resolved the Task Delegator's
                #   square from the coalition's own page. Citing a walkthrough
                #   bullet that says something else would be a worse lie than
                #   citing none. Empty `[]` is the ambiguous case: it reads the
                #   same as an author who simply did not fill it in. ]]
                if not s.get("source_bullets"):
                    warn.append("%s: step %d cites no source_bullets" % (where, j))
                #[[ The mob-count key. validate.py's validate() reads `count`;
                #   a record writing `n` loses the number silently, and
                #   kills.progress in core/kills.lua then wants 1 kill where the
                #   page said 6. All 1254 mob entries in the corpus use
                #   `count`; anything else is a typo with no downstream
                #   error. ]]
                for mob in (s.get("mobs") or []):
                    if "count" not in mob and "n" in mob:
                        bad.append("%s: step %d mob %r uses 'n'; validate.py "
                                   "reads 'count'" % (where, j, mob.get("name")))
                tgt = s.get("target")
                if tgt is not None and not isinstance(tgt, dict):
                    bad.append("%s: step %d target is %r" % (where, j, tgt))

    print("checked %d record(s) across %d file(s)" % (n_rec, len(files)))
    if warn:
        print("%d advisory: step(s) citing no source_bullets" % len(warn))
    bad, known = gatelib.apply(
        bad, args.baseline, args.write_baseline,
        "check_authored.py baseline -- provenance mismatches in the authored corpus",
        "provenance problem(s)")
    if bad:
        print("\n%d PROBLEM(S):" % len(bad))
        for b in bad:
            print("  " + b)
        sys.exit(1)
    print("all provenance fields match the rendered front matter and the cache")


if __name__ == "__main__":
    main()
