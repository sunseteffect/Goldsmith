-- With TSM, an item without 5 days of its own prices shows TSM's region
-- sale average as its usual price, so "where does it normally sit" has an
-- answer the first time its page opens (user, 2026-11-16: Frost Tiger Blade)
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local addon = bench.Login("Mysticmead", { db = db })
local BLADE = 990001
bench.AddItem(BLADE, "Bench Tiger Blade", {})
local values = { dbregionsaleavg = 11800, dbregionmarketavg = 24000, dbregionhistorical = 22400 }
TSM_API = { GetCustomPriceValue = function(source, item)
    if item == "i:" .. BLADE then return values[source:lower()] end
end }

local region = addon:GetRegionPrices(BLADE)
bench.Check("region prices", region and region.sold == 11800 and region.listed == 24000 and region.long == 22400)
bench.Equal("none for an item TSM lacks", addon:GetRegionPrices(990002), nil)

addon:ToggleWindow()
addon:OpenItem("Bench Tiger Blade", BLADE)
bench.Advance(3)
local screen = bench.Screen()
bench.Has("tile says where it's from", screen, "region sales (TSM)", true)
bench.HasNot("no 'needs 5 days' on the tile", screen, "needs 5 days", true)

-- No sale average: what it's listed at, said so
values.dbregionsaleavg = nil
addon:OpenItem("Bench Tiger Blade", BLADE)
addon.RefreshWindow()
bench.Advance(3)
bench.Has("listings when nothing sold", bench.Screen(), "region listings (TSM)", true)
bench.Done()
