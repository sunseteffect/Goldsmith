-- A page scan under half the last price keeps the last one (Winged Stalk:
-- one cheap unit). But only once in a row: each page scan kept the kept
-- price again, and Forever has no full scan to end it, so Red Linen Bag
-- stayed 20s for hours while it sold at 4s (user, 2026-11-08).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local ITEM = 990061
bench.AddItem(ITEM, "Bench Linen Bag", { stack = 1 })
local results = { { itemKey = { itemID = ITEM, battlePetSpeciesID = 0 }, minPrice = 400, totalQuantity = 30 } }
C_AuctionHouse.GetBrowseResults = function() return results end
C_AuctionHouse.HasFullBrowseResults = function() return true end
GoldsmithDB.lastFullRequest = time() -- full scan used: pages
bench.OpenAH()
for _ = 1, 3 do bench.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
bench.Advance(30)
bench.Advance(4)

local function PageScan(before)
    GoldsmithDB.ownScan = { time = time() - 3600, method = "pages", items = 1, group = addon:RealmGroup(),
        prices = { [ITEM] = before } }
    GoldsmithDB.lastFullRequest = time() -- full scan used: pages
    addon:ScanAH()
    for _ = 1, 3 do bench.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
    bench.Advance(30)
    local p = GoldsmithDB.ownScan.prices[ITEM]
    return p and p[1]
end

local first = PageScan({ 2000, 2000, 66 })
bench.Check("first scan ran", GoldsmithDB.ownScan.time >= time() - 60 and not addon:IsScanning())
bench.Equal("first drop under half: last price kept", first, 2000)
local second = PageScan({ 2000, 400, 30 })
bench.Check("second scan ran", GoldsmithDB.ownScan.time >= time() - 60, table.concat(bench.Chat(), " / "))
bench.Equal("already kept: the new lowest", second, 400)
bench.Done()
