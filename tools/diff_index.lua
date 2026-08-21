--[[
tools/diff_index.lua -- compare two generated quest indexes.

    luajit tools/diff_index.lua <old.lua> <new.lua> [--tsv <path>] [--quiet]

Written in Lua on purpose. Both files ARE Lua chunks, so `loadfile` reads them
with zero dependencies and no risk of a second parser disagreeing with the one
the addon actually uses.

Two jobs:

  1. Prove a refactor is a no-op. Row ORDER inside a by_npc list is an emitter
     detail, not data, so rows are compared as an unordered multiset of
     canonical strings. Keep the comparison order-insensitive: an emitter
     change must not be able to masquerade as a data change.

  2. Gate a data change. Reports the regressions that actually matter for
     markers: a quest that disappeared, a zone that went from resolved to nil
     (nil matches EVERY zone), a fame gate that vanished, prerequisites that
     stopped resolving, and NPC keys whose entry count grew sharply -- the
     signature of the "every Moogle in Vana'diel" bug.

BUILD-TIME ONLY.
]]

local N = require('tools/lib/normalize')

local lua_val, sorted_keys, count = N.lua_val, N.sorted_keys, N.count

-------------------------------------------------------------------------------
-- canonical forms
-------------------------------------------------------------------------------

-- One entry row -> a single comparable string. Field order is fixed here, not
-- inherited from the emitter, so the two files can be emitted differently and
-- still compare equal when the DATA is the same.
local function row_key(e)
    local parts = {
        tostring(e.cat), tostring(e.area), tostring(e.id),
        'z=' .. lua_val(e.zone),
        'rep=' .. lua_val(e.repeatable),
        'fame=' .. lua_val(e.fame) .. '/' .. lua_val(e.fame_lvl),
        'partial=' .. lua_val(e.reqs_partial or false),
    }
    local ps = {}
    for _, p in ipairs(e.prev or {}) do
        ps[#ps + 1] = p.unresolved and ('?' .. p.unresolved)
                                   or (p.cat .. '/' .. p.area .. '/' .. p.id)
    end
    table.sort(ps)
    parts[#parts + 1] = 'prev=[' .. table.concat(ps, ',') .. ']'
    local rs = {}
    for _, r in ipairs(e.reqs or {}) do
        rs[#rs + 1] = r.kind .. ':' .. r.rid .. 'x' .. r.n
    end
    table.sort(rs)
    parts[#parts + 1] = 'reqs=[' .. table.concat(rs, ',') .. ']'
    return table.concat(parts, ' ')
end

local function qid(e) return e.cat .. '/' .. e.area .. '/' .. e.id end

--[[ Both index shapes, reduced to the same view.

     v1: by_npc[key] = { <full entry>, ... }
     v2: by_npc[key] = { {q=<qid>, s=<step>, z=<zone>}, ... } + quests[qid]

     Returning one shape lets this tool compare a v1 file against a v2 file,
     which is exactly what the migration needs. ]]
local function load_index(path)
    local chunk, err = loadfile(path)
    if not chunk then return nil, 'cannot load: ' .. tostring(err) end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= 'table' or type(t.by_npc) ~= 'table' then
        return nil, 'malformed index: ' .. tostring(t)
    end

    --[[ Resolve each FILE's references against that file's OWN quests table
         before merging anything.

         A v2 reference is an index into that file's quests table, and those
         indexes are per file. Do not merge two files' by_npc tables and
         resolve afterwards: it reads mission refs against the quest file's
         records and reports losses that are not real. ]]
    local function resolve(src)
        local out = {}
        for npc, list in pairs(src.by_npc or {}) do
            local l = {}
            for _, r in ipairs(list) do
                local e = r
                if r.q ~= nil and src.quests then
                    local q = src.quests[r.q]
                    if q then
                        e = {cat = q.cat, area = q.area, id = q.id, zone = r.z,
                             repeatable = q.repeatable, fame = q.fame,
                             fame_lvl = q.fame_lvl, reqs_partial = q.reqs_partial,
                             prev = q.prev, reqs = q.reqs, steps = q.steps}
                    else
                        e = nil
                    end
                end
                if e then l[#l + 1] = e end
            end
            if #l > 0 then out[npc] = l end
        end
        return out
    end

    -- Mirror core/quests.lua: missions live in a sibling file, so compare the
    -- merged picture.
    local merged = resolve(t)
    local zmerged = {}
    for z, list in pairs(t.by_zone or {}) do
        zmerged[z] = {}
        for _, e in ipairs(list) do table.insert(zmerged[z], e) end
    end

    local dir = path:match('^(.*[/\\])') or ''
    local mchunk = loadfile(dir .. 'mission_index.lua')
    if mchunk then
        local mok, mt = pcall(mchunk)
        if mok and type(mt) == 'table' and type(mt.by_npc) == 'table' then
            for npc, list in pairs(resolve(mt)) do
                local d = merged[npc]
                if not d then
                    merged[npc] = list
                else
                    for _, e in ipairs(list) do d[#d + 1] = e end
                end
            end
            for z, list in pairs(mt.by_zone or {}) do
                zmerged[z] = zmerged[z] or {}
                for _, e in ipairs(list) do table.insert(zmerged[z], e) end
            end
        end
    end
    t = {meta = t.meta, by_npc = merged, by_zone = zmerged, names = t.names}

    local v = {
        path = path,
        meta = t.meta or {},
        rows = {},        -- npc_key -> { row_key -> n }
        npc_of = {},      -- qid -> { npc_key -> true }
        entries = {},     -- qid -> entry (deduped)
        by_zone = {},     -- zone -> { qid -> true }
        names = t.names or {},
        n_rows = 0,
    }

    for npc, list in pairs(t.by_npc) do
        v.rows[npc] = v.rows[npc] or {}
        for _, e in ipairs(list) do
            local k = row_key(e)
            v.rows[npc][k] = (v.rows[npc][k] or 0) + 1
            v.n_rows = v.n_rows + 1
            local id = qid(e)
            v.npc_of[id] = v.npc_of[id] or {}
            v.npc_of[id][npc] = true
            v.entries[id] = v.entries[id] or e
        end
    end

    for z, list in pairs(t.by_zone or {}) do
        v.by_zone[z] = {}
        for _, e in ipairs(list) do
            v.by_zone[z][e.q and 'q' .. tostring(e.q) or qid(e)] = true
        end
    end

    return v
end

-------------------------------------------------------------------------------
-- comparison
-------------------------------------------------------------------------------

local function set_of_keys(t)
    local s = {}
    for k in pairs(t) do s[k] = true end
    return s
end

local function union_keys(a, b)
    local s = set_of_keys(a)
    for k in pairs(b) do s[k] = true end
    return sorted_keys(s)
end

local function npc_list(t)
    local l = {}
    for k in pairs(t) do l[#l + 1] = k end
    table.sort(l)
    return table.concat(l, '|')
end

local M = {}

function M.compare(old, new)
    local r = {
        identical = true,
        row_diffs = {},      -- npc -> {added={}, removed={}}
        quests_gone = {},
        quests_new = {},
        zone_lost = {},      -- resolved -> nil
        fame_lost = {},
        prev_lost = {},
        npc_moved = {},
        nil_zone_old = 0, nil_zone_new = 0,
        counts = {},
    }

    -- --- rows, as an unordered multiset per NPC key -----------------------
    for _, npc in ipairs(union_keys(old.rows, new.rows)) do
        local a, b = old.rows[npc] or {}, new.rows[npc] or {}
        local added, removed = {}, {}
        for _, k in ipairs(union_keys(a, b)) do
            local na, nb = a[k] or 0, b[k] or 0
            for _ = 1, nb - na do added[#added + 1] = k end
            for _ = 1, na - nb do removed[#removed + 1] = k end
        end
        if #added > 0 or #removed > 0 then
            r.identical = false
            r.row_diffs[npc] = {added = added, removed = removed}
        end
    end

    -- --- per quest -------------------------------------------------------
    for _, id in ipairs(union_keys(old.entries, new.entries)) do
        local a, b = old.entries[id], new.entries[id]
        if a and not b then
            r.quests_gone[#r.quests_gone + 1] = id
        elseif b and not a then
            r.quests_new[#r.quests_new + 1] = id
        else
            -- A nil zone matches EVERY zone, so resolved -> nil is a real
            -- regression even though nothing "disappeared".
            if a.zone ~= nil and b.zone == nil then
                r.zone_lost[#r.zone_lost + 1] =
                    ('%s  zone %s -> nil'):format(id, lua_val(a.zone))
            end
            if a.fame and a.fame_lvl and a.fame_lvl > 0
               and not (b.fame and b.fame_lvl and b.fame_lvl > 0) then
                r.fame_lost[#r.fame_lost + 1] =
                    ('%s  fame %s/%s -> %s/%s'):format(id, tostring(a.fame),
                        tostring(a.fame_lvl), tostring(b.fame), tostring(b.fame_lvl))
            end
            local function resolved(e)
                local n = 0
                for _, p in ipairs(e.prev or {}) do
                    if not p.unresolved then n = n + 1 end
                end
                return n
            end
            if resolved(b) < resolved(a) then
                r.prev_lost[#r.prev_lost + 1] =
                    ('%s  resolved prerequisites %d -> %d'):format(id, resolved(a), resolved(b))
            end
            local na, nb = npc_list(old.npc_of[id]), npc_list(new.npc_of[id])
            if na ~= nb then
                r.npc_moved[#r.npc_moved + 1] = ('%s  {%s} -> {%s}'):format(id, na, nb)
            end
        end
    end

    for _, e in pairs(old.entries) do if e.zone == nil then r.nil_zone_old = r.nil_zone_old + 1 end end
    for _, e in pairs(new.entries) do if e.zone == nil then r.nil_zone_new = r.nil_zone_new + 1 end end

    r.counts = {
        npc_keys_old = count(old.rows),   npc_keys_new = count(new.rows),
        rows_old     = old.n_rows,        rows_new     = new.n_rows,
        quests_old   = count(old.entries), quests_new  = count(new.entries),
    }

    if #r.quests_gone > 0 or #r.quests_new > 0 then r.identical = false end
    return r
end

-- Top NPC keys by entry count, side by side. A key that grows sharply is the
-- signature of a generic name (Moogle, Chocobo, ???) losing its zone.
function M.top_npcs(old, new, n)
    local names, out = {}, {}
    for k in pairs(old.rows) do names[k] = true end
    for k in pairs(new.rows) do names[k] = true end
    for k in pairs(names) do
        local a, b = 0, 0
        for _, c in pairs(old.rows[k] or {}) do a = a + c end
        for _, c in pairs(new.rows[k] or {}) do b = b + c end
        out[#out + 1] = {npc = k, old = a, new = b}
    end
    table.sort(out, function(x, y)
        if x.new ~= y.new then return x.new > y.new end
        return x.npc < y.npc
    end)
    local top = {}
    for i = 1, math.min(n or 20, #out) do top[i] = out[i] end
    return top
end

-------------------------------------------------------------------------------
-- CLI
-------------------------------------------------------------------------------

local function report_list(label, list, limit)
    if #list == 0 then return end
    print(('\n%s (%d):'):format(label, #list))
    table.sort(list)
    for i = 1, math.min(limit or 40, #list) do print('   ' .. list[i]) end
    if #list > (limit or 40) then print(('   ... and %d more'):format(#list - (limit or 40))) end
end

local ARG1 = ...
if N.standalone() and (ARG1 == nil or (type(ARG1) == 'string' and ARG1 ~= 'tools/diff_index')) then
    local argv = {...}
    local a, b, tsv, quiet = argv[1], argv[2], nil, false
    for i, v in ipairs(argv) do
        if v == '--tsv' then tsv = argv[i + 1] end
        if v == '--quiet' then quiet = true end
    end
    if not a or not b then
        print('usage: luajit tools/diff_index.lua <old.lua> <new.lua> [--tsv <path>] [--quiet]')
        os.exit(2)
    end

    local old, oerr = load_index(a)
    if not old then io.stderr:write('ERROR ' .. a .. ': ' .. oerr .. '\n') os.exit(1) end
    local new, nerr = load_index(b)
    if not new then io.stderr:write('ERROR ' .. b .. ': ' .. nerr .. '\n') os.exit(1) end

    local r = M.compare(old, new)
    local c = r.counts
    print(('old %s'):format(a))
    print(('new %s'):format(b))
    print(('  npc keys   %6d -> %6d'):format(c.npc_keys_old, c.npc_keys_new))
    print(('  rows       %6d -> %6d'):format(c.rows_old, c.rows_new))
    print(('  quests     %6d -> %6d'):format(c.quests_old, c.quests_new))
    print(('  zone=nil   %6d -> %6d   %s'):format(r.nil_zone_old, r.nil_zone_new,
        r.nil_zone_new <= r.nil_zone_old and 'ok' or '*** REGRESSION: a nil zone matches everywhere'))

    report_list('quests LOST', r.quests_gone)
    report_list('quests GAINED', r.quests_new)
    report_list('zone resolved -> nil', r.zone_lost)
    report_list('fame gate lost', r.fame_lost)
    report_list('prerequisites stopped resolving', r.prev_lost)
    report_list('start NPC changed', r.npc_moved)

    if not quiet then
        print('\ntop NPC keys by entry count (old -> new):')
        for _, t in ipairs(M.top_npcs(old, new, 20)) do
            print(('   %-34s %4d -> %4d%s'):format(t.npc, t.old, t.new,
                (t.new > t.old * 2 and t.new > 10) and '   <-- check' or ''))
        end
    end

    local ndiff = count(r.row_diffs)
    if ndiff == 0 then
        print('\nby_npc rows: IDENTICAL (order-insensitive)')
    else
        print(('\nby_npc rows differ on %d NPC keys:'):format(ndiff))
        local shown = 0
        for _, npc in ipairs(sorted_keys(r.row_diffs)) do
            if shown >= 15 then print('   ...') break end
            shown = shown + 1
            print('  [' .. npc .. ']')
            for _, k in ipairs(r.row_diffs[npc].removed) do print('    - ' .. k) end
            for _, k in ipairs(r.row_diffs[npc].added)   do print('    + ' .. k) end
        end
    end

    if tsv then
        local f = io.open(tsv, 'w')
        if f then
            f:write('qid\tverdict\tdetail\n')
            local function w(v, list)
                for _, l in ipairs(list) do
                    local id = l:match('^(%S+)') or l
                    f:write(('%s\t%s\t%s\n'):format(id, v, l))
                end
            end
            w('LOST', r.quests_gone)
            w('GAINED', r.quests_new)
            w('ZONE_LOST', r.zone_lost)
            w('FAME_LOST', r.fame_lost)
            w('PREV_LOST', r.prev_lost)
            w('NPC_CHANGED', r.npc_moved)
            f:close()
            print('\nwrote ' .. tsv)
        end
    end

    os.exit(r.identical and 0 or 1)
end

M.load_index = load_index
M.row_key = row_key
return M
