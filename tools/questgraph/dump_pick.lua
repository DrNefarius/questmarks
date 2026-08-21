--[[
dump_pick.lua -- the searchable name index behind the editor's pickers.

    luajit tools/questgraph/dump_pick.lua > tools/questgraph/cache/pick.json

`resolve.lua` answers "does THIS name resolve?", one name at a time. A picker
needs the other direction -- "what names are there that start with 'vorp'" --
and that is the only thing missing.

**Built from `N.make_item_index`, the same function resolve.lua uses**, not from
a second walk over res/. If the picker were built any other way it would
cheerfully offer a name the build then could not resolve, which is worse than
having no picker: the human would have done the work and the marker would still
be missing.

The folded key is what actually decides resolution, so it is emitted beside the
display name. `dup` counts how many DISTINCT ids share that folded key, which is
the difference between two real cases the editor must not conflate:

    traverser stone   6 ids, consecutive     one key item per unit carried;
                                             holding ANY of them satisfies it
    Nodal Wand        3 ids, not consecutive genuinely different items sharing a
                                             name -- the resolver picks one over
                                             an unordered pairs(), so the winner
                                             is not stable between runs

Only the second is a problem, and the authored schema cannot express the fix
(it stores a NAME, never an id) -- that is what
tools/pipeline/resolve_overrides.json is for.

BUILD-TIME ONLY. Reads res/, writes nothing.
]]

local N = require('tools/lib/normalize')

local function esc(s)
    return (tostring(s):gsub('[%c"\\]', function(c)
        local map = {['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
                     ['\r'] = '\\r', ['\t'] = '\\t'}
        return map[c] or string.format('\\u%04x', c:byte())
    end))
end

local root = N.normalize_path(N.find_windower_root()) .. '/'
local zones     = N.load_table(root .. 'res/zones.lua')
local items     = N.load_table(root .. 'res/items.lua')
local key_items = N.load_table(root .. 'res/key_items.lua')
if not (zones and items and key_items) then
    io.stderr:write('cannot load res tables from ' .. root .. '\n')
    os.exit(1)
end

local item_by_name, ki_by_name = N.make_item_index(items, key_items)

--[[ How many distinct ids answer to one folded name, and which. Computed over
     the RAW tables rather than over the index, because the index is
     first-wins and would report every name as unique by construction. ]]
local function dupes(tbl, field_list)
    local by = {}
    for id, it in pairs(tbl) do
        if type(it) == 'table' then
            for _, f in ipairs(field_list) do
                if type(it[f]) == 'string' and it[f] ~= '' then
                    local k = N.fold(it[f])
                    by[k] = by[k] or {}
                    local seen = false
                    for _, x in ipairs(by[k]) do if x == id then seen = true end end
                    if not seen then by[k][#by[k] + 1] = id end
                end
            end
        end
    end
    for _, l in pairs(by) do table.sort(l) end
    return by
end

local item_dupes = dupes(items, {'en', 'enl'})
local ki_dupes   = dupes(key_items, {'en', 'enl'})

--[[ A display name for a folded key. The index is folded (lowercased,
     whitespace-collapsed) and showing a player "vorpal sword" when the game
     says "Vorpal Sword" is a small lie that erodes trust in every other field.
     Prefer `en`, fall back to `enl`, fall back to the folded key. ]]
local function display(tbl, id, folded)
    local it = tbl[id]
    if type(it) == 'table' then
        if type(it.en) == 'string' and N.fold(it.en) == folded then return it.en end
        if type(it.enl) == 'string' and N.fold(it.enl) == folded then return it.enl end
        if type(it.en) == 'string' then return it.en end
    end
    return folded
end

local out = {}
local function emit(kind, index, raw, dup)
    local keys = {}
    for k in pairs(index) do keys[#keys + 1] = k end
    table.sort(keys)
    local rows = {}
    for _, k in ipairs(keys) do
        local id = index[k]
        local ids = dup[k]
        local parts = {
            '"n":"' .. esc(display(raw, id, k)) .. '"',
            '"f":"' .. esc(k) .. '"',
            '"id":' .. string.format('%d', id),
        }
        if ids and #ids > 1 then
            local s = {}
            for _, x in ipairs(ids) do s[#s + 1] = string.format('%d', x) end
            parts[#parts + 1] = '"ids":[' .. table.concat(s, ',') .. ']'

            --[[ What actually distinguishes them, not whether the ids happen
                 to be adjacent.

                 Consecutiveness looks like the discriminator and is not:
                     traverser stone  ki   1271-1276  consecutive
                     Nodal Wand       item 21067-9    consecutive
                 The first is one key item per unit carried -- hold any and you
                 hold it, a disjunction validate.py already spreads into an
                 alternatives list. The second is three DIFFERENT weapons that
                 share a name, separated by damage 129/131/133 (Lexeme Blade
                 likewise, 226/228/231). Binding either arbitrarily is a
                 silently wrong marker, and only one of them is safe to OR.

                 So the attributes are compared and the ones that VARY are
                 emitted. An empty list means the ids are indistinguishable in
                 res -- the "one per unit" shape. A non-empty list is a real
                 ambiguity, and the editor shows it and points at
                 tools/pipeline/resolve_overrides.json, because the authored
                 schema stores a name and cannot express which one. ]]
            local varies = {}
            for _, attr in ipairs({'level', 'damage', 'delay', 'defense',
                                   'slots', 'jobs', 'races', 'shield_size'}) do
                local first, differs = nil, false
                for i, x in ipairs(ids) do
                    local it = raw[x]
                    local v = type(it) == 'table' and it[attr] or nil
                    if i == 1 then first = v
                    elseif tostring(v) ~= tostring(first) then differs = true end
                end
                if differs then
                    local vs = {}
                    for _, x in ipairs(ids) do
                        local it = raw[x]
                        vs[#vs + 1] = '"' .. esc(tostring(
                            (type(it) == 'table' and it[attr]) or '?')) .. '"'
                    end
                    varies[#varies + 1] = ('"%s":[%s]')
                        :format(esc(attr), table.concat(vs, ','))
                end
            end
            parts[#parts + 1] = '"differs":{' .. table.concat(varies, ',') .. '}'
        end
        rows[#rows + 1] = '{' .. table.concat(parts, ',') .. '}'
    end
    out[#out + 1] = '"' .. kind .. '":[' .. table.concat(rows, ',') .. ']'
end

emit('item', item_by_name, items, item_dupes)
emit('ki', ki_by_name, key_items, ki_dupes)

--[[ Zones resolve through make_zone_resolver rather than a name index (it
     handles the article the wiki drops -- `Eldieme Necropolis` is really
     `The Eldieme Necropolis`), so they are emitted from the raw table and the
     editor still round-trips every pick through the real resolver. ]]
do
    local rows = {}
    local ids = {}
    for id in pairs(zones) do
        if type(id) == 'number' then ids[#ids + 1] = id end
    end
    table.sort(ids)
    for _, id in ipairs(ids) do
        local z = zones[id]
        if type(z) == 'table' and type(z.en) == 'string' and z.en ~= '' then
            rows[#rows + 1] = ('{"n":"%s","f":"%s","id":%d}')
                :format(esc(z.en), esc(N.fold(z.en)), id)
        end
    end
    out[#out + 1] = '"zone":[' .. table.concat(rows, ',') .. ']'
end

io.write('{' .. table.concat(out, ',') .. '}\n')
