--[[
check.lua -- parse every Lua file here, and catch what parsing cannot.

    luajit tools/check.lua [dir]

Windower ships a patched Lua that allows `'str':method()` without parens.
Stock LuaJIT rejects it, so avoid the shorthand here or this check stops
meaning anything. Point this at a wider tree and files that use it will
fail here; that is expected.

Second pass: accidental globals. A `local` declared below a function that
assigns the same name does not scope it, so the assignment becomes a global
write while readers keep using the local. Reading misses it; a global write
compiles to `GSET`, so the check is "no GSET" plus a short allowlist.
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
local root = (...) or require('tools/lib/root')
root = root:gsub('\\', '/'):gsub('/*$', '')

-- Portable-enough directory walk for Windows.
local function list_lua(dir)
    local out = {}
    local cmd = 'dir /b /s "' .. dir:gsub('/', '\\') .. '\\*.lua" 2>nul'
    local p = io.popen(cmd)
    if not p then return out end
    for line in p:lines() do
        line = line:gsub('%s+$', '')
        if line ~= '' then out[#out + 1] = line:gsub('\\', '/') end
    end
    p:close()
    table.sort(out)
    return out
end

local files = list_lua(root)
if #files == 0 then
    print('no .lua files found under ' .. root)
    os.exit(1)
end

local bad = 0
local parsed = {}          -- the global scan below only trusts files that parsed here
for _, f in ipairs(files) do
    local rel = f:sub(#root + 2)
    local chunk, e = loadfile(f)
    if chunk then
        parsed[f] = true
        print(string.format('[ OK ] %s', rel))
    else
        bad = bad + 1
        print(string.format('[FAIL] %s', rel))
        print(string.format('       %s', tostring(e)))
    end
end

--[[ `_addon` is Windower's own addon-descriptor table and is the one global an
     addon is expected to create. Nothing here writes it today; it is listed so
     that doing so later is a deliberate edit rather than a build failure. ]]
local GLOBAL_OK = {_addon = true}

--[[ Only the SHIPPED tree. tools/ runs offline, sets up package.path and
     otherwise behaves like a script rather than like an addon. ]]
local function shipped(rel)
    return rel == 'questmarks.lua'
        or rel:find('^core/') ~= nil
        or rel:find('^render/') ~= nil
end

--[[ Proving the scan below actually ran.

     The scan shells out to `luajit -bl` and looks for GSET. A shell-out that
     never runs prints nothing, and nothing looks exactly like a clean file.
     Two requirements, both needed:

     (1) Find an interpreter without touching PATH. `arg[-1]` is the binary
         running this script, so it exists by construction. A bare `luajit`
         stays as a fallback.

     (2) Prove the subprocess produced bytecode. `luajit -bl` prints one
         `-- BYTECODE -- name:first-last` header per prototype, so any file
         `loadfile` accepted must yield one. Zero headers is a failure, not a
         pass: cmd.exe silently rejects `"C:\luajit.exe" -bl "C:\file.lua"`
         unless the whole command line gets a second pair of quotes. ]]

local BYTECODE_MARK = '-- BYTECODE --'

local function bytecode_of(exe, file)
    -- The doubled outer quotes are required, not decorative: see (2) above.
    local cmd = string.format('""%s" -bl "%s" 2>&1"',
        (exe:gsub('/', '\\')), (file:gsub('/', '\\')))
    local p = io.popen(cmd)
    if not p then return nil, 'io.popen refused the command' end
    local out = p:read('*a') or ''
    p:close()
    if not out:find(BYTECODE_MARK, 1, true) then
        return nil, (out:gsub('%s+$', ''))
    end
    return out
end

-- A shipped file that parsed, used to prove an interpreter works before the
-- scan trusts it. Every shipped file parses in a healthy tree; if none did,
-- `bad` is already non-zero and the guard reports that it could not run.
local probe
for _, f in ipairs(files) do
    if shipped(f:sub(#root + 2)) and parsed[f] then probe = f break end
end

local interp, interp_err
do
    local tried = {}
    local candidates = {}
    if arg and arg[-1] then candidates[#candidates + 1] = arg[-1] end
    candidates[#candidates + 1] = 'luajit'
    for _, cand in ipairs(candidates) do
        if probe then
            local ok, why = bytecode_of(cand, probe)
            if ok then interp = cand break end
            tried[#tried + 1] = string.format('%s -> %s', cand, why ~= '' and why or 'no output')
        end
    end
    interp_err = table.concat(tried, '\n              ')
end

local globals = {}
local unscanned = {}
local scanned_count = 0
if interp then
    for _, f in ipairs(files) do
        local rel = f:sub(#root + 2)
        if shipped(rel) and parsed[f] then
            local out, why = bytecode_of(interp, f)
            if not out then
                -- Ran for the probe, produced nothing here: report it, never
                -- let it read as a clean file.
                unscanned[#unscanned + 1] = rel .. ' produced no bytecode (' ..
                    (why ~= '' and why or 'no output') .. ')'
            else
                scanned_count = scanned_count + 1
                for line in out:gmatch('[^\r\n]+') do
                    local name = line:match('GSET.-;%s*"([^"]+)"')
                    if name and not GLOBAL_OK[name] then
                        globals[#globals + 1] = rel .. ' writes global ' .. name
                    end
                end
            end
        end
    end
end

if not interp then
    print('')
    print('[FAIL] the accidental-global guard could not run -- rule 7 is UNCHECKED')
    print('       no interpreter produced bytecode for ' ..
          (probe and probe:sub(#root + 2) or '(no shipped file parsed)'))
    if interp_err ~= '' then print('       tried: ' .. interp_err) end
    print('       this is a failure, not a pass: a guard that cannot run must')
    print('       never report [ OK ]. See the note above this line in source.')
    bad = bad + 1
elseif #globals > 0 or #unscanned > 0 then
    print('')
    for _, g in ipairs(globals) do
        print(string.format('[FAIL] %s', g))
        bad = bad + 1
    end
    for _, u in ipairs(unscanned) do
        print(string.format('[FAIL] %s', u))
        bad = bad + 1
    end
    if #globals > 0 then
        print('       a `local` declared BELOW an assignment does not scope it --')
        print('       move the declaration above every function that writes it.')
    end
else
    print(string.format('\n[ OK ] no shipped file writes a global (%s scanned via %s)',
        tostring(scanned_count), interp))
end

print(string.format('\n%d file(s), %d failed', #files, bad))
os.exit(bad == 0 and 0 or 1)
