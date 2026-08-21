--[[
core/kills.lua -- how many of that monster you have beaten this session.

No packet carries a per-quest kill counter; 0x056 only says available / in
progress / done, and it stays the source for completion. So "defeat 5 Nasu" is
counted from combat messages, display only: no marker state, no step advance,
nothing on disk. A count built from messages is a guess, and a wrong guess
saved is permanent; observations get saved here, inferences never do.

Input is 0x028 through `windower.packets.parse_action` (in plugins/LuaCore.dll
here). Seven of the 781 ids in res/action_messages.lua mean the target died,
read out of that file in this install rather than off a wiki:

     6  ${actor} defeats ${target}.
    20  ${target} falls to the ground.
    97  ${target} was defeated by ${actor}.
   113  ${actor} casts ${spell}. ${target} falls to the ground.
   406  ${actor} uses ${weapon_skill}. ${target} falls to the ground.
   605  Additional effect: ${target} falls to the ground.
   646  ${actor} uses ${ability}. ${target} falls to the ground.

Those fire for every fight in the zone, so only your kills and your party's
count, and even that is an approximation, labelled as one wherever it shows:
FFXI credits whoever had the mob claimed and the packet does not say who, so
a mob your party killed on someone else's claim counts here, not in game.

Message 558, "You defeated a designated target. (Progress: ${number}/
${number2})", is the game counting for itself, on 0x02D not 0x028, with
`Param 1` the numerator and `Param 2` the denominator (fields.lua:1992).
Exact, but only for designated targets (Records of Eminence), not for quests.
]]

local kills = {}

--[[ The seven ids that mean the target died. A set rather than a list: this is
     consulted once per action in a combat packet. ]]
local DEFEAT = {
    [6] = true, [20] = true, [97] = true,
    [113] = true, [406] = true, [605] = true, [646] = true,
}

--[[ The game's own progress line for a designated target -- exact, not
     inferred. Arrives on 0x02D with an explicit numerator and denominator; see
     kills.handle_message. ]]
local DESIGNATED = 558

local counts = {}           -- folded monster name -> defeats seen this session
local designated = nil      -- {done, total} from the last message 558
local seen = 0              -- total defeats attributed, for diagnostics

--[[ What is worth counting, and the reason this is not just a filter.

     0x028 arrives for every action of every fight in the zone -- in a camp
     that is a continuous stream, and parsing all of it to answer a question
     nobody asked would be the most expensive thing this addon does. So the
     entry point asks `watching()` FIRST and does not even parse the packet
     when the answer is no, which on a character with no monster-step quest in
     progress is always.

     The set is the monsters named by steps of quests you have actually
     accepted, rebuilt when 0x056 settles. Empty by default: a fresh session
     counts nothing until the index says there is something to count. ]]
local watch = nil           -- folded name -> true, or nil for "nothing"
local n_watch = 0

local function fold(s)
    if s == nil then return nil end
    s = tostring(s):gsub('%s+', ' ')
    return (s:gsub('^%s+', ''):gsub('%s+$', '')):lower()
end
kills.fold = fold

--[[ Injectable so the whole module is testable with no game client -- the same
     pattern core/inventory.lua uses.

     `name_of` and `mine` are resolved AT PACKET TIME on purpose. A defeated mob
     is on its way out of the entity list, so asking for its name a frame later
     can return nothing; and party membership at the moment of the kill is the
     only membership that matters. ]]
local api = {
    name_of = function(id)
        local w = windower
        local f = w and w.ffxi and w.ffxi.get_mob_by_id
        local ok, m = pcall(function() return f and f(id) end)
        return (ok and type(m) == 'table') and m.name or nil
    end,
    -- Is this actor me, or someone in my party or alliance?
    mine = function(actor_id)
        local w = windower
        if not (w and w.ffxi) then return false end
        local ok, me = pcall(w.ffxi.get_mob_by_target, 'me')
        if ok and type(me) == 'table' and me.id == actor_id then return true end
        local okp, party = pcall(w.ffxi.get_party)
        if not okp or type(party) ~= 'table' then return false end
        for _, m in pairs(party) do
            if type(m) == 'table' and m.mob and m.mob.id == actor_id then
                return true
            end
        end
        return false
    end,
}

function kills.set_api(t)
    for k, v in pairs(t or {}) do api[k] = v end
end

function kills.reset()
    counts, designated, seen = {}, nil, 0
    watch, n_watch = nil, 0
end

--[[ Replace the watch set. `names` is an array of monster names, folded here so
     callers never have to know the rule.

     The COUNTS ARE NOT CLEARED. A quest finishing narrows the set, and wiping
     what was already counted would make `//qm kills` forget a fight you just
     had -- while a quest you re-accept in the same session keeps a tally that
     is at worst generous, and is display-only in either case. ]]
function kills.set_watch(names)
    local set, n = nil, 0
    for _, nm in ipairs(names or {}) do
        local k = fold(nm)
        if k and k ~= '' and not (set and set[k]) then
            set = set or {}
            set[k] = true
            n = n + 1
        end
    end
    watch, n_watch = set, n
end

-- Is there anything at all worth parsing a combat packet for?
function kills.watching() return n_watch > 0 end
function kills.watch_size() return n_watch end

--[[ Feed a parsed 0x028.  -> number of defeats attributed by this packet.

     `a` is what `windower.packets.parse_action` returns:
     `{actor_id, targets = {{id, actions = {{message, ...}}}}}`. Everything is
     read defensively -- a shape this does not recognise contributes nothing
     rather than throwing inside a packet handler. ]]
function kills.handle_action(a)
    if type(a) ~= 'table' or type(a.targets) ~= 'table' then return 0 end

    local n = 0
    local ours = nil        -- resolved at most once per packet, and only if needed
    for _, t in pairs(a.targets) do
        if type(t) == 'table' and type(t.actions) == 'table' then
            for _, act in pairs(t.actions) do
                if type(act) == 'table' and DEFEAT[act.message] then
                    --[[ Resolved once per packet and only when a defeat is
                         actually present: `mine` costs a party read, and the
                         overwhelming majority of 0x028 packets are ordinary
                         hits with nothing to count. ]]
                    if ours == nil then ours = api.mine(a.actor_id) and true or false end
                    if ours then
                        local nm = fold(api.name_of(t.id))
                        --[[ Only monsters some accepted quest actually names.
                             Counting everything would turn a levelling session
                             into thousands of entries nobody will ever read,
                             and `//qm kills` is meant to answer one question:
                             am I done with this step. ]]
                        if nm and watch and watch[nm] then
                            counts[nm] = (counts[nm] or 0) + 1
                            seen = seen + 1
                            n = n + 1
                        end
                    end
                end
            end
        end
    end
    return n
end

--[[ Feed a parsed 0x02D ('Kill Message' / basic message).  -> true if it was
     the designated-target progress line.

     This is the one place the GAME hands over a count, so it is kept apart
     from the inferred numbers above and shown as what it is. fields.lua:1992:
     Param 1 is the numerator, Param 2 the denominator, Message the id. ]]
function kills.handle_message(p)
    if type(p) ~= 'table' or p.Message ~= DESIGNATED then return false end
    local a, b = p['Param 1'], p['Param 2']
    if type(a) ~= 'number' or type(b) ~= 'number' then return false end
    designated = {done = a, total = b}
    return true
end

-- How many of this monster have you beaten since login. Name is folded here.
function kills.count(name)
    local k = fold(name)
    return k and counts[k] or 0
end

--[[ Progress across a step's whole monster list.  -> done, needed

     A step can name several monsters -- "defeat the three Nasu and the
     Wyrmfly" -- and the data records a count per monster. `needed` is their
     sum, so a step with no counts recorded reports 0 needed and callers can
     say nothing rather than saying "0 of 0". ]]
function kills.progress(mobs)
    if type(mobs) ~= 'table' then return 0, 0 end
    local done, needed = 0, 0
    for _, m in ipairs(mobs) do
        local want = m.n or 1
        needed = needed + want
        --[[ Clamped per monster. Without this, killing eight of one and none
             of the other reads as "8 of 8 done" for a step that wants four of
             each -- an over-count that would look like a bug in the data. ]]
        local got = kills.count(m.name)
        done = done + (got > want and want or got)
    end
    return done, needed
end

function kills.designated() return designated end

function kills.stats()
    local names = 0
    for _ in pairs(counts) do names = names + 1 end
    return {defeats = seen, names = names, designated = designated,
            watching = n_watch}
end

--[[ Every counted monster, highest first, for `//qm kills`. ]]
function kills.all()
    local out = {}
    for name, n in pairs(counts) do out[#out + 1] = {name = name, n = n} end
    table.sort(out, function(x, y)
        if x.n ~= y.n then return x.n > y.n end
        return x.name < y.name
    end)
    return out
end

kills.DEFEAT_MESSAGES = DEFEAT

return kills
