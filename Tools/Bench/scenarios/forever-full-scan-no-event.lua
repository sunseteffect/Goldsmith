-- Forever's full scan: the listings came (208,747) but never the
-- REPLICATE_ITEM_LIST_UPDATE event, so Goldsmith gave up after 15 s and
-- paged instead (user, 2026-11-08). It looks for the data every second.
-- Materials there are pooled past a stack (214 Linen Cloth for 18,190c:
-- buyout for all of them); a bag's count can be far off, priced for one.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.foreverTest = true
local addon = bench.Login("Mysticmead", { db = db })
local CLOTH, BAG = 990081, 990082
bench.AddItem(CLOTH, "Bench Cloth", { stack = 20, classID = 7 })
bench.AddItem(BAG, "Bench Bag", { stack = 1, classID = 1 })
local listings = {
    { CLOTH, 214, 18190 }, { CLOTH, 20, 600 }, { CLOTH, 180, 18000 },
    { BAG, 200, 400 }, { BAG, 66, 1000 }, { BAG, 3, 1500 },
}
local asked, arrived = false, 0
C_AuctionHouse.ReplicateItems = function() asked = true end
-- Arrives a row a second (208,747 came over time in Forever): reading
-- before the end missed most items
C_AuctionHouse.GetNumReplicateItems = function()
    if asked then arrived = math.min(arrived + 1, #listings) end
    return arrived
end
C_AuctionHouse.GetReplicateItemInfo = function(i)
    local l = listings[i + 1]
    if not l then return nil end
    return "x", 0, l[2], 1, true, 1, 0, 0, 0, l[3], 0, false, nil, "someone", nil, 0, l[1], true
end
GoldsmithDB.lastFullRequest = 0
GoldsmithDB.ownScan = nil -- two items would look like a scan cut short
bench.OpenAH()
bench.Advance(1)
addon:ScanAH()
bench.Advance(40) -- no event at all
bench.Check("not paging instead", GoldsmithDB.ownScan.method == "full", tostring(GoldsmithDB.ownScan.method))
bench.Check("scan finished", not addon:IsScanning())
local cloth = GoldsmithDB.ownScan.prices[CLOTH]
local bag = GoldsmithDB.ownScan.prices[BAG]
bench.Equal("cloth's cheapest: 600c for 20 is 30c", cloth and cloth[2], 30)
bench.Equal("bag's cheapest: 400c for one", bag and bag[2], 400)
bench.Equal("every listing read", GoldsmithDB.ownScan.auctions, #listings)
bench.Done()
