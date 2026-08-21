--[[
dump_index.lua -- data/quest_index.lua + data/mission_index.lua -> JSON on stdout.

    luajit tools/questgraph/dump_index.lua > build/reports/index.json

The questgraph editor needs the SHIPPED index, not just the authored layer,
for two things the authored layer cannot answer:

  * the merged half of every row -- identity, fame, repeatable, prerequisites,
    quest-level requirements. `build/authored/` never held those, so "what the
    addon actually loads" is only visible here.
  * the `prev` DAG, which spans quests AND missions. `gates.prev` in the
    authored record is a list of wiki TITLES; only the index has them resolved
    to {cat, area, id} triples, and only the index has missions at all.

Read with Lua's own `loadfile`, never a Python regex. A regex reader
mis-parses `en="\"Final Fantasy\""` and loses key items 214-216, which is
the same reason tools/lib/normalize.lua says never to read res/*.lua that way.

BUILD-TIME ONLY. Reads two generated files and writes nothing.
]]

local ESCAPES = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function esc(s)
    s = s:gsub('[%c"\\]', function(c)
        return ESCAPES[c] or string.format('\\u%04x', c:byte())
    end)
    return s
end

local out = {}
local function w(s) out[#out + 1] = s end

--[[ Arrays and objects are distinguished by whether key 1 exists. Every table
     in these two files is either a dense array or a string-keyed record, so
     that test is exact here -- it is NOT a general-purpose rule. ]]
local function encode(v)
    local t = type(v)
    if v == nil then w('null')
    elseif t == 'boolean' then w(v and 'true' or 'false')
    elseif t == 'number' then
        w(v == math.floor(v) and string.format('%d', v) or tostring(v))
    elseif t == 'string' then w('"' .. esc(v) .. '"')
    elseif t == 'table' then
        if v[1] ~= nil or next(v) == nil then
            w('[')
            for i = 1, #v do
                if i > 1 then w(',') end
                encode(v[i])
            end
            w(']')
        else
            -- Sorted keys: two dumps of identical data must be byte-identical,
            -- the same rule build_index.lua learned when pairs() made two
            -- builds of the same data differ by ~1500 lines.
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = k end
            table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
            w('{')
            for i, k in ipairs(keys) do
                if i > 1 then w(',') end
                w('"' .. esc(tostring(k)) .. '":')
                encode(v[k])
            end
            w('}')
        end
    else
        w('null')
    end
end

local function load_table(path)
    local f = loadfile(path)
    if not f then return nil end
    local ok, t = pcall(f)
    return ok and t or nil
end

local root = (arg and arg[1]) or '.'
local qi = load_table(root .. '/data/quest_index.lua')
local mi = load_table(root .. '/data/mission_index.lua')

if not qi then
    io.stderr:write('cannot load data/quest_index.lua\n')
    os.exit(1)
end

--[[ Only the parts the editor reads. `by_npc` is 1946 keys of back-references
     into `quests` and would triple the payload for something the editor
     derives itself from each record's own steps. ]]
encode({
    quests   = qi.quests,
    by_zone  = qi.by_zone,
    meta     = qi.meta,
    missions = mi and mi.quests or {},
    mission_meta = mi and mi.meta or {},
})

io.write(table.concat(out))
io.write('\n')
