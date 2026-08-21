--[[
core/fame.lua -- the player's fame level per region.

FFXI never sends numeric fame; there is no "fame" field anywhere in Windower's
packet definitions, only NPC dialogue. Three sources, combined with max():

  1. Dialogue (exact). A checker NPC tells you your level, read off
     `incoming text`: mode 150 (MESSAGE), from_shift_jis, strip PROMPT_CHARS
     \x7F\x31, strip \x1E/\x1F colour codes, split on " : " for speaker and
     line. Only fires when you visit a checker, hence 2 and 3.
  2. Inferred floor (free, no guessing). A quest gated at San d'Oria fame 5
     in your accepted list means you MUST have had fame 5 to accept it, so
     floor[region] = max(fame_lvl over accepted quests there). Completed
     non-repeatables stay in `current` forever, so it is a genuine lower bound.
  3. Manual (`//qm fame sandoria 6`). Always available, always wins ties.

Estimating fame from completed-quest counts is deliberately not implemented.
Fame per quest varies, repeatables grant it again, some grant none, and it
pools per fame-area with per-city multipliers, so a guess is confidently wrong.

meets() returns true / false / nil. nil must never collapse to either.
]]

local fame = {}

local dialogue_data = require('data/fame_dialogue')

local MAX_LEVEL = 9

-- region -> level, per source
local learned = {}      -- from dialogue
local manual  = {}      -- from //qm fame
local floor_  = {}      -- inferred lower bound

-- Every fame region the addon knows. Six of them ship checker anchors in
-- data/fame_dialogue.lua; kazham, mhaura and aht_urhgan do not, so those
-- three are only ever learned from a floor or set by hand.
--[[ Rabao and Selbina are ONE fame area sharing a single checker (Waylea, in
     Rabao) -- FFXIclopedia lists them as a single column. Mhaura is separate:
     the linkage rules group it with Kazham as a feeder for Windurst, not with
     Rabao/Selbina. ]]
local KNOWN_REGIONS = {
    sandoria = true, bastok = true, windurst = true, jeuno = true,
    kazham = true, rabao_selbina = true, norg = true, mhaura = true,
    aht_urhgan = true,
}

-- Confirmed linkage worth applying: Kazham always reports the same level as
-- Windurst. Jeuno's "roughly the average of the three nations" is documented as
-- approximate, so it is NOT derived here -- guessing would produce wrong marks.
local MIRRORS = {kazham = 'windurst'}

fame.unmatched = {}     -- checker lines we saw but could not classify

function fame.reset()
    learned, manual, floor_ = {}, {}, {}
    fame.unmatched = {}
end
fame.reset()

-- ---------------------------------------------------------------------------
-- Text pipeline (pure, so it can be tested without a game client)
-- ---------------------------------------------------------------------------

local PROMPT_CHARS = string.char(0x7F, 0x31)

--[[ Raw client text -> speaker, line.
     Kept free of any windower call so tests can drive it directly; the
     Shift-JIS decode is injected by the caller. ]]
function fame.clean_text(s)
    if type(s) ~= 'string' then return nil, nil end

    -- auto-translate / colour markers: 0x1E and 0x1F each take one argument byte
    s = s:gsub('\30.', ''):gsub('\31.', '')
    -- trailing prompt indicator
    s = s:gsub(PROMPT_CHARS, '')
    -- remaining control bytes
    s = s:gsub('[%z\1-\8\11\12\14-\31\127]', ' ')
    s = s:gsub('%s+', ' '):gsub('^%s+', ''):gsub('%s+$', '')
    if s == '' then return nil, nil end

    -- Non-greedy: the first " : " splits speaker from line, later ones stay.
    local npc, line = s:match('^(.-) : (.*)$')
    if npc and #npc < 32 then
        return npc, line
    end
    return nil, s
end

-- ---------------------------------------------------------------------------
-- Dialogue matching
-- ---------------------------------------------------------------------------

--[[ Fold text for anchor comparison.

     Apostrophes are the trap here: the anchors were transcribed from wiki
     pages, which use typographic quotes (U+2019, and its CP932/UTF-8 byte
     forms), while the game client emits ASCII. An anchor like "isn't a soul"
     would silently never match. Normalise every variant to ASCII ' on both
     sides, and also accept the expanded form of the common contractions so a
     transcription difference cannot cost us a reading. ]]
local function fold_text(s)
    s = s:lower()
    s = s:gsub('\226\128\153', "'")     -- UTF-8 U+2019
    s = s:gsub('\226\128\152', "'")     -- UTF-8 U+2018
    s = s:gsub('\146', "'")             -- CP1252 / Shift-JIS single byte
    s = s:gsub('`', "'")
    s = s:gsub("is not", "isn't")
    s = s:gsub("does not", "doesn't")
    s = s:gsub("are not", "aren't")
    s = s:gsub('%s+', ' ')
    return s
end
fame.fold_text = fold_text

--[[ Classify a checker line. Returns region, level or nil.
     When several anchors match, the LONGEST wins -- some levels' phrasing is a
     prefix of another's (Windurst 1 contains San d'Oria 1's anchor). ]]
function fame.classify(npc, line, zone)
    if not npc or not line then return nil end
    local lnpc, lline = npc:lower(), fold_text(line)

    for region, cfg in pairs(dialogue_data) do
        if cfg.npc:lower() == lnpc then
            -- Abyssea reuses these NPC names for separate 6-level fame tracks,
            -- so the zone check is what stops an Abyssea reading from being
            -- written to a city region.
            if cfg.zone and zone and cfg.zone ~= zone then
                return nil, 'zone mismatch'
            end
            local best_lvl, best_len = nil, -1
            for lvl, anchors in pairs(cfg.levels) do
                for _, a in ipairs(anchors) do
                    local fa = fold_text(a)
                    if #fa > best_len and lline:find(fa, 1, true) then
                        best_lvl, best_len = lvl, #fa
                    end
                end
            end
            if best_lvl then return region, best_lvl end
            return nil, 'unmatched', region
        end
    end
    return nil
end

--[[ The last checker we successfully read, so that continuation lines from the
     SAME NPC are not logged as failures. FFXI splits long dialogue across
     several text events, so the tail of a matched line arrives on its own and
     must not be recorded as unclassified. That noise buries genuine anchor
     failures, and //qm fame dump is the only channel for spotting those. ]]
local last_matched_npc = nil

--[[ Feed one line of already-decoded client text.
     Returns region, level, changed when a fame reading was learned. ]]
function fame.observe(text, zone)
    local npc, line = fame.clean_text(text)
    if not npc then return nil end

    local lnpc = npc:lower()
    local region, lvl, why = fame.classify(npc, line, zone)
    if region and lvl then
        last_matched_npc = lnpc
        local prev = learned[region]
        learned[region] = lvl
        return region, lvl, (prev ~= lvl)
    end

    -- Remember unclassified checker lines so //qm fame dump can surface them.
    -- This is how a wrong anchor gets caught: every anchor was transcribed
    -- from a wiki, not from text the client actually emitted.
    if lvl == 'unmatched' and lnpc ~= last_matched_npc then
        fame.unmatched[#fame.unmatched + 1] = {npc = npc, line = line, region = why}
        if #fame.unmatched > 20 then table.remove(fame.unmatched, 1) end
    end

    -- A different speaker ends the previous conversation.
    if lnpc ~= last_matched_npc then last_matched_npc = nil end
    return nil
end

-- ---------------------------------------------------------------------------
-- Sources
-- ---------------------------------------------------------------------------

local function clamp(l)
    l = tonumber(l)
    if not l then return nil end
    l = math.floor(l)
    if l < 0 then l = 0 elseif l > MAX_LEVEL then l = MAX_LEVEL end
    return l
end

function fame.set_manual(region, level)
    if not KNOWN_REGIONS[region] then return false, 'unknown region' end
    if level == nil then manual[region] = nil return true end
    local l = clamp(level)
    if not l then return false, 'level must be 0-' .. MAX_LEVEL end
    manual[region] = l
    return true
end

function fame.set_floor(region, level)
    local l = clamp(level)
    if not l then return end
    if not floor_[region] or floor_[region] < l then floor_[region] = l end
end

--[[ Recompute the inferred floor from accepted quests.
     `iter` yields (region, required_level) for every quest the player has
     accepted (current OR completed) that carries a fame gate. ]]
function fame.rebuild_floors(iter)
    floor_ = {}
    for region, req in iter do
        if region and req then fame.set_floor(region, req) end
    end
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--[[ Highest authority first. Order matters, so this is an array and not a
     hash walked with `pairs()`.

     The label is not cosmetic: fame.meets() reads it, so a `floor` win
     answers nil (black "!") where a `dialogue` win answers false (grey
     "!"). Same character, same numbers, two different markers. A hash would
     settle the dialogue-vs-floor tie on iteration order, and the game runs
     PUC-Rio 5.1 while the tests run LuaJIT: the two do not order a table
     alike. Walking in order and comparing with a strict `>` below means an
     equal reading can never displace the one already held.

     manual   the user asserted it deliberately; it outranks everything.
     dialogue a checker NPC stated it: a measurement at a known moment.
     floor    a bound, not a reading, and the one meets() will not prove a
              negative with. A floor that only ties a real reading has added
              nothing, so it must not take the label. ]]
local SOURCE_ORDER = {'manual', 'dialogue', 'floor'}

--[[ Resolved per call, never captured: reset() and rebuild_floors() REBIND
     these locals rather than clearing them in place, so a table grabbed at
     load time goes stale the first time a character logs in. reset() has a
     live caller in the login handler, immediately followed by import().
     import() itself does NOT rebind; it writes in place (`manual[r] = ...`),
     so it is safe. ]]
local function source_table(name)
    if name == 'manual' then return manual end
    if name == 'dialogue' then return learned end
    if name == 'floor' then return floor_ end
    return nil
end

--[[ -> level, source ('manual' | 'dialogue' | 'floor'), or nil when unknown.
     Sources combine with max(): a floor can only ever raise confidence, and on
     a tie the higher-authority source keeps the answer -- see SOURCE_ORDER. ]]
function fame.get(region)
    local src = MIRRORS[region] and region or nil
    local probe = MIRRORS[region] or region

    local best, from = nil, nil
    for _, source in ipairs(SOURCE_ORDER) do
        local tbl = source_table(source)
        local v = tbl and tbl[probe]
        --[[ Strict `>`, walking highest authority first: a later source has to
             beat the incumbent, not merely equal it. That is the whole tie
             rule. Write it as a comparison, not as a special case for one
             named source, so a source added here can never turn the tie into
             a coin flip. ]]
        if v and (best == nil or v > best) then
            best, from = v, source
        end
    end
    if best and src then from = from .. ' (mirrors ' .. probe .. ')' end
    return best, from
end

--[[ -> true / false / nil.
     nil means "cannot verify" and MUST propagate as unknown, not collapse to
     either answer; that is what the blue "unverifiable" marker is for.

     The floor is a lower bound, so it cannot prove a negative.
     `rebuild_floors` builds the floor from quests you have already accepted,
     so a quest gated at fame 2 puts the floor at 2: fame is at least 2, and
     that says nothing about whether it is under 5. Never answer false off a
     floor: core/prereq.lua turns false into `add(false, ...)`, a grey marker,
     and a wrong yellow only wastes a trip while a wrong grey hides the quest
     and gives no hint it is there.

         floor >= required   ->  true   (the real value is at least the floor)
         floor <  required   ->  nil    (unknown, NOT "not met")

     Dialogue and manual readings answer both ways: they measure the value at
     a known moment. They do go stale as fame rises (295 entries are
     fame-gated), so re-visit a checker or use `//qm fame`, not loosen this. ]]
function fame.meets(region, required)
    if not region or not required or required <= 0 then return true end
    local have, src = fame.get(region)
    if have == nil then return nil end
    if have >= required then return true end
    --[[ `src` may carry a suffix, as in 'floor (mirrors windurst)' for
         kazham, so this is a find and not an equality test. ]]
    if src and src:find('floor', 1, true) then return nil end
    return false
end

function fame.regions()
    local l = {}
    for r in pairs(KNOWN_REGIONS) do l[#l + 1] = r end
    table.sort(l)
    return l
end

function fame.has_anchors(region) return dialogue_data[region] ~= nil end

function fame.checkers()
    local l = {}
    for region, cfg in pairs(dialogue_data) do
        l[#l + 1] = {region = region, npc = cfg.npc, zone = cfg.zone}
    end
    table.sort(l, function(a, b) return a.region < b.region end)
    return l
end

-- persistence hooks for libs/config
function fame.export() return {manual = manual, learned = learned} end

function fame.import(t)
    if type(t) ~= 'table' then return end
    for r, v in pairs(t.manual or {}) do if KNOWN_REGIONS[r] then manual[r] = clamp(v) end end
    for r, v in pairs(t.learned or {}) do if KNOWN_REGIONS[r] then learned[r] = clamp(v) end end
end

fame.MAX_LEVEL = MAX_LEVEL

return fame
