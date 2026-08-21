--[[
project.lua -- world -> screen projection.

The layout constants below were resolved empirically on 2026-07-31 against
LuaCore 2.6.8.2. `windower.get_camera()` is real but wholly undocumented, so
every one of these was measured, not assumed:

  matrix          nested table, 1-indexed, m[row][col]        (flat[16] failed)
  convention      row-vector: v' = v * M                      (eye->origin = 0.000)
  matrix          a PURE VIEW matrix, orthonormal upper-3x3   (ortho err = 0.000)
                  -> must be composed with projection_matrix
  matrix_inverse  row 4 IS the camera world position          (exact match)
  fov_v / fov_h   FULL angles in RADIANS
                  1/tan(fov_h/2) = 1.19268 = projection_matrix[1][1]  (exact)
                  1/tan(fov_v/2) = 2.01042 = projection_matrix[2][2]  (exact)
  projection      right-handed D3D: P[3][4] = -1, so w = -z_view
  axes            the camera table is Y-up, mob coordinates are Z-up
                  -> view(x, y, z) = mob(x, z, y)
  screen space    ui_x_res / ui_y_res, NOT x_res / y_res
                  (verified install: 2560x1440 raw vs 1280x720 ui, uiscale=2)

The vertical SIGN is deliberately not baked -- it is resolved at runtime by
resolve_vertical_sign(), which projects a point above and below an entity and
keeps whichever lands higher on screen. Cheaper to measure than to argue about.

If a future Windower build changes any of this, `//qm probe` reports it and
project.begin() refuses to draw rather than placing markers wrongly.
]]

local project = {}

-- Resolved layout. Overridable at runtime via //qm layout for other builds.
local L = {
    nested   = true,                        -- m[row][col], 1-indexed
    vec      = 'row',                       -- v' = v * M
    viewproj = false,                       -- `matrix` is view only
    order    = {1, 3, 2},                   -- view(x,y,z) = mob(x, z, y)
    sign     = {1, 1, 1},
    --[[ FFXI's world vertical axis points DOWN, so "2 yalms above a head" is
         mob.z MINUS 2. Measured, not assumed: the offline harness against the
         real captured camera resolves -1, and baking +1 would have put every
         marker under the NPC's feet. Still re-resolved at runtime by
         resolve_vertical_sign() -- this is only the starting value. ]]
    vsign    = -1,
}

-- Per-frame cache. Only columns 1, 2 and 4 of (V*P) are ever needed.
local a11, a21, a31, a41
local a12, a22, a32, a42
local a14, a24, a34, a44
local hw, hh = 0, 0
local live = false

--[[ Previous frame's matrix, kept for lag compensation.

     `windower.get_camera()` returns the matrix as of when Lua runs, but the
     frame the player SEES is composited afterwards with a slightly newer
     camera. The result is that markers visibly drag behind during fast camera
     movement -- they slide like they are on ice and settle when you stop.

     Rather than guess at the latency, measure it: project each point with BOTH
     the current and previous matrices. The difference IS how far the camera
     moved this frame, in screen space, for that exact point. Adding it forward
     extrapolates one frame ahead. It self-cancels when the camera is still
     (delta zero) and scales automatically with rotation speed. ]]
local p11, p21, p31, p41
local p12, p22, p32, p42
local p14, p24, p34, p44
local have_prev = false

--[[ And the frame before that. One frame of history is a NOISY velocity
     estimate: a single hitched frame produces a spike that gets extrapolated
     into a visible throw-and-snap. Two frames let us cross-check -- see the
     estimator in project.point(). ]]
local q11, q21, q31, q41
local q12, q22, q32, q42
local q14, q24, q34, q44
local have_prev2 = false

--[[ The lag is real. Measured against the game's own nameplate: at rest the
     marker sits within ~1 px, while panning it trails 31-37 px behind.

     The estimator that corrects it is not reliable. Do not read a push of 0 as
     proof the marker is placed right; measure it. That is what
     project.raw_of() is for, so the debug view can draw the uncompensated
     position next to the compensated one and you can compare them in one
     frame. ]]
local lag = 1.0

--[[ How heavily to smooth each marker's correction. 0 = react instantly (and
     inherit every frame's noise), 1 = never change. See project.point(). ]]
local smooth = 0.3

--[[ Frame timing, so compensation is measured in TIME rather than in frames.

     The screen delta between two matrices is movement over whatever the last
     frame happened to take. Extrapolating it assumes the next frame takes the
     same time -- and when the client hitches, it does not. A long frame yields
     a genuinely large delta which both estimates corroborate (it really was
     motion), so it survives the filter and gets applied in full, throwing the
     marker.

     So: convert the delta to a velocity, then re-scale it to the frame time we
     actually EXPECT (a smoothed average). A hitched frame contributes a
     normal-sized correction instead of a proportionally huge one.

     os.clock() is wall time on Windows (MSVC's clock() measures elapsed time,
     not CPU time), so it is usable for this. Injectable for tests. ]]
local last_t = nil
local dt_ema = nil
local dt_ratio = 1
local clock = os.clock

function project.set_clock(fn) clock = fn or os.clock end

local o1, o2, o3, s1, s2, s3

-- Viewport is refreshed at 1 Hz, not per frame.
local vp_w, vp_h, vp_at = 1280, 720, -1e9

local NEAR = 0.05          -- clip-w below this is behind/on the near plane
local NDC_SLACK = 1.6      -- generous, so partly-visible icons still draw

-- Uncompensated screen position of the most recent point(); see raw_of().
local last_raw_x, last_raw_y

project.last_error = nil
project.frames_failed = 0        -- CONSECUTIVE; zeroed by the next good frame

--[[ ...and the same evidence in a form that is never erased.

     `frames_failed` answers "is the camera bad right now", which is what
     begin() itself needs -- but zeroing it on the next success also destroys
     the record of an intermittent fault. A camera that blanks every marker one
     frame in three must not look like one that never faltered. Every refusal
     hides every marker, so that is the exact fault a bug report needs to name.

     Three cumulative fields, none of them ever cleared: how many frames were
     refused in total, the worst unbroken run, and the last reason. `//qm diag`
     prints all three. ]]
project.frames_failed_total = 0
project.frames_failed_worst = 0
project.last_fail_error = nil

function project.configure(layout)
    for k, v in pairs(layout or {}) do L[k] = v end
    o1, o2, o3 = L.order[1], L.order[2], L.order[3]
    s1, s2, s3 = L.sign[1], L.sign[2], L.sign[3]
end
project.configure{}

function project.layout()
    return L
end

local function get(m, r, c)
    if L.nested then
        local row = m[r]
        return row and row[c]
    end
    return m[(r - 1) * 4 + c]
end

--[[ Called once per frame before any project.point() call.
     Returns false when the camera is unusable; the caller MUST then hide every
     marker. Drawing on a failed frame would place markers at plausible but
     wrong positions, which is worse than drawing nothing. ]]
function project.set_lag(v)
    lag = math.max(0, math.min(3, tonumber(v) or 1))
    return lag
end
function project.lag() return lag end

function project.set_smooth(v)
    smooth = math.max(0, math.min(0.95, tonumber(v) or 0.55))
    return smooth
end
function project.smooth() return smooth end

--[[ Forget the matrix history and the frame-time average.

     Call this whenever the sampling POINT in the frame changes -- switching
     between the prerender and postrender hooks is the case that matters. The
     two cached matrices would then straddle the switch, so their difference
     spans a partial frame and the velocity estimate is nonsense for exactly
     one frame: a visible throw at the very moment you are trying to compare
     the two hooks. Dropping the history costs one uncompensated frame instead,
     which is the honest answer. ]]
function project.reset_history()
    have_prev, have_prev2 = false, false
    live = false
    last_t, dt_ema, dt_ratio = nil, nil, 1
end

--[[ Record one refused frame and answer `false` for begin().
     Single funnel so the seven refusal sites cannot drift apart -- they already
     had to remember two assignments each, and the cumulative ledger would have
     made it four. ]]
local function refuse(why)
    project.last_error = why
    project.last_fail_error = why
    project.frames_failed = project.frames_failed + 1
    project.frames_failed_total = project.frames_failed_total + 1
    if project.frames_failed > project.frames_failed_worst then
        project.frames_failed_worst = project.frames_failed
    end
    return false
end

function project.begin()
    -- Frame timing for time-normalised compensation (see dt_ratio above).
    do
        local now = clock()
        local dt = last_t and (now - last_t) or nil
        last_t = now
        if dt and dt > 0.0005 and dt < 0.5 then
            dt_ema = dt_ema and (dt_ema * 0.85 + dt * 0.15) or dt
            local r = dt_ema / dt
            dt_ratio = (r < 0.25 and 0.25) or (r > 2 and 2) or r
        else
            -- First frame, or a pause/alt-tab long enough that the gap says
            -- nothing about rendering cadence.
            dt_ratio = 1
        end
    end

    -- Age the history one frame before this frame's matrix overwrites it.
    if live then
        if have_prev then
            q11, q21, q31, q41 = p11, p21, p31, p41
            q12, q22, q32, q42 = p12, p22, p32, p42
            q14, q24, q34, q44 = p14, p24, p34, p44
            have_prev2 = true
        end
        p11, p21, p31, p41 = a11, a21, a31, a41
        p12, p22, p32, p42 = a12, a22, a32, a42
        p14, p24, p34, p44 = a14, a24, a34, a44
        have_prev = true
    else
        have_prev, have_prev2 = false, false
    end
    live = false

    local cam = windower.get_camera()
    if not cam then
        return refuse('get_camera() returned nil')
    end
    if cam.valid == false then
        return refuse('camera not valid (zoning or cutscene)')
    end

    local m = cam.matrix
    if not m then
        return refuse('no matrix')
    end

    --[[ Continuous self-test, 3 float compares.
         For a pure view matrix in this layout, row 4 of matrix_inverse IS the
         camera world position. Measured exact on the reference capture. If it
         ever stops holding, our baked layout is wrong for this build and we
         must not draw. ]]
    local mi = cam.matrix_inverse
    if mi then
        local ex, ey, ez = get(mi, 4, 1), get(mi, 4, 2), get(mi, 4, 3)
        if type(ex) ~= 'number' or type(cam.x) ~= 'number'
           or math.abs(ex - cam.x) + math.abs(ey - cam.y) + math.abs(ez - cam.z) > 0.5 then
            return refuse('matrix layout self-test failed')
        end
    end

    local v11, v12, v13, v14 = get(m,1,1), get(m,1,2), get(m,1,3), get(m,1,4)
    local v21, v22, v23, v24 = get(m,2,1), get(m,2,2), get(m,2,3), get(m,2,4)
    local v31, v32, v33, v34 = get(m,3,1), get(m,3,2), get(m,3,3), get(m,3,4)
    local v41, v42, v43, v44 = get(m,4,1), get(m,4,2), get(m,4,3), get(m,4,4)
    if type(v11) ~= 'number' or type(v44) ~= 'number' then
        return refuse('matrix unreadable in configured layout')
    end

    if L.viewproj then
        a11, a21, a31, a41 = v11, v21, v31, v41
        a12, a22, a32, a42 = v12, v22, v32, v42
        a14, a24, a34, a44 = v14, v24, v34, v44
    else
        local p = cam.projection_matrix
        if not p then
            return refuse('no projection_matrix')
        end
        local p11, p12, p14 = get(p,1,1), get(p,1,2), get(p,1,4)
        local p21, p22, p24 = get(p,2,1), get(p,2,2), get(p,2,4)
        local p31, p32, p34 = get(p,3,1), get(p,3,2), get(p,3,4)
        local p41, p42, p44 = get(p,4,1), get(p,4,2), get(p,4,4)
        if type(p11) ~= 'number' then
            return refuse('projection_matrix unreadable')
        end

        -- A = V * P, but only columns 1, 2 and 4 are ever read.
        a11 = v11*p11 + v12*p21 + v13*p31 + v14*p41
        a21 = v21*p11 + v22*p21 + v23*p31 + v24*p41
        a31 = v31*p11 + v32*p21 + v33*p31 + v34*p41
        a41 = v41*p11 + v42*p21 + v43*p31 + v44*p41

        a12 = v11*p12 + v12*p22 + v13*p32 + v14*p42
        a22 = v21*p12 + v22*p22 + v23*p32 + v24*p42
        a32 = v31*p12 + v32*p22 + v33*p32 + v34*p42
        a42 = v41*p12 + v42*p22 + v43*p32 + v44*p42

        a14 = v11*p14 + v12*p24 + v13*p34 + v14*p44
        a24 = v21*p14 + v22*p24 + v23*p34 + v24*p44
        a34 = v31*p14 + v32*p24 + v33*p34 + v34*p44
        a44 = v41*p14 + v42*p24 + v43*p34 + v44*p44
    end

    -- prim/text coordinates live in ui_*_res space (see libs/texts.lua:381)
    local now = os.clock()
    if now - vp_at > 1.0 then
        local ws = windower.get_windower_settings()
        if ws then
            vp_w, vp_h, vp_at = ws.ui_x_res, ws.ui_y_res, now
        end
    end
    hw, hh = vp_w * 0.5, vp_h * 0.5

    project.frames_failed = 0
    project.last_error = nil
    live = true
    return true
end

--[[ Mob-space point -> prim-space pixel.
     Returns sx, sy, w. nil means culled (behind the camera or off-screen).

     `st` is an optional per-marker table used to smooth that marker's lag
     correction across frames. Pass the same table for the same NPC every
     frame; anything persistent works (questmarks passes the candidate). ]]
function project.point(mx, my, mz, st)
    if not live then return nil end

    local r1, r2, r3 = mx, my, mz
    local x = s1 * (o1 == 1 and r1 or (o1 == 2 and r2 or r3))
    local y = s2 * (o2 == 1 and r1 or (o2 == 2 and r2 or r3))
    local z = s3 * (o3 == 1 and r1 or (o3 == 2 and r2 or r3))

    local w = x*a14 + y*a24 + z*a34 + a44
    if w <= NEAR then return nil end

    local inv = 1 / w
    local nx = (x*a11 + y*a21 + z*a31 + a41) * inv
    if nx < -NDC_SLACK or nx > NDC_SLACK then return nil end
    local ny = (x*a12 + y*a22 + z*a32 + a42) * inv
    if ny < -NDC_SLACK or ny > NDC_SLACK then return nil end

    local sx, sy = hw + nx * hw, hh - ny * hh
    -- Recorded before any compensation, so raw_of() is valid even when
    -- compensation is disabled or skipped this frame.
    last_raw_x, last_raw_y = sx, sy

    --[[ Lag compensation: reproject the same point with last frame's matrix and
         push forward by the difference. See the note beside the prev-matrix
         cache above. Skipped when the point was behind the camera last frame,
         where the delta would be meaningless. ]]
    if lag > 0 and have_prev then
        local pw = x*p14 + y*p24 + z*p34 + p44
        if pw > NEAR then
            local pinv = 1 / pw
            local px = hw + ((x*p11 + y*p21 + z*p31 + p41) * pinv) * hw
            local py = hh - ((x*p12 + y*p22 + z*p32 + p42) * pinv) * hh
            local d1x, d1y = sx - px, sy - py

            --[[ Robust velocity estimate.

                 d1 is this point's screen movement over the last frame -- and a
                 single frame is noisy. d2 is the same movement measured over
                 TWO frames and halved: the same velocity, with single-frame
                 noise averaged out.

                 The two are combined by how much they AGREE, using the cosine
                 between them clamped to [0, 1]:

                   pointing the same way   -> weight ~1, full correction
                   perpendicular / reversed-> weight ~0, no correction

                 Do not swap this for a hard gate ("same sign or nothing").
                 During ordinary camera motion the sign product hovers around
                 zero and flips frame to frame, so such a gate pops the
                 correction between full and none every frame. A continuous
                 weight cannot pop -- it degrades smoothly as the two estimates
                 diverge, which is exactly when we should trust them less. ]]
            local dx, dy = d1x, d1y
            if have_prev2 then
                local qw = x*q14 + y*q24 + z*q34 + q44
                if qw > NEAR then
                    local qinv = 1 / qw
                    local qx = hw + ((x*q11 + y*q21 + z*q31 + q41) * qinv) * hw
                    local qy = hh - ((x*q12 + y*q22 + z*q32 + q42) * qinv) * hh
                    local d2x, d2y = (sx - qx) * 0.5, (sy - qy) * 0.5

                    local m1 = math.sqrt(d1x*d1x + d1y*d1y)
                    local m2 = math.sqrt(d2x*d2x + d2y*d2y)
                    local agree = 0
                    if m1 > 1e-5 and m2 > 1e-5 then
                        agree = (d1x*d2x + d1y*d2y) / (m1 * m2)
                        if agree < 0 then agree = 0 end
                    end

                    --[[ Direction from the average, magnitude from the
                         smaller estimate.

                         Extrapolation only holds while velocity is steady.
                         When the camera decelerates the one-frame estimate
                         falls below the two-frame one, yet both still point
                         the same way -- so an agreement test alone would pass
                         the stale, larger value straight through and throw
                         the marker ahead of where it belongs.

                         Taking the smaller magnitude stops that: at constant
                         velocity m1 == m2 so the correction is unchanged and
                         lag is still fully cancelled, but the moment motion
                         eases off the conservative estimate wins. ]]
                    local mag = ((m1 < m2) and m1 or m2) * agree
                    local ax, ay = (d1x + d2x) * 0.5, (d1y + d2y) * 0.5
                    local am = math.sqrt(ax*ax + ay*ay)
                    if am > 1e-5 then
                        dx, dy = ax / am * mag, ay / am * mag
                    else
                        dx, dy = 0, 0
                    end
                end
            end

            -- Scale from "movement during the last frame" to "movement during
            -- the frame we expect next".
            dx, dy = dx * lag * dt_ratio, dy * lag * dt_ratio

            --[[ Final guard. Even a filtered estimate can be nonsense when a
                 point swings near the near plane, where small world movements
                 become enormous screen movements. Cap the push; discard it
                 entirely past the point where it cannot be lag at all.

                 Size the cap from the geometry, not by feel: a fast camera pan
                 is roughly 180 deg/sec, so ~3 deg in one 60 fps frame. At a
                 ~80 deg horizontal FOV across 1280 px that is about 50 px.
                 Anything beyond that is not lag.

                 Do not loosen it. The pathological case is an NPC very near
                 the camera: it sweeps across the screen enormously per frame,
                 so both estimates are huge and agree, the corroboration filter
                 passes them, and the full push is applied to a marker that
                 needs almost none. ]]
            local mag2 = dx*dx + dy*dy
            local MAX_PUSH = 45
            if mag2 > MAX_PUSH * MAX_PUSH then
                if mag2 > 150 * 150 then
                    dx, dy = 0, 0       -- cannot be lag; ignore entirely
                else
                    local s = MAX_PUSH / math.sqrt(mag2)
                    dx, dy = dx * s, dy * s
                end
            end

            --[[ Per-marker low-pass on the correction (not the position).

                 Everything above still produces a per-frame value, and both
                 dt_ratio and the projection sampling carry frame-to-frame
                 noise that would otherwise reach the screen directly. An
                 exponential average over the correction removes that shimmer
                 while leaving the underlying position exact -- when the camera
                 is still the correction is zero, so smoothing zero stays zero
                 and no lag is introduced at rest.

                 The cost is that a correction ramps in over ~3 frames at the
                 start of a turn. That is a far better trade than shimmering
                 every frame.

                 Asymmetric: ramp up gently, collapse immediately. A symmetric
                 EMA holds the previous correction for several frames, so when
                 the camera stops the marker keeps being pushed ahead of the
                 NPC and crawls back. Smoothing only earns its keep while the
                 correction is growing; while it shrinks there is nothing to
                 protect. So: configured smoothing when growing, near-instant
                 when shrinking. ]]
            if st and smooth > 0 then
                local px_, py_ = st.qm_cx, st.qm_cy
                if px_ then
                    local growing = (dx*dx + dy*dy) > (px_*px_ + py_*py_)
                    local a = growing and (1 - smooth) or 0.9
                    st.qm_cx = px_ + (dx - px_) * a
                    st.qm_cy = py_ + (dy - py_) * a
                else
                    st.qm_cx, st.qm_cy = dx, dy
                end
                --[[ Snap to exactly zero once the residue is sub-pixel. An
                     exponential decay never quite reaches zero, and a marker
                     that keeps twitching by hundredths of a pixel forever is
                     both pointless and a stream of needless prim updates. ]]
                if st.qm_cx * st.qm_cx + st.qm_cy * st.qm_cy < 0.25 then
                    st.qm_cx, st.qm_cy = 0, 0
                end
                dx, dy = st.qm_cx, st.qm_cy
            end

            sx, sy = sx + dx, sy + dy
        end
    end

    return sx, sy, w
end

--[[ Where the LAST project.point() call would have placed the marker with no
     lag compensation at all. Only meaningful immediately after that call.

     Exists so the debug view can show both positions in one frame: whichever
     sits on the NPC is the one telling the truth, which settles "is
     compensation helping here" by observation instead of argument. ]]
function project.raw_of()
    return last_raw_x, last_raw_y
end

-- Project a point `up` yalms above an entity's origin (mob-space vertical is z).
function project.above(mx, my, mz, up, st)
    return project.point(mx, my, mz + up * L.vsign, st)
end

--[[ Resolve which way is up in MOB space, once, from observation rather than
     assumption: project base+2 and base-2 and keep whichever lands higher on
     screen (smaller y). Cheap, self-correcting, and immune to a sign error in
     the baked constants. ]]
function project.resolve_vertical_sign(mx, my, mz)
    local _, ya = project.point(mx, my, mz + 2)
    local _, yb = project.point(mx, my, mz - 2)
    if ya and yb and math.abs(ya - yb) > 1 then
        L.vsign = (ya < yb) and 1 or -1
        return true, L.vsign
    end
    return false
end

function project.viewport()
    return vp_w, vp_h
end

-- Diagnostics for //qm perf
function project.timing()
    return dt_ema, dt_ratio
end

return project
