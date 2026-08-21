--[[
tools/pipeline/dump_res.lua -- freeze the game's own name tables.

    luajit tools/pipeline/dump_res.lua [--names] [--res] [--root <windower dir>]

Two outputs, both derived from data the CLIENT owns rather than from the wiki:

  data/dat_names.lua   id -> name for every quest and mission, read out of the
                       client's DATs (0xD99A-0xD9BE). SHIPPED and frozen: only
                       new game content would need it regenerated.

  build/res.json       the same maps plus res/zones.lua, for the Python stages
                       of the BG Wiki pipeline. NOT shipped, regenerable.

Why dat_names.lua has to exist at all, and why it is worth its own file:

`names[cat][area][id]` is the ONLY input to state.set_area_ids, which is the
ONLY input to resolve_linear -- the function that turns a linear storyline's
"current mission" pointer into a DAT id by taking the largest known id <= the
pointer. Any id missing from that ladder drags resolve_linear's answer
downward, and prereq.marker_state then judges "later in a linear storyline"
against a position that does not exist. So the ladder must hold every id the
client knows, not just the quests with wiki coverage. Do not source it from the
generated index: that only records a quest whose NPC matched.

Reading res/*.lua with anything other than Lua's own loadfile is a mistake: a
regex reader mis-parses en="\"Final Fantasy\"" and silently loses key items
214-216, which is exactly what "A Question of Taste" needs.

BUILD-TIME ONLY.
]]

local N = require('tools/lib/normalize')

local M = {}

local AREAS = {
    quest = {'abyssea', 'adoulin', 'bastok', 'coalition', 'crystal_war',
             'jeuno', 'other', 'outlands', 'sandoria', 'toau', 'windurst'},
    mission = {'acp', 'adoulin', 'asa', 'assault', 'bastok', 'campaign',
               'cop', 'mkd', 'rov', 'sandoria', 'toau', 'tvr', 'windurst',
               'wotg', 'zilart'},
}

-------------------------------------------------------------------------------
-- minimal JSON writer (strings and numbers only -- that is all we emit)
-------------------------------------------------------------------------------

local JSON_ESC = {
    ['"'] = '\\"', ['\\'] = '\\\\', ['\b'] = '\\b', ['\f'] = '\\f',
    ['\n'] = '\\n', ['\r'] = '\\r', ['\t'] = '\\t',
}

local function jstr(s)
    s = tostring(s):gsub('[%c"\\]', function(c)
        return JSON_ESC[c] or string.format('\\u%04x', c:byte())
    end)
    return '"' .. s .. '"'
end

-------------------------------------------------------------------------------
-- load
-------------------------------------------------------------------------------

--[[ -> maps[cat][area][id] = name, plus a per-area count.
     Missing area files are reported, not skipped quietly: a source without
     maps/missions/rov.lua would leave a hole in the ladder. ]]
function M.load_dat_maps(src, report)
    local maps, stats, missing = {}, {}, {}
    for _, cat in ipairs({'quest', 'mission'}) do
        local sub = (cat == 'quest') and 'quests' or 'missions'
        maps[cat] = {}
        for _, area in ipairs(AREAS[cat]) do
            local path = src .. 'maps/' .. sub .. '/' .. area .. '.lua'
            local t = N.load_table(path)
            if type(t) ~= 'table' then
                missing[#missing + 1] = cat .. '/' .. area
            else
                local clean, n = {}, 0
                for id, name in pairs(t) do
                    if type(id) == 'number' and type(name) == 'string' and name ~= '' then
                        clean[id] = name
                        n = n + 1
                    end
                end
                maps[cat][area] = clean
                stats[cat .. '/' .. area] = n
            end
        end
    end
    if report and #missing > 0 then
        report('  WARNING: no DAT map for ' .. table.concat(missing, ', '))
    end
    return maps, stats, missing
end

-------------------------------------------------------------------------------
-- emit
-------------------------------------------------------------------------------

function M.write_names(path, maps, stats)
    local f, err = io.open(path, 'w')
    if not f then return nil, 'cannot write ' .. path .. ': ' .. tostring(err) end

    local total = 0
    for _, n in pairs(stats) do total = total + n end

    f:write('-- questmarks DAT name tables -- GENERATED FILE, DO NOT EDIT BY HAND.\n')
    f:write('-- Regenerate: luajit tools/pipeline/dump_res.lua --names '
            .. '--dat-source <dir>\n')
    f:write('--\n')
    f:write('-- names[cat][area][id] = the quest/mission name the CLIENT uses, read\n')
    f:write('-- out of the game\'s own DAT files (0xD99A-0xD9BE). This is game data, not\n')
    f:write('-- wiki data -- see NOTICE. Frozen: nothing in questmarks needs an extractor\n')
    f:write('-- unless the game adds content.\n')
    f:write('--\n')
    f:write('-- Load-bearing beyond labelling: core/quests.lua feeds these ids to\n')
    f:write('-- state.set_area_ids, and resolve_linear picks the largest id <= the packet\n')
    f:write('-- pointer. A missing id silently drags a linear storyline backwards, so this\n')
    f:write('-- table must stay COMPLETE regardless of which quests have wiki coverage.\n')
    f:write(('-- %d names.\n\n'):format(total))
    f:write('return {\n')

    for _, cat in ipairs({'quest', 'mission'}) do
        f:write(('  %s = {\n'):format(cat))
        for _, area in ipairs(N.sorted_keys(maps[cat] or {})) do
            f:write(('    %s = {   -- %d\n'):format(area, stats[cat .. '/' .. area] or 0))
            for _, id in ipairs(N.sorted_keys(maps[cat][area])) do
                f:write(('      [%d] = %s,\n'):format(id, N.lua_str(maps[cat][area][id])))
            end
            f:write('    },\n')
        end
        f:write('  },\n')
    end
    f:write('}\n')
    f:close()
    return total
end

function M.write_res_json(path, maps, zones)
    -- 'wb' so the JSON is LF on every platform; see build_index.lua's emit().
    local f, err = io.open(path, 'wb')
    if not f then return nil, 'cannot write ' .. path .. ': ' .. tostring(err) end

    f:write('{\n')
    f:write('  "schema": "questmarks-res/1",\n')

    f:write('  "zones": {\n')
    local zkeys = N.sorted_keys(zones)
    for i, zid in ipairs(zkeys) do
        local z = zones[zid]
        local name = type(z) == 'table' and z.en or z
        if type(name) == 'string' then
            f:write(('    "%d": %s%s\n'):format(zid, jstr(name),
                i < #zkeys and ',' or ''))
        end
    end
    f:write('  },\n')

    f:write('  "dat": {\n')
    for ci, cat in ipairs({'quest', 'mission'}) do
        f:write(('    "%s": {\n'):format(cat))
        local akeys = N.sorted_keys(maps[cat] or {})
        for ai, area in ipairs(akeys) do
            f:write(('      "%s": {'):format(area))
            local ids = N.sorted_keys(maps[cat][area])
            for i, id in ipairs(ids) do
                f:write(('%s"%d": %s'):format(i > 1 and ', ' or '', id,
                    jstr(maps[cat][area][id])))
            end
            f:write(('}%s\n'):format(ai < #akeys and ',' or ''))
        end
        f:write(('    }%s\n'):format(ci < 2 and ',' or ''))
    end
    f:write('  }\n')
    f:write('}\n')
    f:close()
    return true
end

-------------------------------------------------------------------------------
-- driver
-------------------------------------------------------------------------------

function M.run(opts)
    opts = opts or {}
    local report = opts.report or print

    local root = N.normalize_path(N.find_windower_root(opts.root)) .. '/'
    local outdir = root .. 'addons/questmarks/'

    --[[ `--names` is the only branch here that wants a DAT extractor.

         data/dat_names.lua ships and is frozen. Its contents are the client's
         own strings, pulled out of the DATs at 0xD99A-0xD9BE. The extractor
         requirement stays inside this branch: `--res` reads nothing but
         res/zones.lua and must keep working without one.

         If the game ever adds content, point this at any DAT extractor that
         writes maps/quests/<area>.lua and maps/missions/<area>.lua. Until then
         nobody runs it. ]]
    local maps, stats, missing = nil, {}, {}

    if opts.names ~= false then
        --[[ The extractor is not bundled and is not named here. Pass
             --dat-source <dir>, where <dir> holds maps/quests/<area>.lua and
             maps/missions/<area>.lua. data/dat_names.lua is shipped and
             frozen, so this branch only matters if the game adds content. ]]
        local src = opts.dat_source
        if not src or not N.file_exists(src .. 'maps') then
            return nil, '--names needs a DAT name source. Pass --dat-source '
                .. '<dir> holding maps/quests/<area>.lua and '
                .. 'maps/missions/<area>.lua. data/dat_names.lua is shipped '
                .. 'and frozen, so this is only needed if the game added '
                .. 'content.'
        end
        maps, stats, missing = M.load_dat_maps(src, report)
        if missing and #missing > 0 then
            report(('  WARNING: %d area map(s) missing'):format(#missing))
        end
        local path = outdir .. 'data/dat_names.lua'
        local total, err = M.write_names(path, maps, stats)
        if not total then return nil, err end
        report(('  wrote %s  (%d names)'):format(path, total))
    end

    --[[ ...and `--res` reads our own shipped copy, not an extractor.
         build/res.json is the id -> name table the Python stages need, and it
         is the SAME table data/dat_names.lua already carries -- that file is
         generated from the DATs above and is shipped. Reading it here means the
         regenerable half of this tool needs nothing outside questmarks, which
         is the whole point of the scoping above. It also cannot drift from what
         the Lua build uses, because it IS what the Lua build uses. ]]
    if opts.res and not maps then
        local dn = N.load_table(outdir .. 'data/dat_names.lua')
        if type(dn) ~= 'table' then
            return nil, 'data/dat_names.lua not readable at ' .. outdir
        end
        maps = dn
        for _, cat in ipairs({'quest', 'mission'}) do
            local n = 0
            for _, area in pairs(dn[cat] or {}) do
                for _ in pairs(area) do n = n + 1 end
            end
            stats[cat .. ' names'] = n
        end
    end

    if opts.res then
        local zones
        if N.standalone() then
            zones = N.load_table(root .. 'res/zones.lua')
        else
            zones = require('resources').zones
        end
        if not zones then return nil, 'failed to load res/zones.lua' end
        -- build/ is regenerable scratch, so create it rather than requiring it
        os.execute('mkdir "' .. (outdir .. 'build'):gsub('/', '\\') .. '" 2>nul')
        local path = outdir .. 'build/res.json'
        local ok, err = M.write_res_json(path, maps, zones)
        if not ok then return nil, err end
        report(('  wrote %s'):format(path))
    end

    for _, k in ipairs(N.sorted_keys(stats)) do
        report(('  %-20s %4d'):format(k, stats[k]))
    end
    return stats, nil, missing
end

local ARG1 = ...
if N.standalone() and (ARG1 == nil or (type(ARG1) == 'string' and ARG1:sub(1, 1) == '-')) then
    local argv = {...}
    local opts = {names = nil, res = false}
    local only_res = false
    for i, a in ipairs(argv) do
        if a == '--names' then opts.names = true
        elseif a == '--res' then opts.res = true; only_res = (opts.names == nil)
        elseif a == '--root' then opts.root = argv[i + 1]
        elseif a == '--dat-source' then
            opts.dat_source = (argv[i + 1] or ''):gsub('/*$', '') .. '/'
        elseif a == '--help' or a == '-h' then
            print('usage: luajit tools/pipeline/dump_res.lua [--names] '
                  .. '[--res] [--root <dir>] [--dat-source <dir>]')
            os.exit(0)
        end
    end
    if #argv == 0 then opts.names, opts.res = true, true end
    if only_res then opts.names = false end
    local st, err = M.run(opts)
    if not st then
        io.stderr:write('ERROR: ' .. tostring(err) .. '\n')
        os.exit(1)
    end
end

return M
