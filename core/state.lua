--[[
core/state.lua -- quest and mission completion state, decoded from packet 0x056.

All from packets, no memory reads.

Two decoding schemes, and the difference matters:
  * BITFIELD areas (all quests, plus completed nation/Zilart/ToAU/WotG
    missions) arrive as a 32-byte blob, bit N == DAT index N. Exact.
  * LINEAR mission lines (nation, Zilart, CoP, SoA, RoV, ACP, MKD, ASA, TVR)
    send one "current mission" INTEGER, and fields.lua warns the value
    "doesn't correspond directly to DAT". Those need fuzzy matching.

Watch what `current` means. From libs/packets/fields.lua: "Quests will remain
in your 'current' list after they are completed unless they are repeatable."
So it means "accepted at some point", not "in progress":

    in_progress = current AND NOT completed
    available   = NOT current AND NOT completed
]]

local state = {}

-- ---------------------------------------------------------------------------
-- Sub-type tables
-- ---------------------------------------------------------------------------

-- Sub-types carrying a plain 32-byte 'Quest Flags' bitfield.
local BITFIELD_LOGS = {
    -- current quests
    [0x0050] = {cat = 'quest', kind = 'current',   area = 'sandoria'},
    [0x0058] = {cat = 'quest', kind = 'current',   area = 'bastok'},
    [0x0060] = {cat = 'quest', kind = 'current',   area = 'windurst'},
    [0x0068] = {cat = 'quest', kind = 'current',   area = 'jeuno'},
    [0x0070] = {cat = 'quest', kind = 'current',   area = 'other'},
    [0x0078] = {cat = 'quest', kind = 'current',   area = 'outlands'},
    [0x0088] = {cat = 'quest', kind = 'current',   area = 'crystal_war'},
    [0x00E0] = {cat = 'quest', kind = 'current',   area = 'abyssea'},
    [0x00F0] = {cat = 'quest', kind = 'current',   area = 'adoulin'},
    [0x0100] = {cat = 'quest', kind = 'current',   area = 'coalition'},
    [0x0110] = {cat = 'quest', kind = 'current',   area = 'acp'},
    [0x0120] = {cat = 'quest', kind = 'current',   area = 'mkd'},
    [0x0130] = {cat = 'quest', kind = 'current',   area = 'asa'},
    -- completed quests
    [0x0090] = {cat = 'quest', kind = 'completed', area = 'sandoria'},
    [0x0098] = {cat = 'quest', kind = 'completed', area = 'bastok'},
    [0x00A0] = {cat = 'quest', kind = 'completed', area = 'windurst'},
    [0x00A8] = {cat = 'quest', kind = 'completed', area = 'jeuno'},
    [0x00B0] = {cat = 'quest', kind = 'completed', area = 'other'},
    [0x00B8] = {cat = 'quest', kind = 'completed', area = 'outlands'},
    [0x00C8] = {cat = 'quest', kind = 'completed', area = 'crystal_war'},
    [0x00E8] = {cat = 'quest', kind = 'completed', area = 'abyssea'},
    [0x00F8] = {cat = 'quest', kind = 'completed', area = 'adoulin'},
    [0x0108] = {cat = 'quest', kind = 'completed', area = 'coalition'},
    [0x0118] = {cat = 'quest', kind = 'completed', area = 'acp'},
    [0x0128] = {cat = 'quest', kind = 'completed', area = 'mkd'},
    [0x0138] = {cat = 'quest', kind = 'completed', area = 'asa'},
    --[[ Completed campaign ops, two halves of one ladder.

         Both halves belong to the area `campaign`; every query in the addon
         asks for that name. One 32-byte blob carries 256 bits and campaign DAT
         ids run 1..499, so one blob cannot cover the line. The second blob is
         the same ladder continued at id 256: route it with an offset and merge.

         Merge, do not replace. Both sub-types arrive in one 0x056 burst in no
         guaranteed order. See store_bits(). ]]
    [0x0030] = {cat = 'mission', kind = 'completed', area = 'campaign'},
    [0x0038] = {cat = 'mission', kind = 'completed', area = 'campaign', offset = 256},
}

--[[ Sub-types with named multi-field layouts. `mode` says how to read a field:
       'bits'   a bitfield blob   -> exact membership
       'linear' a current-mission integer -> fuzzy, see resolve_linear()
       'raw'    stash it (Nation, used to route the nation mission line) ]]
local FIELD_LOGS = {
    [0x0080] = {
        {label = 'Current TOAU Quests',      cat = 'quest',   area = 'toau',     kind = 'current',   mode = 'bits'},
        {label = 'Current Assault Mission',  cat = 'mission', area = 'assault',  kind = 'current',   mode = 'linear'},
        {label = 'Current TOAU Mission',     cat = 'mission', area = 'toau',     kind = 'current',   mode = 'linear'},
        {label = 'Current WOTG Mission',     cat = 'mission', area = 'wotg',     kind = 'current',   mode = 'linear'},
        {label = 'Current Campaign Mission', cat = 'mission', area = 'campaign', kind = 'current',   mode = 'linear'},
    },
    [0x00C0] = {
        {label = 'Completed TOAU Quests',    cat = 'quest',   area = 'toau',     kind = 'completed', mode = 'bits'},
        {label = 'Completed Assaults',       cat = 'mission', area = 'assault',  kind = 'completed', mode = 'bits'},
    },
    -- Nation and Zilart missions DO get a completed bitfield here. Only their
    -- "current" pointer is an integer, which makes them far more reliable than
    -- the purely-linear lines.
    [0x00D0] = {
        {label = "Completed San d'Oria Missions", cat = 'mission', area = 'sandoria', kind = 'completed', mode = 'bits'},
        {label = 'Completed Bastok Missions',     cat = 'mission', area = 'bastok',   kind = 'completed', mode = 'bits'},
        {label = 'Completed Windurst Missions',   cat = 'mission', area = 'windurst', kind = 'completed', mode = 'bits'},
        {label = 'Completed Zilart Missions',     cat = 'mission', area = 'zilart',   kind = 'completed', mode = 'bits'},
    },
    [0x00D8] = {
        {label = 'Completed TOAU Missions',  cat = 'mission', area = 'toau', kind = 'completed', mode = 'bits'},
        {label = 'Completed WOTG Missions',  cat = 'mission', area = 'wotg', kind = 'completed', mode = 'bits'},
    },
    [0xFFFE] = {
        {label = 'Current TVR Mission',      cat = 'mission', area = 'tvr',  kind = 'current', mode = 'linear', tvr = true},
    },
    [0xFFFF] = {
        {label = 'Nation',                                                                      mode = 'raw'},
        {label = 'Current Nation Mission',   cat = 'mission', area = 'nation',  kind = 'current', mode = 'linear'},
        {label = 'Current ROZ Mission',      cat = 'mission', area = 'zilart',  kind = 'current', mode = 'linear'},
        {label = 'Current COP Mission',      cat = 'mission', area = 'cop',     kind = 'current', mode = 'linear'},
        {label = 'Current ACP Mission',      cat = 'mission', area = 'acp',     kind = 'current', mode = 'linear'},
        {label = 'Current MKD Mission',      cat = 'mission', area = 'mkd',     kind = 'current', mode = 'linear'},
        {label = 'Current ASA Mission',      cat = 'mission', area = 'asa',     kind = 'current', mode = 'linear'},
        {label = 'Current SOA Mission',      cat = 'mission', area = 'adoulin', kind = 'current', mode = 'linear'},
        {label = 'Current ROV Mission',      cat = 'mission', area = 'rov',     kind = 'current', mode = 'linear'},
    },
}

local NATION_AREA = {[0] = 'sandoria', [1] = 'bastok', [2] = 'windurst'}

--[[ Mutually exclusive mission branches.

     The rank-2 nation mission sends you to the OTHER two nations, one DAT entry
     per destination. You do exactly one, so the sibling's bit stays clear
     forever: a green "!" you can never earn.

     Group on the id layout, not on names. All three nation lines put the base
     at 5 and the branches at 8 and 9, with 6 and 7 unused:

       windurst  #5 The Three Kingdoms  -> #8 (San d'Oria)  #9 (Bastok)
       bastok    #5 The Emissary        -> #8 (San d'Oria)  #9 (Windurst)
       sandoria  #5 Journey Abroad      -> #8 Journey to Bastok, #9 to Windurst

     San d'Oria does not name its branches after the base, so a name rule finds
     only 2 of 3. Do not try one: 286 other index entries have a parenthetical
     suffix (Campaign ops, Abyssea ops, Unlocking a Myth) and none are exclusive.

     Any member completed completes the group, symmetric because we have only
     seen one player's bitfields. First id is the umbrella, the rest branches;
     completed_sibling() prefers a branch so //qm why can say "completed via The
     Three Kingdoms (Bastok)" and name the route actually taken. ]]
local EXCLUSIVE = {
    ['mission/sandoria'] = {{5, 8, 9}},
    ['mission/bastok']   = {{5, 8, 9}},
    ['mission/windurst'] = {{5, 8, 9}},
}

-- id -> its group, built once. Lets status_of() stay a table lookup.
local exclusive_of = {}
for key, groups in pairs(EXCLUSIVE) do
    local m = {}
    for _, g in ipairs(groups) do
        for _, id in ipairs(g) do m[id] = g end
    end
    exclusive_of[key] = m
end

--[[ Another member of this id's exclusive group that the player has completed,
     or nil. Returns nil for everything outside the three nation lines.

     Prefers a BRANCH over the umbrella entry -- see the convention note above.
     Finishing the mission sets both, and the branch is the one that says which
     route was taken. ]]
local function completed_sibling(cat, area, id)
    local m = exclusive_of[cat .. '/' .. area]
    local g = m and m[id]
    if not g then return nil end
    local umbrella
    for i, other in ipairs(g) do
        if other ~= id and state.is_completed(cat, area, other) then
            if i > 1 then return other end
            umbrella = other
        end
    end
    return umbrella
end
-- Public so `//qm why` can name the branch that was actually taken.
state.completed_sibling = completed_sibling

-- ---------------------------------------------------------------------------
-- Storage
-- ---------------------------------------------------------------------------

local bits         -- bits[cat][kind][area] = set (1-indexed; id N -> set[N+1])
local halves       -- halves[cat][kind][area][offset] = the set that blob gave
local spans        -- spans[cat][kind][area][offset]  = how many bits it covered
local linear       -- linear[cat][area]     = current-mission integer
local linear_idle  -- linear_idle[cat][area] = true when the pointer means
                   -- "nothing active, this is the NEXT one" (TVR bit 31), so
                   -- the mission the pointer names is itself startable
local raw          -- raw['Nation'] etc.
local loaded

-- id lists per area, supplied by core/quests.lua once the index is loaded.
-- Needed only for fuzzy matching of the linear lines.
local area_ids = {}

function state.reset()
    bits = {quest = {current = {}, completed = {}},
            mission = {current = {}, completed = {}}}
    halves = {quest = {current = {}, completed = {}},
              mission = {current = {}, completed = {}}}
    spans = {quest = {current = {}, completed = {}},
             mission = {current = {}, completed = {}}}
    linear = {quest = {}, mission = {}}
    linear_idle = {quest = {}, mission = {}}
    raw = {}
    loaded = false
end
state.reset()

function state.is_loaded() return loaded end

--[[ The player's allegiance, from the Nation field of packet 0xFFFF.
     -> 'sandoria' | 'bastok' | 'windurst' | nil (not received yet)

     Needed because nation mission lines are mutually exclusive: a Windurst
     character can never start San d'Oria mission 1, so marking it is wrong. ]]
function state.nation()
    return NATION_AREA[raw['Nation']]
end

-- Mission areas that are gated on the player's allegiance.
state.NATION_AREAS = {sandoria = true, bastok = true, windurst = true}

--[[ Register the sorted DAT ids known for an area. Used only by the linear
     mission lines, whose packet value does not map 1:1 to a DAT id. ]]
function state.set_area_ids(cat, area, ids)
    local sorted = {}
    for _, id in ipairs(ids) do sorted[#sorted + 1] = id end
    table.sort(sorted)
    area_ids[cat .. '/' .. area] = sorted
end

-- ---------------------------------------------------------------------------
-- Bitfield decode
-- ---------------------------------------------------------------------------

local band, lshift
do
    local ok, b = pcall(require, 'bit')
    b = ok and b or rawget(_G, 'bit')
    if b then
        band, lshift = b.band, b.lshift
    else
        -- Pure-Lua fallback; never used under LuaJIT or Windower.
        band = function(a, c)
            local r, m = 0, 1
            while a > 0 and c > 0 do
                if a % 2 == 1 and c % 2 == 1 then r = r + m end
                a, c, m = math.floor(a / 2), math.floor(c / 2), m * 2
            end
            return r
        end
        lshift = function(a, n) return a * 2 ^ n end
    end
end

local to_set_cache = {}

--[[ Raw bitflags -> boolean set, 1-indexed (DAT id N lives at set[N+1]).
     Memoized on the raw value: the 0x056 burst re-sends identical blobs on
     every zone, so this is nearly free after the first zone-in. ]]
local function to_set(raw_data)
    if not raw_data then return {} end
    local cached = to_set_cache[raw_data]
    if cached then return cached end

    local set = {}
    if type(raw_data) == 'number' then
        for i = 0, 31 do
            if band(raw_data, lshift(1, i)) ~= 0 then set[i + 1] = true end
        end
    elseif type(raw_data) == 'string' then
        for i = 0, #raw_data * 8 - 1 do
            local byte = raw_data:byte(math.floor(i / 8) + 1)
            if byte and band(byte, lshift(1, i % 8)) ~= 0 then set[i + 1] = true end
        end
    else
        return {}
    end

    to_set_cache[raw_data] = set
    return set
end
state._to_set = to_set          -- exposed for tests

--[[ How many ids a blob actually spoke for. A 32-byte string covers 256; a bare
     number is a 32-bit field and covers 32. Recording the WIDTH rather than
     assuming 256 is what keeps the unknown honest: without it a 4-byte field
     would silently claim to answer for ids 32..255. ]]
local function bit_width(raw)
    if type(raw) == 'string' then return #raw * 8 end
    if type(raw) == 'number' then return 32 end
    return 0
end

--[[ Store one blob and rebuild the merged view.

     Merge, never replace. The halves of a split ladder (campaign 0x0030 and
     0x0038) arrive in one 0x056 burst with no guaranteed order, so
     `bits[...] = to_set(blob)` would drop whichever landed first.

     Rebuild into a fresh table rather than writing into the incoming set:
     to_set() memoizes on the raw value and hands back a shared table, so
     mutating it corrupts every later reader of the same blob.

     The offsets are disjoint fixed-width blocks, so no index is written twice
     and `pairs()` order cannot change the result. ]]
local function store_bits(cat, kind, area, offset, raw)
    local hk, sp = halves[cat][kind], spans[cat][kind]
    hk[area] = hk[area] or {}
    sp[area] = sp[area] or {}
    hk[area][offset] = to_set(raw)
    sp[area][offset] = bit_width(raw)

    local merged = {}
    for off, s in pairs(hk[area]) do
        for i, v in pairs(s) do merged[i + off] = v end
    end
    bits[cat][kind][area] = merged
end

-- ---------------------------------------------------------------------------
-- Packet handling
-- ---------------------------------------------------------------------------

--[[ Feed a packet parsed by libs/packets. Safe to call with anything; returns
     true only if the packet actually contributed state. ]]
function state.handle_packet(p)
    if type(p) ~= 'table' or p.Type == nil then return false end
    local touched = false

    local log = BITFIELD_LOGS[p.Type]
    if log then
        local blob = p['Quest Flags']
        if blob ~= nil then
            store_bits(log.cat, log.kind, log.area, log.offset or 0, blob)
            touched = true
        end
    end

    local fields = FIELD_LOGS[p.Type]
    if fields then
        for _, f in ipairs(fields) do
            local v = p[f.label]
            if v ~= nil then
                if f.mode == 'raw' then
                    raw[f.label] = v
                    touched = true
                elseif f.mode == 'bits' then
                    store_bits(f.cat, f.kind, f.area, f.offset or 0, v)
                    touched = true
                elseif f.mode == 'linear' and type(v) == 'number' then
                    --[[ TVR (0xFFFE) packs a flag in bit 31 of a signed int32:

                           bit 31 clear -> a mission is in progress, and the
                                           value is near its DAT id
                           bit 31 set   -> no active mission, and the value is
                                           near the next uncompleted mission

                         The distinction matters: with the flag set, the mission
                         the pointer lands on has not been started, so reporting
                         it as in_progress would be wrong. TVR alone needs this
                         because it lets you finish a mission without
                         auto-starting the next; the other linear lines always
                         keep a current mission. ]]
                    if f.tvr then
                        local no_active = v < 0
                        if no_active then v = v + 2147483648 end
                        linear_idle[f.cat][f.area] = no_active
                    end
                    linear[f.cat][f.area] = v
                    touched = true
                end
            end
        end

        -- Route the single nation-mission pointer to the player's own nation.
        if p.Type == 0xFFFF then
            local area = NATION_AREA[raw['Nation']]
            if area and linear.mission['nation'] then
                linear.mission[area] = linear.mission['nation']
            end
        end
    end

    if touched then loaded = true end
    return touched
end

-- ---------------------------------------------------------------------------
-- Queries
-- ---------------------------------------------------------------------------

--[[ An id past the end of the blob reads `false`, on purpose.

     `s[id + 1] == true` cannot tell "the game said no" from "the blob never
     reached this id", so both answer false. `spans` above records how wide each
     blob was, so returning nil instead is two lines of work. Don't: nil
     propagates. `prereq.marker_state` returns nil as soon as `status_of` does,
     and core/quests.lua reads `marker_state(...) ~= nil`
     as "did this draw", so nil here deletes the marker instead of blacking it
     out, and a marker may be moved but never deleted.

     The trade is one-sided anyway. Merged, the campaign ladder covers 0..511
     and every campaign index row is <= 499, so the check would never fire for
     the line it was written for. Its only live effect is quest/other
     1039..1049, the ten Mog Garden quests, which would go from a wrong green
     "!" to no marker at all. Those ids are probably reported in a log sub-type
     this addon does not decode; worth finding out before anything is deleted. ]]
function state.is_completed(cat, area, id)
    local s = bits[cat] and bits[cat].completed[area]
    if s then return s[id + 1] == true end
    return nil                                    -- no data for this area
end

function state.is_current(cat, area, id)
    local s = bits[cat] and bits[cat].current[area]
    if s then return s[id + 1] == true end
    return nil
end

--[[ Fuzzy resolve for the linear lines: the packet value does not map 1:1 to a
     DAT id, so take the largest known id <= the packet value. Everything
     strictly below that is treated as completed. It is an approximation, not a
     decode. ]]
--[[ The DAT id the linear pointer currently resolves to, or nil if this area
     is not driven by one. Exposed so prereq can tell "one step ahead" from
     "twenty steps ahead" -- in a strictly linear storyline everything past the
     pointer is unreachable, regardless of what metadata we happen to have. ]]
function state.linear_at(cat, area)
    if not (linear[cat] and linear[cat][area]) then return nil end
    return state._resolve_linear(cat, area)
end

local function resolve_linear(cat, area)
    local v = linear[cat] and linear[cat][area]
    if not v then return nil end
    local ids = area_ids[cat .. '/' .. area]
    if not ids or #ids == 0 then return v end
    local best = nil
    for _, id in ipairs(ids) do
        if id <= v then best = id else break end
    end
    return best or ids[1]
end
state._resolve_linear = resolve_linear

--[[ -> status, source
       status = 'done' | 'in_progress' | 'available' | nil (no data)
       source = 'exact'  decided by a bitfield  -- trustworthy
                'group'  a mutually exclusive sibling was completed instead
                         -- also exact; see EXCLUSIVE above
                'linear' decided by the fuzzy current-mission pointer

     The source matters. Bitfields are exact: a bit is set or it is not. The
     linear pointer is a guess -- fields.lua warns its value "doesn't correspond
     directly to DAT", so resolve_linear() picks the largest known id below it.
     That guess can land on a mission the player has not reached, which is why
     callers must be able to tell the two apart and sanity-check the guess
     against prerequisite data. See prereq.marker_state(). ]]
function state.status_of(cat, area, id)
    local done = state.is_completed(cat, area, id)
    local cur  = state.is_current(cat, area, id)

    if done ~= nil or cur ~= nil then
        if done then return 'done', 'exact' end
        --[[ You took the other branch. The sibling's completed bit is exact,
             so this is as trustworthy as `done` itself -- and it outranks a
             stale `current` bit, since finishing either branch ends the whole
             mission however it was started. ]]
        if completed_sibling(cat, area, id) then return 'done', 'group' end
        -- see the header: `current` means "ever accepted", so in-progress is
        -- current AND NOT completed.
        if cur then return 'in_progress', 'exact' end
        -- Nation and Zilart missions have an exact COMPLETED bitfield but only
        -- a fuzzy pointer for "which one am I on", so this branch is a guess
        -- even though the completed half was exact.
        if resolve_linear(cat, area) == id then return 'in_progress', 'linear' end

        --[[ 'available' is not an exact answer here.

             The completed bit is exact and clear, so "not finished" is certain.
             But `available` also claims you can take it now, and a completed
             bitfield cannot tell the mission you can start next from one thirty
             rungs down the same line. Only the pointer knows that, and it is a
             guess.

             No mission line has a `current` bitfield. Nation, Zilart, ToAU,
             WotG and Assault have an exact completed bitfield plus a fuzzy
             pointer; the rest have only the pointer. Say 'linear' whenever a
             pointer exists, so prereq.marker_state keeps its sanity check and
             the look-ahead (keyed on `src == 'linear'`, blocks anything past
             the pointer) runs on the lines that do have completed bits.

             Quests are fine: no quest area has a linear pointer, so
             resolve_linear returns nil and the answer stays exact. ]]
        if resolve_linear(cat, area) ~= nil then return 'available', 'linear' end
        return 'available', 'exact'
    end

    local at = resolve_linear(cat, area)
    if at == nil then return nil end
    if id < at then return 'done', 'linear' end
    if id == at then
        -- TVR with bit 31 set: the pointer is the NEXT uncompleted mission,
        -- which has not been started.
        if linear_idle[cat] and linear_idle[cat][area] then
            return 'available', 'linear'
        end
        return 'in_progress', 'linear'
    end
    return 'available', 'linear'
end

-- Diagnostics for //qm state
function state.dump(cat, area)
    local out = {current = {}, completed = {}, linear = linear[cat] and linear[cat][area]}
    for _, kind in ipairs({'current', 'completed'}) do
        local s = bits[cat] and bits[cat][kind][area]
        if s then
            for idx in pairs(s) do out[kind][#out[kind] + 1] = idx - 1 end
            table.sort(out[kind])
        end
    end
    return out
end

function state.areas_with_data()
    local seen = {}
    for cat, kinds in pairs(bits) do
        for kind, areas in pairs(kinds) do
            for area in pairs(areas) do seen[cat .. '/' .. area] = true end
        end
    end
    for cat, areas in pairs(linear) do
        for area in pairs(areas) do seen[cat .. '/' .. area] = true end
    end
    local l = {}
    for k in pairs(seen) do l[#l + 1] = k end
    table.sort(l)
    return l
end

state.BITFIELD_LOGS = BITFIELD_LOGS
state.FIELD_LOGS = FIELD_LOGS

return state
