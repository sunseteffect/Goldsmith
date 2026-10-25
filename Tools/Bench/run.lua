-- Runs every scenario (or those whose name contains a word), each in its
-- own Lua process so none sees another's changes, and prints a summary.
--
--   lua Tools\Bench\run.lua              every scenario, failures in full
--   lua Tools\Bench\run.lua mail         only scenarios with "mail" in the name
--   lua Tools\Bench\run.lua -v           every check, passes too
--
-- Exits 1 if any scenario failed.

local dir = arg[0]:match("^(.*[/\\])") or ".\\"
dir = dir:gsub("/", "\\")
local lua = os.getenv("LUA") or "C:\\Program Files (x86)\\Lua\\5.1\\lua.exe"

local verbose, filter = false, nil
for _, a in ipairs(arg) do
    if a == "-v" then verbose = true else filter = a:lower() end
end

local names = {}
local list = io.popen('dir /b /o:n "' .. dir .. 'scenarios\\*.lua" 2>nul')
for name in list:lines() do
    if not filter or name:lower():find(filter, 1, true) then table.insert(names, name) end
end
list:close()
if #names == 0 then
    print("No scenarios" .. (filter and (" matching " .. filter) or "") .. " in " .. dir .. "scenarios")
    os.exit(1)
end

local benchDir = dir:gsub("\\", "/")
local failedNames, totalPass, totalFail = {}, 0, 0
local started = os.clock()
for _, name in ipairs(names) do
    local cmd = string.format('""%s" -e "BENCH_DIR=[[%s]]" "%sscenarios\\%s" 2>&1"', lua, benchDir, dir, name)
    local p = io.popen(cmd)
    local out = p:read("*a")
    p:close()
    local result = out:match("RESULT (%u+) [^\n]*")
    local pass, fail = out:match("RESULT %u+ [^:]+: (%d+) passed, (%d+) failed")
    totalPass = totalPass + (tonumber(pass) or 0)
    totalFail = totalFail + (tonumber(fail) or 0)
    if result == "PASS" then
        print(string.format("PASS  %-40s %s checks", name, pass))
        if verbose then io.write(out) end
    else
        if not result then totalFail = totalFail + 1 end
        table.insert(failedNames, name)
        print(string.format("FAIL  %-40s %s", name, result and (fail .. " of " .. (pass + fail) .. " checks failed") or "crashed"))
        -- Everything but the passes, so the failure reads in context
        for line in out:gmatch("[^\n]+") do
            if verbose or not line:find("^  PASS ") then print("      " .. line) end
        end
    end
end
print(string.rep("-", 60))
print(string.format("%d scenarios, %d checks passed, %d failed (%.1f s)", #names, totalPass, totalFail, os.clock() - started))
if #failedNames > 0 then
    print("Failed: " .. table.concat(failedNames, ", "))
    os.exit(1)
end
