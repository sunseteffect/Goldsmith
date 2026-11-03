-- The page scan's percent goes by the usual page count: the middle of the
-- last 5 scans that reached the end. A scan that stalled (an AH mount's
-- owner walked off mid-scan) is saved but its page count isn't, so the
-- next scan doesn't sit at 99% (user, 2026-11-03).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
GoldsmithDB.scanPagesSeen, GoldsmithDB.scanPages = nil, 67
bench.Equal("old single count starts it", addon:UsualScanPages(), 67)

-- One odd count doesn't move it
addon:RecordScanPages(69)
addon:RecordScanPages(68)
addon:RecordScanPages(45)
bench.Equal("middle of 67, 69, 68, 45", addon:UsualScanPages(), 67)
addon:RecordScanPages(20)
bench.Equal("under half the usual: not kept", #GoldsmithDB.scanPagesSeen, 4)
addon:RecordScanPages(70)
addon:RecordScanPages(71)
bench.Equal("keeps the last 5", #GoldsmithDB.scanPagesSeen, 5)
bench.Equal("usual now", addon:UsualScanPages(), 69)

-- A page scan that stalls at page 20: saved, page count not kept
local before = GoldsmithDB.ownScan or {}
before.time, before.items, before.group = time() - 3600, 40, addon:RealmGroup()
GoldsmithDB.ownScan = before
GoldsmithDB.lastFullRequest = time() -- full scan used: pages
local results = {}
for i = 1, 50 do
    results[i] = { itemKey = { itemID = 200000 + i, battlePetSpeciesID = 0 }, minPrice = 10000, totalQuantity = 5 }
end
C_AuctionHouse.GetBrowseResults = function() return results end
C_AuctionHouse.HasFullBrowseResults = function() return false end
bench.OpenAH()
bench.Advance(4)
local seen = bench.Copy(GoldsmithDB.scanPagesSeen)
addon:ScanAH()
for _ = 1, 20 do bench.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED") end
bench.Has("percent from the usual 69", bench.Screen(), "Scanning 28%")
bench.Advance(25)
bench.Check("scan finished", not addon:IsScanning())
bench.Equal("stalled scan saved", GoldsmithDB.ownScan.items, 50)
bench.Equal("its page count not kept", bench.Serialize(GoldsmithDB.scanPagesSeen), bench.Serialize(seen))
bench.Done()
