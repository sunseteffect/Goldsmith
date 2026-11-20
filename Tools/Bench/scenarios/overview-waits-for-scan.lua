-- The window doesn't reload while an AH scan runs: each page of a page
-- scan asked for a refresh, and the Overview started loading again every
-- half second until the scan was done (user, 2026-11-18). It refreshes
-- once when the scan ends, and once a scan that stopped is over.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
addon:ToggleWindow()
addon:ShowTab("overview")
bench.Advance(5)

local refreshes = 0
local before = addon.OnTabRefreshed
addon.OnTabRefreshed = function(...)
    refreshes = refreshes + 1
    if before then before(...) end
end

local last = GoldsmithDB.ownScan or {}
last.time, last.items, last.group = time() - 3600, 40, addon:RealmGroup()
GoldsmithDB.ownScan = last
GoldsmithDB.lastFullRequest = time() -- full scan used: pages
local results = {}
for i = 1, 50 do
    results[i] = { itemKey = { itemID = 200000 + i, battlePetSpeciesID = 0 }, minPrice = 10000, totalQuantity = 5 }
end
local full = false
C_AuctionHouse.GetBrowseResults = function() return results end
C_AuctionHouse.HasFullBrowseResults = function() return full end
bench.OpenAH()
bench.Advance(4)
refreshes = 0
addon:ScanAH()
bench.Check("scanning", addon:IsScanning())
for _ = 1, 30 do
    bench.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    bench.Advance(0.6)
end
bench.Equal("no refresh during 30 pages", refreshes, 0)

full = true
bench.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
bench.Advance(5)
bench.Check("scan finished", not addon:IsScanning())
bench.Check("refreshed after it", refreshes >= 1 and refreshes <= 2, refreshes .. " refreshes")

-- A scan stopped by the AH closing: the waiting refresh still comes
full = false
GoldsmithDB.lastFullRequest = time()
bench.Advance(4)
addon:ScanAH()
bench.Check("scanning again", addon:IsScanning())
refreshes = 0
for _ = 1, 5 do
    bench.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
    bench.Advance(0.6)
end
bench.Equal("none while scanning", refreshes, 0)
bench.CloseAH()
bench.Advance(3)
bench.Check("stopped", not addon:IsScanning())
bench.Equal("one refresh once stopped", refreshes, 1)
bench.Done()
