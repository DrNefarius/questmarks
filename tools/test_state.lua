-- Offline tests for core/state.lua. Synthesizes 0x056 packets; no game needed.

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
local state = require('core/state')

local pass, fail = 0, 0
local function check(name, ok, detail)
    if ok then pass = pass + 1; print(('  PASS  %-52s %s'):format(name, detail or ''))
    else       fail = fail + 1; print(('  FAIL  %-52s %s'):format(name, detail or '')) end
end

-- Build a 32-byte 'Quest Flags' blob with the given DAT ids set.
local function blob(ids)
    local bytes = {}
    for i = 1, 32 do bytes[i] = 0 end
    for _, id in ipairs(ids) do
        local byte_pos = math.floor(id / 8) + 1
        bytes[byte_pos] = bytes[byte_pos] + 2 ^ (id % 8)
    end
    local s = {}
    for i = 1, 32 do s[i] = string.char(bytes[i]) end
    return table.concat(s)
end

print('=== bitflag decode ===')
state.reset()
local set = state._to_set(blob{0, 2, 8, 31, 255})
check('id 0  -> set[1]',   set[1] == true)
check('id 2  -> set[3]',   set[3] == true)
check('id 8  -> set[9]',   set[9] == true)
check('id 31 -> set[32]',  set[32] == true)
check('id 255-> set[256]', set[256] == true)
check('id 1 not set',      set[2] == nil)
check('LSB-first within a byte', state._to_set(string.char(0x05) .. string.rep('\0', 31))[3] == true,
      'byte 0x05 -> ids 0 and 2')

print('\n=== the current/completed semantic ===')
--[[ The load-bearing rule from fields.lua: a completed non-repeatable quest
     STAYS in the current list. So current alone never means in-progress. ]]
state.reset()
state.handle_packet{Type = 0x0050, ['Quest Flags'] = blob{1, 2, 3}}   -- current  S d'O
state.handle_packet{Type = 0x0090, ['Quest Flags'] = blob{2}}         -- completed S d'O

check('current+completed -> done',
      state.status_of('quest', 'sandoria', 2) == 'done',
      state.status_of('quest', 'sandoria', 2))
check('current only      -> in_progress',
      state.status_of('quest', 'sandoria', 1) == 'in_progress',
      state.status_of('quest', 'sandoria', 1))
check('neither           -> available',
      state.status_of('quest', 'sandoria', 7) == 'available',
      state.status_of('quest', 'sandoria', 7))
check('is_completed exact', state.is_completed('quest', 'sandoria', 2) == true)
check('is_current exact',   state.is_current('quest', 'sandoria', 3) == true)
check('unknown area -> nil', state.status_of('quest', 'abyssea', 5) == nil,
      tostring(state.status_of('quest', 'abyssea', 5)))

print('\n=== the 0x056 sub-type watch lists, against a FROZEN expectation ===')
--[[ The list being checked may not be the list doing the checking.

     Do not iterate state.BITFIELD_LOGS to build these assertions. A deleted
     entry then leaves both sides at once and the suite still passes green.

     The expectation is frozen here, outside core/state.lua, and checked both
     ways: every frozen sub-type must still route and decode, and none may
     exist that this list does not name. A new sub-type is meant to fail here.
     FIELD_LOGS gets the same treatment. ]]

-- {sub-type -> cat/kind/area}, sorted by sub-type, written out by hand.
local EXPECT_BITFIELD = {
    --[[ 0x0038 routes to `campaign` with offset 256, not to an area of its
         own: it is the second half of one ladder. Campaign ids run to 499 and
         a blob covers 256, and every query asks for `campaign`, so a separate
         area name for the high half would be read by nothing.

         The fifth column is the offset, frozen rather than derived. The decode
         check below resets state per row, so 0x0038 alone sets id 5 + 256; an
         unfrozen offset would assert against the wrong id. Read the offset off
         the shipped table and the check can never fail. ]]
    {0x0030, 'mission', 'completed', 'campaign', 0},
    {0x0038, 'mission', 'completed', 'campaign', 256},
    {0x0050, 'quest',   'current',   'sandoria'},
    {0x0058, 'quest',   'current',   'bastok'},
    {0x0060, 'quest',   'current',   'windurst'},
    {0x0068, 'quest',   'current',   'jeuno'},
    {0x0070, 'quest',   'current',   'other'},
    {0x0078, 'quest',   'current',   'outlands'},
    {0x0088, 'quest',   'current',   'crystal_war'},
    {0x0090, 'quest',   'completed', 'sandoria'},
    {0x0098, 'quest',   'completed', 'bastok'},
    {0x00A0, 'quest',   'completed', 'windurst'},
    {0x00A8, 'quest',   'completed', 'jeuno'},
    {0x00B0, 'quest',   'completed', 'other'},
    {0x00B8, 'quest',   'completed', 'outlands'},
    {0x00C8, 'quest',   'completed', 'crystal_war'},
    {0x00E0, 'quest',   'current',   'abyssea'},
    {0x00E8, 'quest',   'completed', 'abyssea'},
    {0x00F0, 'quest',   'current',   'adoulin'},
    {0x00F8, 'quest',   'completed', 'adoulin'},
    {0x0100, 'quest',   'current',   'coalition'},
    {0x0108, 'quest',   'completed', 'coalition'},
    {0x0110, 'quest',   'current',   'acp'},
    {0x0118, 'quest',   'completed', 'acp'},
    {0x0120, 'quest',   'current',   'mkd'},
    {0x0128, 'quest',   'completed', 'mkd'},
    {0x0130, 'quest',   'current',   'asa'},
    {0x0138, 'quest',   'completed', 'asa'},
}

-- Pins the literal in every name below to the list itself, so the two cannot
-- drift apart.
check('the frozen bitfield list is still the 28 sub-types 0x056 carries',
      #EXPECT_BITFIELD == 28, ('%d frozen'):format(#EXPECT_BITFIELD))

local mis_route, mis_decode = {}, {}
for _, w in ipairs(EXPECT_BITFIELD) do
    local subtype, cat, kind, area, off = w[1], w[2], w[3], w[4], w[5] or 0
    local log = state.BITFIELD_LOGS[subtype]
    if not log then
        mis_route[#mis_route + 1] = ('0x%04X absent'):format(subtype)
    elseif log.cat ~= cat or log.kind ~= kind or log.area ~= area
           or (log.offset or 0) ~= off then
        mis_route[#mis_route + 1] = ('0x%04X->%s/%s/%s+%s'):format(
            subtype, tostring(log.cat), tostring(log.kind), tostring(log.area),
            tostring(log.offset or 0))
    end
    --[[ Reset per row, and that is load-bearing rather than tidy.

         Do not hoist it out of the loop. 0x0030 and 0x0038 share the campaign
         area, so a bit left set by one row lets the next row pass on the other
         sub-type's data whatever its own routing says. An assertion that
         cannot fail is worse than no assertion.

         The decode is driven off the FROZEN row, never off the shipped table,
         which is the point: a deleted sub-type fails here even though there is
         nothing left in BITFIELD_LOGS to iterate over. ]]
    state.reset()
    state.handle_packet{Type = subtype, ['Quest Flags'] = blob{5}}
    local fn = (kind == 'completed') and state.is_completed or state.is_current
    if fn(cat, area, 5 + off) ~= true then
        mis_decode[#mis_decode + 1] = ('0x%04X'):format(subtype)
    end
end
state.reset()
check('all 28 frozen bitfield sub-types are still routed as frozen',
      #mis_route == 0, table.concat(mis_route, ' '))
check('all 28 frozen bitfield sub-types still decode a set bit',
      #mis_decode == 0, table.concat(mis_decode, ' '))

--[[ The split campaign ladder, asserted by behaviour.

     The frozen table above proves 0x0038 is routed to campaign+256. It cannot
     prove the two halves survive each other. They arrive in one 0x056 burst
     with no guaranteed order, so a plain `bits[...] = to_set(blob)` lets
     whichever lands second wipe the first, and the winner differs per login.

     0x0038 is sent first here on purpose. ]]
;(function()
    state.reset()
    state.handle_packet{Type = 0x0038, ['Quest Flags'] = blob{44}}   -- id 300
    state.handle_packet{Type = 0x0030, ['Quest Flags'] = blob{10}}   -- id 10
    check('the low campaign half survives the high half arriving first',
          state.is_completed('mission', 'campaign', 10) == true,
          tostring(state.is_completed('mission', 'campaign', 10)))
    check('the high campaign half is readable at all',
          state.is_completed('mission', 'campaign', 300) == true,
          ('id 300 = bit 44 of the second blob -> %s')
              :format(tostring(state.is_completed('mission', 'campaign', 300))))
    check('a clear bit in the high half is a definite false, not nil',
          state.is_completed('mission', 'campaign', 299) == false,
          tostring(state.is_completed('mission', 'campaign', 299)))

    --[[ The wart that was deliberately left. An id past every blob still reads
         `false`, not nil, and core/state.lua argues at length why fixing it here
         would DELETE markers rather than blacken them (marker_state returns nil
         the moment status_of does, and quests.lua treats nil as "did not draw").
         Asserted so the current behaviour is stated rather than assumed, and so
         that anyone who does change it has to come here and say why. ]]
    check('an id past every blob still reads false -- known wart, see state.lua',
          state.is_completed('mission', 'campaign', 600) == false,
          tostring(state.is_completed('mission', 'campaign', 600)))

    state.reset()
end)()

local frozen_bf = {}
for _, w in ipairs(EXPECT_BITFIELD) do frozen_bf[w[1]] = true end
local extra_bf = {}
for subtype in pairs(state.BITFIELD_LOGS) do
    if not frozen_bf[subtype] then
        extra_bf[#extra_bf + 1] = ('0x%04X'):format(subtype)
    end
end
-- Sorted, so the failure message does not depend on pairs() order.
table.sort(extra_bf)
check('no bitfield sub-type exists that the frozen list does not name',
      #extra_bf == 0, table.concat(extra_bf, ' '))

--[[ FIELD_LOGS. `raw` rows carry no cat/area/kind -- Nation is a routing input,
     not a status -- so those stay nil here and are checked as nil. ]]
local EXPECT_FIELD = {
    {st = 0x0080, label = 'Current TOAU Quests',           cat = 'quest',   area = 'toau',     kind = 'current',   mode = 'bits'},
    {st = 0x0080, label = 'Current Assault Mission',       cat = 'mission', area = 'assault',  kind = 'current',   mode = 'linear'},
    {st = 0x0080, label = 'Current TOAU Mission',          cat = 'mission', area = 'toau',     kind = 'current',   mode = 'linear'},
    {st = 0x0080, label = 'Current WOTG Mission',          cat = 'mission', area = 'wotg',     kind = 'current',   mode = 'linear'},
    {st = 0x0080, label = 'Current Campaign Mission',      cat = 'mission', area = 'campaign', kind = 'current',   mode = 'linear'},
    {st = 0x00C0, label = 'Completed TOAU Quests',         cat = 'quest',   area = 'toau',     kind = 'completed', mode = 'bits'},
    {st = 0x00C0, label = 'Completed Assaults',            cat = 'mission', area = 'assault',  kind = 'completed', mode = 'bits'},
    {st = 0x00D0, label = "Completed San d'Oria Missions", cat = 'mission', area = 'sandoria', kind = 'completed', mode = 'bits'},
    {st = 0x00D0, label = 'Completed Bastok Missions',     cat = 'mission', area = 'bastok',   kind = 'completed', mode = 'bits'},
    {st = 0x00D0, label = 'Completed Windurst Missions',   cat = 'mission', area = 'windurst', kind = 'completed', mode = 'bits'},
    {st = 0x00D0, label = 'Completed Zilart Missions',     cat = 'mission', area = 'zilart',   kind = 'completed', mode = 'bits'},
    {st = 0x00D8, label = 'Completed TOAU Missions',       cat = 'mission', area = 'toau',     kind = 'completed', mode = 'bits'},
    {st = 0x00D8, label = 'Completed WOTG Missions',       cat = 'mission', area = 'wotg',     kind = 'completed', mode = 'bits'},
    {st = 0xFFFE, label = 'Current TVR Mission',           cat = 'mission', area = 'tvr',      kind = 'current',   mode = 'linear'},
    {st = 0xFFFF, label = 'Nation',                                                                                mode = 'raw'},
    {st = 0xFFFF, label = 'Current Nation Mission',        cat = 'mission', area = 'nation',   kind = 'current',   mode = 'linear'},
    {st = 0xFFFF, label = 'Current ROZ Mission',           cat = 'mission', area = 'zilart',   kind = 'current',   mode = 'linear'},
    {st = 0xFFFF, label = 'Current COP Mission',           cat = 'mission', area = 'cop',      kind = 'current',   mode = 'linear'},
    {st = 0xFFFF, label = 'Current ACP Mission',           cat = 'mission', area = 'acp',      kind = 'current',   mode = 'linear'},
    {st = 0xFFFF, label = 'Current MKD Mission',           cat = 'mission', area = 'mkd',      kind = 'current',   mode = 'linear'},
    {st = 0xFFFF, label = 'Current ASA Mission',           cat = 'mission', area = 'asa',      kind = 'current',   mode = 'linear'},
    {st = 0xFFFF, label = 'Current SOA Mission',           cat = 'mission', area = 'adoulin',  kind = 'current',   mode = 'linear'},
    {st = 0xFFFF, label = 'Current ROV Mission',           cat = 'mission', area = 'rov',      kind = 'current',   mode = 'linear'},
}

local frozen_subtypes, n_frozen_st = {}, 0
for _, w in ipairs(EXPECT_FIELD) do
    if not frozen_subtypes[w.st] then
        frozen_subtypes[w.st] = true
        n_frozen_st = n_frozen_st + 1
    end
end
check('the frozen field-log list is still 23 fields over 6 sub-types',
      #EXPECT_FIELD == 23 and n_frozen_st == 6,
      ('%d fields, %d sub-types'):format(#EXPECT_FIELD, n_frozen_st))

local mis_field = {}
for _, w in ipairs(EXPECT_FIELD) do
    local found
    for _, f in ipairs(state.FIELD_LOGS[w.st] or {}) do
        if f.label == w.label then found = f end
    end
    if not found then
        mis_field[#mis_field + 1] = ('0x%04X %s absent'):format(w.st, w.label)
    elseif found.cat ~= w.cat or found.area ~= w.area
           or found.kind ~= w.kind or found.mode ~= w.mode then
        mis_field[#mis_field + 1] = ('0x%04X %s->%s/%s/%s/%s'):format(
            w.st, w.label, tostring(found.cat), tostring(found.area),
            tostring(found.kind), tostring(found.mode))
    end
end
check('all 23 frozen field-log fields are still routed as frozen',
      #mis_field == 0, table.concat(mis_field, ' '))

local frozen_fl = {}
for _, w in ipairs(EXPECT_FIELD) do
    frozen_fl[('0x%04X %s'):format(w.st, w.label)] = true
end
local extra_fl = {}
for subtype, fields in pairs(state.FIELD_LOGS) do
    for _, f in ipairs(fields) do
        local k = ('0x%04X %s'):format(subtype, tostring(f.label))
        if not frozen_fl[k] then extra_fl[#extra_fl + 1] = k end
    end
end
table.sort(extra_fl)
check('no field-log field exists that the frozen list does not name',
      #extra_fl == 0, table.concat(extra_fl, ' '))

--[[ And they must actually DECODE, not merely be present. One packet per frozen
     sub-type carrying every frozen label at once -- which is the shape the
     client sends -- and each linear field gets a DISTINCT value, so a label
     wired to the wrong area cannot pass by landing on a matching number. ]]
state.reset()
local packets, order = {}, {}
for i, w in ipairs(EXPECT_FIELD) do
    if not packets[w.st] then
        packets[w.st] = {Type = w.st}
        order[#order + 1] = w.st
    end
    if w.mode == 'bits' then packets[w.st][w.label] = blob{5}
    elseif w.mode == 'linear' then packets[w.st][w.label] = 200 + i
    else packets[w.st][w.label] = 0 end        -- Nation 0 -> San d'Oria
end
-- ipairs over `order`, not pairs over `packets`: keep the send order stable.
for _, subtype in ipairs(order) do state.handle_packet(packets[subtype]) end

local bad_bits, bad_lin, n_bits, n_lin = {}, {}, 0, 0
for i, w in ipairs(EXPECT_FIELD) do
    if w.mode == 'bits' then
        n_bits = n_bits + 1
        local fn = (w.kind == 'completed') and state.is_completed or state.is_current
        if fn(w.cat, w.area, 5) ~= true then
            bad_bits[#bad_bits + 1] = ('0x%04X %s'):format(w.st, w.label)
        end
    elseif w.mode == 'linear' then
        n_lin = n_lin + 1
        if state.linear_at(w.cat, w.area) ~= 200 + i then
            bad_lin[#bad_lin + 1] = ('0x%04X %s->%s'):format(w.st, w.label,
                tostring(state.linear_at(w.cat, w.area)))
        end
    end
end
check('the 9 field-log bitfield fields decode a set bit',
      #bad_bits == 0 and n_bits == 9, table.concat(bad_bits, ' '))
check('the 13 field-log linear fields each resolve to their OWN value',
      #bad_lin == 0 and n_lin == 13, table.concat(bad_lin, ' '))
--[[ The one `raw` field earns its place by routing: Nation is not a status,
     it is what decides WHICH nation line the single pointer describes. ]]
check('the raw Nation field still routes the nation mission pointer',
      state.nation() == 'sandoria'
      and state.linear_at('mission', 'sandoria') ~= nil
      and state.linear_at('mission', 'sandoria') == state.linear_at('mission', 'nation'),
      ('nation=%s sandoria=%s'):format(tostring(state.nation()),
          tostring(state.linear_at('mission', 'sandoria'))))

print('\n=== nation + Zilart missions (completed bitfield via 0x00D0) ===')
state.reset()
state.handle_packet{
    Type = 0x00D0,
    ["Completed San d'Oria Missions"] = blob{0, 1, 2},
    ['Completed Bastok Missions']     = blob{},
    ['Completed Windurst Missions']   = blob{},
    ['Completed Zilart Missions']     = blob{0},
}
check('sandoria mission 1 done',  state.status_of('mission', 'sandoria', 1) == 'done')
check('sandoria mission 9 avail', state.status_of('mission', 'sandoria', 9) == 'available')
check('zilart mission 0 done',    state.status_of('mission', 'zilart', 0) == 'done')
check('bastok untouched -> available', state.status_of('mission', 'bastok', 0) == 'available')

print('\n=== mutually exclusive rank-2 branches (5 / 8 / 9) ===')
--[[ Rank 2 branches are mutually exclusive. A Windurst character who runs "The
     Three Kingdoms" via Bastok has #5 and #9 set and never gets #8, so #8 must
     not sit at `available` showing a green "!" for a mission that can never be
     started. Any member completed finishes the whole group. ]]
state.reset()
state.handle_packet{
    Type = 0x00D0,
    ["Completed San d'Oria Missions"] = blob{},
    ['Completed Bastok Missions']     = blob{},
    ['Completed Windurst Missions']   = blob{0, 1, 2, 3, 4, 5, 9},   -- rank 2 via Bastok
    ['Completed Zilart Missions']     = blob{},
}
local st8, src8 = state.status_of('mission', 'windurst', 8)
check('the branch NOT taken reports done', st8 == 'done', tostring(st8))
check('  ... and says so via the group, not the bitfield', src8 == 'group', tostring(src8))
check('the branch taken is still plainly exact',
      select(2, state.status_of('mission', 'windurst', 9)) == 'exact')
check('completed_sibling names the branch actually run',
      state.completed_sibling('mission', 'windurst', 8) == 9,
      tostring(state.completed_sibling('mission', 'windurst', 8)))
check('a non-member in the same line is untouched',
      state.status_of('mission', 'windurst', 10) == 'available',
      tostring(state.status_of('mission', 'windurst', 10)))

--[[ Symmetric: we have only ever observed one player's bitfields, so the
     reverse pairing must work too. ]]
state.reset()
state.handle_packet{Type = 0x00D0, ['Completed Windurst Missions'] = blob{8}}
check('reverse pairing: #8 done finishes #9',
      state.status_of('mission', 'windurst', 9) == 'done')
check('  ... and finishes the base #5 too',
      state.status_of('mission', 'windurst', 5) == 'done')

state.reset()
state.handle_packet{Type = 0x00D0, ['Completed Windurst Missions'] = blob{5}}
check('the base alone finishes both branches',
      state.status_of('mission', 'windurst', 8) == 'done'
      and state.status_of('mission', 'windurst', 9) == 'done')

--[[ Do not group these by name. Two nations name the branches after the base
     mission ("The Three Kingdoms (Bastok)"), but San d'Oria does not: its
     branches are "Journey to Bastok" / "Journey to Windurst" against a base of
     "Journey Abroad". A name-based rule passes for windurst and bastok and
     misses sandoria. The grouping must stay structural. ]]
state.reset()
state.handle_packet{Type = 0x00D0, ["Completed San d'Oria Missions"] = blob{9}}
check("San d'Oria groups too, despite unrelated branch names",
      state.status_of('mission', 'sandoria', 8) == 'done',
      tostring(state.status_of('mission', 'sandoria', 8)))
state.reset()
state.handle_packet{Type = 0x00D0, ['Completed Bastok Missions'] = blob{8}}
check('Bastok groups too', state.status_of('mission', 'bastok', 9) == 'done')

--[[ The group is scoped to cat/area. Quest ids 5/8/9 in the very same nation
     are ordinary unrelated quests and must not be collapsed. ]]
state.reset()
state.handle_packet{Type = 0x0060, ['Quest Flags'] = blob{}}          -- current  windurst
state.handle_packet{Type = 0x00A0, ['Quest Flags'] = blob{9}}         -- completed windurst
check('QUESTS with the same ids are not grouped',
      state.status_of('quest', 'windurst', 8) == 'available',
      tostring(state.status_of('quest', 'windurst', 8)))

--[[ A stale `current` bit on the branch you abandoned must not win over a
     sibling that is actually finished -- either route ends the same mission. ]]
state.reset()
state.handle_packet{Type = 0x00D0, ['Completed Windurst Missions'] = blob{9}}
state.handle_packet{Type = 0xFFFF, Nation = 2, ['Current Nation Mission'] = 9}
check('a completed sibling outranks the mission pointer',
      state.status_of('mission', 'windurst', 8) == 'done',
      tostring(state.status_of('mission', 'windurst', 8)))

print('\n=== nation routing (0xFFFF) ===')
state.reset()
state.set_area_ids('mission', 'bastok', {0, 1, 2, 3, 4, 5})
state.handle_packet{
    Type = 0xFFFF,
    Nation = 1,                       -- Bastok
    ['Current Nation Mission'] = 3,
    ['Current ROZ Mission'] = 0,
}
check('nation pointer routed to bastok',
      state._resolve_linear('mission', 'bastok') == 3,
      tostring(state._resolve_linear('mission', 'bastok')))
state.reset()
state.set_area_ids('mission', 'windurst', {0, 1, 2, 3})
state.handle_packet{Type = 0xFFFF, Nation = 2, ['Current Nation Mission'] = 2}
check('nation 2 routes to windurst',
      state._resolve_linear('mission', 'windurst') == 2)

print('\n=== linear fuzzy match ===')
state.reset()
-- TVR sends 454 when the active DAT id is 452.
state.set_area_ids('mission', 'tvr', {448, 450, 452, 456})
state.handle_packet{Type = 0xFFFE, ['Current TVR Mission'] = 454}
check('largest id <= packet value wins',
      state._resolve_linear('mission', 'tvr') == 452,
      tostring(state._resolve_linear('mission', 'tvr')))
check('below pointer -> done',        state.status_of('mission', 'tvr', 450) == 'done')
check('at pointer    -> in_progress', state.status_of('mission', 'tvr', 452) == 'in_progress')
check('above pointer -> available',   state.status_of('mission', 'tvr', 456) == 'available')

print('\n=== TVR bit-31 "no active mission" flag ===')
state.reset()
state.set_area_ids('mission', 'tvr', {448, 452, 460})
-- 0x800001CC as a signed int32 is negative; stripping bit 31 gives 460.
state.handle_packet{Type = 0xFFFE, ['Current TVR Mission'] = 0x800001CC - 4294967296}
check('bit 31 stripped -> 460',
      state._resolve_linear('mission', 'tvr') == 460,
      tostring(state._resolve_linear('mission', 'tvr')))

print('\n=== robustness ===')
state.reset()
check('nil packet ignored',        state.handle_packet(nil) == false)
check('typeless packet ignored',   state.handle_packet{} == false)
check('unknown sub-type ignored',  state.handle_packet{Type = 0x1234} == false)
check('not loaded yet',            state.is_loaded() == false)
state.handle_packet{Type = 0x0050, ['Quest Flags'] = blob{0}}
check('loaded after a real packet', state.is_loaded() == true)
check('missing Quest Flags ignored', state.handle_packet{Type = 0x0058} == false)

print('\n=== dump / reset ===')
state.reset()
state.handle_packet{Type = 0x0050, ['Quest Flags'] = blob{4, 9}}
state.handle_packet{Type = 0x0090, ['Quest Flags'] = blob{4}}
local d = state.dump('quest', 'sandoria')
check('dump current',   #d.current == 2 and d.current[1] == 4 and d.current[2] == 9)
check('dump completed', #d.completed == 1 and d.completed[1] == 4)
state.reset()
check('reset clears', state.status_of('quest', 'sandoria', 4) == nil and state.is_loaded() == false)

print(('\n%d passed, %d failed'):format(pass, fail))
os.exit(fail == 0 and 0 or 1)

