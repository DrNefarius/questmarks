# questmarks

WoW-style quest markers over FFXI NPCs, for Windower 4.

Reads your quest and mission state from packet `0x056`, joins it against
BG-Wiki-derived quest metadata, evaluates prerequisites, works out **which step
of the quest you are on**, and draws a marker above the NPC (or the monster)
**in the 3D world**.

![questmarks working in game](assets/teaser.gif)

## Install

Download or clone this repository into your Windower `addons` folder, so that
it sits at `Windower4/addons/questmarks/`, then in game:

```
//lua load questmarks
```

To load it every session, add `lua load questmarks` to your Windower init
script. **Windower 4 is all you need**: no other addon at runtime and none to
build the index either, which `tools/test_standalone.lua` enforces on every run.
The quest data ships with the addon, so there is nothing else to install and
nothing to configure.

**A browsable list, if you want one.** [questmarks-ui](https://github.com/DrNefarius/questmarks-ui/) is a
separate addon, in its own repository, that puts your accepted quests in an
in-game window grouped by region, with each quest's full step ladder beside it.
It reads this addon's data and its `build/` directory off disk; nothing here
reads it back, and nothing here may, which is the rule
`tools/test_standalone.lua` enforces.

## Markers

Colour carries the **state**. The glyph says what the NPC is *for*.

| | Quest | Mission | Campaign |
|---|---|---|---|
| available, all prerequisites met | **yellow !** | **green !** | **red !** |
| accepted, ready to hand in | **yellow ?** | **green ?** | **red ?** |
| accepted, in progress | **grey ?** | muted green **?** | muted red **?** |
| a prerequisite is definitely unmet | **grey !** | **grey !** | **grey !** |
| something could not be verified | **black !** | **black !** | **black !** |
| repeatable, already done | **blue !** | **blue !** | **blue !** |

**Missions are green when they're actionable**, Campaign red, so the main
storyline and the war content are not lost in a crowd of yellow side quests.
Once blocked or unverifiable they drop back to the shared grey/black, and on an
NPC offering both, the mission wins the marker.

**Nation missions are filtered to your allegiance.** A Windurst character never
sees San d'Oria mission markers, because those lines are mutually exclusive.
San d'Oria *quests* still show; only missions are gated.

**The black `!` means "I can't verify this"**, not *"go do it"* and not *"you
can't"*. In practice it almost always means unknown fame.

**Anything you can start always beats a repeatable you've already done.** An
NPC with both shows yellow (or green for a mission), never blue. Repeatable
quests and missions toggle separately, since there are far more of the former:

```
//qm show repeat_quest off     278 repeatable quests
//qm show repeat_mission off   29 repeatable missions
```

### The glyph vocabulary

Before you accept a quest the glyph is always `!`: *"there is something here to
take"* is the whole message. Once accepted, it refines into **what that step
asks of you**:

| glyph | meaning | step kinds |
|---|---|---|
| **?** | talk to finish, or nothing more specific is known | `turnin`, `travel`, `wait`, `cutscene`, `other` |
| **speech bubble** | talk to this NPC | `talk` |
| **hand-over** | trade the listed items here | `trade` |
| **sack** | this drops something the step needs | `obtain`, monster role `drop` |
| **sword** | defeat this | `fight`, monster roles `kill` and `spawn` |
| **magnifier** | examine this (a `???`, a door, a monument) | `examine` |

`!` and `?` carry the state colour. The action glyphs keep a fixed identity
colour in every state instead, except `trade`: on the hand-over, "you have the
items" versus "you don't" is worth seeing at a glance.

**Monsters get markers too**, a sword where the quest wants one dead and a sack
where it wants its drop. Duplicate monsters are *not* collapsed the way
duplicate NPCs are: two Sand Sweepers are two real targets. Corpses are skipped.

## Steps

**Packet `0x056` carries no step data.** Nothing in any packet says "you are on
step 3 of 7", so the position is *inferred* from the items and key items you
hold. Steps that leave no trace are stepped over rather than waited for, which
means the position **can lag, and can never run ahead of you**: the marker
points somewhere you have already been rather than somewhere you have not
earned. With no evidence at all it sits one step past the giver.

`A Question of Taste` is six steps, three of them observable, over four key
items:

| you are on | evidence held | inferred | marker lands on |
|---|---|---|---|
| not yet accepted | none | none | Etteh Sulaej, Kazham ✔ |
| 2 | KI 213 | 2 | Angelica, Windurst Waters ✔ |
| 3 | + KI 259, 214 | 3 | Etteh Sulaej ✔ |
| **4** | unchanged | **3** | **Etteh Sulaej (stale)** |
| **5** | unchanged | **3** | **Etteh Sulaej (stale)** |
| 6 | KI 215 | 6 | Etteh Sulaej ✔ |

Four of six right, two stale, **none ever ahead of the player**. It plays better
than that reads: a stale marker is still somewhere you have been, and the last
step of most quests is a hand-in whose step usually is observable, so the marker
tends to be right when you accept and when you can finish.
`python tools/questgraph/qg.py report` measures the rest.

**`//qm why <npc>` prints the whole ladder**, marking the inferred step, the
step actually carrying the marker, and a verdict on every piece of evidence.
That is the command for "why is my marker here". **`//qm steps off` turns the
feature off**, pinning every marker back on its quest giver.

**One thing that will look like a bug and isn't.** While you stand in the
giver's zone with a quest in progress whose current step is somewhere else, that
quest shows no marker at all. There is genuinely nothing to do at the giver, and
an empty city reads better than a marker meaning "elsewhere". Nothing is lost:
`//qm todo` still lists the quest and names where the step actually is, and
`//qm why <npc>` prints a `- hidden:` line explaining it.

## Commands

```
//qm                       help
//qm diag                  dump everything to questmarks.log
//qm debug [on|off]        caption each marker with NPC, distance and lag push
//qm on | off | toggle
//qm todo [what] [n]       what you are in the middle of, anywhere in the world
//qm why <npc|t>           explain every marker on an NPC ('t' = your target)
//qm steps [on|off]        follow a quest along its steps (default on)
//qm npcs                  quest NPCs resolved in this zone
//qm new                   what became newly available at the last check
//qm notify [on|off]       announce newly available quests (default on)
//qm fame                  show fame levels and where each came from
//qm fame <region> <0-9>   set manually    //qm fame <region> reset
//qm fame dump             checker lines seen but not recognised
//qm show <state> [on|off] turnin progress ready unknown blocked
                           repeat_quest | repeat_mission
//qm dist <yalms>          default 50      //qm floor <yalms>   default 6
//qm max <n>               default 16      //qm size <px>       default 60
//qm perspective [on|off]  scale markers with distance (default on)
//qm refdist <yalms>       distance at which //qm size is exact, default 8
//qm pxmin | pxmax <px>    perspective size clamps, default 10 / 180
//qm offset <yalms>        default 2.3     marker height above the NPC
//qm sizescale <0-1>       scale marker height by NPC race (0 = fixed height)
//qm lag <0-3>             camera lag compensation, default 1 (0 = off, see below)
//qm smooth <0-0.9>        damp marker shimmer, default 0.3 (0 = raw)
//qm dump <npc|t>          compare every entity sharing that name
//qm visible [on|off]      only mark NPCs the client has spawned (default on)
//qm menu [on|off]         hide markers while a menu is open (default on)
//qm kills [n]             monsters beaten this session (display only)
//qm settings              effective values, flagging stale saved ones
//qm reset confirm         clear saved settings (keeps fame)
//qm data | state <area> | probe | perf
//qm rebuild [all|v1]      regenerate the index (only use if you know what you're doing!)
```

`//qm why t` is the one to reach for when a marker looks wrong. **Every
command's output is also written to `questmarks.log`**, because in-game chat
cannot be copied out: when something looks wrong, run `//qm diag` and send it.

`//qm todo` walks the whole index and lists what you are in the middle of,
newest-actionable first, naming the step and the city it is in, which markers
alone can never do:

```
questmarks: 3 to do (accepted): 1 turnin, 2 progress
   yellow ? turnin    A Question of Taste   Etteh Sulaej, Kazham (J-9) step 6/6
   grey ? progress    Waking the Colossus   Iron Eater, Metalworks (J-8) step 5/14
   grey ? progress    The Gobbiebag Part I  Bluffnix, Lower Jeuno (H-9) step 1/2
```

It defaults to what you have **accepted**. `//qm todo ready` lists what you
could start right now, `//qm todo all` every state, and any of the six state
names on its own filters to it. A trailing number raises the chat cap; the full
list always goes to `questmarks.log`.

## Fame

FFXI never sends your numeric fame to the client, so questmarks assembles it
from three sources and takes the highest. **Dialogue**: talk to a checker and
your level is read from what they say, saved per character the moment it is
learned, so you only visit each one once.

| Region | Checker | Where |
|---|---|---|
| Bastok | Flaco | Port Bastok (E-6) |
| San d'Oria | Namonutice | Southern San d'Oria (K-6) |
| Windurst | Zabirego-Hajigo | Windurst Waters (F-10) |
| Jeuno | Mendi | Lower Jeuno (H-8) |
| Norg / Tenshodo | Vaultimand | Norg (H-8) |
| Rabao / Selbina | Waylea | Rabao (G-9) |

**Inferred floor**: if you have accepted a quest gated at fame 5 you must have
had fame 5, so that becomes a lower bound for free. **Manual**:
`//qm fame bastok 6`. Three regions in the data have **no checker anchors
shipped**, `aht_urhgan`, `kazham` and `mhaura`, so their level can only come
from the floor or from you; `//qm fame` flags them. If a checker ever says
something the addon doesn't recognise, `//qm fame dump` captures it verbatim so
the anchor can be corrected from real observation.

## Known limitations

Completion is decoded from packet `0x056` and is exact. Everything else is
**inferred**: which step you're on, your fame floor, whether you've beaten
enough of something. A wrong inference moves a marker rather than deleting one,
and is never written to disk.

- **Markers draw through walls.** Windower's Lua API exposes no depth buffer, so
  true occlusion is impossible. A distance cap, a same-floor check
  (`//qm floor`) and a fade with distance reduce the problem rather than
  eliminate it.
- **The step position is inferred, and can be stale.** It is never ahead of you
  and never a marker where none existed before, but on a long unobservable
  stretch it points at the last place it could prove you reached. `//qm why t`
  shows which step and why.
- **Linear mission progress is inferred.** CoP, SoA, RoV, ACP, MKD, ASA and TVR
  send only a "current mission" integer with no completed bitfield, so the addon
  resolves it to the nearest known ID, treats everything below as complete and
  blocks anything past it. Nation and Zilart missions do get an exact bitfield
  and are reliable.
- **Items needed to *complete* a quest don't gate it. Items needed to *start*
  one do.** A quest is never greyed out for turn-in items you have not collected
  yet, but some cannot be begun empty-handed, and a yellow `!` there sends you
  across Jeuno for nothing.
- **Kill counts are counted, not reported.** No packet says "3 of 5 Sand
  Sweepers", so the addon tallies defeat messages itself: session-local,
  approximate, never saved, and never advancing a step. `//qm kills` lists it.
- **Markers trail slightly while the camera turns**, ~31-37px behind during a
  pan and ~1px at rest. `//qm lag` compensates imperfectly; `//qm debug` draws a
  dim ghost at the *uncompensated* position so you can see which is closer.
- **Markers only appear for NPCs the client has spawned**, so a giver it has not
  loaded yet gets none even within `//qm dist`. `//qm visible off` marks every
  indexed entity in range instead, at the price of markers over empty air. This
  also hides ghost NPCs: FFXI keeps spare entity slots for conditionally-visible
  NPCs, so a zone can hold several entities with one name while only one is
  rendered. The addon skips untargetable copies and keeps the nearest of the
  rest; if a marker still floats over nothing, `//qm dump <npc>` prints every
  copy.
- **Marker height follows the NPC's race** (Galka high, Tarutaru low), the only
  usable signal there is. Roughly a third of quest givers report a race that
  says nothing about height and get the default offset.

## Notifications

Completing a quest or gaining a fame level can unlock content anywhere in the
world, where no marker will ever be visible, so questmarks diffs the whole index
on every zone-in and reports it in one line. The first check after login is
deliberately silent, because otherwise every quest in the game would count as
new. Some content starts just by *entering* a zone, with no NPC to mark, so that
is announced on arrival instead, counted and tagged by kind:

```
questmarks: entering this zone starts 1 mission(s):
   Unraveling Reason   [mission]
```

## Contributing

There are two quite different ways to help, and they need different things from
you. Pick the one you came for; you do not need the other.

| you want to | you need | go to |
|---|---|---|
| fix a marker that points at the wrong NPC, or a quest whose steps are wrong | Python 3, LuaJIT, and to have played the quest | [Correcting quest data](#correcting-quest-data) |
| change how the addon behaves, looks or performs | LuaJIT and a Windower install | [Working on the addon](#working-on-the-addon) |

Corrections are the more valuable of the two and the easier to start on. There
is no Lua and no packet knowledge in it.

### Correcting quest data

**Everything the addon knows about a quest is one JSON record**, in
`build/authored/`. There are 1546 of them. Each is a step ladder: what you do,
where, to whom, and what you are holding when it is done. `data/*.lua` is
generated from those records and is *not* where you fix anything.

```
build/authored/     the source of truth: one step ladder per quest   <- edit here
  -> build/validated/     names resolved to resource ids
  -> data/quest_steps.lua the emitted ladders
  -> data/quest_index.lua the shipped index the addon reads
```

You edit the first box. Everything downstream is rebuilt from it.

#### What you need

Python 3, and LuaJIT at `%LOCALAPPDATA%\Programs\LuaJIT\LuaJIT\bin\luajit.exe`.
No `pip install`, no Node, no build step. Clone the repository and you have
everything else already: the corpus is committed.

#### 1. Find out what is actually wrong

In game, target the NPC and run:

```
//qm why t
```

That prints the quest's whole ladder, which step the addon thinks you are on,
which step is carrying the marker, and a verdict on every piece of evidence it
checked. It also prints the quest id, in `cat/area/id` form, which is what you
search for next.

Every diagnostic command writes to `questmarks.log` in the addon folder as well
as to chat, so you do not have to copy anything out of the game. If you played
for an evening and want the whole session's worth at once:

```bash
python tools/questgraph/qg.py why questmarks.log
```

which lists every quest the log mentions, with its state, and flags any that
have no authored record at all.

#### 2. Open questgraph

```bash
python tools/questgraph/qg.py
```

It serves on `http://127.0.0.1:8787` and opens your browser. Loopback only, and
it can write to `build/authored/`, so do not expose it. `--no-browser` and
`--port` are there if you need them.

You land on a list of areas, quest and mission both. Click into one and you get
every quest in it as a row of marks, one mark per position in its ladder,
**filled where the addon can observe that position and hollow where it
cannot**. A long hollow run is the answer to "why does my marker not move".
Quests are grouped into bands by what is wrong with them, worst first; the
biggest band, *never moves*, is mostly **correct** and is labelled so you do
not waste an evening in it.

Click a quest to open it as a numbered work instruction, with the zone in the
margin and, under each step, what it needs, what it grants and which monsters
are involved.

If you already know the quest, the search box takes a name or a `cat/area/id`.

#### 3. Fix it

**There is no JSON to type.** Click a value in the sentence and the right
control opens: the verb picks the step kind, the target name opens an entity
picker, the zone opens a search over the game's own zone table. The number in
the left gutter opens the structural verbs — add a step before or after, move
it, delete it, make it optional, group it with the next one, and **edit the
note**. Renumbering happens for you.

**Nobody types a resource id.** Items, key items and zones are searched against
the same index the build's resolver uses, so the picker cannot offer you a name
that then fails to resolve. NPC and monster names are in no game table at all,
so there the picker suggests what this quest's own cached wiki page links, as a
hint rather than a rule — an object like a door or a `???` will not be in it,
and that is normal.

**Step notes are the easiest useful contribution in the project.** The sibling
addon `questmarks-ui` draws each step's `note` under it, expanded, so a note
that reads badly or says something untrue is on a player's screen. Fixing one
needs nothing but the game: open the step menu and choose *edit the note*. Write
for somebody standing in Vana'diel who has never seen this repository. Words
from the wiki are fine ("the page says", "bullet 3"); words from this pipeline
are not, and the build will fail and name the term if one gets through. The
quest-level `notes` field is a different thing, read by the next reviewer and
never shown to a player.

#### 4. Say why, and commit

When you choose **review and commit**, questgraph asks for two things and then
writes the record itself:

- **basis**, which is `game` or `reading`, and
- **reason**, one sentence.

**`basis` is not paperwork; it changes what the build does.**

| | what it means | what it changes |
|---|---|---|
| `game` | you stood there and saw it. The page is wrong | the build stops requiring that the value appear on the wiki page, for the fields you changed and no others. Without it your correction is **refused** at build time |
| `reading` | the page supports your fix and the earlier reading of it was wrong | the value still has to be attested on the page |

Either way, the quest is never scheduled for automatic re-reading again, so a
later authoring pass cannot quietly overwrite you.

Before it writes anything the tool shows you a diff, and refuses a set of
things outright: writing to a generated file, editing a record's
provenance, removing a marker without saying so, recording evidence on a later
step than the one you actually obtain it on, or writing to a file that changed
on disk while you had it open. There is no bulk edit and no find-and-replace,
deliberately.

#### 5. Check it, then send it

```bash
python tools/pipeline/validate.py         # authored -> validated
python tools/pipeline/emit_lua.py         # validated -> data/quest_steps.lua
luajit tools/build_index.lua --all-areas  # -> data/quest_index.lua, mission_index.lua
```

then run the six suites (see below). `python tools/questgraph/qg.py verify` does
the build and the suites in one command.

**Commit your change to `build/authored/` and nothing else.** Rebuild locally by
all means, but leave the regenerated `data/*.lua` out of the pull request. It is
a megabyte and a half of generated Lua at one line per row, so two people fixing
two different quests would conflict on every line either of them touched. The
maintainer regenerates `data/` once at release time. A good pull request is one
or two edited JSON files and a diff a reviewer can actually read.

### Working on the addon

Everything except the rendering itself is testable without launching the game.
The six suites should be green before anything is published, and `smoke.lua`
before you play: a nil index in a command handler is otherwise found
mid-session, in a chat window you cannot copy out of. They find the addon
directory from their own location, so run them from the root of a clone
anywhere.

```
luajit tools/check.lua            # parse every file, and reject any global write
luajit tools/test_project.lua     # world->screen, vs a real captured camera
luajit tools/test_state.lua       # 0x056 decode
luajit tools/test_core.lua        # fame / inventory / prereq / steps / index join
luajit tools/test_standalone.lua  # no runtime dependency on anything else
luajit tools/smoke.lua            # run every //qm command against a stub client
```

Two rules those suites exist to enforce, worth knowing before you change
anything:

- **No shipped file writes a global.** `check.lua` scans the bytecode for it.
- **An unknown must never collapse into a definite answer.** A quest whose
  prerequisites cannot be verified draws a black `!`, not a grey one; that
  distinction is the whole of `core/prereq.lua` and most of `test_core.lua`.

**If your change touches the build rather than the addon**, prove it moved no
data:

```bash
luajit tools/diff_index.lua <old.lua> <new.lua>
```

It compares two generated indexes as an unordered multiset, so a change to the
emitter cannot masquerade as a change to the data, and it reports only the
differences that actually move markers: a quest that disappeared, a zone that
went from resolved to nil, a fame gate that vanished, an NPC key whose entry
count grew sharply. Keep a copy of `data/quest_index.lua` before your build and
point this at both.

Then run the build **twice** and confirm the generated files are byte-identical.
Nothing may depend on `pairs()` order reaching the output: a build that is not
reproducible leaves `git status` dirty after a no-op rebuild, and turns every
real data change into a diff nobody can read. `.gitattributes` pins the line
endings that guarantee holds on.

**Where the data comes from**, if you need to work on the pipeline itself: every
quest and mission fact is read from a local cache of
[BG Wiki](https://www.bg-wiki.com) pages, except *identity*, which comes from the
game client's own DAT name table. The page cache is ~293 MB and is not
published; only `check_authored.py` and `check_grounded.py` read it, and
`tools/pipeline/fetch_wiki.py` rebuilds it. Most of `build/` is committed rather
than treated as an artifact: `build/authored/` is the source of truth,
`build/rendered/` is runtime data `questmarks-ui` reads off disk,
`build/authored-quarantine/` holds records that were read but do not ship, and
`build/res.json` is the client's own name tables dumped for the build. Only the
three regenerable stages are ignored, and `.gitignore` says so at the top.

**Everything under `data/` is generated** and will be overwritten by the next
build, bar `data/npc_overrides.lua` and `data/fame_dialogue.lua`, which are
hand-maintained and say so at the top.

## Licence

The code is **MIT** (`LICENSE`). The bundled quest and mission data derives from
BG Wiki and is **CC BY-NC-SA 3.0**; `data/dat_names.lua` is extracted from the
game client and is Square Enix content, under neither. `LICENSE-DATA` states
which terms cover which files, and `NOTICE` is the full attribution.

**The non-commercial clause is inherited from BG Wiki and is not optional.**
questmarks as a whole cannot be sold or bundled into anything monetised.

## Thanks

questmarks started as a consumer of [chronicle](https://github.com/jintawk/ffxi-chronicle)
by jintawk. Its bundled BG Wiki tables answered which quests exist, who gives
them, what they need and what they lead to, and that was enough to prove the
idea was worth building. Every one of those questions is now answered from this
project's own page cache and from the game client's own data, and nothing here
reads that addon any more, but the shape of the answer was learned there first.
Two readings of its *code* also survive, cited where they are used: the packet
`0x056` decode in `core/state.lua` (which chronicle in turn credits to the
**Mastery** addon for the original `story_logs` mapping) and the batched
multi-bag inventory sweep in `core/inventory.lua`. Thank you both.

`core/fame.lua`'s dialogue reading was learned from
[Balloon](https://github.com/StarlitGhost/Balloon).

Quest and mission data from [BG Wiki](https://www.bg-wiki.com) and its
contributors. *Final Fantasy XI* is © SQUARE ENIX CO., LTD. This is an
unofficial, non-commercial fan tool with no affiliation to or endorsement by
Square Enix.
