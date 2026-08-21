#!/usr/bin/env python3
"""check_voice.py: keep build vocabulary out of the notes a PLAYER reads.

    python tools/pipeline/check_voice.py [--in build/authored] [glob]

`steps[].note` is drawn on screen. The sibling addon questmarks-ui reads
build/authored/ at runtime through its own notes.lua, and word-wraps the note
under its step, expanded by default for the whole candidate band, so the player
never opts in. Two examples:

    quest/abyssea/162 step 1   "...that key-item name is not unique in
                                res/key_items.lua and the resolver rejects it"
    mission/windurst/10 step 1 "...That is what rule 7 asks for, and it is why
                                the Reward listing does not bar it here"

Wiki words stay and are not checked: README and NOTICE both say the data comes
from BG Wiki, so "the page says", "bullet 3" and "walkthrough" read correctly.
lib/player_voice.json keeps them in `allowed` so nobody tidies them to `banned`.

Scope is `steps[].note` only. Quest-level `notes` is the reviewer channel and
is exempt: questmarks-ui/notes.lua's anchored pattern matches `"note"` and
cannot match `"notes"`, so no player reaches it. `steps[].note` is clean today,
so the baseline is empty; include `notes` and it opens at 3931 entries
with 1300 of the 1546 records failing on prose nobody will read.

emit_lua.py and questgraph refuse to scan note prose, and they are right:
scanning it to DERIVE what a step requires is the pattern-matching this pipeline
exists to avoid. This gate derives nothing and changes no record. It judges
prose as prose, so a false positive costs a reword, not a wrong marker.

Known hole: `snake_case_field` and `record` also hit ordinary English, so
"record the order" trips `record`. Deliberate; the alternative is listing every
schema field by hand and missing the next one. Fix the note, not the pattern.

Build-time only.
"""

import argparse
import glob
import io
import json
import os
import re
import sys

import gatelib

HERE = os.path.dirname(os.path.abspath(__file__))
ADDON = os.path.normpath(os.path.join(HERE, "..", ".."))
VOICE = os.path.join(HERE, "lib", "player_voice.json")


def load_voice(path):
    """-> (translate, banned). Fatal if absent: a silently empty gate passes."""
    if not os.path.isfile(path):
        sys.exit("check_voice.py: %s not found. That file is the vocabulary; "
                 "without it this gate would pass everything, which is worse "
                 "than not running." % path)
    with io.open(path, encoding="utf-8") as f:
        d = json.load(f)
    tr = [(re.compile(r"\b%s\b" % re.escape(t["from"]), re.I), t["to"])
          for t in d.get("translate") or []]
    ban = [(b["id"], re.compile(b["re"], re.I)) for b in d.get("banned") or []]
    if not ban:
        sys.exit("check_voice.py: player_voice.json has no `banned` terms.")

    #[[ The two readers have to stay in step, and only this side can check it.
    #
    #   Lua patterns have no alternation and no \b, so questmarks-ui cannot use
    #   the `re` field. Each rule carries `lua_find` (plain substrings) and/or
    #   `lua_match` (Lua patterns) beside it. A rule added with only `re` would
    #   fail the build here and be invisible in the panel, which is the silent
    #   half of exactly the drift this one file exists to prevent. So the gate
    #   refuses to run rather than enforce a rule its counterpart cannot.
    #
    #   Fatal, not a warning: a warning in a build that prints 40 lines is a
    #   warning nobody reads. ]]
    orphan = [b["id"] for b in d["banned"]
              if not (b.get("lua_find") or b.get("lua_match"))]
    if orphan:
        sys.exit("check_voice.py: %s has rule(s) with no Lua form, so "
                 "questmarks-ui could not enforce them: %s\nAdd `lua_find` "
                 "(plain substrings) or `lua_match` (Lua patterns) to each."
                 % (os.path.basename(path), ", ".join(orphan)))
    return tr, ban


#[[ Sentences, not notes, because that is the unit the UI redacts.
#
#   questmarks-ui/notes.lua drops an offending SENTENCE and keeps the rest, so
#   a gate that reported whole notes would not tell an author which part to
#   fix, and the two sides would disagree about what "one problem" is. Split on
#   terminal punctuation and on the ` -- ` the corpus uses as an em dash. ]]
_SPLIT = re.compile(r"(?<=[.;!?])\s+(?=[A-Z0-9'\"(\[])|\s+--\s+")


def sentences(text):
    text = re.sub(r"\s+", " ", text.strip())
    return [s for s in _SPLIT.split(text) if s and s.strip()]


def offences(rec, tr, ban):
    """(label, term_id, sentence) for every player-facing note that leaks.

    The deliberate complement of check_grounded.py's `values()`: that one takes
    everything that becomes marker data and skips the notes; this one takes the
    one note the player reads and skips everything else.
    """
    out = []
    for s in rec.get("steps") or []:
        note = s.get("note")
        if not isinstance(note, str) or not note.strip():
            continue
        label = "steps[%s].note" % s.get("n")
        for sent in sentences(note):
            #[[ Translation runs FIRST, exactly as it does in the UI. `rung` and
            #   `evidence` have real player words, so a sentence whose only sin
            #   is one of those is not a problem at all, and reporting it would
            #   put entries in the baseline that need no author action. It
            #   suppresses nothing today because the corpus is clean; drop it
            #   and the next note written with `rung` or `evidence` in it comes
            #   back as a false failure. ]]
            probe = sent
            for pat, to in tr:
                probe = pat.sub(to, probe)
            for tid, pat in ban:
                if pat.search(probe):
                    out.append((label, tid, sent))
                    break          # one problem per sentence, not per term
    return out


def main():
    ap = argparse.ArgumentParser()
    gatelib.add_args(ap, "baseline-voice.txt")
    ap.add_argument("--show", action="store_true",
                    help="print the offending sentence under each problem -- "
                         "for working through the list, not for the build")
    args = ap.parse_args()

    tr, ban = load_voice(VOICE)

    files = sorted(glob.glob(os.path.join(args.indir, args.pattern)))
    if not files:
        sys.exit("check_voice.py: %s matched no files.\n"
                 "build/authored/ is committed, so an empty result usually\n"
                 "means --in points somewhere else. Pass --in with the\n"
                 "corpus directory, or drop the pattern to check all of it."
                 % os.path.join(args.indir, args.pattern))

    n_rec, n_note, bad, texts = 0, 0, [], {}
    for path in files:
        base = os.path.basename(path)
        try:
            recs = json.load(io.open(path, encoding="utf-8"))
        except ValueError:
            continue
        for r in recs if isinstance(recs, list) else []:
            n_rec += 1
            ident = r.get("identity") or {}
            key = "%s/%s/%s" % (ident.get("cat"), ident.get("area"),
                                ident.get("id"))
            n_note += sum(1 for s in (r.get("steps") or [])
                          if isinstance(s.get("note"), str) and s["note"].strip())
            for label, tid, sent in offences(r, tr, ban):
                #[[ The violation line is the identity key (gatelib.apply
                #   dedupes on the whole string), so it is keyed on the TERM
                #   and never on the note text. Interpolating the prose would
                #   make every unrelated rewording a new failure AND orphan the
                #   old entry, so a single edit would show up as one problem
                #   fixed and one appearing. Keyed this way, rewording a note
                #   into the player's voice removes its line and adds nothing. ]]
                p = "%-22s %-16s %-22s [%s]" % (key, label, tid, base)
                bad.append(p)
                texts.setdefault(p, sent)

    print("checked %d player-facing note(s) across %d record(s) in %d file(s)"
          % (n_note, n_rec, len(files)))

    bad, known = gatelib.apply(bad, args.baseline, args.write_baseline,
                               "check_voice.py baseline -- build vocabulary in "
                               "notes the player reads",
                               "leak(s)")
    if bad:
        print("\n%d NEW BUILD TERM(S) IN A PLAYER-FACING NOTE:" % len(bad))
        for b in bad:
            print("  " + b)
            if args.show:
                print("      " + texts.get(b, ""))
        print("\nThese are drawn in the questmarks-ui detail pane. Reword the "
              "note for somebody standing in the game, or move the reasoning to "
              "the quest-level `notes` field, which no player ever sees.")
        sys.exit(1)

    print("every player-facing note speaks the player's language")


if __name__ == "__main__":
    main()
