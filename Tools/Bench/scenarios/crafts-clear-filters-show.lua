-- Crafts: clearing filters puts Show back to Recommended (user,
-- 2026-11-10: "the clear filters button doesn't clear the drop down menu
-- to put it back to default"). Not learned yet counts as a filter; All
-- crafts doesn't (it shows more), but clearing resets it too.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local ui = GoldsmithDB.ui2
ui.craftsOnlyMine, ui.craftsGear, ui.profession = nil, nil, "All"
ui.craftsShow = "unlearned"
addon:ToggleWindow()
addon:ShowTab("crafts")
bench.Advance(5)
bench.Has("Not learned yet is a filter", table.concat(bench.Screen(), "\n"), "Filtered: Not learned yet", true)
bench.Click("Filtered")
bench.Advance(3)
bench.Equal("cleared: back to Recommended", ui.craftsShow, nil)

-- All crafts alone isn't a filter
ui.craftsShow = "all"
addon.RefreshWindow()
bench.Advance(3)
bench.HasNot("All crafts alone: not Filtered", table.concat(bench.Screen(), "\n"), "Filtered:", true)

-- With Only <name> on, clearing resets Show as well
ui.craftsOnlyMine = true
addon.RefreshWindow()
bench.Advance(3)
bench.Click("Filtered")
bench.Advance(3)
bench.Equal("Only me cleared", ui.craftsOnlyMine, nil)
bench.Equal("Show back to Recommended", ui.craftsShow, nil)
bench.Done()
