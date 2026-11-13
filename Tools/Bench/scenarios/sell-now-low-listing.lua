-- Sell now goes by the lowest price really listed, not a price raised
-- above it: Mark of the Magister, 5 listed at 200g, was valued at its
-- usual 500g (a lone low listing under half of usual) and raid-warned
-- "sell now" at a 427.85g break-even (user, 2026-10-31).
local bench = dofile(BENCH_DIR .. "bench.lua")
local g = bench.Gold
local db = bench.LoadSaved()
-- Prices come from the GetAHPrice stand-in below, not what the saved
-- scan, searches and listings saw (GetSellNowPrice goes by the lowest)
db.ownScan, db.orderBooks, db.searchPrices = nil, {}, {}
db.sellNowTold = nil
local addon = bench.Login("Mysticmead", { db = db })
-- One held a while whatever your bags hold today
bench.HoldCrafted(addon)

-- Something held a while, with a real cost
local item
for _, held in ipairs(addon:GetStockValue("All").heldLong) do
    local cost, _, source = addon:GetUnitCostBasis(held.name, held.count, held.itemID)
    if not item and cost and cost > 0 and not addon:IsGear(held.itemID) and (source == "crafted" or source == "paid") then
        item = { itemID = held.itemID, name = held.name, cost = cost }
    end
end
bench.Check("something held a while", item ~= nil)

-- Valued well above break-even (as the usual price), but a search today
-- saw it listed under break-even
local ahPrice = addon.GetAHPrice
addon.GetAHPrice = function(self, itemID, ...)
    if itemID == item.itemID then return math.floor(item.cost * 1.5) end
    return ahPrice(self, itemID, ...)
end
db.searchPrices = { [item.itemID] = { time = time(), price = math.floor(item.cost * 0.6), quantity = 118,
    group = addon:RealmGroup() } }
addon:DataChanged()
bench.Equal("sell price is the low listing", addon:GetSellNowPrice(item.itemID), math.floor(item.cost * 0.6))
addon:CheckSellNow()
bench.Advance(2)
bench.HasNot("listed under break-even: quiet", bench.Chat(), item.name .. " is above break-even")
bench.HasNot("no raid warning", bench.Calls(), "RaidNotice(")

-- The listing gone, the price above break-even: told
db.searchPrices = {}
addon:DataChanged()
addon:CheckSellNow()
bench.Advance(2)
bench.Has("above break-even: told", bench.Chat(), item.name .. " is above break-even")
bench.Done()
