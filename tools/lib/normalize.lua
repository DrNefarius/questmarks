--[[
tools/lib/normalize.lua -- what a NAME means.

Every rule for turning a BG-Wiki surface string into something the runtime can
match: NPC names into `by_npc` keys, zone names into res/zones.lua ids, item and
key-item names into resource ids, fame strings into the addon's nine regions.

Extracted verbatim from tools/build_index.lua so there is exactly ONE
implementation and two callers -- build_index.lua (missions) and
tools/pipeline/resolve.lua (quests, from the BG Wiki cache). Do not add a
second implementation in another language. Do not read res/*.lua with a regex
either: a regex mis-parses `en="\"Final Fantasy\""` and loses key items
214-216. Lua's own loadfile is the only correct reader.

BUILD-TIME ONLY. Nothing shipped at runtime requires this file.
]]

local M = {}

-------------------------------------------------------------------------------
-- small helpers
-------------------------------------------------------------------------------

local function trim(s)
    return (tostring(s):gsub('^%s+', ''):gsub('%s+$', ''))
end
M.trim = trim

-- The canonical lookup-key form: collapse whitespace, lowercase.
-- FFXI entity names are ASCII (apostrophes aside), so no accent folding needed.
local function fold(s)
    if s == nil then return nil end
    s = tostring(s):gsub('%s+', ' ')
    return trim(s):lower()
end
M.fold = fold

local function set(list)
    local t = {}
    for _, v in ipairs(list) do t[v] = true end
    return t
end
M.set = set

local function sorted_keys(t)
    local ks = {}
    for k in pairs(t) do ks[#ks + 1] = k end
    table.sort(ks, function(a, b)
        if type(a) == type(b) then return a < b end
        return tostring(a) < tostring(b)
    end)
    return ks
end
M.sorted_keys = sorted_keys

local function count(t)
    local n = 0
    for _ in pairs(t) do n = n + 1 end
    return n
end
M.count = count

local function file_exists(p)
    local f = io.open(p, 'r')
    if f then f:close() return true end
    return false
end
M.file_exists = file_exists

local function load_table(path)
    if not file_exists(path) then return nil end
    local chunk, err = loadfile(path)
    if not chunk then return nil, err end
    local ok, res = pcall(chunk)
    if not ok then return nil, res end
    return res
end
M.load_table = load_table

-------------------------------------------------------------------------------
-- Lua emitter primitives (shared by every generator in tools/)
-------------------------------------------------------------------------------

local function lua_str(s)
    s = tostring(s)
    s = s:gsub('\\', '\\\\'):gsub("'", "\\'"):gsub('\n', '\\n'):gsub('\r', '\\r')
    return "'" .. s .. "'"
end
M.lua_str = lua_str

local function lua_val(v)
    if v == nil then return 'nil' end
    if v == true then return 'true' end
    if v == false then return 'false' end
    if type(v) == 'number' then
        if v == math.floor(v) then return string.format('%d', v) end
        return tostring(v)
    end
    return lua_str(v)
end
M.lua_val = lua_val

-------------------------------------------------------------------------------
-- paths
-------------------------------------------------------------------------------

-- Collapse '.' and '..' segments so reported paths are readable.
local function normalize_path(p)
    p = p:gsub('\\', '/'):gsub('//+', '/')
    local parts = {}
    for seg in p:gmatch('[^/]+') do
        if seg == '..' and #parts > 0 and parts[#parts] ~= '..'
                       and not parts[#parts]:find(':$') then
            table.remove(parts)
        elseif seg ~= '.' then
            parts[#parts + 1] = seg
        end
    end
    local out = table.concat(parts, '/')
    if p:sub(1, 1) == '/' then out = '/' .. out end
    return out
end
M.normalize_path = normalize_path

local function cwd()
    local p = io.popen and io.popen('cd')          -- Windows `cd` prints the cwd
    if not p then return nil end
    local d = p:read('*l')
    p:close()
    return d and normalize_path(d) or nil
end

--[[ `standalone` = "no game client", which decides how res tables are loaded.
     It is NOT the same as "run from the command line". ]]
function M.standalone()
    return rawget(_G, 'windower') == nil
end

--[[ This file lives at addons/questmarks/tools/lib/, so the Windower root is
     four levels up -- one deeper than build_index.lua's own three. Count them
     off the path rather than trusting the sentence: lib -> tools -> questmarks
     -> addons -> Windower.

     There used to be a hardcoded 'C:/Program Files (x86)/Windower' below the
     check, and it was hiding a real fault: the walk went up three, landed on
     `addons`, failed the check and returned the literal, which is correct on
     exactly one machine. build_index.lua and dump_res.lua derive
     `root .. 'addons/questmarks/'` from this answer, so a wrong root does not
     merely fail to find res/, it points the build at a different tree.

     No fallback now. If the walk ever lands somewhere without res/, say so and
     stop, which is what resolve.lua already does when the tables will not
     load. A wrong answer here is worse than no answer. ]]
function M.find_windower_root(explicit)
    if explicit then return normalize_path(explicit) end
    if not M.standalone() then
        return normalize_path(windower.windower_path)
    end

    -- debug.getinfo gives whatever path was typed, so it may be relative --
    -- anchor it to the cwd before walking up, or the result depends on where
    -- the script happened to be invoked from.
    local here = debug.getinfo(1, 'S').source:sub(2):gsub('\\', '/')
    if not here:match('^%a:/') and not here:match('^/') then
        local c = cwd()
        if c then here = c .. '/' .. here end
    end
    local dir = here:match('^(.*)/[^/]*$') or '.'
    local root = normalize_path(dir .. '/../../../..')
    if file_exists(root .. '/res/zones.lua') then return root end

    io.stderr:write(
        'cannot find the Windower root.\n' ..
        'Derived ' .. root .. ' from this file, but ' .. root ..
        '/res/zones.lua is not there.\n' ..
        'This addon is expected at <windower>/addons/questmarks. ' ..
        'build_index.lua and\ndump_res.lua also accept --root <windower dir>.\n')
    os.exit(1)
end

-------------------------------------------------------------------------------
-- normalizer: a giver string -> lookup keys
-------------------------------------------------------------------------------

-- Clickable objects / placeholders that are not name-matchable NPCs.
local OBJECT_DENY = set{
    'full moon fountain', 'blank spot', 'blank target', 'glowing hearth',
    '???', 'none',
}
M.OBJECT_DENY = OBJECT_DENY

-- Trailing ", X" qualifiers that are zone hints rather than part of the name.
local ZONE_QUALIFIER_HINTS = set{'abyssea', 'al zahbi', 'riverne', 'aht urhgan'}
M.ZONE_QUALIFIER_HINTS = ZONE_QUALIFIER_HINTS

--[[ NPC names shared by many entities across the world. For these a resolved
     zone is MANDATORY: an unresolved zone means "match anywhere", which for a
     name like "Moogle" marks hundreds of NPCs. Dropping the entry is the
     lesser error -- one missing marker beats a wrong marker on every Moogle in
     Vana'diel. Gate guards are exempt: their names ARE unique, and they use
     the explicit any-zone sentinel rather than falling through unresolved. ]]
local AMBIGUOUS_NPCS = set{
    'moogle', 'nomad moogle', 'pilgrim moogle', 'chocobo', '???',
    'voidwatch officer', 'voidwatch purveyor', 'dominion sergeant',
    'guard', 'gate guard', 'npc',
}
M.AMBIGUOUS_NPCS = AMBIGUOUS_NPCS

--[[ -> keys (array), kind, zone_hint
     kind is one of: 'npc' | 'generic' | 'object' | 'zone_trigger' | 'none' ]]
local function normalize_npc(raw, resolve_zone, overrides)
    if raw == nil then return {}, 'none', nil end

    local s = trim(tostring(raw):gsub('%s+', ' '))
    if s == '' then return {}, 'none', nil end

    -- hand-curated overrides win outright, before any parsing
    local ov = overrides and overrides[fold(s)]
    if ov then
        if ov.drop then return {}, ov.kind or 'generic', nil end
        local keys = {}
        for _, n in ipairs(ov.names or {}) do keys[#keys + 1] = fold(n) end
        return keys, 'npc', ov.zone
    end

    -- repair extractor damage BEFORE anything else parses the string
    s = s:gsub(',,', ',')
    s = s:gsub('[\\,%(%[/]+$', '')
    s = s:gsub('%[([^%]]*)%]', '%1')          -- Caf[e] -> Cafe
    s = trim(s)
    if s == '' then return {}, 'none', nil end

    local low = s:lower()
    if OBJECT_DENY[low] then return {}, 'object', nil end
    if low == 'n/a' or low == '???' then return {}, 'none', nil end
    if not s:find('%a') then return {}, 'none', nil end

    --[[ Doors ARE real, markable entities. The client names them "Door:Name"
         with no space; BG Wiki writes "Door: Name" with one. Normalise to the
         client's form so the key matches -- confirmed against a live NPC dump
         showing Door:Manustery, Door:House, Door:Nchaa's Good Goods. ]]
    local door = s:match('^[Dd]oor%s*:%s*(.+)$')
    if door then
        door = trim(door)
        if door == '' then return {}, 'object', nil end
        return {fold('Door:' .. door)}, 'npc', nil
    end

    s = trim((s:gsub('^[Tt]rade%s+', '')))

    -- generics we cannot resolve to a concrete entity name
    if s:lower():find('^any%s') or s:lower():find('^any of the following') then
        return {}, 'generic', nil
    end

    -- multi-option: split and recurse
    do
        local parts, found = {}, false
        local work = s
        work = work:gsub('%s+[Oo][Rr]%s+', '\1')
        work = work:gsub('%s+[Aa][Nn][Dd]%s+', '\1')
        work = work:gsub('%s*&%s*', '\1')
        work = work:gsub('%s*/%s*', '\1')
        for part in work:gmatch('[^\1]+') do
            part = trim(part)
            if part ~= '' then parts[#parts + 1] = part end
        end
        if #parts > 1 then
            local keys, hint = {}, nil
            for _, p in ipairs(parts) do
                local k, kind, h = normalize_npc(p, resolve_zone, overrides)
                if kind == 'npc' then
                    for _, kk in ipairs(k) do keys[#keys + 1] = kk end
                    found = true
                end
                hint = hint or h
            end
            if found then return keys, 'npc', hint end
            return {}, 'none', nil
        end
    end

    local zone_hint = nil

    -- trailing ", <zone>" qualifier
    local head, tail = s:match('^(.*),%s*([^,]+)$')
    if head and tail then
        head, tail = trim(head), trim(tail)
        if head ~= '' and tail ~= '' then
            local zid = resolve_zone(tail)
            if zid ~= nil or ZONE_QUALIFIER_HINTS[tail:lower()] then
                zone_hint = zid
                s = head
            end
        end
    end

    -- parentheticals
    local keys_src = {}
    local base_s = s:match('^(.-)%s*%(%s*[Ss]%s*%)%s*$')
    local base_a = s:match('^(.-)%s*%(%s*[Aa]%s*%)%s*$')
    if base_s then
        keys_src = {base_s .. ' [S]', base_s}   -- BG "(S)" == in-game "[S]"
    elseif base_a then
        keys_src = {base_a}                     -- Abyssea NPCs are named plainly
    else
        local cut = s:find('%(')
        if cut then s = trim(s:sub(1, cut - 1)) end
        keys_src = {s}
    end

    local cleaned = {}
    for _, k in ipairs(keys_src) do
        k = trim(k)
        if k ~= '' then cleaned[#cleaned + 1] = k end
    end
    if #cleaned == 0 then return {}, 'none', nil end

    --[[ A "name" that is really a zone means a zone-entry-triggered quest.
         Check EVERY candidate key, not just the last: a "(S)" name expands to
         {"Name [S]", "Name"} and only the FIRST form resolves as a zone. Test
         the last alone and "La Vaule (S)" passes as an NPC. ]]
    for _, k in ipairs(cleaned) do
        if resolve_zone(k) ~= nil then return {}, 'zone_trigger', nil end
        if OBJECT_DENY[fold(k)] then return {}, 'object', nil end
    end

    local keys, seen = {}, {}
    for _, k in ipairs(cleaned) do
        local fk = fold(k)
        if fk and fk ~= '' and not seen[fk] then
            seen[fk] = true
            keys[#keys + 1] = fk
        end
    end
    if #keys == 0 then return {}, 'none', nil end
    return keys, 'npc', zone_hint
end
M.normalize_npc = normalize_npc

-------------------------------------------------------------------------------
-- zone resolver
-------------------------------------------------------------------------------

local ZONE_ALIASES = {
    ['konschtat']            = 'Konschtat Highlands',
    ['attohwa']              = 'Attohwa Chasm',
    ['misareaux']            = 'Misareaux Coast',
    ['la theine']            = 'La Theine Plateau',
    ['tahrongi']             = 'Tahrongi Canyon',
    ['vunkerl']              = 'Vunkerl Inlet [S]',
    ['grauberg']             = 'Grauberg [S]',
    ['uleguerand']           = 'Uleguerand Range',
    ['aht urghan whitegate'] = 'Aht Urhgan Whitegate',   -- typo in source data
    ['mog gardens']          = 'Mog Garden',
}
M.ZONE_ALIASES = ZONE_ALIASES

-- Deliberately unresolvable: ambiguous, or not a zone at all. Explicit so they
-- read as intentional rather than as silent misses.
--[[ A Mog House is not a zone in res/zones.lua -- the client reports the
     surrounding city zone and flags `mog_house` in get_info() instead. These
     map to the sentinel 'moghouse', which the runtime checks against that
     flag. Without it "Moogle, Mog House" is an unresolved zone and matches
     every Moogle in the game. ]]
local ZONE_MOGHOUSE = set{
    'mog house', 'home nation mog house', 'mog house (any nation)',
    'your mog house', 'moghouse',
}
M.ZONE_MOGHOUSE = ZONE_MOGHOUSE

local ZONE_NULL = set{
    'altepa', 'any starter city', 'abyssea', 'n/a', 'various', 'any city',
}
M.ZONE_NULL = ZONE_NULL

--[[ The nine Abyssea zones share their bare names with real Vana'diel zones,
     and ZONE_ALIASES resolves the bare form to the REAL one -- 'attohwa' is
     Attohwa Chasm, not Abyssea - Attohwa. That is right for a plain giver
     string and wrong for a step inside an Abyssea walkthrough, so the caller
     passes area='abyssea' and gets the 'Abyssea - ' form tried first.
     Deliberately area-scoped: applying it globally would move real Attohwa
     Chasm markers into Abyssea. ]]
local ABYSSEA_BARE = set{
    'attohwa', 'misareaux', 'la theine', 'tahrongi', 'konschtat',
    'vunkerl', 'grauberg', 'uleguerand', 'altepa',
}
M.ABYSSEA_BARE = ABYSSEA_BARE

function M.make_zone_resolver(zones)
    local exact, loose = {}, {}
    for zid, z in pairs(zones) do
        local name = type(z) == 'table' and z.en or z
        if type(name) == 'string' and name ~= '' and name ~= 'unknown' then
            local f = fold(name)
            if exact[f] == nil then exact[f] = zid end
            local lf = f:gsub('[^%a%d ]', '')
            if loose[lf] == nil then loose[lf] = zid end
        end
    end

    --[[ `area` is optional and is only consulted for the Abyssea case above.
         Callers that do not pass it are unaffected. ]]
    return function(raw, area)
        if raw == nil then return nil end
        local s = trim(tostring(raw):gsub('%s+', ' '))
        if s == '' then return nil end
        if area == 'abyssea' and ABYSSEA_BARE[fold(s)] then
            local ab = exact[fold('Abyssea - ' .. s)]
            if ab then return ab end
        end
        if ZONE_MOGHOUSE[fold(s)] then return 'moghouse' end
        if ZONE_NULL[fold(s)] then return nil end

        -- BG Wiki writes "(S)"; res/zones.lua writes "[S]"
        local s2 = s:gsub('%(%s*[Ss]%s*%)%s*$', '[S]')
        s2 = trim(s2)
        if not s2:find('%[S%]$') then
            local cut = s2:find('%(')
            if cut then s2 = trim(s2:sub(1, cut - 1)) end
        end
        s2 = trim((s2:gsub('%)+$', '')))

        for _, cand in ipairs({s, s2}) do
            local f = fold(cand)
            if exact[f] then return exact[f] end
            local lf = f:gsub('[^%a%d ]', '')
            if loose[lf] then return loose[lf] end
            local alias = ZONE_ALIASES[f]
            if alias and exact[fold(alias)] then return exact[fold(alias)] end
        end
        return nil
    end
end

-------------------------------------------------------------------------------
-- fame region mapping
--
-- The `fame` field is polluted: only ~9 of its distinct values are real FFXI
-- fame regions. The rest are expansion/category names that leaked in during
-- scraping (Abyssea 188, Other 89, Wings of the Goddess 56, ...), plus BG
-- Wiki's own single-letter shorthands and Abyssea zone codes.
-- Anything mapping to false is NOT a fame gate and must not block a marker.
-------------------------------------------------------------------------------

local FAME_REGIONS = {
    ["san d'oria"]              = 'sandoria',
    ['bastok']                  = 'bastok',
    ['windurst']                = 'windurst',
    ['jeuno']                   = 'jeuno',
    ['kazham']                  = 'kazham',
    -- Rabao and Selbina are one fame area (single checker, Waylea in Rabao).
    -- Mhaura is NOT part of it -- the linkage rules group Mhaura with Kazham.
    ['rabao']                   = 'rabao_selbina',
    ['selbina']                 = 'rabao_selbina',
    ['mhaura']                  = 'mhaura',
    ['norg']                    = 'norg',
    ['aht urhgan']              = 'aht_urhgan',
    ['treasures of aht urhgan'] = 'aht_urhgan',
    -- not fame systems:
    ['abyssea']              = false, ['other']             = false,
    ['outlands']             = false, ['crystal war']       = false,
    ['wings of the goddess'] = false, ['vision of abyssia'] = false,
    ['n/a']                  = false, ['adoulin']           = false,
    ['seekers of adoulin']   = false, ['abyssea - uleguerand'] = false,
}
M.FAME_REGIONS = FAME_REGIONS

--[[ BG Wiki's raw `Fame=` field. 44 distinct values across the cache: the long
     names above, single-letter shorthands, and nine Abyssea zone codes. Kept
     SEPARATE from FAME_REGIONS so the mission path in build_index.lua never
     sees it -- only the wiki pipeline consults this. ]]
local FAME_RAW_ALIASES = {
    ['s'] = "san d'oria", ['b'] = 'bastok',  ['w'] = 'windurst',
    ['j'] = 'jeuno',      ['k'] = 'kazham',  ['r'] = 'rabao',
    ['n'] = 'norg',       ['au'] = 'aht urhgan',
    ['o'] = 'other',      ['ot'] = 'other',  ['a'] = 'abyssea',
    ['none'] = 'n/a',     ['?'] = 'n/a',     ['1'] = 'n/a',
    -- Abyssea zone codes. None of these is a fame system.
    ['agra'] = 'abyssea', ['aalt'] = 'abyssea', ['aule'] = 'abyssea',
    ['aatt'] = 'abyssea', ['amis'] = 'abyssea', ['avun'] = 'abyssea',
    ['alth'] = 'abyssea', ['akon'] = 'abyssea', ['atah'] = 'abyssea',
}
M.FAME_RAW_ALIASES = FAME_RAW_ALIASES

--[[ -> region string | nil.  nil means "not a fame gate", which is NOT the
     same as "we failed to read it": callers keep the raw string alongside so
     an audit can prove the nil was a decision. ]]
function M.fame_region(raw)
    if raw == nil then return nil end
    local f = fold(raw)
    if f == '' then return nil end
    f = FAME_RAW_ALIASES[f] or f
    local r = FAME_REGIONS[f]
    if r == false then return nil end
    return r
end

-------------------------------------------------------------------------------
-- item / key-item name indexes
-------------------------------------------------------------------------------

--[[ Index BOTH `en` and `enl`.

     res/items.lua `en` is the ABBREVIATED in-game name ("3Leaf Mandra Bud");
     `enl` is the full log name ("three-leaf mandragora bud"). BG Wiki writes
     requirements using the log name, so indexing `en` alone misses a large
     fraction of them -- "Two-Leaf Mandragora Bud" and "Revival Tree Root"
     both resolve only via `enl`, while "Zinc Ore" resolves only via
     `en`. Neither field is a superset, so both are needed. `en` wins collisions
     since it is the name the client actually reports for inventory items.

     The two-pass order over `items` is load-bearing: every `en` is registered
     before any `enl`, so an `enl` can never shadow an `en`. ]]
function M.make_item_index(items, key_items)
    local item_by_name, ki_by_name = {}, {}
    local function add(tbl, name, id)
        if type(name) ~= 'string' or name == '' then return end
        local f = fold(name)
        if f ~= '' and tbl[f] == nil then tbl[f] = id end
    end
    for id, it in pairs(items) do
        if type(it) == 'table' then add(item_by_name, it.en, id) end
    end
    for id, it in pairs(items) do
        if type(it) == 'table' then add(item_by_name, it.enl, id) end
    end
    --[[ THIRD pass: `enl` with its measure phrase stripped.

         The log name is written as the game would say it in a sentence -- "a
         vial of Quadav mage blood", "a square of linen cloth", "a head of La
         Theine cabbage" -- while BG Wiki writes the bare noun ("Quadav Mage
         Blood"). Neither `en` ("Qdv. Mage Blood") nor `enl` matches that, so
         without this pass a large family of perfectly ordinary trade items
         resolves to nothing.

         Runs LAST and still only fills empty keys, so it can never shadow a
         real `en` or `enl`. ]]
    for id, it in pairs(items) do
        if type(it) == 'table' and type(it.enl) == 'string' then
            local tail = it.enl:match('^.-%s+of%s+(.+)$')
            if tail then add(item_by_name, tail, id) end
            local bare = it.enl:match('^[Aa]n?%s+(.+)$')
                      or it.enl:match('^[Tt]he%s+(.+)$')
            if bare then
                add(item_by_name, bare, id)
                local btail = bare:match('^.-%s+of%s+(.+)$')
                if btail then add(item_by_name, btail, id) end
            end
        end
    end
    for id, it in pairs(key_items) do
        if type(it) == 'table' then
            add(ki_by_name, it.en, id)
            add(ki_by_name, it.enl, id)
        end
    end
    return item_by_name, ki_by_name
end

-- Repairs for the ~8% of wiki key-item names that miss on a raw lookup. Each
-- targets an artefact actually seen in the cache. Deliberately NO fuzzy
-- matching: a wrong resource id is a silently wrong marker, a missing one is an
-- honest nil. Returns id, repaired_name.
function M.resolve_entity(name, tbl)
    if type(name) ~= 'string' then return nil end
    local cands = {name}
    local function push(s)
        s = trim(s or '')
        if s ~= '' then cands[#cands + 1] = s end
    end
    push((name:gsub('%s*%(%d+%)%s*$', '')))          -- "Large memory fragment (3)"
    push((name:gsub('%s+[xX]%s*%d+%s*$', '')))       -- "Zinc Ore x4"
    push((name:gsub('_', ' ')))                      -- "Breath_of_dawn"
    push((name:gsub("^'+", ''):gsub("'+$", '')))     -- stray wiki emphasis
    push((name:gsub('^"', ''):gsub('"$', '')))       -- "Rhapsody in Umber"
    push((name:gsub('%s*%(Key Item%)%s*$', '')))
    for _, c in ipairs(cands) do
        local id = tbl[fold(c)]
        if id then return id, c end
    end
    return nil
end

return M
