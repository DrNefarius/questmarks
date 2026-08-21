#!/usr/bin/env python3
"""check_grounded.py: every fact in a record must appear on that record's OWN page.

    python tools/pipeline/check_grounded.py [--in build/authored] [glob]

Reading a second page to resolve a NAME is allowed. Importing content from one
is not. The output can't tell them apart: an imported grid ref and a
read one are the same four characters. So every string that becomes marker data
(zone, grid, target names, object names, mob names) is checked against the
record's own page, rendered text and raw wikitext both. A miss is a marker
pointing where the source never said.

The sibling-heavy families are where this earns its keep. Over the 185
mission/campaign records in build/authored-quarantine/ it still reports 15,
mostly grid refs and zones lifted from another nation's matching op, plus
return-to-giver steps on pages with no such bullet. Page said `pos=I-9`, record
said `H-9`, copied from five siblings that agree with each other and not with
this one. The record flagged it in a note, but a note is prose and the grid
draws the marker. Re-derive with

    python tools/pipeline/check_grounded.py --in build/authored-quarantine

Two holes, because a gate trusted further than it goes does more harm than none:

  * Strings, not entities. It asks whether "I-9" is on the page, never whether
    it is that NPC's square. A record putting Rasdinice on I-9 passes
    mission/campaign/114: I-9 is on that page as Dilgeur's square, while the
    header gives Rasdinice `pos=J-9`.
  * The haystack includes our own output. coalition_prepass.py resolves a
    coalition giver from another page into the rendered .md, so 665 of 968
    coalition values get checked against something this pipeline wrote. That
    resolution is sound and cross-checked, just not by this tool.

Exit 1 on any ungrounded value. Build-time only.
"""

import argparse
import glob
import gatelib
import io
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, "..", ".."))
RENDERED = os.path.join(ADDON, "build", "rendered")
CACHE_PAGES = os.path.join(ADDON, "bgwiki-rest-cache", "pages")
_HASH_RE = re.compile(r"_[0-9a-f]{10}$")


def stem(n):
    return _HASH_RE.sub("", n)


def _find(directory, cache_file, ext):
    p = os.path.join(directory, cache_file + ext)
    if os.path.isfile(p):
        return p
    key = stem(cache_file)
    hits = [f for f in os.listdir(directory)
            if f.endswith(ext) and stem(f[:-len(ext)]) == key]
    return os.path.join(directory, hits[0]) if len(hits) == 1 else None


_BY_IDENTITY = None


def _identity_index():
    """(cat, area, id) -> rendered path, preferring a hand pin.

    The same lookup problem check_authored.py guards against, with a worse
    symptom. cache_file is not unique per identity: the destination splits
    render one cached page once per DAT id, and mission_prepass renders that
    page again under its own binding. Reading the wrong one here does not
    merely compare against the wrong front matter. It searches the wrong
    HAYSTACK, so a value the author's page states plainly is reported as
    unattested.

    The Windurst gate guards are the worked case: the pin lists all four with
    zone and square, mission_prepass's rendering of the same page lists none,
    and without the rank the record is failed for reading what it was given. A
    pin exists because the automatic rendering was inadequate, so it wins.
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


def page_text(cache_file, ident=None):
    """Rendered prose + raw wikitext, folded, as one haystack."""
    parts = []
    r = (ident and _identity_index().get(ident)) or _find(RENDERED, cache_file, ".md")
    if r:
        parts.append(io.open(r, encoding="utf-8").read())
    c = _find(CACHE_PAGES, cache_file, ".json")
    if c:
        try:
            d = json.load(io.open(c, encoding="utf-8"))
            parts.append((d.get("normalized") or {}).get("source") or "")
        except ValueError:
            pass
    return fold("\n".join(parts)) if parts else None


def fold(s):
    """Case- and punctuation-insensitive, so 'Vunkerl Inlet (S)' matches
    '[[Vunkerl Inlet (S)]]' and curly quotes match straight ones."""
    s = s.replace("’", "'").replace("‘", "'")
    return re.sub(r"[^0-9a-z']+", " ", s.lower())


#[[ A correction made in game cannot be grounded on the page, and that is the
#   whole point of it. "I stood there and the guard is at K-9" is worth more
#   than what the wiki says, and this gate would reject it precisely because
#   the page does not say K-9.
#
#   A field is exempt when the record's `human` block says a person changed
#   THAT field with basis "game". Only the named fields, never the whole
#   record: a player who corrected one grid ref has not vouched for the other
#   nineteen values on the page.
#
#   Exempt is not invisible. These are counted and listed on every run, the
#   same as the era-suffix normalisations, so nobody can park a bad value here
#   and have it disappear.
#
#   `human.fields` comes from edits.changed_paths and is finer-grained than
#   this tool's labels: it writes `steps[2].target.name` where values() says
#   `steps[2].target`, and `steps[2].mobs[1].name` where values() says
#   `steps[2].mob`. _canon folds the first vocabulary onto the second. A bare
#   `steps[23]`, which changed_paths emits when a whole step moved, covers
#   everything in that step by prefix. ]]
def _canon(path):
    path = re.sub(r"^(steps\[\d+\])\.target\b.*$", r"\1.target", path)
    path = re.sub(r"^(steps\[\d+\])\.mobs\[\d+\].*$", r"\1.mob", path)
    return path


def in_game_fields(rec):
    """Canonical field paths this record's owner corrected from play."""
    h = rec.get("human") or {}
    out = set()
    for entry in [h] + list(h.get("history") or []):
        if (entry or {}).get("basis") != "game":
            continue
        for f in entry.get("fields") or []:
            out.add(_canon(f))
    return out


def covered(label, fields):
    return any(label == f or label.startswith(f + ".") for f in fields)


def values(rec):
    """(label, value) pairs that become marker data. Deliberately NOT notes."""
    out = []
    st = rec.get("start") or {}
    for k in ("npc", "zone", "grid"):
        if st.get(k):
            out.append(("start.%s" % k, st[k]))
    for s in rec.get("steps") or []:
        n = s.get("n")
        for k in ("zone", "grid"):
            if s.get(k):
                out.append(("steps[%s].%s" % (n, k), s[k]))
        t = s.get("target") or {}
        if isinstance(t, dict) and t.get("name"):
            out.append(("steps[%s].target" % n, t["name"]))
        for m in s.get("mobs") or []:
            if m.get("name"):
                out.append(("steps[%s].mob" % n, m["name"]))
    return out


def main():
    ap = argparse.ArgumentParser()
    gatelib.add_args(ap, "baseline-grounded.txt")
    ap.add_argument("--quiet", action="store_true")
    args = ap.parse_args()

    #[[ Same guard as check_authored.py, for the same reason: the page cache is
    #   .gitignored, so a fresh clone has nothing to ground AGAINST. Skip
    #   loudly instead of raising FileNotFoundError, which emit_lua.py would
    #   otherwise report as a corpus failure and refuse to emit on. ]]
    if not os.path.isdir(CACHE_PAGES):
        print("SKIPPED -- no page cache at %s"
              % os.path.relpath(CACHE_PAGES, ADDON))
        print("  This gate checks each authored step against the words on its "
              "cached page,")
        print("  and cannot run without it. Your edit is NOT grounded-checked.")
        print("  Regenerate the cache with tools/pipeline/fetch_wiki.py to "
              "enable it (see README).")
        return

    files = sorted(glob.glob(os.path.join(args.indir, args.pattern)))
    n_rec, n_val, bad, nopage, norm, ingame = 0, 0, [], [], [], []
    for path in files:
        rel = os.path.relpath(path, ADDON)
        try:
            recs = json.load(io.open(path, encoding="utf-8"))
        except ValueError:
            continue
        for r in recs if isinstance(recs, list) else []:
            n_rec += 1
            ident = r.get("identity") or {}
            cf = (r.get("source") or {}).get("cache_file")
            key = "%s/%s/%s" % (ident.get("cat"), ident.get("area"), ident.get("id"))
            hay = page_text(cf, (ident.get("cat"), ident.get("area"),
                                 ident.get("id"))) if cf else None
            if hay is None:
                nopage.append("%s (%s)" % (key, cf))
                continue
            played = in_game_fields(r)
            for label, val in values(r):
                n_val += 1
                f = fold(str(val)).strip()
                if not f or f in hay:
                    continue
                if played and covered(label, played):
                    ingame.append("%s  %-22s %r (%s)"
                                  % (key, label, val,
                                     (r.get("human") or {}).get("by") or "unknown"))
                    continue
                #[[ A multi-option giver is several names, not one.
                #
                #   "Any Bastok Gate Guard" resolves to four real NPCs, and
                #   normalize_npc splits `snpc` on " or " so build_index gets
                #   one marker key per name. The joined string is therefore
                #   never on any page, because the page lists the guards on
                #   separate lines, while every PART of it is. Testing the join
                #   rejects a correct record for a punctuation choice this
                #   pipeline itself makes.
                #
                #   Each part still has to be grounded on its own, so an
                #   invented name cannot hide inside a list. ]]
                parts = [p.strip() for p in re.split(r"\s+or\s+", fold(str(val)))
                         if p.strip()]
                if len(parts) > 1 and all(p in hay for p in parts):
                    continue
                #[[ An era suffix is resolution, not import, and the two have to
                #   be told apart or this tool cannot be used as a gate.
                #
                #   A Wings-of-the-Goddess page often writes "Vunkerl Inlet" in
                #   prose while the zone the client knows is "Vunkerl Inlet (S)".
                #   Adding the suffix picks the right id for a place the page
                #   named; it invents nothing, and build_index.lua already has a
                #   past_era_twin rule for the same problem. Reported separately
                #   so the count stays visible, not silently accepted.
                #
                #   Changing a GRID from the page's I-9 to a sibling's H-9 is a
                #   different act entirely: the page named a square and the
                #   record names another. That stays fatal.
                #
                #   fold() has already dropped the parentheses, so the era
                #   suffix arrives here as a trailing bare " s". ]]
                base = re.sub(r"\s+s$", "", f).strip()
                if base and base != f and base in hay:
                    norm.append("%s  %-22s %r (page says %r)"
                                % (key, label, val, base))
                    continue
                #[[ A grid ref written without its hyphen. Pages write both
                #   "(K-8)" and "(K8)"; fold() keeps the digit separate in one
                #   and not the other, so the same square reads as two strings.
                #   Squashing the space is not a normalisation of MEANING. ]]
                if re.match(r"^[a-z] \d+$", f) and f.replace(" ", "") in hay.replace(" ", ""):
                    continue
                #[[ The page's name is a shortening of the recorded one. BG Wiki
                #   writes "Zvahl Keep (S)" for the zone the client calls
                #   "Castle Zvahl Keep (S)". Expanding a short form to the full
                #   zone name resolves an id for a place the page named; it is
                #   the same act as adding the era suffix. Requires the page's
                #   form to be a SUBSTRING of the recorded one, which an
                #   unrelated name cannot satisfy. ]]
                shortened = [h for h in (base, f) if h and h in hay]
                if not shortened:
                    words = f.split()
                    if len(words) > 2 and " ".join(words[1:]) in hay:
                        norm.append("%s  %-22s %r (page writes the short form %r)"
                                    % (key, label, val, " ".join(words[1:])))
                        continue
                bad.append("%s  %-22s %-28r  [%s]"
                           % (key, label, val, os.path.basename(rel)))

    print("checked %d value(s) across %d record(s) in %d file(s)"
          % (n_val, n_rec, len(files)))
    if norm:
        print("%d era-suffix normalisation(s) accepted (base name is on the page):"
              % len(norm))
        for n in norm[:6]:
            print("    " + n)
        if len(norm) > 6:
            print("    ... and %d more" % (len(norm) - 6))
    if ingame:
        print("%d value(s) accepted on an in-game correction (not on the page, "
              "and not meant to be):" % len(ingame))
        for g in ingame[:8]:
            print("    " + g)
        if len(ingame) > 8:
            print("    ... and %d more" % (len(ingame) - 8))
    if nopage and not args.quiet:
        print("%d record(s) with no page on disk" % len(nopage))
    bad, known = gatelib.apply(
        bad, args.baseline, args.write_baseline,
        "check_grounded.py baseline -- values not attested on their own page",
        "ungrounded value(s)")
    if bad:
        print("\n%d NEW VALUE(S) NOT ON THEIR OWN PAGE:" % len(bad))
        for b in bad:
            print("  " + b)
        sys.exit(1)
    print("no NEW ungrounded value(s); %d known and listed in the baseline" % known)


if __name__ == "__main__":
    main()
