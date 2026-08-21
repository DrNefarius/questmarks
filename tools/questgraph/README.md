# questgraph

A visualisation and correction tool for the questmarks quest data. You open it
when the game shows you a marker that makes no sense.

It is a **separate program from the addon**. Nothing here ships; nothing the
addon loads may ever require anything in this directory.

```bash
python tools/questgraph/qg.py
```

Serves on `http://127.0.0.1:8787`, **loopback only and unauthenticated**. It
can write to `build/authored/`, so it must not be reachable off this machine.

```
python tools/questgraph/qg.py report     the triage list, as text
python tools/questgraph/qg.py graph      the prev DAG analysis
python tools/questgraph/qg.py why [file] parse questmarks.log (or a pasted block)
python tools/questgraph/qg.py verify     the full build, then the whole suite
python tools/questgraph/test_questgraph.py
```

Python 3 and LuaJIT at `%LOCALAPPDATA%\Programs\LuaJIT\LuaJIT\bin\luajit.exe`.
No pip installs, no CDN, no framework, no build step. Same rule as the addon.

---

## The one object: the trace

A row of marks, one per **collapsed ladder position**, filled where the addon
can observe that position and hollow where it cannot.

```
▪▫▫▫▪▫    lit, then three dark, then lit
```

It is the same object at all three zooms and it never means anything else. A
long hollow run *is* the answer to "why is my marker wrong". The mark cannot
move through a stretch the game never reports. You see it before you read a
word.

**filled = the addon can see it. hollow = it cannot. One accent colour, and it
always means: a human must decide something here.** Nothing else is coloured.
Kind, zone, confidence, mob role and target type are carried by word, position
and weight instead, so the whole tool survives greyscale.

## Three levels

**Areas.** Ten rows, one per quest area, each with an aggregate trace: bar
height at position *k* is the fraction of that area's quests still observable
there. A profile that starts high and falls away is the corpus's normal shape;
a flat hollow line from position 1 is an extraction failure at the scale of a
whole area. Counts per severity band beside it.

**One area.** Every quest as its own trace, no titles, grouped into five bands
and packed into CSS columns. Position *k* lands at the same x in every column,
so a systematic failure draws as a vertical band across the screen. 184 quests
fit on one screen. Tick **show titles** when you need them.

The bands are ordered by what they cost, and one of them exists to *stop* you
looking:

| band | meaning |
|---|---|
| **cannot be trusted** | a name does not resolve, so a marker is silently absent right now |
| **stalls mid-quest** | observable, then five or more positions dark |
| **awaiting judgement** | a reader recorded a call they could not make |
| **never moves** | no observable evidence anywhere (**usually correct**) |
| **nothing found** | no signal of any kind |

*never moves* is the biggest band by far, about half the corpus, and most of it
is fine: the mark sits one past the giver for the whole quest, which is the
honest answer. Ranking unfalsifiable as suspicious would send you to inspect
hundreds of records with nothing to fix, so it gets its own band and its own
sentence saying so. `python tools/questgraph/qg.py report` prints the live
count; do not copy one in here, it moves with every authoring batch.

**One quest.** A numbered work instruction, not a node-link diagram. The
corpus is short procedures, not a topology (median 4 steps; 764 of 1546 are
three steps or fewer). The zone sits in the left margin, printed only where it
*changes*. The spine down the body column carries the lit/dark law at full
scale, and a fixed-position ledger under every step reads

```
        needs   Zvahl Coffer Key ×1   or   Thief's Tools ×1
       grants   Old gauntlets (key item)
         mobs   spawns Dark Spark
```

Every label sits at the same x for the whole page, so the evidence chain reads
as a column with visible gaps. **An empty row is still drawn**. That ghost is
the click target that creates the thing.

Three renderings are measured facts, not taste:

- **a group is one rung, not N steps.** `Lure of the Wildcat` is 22 steps of
  which 20 are one unordered group; the addon draws all 20 at once. It renders
  as rung `2-21`, *in any order*, members **bulleted and never numbered**.
  Numbering an unordered set would be a lie.
- **each group member carries its own zone**, because 120 of 190 groups span
  more than one. Any scheme that binds zone to the rung asserts a wrong zone
  for up to 20 members.
- **optional steps hang off the spine**, which runs straight past.

## Editing

There is no JSON textarea. The UI mutates a typed model (`model.js`) and
serialises it, so **a syntax error cannot be authored**. Not caught after the
fact. Never written in the first place.

Click any value in the sentence to change it: the verb picks the kind, the name
opens the entity picker, the zone opens a `res/` search. The number in the
gutter opens the structural verbs (insert, delete, move, make optional, group
with the next step). **Renumbering is automatic and the strip says what moved**,
because dense `n` is a hard gate.

**Nobody types a resource id.** Items, key items and zones are searched against
an index built from `normalize.make_item_index`, the same function the resolver
uses. So the picker cannot offer a name the build then fails to resolve. Two
duplicate-name cases are distinguished rather than hidden:

- `traverser stone` is six consecutive key items with **no distinguishing
  attribute**: one per unit carried, hold any and you hold it. An OR-list, not
  an error.
- `Nodal Wand` is three items separated by **damage 129 / 131 / 133**. The
  resolver picks one over an unordered `pairs()` and the winner is not stable
  between runs. The picker says so and points at
  `tools/pipeline/resolve_overrides.json`, the only place that can be fixed.
  The authored record stores a name, never an id.

**NPCs and monsters are in no `res/` table at all.** The picker offers what
*this quest's own cached wiki page links*, matched on `source.page_id`. It is a
suggestion and never a gate, and the signal is **type-aware** because the two
cases are nothing alike. Across the corpus the step targets are 4045 npc, 1725
object and 317 zone; for the share of each that its own page actually links,
read what the picker reports rather than a number here, because it moves with
every authoring batch.

Nearly every NPC name is linked on its own page, and most object names are not.
So an unfindable NPC name is worth a warning. An unfindable object is normal:
doors, `???`, altars, furniture. A field that refused them would make it
impossible to add the missing target a correction exists to add.

**Validation problems appear on the element they are about.** A problem with
step 22's evidence renders under step 22, not in a list at the bottom.

## What it refuses

A bad write should be caught before it lands, not found later in a diff of a
1546-record corpus. So the tool shows you a diff before it commits, keeps a
local copy of what it replaced (`backups/`, deliberately outside `build/`)
and an append-only ledger of what it changed (`edits.jsonl`), and requires
`basis` + `reason` on every correction.

`basis` and `reason` are the half that outlives the session: they go into the
record itself, and the build reads `basis` to decide whether the value has to
be attested on the wiki page. The backups and the ledger are local working
state and are not committed.

- writing to any generated file
- editing `identity`, `source` or `extraction` (provenance, not reasoning)
- removing a marker position without saying so (a *zone change* is a move, not
  a removal, and is not treated as one)
- recording evidence on a step later than where you obtain it (the failure that
  looks like a fix and makes every step between unreachable forever)
- writing to a file that changed on disk since it was loaded
- reverting an edit that a later edit has superseded

and there is deliberately **no bulk edit and no find-and-replace across
quests**. The dataset exists because 1546 pages were read instead of
pattern-matched.

## The files

```
qg.py                 server + CLI
corpus.py             loads all four layers and joins them; writes nothing
gates.py              checks a proposed record -- calls the real validate.py
edits.py              the ONLY write path: backup, diff, ledger, refusals
entities.py           wikilink evidence + the res/ name index behind the pickers
graph.py              the prev DAG: cycles, depth, out-of-index edges
triage.py             the trace, the severity bands, the ranking
playlog.py            //qm why and questmarks.log
dump_index.lua        quest_index + mission_index -> JSON, via Lua's loadfile
dump_pick.lua         the picker index, from normalize.make_item_index
web/                  index.html, style.css, and four IIFE scripts:
                        model.js  the typed record -- invalid JSON is impossible
                        pick.js   the pickers
                        quest.js  level 3, the document and its editor
                        app.js    shell, routing, levels 1 and 2
test_questgraph.py    107 checks, against a throwaway copy of the tree
```

Each web script is wrapped in an IIFE. They are classic scripts sharing one
lexical scope, so two files declaring `const esc` is a hard `SyntaxError` that
kills the second one outright. As far as the page is concerned it fails
silently.
