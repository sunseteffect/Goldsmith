-- Posted lately but back in the bags, unsold: Sell now names it once that
-- character's auctions were read after the post without it. A Sunglass
-- Vial (266g vs 78.76g break-even) and 4 Quel'dorei Medley stayed
-- "posted in the last day" for a whole day (user, 2026-10-30).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.sellNowTold = nil
local addon = bench.Login("Mysticmead", { db = db })

-- Everything held under its break-even but one, priced above it
local prices, item = {}, nil
local ahPrice = addon.GetAHPrice
addon.GetAHPrice = function(self, itemID, ...)
    if prices[itemID] then return prices[itemID] end
    return ahPrice(self, itemID, ...)
end
for _, held in ipairs(addon:GetStockValue("All").heldLong) do
    local cost, _, source = addon:GetUnitCostBasis(held.name, held.count, held.itemID)
    if cost and cost > 0 then
        prices[held.itemID] = math.floor(cost * 0.9)
        if not item and not addon:IsGear(held.itemID) and (source == "crafted" or source == "paid") then
            item = { itemID = held.itemID, name = held.name, cost = cost }
        end
    end
end
bench.Check("something held a while, not gear", item ~= nil)
-- Well over: Sell now may count a blended cost above this one (bought and
-- crafted, sell-now-bought-and-crafted)
prices[item.itemID] = math.floor(item.cost * 5)
local me = db.characters["Mysticmead-Sargeras"]
for _, c in pairs(db.characters) do if c.auctions then c.auctions[item.itemID] = nil end end

local function Named()
    addon:DataChanged()
    for _, s in ipairs(addon:GetSellNow()) do
        if s.itemID == item.itemID then return true end
    end
    return false
end

-- Just posted, auctions not read since: still being sold
addon.ledger:addCost("Cooking", item.name, 1, 100, "DEPOSIT")
me.auctionsTime = time() - 60
bench.Check("just posted: not named", not Named())

-- Auctions read right after posting, before the listing shows: still posted
me.auctionsTime = time() + 60
bench.Check("read a minute after: not named", not Named())

-- Read well after the post and not there: it came back
me.auctionsTime = time() + 20 * 60
bench.Check("read later, not listed: named", Named())

-- Read later and still listed: being sold
me.auctions = me.auctions or {}
me.auctions[item.itemID] = 1
bench.Check("read later, still listed: not named", not Named())
bench.Done()
