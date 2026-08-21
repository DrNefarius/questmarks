--[[
render/markers.lua -- the prim pool that draws markers in the world.

Deliberately does NOT use libs/images.lua. That library keeps a global
`saved_images` registry, defaults every image to draggable, and registers a
global `mouse` handler that hover-tests every image on every mouse event
(images.lua:11, :70, :381). With a pool of markers that is a hit test per
marker per mouse-move, and the user could drag a marker off its NPC. Raw
windower.prim.* instead.

Prims are named GLOBAL objects, so the pool is fixed and recycled: never
create or delete during a frame. Every prim call is change-detected, because
the native calls dominate the frame cost and a stationary camera looking at
stationary NPCs should issue almost none.

OCCLUSION: there is no depth buffer access from Lua, so markers draw through
walls. That is not fixable, only mitigated -- distance cull, a same-floor
check (which handles the Jeuno tiers / Metalworks / mog house cases), and an
alpha ramp so anything far reads as ambient rather than assertive.
]]

local markers = {}

local project = require('render/project')

-- --------------------------------------------------------------------------
-- Appearance
-- --------------------------------------------------------------------------

--[[ Glyph by state. Missions use the SAME glyphs as quests and are
     distinguished by hue instead. Do not give them an interrobang; it is
     unreadable at icon size in a busy scene. ]]
local GLYPH = {
    turnin = 'query', progress = 'query',
    ready = 'bang', unknown = 'bang', blocked = 'bang', ['repeat'] = 'bang',
}

--[[ Colour by state, with per-category overrides where it matters.

     yellow = actionable quest        green = actionable mission
     red    = actionable CAMPAIGN     black = cannot verify
     grey   = not actionable          blue  = repeatable

     Categories only diverge when ACTIONABLE. That is the whole point --
     storyline missions should not be lost among yellow side quests, and
     Campaign has its own standing again. Blocked / unverifiable / repeatable
     stay shared, because grey is grey and splitting those too would just add
     noise. ]]
local COLOR = {
    turnin     = {255, 215,  40},   -- yellow
    ready      = {255, 215,  40},   -- yellow
    progress   = {165, 165, 165},   -- grey
    blocked    = {140, 140, 140},   -- grey
    --[[ Near-black rather than pure black: set_color MULTIPLIES the texture, so
         {0,0,0} would erase the glyph entirely. This still reads as black while
         staying distinguishable from the grey of `blocked`. ]]
    unknown    = { 25,  25,  32},
    ['repeat'] = { 90, 170, 255},   -- blue
}

local MISSION_COLOR = {
    turnin   = { 70, 235, 120},     -- green
    ready    = { 70, 235, 120},     -- green
    progress = {120, 180, 140},     -- muted green, still reads as "mission"
}

-- Campaign is the war content and gets its own identity.
local CAMPAIGN_COLOR = {
    turnin   = {255,  70,  60},     -- red
    ready    = {255,  70,  60},     -- red
    progress = {190, 110, 100},     -- muted red
}

--[[ `campaign_2` was never an INDEX area -- it was only ever a packet-routing
     label for the second half of the campaign completed bitfield (0x0038), and
     that now routes to `campaign` with an offset, so no entry can ever carry it.
     Measured: 0 rows in either index. Kept as a one-word no-op rather than
     removed, because a colour set is the wrong place to discover that a
     re-route happened; state.lua explains it where it is decided. ]]
local CAMPAIGN_AREAS = {campaign = true, campaign_2 = true}

--[[ What a step ASKS OF YOU, once you have accepted the quest.

     Colour still carries the state; this only refines the "?" into something
     that says which kind of thing to do when we know. It applies to accepted
     quests only -- anything not yet started keeps the classic "!", because
     "there is something here to take" is the whole message at that point.

     A monster is a marker target like any other: get_mob_list() returns every
     entity, not just NPCs. The ROLE picks the glyph, so the same monster is a
     sword in a quest that needs it dead and a bag in one that needs its drop. ]]
local STEP_GLYPH = {
    talk = 'talk', trade = 'trade', turnin = 'query', examine = 'search',
    fight = 'sword', travel = 'query', obtain = 'bag', wait = 'query',
    cutscene = 'query', other = 'query',
}
local MOB_GLYPH = {kill = 'sword', spawn = 'sword', drop = 'bag'}

--[[ Glyphs that carry a FIXED colour instead of the state colour.

     `!` and `?` encode state in their hue -- yellow actionable, grey not, blue
     repeatable, black unverifiable -- and that is the whole reason they are
     tinted. The action glyphs do not participate in that vocabulary: there is
     no "inactive sack", so tinting one grey says nothing and only makes it look
     washed out. They get an identity colour instead, which also lets the sack
     actually look like sackcloth.

     `trade` is deliberately NOT in here. It is the hand-over glyph, so it is
     the one action glyph where "ready" versus "not ready" is a real distinction
     worth seeing, and it keeps the yellow.

     set_color MULTIPLIES against a white body, so these are the colours you get
     on screen. The near-black outline stays near-black whatever it is multiplied
     by, which is what keeps every glyph readable against sky, stone or water. ]]
local GLYPH_TINT = {
    bag    = {168, 116,  66},   -- sackcloth brown
    search = {208, 208, 208},   -- light grey
    sword  = {208, 208, 208},   -- light grey, like steel
    talk   = {255, 255, 255},   -- white
}

-- -> glyph, r, g, b
local function style_for(st, cat, area, hint)
    local c
    if cat == 'mission' then
        c = (area and CAMPAIGN_AREAS[area] and CAMPAIGN_COLOR[st]) or MISSION_COLOR[st]
    end
    c = c or COLOR[st] or COLOR.blocked

    local g = GLYPH[st] or 'bang'
    if hint and (st == 'progress' or st == 'turnin') then
        g = (hint.mob and MOB_GLYPH[hint.mob])
            or (hint.kind and STEP_GLYPH[hint.kind])
            or g
    end
    local t = GLYPH_TINT[g]
    if t then return g, t[1], t[2], t[3] end
    return g, c[1], c[2], c[3]
end
markers.STEP_GLYPH, markers.MOB_GLYPH = STEP_GLYPH, MOB_GLYPH
markers.GLYPH_TINT = GLYPH_TINT

-- Kept for //qm why's textual output.
local STYLE = setmetatable({}, {__index = function(_, st)
    if not COLOR[st] then return nil end
    return {GLYPH[st] or 'bang'}
end})

local cfg = {
    max_markers   = 16,
    icon_size     = 60,     -- px at ref_distance; tuned in game
    max_distance  = 50,
    floor_tol     = 6,      -- |dz| beyond this = different floor, hide
    head_offset   = 2.3,    -- tuned in game across races
    fade_start    = 15,     -- full alpha inside this
    min_alpha     = 90,
    max_alpha     = 255,
    scale_min     = 0.6,    -- flat mode only: smallest fraction of icon_size
    enabled       = true,

    --[[ Perspective sizing.

         With this off, a marker is a fixed number of screen pixels regardless
         of range, so it reads as a HUD overlay rather than something sitting
         in the world -- a distant NPC's marker looks the same size as one in
         front of you.

         With it on, the marker behaves like a fixed-size object in 3D: screen
         size is proportional to 1/depth, which is precisely what perspective
         division does to any real object. `w` from project.point() IS that
         depth (verified: w equals distance for a point straight ahead), so
         the whole thing is one division.

         Expressed as "icon_size pixels at ref_distance yalms" rather than as a
         world-space height, because those are units already used elsewhere:
         the default is 32 px at 8 yalms.

         Clamps matter. Unbounded 1/w fills the screen at point-blank range and
         vanishes below a pixel across a zone, so the result is bounded at both
         ends. ]]
    perspective   = true,
    ref_distance  = 8,      -- yalms at which icon_size is exact
    px_min        = 10,     -- never smaller than this
    px_max        = 180,    -- never larger than this (3x icon_size)

    --[[ Per-NPC height. A fixed offset clips a Galka's nameplate while floating
         absurdly high over a Tarutaru.

         `model_size` is 0 for every NPC in game, in every zone tested. It is
         useless here. Do not try to use it.

         `race` does work. Measured live: Clarion Star (Galka) = 8,
         Alib-Mufalib (Tarutaru male) = 5, Gulmama (Tarutaru female) = 6,
         Secodiand (Elvaan male) = 3, Corann (Hume male) = 1, Kaede (child) = 30.

         Race 0 is "Precomposed NPC" and covers a large minority (Moogles,
         Benita, Ronan...) -- those simply get the base offset, which is the
         honest answer since the race field tells us nothing about them.

         The factors below are eyeballed from in-game proportions relative to a
         Hume male, NOT measured. Tune with //qm sizescale (0 disables). ]]
    size_scale    = 1.0,
}

-- race id -> height relative to a Hume male
local RACE_HEIGHT = {
    [0]  = 1.00,   -- Precomposed NPC: unknown, use the base offset
    [1]  = 1.00,   -- Hume male
    [2]  = 0.94,   -- Hume female
    [3]  = 1.18,   -- Elvaan male
    [4]  = 1.09,   -- Elvaan female
    [5]  = 0.62,   -- Tarutaru male
    [6]  = 0.62,   -- Tarutaru female
    [7]  = 0.97,   -- Mithra
    [8]  = 1.24,   -- Galka
    [29] = 0.60,   -- Mithra child
    [30] = 0.60,   -- Elvaan/Hume child female
    [31] = 0.62,   -- Elvaan/Hume child male
    [32] = 1.30, [33] = 1.30, [34] = 1.30, [35] = 1.30, [36] = 1.30,  -- chocobos
}

function markers.config(t)
    for k, v in pairs(t or {}) do
        if cfg[k] ~= nil then cfg[k] = v end
    end
    return cfg
end
function markers.settings() return cfg end

-- --------------------------------------------------------------------------
-- Prim API (injectable so the pool logic is testable without a client)
-- --------------------------------------------------------------------------

local api
local function default_api()
    return {
        create   = function(n) windower.prim.create(n) end,
        delete   = function(n) windower.prim.delete(n) end,
        texture  = function(n, p) windower.prim.set_texture(n, p) end,
        pos      = function(n, x, y) windower.prim.set_position(n, x, y) end,
        size     = function(n, w, h) windower.prim.set_size(n, w, h) end,
        color    = function(n, a, r, g, b) windower.prim.set_color(n, a, r, g, b) end,
        visible  = function(n, v) windower.prim.set_visibility(n, v) end,
        fit      = function(n, v) windower.prim.set_fit_to_texture(n, v) end,
        path     = function() return windower.addon_path .. 'assets/' end,

        -- debug labels
        tcreate  = function(n) windower.text.create(n) end,
        tdelete  = function(n) windower.text.delete(n) end,
        ttext    = function(n, s) windower.text.set_text(n, s) end,
        tpos     = function(n, x, y) windower.text.set_location(n, x, y) end,
        tvisible = function(n, v) windower.text.set_visibility(n, v) end,
        tsetup   = function(n)
            windower.text.set_font(n, 'Consolas')
            windower.text.set_font_size(n, 9)
            windower.text.set_color(n, 255, 255, 255, 255)
            windower.text.set_bg_color(n, 160, 0, 0, 0)
            windower.text.set_bg_visibility(n, true)
        end,
    }
end

function markers.set_api(t) api = t end

-- --------------------------------------------------------------------------
-- Pool
-- --------------------------------------------------------------------------

local pool = {}          -- [i] = {name, shown, glyph, a, r, g, b, x, y, w, h}
local built = 0

--[[ Debug labels. A marker floating over empty space is impossible to
     diagnose from a screenshot -- you cannot tell WHICH NPC it belongs to or
     how far away that NPC is. With these on, every marker is captioned with
     its NPC, state, distance and screen position, so one screenshot identifies
     the culprit exactly. ]]
local labels = {}
local ghosts = {}          -- uncompensated position, debug only
local labels_built = 0
local debug_on = false

function markers.set_debug(v)
    debug_on = v and true or false
    if not debug_on then
        for i = 1, labels_built do
            if labels[i].shown then
                pcall(api.tvisible, labels[i].name, false)
                labels[i].shown = false
            end
            if ghosts[i] and ghosts[i].shown then
                pcall(api.visible, ghosts[i].name, false)
                ghosts[i].shown = false
            end
        end
    end
    return debug_on
end
function markers.debug() return debug_on end

markers.stats = {drawn = 0, culled_dist = 0, culled_floor = 0,
                 culled_screen = 0, prim_calls = 0}

local function slot_name(i) return ('questmarks_icon_%02d'):format(i) end

--[[ Icon size in pixels at clip depth `w`.

     Perspective mode: size ∝ 1/w, so the marker keeps a constant apparent size
     in the WORLD -- it grows as you approach and shrinks with range, like any
     real object. Exact at ref_distance, clamped at both ends.

     Flat mode: a fixed pixel size with a gentle linear taper toward scale_min
     at max_distance. Reads as a HUD overlay. ]]
function markers.size_at(w)
    if cfg.perspective then
        local d = (w and w > 0.01) and w or 0.01
        local px = cfg.icon_size * (cfg.ref_distance / d)
        if px < cfg.px_min then px = cfg.px_min
        elseif px > cfg.px_max then px = cfg.px_max end
        return math.floor(px + 0.5)
    end

    local scale = 1
    local span = cfg.max_distance - cfg.fade_start
    if span > 0 and w and w > cfg.fade_start then
        local t = (w - cfg.fade_start) / span
        if t > 1 then t = 1 end
        scale = 1 - t * (1 - cfg.scale_min)
    end
    return math.floor(cfg.icon_size * scale + 0.5)
end

--[[ Height above an NPC's origin, scaled by race.
     Unknown or unmapped races fall back to the flat offset. ]]
function markers.head_offset_for(c)
    if cfg.size_scale <= 0 or not c then return cfg.head_offset end
    local h = RACE_HEIGHT[c.race]
    if not h then return cfg.head_offset end
    -- size_scale blends between "no adjustment" (0) and the full race factor (1)
    return cfg.head_offset * (1 + cfg.size_scale * (h - 1))
end
markers.RACE_HEIGHT = RACE_HEIGHT

function markers.destroy()
    for i = 1, built do
        pcall(api.delete, pool[i].name)
    end
    for i = 1, labels_built do
        pcall(api.tdelete, labels[i].name)
        if ghosts[i] then pcall(api.delete, ghosts[i].name) end
    end
    pool, built = {}, 0
    labels, ghosts, labels_built = {}, {}, 0
end

function markers.init(n)
    if not api then api = default_api() end
    if built > 0 then markers.destroy() end

    n = n or cfg.max_markers

    --[[ Floor it, and floor it here so every caller is covered rather than one
         command. `//qm max` is `tonumber(a1)` with no integer check. A
         fractional `n` makes `base = n - limit` fractional, every
         `visible[base + i]` is nil, and the renderer throws on every frame.
         Three throws trip the circuit breaker, and `max_markers` is persisted
         and re-applied at login, so the addon comes back up already broken,
         with `//qm on` unable to clear it because the next frame throws again.
         `//qm max 3.5` is a typo, not an attack, and it must not be able to
         remove every marker in the game permanently. ]]
    n = math.floor(tonumber(n) or 0)
    if n < 0 then n = 0 end

    for i = 1, n do
        local name = slot_name(i)
        --[[ A prior hard crash can leave the name registered, and create() on
             an existing name is not documented to be safe. Delete first,
             unconditionally, and ignore the failure when it did not exist. ]]
        pcall(api.delete, name)
        api.create(name)
        api.texture(name, api.path() .. 'bang.png')
        api.fit(name, false)
        api.size(name, cfg.icon_size, cfg.icon_size)
        api.visible(name, false)
        pool[i] = {name = name, shown = false, glyph = 'bang',
                   a = -1, r = -1, g = -1, b = -1, x = -1, y = -1,
                   w = cfg.icon_size, h = cfg.icon_size}
    end
    built = n

    for i = 1, n do
        local name = ('questmarks_label_%02d'):format(i)
        pcall(api.tdelete, name)
        local ok = pcall(function()
            api.tcreate(name)
            api.tsetup(name)
            api.tvisible(name, false)
        end)
        labels[i] = {name = name, shown = false, text = nil, x = -1, y = -1,
                     usable = ok}

        --[[ Ghost marker: the UNCOMPENSATED position, drawn dim alongside the
             real one when debug is on. Whichever sits on the NPC is the one
             telling the truth, so a single screenshot settles whether
             compensation is helping or hurting at that instant. ]]
        local gname = ('questmarks_ghost_%02d'):format(i)
        pcall(api.delete, gname)
        pcall(function()
            api.create(gname)
            api.texture(gname, api.path() .. 'bang.png')
            api.fit(gname, false)
            api.color(gname, 110, 255, 255, 255)
            api.visible(gname, false)
        end)
        ghosts[i] = {name = gname, shown = false, x = -1, y = -1, w = -1}
    end
    labels_built = n

    return built
end

function markers.hide_all()
    for i = 1, built do
        local s = pool[i]
        if s.shown then
            api.visible(s.name, false)
            s.shown = false
            markers.stats.prim_calls = markers.stats.prim_calls + 1
        end
    end
    for i = 1, labels_built do
        local L = labels[i]
        if L.shown then pcall(api.tvisible, L.name, false); L.shown = false end
        local G = ghosts[i]
        if G and G.shown then pcall(api.visible, G.name, false); G.shown = false end
    end
end

-- Change-detected setters: native prim calls dominate the frame cost.
local function apply(s, glyph, x, y, size, a, r, g, b)
    local calls = 0
    if s.glyph ~= glyph then
        api.texture(s.name, api.path() .. glyph .. '.png')
        s.glyph = glyph
        calls = calls + 1
    end
    if s.w ~= size then
        api.size(s.name, size, size)
        s.w, s.h = size, size
        calls = calls + 1
    end
    if s.x ~= x or s.y ~= y then
        api.pos(s.name, x, y)
        s.x, s.y = x, y
        calls = calls + 1
    end
    if s.a ~= a or s.r ~= r or s.g ~= g or s.b ~= b then
        api.color(s.name, a, r, g, b)
        s.a, s.r, s.g, s.b = a, r, g, b
        calls = calls + 1
    end
    if not s.shown then
        api.visible(s.name, true)
        s.shown = true
        calls = calls + 1
    end
    markers.stats.prim_calls = markers.stats.prim_calls + calls
end

--[[ Draw one frame.

     `candidates` is an array of {x, y, z, state} in MOB space. markers.lua
     never touches quest data -- that separation is what lets a 2D renderer be
     swapped in without changing anything upstream.

     `player` is {x, y, z} for the distance and same-floor tests.

     Returns the number drawn, or nil (having hidden everything) if the camera
     is unusable this frame. ]]
function markers.render(candidates, player)
    local st = markers.stats
    st.drawn, st.culled_dist, st.culled_floor, st.culled_screen, st.prim_calls = 0, 0, 0, 0, 0

    if not cfg.enabled or built == 0 then markers.hide_all() return 0 end

    if not project.begin() then
        -- Camera unusable (zoning, cutscene, or a failed layout self-test).
        -- Hide rather than draw at plausible-but-wrong positions.
        markers.hide_all()
        return nil
    end

    local maxd2 = cfg.max_distance * cfg.max_distance
    local visible, n = {}, 0

    for i = 1, #candidates do
        local c = candidates[i]
        local keep = true

        if player then
            local dx, dy = c.x - player.x, c.y - player.y
            local d2 = dx*dx + dy*dy
            if d2 > maxd2 then
                keep = false
                st.culled_dist = st.culled_dist + 1
            elseif cfg.floor_tol > 0 and math.abs(c.z - player.z) > cfg.floor_tol then
                --[[ Cheap stand-in for occlusion. Kills the worst offenders:
                     Jeuno's tiers, Metalworks, Whitegate levels, mog houses. ]]
                keep = false
                st.culled_floor = st.culled_floor + 1
            end
        end

        if keep then
            -- `c` doubles as this marker's smoothing state; it survives
            -- between scans, which is many frames.
            local sx, sy, w = project.above(c.x, c.y, c.z,
                                            markers.head_offset_for(c), c)
            if sx then
                local rx, ry = project.raw_of()
                n = n + 1
                visible[n] = {sx = sx, sy = sy, w = w, state = c.state, ref = c,
                              rx = rx, ry = ry}
            else
                st.culled_screen = st.culled_screen + 1
            end
        end
    end

    --[[ Farthest first, so that IF draw order follows creation order the
         nearest markers land on top. Draw order is not documented, so this is
         a free best-effort: when the assumption holds it is correct, and when
         it does not the overlap was arbitrary anyway. ]]
    table.sort(visible, function(a, b) return a.w > b.w end)

    --[[ Two concerns share one array, so keep them apart.

         The sort above is the DRAW order. The pool budget is a SELECTION, and
         the two want opposite ends: when candidates outnumber slots the ones
         that must lose are the FARTHEST, never the nearest. Do not take the
         budget off the front of a farthest-first array: that keeps the wrong
         half and drops every NPC the player is standing next to.

         Flipping the comparator would fix the selection and destroy the
         z-order, so instead take the budget off the BACK: the last `limit`
         entries of a farthest-first array are the nearest `limit`, and they are
         still in farthest-first order among themselves. One sort, both
         orderings, and `base` is the only new arithmetic. ]]
    local limit = built < n and built or n
    local base = n - limit           -- entries [1..base] are the farthest, dropped
    local fade_span = cfg.max_distance - cfg.fade_start

    for i = 1, limit do
        local v = visible[base + i]
        local glyph, cr, cg, cb = style_for(v.state, v.ref.cat, v.ref.area, v.ref.hint)

        local alpha = cfg.max_alpha
        if fade_span > 0 and v.w > cfg.fade_start then
            local t = (v.w - cfg.fade_start) / fade_span
            if t > 1 then t = 1 end
            alpha = math.floor(cfg.max_alpha - t * (cfg.max_alpha - cfg.min_alpha))
        end

        local size = markers.size_at(v.w)

        apply(pool[i], glyph,
              math.floor(v.sx - size * 0.5), math.floor(v.sy - size * 0.5),
              size, alpha, cr, cg, cb)
        v.ref.screen_x, v.ref.screen_y = v.sx, v.sy

        --[[ Caption each marker with everything needed to diagnose a bad one
             from a single screenshot: which NPC it belongs to, how far away
             that NPC is, and how big the lag correction currently is. ]]
        --[[ Ghost at the uncompensated position. If the ghost sits on the NPC
             and the solid marker does not, compensation is hurting at that
             instant; if the reverse, it is helping. Directly observable. ]]
        local G = ghosts[i]
        if G then
            if debug_on and v.rx then
                local gx = math.floor(v.rx - size * 0.5)
                local gy = math.floor(v.ry - size * 0.5)
                if G.w ~= size then api.size(G.name, size, size); G.w = size end
                if G.x ~= gx or G.y ~= gy then
                    api.pos(G.name, gx, gy); G.x, G.y = gx, gy
                end
                if not G.shown then api.visible(G.name, true); G.shown = true end
            elseif G.shown then
                api.visible(G.name, false); G.shown = false
            end
        end

        local L = labels[i]
        if debug_on and L and L.usable then
            --[[ SIGNED push, not just magnitude. Direction is the whole
                 question: a marker pushed the same way the scene is moving is
                 over-correcting, the opposite way is under-correcting, and a
                 magnitude alone cannot distinguish them. ]]
            local ex, ey = 0, 0
            if v.rx then ex, ey = v.sx - v.rx, v.sy - v.ry end
            local txt = ('%s  %s  d=%.1f  push=%+.0f,%+.0f  %dpx')
                :format(v.ref.name or '?', v.state, v.w or -1, ex, ey, size)
            if L.text ~= txt then api.ttext(L.name, txt); L.text = txt end
            local lx, ly = math.floor(v.sx + size * 0.5 + 4), math.floor(v.sy - 6)
            if L.x ~= lx or L.y ~= ly then
                api.tpos(L.name, lx, ly); L.x, L.y = lx, ly
            end
            if not L.shown then api.tvisible(L.name, true); L.shown = true end
        elseif L and L.shown then
            api.tvisible(L.name, false); L.shown = false
        end
    end

    for i = limit + 1, built do
        local s = pool[i]
        if s.shown then
            api.visible(s.name, false)
            s.shown = false
            st.prim_calls = st.prim_calls + 1
        end
        local L = labels[i]
        if L and L.shown then api.tvisible(L.name, false); L.shown = false end
        local G = ghosts[i]
        if G and G.shown then api.visible(G.name, false); G.shown = false end
    end

    st.drawn = limit
    return limit
end

--[[ Resolve which way is up, once, from a real entity position. Called by the
     entry point the first time a candidate is in view; see project.lua for why
     the sign is measured rather than assumed. ]]
local vsign_done = false
function markers.ensure_vertical_sign(x, y, z)
    if vsign_done then return true end
    if project.resolve_vertical_sign(x, y, z) then
        vsign_done = true
        return true
    end
    return false
end
function markers.reset_vertical_sign() vsign_done = false end

markers.STYLE = STYLE
markers.GLYPH = GLYPH
markers.COLOR = COLOR
markers.MISSION_COLOR = MISSION_COLOR
markers.CAMPAIGN_COLOR = CAMPAIGN_COLOR
markers.CAMPAIGN_AREAS = CAMPAIGN_AREAS
markers.style_for = style_for

return markers
