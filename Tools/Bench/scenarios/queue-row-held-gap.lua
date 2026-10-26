-- A queued craft whose profit clearly differs from the to-do's because of
-- what you hold is starred, and the queue's footer says why, even when the
-- whole queue's gap is too small to mention on its own. Mysticmead's
-- Blooming Feast read +148.51g in the queue and +126.60g on the to-do
-- (Malleable Root held at less than today's price), with nothing on screen
-- to say so (user, 2026-10-26: "if there is a mismatch we need to make it
-- clear why so the user doesn't think goldsmith is broken").
local bench = dofile(BENCH_DIR .. "bench.lua")
local KEY = "Mysticmead-Sargeras"
local db = bench.LoadSaved()
local ids = {}
for id, r in pairs(db.recipes) do ids[r.outputName or "?"] = ids[r.outputName or "?"] or id end
db.queues[KEY] = {
    { recipeID = ids["Light's Potential"], quantity = 5, made = 0, tier = 2, concentrate = true, added = os.time() },
    { recipeID = ids["Bouquet of Herbs"], quantity = 2, made = 0, tier = 1, added = os.time() },
    { recipeID = ids["Blooming Feast"], quantity = 2, made = 0, added = os.time() },
}
local addon = bench.Login("Mysticmead", { db = db })
-- What you hold, at what you paid: the 5 roots about 15g each (today's
-- price is higher), whatever the saved data says now
bench.SetBags({ ["Malleable Root"] = 5 })
local ownCost = addon.GetOwnCost
addon.GetOwnCost = function(self, name, ...)
    if name == "Malleable Root" then return bench.Gold(15) end
    return ownCost(self, name, ...)
end
addon:DataChanged()

local q = addon:BuildQueue(KEY)
local feast, plans = nil, {}
for _, row in ipairs(q.rows) do
    table.insert(plans, row.plan)
    if row.recipe.outputName == "Blooming Feast" then feast = row end
end
local gap = addon:HeldGap(plans, true)
bench.Check("the queue's gap is under the usual line", addon:HeldGap(plans) == nil,
    addon:FormatMoney(gap or 0) .. " of " .. addon:FormatMoney(q.profit))

addon:ToggleWindow()
addon:ShowTab("queue")
bench.Advance(3)
local screen = bench.Screen()
-- The star itself is on a list row, which the bench doesn't draw: rows
-- a gold or more off are starred, under 10% of their profit too (the
-- feast's 13.34g against +136.47g went unexplained in game), and rows
-- under a gold are not
bench.Check("feast starred", addon:QueueRowGap(feast) ~= nil)
for _, row in ipairs(q.rows) do
    local p = row.plan
    local off = math.abs(p.cost - p.marketCost)
    bench.Equal(string.format("%s starred at %s off", row.recipe.outputName, addon:FormatMoney(off)),
        addon:QueueRowGap(row) ~= nil, off >= bench.Gold(1))
end
local small = { plan = { nodes = {}, cost = bench.Gold(100), marketCost = bench.Gold(87), revenue = bench.Gold(250) } }
bench.Check("a 13g gap under 10% of the profit is starred", addon:QueueRowGap(small) ~= nil)
bench.Has("footer: profit at today's prices", screen,
    addon:FormatSignedMoney(q.profit + gap) .. " at today's prices")
bench.Has("footer: why, starred", screen, "* You paid " .. addon:FormatMoney(math.abs(gap)) .. " less for")
bench.Done()
