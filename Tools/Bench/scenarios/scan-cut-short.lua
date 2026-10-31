-- A page scan cut short keeps the last scan: another addon's AH search
-- took over the page scan's results and 29 items were saved as the whole
-- scan (user, 2026-10-30). A page scan with no page at all asks once
-- more before giving up (twice no page came in 20 s, the next press
-- worked; 2026-10-30 and 31).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local before = GoldsmithDB.ownScan or {}
before.time, before.items, before.group = time(), 12000, addon:RealmGroup()
GoldsmithDB.ownScan = before
GoldsmithDB.lastFullRequest = time() -- full scan used: pages
bench.OpenAH()
bench.Advance(4)

-- Another search during the page scan
bench.Calls()
bench.Chat()
addon:ScanAH()
bench.Has("pages", bench.Calls(), "SendBrowseQuery")
bench.Check("scanning", addon:IsScanning())
C_AuctionHouse.SendBrowseQuery({ searchString = "Hochenblume" })
bench.Has("another search stops it", bench.Chat(), "another AH search started. The last scan is kept.", true)
bench.Check("not scanning", not addon:IsScanning())
bench.Equal("last scan kept", GoldsmithDB.ownScan, before)

-- Only 29 items came back
local results = {}
for i = 1, 29 do
    results[i] = { itemKey = { itemID = 200000 + i, battlePetSpeciesID = 0 }, minPrice = 10000, totalQuantity = 5 }
end
local oldResults = C_AuctionHouse.GetBrowseResults
C_AuctionHouse.GetBrowseResults = function() return results end
addon:ScanAH()
bench.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
bench.Advance(1)
bench.Has("says it came back short", bench.Chat(), "only 29 items came back, so the last scan is kept.", true)
bench.Equal("last scan kept", GoldsmithDB.ownScan, before)
bench.Equal("kept as a failure", GoldsmithDB.scanFail and GoldsmithDB.scanFail.items, 29)
C_AuctionHouse.GetBrowseResults = oldResults

-- No page at all: asks once more, then gives up
bench.Calls()
addon:ScanAH()
bench.Calls()
bench.Advance(21)
bench.Has("asks again", bench.Calls(), "SendBrowseQuery")
bench.Check("still scanning", addon:IsScanning())
bench.HasNot("no message yet", bench.Chat(), "sent nothing back", true)
bench.Advance(21)
bench.Has("then says so", bench.Chat(), "sent nothing back, so the last scan is kept.", true)
bench.Check("not scanning", not addon:IsScanning())
bench.Done()
