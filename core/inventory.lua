--[[
core/inventory.lua -- cached "do I hold this item / key item" lookups.

Used for the turn-in signal (yellow "?" vs grey "?"), and almost never for
whether a quest is AVAILABLE -- you normally accept a quest before gathering
anything, so greying every quest whose items you are not carrying would hide
most of the index behind errands you have not run.

The one exception is an ENTRY CONDITION: a step-1 requirement flagged `eq`,
meaning the page says you must have the item equipped to start at all. See the
entry-conditions block in core/prereq.lua. Twenty entries index-wide.

The sweep is batched: one get_items() per bag, tallied into a flat
id -> count table. Never one call per item per bag.

Refresh is event-driven, not polled. The hot render path never touches this.
]]

local inventory = {}

-- Bags worth scanning, ordered cheapest-first.
--[[ Every bag the client will hand us, taken from res/bags.lua rather than
     remembered. Keep it in step with res/bags.lua: a bag missing from this
     list is not a missing count, it is a wrong inference. An item in an
     unscanned bag reads as "not held", so the marker stays grey and the step
     ladder pins to an earlier step, with `//qm why` calling it an honest
     evidence miss.

     `recycle` (17) is deliberately excluded: it is the delete bin, and an item
     in it is on its way out rather than held. Mog House bags stay in -- they
     are unreadable away from a Mog House, which the per-bag pcall already
     tolerates, and including them means a player standing in their Mog House
     gets a correct answer instead of a confusing one. ]]
local BAGS = {
    'inventory', 'satchel', 'sack', 'case', 'temporary',
    'wardrobe', 'wardrobe2', 'wardrobe3', 'wardrobe4',
    'wardrobe5', 'wardrobe6', 'wardrobe7', 'wardrobe8',
    'safe', 'safe2', 'storage', 'locker',
}

--[[ Item `Status`, per slot. Verified in THIS install rather than assumed:
     `windower.ffxi.get_items()` returns slots carrying `count, id, slot,
     bazaar, status, extdata` (the field block is in plugins/LuaCore.dll), and
     the byte's meaning is enumerated in addons/libs/packets/fields.lua:282
     under 'itemstat'.

         0x00 None    0x05 Equipped    0x0F Synthing
         0x13 Active linkshell         0x19 Bazaaring

     Only Equipped is used. It answers a question the bag sweep cannot: all
     twenty `Unlocking a Myth` pages want the weapon equipped and say nothing
     else, so carrying one in a wardrobe does not satisfy them. ]]
local ITEMSTAT_EQUIPPED = 0x05

local item_counts = {}      -- resource id -> total count held
local equipped = {}         -- resource id -> count held in an EQUIPPED slot
local key_items = {}        -- resource id -> true
--[[ Two dirty flags, not one.

     Packet 0x055 announces a key item change and says nothing about your bags,
     and every zone-in sends six or more of those packets. Keep them split, or
     arriving somewhere costs six sweeps of seventeen bags instead of one
     get_key_items() call. ]]
local dirty_items = true
local dirty_kis = true
local last_refresh = 0
local skipped_bags = 0      -- bags get_bag_info said this character does not have
local bags_answered = 0     -- bags get_bag_info answered about at all

--[[ `swept` distinguishes "you do not hold it" from "we have not read the bags"
     -- which covers never having looked AND having looked and been refused.
     count() returns 0 for all of them, which is harmless for a turn-in check (a
     missing item just means no yellow "?") but NOT for step inference, where
     "no evidence" would silently read as "step not done" and pin the marker to
     step 1 forever without ever saying why. core/steps.lua asks first.

     Set at the foot of refresh() from what that sweep actually managed to read,
     never latched true for having tried. The long note there says why.

     `generation` counts real sweeps. Anything caching a derived answer keys off
     it rather than off a timestamp, because refresh() is rate limited and
     count() can re-sweep on its own when dirty -- so the call site cannot know
     whether the underlying data moved. ]]
local swept = false
local generation = 0

-- Injectable so tests can run without a game client.
local api = {
    get_items = function(bag) return windower.ffxi.get_items(bag) end,
    get_key_items = function() return windower.ffxi.get_key_items() end,
    --[[ `windower.ffxi.get_bag_info(bag)` -> {max, count, enabled}. Verified
         present in this install (the function name and all three keys are in
         plugins/LuaCore.dll). Optional by design: nil here means "sweep
         everything". ]]
    get_bag_info = function(bag)
        -- Reads the global defensively: this module is loaded by offline tests
        -- where there is no `windower` at all.
        local w = windower
        local f = w and w.ffxi and w.ffxi.get_bag_info
        return f and f(bag) or nil
    end,
    clock = function() return os.clock() end,
}

function inventory.set_api(t)
    for k, v in pairs(t or {}) do api[k] = v end
end

function inventory.invalidate()
    dirty_items, dirty_kis = true, true
end

-- 0x055: key items moved, bags did not. See the note beside the flags.
function inventory.invalidate_key_items() dirty_kis = true end

function inventory.reset()
    item_counts, key_items, last_refresh = {}, {}, 0
    dirty_items, dirty_kis = true, true
    equipped, skipped_bags, bags_answered = {}, 0, 0
    swept = false
    generation = generation + 1
end

-- Has a real sweep ever happened? False means "unknown", not "empty".
function inventory.ready() return swept end

-- Bumped once per actual sweep. Cache keys, not timestamps.
function inventory.generation() return generation end

--[[ Rebuild the cache. Cheap enough to call on any inventory event, but rate
     limited so a burst of "add item" packets (a stack split, a coffer opening)
     cannot trigger a dozen full sweeps in one frame. ]]
function inventory.refresh(force)
    local now = api.clock()
    local want_items = force or dirty_items or (now - last_refresh) >= 5
    local want_kis = force or dirty_kis or (now - last_refresh) >= 5
    if not want_items and not want_kis then return false end

    if want_kis then
        local kis = {}
        local okk, list = pcall(api.get_key_items)
        if okk and type(list) == 'table' then
            for _, id in pairs(list) do
                if type(id) == 'number' then kis[id] = true end
            end
        end
        key_items = kis
        dirty_kis = false
        --[[ The only moment the swept list and the 0x055 decode both exist, so
             the only place the bitfield's id stride can be checked against
             ground truth. See core/keyitems.lua -- it is information until it
             agrees, never before. ]]
        if okk and type(list) == 'table' then
            pcall(function() require('core/keyitems').verify(list) end)
        end
    end

    if not want_items then
        last_refresh = now
        generation = generation + 1
        return true
    end

    local counts, eq, skipped, answered = {}, {}, 0, 0
    --[[ Bags this sweep got a real answer about. Read by the `swept` decision
         below the loop, and it is a COUNT OF SUCCESSES rather than of attempts:
         a sweep in which every get_items() threw learned nothing whatever, and
         must not be allowed to claim it did. ]]
    local read = 0
    for _, bag in ipairs(BAGS) do
        --[[ Skip bags this character does not have. Most characters own a
             fraction of the seventeen -- the wardrobes and the second safe are
             all purchases -- and get_items() on one still costs a call and a
             table.

             Skip only on an explicit `enabled == false`. A failed call, a
             missing function or any other shape falls through to sweeping,
             because the cost of a wrong skip is not a slow sweep: it is an item
             reading as not-held, which pins a step ladder and produces a marker
             that never advances. That failure mode is silent. ]]
        local okb, info = pcall(api.get_bag_info, bag)
        --[[ Counted separately from `skipped`, because "0 skipped" alone is
             ambiguous: it reads the same whether every bag is enabled or
             get_bag_info answered nothing at all. The first is a fact about
             the character, the second about the client, and a diagnostic that
             cannot tell them apart is not a diagnostic. ]]
        if okb and type(info) == 'table' and info.enabled ~= nil then
            answered = answered + 1
        end
        local usable = not (okb and type(info) == 'table' and info.enabled == false)
        if not usable then
            skipped = skipped + 1
        else
            local ok, items = pcall(api.get_items, bag)
            if ok and type(items) == 'table' then
                --[[ An EMPTY table counts. "This bag holds nothing" is a fact
                     about the character; a thrown call is a fact about the
                     client, and only the second one is ignorance. ]]
                read = read + 1
                for _, slot in pairs(items) do
                    if type(slot) == 'table' and slot.id and slot.id ~= 0 then
                        local n = slot.count or 1
                        counts[slot.id] = (counts[slot.id] or 0) + n
                        if slot.status == ITEMSTAT_EQUIPPED then
                            eq[slot.id] = (eq[slot.id] or 0) + n
                        end
                    end
                end
            end
        end
    end
    item_counts, equipped = counts, eq
    skipped_bags, bags_answered = skipped, answered

    dirty_items = false
    last_refresh = now
    --[[ `swept` describes the tables this sweep just installed, so it is
         recomputed here rather than latched true on the first refresh().

         A flat `swept = true` would say "a sweep was tried", not "the bags
         were read". At load and at login the client can refuse every
         get_items(); the loop learns nothing, but `counts` has already replaced
         the cache, so count() answers 0 for everything. ready() must not call
         that a real reading of an empty inventory: the entry gates in
         core/prereq.lua would turn it into a definite false, a grey "!" over a
         quest the player can walk in and start. An unknown turned into a
         confident no is the worst answer this addon can give.

         `read > 0` is the whole test: a bag handed back a table, empty or not.

         Do not OR in `skipped > 0` on the grounds that `enabled == false` is
         the client answering rather than failing. `skipped` can only decide
         when `read == 0`, which means no bag answered at all, `inventory`
         included, and every character owns `inventory`.

         swept goes false only at module load and in reset() (shipped caller:
         the login handler); refresh() re-sweeps within five seconds. ]]
    swept = (read > 0)
    generation = generation + 1
    return true
end

function inventory.count(rid)
    if dirty_items then inventory.refresh() end
    return item_counts[rid] or 0
end

function inventory.has_item(rid, n)
    return inventory.count(rid) >= (n or 1)
end

--[[ How many of this item are in an EQUIPPED slot right now.

     Distinct from `count` on purpose. "Held" and "equipped" are different
     facts and the twenty `Unlocking a Myth` quests need the second one: their
     pages ask for a Vigil Weapon *equipped* and say nothing else, so a sword
     in a wardrobe does not satisfy them. ]]
function inventory.equipped_count(rid)
    if dirty_items then inventory.refresh() end
    return equipped[rid] or 0
end

function inventory.has_equipped(rid, n)
    return inventory.equipped_count(rid) >= (n or 1)
end

function inventory.has_key_item(rid)
    if dirty_kis then inventory.refresh() end
    return key_items[rid] == true
end

--[[ One requirement, one answer -- so `satisfies` and `satisfies_any` cannot
     drift apart, which they would the moment a third kind appeared.

     `eq = true` on a requirement means the quest wants the item EQUIPPED
     rather than merely carried. The flag is set at build time and only where
     the source page actually says so; without it, held is held. ]]
local function holds(r)
    if r.kind == 'ki' then return inventory.has_key_item(r.rid) end
    if r.eq then return inventory.has_equipped(r.rid, r.n) end
    return inventory.has_item(r.rid, r.n)
end
inventory.holds = holds

--[[ Are all of an index entry's resolved requirements held?
     Returns satisfied, missing_count. Note that `reqs` on an entry has already
     been filtered by the builder to items it could resolve -- unparseable BG
     Wiki prose was dropped and the entry flagged reqs_partial. ]]
function inventory.satisfies(reqs)
    if not reqs or #reqs == 0 then return true, 0 end
    local missing = 0
    for _, r in ipairs(reqs) do
        if not holds(r) then missing = missing + 1 end
    end
    return missing == 0, missing
end

--[[ Is ANY ONE of these held?  -> satisfied, held_count

     The other half of `satisfies`, and the corpus needs both. 18% of the pilot
     quests describe alternatives rather than a set: `Cargo` takes any one of
     three rolanberries, `The Angling Armorer` any one of four rusty weapons,
     `Mandragora-Mad` any one of five drops, and `The Gobbiebag Part I` takes
     four specific items OR a single Goblin Stew instead. An AND-list is simply
     the wrong shape for those: it would demand every alternative at once. ]]
function inventory.satisfies_any(alts)
    if not alts or #alts == 0 then return false, 0 end
    local held = 0
    for _, r in ipairs(alts) do
        if holds(r) then held = held + 1 end
    end
    return held > 0, held
end

--[[ The full predicate a step is judged by: the listed SET, or ALTERNATIVELY
     any single one of the alternates.

     `alt` is not "and also one of these" -- it is a second, independent way to
     satisfy the same step. That is what the data actually says: Gobbiebag's
     stew REPLACES the four items rather than joining them, so a conjunction
     would be wrong in exactly the case the field was added for.

     -> satisfied, recorded   (recorded = false when neither list has content,
     which callers must distinguish from "not held": a step with nothing
     recorded is unknown, not unsatisfied.) ]]
function inventory.meets(all, alt)
    local has_all = all and #all > 0
    local has_alt = alt and #alt > 0
    if not has_all and not has_alt then return false, false end
    if has_all and inventory.satisfies(all) then return true, true end
    if has_alt and inventory.satisfies_any(alt) then return true, true end
    return false, true
end

function inventory.stats()
    local n = 0
    for _ in pairs(item_counts) do n = n + 1 end
    local k = 0
    for _ in pairs(key_items) do k = k + 1 end
    local e = 0
    for _ in pairs(equipped) do e = e + 1 end
    return n, k, (dirty_items or dirty_kis), e, skipped_bags, bags_answered
end

inventory.BAGS = BAGS

return inventory
