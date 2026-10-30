-- A material you both craft and buy: Sell now's break-even is the item
-- page's, from what the ones you hold cost you. 6 Sunglass Vial (2 crafted
-- at 75g, the rest bought at 266g) had 78.69g in Sell now and 199.48g on
-- the item page (user, 2026-10-30).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.sellNowTold = nil
local addon = bench.Login("Mysticmead", { db = db })

-- A held material whose cost blends crafted and paid
local materials = addon:GetTrackedMaterials()
local item
for _, held in ipairs(addon:GetStockValue("All").heldLong) do
    local _, source = addon:GetOwnCost(held.name, nil, held.itemID)
    if not item and materials[held.itemID] and db.craftLots[held.itemID] and source == "paid+crafted"
        and not addon:IsGear(held.itemID) then
        item = held
    end
end
bench.Check("a held material both crafted and bought", item ~= nil)

-- Not posted lately, priced well above any cost
for _, c in pairs(db.characters) do
    if c.auctions then c.auctions[item.itemID] = nil end
    c.auctionsTime = time() + 3600
end
local page = addon:GetItemDetails(item.name, item.itemID)
local ahPrice = addon.GetAHPrice
addon.GetAHPrice = function(self, itemID, ...)
    if itemID == item.itemID then return math.floor(page.breakEven * 3) end
    return ahPrice(self, itemID, ...)
end
addon:DataChanged()
page = addon:GetItemDetails(item.name, item.itemID)
local found
for _, s in ipairs(addon:GetSellNow()) do
    if s.itemID == item.itemID then found = s end
end
bench.Check("named in Sell now", found ~= nil)
bench.Check("same break-even as the item page", found and page.breakEven
    and math.abs(found.breakEven - page.breakEven) < 100)
bench.Done()
