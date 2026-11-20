-- Forever sends a full scan's listings in bursts with pauses between. A
-- pause read half the AH (36,121 listings) and the cheap half was missing:
-- Steel Bar at 15s with 66 listed, then 3,375 from 8.45s minutes later,
-- and Buy next paid 15s (user, 2026-11-18). Short of what recent full
-- scans saw, it waits for the rest.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.foreverTest = true
local addon = bench.Login("Mysticmead", { db = db })
local STEEL = 990091
bench.AddItem(STEEL, "Bench Steel", { stack = 20, classID = 7 })
-- Ten listings: the expensive five come first, then a pause, then the
-- cheap five
local listings = {}
for i = 1, 5 do listings[i] = { STEEL, 1, 1500 } end
for i = 6, 10 do listings[i] = { STEEL, 1, 845 } end
local asked, arrived, waited = false, 0, 0
C_AuctionHouse.ReplicateItems = function() asked, arrived, waited = true, 0, 0 end
C_AuctionHouse.GetNumReplicateItems = function()
    if not asked then return 0 end
    if arrived < 5 then
        arrived = arrived + 1
    elseif waited < 8 then
        waited = waited + 1 -- the pause: longer than the 3 s that read too soon
    else
        arrived = math.min(arrived + 1, #listings)
    end
    return arrived
end
C_AuctionHouse.GetReplicateItemInfo = function(i)
    local l = listings[i + 1]
    if not l or i >= arrived then return nil end
    return "x", 0, l[2], 1, true, 1, 0, 0, 0, l[3], 0, false, nil, "someone", nil, 0, l[1], true
end
local function Scan()
    GoldsmithDB.lastFullRequest = 0
    GoldsmithDB.ownScan = nil
    bench.OpenAH()
    bench.Advance(1)
    addon:ScanAH()
    bench.Advance(60)
    bench.CloseAH()
    return GoldsmithDB.ownScan
end

-- A full scan before saw all ten: waits through the pause
GoldsmithDB.fullScanSeen = { { group = addon:RealmGroup(), auctions = 10 } }
local scan = Scan()
bench.Equal("every listing read", scan and scan.auctions, 10)
bench.Equal("the cheap ones priced", scan and scan.prices[STEEL] and scan.prices[STEEL][2], 845)
bench.Equal("its count kept", addon:ExpectedFullListings(), 10)

-- The AH really got smaller: waits up to 3 minutes, then reads what's there
listings = { { STEEL, 1, 900 }, { STEEL, 1, 900 } }
GoldsmithDB.fullScanSeen = { { group = addon:RealmGroup(), auctions = 100 } }
scan = Scan()
bench.Check("not stuck", scan == nil or not addon:IsScanning())
bench.Advance(180)
bench.Check("finished in the end", not addon:IsScanning())
bench.Done()
