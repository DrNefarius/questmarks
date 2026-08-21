--[[
build_index.lua -- generates questmarks' runtime quest index.

Reads data/dat_names.lua (client DAT names), Windower's `res/` tables and the
step ladders in data/quest_steps.lua, and emits:
    questmarks/data/quest_index.lua     the runtime index
    questmarks/data/mission_index.lua   missions, on the same terms
    questmarks/tools/unmatched.txt      every start_npc that produced no key

Must not read any other addon's directory; tools/test_standalone.lua enforces
that. Runs offline (luajit tools/build_index.lua [--all-areas]) or in game
(//qm rebuild), picked by whether the `windower` global exists. Identity --
which rows exist -- comes from the DAT names; everything else is first-hand
from the BG Wiki page cache. Never copy a count out of a comment; every run
prints the live figures. Wiki data is CC BY-NC-SA 3.0, DAT names are Square
Enix game content, this file itself is MIT. See NOTICE and LICENSE-DATA.
]]

local M = {}

--[[ Everything about what a NAME means lives in tools/lib/normalize.lua, shared
     with the BG Wiki pipeline so the two can never disagree. This file keeps
     only the index assembly and the emitter. ]]
local N = require('tools/lib/normalize')

--[[ `standalone` = "no game client", which decides how res tables are loaded.
     It is NOT the same as "run from the command line" -- an offline test can
     require() this module with no windower global present.

     Keep those separate: requiring this module must never build the index. The
     vararg of a main chunk is the command line; of a required module it is the
     module name -- so a nil or option-shaped first argument means we really
     were invoked as a script. ]]
local ARG1 = ...
local run_as_script = (ARG1 == nil)
    or (type(ARG1) == 'string' and ARG1:sub(1, 1) == '-')

local standalone = N.standalone()

-- v1 scope: nations + Jeuno. --all-areas lifts this for DISPLAY only;
-- prerequisite RESOLUTION always spans every area so cross-area chains work.
local V1_QUEST_AREAS   = {'sandoria', 'bastok', 'windurst', 'jeuno'}
local V1_MISSION_AREAS = {'sandoria', 'bastok', 'windurst', 'zilart'}

-------------------------------------------------------------------------------
-- everything below is borrowed from tools/lib/normalize.lua, which owns the
-- rules. Bound to locals so the assembly code below reads unchanged.
-------------------------------------------------------------------------------

local trim, fold, set        = N.trim, N.fold, N.set
local sorted_keys, count     = N.sorted_keys, N.count
local file_exists, load_table = N.file_exists, N.load_table
local lua_str, lua_val       = N.lua_str, N.lua_val
local normalize_npc          = N.normalize_npc
local make_zone_resolver     = N.make_zone_resolver
--[[ `FAME_REGIONS` is deliberately NOT bound here. Fame reaches this file
     already resolved by stage C and nothing here parses a fame string; an
     unused binding to a shared module is how a reader concludes a dependency
     still exists. It lives in tools/lib/normalize.lua, where resolve.lua uses
     it through `fame_region`. ]]
local AMBIGUOUS_NPCS         = N.AMBIGUOUS_NPCS
local normalize_path         = N.normalize_path
local find_windower_root     = N.find_windower_root

--[[ Who gives this quest -- one answer, read in two places.

     The record's `snpc` field and the by_npc `s=0` giver row must agree about
     the name, so both go through this one expression. A name in the record
     with no row behind it is a giver //qm why can name and no marker can draw.

     `no_giver` beats the npc_key fallback. Those entries are anchored on a
     mid-quest step purely so the quest exists at all, and calling that NPC the
     giver would put a "start here" marker on somebody you cannot start
     anything with.

     Returns the EMPTY STRING, never nil, because that is what the record ships
     for a quest with no known giver; core/prereq.lua tests for it explicitly
     (`''` is truthy in Lua, so `or` cannot catch it). ]]
local function giver_of(e)
    local L = e.ladder
    return (L and L.snpc) or (not e.no_giver and e.npc_key) or ''
end

--[[ Which entities draw this quest's start marker -- a set, unlike
     `giver_of`, which is the one name the record prints.

     A giver written as a role expands: nation missions write
     `Start = "Any Bastok Gate Guard"` and data/npc_overrides.lua turns that
     into Argus, Cleades, Rashid and Malduc, all of whom really do start it.

     Do not widen this to every by_npc key. That is the scan set, wider on
     purpose (the union block adds the ladder's giver to the record's and
     back). Widening puts a start marker on a cutscene or a mid-quest contact:
     quest/windurst/81-83 starts at `House of the Hero`, not on `carbuncle`.
     66 records carry `start_disagrees_with_header` to say the header giver is
     not the walkthrough's.

     So: the override's expansion or nothing, and only when the printed giver
     is one of its NPCs. Returns {} for a `no_giver` entry. ]]
local function giver_keys(e)
    local g = giver_of(e)
    if g == '' then return {} end
    for _, k in ipairs(e.gkeys or {}) do
        if k == g then return e.gkeys end
    end
    return {g}
end

--[[ Does this quest repeat -- true, false, or NOBODY WROTE IT DOWN.

     A scraped field is typically a free string ("Yes", "No", nil), and reading
     it as `tostring(x or ''):lower() == 'yes'` answers a DIFFERENT question:
     it says false both for a page that stated the quest is one-shot and for a
     page that stated nothing at all. Unknown is not false. A completed
     non-repeatable draws no marker, so recording an unknown as false is a
     marker that can never appear and a `//qm why` that asserts a fact nobody
     has.

     nil is returned, never false, when the field is absent. That is the third
     state the whole addon is built on and it must not collapse here. ]]
local function chron_repeatable(rec)
    if rec.repeatable == nil then return nil end
    return tostring(rec.repeatable):lower() == 'yes'
end

--[[ One source: the page cache's own reading. The second argument is a merge
     slot nothing feeds any more, so this reduces to "the reading wins".

     No floor. Do not add one to stop a `false` reading overwriting a scraped
     `true`: the two markers such a floor keeps are both wrong.

       quest/jeuno/52 (Borghertz's Wild Hands) -- BG Wiki tags 5 of the 15
         identical Borghertz quests |Repeatable=Yes and 10 |Repeatable=af,
         which renders "Yes, after Memory reset". That is an artifact-armour
         reset at Vingijard (Lower Jeuno H-9), not a repeatable quest.
       quest/other/19 (An Explorer's Footsteps) -- its wikitext says
         `|Repeatable=no`. The "repeating" is a loop inside one completion
         (clay -> monument -> Abelard, seventeen times).

     If a third case turns up, measure it before re-adding a floor. nil in,
     nil out: unknown is not false, and a page that said nothing must not ship
     as a definite "no". Counts are on the build's `repeatable` line. ]]
local function merge_repeatable(wiki, chron)
    if wiki == nil then return chron end
    return wiki
end

--[[ The duplicate-identity merge, widened to three states.

     nil must not collapse to false: a pair whose sources both say nothing
     stays unknown. Definite beats unknown and true beats false, so the merge
     cannot lose a marker and cannot depend on which row `pairs()` reached
     first. ]]
local function or_repeatable(a, b)
    if a == true or b == true then return true end
    if a == false or b == false then return false end
    return nil
end

--[[ Fame has one source: stage C resolves it and it reaches this file through
     the ladder. Nothing merges or overrides it.

     If a merge is ever proposed again: fame must be merged by region, never
     field by field. Field by field can state what neither source said --
     "Bastok / 3" against a reading of "Windurst" emits "Windurst / 3", a
     threshold invented from two halves about different cities.

     One known loss: quest/sandoria/75 has no ladder, so it ships with no fame
     gate. A dropped gate shows the quest early, which beats a marker that
     never appears. The page is in the cache as "The Rivalry" / "The
     Competition"; pinning that row restores the row and its fame together.

     The build reports how many rows carry a region. A fall means the emitter
     stopped writing the field, and there is no second source behind it. ]]
--[[ The metadata a DAT id gets when no second source describes it, which
     today is every id.

     FROZEN and shared, never copied per row: every field a caller reads off it
     must come back nil, and a fresh `{}` per id would be the same thing at more
     cost. It is compared by IDENTITY (`rec == EMPTY_REC`) rather than by
     emptiness, which a fresh table could not support. Nothing may write to
     it. ]]
local EMPTY_REC = {}


-------------------------------------------------------------------------------
-- build
-------------------------------------------------------------------------------

function M.build(opts)
    opts = opts or {}
    local report = opts.report or print

    local root = normalize_path(find_windower_root(opts.root)) .. '/'

    local outdir = root .. 'addons/questmarks/'

    --[[ Nothing here reads addons/. The build needs res/ (Windower's own),
         this addon's own data/ and build/, and nothing else. Keep it that
         way: tools/test_standalone.lua fails on an `addons/` or `../` literal
         in a shipped file. ]]

    report('Loading res tables ...')
    local zones, items, key_items
    if standalone then
        zones     = load_table(root .. 'res/zones.lua')
        items     = load_table(root .. 'res/items.lua')
        key_items = load_table(root .. 'res/key_items.lua')
    else
        local res = require('resources')
        zones, items, key_items = res.zones, res.items, res.key_items
    end
    if not (zones and items and key_items) then
        return nil, 'failed to load res tables'
    end

    local function count(t) local n = 0 for _ in pairs(t) do n = n + 1 end return n end
    report(('  zones=%d items=%d key_items=%d'):format(
        count(zones), count(items), count(key_items)))

    local resolve_zone = make_zone_resolver(zones)

    --[[ An era is not a spelling.

         Wings of the Goddess duplicates twenty-odd zones into a past era. BG
         Wiki writes "Bastok Markets (S)"; res/zones.lua writes "Bastok Markets
         [S]" (id 87) beside the present-day "Bastok Markets" (id 235).
         make_zone_resolver handles the spellings; what goes missing is the
         scraped Start= field, which records the bare name. A giver row stamped
         235 with every step row in 87 is on the far side of a time portal, so
         the marker is unreachable.

         So `sz`, the authored start zone id, is consulted, but only when it is
         the past-era twin of the resolved zone: same res name but for the era
         suffix. Of 906 records where both resolve, they disagree 185
         times and only 41 are era twins. The other 144 are sub-area against
         city (`Abyssea - La Theine` against `La Theine Plateau`) and are left
         alone. Matched on the res name, `%d*` so a future "[S2]" fits. ]]
    local function zone_name(z)
        local t = zones[z]
        if type(t) == 'table' then return type(t.en) == 'string' and t.en or nil end
        return type(t) == 'string' and t or nil
    end
    local function past_era_twin(authored, present)
        if type(authored) ~= 'number' or type(present) ~= 'number' then return false end
        if authored == present then return false end
        local na = zone_name(authored)
        local base = na and na:match('^(.-)%s*%[S%d*%]$')
        local np = zone_name(present)
        return (base ~= nil and np ~= nil and fold(base) == fold(np))
    end

    local overrides = load_table(outdir .. 'data/npc_overrides.lua') or {}

    --[[ The override table read backwards: key set -> the override that
         produces it, so a ladder's giver can reach the same override the
         scraped `start_npc` goes through.

         A raw-string lookup ("Any Bastok Gate Guard") gets four keys plus
         `zone = false`, the any-zone sentinel. The ladder never sees that
         string -- stage C resolved it already -- so
         it arrives with `snpc='argus'`, `snpcs={argus,cleades,rashid,malduc}`
         and no zone. Marking every guard in Argus's district would put markers
         in towns those guards are not in.

         Matched on the whole key set, never one member: Argus alone still
         means Argus, so quest/abyssea/14 and /17, whose giver really is one
         named guard, keep their single key and their own zone. Built over
         `sorted_keys`, first wins, so two overrides with the same set cannot
         depend on hash order. Multi-name overrides only; normalize_npc
         handles a single-name one directly. ]]
    local ov_by_keyset = {}
    for _, raw in ipairs(sorted_keys(overrides)) do
        local ov = overrides[raw]
        if type(ov) == 'table' and type(ov.names) == 'table' and #ov.names > 1 then
            local ks = {}
            for _, n in ipairs(ov.names) do ks[#ks + 1] = fold(n) end
            table.sort(ks)
            local sig = table.concat(ks, '\1')
            if ov_by_keyset[sig] == nil then ov_by_keyset[sig] = ov end
        end
    end

    --[[ Every NPC the ladder says can start this row, and the zone that set is
         valid in.

         `snpc` is one name because the record prints one name. `snpcs` is the
         list stage C carries beside it for the rows whose page states the giver
         as a ROLE -- see validate.py, which explains why the set may not be
         folded back into the string field. This is the one place the two meet.

         Returns nil when the ladder names no giver at all, so a caller can tell
         that from "named one we could not parse". ]]
    local function ladder_giver_keys(L)
        if not L then return nil end
        local base, hint = {}, nil
        if type(L.snpc) == 'string' and L.snpc ~= '' then
            base, _, hint = normalize_npc(L.snpc, resolve_zone, overrides)
        end
        local keys, seen = {}, {}
        local function add(k)
            if type(k) == 'string' and k ~= '' and not seen[k] then
                seen[k] = true
                keys[#keys + 1] = k
            end
        end
        for _, k in ipairs(base) do add(k) end
        for _, k in ipairs(L.snpcs or {}) do add(k) end
        if #keys == 0 then return nil end
        local sig = {}
        for _, k in ipairs(keys) do sig[#sig + 1] = k end
        table.sort(sig)
        local ov = ov_by_keyset[table.concat(sig, '\1')]
        if ov ~= nil then hint = ov.zone end
        --[[ Third return: the ROLE set, present only on an exact whole-set
             match. `giver_keys` uses it to decide where the s=0 giver row is
             drawn, and it must stay separate from `keys` -- `keys` is the SCAN
             set and legitimately holds more (a `(S)` name expands to two
             spellings, and the union block adds the record's giver). Widening
             the giver row across all of that is what the note at `giver_keys`
             warns against.

             A COPY, not `keys` itself. The rescue block assigns the first
             return straight into the caller's `keys`, and the union block below
             it APPENDS to that same table -- so returning one table twice would
             let the scan set grow the role set from under `giver_keys`, which
             is exactly the widening this return exists to prevent. ]]
        local role = nil
        if ov ~= nil then
            role = {}
            for i, k in ipairs(keys) do role[i] = k end
        end
        return keys, hint, role
    end

    --[[ The role comes from the ladder alone. Do not take it from the header
         string: a row whose ladder names one specific guard, with no `snpcs`,
         would then be widened onto the whole role whenever the header still
         said the role. That is the header-disagrees-with-walkthrough case
         `giver_keys` guards against. ]]

    --[[ Real step ladders, read from the BG Wiki cache by the pipeline in
         tools/pipeline/ and merged onto the DAT id list here.

         A missing ladder is handled rather than fatal: such a row would keep a
         synthetic single step at its giver, so the dataset could land quest by
         quest instead of all at once. No shipped row takes that path today. ]]
    local ladders = load_table(outdir .. 'data/quest_steps.lua') or {}
    local n_ladders = 0
    for _ in pairs(ladders) do n_ladders = n_ladders + 1 end
    if n_ladders > 0 then
        report(('  %d real step ladder(s) from data/quest_steps.lua'):format(n_ladders))
    end

    -- Both `en` and `enl`, `en` winning collisions. See normalize.lua for why.
    local item_by_name, ki_by_name = N.make_item_index(items, key_items)

    -- ---- load every area (prereq resolution must span all of them) --------
    local cats = {quest = {}, mission = {}}
    local AREA_FILES = {
        quest = {'abyssea', 'adoulin', 'bastok', 'coalition', 'crystal_war',
                 'jeuno', 'other', 'outlands', 'sandoria', 'toau', 'windurst'},
        mission = {'acp', 'adoulin', 'asa', 'assault', 'bastok', 'campaign',
                   'cop', 'mkd', 'rov', 'sandoria', 'toau', 'tvr', 'windurst',
                   'wotg', 'zilart'},
    }

    --[[ The DAT owns identity, via data/dat_names.lua. No other source decides
         which quests exist.

         Why the DAT wins: the runtime already believes it. core/state.lua
         builds the completion set from the 0x056 blob at :306-308, where bit
         N is DAT index N, and is_completed does `s[id + 1]` (:451-455), so a
         wrong id reports another quest's completion. Scraped ids disagree with
         it 41 times, all `quest/coalition`.

         A scraped `id` is accepted where the DAT name at that id matches the
         page name, else the page name is bound against the DAT. A plain name
         lookup would not do -- the DAT holds "Eddies of Despair" at rov/130
         and rov/232 both. Zero unbound, zero collisions. ]]
    local dat_names = load_table(outdir .. 'data/dat_names.lua')
    if not dat_names then
        return nil, 'data/dat_names.lua not found or unreadable at ' .. outdir
    end

    --[[ PER CATEGORY, because one summed line cannot state the invariant.
         Quests and missions bind under the same rule and can move
         independently, so a single summed "kept / rebound" line would hide
         which side moved. Both report 0 rebound today, which is the answer
         the split is there to make visible rather than to assume. Keyed by
         cat so the report loop can walk them in a fixed order. ]]
    local zone_over_rows = {}
    local bind = {
        quest   = {kept = 0, rebound = 0, unbound = 0, collided = 0, rows = {}},
        mission = {kept = 0, rebound = 0, unbound = 0, collided = 0, rows = {}},
    }

    --[[ Scraped page titles carry a disambiguating parenthetical the DAT does
         not ("Eco-Warrior (Bastok)" against a bare "Eco-Warrior"), so the bare
         form is tried second. Only ever as a fallback: stripping first would
         collapse the three same-named Eco-Warriors into one. ]]
    local function bare_name(s) return (tostring(s):gsub('%s*%([^)]*%)%s*$', '')) end
    local function name_eq(a, b)
        if a == nil or b == nil then return false end
        return fold(a) == fold(b) or fold(a) == fold(bare_name(b))
    end

    --[[ ipairs over a fixed pair, not pairs() over a map literal. The rows this
         loop appends go straight into the report, so a hash-order walk lets the
         quest and mission blocks swap places between builds -- a diff of two
         build logs then shows movement that is not there. Cheap to get right
         and this function's whole argument is that ordering is not incidental. ]]
    for _, ent in ipairs({{'quest', 'quests'}, {'mission', 'missions'}}) do
        local cat, sub = ent[1], ent[2]
        local B = bind[cat]
        for _, area in ipairs(AREA_FILES[cat]) do
            local names = (dat_names[cat] or {})[area]
            if not names then
                report(('  WARNING: dat_names has no %s/%s'):format(cat, area))
            else
                --[[ Empty, always. The loop below still runs over it because
                     the shape it produces -- `meta` and `page`, looked up by
                     DAT id -- is what every branch downstream expects, and an
                     empty one makes each of those branches fall through to the
                     authored data or to nothing at all.

                     It is not dead code waiting to be deleted. Keeping the loop
                     is what makes the binding REPORT still true (0 kept, 0
                     rebound, 0 unbound, 0 collisions), and those four zeros
                     assert the thing worth asserting: no row's identity comes
                     from anywhere but data/dat_names.lua. ]]
                local wiki = {}

                --[[ Built in SORTED id order, so a DAT name that appears twice
                     resolves to its lowest id on every run. pairs() here would
                     reintroduce exactly the hash-order non-determinism the
                     accept-when-corroborated rule exists to avoid. ]]
                local by_name = {}
                for _, id in ipairs(sorted_keys(names)) do
                    local f = fold(names[id])
                    if by_name[f] == nil then by_name[f] = id end
                end

                local meta, page = {}, {}
                for _, qname in ipairs(sorted_keys(wiki)) do
                    local rec = wiki[qname]
                    if type(rec) == 'table' then
                        local id
                        if rec.id and name_eq(names[rec.id], qname) then
                            id = rec.id
                            B.kept = B.kept + 1
                        else
                            id = by_name[fold(qname)] or by_name[fold(bare_name(qname))]
                            if id then
                                B.rebound = B.rebound + 1
                                B.rows[#B.rows + 1] =
                                    ('    REBOUND %s/%s/%s -> %d  %s  (id %s is "%s")'):format(
                                        cat, area, tostring(rec.id), id, qname,
                                        tostring(rec.id),
                                        tostring(rec.id and names[rec.id]))
                            else
                                --[[ A scraped record naming a quest the DAT
                                     does not have. Its metadata is dropped, so
                                     it is named rather than counted -- silently
                                     losing a giver is how a marker disappears
                                     without anyone noticing. Zero today. ]]
                                B.unbound = B.unbound + 1
                                B.rows[#B.rows + 1] =
                                    ('    UNBOUND %s/%s  %s  (source id %s)')
                                        :format(cat, area, qname, tostring(rec.id))
                            end
                        end
                        --[[ First writer wins, in sorted-name order -- and
                             COUNTED, because the loser is discarded whole.

                             A second record landing on an id already taken
                             loses its giver, zone, requirements, prerequisites
                             and its page alias, which is the same disappearing
                             marker the unbound branch above is careful to name.
                             Zero collisions is one of the two numbers that make
                             this rule safe, and a number nothing prints is not
                             a number anybody checks. Zero today, in both
                             categories. ]]
                        if id then
                            if meta[id] == nil then
                                meta[id], page[id] = rec, qname
                            else
                                B.collided = B.collided + 1
                                B.rows[#B.rows + 1] =
                                    ('    COLLISION %s/%s/%d  kept "%s", DROPPED "%s"')
                                        :format(cat, area, id, tostring(page[id]), qname)
                            end
                        end
                    end
                end
                cats[cat][area] = {ids = sorted_keys(names), name = names,
                                   meta = meta, page = page}
            end
        end
    end

    for _, cat in ipairs({'quest', 'mission'}) do
        local B = bind[cat]
        report(('  identity from data/dat_names.lua  %-7s %d kept, %d rebound, '
            .. '%d UNBOUND, %d COLLISIONS')
            :format(cat, B.kept, B.rebound, B.unbound, B.collided))
        for _, l in ipairs(B.rows) do report(l) end
    end

    --[[ ---- name -> (cat, area, id) for prerequisite resolution -------------

         TWO indexes, because names are not globally unique. "Magicite" is
         mission #13 in ALL THREE nation lines, so a global lookup sees a
         collision and gives up.

         The per-area index answers it: a San d'Oria mission's prerequisite
         obviously means San d'Oria's copy. Only fall back to the global index
         (and then to unresolved) when the name does not exist in the entry's
         own area. ]]
    --[[ Iterated in SORTED order, not pairs() order.

         Both matter. `name_index` keeps the FIRST name it sees and flags later
         conflicts ambiguous, so hash order would decide which area wins a
         collision -- and the emit loop below writes rows in iteration order,
         so it would permute the rows inside each by_npc list on every rebuild.
         Two builds of the same data must be byte-identical, or a diff between
         index versions hides the real changes in the noise. ]]
    local name_index, ambiguous, by_area = {}, {}, {}
    --[[ Same three, with punctuation dropped. A strictly later rung -- see the
         population loop below for why it must also be unique to be used. ]]
    local name_relax, relax_ambiguous, by_area_relax = {}, {}, {}
    local function relax_key(s) return (fold(s):gsub('%p', '')) end
    for _, cat in ipairs(sorted_keys(cats)) do
        local areas = cats[cat]
        for _, area in ipairs(sorted_keys(areas)) do
            local d = areas[area]
            local akey = cat .. '/' .. area
            by_area[akey] = by_area[akey] or {}
            by_area_relax[akey] = by_area_relax[akey] or {}
            --[[ Two names per row, and both need indexing.

                 A prerequisite is written by hand on a BG Wiki page, so it
                 names the quest the wiki's way, while the row is keyed by DAT
                 id and carries the DAT name.

                 Almost everywhere those are the same string: after binding the
                 page name equals the DAT name for all 1127 scraped quest
                 records, the 41 rebound coalition rows included. The alias
                 branch below fires exactly once in the whole build, on
                 mission/rov/232, "Eddies of Despair (2)" against a DAT that
                 spells 130 and 232 identically. Quest side: zero.

                 Still worth the four lines. It is the shape that recurs
                 whenever the client reuses a name, and missing it leaves a
                 prerequisite that cannot resolve, shown as a black "!".
                 So: DAT name first, page alias only where it differs. ]]
            local function add_name(qname, id)
                if qname == nil or qname == '' then return end
                local k = fold(qname)
                --[[ Refuses on a collision. A wrong prerequisite is a silently
                     wrong marker; an unresolved one is an honest unknown.

                     `resolve_prev_name` consults this index first and
                     unconditionally, so the global `ambiguous` set below cannot
                     override it -- the flag has to be set here. Off the DAT, 11
                     names repeat within an area, and on 6 of them the lower id
                     is an empty slot while
                     the real quest sits higher: "The Emissary (San d'Oria)" at
                     mission/bastok 6 and 8, "Journey to Bastok" at
                     mission/sandoria 6 and 8. First-wins would hand a
                     prerequisite the empty slot.

                     Latent, not live: nothing names those six today, the
                     nation lines being written as mission numbers. names.py
                     returns `ambiguous_dat_id` at the same fork. ]]
                local at = by_area[akey][k]
                if at == nil then
                    by_area[akey][k] = {cat = cat, area = area, id = id}
                elseif at and at.id ~= id then
                    by_area[akey][k] = false
                end
                do
                    local prev = name_index[k]
                    if prev and (prev.area ~= area or prev.id ~= id) then
                        ambiguous[k] = true
                    elseif not prev then
                        name_index[k] = {cat = cat, area = area, id = id}
                    end
                end

                    --[[ A parallel index with punctuation removed, used ONLY as
                         a later rung and ONLY when it lands on one candidate.

                         BG Wiki writes a Previous field by hand, so it drifts
                         from the title by an apostrophe: "The Postman Always
                         K.O.s Twice" against the DAT's "K.O.'s". Without this
                         rung such a prerequisite cannot resolve and the quest
                         shows a black "!" whatever the player has finished.

                         Uniqueness is not decoration: 5 DAT names collide once
                         punctuation is dropped. A wrong prerequisite is a
                         silently wrong marker; an unresolved one is an honest
                         unknown, so a collision must stay unresolved. ]]
                local rk = relax_key(qname)
                local rprev = by_area_relax[akey][rk]
                if rprev == nil then
                    by_area_relax[akey][rk] = {cat = cat, area = area, id = id}
                elseif rprev and (rprev.id ~= id) then
                    by_area_relax[akey][rk] = false
                end
                local gprev = name_relax[rk]
                if gprev and (gprev.area ~= area or gprev.id ~= id) then
                    relax_ambiguous[rk] = true
                elseif not gprev then
                    name_relax[rk] = {cat = cat, area = area, id = id}
                end
            end

            --[[ Numeric id order, not name order. Walking sorted page names
                 would let the alphabet decide which row wins a same-name
                 collision; walking the ids makes it the lowest id, which is
                 stable under any future renaming of a page. ]]
            for _, id in ipairs(d.ids) do
                add_name(d.name[id], id)
                local alias = d.page[id]
                if alias and fold(alias) ~= fold(d.name[id]) then
                    add_name(alias, id)
                end
            end
        end
    end
    report(('name index: %d entries, %d ambiguous (resolved per-area first)')
        :format(count(name_index), count(ambiguous)))

    --[[ Out of scope, which is not the same as not yet authored.

         Adoulin's coalition assignments are excluded from the index. Not for
         want of data -- all 95 are read and carry a ladder -- but because a
         coalition assignment is a rotating offer against a shared quest-log
         slot, bought with Imprimaturs. This addon's marker states (take it,
         turn it in, repeat it) describe none of that, and a "you can start
         this" marker on a Task Delegator is true only until the rotation
         moves.

         Excluded here and nowhere else. The rows are still loaded above, so
         prerequisite resolution still spans them (nothing names one today),
         data/quest_steps.lua keeps its 95 ladders, and the DAT binding is
         untouched: a coalition row still binds to its DAT id here, and a
         wrong id would still be a wrong completion bit.

         Costs 96 rows, 32 coalition-only by_npc keys, 0 by_zone refs, 0
         prerequisites. Re-including the area is deleting one line here. ]]
    local EXCLUDED_AREAS = {quest = {coalition = true}}

    -- ---- which areas get markers -----------------------------------------
    local want = {}
    do
        local raw
        if opts.all_areas then
            raw = {}
            --[[ sorted_keys over `cats`, not pairs(): the excluded rows are
                 REPORTED below, and a report whose line order moves between
                 builds is a diff full of changes that are not changes. ]]
            for _, cat in ipairs(sorted_keys(cats)) do
                raw[cat] = sorted_keys(cats[cat])
            end
        else
            raw = {quest = V1_QUEST_AREAS, mission = V1_MISSION_AREAS}
        end
        for _, cat in ipairs(sorted_keys(raw)) do
            local skip = EXCLUDED_AREAS[cat] or {}
            local keep = {}
            for _, area in ipairs(raw[cat]) do
                if skip[area] then
                    --[[ Named, not silently filtered. An area vanishing from
                         the index is the largest change this build can make and
                         it must never read as data going missing. ]]
                    report(('  area EXCLUDED from the index: %s/%s (out of '
                        .. 'scope -- see EXCLUDED_AREAS)'):format(cat, area))
                else
                    keep[#keep + 1] = area
                end
            end
            want[cat] = keep
        end
    end

    --[[ by_zone: quests started by ENTERING a zone rather than by talking to
         anyone. 48 of them across the full data set. There is no NPC to mark,
         but the addon can still tell you "this zone starts a quest you can
         take" when you arrive. ]]
    --[[ `all_entries` is the deduplicated truth: by_npc stores the same entry
         object under every key that can give it (gate guards, multi-option
         givers), so counting it double-counts. ]]
    local by_npc, by_zone, all_entries, unmatched = {}, {}, {}, {}
    --[[ Named, not merely counted, like every other substitution in this build:
         moving a giver's marker to a different zone is exactly the change a
         human has to be able to check. ]]
    local era_rows = {}
    local st = {
        indexed = 0, no_npc = 0, generic = 0, object = 0, zone_trigger = 0,
        none = 0, prev_unresolved = 0, zone_unresolved = 0,
        reqs_partial = 0,
    }

    --[[ Folded into `st` here rather than at the binding loop, which runs long
         before `st` exists. Summed across categories only for the stat block;
         the per-category split is reported at the loop, where a difference
         between the two categories would be the informative part. ]]
    st.id_kept     = bind.quest.kept     + bind.mission.kept
    st.id_rebound  = bind.quest.rebound  + bind.mission.rebound
    st.id_unbound  = bind.quest.unbound  + bind.mission.unbound
    st.id_collided = bind.quest.collided + bind.mission.collided

    --[[ Resolve a record's `previous` names into (cat, area, id) references.

         Own area before global, exact before relaxed, and a trailing "(Quest)"
         -- a wiki disambiguation artifact, never part of a DAT name -- stripped
         as a second candidate. Only "(Quest)" and never any trailing
         parenthetical: "Eco-Warrior" is ONE bare DAT name in three areas and
         the wiki tells them apart by exactly that suffix, so stripping blindly
         would merge three quests.

         EXTRACTED so the zone-trigger branch can call it too. A row that skips
         it ships with no prerequisites, and prereq.evaluate returns 'ready'
         for a row with nothing to check. ]]
    --[[ ONE name -> one {cat, area, id}, or nil.

         Split out of resolve_prev so the AUTHORED prerequisites can go through
         exactly this path rather than a second copy of it. Everything that
         makes it correct is order-dependent and easy to get subtly wrong
         somewhere else: the quest's OWN area wins first (`Ghosts of the Past`
         is both mission/toau/15 and quest/bastok/51, and quest/bastok/52 means
         the latter), a globally ambiguous name is refused rather than guessed,
         and only then does the relaxed matcher run -- which is what closes
         `Water Way to Go` against the client's `Water Way to Go!` and
         `The Postman Always K.O.s Twice` against `K.O.'s`. ]]
    --[[ "Promathia Mission 3-2" -> "A Vessel Without a Captain".

         Applied at the very top of name resolution, so every `previous` string
         is de-numbered by the same line of code. De-numbering one copy of a
         prerequisite and not another leaves the row holding a resolved entry
         AND an unresolved twin, which pins the quest at nil forever. A black
         "!" that can never clear is worse than a false yellow.

         Table generated from bgwiki-rest-cache/supplemental/mission_numbers.json
         by emit_lua.py. Absent is survivable: a numbered prerequisite simply
         stays unresolved. ]]
    local mnum = load_table(outdir .. 'tools/lib/mission_numbers.lua')
    local function denumber(pname)
        if not mnum then return pname end
        local line, num = pname:match('^%s*(.-)%s+[Mm]ission%s+(%d+%-?%d*)%s*$')
        if not line then return pname end
        local key = mnum.aliases and mnum.aliases[fold(line)]
        if not key then return pname end
        local t = mnum.lines and mnum.lines[key]
        return (t and t[num]) or pname
    end

    local function resolve_prev_name(pname, cat, area)
        pname = denumber(pname)
        local own = by_area[cat .. '/' .. area] or {}
        local own_r = by_area_relax[cat .. '/' .. area] or {}
        local cands = {pname}
        local bare = pname:gsub('%s*%(%s*[Qq]uest%s*%)%s*$', '')
        if bare ~= pname and bare ~= '' then
            cands[#cands + 1] = bare
        end

        local hit
        for _, c in ipairs(cands) do
            hit = hit or own[fold(c)]
        end
        for _, c in ipairs(cands) do
            local k = fold(c)
            if not hit and not ambiguous[k] then
                hit = name_index[k]
            end
        end
        for _, c in ipairs(cands) do
            if not hit then
                local r = own_r[relax_key(c)]
                if r then
                    hit = r
                    st.prev_relaxed = (st.prev_relaxed or 0) + 1
                end
            end
        end
        for _, c in ipairs(cands) do
            local k = relax_key(c)
            if not hit and not relax_ambiguous[k] then
                hit = name_relax[k]
                if hit then
                    st.prev_relaxed = (st.prev_relaxed or 0) + 1
                end
            end
        end
        return hit
    end

    local function resolve_prev(rec, cat, area)
        local prev = {}
        for _, pname in ipairs(rec.previous or {}) do
            if type(pname) == 'string' then
                local hit = resolve_prev_name(pname, cat, area)
                if hit then
                    prev[#prev + 1] = hit
                else
                    prev[#prev + 1] = {unresolved = pname}
                    st.prev_unresolved = st.prev_unresolved + 1
                end
            end
        end
        return prev
    end

    for _, cat in ipairs({'quest', 'mission'}) do
        for _, area in ipairs(want[cat] or {}) do
            local d = cats[cat][area]
            if not d then
                report(('  WARNING: no data for %s/%s'):format(cat, area))
            else
                --[[ Driven by the DAT id list, so the row set is every quest
                     the client knows about rather than every page that was
                     scraped. `rec` is a metadata side-table looked up by that
                     id, and an id with no record gets an empty one.

                     Empty is legitimate: 16 quest and 88 mission ids arrive
                     with no record and no ladder. Most are unused DAT slots
                     the client ships anyway ("JNQuest", "Windurst Quest #22").
                     They resolve no giver and emit no row.

                     `no_source` counts those 104 separately even though they
                     also land in `no_npc`. Without it, one number conflates "we
                     know the quest but not its giver" with "nothing on disk
                     knows this quest", and only the first is worth authoring a
                     page for. ]]
                for _, qid in ipairs(d.ids) do
                    do
                        local rec = d.meta[qid] or EMPTY_REC
                        if rec == EMPTY_REC and not ladders[cat .. '/' .. area .. '/' .. qid] then
                            st.no_source = (st.no_source or 0) + 1
                        end
                        local keys, kind, zone_hint =
                            normalize_npc(rec.start_npc, resolve_zone, overrides)

                        --[[ The role set, tracked separately from `keys` FROM
                             HERE DOWN. `keys` accumulates everywhere the row is
                             worth SCANNING; this is the much smaller set of
                             NPCs the row's own source says can START it, and it
                             is only ever non-nil when an override expanded a
                             role. `giver_keys` reads it and nothing else does.
                             The scraped string is tried first because it is the
                             shape the override was written for; the ladder's
                             set below fills it in when that string is absent. ]]
                        local role_set = nil

                        --[[ A real ladder can also rescue a quest whose GIVER
                             the scraped record never resolved, not just its
                             zone.

                             Without it the pipeline can only improve rows the
                             scrape already produced and can never add one.
                             "Meanwhile, Back on Abyssea" is the shape: an empty
                             Start= with Joachim named in its walkthrough, which
                             is exactly the fact reading the page recovers. 114
                             pages have an empty Start= and 112 more have no
                             wikilink in it, a fifth of the corpus.

                             Strictly additive: it only fires where the record
                             produced nothing usable, so no existing row can
                             change or disappear. `snpc` is already the folded
                             key form, the same shape normalize_npc returns. ]]
                        local L_start = ladders[cat .. '/' .. area .. '/' .. qid]
                        if kind ~= 'zone_trigger' and (kind ~= 'npc' or #keys == 0)
                           and L_start and L_start.snpc and L_start.snpc ~= '' then
                            --[[ THROUGH normalize_npc, not straight into `keys`.
                                 Do not wrap `snpc` as one key on the argument
                                 that it is "already the folded key form".
                                 That is true of a single name and false of
                                 every other shape that function handles --
                                 most importantly the MULTI-OPTION giver.
                                 "Any Bastok Gate Guard" resolves to four real
                                 NPCs, written "Argus or Cleades or Malduc or
                                 Rashid". normalize_npc splits that into four
                                 keys; wrapping it whole makes ONE key of the
                                 entire sentence, which matches no entity, so
                                 three of the four guards get no marker.
                                 Idempotent on a plain name -- `normalize_npc
                                 ('argus')` returns `{'argus'}` -- so every
                                 single-giver row is unaffected. ]]
                            --[[ ...and through `snpcs` too, which is the same
                                 expansion for a giver stated as a ROLE. This is
                                 the only route the other three guards have. ]]
                            local lk, lhint, lrole = ladder_giver_keys(L_start)
                            if lk then
                                keys, kind, zone_hint = lk, 'npc', lhint
                                role_set = role_set or lrole
                            else
                                --[[ normalize_npc declined to produce keys --
                                     an unrecognised shape. Kept whole so the
                                     row is not silently dropped; it will match
                                     no entity, which is visible in
                                     tools/unmatched.txt. ]]
                                keys, kind, zone_hint = {L_start.snpc}, 'npc', nil
                            end
                            st.rescued_start = (st.rescued_start or 0) + 1
                        end

                        --[[ The ladder's giver keys are unioned in, even where
                             the scraped record produced some. `giver_of`
                             prefers the ladder's `snpc` for the emitted column
                             while the by_npc keys come from `start_npc`, so
                             without this a row can display one giver and draw
                             on another.

                             Union, not replacement. The two sides disagree on
                             55 rows and the ladder is not always the better
                             read -- for the Abyssea entry quests the record
                             names the quest NPC and the ladder the Cavernous
                             Maw, and a player might look at either. Replacing
                             would move 55 markers to fix a four-guard problem;
                             unioning adds the guards and moves nothing. ]]
                        if kind == 'npc' and L_start and L_start.snpc
                           and L_start.snpc ~= '' then
                            local lk, _, lrole = ladder_giver_keys(L_start)
                            lk = lk or {}
                            role_set = role_set or lrole
                            local have = {}
                            for _, k in ipairs(keys) do have[k] = true end
                            for _, k in ipairs(lk) do
                                if not have[k] then
                                    keys[#keys + 1] = k
                                    have[k] = true
                                    st.giver_key_added = (st.giver_key_added or 0) + 1
                                end
                            end
                        end

                        --[[ An authored giver beats a scraped zone trigger,
                             the one place the rescue above is not additive.

                             A row is marked zone-triggered when the page's
                             Start field holds a zone, not a person. Right
                             reading of the field, but a whole zone is
                             not markable: by_zone entries have no entity to
                             draw on, so they show in `//qm todo` and put
                             nothing in the world.

                             17 of the 53 such rows have a ladder naming
                             something specific, 13 of them an object --
                             mission/cop/718's "dilapidated gate", asa/7's
                             "ensorcelled door", cop/728's "shaft entrance".
                             Those are what the player examines to begin.

                             This moves markers, so it is reported row by row. ]]
                        if kind == 'zone_trigger'
                           and L_start and L_start.snpc and L_start.snpc ~= '' then
                            zone_over_rows[#zone_over_rows + 1] =
                                ('    %s/%s/%d  zone trigger -> %q'):format(
                                    cat, area, qid, L_start.snpc)
                            keys, kind, zone_hint = {L_start.snpc}, 'npc', nil
                            st.giver_over_zone = (st.giver_over_zone or 0) + 1
                        end

                        --[[ The authored zone trigger: an entry with no giver
                             because it genuinely has none.

                             Some content is not handed out by anybody. Walk
                             into Promyvion - Vahzl and Chains of Promathia 5-2
                             starts. The page's Start field names a zone, which
                             normalize_npc reads, and that is where the 49
                             scraped zone-started rows come from. The authored
                             path needs this branch to say the same thing: the
                             rescue above forces `kind = 'npc'` and the ladder
                             only offers `snpc`, so without it such a row falls
                             through to `no_npc` and draws nothing.

                             `sz` is the authored start zone, resolved to an id
                             by stage C, so it cannot mis-resolve. 39 rows have
                             no giver and a resolved start zone; 8 have neither
                             and stay put -- we cannot place them. ]]
                        if kind ~= 'zone_trigger' and (kind ~= 'npc' or #keys == 0)
                           and L_start and (not L_start.snpc or L_start.snpc == '')
                           and type(L_start.sz) == 'number' then
                            kind, zone_hint = 'zone_trigger', L_start.sz
                            st.authored_zone_trigger =
                                (st.authored_zone_trigger or 0) + 1
                        end

                        --[[ Last resort: a quest with NO giver anywhere, but a
                             ladder that still names somewhere to stand.

                             14 of these -- Campaign ops and ToAU chains that
                             start by zoning in or by an NPC no source ever
                             names. The entry is bootstrapped from by_npc, so
                             with no giver key nothing is inserted, the quest
                             never becomes an entry, and its whole ladder is
                             discarded even though its own STEPS name markable
                             targets.

                             Anchored on the first markable step purely so the
                             quest exists. `snpc` is deliberately left empty
                             (see the snpc line below): step 0 is the GIVER, and
                             a mid-quest NPC is not one. An unstarted quest asks
                             `has_entity(steps[1])` and otherwise wants step 0,
                             so with no giver it draws nothing until accepted --
                             which is correct, because there is nowhere to
                             accept it from that we know of. ]]
                        local anchored_on_a_step = false
                        if kind ~= 'zone_trigger' and (kind ~= 'npc' or #keys == 0)
                           and L_start and L_start.steps then
                            for _, s in ipairs(L_start.steps) do
                                if s.npc and s.npc ~= '' then
                                    keys, kind, zone_hint = {s.npc}, 'npc', nil
                                    anchored_on_a_step = true
                                    st.rescued_by_step = (st.rescued_by_step or 0) + 1
                                    break
                                end
                            end
                        end

                        if kind == 'zone_trigger' then
                            --[[ Keep it, keyed by the zone that starts it. The
                                 trigger zone is the start_npc string itself
                                 (BG Wiki puts a zone name in the giver field
                                 for these), falling back to start_zone.

                                 An AUTHORED trigger arrives with `zone_hint`
                                 already an id and is preferred outright: it was
                                 resolved by stage C against res/zones.lua from
                                 the page's own Start field, where these two
                                 resolve scraped free text. Same zone in the
                                 overwhelming majority of cases; where they
                                 differ the first-hand one is the better read,
                                 and unlike the strings it cannot fail to
                                 resolve at all. ]]
                            local tz = (type(zone_hint) == 'number' and zone_hint)
                                or resolve_zone(rec.start_npc) or resolve_zone(rec.start_zone)
                            if tz then
                                by_zone[tz] = by_zone[tz] or {}
                                --[[ A real entry, not an identity triple.

                                     A bare {cat, area, id} reaches
                                     prereq.evaluate with no prerequisites, no
                                     fame gate and no level, and that returns
                                     'ready' unconditionally because there is
                                     nothing there to check.

                                     `previous` is resolved by the same function
                                     the NPC branch uses. ]]
                                table.insert(by_zone[tz], {
                                    cat = cat, area = area, id = qid, zone = tz,
                                    repeatable = chron_repeatable(rec),
                                    prev = resolve_prev(rec, cat, area),
                                    reqs = {},
                                    fame = nil, fame_lvl = nil,
                                })
                                st.zone_started = (st.zone_started or 0) + 1
                            else
                                st.zone_trigger = (st.zone_trigger or 0) + 1
                                unmatched[#unmatched + 1] = ('%s/%s/%d\t%s\t%s')
                                    :format(cat, area, qid, kind, tostring(rec.start_npc))
                            end
                        elseif kind ~= 'npc' or #keys == 0 then
                            if rec.start_npc == nil then
                                st.no_npc = st.no_npc + 1
                            else
                                st[kind] = (st[kind] or 0) + 1
                                unmatched[#unmatched + 1] = ('%s/%s/%d\t%s\t%s')
                                    :format(cat, area, qid, kind, tostring(rec.start_npc))
                            end
                        else
                            --[[ Three distinct zone outcomes, and they must
                                 stay distinct:

                                   false        deliberately ANY zone -- an
                                                override said so (gate guards,
                                                whose nation spans districts)
                                   'moghouse'   only inside a Mog House
                                   number       that zone
                                   nil          UNRESOLVED -- we simply failed

                                 Collapse `false` and `nil` to one value and a
                                 failure to resolve is indistinguishable from a
                                 decision to match everywhere. ]]
                            local zid
                            if zone_hint == false then
                                zid = false
                            else
                                zid = resolve_zone(rec.start_zone)
                                if zid == nil then
                                    zid = zone_hint
                                    if rec.start_zone then
                                        st.zone_unresolved = st.zone_unresolved + 1
                                    end
                                end
                            end

                            --[[ ...and if the resolved zone is the present-day
                                 twin of the past-era zone the page named, the
                                 page wins. See past_era_twin above for why this
                                 one disagreement is decided here and the other
                                 hundred are not. `false` (deliberately any
                                 zone) and nil are both non-numbers, so neither
                                 can be overwritten by this. ]]
                            if L_start and past_era_twin(L_start.sz, zid) then
                                era_rows[#era_rows + 1] = ('    %s/%s/%d  giver '
                                    .. 'zone %d %s -> %d %s (page says "%s")')
                                    :format(cat, area, qid, zid,
                                            tostring(zone_name(zid)),
                                            L_start.sz, tostring(zone_name(L_start.sz)),
                                            tostring(rec.start_zone))
                                zid = L_start.sz
                                st.era_zone_fixed = (st.era_zone_fixed or 0) + 1
                            end

                            --[[ A generic name with no zone would match every
                                 entity of that name in the world -- "Moogle,
                                 Mog House" marked every Moogle in Vana'diel.
                                 Drop rather than over-mark. ]]
                            --[[ A real step ladder can rescue a quest the
                                 ambiguity guard would drop.

                                 "Dominion Op #01 (Altepa)" is given by a
                                 Dominion Sergeant -- a name shared world-wide,
                                 so it may only be indexed WITH a zone -- and
                                 the scraped zone is a bare "Altepa", which is
                                 deliberately unresolvable. Reading the wiki
                                 page gives "Abyssea - Altepa", which resolves,
                                 and that is exactly the missing fact. 18 rows
                                 depend on it. ]]
                            local L0 = ladders[cat .. '/' .. area .. '/' .. qid]

                            --[[ The page's own start zone, which outranks step
                                 1's. `sz` is the Start= field's zone, resolved
                                 to an id by stage C: where the giver stands.
                                 Step 1's zone is where the first thing happens,
                                 which is often but not always the same place.

                                 quest/abyssea/182 is given by Esha'ntarl in
                                 Ru'Lude Gardens (251) while its first step is
                                 in zone 45. Stamp the giver row with step 1's
                                 zone and the marker cannot draw where the NPC
                                 is.

                                 Step 1 stays as the rung below, for rows whose
                                 page states no start zone at all. ]]
                            if zid == nil and L0 and type(L0.sz) == 'number' then
                                zid = L0.sz
                                st.zone_from_start = (st.zone_from_start or 0) + 1
                            end

                            if zid == nil and L0 and L0.steps and L0.steps[1]
                               and L0.steps[1].z then
                                zid = L0.steps[1].z
                                st.rescued_by_ladder = (st.rescued_by_ladder or 0) + 1
                            end

                            local ambiguous_name = false
                            if zid == nil then
                                for _, k in ipairs(keys) do
                                    if AMBIGUOUS_NPCS[k] then ambiguous_name = true end
                                end
                            end

                            if ambiguous_name then
                                st.ambiguous_dropped = (st.ambiguous_dropped or 0) + 1
                                unmatched[#unmatched + 1] =
                                    ('%s/%s/%d\tambiguous\t%s (no resolvable zone: %s)')
                                    :format(cat, area, qid, tostring(rec.start_npc),
                                            tostring(rec.start_zone))
                            else

                            local prev = resolve_prev(rec, cat, area)

                            --[[ requirements -> resource ids.
                                 BG Wiki's requirement strings are frequently
                                 prose ("Vigil Weapon equipped.", "Varies",
                                 "10,000 Moat Carp and/or Forest Carp"). Those
                                 resolve to nothing, and KEEPING them would mean
                                 the quest could never reach the yellow "?"
                                 turn-in state. Dropping them can instead show
                                 yellow "?" slightly early -- the better failure,
                                 given turn-in detection is already a heuristic.
                                 The entry is flagged so //qm why can say so. ]]
                            --[[ The whole-quest requirement list, from our own
                                 ladder.

                                 core/prereq.lua reads `step.reqs or
                                 entry.reqs`, so this is the fallback for a step
                                 with no requirement of its own, and it only
                                 decides anything on a hand-over step: the
                                 branch that uses it gates on
                                 `steps.is_handover`. A thin list shows a
                                 yellow "?" early, which beats no marker at all.

                                 Union of the ladder's step requirements, deduped
                                 on (kind, rid) keeping the largest count. A row
                                 with no ladder gets an empty list. ]]
                            local reqs, dropped = {}, false
                            local L_reqs = ladders[cat .. '/' .. area .. '/' .. qid]
                            local seen_req = {}
                            for _, s in ipairs((L_reqs and L_reqs.steps) or {}) do
                                for _, r in ipairs(s.reqs or {}) do
                                    if r.rid then
                                        local k = (r.kind or 'item') .. ':' .. r.rid
                                        local prev = seen_req[k]
                                        if prev then
                                            if (r.n or 1) > (prev.n or 1) then
                                                prev.n = r.n or 1
                                            end
                                        else
                                            local e = {kind = r.kind or 'item',
                                                       rid = r.rid, n = r.n or 1}
                                            seen_req[k] = e
                                            reqs[#reqs + 1] = e
                                        end
                                    end
                                end
                                if s.reqs_partial then dropped = true end
                            end
                            if dropped then st.reqs_partial = st.reqs_partial + 1 end

                            --[[ No fame here. The page's reading is the only
                                 one, so the entry starts with no fame and
                                 `attach_ladder` puts the ladder's in. Left nil
                                 rather than absent so every entry keeps the
                                 same shape. ]]
                            local entry = {
                                cat = cat, area = area, id = qid, zone = zid,
                                --[[ The scraped half only. The wiki's half is
                                     merged in at `number()`, which is where the
                                     ladder -- and therefore `L.rep` -- first
                                     becomes available for this entry. ]]
                                repeatable = chron_repeatable(rec),
                                prev = prev, reqs = reqs, reqs_partial = dropped,
                                fame = nil, fame_lvl = nil,
                                --[[ This quest exists in the index only because
                                     one of its STEPS named somewhere; nobody
                                     knows who gives it. Step 0 must stay empty
                                     -- see the snpc line in the emitter. ]]
                                no_giver = anchored_on_a_step or nil,
                                --[[ The role set, or nil -- NOT the by_npc key
                                     list. `keys` is the SCAN set and is wider
                                     on purpose; see giver_keys' note for why
                                     this field must not hold it. This is the
                                     override expansion
                                     of a giver the page wrote as a role, and
                                     `giver_keys` is the only reader.

                                     A reference to a table built fresh per row
                                     by ladder_giver_keys, so
                                     no two entries share one and nothing writes
                                     to it after this point. ]]
                                gkeys = role_set,
                            }
                            for _, k in ipairs(keys) do
                                by_npc[k] = by_npc[k] or {}
                                table.insert(by_npc[k], entry)
                                --[[ The first key is the step's nominal target.
                                     A multi-option giver ("Ambrotien or
                                     Endracion or Grilau") has no single one, and
                                     it does not matter here: the by_npc key is
                                     what draws the marker, while step.npc only
                                     labels it in //qm why. ]]
                                entry.npc_key = entry.npc_key or k
                            end
                            all_entries[#all_entries + 1] = entry
                            st.indexed = st.indexed + 1
                            end     -- ambiguous_name guard
                        end
                    end
                end
            end
        end
    end

    -- ---- emit -------------------------------------------------------------

    --[[ TWO files, split by category, and the split is not cosmetic.

         The two halves differ in provenance -- which NOTICE states -- and in
         cadence: a mission rebuild takes under a second and runs in game via
         //qm rebuild,
         while a quest rebuild is an offline pipeline. Sharing one file would
         mean //qm rebuild either cannot run or silently destroys the quest half.

         A bad run also then corrupts only one file. ]]
    --[[ v2 layout, written as STATEMENTS rather than one table constructor.

         The v1 file is a single 290 KB literal and works, but the real dataset
         with steps will be several times that and LuaJIT refuses very large
         constructors ("function or expression too complex"). One statement per
         quest has no ceiling and diffs far better. One local `Q`, not one per
         quest -- Lua caps a function at 200 locals.

         Each quest record exists ONCE; by_npc holds {q, s, z} references. The
         zone is duplicated onto the reference and is the only duplicated field:
         it keeps wanted_names and zone_ok a flat scan with no indirection, so
         the hot path costs exactly what it did before.

         At this stage the steps array is SYNTHETIC -- one 'talk' step at the
         resolved start NPC, conf=1. That is the point: it exercises the entire
         new runtime path in game (v2 load, ref expansion, steps.current, the
         per-step filter, the //qm why block) on data that provably cannot
         advance past step 1, so any crash or perf surprise surfaces at zero
         data risk. ]]
    local function emit(path, want_cat, title, note)
        --[[ 'wb', not 'w'. Text mode on Windows turns every LF into CRLF, so
             the same corpus builds differently on Windows and on Linux. That
             breaks the byte-identical guarantee this build is checked against,
             and leaves `git status` dirty after a rebuild on the other
             platform. emit_lua.py pins an explicit LF newline for the same
             reason. ]]
        local f, ferr = io.open(path, 'wb')
        if not f then return nil, 'cannot write ' .. path .. ': ' .. tostring(ferr) end

        --[[ The header describes the file, so it must be counted from the file.

             `all_entries` counts entries CREATED and `order` counts records
             EMITTED, and they differ in both directions: merged duplicates are
             in the first and not the second, zone-triggered entries in the
             second and not the first. Counting `keys` and `rows` before `extra`
             -- every per-step row a real ladder adds -- misses those rows too.

             The header is not decorative: `meta.indexed` ships, and
             core/quests.lua sums it into the number `//qm diag` prints. So the
             counts are taken from the emitted content, below -- after numbering
             and after `extra` -- and the header is written there too. Nothing is
             written to `f` before that point. ]]
        local zones = 0
        local kept = {}
        for npc, list in pairs(by_npc) do
            local l = {}
            for _, e in ipairs(list) do
                if e.cat == want_cat then l[#l + 1] = e end
            end
            if #l > 0 then kept[npc] = l end
        end
        local kept_z = {}
        for z, list in pairs(by_zone) do
            local l = {}
            for _, e in ipairs(list) do
                if e.cat == want_cat then l[#l + 1] = e end
            end
            if #l > 0 then kept_z[z] = l; zones = zones + 1 end
        end

        --[[ Number every entry once, in a deterministic order, then reference
             it. by_npc stores the same entry object under several keys (gate
             guards, multi-option givers), so identity -- not value -- decides
             which index a reference gets. ]]
        --[[ One row per quest, which is not guaranteed. `number` dedupes by
             entry identity and is blind to two different objects for the same
             quest:

                 id 34  Gather: Ceizak Battlegrounds | Gather: Yahse Hunting Grounds
                 id 80  Recover: Ceizak Battlegrounds | Research: Foret de Hennetiel

             Two rows for one quest means `quests.each_entry` returns whichever
             `pairs()` hit first, so a blue "!" shows or not by hash order.
             Merged rather than refused. Refs survive: `qindex[e]` points at the
             survivor and a ladderless by_npc ref keeps its own zone, so both
             Task Delegators keep the quest. `zone` is not merged; the
             survivor's wins, reported. MERGE_WATCH must list fields an entry
             really has, never one derived at emit time -- `lvl`, `snpc` and
             `conf` are nil against nil here. ]]
        local qindex, order, by_key = {}, {}, {}
        local dupe_rows, n_dupes = {}, 0
        --[[ `gkeys` is deliberately NOT here. It is a TABLE, and this loop
             compares with `~=`, so every duplicate would report a difference
             from the survivor purely on identity -- a watch that always fires
             is as useless as one that cannot. It is also unreadable on a
             duplicate: only survivors reach `order`, and `giver_keys` is called
             over `order` alone. If that ever changes, compare the CONTENTS
             here, not the reference. ]]
        local MERGE_WATCH = {'zone', 'npc_key', 'no_giver', 'fame', 'fame_lvl',
                             'reqs_partial'}
        --[[ Attaching the ladder is also where the two `repeatable` sources
             meet, because `L.rep` is the wiki's half and this is the first
             point at which an entry has an `L` at all. One function, called at
             both attach sites, so a duplicate and its survivor cannot end up
             merged against different rules.

             FAME meets here too, and for exactly the same reason -- `L.fame` is
             its wiki half and there is no earlier point that has one. Note the
             ordering constraint this creates with MERGE_WATCH above, which
             watches `fame` and `fame_lvl`: both attach sites run BEFORE the
             duplicate comparison, so what that watch reports is post-merge on
             both rows. That is the comparison worth having -- two rows that
             disagreed only because one had a ladder and the other did not
             would otherwise be reported as a data conflict every build. ]]
        local n_rep_changed, n_rep_gained, n_rep_demoted = 0, 0, 0
        local n_fame_gained, n_fame_lvl_gained = 0, 0
        local n_fame_conflict, n_fame_lvl_moved = 0, 0
        local fame_conflict_rows = {}
        local function attach_ladder(e, key)
            e.ladder = ladders[key]
            local L = e.ladder
            local wiki = L and L.rep
            local merged = merge_repeatable(wiki, e.repeatable)
            if merged ~= e.repeatable then
                n_rep_changed = n_rep_changed + 1
                if merged == true then n_rep_gained = n_rep_gained + 1 end
            end
            --[[ A demotion is the interesting event, not the total: it is a
                 'repeat' marker this build removes. Counted so that a change in
                 it is a question somebody asks rather than silence. 6 today:
                 the two the floor comment names, plus four Borghertz records
                 read as `false` for the same wiki-tagging reason. A seventh is
                 a new case and wants measuring before it is believed. ]]
            if wiki == false and e.repeatable == true then
                n_rep_demoted = n_rep_demoted + 1
            end
            e.repeatable = merged

            --[[ Fame, straight from the ladder. There is no second source to
                 merge against.

                 Still counted: an entry arrives here with no fame at all, so
                 `n_fame_gained` is the number of rows whose page stated a
                 region, and `n_fame_lvl_gained` the number that also stated a
                 threshold and so carry a gate that can actually fire. Those two
                 are the numbers the report prints and the only check that the
                 emitter is still writing the field.

                 `n_fame_conflict` and `n_fame_lvl_moved` cannot fire and are
                 kept at zero rather than deleted: they are what the report line
                 asserts, and a line that stops asserting something stops
                 catching anything. ]]
            local wf, wl = (L and L.fame), (L and L.fame_lvl)
            if wf ~= nil then
                n_fame_gained = n_fame_gained + 1
                if wl ~= nil then
                    n_fame_lvl_gained = n_fame_lvl_gained + 1
                end
            end
            e.fame, e.fame_lvl = wf, wl
        end
        local function number(e)
            if qindex[e] then return end
            local key = e.cat .. '/' .. e.area .. '/' .. e.id
            local first = by_key[key]
            if first then
                n_dupes = n_dupes + 1
                --[[ Every reference that would have pointed at this copy now
                     points at the survivor. Nothing is dropped. ]]
                qindex[e] = qindex[first]
                --[[ ...and the duplicate gets the ladder too, purely so the
                     by_npc writer's `if not e.ladder` guard skips it.

                     Without this a merged duplicate that ever gained a ladder
                     would emit `{q=survivor, s=1, z=<its own zone>}` from its
                     npc key -- a step-1 marker in the duplicate's zone for work
                     the ladder puts somewhere else, which is the
                     wrong-destination marker this project forbids. The ladder is
                     keyed on the identity both copies share, so this is the same
                     object the survivor got, never a second one.

                     Unreachable today: `n_dupes` is zero in every category,
                     identity coming from the client's DAT and the coalition
                     area not reaching the index at all. Kept as one line that
                     disarms a trap rather than leaving it armed. ]]
                attach_ladder(e, key)
                first.repeatable = or_repeatable(first.repeatable, e.repeatable)
                local differs = {}
                for _, f in ipairs(MERGE_WATCH) do
                    if first[f] ~= e[f] then
                        differs[#differs + 1] = ('%s %s/%s'):format(
                            f, tostring(first[f]), tostring(e[f]))
                    end
                end
                dupe_rows[#dupe_rows + 1] = ('    %s  merged%s'):format(
                    key, #differs > 0
                        and ('  DISAGREES ON ' .. table.concat(differs, ', '))
                        or '')
                return
            end
            order[#order + 1] = e
            qindex[e] = #order
            by_key[key] = e
            attach_ladder(e, key)
        end
        for _, npc in ipairs(sorted_keys(kept)) do
            for _, e in ipairs(kept[npc]) do number(e) end
        end
        --[[ Zone-triggered entries get a record too.

             Build `order` from by_npc alone and an entry with no NPC giver
             never becomes a `Q[]` row -- by_zone then emits it as a bare
             {cat, area, id} carrying no prerequisite, fame, level or job data
             whatsoever, and `prereq.evaluate` on such a row returns 'ready'
             with zero reasons because there is nothing there to check. All 49
             are in that shape when they arrive.

             They are built at the zone_trigger branch, far above the point
             where prerequisites, requirements and fame are parsed, so the two
             lines below fill the collections the row emitter indexes. Shape
             only; no content is invented. ]]
        for _, z in ipairs(sorted_keys(kept_z)) do
            for _, e in ipairs(kept_z[z]) do
                e.prev = e.prev or {}
                e.reqs = e.reqs or {}
                number(e)
            end
        end

        --[[ The authored prerequisites, merged in.

             Not a rare shape. `Waking Dreams` needs `Darkness Named`, which is
             not a quest but Chains of Promathia 3-5, mission/cop/358, and a
             scrape of the header field never records a mission as a quest's
             prerequisite. Without this merge Kerutoto offers the quest to a
             character who has never started CoP.

             Union, not replacement: both sources are BG Wiki derived and both
             can be short, so a name missing from either is a false yellow.
             Deduped on the resolved identity. An unresolvable name is kept as
             `{unresolved = ...}`, which `prereq.evaluate` reads as nil and
             draws black -- incomplete data must not read as a blocked player. ]]
        local n_prev_added, n_prev_mission, n_prev_unres, n_prev_q = 0, 0, 0, 0
        local n_prev_evicted = 0
        local prev_added_rows = {}
        for _, e in ipairs(order) do
            local L = e.ladder
            if L and L.prev and #L.prev > 0 then
                e.prev = e.prev or {}
                local seen = {}
                for _, p in ipairs(e.prev) do
                    seen[p.unresolved and ('?' .. p.unresolved)
                        or ('%s/%s/%d'):format(p.cat, p.area, p.id)] = true
                end
                for _, pname in ipairs(L.prev) do
                    if type(pname) == 'string' then
                        local hit = resolve_prev_name(pname, e.cat, e.area)
                        --[[ The stale twin. The same prerequisite can arrive
                             twice, and where a page wrote it as a NUMBER
                             ("Zilart Mission 13") only the authored copy passes
                             through stage C's de-numbering -- the other stays
                             an unresolvable string.
                             Left alone, the row holds both, and the unresolved
                             one pins the quest at nil forever: a black "!" that
                             cannot go yellow however much of Rise of the Zilart
                             the player has finished. So a resolved name evicts
                             its own unresolved twin. ]]
                        if hit then
                            for i = #e.prev, 1, -1 do
                                if e.prev[i].unresolved == pname then
                                    table.remove(e.prev, i)
                                    seen['?' .. pname] = nil
                                    n_prev_evicted = n_prev_evicted + 1
                                end
                            end
                        end
                        local key = hit
                            and ('%s/%s/%d'):format(hit.cat, hit.area, hit.id)
                            or ('?' .. pname)
                        if not seen[key] then
                            seen[key] = true
                            n_prev_added = n_prev_added + 1
                            if hit then
                                e.prev[#e.prev + 1] = hit
                                if hit.cat == 'mission' then
                                    n_prev_mission = n_prev_mission + 1
                                    --[[ Named, not just counted. A mission
                                         prerequisite is the case this whole
                                         merge exists for and the one most
                                         likely to be wrong, so every one of
                                         them is printed for a human to read
                                         rather than hidden inside a total. ]]
                                    prev_added_rows[#prev_added_rows + 1] =
                                        ('    %s/%s/%d  needs  %s = %s/%s/%d')
                                        :format(e.cat, e.area, e.id, pname,
                                                hit.cat, hit.area, hit.id)
                                else
                                    n_prev_q = n_prev_q + 1
                                end
                            else
                                e.prev[#e.prev + 1] = {unresolved = pname}
                                n_prev_unres = n_prev_unres + 1
                            end
                        end
                    end
                end
            end
        end
        if n_prev_added > 0 then
            report(('  authored prerequisites merged  %d new (%d quest, %d '
                .. 'MISSION, %d unresolved)'):format(
                    n_prev_added, n_prev_q, n_prev_mission, n_prev_unres))
            if n_prev_evicted > 0 then
                report(('    ...and %d stale unresolved twin(s) evicted by a '
                    .. 'resolved name'):format(n_prev_evicted))
            end
            table.sort(prev_added_rows)
            for _, l in ipairs(prev_added_rows) do report(l) end
        end
        st.prev_from_authored = n_prev_added
        st.prev_mission = n_prev_mission

        --[[ Named, not just counted, for the same reason the merged
             prerequisites are: this collapses two rows into one and a silent
             collapse is indistinguishable from data going missing. ]]
        if n_dupes > 0 then
            report(('  duplicate quest identities merged  %d (%d rows -> %d)')
                :format(n_dupes, #order + n_dupes, #order))
            table.sort(dupe_rows)
            for _, l in ipairs(dupe_rows) do report(l) end
        end
        st.dupes_merged = n_dupes

        --[[ The tri-state, counted where it is decided. A false and an unknown
             draw the same marker, so nothing downstream can tell them apart and
             only this line can say whether the third state still exists. ]]
        do
            local rt, rf, rn = 0, 0, 0
            for _, e in ipairs(order) do
                if e.repeatable == true then rt = rt + 1
                elseif e.repeatable == false then rf = rf + 1
                else rn = rn + 1 end
            end
            report(('  repeatable  true=%d false=%d UNKNOWN=%d  '
                .. '(%d changed by the authored reading, %d of them gained a '
                .. 'repeat marker, %d lost one to a wiki `false`)')
                :format(rt, rf, rn, n_rep_changed, n_rep_gained, n_rep_demoted))
            st.repeat_true, st.repeat_false, st.repeat_unknown = rt, rf, rn
        end

        --[[ Fame, on the same terms and for the same reason: a gate with no
             LEVEL is inert at runtime (core/prereq.lua tests `entry.fame and
             entry.fame_lvl and entry.fame_lvl > 0`), so a region count alone
             would report gates that never fire as though they worked. Both
             numbers, always.

             The conflict counts are printed rather than counted away even
             though they cannot move: there is one reading of a page and nothing
             left to disagree with. They are kept because this line is the
             assertion -- a nonzero here would mean a second fame source has
             appeared from somewhere, and a report that quietly stops asserting
             a thing is how that gets in unnoticed. `regions` is the number to
             watch: it has no fallback behind it, so a fall in it is data
             actually going missing. ]]
        do
            local fr, fl = 0, 0
            for _, e in ipairs(order) do
                if e.fame then
                    fr = fr + 1
                    if e.fame_lvl and e.fame_lvl > 0 then fl = fl + 1 end
                end
            end
            report(('  fame  regions=%d of which %d carry a live level  '
                .. '(%d regions read off a page, %d of those with a threshold, '
                .. '%d region CONFLICTS, %d levels moved)')
                :format(fr, fl, n_fame_gained, n_fame_lvl_gained,
                        n_fame_conflict, n_fame_lvl_moved))
            for _, l in ipairs(fame_conflict_rows) do report(l) end
            st.fame_regions, st.fame_levels = fr, fl
            st.fame_conflicts = n_fame_conflict + n_fame_lvl_moved
        end

        --[[ Markers that moved, named rather than counted. Each of these was a
             by_zone entry drawing nothing in the world and is now an entity the
             player can actually see. A row appearing here that should NOT have
             moved is a wrong-destination marker, which is why the list prints
             in full and never truncates. ]]
        if #zone_over_rows > 0 then
            report(('  authored giver overrode a zone trigger on %d row(s):')
                :format(#zone_over_rows))
            for _, l in ipairs(zone_over_rows) do report(l) end
        end

        --[[ Ladders LOADED is not ladders APPLIED, and reporting only the first
             hides a real loss: a ladder for a quest that never becomes an entry
             is dropped without a word. Name the survivors here so a mismatch is
             loud rather than something a spot-check has to notice. ]]
        --[[ Both sides are scoped to the cat being emitted, and both must be.
             `ladders` holds quests and missions together, so an unscoped
             denominator lists every ladder of the other cat as lost and prints
             a one-cat `n_applied` over a whole-corpus total. `n_applied` is
             what the meta writer prints as `steps`, and the LADDER NOT APPLIED
             warning has to run for both halves: 33 bound mission pages have no
             index row. ]]
        local n_applied = 0
        do
            local applied = {}
            for _, e in ipairs(order) do
                if e.ladder then applied[e.cat .. '/' .. e.area .. '/' .. e.id] = true end
            end
            --[[ A ladder in an EXCLUDED area is not a lost ladder, and counting
                 it as one would bury the real losses this block exists to name.
                 The 95 coalition ladders are read, correct and deliberately not
                 built (see EXCLUDED_AREAS) -- so they leave the denominator
                 rather than joining the LOST list, and are reported as their
                 own line so the number is still visible. ]]
            local skip = EXCLUDED_AREAS[want_cat] or {}
            local mine, n_mine, n_excluded = {}, 0, 0
            for k in pairs(ladders) do
                if k:sub(1, #want_cat + 1) == want_cat .. '/' then
                    local area = k:match('^[^/]+/([^/]+)/')
                    if area and skip[area] then
                        n_excluded = n_excluded + 1
                    else
                        mine[k] = true
                        n_mine = n_mine + 1
                    end
                end
            end
            local lost = {}
            for k in pairs(mine) do
                if not applied[k] then lost[#lost + 1] = k end
            end
            table.sort(lost)
            for _ in pairs(applied) do n_applied = n_applied + 1 end
            if n_mine > 0 then
                report(('  %d of %d step ladder(s) applied'):format(n_applied, n_mine))
            end
            if n_excluded > 0 then
                report(('    ...and %d authored ladder(s) held back with an '
                    .. 'excluded area'):format(n_excluded))
            end
            for _, k in ipairs(lost) do
                report(('    LADDER NOT APPLIED: %s (no index entry for it)'):format(k))
            end
        end

        --[[ A real ladder puts NPCs on the map that the giver row never
             mentions -- Waking the Colossus visits Halver, Iron Eater and
             Kupipi in three different cities. Each needs its own by_npc row
             carrying ITS step index and ITS zone, or wanted_names never puts
             it in the scan set and no marker can appear there.

             Step 0 is the giver, emitted only when the giver is not already a
             step target, so an NPC never collects two rows for one quest.
             core/prereq.lua knows that rule and asks for the giver's OWN rung
             when he has one -- see giver_row() there. ]]
        --[[ Where has this name actually been seen?

             A step whose zone the page never stated is an honest nil, and
             replacing it with the GIVER's zone is a guess wearing the costume
             of a reading. 137 refs over 110 steps in 79 quests have no zone of
             their own, and 35 of them are contradicted by an explicit `z` on
             the same name elsewhere in the data: `zaldon` sits in 248 (Selbina)
             by five explicit refs, while the giver of his quest is in 247
             (Rabao).

             This table is the counter-evidence: every zone a name is stated to
             be in, gathered from steps that DID record one, across every
             ladder. Built before the refs are emitted so the decision below can
             consult the whole corpus, and a set rather than a list so nothing
             depends on iteration order. ]]
        local zone_evidence = {}
        do
            --[[ `only` is the single attested zone while n == 1; it exists so
                 the report line below can say what the data actually claimed,
                 rather than having to pick one out of a set with `pairs`. ]]
            local function saw(name, z)
                if not name or name == '' or type(z) ~= 'number' then return end
                local ev = zone_evidence[name]
                if not ev then ev = {n = 0}; zone_evidence[name] = ev end
                if not ev[z] then ev[z] = true; ev.n = ev.n + 1; ev.only = z end
            end
            for _, e in ipairs(order) do
                if e.ladder then
                    for _, s in ipairs(e.ladder.steps) do
                        saw(s.npc, s.z)
                        for _, mob in ipairs(s.mobs or {}) do saw(mob.name, s.z) end
                    end
                end
            end
        end

        --[[ The zone to put on one ref, decided per target, not per step. Only
             for a step with no recorded zone; a step that states one keeps it,
             which is what tells the two Exoroches and the two Kupipis apart.

             A monster never inherits the giver's town. 75 of the 137 zoneless
             refs are mob refs, and a mob does not spawn in the giver's city, so
             a stamp there guarantees that rung cannot draw. nil means "wherever
             you find it", which is how a mob is hunted anyway.

             An NPC is unstamped only when the data contradicts the stamp and
             the name is unambiguous (one attested zone, so one NPC). A blanket
             nil would be worse: a name attested in two zones would light up
             both, turning a missing marker into one that sends the player to
             the wrong city.

             Names with no evidence keep the giver's zone. Unfounded too, but
             not checkable offline, and nil would widen 92 refs worldwide. ]]
        local n_unstamped_mob, n_unstamped_npc, n_kept_ambiguous = 0, 0, 0
        local unstamped_rows = {}
        local function ref_zone(e, s, si, name, is_mob)
            if s.z ~= nil then return s.z end
            if is_mob then
                if type(e.zone) == 'number' then n_unstamped_mob = n_unstamped_mob + 1 end
                return nil
            end
            if type(e.zone) ~= 'number' then return e.zone end
            local ev = zone_evidence[name]
            if not ev then return e.zone end          -- unfounded, but unfalsified
            if ev[e.zone] then return e.zone end      -- the data agrees: keep it
            if ev.n > 1 then                          -- two NPCs share this name
                n_kept_ambiguous = n_kept_ambiguous + 1
                return e.zone
            end
            n_unstamped_npc = n_unstamped_npc + 1
            unstamped_rows[#unstamped_rows + 1] = ('    zone stamp dropped: %s '
                .. 'step %d "%s" was stamped %d, stated elsewhere as %d')
                :format(e.cat .. '/' .. e.area .. '/' .. e.id, si, name,
                        e.zone, ev.only)
            return nil
        end

        local extra = {}
        local widened_rows = {}
        local function add_ref(key, ref)
            if not key or key == '' then return end
            extra[key] = extra[key] or {}
            extra[key][#extra[key] + 1] = ref
        end
        for i, e in ipairs(order) do
            local L = e.ladder
            if L then
                --[[ The giver the RECORD will ship, by the same fallback chain
                     the `snpc=` field uses below. One expression, read twice,
                     so the two cannot drift apart: a record naming a giver with
                     no row behind it is a //qm why answer with no marker. ]]
                local snpc = giver_of(e)
                --[[ PER KEY, not once for the whole row.
                     A single flag tested against `snpc` is right while the
                     giver is one name and wrong the moment it is a set: for
                     "Any Bastok Gate Guard" the ladder's step 1 is at Argus,
                     and one flag then suppresses the s=0 row at Cleades,
                     Rashid and Malduc too -- NPCs that step never mentions.
                     Identical for a single-key giver, which is every row but
                     the gate guards. ]]
                local step_target = {}
                for si, s in ipairs(L.steps) do
                    if s.npc and s.npc ~= '' then
                        add_ref(s.npc, ('{q=%d,s=%d,z=%s}'):format(
                            i, si, lua_val(ref_zone(e, s, si, s.npc, false))))
                        step_target[s.npc] = true
                    end
                    --[[ Monsters are marker targets too, and get_mob_list()
                         already returns them -- the scan simply never had a
                         reason to look. `m` carries the ROLE, which picks the
                         glyph: a sword to kill it, a bag because it drops what
                         this step needs. ]]
                    for _, mob in ipairs(s.mobs or {}) do
                        add_ref(mob.name, ('{q=%d,s=%d,z=%s,m=%s}'):format(
                            i, si, lua_val(ref_zone(e, s, si, mob.name, true)),
                            lua_str(mob.role or 'kill')))
                    end
                end
                if snpc ~= '' then
                    for _, k in ipairs(giver_keys(e)) do
                        if not step_target[k] then
                            add_ref(k, ('{q=%d,s=0,z=%s}'):format(
                                i, lua_val(e.zone)))
                            --[[ Named, not merely counted, like every other
                                 substitution in this build: each of these is a
                                 START marker appearing on an NPC that carried
                                 none, and a human has to be able to check that
                                 the NPC really is an alternative giver rather
                                 than a mid-quest contact the union block
                                 happened to add. ]]
                            if k ~= snpc then
                                widened_rows[#widened_rows + 1] =
                                    ('    %s/%s/%d  giver row also at %q '
                                     .. '(snpc=%q)'):format(
                                        e.cat, e.area, e.id, k, snpc)
                                st.giver_row_widened =
                                    (st.giver_row_widened or 0) + 1
                            end
                        end
                    end
                end
            end
        end

        --[[ Named, not merely counted, for the same reason the merged
             prerequisites are: an unstamped zone widens where a marker may
             draw, and a silent widening is indistinguishable from data going
             missing. ]]
        if #widened_rows > 0 then
            --[[ Do not word this as "already indexed under". That is only true
                 of the SCAN set: 126 of these 164 keys are not in the emitted
                 by_npc at all, and six of the guards are new keys entirely. ]]
            report(('  giver row emitted at %d additional key(s) -- the other '
                .. 'NPCs of a giver the page stated as a ROLE, which the s=0 '
                .. 'ref never reached:'):format(#widened_rows))
            table.sort(widened_rows)
            for _, l in ipairs(widened_rows) do report(l) end
        end

        if n_unstamped_mob + n_unstamped_npc > 0 then
            report(('  giver-zone stamps dropped  %d (%d monster ref(s), %d '
                .. 'contradicted NPC ref(s)); %d kept on names attested in more '
                .. 'than one zone'):format(n_unstamped_mob + n_unstamped_npc,
                    n_unstamped_mob, n_unstamped_npc, n_kept_ambiguous))
            table.sort(unstamped_rows)
            for _, l in ipairs(unstamped_rows) do report(l) end
        end

        --[[ by_npc, BUILT BEFORE IT IS COUNTED and before the header claims a
             number for it. Rows come from two places: the giver row a
             ladderless quest gets, and the per-step rows a real ladder adds. A
             quest WITH a ladder emits only the ladder's rows -- its giver is
             already in there as a step or as the explicit s=0 row -- or the
             giver would be marked twice.

             `sorted_keys`, not `pairs`, for the file order; and the list is
             materialised here rather than recomputed at write time so the
             header and the body can never describe different content. ]]
        local all_keys = {}
        for npc in pairs(kept) do all_keys[npc] = true end
        for npc in pairs(extra) do all_keys[npc] = true end
        local npc_names, npc_refs = sorted_keys(all_keys), {}
        local keys, rows = 0, 0
        for _, npc in ipairs(npc_names) do
            local refs = {}
            for _, e in ipairs(kept[npc] or {}) do
                if not e.ladder then
                    refs[#refs + 1] = ('{q=%d,s=1,z=%s}')
                        :format(qindex[e], lua_val(e.zone))
                end
            end
            for _, r in ipairs(extra[npc] or {}) do refs[#refs + 1] = r end
            if #refs > 0 then
                npc_refs[npc] = refs
                keys = keys + 1
                rows = rows + #refs
            end
        end
        --[[ Records EMITTED, which is what the reader of this file can count.
             `all_entries` counts entries CREATED and the two differ in both
             directions -- see the header note above. ]]
        local indexed = #order

        f:write(('-- questmarks %s -- GENERATED FILE, DO NOT EDIT BY HAND.\n'):format(title))
        f:write('-- Regenerate: luajit tools/build_index.lua   (or //qm rebuild in game)\n')
        f:write('--\n')
        f:write(note)
        f:write('--\n')
        --[[ ...and what was left out of it. Printing `ALL` flat on a file
             holding 0 of 96 coalition rows tells a reader the assignments have
             no data at all, and a maintainer diffing two indexes sees 96 rows
             vanish under an unchanged header. The generated file has to say
             what it is.

             `all_areas` keeps its meaning -- the SCOPE SWITCH really is
             all-areas, //qm diag prints it and //qm rebuild reads it back -- so
             the exclusion is named separately rather than by lying about the
             switch. ]]
        local excl = {}
        for _, xcat in ipairs(sorted_keys(EXCLUDED_AREAS)) do
            for _, xarea in ipairs(sorted_keys(EXCLUDED_AREAS[xcat])) do
                excl[#excl + 1] = xcat .. '/' .. xarea
            end
        end
        f:write(('-- areas: %s%s\n'):format(
            opts.all_areas and 'ALL' or 'v1 (nations + Jeuno)',
            #excl > 0 and (', EXCLUDING ' .. table.concat(excl, ' ')
                           .. ' -- out of scope, see EXCLUDED_AREAS in '
                           .. 'tools/build_index.lua') or ''))
        f:write(('-- indexed=%d  npc keys=%d  rows=%d\n'):format(indexed, keys, rows))
        --[[ No `names` table. The complete id -> name ladder lives in
             data/dat_names.lua, which is the client's own and does not depend
             on a quest's giver having resolved. ]]
        f:write('-- names live in data/dat_names.lua, complete and client-derived.\n\n')

        f:write('local Q = {}\n\n')
        for i, e in ipairs(order) do
            local parts = {
                'cat=' .. lua_str(e.cat),
                'area=' .. lua_str(e.area),
                'id=' .. lua_val(e.id),
                'repeatable=' .. lua_val(e.repeatable),
                'fame=' .. lua_val(e.fame),
                'fame_lvl=' .. lua_val(e.fame_lvl),
            }
            if e.reqs_partial then parts[#parts + 1] = 'reqs_partial=true' end
            if #e.prev > 0 then
                local ps = {}
                for _, p in ipairs(e.prev) do
                    if p.unresolved then
                        ps[#ps + 1] = '{unresolved=' .. lua_str(p.unresolved) .. '}'
                    else
                        ps[#ps + 1] = ('{cat=%s,area=%s,id=%s}'):format(
                            lua_str(p.cat), lua_str(p.area), lua_val(p.id))
                    end
                end
                parts[#parts + 1] = 'prev={' .. table.concat(ps, ',') .. '}'
            end
            local reqs_src = 'nil'
            if #e.reqs > 0 then
                local rs = {}
                for _, r in ipairs(e.reqs) do
                    rs[#rs + 1] = ('{kind=%s,rid=%d,n=%d}'):format(
                        lua_str(r.kind), r.rid, r.n)
                end
                reqs_src = '{' .. table.concat(rs, ',') .. '}'
                parts[#parts + 1] = 'reqs=' .. reqs_src
            end
            --[[ `snpc` is the quest GIVER, kept beside the ladder rather than
                 inside it. It is the fallback for a quest whose every step
                 target is a '???' or a mob -- without it such a quest would go
                 from a grey "?" on its giver to no marker at all. Here it is
                 always step 1's target too, because the synthetic ladder IS
                 the giver. ]]
            local L = e.ladder
            --[[ Through giver_of(), which the by_npc ref emitter reads too --
                 the two used to compute this independently and disagreed twice,
                 leaving a record naming a giver no row existed for. ]]
            parts[#parts + 1] = 'snpc=' .. lua_str(giver_of(e))
            parts[#parts + 1] = 'conf=' .. lua_val((L and L.conf) or 1)
            if L then
                if L.lvl then parts[#parts + 1] = 'lvl=' .. lua_val(L.lvl) end
                if L.jobs and #L.jobs > 0 then
                    local js = {}
                    for _, j in ipairs(L.jobs) do js[#js + 1] = lua_str(j) end
                    parts[#parts + 1] = 'jobs={' .. table.concat(js, ',') .. '}'
                end
                --[[ The craft-skill gate, carried through verbatim from
                     quest_steps.lua. `sk` is a res/skills.lua id, `rank` a
                     res/synth_ranks.lua id and `lvl` a raw skill level; `nm`
                     and `rk` are the display names, resolved at build time
                     because core/prereq.lua may not read res/ at runtime.

                     `~= nil` throughout: rank 0 is Amateur and level 0 is a
                     legal threshold, so a truthiness test would drop the two
                     values most likely to expose a bug. ]]
                if L.craft and #L.craft > 0 then
                    local cs = {}
                    for _, c in ipairs(L.craft) do
                        local f = {'sk=' .. lua_val(c.sk)}
                        if c.rank ~= nil then f[#f + 1] = 'rank=' .. lua_val(c.rank) end
                        if c.lvl ~= nil then f[#f + 1] = 'lvl=' .. lua_val(c.lvl) end
                        if c.pts ~= nil then f[#f + 1] = 'pts=' .. lua_val(c.pts) end
                        if c.nm then f[#f + 1] = 'nm=' .. lua_str(c.nm) end
                        if c.rk then f[#f + 1] = 'rk=' .. lua_str(c.rk) end
                        cs[#cs + 1] = '{' .. table.concat(f, ',') .. '}'
                    end
                    parts[#parts + 1] = 'craft={' .. table.concat(cs, ',') .. '}'
                end
                local ss = {}
                for _, s in ipairs(L.steps) do
                    local sp = {'k=' .. lua_str(s.k)}
                    if s.npc then sp[#sp + 1] = 'npc=' .. lua_str(s.npc) end
                    if s.z ~= nil then sp[#sp + 1] = 'z=' .. lua_val(s.z) end
                    if s.g then sp[#sp + 1] = 'g=' .. lua_str(s.g) end
                    if s.grp then sp[#sp + 1] = 'grp=' .. lua_str(s.grp) end
                    if s.optional then sp[#sp + 1] = 'optional=true' end
                    --[[ The hedge has to survive the copy.
                         `reqs_partial` says "this step had a requirement we
                         could not resolve, so the list you are reading is
                         short". core/prereq.lua reads it to refuse a confident
                         verdict on an incomplete list, which is the hedge
                         that keeps an unknown from reading as a definite no.
                         107 steps carry it in quest_steps.lua. One field, and
                         it is the difference between "you are not ready" and
                         "we do not know what this needs". ]]
                    if s.reqs_partial then sp[#sp + 1] = 'reqs_partial=true' end
                    for _, fld in ipairs({'reqs', 'reqs_alt', 'ev', 'ev_alt'}) do
                        if s[fld] then
                            local rs = {}
                            for _, r in ipairs(s[fld]) do
                                --[[ `eq` must survive the copy. It is the only
                                     per-requirement flag, it makes the check
                                     STRICTER (equipped, not merely carried),
                                     and dropping it here would silently undo
                                     the pipeline's work with the index still
                                     looking correct. ]]
                                --[[ ...and an `eq` requirement carries its
                                     NAME, which no other requirement does.

                                     It is the only one that greys a marker on
                                     sight, so "you need a Vorpal Sword
                                     equipped" has to be sayable -- "requirement
                                     17742" is not an explanation. Resolved here
                                     because res/items.lua is 5 MB and 23,512
                                     rows: loading it in game to caption twenty
                                     strings would be absurd, and inventing an
                                     unverified `get_item` call worse. Bounded
                                     to exactly the rows that carry `eq`. ]]
                                local nm = ''
                                if r.eq and r.kind == 'item' then
                                    local it = items and items[r.rid]
                                    local en = type(it) == 'table' and it.en or nil
                                    if en then nm = ',nm=' .. lua_str(en) end
                                end
                                rs[#rs + 1] = ('{kind=%s,rid=%d,n=%d%s%s}')
                                    :format(lua_str(r.kind), r.rid, r.n or 1,
                                            r.eq and ',eq=true' or '', nm)
                            end
                            sp[#sp + 1] = fld .. '={' .. table.concat(rs, ',') .. '}'
                        end
                    end
                    if s.mobs then
                        --[[ HOW MANY, not just which. `n` is the count the page
                             stated; 667 of the 893 mob records in
                             quest_steps.lua carry one.

                             It is DISPLAYED, so dropping it is worse than
                             merely lossy. kills.progress computes
                             `want = m.n or 1` and clamps each monster at
                             `want`, so a step wanting five of one monster with
                             no `n` reports a denominator of one -- and the
                             clamp then pins the numerator at one too, leaving
                             `//qm why` printing "beaten 1 this session"
                             however many you killed. ]]
                        local ms = {}
                        for _, m in ipairs(s.mobs) do
                            ms[#ms + 1] = ('{name=%s,role=%s%s}')
                                :format(lua_str(m.name), lua_str(m.role or 'kill'),
                                        m.n and (',n=' .. lua_val(m.n)) or '')
                        end
                        sp[#sp + 1] = 'mobs={' .. table.concat(ms, ',') .. '}'
                    end
                    ss[#ss + 1] = '{' .. table.concat(sp, ',') .. '}'
                end
                parts[#parts + 1] = 'steps={' .. table.concat(ss, ',') .. '}'
            else
                -- The synthetic ladder: exactly one step, at the giver.
                parts[#parts + 1] = ('steps={{k=\'talk\',npc=%s,z=%s%s}}'):format(
                    lua_str(e.npc_key or ''), lua_val(e.zone),
                    reqs_src ~= 'nil' and (',reqs=' .. reqs_src) or '')
            end
            f:write(('Q[%d] = {%s}\n'):format(i, table.concat(parts, ',')))
        end
        f:write('\n')

        f:write('return {\n')
        f:write('  meta = {\n')
        f:write('    version = 2,\n')
        f:write(('    cat = %s,\n'):format(lua_str(want_cat)))
        f:write(('    all_areas = %s,\n'):format(opts.all_areas and 'true' or 'false'))
        f:write(('    indexed = %d,\n'):format(indexed))
        --[[ `steps` is the COUNT of rows carrying a real first-hand ladder, not
             a boolean. 0 says "synthetic ladders only" just as honestly, and a
             drop between builds is visible. ]]
        f:write(('    steps = %d,   -- rows carrying a real, first-hand ladder\n')
                :format(n_applied))
        f:write("    source = 'BG Wiki CC BY-NC-SA 3.0, first-hand from "
                .. "bgwiki-rest-cache; identity from the client DAT table',\n")
        f:write('  },\n')
        f:write('  quests = Q,\n')

        --[[ Written from the list built above the header, not rebuilt here. The
             header's `npc keys` and `rows` count exactly these lines. ]]
        f:write('  by_npc = {\n')
        for _, npc in ipairs(npc_names) do
            local refs = npc_refs[npc]
            if refs then
                f:write(('    [%s] = {%s},\n'):format(lua_str(npc), table.concat(refs, ',')))
            end
        end
        f:write('  },\n')

        --[[ References, not copies -- the same shape by_npc uses, so a
             zone-triggered entry carries its prerequisites, fame gate, level
             and job just like every other one. Not a bare identity triple; see
             the numbering block above. ]]
        f:write('  by_zone = {\n')
        for _, z in ipairs(sorted_keys(kept_z)) do
            local parts = {}
            for _, e in ipairs(kept_z[z]) do
                parts[#parts + 1] = ('{q=%d}'):format(qindex[e])
            end
            f:write(('    [%d] = {%s},\n'):format(z, table.concat(parts, ',')))
        end
        f:write('  },\n')
        f:write('}\n')
        f:close()
        return {indexed = indexed, keys = keys, rows = rows, zones = zones}
    end

    --[[ Anyone reading the generated file needs to know which half of a row
         came from where before they trust it. Keep this note in step with the
         emitter. ]]
    local QUEST_NOTE =
        '-- Quest metadata derived from BG Wiki (https://www.bg-wiki.com),\n'
     .. '-- licensed CC BY-NC-SA 3.0, from TWO sources merged here:\n'
     .. '--\n'
     .. '--   steps, per-step targets/zones/grid refs/item ids, job and level\n'
     .. '--   gates, confidence tier   -- FIRST-HAND from the page cache in\n'
     .. '--                               bgwiki-rest-cache/, read by tools/pipeline/\n'
     .. '--   fame (region and level)  -- FIRST-HAND from the page cache too.\n'
     .. '--   repeatable, prerequisites, quest-level item requirements, and the\n'
     .. '--   start NPC\n'
     .. '--                            -- FIRST-HAND. Each row\'s own ladder is the\n'
     .. '--                               only source; the per-field rules are at\n'
     .. '--                               merge_repeatable and the prerequisite\n'
     .. '--                               union in tools/build_index.lua.\n'
     .. '--   identity (category, area, id)\n'
     .. '--                            -- the CLIENT\'S OWN DAT name table, via\n'
     .. '--                               data/dat_names.lua. Not wiki data: this\n'
     .. '--                               build walks the DAT id list to decide\n'
     .. '--                               which quests exist. Game content, covered\n'
     .. '--                               by the SQUARE ENIX notice rather than CC.\n'
     .. '--\n'
     .. '-- No other addon is read, at build time or at run time.\n'
     .. '-- No wiki prose is carried: the emitter drops every `note`. See NOTICE.\n'
    local MISSION_NOTE =
        '-- Mission metadata derived from BG Wiki (https://www.bg-wiki.com),\n'
     .. '-- licensed CC BY-NC-SA 3.0. See NOTICE.\n'
     .. '--\n'
     .. '--   identity (category, area, id)  -- the CLIENT\'S OWN DAT name table via\n'
     .. '--                                     data/dat_names.lua. Game content.\n'
     .. '--   step ladders, per-step targets/zones/grid refs, start NPC,\n'
     .. '--   repeatable, prerequisites\n'
     .. '--                     -- FIRST-HAND from bgwiki-rest-cache/, by way of a\n'
     .. '--                        scrape of Category:Missions and the authored\n'
     .. '--                        Campaign Ops. Every row carries a real ladder.\n'
     .. '--\n'
     .. '-- No other addon is read, at build time or at run time.\n'
     .. '--\n'
     .. '-- This file is the ONLY part of the index //qm rebuild touches.\n'

    local index_path   = outdir .. 'data/quest_index.lua'
    local mission_path = outdir .. 'data/mission_index.lua'

    local qs, qerr = emit(index_path, 'quest', 'quest index', QUEST_NOTE)
    if not qs then return nil, qerr end
    local ms, merr = emit(mission_path, 'mission', 'mission index', MISSION_NOTE)
    if not ms then return nil, merr end

    local um_path = outdir .. 'tools/unmatched.txt'
    local uf = io.open(um_path, 'wb')   -- LF on every platform, see emit()
    if uf then
        uf:write('# start_npc values that produced no usable NPC key.\n')
        uf:write('# columns: cat/area/id <TAB> kind <TAB> raw value\n')
        uf:write('# Curate real NPCs into data/npc_overrides.lua.\n\n')
        table.sort(unmatched)
        for _, l in ipairs(unmatched) do uf:write(l .. '\n') end
        uf:close()
    end

    if #era_rows > 0 then
        report(('  giver zones moved to their past-era twin  %d'):format(#era_rows))
        table.sort(era_rows)
        for _, l in ipairs(era_rows) do report(l) end
    end

    report('')
    report(('  wrote %s  (%d quests, %d npc keys, %d rows)')
        :format(index_path, qs.indexed, qs.keys, qs.rows))
    report(('  wrote %s  (%d missions, %d npc keys, %d rows)')
        :format(mission_path, ms.indexed, ms.keys, ms.rows))
    report(('  wrote %s  (%d entries)'):format(um_path, #unmatched))
    for _, k in ipairs({'indexed', 'zone_started', 'no_npc',
                        --[[ `no_source` is the subset of `no_npc` with no
                             record AND no ladder -- a DAT id nothing on disk
                             describes, as opposed to a quest we know about but
                             cannot place. Every counter this file sets belongs
                             in this list; one that is set and never printed is
                             invisible. ]]
                        'no_source', 'generic', 'object',
                        'zone_trigger', 'authored_zone_trigger', 'giver_over_zone',
                        'none', 'ambiguous_dropped',
                        'zone_unresolved', 'prev_unresolved',
                        --[[ No `req_dropped` here. The requirement list comes
                             from the authored ladder, where stage C has already
                             resolved every name to an id, so nothing can fail
                             to resolve at this point -- and a counter that can
                             only print 0 reads like a clean bill of health. ]]
                        'reqs_partial',
                        'rescued_start', 'rescued_by_step',
                        'zone_from_start', 'rescued_by_ladder',
                        'giver_key_added',
                        --[[ `giver_key_added` widens the SCAN set,
                             `giver_row_widened` the GIVER row; they answer
                             different questions and only the second can put a
                             "start here" marker on somebody new.

                             ACCUMULATES ACROSS BOTH emit() calls, so this total
                             is quests plus missions while each block's own line
                             above prints its half. Every one of them is a gate
                             guard today. ]]
                        'giver_row_widened',
                        'prev_relaxed', 'era_zone_fixed',
                        --[[ The identity-binding invariants. Two of these are
                             the numbers the binding rule calls load-bearing, so
                             they belong in the run's own summary rather than
                             only in a comment. ]]
                        'id_kept', 'id_rebound', 'id_unbound', 'id_collided'}) do
        report(('  %-16s %d'):format(k, st[k] or 0))
    end
    report(('  %-16s %d'):format('npc keys', count(by_npc)))

    st.npc_keys = count(by_npc)
    return st
end

-- offline entry point -- only when actually invoked as a script
if standalone and run_as_script then
    local argv = {...}
    local all_areas, root = false, nil
    for i, a in ipairs(argv) do
        if a == '--all-areas' then
            all_areas = true
        elseif a == '--root' then
            root = argv[i + 1]
        elseif a == '--help' or a == '-h' then
            print('usage: luajit tools/build_index.lua [--all-areas] '
                .. '[--root <windower dir>]')
            os.exit(0)
        end
    end
    local st, err = M.build{all_areas = all_areas, root = root}
    if not st then
        io.stderr:write('ERROR: ' .. tostring(err) .. '\n')
        os.exit(1)
    end
end

return M
