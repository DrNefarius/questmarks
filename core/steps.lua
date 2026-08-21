--[[
core/steps.lua -- which step of a quest are you on?

Packet 0x056 says only available / in progress / done. Nothing in any packet
says "you are on step 3 of 7". So a quest's position is INFERRED, from the only
things the client will actually tell us: the items and key items you hold.

    current(q) = 1 + max{ i : evidence(step i) is definitely TRUE }

A high-water mark over POSITIVE evidence only. Three properties follow, and
each is pinned by a test:

  * Steps with no evidence are stepped OVER, not blocked. Most steps have none
    -- "talk to X" leaves no trace -- so a rule that waited for proof of every
    step would never move at all.
  * The mark never runs ahead of the evidence. It can lag (an unmodellable
    stretch leaves the marker on the last step we could see), and lagging is
    the safe direction: the marker points somewhere you have already been
    rather then somewhere you have not earned.
  * With no evidence anywhere it returns 1, which is exactly the pre-steps
    behaviour -- the marker sits on the quest giver.

The governing invariant: bad step data may put a marker somewhere new; it must
never silently remove the marker that exists today. Everything here that looks
over-cautious is serving that sentence.

Kept out of prereq.lua on purpose. That file's header promises pure tri-state
functions of packet state and fame; this one is stateful (a memo, a generation
counter, a per-session latch) and would falsify it.
]]

local steps = {}

local inventory = require('core/inventory')
local state = require('core/state')

local enabled = true

--[[ Memo, dropped wholesale whenever inventory actually moves. Keyed by quest
     key; only quests something asked about are ever computed, so this never
     walks the index. ]]
local cache = {}
local cache_gen = -1

--[[ Per-session high-water mark, so the marker cannot walk BACKWARDS while you
     play. It has to exist because a key item can be handed over mid-quest: the
     evidence that carried you to step 4 disappears at step 5, and without the
     latch the marker would jump back to the giver.

     Deliberately not persisted. The project already draws this line correctly
     for fame: a dialogue READING is an observation and is saved per character,
     while the INFERRED floor is recomputed from scratch on every settle
     (core/quests.lua). A step mark is a floor, not a reading. Writing an
     inference to disk makes a wrong one permanent and undiagnosable. ]]
local latch = {}

local evals = 0

local function qkey(q) return q.cat .. '/' .. q.area .. '/' .. q.id end

-- Inventory moved: every derived answer is stale. O(1) -- a fresh table beats
-- walking entries to compare timestamps.
function steps.invalidate()
    cache = {}
    cache_gen = -1
end

function steps.enable(v) enabled = v and true or false; steps.invalidate() end
function steps.enabled() return enabled end

-- Login, logout, character switch: the latch describes a character's session
-- and means nothing for the next one.
function steps.reset()
    cache, cache_gen, latch, evals = {}, -1, {}, 0
end

--[[ 0x056 settled. A quest that is no longer in progress has no position, and
     keeping its latch would resurrect a stale mark if it were ever repeated.
     Walks the latch table (tens of entries), never the index. ]]
function steps.on_state_change()
    for k in pairs(latch) do
        local cat, area, id = k:match('^(.-)/(.-)/(%d+)$')
        if cat and state.status_of(cat, area, tonumber(id)) ~= 'in_progress' then
            latch[k] = nil
        end
    end
    steps.invalidate()
end

-------------------------------------------------------------------------------
-- the rule
-------------------------------------------------------------------------------

--[[ Is this step's target something a marker can sit on?

     'npc' is the ordinary case. Doors and named furniture are real, targetable
     entities the client names, so they come through as npc keys too.

     MONSTERS COUNT. get_mob_list() returns every entity and not only NPCs, so
     "defeat the NM" is a real, pointable target -- and it is the single biggest
     category of step that otherwise has nothing to mark: 281 of 987 walkthroughs
     have a defeat/kill/spawn step. Everything downstream of this predicate was
     already built for it and was simply never reached: build_index emits a
     by_npc row per monster carrying its role, quests.wanted_names tags those
     keys 'mob', the scan gives every monster its own slot instead of collapsing
     duplicates to the nearest and skips corpses (status 2/3), and
     render/markers picks the glyph from the role -- a sword to kill it, a bag
     because it drops what this step needs.

     Measured before this line changed: 49 of 54 monster rows in the pilot index
     could never draw, because marker_idx walked straight back past their step.
     The five that could were steps that happened to ALSO have an NPC target.

     A '???' and a zone entry still have nothing to mark, and a fight step with
     no monster recorded still has nothing to mark -- which is what keeps the
     step-0 giver fallback alive for quests like `Blade of Evil`. ]]
local function markable(s)
    if s == nil then return false end
    if s.npc ~= nil and s.npc ~= '' then return true end
    return s.mobs ~= nil and #s.mobs > 0
end
steps.markable = markable

--[[ ... on a NAMED entity you can walk up to and talk to, specifically.

     Narrower than `markable` on purpose, and the difference matters in exactly
     one place: a quest you have NOT accepted is offered by somebody, never by a
     monster, so its step 1 may only be marked when there is a real entity
     there. Without this split a quest whose first step is "defeat X" would put
     a green "!" on a monster for a quest you cannot accept from it. ]]
local function has_entity(s)
    return s ~= nil and s.npc ~= nil and s.npc ~= ''
end
steps.has_entity = has_entity

--[[ Hand-over steps are the ones where holding the right items means "ready",
     which is what earns the yellow "?" rather than the grey one.

     A final `talk` counts. BG Wiki writes the last step of most quests as
     "return to X and speak to him", and treating that as a hand-over preserves
     the behaviour the addon already has for quests whose requirements resolve. ]]
function steps.is_handover(q, i)
    local s = q.steps and q.steps[i]
    if not s then return false end
    if s.k == 'trade' or s.k == 'turnin' then return true end
    return s.k == 'talk' and i == #q.steps
end

--[[ -> idx, n, step, info   (or nil when there is nothing to say)

     info.marker_idx  the step whose target actually carries the marker; equals
                      idx unless idx is unmarkable and we held back
     info.best        highest step whose evidence read TRUE (0 = none)
     info.source      'evidence' | 'latch' | 'default' | 'unknown'
     info.known       false when inventory has never been swept
     info.held        true when marker_idx < idx ]]
function steps.current(q)
    if not enabled then return nil end
    if type(q) ~= 'table' or type(q.steps) ~= 'table' or #q.steps == 0 then
        return nil
    end

    --[[ Repeatable quests DO step, but only while re-accepted -- which is
         guaranteed by the only caller that matters: prereq consults a position
         solely when 0x056 reports the quest in progress. A completed repeatable
         is 'done', so it falls to the start-NPC branch and shows its blue "!"
         on the giver exactly as before.

         The residual risk is a quest that leaves its key item with you after
         completion: re-accept it and the mark starts partway along. Measured
         cost of excluding them outright instead was 93 of the 347 key-item
         quests -- a third of everything that can step -- so the trade goes the
         other way, with `//qm steps off` as the escape hatch. ]]

    local n = #q.steps
    local key = qkey(q)

    local gen = inventory.generation()
    if cache_gen ~= gen then cache, cache_gen = {}, gen end
    local hit = cache[key]
    if hit then return hit.idx, n, q.steps[hit.idx], hit end

    --[[ Nothing swept yet means every count reads 0, which is indistinguishable
         from "not held". Answer step 1 -- identical to the pre-steps behaviour
         -- and do NOT write the latch, because a monotone structure must never
         record a guess. ]]
    if not inventory.ready() then
        local info = {marker_idx = 1, best = 0, source = 'unknown',
                      known = false, held = false}
        cache[key] = {idx = 1, marker_idx = 1, best = 0, source = 'unknown',
                      known = false, held = false}
        return 1, n, q.steps[1], info
    end

    --[[ Accepting the quest is itself an observation. Step 1 is whatever
         starts it (the conversation, the door, the zone line), so 0x056
         saying in_progress proves step 1 is behind you. That is a reading,
         not a guess.

         Without this the mark sits on the giver showing "talk to me" for a
         quest you just took from him. Found in game on Eco-Warrior: accepted
         from Lumomo, step 1 grants nothing observable, so the marker stayed
         on Lumomo while the real next stop was Ahko Mhalijikhari, two zones
         away.

         It does not weaken positive-evidence-only. It says step 1 is done,
         never that step 2 is reachable.

         Checked here rather than trusted from the caller, because `current`
         is public and an unaccepted quest must have no position at all. ]]
    local accepted = (n > 1)
        and state.status_of(q.cat, q.area, q.id) == 'in_progress'

    local best = accepted and 1 or 0
    local from_accept = accepted
    for i = 1, n do
        local s = q.steps[i]
        --[[ `optional` steps are never ladder positions. 41% of walkthroughs
             carry conditional or "for an additional cutscene" lines, and
             treating one as a position pins the mark on something the player
             may never do. ]]
        --[[ `ev_alt` is a SECOND way to satisfy the same step, not an extra
             condition on it -- see inventory.meets. ]]
        if not s.optional and inventory.meets(s.ev, s.ev_alt) then
            best = i
            from_accept = false
        end
    end
    evals = evals + 1

    local idx = best + 1
    --[[ Clamp to n, not n+1. best == n means "everything observable is done",
         and the last step's target is the turn-in NPC -- exactly where the
         yellow "?" belongs. Whether the quest is DONE is 0x056's call, not
         ours. ]]
    if idx > n then idx = n end

    --[[ Its own label, not 'evidence'. `//qm why` printing "step 2 (evidence)"
         when nothing was held would be a lie about where the number came from,
         and that line is the whole diagnosis path for "why is my marker here". ]]
    local source
    if from_accept then source = 'accepted'
    elseif best > 0 then source = 'evidence'
    else source = 'default' end
    local held_mark = latch[key]
    if held_mark and held_mark > idx then
        idx = held_mark
        source = 'latch'
    end
    latch[key] = idx

    --[[ The current step may have nothing to mark. Walk BACK to the nearest
         markable one rather than showing nothing.

         Showing nothing is the one genuinely unacceptable option: today a
         quest with no usable requirements still shows a grey "?" on its giver
         for its whole duration, and a marker that vanishes the moment
         inference lands on a "defeat the NM" step is indistinguishable from a
         crash or from the addon being switched off. Jumping FORWARD to the
         next markable step is worse still -- it asserts the unmarkable step is
         finished, which is the positive-evidence-only rule broken outright. ]]
    local marker_idx = idx
    while marker_idx > 1 and not markable(q.steps[marker_idx]) do
        marker_idx = marker_idx - 1
    end
    if not markable(q.steps[marker_idx]) then
        --[[ Nothing markable at or before the current step. Some quests are
             like this all the way through: "Blade of Evil" starts by ZONING
             into Beadeaux and everything after is a '???' or a mob, so it
             compiles to six steps and zero markable targets.

             Fall back to step 0 -- the quest giver, who is not a step at all
             but is where the marker sat before any of this existed. That keeps
             the promise that new data may move a marker but never silently
             deletes one.

             Deliberately NOT a forward scan for the next markable step: that
             would assert the unmarkable ones are finished, which is the
             positive-evidence-only rule broken outright. ]]
        marker_idx = (q.snpc and q.snpc ~= '') and 0 or nil
    end

    local info = {
        marker_idx = marker_idx, best = best, source = source,
        known = true, held = (marker_idx ~= nil and marker_idx ~= idx),
    }
    cache[key] = {idx = idx, marker_idx = marker_idx, best = best,
                  source = source, known = true, held = info.held}
    return idx, n, q.steps[idx], info
end

-------------------------------------------------------------------------------
-- diagnostics
-------------------------------------------------------------------------------

--[[ What `//qm why` should print in a ladder row's target column.

     A step can be markable WITHOUT having an npc key -- that is what a monster
     step is -- so the printer cannot derive this from `npc` alone. It used to
     try, as `row.markable and row.npc or '(nothing to mark)'`, which for a mob
     step collapses through a nil `npc` straight to the fallback and reports
     "(nothing to mark)" about a step carrying five live markers. Reported in
     game on Mandragora-Mad. Computed here, once, so there is one answer. ]]
local function row_label(s)
    if s == nil then return nil end
    if s.npc ~= nil and s.npc ~= '' then return s.npc end
    if s.mobs and #s.mobs > 0 then
        local names = {}
        for _, m in ipairs(s.mobs) do
            if m.name then names[#names + 1] = m.name end
        end
        if #names > 0 then return table.concat(names, ', ') end
    end
    return nil
end
steps.row_label = row_label

--[[ One row per step for `//qm why`, including the verdict on each piece of
     evidence. This is the whole diagnosis path for "my marker is on the wrong
     NPC", so it reports what was checked, not just the conclusion. ]]
--[[ `active` = the quest is in progress. When it is not, there IS no position
     -- only a giver -- so report the ladder without asking for one. That also
     keeps //qm why from writing a latch entry for every quest it explains,
     which is what once inflated //qm steps to "62 in progress" on a character
     with a handful. ]]
function steps.explain(q, active)
    if type(q) ~= 'table' or type(q.steps) ~= 'table' or #q.steps == 0 then
        return nil
    end
    if active == false then
        local out = {idx = 1, n = #q.steps, rows = {},
                     info = {marker_idx = 1, best = 0, source = 'not_started',
                             known = inventory.ready(), held = false}}
        for i = 1, #q.steps do
            local s = q.steps[i]
            out.rows[i] = {
                n = i, kind = s.k, npc = s.npc, zone = s.z, grid = s.g,
                label = row_label(s),
                optional = s.optional and true or false,
                markable = markable(s), evidence = s.ev, evidence_alt = s.ev_alt,
                verdict = nil,
                current = (i == 1), marker = (i == 1),
            }
        end
        return out
    end
    local idx, n, _, info = steps.current(q)
    if not idx then return nil end
    local out = {idx = idx, n = n, info = info, rows = {}}
    for i = 1, n do
        local s = q.steps[i]
        local verdict
        local met, recorded = inventory.meets(s.ev, s.ev_alt)
        if not recorded then
            verdict = nil                                  -- nothing recorded
        elseif not info.known then
            verdict = nil                                  -- not swept yet
        else
            verdict = met and true or false
        end
        out.rows[i] = {
            n = i, kind = s.k, npc = s.npc, zone = s.z, grid = s.g,
            label = row_label(s),
            optional = s.optional and true or false,
            markable = markable(s),
            evidence = s.ev, evidence_alt = s.ev_alt, verdict = verdict,
            current = (i == idx), marker = (i == info.marker_idx),
        }
    end
    return out
end

function steps.stats()
    --[[ `advanced` is the number that matters, and it is NOT the size of the
         latch table. Every quest steps.current() is asked about gets a latch
         entry, including the ones sitting at step 1, so counting entries
         reports "how many quests are in progress" while claiming to report
         "how many have moved". Caught in game: the synthetic single-step
         ladder, which provably cannot advance, reported 62.

         Only a mark ABOVE 1 means inference did something. ]]
    local latched, advanced = 0, 0
    for _, idx in pairs(latch) do
        latched = latched + 1
        if idx > 1 then advanced = advanced + 1 end
    end
    local cached = 0
    for _ in pairs(cache) do cached = cached + 1 end
    return {
        enabled = enabled, tracked = latched, advanced = advanced,
        cached = cached, generation = cache_gen, evals = evals,
        inventory_ready = inventory.ready(),
    }
end

return steps
