-- Something held a while that the AH now buys above its break-even:
-- a green chat line, once a day, and a Do this next card (Light's
-- Potential was 20.60g on Oct 18 against a 17.08g break-even, held 26
-- days, and nobody noticed; user, 2026-10-27). Not gear: its price is one
-- realm's listing (an Apron "above break-even" at 953g).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.sellNowTold = nil
local addon = bench.Login("Mysticmead", { db = db })
-- Everything held a while, under its break-even, so only the one raised
-- below counts
local item
for _, held in ipairs(addon:GetStockValue("All").heldLong) do
    local cost, _, source = addon:GetUnitCostBasis(held.name, held.count, held.itemID)
    if cost and cost > 0 then
        db.ownScan.prices[held.itemID] = { math.floor(cost * 0.9) }
        if not item and not addon:IsGear(held.itemID) and (source == "crafted" or source == "paid") then
            item = { itemID = held.itemID, name = held.name, cost = cost }
        end
    end
end
bench.Check("something held a while, not gear", item ~= nil)
db.searchPrices = {}
addon:DataChanged()
addon:CheckSellNow()
bench.Advance(2)
bench.HasNot("under break-even: quiet", bench.Chat(), "above break-even")

-- Over it: told once
db.ownScan.prices[item.itemID] = { math.floor(item.cost * 1.3) }
addon:DataChanged()
addon:CheckSellNow()
bench.Advance(2)
bench.Has("over break-even: a chat line", bench.Chat(), item.name .. " is above break-even")
bench.HasNot("no sound", bench.Calls(), "PlaySound(")
addon:CheckSellNow()
bench.Advance(2)
bench.HasNot("once a day", bench.Chat(), "above break-even")

addon:ToggleWindow()
addon:ShowTab("overview")
bench.Advance(3)
bench.Has("a Do this next card", bench.Screen(), "Sell now: above break-even")
bench.Done()
