-- Something worth selling that comes into your bags after the scan (out
-- of the bank, the mail or an alt): the green line too, not only the
-- Do this next card. A Sunglass Vial taken out after the 10:37 scan made
-- the card but no chat line (user, 2026-10-29).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
-- Prices come from the GetAHPrice stand-in below, not what the saved
-- scan, searches and listings saw (GetSellNowPrice goes by the lowest)
db.ownScan, db.orderBooks, db.searchPrices = nil, {}, {}
db.sellNowTold = nil
db.setupDone = true
db.searchPrices = {}
-- One crafted item, held weeks, in nobody's stock yet
local itemID, lot
for id, lots in pairs(db.craftLots) do
    -- The newest lot old too: a Missive crafted again lately is held
    -- since then (2026-10-30)
    local last = lots[#lots]
    -- Not a material your recipes use: those are named only once listed
    -- (IsForSale). Crystalline Glass turned 10 days old and was picked,
    -- quiet by design (2026-11-12). Worth 10g+, so one clears SELL_NOW_MIN_GOLD
    if #lots > 0 and last.unitCost and last.unitCost >= 100000 and not db.reagents[last.name or ""]
        and last.time < os.time() - 10 * 86400
        and lots[1].time < os.time() - 10 * 86400 then
        itemID, lot = id, last
        break
    end
end
bench.Check("a crafted item held a while", itemID ~= nil)
for _, c in pairs(db.characters) do
    if c.stock then c.stock[itemID] = nil end
    if c.auctions then c.auctions[itemID] = nil end
end
db.warbandStock[itemID] = nil
local addon = bench.Login("Mysticmead", { db = db })
local ahPrice = addon.GetAHPrice
addon.GetAHPrice = function(self, id, ...)
    if id == itemID then return math.floor(lot.unitCost * 3) end
    return ahPrice(self, id, ...)
end
addon.IsGear = function() return false end
addon:DataChanged()
bench.Advance(40)
bench.HasNot("not held: quiet", bench.Chat(), lot.name .. " is above break-even")

-- Into the bags with the window open (stock is counted while it's in use)
addon:ToggleWindow()
addon:ShowTab("overview")
bench.Advance(2)
bench.SetBags({ [itemID] = 1 })
bench.Advance(15)
bench.Has("new in stock: a chat line", bench.Chat(), lot.name .. " is above break-even")
bench.Done()
