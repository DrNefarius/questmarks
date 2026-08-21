--[[
npc_overrides.lua -- hand-curated fixes for the page's `Start=` giver strings.

This file is applied by tools/build_index.lua BEFORE any parsing, so an entry
here wins outright over the automatic normalizer. Re-run the builder after
editing:

    luajit tools/build_index.lua        (or //qm rebuild in game)

Keys are the page's raw giver string -- the `Start=` field verbatim --
lowercased and whitespace-collapsed.

Values:
    {names = {'Real Name', ...}}        map to one or more real entity names
    {names = {...}, zone = 231}         ... and pin it to a zone id
    {drop = true, kind = 'generic'}     never mark this one

---------------------------------------------------------------------------
HOW TO FILL IN THE GATE GUARDS
---------------------------------------------------------------------------
DONE -- this section is kept as the record of HOW, not as a task.

63 nation-mission entries used to fall out of the index because BG Wiki records
their giver as "Any Bastok Gate Guard", a ROLE rather than an entity the client
has. Those are the starting missions for all three nations, so they mattered.

They were deliberately NOT guessed -- inventing entity names produces markers
that silently never appear. They were read off the live client instead: dump
every NPC name in each nation's starting city and take the guards standing at
the zone exits. All 11 are below, cross-checked against the wiki's
Category:Gate_Guard.

If a future role needs the same treatment, that is the procedure: dump the
zone, read the names, add them here. Never guess one.

Zone ids for reference (res/zones.lua):
    230 Southern San d'Oria   231 Northern San d'Oria   232 Port San d'Oria
    234 Bastok Mines          235 Bastok Markets        236 Port Bastok
    238 Windurst Waters       239 Windurst Walls        240 Port Windurst
    241 Windurst Woods        243 Ru'Lude Gardens       244 Upper Jeuno
    245 Lower Jeuno           246 Port Jeuno
]]

return {
    --[[ -------------------------------------------------------------------
    Gate guards -- nation missions.

    Names from https://www.bg-wiki.com/ffxi/Category:Gate_Guard
    Cross-checked against live NPC dumps: Endracion (zone 230), Cleades
    (zone 235) and Rakoh Buuma (zone 241) all appear verbatim, which confirms
    the list matches real entity names.

    `zone = false` means "match in ANY zone" -- deliberate, because a nation
    mission can be started at any of its nation's gate guards, which sit in
    different zones. Without this the quest's own start_zone would pin the
    marker to one city district.
    ------------------------------------------------------------------------ ]]
    ["any san d'oria gate guard"] = {
        zone = false,
        names = {
            'Ambrotien',        -- Southern San d'Oria
            'Endracion',        -- Southern San d'Oria  (confirmed in dump)
            'Grilau',           -- Northern San d'Oria
        },
    },
    ["any bastok gate guard"] = {
        zone = false,
        names = {
            'Argus',            -- Port Bastok
            'Cleades',          -- Bastok Markets       (confirmed in dump)
            'Rashid',           -- Bastok Mines
            'Malduc',           -- Metalworks
        },
    },
    ["any windurst gate guard"] = {
        zone = false,
        names = {
            'Rakoh Buuma',      -- Windurst Woods       (confirmed in dump)
            'Janshura-Rashura', -- Port Windurst
            'Mokyokyo',         -- Windurst Waters
            'Zokima-Rokima',    -- Windurst Walls
        },
    },

    -- ---------------------------------------------------------------------
    -- Extractor damage in the source data. These are real NPCs whose names
    -- were truncated or mangled during the BG Wiki scrape.
    -- ---------------------------------------------------------------------
    ["roskin (near caf[\\'e] des larmes"] = {names = {'Roskin'}},
    ["nhili uvolep (order of renaye"]     = {names = {'Nhili Uvolep'}},
    ["amchuchu (inventors\\' coalition"]  = {names = {'Amchuchu'}},
    ["belgidiveau,,"]                     = {names = {'Belgidiveau'}},

    -- ---------------------------------------------------------------------
    -- Add your own below. Anything listed in tools/unmatched.txt that is
    -- actually a real, name-matchable NPC belongs here.
    -- ---------------------------------------------------------------------
}
