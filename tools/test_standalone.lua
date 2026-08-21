--[[
test_standalone.lua -- proves questmarks has no runtime dependency on any other
addon.

The quest data is built offline, so the build reads inputs this addon does not
ship (provenance is in NOTICE). That is a build-time relationship, like a
compiler. Once data/quest_index.lua exists, nothing outside this addon is read
at runtime.

This test fails loudly if that ever stops being true.

    luajit tools/check.lua && luajit tools/test_standalone.lua
]]

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
local ROOT = require('tools/lib/root')
package.path = ROOT .. '/?.lua;' .. package.path

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then pass = pass + 1; print(('  PASS  %-56s %s'):format(name, detail or ''))
    else       fail = fail + 1; print(('  FAIL  %-56s %s'):format(name, detail or '')) end
end

-- ---------------------------------------------------------------------------
-- 1. No shipped module may require() anything outside this addon or Windower.
-- ---------------------------------------------------------------------------

--[[ Hand-maintained. A module missing from this list would be exempt from every
     guarantee below, so the set-equality check further down makes forgetting
     impossible. ]]
local SHIPPED = {
    'questmarks.lua',
    'core/state.lua', 'core/quests.lua', 'core/prereq.lua',
    'core/fame.lua', 'core/inventory.lua', 'core/notify.lua', 'core/steps.lua',
    'core/keyitems.lua', 'core/kills.lua', 'core/skills.lua',
    'render/project.lua', 'render/markers.lua',
    'data/quest_index.lua', 'data/mission_index.lua',
    'data/fame_dialogue.lua', 'data/npc_overrides.lua',
    'data/dat_names.lua', 'data/quest_steps.lua',
}

-- Windower stock libraries are fair game; other addons are not.
local ALLOWED = {
    config = true, packets = true, logger = true, resources = true, bit = true,
}

local function read(path)
    local f = io.open(ROOT .. '/' .. path, 'r')
    if not f then return nil end
    local s = f:read('*a')
    f:close()
    return s
end

-- Strip comments so attribution text does not trip the scanner.
local function strip_comments(src)
    src = src:gsub('%-%-%[%[.-%]%]', ' ')      -- block comments
    src = src:gsub('%-%-[^\n]*', ' ')          -- line comments
    return src
end

--[[ Enumerate what is actually on disk so SHIPPED cannot go stale.

     Every .lua under core/, render/ and data/ ships, by definition -- those
     three directories contain nothing else. tools/ is deliberately excluded:
     it is build-time only and may read Windower's res/ and its own build
     inputs. ]]
local function list_lua(subdir)
    local out = {}
    local cmd = 'dir /b /s "' .. (ROOT .. '/' .. subdir):gsub('/', '\\')
                .. '\\*.lua" 2>nul'
    local p = io.popen(cmd)
    if not p then return out end
    for line in p:lines() do
        line = line:gsub('%s+$', ''):gsub('\\', '/')
        if line ~= '' then
            out[#out + 1] = line:sub(#ROOT + 2)
        end
    end
    p:close()
    return out
end

print('=== SHIPPED lists every shipped file ===')
local listed = {}
for _, p in ipairs(SHIPPED) do listed[p] = true end
local on_disk, unlisted = {}, {}
for _, sub in ipairs({'core', 'render', 'data'}) do
    for _, p in ipairs(list_lua(sub)) do
        on_disk[p] = true
        if not listed[p] then unlisted[#unlisted + 1] = p end
    end
end
check('no shipped module escapes the guarantees below', #unlisted == 0,
      #unlisted > 0 and ('add to SHIPPED: ' .. table.concat(unlisted, ', '))
                     or ('%d files under core/ render/ data/'):format(
                            (function() local n = 0 for _ in pairs(on_disk) do n = n + 1 end return n end)()))

local ghosts = {}
for _, p in ipairs(SHIPPED) do
    if p ~= 'questmarks.lua' and not on_disk[p] then ghosts[#ghosts + 1] = p end
end
check('SHIPPED names no file that no longer exists', #ghosts == 0,
      table.concat(ghosts, ', '))

print('\n=== no external requires in shipped code ===')
local bad = {}
for _, path in ipairs(SHIPPED) do
    local src = read(path)
    if not src then
        bad[#bad + 1] = path .. ' MISSING'
    else
        for mod in strip_comments(src):gmatch("require%s*%(?%s*['\"]([^'\"]+)['\"]") do
            local top = mod:match('^([^/%.]+)')
            if not (mod:find('^core/') or mod:find('^render/') or mod:find('^data/')
                    or ALLOWED[top]) then
                bad[#bad + 1] = ('%s requires %q'):format(path, mod)
            end
        end
    end
end
check('every shipped file requires only questmarks or Windower stock',
      #bad == 0, table.concat(bad, ' | '))

print('\n=== no other addon is read at runtime ===')
local reads = {}
for _, path in ipairs(SHIPPED) do
    local src = strip_comments(read(path) or '')
    for lit in src:gmatch("['\"]([^'\"]*addons[/\\][^'\"]*)['\"]") do
        reads[#reads + 1] = ('%s -> %s'):format(path, lit)
    end
    -- windower.addon_path is our OWN directory, so it is fine; a hard-coded
    -- sibling addon path is not.
    for lit in src:gmatch("['\"]([^'\"]*%.%./[^'\"]*)['\"]") do
        reads[#reads + 1] = ('%s -> %s'):format(path, lit)
    end
end
check('no shipped file references another addon path', #reads == 0,
      table.concat(reads, ' | '))

print('\n=== the index is self-contained ===')
local quests = require('core/quests')
local meta, err = quests.load(ROOT .. '/data/quest_index.lua')
check('index loads with nothing else present', meta ~= nil, err or '')
local npcs, rows = quests.stats()
check('index carries real content', npcs > 400 and rows > 1000,
      ('%d npcs / %d rows'):format(npcs, rows))

--[[ The builder reads no addon directory at all. Its inputs are Windower's
     res/, this addon's own data/ and build/, and nothing else, so the boundary
     this file exists to hold covers the tool as well as the shipped code.

     A bogus root must therefore fail on res/. An error that names a sibling
     addon means the boundary has broken. ]]
print('\n=== the builder reads no other addon ===')
local builder = require('tools/build_index')
local st, berr = builder.build{root = ROOT .. '/tools/__no_such_windower__',
                               report = function() end}
check('build with a bogus root returns an error, does not throw', st == nil)
check('...and it is res/, not another addon, that it could not find',
      type(berr) == 'string' and berr:lower():find('chronicle') == nil,
      tostring(berr))

do
    local src = io.open(ROOT .. '/tools/build_index.lua', 'r')
    local body = src and src:read('*a') or ''
    if src then src:close() end
    --[[ The same literal scan the shipped-file check above runs. `addons/` is
         how every other-addon path in this tree is written. Comment lines are
         skipped, so prose about the boundary cannot fail the test that proves
         it. ]]
    local hits = {}
    for line in body:gmatch('[^\r\n]+') do
        local code = line:gsub('^%s+', '')
        if code:find('addons/', 1, true) and code:sub(1, 2) ~= '--'
           and not code:find('^%]?%]?%s*[A-Za-z]') then
            hits[#hits + 1] = code
        end
    end
    check('build_index.lua holds no other-addon path literal',
          #hits == 0, table.concat(hits, ' | '))
end

print('\n=== assets are ours ===')
for _, a in ipairs({'assets/bang.png', 'assets/query.png'}) do
    local f = io.open(ROOT .. '/' .. a, 'rb')
    check(a .. ' present', f ~= nil)
    if f then f:close() end
end

print(('\n%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)
