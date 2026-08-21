"""Bind a BG Wiki page title to the game's own quest id.

The wiki has no numeric quest id anywhere (an exhaustive scan of the 3414
cached pages finds none), so the page title is the only identity, and the only
bridge to something the addon can track is the client's own DAT name table
(data/dat_names.lua, dumped to build/res.json).

The binding is not exhaustive and is not meant to be: a page the ladder leaves
ambiguous, or whose title is genuinely absent from the DAT, is left unbound
rather than guessed at.

Build-time only.
"""

import re
import unicodedata

# ---------------------------------------------------------------------------
# normalisation
# ---------------------------------------------------------------------------

_QUOTES = {
    "’": "'", "‘": "'",
    "“": '"', "”": '"',
    "–": "-", "—": "-",
}


def norm(s):
    """Fold a title or DAT name to a comparison key.

    Deleting '#' is not cosmetic: the wiki writes "Dominion Op 01 (Altepa)"
    while the DAT writes "Dominion Op #01 (Altepa)", and that single character
    accounts for 51 of the authored records.
    """
    if s is None:
        return ""
    s = unicodedata.normalize("NFKD", s)
    for a, b in _QUOTES.items():
        s = s.replace(a, b)
    s = s.replace("#", "")
    s = re.sub(r"[^0-9A-Za-z']+", " ", s)
    return s.strip().lower()


def strip_trailing_paren(s):
    return re.sub(r"\s*\([^)]*\)\s*$", "", s)


def s_to_bracket(s):
    """BG Wiki writes past-era names "(S)"; the client writes "[S]"."""
    return re.sub(r"\s*\(\s*[Ss]\s*\)\s*$", " [S]", s)


# The trailing parenthetical on a wiki title is usually a disambiguator, and
# for these values it names the DAT area. That is how three families of
# same-named quests are told apart.
AREA_HINTS = {
    "bastok": "bastok",
    "san d'oria": "sandoria",
    "sandoria": "sandoria",
    "windurst": "windurst",
    "jeuno": "jeuno",
    "kazham": "outlands",
    "altepa": "abyssea",
    "grauberg": "abyssea",
    "uleguerand": "abyssea",
    "attohwa": "abyssea",
    "misareaux": "abyssea",
    "vunkerl": "abyssea",
    "la theine": "abyssea",
    "konschtat": "abyssea",
    "tahrongi": "abyssea",
}


def area_hint(title):
    m = re.search(r"\(([^)]*)\)\s*$", title or "")
    if not m:
        return None
    return AREA_HINTS.get(norm(m.group(1)).replace(" ", " "))


# ---------------------------------------------------------------------------
# the index
# ---------------------------------------------------------------------------


class DatIndex:
    """dat['quest'][area][id] = name, inverted for lookup by normalised name.

    Three tiers, consulted in order, because collapsing them loses real
    distinctions:

      by_exact  the DAT string verbatim. `Curses, Foiled Again!` and
                `Curses, Foiled...Again!?` are two different quests (windurst
                32 and 33) that differ ONLY in punctuation, which norm() throws
                away. Without this tier both pages are ambiguous and neither
                binds.
      by_name   normalised, which is what absorbs '#', curly quotes and
                "(S)" vs "[S]".
      by_half   one half of a slash-merged DAT name. Strictly weaker: `The Old
                Lady` is both an exact id (other 10) and half of `Elder
                Memories/The Old Lady` (other 24), and the exact one must win.
    """

    def __init__(self, dat, cat="quest"):
        self.cat = cat
        self.by_exact = {}
        self.by_name = {}
        self.by_half = {}
        self.n = 0
        for area, ids in (dat.get(cat) or {}).items():
            for sid, name in ids.items():
                rec = (cat, area, int(sid), name)
                self.n += 1
                self.by_exact.setdefault(name.strip(), []).append(rec)
                self.by_name.setdefault(norm(name), []).append(rec)
                if "/" in name:
                    for half in name.split("/"):
                        if half.strip():
                            self.by_half.setdefault(norm(half), []).append(rec)

    def _pick(self, hits, title):
        uniq = list({(h[0], h[1], h[2]): h for h in hits}.values())
        if len(uniq) == 1:
            return uniq[0], None
        hint = area_hint(title)
        if hint:
            narrowed = [h for h in uniq if h[1] == hint]
            if len(narrowed) == 1:
                return narrowed[0], None
        return None, "ambiguous_dat_id"

    def bind(self, title, overrides=None):
        """-> (record, rule, error).

        A hand pin wins outright. Otherwise: verbatim, then normalised, then
        slash-halves; and within each tier the title is tried as written before
        anything is stripped from it. Stripping the parenthetical is LAST
        because it is the lossy step: `Eco-Warrior` is one bare DAT name in
        three different areas while the wiki disambiguates it, so stripping
        without re-disambiguating would collapse three distinct quests into one.
        """
        if overrides and title in overrides:
            o = overrides[title]
            if o is None:
                return None, "override", "excluded_by_hand"
            return (self.cat, o["area"], int(o["id"]),
                    o.get("dat_name", title)), "manual", None

        forms = [
            (title, "exact"),
            (s_to_bracket(title), "s_bracket"),
            (re.sub(r"\s*\(Quest\)\s*$", "", title), "quest_suffix"),
            (strip_trailing_paren(title), "paren_strip"),
        ]

        # Verbatim first: punctuation is the only thing separating a couple of
        # genuinely distinct quests, and norm() deletes it.
        for cand, rule in forms:
            hits = self.by_exact.get(cand.strip())
            if hits:
                rec, err = self._pick(hits, title)
                if rec:
                    return rec, rule + "_verbatim", None

        last_err = None
        for table, tier in ((self.by_name, ""), (self.by_half, "_half")):
            seen = set()
            for cand, rule in forms:
                key = norm(cand)
                if not key or key in seen:
                    continue
                seen.add(key)
                hits = table.get(key)
                if not hits:
                    continue
                rec, err = self._pick(hits, title)
                if rec:
                    return rec, rule + tier, None
                last_err = err
        return None, None, last_err or "no_dat_id"
