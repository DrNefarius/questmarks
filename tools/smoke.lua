--[[
smoke.lua -- load the real questmarks.lua against a stub client and drive every
command once. Build-time only.

    luajit tools/smoke.lua

questmarks.lua is 1400 lines of event handlers and command printers that no test
ran; a nil index in one could only be found by typing the command in game. This
is a smoke run, not a unit test: it checks that nothing throws and prints what
the player would see. Wrong-but-not-fatal output is test_core's job.

Two stubs matter. Windower's libs (config, logger, packets) need its patched
Lua (`'str':method()` without parens), which stock LuaJIT will not parse, so
they get stand-ins. And `windower.get_camera` is top level, not under
`windower.ffxi` -- misplace it and `//qm probe` is the only command that throws,
which looks like an addon bug.
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
local A = require('tools/lib/root') .. '/'
local W = require('tools/lib/root') .. '/../../'
package.path = A .. '?.lua;' .. package.path

_addon = {name = 'questmarks', version = 'smoke', language = 'English',
          command = 'qm', commands = {}}

local events, chat = {}, {}
local function noop() end
local function nooptbl() return {} end

-- Any prim/text method is a no-op; nothing is drawn.
local sink = setmetatable({}, {__index = function() return noop end})

windower = {
    addon_path = A,
    windower_path = W,
    add_to_chat = function(_, s) chat[#chat + 1] = s end,
    register_event = function(...)
        local a = {...}
        local fn = a[#a]
        for i = 1, #a - 1 do
            events[a[i]] = events[a[i]] or {}
            table.insert(events[a[i]], fn)
        end
        return #events
    end,
    unregister_event = noop,
    send_command = noop,
    from_shift_jis = function(s) return s end,
    to_shift_jis = function(s) return s end,
    get_windower_settings = function()
        return {x_res = 1280, y_res = 720, ui_x_res = 1280, ui_y_res = 720}
    end,
    -- TOP level, not under .ffxi -- see the header.
    get_camera = function() return nil end,
    prim = sink,
    text = sink,
    packets = {parse_action = function() return nil end},
    ffxi = {
        get_info = function()
            return {zone = 245, logged_in = true, mog_house = false,
                    day = 1, moon = 21, moon_phase = 1, time = 1191,
                    weather = 0, menu_open = false, chat_open = false,
                    server = 5, language = 'English',
                    target_arrow = {x = 0, y = 0, z = 0}}
        end,
        get_player = function()
            return {name = 'Smoke', main_job = 'RDM', main_job_level = 99,
                    id = 1, index = 1}
        end,
        get_items = function() return {} end,
        get_key_items = nooptbl,
        get_bag_info = function() return {max = 80, count = 0, enabled = true} end,
        get_mob_by_target = function(t)
            if t == 'me' then
                return {name = 'Smoke', x = 0, y = 0, z = 0, id = 1, index = 1}
            end
            return nil
        end,
        get_mob_by_index = function() return nil end,
        get_mob_by_id = function() return nil end,
        get_mob_list = nooptbl,
        get_party = nooptbl,
    },
}

_libs = {}
flog = noop
package.loaded['logger'] = true
package.loaded['config'] = {
    load = function(defaults)
        local t = defaults or {}
        t.save = noop
        return t
    end,
    save = noop,
}
package.loaded['packets'] = {parse = function() return nil end,
                             new = function() return {} end}

-- Never touch the player's real settings.xml.
local real_open = io.open
io.open = function(path, mode)
    if mode and mode:find('w') and tostring(path):find('settings') then
        return {write = noop, close = noop}
    end
    return real_open(path, mode)
end

local ok, err = pcall(dofile, A .. 'questmarks.lua')
if not ok then
    print('FAIL  questmarks.lua did not load: ' .. tostring(err))
    os.exit(1)
end
print('[ OK ] questmarks.lua loads against a stub client')

local cmd = events['addon command'] and events['addon command'][1]
if not cmd then print('FAIL  no addon command handler registered') os.exit(1) end

local failures = 0
local function run(...)
    local before = #chat
    local okc, e = pcall(cmd, ...)
    local label = table.concat({...}, ' ')
    if okc then
        print(('[ OK ] //qm %-22s %d line(s)'):format(label, #chat - before))
    else
        failures = failures + 1
        print(('[FAIL] //qm %-22s %s'):format(label, tostring(e)))
    end
end

--[[ Every command, including the argument forms. `help` is the bare fallback,
     which is what an unknown command reaches. ]]
print('\n=== commands, with nothing in progress ===')
for _, c in ipairs({
    {'todo'}, {'todo', 'all'}, {'todo', 'ready'}, {'todo', 'turnin'},
    {'todo', 'all', '4'}, {'todo', 'rubbish'},
    {'kills'}, {'kills', '5'},
    {'why', 'zalsuhm'}, {'why', 'no such npc'}, {'why'},
    {'menu'}, {'menu', 'on'}, {'menu', 'off'},
    {'steps'}, {'steps', 'off'}, {'steps', 'on'},
    {'new'}, {'notify'}, {'notify', 'on'},
    {'data'}, {'npcs'}, {'state'}, {'perf'}, {'probe'}, {'settings'},
    {'fame'}, {'fame', 'dump'}, {'fame', 'bastok', '5'}, {'fame', 'bastok', 'reset'},
    {'show'}, {'show', 'turnin', 'off'}, {'show', 'turnin', 'on'},
    {'dist', '50'}, {'max', '16'}, {'lag'}, {'smooth'}, {'debug'}, {'debug', 'off'},
    {'visible'}, {'visible', 'on'}, {'dump'}, {'help'}, {'not-a-command'},
}) do run(unpack(c)) end

--[[ The runs above take the EMPTY branches -- "nothing to do", "no defeats".
     The row formatting is what has never executed, so force real rows through
     it: a spread of accepted quests, a stocked bag, and some kills. ]]
print('\n=== commands, with quests in progress and kills counted ===')

local state = require('core/state')
local inventory = require('core/inventory')
local kills = require('core/kills')
local quests = require('core/quests')

local function blob(ids)
    local b = {}
    for i = 1, 32 do b[i] = 0 end
    for _, id in ipairs(ids) do
        local p = math.floor(id / 8) + 1
        b[p] = b[p] + 2 ^ (id % 8)
    end
    local s = {}
    for i = 1, 32 do s[i] = string.char(b[i]) end
    return table.concat(s)
end

state.handle_packet{Type = 0x0050, ['Quest Flags'] = blob{4, 7, 9, 11, 30}}
state.handle_packet{Type = 0x0090, ['Quest Flags'] = blob{}}
state.handle_packet{Type = 0x0068, ['Quest Flags'] = blob{27, 90, 131}}
state.handle_packet{Type = 0x00A8, ['Quest Flags'] = blob{}}
state.handle_packet{Type = 0x0078, ['Quest Flags'] = blob{3, 19}}
state.handle_packet{Type = 0x00B8, ['Quest Flags'] = blob{}}

windower.ffxi.get_items = function(bag)
    if bag ~= 'inventory' then return {} end
    return {{id = 17742, count = 1, status = 0x05},   -- Vorpal Sword, worn
            {id = 592, count = 1, status = 0x00}}
end
inventory.reset()
inventory.refresh(true)

--[[ A well-formed 0x062, so the skill reporting in //qm probe, //qm data and
     //qm diag runs its populated branch and not just its empty one. That is
     the whole reason this file exists: the //qm todo row formatting turned out
     never to have been executed at all.

     Fishing at rank 8 / level 61 specifically. The shipped index gates on two
     crafts, Fishing (sk=48) and Synergy (sk=57), and this drives the craft
     predicate through the real addon rather than only through test_core's
     synthetic entry. ]]
local skills_chunk
do
    local b = {}
    for i = 1, 0x100 do b[i] = 0 end
    local function put(off, w)
        b[off + 1] = w % 256
        b[off + 2] = math.floor(w / 256) % 256
    end
    put(0x80 + 5 * 2, 200)                       -- a combat skill: level only
    put(0xE0 + (48 - 48) * 2, 8 + 61 * 32)       -- Fishing: rank 8, level 61
    put(0xE0 + (56 - 48) * 2, 3 + 25 * 32)       -- Cooking: rank 3, level 25
    local s = {}
    for i = 1, 0x100 do s[i] = string.char(b[i]) end
    skills_chunk = table.concat(s)
end

--[[ ...and a get_player() that actually carries `skills`. The stub above
     deliberately omits it, which exercises the 'absent' branch.

     NAME-KEYED, because that half is established: plugins/LuaCore.dll carries a
     contiguous snake_case key block at 0x195b40 (hand_to_hand ... fishing
     goldsmithing ... synergy) between the vitals keys and the mob keys. What
     the VALUES are -- raw 16-bit words or already-decoded levels -- is the half
     one login still has to settle, so this fixture picks raw words and the
     assertion below names that specific reading rather than "something was
     identified". ]]
windower.ffxi.get_player = function()
    local sk = {fishing = 8 + 61 * 32, cooking = 3 + 25 * 32,
                woodworking = 0, smithing = 0, goldsmithing = 0,
                clothcraft = 0, leathercraft = 0, bonecraft = 0,
                alchemy = 0, synergy = 0}
    return {name = 'Smoke', main_job = 'RDM', main_job_level = 99,
            id = 1, index = 1, skills = sk}
end

kills.set_api{name_of = function() return 'Nasu' end, mine = function() return true end}
kills.set_watch{'Nasu', 'Wyrmfly'}
for _ = 1, 3 do
    kills.handle_action{actor_id = 1,
                        targets = {{id = 100, actions = {{message = 6}}}}}
end

chat = {}
run('todo')
run('todo', 'all', '4')
run('kills')
run('why', 'zalsuhm')
run('steps')

--[[ Feed a real 0x062 before the reporting commands run.

     "Does not throw on rubbish" says nothing about whether the good path works,
     and the empty branch of a report is not the branch that breaks. So the
     packet goes in here, and `probe` and `data` below print their populated
     branch, which is the one a bug report is built from. ]]
;(function()
    local ch = events['incoming chunk'] and events['incoming chunk'][1]
    if not ch then return end          -- reported as a failure further down
    local okp, e = pcall(ch, 0x062, skills_chunk, nil, false, false)
    local pskills = require('core/skills')
    if not okp then
        failures = failures + 1
        print(('[FAIL] 0x062 threw on a valid payload: %s'):format(tostring(e)))
    elseif pskills.rank(48) ~= 8 or pskills.level(48) ~= 61 then
        failures = failures + 1
        print(('[FAIL] 0x062 decoded rank=%s level=%s, wanted 8/61')
              :format(tostring(pskills.rank(48)), tostring(pskills.level(48))))
    else
        print('[ OK ] 0x062 decodes Fishing rank 8 / level 61 through the addon')
    end
    --[[ The handler calls refresh_player(), which hands get_player().skills to
         the identifier. With the packet already in, a name-keyed table of raw
         16-bit words is the only reading that survives -- so this exercises the
         whole loop through the real addon, not just the decode. ]]
    local s = pskills.stats()
    if s.shape == 'raw16/name' and s.player_trusted then
        print('[ OK ] get_player().skills identified as raw16/name from the packet')
    else
        failures = failures + 1
        print(('[FAIL] shape came out %s (trusted=%s), wanted raw16/name')
              :format(tostring(s.shape), tostring(s.player_trusted)))
    end
end)()

local probe_at = #chat
run('probe')
run('data')
--[[ Assert the report actually SAID something. A reporting function that runs
     without throwing and prints the empty branch looks identical to one that
     works, which is how `meta.steps` stayed a hardcoded `false` through an
     entire extraction. ]]
;(function()
    local said = false
    for i = probe_at + 1, #chat do
        if tostring(chat[i]):find('rank 8') then said = true end
    end
    if said then
        print('[ OK ] //qm probe prints the decoded craft ranks')
    else
        failures = failures + 1
        print('[FAIL] //qm probe ran but never printed a craft rank')
    end
end)()

print('\n=== what the player would see ===')
for i = 1, math.min(#chat, 18) do print('   ' .. tostring(chat[i])) end

--[[ The packet handlers, which are the other half of the never-executed
     surface. Fed deliberate rubbish: every one is pcall'd or shape-checked, and
     a malformed packet must never take the addon down. ]]
print('\n=== packet handlers, fed rubbish ===')
local chunk = events['incoming chunk'] and events['incoming chunk'][1]
if chunk then
    for _, id in ipairs({0x056, 0x055, 0x028, 0x02D, 0x01F, 0x020, 0x062, 0x999}) do
        local okp, e = pcall(chunk, id, string.rep('\0', 8), nil, false, false)
        if okp then print(('[ OK ] 0x%03X survives a malformed payload'):format(id))
        else failures = failures + 1
             print(('[FAIL] 0x%03X threw: %s'):format(id, tostring(e))) end
    end

else
    failures = failures + 1
    print('[FAIL] no incoming chunk handler registered')
end

--[[ `login` and `logout` are the only callers of kills.reset(), steps.reset(),
     pskills.reset(), keyitems.reset() and inventory.reset(), and until now no
     test invoked either -- a logout that reset nothing looked identical to one
     that reset everything.

     Inferences must not survive: kill tally, step latch, craft ranks, key-item
     bitfields, bag cache. Observations must: save_fame() writes the in-memory
     table straight back to disk, so a logout that cleared fame would wipe the
     saved file too. Don't "fix" the fame assertion below to match the others.

     Arm first. Every reset is checked against a value that was non-empty one
     line earlier, or "it is empty after logout" can never fail -- that is how
     test_state.lua's 0x056 watch list stayed green while 18 of its 28 sub-types
     were deleted. And reset means nil where a module has a tri-state:
     pskills.rank() and keyitems.available() must come back nil (unknown, the
     black "!"), never 0 or false, which would claim the next character has
     none. ]]
print('\n=== login / logout: observations persist, inferences do not ===')

local keyitems = require('core/keyitems')
local notify   = require('core/notify')
local fame     = require('core/fame')
local steps    = require('core/steps')
local pskills  = require('core/skills')

local login_fn  = events['login']  and events['login'][1]
local logout_fn = events['logout'] and events['logout'][1]

local function ck(label, cond, detail)
    if cond then print(('[ OK ] %-44s %s'):format(label, detail or ''))
    else failures = failures + 1
         print(('[FAIL] %-44s %s'):format(label, detail or '')) end
end

ck('login and logout handlers are registered',
   login_fn ~= nil and logout_fn ~= nil,
   ('login=%s logout=%s'):format(tostring(login_fn ~= nil), tostring(logout_fn ~= nil)))

if login_fn and logout_fn then
    --[[ Key items are armed by calling the decoder directly rather than by
         feeding 0x055 through the addon: `packets.parse` is stubbed to nil in
         this file (see the header), so the addon's 0x055 branch never reaches
         core/keyitems at all. The decode itself is test_core's job; what is
         under test here is only that logout clears the result. ]]
    keyitems.handle_packet{Type = 0,
        ['Key item available'] = string.char(0x0B) .. string.rep('\0', 63)}

    --[[ Through the COMMAND, not through fame.set_manual(), because the
         command is what also calls save_fame(), and "saved per character" is
         what is being tested here. Makes the login assertion further down a
         real round trip: set, persist, log out, log in, still there. ]]
    run('fame', 'sandoria', '6')

    --[[ notify has to be armed too, and it was not. `notify.primed()` is
         `prev ~= nil` (core/notify.lua:31) and `prev` is set only by
         notify.update(). Without this call the assertion further down --
         "logout clears the notify baseline" -- reads false BEFORE logout as
         well as after, so it passes whatever logout does. That is a check that
         cannot fail, sitting inside the block written to eliminate checks that
         cannot fail. Arm it, and assert the arming with everything else. ]]
    notify.update(quests)

    local a_kills   = kills.stats().defeats
    local a_steps   = steps.stats().tracked
    local a_rank    = pskills.rank(48)
    local a_keyitem = keyitems.available(0)
    local a_bags    = inventory.ready()
    local a_state   = state.is_loaded()
    local a_notify  = notify.primed()
    local a_fame    = fame.get('sandoria')

    ck('ARMED: an inference is present in every module',
       a_kills > 0 and a_steps > 0 and a_rank == 8
       and a_keyitem == true and a_bags == true and a_state == true
       and a_notify == true,
       ('kills=%d steps=%d fishing_rank=%s keyitem=%s bags=%s state=%s notify=%s')
       :format(a_kills, a_steps, tostring(a_rank), tostring(a_keyitem),
               tostring(a_bags), tostring(a_state), tostring(a_notify)))
    ck('ARMED: and a SAVED observation is present',
       a_fame == 6, ('sandoria fame=%s'):format(tostring(a_fame)))

    local okl, el = pcall(logout_fn)
    ck('logout runs without throwing', okl, tostring(el))

    ck('logout clears the kill tally',
       kills.stats().defeats == 0, ('defeats=%d'):format(kills.stats().defeats))
    ck('logout clears the step latch',
       steps.stats().tracked == 0, ('tracked=%d'):format(steps.stats().tracked))
    ck('logout clears the identified craft ranks',
       pskills.ready() == false and pskills.rank(48) == nil,
       ('ready=%s rank48=%s (must be nil, not 0)')
       :format(tostring(pskills.ready()), tostring(pskills.rank(48))))
    ck('logout clears the key-item bitfields',
       keyitems.ready() == false and keyitems.available(0) == nil,
       ('ready=%s available(0)=%s (must be nil, not false)')
       :format(tostring(keyitems.ready()), tostring(keyitems.available(0))))
    ck('logout clears the bag cache',
       inventory.ready() == false, ('ready=%s'):format(tostring(inventory.ready())))
    ck('logout clears the 0x056 quest state',
       state.is_loaded() == false, ('loaded=%s'):format(tostring(state.is_loaded())))
    ck('logout clears the notify baseline',
       notify.primed() == false, ('primed=%s'):format(tostring(notify.primed())))

    --[[ The opposite assertion, and the one that stops "reset everything"
         from being an acceptable fix. See the block comment above. ]]
    ck('logout does NOT clear fame -- observations persist',
       fame.get('sandoria') == 6, ('sandoria fame=%s'):format(tostring(fame.get('sandoria'))))

    local okg, eg = pcall(login_fn)
    ck('login runs without throwing', okg, tostring(eg))

    --[[ login RE-READS fame rather than keeping it: load_fame() resets and
         then imports THIS character's saved table. That is not a violation of
         the rule, it is how the per-character half works -- so the assertion
         is that the saved reading comes back, which only holds if logout left
         the file alone. ]]
    ck('login restores the saved fame reading',
       fame.get('sandoria') == 6, ('sandoria fame=%s'):format(tostring(fame.get('sandoria'))))
    ck('login leaves every inference empty',
       kills.stats().defeats == 0 and steps.stats().tracked == 0
       and pskills.rank(48) == nil and keyitems.available(0) == nil
       and inventory.ready() == false and state.is_loaded() == false,
       ('kills=%d steps=%d rank48=%s keyitem=%s bags=%s state=%s')
       :format(kills.stats().defeats, steps.stats().tracked,
               tostring(pskills.rank(48)), tostring(keyitems.available(0)),
               tostring(inventory.ready()), tostring(state.is_loaded())))
end

print(('\n%s -- %d failure(s)'):format(
    failures == 0 and 'smoke run clean' or 'SMOKE RUN FAILED', failures))
os.exit(failures == 0 and 0 or 1)
