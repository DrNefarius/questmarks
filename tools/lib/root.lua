--[[
tools/lib/root.lua -- the addon's own directory, as an absolute path.

    local ROOT = require('tools/lib/root')

Exists so the test suites run from a clone anywhere instead of from one
machine's install path, which is what they used to hardcode.

Worked out from THIS file's location, not the caller's, so it gives the same
answer wherever it is required from. debug.getinfo reports the path as it was
typed, so a relative one gets anchored to the working directory first.

BUILD-TIME ONLY: nothing under tools/ ships. Shipped code must not require it.

string.char(92) is a backslash, written that way so no escaping has to survive
a shell, an editor and Lua all at once.
]]

local src = debug.getinfo(1, 'S').source:sub(2):gsub(string.char(92), '/')

if not src:match('^%a:/') and not src:match('^/') then
    local p = io.popen('cd')
    if p then
        local c = p:read('*l')
        p:close()
        if c and c ~= '' then
            src = c:gsub(string.char(92), '/'):gsub('/*$', '') .. '/' .. src
        end
    end
end

--[[ Strip '/tools/lib/root.lua'. Falls back to '.' rather than erroring: a
     caller that has been moved elsewhere still gets a usable relative root,
     and the failure shows up as a missing file rather than a cryptic nil. ]]
local root = (src:match('^(.*)/tools/lib/[^/]*$')) or '.'

--[[ Collapse the './' a relative invocation leaves behind, so the result is a
     clean prefix. test_standalone.lua slices `dir /b /s` output with
     `#ROOT + 2`, and a stray '/.' would shift every name by two characters. ]]
root = root:gsub('/%./', '/'):gsub('/%.$', ''):gsub('/+$', '')
return root
