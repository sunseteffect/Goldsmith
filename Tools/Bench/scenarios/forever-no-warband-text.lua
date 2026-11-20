-- Forever has no warband bank: the gold chart and other text don't name
-- one (user, 2026-11-18: "all characters and warband bank, now 38g").
-- Retail still does.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
bench.Equal("retail: names it", addon:AndWarband(), " and the warband bank")
addon.isForever = true
bench.Equal("forever: nothing", addon:AndWarband(), "")
bench.Equal("forever: nothing for other wording", addon:AndWarband(" or in the warband bank"), "")
addon:ToggleWindow()
addon:ShowTab("overview")
bench.Advance(5)
local screen = table.concat(bench.Screen(), "\n")
bench.HasNot("forever: no warband on the Overview", screen, "warband", true)
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
