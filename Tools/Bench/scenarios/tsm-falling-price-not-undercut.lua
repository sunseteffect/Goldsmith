-- A price falling day after day isn't an undercut because TSM's market
-- value (an average over days) is still high. Spidersilk Boots fell 130s,
-- 106s, 97s, 93s, 85s to 70s, 84 up from 65s; TSM: market value 159.04s,
-- recent 93.36s, sold for 88.77s. They were valued at the market value
-- ("looked like a small undercut") and queued at a profit that wasn't
-- there (user, 2026-11-11). A real lone undercut, under a recent price
-- and sales that back the market value, still is one.
local bench = dofile(BENCH_DIR .. "bench.lua")
local ITEM = 990201
local tsm = {}
TSM_API = {
    GetCustomPriceValue = function(source, item) if item == "i:" .. ITEM then return tsm[source] end end,
    IsUIVisible = function() return false end,
}
local db = bench.LoadSaved()
db.searchPrices, db.orderBooks = {}, {}
local addon = bench.Login("Mysticmead", { db = db })
bench.AddItem(ITEM, "Bench Silk Boots", { stack = 1 })
GoldsmithDB.ownScan = { time = time() - 60, method = "pages", items = 1, group = addon:RealmGroup(),
    prices = { [ITEM] = { 7000, 7000, 84 } } }
-- Goldsmith's own prices for the days before: falling, never holding
GoldsmithDB.priceHistory = GoldsmithDB.priceHistory or {}
local history = {}
for back, p in ipairs({ 9300, 9700, 10600, 13000 }) do history[date("%Y-%m-%d", time() - back * 86400)] = p end
GoldsmithDB.priceHistory[ITEM] = history

-- The boots: the scan's 70s
tsm = { DBMarket = 15904, DBRecent = 9336, DBRegionSaleAvg = 8877, DBMinBuyout = 8736 }
addon:DataChanged()
local price, source = addon:GetAHPriceInfo(ITEM)
bench.Equal("falling: the scan's price", price, 7000)
bench.Equal("falling: from the scan", source, "Scan")

-- No recent value, but sales well under the market value: the same
tsm = { DBMarket = 15904, DBRegionSaleAvg = 8877 }
addon:DataChanged()
bench.Equal("sales under the market value: the scan's price", addon:GetAHPrice(ITEM), 7000)

-- A lone undercut: recent and sales both near the market value
tsm = { DBMarket = 15904, DBRecent = 15500, DBRegionSaleAvg = 15000 }
addon:DataChanged()
price, source = addon:GetAHPriceInfo(ITEM)
bench.Equal("lone undercut: the market value", price, 15904)
bench.Equal("lone undercut: from TSM", source, "TSM market")
bench.Done()
