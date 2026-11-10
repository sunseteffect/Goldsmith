-- Back for each tab on its own (user, 2026-11-09): open a queued craft
-- from the Queue, go back to the Queue by its tab, finish the queue, come
-- back to Crafts. Crafts showed the queued craft's plan still and Back
-- went to the Queue, not the Crafts list. A plan opened from the Queue is
-- a detour now: Back or another tab ends it, and Crafts shows what it had
-- before (its own plan or the list).
local bench = dofile(BENCH_DIR .. "bench.lua")
local SIENNA_INK = 1230016
local MADDOXYNN = "Maddoxynn-Sargeras"

local db = bench.LoadSaved()
local addon = bench.Login("Mysticmead", { db = db })
local recipes = GoldsmithDB.recipes
-- Another craft for Crafts' own plan
local other
for id, r in pairs(recipes) do
    if id ~= SIENNA_INK and r.outputName and not other then other = r end
end

local function Tab(key)
    addon.tourParts.tabs[key]:Click()
    bench.Advance(2)
end
local function Showing()
    local view = addon:GetTabScreen("crafts").view
    local p = view.plan.plan
    return addon:CurrentTab(), p and p.recipe.recipeID
end

-- 1. Your exact steps, from the Crafts list
Tab("crafts")
addon:OpenCraftPlan(recipes[SIENNA_INK], { tier = 2 }, MADDOXYNN, 6, "queue")
bench.Advance(2)
local tab, plan = Showing()
bench.Equal("queue item opens its plan", plan, SIENNA_INK)
Tab("queue")
Tab("crafts")
tab, plan = Showing()
bench.Equal("Crafts shows its list, not the queued plan", plan, nil)

-- 2. Crafts' own plan survives a detour left by the Queue tab
addon:OpenCraftPlan(other, nil, addon.charKey)
bench.Advance(2)
Tab("queue")
addon:OpenCraftPlan(recipes[SIENNA_INK], { tier = 2 }, MADDOXYNN, 6, "queue")
bench.Advance(2)
tab, plan = Showing()
bench.Equal("detour shows the queued plan", plan, SIENNA_INK)
Tab("queue")
Tab("crafts")
tab, plan = Showing()
bench.Equal("Crafts' own plan is back", plan, other.recipeID)
bench.Click("< Back")
tab, plan = Showing()
bench.Equal("Back from it: the Crafts list", plan, nil)
bench.Equal("still on Crafts", tab, "crafts")

-- 3. Same with Back on the detour: to the Queue, Crafts keeps its own plan
addon:OpenCraftPlan(other, nil, addon.charKey)
bench.Advance(2)
addon:OpenCraftPlan(recipes[SIENNA_INK], { tier = 2 }, MADDOXYNN, 6, "queue")
bench.Advance(2)
bench.Click("< Back")
tab, plan = Showing()
bench.Equal("Back from the detour: the Queue", tab, "queue")
Tab("crafts")
tab, plan = Showing()
bench.Equal("Crafts' own plan is still there", plan, other.recipeID)

-- 4. Clicking Crafts while on Crafts still goes to the list
Tab("crafts")
tab, plan = Showing()
bench.Equal("Crafts again: the list", plan, nil)
bench.Done()
