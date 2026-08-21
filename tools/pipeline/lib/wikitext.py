"""Render BG Wiki markup into text a reader can follow.

Presentation only. Nothing here decides what a step is, which NPC it targets,
or whether anything is evidence: that is the reading pass's job. Those
judgements are made by reading, not by pattern-matching. This file exists so
the reader sees prose instead of markup.

Two rules earn their keep and both are about not throwing information away:

  * `{{KI}}` becomes a "[KI]" prefix. It is a distinction the source itself
    makes (key item versus ordinary item), and most key-item names in the
    corpus resolve exactly against res/key_items.lua, so collapsing it would
    destroy the single richest source of observable evidence. The rate is not
    quoted here: res/key_items.lua is Windower's table, not this repository's,
    so nobody with a clone alone can check a figure stated for it.

  * An unrecognised template becomes a visible "[[tpl:Name]]" marker plus a
    flag, never a silent deletion. Silent deletion is how data disappears
    without anyone noticing.

Build-time only.
"""

import re

# ---------------------------------------------------------------------------
# template handling
# ---------------------------------------------------------------------------

# Rarity / decoration glyphs: no information, drop them.
_DROP = {
    "vdrop", "xdrop", "xxdrop", "udrop", "cdrop", "vcdrop", "rdrop", "gdrop",
    "ndrop", "ex", "rare", "pagename", "-", "clear", "aug", "augment",
}

# Element icons that appear beside weather and crystal names.
_ELEMENTS = {"fire", "ice", "wind", "earth", "lightning", "water", "light",
             "dark", "thunder"}

#[[ MediaWiki's pipe escapes. A literal '|' cannot appear inside a template
#   parameter, so wiki tables written inside one use these instead. 770 of them
#   in the pages the authored corpus cites, almost all in the `Unlocking a
#   Myth` pages. Leaving them unexpanded turns those tables into noise. ]]
_PIPES = {"!": "|", "!-": "|-", "!}": "|}", "(": "{{", ")": "}}"}


def _split_params(body):
    """Split a template body on top-level '|', respecting nesting."""
    out, depth, cur = [], 0, []
    i = 0
    while i < len(body):
        c = body[i]
        nxt = body[i + 1] if i + 1 < len(body) else ""
        if c == "{" and nxt == "{":
            depth += 1
            cur.append("{{")
            i += 2
            continue
        if c == "}" and nxt == "}":
            depth -= 1
            cur.append("}}")
            i += 2
            continue
        if c == "[" and nxt == "[":
            depth += 1
            cur.append("[[")
            i += 2
            continue
        if c == "]" and nxt == "]":
            depth -= 1
            cur.append("]]")
            i += 2
            continue
        if c == "|" and depth == 0:
            out.append("".join(cur))
            cur = []
            i += 1
            continue
        cur.append(c)
        i += 1
    out.append("".join(cur))
    return out


def _named(params):
    pos, named = [], {}
    for p in params:
        m = re.match(r"\s*([A-Za-z_][\w ]*)\s*=(.*)$", p, re.S)
        if m:
            named[m.group(1).strip().lower()] = m.group(2).strip()
        else:
            pos.append(p.strip())
    return pos, named


def _render_template(name, params, flags):
    low = name.strip().lower()
    if low in _PIPES:
        return _PIPES[low]
    pos, named = _named(params)

    #[[ "{{:Some Page}}" transcludes another page wholesale. Almost none of
    #   those pages are in this cache, so the content is genuinely absent.
    #   Say so plainly rather than leaving a bare fragment that reads like
    #   part of the walkthrough. ]]
    if low.startswith(":"):
        flags.add("transclusion")
        return "[content transcluded from '%s', not available here]" % name.strip()[1:]

    if low in ("ki", "keyitem", "key item"):
        return "[KI]"
    if low in _DROP or low in _ELEMENTS:
        return ""
    if low in ("color", "colour"):
        return pos[-1] if pos else ""
    if low == "itemicon":
        # "{{ItemIcon|Beeswax|22}} [[Beeswax]]": the name is almost always
        # linked right next to it, so emit nothing and let the link carry it.
        # When it is not linked, the dedupe helper in strip_markup() re-adds it.
        return "\x00ICON:" + (pos[0] if pos else "") + "\x01"
    if low in ("item tooltip", "imgpop", "icon", "h:text"):
        return pos[0] if pos else ""
    if low in ("question", "yellow", "zone"):
        # In-game dialogue-choice and label helpers; the words are the content.
        return " ".join(p.strip() for p in pos if p.strip())
    if low == "tooltip":
        if "text" in named:
            return named["text"]
        return pos[0] if pos else ""
    if low in ("verification", "information needed", "stub"):
        # A quality signal the reader should see, not a wart to hide.
        flags.add("unverified")
        return "[unverified]"
    if low.startswith("item synth"):
        flags.add("crafting")
        return "[CRAFTING RECIPE]"
    if low == "#replace:":
        return pos[0] if pos else ""
    if low.startswith("#"):
        return ""
    # Anything else: keep it VISIBLE and flag it.
    flags.add("unknown_template")
    return "[[tpl:%s]]" % name.strip()


def expand_templates(text, flags):
    """Innermost-first, so nested templates resolve before their parents."""
    pat = re.compile(r"\{\{([^{}]*)\}\}", re.S)
    for _ in range(12):
        m = pat.search(text)
        if not m:
            break
        text = pat.sub(
            lambda mm: _render_template(
                _split_params(mm.group(1))[0], _split_params(mm.group(1))[1:], flags
            ),
            text,
        )
    return text


# ---------------------------------------------------------------------------
# links, tags, emphasis
# ---------------------------------------------------------------------------


def expand_links(text):
    def one(m):
        target = m.group(1)
        shown = m.group(2)
        if target.lower().startswith(("file:", "image:", "category:")):
            return ""
        if target.startswith(":category:") or target.startswith(":Category:"):
            target = target.split(":", 2)[-1]
        return (shown if shown else target).strip()

    return re.sub(r"\[\[([^\]|]+)(?:\|([^\]]*))?\]\]", one, text)


def strip_markup(text, flags):
    text = re.sub(r"<!--.*?-->", "", text, flags=re.S)
    text = re.sub(r"<ref[^>]*>.*?</ref>", "", text, flags=re.S)
    text = re.sub(r"<ref[^>]*/>", "", text)
    text = re.sub(r"<br\s*/?>", "\n", text, flags=re.I)
    text = re.sub(r"</?(sup|sub|small|big|span|div|center|i|b|u|s)[^>]*>", "", text, flags=re.I)
    text = re.sub(r"<hr[^>]*>", "\n---\n", text, flags=re.I)
    # Emphasis markers go, the TEXT stays: '''???''' is a clickable object.
    text = text.replace("'''''", "").replace("'''", "").replace("''", "")
    text = text.replace("&nbsp;", " ").replace("&amp;", "&")

    #[[ "{{ItemIcon|Beeswax|22}} [[Beeswax]]" names the item twice. Drop the
    #   icon's copy only when the line names it again. If the icon is the ONLY
    #   mention, which happens in Item Reqs, keeping it is the difference
    #   between a resolvable item and none at all. ]]
    def dedupe(line):
        def one(m):
            name = m.group(1).strip()
            rest = line.replace(m.group(0), "")
            return "" if name and name.lower() in rest.lower() else name
        return re.sub(r"\x00ICON:(.*?)\x01", one, line)

    text = "\n".join(dedupe(l) for l in text.split("\n"))
    text = text.replace("\x00ICON:", "").replace("\x01", "")
    return text


# ---------------------------------------------------------------------------
# tables
# ---------------------------------------------------------------------------


def _cell_text(raw):
    """Strip a cell's HTML attributes, which sit before a single '|'."""
    parts = re.split(r"(?<!\|)\|(?!\|)", raw, maxsplit=1)
    if len(parts) == 2 and re.search(
        r"(rowspan|colspan|align|style|bgcolor|width|class|scope)\s*=", parts[0], re.I
    ):
        return parts[1].strip()
    return raw.strip()


def _rowspan_of(raw):
    m = re.search(r"rowspan\s*=\s*\"?(\d+)", raw, re.I)
    return int(m.group(1)) if m else 1


def render_table(block):
    """A wikitable -> pipe-delimited lines, with rowspans REPEATED.

    Rowspan is what encodes zone grouping in the "visit these 20 NPCs" tables:
    one cell says "Bastok Mines" and spans the five NPC rows under it. Collapse
    it and four of every five targets lose their zone.
    """
    lines = [l for l in block.splitlines()]
    rows, cur = [], None
    for l in lines:
        s = l.strip()
        if s.startswith("{|") or s.startswith("|}"):
            continue
        if s.startswith("|-"):
            if cur is not None:
                rows.append(cur)
            cur = []
            continue
        if cur is None:
            cur = []
        if s.startswith("!") or s.startswith("|"):
            body = s[1:]
            sep = "!!" if s.startswith("!") else "||"
            for piece in body.split(sep):
                cur.append(piece)
        elif s and cur:
            cur[-1] = cur[-1] + " " + s
    if cur:
        rows.append(cur)

    carry = {}          # column -> [text, rows_remaining]
    out = []
    for row in rows:
        cells, col, i = [], 0, 0
        while True:
            while col in carry and carry[col][1] > 0:
                cells.append(carry[col][0])
                carry[col][1] -= 1
                if carry[col][1] == 0:
                    del carry[col]
                col += 1
            if i >= len(row):
                break
            raw = row[i]
            i += 1
            span = _rowspan_of(raw)
            txt = _cell_text(raw)
            cells.append(txt)
            if span > 1:
                carry[col] = [txt, span - 1]
            col += 1
        line = " | ".join(c for c in cells if c is not None)
        if line.strip(" |"):
            out.append("    " + line.strip())
    return "\n".join(out)


_TABLE_RE = re.compile(r"^\s*\{\|.*?^\s*\|\}", re.S | re.M)


def extract_tables(text, flags):
    if "{|" not in text:
        return text
    flags.add("wikitable")

    def one(m):
        return "\n[TABLE]\n" + render_table(m.group(0)) + "\n[/TABLE]\n"

    return _TABLE_RE.sub(one, text)


# ---------------------------------------------------------------------------
# structure
# ---------------------------------------------------------------------------


def keep_subheadings(text):
    """A sub-heading inside a walkthrough is structure, not decoration.

    "First Envelope" / "Second Envelope" tells the reader those steps are two
    independent branches rather than one sequence, which is exactly the sort of
    thing the numbering alone would hide.
    """
    return _HEADING.sub(lambda m: "\n== %s ==\n" % m.group(2).strip(), text)


def bullets(text):
    """Number top-level steps, indent everything below them.

    The single most useful structural rule in the corpus: a top-level `*` is a
    candidate step, `**` and deeper is commentary and strategy. Marking that
    depth is syntactic: it is not a decision about what the step IS, only a
    faithful rendering of how the source laid it out. The prompt tells the
    reader these are CANDIDATES it may merge or split.
    """
    out, n = [], 0
    for line in text.splitlines():
        m = re.match(r"^([*#:]+)\s*(.*)$", line)
        if not m:
            out.append(line)
            continue
        depth, body = len(m.group(1)), m.group(2).strip()
        if not body:
            continue
        if depth == 1 and m.group(1)[0] in "*#":
            n += 1
            out.append("[%d] %s" % (n, body))
        else:
            out.append("    " * (depth - 1) + "- " + body)
    return "\n".join(out)


def _plain_bullets(text):
    """Infobox fields carry lists too ("Item Reqs" often has three OR-branches),
    but they are NOT walkthrough steps and numbering them as such invites the
    reader to treat an item list as a sequence of actions."""
    out = []
    for line in text.splitlines():
        m = re.match(r"^([*#:]+)\s*(.*)$", line)
        if m:
            body = m.group(2).strip()
            if body:
                out.append("    " * (len(m.group(1)) - 1) + "- " + body)
        else:
            out.append(line)
    return "\n".join(out)


def render(text, numbered=True):
    """-> (rendered_text, flags)

    `numbered` marks top-level bullets as candidate steps [1], [2], ... Only the
    Walkthrough gets that; infobox fields use plain dashes.
    """
    flags = set()
    if not text:
        return "", flags
    if numbered:
        text = keep_subheadings(text)
    text = extract_tables(text, flags)
    text = expand_templates(text, flags)
    text = expand_links(text)
    text = strip_markup(text, flags)
    text = re.sub(r"\[\[Category:[^\]]*\]\]", "", text)
    text = bullets(text) if numbered else _plain_bullets(text)
    text = re.sub(r"[ \t]+\n", "\n", text)
    text = re.sub(r"\n{3,}", "\n\n", text)
    return text.strip(), flags


# ---------------------------------------------------------------------------
# section extraction
# ---------------------------------------------------------------------------


def infobox(source, name="Quest Header"):
    """Pull a template block out by brace matching, not regex.

    The Reward and Item Reqs fields nest templates several deep, so a
    non-greedy regex stops at the first inner '}}' and silently truncates the
    infobox.
    """
    i = source.find("{{" + name)
    if i < 0:
        low = source.lower().find("{{" + name.lower())
        if low < 0:
            return None
        i = low
    depth, j = 0, i
    while j < len(source):
        if source.startswith("{{", j):
            depth += 1
            j += 2
            continue
        if source.startswith("}}", j):
            depth -= 1
            j += 2
            if depth == 0:
                return source[i:j]
            continue
        j += 1
    return None


def infobox_fields(block):
    if not block:
        return {}
    inner = block[2:-2]
    parts = _split_params(inner)
    fields = {}
    for p in parts[1:]:
        m = re.match(r"\s*([^=]+?)\s*=(.*)$", p, re.S)
        if m:
            fields[m.group(1).strip()] = m.group(2).strip()
    return fields


_HEADING = re.compile(r"^\s*(={2,6})\s*(.+?)\s*\1\s*$", re.M)


def section(source, want):
    """Heading level varies: '====Walkthrough====' and '==Walkthrough=='
    both occur, so match the NAME and ignore the depth when FINDING it.

    But the section ends at the next heading of the same or shallower level,
    not at the next heading of any level. Sub-headings belong to the section
    they sit under: `As Thick as Thieves` splits its walkthrough into
    '====First Envelope====' and '====Second Envelope===='. Stopping at the
    first of those throws away everything after step 2.

    Measured: stopping at the first sub-heading truncates 71 pages and loses
    111,714 characters of walkthrough, 12,591 of them from a single quest.
    """
    hits = [m for m in _HEADING.finditer(source)]
    for k, m in enumerate(hits):
        if m.group(2).strip().lower() == want.lower():
            level = len(m.group(1))
            start = m.end()
            end = len(source)
            for j in range(k + 1, len(hits)):
                if len(hits[j].group(1)) <= level:
                    end = hits[j].start()
                    break
            return source[start:end]
    return None


def sections_after(source, want):
    """Every sibling section that FOLLOWS the named one, in page order.

    -> [(title, body), ...]

    `section()` stops at the next same-or-shallower heading, which is right
    for finding where the Walkthrough ends and wrong for deciding what the
    walkthrough IS. Measured on the corpus: 165 pages have a sibling section
    after Walkthrough, and some of them carry the rest of the quest.
    `Hitting the Marquisate` puts its last four steps, and the only use of the
    Pickaxe its own header demands, under '====Afterwards===='.

    No allowlist, and deliberately so. The vocabulary is open, not closed: the
    tail is `Two Additional Coffers`, `Repeating the Quest`, `Boss Fight`,
    `The Rest of the Armor`, `Olavia's Walking Path`, `[[Gusgen Mines]]` ...
    mostly singletons. Guessing which titles are "really" walkthrough is
    interpretation, and interpretation is the reading pass's job, not this
    file's. The prepass renders and labels; a reader decides. That is the same
    rule that keeps an unrecognised template as `[[tpl:Name]]` rather than
    dropping it.

    Category links and the like are not headings and stay out on their own.
    """
    hits = list(_HEADING.finditer(source))
    for k, m in enumerate(hits):
        if m.group(2).strip().lower() != want.lower():
            continue
        level = len(m.group(1))
        out = []
        for j in range(k + 1, len(hits)):
            if len(hits[j].group(1)) > level:
                continue            # a sub-heading; it belongs to its own parent
            start = hits[j].end()
            end = len(source)
            for i in range(j + 1, len(hits)):
                if len(hits[i].group(1)) <= len(hits[j].group(1)):
                    end = hits[i].start()
                    break
            out.append((hits[j].group(2).strip(), source[start:end]))
        return out
    return []
