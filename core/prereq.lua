--[[
core/prereq.lua -- tri-state prerequisite evaluation.

Every predicate answers true / false / nil, and they aggregate as:

    any false          -> 'blocked'        (grey !)
    else any nil       -> 'unverifiable'   (black !)
    else               -> 'ready'          (yellow !)

The core rule: nil must never collapse to true or false. Fame is permanently
unknowable for a region the player has never had checked, and silently guessing
either way produces confidently wrong markers -- worse than an honest hedge.
The black "!" exists precisely so that uncertainty is visible rather than
laundered into a confident answer.

BLACK, not blue, and the distinction is load-bearing: render/markers.lua draws
'unknown' at {25,25,32} -- near-black, because set_color multiplies the texture
and {0,0,0} would erase the glyph -- while blue {90,170,255} is 'repeat'.

Every predicate also records a human-readable reason, which is what makes
`//qm why <npc>` able to explain any marker on screen.
]]

local prereq = {}

local state = require('core/state')
local fame = require('core/fame')
local inventory = require('core/inventory')
-- steps requires state and inventory, never prereq: no cycle.
local steps = require('core/steps')
--[[ Pure arithmetic over a packet, no client call anywhere in it, so requiring
     it here keeps every predicate testable with no game running. ]]
local skills = require('core/skills')

--[[ Step kinds where step 1 IS the acceptance, so its items are a condition of
     starting rather than an errand to run afterwards. See the entry-conditions
     block in `evaluate`. `talk` is not here on purpose. ]]
local ENTRY_KIND = {trade = true, examine = true}

-- Names resolved to (cat, area, id) at build time; used to label reasons.
local names = nil
function prereq.set_names(t) names = t end

--[[ The player's own job and level, pushed in from the entry point rather than
     read here, so every predicate stays testable with no game client.

     nil means NOT KNOWN YET -- at the character-select screen there is no
     player -- and the tri-state rule applies in full: an unknown job must read
     `nil`, never `false`. Guessing "you cannot do this" before login would
     grey out most of the artifact-armour lines on sight. ]]
local player_job, player_lvl = nil, nil
function prereq.set_player(job, lvl)
    player_job = job
    player_lvl = tonumber(lvl)
end

local function quest_name(cat, area, id)
    local c = names and names[cat]
    local a = c and c[area]
    return (a and a[id]) or string.format('%s #%d', area, id)
end

--[[ Evaluate one index entry.
     -> status, reasons
        status  = 'ready' | 'blocked' | 'unverifiable'
        reasons = array of {ok = true|false|nil, text = ...} ]]
function prereq.evaluate(entry)
    local reasons = {}
    local any_false, any_unknown = false, false

    local function add(ok, text)
        reasons[#reasons + 1] = {ok = ok, text = text}
        if ok == false then any_false = true
        elseif ok == nil then any_unknown = true end
    end

    -- --- prerequisite quests -------------------------------------------
    for _, p in ipairs(entry.prev or {}) do
        if p.unresolved then
            --[[ The builder could not map this name to a DAT id -- ambiguous
                 across areas, or naming something the client does not have.
                 Unknown, not blocked: refusing to mark a quest because OUR data
                 is incomplete would be a lie about the player's progress. ]]
            add(nil, ('prerequisite "%s" could not be resolved'):format(p.unresolved))
        else
            --[[ status_of, NOT is_completed. Purely linear lines (TVR, CoP,
                 SoA, RoV...) never send a completed bitfield, so is_completed
                 returns nil for every prerequisite in them. status_of falls
                 back to the line's current-mission pointer, which does resolve
                 them -- TVR "Moglesse Oblige" and its prerequisite "Odin's
                 Eye". ]]
            local st = state.status_of(p.cat, p.area, p.id)
            local label = quest_name(p.cat, p.area, p.id)
            if st == nil then
                -- Genuinely no packet data for that area (still zoning, or a
                -- sub-type that never arrived).
                add(nil, ('prerequisite "%s": no data yet'):format(label))
            elseif st == 'done' then
                add(true, ('prerequisite "%s" complete'):format(label))
            else
                add(false, ('prerequisite "%s" not complete'):format(label))
            end
        end
    end

    -- --- fame ------------------------------------------------------------
    if entry.fame and entry.fame_lvl and entry.fame_lvl > 0 then
        local ok = fame.meets(entry.fame, entry.fame_lvl)
        local have, src = fame.get(entry.fame)
        if ok == nil then
            add(nil, ('%s fame %d required, current level unknown')
                :format(entry.fame, entry.fame_lvl))
        elseif ok then
            add(true, ('%s fame %d required, have %d (%s)')
                :format(entry.fame, entry.fame_lvl, have, src or '?'))
        else
            add(false, ('%s fame %d required, have %d (%s)')
                :format(entry.fame, entry.fame_lvl, have, src or '?'))
        end
    end

    --[[ --- job -----------------------------------------------------------

         Measured on the wiki cache: of the 183 quests that state a level
         restriction, 88 name a JOB, and they cluster hard -- Guslam in Upper
         Jeuno hands out the whole `Borghertz's ... Hands` set, one per job.
         Without this gate every character sees a badge of ~15 on him, 14 of
         which they can never start on their current job.

         Unlike fame this is EXACTLY observable, so it is a definite false: a
         grey "!" that says why, never a wrong yellow. ]]
    --[[ `jobs` is a LIST. `Old Wounds` gates on seven -- WAR, RDM, PLD, DRK,
         BLU, COR, RUN -- and reading a scalar would keep one and silently drop
         six, which is a definite FALSE on six jobs that can really do it. The
         scalar `job` is still honoured: v1-shaped rows and missions never carry
         more than one, and the whole point of the tri-state is that a shape we
         do not recognise must read unknown rather than blocked. ]]
    local jobs = entry.jobs
    if jobs == nil and entry.job then jobs = {entry.job} end
    if jobs and #jobs > 0 then
        local label = table.concat(jobs, '/')
        if player_job == nil then
            add(nil, ('%s only, current job unknown'):format(label))
        else
            local ok = false
            for _, j in ipairs(jobs) do
                if player_job == j then ok = true end
            end
            if ok then
                add(true, ('%s only, and you are %s'):format(label, player_job))
            else
                add(false, ('%s only, you are %s'):format(label, player_job))
            end
        end
    end

    -- --- level ------------------------------------------------------------
    if entry.lvl and entry.lvl > 0 then
        if player_lvl == nil then
            add(nil, ('level %d required, current level unknown'):format(entry.lvl))
        elseif player_lvl >= entry.lvl then
            add(true, ('level %d required, you are %d'):format(entry.lvl, player_lvl))
        else
            add(false, ('level %d required, you are %d'):format(entry.lvl, player_lvl))
        end
    end

    --[[ --- craft and combat skill ------------------------------------------

         "Indomitable Spirit" (the Ebisu rod) stays out of your log until you
         buy `Serpent Rumors` from Fennella in Port Windurst: 95,000 Guild
         Points at Fishing rank Adept or higher. Packet 0x062 gives Rank, Level
         and Capped for the ten Synthesis skills and Level for the 48 combat
         ones on an exact layout (core/skills.lua), so a rank shortfall is a
         definite false like the job gate, and a grey "!" that says why beats
         a yellow one that walks the player to Windurst for nothing.

         The craft list is an AND; `jobs` above is an OR, and validate.py in
         tools/pipeline says the same, so copying the wrong precedent inverts
         a gate. 0x062 only arrives at login and on a skill change, so after a
         mid-session load craft rank is UNKNOWN, not zero. Reading it as zero
         greys a quest because we have not looked yet, the same failure
         `inventory.ready()` prevents one block below. ]]
    for _, c in ipairs(entry.craft or {}) do
        local what = c.nm or ('skill ' .. tostring(c.sk))
        if c.rank ~= nil then
            local ok = skills.meets_rank(c.sk, c.rank)
            local have = skills.rank(c.sk)
            local need = c.rk and ('%s (rank %d)'):format(c.rk, c.rank)
                              or ('rank %d'):format(c.rank)
            if ok == nil then
                add(nil, ('%s %s or higher required, your rank is not known yet')
                    :format(what, need))
            elseif ok then
                add(true, ('%s %s or higher required, yours is %d')
                    :format(what, need, have))
            else
                add(false, ('%s %s or higher required, yours is %d')
                    :format(what, need, have))
            end
        end
        --[[ A skill level may never return false. Rank above may; this may not,
             and the asymmetry is a fact about the game rather than a hedge.

             Packet 0x062 reports your NATURAL skill -- the number the in-game
             menu shows. Equipment adds on top of it invisibly: Trainee's
             Spectacles give +1 Fishing and the menu still reads 1 when your
             effective skill is 2. And the quests CHECK THE EFFECTIVE NUMBER --
             `Inside the Belly` says so in its own requirements line, offering
             gear and Advanced Synthesis Image Support as ways to "help hit
             level 30".

             So base-below-threshold is not evidence that you cannot start the
             quest; it is evidence that we cannot tell. That is precisely what
             `nil` means here, and greying on it would be a confident wrong
             answer of the worst kind -- a marker that vanishes for a player who
             is correctly geared and has no way to find out why.

             This is still worth having. Above the threshold is a definite TRUE,
             and below it the marker goes from a confident yellow "!" to an
             honest black one that `//qm why` can explain. The false yellow is
             removed without a false grey being invented to replace it.

             A RANK cannot be borrowed -- no equipment in the game moves the
             stored result of a rank-up test -- which is exactly why the rank
             branch above is allowed the `false` this one is not. ]]
        if c.lvl ~= nil then
            local ok = skills.meets_level(c.sk, c.lvl)
            local have = skills.level(c.sk)
            if ok == nil then
                add(nil, ('%s skill %d required, your skill is not known yet')
                    :format(what, c.lvl))
            elseif ok then
                add(true, ('%s skill %d required, you have %d')
                    :format(what, c.lvl, have))
            else
                add(nil, ('%s skill %d required and your natural skill is %d -- '
                    .. 'but equipment adds to this and is not visible here, so '
                    .. 'this is not a definite answer'):format(what, c.lvl, have))
            end
        end
        --[[ Guild points, from packet 0x113. The other half of the same
             sentence: `Indomitable Spirit` asks for 95,000 Guild Points AND
             Fishing rank Adept, and a player at Adept with 40,000 points can no
             more buy the key item than one at rank 3. Both are exactly
             observable, so both are definite-false predicates and neither is
             allowed to stand in for the other. ]]
        if c.pts ~= nil then
            local ok = skills.meets_points(c.sk, c.pts)
            local have = skills.points(c.sk)
            if ok == nil then
                add(nil, ('%s guild points %d required, your balance is not '
                    .. 'known yet'):format(what, c.pts))
            elseif ok then
                add(true, ('%s guild points %d required, you have %d')
                    :format(what, c.pts, have))
            else
                add(false, ('%s guild points %d required, you have %d')
                    :format(what, c.pts, have))
            end
        end
    end

    --[[ --- entry conditions: what you must already BE ----------------------

         Requirements do not normally gate availability, and that rule is
         right: you accept a quest and then go and collect its items. Greying
         every quest whose turn-in items you are not carrying would hide most
         of the index behind errands you have not run yet.

         `eq` on STEP 1 is the exception, and it is a different kind of thing.
         All twenty `Unlocking a Myth` pages read "Talk to Zalsuhm ... with a
         Vigil Weapon equipped for a cutscene" -- the weapon is a state you must
         be IN when you speak to him, not a fetch you do afterwards. Talk to him
         without it and nothing happens, so a yellow "!" there is a lie.

         STEP 1 SPECIFICALLY, not any `eq` anywhere. A later step wanting
         something equipped is a condition on THAT step, and gating the quest on
         it would be the fetch mistake again.

         Exactly observable, so it is a definite-false predicate like job and
         level -- with the one hedge that matters: before the bags have been
         swept every count reads 0, which is indistinguishable from "not
         wearing it". That reads `nil`, never `false`, or a quest would grey out
         on nothing more than the addon not having looked yet. ]]
    local s1 = entry.steps and entry.steps[1]
    local worn_gate = false
    for _, r in ipairs((s1 and s1.reqs) or {}) do
        if r.eq then
            worn_gate = true
            --[[ Quoted rather than given an article. "a Elder Staff" and
                 "a Inferno Claws" both read as typos, and no article is right
                 for every weapon name in the set -- several are plural. ]]
            local what = r.nm and ('"' .. r.nm .. '"')
                or ('item ' .. tostring(r.rid))
            if not inventory.ready() then
                add(nil, ('needs %s equipped; equipment not read yet'):format(what))
            elseif inventory.has_equipped(r.rid, r.n) then
                add(true, ('needs %s equipped, and you are wearing one'):format(what))
            elseif inventory.has_item(r.rid, r.n) then
                add(false, ('needs %s EQUIPPED -- you have one, but it is not '
                    .. 'equipped'):format(what))
            else
                add(false, ('needs %s equipped, and you do not have one')
                    :format(what))
            end
        end
    end

    --[[ The second entry condition: the act of starting IS the hand-over.

         When step 1 is a `trade` or an `examine` carrying requirements, the
         item is not something you fetch after accepting -- presenting it is how
         the quest begins. `A Minstrel in Despair` is one step: trade the item,
         that is the quest. `A Beaked Blusterer` opens by examining a cavernous
         maw with a traverser stone, and without one you cannot go through it.
         So "yellow, go and take this quest" is wrong in exactly the way the
         Vigil Weapons were.

         `talk` is deliberately EXCLUDED. Measured on the shipped index, and
         stated with the definition because the answer depends on it: 31 entries
         have an ITEM requirement on a talk step 1. Twenty of those are `eq`
         items and are gated anyway by the equipped gate, which does not care
         what kind the step is. So this exclusion actually decides **10** entries
         (11 if `reqs_alt` is counted) -- the ones carrying a plain, non-equipped
         item on a talk step. There the reading is genuinely ambiguous -- "speak to him
         while holding X" and "here is what this quest will eventually want" look
         identical once the prose is dropped -- and greying on the second
         reading would be the fetch mistake this whole block exists to avoid.
         Only `eq` gates a talk step, because there the page said so outright.

         Two hedges, both mattering for the same reason as everywhere else:
         `reqs_partial` means the recorded list is known to be incomplete, so a
         miss proves nothing and reads `nil`; and before the first bag sweep
         every count is 0, which is not evidence of anything. ]]
    if s1 and not worn_gate and ENTRY_KIND[s1.k] then
        --[[ Ask first, then look -- and the order is the whole hedge.

             `inventory.meets` reaches count(), which re-sweeps whenever the
             cache is dirty, and a sweep sets ready(). So asking ready() after
             meets() has returned can never see false: getting the answer
             destroys the evidence that we had not had one. Snapshot ready()
             before the call, so this gate and the equipped gate one block up
             give the same answer to the same unread bags.

             The cost is the first entry evaluated on a cold cache: `//qm todo`
             right after a login reads black on that one until the next scan
             tick. That is the correct trade -- black says "not looked yet",
             which was true when we were asked, where grey claims a fact we did
             not have.

             meets() is still CALLED rather than skipped, so the sweep it
             triggers warms the cache for every entry after this one. ]]
        local read = inventory.ready()
        local met, recorded = inventory.meets(s1.reqs, s1.reqs_alt)
        if recorded then
            local how = (s1.k == 'trade') and 'handing it over' or 'presenting it'
            if s1.reqs_partial then
                add(nil, ('starts by %s, and the recorded item list is known to '
                    .. 'be incomplete'):format(how))
            elseif not read then
                add(nil, ('starts by %s; your bags have not been read yet')
                    :format(how))
            elseif met then
                add(true, ('starts by %s, and you have what it asks for')
                    :format(how))
            else
                local _, missing = inventory.satisfies(s1.reqs or {})
                add(false, ('cannot be STARTED without the item -- it begins by '
                    .. '%s, and you are missing %d of %d'):format(
                        how, missing, #(s1.reqs or {})))
            end
        end
    end

    local status = 'ready'
    if any_false then status = 'blocked'
    elseif any_unknown then status = 'unverifiable' end
    return status, reasons
end

--[[ Turn-in signal for a quest already in progress.
     -> ready(boolean), note

     HEURISTIC, and labelled as one: 0x056 carries no per-quest step data --
     there is no packet that says "you are on step 3 of 7". We approximate
     "can hand in" as "holds everything in the resolved requirement list", and
     assume the turn-in NPC is the start NPC (true for most FFXI quests).
     Multi-stage quests will therefore show yellow "?" early. No packet-level
     fix exists. ]]
function prereq.can_turn_in(entry, step)
    --[[ With step data the question narrows from "do you hold everything this
         whole quest ever asks for" to "do you hold what THIS step needs". 74%
         of entries carry no whole-quest requirement list, so without a step
         they can never reach the yellow "?". Entries with no step data fall
         back to `entry.reqs`. ]]
    local reqs = step and step.reqs or entry.reqs
    --[[ `reqs_alt` is a SECOND, independent way to satisfy the same hand-over --
         four Gobbiebag items OR one Goblin Stew -- not an extra condition. 18%
         of entries take any one of a list; treat those as an AND and every one
         of them stays grey for ever. ]]
    local alts = step and step.reqs_alt or entry.reqs_alt
    --[[ `reqs_partial` on a STEP means something different from the
         whole-quest flag: not "we failed to read it" but "there is a second way
         to satisfy this that an AND-list cannot express" -- the Goblin Stew
         that replaces all four Gobbiebag items, the key item that replaces
         Elder Memories' three trades. Do not report a step one as "could not
         be parsed". ]]
    local partial = (step and step.reqs_partial) or (not step and entry.reqs_partial)

    local met, recorded = inventory.meets(reqs, alts)
    if not recorded then
        -- No usable signal at all -- stay grey rather than promising a turn-in.
        return false, partial
            and 'this step has an alternative the item list cannot express'
            or 'no item requirements recorded'
    end
    if met then
        if reqs and #reqs > 0 and inventory.satisfies(reqs) then
            return true, partial
                and 'holds every listed item (an alternative route also exists)'
                or 'holds all requirements'
        end
        return true, ('holds one of the %d accepted alternatives'):format(#alts)
    end
    if not reqs or #reqs == 0 then
        return false, ('holds none of the %d accepted alternatives'):format(#alts)
    end
    local _, missing = inventory.satisfies(reqs)
    --[[ The one failure a bare count cannot explain: you are carrying exactly
         what the step lists and it still reads as missing, because the quest
         wants the item EQUIPPED. All twenty `Unlocking a Myth` pages say only
         "a Vigil Weapon equipped", so without this line they report
         "missing 1 of 1 requirements" with the sword sitting in your bag --
         which reads as a data bug rather than as an instruction. ]]
    local carried_not_worn = false
    for _, r in ipairs(reqs) do
        if r.eq and inventory.has_item(r.rid, r.n)
           and not inventory.has_equipped(r.rid, r.n) then
            carried_not_worn = true
        end
    end
    local tail = carried_not_worn
        and ' -- carried, but this step needs it EQUIPPED' or ''
    if alts and #alts > 0 then
        return false, ('missing %d of %d requirements, and none of the %d alternatives%s')
            :format(missing, #reqs, #alts, tail)
    end
    return false, ('missing %d of %d requirements%s'):format(missing, #reqs, tail)
end

--[[ Which by_npc row is the quest giver's. -> step index, or nil.

     Three branches of suppressed_reason answer "mark the giver", and that is
     useless unless it names a row the index has. tools/build_index.lua emits
     an s=0 giver row only when the giver is not already a step target, so no
     NPC collects two rows for one quest (see its `add_ref` loop). For 1036 of
     the 1099 shipped quest records the giver IS a step target, so there is no
     s=0 row to ask for. Bad data may move a marker, never delete one. So: the
     giver's own step when he has one, step 0 when he does not. Both rows exist
     and name the same NPC in the same spot, so nothing new gets marked.
     `ipairs` and first match, never `pairs`, or which rung wins depends on
     table order.

     nil, not 0, when there is no giver: `entry.snpc` is the empty STRING for
     8 records and '' is truthy in Lua, so the `or '?'` fallback below does not
     catch it. nil routes to "nothing can carry a marker" instead. Those quests
     stay dark on purpose: their other rows are mid-quest NPCs, and pointing a
     player at one to start a quest he cannot start there is worse than
     nothing. ]]
local function giver_row(entry)
    local snpc = entry.snpc
    if snpc == nil or snpc == '' then return nil end
    for i, s in ipairs(entry.steps) do
        if s.npc == snpc then return i end
    end
    return 0
end

--[[ Full marker state for one quest entry.
     -> state, reasons

     States, highest display priority first -- this list is PRIORITY at the foot
     of the file, in its order, and the two must not drift:
       'turnin'   yellow ?   in progress, requirements held               (6)
       'ready'    yellow !   available, prerequisites met                 (5)
       'unknown'  black  !   available, something unverifiable (usually fame) (4)
       'progress' grey   ?   in progress                                  (3)
       'blocked'  grey   !   available, a prerequisite is definitely unmet (2)
       'repeat'   blue   !   completed but repeatable                     (1)
       nil                   nothing to show

     'unknown' is drawn NEAR-BLACK, not blue: render/markers.lua sets it to
     {25,25,32}, because set_color multiplies the texture and a true {0,0,0}
     would erase the glyph. Blue belongs to 'repeat' alone. ]]
--[[ Why an entry shows no marker at all, for //qm why. Returns nil when the
     entry is not suppressed (it may still have no marker for other reasons,
     e.g. completed and not repeatable). ]]
function prereq.suppressed_reason(entry, at_step)
    if entry.cat == 'mission' and state.NATION_AREAS[entry.area] then
        local mine = state.nation()
        if mine and mine ~= entry.area then
            return ('%s mission line -- you are aligned with %s, so this line '
                .. 'is not available to you'):format(entry.area, mine)
        end
    end

    --[[ This NPC is not where you are.

         An entry now reaches the marker layer once per step whose target is
         this NPC, and only the CURRENT step may draw. Putting that here rather
         than in a new predicate is deliberate: marker_state already consults
         this first and returns nil on a hit, and `//qm why` already prints the
         result as `- hidden: ...`. So the single most useful diagnostic in the
         feature -- the line that turns "my marker disappeared" into a
         one-liner -- costs no new printing code.

         `at_step` nil means "any step", which is what notify and zone_starts
         pass. That is correct, not a shortcut: they ask whether something
         became actionable ANYWHERE, not where to stand. ]]
    if at_step and entry.steps and #entry.steps > 0 then
        local n = #entry.steps
        --[[ `at_giver` = the answer is "stand where the quest giver stands",
             whatever row number that turns out to be. Kept separate from
             `want` because `want == 0` is not the only way to say it:
             giver_row() answers with a real step index whenever the giver has
             one. It picks the wording below, and it switches OFF the unordered
             -group expansion. ]]
        local want, why, at_giver

        --[[ A quest you have not ACCEPTED has no position -- there is only the
             giver. Do not ask steps.current() here: it makes the answer depend
             on what you happen to be carrying, so a key item held for any other
             reason can advance an unstarted quest and hide its start NPC. Bad
             step data may add a marker, never silently remove one. ]]
        --[[ Step 0 is not a step: it is the quest GIVER, carried alongside the
             ladder so a quest whose every target is a '???' or a mob still has
             somewhere to put a marker. It is only ever the answer when no step
             at or before the current one can be marked. ]]
        if state.status_of(entry.cat, entry.area, entry.id) == 'in_progress' then
            local idx, _, _, info = steps.current(entry)
            --[[ Written out rather than `idx and info.marker_idx or 1`: that
                 idiom silently turns a legitimate nil marker_idx ("nothing can
                 be marked") into 1, which then marks a step that cannot be
                 marked. Caught by the no-giver test below. ]]
            if idx then
                want = info.marker_idx
                --[[ marker_idx 0 is steps.current saying "nothing at or before
                     your position can be marked, fall back to the giver". Route
                     it through giver_row for the same reason as every other
                     giver answer: step 0 is only a row when the giver is not
                     also a step. ]]
                if want == 0 then want = giver_row(entry) end
                at_giver = (info.marker_idx == 0)
            else
                --[[ steps.current answers nil here for exactly one reason:
                     `//qm steps off`. The other two nil paths -- no ladder, or
                     an empty one -- are already excluded by the `#entry.steps >
                     0` guard above.

                     Ask for the giver by name, not for step 1's target. README
                     calls this switch an escape hatch that pins every marker
                     back on its quest giver, and step 1's target is the giver
                     for 984 of 1099 quests and something else for the rest. ]]
                want = giver_row(entry)
                at_giver = true

                --[[ ...but never at the cost of a marker. `quest/crystal_war/89`
                     has no recorded giver and its first three steps are `planar
                     rift`, a named standing entity, so asking for a giver that
                     does not exist would suppress every row it has. Bad data may
                     move a marker, never delete one, and the message below would
                     be a lie for it: three steps CAN carry a marker.

                     So when there is no giver, fall back to step 1.
                     `has_entity`, not `markable`, so the fallback can never land
                     on a monster: the three records that stay dark here
                     (crystal_war/82, crystal_war/87, toau/41) are mob-only at
                     step 1 and have no giver either, which leaves genuinely
                     nothing honest to mark. ]]
                if want == nil and steps.has_entity(entry.steps[1]) then
                    want, at_giver = 1, false
                end
            end
            why = 'you are on step %d'
        else
            --[[ has_entity, NOT markable: a quest is offered by somebody, never
                 by a monster. A first step of "defeat X" is markable once you
                 are ON it, but before you accept the quest the only honest
                 place for its "!" is the giver. ]]
            if steps.has_entity(entry.steps[1]) then
                want = 1
            else
                want = giver_row(entry)
                at_giver = true
            end
            why = 'you have not started it, so only step %d can be marked'
        end

        --[[ Nothing markable AND no giver recorded. Honest, and it is the
             answer for 8 records whose `snpc` is the empty string. ]]
        if want == nil then
            return 'no step of this quest can carry a marker, and no quest '
                .. 'giver was recorded for it'
        end

        --[[ Some steps are an UNORDERED SET. "Lure of the Wildcat" sends you to
             twenty NPCs and the wiki is explicit that order does not matter, so
             walking them one at a time would mark Albiona and nothing else
             until you happened to visit her. Steps sharing a group are all
             current together, and all of them draw.

             Nothing distinguishes one member from another observably -- there
             is no per-NPC evidence -- so marking the whole set is both the only
             honest answer and the useful one.

             NOT when the answer is the giver. A group is a set of steps that
             are CURRENT together; the giver's rung is not a position you are
             standing on, it is the fallback for having nowhere else to point.
             Two shipped giver rungs carry a `grp` (quest/sandoria/93 step 2,
             quest/crystal_war/92 step 1), and expanding those would put a "!"
             on every other member -- NPCs you cannot start the quest from. ]]
        --[[ Written out rather than `cond and entry.steps[want] or nil`: that
             idiom picks the wrong branch on a nil middle value. ]]
        local wstep = nil
        if not at_giver and want > 0 then wstep = entry.steps[want] end
        if wstep and wstep.grp then
            local astep = (at_step > 0) and entry.steps[at_step] or nil
            if astep and astep.grp == wstep.grp then return nil end
        end

        if at_step ~= want then
            local tgt = (want > 0) and entry.steps[want] or nil
            --[[ Name the MONSTER when the current step is a fight, rather than
                 falling through to the giver's name and telling the player to
                 stand somewhere the marker is not. Written out because
                 `tgt.npc or ...` would silently skip a mob step. ]]
            local label
            if tgt then
                label = tgt.npc
                if (label == nil or label == '') and tgt.mobs and tgt.mobs[1] then
                    label = tgt.mobs[1].name
                end
            end
            --[[ `or '?'` cannot catch the empty string -- '' is truthy in Lua
                 -- so test for it. Unreachable from the giver branch
                 (giver_row answers nil rather than 0 when there is no name),
                 and kept anyway because this line also serves the ordinary
                 step branches. ]]
            if label == nil or label == '' then label = entry.snpc end
            if label == nil or label == '' then label = '?' end
            local grid = (tgt and tgt.g) and (' ' .. tgt.g) or ''
            --[[ Keyed on at_giver, not on `want == 0`: the giver's row is his
                 own step index whenever he has one, so `want` is usually a real
                 step number even when the marker is squarely on the giver.
                 Naming the row number instead would tell the player to go and
                 do a step of a quest he has not started. ]]
            if at_giver then
                return ('this NPC is step %d of %d; nothing at your current step '
                     .. 'can be marked, so the marker is on the quest giver (%s)')
                    :format(at_step, n, entry.snpc)
            end
            return ('this NPC is step %d of %d; ' .. why .. ' (%s%s)')
                :format(at_step, n, want, label, grid)
        end
    end
    return nil
end

--[[ `at_step` is the step index of the by_npc row being evaluated, or nil for a
     quest-level question (notify, zone_starts, //qm todo). Entries with no step
     data ignore it entirely, so a v1 index behaves exactly as it always has. ]]
function prereq.marker_state(entry, at_step)
    --[[ Nation missions are mutually exclusive with your allegiance: a Windurst
         character can never start San d'Oria mission 1, so marking it on a San
         d'Oria gate guard is simply wrong.

         Only suppressed once the Nation field has actually arrived; before then
         nation() is nil and we show everything rather than hide content on a
         guess. ]]
    if prereq.suppressed_reason(entry, at_step) then return nil end

    local st, src = state.status_of(entry.cat, entry.area, entry.id)
    if st == nil then return nil end

    --[[ SANITY CHECK.

         A linear mission line reports "which mission am I on" as an integer
         that does not map 1:1 to DAT ids, so resolve_linear() has to guess.
         That guess can land far ahead of where the player actually is:
         Windurst mission 23 "Moon Reading" reads in_progress while its
         prerequisite "Doll of the Dead" is provably incomplete.

         Prerequisite completion comes from an EXACT bitfield. So when a merely
         inferred in_progress contradicts exact data, the exact data wins and
         the mission is reported as blocked instead. Only applied to 'linear'
         claims: when `current` came from a real bitfield the player genuinely
         did accept it, and a prerequisite conflict then means OUR metadata is
         wrong, not the game's. ]]
    if st == 'in_progress' and src == 'linear' then
        local pstatus, reasons = prereq.evaluate(entry)
        if pstatus == 'blocked' then
            table.insert(reasons, 1, {ok = false,
                text = 'reported in progress by the mission pointer, but a '
                    .. 'prerequisite is provably incomplete -- trusting the '
                    .. 'prerequisite'})
            return 'blocked', reasons
        end
    end

    --[[ Completed. `entry.repeatable` is a tri-state and the nil branch below
         is a decision, so please don't "fix" it back.

         true / false / nil, where nil means the page never said whether the
         quest repeats. `if entry.repeatable then` is false for nil, so an
         unknown falls through to `return nil` and the quest draws nothing.
         An unknown here is not "does not repeat", it is "we can't say this is
         available again", and the honest answer to that is to say nothing.

         Routing nil into the branch instead would draw a blue "!" on the giver
         of every unknown row, on no evidence, and a blue "!" means go and do
         this again. Nothing is lost by staying quiet: the quest is complete, so
         there was no marker there to remove.

         Counts move with every authoring batch; read the build's `repeatable`
         line rather than trusting a number here. ]]
    if st == 'done' then
        if entry.repeatable then
            -- Repeatable and complete: available again, so run the normal
            -- availability rules rather than hiding it.
            local pstatus, reasons = prereq.evaluate(entry)
            if pstatus == 'ready' then return 'repeat', reasons end
            if pstatus == 'blocked' then return 'blocked', reasons end
            return 'unknown', reasons
        end
        return nil
    end

    if st == 'in_progress' then
        --[[ With steps, "ready to hand in" needs TWO things, not one: the
             current step's own requirements are held AND that step is a
             hand-over. A mid-quest fetch with the items already in your bag is
             still grey -- you are holding them to use, not to give back.

             A marker held back onto an earlier step (because the current one is
             a '???' or an NM) is never `turnin` either: by definition you are
             not standing at the hand-over. ]]
        local idx, n, step, info = steps.current(entry)

        --[[ Look ahead across steps the MARKER CANNOT DISTINGUISH.

             Found in game on "The Gobbiebag Part I": step 1 is talk-to-Bluffnix
             and step 2 is trade-to-Bluffnix, same NPC, same spot. Talking leaves
             no trace we can observe, so the mark never leaves step 1 and the
             yellow "?" could never fire however many items you were carrying.

             But a marker on Bluffnix IS both steps -- standing there you can do
             either. So readiness is judged on the LAST consecutive step sharing
             this target, not just the current one. That is not a guess about
             progress: it is an admission that these steps are one marker.

             The walk stops the moment the target or zone changes, so it can
             never reach across a journey. ]]
        local at = idx
        if idx and step then
            local j = idx
            while j < n do
                local a, b = entry.steps[j], entry.steps[j + 1]
                if not (a and b and a.npc and b.npc == a.npc and b.z == a.z
                        and not b.optional and not b.grp) then break end
                j = j + 1
            end
            at = j
        end
        local look = at and entry.steps[at] or step

        local ok, note = prereq.can_turn_in(entry, look)
        if idx then
            if not steps.is_handover(entry, at) or info.held then ok = false end
            note = (at ~= idx)
                and ('step %d-%d/%d (same NPC): %s'):format(idx, at, n, note)
                or  ('step %d/%d: %s'):format(idx, n, note)
        end
        return (ok and 'turnin' or 'progress'), {{ok = ok or nil, text = note}}
    end

    -- available
    local pstatus, reasons = prereq.evaluate(entry)

    --[[ Linear storylines: CoP, SoA, RoV, ACP, MKD, ASA and TVR send only a
         "current mission" integer, so everything past the pointer is simply
         not reachable yet -- you cannot skip ahead in a linear line.

         Without this, a mission twenty steps down the chain whose `previous`
         metadata is missing or unresolved would show a confident green "!".
         The prerequisite chain catches most of them, but it is only as good as
         the pages it was read from; the pointer is authoritative about
         ordering. ]]
    if src == 'linear' and pstatus ~= 'blocked' then
        local at = state.linear_at(entry.cat, entry.area)
        if at and entry.id > at then
            table.insert(reasons, 1, {ok = false,
                text = 'later in a linear storyline (currently at #' .. at .. ')'})
            return 'blocked', reasons
        end
    end

    if pstatus == 'ready' then return 'ready', reasons end
    if pstatus == 'blocked' then return 'blocked', reasons end
    return 'unknown', reasons
end

-- Display priority: the winning glyph when one NPC carries several quests.
local PRIORITY = {
    turnin = 6, ready = 5, unknown = 4, progress = 3, blocked = 2, ['repeat'] = 1,
}

function prereq.priority(s) return PRIORITY[s] or 0 end

prereq.STATES = PRIORITY

return prereq
