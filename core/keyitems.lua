--[[
core/keyitems.lua -- the two bitfields in packet 0x055, decoded.

Layout from addons/libs/packets/fields.lua:2784 in THIS install:

    fields.incoming[0x055] = L{
        {ctype='data[0x40]', label='Key item available'},   -- 0x04
        {ctype='data[0x40]', label='Key item examined'},    -- 0x44
        {ctype='unsigned int', label='Type'},               -- 0x84
    }

`available` is what `windower.ffxi.get_key_items()` returns; `examined` (1 once
you have looked at the key item in the menu) is available nowhere else. The
addon used to drop the body and treat 0x055 as a "re-sweep the bags" ping that
killed the whole inventory cache; a zone-in sends six or more, so arriving
anywhere forced repeated 17-bag sweeps for data the packet already held.
`examined` only shows in `//qm why` and `//qm diag`; no dataset step uses it.

Category `t` carries ids `t*512 + bit`. fields.lua's comment says six
categories, which stops at id 3071, but res/key_items.lua here runs to 3381.
One login in Lower Jeuno: 16 packets, categories 0..7, 512 bits each, highest
id 4095, cross-check 43 agree, 0 only in the packet, 0 only in the sweep. So
there are eight categories now, not six, and the stride is right. Nothing here
special-cased six; any `Type` is accepted and offsets by 512.

The same comparison runs on every sweep, so a ninth category shows up as a
number rather than a surprise. The decode is TRUSTED only after a run with no
disagreement in either direction; until then the swept list stays authoritative
and this module is information only. `//qm data` prints the verdict, the
categories seen and the highest id.
]]

local keyitems = {}

local bit = require('bit')
local band, lshift = bit.band, bit.lshift

local BYTES = 0x40              -- per bitfield
local BITS  = BYTES * 8         -- 512 ids per category

--[[ Per category, so that "this category has never arrived" stays
     distinguishable from "the bit is 0". Collapsing them would make an
     unarrived category read as "you hold none of these", which is the exact
     shape of error that produces a marker stuck on step 1 with no explanation. ]]
local avail = {}                -- [type] = {[bit] = true}
local exam  = {}                -- [type] = {[bit] = true}
local n_packets = 0
local max_id = -1
local trusted = false
local last_check = nil          -- {matched, only_packet, only_swept} or nil

function keyitems.reset()
    avail, exam = {}, {}
    n_packets, max_id = 0, -1
    trusted, last_check = false, nil
end

local function decode(raw, into)
    local changed = false
    for i = 0, BITS - 1 do
        local byte = raw:byte(math.floor(i / 8) + 1)
        local on = byte ~= nil and band(byte, lshift(1, i % 8)) ~= 0
        local was = into[i] or false
        if on ~= was then
            into[i] = on or nil
            changed = true
        end
    end
    return changed
end

--[[ Feed a parsed 0x055.  -> changed(boolean)

     `packets.parse` applies a field's `enc.decode` and never its `fn`, so
     'Key item available' arrives as a raw 64-byte STRING rather than as the hex
     text fields.lua's formatter would render. Both shapes are tolerated anyway:
     a non-string is simply refused, because a half-understood packet must leave
     the previous answer alone rather than overwrite it with nothing. ]]
function keyitems.handle_packet(p)
    if type(p) ~= 'table' then return false end
    local t = p['Type']
    local av = p['Key item available']
    local ex = p['Key item examined']
    if type(t) ~= 'number' or t < 0 or type(av) ~= 'string' then return false end

    avail[t] = avail[t] or {}
    exam[t]  = exam[t] or {}
    local changed = decode(av, avail[t])
    if type(ex) == 'string' then
        -- Deliberately not folded into `changed`: nothing acts on `examined`,
        -- so a change in it must not invalidate a single cache.
        decode(ex, exam[t])
    end

    n_packets = n_packets + 1
    local top = (t + 1) * BITS - 1
    if top > max_id then max_id = top end
    return changed
end

-- Has any category arrived at all?
function keyitems.ready() return n_packets > 0 end

--[[ -> true | false | nil   (nil = this id's category has never arrived)

     Tri-state on purpose, and for the same reason every predicate in
     core/prereq.lua is: an unknown that collapses to false is a confidently
     wrong answer, and here it would be one about evidence. ]]
local function lookup(store, id)
    if type(id) ~= 'number' or id < 0 then return nil end
    local t = math.floor(id / BITS)
    local c = store[t]
    if not c then return nil end
    return c[id % BITS] == true
end

function keyitems.available(id) return lookup(avail, id) end
function keyitems.examined(id) return lookup(exam, id) end

--[[ Every id the packets currently report as held. Used for the cross-check
     and for diagnostics; nothing in the marker path walks it. ]]
function keyitems.held_ids()
    local out = {}
    for t, c in pairs(avail) do
        for b in pairs(c) do out[#out + 1] = t * BITS + b end
    end
    table.sort(out)
    return out
end

--[[ Compare the decode against the list the client hands back, and only then
     decide whether to believe it.

     `swept` is the array of ids from windower.ffxi.get_key_items(). Agreement
     has to hold in BOTH directions: an id the packet reports and the sweep does
     not is just as much a broken stride as the reverse. One disagreement is
     enough to withdraw trust -- there is no partial credit for a bitfield.

     Called from the inventory sweep, which is the only place both facts exist
     at the same moment. ]]
function keyitems.verify(swept)
    if type(swept) ~= 'table' or not keyitems.ready() then
        trusted = false
        return false
    end

    local from_sweep = {}
    for _, id in pairs(swept) do
        if type(id) == 'number' then from_sweep[id] = true end
    end

    local matched, only_packet, only_swept = 0, 0, 0
    for _, id in ipairs(keyitems.held_ids()) do
        if from_sweep[id] then matched = matched + 1 else only_packet = only_packet + 1 end
    end
    for id in pairs(from_sweep) do
        --[[ An id in a category that never arrived is NOT a disagreement --
             it is missing data, and counting it as one would keep trust
             permanently withdrawn on a character who has not zoned yet. ]]
        if keyitems.available(id) == false then only_swept = only_swept + 1 end
    end

    last_check = {matched = matched, only_packet = only_packet,
                  only_swept = only_swept}
    trusted = (only_packet == 0 and only_swept == 0)
    return trusted
end

function keyitems.trusted() return trusted end

function keyitems.stats()
    local cats, n_avail, n_exam = {}, 0, 0
    for t, c in pairs(avail) do
        cats[#cats + 1] = t
        for _ in pairs(c) do n_avail = n_avail + 1 end
    end
    for _, c in pairs(exam) do
        for _ in pairs(c) do n_exam = n_exam + 1 end
    end
    table.sort(cats)
    return {
        packets = n_packets, categories = cats, held = n_avail,
        examined = n_exam, max_id = max_id, trusted = trusted,
        check = last_check, bits_per_category = BITS,
    }
end

keyitems.BITS = BITS

return keyitems
