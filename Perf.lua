local addon = _G.Goldsmith or {}

-- Performance check (/gsm perf)
--
-- Times the work behind each tab and the Crafts list, twice each: cold
-- (caches emptied, as after prices or bags change) and warm (cached, as when
-- switching tabs). Each runs as it does in normal use, spread over frames
-- (addon:RunWork), one step after another, so the check itself never
-- freezes the game. For each it records the total time and the longest
-- single frame (what players feel). Prints the results with Goldsmith's
-- memory and how much data there is, and keeps the last PERF_RUNS in
-- GoldsmithDB.perfRuns so they can be read from the saved file after
-- logging out. Meant for a big fake account (Tools\Stress-Swap.ps1) as well
-- as real ones.
local PERF_RUNS = 10
-- One frame at 60 fps; longer than this is a visible hitch
local FRAME_MS = 16
-- A step that hasn't finished by then is recorded as stuck
local STEP_TIMEOUT = 60
local TABS = { "overview", "crafts", "queue", "items", "history", "characters" }

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function MemoryKB()
    if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
        UpdateAddOnMemoryUsage()
        return GetAddOnMemoryUsage("Goldsmith")
    end
end

local function Verdict(s)
    if math.max(s.coldLongest or 0, s.warmLongest or 0) > FRAME_MS then return "|cffff8040stutters|r" end
    return "|cff40ff40ok|r"
end

local function Report(run)
    print("|cffffd040Goldsmith performance|r" .. (run.stressTest and " (fake test data)" or ""))
    for _, s in ipairs(run.steps) do
        if s.error then
            print(string.format("  %s: |cffff4040%s|r", s.label, s.error))
        else
            print(string.format("  %s: cold %d ms (longest frame %d ms), warm %d ms (%d ms), %s",
                s.label, s.cold, s.coldLongest, s.warm, s.warmLongest, Verdict(s)))
        end
    end
    local d = run.data
    print(string.format("  Data: %d characters, %d recipes, %d transactions, %d price history points",
        d.characters, d.recipes, d.entries, d.priceHistory))
    print(string.format("  Memory: %s   Loading at login: %s",
        run.memoryKB and string.format("%.1f MB", run.memoryKB / 1024) or "unknown",
        run.loginMs and string.format("%d ms", run.loginMs) or "unknown"))
    print(string.format("  Cold = after data changes, warm = switching tabs; the total is spread over frames. A frame over %d ms stutters.", FRAME_MS))
    local longest = {}
    for label, ms in pairs(run.longestFrame) do
        local where = run.longestWhere[label]
        table.insert(longest, string.format("%s %d ms%s", label, ms,
            (ms > FRAME_MS and where and where ~= "") and (" (" .. where .. ")") or ""))
    end
    table.sort(longest)
    print("  Longest frame of loading this session (what you feel): "
        .. (#longest > 0 and table.concat(longest, ", ") or "none yet, open some tabs first"))
end

local running = false

local function Run()
    local ui = GoldsmithDB.ui2
    local wasShown, oldTab = addon.window:IsShown(), ui.tab
    local run = { time = time(), steps = {}, stressTest = GoldsmithDB.stressTest and true or nil }
    -- Saved before anything is timed, so a step that errors still leaves
    -- the steps before it (and the error) in the saved file
    GoldsmithDB.perfRuns = GoldsmithDB.perfRuns or {}
    table.insert(GoldsmithDB.perfRuns, run)
    while #GoldsmithDB.perfRuns > PERF_RUNS do table.remove(GoldsmithDB.perfRuns, 1) end

    -- Each step: start(done) runs it once and calls done(work) when it's
    -- finished (work.totalMs, work.longestMs)
    local steps = {}
    for _, key in ipairs(TABS) do
        table.insert(steps, { label = key:sub(1, 1):upper() .. key:sub(2) .. " tab", start = function(done)
            addon.OnTabRefreshed = function(tab, work)
                if tab == key then done(work) end
            end
            addon:ShowTab(key)
        end })
    end
    local function DataStep(label, fn)
        table.insert(steps, { label = label, start = function(done)
            addon:RunWork(fn, nil, done, "perf")
        end })
    end
    DataStep("Crafts rows, every expansion", function()
        addon:GetCraftRows("All", { showIgnored = true })
    end)
    DataStep("Crafts rows with concentration", function()
        addon:GetCraftRows("All", { showIgnored = true, concentration = true })
    end)
    DataStep("Salvage rows", function() addon:GetSalvageRows("All", {}) end)

    local function Finish()
        addon.OnTabRefreshed = nil
        addon:ShowTab(oldTab)
        if not wasShown then addon.window:Hide() end
        -- What players feel: the longest single frame each tab's loading
        -- took in normal use this session, and where it was
        run.longestFrame, run.longestWhere = {}, {}
        for label, ms in pairs(addon.workLongest or {}) do
            if label ~= "perf" then
                run.longestFrame[label] = ms
                run.longestWhere[label] = addon.workLongestWhere[label]
            end
        end
        -- Counted a frame later: 150k price points on a big account
        C_Timer.After(0, function()
            local points = 0
            for _, days in pairs(GoldsmithDB.priceHistory or {}) do points = points + Count(days) end
            run.memoryKB = MemoryKB()
            run.loginMs = addon.initMs
            run.data = {
                characters = Count(GoldsmithDB.characters), recipes = Count(GoldsmithDB.recipes),
                entries = #(GoldsmithDB.entries or {}), priceHistory = points,
            }
            running = false
            Report(run)
        end)
    end

    -- Steps one after another, each cold then warm; a frame between them
    local index = 0
    local function NextStep()
        index = index + 1
        local step = steps[index]
        if not step then
            Finish()
            return
        end
        local result = { label = step.label }
        table.insert(run.steps, result)
        local finished = false
        local function Timeout()
            if finished then return end
            finished = true
            result.error = string.format("didn't finish within %d seconds", STEP_TIMEOUT)
            C_Timer.After(0, NextStep)
        end
        C_Timer.After(STEP_TIMEOUT, Timeout)
        addon:DataChanged()
        step.start(function(cold)
            if finished then return end
            result.cold, result.coldLongest = cold.totalMs, cold.longestMs
            C_Timer.After(0, function()
                if finished then return end
                step.start(function(warm)
                    if finished then return end
                    finished = true
                    result.warm, result.warmLongest = warm.totalMs, warm.longestMs
                    C_Timer.After(0, NextStep)
                end)
            end)
        end)
    end

    addon.window:Show()
    NextStep()
end

function addon:RunPerfCheck()
    if not addon.window then return end
    if running then
        print("Goldsmith: the performance check is already running.")
        return
    end
    running = true
    print("Goldsmith: measuring every tab, spread over frames like normal use. Results in a few seconds...")
    C_Timer.After(0.1, Run)
end

_G.Goldsmith = addon
