--[[
fame_dialogue.lua -- fame-checker NPCs and the phrases that identify each level.

FFXI never sends numeric fame to the client (there is no "fame" field anywhere
in Windower's packet definitions), so the only way to know it is to read what a
fame-checker NPC says. core/fame.lua captures that via `incoming text`.

MATCHING RULES -- these are why the anchors are short:

  * Anchors are SHORT DISTINGUISHING SUBSTRINGS, never whole lines. The real
    dialogue interpolates the player's name mid-sentence and contains
    gender/rank branches the client resolves to one side (Mister/Miss,
    Sir/Lady, Lord/Lady, he/she, Hero/Heroine). Matching a long span would
    break on any of those; matching a short name-free span does not.
  * Matching is case-insensitive and anchored per NPC, so identical phrasing
    across nations cannot collide.
  * When several anchors match, the LONGEST wins (most specific).

SOURCE -- FFXIclopedia's Reputation page is authoritative here.

  Bastok, San d'Oria and Windurst were transcribed from BG Wiki, where both
  wikis agree on the level->line ordering.

  Jeuno (Mendi) and Rabao/Selbina (Waylea) were previously EXCLUDED because BG
  Wiki and FFXIclopedia contradicted each other -- BG numbers Mendi's table 0-9
  with a row duplicated from San d'Oria's, and the two disagree on six of
  Waylea's nine levels. That conflict is now resolved in favour of
  FFXIclopedia's Reputation page, which lays all four Jeuno/Outlands checkers
  out in one table, level by level. Jeuno was the single biggest gap: 116 of
  the indexed quests are gated on it.

  Anything learned from an unrecognised checker is recorded by //qm fame dump,
  so remaining gaps can be closed from real observation rather than a wiki.

Sources: https://ffxiclopedia.fandom.com/wiki/Reputation (Jeuno/Outlands table)
         https://www.bg-wiki.com/ffxi/Fame and the individual NPC pages.
]]

return {
    -- region -> {npc = <entity name>, zone = <zone id>, levels = {[n] = {anchors}}}
    bastok = {
        npc = 'Flaco',
        zone = 236,                     -- Port Bastok
        levels = {
            [1] = {'some kind of snail'},
            [2] = {'sounds familiar'},
            [3] = {'not doing too bad'},
            [4] = {'quite a few people are talking'},
            [5] = {'a lot of people know'},
            [6] = {'most everyone in this country'},
            [7] = {'look so surprised'},
            [8] = {'hero to the people of bastok'},
            [9] = {'household name in these parts'},
        },
    },

    sandoria = {
        npc = 'Namonutice',
        zone = 230,                     -- Southern San d'Oria
        levels = {
            [1] = {'never heard that name'},
            [2] = {'might have heard that name'},
            [3] = {'a name i often hear'},
            [4] = {'well known in these parts'},
            [5] = {'famous in our kingdom'},
            [6] = {'reputation sparkles'},
            [7] = {'practically all of the kingdom'},
            [8] = {'every infant in his cradle'},
            [9] = {"isn't a soul in the kingdom"},
        },
    },

    --[[ Jeuno -- the largest fame gate in the index (116 quests).
         Ordering per FFXIclopedia's Reputation table, which numbers Mendi 1-9.
         BG Wiki's 0-9 numbering is NOT used: its row 3 is a verbatim copy of
         Namonutice's San d'Oria level-4 line, which makes its low levels
         off-by-one. ]]
    jeuno = {
        npc = 'Mendi',
        zone = 245,                     -- Lower Jeuno (H-8)
        levels = {
            [1] = {'all roads lead to jeuno'},
            [2] = {'name is vaguely familiar'},
            [3] = {'travelers in a tavern talk about you'},
            [4] = {'hear your name mentioned quite often'},
            [5] = {'good deal of people here in jeuno'},
            [6] = {'growing reputation precedes you'},
            [7] = {'literally everyone in jeuno knows your name'},
            [8] = {'synonymous with courage and sacrifice'},
            [9] = {'emerged as a hero to the people of jeuno'},
        },
    },

    --[[ Rabao and Selbina are ONE fame area sharing a single checker in Rabao.
         Ordering per FFXIclopedia; BG Wiki permutes levels 3-8 differently and
         the two cannot both be right. Waylea's lines run to several paragraphs
         with hard line breaks, so anchors stay inside a single sentence. ]]
    rabao_selbina = {
        npc = 'Waylea',
        zone = 247,                     -- Rabao (G-9)
        levels = {
            [1] = {"taking on many requests"},
            [2] = {'vague memory of hearing that name'},
            [3] = {'once or twice around these parts'},
            [4] = {'journey of a thousand miles'},
            [5] = {'endeavors in neighboring countries'},
            [6] = {'comes up quite a lot in conversation'},
            [7] = {'hardly a soul in all of rabao'},
            [8] = {'start making appointments'},
            [9] = {'status of hero in my eyes'},
        },
    },

    --[[ Norg / Tenshodo is an INDEPENDENT track -- it is not raised by the
         three nations' fame and does not feed them. Three quests in v1 scope
         are gated on it (Silence of the Rams lvl 2, Shady Business lvl 1,
         Faded Promises lvl 4), all given in Jeuno, so this can gate markers a
         long way from Norg itself.

         Vaultimand is the only checker used. The rice-ball price method (via
         Ghebi Damomohe in Lower Jeuno) is deliberately NOT implemented: it
         infers fame from a vendor's asking price, which needs a shop
         interaction rather than a dialogue line and is a far more fragile
         signal than being told the answer outright.

         Anchors avoid his Mister/Miss and Lord/Lady branches at levels 7-9. ]]
    norg = {
        npc = 'Vaultimand',
        zone = 252,                     -- Norg (H-8)
        levels = {
            [1] = {'one puny ant'},
            [2] = {'me line of work'},
            [3] = {'keep up tha good work'},
            [4] = {'measly insect'},
            [5] = {"talkin' to me mateys"},
            [6] = {'hardly a soul in norg'},
            [7] = {"household name 'round norg"},
            [8] = {'some sorta legend'},
            [9] = {"next t'our leader"},
        },
    },

    windurst = {
        npc = 'Zabirego-Hajigo',
        zone = 238,                     -- Windurst Waters
        levels = {
            [1] = {'never heard that name before'},
            [2] = {'some other lady', 'some other lord'},
            [3] = {'starting to talk about'},
            [4] = {'over their dinners'},
            [5] = {"aren't many windurstians"},
            [6] = {'living in a hole'},
            [7] = {"isn't a soul in all of windurst"},
            [8] = {"a day doesn't go by"},
            [9] = {'honored to have the hero'},
        },
    },
}
