--[[
questmarks -- WoW-style quest markers over FFXI NPCs.

Reads quest and mission state from packet 0x056, joins it against BG-Wiki-derived
quest-giver metadata, evaluates prerequisites, and draws a marker above the NPC
in the 3D world.

Colour carries the state and the glyph says what the NPC is for. The state
colours, as render/markers.lua defines them:

    yellow     available now, or ready to hand in   (quest)
    green      the same, for a mission
    red        the same, for Campaign
    grey       a prerequisite is definitely unmet, or accepted and in progress
    black      something could not be verified, usually fame
    blue       repeatable, and already done

`!` and `?` are the default glyphs; an accepted step swaps in the glyph for
what it asks of you (talk, trade, examine, fight, obtain).

See README.md for the full table, including the per-category variants and the
glyph vocabulary, and NOTICE for data attribution.

MUST NOT: require anything outside this addon or Windower's own stock libraries
(config, packets, logger, bit) -- tools/test_standalone.lua enforces it. Must
not write a global; tools/check.lua enforces that.
]]

_addon.name     = 'questmarks'
_addon.author   = 'DrNefarius'
--[[ Bump this whenever anything shipped changes. It is the only thing that
     tells two log files apart, and questmarks.log APPENDS across sessions --
     so during a multi-day test a single file holds several builds, and a line
     without a version is a line you cannot attribute. ]]
_addon.version  = '1.0.0'
_addon.commands = {'questmarks', 'qm'}

require('logger')
local config  = require('config')
local packets = require('packets')

-- Slash form is what works under Windower's Lua. Do not mix with dot form:
-- Lua would treat them as separate modules and load each one twice, giving
-- two independent copies of the state tables.
local state     = require('core/state')
local quests    = require('core/quests')
local prereq    = require('core/prereq')
local fame      = require('core/fame')
local inventory = require('core/inventory')
local keyitems  = require('core/keyitems')
local kills     = require('core/kills')
local pskills   = require('core/skills')
local steps = require('core/steps')
local notify    = require('core/notify')
local markers   = require('render/markers')
local project   = require('render/project')

-- ---------------------------------------------------------------------------
-- Settings
-- ---------------------------------------------------------------------------

local defaults = {
    enabled       = true,
    max_markers   = 16,
    icon_size     = 60,     -- px at ref_distance; tuned in game
    --[[ Scale markers by distance so they read as objects in the world rather
         than as a flat HUD overlay. icon_size is then the size at
         ref_distance yalms. See markers.size_at(). ]]
    perspective   = true,
    ref_distance  = 8,
    px_min        = 10,
    -- 3x icon_size, so the 1/depth curve still works at conversation range;
    -- at 96 it would have clamped from 5 yalms inward.
    px_max        = 180,
    max_distance  = 50,
    floor_tol     = 6,
    -- 2.3 measured in game as the value that sits correctly across races
    head_offset   = 2.3,
    size_scale    = 1.0,    -- 0 disables per-NPC (race-based) height scaling
    --[[ Real latency, measured at one frame of camera movement while panning.
         Measured under prerender; the `hook` note below says how to re-measure
         it under postrender, which is now the default. ]]
    lag           = 1.0,
    smooth        = 0.3,    -- low-pass on that correction; tuned in game
    --[[ Which hook draws the markers: 'prerender' or 'postrender'.

         postrender, because prerender was measurably the wrong sampling point.
         Measured 2026-08-02 against the game's own nameplate: at rest the
         marker sat +0.3 px off, so the projection maths is exact; while panning
         it trailed by exactly one frame of camera movement, predicted vs
         measured within 0.8 px over six frames.

         postrender also removes the shimmer on long steady pans, and that is
         the tell: steady velocity is the easy case for the estimator, so the
         noise is not the estimator's fault. A prerender read lands either side
         of the client's own camera update, giving the odd double-movement or
         zero-movement frame. The filters (corroboration, time normalisation,
         min-magnitude, asymmetric decay) still help at a deceleration but are
         not load-bearing.

         To re-check whether `lag` still earns its keep under postrender, set
         `//qm lag 0` and pan hard. Glued to the nameplate means the sampling
         point was the whole problem and the compensation is pure cost; still
         trailing, then catching up at the stop, means the prim overlay is
         itself a frame behind and lag has a job. Overshoot after a sudden stop
         stays either way, because extrapolation assumes the camera keeps
         moving.

         Kept as a runtime switch so the A/B is one command: it has to be the
         same pan twice, and a reload loses marker state. ]]
    hook          = 'postrender',
    scan_interval = 0.5,
    -- Only mark NPCs the client has actually spawned; see scan().
    visible_only  = true,
    --[[ Repeatables split by category (300 repeatable quests vs 11 repeatable
         missions) so either can be silenced without losing the other.

         Named `repeat_quest` rather than `repeat` deliberately: an existing
         settings.xml pins whatever it already holds, so reusing the old key
         would leave anyone who ever toggled it stuck on their old value. A
         NEW key picks up this default. `//qm show repeat` still works as an
         alias. See the note on defaults above. ]]
    show = {
        turnin = true, progress = true, ready = true,
        unknown = true, blocked = true,
        repeat_quest = true, repeat_mission = true,
    },
    -- announce newly-actionable quests in chat
    notify        = true,
    notify_detail = 6,      -- name them individually up to this many
    --[[ Hide markers while a menu or dialogue box is open. See menu_is_open()
         -- it refuses to act on the flag until it has seen it read false once,
         so an unexpected meaning leaves the addon exactly as it was rather than
         blanking it. A NEW key, so the default reaches existing users. ]]
    hide_on_menu  = true,
    --[[ Follow a quest along its steps instead of pinning the marker to the
         giver. A NEW key on purpose: once a key exists in settings.xml the
         saved value wins forever, so reusing an old one would leave anyone who
         had ever toggled it stuck on it. New keys take the default.

         //qm steps off reproduces the pre-steps behaviour exactly, so the
         feature is A/B-testable in game against the same data file. ]]
    steps         = true,
    --[[ Fame is PER CHARACTER, so it is keyed by character name rather than
         relying on the config library's own per-character merge. Explicit
         keying is easier to reason about and survives however config chooses
         to section the XML. ]]
    fame_by_char = {},
}

local settings = config.load(defaults)

-- ---------------------------------------------------------------------------
-- Runtime
-- ---------------------------------------------------------------------------

local candidates = {}       -- {index, name, x, y, z, state}
local scan_filtered         -- what the last scan discarded, for //qm diag
local wanted = nil          -- npc key set for the current zone
local cur_zone = nil
local last_scan = 0
local dirty_state = true    -- marker states need recomputing
--[[ An item packet arrived. Deliberately NOT `dirty_state` directly: see the
     0x01F/0x020 handler. The scan tick converts it, which coalesces a gear
     swap's worth of packets into one re-evaluation. ]]
local inv_dirty = false
local rebuild_pending = false
local index_ok = false
--[[ `frames` and `blank` are COUNTS, not timings, and both are reported by
     `//qm diag` and `//qm perf`. `blank` is a frame on which markers.render()
     returned nil -- the camera refused, so every marker was hidden. Counted on
     this side of the call as well as inside project, because "how many frames
     did the player see nothing on" is the question a bug report actually asks,
     and a per-frame timing next to a zero drawn count cannot answer it. ]]
local perf = {scan = 0, eval = 0, render = 0, frames = 0, blank = 0}

local MODE_MESSAGE = 150    -- chat mode for NPC dialogue text

--[[ Output helpers.

     Everything diagnostic goes to BOTH the chat log and questmarks.log in the
     addon directory. In-game chat cannot be copied out, so without a file
     there is no way to report what the addon actually saw -- which makes any
     bug report a game of telephone. `//qm diag` dumps the whole picture in one
     go for exactly that reason. ]]
local LOGFILE = 'questmarks.log'

local function fmt(f, ...)
    if select('#', ...) == 0 then return tostring(f) end
    local ok, s = pcall(string.format, f, ...)
    return ok and s or tostring(f)
end

local function msg(f, ...)
    local s = fmt(f, ...)
    windower.add_to_chat(207, 'questmarks: ' .. s)
    flog(LOGFILE, s)
end

-- Indented detail line, for multi-line command output.
local function line(f, ...)
    local s = fmt(f, ...)
    windower.add_to_chat(207, '   ' .. s)
    flog(LOGFILE, '   ' .. s)
end

local function err(f, ...)
    local s = fmt(f, ...)
    windower.add_to_chat(167, 'questmarks: ' .. s)
    flog(LOGFILE, 'ERROR: ' .. s)
end

local function log_only(f, ...)
    flog(LOGFILE, fmt(f, ...))
end

--[[ Declared HERE, far above menu_is_open() which is the only thing that
     reasons about it, because the `login` handler resets it and is written
     earlier in the file. A `local` below a function that assigns the same name
     does not scope it -- the assignment silently becomes a global while every
     reader keeps using the local, so the reset compiles, runs, and does
     nothing. No test catches this: the file parses either way. ]]
local menu_seen_closed = false

--[[ Render circuit breaker: three consecutive throws out of markers.render
     stop the renderer. Drawing nothing beats drawing somewhere wrong.

     Do NOT stop it by setting `settings.enabled = false`. That key is persisted
     to data/settings.xml by thirteen `settings:save()` calls, so three unlucky
     frames would disable every marker on disk with no way back: render_frame()
     returns on its first line when `enabled` is false, so the
     `render_errors = 0` reset at the bottom is unreachable. `render_halted` is
     the latch instead: runtime only, never saved, cleared by `//qm on` /
     `//qm toggle` and by `login`, reported by `//qm diag`.

     Declared up here beside menu_seen_closed because `login` assigns both and
     is written earlier. A `local` below a function that assigns the same name
     does not scope it; the assignment silently becomes a global. ]]
local render_errors = 0
local render_halted = false

-- ---------------------------------------------------------------------------
-- res/ name lookups -- DISPLAY ONLY
-- ---------------------------------------------------------------------------

--[[ Turn an id into the name a human recognises: zones, and the environment
     fields `//qm diag` reports.

     Nothing in the marker path depends on any of this. The index carries ids
     because ids are what packets and the entity list speak; a name is only
     ever needed to print a line -- "step 3/6, Etteh Sulaej (F-4)" is unreadable
     without the city.

     Read straight out of Windower's own res/*.lua rather than through
     `require('resources')`: that library pulls in functions, tables, sets,
     strings and bit, and monkeypatches the base string and table metatables,
     which is a large blast radius for a lookup table. loadfile on a plain data
     file touches nothing.

     Every res table shipped with Windower has the same shape -- `[id] = {id=,
     en=, ...}` -- verified for zones, days, weather and moon_phases in this
     install, so one reader covers all four.

     Lazy, cached, and pcall'd end to end: a missing or changed res file
     degrades to printing the raw id, never to a failed command. res/ is
     Windower's own directory and not another addon, so this does not weaken
     the standalone guarantee NOTICE makes. ]]
local res_cache = {}
local function res_name(file, id)
    if type(id) ~= 'number' then return nil end
    local t = res_cache[file]
    if t == nil then
        t = {}
        res_cache[file] = t
        pcall(function()
            local chunk = loadfile(windower.windower_path .. 'res/' .. file .. '.lua')
            if not chunk then return end
            local raw = chunk()
            if type(raw) ~= 'table' then return end
            for k, v in pairs(raw) do
                local n = type(v) == 'table' and v.en or v
                if type(k) == 'number' and type(n) == 'string' then t[k] = n end
            end
        end)
    end
    return t[id]
end

local function zone_name(id) return res_name('zones', id) end

--[[ `id (Name)`, or just the value when it is not an id we can resolve. Used
     for the environment line, where the RAW value matters as much as the name:
     the types get_info() returns for day / weather / moon_phase are documented
     nowhere and no addon in this install reads them, so the point of printing
     them is to find out. ]]
local function res_label(file, v)
    local n = res_name(file, v)
    if n then return ('%s (%s)'):format(tostring(v), n) end
    return ('%s [%s]'):format(tostring(v), type(v))
end

-- ---------------------------------------------------------------------------
-- Fame persistence (per character)
-- ---------------------------------------------------------------------------

--[[ Push settings into the renderer.

     MUST be re-run on login, not only at addon load. Windower's config library
     chooses the per-character section using windower.ffxi.get_player(), which
     is not available while the addon loads at the character-select screen --
     so at load time `settings` holds the GLOBAL values, and any per-character
     override silently does not apply. That is true of every per-character
     setting, not just one. ]]
local function apply_settings()
    markers.config{
        max_markers  = settings.max_markers,
        icon_size    = settings.icon_size,
        max_distance = settings.max_distance,
        floor_tol    = settings.floor_tol,
        head_offset  = settings.head_offset,
        size_scale   = settings.size_scale,
        perspective  = settings.perspective,
        ref_distance = settings.ref_distance,
        px_min       = settings.px_min,
        px_max       = settings.px_max,
    }
    project.set_lag(settings.lag)
    project.set_smooth(settings.smooth)
    --[[ Per-character, like everything else here: apply_settings runs at load,
         at login and at a mid-session reload, because the config library cannot
         pick the right section until a player exists. ]]
    steps.enable(settings.steps ~= false)
end

local function fame_key()
    local ok, p = pcall(windower.ffxi.get_player)
    return (ok and p and p.name or 'unknown'):lower()
end

--[[ Push the player's main job and level into prereq, which must stay free of
     any client call so it can be tested offline.

     Both stay nil until a player exists (the addon usually loads at character
     select), and nil means UNKNOWN, not "fails the gate" -- otherwise every
     job-locked quest would grey out on sight. Refreshed on the same events
     that already refresh state, since changing job is a job-change packet away
     and 88 quests in the index care. ]]
--[[ ...and `skills`.

     get_player() returns about 30 fields. Do not assume the two read here are
     all it offers: one quest in the corpus is flagged
     `craft_rank_gate_unmodelled` for want of a craft rank.

     The shape of `skills` is documented nowhere and no addon in this install
     reads it, so core/skills.lua IDENTIFIES it against packet 0x062 rather than
     assuming one -- and an unidentified shape simply leaves the packet
     authoritative. Handing it over costs one table walk on events that were
     already happening. ]]
local function refresh_player()
    local ok, p = pcall(windower.ffxi.get_player)
    if not ok or not p then
        prereq.set_player(nil, nil)
        pcall(pskills.observe, nil)
        return
    end
    local job = p.main_job
    prereq.set_player(job, p.main_job_level)
    pcall(pskills.observe, p.skills)
end

--[[ Persist immediately, never only on unload.

     Two reasons. config.save() silently does nothing while logged out
     (config.lua:330), so an unload during logout would drop the data. And a
     crash or a Windower restart never fires unload at all. Fame is expensive
     to re-acquire -- it means physically running to Norg or Rabao -- so it is
     written the moment it is learned. ]]
local function save_fame()
    settings.fame_by_char = settings.fame_by_char or {}
    settings.fame_by_char[fame_key()] = fame.export()
    local ok, e = pcall(function() settings:save() end)
    if not ok then log_only('fame save failed: %s', tostring(e)) end
end

local function load_fame()
    fame.reset()
    local t = (settings.fame_by_char or {})[fame_key()]
    if t then fame.import(t) end
    local n = 0
    for _ in pairs((t or {}).learned or {}) do n = n + 1 end
    for _ in pairs((t or {}).manual or {}) do n = n + 1 end
    return n
end

-- ---------------------------------------------------------------------------
-- Candidate scanning
-- ---------------------------------------------------------------------------

--[[ Resolve which nearby entities are quest givers.

     Uses get_mob_list() (index -> name, whole zone) to find candidate indices,
     then get_mob_by_index() only for those. The probe measured 480 entries in
     get_mob_list against 54 in get_mob_array, so this is both cheaper AND sees
     more of the zone. Entities the client has not spawned simply have no
     position, which doubles as free render-gating. ]]
-- `dead` starts at 0 rather than springing into existence on the first corpse,
-- so //qm diag can print it unconditionally. See the corpse filter below.
scan_filtered = {hidden = 0, duplicate = 0, dead = 0, ghosts = {}}

local function scan()
    local t0 = os.clock()
    candidates = {}
    scan_filtered = {hidden = 0, duplicate = 0, dead = 0, ghosts = {}}
    if not wanted then return end

    local ok, list = pcall(windower.ffxi.get_mob_list)
    if not ok or type(list) ~= 'table' then return end

    local me = windower.ffxi.get_mob_by_target('me')

    --[[ FFXI keeps spare entity slots for conditionally-visible NPCs (cutscene
         copies, quest-state variants, seasonal versions), so one zone can hold
         several entities with the same name while only one is rendered.
         Marking them all puts markers over empty air. Two filters, in order:

         1. visible_only (default on). `valid_target` tracks whether the client
            has the entity spawned: false at range, true as you approach. So
            markers fade in and out with their NPCs, and lone ghosts go with
            them. The cost is deliberate: nothing is marked before the client
            spawns it, even inside `//qm dist`. `//qm visible off` marks every
            entity in range instead.

         2. Dedup by name: one per name, targetable first, then nearest. You
            can only talk to one copy, so marking more is always wrong.

         No documented "is rendered" flag exists, and `status`/`spawn_type`
         measured identical (0 and 2) for real NPCs and ghosts alike.
         `//qm dump <npc>` prints every field of every copy. ]]
    local best = {}
    for idx, name in pairs(list) do
        local want = type(name) == 'string' and wanted[quests.fold(name)]
        if want then
            local ok2, m = pcall(windower.ffxi.get_mob_by_index, idx)
            if ok2 and m and m.x then
                local targetable = m.valid_target and true or false
                --[[ MONSTERS are marker targets too, and they need the opposite
                     of the NPC rules.

                     Duplicate NPCs are ghost entity slots -- spare copies the
                     client keeps for conditionally-visible NPCs -- so only the
                     nearest may be marked. Duplicate MONSTERS are all real and
                     all valid: thirty Topaz Quadav is thirty things you can
                     legitimately kill for the drop, and collapsing them to one
                     would hide the other twenty-nine.

                     A corpse is not a target though. res/statuses.lua: 2 = Dead,
                     3 = Engaged dead. ]]
                local is_mob = (want == 'mob')
                local dead = is_mob and (m.status == 2 or m.status == 3)
                if dead then
                    scan_filtered.dead = (scan_filtered.dead or 0) + 1
                elseif settings.visible_only and not targetable then
                    scan_filtered.hidden = scan_filtered.hidden + 1
                else
                    local key = quests.fold(name)
                    local d2 = math.huge
                    if me and me.x then
                        local dx, dy, dz = m.x - me.x, m.y - me.y, m.z - me.z
                        d2 = dx*dx + dy*dy + dz*dz
                    end
                    local cand = {index = idx, name = name, x = m.x, y = m.y,
                                  z = m.z, d2 = d2, targetable = targetable,
                                  -- drives per-NPC marker height
                                  model_size = m.model_size, race = m.race}

                    --[[ A monster gets its OWN slot per entity index, so all
                         of them survive; an NPC key collapses to the nearest
                         copy as before. ]]
                    if is_mob then key = key .. '#' .. tostring(idx) end
                    cand.mob = is_mob or nil

                    local prev = best[key]
                    if not prev then
                        best[key] = cand
                    else
                        scan_filtered.duplicate = scan_filtered.duplicate + 1
                        local better = (cand.targetable ~= prev.targetable)
                            and cand.targetable
                            or (cand.targetable == prev.targetable and cand.d2 < prev.d2)
                        if #scan_filtered.ghosts < 12 then
                            local drop = better and prev or cand
                            scan_filtered.ghosts[#scan_filtered.ghosts + 1] =
                                ('%s: kept idx=%d, dropped idx=%d (targetable=%s d=%.1f)')
                                :format(name, better and cand.index or prev.index,
                                        drop.index, tostring(drop.targetable),
                                        math.sqrt(drop.d2))
                        end
                        if better then best[key] = cand end
                    end
                end
            end
        end
    end

    --[[ Truncate by distance, not by hash order.

         An unordered `pairs()` walk with a hard break at 64 lets the hash
         decide which 64 of an over-full set survive, so two scans from the same
         spot can keep different markers -- in the one place that decides what
         the player sees.

         The cap is reachable: 72 monster names are zone-agnostic, so every zone
         can reach it, and a monster takes one slot per live entity. A field
         full of `carrion crow` fills it single-handed.

         Sorting by distance first keeps the 64 nearest, which is deterministic
         and also the right 64; the marker budget in render/markers.lua settles
         it the same way. The tie-break is spelled out because table.sort is not
         stable and the input order here is arbitrary.

         This still does not say whether a live zone ever holds more than 64
         spawned wanted entities. It only makes the answer repeatable. ]]
    local n = 0
    for _, c in pairs(best) do
        n = n + 1
        candidates[n] = c
    end
    table.sort(candidates, function(a, b)
        if a.d2 ~= b.d2 then return a.d2 < b.d2 end
        if a.name ~= b.name then return a.name < b.name end
        return (a.index or 0) < (b.index or 0)
    end)
    for i = n, 65, -1 do candidates[i] = nil end

    dirty_state = true
    perf.scan = (os.clock() - t0) * 1000
end

--[[ Should this marker state be drawn for this category?
     Only `repeat` splits by category -- see the note on defaults.show. ]]
local function shown(st, cat)
    if st == 'repeat' then
        local key = (cat == 'mission') and 'repeat_mission' or 'repeat_quest'
        return settings.show[key] ~= false
    end
    return settings.show[st] and true or false
end

--[[ Recompute marker states. Event-driven in the sense that matters: every
     caller sets `dirty_state` and render_frame consumes it once per frame, so
     a frame on which nothing changed does none of this work. It is still the
     frame loop that calls it, so keep it cheap. ]]
local function evaluate()
    local t0 = os.clock()
    inventory.refresh()
    for i = 1, #candidates do
        local c = candidates[i]
        local st, count, _, cat, area, hint = quests.marker_for(c.name, cur_zone)
        if st and shown(st, cat) then
            c.state, c.count, c.cat, c.area, c.hint = st, count, cat, area, hint
        else
            c.state, c.count, c.cat, c.area, c.hint = nil, 0, nil, nil, nil
        end
    end
    dirty_state = false
    perf.eval = (os.clock() - t0) * 1000
end

--[[ Announce that something became actionable, anywhere in the world -- as ONE
     line. Silent on the first snapshot after login; see core/notify.

     Do not print the whole batch here, grouped by zone or otherwise. The list
     grows without bound: every fame level and every completed quest can unlock
     content across the whole game, and dumping all of it floods the chat window
     at exactly the moment you are reading something else. Grouping by zone also
     has to cope with entries whose zone does not resolve.

     The batch is still computed on every settle, so `//qm new` lists it on
     demand. This line exists only so you know there is something to list. ]]
local function report_new()
    if not settings.notify or not index_ok then return end

    local ok, gained = pcall(notify.update, quests)
    if not ok or #gained == 0 then return end

    msg('%d newly available -- //qm new to list', #gained)
end

-- Debounced: the 0x056 burst arrives as ~27 packets on every zone-in.
local function schedule_rebuild()
    if rebuild_pending then return end
    rebuild_pending = true
    coroutine.schedule(function()
        rebuild_pending = false
        --[[ Protected as a whole. Unprotected, one bad entry takes the entire
             callback down: a raw Lua error in chat, and everything below it --
             including the zone-start announcement -- silently skipped.

             err() also writes to questmarks.log, so a failure here can be read
             back instead of being chased in a chat window that scrolls. ]]
        local ok, e = pcall(function()
            refresh_player()
            quests.rebuild_fame_floors()
            --[[ A quest that stopped being in progress has no step position;
                 keeping its high-water mark would resurrect a stale one if it
                 were ever repeated. Walks the latch table, not the index. ]]
            steps.on_state_change()
            --[[ Which monsters are worth counting changed with the quest log.
                 Recomputed here rather than per packet: 0x028 is a firehose and
                 core/kills refuses to even parse one while this set is empty. ]]
            kills.set_watch(quests.watched_mobs())
            dirty_state = true
            scan()
            report_new()

            --[[ Some quests are started by entering a zone, with no NPC to mark.
                 This is the only way the addon can surface them at all. ]]
            if settings.notify and cur_zone then
                local zs = quests.zone_starts(cur_zone)
                if zs then
                    --[[ Call a mission a mission. 47 of the 49 zone-triggered
                         entries in the index are missions, so "quest(s)" for
                         everything is wrong for nearly all of them.

                         The distinction is not pedantry here. Missions are the
                         storyline, they are why the renderer colours them
                         differently, and a player told a mission is a side
                         quest may leave it for later. ]]
                    local nq, nm = 0, 0
                    for _, z in ipairs(zs) do
                        if z.entry.cat == 'mission' then nm = nm + 1
                        else nq = nq + 1 end
                    end
                    local what
                    if nq > 0 and nm > 0 then
                        what = ('%d quest(s) and %d mission(s)'):format(nq, nm)
                    elseif nm > 0 then
                        what = ('%d mission(s)'):format(nm)
                    else
                        what = ('%d quest(s)'):format(nq)
                    end
                    msg('entering this zone starts %s:', what)
                    for _, z in ipairs(zs) do
                        line('%s%s', z.name or '?',
                             z.entry.cat == 'mission' and '   [mission]' or '')
                    end
                end
            end
        end)
        if not ok then err('state update failed: %s', tostring(e)) end
    end, 2)
end

-- ---------------------------------------------------------------------------
-- Events
-- ---------------------------------------------------------------------------

windower.register_event('incoming chunk', function(id, original)
    if id == 0x056 then
        local ok, p = pcall(packets.parse, 'incoming', original)
        if ok and p then
            if state.handle_packet(p) then schedule_rebuild() end
        end
    elseif id == 0x055 then
        --[[ 0x055 is a KEY ITEM update and says nothing about your bags. Do not
             use it as a bare "re-sweep everything" ping: it carries the answer
             itself, in two 512-bit fields, one for held and one for examined.
             See core/keyitems.lua, which is deliberately information-only until
             its id stride has been checked against get_key_items(). ]]
        local ok, p = pcall(packets.parse, 'incoming', original)
        if ok and p then pcall(keyitems.handle_packet, p) end
        inventory.invalidate_key_items()
        dirty_state = true

    elseif id == 0x028 and kills.watching() then
        --[[ Combat. The ONLY reason to look at it: "defeat 5 Nasu" is a step
             the player cannot check their own progress on, and no packet
             carries a per-quest kill counter. Counted session-locally and shown
             only -- see core/kills.lua, which is emphatic that this never
             advances a step.

             `kills.watching()` is in the CONDITION, not inside the handler.
             This packet arrives for every action of every fight in the zone,
             and parse_action on all of it would be the most expensive thing
             the addon does -- so with no monster-step quest accepted, which is
             the normal case, the packet is not even parsed.

             `dirty_state` is deliberately NOT set either: a marker must not
             re-evaluate on every hit in a fight. ]]
        local ok, a = pcall(windower.packets.parse_action, original)
        if ok and a then pcall(kills.handle_action, a) end

    elseif id == 0x01F or id == 0x020 then
        --[[ 'Item Assign' and 'Item Updates' (fields.lua:1683 and :1692). Both
             carry Item, Bag, Index and a `Status` byte -- the same itemstat
             enum whose 0x05 means Equipped -- so this is how the client says
             an item appeared, disappeared, or was put on.

             This is the only event that fires when you equip a weapon or pick
             up a turn-in item. 0x055, 0x056, zone change, login and fame do
             not, so without it a marker believes the last sweep until you zone
             and an equipment-dependent entry reads grey with no way to tell why.

             Debounced via the scan tick rather than setting dirty_state here.
             0x020 is not rare -- a full gear swap is a burst of them, and a
             synthesis or a treasure pool can produce a sustained stream -- and
             each one forces the next sweep past its rate limit. Coalescing to
             the scan interval bounds that to twice a second whatever the packet
             rate. ]]
        inventory.invalidate()
        inv_dirty = true

    elseif id == 0x02D then
        --[[ The one exact count the game hands over -- message 558 with its own
             numerator and denominator. Parsed rather than pattern-matched out
             of chat text. ]]
        local ok, p = pcall(packets.parse, 'incoming', original)
        if ok and p then pcall(kills.handle_message, p) end

    elseif id == 0x062 then
        --[[ 'Skills Update' -- 48 combat entries at 0x80 and the ten Synthesis
             ones at 0xE0, each a 16-bit word. This is where a craft RANK comes
             from, and `Indomitable Spirit` needs one: the quest does not exist
             in your log until you buy a key item that requires Fishing rank
             Adept.

             Handed the RAW chunk, not a parsed table. `packets.parse` never
             applies a field's `fn` (paid for once already, in
             core/keyitems.lua), and this packet is described with `ref=` /
             `count=` structures whose handling would have to be trusted. The
             byte layout is unambiguous, so core/skills.lua reads it directly
             and depends on none of that.

             `dirty_state` only on a real change: 0x062 arrives on every skill
             tick while crafting or fighting, and re-evaluating the whole index
             on each one would be the 0x028 firehose again. ]]
        local ok, changed = pcall(pskills.handle_chunk, original)
        if ok and changed then
            --[[ A skill-up may have just identified the shape of
                 get_player().skills, so re-offer it. Cheap, and it means the
                 experiment is not confined to the login path. ]]
            refresh_player()
            dirty_state = true
        end

    elseif id == 0x113 then
        --[[ 'Currency Info' -- conquest points, seals, and NINE guild-point
             counters at 0x20 in res/skills.lua id order. The other half of
             `Indomitable Spirit`: 95,000 Guild Points AND Fishing rank Adept.

             Guild points are easy to miss: a grep for them turns up only guild
             SHOP packets, so they look unobservable. They are at
             fields.lua:3855. ]]
        local ok, changed = pcall(pskills.handle_currency, original)
        if ok and changed then dirty_state = true end
    end
end)

--[[ Fame learning. The client has already rendered the text (DAT lookup, name
     and gender substitution done), so this is the real string the player sees. ]]
windower.register_event('incoming text', function(original, modified, mode)
    if mode ~= MODE_MESSAGE then return end
    local ok, decoded = pcall(windower.from_shift_jis, original)
    if not ok then return end

    local info = windower.ffxi.get_info()
    local region, level, changed = fame.observe(decoded, info and info.zone)
    if region and changed then
        msg('learned %s fame level %d (saved)', region, level)
        save_fame()
        dirty_state = true
        -- A fame level can unlock quests all over the world.
        coroutine.schedule(report_new, 1)
    end
end)

windower.register_event('zone change', function(new_id)
    cur_zone = new_id
    candidates = {}
    wanted = index_ok and quests.wanted_names(new_id) or nil
    markers.hide_all()
    markers.reset_vertical_sign()
    inventory.invalidate()
    dirty_state = true
    last_scan = 0
end)

windower.register_event('login', function()
    state.reset()
    notify.reset()
    inventory.reset()
    -- The bitfields describe one character's key items.
    keyitems.reset()
    -- ...and the kill tally describes one character's session.
    kills.reset()
    --[[ ...and skills describe ONE character. Carrying a Fishing rank across a
         character switch would grey or clear a craft gate on somebody else's
         numbers, and the identified shape of get_player().skills is an
         inference, which by this project's central rule may not outlive a
         logout. Both start empty; the packet re-arrives at login. ]]
    pskills.reset()
    -- The step high-water mark describes ONE character's session.
    steps.reset()
    markers.reset_vertical_sign()
    --[[ The menu flag is only trusted once it has been seen false, and login
         is where that evidence should start over: the character-select screen
         is exactly the state in which a flag could look stuck. ]]
    menu_seen_closed = false
    --[[ ...and so is the render circuit breaker. It latches a runtime fault,
         not a preference, so a new session must not inherit it. The latch is
         runtime only, so there is nothing on disk to undo. ]]
    render_halted, render_errors = false, 0

    --[[ Only now does the config library know which character it is, so this
         is the first moment per-character settings are actually correct.
         Re-apply them; see apply_settings(). ]]
    apply_settings()
    if markers.settings().max_markers ~= nil then
        markers.init(settings.max_markers)
    end

    local n = load_fame()
    if n > 0 then msg('restored %d saved fame reading(s)', n) end
    -- Job and level gate 88 quests; until this runs they read UNKNOWN, not
    -- blocked, so the worst case before it is a black "!" rather than a hidden
    -- marker.
    refresh_player()
    dirty_state = true
end)

windower.register_event('logout', function()
    state.reset()
    notify.reset()          -- next login must not announce the whole game
    steps.reset()           -- ... and must not inherit the last one's progress

    --[[ Reset inferences at BOTH ends of a session.

         Between logout and the next character finishing login, the kill tally,
         the bag cache, the key-item bitfields and the identified craft ranks
         would otherwise still be answering about somebody else. The client is
         not obliged to deliver both events (a crash or an alt-F4 delivers
         neither), so whichever one arrives has to leave nothing inferred
         behind it.

         `fame` is deliberately absent, and a blanket "reset everything" would
         break it. Fame readings are observations: saved per character the
         moment they are learned, reloaded by `login`, and expensive to
         re-acquire, since it means physically running to Norg or Rabao. Worse,
         save_fame() in the unload handler writes the in-memory table straight
         back to disk, so resetting fame here would erase the saved readings
         too. A relog keeps what was measured and forgets what was guessed. ]]
    inventory.reset()
    keyitems.reset()
    kills.reset()
    pskills.reset()
    --[[ The menu flag is trusted only once it has been observed FALSE; the next
         character must earn that again rather than inherit it, for the same
         reason `login` clears it. ]]
    menu_seen_closed = false

    candidates = {}
    markers.hide_all()
end)

for _, ev in ipairs({'add item', 'remove item'}) do
    windower.register_event(ev, function()
        inventory.invalidate()
        dirty_state = true
    end)
end

--[[ Changing job re-decides 88 job-locked quests -- the whole
     `Borghertz's ... Hands` set sits on one NPC, one per job. ]]
windower.register_event('job change', function()
    refresh_player()
    dirty_state = true
end)

--[[ Suppress markers while a menu or dialogue box covers the world; markers
     over an open dialogue box are the most visible way a 3D overlay breaks.

     `get_info().menu_open` exists here: the contiguous key block in
     plugins/LuaCore.dll gives all thirteen keys (day, moon, moon_phase, time,
     zone, logged_in, server, weather, mog_house, language, menu_open,
     chat_open, target_arrow). Its type and meaning are documented nowhere and
     no addon here reads it, so two guards:

     1. `if info.menu_open then` is wrong on its face. In Lua 0 is truthy, so a
        count of open menus would hide every marker forever. Handle each
        plausible shape; an unknown one never suppresses.

     2. Don't trust the flag until it has read false once since login. If it
        really means "the menu bar exists", the addon would draw nothing with
        no clue why. A real flag earns trust on the first frame you walk
        around; a constant never does, so the feature stays inert instead.

     `//qm probe` prints the live value and its type. `menu_seen_closed` is
     declared near the top of the file, beside the output helpers. ]]
local function menu_is_open(info)
    local v = info and info.menu_open
    local open
    if v == nil or v == false then open = false
    elseif v == true then open = true
    elseif type(v) == 'number' then open = (v ~= 0)
    elseif type(v) == 'string' then open = (v ~= '' and v ~= '0')
    else return false end                    -- unknown shape: never suppress

    if not open then
        menu_seen_closed = true
        return false
    end
    return menu_seen_closed
end

local function render_frame()
    -- `render_halted` is the circuit breaker, `settings.enabled` is the player;
    -- deliberately two flags, because only one of them is persisted.
    if not settings.enabled or render_halted or not index_ok then return end

    --[[ Sampled per frame rather than per scan tick: a dialogue box opens
         between ticks, and half a second of markers floating over it is the
         exact artefact this removes. One extra get_info() per frame beside the
         get_mob_by_target('me') that already runs there. ]]
    local info = windower.ffxi.get_info()
    if settings.hide_on_menu and menu_is_open(info) then
        markers.hide_all()
        return
    end

    local now = os.clock()
    if now - last_scan > settings.scan_interval then
        last_scan = now
        -- Item traffic since the last tick, collapsed into one re-evaluation.
        if inv_dirty then
            inv_dirty = false
            dirty_state = true
        end
        if info then
            -- A Mog House is not its own zone; the client reports the
            -- surrounding city and flags it here.
            quests.set_mog_house(info.mog_house)
            if info.zone ~= cur_zone then
                cur_zone = info.zone
                wanted = quests.wanted_names(cur_zone)
            end
        end
        scan()
    end
    if dirty_state then evaluate() end

    local me = windower.ffxi.get_mob_by_target('me')
    if not me or not me.x then markers.hide_all() return end

    local drawable, n = {}, 0
    for i = 1, #candidates do
        local c = candidates[i]
        if c.state then n = n + 1; drawable[n] = c end
    end
    if n == 0 then markers.hide_all() return end

    markers.ensure_vertical_sign(drawable[1].x, drawable[1].y, drawable[1].z)

    local t0 = os.clock()
    local ok, res = pcall(markers.render, drawable, me)
    perf.render = (os.clock() - t0) * 1000
    perf.frames = perf.frames + 1

    if not ok then
        render_errors = render_errors + 1
        if render_errors >= 3 then
            --[[ HALT, do not disable. `settings.enabled` is the player's own
                 switch and is written to disk; this fault is neither theirs nor
                 durable. Zero the counter on the way in so that whatever
                 resumes -- //qm on, or the next login -- starts from a clean
                 slate instead of one bad frame away from halting again. ]]
            render_halted = true
            render_errors = 0
            markers.hide_all()
            err('render failed 3x, markers HALTED. Last error: %s', tostring(res))
            err('nothing was saved -- //qm on resumes, //qm diag reports it.')
        end
    else
        --[[ One good frame stops an intermittent throw accumulating toward the
             breaker. This line is only reachable because the halt is a separate
             flag from `settings.enabled`; halting via `enabled` would make it
             dead code and the latch would never clear. ]]
        render_errors = 0
        --[[ A nil result is NOT a failure: markers.render returns nil when
             project.begin() refused the camera, having already hidden
             everything. It is not an error to count against the breaker -- a
             cutscene would trip it -- but it is a frame the player saw no
             markers on, so it is counted rather than discarded. ]]
        if res == nil then perf.blank = perf.blank + 1 end
    end
end

--[[ Both hooks are registered; `settings.hook` decides which one draws.

     Gating here rather than registering and unregistering means the switch is
     a single flag with no lifecycle to get wrong, and the inactive hook costs
     one string compare per frame. project.begin() -- which is what ages the
     matrix history -- is only reached from markers.render(), so the dormant
     hook cannot pollute the velocity estimate. ]]
windower.register_event('prerender', function()
    if settings.hook ~= 'postrender' then render_frame() end
end)

windower.register_event('postrender', function()
    if settings.hook == 'postrender' then render_frame() end
end)

windower.register_event('unload', function()
    --[[ Non-negotiable: prims are named global objects and orphaned ones stay
         on screen until Windower restarts. ]]
    markers.destroy()
    -- Best effort only; the authoritative save happens when fame is learned.
    pcall(save_fame)
end)

-- ---------------------------------------------------------------------------
-- Commands
-- ---------------------------------------------------------------------------

--[[ Name the colour from the RGB actually used to draw, rather than
     re-deriving it. A second copy of the colour rules drifts out of sync with
     the renderer, and a printed colour that disagrees with the screen is worse
     than none. ]]
local function hue_name(r, g, b)
    local mx = math.max(r, g, b)
    if mx < 70 then return 'black' end
    if math.abs(r - g) < 30 and math.abs(g - b) < 30 then return 'grey' end
    if b > r and b > g then return 'blue' end
    if g > r then return 'green' end
    if r > 200 and g > 150 then return 'yellow' end
    if g > 140 then return 'green' end
    return 'red'
end

local function fmt_state(s, cat, area)
    local glyph, r, g, b = markers.style_for(s, cat, area)
    if not markers.GLYPH[s] then return tostring(s) end
    return ('%s %s %s'):format(hue_name(r, g, b), glyph == 'bang' and '!' or '?', s)
end

--[[ "Zalsuhm, Lower Jeuno (H-9)" from a quests.where_of() result. Each of the
     three parts is independently optional: a step can name a monster with no
     zone, a zone with no grid reference, or nothing at all. ]]
local function fmt_where(w)
    if not w then return '?' end
    local parts = {}
    if w.label then parts[#parts + 1] = w.label end
    local z = w.zone and (zone_name(w.zone) or ('zone ' .. tostring(w.zone)))
    if z then parts[#parts + 1] = z end
    local s = table.concat(parts, ', ')
    if #parts > 0 and w.grid then s = s .. ' (' .. w.grid .. ')' end

    --[[ ...and where the work is, when that is not where the marker is.

         `at_zone` is set only when the current step cannot carry a marker -- a
         '???', or a fight with no monster recorded -- and it answers "where do
         I go" rather than "where is the marker". '???' spots cannot be marked:
         the client names every one of them '???' and one town holds up to
         fifteen. But 327 of the 332 '???' steps know their zone and 274 know
         their map cell, and all of it is already in the index.

         Printed AFTER an arrow, never instead of the marker's location. Those
         are two different facts and collapsing them would trade one confusing
         answer for another. When both are in the same zone only the cell is
         added, because repeating the zone name reads like a second place.

         Computed BEFORE the empty-string bail-out, not after. An empty marker
         half is precisely the "nothing anywhere can be marked" case this exists
         to serve, so bailing out first would blank the row that needs it most. ]]
    if w.at_zone then
        local same = (w.zone ~= nil and w.zone == w.at_zone)
        local az = same and ''
            or (zone_name(w.at_zone) or ('zone ' .. tostring(w.at_zone)))
        local cell = w.at_grid and ('(' .. w.at_grid .. ')') or ''
        local where = (az ~= '' and cell ~= '') and (az .. ' ' .. cell)
            or (az ~= '' and az or cell)
        if where ~= '' then
            --[[ "examine: Yhoator Jungle (H-9)" rather than "examine at ...".
                 `at_kind` is the raw step verb, and `travel at X` / `other at X`
                 read as broken English on the 220 steps that carry those. ]]
            local lead = w.at_kind and (w.at_kind .. ': ') or ''
            s = (s ~= '') and (s .. ' -> ' .. lead .. where)
                or (lead .. where)
        end
    end
    if s == '' then return '?' end
    return s
end

--[[ Everything get_info() returns, raw value and resolved name side by side.

     This exists to measure, not to decorate. `get_info()` returns thirteen
     keys, and game time and weather are among them -- do not assume a field is
     unavailable because nothing here reads it yet.

     So the raw value prints beside the resolved name, and the type beside
     anything that does not resolve: the point is to find out what these fields
     really are in a running client. Time is shown both ways for the same
     reason, the units are documented nowhere and the second reading is
     labelled as the guess it is.

     Feeds `//qm probe` (chat) and `//qm diag` (log). ]]
local function env_lines(head, detail)
    local info = windower.ffxi.get_info()
    if type(info) ~= 'table' then
        head('get_info() returned %s', type(info))
        return
    end
    head('environment, from get_info():')
    detail('zone     %s   mog_house %s   logged_in %s',
           res_label('zones', info.zone), tostring(info.mog_house),
           tostring(info.logged_in))
    detail('day      %s', res_label('days', info.day))
    detail('moon     %s [%s]   phase %s', tostring(info.moon), type(info.moon),
           res_label('moon_phases', info.moon_phase))
    local t = info.time
    detail('time     %s [%s]%s', tostring(t), type(t),
           type(t) == 'number' and (('   = %02d:%02d if it is minutes of the '
               .. 'Vanadiel day'):format(math.floor(t / 60) % 24, t % 60)) or '')
    detail('weather  %s', res_label('weather', info.weather))
    detail('menu_open %s [%s]  trusted=%s   chat_open %s   target_arrow %s',
           tostring(info.menu_open), type(info.menu_open),
           tostring(menu_seen_closed), tostring(info.chat_open),
           type(info.target_arrow))
    detail('server   %s   language %s',
           tostring(info.server), tostring(info.language))

    --[[ The open question about grid references.

         The index carries a map grid cell for most step targets -- "G-11" --
         and the scan throws it away, disambiguating duplicate entities by
         nearest-to-player instead. Several doors in Lower Jeuno are called
         "Door:Merchant's House" and only one of them is in G-11, so the grid
         would be a much stronger signal than distance.

         It needs a world->grid transform, which is per zone. `get_map_data`
         exists in this install (the name is in plugins/LuaCore.dll) and NO
         addon here calls it -- but unlike every other structured getter in that
         binary, it has no block of return-field names beside it, and
         `map_index`, `x_offset`, `map_scale` and `map_id` are absent
         altogether. That is strong evidence it does not hand over calibration,
         and weak evidence is not evidence: this prints whatever it really
         returns so one login settles it instead of another inherited claim. ]]
    local okm, md = pcall(function()
        local f = windower.ffxi.get_map_data
        return f and f() or nil
    end)
    if not okm then
        detail('map_data  call failed: %s', tostring(md))
    elseif type(md) ~= 'table' then
        detail('map_data  %s [%s]', tostring(md), type(md))
    else
        local keys = {}
        for k, v in pairs(md) do
            keys[#keys + 1] = ('%s=%s[%s]'):format(tostring(k), tostring(v), type(v))
        end
        table.sort(keys)
        detail('map_data  %d field(s): %s', #keys,
               #keys > 0 and table.concat(keys, ' ') or '(empty table)')
    end
end

--[[ What packet 0x055 is actually saying, and whether it can be believed.

     This is the measurement the module exists to make. `categories` and
     `max id` settle the open question about the id stride: fields.lua says six
     categories, which reaches id 3071, while res/key_items.lua in this install
     runs to 3381 -- so either the comment is stale or the layout is not what it
     is documented to be. The verdict line answers it from real data instead of
     from a claim. ]]
local function ki_lines(head, detail)
    local s = keyitems.stats()
    if s.packets == 0 then
        head('key item packets (0x055): none seen yet -- zone once')
        return
    end
    head('key item packets (0x055): %d seen, %s', s.packets,
         s.trusted and 'decode AGREES with get_key_items()'
                    or 'decode NOT yet corroborated -- swept list is authoritative')
    detail('categories %s   %d bits each   highest id covered %d',
           table.concat((function()
               local l = {}
               for i, t in ipairs(s.categories) do l[i] = tostring(t) end
               return l
           end)(), ','), s.bits_per_category, s.max_id)
    detail('held %d   examined %d', s.held, s.examined)
    if s.check then
        detail('cross-check: %d agree, %d only in the packet, %d only in the sweep',
               s.check.matched, s.check.only_packet, s.check.only_swept)
    end
end

--[[ What packet 0x062 says, and what get_player().skills actually turned out
     to be. Three things have to show up or the report is useless: whether a
     0x062 has arrived at all (everything reads nil before that, so "unknown"
     must not look like "zero"), the identified shape including the non-answers
     ('ambiguous', 'unrecognised', 'numeric, not yet identified'), and whether
     the test could tell anything apart. A character with every craft at 0 makes
     the raw-word, level and rank readings identical, so no amount of skills
     will separate them. Printing the craft numbers lets you spot that. ]]
local function skill_lines(head, detail)
    local s = pskills.stats()
    if s.packets == 0 then
        head('skills packet (0x062): none seen yet -- it arrives at login and '
             .. 'on a skill change')
    else
        head('skills packet (0x062): %d seen, %d/%d craft and %d/48 combat '
             .. 'skills known', s.packets, s.craft_known, 10, s.combat_known)
        local any = false
        for id = pskills.CRAFT_FIRST, pskills.CRAFT_LAST do
            local c = s.craft[id]
            if c and ((c.rank or 0) > 0 or (c.level or 0) > 0) then
                detail('  skill %d  rank %d  level %d%s', id, c.rank or -1,
                       c.level or -1, c.capped and '  CAPPED' or '')
                any = true
            end
        end
        if not any then
            detail('  every craft reads rank 0 level 0 -- so nothing here can '
                   .. 'tell the candidate readings apart')
        end
        --[[ The combat skills, and this is a measurement rather than a
             decoration: a character with no crafts leaves the craft readings
             unable to tell anything apart, while 48 combat skills sit decoded.

             Two questions it answers. A CAPPED entry is the only place the
             raw-word and level readings of get_player().skills differ, so one
             of those identifies the shape outright. And comparing any line here
             against the same skill in the in-game menu says whether the Level
             field counts whole points or tenths -- which the bit width already
             settles for crafts (bit[10] tops out at 1023 and craft skill reaches
             110, so tenths could not fit) and cannot settle for combat, where
             bit[15] has room for either. ]]
        local shown = 0
        for id = 0, pskills.COMBAT_LAST do
            local c = s.combat[id]
            if c and shown < 8 then
                detail('  combat skill %d  level %d%s', id, c.level,
                       c.capped and '  CAPPED' or '')
                shown = shown + 1
            end
        end
        local n_nz = 0
        for _ in pairs(s.combat) do n_nz = n_nz + 1 end
        if shown == 0 then
            detail('  every combat skill reads level 0 as well')
        else
            --[[ Says when the list was cut short. A capped print that silently
                 stops at eight reads exactly like a character with eight
                 skills, and a number that cannot tell those apart is worse
                 than no number. ]]
            detail('  ...%d combat skill(s) above zero%s, %d capped -- compare '
                   .. 'one against the in-game menu to fix the units',
                   n_nz, (n_nz > shown)
                       and (', first %d shown'):format(shown) or '',
                   s.combat_capped)
        end
    end
    --[[ Guild points, packet 0x113. Printed even at zero known, because "no
         0x113 seen" and "every guild at 0" are different answers and the gate
         treats them differently -- the first is a black "!", the second a
         grey one. ]]
    if s.currency == 0 then
        head('currency packet (0x113): none seen yet -- guild points unknown')
    else
        head('currency packet (0x113): %d seen, %d/9 guild balances known',
             s.currency, s.points_known)
        for id = 48, 56 do
            if (s.points[id] or 0) > 0 then
                detail('  guild %d  %d point(s)', id, s.points[id])
            end
        end
    end
    detail('get_player().skills: %s   %s', tostring(s.shape),
           tostring(s.shape_detail))
    if s.check then
        detail('second-source check: %d skills compared, %d reading(s) still '
               .. 'agree, %d comparison(s) discriminating',
               s.check.tested, s.check.agreed, s.check.discriminating)
    end
    detail('trusted as a second source: %s', tostring(s.player_trusted))
end

local function cmd_fame(a1, a2)
    if not a1 then
        msg('fame levels:')
        for _, r in ipairs(fame.regions()) do
            local lvl, src = fame.get(r)
            local anchors = fame.has_anchors(r) and '' or '  [no checker anchors shipped]'
            line('%-15s %-8s %s%s', r, lvl and tostring(lvl) or 'unknown', src or '', anchors)
        end
        for _, c in ipairs(fame.checkers()) do
            line('checker: %-18s %-10s zone %d', c.npc, c.region, c.zone)
        end
        if #fame.unmatched > 0 then
            msg('unclassified checker lines seen: %d (use //qm fame dump)', #fame.unmatched)
        end
        return
    end

    if a1 == 'dump' then
        if #fame.unmatched == 0 then msg('no unclassified checker lines seen') return end
        for _, u in ipairs(fame.unmatched) do
            line('[%s] %s', u.npc, u.line)
        end
        return
    end

    if a2 == nil then err('usage: //qm fame <region> <0-9|reset>') return end
    if a2 == 'reset' then
        fame.set_manual(a1, nil)
        msg('cleared manual fame for %s', a1)
    else
        local ok, why = fame.set_manual(a1, tonumber(a2))
        if not ok then err('%s', why or 'failed') return end
        msg('%s fame set to %d', a1, tonumber(a2))
    end
    save_fame()
    dirty_state = true
end

local function cmd_why(name)
    if not name then err('usage: //qm why <npc name>') return end

    -- allow the current target as a shortcut
    if name == 't' then
        local t = windower.ffxi.get_mob_by_target('t')
        if not t then err('no target') return end
        name = t.name
    end

    local rows = quests.explain(name, cur_zone)
    if not rows then msg('%q has no indexed quests in this zone', name) return end

    msg('%s -- %d indexed entr%s', name, #rows, #rows == 1 and 'y' or 'ies')
    for _, r in ipairs(rows) do
        line('[%s/%s #%d] %s', r.entry.cat, r.entry.area, r.entry.id, r.name or '?')
        line('  state: %s   marker: %s',
             tostring(r.quest_status),
             r.marker and fmt_state(r.marker, r.entry.cat, r.entry.area) or 'none')
        if r.suppressed then line('  - hidden: %s', r.suppressed) end
        --[[ Without this, an exclusive branch you did not take reads as a bare
             "done" with no marker, which looks identical to a mission you
             genuinely finished -- and identical to a bug. Name the sibling. ]]
        if r.quest_source == 'group' then
            local sib = state.completed_sibling(r.entry.cat, r.entry.area, r.entry.id)
            line('  + completed via "%s", which is the same mission by another '
                 .. 'route -- this branch can never be started',
                 (sib and quests.name_of(r.entry.cat, r.entry.area, sib))
                 or ('#' .. tostring(sib)))
        end
        -- Only report a fame GATE when there is actually a level to meet;
        -- many entries name a region with no threshold, which gates nothing.
        if r.entry.fame and r.entry.fame_lvl and r.entry.fame_lvl > 0 then
            local have, src = fame.get(r.entry.fame)
            line('  fame gate: %s level %d (have %s%s)',
                 r.entry.fame, r.entry.fame_lvl,
                 have and tostring(have) or 'unknown',
                 src and (', ' .. src) or '')
        end
        for _, why in ipairs(r.reasons or {}) do
            local mark = why.ok == true and '+' or (why.ok == false and 'x' or '?')
            line('  %s %s', mark, why.text)
        end
        --[[ The turn-in check, which is the whole answer for an in-progress
             quest. Without it a grey "?" is unreadable: "you are missing 4 of 4
             items" and "this quest can never report readiness" look identical.
             marker_state already works this out. ]]
        if r.quest_status == 'in_progress' then
            for _, why in ipairs(r.marker_reasons or {}) do
                local mark = why.ok == true and '+' or (why.ok == false and 'x' or '?')
                line('  %s %s', mark, why.text)
            end
        end

        --[[ The step ladder, so a marker on the wrong NPC can be identified
             from one command rather than guessed at. `>` is where inference
             puts you, `*` is the step actually carrying the marker. ]]
        local sx = r.steps
        if sx and sx.n and sx.n > 1 then
            line('  ladder: step %d of %d (%s)', sx.idx, sx.n,
                 (sx.info and sx.info.source) or '?')
            for _, row in ipairs(sx.rows or {}) do
                local flag = (row.current and '>' or ' ') .. (row.marker and '*' or ' ')
                local verdict = row.evidence == nil and ''
                    or (row.verdict == true and '   evidence: HELD'
                        or (row.verdict == false and '   evidence: not held'
                            or '   evidence: unknown'))
                --[[ The second 0x055 bitfield, which exists nowhere else. It
                     decides NOTHING -- no step in the dataset means "examined"
                     -- but it is the only place a key item's examined bit has
                     ever been visible, and it distinguishes a key item you were
                     handed from one you have actually looked at. ]]
                if row.evidence and keyitems.ready() then
                    local yes, no = 0, 0
                    for _, ev in ipairs(row.evidence) do
                        if ev.kind == 'ki' then
                            local x = keyitems.examined(ev.rid)
                            if x == true then yes = yes + 1
                            elseif x == false then no = no + 1 end
                        end
                    end
                    if yes > 0 or no > 0 then
                        verdict = verdict .. ('  (%d examined, %d not)'):format(yes, no)
                    end
                end
                --[[ `row.label` and not `row.npc`: a monster step is markable
                     without an npc key, so reading `row.npc` collapses through
                     nil to "(nothing to mark)" while the markers are on screen.
                     core/steps.lua computes the label once. ]]
                --[[ The CITY, not just the grid reference. A ladder routinely
                     crosses zones -- "Waking the Colossus" visits three -- and
                     a bare "I-11" beside a name you do not recognise says
                     nothing. `row` already carries label/zone/grid under
                     exactly the names fmt_where wants. ]]
                local target = row.label and fmt_where(row)
                    or ('(nothing to mark)' .. (row.zone
                        and ('  ' .. (zone_name(row.zone)
                                      or ('zone ' .. row.zone))) or ''))
                --[[ "defeat 5 Nasu" is the step a player has no way to check
                     their own progress on, and this is the only answer the
                     addon can offer. Session-local and approximate -- it counts
                     your party's defeats, while the game credits the party that
                     had the mob claimed -- so it is shown next to the step and
                     never used to advance it. ]]
                local mobs = r.entry.steps and r.entry.steps[row.n]
                    and r.entry.steps[row.n].mobs
                if mobs then
                    local done, needed = kills.progress(mobs)
                    if needed > 1 then
                        verdict = verdict .. ('   beaten %d/%d this session')
                            :format(done, needed)
                    elseif done > 0 then
                        verdict = verdict .. ('   beaten %d this session'):format(done)
                    end
                end
                line('   %s %2d %-8s %-44s%s', flag, row.n, row.kind,
                     target, verdict)
            end
        end
    end
end

--[[ //qm todo -- the whole index, filtered to what you can act on.

     Markers only exist for NPCs you are standing near, and `//qm new` only
     reports CHANGES. Neither answers "what am I in the middle of". This walks
     every indexed entry and asks for its quest-level marker state, the same
     walk notify.update does on every 0x056 settle, so the cost is known and
     affordable on demand.

     Quest-level (`marker_state(entry)` with no step) is the right question, not
     a shortcut. A quest whose current step is in another zone deliberately
     draws no marker where you are standing; it is still on your to-do list, and
     this is the command that says so.

     The default is what you have accepted, not everything you could start.
     `ready` alone is hundreds of entries on a developed character, a list
     nobody reads, while turnin+progress is the size of your quest log. The
     wider views are one word away.

     Colour names come from fmt_state, which reads them back out of the same
     COLOR table the renderer draws from, so the STATE colour here can never
     disagree with the screen. The step glyph and its tint can: fmt_state has
     no `hint` to pass, because a hint is decided per NPC in
     `quests.marker_for` and a todo row is not per NPC. So an accepted "obtain"
     step prints "grey ?" while the world draws a brown bag. ]]
local TODO_SETS = {
    accepted = {turnin = true, progress = true},
    all      = {turnin = true, progress = true, ready = true, unknown = true,
                blocked = true, ['repeat'] = true},
}

local function cmd_todo(a1, a2)
    if not index_ok then err('no index loaded') return end

    local want, what = TODO_SETS.accepted, 'accepted'
    local cap = settings.notify_detail or 6
    for _, a in ipairs({a1, a2}) do
        local n = tonumber(a)
        if n then
            cap = math.max(1, math.floor(n))
        elseif TODO_SETS[a] then
            want, what = TODO_SETS[a], a
        elseif markers.GLYPH[a] then
            want, what = {[a] = true}, a
        else
            err('usage: //qm todo [all|turnin|progress|ready|unknown|blocked'
                .. '|repeat] [n]')
            return
        end
    end

    local t0 = os.clock()
    local ok, rows = pcall(quests.todo, want)
    if not ok then err('todo failed: %s', tostring(rows)) return end
    local ms = (os.clock() - t0) * 1000

    if #rows == 0 then
        msg('nothing %s -- //qm todo all lists every state', what == 'accepted'
            and 'in progress or ready to hand in' or ('is ' .. what))
        return
    end

    local by_state = {}
    for _, r in ipairs(rows) do by_state[r.state] = (by_state[r.state] or 0) + 1 end
    local tally = {}
    for _, s in ipairs({'turnin', 'ready', 'unknown', 'progress', 'blocked',
                        'repeat'}) do
        if by_state[s] then tally[#tally + 1] = ('%d %s'):format(by_state[s], s) end
    end
    msg('%d to do (%s): %s   [%.0f ms]', #rows, what,
        table.concat(tally, ', '), ms)

    --[[ CHAT is capped and the LOG is not, the same split `//qm new` uses:
         truncating both would mean the overflow existed nowhere, and the log
         is the channel that exists precisely because chat cannot be read back.
         `//qm todo <n>` raises the chat cap when you want it all in front of
         you. ]]
    for i, r in ipairs(rows) do
        local w = r.where or {}
        local pos = w.step and (' step %d/%d%s'):format(w.step, w.of,
                                                        w.held and ' (held)' or '')
                 or ''
        local s = fmt('%-17s %-38s %s%s',
                      fmt_state(r.state, r.entry.cat, r.entry.area),
                      r.name or r.key, fmt_where(w), pos)
        if i <= cap then line('%s', s) else log_only('   %s', s) end
    end
    if #rows > cap then
        line('... and %d more (full list in %s)', #rows - cap, LOGFILE)
    end
end

--[[ Dump every entity in the zone sharing a name, with the fields that might
     distinguish a rendered NPC from a conditionally-hidden duplicate.

     This exists because FFXI gives no documented "is rendered" flag. When a
     marker appears over empty air, run this on that NPC: comparing the two
     rows shows which field actually separates the real one from the ghost. ]]
local function cmd_dump(name)
    if not name then err('usage: //qm dump <npc name>  (or "t" for target)') return end
    if name == 't' then
        local t = windower.ffxi.get_mob_by_target('t')
        if not t then err('no target') return end
        name = t.name
    end

    local want = quests.fold(name)
    local ok, list = pcall(windower.ffxi.get_mob_list)
    if not ok or type(list) ~= 'table' then err('get_mob_list failed') return end

    local me = windower.ffxi.get_mob_by_target('me')
    local found = 0
    msg('entities named %q in zone %s:', name, tostring(cur_zone))
    for idx, n in pairs(list) do
        if type(n) == 'string' and quests.fold(n) == want then
            local ok2, m = pcall(windower.ffxi.get_mob_by_index, idx)
            if ok2 and m then
                found = found + 1
                local d = (me and m.x) and math.sqrt(
                    (m.x-me.x)^2 + (m.y-me.y)^2 + (m.z-me.z)^2) or -1
                line('idx=%-5d dist=%-7.2f valid_target=%-5s status=%-4s spawn_type=%s',
                     idx, d, tostring(m.valid_target), tostring(m.status),
                     tostring(m.spawn_type))
                line('  is_npc=%-5s model_size=%-6s model_scale=%-6s race=%s id=%s',
                     tostring(m.is_npc), tostring(m.model_size),
                     tostring(m.model_scale), tostring(m.race), tostring(m.id))
                line('  pos=%.2f, %.2f, %.2f  heading=%s',
                     m.x or 0, m.y or 0, m.z or 0, tostring(m.heading))
            end
        end
    end
    if found == 0 then msg('no entity by that name in this zone') return end
    if found > 1 then
        msg('%d copies. An NPC name collapses to the nearest targetable one; '
            .. 'a monster name does not, and every copy can carry a marker.',
            found)
    end
end

--[[ One-shot dump of everything a bug report needs. In-game chat is not
     copyable, so this writes the full picture to questmarks.log in one go. ]]
local function cmd_diag()
    local info = windower.ffxi.get_info() or {}
    local me = windower.ffxi.get_mob_by_target('me')

    log_only('')
    log_only('================ //qm diag ================')
    msg('writing diagnostics to %s%s', windower.addon_path, LOGFILE)

    local m = quests.meta()
    local npcs, entries = quests.stats()
    line('addon %s  index %s entries / %d npc keys / %d rows  all_areas=%s',
         _addon.version, tostring(m and m.indexed), npcs, entries,
         tostring(m and m.all_areas))
    --[[ The id ladder decides where every LINEAR mission line thinks you are,
         so a missing dat_names.lua is worth seeing at a glance in any bug
         report -- it silently drags CoP/RoV/SoA/ACP/MKD/ASA/TVR position
         backwards rather than failing. ]]
    line('dat names: %d ids from data/dat_names.lua%s',
         (m and m.dat_names_added) or 0,
         ((m and m.dat_names_added or 0) > 0) and ''
             or '   *** MISSING -- linear missions will misresolve')
    --[[ `enabled` is the player's switch; the halt is the circuit breaker, and
         the two are separate on purpose (only one of them is saved). Report the
         halt here, or a three-frame fault looks exactly like "the addon just
         stopped working". ]]
    line('zone %s  logged_in=%s  enabled=%s%s',
         tostring(info.zone), tostring(info.logged_in), tostring(settings.enabled),
         render_halted and '   *** RENDER HALTED after 3 throws -- //qm on resumes' or '')
    if me then line('player at %.2f, %.2f, %.2f', me.x, me.y, me.z) end
    --[[ The whole environment, because a bug report that says "markers
         vanished" is answered by menu_open and by nothing else. ]]
    env_lines(line, line)
    line('hide_on_menu=%s', tostring(settings.hide_on_menu))
    ki_lines(line, line)
    skill_lines(line, line)

    local ok = project.begin()
    local L = project.layout()
    line('projection %s  nested=%s vec=%s viewproj=%s axes={%d,%d,%d} vsign=%d',
         ok and 'OK' or ('FAILED: ' .. tostring(project.last_error)),
         tostring(L.nested), L.vec, tostring(L.viewproj),
         L.order[1], L.order[2], L.order[3], L.vsign)
    local vw, vh = project.viewport()
    line('viewport %dx%d (ui space)', vw, vh)
    line('hook %s  lag %.2f  smooth %.2f', settings.hook,
         project.lag(), project.smooth())

    line('packet data for: %s', table.concat(state.areas_with_data(), ' '))
    for _, r in ipairs(fame.regions()) do
        local lvl, src = fame.get(r)
        line('fame %-15s %-8s %s', r, lvl and tostring(lvl) or 'unknown', src or '')
    end
    for _, u in ipairs(fame.unmatched) do
        line('UNCLASSIFIED checker line [%s] %s', u.npc, u.line)
    end

    local s = markers.stats
    line('perf: scan %.2fms eval %.2fms render %.3fms | drawn %d prim_calls %d'
         .. ' | %d frame(s) rendered',
         perf.scan, perf.eval, perf.render, s.drawn, s.prim_calls, perf.frames)
    line('culled: %d distance / %d floor / %d offscreen',
         s.culled_dist, s.culled_floor, s.culled_screen)

    --[[ The camera ledger. A refused frame hides EVERY marker.
         project.frames_failed alone is not enough: it is a consecutive counter
         that the next good frame zeroes, so an intermittent fault erases its
         own evidence and "all my markers keep flickering off" has nothing to
         point at. These totals are never cleared. `blank` is the same event
         counted on the addon's side of the call. ]]
    line('camera: %d frame(s) refused total (%d blank render(s), worst run %d,'
         .. ' %d now)%s',
         project.frames_failed_total, perf.blank,
         project.frames_failed_worst, project.frames_failed,
         project.last_fail_error
             and ('   last reason: ' .. tostring(project.last_fail_error)) or '')

    --[[ The corpse filter is reported because it is THE ONLY filter that can
         remove a MONSTER marker, and monsters are marker targets in their own
         right. Unreported, a step whose whole monster list was lying dead on
         the floor looked identical to a step that never produced a marker. ]]
    line('scan: %d not spawned/visible (visible_only=%s), %d duplicate name(s)'
         .. ' collapsed, %d dead (corpse)',
         scan_filtered.hidden, tostring(settings.visible_only),
         scan_filtered.duplicate, scan_filtered.dead or 0)
    for _, g in ipairs(scan_filtered.ghosts) do line('  %s', g) end

    local dt, ratio = project.timing()
    line('nation = %s   lag = %.2f (time-scale %.2f)   frame %.1f ms   '
         .. 'head_offset %.2f x race-scale %.2f',
         tostring(state.nation()), project.lag(), ratio or 1, (dt or 0) * 1000,
         markers.settings().head_offset, markers.settings().size_scale)

    --[[ model_size is logged so the marker-height reference can be calibrated
         from real NPCs -- its units are undocumented. ]]
    line('%d candidate NPC(s):', #candidates)
    for _, c in ipairs(candidates) do
        line('  %-26s %-10s x%-3s idx=%-5s model_size=%-8s race=%-4s head=%.2f',
             c.name, c.state or '-', tostring(c.count or 0), tostring(c.index),
             tostring(c.model_size), tostring(c.race),
             markers.head_offset_for(c))
    end

    -- full per-quest breakdown for every marked NPC, log only (too long for chat)
    for _, c in ipairs(candidates) do
        if c.state then
            local rows = quests.explain(c.name, cur_zone)
            log_only('--- %s ---', c.name)
            for _, r in ipairs(rows or {}) do
                log_only('   [%s/%s #%d] %s | state=%s marker=%s',
                    r.entry.cat, r.entry.area, r.entry.id, r.name or '?',
                    tostring(r.quest_status), tostring(r.marker))
                for _, why in ipairs(r.reasons or {}) do
                    log_only('      %s %s',
                        why.ok == true and '+' or (why.ok == false and 'x' or '?'),
                        why.text)
                end
            end
        end
    end
    log_only('================ end diag ================')
    msg('done. Send me that file.')
end

--[[ Note on defaults: once a key exists in data/settings.xml, the value there
     wins and changing the default in this file has NO effect for anyone who
     has already run the addon. Do not "fix" behaviour by editing a default and
     assume it reaches existing users -- it does not. //qm reset is the escape
     hatch. ]]
local NUMERIC = {
    dist = 'max_distance', max = 'max_markers', size = 'icon_size',
    offset = 'head_offset', floor = 'floor_tol',
    sizescale = 'size_scale',
    refdist = 'ref_distance', pxmin = 'px_min', pxmax = 'px_max',
}

windower.register_event('addon command', function(cmd, a1, a2)
    cmd = (cmd or 'help'):lower()

    if cmd == 'on' or cmd == 'off' or cmd == 'toggle' then
        settings.enabled = (cmd == 'on') or (cmd == 'toggle' and not settings.enabled)
        --[[ Switching markers back on is also the acknowledgement that clears
             the render circuit breaker. The counter must go with it: left
             standing, the next single bad frame re-halts immediately and
             `//qm on` appears to do nothing at all. ]]
        if settings.enabled and render_halted then
            render_halted, render_errors = false, 0
            msg('render halt cleared')
        end
        if not settings.enabled then markers.hide_all() end
        settings:save()
        msg('markers %s', settings.enabled and 'ON' or 'OFF')

    elseif NUMERIC[cmd] then
        local key = NUMERIC[cmd]
        local v = tonumber(a1)
        if not v then msg('%s = %s', cmd, tostring(settings[key])) return end
        --[[ `max` is a POOL SIZE -- a count of prims -- so it has to be a whole
             number. markers.init floors it defensively too, but normalise it
             here as well so what gets PERSISTED and echoed back is the value
             actually in use, rather than a 3.5 that silently behaves as 3. ]]
        if cmd == 'max' then
            v = math.floor(v)
            if v < 0 then v = 0 end
        end
        settings[key] = v
        markers.config{[key] = v}
        if cmd == 'max' then markers.init(v) end
        settings:save()
        msg('%s = %s', cmd, tostring(v))

    elseif cmd == 'show' then
        if not a1 then
            local l = {}
            for k, v in pairs(settings.show) do
                l[#l + 1] = ('%s=%s'):format(k, v and 'on' or 'off')
            end
            table.sort(l)
            msg('show: %s', table.concat(l, ' '))
            line('repeat_quest = repeatable QUESTS (300), repeat_mission = MISSIONS (11)')
            line('a yellow/green "available" marker always outranks a blue repeatable one')
            return
        end
        if a1 == 'repeat' then a1 = 'repeat_quest' end      -- backwards-compatible alias
        if settings.show[a1] == nil then err('unknown state %q', a1) return end
        settings.show[a1] = (a2 == 'on') or (a2 == nil and not settings.show[a1])
        settings:save()
        dirty_state = true
        msg('show %s = %s', a1, settings.show[a1] and 'on' or 'off')

    elseif cmd == 'fame' then
        cmd_fame(a1, a2)

    elseif cmd == 'why' then
        cmd_why(a1)

    elseif cmd == 'diag' then
        cmd_diag()

    elseif cmd == 'dump' then
        cmd_dump(a1)

    elseif cmd == 'settings' then
        --[[ Show effective values AND flag any that a stale saved file is
             pinning away from the current default. A saved value that no longer
             matches the shipped default is otherwise invisible. ]]
        msg('effective settings (* = differs from the shipped default):')
        local keys = {}
        for k in pairs(defaults) do
            if type(defaults[k]) ~= 'table' then keys[#keys + 1] = k end
        end
        table.sort(keys)
        for _, k in ipairs(keys) do
            local cur, def = settings[k], defaults[k]
            line('%s %-16s %-10s (default %s)', cur ~= def and '*' or ' ',
                 k, tostring(cur), tostring(def))
        end
        line('marker height in use: %.2f base, race scaling %s',
             markers.settings().head_offset,
             markers.settings().size_scale > 0 and 'on' or 'off')

    elseif cmd == 'reset' then
        if a1 ~= 'confirm' then
            err('this clears ALL saved settings for this character.')
            err('fame readings are preserved. run:  //qm reset confirm')
            return
        end
        local keep = settings.fame_by_char
        for k, v in pairs(defaults) do
            if type(v) == 'table' then
                local t = {}
                for kk, vv in pairs(v) do t[kk] = vv end
                settings[k] = t
            else
                settings[k] = v
            end
        end
        settings.fame_by_char = keep
        settings:save()
        msg('settings reset to defaults (fame kept). reloading ...')
        windower.send_command('lua reload questmarks')

    elseif cmd == 'steps' then
        if a1 == 'on' or a1 == 'off' then
            settings.steps = (a1 == 'on')
            settings:save()
            steps.enable(settings.steps)
            dirty_state = true
            msg('step markers %s', settings.steps and 'ON' or 'OFF')
        else
            local s = steps.stats()
            msg('step markers %s', s.enabled and 'ON' or 'OFF')
            --[[ `advanced` is the informative one: 0 means inference is doing
                 nothing, and an implausibly large value means evidence is
                 firing where it should not. `tracked` is just how many quests
                 are in progress and have been asked about. ]]
            msg('  in progress: %d   past step 1: %d   cached: %d   evaluations: %d',
                s.tracked, s.advanced, s.cached, s.evals)
            msg('  inventory swept: %s%s', tostring(s.inventory_ready),
                s.inventory_ready and '' or '   (no evidence can read true yet)')
        end

    elseif cmd == 'notify' then
        settings.notify = (a1 == 'on') or (a1 == nil and not settings.notify)
        settings:save()
        msg('notifications %s', settings.notify and 'ON' or 'OFF')

    elseif cmd == 'todo' then
        cmd_todo(a1, a2)

    elseif cmd == 'new' then
        local g = notify.last()
        if not notify.primed() then
            msg('no baseline yet -- zone once so state can settle')
        elseif #g == 0 then
            msg('nothing has become newly available since the last check')
        else
            --[[ CHAT is capped -- this is the only list left after the
                 announcement was reduced to one line, and an unlock that opens
                 dozens of quests would just move the flood here instead.

                 The LOG is not capped. Truncating both would mean the overflow
                 existed nowhere, and the log is the channel that exists
                 precisely because chat cannot be read back. ]]
            msg('%d newly available at the last check:', #g)
            local cap = settings.notify_detail or 6
            for i, item in ipairs(g) do
                local s = fmt('%s/%s #%d  %s',
                              item.entry.cat, item.entry.area, item.entry.id,
                              quests.name_of(item.entry.cat, item.entry.area,
                                             item.entry.id) or '?')
                if i <= cap then line('%s', s) else log_only('   %s', s) end
            end
            if #g > cap then
                line('... and %d more (full list in questmarks.log)', #g - cap)
            end
        end

    elseif cmd == 'lag' then
        if not a1 then
            msg('lag compensation = %.2f (0 = off, 1 = one frame)', project.lag())
            return
        end
        settings.lag = project.set_lag(a1)
        settings:save()
        msg('lag compensation = %.2f -- markers are extrapolated forward by the '
            .. 'camera movement measured last frame', settings.lag)

    elseif cmd == 'hook' then
        --[[ See the `hook` note beside the defaults. postrender is the default
             because prerender was measurably the wrong sampling point; this
             stays switchable so the comparison remains one command. ]]
        if not a1 then
            msg('render hook = %s  (pre | post; postrender is the default)',
                settings.hook)
            line('prerender samples the camera before the client updates it, so')
            line('deltas came out uneven and the compensation shimmered.')
            line('switch hooks and compare with //qm lag 0 while panning hard.')
            return
        end
        local want = (a1 == 'post' or a1 == 'postrender') and 'postrender'
                  or (a1 == 'pre' or a1 == 'prerender') and 'prerender'
        if not want then err('usage: //qm hook pre|post') return end
        if want ~= settings.hook then
            settings.hook = want
            settings:save()
            --[[ The two cached matrices would straddle the switch, so their
                 difference spans a partial frame. Drop them. ]]
            project.reset_history()
        end
        msg('render hook = %s', settings.hook)

    elseif cmd == 'debug' then
        local on = markers.set_debug((a1 == 'on') or (a1 == nil and not markers.debug()))
        msg('debug labels %s', on and 'ON' or 'OFF')
        if on then
            line('each marker is captioned: NPC, state, distance, current lag push, size')
            line('screenshot one that looks wrong and the caption identifies it')
        end

    elseif cmd == 'perspective' then
        settings.perspective = (a1 == 'on')
            or (a1 == nil and not settings.perspective)
        markers.config{perspective = settings.perspective}
        settings:save()
        msg('perspective sizing %s -- %s', settings.perspective and 'ON' or 'OFF',
            settings.perspective
                and ('markers scale with distance; %d px at %d yalms, clamped %d-%d')
                    :format(settings.icon_size, settings.ref_distance,
                            settings.px_min, settings.px_max)
                or 'markers are a fixed screen size at any range')

    elseif cmd == 'smooth' then
        if not a1 then
            msg('smoothing = %.2f (0 = react instantly, 0.9 = very steady)',
                project.smooth())
            return
        end
        settings.smooth = project.set_smooth(a1)
        settings:save()
        msg('smoothing = %.2f -- higher damps shimmer but ramps in more slowly '
            .. 'at the start of a turn', settings.smooth)

    elseif cmd == 'visible' then
        settings.visible_only = (a1 == 'on')
            or (a1 == nil and not settings.visible_only)
        settings:save()
        last_scan = 0
        dirty_state = true
        msg('visible_only = %s -- %s', settings.visible_only and 'on' or 'off',
            settings.visible_only
                and 'markers only on NPCs the client has spawned (fade in/out with them)'
                or 'mark every indexed entity within range, spawned or not')


    elseif cmd == 'npcs' then
        if #candidates == 0 then msg('no quest NPCs resolved in this zone') return end
        msg('%d quest NPC(s) in zone %s:', #candidates, tostring(cur_zone))
        for _, c in ipairs(candidates) do
            line('%-28s %-22s%s', c.name,
                 c.state and fmt_state(c.state, c.cat, c.area) or '-',
                 (c.count and c.count > 1) and (' x' .. c.count) or '')
        end

    elseif cmd == 'data' then
        local m = quests.meta()
        local npcs, entries = quests.stats()
        msg('index: %s entries over %d npc keys (%d rows), all_areas=%s',
            m and m.indexed or '?', npcs, entries, m and tostring(m.all_areas) or '?')
        msg('areas: %s', table.concat(quests.areas(), ' '))
        msg('dat names: %d ids registered', (m and m.name_ids) or 0)
        local ni, nk, _, neq, nskip, nans = inventory.stats()
        msg('inventory cache: %d item ids (%d equipped), %d key items', ni, neq, nk)
        --[[ Worth a line of its own: a bag wrongly skipped reads as "you do not
             hold it", which pins a ladder silently. If this number is ever
             surprising, that is the first place to look.

             `nans` is reported because "0 skipped" alone cannot distinguish
             "you own all seventeen" from "get_bag_info told us nothing". ]]
        msg('bags: %d swept, %d skipped as not owned; get_bag_info answered '
            .. 'for %d of %d', #inventory.BAGS - nskip, nskip, nans,
            #inventory.BAGS)
        ki_lines(msg, line)
        skill_lines(msg, line)

    elseif cmd == 'state' then
        if not a1 then
            msg('packet data for: %s', table.concat(state.areas_with_data(), ' '))
            return
        end
        local d = state.dump(a2 and a1 or 'quest', a2 or a1)
        msg('%s: %d current, %d completed%s', a2 or a1, #d.current, #d.completed,
            d.linear and (', linear=' .. tostring(d.linear)) or '')

    elseif cmd == 'kills' then
        --[[ Session-local, unpersisted, and never load-bearing. It exists
             because "defeat 5 Nasu" is otherwise unanswerable: 91 monster
             targets in the index carry a count above 1, and nothing in any
             packet reports quest kill progress. ]]
        local list = kills.all()
        local s = kills.stats()
        local d = kills.designated()
        if #list == 0 then
            msg('no defeats counted yet this session%s', s.watching == 0
                and ' -- nothing is being watched, because no quest you have '
                    .. 'accepted names a monster'
                or (' (watching %d monster name(s))'):format(s.watching))
        else
            msg('%d defeats over %d monster name(s) this session:',
                s.defeats, s.names)
            local cap = tonumber(a1) or 12
            for i, k in ipairs(list) do
                if i <= cap then line('%4d  %s', k.n, k.name)
                else log_only('   %4d  %s', k.n, k.name) end
            end
            if #list > cap then
                line('... and %d more (full list in %s)', #list - cap, LOGFILE)
            end
        end
        if d then
            line('designated target progress (from the game): %s/%s',
                 tostring(d.done), tostring(d.total))
        end
        line('counted from combat messages, cleared at login, and never used')
        line('to advance a step -- 0x056 alone decides whether a quest is done.')

    elseif cmd == 'menu' then
        settings.hide_on_menu = (a1 == 'on')
            or (a1 == nil and not settings.hide_on_menu)
        settings:save()
        msg('hide markers while a menu is open: %s',
            settings.hide_on_menu and 'ON' or 'OFF')
        if settings.hide_on_menu then
            line('the flag is only acted on once it has been seen to read')
            line('false at least once since login -- so if it never does, this')
            line('setting does nothing rather than blanking every marker.')
            line('//qm probe shows its live value and whether it is trusted yet.')
        end

    elseif cmd == 'probe' then
        local ok = project.begin()
        msg('projection: %s', ok and 'OK' or ('FAILED - ' .. tostring(project.last_error)))
        local L = project.layout()
        msg('layout: nested=%s vec=%s viewproj=%s axes={%d,%d,%d} vsign=%d',
            tostring(L.nested), L.vec, tostring(L.viewproj),
            L.order[1], L.order[2], L.order[3], L.vsign)
        local vw, vh = project.viewport()
        msg('viewport: %dx%d (ui space)', vw, vh)
        env_lines(msg, line)
        skill_lines(msg, line)

    elseif cmd == 'perf' then
        local s = markers.stats
        msg('scan %.2fms  eval %.2fms  render %.3fms', perf.scan, perf.eval, perf.render)
        msg('drawn %d  prim calls %d  culled: %d dist / %d floor / %d screen',
            s.drawn, s.prim_calls, s.culled_dist, s.culled_floor, s.culled_screen)
        local dt, ratio = project.timing()
        msg('frame %.1f ms (%.0f fps)  lag %.2f x %.2f time-scale  smooth %.2f',
            (dt or 0) * 1000, dt and dt > 0 and (1 / dt) or 0, project.lag(),
            ratio or 1, project.smooth())
        -- Which hook produced these numbers; a screenshot is useless without it.
        msg('hook %s', settings.hook)
        --[[ A per-frame timing with no denominator says nothing about how long
             the session has been running, and a `drawn 0` says nothing about
             WHY. `blank` is frames the camera refused, on which every marker
             was hidden; the totals in project are never zeroed, so an
             intermittent fault still shows up here long after it cleared. ]]
        msg('%d frame(s) rendered, %d blank (camera refused %d total, worst run %d)%s',
            perf.frames, perf.blank, project.frames_failed_total,
            project.frames_failed_worst,
            render_halted and '   *** RENDER HALTED -- //qm on resumes' or '')

    elseif cmd == 'rebuild' then
        --[[ Preserve the scope already built unless explicitly overridden, so a
             rebuild never silently shrinks the index from every area back to
             the v1 subset. ]]
        local m = quests.meta()
        local all = (m and m.all_areas) and true or false
        if a1 == 'all' then all = true elseif a1 == 'v1' then all = false end

        msg('rebuilding index (%s areas) ...', all and 'ALL' or 'v1')
        local ok, builder = pcall(require, 'tools/build_index')
        if not ok then err('cannot load builder: %s', tostring(builder)) return end
        local st, e = builder.build{all_areas = all, report = function(l) line('%s', l) end}
        if not st then err('%s', tostring(e)) return end
        msg('done: %d indexed. Reloading ...', st.indexed)
        windower.send_command('lua reload questmarks')

    elseif cmd == 'reload' then
        windower.send_command('lua reload questmarks')

    else
        msg('commands (all output also goes to %s):', LOGFILE)
        for _, l in ipairs({
            'diag              dump EVERYTHING to the log -- send me that file',
            'debug [on|off]    caption each marker with NPC/distance/lag push',
            'on | off | toggle',
            'why <npc|t>       explain every marker on an NPC (t = target)',
            'dump <npc|t>      compare every entity sharing that name',
            'visible [on|off]  only mark NPCs the client has spawned (default on)',
            'menu [on|off]     hide markers while a menu is open (default on)',
            'kills [n]         monsters beaten this session (display only)',
            'todo [what] [n]   what you are in the middle of, anywhere in the',
            '                  world.  what = all | turnin | progress | ready |',
            '                  unknown | blocked | repeat;  n raises the chat cap',
            'new               what became available at the last check',
            'notify [on|off]   announce newly available quests (default on)',
            'npcs              quest NPCs resolved in this zone',
            'fame              show levels;  fame <region> <0-9|reset>;  fame dump',
            'show <state> [on|off]   turnin progress ready unknown blocked',
            '                        repeat_quest | repeat_mission',
            'steps [on|off]    follow a quest along its steps (default on);',
            '                  bare form reports how many are past step 1',
            'dist | max | size | offset | floor  <n>',
            'perspective [on|off]  scale markers with distance (default on)',
            'refdist | pxmin | pxmax <n>   perspective tuning',
            'lag <0-3>         camera lag compensation (1 = one frame)',
            'hook pre|post     which render hook places the markers',
            'smooth <0-0.9>    damp marker shimmer (higher = steadier)',
            'sizescale <0-1>   scale marker height by NPC race (0 = fixed)',
            'settings          effective values, flagging stale saved ones',
            'reset confirm     clear saved settings (keeps fame)',
            'data | state [cat] <area> | probe | perf',
            'rebuild [all|v1]  regenerate the index',
        }) do line('//qm ' .. l) end
    end
end)

-- ---------------------------------------------------------------------------
-- Boot
-- ---------------------------------------------------------------------------

do
    local meta, e = quests.load(windower.addon_path .. 'data/quest_index.lua')
    if not meta then
        err('%s', tostring(e))
        err('run:  luajit tools/build_index.lua   (or //qm rebuild)')
    else
        index_ok = true
        --[[ Applied again on login, when the config library can finally
             resolve the per-character section. See apply_settings(). ]]
        apply_settings()
        markers.init(settings.max_markers)
        local nf = load_fame()
        if nf > 0 then msg('restored %d saved fame reading(s)', nf) end

        local info = windower.ffxi.get_info()
        cur_zone = info and info.zone
        if cur_zone then wanted = quests.wanted_names(cur_zone) end

        -- Already logged in (a mid-session reload) means login never fires,
        -- so resolve per-character settings and fame here instead.
        if info and info.logged_in then
            apply_settings()
            load_fame()
            refresh_player()
        end

        local npcs = select(1, quests.stats())
        --[[ The version and the ladder count are the BUILD STAMP. questmarks.log
             appends forever, so over a long test one file spans several builds;
             without this, a log line cannot be attributed to the code that
             produced it. The ladder count is included because it moves whenever
             the index is regenerated, which the version alone would not catch. ]]
        msg('v%s loaded %s entries over %d NPCs (%s step ladders) at %.2f '
            .. 'marker height. //qm for help.',
            _addon.version, tostring(meta.indexed), npcs,
            tostring(meta.steps or 0), markers.settings().head_offset)
    end
end
