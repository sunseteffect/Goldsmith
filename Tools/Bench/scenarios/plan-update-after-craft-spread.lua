-- An open plan is worked out again after each craft as work over frames,
-- not at once: at once it took 79 ms, a hitch as each craft finished
-- (user, 2026-11-13: "a small hitch when i finish crafting"). Bag changes
-- while it shows do the same.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
addon:ToggleWindow()
bench.Advance(1)

-- A recipe Mysticmead knows, its plan open
local recipe
for id in pairs(addon.char.knownRecipes) do
    local r = GoldsmithDB.recipes[id]
    if r and r.outputItemID and not recipe then recipe = r end
end
bench.Check("a known recipe", recipe ~= nil)
addon:OpenCraftPlan(recipe, nil, addon.charKey, 3)
bench.Advance(5)
local plan = addon:GetTabScreen("crafts").view.plan
bench.Check("its plan shows", plan:IsVisible() and plan.plan ~= nil)

local updates, paused = 0, 0
local update = plan.Update
plan.Update = function(self, ...)
    updates = updates + 1
    -- Inside work (a coroutine) it can wait for the next frame
    if coroutine.running() then paused = paused + 1 end
    return update(self, ...)
end

-- A craft done, then a bag change: both as work that can pause
addon.PlanCraftsDone(recipe.recipeID, 1, 1)
bench.Fire("BAG_UPDATE_DELAYED")
bench.Advance(3)
bench.Check("worked out again", updates >= 1, tostring(updates))
bench.Equal("each time as work that can pause", paused, updates)
plan.Update = update
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
