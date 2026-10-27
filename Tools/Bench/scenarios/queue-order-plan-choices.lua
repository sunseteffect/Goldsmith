-- A queued crafting order opened from the Queue tab is planned as that
-- order: without what the customer provides, paid by its commission, and
-- a right-click choice on it is the order's, so the queue and Buy next
-- follow it. Buy on Row Walker's Insurance's Smuggler's Enchanted Edge
-- stayed on the plan, the queue still crafted it, and the plan switched to
-- buying gold Edges (user, 2026-10-26): gold made with concentration from
-- silver materials beat silver bought, its concentration not counted.
local bench = dofile(BENCH_DIR .. "bench.lua")
local KEY = "Maddoxius-Sargeras"
local SILVER, GOLD = 243737, 243738
local db = bench.LoadSaved()
local recipeID
for id, r in pairs(db.recipes) do
    if r.outputName == "Row Walker's Insurance" then recipeID = id end
end
local order = { orderID = 1, recipeID = recipeID, quantity = 1, made = 0, concentrate = false,
    provided = { [251283] = 1, [244634] = 1, [232875] = 2, [244636] = 2, [238512] = 200 },
    customer = "Bench", commission = bench.Gold(81.62), rewardsValue = 0, added = os.time() }
db.queues[KEY] = { order }
local addon = bench.Login("Maddoxius", { db = db })
local ahPrice = addon.GetAHPrice
addon.GetAHPrice = function(self, id, ...)
    if id == SILVER then return bench.Gold(29) end
    if id == GOLD then return bench.Gold(59.23) end
    return ahPrice(self, id, ...)
end
addon:DataChanged()

local row = addon:CraftedTierRow(GOLD, "Smuggler's Enchanted Edge")
bench.Check("gold Edge is made with concentration (what this tests)", row and row.concentrate,
    row and "no concentration" or "no gold row")

local function EdgeLine(plan)
    for _, n in ipairs(addon:FlattenPlan(plan)) do
        if n.itemID == SILVER or n.itemID == GOLD then return n end
    end
end

-- The order's plan from its queue row
addon:ToggleWindow()
bench.Advance(2)
addon:OpenCraftPlan(db.recipes[recipeID], { order = order }, KEY, 1, "queue")
bench.Advance(3)
local screen = bench.Screen()
bench.Has("paid by the order", screen, "The order's commission and rewards")
bench.Has("the commission", screen, "81.62g", true)
bench.HasNot("no Add to queue for an order", screen, "Add to queue")

-- Buy on the silver Edge, as the right-click menu sets it on the plan
-- screen's entry: the queue plans it the same way
order.choices = { [SILVER] = "Buy" }
addon:QueueEntryChanged()
bench.Advance(3)
local q = addon:BuildQueue(KEY)
local edge = q.rows[1] and q.rows[1].plan and EdgeLine(q.rows[1].plan)
bench.Equal("queue buys the Edge", edge and edge.best and edge.best.method, "Buy")
bench.Equal("silver, not gold", edge and edge.itemID, SILVER)
bench.Has("the plan shops for 2 silver Edges", bench.Screen(), "AH: 1 item, about 58.00g", true)
bench.Done()
