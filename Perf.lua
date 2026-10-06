local addon = _G.Goldsmith or {}

-- Performance check (/gsm perf)
--
-- Times the work behind each tab and the Crafts list, twice each: cold
-- (caches emptied, as after prices or bags change) and warm (cached, as when
-- switching tabs). Prints the results with Goldsmith's memory and how much
-- data there is, and keeps the last PERF_RUNS in GoldsmithDB.perfRuns so
-- they can be read from the saved file after logging out. Meant for a big
-- fake account (Tools\Stress-Swap.ps1) as well as real ones.
local PERF_RUNS = 10
-- One frame at 60 fps; longer than this is a visible hitch
local FRAME_MS = 16
-- A freeze players notice
local FREEZE_MS = 250
local TABS = { "overview", "crafts", "queue", "items", "history", "characters" }

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

local function Time(fn)
    local start = debugprofilestop()
    fn()
    return debugprofilestop() - start
end

-- Cold, then warm
local function Measure(fn)
    addon:DataChanged()
    local cold = Time(fn)
    return cold, Time(fn)
end

local function MemoryKB()
    if UpdateAddOnMemoryUsage and GetAddOnMemoryUsage then
        UpdateAddOnMemoryUsage()
        return GetAddOnMemoryUsage("Goldsmith")
    end
end

local function Verdict(cold, warm)
    if warm > FRAME_MS then return "|cffff8040stutters|r" end
    if cold > FREEZE_MS then return "|cffffd040freezes when data changes|r" end
    return "|cff40ff40ok|r"
end

local function Run()
    local ui = GoldsmithDB.ui2
    local wasShown, oldTab = addon.window:IsShown(), ui.tab
    local run = { time = time(), steps = {}, stressTest = GoldsmithDB.stressTest and true or nil }
    -- Saved before anything is timed, so a step that errors still leaves
    -- the steps before it (and the error) in the saved file
    GoldsmithDB.perfRuns = GoldsmithDB.perfRuns or {}
    table.insert(GoldsmithDB.perfRuns, run)
    while #GoldsmithDB.perfRuns > PERF_RUNS do table.remove(GoldsmithDB.perfRuns, 1) end

    -- Open every tab once first, so building its frames isn't timed
    addon.window:Show()
    for _, key in ipairs(TABS) do
        local ok, err = pcall(addon.ShowTab, addon, key)
        if not ok then run.openError = run.openError or (key .. ": " .. tostring(err)) end
    end

    local function Step(label, fn)
        local ok, cold, warm = pcall(Measure, fn)
        if ok then
            table.insert(run.steps, { label = label, cold = cold, warm = warm })
        else
            table.insert(run.steps, { label = label, error = tostring(cold) })
        end
    end
    for _, key in ipairs(TABS) do
        Step(key:sub(1, 1):upper() .. key:sub(2) .. " tab", function() addon:ShowTab(key) end)
    end
    Step("Crafts rows, every expansion", function()
        addon:GetCraftRows("All", { showIgnored = true })
    end)
    Step("Crafts rows with concentration", function()
        addon:GetCraftRows("All", { showIgnored = true, concentration = true })
    end)
    Step("Salvage rows", function() addon:GetSalvageRows("All", {}) end)

    pcall(addon.ShowTab, addon, oldTab)
    if not wasShown then addon.window:Hide() end

    local points = 0
    for _, days in pairs(GoldsmithDB.priceHistory or {}) do points = points + Count(days) end
    run.memoryKB = MemoryKB()
    run.loginMs = addon.initMs
    run.data = {
        characters = Count(GoldsmithDB.characters), recipes = Count(GoldsmithDB.recipes),
        entries = #(GoldsmithDB.entries or {}), priceHistory = points,
    }

    print("|cffffd040Goldsmith performance|r" .. (run.stressTest and " (fake test data)" or ""))
    if run.openError then print("  |cffff4040Error opening a tab:|r " .. run.openError) end
    for _, s in ipairs(run.steps) do
        if s.error then
            print(string.format("  %s: |cffff4040error:|r %s", s.label, s.error))
        else
            print(string.format("  %s: cold %d ms, warm %d ms, %s", s.label, s.cold, s.warm, Verdict(s.cold, s.warm)))
        end
    end
    local d = run.data
    print(string.format("  Data: %d characters, %d recipes, %d transactions, %d price history points",
        d.characters, d.recipes, d.entries, d.priceHistory))
    print(string.format("  Memory: %s   Loading at login: %s",
        run.memoryKB and string.format("%.1f MB", run.memoryKB / 1024) or "unknown",
        run.loginMs and string.format("%d ms", run.loginMs) or "unknown"))
    print(string.format("  Cold = after data changes, warm = switching tabs. Over %d ms stutters.", FRAME_MS))
end

function addon:RunPerfCheck()
    if not addon.window then return end
    print("Goldsmith: measuring, the game will freeze for a few seconds...")
    -- A moment later, so the line above shows first
    C_Timer.After(0.1, Run)
end

_G.Goldsmith = addon
