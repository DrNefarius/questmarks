--[[
core/notify.lua -- tells you when something becomes newly actionable.

Markers only help for NPCs you are standing near. Completing a quest, gaining a
fame level or finishing a mission can unlock content anywhere in the world, and
nothing would otherwise tell you. This diffs marker states across the WHOLE
index -- not just the current zone -- and reports what just opened up.

Only transitions INTO an actionable state are reported. Going from blocked to
ready is news; going from ready to done is not, you were there.

The first snapshot after login is deliberately silent: on a fresh character
every available quest in the game would qualify as "new", which is noise, not
information.
]]

local notify = {}

local prereq = require('core/prereq')

-- States worth interrupting the player for.
local ACTIONABLE = {ready = true, turnin = true}

local prev = nil        -- key -> marker state at the last snapshot
local last_gained = {}  -- the most recent batch, for //qm new

function notify.reset()
    prev, last_gained = nil, {}
end

function notify.primed() return prev ~= nil end

--[[ Recompute every entry's marker state and return what just became
     actionable.

     -> array of {key, entry, from, to}   (empty on the first call)

     Runs on 0x056 settle and fame changes only -- never per frame. Cost is one
     prereq evaluation per indexed entry. ]]
function notify.update(quests)
    local cur, gained = {}, {}

    quests.each_entry(function(key, entry)
        local st = prereq.marker_state(entry)
        if st then cur[key] = st end
        if prev then
            local was = prev[key]
            if ACTIONABLE[st] and not ACTIONABLE[was] then
                gained[#gained + 1] = {key = key, entry = entry, from = was, to = st}
            end
        end
    end)

    local first = (prev == nil)
    prev = cur
    if first then return {} end

    last_gained = gained
    return gained
end

function notify.last() return last_gained end

--[[ No zone grouping here. The announcement is one line (see report_new) and
     `//qm new` walks the batch directly.

     If it ever comes back, note that `entry.zone` is four-valued: a number,
     `false` for "any zone", the string 'moghouse', or nil when it never
     resolved. 75 indexed entries have zone=nil, and Lua cannot use nil as a
     table key, so grouping needs a sentinel key. The comparator must handle
     mixed types too -- `or math.huge` does not rescue 'moghouse', a string
     is truthy. ]]

notify.ACTIONABLE = ACTIONABLE

return notify
