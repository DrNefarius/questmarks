--[[
core/skills.lua -- decodes packet 0x062 "Skills Update" and works out the shape
of `windower.ffxi.get_player().skills` by experiment instead of guessing.

Layout is from libs/packets/fields.lua:3111-3128 in this install. Offsets there
are absolute and the field list starts at 0x04, so the leading char[124] of
junk puts the 48 combat entries at 0x80, the 10 craft entries at 0xE0, and the
last byte we read at 0xF3. `lookup={res.skills,0x30}` is what binds the craft
block to res/skills.lua ids 48..57, Fishing 48 through Synergy 57.

Read straight off the bytes, not through `packets.parse`: parse never applies a
field's `fn` and may not handle ref/count/bit structures at all. Bits are
LSB-first in a little-endian 16-bit word, the same decode core/keyitems.lua
uses on 0x055, which agrees with get_key_items() on 43 of 43 key items in play.
So word = b0 + b1*256, and

    Rank   = word AND 0x1F          bits 0-4
    Level  = (word >> 5) AND 0x3FF  bits 5-14
    Capped = word >= 0x8000         bit 15
    combat entries: Level is bits 0-14, same Capped bit, no Rank

`get_player().skills` is pollable and the packet is not (0x062 arrives on login
and on a skill change, so an addon loaded mid-session may never see one), but
its shape is documented nowhere. LuaCore.dll names the keys at 0x195b40, 46
snake_case entries. Grepping that binary for res/skills.lua's `en` spellings
(`Fishing`, `Hand-to-Hand`) finds nothing and looks like proof the block is
absent; it is not, the keys are snake_case. An absence is only evidence if you
searched for the right thing. Nothing near that block says rank, level or
capped, so 0x062 stays the only authority on craft RANK.

The shape is identified by experiment: each candidate reading is checked
against the packet and survives only if it agrees on every skill. Eliminate on
disagreement, never confirm by silence, and two survivors means "ambiguous"
with nothing trusted. One DISCRIMINATING skill is needed as well, one whose
value differs between candidates: a character with every craft at 0 makes the
raw-word, level and rank readings identical, and a vacuous pass is worth less
than no experiment. Tables with named rank/level fields say what they are and
skip all this; `//qm probe` prints the raw value, the shape and the verdict.

Tri-state throughout: before a 0x062 arrives, craft rank is UNKNOWN, not zero.
Reading it as zero would grey every craft-gated quest just because the addon
has not looked yet. Same hedge as `inventory.ready()` in core/steps.lua, and
the reason the blue/black "!" exists.
]]

local skills = {}

local bit = require('bit')
local band, rshift = bit.band, bit.rshift

--[[ res/skills.lua ids. The Synthesis block is contiguous and the packet's own
     `lookup` offset (0x30 = 48) is what says so, so these are read off the
     field definition rather than off a wiki page. ]]
local COMBAT_FIRST, COMBAT_N = 0x00, 0x30      -- ids 0..47
local CRAFT_FIRST,  CRAFT_N  = 0x30, 0x0A      -- ids 48..57
local COMBAT_OFF, CRAFT_OFF  = 0x80, 0xE0      -- packet offsets
local NEEDED = CRAFT_OFF + CRAFT_N * 2         -- 0xF4 bytes: last read is 0xF3

skills.CRAFT_FIRST = CRAFT_FIRST
skills.CRAFT_LAST  = CRAFT_FIRST + CRAFT_N - 1
skills.COMBAT_LAST = COMBAT_FIRST + COMBAT_N - 1

--[[ Every key in LuaCore's block, against its res/skills.lua id.

     Written out rather than folded from res because this module is SHIPPED and
     may not read res/ at runtime, and because the experiment below needs a
     fixed anchor: it interprets get_player().skills BEFORE any gate has been
     evaluated, so it cannot borrow a name from the index the way the reason
     lines do.

     The mapping is a PLAIN FOLD of res/skills.lua's `en` -- lowercase, hyphen
     and space to underscore -- and that was checked rather than assumed: all 43
     keys in the binary block match, with no special cases, and the only res rows
     without a key are id 0 "(N/A)" and the three Automaton skills (22-24), which
     the block genuinely omits. Those three therefore have no name reading and
     are answered by the packet alone.

     All 43 keys are listed, not just the ten crafts. A character with no craft
     skills gives the experiment nothing to tell the raw-word and level
     readings apart; the 48 combat skills are what identify the shape. Do not
     trim this table back to the crafts a gate reads by name. ]]
local SKILL_KEYS = {
    [1]  = 'hand_to_hand',        [2]  = 'dagger',
    [3]  = 'sword',               [4]  = 'great_sword',
    [5]  = 'axe',                 [6]  = 'great_axe',
    [7]  = 'scythe',              [8]  = 'polearm',
    [9]  = 'katana',              [10] = 'great_katana',
    [11] = 'club',                [12] = 'staff',
    [25] = 'archery',             [26] = 'marksmanship',
    [27] = 'throwing',            [28] = 'guard',
    [29] = 'evasion',             [30] = 'shield',
    [31] = 'parrying',            [32] = 'divine_magic',
    [33] = 'healing_magic',       [34] = 'enhancing_magic',
    [35] = 'enfeebling_magic',    [36] = 'elemental_magic',
    [37] = 'dark_magic',          [38] = 'summoning_magic',
    [39] = 'ninjutsu',            [40] = 'singing',
    [41] = 'stringed_instrument', [42] = 'wind_instrument',
    [43] = 'blue_magic',          [44] = 'geomancy',
    [45] = 'handbell',
    [48] = 'fishing',      [49] = 'woodworking', [50] = 'smithing',
    [51] = 'goldsmithing', [52] = 'clothcraft',  [53] = 'leathercraft',
    [54] = 'bonecraft',    [55] = 'alchemy',     [56] = 'cooking',
    [57] = 'synergy',
}
--[[ res/synth_ranks.lua: 0 Amateur .. 8 Adept .. 10 Expert. Named here only so
     `//qm probe` and the build's assertions can say "8 is Adept" without this
     module reading res/ -- which it must not do, being shipped code. ]]
skills.MAX_RANK = 10

-- [id] = {rank = n|nil, level = n, capped = bool}
local by_id = {}
local n_packets = 0
local shape = nil               -- nil until get_player().skills has been looked at
local shape_detail = nil        -- human-readable, for //qm probe
local player_trusted = false
local player_skills = nil       -- the last table get_player() handed over
local identified = nil          -- the surviving reading, for skills.get
local last_check = nil          -- {tested, agreed, discriminating} or nil

function skills.reset()
    by_id = {}
    n_packets = 0
    shape, shape_detail = nil, nil
    player_trusted = false
    player_skills = nil
    identified = nil
    last_check = nil
    skills.reset_points()
end

-------------------------------------------------------------------------------
-- The packet
-------------------------------------------------------------------------------

local function word_at(data, off)
    local a, b = data:byte(off + 1), data:byte(off + 2)
    if a == nil or b == nil then return nil end
    return a + b * 256
end

local function craft_of(w)
    return {rank = band(w, 0x1F),
            level = band(rshift(w, 5), 0x3FF),
            capped = w >= 0x8000}
end

local function combat_of(w)
    return {rank = nil, level = band(w, 0x7FFF), capped = w >= 0x8000}
end

local function same(a, b)
    return a and b and a.rank == b.rank and a.level == b.level
       and a.capped == b.capped
end

--[[ Feed the RAW incoming chunk for 0x062.  -> changed(boolean)

     Refused rather than half-read when the chunk is short. A truncated packet
     that overwrote ten good craft entries with nils would turn a known rank
     into an unknown one, and "the addon stopped knowing" is a worse failure
     than "the addon never knew": the first looks like a bug in the gate. ]]
function skills.handle_chunk(data)
    if type(data) ~= 'string' or #data < NEEDED then return false end

    local changed = false
    local function put(id, v)
        if not same(by_id[id], v) then changed = true end
        by_id[id] = v
    end

    for i = 0, COMBAT_N - 1 do
        local w = word_at(data, COMBAT_OFF + i * 2)
        if w then put(COMBAT_FIRST + i, combat_of(w)) end
    end
    for i = 0, CRAFT_N - 1 do
        local w = word_at(data, CRAFT_OFF + i * 2)
        if w then put(CRAFT_FIRST + i, craft_of(w)) end
    end

    n_packets = n_packets + 1
    return changed
end

-- Has a 0x062 arrived at all? Everything below reads nil until it has.
function skills.ready() return n_packets > 0 end

--[[ Why a level threshold answers nil instead of false.

     0x062 reports NATURAL skill and the quests check EFFECTIVE skill, so
     `core/prereq.lua` returns nil below a level threshold rather than false.
     The obvious repair is to bound what can be borrowed and grey only when
     even the maximum could not close the gap. The numbers kill it. From BG
     Wiki's Category:Craft and Category:Advanced Synthesis Image Support:
     apron +1, belt +1, specs/hat/gloves +1, Escutcheon phases 2-4 +2, Image
     Support +3, Escutcheon phase-4 enchantment +10, so +18 at the very most.
     A bound of 18 against a threshold of 20 greys a player at natural 0 or 1
     and nobody else, and against `The Wondrous Whatchamacallit`'s Synergy 5
     it never fires at all.

     Worse, every omission from that gear table is a FALSE GREY, the exact
     failure the nil prevents, and new gear only shrinks the bound. It does
     not generalise either: the 12 Category:WSNM quests want combat skill
     240-250, and combat +skill gear is not four slots, it is most of the
     game's equipment plus merits and job traits, so the bound would be too
     large to ever fire.

     One term is observable: res/buffs.lua carries an "Imagery" buff per
     guild craft at ids 235-243, which is 235 + (skill_id - 48) over the nine
     crafts with guilds (Synergy has none), and `get_player()` has a `buffs`
     field. So the +3 is knowable; the gear and the enchantment are not.
     Nothing reads this today. ]]

-------------------------------------------------------------------------------
-- Guild points -- packet 0x113, the OTHER half of a craft-guild gate
-------------------------------------------------------------------------------

--[[ `Indomitable Spirit` costs 95,000 Guild Points AND Fishing rank Adept.
     Grepping for "guild" turns up only shop traffic, which makes the points
     half look unobservable. It is not; the grep was just too narrow.

     From addons/libs/packets/fields.lua:3855, incoming 0x113 "Currency Info":

         {ctype='signed int', label='Guild Points (Fishing)'},        -- 20
         {ctype='signed int', label='Guild Points (Woodworking)'},    -- 24
         ... Smithing 28, Goldsmithing 2C, Weaving 30, Leathercraft 34,
             Bonecraft 38, Alchemy 3C, Cooking 40

     NINE guilds, not ten. They are contiguous at 0x20 in res/skills.lua id
     order for ids 48..56, and Synergy (57) has none -- it is not a guild with a
     point economy. "Weaving" is the guild's name for Clothcraft, id 52; the
     order is what binds them, not the label.

     Deliberately NOT extrapolated past Cooking. 0x44 is `Cinders`, a completely
     different currency, so an off-by-one here would silently report somebody's
     Cinders as their Synergy guild points. ]]
local GP_OFF, GP_FIRST, GP_N = 0x20, 0x30, 9     -- ids 48..56
local GP_NEEDED = GP_OFF + GP_N * 4              -- 0x44 bytes: last read is 0x43

local points_by_id = {}
local n_currency = 0

--[[ Declared here and called from reset() above, which runs earlier in the
     file: `skills.reset` is a table field, so it is resolved at call time and
     the ordering is fine. Written as a separate function anyway so that "what
     login clears" stays one list. ]]
function skills.reset_points()
    points_by_id = {}
    n_currency = 0
end

--[[ Feed the RAW incoming chunk for 0x113.  -> changed(boolean) ]]
function skills.handle_currency(data)
    if type(data) ~= 'string' or #data < GP_NEEDED then return false end
    local changed = false
    for i = 0, GP_N - 1 do
        local off = GP_OFF + i * 4
        local a, b, c, d = data:byte(off + 1), data:byte(off + 2),
                           data:byte(off + 3), data:byte(off + 4)
        if a and b and c and d then
            local v = a + b * 256 + c * 65536 + d * 16777216
            --[[ `signed int` in the field definition, so the top bit is a sign.
                 Guild points should never be negative, but decoding a signed
                 field as unsigned would turn a hypothetical -1 into four
                 billion, which passes every threshold ever written. ]]
            if v >= 2147483648 then v = v - 4294967296 end
            local id = GP_FIRST + i
            if points_by_id[id] ~= v then changed = true end
            points_by_id[id] = v
        end
    end
    n_currency = n_currency + 1
    return changed
end

-- -> number | nil. nil is "no 0x113 has arrived", never "you have none".
function skills.points(id)
    if type(id) ~= 'number' then return nil end
    return points_by_id[id]
end

function skills.meets_points(id, want)
    if type(want) ~= 'number' then return nil end
    local p = skills.points(id)
    if p == nil then return nil end
    return p >= want
end

-------------------------------------------------------------------------------
-- get_player().skills -- shape identification
-------------------------------------------------------------------------------

--[[ The candidate readings. `base` is what index holds skill id 0, and `read`
     turns one stored value into the {rank, level, capped} this module speaks.

     Only the numeric readings need an experiment. A value that is a TABLE
     carrying named fields says what it is, and is handled separately below.

     Six candidates, and an "array of craft ranks" is deliberately absent:
     the field covers all 58 skills and 48 of them have no rank at all, so it is
     not a coherent hypothesis about the client. Do not add one back: a combat
     slot would eliminate it by asserting rank 0 against a truth of nil, which
     is elimination by accident rather than by measurement -- the failure the
     discriminating count below exists to expose. ]]
local function by_index(base)
    return function(id) return id + base end
end
local function by_skill_name(id) return SKILL_KEYS[id] end

local function as_word(v, id)
    return (id >= CRAFT_FIRST) and craft_of(v) or combat_of(v)
end
local function as_level(v) return {level = v} end

--[[ `slot` maps a skill id to the table key a reading expects to find it under,
     so an id-keyed array and a name-keyed table go through identical machinery.
     The name-keyed readings speak about every skill LuaCore names, which is the
     whole point: a character with no crafts still has 48 combat skills to be
     identified against. ]]
local READINGS = {
    {name = 'raw16/0',    slot = by_index(0),    read = as_word},
    {name = 'raw16/1',    slot = by_index(1),    read = as_word},
    {name = 'level/0',    slot = by_index(0),    read = as_level},
    {name = 'level/1',    slot = by_index(1),    read = as_level},
    {name = 'raw16/name', slot = by_skill_name,  read = as_word},
    {name = 'level/name', slot = by_skill_name,  read = as_level},
}

--[[ Does a candidate reading agree with the packet on this skill?

     Compared FIELD BY FIELD and only on fields the candidate actually claims:
     a 'level' reading says nothing about capped, and demanding agreement on a
     field it never asserted would eliminate the correct answer. ]]
local function agrees(got, truth)
    if got == nil or truth == nil then return false end
    if got.rank ~= nil and got.rank ~= truth.rank then return false end
    if got.level ~= nil and got.level ~= truth.level then return false end
    if got.capped ~= nil and got.capped ~= truth.capped then return false end
    return true
end

--[[ Look at whatever get_player() handed over.  -> shape(string)

     Called from the same place refresh_player() already runs, so it costs one
     table walk on events that were happening anyway.

     Nothing here can make a gate answer WRONG: an unidentified shape leaves
     `player_trusted` false, and every reader below falls through to the packet,
     which is exact. The worst case is that this module learns nothing. ]]
function skills.observe(t)
    player_skills = type(t) == 'table' and t or nil
    if type(t) ~= 'table' then
        shape = 'absent'
        shape_detail = ('get_player().skills is %s'):format(type(t))
        player_trusted = false
        identified = nil
        return shape
    end

    --[[ Self-describing: values are tables with the names the packet's own
         field definition uses. Nothing is being guessed, so nothing needs
         corroborating -- and this branch is the only one that works before a
         0x062 has ever arrived.

         Keyed either way. LuaCore's block says the keys are snake_case names,
         but neither family is assumed here. ]]
    local n_tables, n_numbers, n_strkeys, keymin, keymax, n = 0, 0, 0, nil, nil, 0
    for k, v in pairs(t) do
        n = n + 1
        if type(k) == 'number' then
            if keymin == nil or k < keymin then keymin = k end
            if keymax == nil or k > keymax then keymax = k end
        elseif type(k) == 'string' then
            n_strkeys = n_strkeys + 1
        end
        if type(v) == 'table' then n_tables = n_tables + 1
        elseif type(v) == 'number' then n_numbers = n_numbers + 1 end
    end
    local named_keys = n_strkeys > 0 and n_strkeys >= (n - n_strkeys)

    if n_tables > 0 and n_tables >= n_numbers then
        local named = false
        for _, v in pairs(t) do
            if type(v) == 'table' and (type(v.level) == 'number'
                                       or type(v.rank) == 'number') then
                named = true
            end
        end
        shape = named and (named_keys and 'struct/name' or 'struct/id')
                      or 'unrecognised'
        shape_detail = ('%d entries, %s keys, values are tables%s'):format(
            n, named_keys and 'name' or 'numeric',
            named and ' with level/rank fields' or ' with no field we know')
        player_trusted = named
        identified = nil
        return shape
    end

    if n_numbers == 0 then
        shape = 'unrecognised'
        shape_detail = ('%d entries, no numeric values'):format(n)
        player_trusted = false
        identified = nil
        return shape
    end

    --[[ Numeric, so it must be identified against the packet. Nothing can be
         concluded before one has arrived -- and saying so is the answer, not a
         failure. ]]
    if not skills.ready() then
        shape = 'numeric, not yet identified'
        shape_detail = ('%d numeric entries, %s -- no 0x062 seen yet, so no '
            .. 'reading can be ruled in or out'):format(n,
                named_keys and (n_strkeys .. ' name keys')
                    or ('keys ' .. tostring(keymin) .. '..' .. tostring(keymax)))
        player_trusted = false
        identified = nil
        return shape
    end

    local alive, tested, discriminating = {}, 0, 0
    for _, c in ipairs(READINGS) do alive[c.name] = c end
    --[[ How many comparisons each reading actually MADE. A name-keyed reading
         looking at an id-keyed table finds nothing under any of its keys, so it
         is never contradicted and would otherwise come through the loop
         untouched and be counted as a survivor -- the vacuous pass again, one
         level up from the all-zero character. Untested is not agreement. ]]
    local seen = {}

    for id, truth in pairs(by_id) do
        --[[ A comparison DISCRIMINATES when it splits the field: some readings
             agree with the packet on this skill and some do not, so looking at
             it eliminates something. Any looser definition lets an all-zero
             character look like a thorough experiment.

             Scored over all six readings, alive or already eliminated.
             Elimination is greedy: the first capped skill kills `raw16/name`,
             so a count scored over survivors alone could never score both a
             yes and a no afterwards and would report a floor, which reads as
             thin evidence. Scoring over all six also makes the count
             independent of the order `pairs` walks in, and eliminations are
             applied only after the skill is scored, for the same reason. ]]
        local verdicts, d_yes, d_no, any = {}, 0, 0, false
        for _, c in ipairs(READINGS) do
            local key = c.slot(id)
            local v = key ~= nil and t[key] or nil
            if type(v) == 'number' then
                any = true
                local ok = agrees(c.read(v, id), truth)
                verdicts[c.name] = ok
                seen[c.name] = (seen[c.name] or 0) + 1
                if ok then d_yes = d_yes + 1 else d_no = d_no + 1 end
            end
        end
        if any then
            tested = tested + 1
            if d_yes > 0 and d_no > 0 then discriminating = discriminating + 1 end
            for name, ok in pairs(verdicts) do
                if not ok then alive[name] = nil end
            end
        end
    end

    local survivors = {}
    for name in pairs(alive) do
        if (seen[name] or 0) > 0 then survivors[#survivors + 1] = name
        else alive[name] = nil end
    end
    table.sort(survivors)
    last_check = {tested = tested, agreed = #survivors,
                  discriminating = discriminating}

    if #survivors == 1 and discriminating > 0 then
        shape = survivors[1]
        shape_detail = ('identified from %d skills (%d discriminating)'):format(
            tested, discriminating)
        player_trusted = true
        identified = alive[survivors[1]]
    elseif #survivors == 0 then
        shape = 'unrecognised'
        shape_detail = ('no reading agreed with the packet over %d skills')
            :format(tested)
        player_trusted = false
        identified = nil
    else
        shape = 'ambiguous'
        shape_detail = ('%d readings still agree (%s) over %d skills, %d of '
            .. 'them discriminating -- not enough to choose'):format(
                #survivors, table.concat(survivors, ' '), tested, discriminating)
        player_trusted = false
        identified = nil
    end
    return shape
end

-------------------------------------------------------------------------------
-- Reading one skill
-------------------------------------------------------------------------------

--[[ -> {rank, level, capped} | nil

     nil is "not known". The PACKET wins whenever it has spoken, because it is
     exact; get_player() is consulted only for a skill the packet has not
     covered, and only once its shape has been established.

     For a numeric reading that establishing REQUIRED the packet, so the
     fallback can only ever fill in a skill a later packet has not yet reached.
     The self-describing shapes are the ones that matter here: they need no
     experiment, so they answer for an addon loaded mid-session that has never
     seen a 0x062 at all. ]]
function skills.get(id)
    if type(id) ~= 'number' then return nil end
    local v = by_id[id]
    if v then return v end
    if not (player_trusted and type(player_skills) == 'table') then return nil end

    if shape == 'struct/name' or shape == 'struct/id' then
        local key = (shape == 'struct/name') and SKILL_KEYS[id] or id
        local raw = key ~= nil and player_skills[key] or nil
        if type(raw) == 'table' and (type(raw.level) == 'number'
                                     or type(raw.rank) == 'number') then
            return {rank = raw.rank, level = raw.level,
                    capped = raw.capped == true or nil}
        end
        return nil
    end

    if identified then
        local key = identified.slot(id)
        local raw = key ~= nil and player_skills[key] or nil
        if type(raw) == 'number' then return identified.read(raw, id) end
    end
    return nil
end

function skills.rank(id)
    local v = skills.get(id)
    return v and v.rank or nil
end

function skills.level(id)
    local v = skills.get(id)
    return v and v.level or nil
end

function skills.capped(id)
    local v = skills.get(id)
    if v == nil then return nil end
    return v.capped == true
end

--[[ The two predicates the gate is made of.  -> true | false | nil

     THE WHOLE POINT IS THE nil. "Fishing rank Adept or higher" is definitely
     false at rank 7 and definitely true at rank 8, and it is NOT false merely
     because no skills packet has been seen. The tri-state is the difference
     between a grey "!" that says why and a grey "!" that is a lie. ]]
function skills.meets_rank(id, want)
    if type(want) ~= 'number' then return nil end
    local r = skills.rank(id)
    if r == nil then return nil end
    return r >= want
end

function skills.meets_level(id, want)
    if type(want) ~= 'number' then return nil end
    local l = skills.level(id)
    if l == nil then return nil end
    return l >= want
end

-------------------------------------------------------------------------------

--[[ Everything //qm probe and //qm data need to settle the open question from
     one login: whether a packet arrived, what get_player().skills turned out to
     be, and -- for the craft block specifically -- the numbers themselves, since
     an all-zero character is exactly the case where the experiment proves
     nothing and the report must say so. ]]
function skills.stats()
    local craft, n_known, n_nonzero = {}, 0, 0
    for id = CRAFT_FIRST, CRAFT_FIRST + CRAFT_N - 1 do
        local v = by_id[id]
        craft[id] = v and {rank = v.rank, level = v.level, capped = v.capped} or nil
        if v then
            n_known = n_known + 1
            if (v.rank or 0) > 0 or (v.level or 0) > 0 then
                n_nonzero = n_nonzero + 1
            end
        end
    end
    --[[ The combat entries are reported too, and they are the ones that will
         actually settle something on a character with no crafts: a CAPPED
         combat skill is the only place the raw-word and level readings differ
         (word = level + 0x8000), and comparing one printed number against the
         in-game menu settles whether the Level field counts whole points or
         tenths -- which the bit width settles for crafts and cannot for
         combat. ]]
    local combat, n_combat, n_capped = {}, 0, 0
    for id = COMBAT_FIRST, COMBAT_FIRST + COMBAT_N - 1 do
        local v = by_id[id]
        if v then
            n_combat = n_combat + 1
            if (v.level or 0) > 0 then
                combat[id] = {level = v.level, capped = v.capped}
            end
            if v.capped then n_capped = n_capped + 1 end
        end
    end
    local gp, n_gp = {}, 0
    for id = GP_FIRST, GP_FIRST + GP_N - 1 do
        gp[id] = points_by_id[id]
        if points_by_id[id] ~= nil then n_gp = n_gp + 1 end
    end
    return {
        packets = n_packets, craft = craft, craft_known = n_known,
        craft_nonzero = n_nonzero, combat_known = n_combat,
        combat = combat, combat_capped = n_capped,
        shape = shape, shape_detail = shape_detail,
        player_trusted = player_trusted, check = last_check,
        currency = n_currency, points = gp, points_known = n_gp,
    }
end

return skills
