--[[
tools/pipeline/resolve.lua -- name -> resource id, in bulk, over stdin.

    echo '{"kind":"ki","name":"Imperial missive"}' | luajit tools/pipeline/resolve.lua

JSONL in, JSONL out, one process for a whole build. A thin CLI over
tools/lib/normalize.lua so the BG Wiki pipeline and the mission builder can
never disagree about what a name means -- and so res/*.lua is only ever read by
Lua's own loadfile. A regex reader mis-parses en="\"Final Fantasy\"" and
silently loses key items 214-216, which is exactly what "A Question of Taste"
needs.

kinds:
    zone  -> res/zones.lua id, or the 'moghouse' sentinel
    npc   -> folded by_npc key(s), plus whether the name is a known ambiguous one
    item  -> res/items.lua id (en and enl, en winning)
    ki    -> res/key_items.lua id
    fame  -> one of the addon's nine fame regions, or null
    skill -> res/skills.lua id, with `en` and `category` echoed back
    srank -> res/synth_ranks.lua id (Amateur 0 .. Adept 8 .. Expert 10)

BUILD-TIME ONLY.
]]

local N = require('tools/lib/normalize')

-------------------------------------------------------------------------------
-- minimal JSON (flat objects of strings/numbers/booleans/null)
-------------------------------------------------------------------------------

local function jesc(s)
    return (tostring(s):gsub('[%c"\\]', function(c)
        local map = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                     ['\r'] = '\\r', ['\t'] = '\\t'}
        return map[c] or string.format('\\u%04x', c:byte())
    end))
end

local function jval(v)
    if v == nil then return 'null' end
    if v == true then return 'true' end
    if v == false then return 'false' end
    if type(v) == 'number' then return string.format('%d', v) end
    return '"' .. jesc(v) .. '"'
end

--[[ Only the shapes this tool receives, but it MUST honour backslash escapes.

     A pattern like '"([^"]*)"' stops at the first quote inside the value, and
     three of the key items this pipeline depends on have literal quotes in
     their names -- res/key_items.lua 214 is '"Final Fantasy"'. Truncate
     there and the key item resolves to nothing. ]]
local function jparse(line)
    local t, i, n = {}, 1, #line
    local function read_string()
        while i <= n and line:sub(i, i) ~= '"' do i = i + 1 end
        if i > n then return nil end
        i = i + 1
        local buf = {}
        while i <= n do
            local c = line:sub(i, i)
            if c == '\\' then
                local e = line:sub(i + 1, i + 1)
                local map = {n = '\n', r = '\r', t = '\t'}
                buf[#buf + 1] = map[e] or e
                i = i + 2
            elseif c == '"' then
                i = i + 1
                return table.concat(buf)
            else
                buf[#buf + 1] = c
                i = i + 1
            end
        end
        return table.concat(buf)
    end
    while true do
        local key = read_string()
        if not key then break end
        while i <= n and line:sub(i, i):match('[%s:]') do i = i + 1 end
        local c = line:sub(i, i)
        if c == '"' then
            t[key] = read_string()
        elseif line:sub(i, i + 3) == 'null' then
            i = i + 4
        else
            local num = line:match('^(%-?%d+)', i)
            if num then
                t[key] = tonumber(num)
                i = i + #num
            end
        end
    end
    return t
end

-------------------------------------------------------------------------------

local root = N.normalize_path(N.find_windower_root()) .. '/'
local zones     = N.load_table(root .. 'res/zones.lua')
local items     = N.load_table(root .. 'res/items.lua')
local key_items = N.load_table(root .. 'res/key_items.lua')
--[[ res/skills.lua carries every skill the game has -- 0-47 combat and magic,
     48-57 the Synthesis block -- and res/synth_ranks.lua the eleven craft rank
     names. Both are tiny and both are read the same way as everything else:
     by Lua's own loadfile, never by a regex.

     A missing one is FATAL, never a warning. These resolve gates, and a gate
     whose skill fails to resolve is a gate that quietly stops existing. ]]
local skills_res = N.load_table(root .. 'res/skills.lua')
local sranks_res = N.load_table(root .. 'res/synth_ranks.lua')
if not (zones and items and key_items and skills_res and sranks_res) then
    io.stderr:write('cannot load res tables from ' .. root .. '\n')
    os.exit(1)
end

--[[ Folded name -> id, for the two small tables. Built once, and DUPLICATE
     NAMES ARE REFUSED rather than resolved to whichever id pairs() reached
     first: res/skills.lua has real repeats among the combat entries (several
     ids share a display name), and a craft gate silently pointing at the wrong
     skill id would be a confidently wrong grey marker. ]]
local function name_index(tbl)
    local by, dupe = {}, {}
    for id, r in pairs(tbl) do
        if type(r) == 'table' and type(r.en) == 'string' then
            local f = N.fold(r.en)
            if by[f] ~= nil and by[f] ~= id then dupe[f] = true end
            if by[f] == nil then by[f] = id end
        end
    end
    for f in pairs(dupe) do by[f] = nil end
    return by
end
local skill_by_name = name_index(skills_res)
local srank_by_name = name_index(sranks_res)

local resolve_zone = N.make_zone_resolver(zones)
local item_by_name, ki_by_name = N.make_item_index(items, key_items)
local overrides = N.load_table(root .. 'addons/questmarks/data/npc_overrides.lua') or {}

--[[ Key-item names are NOT unique: ids 5, 6 and 7 are all "letter to the
     consuls". A name with more than one id is REJECTED rather than guessed --
     a wrong id is a silently wrong marker, a missing one is an honest nil. ]]
--[[ ... but a NAME shared by several consecutive ids is not an ambiguity at
     all. res/key_items.lua holds `traverser stone` at 1271-1276, `voidstone` at
     1539-1544, `Magian Mooglehood missive` at 1768-1772: one key item per unit
     you can carry, which is how the game represents holding more than one.
     "You hold a Traverser stone" is therefore true if you hold ANY of them --
     a disjunction, which the schema now has a word for. So every id is
     returned and the caller decides; only genuinely distinct items sharing a
     name would still be a problem, and none were found. ]]
local ki_dupes, ki_all = {}, {}
do
    local seen = {}
    for id, it in pairs(key_items) do
        if type(it) == 'table' and type(it.en) == 'string' then
            local f = N.fold(it.en)
            ki_all[f] = ki_all[f] or {}
            ki_all[f][#ki_all[f] + 1] = id
            if seen[f] and seen[f] ~= id then ki_dupes[f] = true end
            seen[f] = id
        end
    end
    for _, l in pairs(ki_all) do table.sort(l) end
end

local FAME = {
    ["san d'oria"] = 'sandoria', ['sandoria'] = 'sandoria',
    ['bastok'] = 'bastok', ['windurst'] = 'windurst', ['jeuno'] = 'jeuno',
    ['kazham'] = 'kazham', ['rabao'] = 'rabao_selbina',
    ['selbina'] = 'rabao_selbina', ['rabao_selbina'] = 'rabao_selbina',
    ['mhaura'] = 'mhaura', ['norg'] = 'norg',
    ['aht urhgan'] = 'aht_urhgan', ['aht_urhgan'] = 'aht_urhgan',
}

local function handle(req)
    local kind, name, area = req.kind, req.name, req.area
    local out = {kind = kind, name = name, area = area}

    if kind == 'zone' then
        local z = resolve_zone(name, area)
        out.id = (z ~= nil and z ~= false) and z or nil
        if z == 'moghouse' then out.id = nil; out.moghouse = true end

    elseif kind == 'npc' then
        local keys, k = N.normalize_npc(name, function(s) return resolve_zone(s, area) end,
                                        overrides)
        if k == 'npc' and #keys > 0 then
            out.keys = keys
            for _, kk in ipairs(keys) do
                if N.AMBIGUOUS_NPCS[kk] then out.ambiguous = true end
            end
            --[[ Was this a role, or just a name with an "or" in it?

                 Both come back as several keys and the caller cannot tell them
                 apart from the list alone, which matters: an override is a
                 CURATED expansion of a role ("Any Bastok Gate Guard" -> four
                 real guards), while the multi-option split is normalize_npc
                 cutting a free string on `or`, `and`, `&` and `/`. The second
                 is fine for deciding where to SCAN and useless for deciding who
                 GIVES a quest -- "Waoud/Raubahn, Aht Urhgan Whitegate - (J-10)"
                 splits into `waoud` and the fragment
                 `raubahn, aht urhgan whitegate -`, which is not an NPC.

                 Reported as a flag rather than re-derived by the caller so the
                 override table stays read in exactly one place. ]]
            local ov = overrides and overrides[N.fold(
                N.trim((tostring(name):gsub('%s+', ' '))))]
            if type(ov) == 'table' and type(ov.names) == 'table'
               and #ov.names > 1 then
                out.role = true
            end
        end
        out.npc_kind = k

    elseif kind == 'item' then
        out.id = select(1, N.resolve_entity(name, item_by_name))

    elseif kind == 'ki' then
        local id, used = N.resolve_entity(name, ki_by_name)
        local f = N.fold(used or name)
        if id and ki_dupes[f] then
            -- Not one answer, but every answer: hold ANY of them and you hold it.
            out.id = nil
            out.ids = ki_all[f]
            out.reason = 'one key item per unit carried; any id satisfies it'
        else
            out.id = id
        end

    elseif kind == 'fame' then
        local f = N.fold(name or '')
        out.id = FAME[f] or N.fame_region(name)

    elseif kind == 'skill' then
        local id = skill_by_name[N.fold(name or '')]
        out.id = id
        --[[ `category` comes back so the caller can REFUSE a craft gate that
             names a combat skill and vice versa. The two ride the same packet
             but not the same field -- craft has a Rank and combat does not --
             so mixing them up would silently compare a rank threshold against
             a skill level. ]]
        if id then
            local r = skills_res[id]
            out.en = type(r) == 'table' and r.en or nil
            out.category = type(r) == 'table' and r.category or nil
        end

    elseif kind == 'srank' then
        --[[ Amateur is id 0, so `out.id` must be allowed to be 0 and every
             caller must test `id ~= nil` rather than truthiness. Lua would be
             fine; the Python on the other side of this pipe would not. ]]
        local id = srank_by_name[N.fold(name or '')]
        out.id = id
        if id then
            local r = sranks_res[id]
            out.en = type(r) == 'table' and r.en or nil
        end
    end

    local parts = {}
    for _, key in ipairs({'kind', 'name', 'area', 'id', 'ambiguous',
                          'moghouse', 'npc_kind', 'role', 'reason', 'en',
                          'category'}) do
        if out[key] ~= nil then
            parts[#parts + 1] = ('"%s":%s'):format(key, jval(out[key]))
        end
    end
    if out.keys then
        local ks = {}
        for _, kk in ipairs(out.keys) do ks[#ks + 1] = jval(kk) end
        parts[#parts + 1] = '"keys":[' .. table.concat(ks, ',') .. ']'
    end
    if out.ids then
        local is = {}
        for _, ii in ipairs(out.ids) do is[#is + 1] = jval(ii) end
        parts[#parts + 1] = '"ids":[' .. table.concat(is, ',') .. ']'
    end
    return '{' .. table.concat(parts, ',') .. '}'
end

for line in io.lines() do
    if line:match('%S') then
        print(handle(jparse(line)))
    end
end
