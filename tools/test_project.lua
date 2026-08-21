-- Offline verification of render/project.lua against the REAL camera state
-- captured from a live client on 2026-07-31.

local CAM = {
    valid = true,
    x = 104.2866897583, y = -7.336763381958, z = -49.785369873047,
    aspect = 1.7777775526047,
    fov_h = 1.3954982757568, fov_v = 0.92314583063126,
    matrix = {
        {0.89215463399887, -0.085574641823769,  0.44355046749115, 0},
        {0,                -0.98189264535904,  -0.18943755328655, 0},
        {0.45173007249832,  0.16900758445263,  -0.87600016593933, 0},
        {-70.550308227539, 10.1344871521,      -91.258255004883,  1},
    },
    matrix_inverse = {
        {0.89215475320816, -7.4505823732807e-09, 0.45173013210297, 0},
        {-0.08557466417551, -0.98189288377762,   0.16900762915611, 0},
        {0.44355055689812, -0.18943758308887,   -0.87600028514862, 0},
        {104.2866897583,   -7.336763381958,     -49.785369873047,  1},
    },
    projection_matrix = {
        {1.1926798820496, 0,               0,                0},
        {0,               2.0104167461395, 0,                0},
        {0,               0,              -1.0000015497208, -1},
        {0,               0,              -0.10000015795231, 0},
    },
}

_G.windower = {
    get_camera = function() return CAM end,
    get_windower_settings = function()
        return {x_res = 2560, y_res = 1440, ui_x_res = 1280, ui_y_res = 720}
    end,
}

--[[ Bootstrap package.path from this file's own location, so the suite runs
     from a clone anywhere and not just from one machine's install. Inline
     rather than a local because test_core.lua's main chunk is on Lua's
     200-local ceiling. tools/lib/root.lua does the same job for every use
     after this line. ]]
package.path = (function()
    local s = debug.getinfo(1, 'S').source:sub(2):gsub(string.char(92), '/')
    if not s:match('^%a:/') and not s:match('^/') then
        local p = io.popen('cd')
        if p then
            local c = p:read('*l'); p:close()
            if c and c ~= '' then s = c:gsub(string.char(92), '/') .. '/' .. s end
        end
    end
    return ((s:match('^(.*)/tools/[^/]*$')) or '.'):gsub('/%%./', '/'):gsub('/%%.$', '')
end)() .. '/?.lua;' .. package.path
local P = require('render/project')

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then pass = pass + 1; print(('  PASS  %-46s %s'):format(name, detail or ''))
    else       fail = fail + 1; print(('  FAIL  %-46s %s'):format(name, detail or '')) end
end

print('=== project.begin() ===')
check('begin() succeeds', P.begin() == true, tostring(P.last_error))

local vw, vh = P.viewport()
check('viewport is ui space', vw == 1280 and vh == 720, ('%dx%d'):format(vw, vh))

--[[ The camera basis in world space is rows 1-3 of matrix_inverse.
     P[3][4] = -1 so w = -z_view: visible points lie along -Z_camera.
     Therefore forward = -matrix_inverse[3].                              ]]
local mi = CAM.matrix_inverse
local fwd = {-mi[3][1], -mi[3][2], -mi[3][3]}
local right = {mi[1][1], mi[1][2], mi[1][3]}
local up = {mi[2][1], mi[2][2], mi[2][3]}

-- These are VIEW-space (Y-up). project.point() takes MOB space (Z-up),
-- and the resolved mapping is view(x,y,z) = mob(x, z, y) -- so invert it.
local function view_to_mob(vx, vy, vz) return vx, vz, vy end

local function ahead(dist, dr, du)
    dr, du = dr or 0, du or 0
    return view_to_mob(
        CAM.x + fwd[1]*dist + right[1]*dr + up[1]*du,
        CAM.y + fwd[2]*dist + right[2]*dr + up[2]*du,
        CAM.z + fwd[3]*dist + right[3]*dr + up[3]*du)
end

print('\n=== centre / culling ===')
local sx, sy, w = P.point(ahead(10))
check('10y ahead projects', sx ~= nil, sx and ('(%.1f, %.1f) w=%.2f'):format(sx, sy, w) or 'nil')
if sx then
    check('  ... lands at screen centre',
        math.abs(sx - 640) < 1.5 and math.abs(sy - 360) < 1.5,
        ('dx=%.3f dy=%.3f'):format(sx - 640, sy - 360))
    check('  ... w equals distance', math.abs(w - 10) < 0.01, ('w=%.4f'):format(w))
end

local bx = P.point(ahead(-10))
check('behind camera is culled', bx == nil, bx and 'DREW' or 'nil')

local ox = P.point(ahead(10, 400, 0))
check('far off-axis is culled', ox == nil, ox and 'DREW' or 'nil')

print('\n=== orientation ===')
local rx, ry = P.point(ahead(10, 2, 0))
check('right of centre -> larger x', rx and rx > 640, rx and ('x=%.1f'):format(rx) or 'nil')
local _, uy = P.point(ahead(10, 0, 2))
check('above centre -> smaller y', uy and uy < 360, uy and ('y=%.1f'):format(uy) or 'nil')

print('\n=== fov consistency ===')
-- A point exactly at the horizontal fov edge must land on the screen edge.
local half_h = math.tan(CAM.fov_h / 2)
local ex = P.point(ahead(10, 10 * half_h, 0))
check('fov_h edge lands at screen right edge',
    ex and math.abs(ex - 1280) < 2, ex and ('x=%.2f (want 1280)'):format(ex) or 'nil')
local _, ey = P.point(ahead(10, 0, 10 * math.tan(CAM.fov_v / 2)))
check('fov_v edge lands at screen top edge',
    ey and math.abs(ey - 0) < 2, ey and ('y=%.2f (want 0)'):format(ey) or 'nil')

print('\n=== vertical sign resolution ===')
local mx, my, mz = ahead(15)
local ok, vs = P.resolve_vertical_sign(mx, my, mz)
check('resolve_vertical_sign converges', ok, ok and ('vsign=%d'):format(vs) or 'no separation')
local _, y_head = P.above(mx, my, mz, 2.0)
local _, y_feet = P.point(mx, my, mz)
check('above() draws higher than feet', y_head and y_feet and y_head < y_feet,
    (y_head and y_feet) and ('head=%.1f feet=%.1f'):format(y_head, y_feet) or 'nil')

print('\n=== lag compensation ===')
--[[ Compensation is ON by default, at lag = 1.0 in both render/project.lua
     and the addon settings: one frame of camera movement, measured in game.
     These tests set it explicitly anyway, so they still say what they mean
     if the default ever moves. ]]
P.set_lag(1)
local px, py, pz = ahead(12)

-- A static camera, several frames running: the position must not drift.
P.begin(); local s0 = select(1, P.point(px, py, pz))
P.begin(); local s1 = select(1, P.point(px, py, pz))
P.begin(); local s2 = select(1, P.point(px, py, pz))
check('static camera -> no drift at all',
      s0 and math.abs(s1 - s0) < 1e-6 and math.abs(s2 - s0) < 1e-6,
      ('%.6f %.6f %.6f'):format(s0 or -1, s1 or -1, s2 or -1))

-- Slide the camera sideways a fixed amount per frame; the view matrix's 4th
-- row is the translation component, so nudging it simulates camera motion.
local function slide(n)
    CAM.matrix[4][1] = -70.550308227539 + n
end
local function frame(n) slide(n); P.begin(); return (P.point(px, py, pz)) end

slide(0); P.begin(); P.point(px, py, pz)
local a = frame(1)           -- steady motion, frame 1
local b = frame(2)           -- steady motion, frame 2
local raw = (function()      -- same frame, compensation disabled
    P.set_lag(0); slide(2); P.begin(); local r = (P.point(px, py, pz))
    P.set_lag(1); return r
end)()
check('steady motion is extrapolated ahead of the raw position',
      b and raw and math.abs(b - raw) > 0.5,
      ('compensated %.2f vs raw %.2f'):format(b or -1, raw or -1))

--[[ Direction reversal between the one-frame and two-frame estimates means
     jitter, not motion. The filter must emit zero rather than extrapolate it. ]]
P.set_lag(1)
slide(0); P.begin(); P.point(px, py, pz)
slide(6); P.begin(); P.point(px, py, pz)
slide(0); P.begin()                       -- snapped back: d1 and d2 disagree
local jitter = (P.point(px, py, pz))
slide(0); P.set_lag(0); P.begin()
local jitter_raw = (P.point(px, py, pz))
P.set_lag(1)
check('direction reversal is rejected, not amplified',
      jitter and jitter_raw and math.abs(jitter - jitter_raw) < 1e-6,
      ('filtered %.3f vs raw %.3f'):format(jitter or -1, jitter_raw or -1))

--[[ Frame-time normalisation. A hitched frame produces a genuinely large delta
     that BOTH estimates corroborate, so the corroboration filter passes it and
     it gets extrapolated in full -- throwing the marker. Compensation must be
     measured in time, not in frames. ]]
P.set_lag(1)
local t = 0
P.set_clock(function() return t end)

local function steady_frames(dt, n, from)
    -- Run n frames of constant-velocity camera motion at a fixed frame time.
    local pos = from
    local last
    for _ = 1, n do
        t = t + dt
        pos = pos + 1
        slide(pos)
        P.begin()
        last = (P.point(px, py, pz))
    end
    return last, pos
end

-- Settle at a steady 60 fps, then take one identical-motion frame.
CAM.matrix[4][1] = -70.550308227539
last_t = nil
local normal, pos = steady_frames(1/60, 12, 0)

-- Same camera movement, but the frame took 4x as long.
t = t + (1/60) * 4
pos = pos + 1
slide(pos)
P.begin()
local hitched = (P.point(px, py, pz))

local _, ratio = P.timing()
check('a long frame scales its correction DOWN', ratio < 0.6,
      ('dt_ratio %.3f'):format(ratio))
--[[ Bound is MAX_PUSH (45 px) plus a pixel of rounding: the correction is
     clamped there, so no two frames can ever differ by more than that however
     badly the frame time misbehaves. Asserting a tighter arbitrary number just
     re-tunes itself every time the estimator changes. ]]
check('hitched frame stays within the correction clamp',
      normal and hitched and math.abs(hitched - normal) <= 46,
      ('normal %.1f vs hitched %.1f (delta %.1f)')
        :format(normal or -1, hitched or -1, math.abs((hitched or 0) - (normal or 0))))

P.set_clock(nil)
CAM.matrix[4][1] = -70.550308227539       -- restore
check('lag is configurable and clamped',
      P.set_lag(99) == 3 and P.set_lag(-1) == 0 and P.set_lag(1) == 1)

print('\n=== deceleration must not be extrapolated through ===')
--[[ Measured from six consecutive in-game frames: the marker spiked +70 px
     then snapped back -82 px. Cause: the camera moved a long way in one frame
     and then eased off, but the one-frame and two-frame estimates still
     pointed the SAME WAY, so an agreement-only test passed the stale large
     value through. Magnitude now comes from the smaller estimate. ]]
P.set_lag(1); P.set_smooth(0); P.set_clock(nil)

local function frames_at(offsets)
    -- Drive the camera through explicit per-frame positions, return the final
    -- compensated and raw screen x.
    CAM.matrix[4][1] = -70.550308227539
    for _, o in ipairs(offsets) do slide(o); P.begin(); P.point(px, py, pz) end
    local comp = (P.point(px, py, pz))
    return comp
end

-- Steady motion: 4 px per frame throughout.
local steady = frames_at{0, 4, 8, 12, 16}
-- Same history, but the LAST frame barely moves (deceleration).
local decel  = frames_at{0, 4, 8, 12, 12.3}

P.set_lag(0)
local decel_raw = frames_at{0, 4, 8, 12, 12.3}
P.set_lag(1)

check('deceleration is not over-extrapolated',
      decel and decel_raw and math.abs(decel - decel_raw) < math.abs(steady - decel_raw),
      ('decel err %.1f vs steady-style err %.1f'):format(
        math.abs((decel or 0) - (decel_raw or 0)),
        math.abs((steady or 0) - (decel_raw or 0))))

CAM.matrix[4][1] = -70.550308227539
P.set_smooth(0.3)

print('\n=== a stopped camera must drop the correction at once ===')
--[[ Observed in game: when the camera stopped, the uncompensated ghost sat on
     the NPC while the compensated marker was well to its right, crawling back
     over several frames. Cause: a symmetric EMA keeps feeding the previous
     correction after it is no longer needed. Smoothing is now asymmetric --
     gentle while the correction grows, near-instant while it shrinks. ]]
P.set_lag(1); P.set_smooth(0.55); P.set_clock(nil)
local sst = {}
CAM.matrix[4][1] = -70.550308227539
-- Small steps: a large slide moves the point off screen and it gets culled,
-- so no correction is ever built.
for _, o in ipairs{0, 1, 2, 3, 4} do slide(o); P.begin(); P.point(px, py, pz, sst) end
local moving_push = math.sqrt((sst.qm_cx or 0)^2 + (sst.qm_cy or 0)^2)
check('a moving camera builds a correction', moving_push > 5,
      ('%.1f px'):format(moving_push))

-- Camera stops dead: same position for the next frames.
slide(4); P.begin(); P.point(px, py, pz, sst)
local after1 = math.sqrt((sst.qm_cx or 0)^2 + (sst.qm_cy or 0)^2)
slide(4); P.begin(); P.point(px, py, pz, sst)
local after2 = math.sqrt((sst.qm_cx or 0)^2 + (sst.qm_cy or 0)^2)

check('one frame after the stop the correction has mostly gone',
      after1 < moving_push * 0.25,
      ('%.1f px -> %.1f px'):format(moving_push, after1))
check('two frames after the stop it is essentially zero', after2 < 1.0,
      ('%.2f px'):format(after2))

CAM.matrix[4][1] = -70.550308227539
P.set_smooth(0.3)

print('\n=== smoothing ===')
--[[ Smoothing must never move a marker that is standing still: it low-passes
     the CORRECTION, and the correction at rest is zero. ]]
P.set_lag(1); P.set_smooth(0.55)
local sm = {}
-- Settle first: the preceding block leaves the camera displaced, and the
-- resulting correction must be allowed to decay before measuring "at rest".
for _ = 1, 4 do slide(0); P.begin(); P.point(px, py, pz, sm) end
slide(0); P.begin(); local rest1 = (P.point(px, py, pz, sm))
slide(0); P.begin(); local rest2 = (P.point(px, py, pz, sm))
check('smoothing adds no drift at rest',
      rest1 and math.abs(rest2 - rest1) < 1e-6,
      ('%.6f vs %.6f'):format(rest1 or -1, rest2 or -1))

--[[ A correction must RAMP rather than snap on. Given identical camera motion
     each frame, a smoothed marker moves less on the first frame of the turn
     than an unsmoothed one -- that gap is the shimmer being removed. ]]
local function run(smooth_v, state)
    P.set_smooth(smooth_v)
    CAM.matrix[4][1] = -70.550308227539
    slide(0); P.begin(); P.point(px, py, pz, state)
    slide(1); P.begin(); P.point(px, py, pz, state)
    slide(2); P.begin(); return (P.point(px, py, pz, state))
end
local raw_first    = run(0,    {})
local smooth_first = run(0.55, {})
check('smoothing ramps the correction in instead of snapping',
      raw_first and smooth_first and smooth_first < raw_first,
      ('smoothed %.1f < raw %.1f'):format(smooth_first or -1, raw_first or -1))
check('smoothing is configurable and clamped',
      P.set_smooth(9) == 0.95 and P.set_smooth(-1) == 0 and P.set_smooth(0.55) == 0.55)
CAM.matrix[4][1] = -70.550308227539

print('\n=== self-test guard ===')
local saved = CAM.matrix_inverse
CAM.matrix_inverse = {{1,0,0,0},{0,1,0,0},{0,0,1,0},{999,999,999,1}}
check('bad matrix_inverse refuses to draw', P.begin() == false, tostring(P.last_error))
CAM.matrix_inverse = saved
check('recovers after restore', P.begin() == true, tostring(P.last_error))

CAM.valid = false
check('invalid camera refuses to draw', P.begin() == false, tostring(P.last_error))
CAM.valid = true

print(('\n%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)

