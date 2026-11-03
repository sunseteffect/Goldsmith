-- Crafts made from the queue panel come off the Crafts page's box, one by
-- one, as the plan's own Craft button's do. 8 of 60 Harandar Celebrations
-- crafted from the queue left the page planning 60, so it asked to salvage
-- more Plant Protein and buy more vendor items (user, 2026-11-03).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead", { db = bench.LoadSaved() })
local calls, crafts = {}, 0
addon.PlanCraftsDone = function(recipeID, made, n)
    table.insert(calls, recipeID)
    crafts = crafts + n
end
local recipe = { recipeID = 999001, outputName = "Test Feast" }
-- Started by the queue: no fromPlan
addon:StartCraftBatch(recipe, { crafts = 3 })
bench.Check("following the crafts", addon:CraftBatchRunning())
addon:CraftBatchResult(999001, recipe, { itemID = 1, quantity = 1 }, nil, {})
bench.Equal("first craft off the box", crafts, 1)
addon:CraftBatchResult(999001, recipe, { itemID = 1, quantity = 1 }, nil, {})
addon:CraftBatchResult(999001, recipe, { itemID = 1, quantity = 1 }, nil, {})
bench.Equal("all three off, none twice", crafts, 3)
bench.Equal("for its recipe", calls[3], 999001)
bench.Check("done following", not addon:CraftBatchRunning())
bench.Done()
