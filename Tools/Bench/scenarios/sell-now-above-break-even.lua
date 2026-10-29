-- Something held a while that the AH now buys above its break-even:
-- a green chat line, once a day, and a Do this next card (Light's
-- Potential was 20.60g on Oct 18 against a 17.08g break-even, held 26
-- days, and nobody noticed; user, 2026-10-27). Not gear: its price is one
-- realm's listing (an Apron "above break-even" at 953g).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.sellNowTold = nil
db.setupDone = true  -- Do this next, not the Getting started list
local addon = bench.Login("Mysticmead", { db = db })
-- Prices set here, whatever the saved scans say: everything held a while
-- under its break-even, so only the one raised
-- below counts
local item
local prices = {}
local ahPrice = addon.GetAHPrice
addon.GetAHPrice = function(self, itemID, ...)
    if prices[itemID] then return prices[itemID] end
    return ahPrice(self, itemID, ...)
end
local candidates = {}
for _, held in ipairs(addon:GetStockValue("All").heldLong) do
    local cost, _, source = addon:GetUnitCostBasis(held.name, held.count, held.itemID)
    if cost and cost > 0 then
        prices[held.itemID] = math.floor(cost * 0.9)
        if not addon:IsGear(held.itemID) and (source == "crafted" or source == "paid") then
            table.insert(candidates, { itemID = held.itemID, name = held.name, cost = cost })
        end
    end
end
-- One Sell now would name at a higher price: not one posted in the last
-- day (a Sunglass Vial just posted, 2026-10-29)
for _, c in ipairs(candidates) do
    if not item then
        prices[c.itemID] = math.floor(c.cost * 1.3)
        addon:DataChanged()
        for _, s in ipairs(addon:GetSellNow()) do
            if s.itemID == c.itemID then item = c end
        end
        prices[c.itemID] = math.floor(c.cost * 0.9)
    end
end
bench.Check("something held a while, not gear", item ~= nil)
db.searchPrices = {}
addon:DataChanged()
addon:CheckSellNow()
bench.Advance(2)
bench.HasNot("under break-even: quiet", bench.Chat(), "above break-even")

-- Over it: told once
prices[item.itemID] = math.floor(item.cost * 1.3)
addon:DataChanged()
addon:CheckSellNow()
bench.Advance(2)
bench.Has("over break-even: a chat line", bench.Chat(), item.name .. " is above break-even")
bench.HasNot("no sound", bench.Calls(), "PlaySound(")
addon:CheckSellNow()
bench.Advance(2)
bench.HasNot("once a day", bench.Chat(), "above break-even")

-- On the AH already (just posted): not told again (2 Soul Cipher were,
-- 2026-10-27)
db.sellNowTold = {}
local me = db.characters["Mysticmead-Sargeras"]
me.auctions = me.auctions or {}
me.auctions[item.itemID] = 1
addon:DataChanged()
addon:CheckSellNow()
bench.Advance(2)
bench.HasNot("listed on the AH: quiet", bench.Chat(), "above break-even")
me.auctions[item.itemID] = nil
addon:DataChanged()

-- Kept for yourself (potions you use): off the Held board and Sell now
addon:SetKept(item.itemID, item.name, true)
local listed = false
for _, s in ipairs(addon:GetSellNow()) do if s.itemID == item.itemID then listed = true end end
bench.Check("kept: not in Sell now", not listed)
local onBoard = false
for _, h in ipairs(addon:GetStockValue("All").heldLong) do if h.itemID == item.itemID then onBoard = true end end
bench.Check("kept: not held for sale", not onBoard)
addon:SetKept(item.itemID, item.name, false)

addon:ToggleWindow()
addon:ShowTab("overview")
bench.Advance(3)
bench.Has("a Do this next card", bench.Screen(), "Sell now: above break-even")
bench.Done()
