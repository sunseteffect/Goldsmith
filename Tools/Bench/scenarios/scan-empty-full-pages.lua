-- A full scan that comes back with nothing priced pages instead, as it
-- does when the full scan never answers; only when paging finds nothing
-- too does it say so, and the last scan stays. What happened is kept in
-- GoldsmithDB.scanFail (user, 2026-10-27: a scan failed, a second press
-- worked).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local before = GoldsmithDB.ownScan
GoldsmithDB.lastFullRequest = 0
C_AuctionHouse.GetNumReplicateItems = function() return 5 end
C_AuctionHouse.GetReplicateItemInfo = function() return nil end
bench.OpenAH()
bench.Calls()
bench.Chat()
addon:ScanAH()
bench.Has("asks for a full scan", bench.Calls(), "ReplicateItems")
bench.Fire("REPLICATE_ITEM_LIST_UPDATE")
bench.Advance(4)
bench.Has("then pages", bench.Calls(), "SendBrowseQuery")
bench.HasNot("no message yet", bench.Chat(), "sent nothing back", true)
bench.Equal("the failed full scan is kept", GoldsmithDB.scanFail and GoldsmithDB.scanFail.method, "full")
bench.Fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
bench.Advance(1)
bench.Has("paging empty too: says so", bench.Chat(), "sent nothing back, so the last scan is kept. Try again in a minute.")
bench.Equal("last scan kept", GoldsmithDB.ownScan, before)
bench.Check("not scanning", not addon:IsScanning())
bench.Done()
