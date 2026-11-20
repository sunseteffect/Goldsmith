-- The queue's totals show ROI beside the profit, as a plan does (user,
-- 2026-11-18: "can we put ROI on the queue screen? like on the bottom")
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.queues = {}
local addon = bench.Login("Mysticmead", { db = db })
local best
for _, c in ipairs(addon:GetBestCrafts("All", math.huge)) do
    if c.charKey == addon.charKey then best = c break end
end
bench.Check("a craft to queue (what this tests)", best ~= nil)
addon:AddToQueue(addon.charKey, best.recipe.recipeID, 2, best.row.tier, false)
addon:ToggleWindow()
addon:ShowTab("queue")
bench.Advance(5)
local q = addon:BuildQueue(addon.charKey)
local want = string.format("%d%% ROI", math.floor(q.profit / q.cost * 100 + 0.5))
bench.Has("ROI under the totals", table.concat(bench.Screen(), "\n"), want, true)
addon:ClearQueue(addon.charKey)
addon.RefreshWindow()
bench.Advance(3)
bench.HasNot("empty queue: none", table.concat(bench.Screen(), "\n"), "% ROI", true)
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
