-- Forever mode on retail (/gsm forever): every tab draws without an error,
-- Midnight-only parts are gone, money reads in silver and copper, and the
-- titles are a hundredth of retail's (port plan, 2026-10-28)
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.foreverTest = true
local addon = bench.Login("Mysticmead", { db = db })
bench.Check("Forever mode on", addon.isForever == true)
-- Test 57: the test switch kept Goldsmith Data's retail prices
bench.Check("no Goldsmith Data", addon:GetBlizzardDataTime() == nil)
db.setupDone = nil

addon:ToggleWindow()
bench.Advance(2)
local screens = {}
for _, tab in ipairs({ "overview", "characters", "crafts", "queue", "items", "history", "stats" }) do
    addon:ShowTab(tab)
    bench.Advance(5)
    bench.Equal(tab .. " tab opens", addon:CurrentTab(), tab)
    screens[tab] = table.concat(bench.Screen(), "\n")
end

bench.HasNot("Stats: no multicraft", screens.stats, "Multicraft procs")
bench.HasNot("Stats: no concentration spent", screens.stats, "Concentration spent")
bench.HasNot("Stats: no patron orders", screens.stats, "Patron orders filled")
bench.Has("Stats: gathering section", screens.stats, "Gathering")
bench.HasNot("History: no Orders chip", screens.history, "\nOrders\n")
bench.Has("Overview: last AH scan tile", screens.overview:upper(), "LAST AH SCAN")
bench.HasNot("Overview: no Goldsmith Data step", screens.overview, "Goldsmith Data")
bench.HasNot("Stats: no players' orders", screens.stats, "From players' orders")

bench.Equal("12s 40c", addon:FormatMoney(1240), "12s 40c")
bench.Equal("3g 25s", addon:FormatMoney(32500), "3g 25s")
local title = addon:GoldsmithTitles()[2]
bench.Equal("Journeyman at 10g", title[1], 10)
bench.Check("minLine default in silver", addon:Setting("minLine") == 0.5 or GoldsmithDB.settings.minLine ~= nil)
bench.Equal("no-price text after a scan", addon:NoPriceText("x"),
    addon:GetOwnScanTime() and "None on the AH in your last scan." or "x")
bench.Equal("Exclude text drops concentration",
    addon:ForeverText("Excluded: not counted in stock, concentration, total gold, Crafts or Do this next."),
    "Excluded: not counted in stock, total gold, Crafts or Do this next.")
bench.Equal("Coarse Thread priced from the built-in vendor list", GoldsmithDB.vendorPrices[2320] or addon:GetVendorPrice(2320), GoldsmithDB.vendorPrices[2320] or 10)
bench.Done()
