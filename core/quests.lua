--[[
core/quests.lua -- the join between the static index and live packet state.

Owns data/quest_index.lua, answers "what should this NPC be showing right now",
and maintains the per-zone candidate name set the renderer scans against.

Zone handling is deliberately permissive: an entry with zone == nil matches in
ANY zone. That covers two real cases -- gate guards (a nation mission can be
started at any of that nation's guards, which sit in different districts) and
the 14 entries whose start_zone string never resolved. Dropping those would
lose real content; matching them everywhere costs at most a spurious marker on
a same-named NPC elsewhere.
]]

local quests = {}

local state = require('core/state')
local prereq = require('core/prereq')
local fame = require('core/fame')

local index = nil
local by_npc = {}
local by_zone = {}      -- zone id -> quests started by ENTERING that zone
local names = {}

-- zone id -> { [npc_key] = true }, built lazily and cached
local zone_cache = {}

local function fold(s)
    if s == nil then return nil end
    s = tostring(s):gsub('%s+', ' ')
    return (s:gsub('^%s+', ''):gsub('%s+$', '')):lower()
end
quests.fold = fold

-- ---------------------------------------------------------------------------
-- Loading
-- ---------------------------------------------------------------------------

--[[ The complete id -> name ladder, straight from the client's DATs.

     This must not come from the index. The index only records a quest whose
     giver resolved to an NPC name, so its `names` table shipped with holes --
     measured: mission/rov 4 of 94, mkd 1 of 15, acp 2 of 12, adoulin 33 of 106.
     Those ids are the ONLY input to resolve_linear, which answers "which
     mission am I on" by taking the largest known id <= the packet's pointer, so
     every hole drags that answer backwards and prereq then judges "later in a
     linear storyline" against a position that does not exist.

     Falls back to the index's own names when data/dat_names.lua is absent, so
     an older install and the offline fixtures keep working unchanged. ]]
local function load_dat_names(index_path)
    local dir = index_path:match('^(.*[/\\])') or ''
    local chunk = loadfile(dir .. 'dat_names.lua')
    if not chunk then return nil end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= 'table' then return nil end
    return t
end

--[[ DAT names win, index names fill any gap. They differ in kind, not just in
     coverage: the DAT string is what the player's own quest log says
     ("Dominion Op #01 (Altepa)"), while the index carries the BG Wiki page
     title ("Dominion Op 01 (Altepa)"). For a message the player reads, the
     client's own wording is the right one. ]]
local function merge_names(dat, from_index)
    if not dat then return from_index, 0 end
    local out, added = {}, 0
    for _, src in ipairs({from_index, dat}) do
        for cat, areas in pairs(src) do
            out[cat] = out[cat] or {}
            for area, ids in pairs(areas) do
                out[cat][area] = out[cat][area] or {}
                for id, nm in pairs(ids) do
                    if src == dat and out[cat][area][id] == nil then added = added + 1 end
                    out[cat][area][id] = nm
                end
            end
        end
    end
    return out, added
end

--[[ Missions ship in their own file. Both halves are regenerated first-hand
     from the BG Wiki cache.

     They stay split because they rebuild on different cadences: a mission
     rebuild runs in game via //qm rebuild, a quest rebuild is an offline
     pipeline, and a bad build of one cannot take the other down with it.

     Absent is not an error: an install that predates the split simply has all
     its rows in the quest file already. ]]
local function load_sibling(index_path, name)
    local dir = index_path:match('^(.*[/\\])') or ''
    local chunk = loadfile(dir .. name)
    if not chunk then return nil end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= 'table' or type(t.by_npc) ~= 'table' then return nil end
    return t
end

--[[ One NPC can carry both kinds -- a gate guard hands out nation missions
     while standing next to a quest giver, and 22 keys really do overlap -- so
     the two by_npc tables are concatenated per key rather than replaced. ]]
local function merge_rows(dst, src)
    for npc, list in pairs(src) do
        local d = dst[npc]
        if not d then
            dst[npc] = list
        else
            for _, e in ipairs(list) do d[#d + 1] = e end
        end
    end
end

--[[ v2: by_npc holds cheap references, {q = <quest index>, s = <step>, z = <zone>},
     and the quest record -- including its steps array -- exists exactly once in
     `quests`. An NPC that is the target of three different steps gets three
     refs, all pointing at the same record.

     Expanded here rather than in the file so the DATA file stays plain data.
     Each row is a two-field table whose metatable falls through to the shared
     record, so `row.cat`, `row.prev`, `row.steps` all keep working and nothing
     downstream had to change. The row owns `zone` and `step`: zone must be the
     STEP's zone (a later step can be in another city, and zone_ok filters on
     it), and step is which position this NPC stands for.

     v1 files have no `quests` table and pass through untouched. ]]
local function expand_v2(t, stats)
    if type(t.quests) ~= 'table' then return t.by_npc, t.by_zone end

    local mt = {}
    for i, q in pairs(t.quests) do
        --[[ Tolerant, not fatal: a malformed steps array costs THAT quest its
             stepping and nothing else. A data bug must not take the addon down. ]]
        if type(q.steps) ~= 'table' or #q.steps == 0 then
            q.steps = nil
            stats.dropped = (stats.dropped or 0) + 1
        else
            for n = 1, #q.steps do
                if type(q.steps[n]) ~= 'table' then
                    q.steps = nil
                    stats.dropped = (stats.dropped or 0) + 1
                    break
                end
            end
        end
        mt[i] = {__index = q}
    end

    local out = {}
    for npc, refs in pairs(t.by_npc) do
        local l = {}
        for _, r in ipairs(refs) do
            local m = mt[r.q]
            if m then
                -- `mob` is the ROLE ('kill'/'drop'/'spawn') when this row is a
                -- monster rather than an NPC; nil for everything else.
                l[#l + 1] = setmetatable({step = r.s, zone = r.z, mob = r.m}, m)
                stats.rows = (stats.rows or 0) + 1
            end
        end
        if #l > 0 then out[npc] = l end
    end

    --[[ by_zone gets the SAME treatment, and until now it did not.

         Its rows were bare {cat, area, id} -- no prerequisites, no fame gate,
         no level, no job -- so `prereq.evaluate` had literally nothing to check
         and returned 'ready' for all 49 of them. A zone-triggered mission was
         announced as takeable the moment its completed bit was clear, however
         far down its storyline it sat.

         Both shapes are accepted. A `{q=n}` row is a reference into the shared
         records; a row carrying `cat` is the old flattened form and passes
         through untouched, because tools/baseline/quest_index.v1.lua is still
         loaded by the blast-radius test and must keep working. ]]
    local outz = {}
    for z, refs in pairs(t.by_zone or {}) do
        local l = {}
        for _, r in ipairs(refs) do
            if r.q then
                local m = mt[r.q]
                if m then
                    l[#l + 1] = setmetatable({zone = z}, m)
                    stats.zone_rows = (stats.zone_rows or 0) + 1
                end
            else
                l[#l + 1] = r
            end
        end
        if #l > 0 then outz[z] = l end
    end
    return out, outz
end

function quests.load(path)
    local chunk, err = loadfile(path)
    if not chunk then return nil, 'cannot load index: ' .. tostring(err) end
    local ok, t = pcall(chunk)
    if not ok or type(t) ~= 'table' or type(t.by_npc) ~= 'table' then
        return nil, 'malformed index: ' .. tostring(t)
    end

    local added
    index = t

    -- Copy rather than alias: merging missions in must not mutate the loaded
    -- chunk's own table, which //qm rebuild may reload from underneath us.
    local xstats = {}
    by_npc, by_zone = {}, {}
    local qn, qz = expand_v2(t, xstats)
    merge_rows(by_npc, qn)
    for z, list in pairs(qz or {}) do
        by_zone[z] = by_zone[z] or {}
        for _, e in ipairs(list) do table.insert(by_zone[z], e) end
    end

    local missions = load_sibling(path, 'mission_index.lua')
    if missions then
        local mn, mz = expand_v2(missions, xstats)
        merge_rows(by_npc, mn)
        for z, list in pairs(mz or {}) do
            by_zone[z] = by_zone[z] or {}
            for _, e in ipairs(list) do table.insert(by_zone[z], e) end
        end
    end

    names, added = merge_names(load_dat_names(path), t.names or {})
    zone_cache = {}
    prereq.set_names(names)

    --[[ Hand the DAT id lists to state.lua. Only the linear mission lines
         actually need them (their packet value is a pointer, not an id), but
         registering everything is cheap and keeps the two modules from having
         to agree on which areas are linear. ]]
    local n_ids = 0
    for cat, areas in pairs(names) do
        for area, ids in pairs(areas) do
            local l = {}
            for id in pairs(ids) do l[#l + 1] = id end
            n_ids = n_ids + #l
            state.set_area_ids(cat, area, l)
        end
    end

    local meta = t.meta or {}
    meta.dat_names_added = added
    meta.name_ids = n_ids
    meta.missions = missions and (missions.meta and missions.meta.indexed) or 0
    meta.quests = meta.indexed or 0
    meta.steps_dropped = xstats.dropped or 0
    -- `indexed` stays the total, because every existing reader means "how much
    -- is in the index" by it.
    meta.indexed = (meta.quests or 0) + (meta.missions or 0)
    return meta
end

function quests.loaded() return index ~= nil end
function quests.meta() return index and index.meta or nil end
function quests.name_of(cat, area, id)
    local c = names[cat]; local a = c and c[area]
    return a and a[id]
end

-- ---------------------------------------------------------------------------
-- Lookup
-- ---------------------------------------------------------------------------

--[[ Whether we are currently inside a Mog House. Set by the entry point from
     get_info().mog_house, because a Mog House is not a zone of its own -- the
     client reports the surrounding city. ]]
local in_mog_house = false
function quests.set_mog_house(v) in_mog_house = v and true or false end

--[[ Does this entry apply where the player is standing?

       zone == false       deliberately any zone (gate guards)
       zone == 'moghouse'  only inside a Mog House
       zone == nil         unresolved; allowed anywhere, but the builder has
                           already dropped these for generic NPC names so it
                           cannot mark every Moogle in the world
       zone == number      that zone only                                   ]]
local function zone_ok(e, zone)
    if e.zone == false or e.zone == nil then return true end
    if e.zone == 'moghouse' then return in_mog_house end
    return zone == nil or e.zone == zone
end

-- Entries registered for this NPC that are valid where the player is.
function quests.for_npc(npc, zone)
    local list = by_npc[fold(npc)]
    if not list then return nil end
    local out = nil
    for _, e in ipairs(list) do
        if zone_ok(e, zone) then
            out = out or {}
            out[#out + 1] = e
        end
    end
    return out
end

--[[ The set of NPC names worth looking for in a zone. The renderer intersects
     this against the live entity list, so it must be cheap and cached. ]]
--[[ Deliberately ignores the Mog House flag: this is only the cheap candidate
     filter for the entity scan, and a superset is fine. for_npc() applies the
     real test when marker state is computed. ]]
--[[ Values are `true` for an NPC and 'mob' for a monster, because the scan has
     to treat them differently: duplicate NPCs are ghost entity slots and get
     collapsed to the nearest, while duplicate monsters are all real and all
     valid targets. A name that is both stays 'mob', which is the safe way
     round -- it only costs the dedup. ]]
function quests.wanted_names(zone)
    if zone_cache[zone] then return zone_cache[zone] end
    local set = {}
    for npc, list in pairs(by_npc) do
        for _, e in ipairs(list) do
            if e.zone == nil or e.zone == false or e.zone == 'moghouse'
               or e.zone == zone then
                if e.mob then set[npc] = 'mob'
                elseif set[npc] == nil then set[npc] = true end
            end
        end
    end
    zone_cache[zone] = set
    return set
end

--[[ Aggregate marker for one NPC.
     -> marker_state, total_count, details, cat

     `total_count` deliberately counts every markable entry on the NPC, not
     just those in the winning state, so the badge answers "how much is here"
     rather than "how many are yellow".

     `cat` is the winning entry's category, which the renderer uses to colour
     missions differently from quests. On equal priority a MISSION wins the
     tie: missions are the main storyline and the entire point of colouring
     them separately is that they should not be lost among side quests. ]]
function quests.marker_for(npc, zone)
    local list = quests.for_npc(npc, zone)
    if not list then return nil end

    local best, best_pri, best_cat, best_area, count, details = nil, -1, nil, nil, 0, nil
    local best_hint
    for _, e in ipairs(list) do
        -- `e.step` is the step index this row stands for; nil on a v1 row and
        -- on every mission, which makes marker_state ignore stepping entirely.
        local st = prereq.marker_state(e, e.step)
        if st then
            count = count + 1
            details = details or {}
            details[#details + 1] = {entry = e, state = st}
            local pri = prereq.priority(st)
            if pri > best_pri
               or (pri == best_pri and e.cat == 'mission' and best_cat ~= 'mission') then
                best, best_pri, best_cat, best_area = st, pri, e.cat, e.area
                --[[ What the winning row ASKS of you, which is what picks the
                     glyph. `mob` is the role when this row is a monster;
                     otherwise the step's own kind. ]]
                local s = e.steps and e.step and e.steps[e.step]
                best_hint = {mob = e.mob, kind = s and s.k}
            end
        end
    end
    if not best then return nil end
    return best, count, details, best_cat, best_area, best_hint
end

--[[ Full per-quest breakdown for `//qm why`. Includes entries with no marker
     so the user can see WHY something is absent, which is the common question. ]]
function quests.explain(npc, zone)
    local list = quests.for_npc(npc, zone)
    if not list then return nil end

    --[[ ONE row per quest, not one per step.

         An NPC that is several steps of the same quest gets a by_npc row for
         each -- Bluffnix is both steps of "The Gobbiebag Part I", Ajithaam is
         its first and last -- and //qm why printed the quest once per row.
         That is noise in the one file people send when something looks wrong.

         The row that actually draws wins; failing that the first, so the
         explanation still says why nothing is marked. `at_steps` keeps the full
         list so the output can name them. ]]
    local steps = require('core/steps')
    local best, order = {}, {}
    for _, e in ipairs(list) do
        local key = e.cat .. '/' .. e.area .. '/' .. e.id
        local drew = prereq.marker_state(e, e.step) ~= nil
        local cur = best[key]
        if not cur then
            order[#order + 1] = key
            best[key] = {entry = e, drew = drew, at_steps = {e.step}}
        else
            cur.at_steps[#cur.at_steps + 1] = e.step
            if drew and not cur.drew then cur.entry, cur.drew = e, true end
        end
    end

    local out = {}
    for _, key in ipairs(order) do
        local e = best[key].entry
        --[[ marker_state's OWN reasons, kept rather than dropped. For an
             in-progress quest they are the entire turn-in explanation -- which
             step is current, whether its items are held -- and without them
             //qm why shows a grey "?" with no way to tell "you are missing
             four items" from "this quest can never report readiness". ]]
        local st, mreasons = prereq.marker_state(e, e.step)
        local status, source = state.status_of(e.cat, e.area, e.id)
        local _, reasons = prereq.evaluate(e)
        out[#out + 1] = {
            entry = e,
            name = quests.name_of(e.cat, e.area, e.id),
            marker = st,
            quest_status = status,
            -- `//qm why` prints this: 'done' with no marker is otherwise
            -- indistinguishable from a mission you never touched.
            quest_source = source,
            reasons = reasons,
            suppressed = prereq.suppressed_reason(e, e.step),
            -- The whole step ladder, so a marker on the wrong NPC can be
            -- diagnosed from one //qm why instead of guessed at. A quest that
            -- is not in progress has no position, and asking for one would
            -- both claim something untrue and pollute the step statistics.
            steps = steps.explain(e, status == 'in_progress'),
            marker_reasons = mreasons,
            at_step = e.step,
            -- every step of this quest that lives on THIS NPC
            at_steps = best[key].at_steps,
        }
    end
    return out
end

-- ---------------------------------------------------------------------------
-- Inferred fame floors
-- ---------------------------------------------------------------------------

--[[ A quest gated at fame N that the player has ACCEPTED proves fame >= N.
     Because completed non-repeatable quests stay in the `current` list, this
     is a genuine lower bound and never over-claims. Free, exact, no guessing --
     and it converts a large share of "unknown" fame into "met" without the
     player ever visiting a checker.

     Deduplicated over the index because one entry appears under several NPC
     keys (multi-option givers, gate guards). ]]
function quests.rebuild_fame_floors()
    local seen, found = {}, 0
    local pending = {}

    for _, list in pairs(by_npc) do
        for _, e in ipairs(list) do
            if e.fame and e.fame_lvl and e.fame_lvl > 0 then
                local key = e.cat .. '/' .. e.area .. '/' .. e.id
                if not seen[key] then
                    seen[key] = true
                    local st = state.status_of(e.cat, e.area, e.id)
                    if st == 'in_progress' or st == 'done' then
                        pending[#pending + 1] = {e.fame, e.fame_lvl}
                        found = found + 1
                    end
                end
            end
        end
    end

    local i = 0
    fame.rebuild_floors(function()
        i = i + 1
        local p = pending[i]
        if not p then return nil end
        return p[1], p[2]
    end)
    return found
end

--[[ Quests this zone starts on ENTRY -- no NPC hands them out, so they can
     never carry a marker. Returns only those currently actionable, since
     announcing one you have already done would be noise.
     -> array of {entry, name} ]]
function quests.zone_starts(zone)
    local list = by_zone[zone]
    if not list then return nil end
    local out
    for _, ref in ipairs(list) do
        local st = prereq.marker_state(ref)
        if st == 'ready' or st == 'turnin' then
            out = out or {}
            out[#out + 1] = {entry = ref, state = st,
                             name = quests.name_of(ref.cat, ref.area, ref.id)}
        end
    end
    return out
end

--[[ Visit every indexed entry exactly once.

     `by_npc` stores an entry under each NPC name that can give it -- gate
     guards and multi-option givers duplicate rows -- so anything counting or
     diffing entries must deduplicate on (cat, area, id) or it will process the
     same quest several times. ]]
function quests.each_entry(fn)
    local seen = {}
    for npc, list in pairs(by_npc) do
        for _, e in ipairs(list) do
            local key = e.cat .. '/' .. e.area .. '/' .. e.id
            if not seen[key] then
                seen[key] = true
                fn(key, e, npc)
            end
        end
    end
end

-- ---------------------------------------------------------------------------
-- The whole-index view (//qm todo)
-- ---------------------------------------------------------------------------

--[[ The single zone the GIVER stands in, or nil when that is not one place.

     Do not read `e.zone` for this. It is THIS row's step zone and which row we
     hold is a `pairs()` accident, so it printed one of the quest's step cities
     at random beside the giver's name: 36 of 55 entries gave a different zone
     between processes, abyssea/182 rotating over 45 / 216 / 251 / 254 while its
     giver Esha'ntarl never leaves 251. Sorting the walk only makes that coin
     flip repeatable, and a repeatable wrong city still sends the player there.

     The label comes from `snpc`, so the zone does too: the giver's own rows
     carry it (one under the giver's key, step 0, in the giver's zone). 53 of
     the 54 answer this way, in any iteration order, because the question is
     "is there exactly ONE distinct numeric zone". Order has to be irrelevant:
     the game runs PUC-Rio 5.1 and the suites run LuaJIT, which hash differently.

     Two zones means the giver really stands in both (prof. schultz, 112 and
     165) and we then name NEITHER; a confidently wrong city is worse than none.
     Costs one row its zone and no row a marker: `where_of` feeds the `//qm todo`
     text and nothing else. ]]
local function giver_zone(e)
    local key = fold(e.snpc)
    if key == nil or key == '' then return nil end
    local found = nil
    for _, r in ipairs(by_npc[key] or {}) do
        if r.cat == e.cat and r.area == e.area and r.id == e.id
           and type(r.zone) == 'number' then
            if found == nil then found = r.zone
            elseif found ~= r.zone then return nil end
        end
    end
    return found
end

--[[ WHERE a quest is asking you to be, as data rather than as a sentence.
     -> {label, zone, grid, step, of, held}   (label may be nil)

     Two different questions depending on whether you have accepted it:

       in progress -> the step the MARKER is on, which is `marker_idx` and not
                      `idx`. They differ whenever the current step is a '???'
                      or a monster with nothing recorded, and pointing at the
                      unmarkable one would name a place you cannot go.
       otherwise   -> the giver, which is `snpc`. Deliberately NOT the row's
                      own npc key: `each_entry` hands back whichever row
                      `pairs()` reached first, so using it would make the
                      answer differ between runs for any quest that visits one
                      NPC twice.

     Zone and grid come from the STEP, because a quest's steps span cities. A
     quest with no ladder has the synthetic single step at its giver, so this
     path works unchanged for missions and for the 120 quests with no ladder. ]]
function quests.where_of(e, status)
    local out = {}
    if type(e) ~= 'table' then return out end

    local sx = require('core/steps')
    if status == 'in_progress' and e.steps then
        local idx, n, _, info = sx.current(e)
        if idx then
            out.step, out.of, out.held = idx, n, info.held

            --[[ Where the STEP is, when that is not where the marker is.

                 A '???' step can never carry a marker: the client calls every
                 one of them '???' and one town holds as many as fifteen. The
                 marker holds back to the previous NPC, so the caller hears
                 where the MARKER is and never where the work is. The index has
                 the place anyway: 327 of the 332 '???' steps carry a zone and
                 274 a map grid ref, dropped only because the marker path needs
                 an npc key. Reported ALONGSIDE the marker's location, never
                 instead of it; costs no marker, cannot touch the tri-state.

                 The gate is `marker_idx ~= idx`. Two tempting alternatives are
                 both wrong. `info.held` is false when marker_idx is nil, the
                 "nothing anywhere can be marked" case, which is exactly when
                 this is most useful. markable() alone is false in the pre-sweep
                 window: core/steps.lua's `not inventory.ready()` early return
                 hands back idx = marker_idx = 1 without testing markability, so
                 a quest whose step 1 is a '???' would draw an arrow to the place
                 it just named. 8 shipped rows do that on every login, until the
                 first bag sweep lands. ]]
            local cs = e.steps[idx]
            if cs and info.marker_idx ~= idx and not sx.markable(cs)
               and cs.z ~= nil then
                out.at_kind, out.at_zone, out.at_grid = cs.k, cs.z, cs.g
            end

            local mi = info.marker_idx
            local s = (mi and mi > 0) and e.steps[mi] or nil
            if s then
                out.label, out.zone, out.grid = sx.row_label(s), s.z, s.g
                return out
            end
            --[[ marker_idx 0 is the giver and nil is "nothing anywhere can be
                 marked". Both fall through to the giver below, which is where
                 the marker itself falls back to. ]]
        end
    end

    local snpc = e.snpc
    if snpc == nil or snpc == '' then
        -- A giverless quest (anchored on its first markable step at build
        -- time). Name that step rather than nothing.
        for _, s in ipairs(e.steps or {}) do
            if sx.markable(s) then
                out.label, out.zone, out.grid = sx.row_label(s), s.z, s.g
                return out
            end
        end
        return out
    end

    out.label = snpc
    for _, s in ipairs(e.steps or {}) do
        if s.npc == snpc then
            out.zone, out.grid = s.z, s.g
            return out
        end
    end
    --[[ No step names the giver (a rescued start, or a v1-shaped mission row).
         `e.zone` is NOT the answer here -- it is this row's step zone, and which
         row we hold is a `pairs()` accident -- so the giver's own rows are asked
         instead. nil when the giver is in more than one zone or in none, which
         prints the giver's name with no city rather than the wrong city. ]]
    out.zone = giver_zone(e)
    return out
end

--[[ The monsters named by steps of quests you have ACCEPTED.
     -> array of names (unfolded, as the data records them)

     Feeds core/kills, whose whole cost problem is that packet 0x028 arrives
     for every action of every fight in the zone. With this list the entry
     point can refuse to parse a combat packet at all unless something is
     actually being counted -- which, for a character with no monster-step
     quest in progress, is always.

     `in_progress` and not "markable": a quest you have not started cannot have
     kill progress, and one whose mob step is unreachable this minute may still
     be the reason you are here. ]]
function quests.watched_mobs()
    local seen, out = {}, {}
    quests.each_entry(function(_, e)
        if state.status_of(e.cat, e.area, e.id) ~= 'in_progress' then return end
        for _, s in ipairs(e.steps or {}) do
            for _, m in ipairs(s.mobs or {}) do
                if m.name and not seen[m.name] then
                    seen[m.name] = true
                    out[#out + 1] = m.name
                end
            end
        end
    end)
    return out
end

--[[ Every indexed entry whose QUEST-LEVEL marker state is one of `states`.

     Quest-level means `marker_state(entry)` with no step -- exactly what
     notify.update asks, and correct for the same reason: this is a list of
     what is actionable ANYWHERE, not a question about where to stand. A quest
     whose current step is two zones away still belongs on your to-do list even
     though, by design, it draws no marker in the giver's zone.

     Sorted by display priority so the things you can finish come first. Cost
     is one prereq evaluation per entry, the same walk notify already does on
     every 0x056 settle -- so this is affordable on demand, not per frame. ]]
function quests.todo(states)
    local out = {}
    quests.each_entry(function(key, e)
        local st = prereq.marker_state(e)
        if st and states[st] then
            local status = state.status_of(e.cat, e.area, e.id)
            out[#out + 1] = {
                key = key, entry = e, state = st, status = status,
                name = quests.name_of(e.cat, e.area, e.id),
                where = quests.where_of(e, status),
            }
        end
    end)
    table.sort(out, function(a, b)
        local pa, pb = prereq.priority(a.state), prereq.priority(b.state)
        if pa ~= pb then return pa > pb end
        -- Missions above quests at equal priority, for the same reason they
        -- win the marker: they are the storyline, not a side errand.
        if a.entry.cat ~= b.entry.cat then return a.entry.cat < b.entry.cat end
        return (a.name or a.key) < (b.name or b.key)
    end)
    return out
end

-- ---------------------------------------------------------------------------
-- Diagnostics
-- ---------------------------------------------------------------------------

function quests.stats()
    local npcs, entries = 0, 0
    for _, list in pairs(by_npc) do
        npcs = npcs + 1
        entries = entries + #list
    end
    return npcs, entries
end

function quests.areas()
    local seen = {}
    for _, list in pairs(by_npc) do
        for _, e in ipairs(list) do seen[e.cat .. '/' .. e.area] = true end
    end
    local l = {}
    for k in pairs(seen) do l[#l + 1] = k end
    table.sort(l)
    return l
end

return quests
