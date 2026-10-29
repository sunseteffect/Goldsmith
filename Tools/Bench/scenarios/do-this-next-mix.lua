-- Clicking Do this next's concentration card opens the plan with the
-- card's mix, not a saved pick that needs more than you have (user,
-- 2026-10-28: the card said 278 concentration, the plan opened on the
-- all silver pick at 314 with 298 and said not enough)
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.setupDone = true
db.queues = {}  -- nothing queued, so the plan says Add to queue
local key
for k in pairs(db.characters) do if k:match("^Mysticmead") then key = k end end
for _, snap in pairs(db.characters[key].concentration or {}) do
    snap.current, snap.time = 298, os.time()
end
local addon = bench.Login("Mysticmead", { db = db })

local todo = addon:GetCharacterTodo("All")[key]
local first
for _, item in ipairs(todo and todo.items or {}) do
    if item.concentration and not first then first = item end
end
bench.Check("a concentration to-do", first ~= nil, "none: nothing to test")
if not first then return bench.Done() end

-- Save a pick of the same tier that the card didn't use, the most
-- concentration first
local other
local tierRows = addon:WithCharacter(key, addon.GetTierRows, addon, first.recipe) or {}
for _, e in ipairs(tierRows[1] and tierRows[1].scenarios or {}) do
    if e.tier == first.row.tier and e.concentrate and e.concentrationValue
        and e.description ~= first.row.description
        and (not other or e.scenario.concentration > other.scenario.concentration) then
        other = e
    end
end
bench.Check("another mix to pick", other ~= nil)
if not other then return bench.Done() end
GoldsmithDB.ui2 = GoldsmithDB.ui2 or {}
GoldsmithDB.ui2.planMix = GoldsmithDB.ui2.planMix or {}
GoldsmithDB.ui2.planMix[first.recipe.recipeID] = { tier = first.row.tier, concentrate = true,
    description = other.description }
bench.Log("card: %s; saved pick: %s", tostring(first.row.description), tostring(other.description))

addon:ToggleWindow()
bench.Advance(2)
addon:OpenCraftPlan(first.recipe, first.row, key, nil, nil, first.crafts, first.row.description)
bench.Advance(5)
local screen = table.concat(bench.Screen(), "\n")
bench.Has("plan uses the card's mix", screen, "Picked: " .. first.row.description:gsub("^%l", string.upper))
bench.HasNot("no not-enough warning", screen, "not enough concentration now")
-- What it takes to start and ingenuity's chance, not an average
bench.HasNot("no after-ingenuity average", screen, "after ingenuity")
bench.Has("ingenuity as a chance", screen, "% chance to get ")

-- Add to queue from that plan: the queue uses the card's mix too
bench.Click("Add to queue")
bench.Advance(2)
addon:ShowTab("queue")
bench.Advance(5)
local queue = table.concat(bench.Screen(), "\n")
bench.Has("queued it", queue, first.recipe.outputName)
bench.HasNot("queue fits the concentration", queue, "(you have", true)
bench.HasNot("queue: no needs concentration", queue, "Needs concentration", true)

-- Back on the plan: click another mix, then the card's again, Update
-- queue: the queue keeps the card's (it went back to the 248 mix,
-- user, 2026-10-28)
local function MixRow(description, picked)
    for _, f in ipairs(bench.wow.frames) do
        if f.entry and f:IsVisible() and (picked == nil or f.picked == picked)
            and (not description or f.entry.description == description) then return f end
    end
end
addon:OpenCraftPlan(first.recipe, { tier = first.row.tier, concentrate = true }, key, nil, "queue")
bench.Advance(5)
local away = MixRow(nil, false)
bench.Check("another mix row", away ~= nil)
if away then
    away:Click()
    bench.Advance(2)
    local entry = db.queues[key][1]
    bench.Equal("queue follows the click", entry and entry.prefMix, away.entry.description)
    local back = MixRow(first.row.description)
    bench.Check("the card's mix row", back ~= nil)
    if back then back:Click() end
    bench.Advance(2)
    bench.Click("Update queue")
    bench.Advance(2)
    bench.Equal("queue back on the card's mix", entry and entry.prefMix, first.row.description)
end
for line in screen:gmatch("[^\n]+") do
    if line:find("concentration (", 1, true) then bench.Log("%s", line) end
end
bench.Done()
