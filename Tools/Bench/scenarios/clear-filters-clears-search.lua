-- The Filtered chip counts a tab's search, and clicking it clears the
-- search with the rest (user, 2026-11-18: "if i am clearing filters i have
-- to also clear the search"). Crafts, Items and History.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local ui = GoldsmithDB.ui2
ui.profession, ui.craftsOnlyMine, ui.craftsGear = "All", nil, nil
addon:ToggleWindow()
for _, tab in ipairs({ "crafts", "items", "history" }) do
    addon:ShowTab(tab)
    bench.Advance(3)
    local view = addon:GetTabScreen(tab).view
    view.searchBox:SetText("bar")
    view.search = "bar"
    addon.RefreshWindow()
    bench.Advance(3)
    bench.Has(tab .. ": the chip shows", table.concat(bench.Screen(), " "), "Filtered: ", true)
    bench.Click("Filtered: ", "LeftButton", 3)
    bench.Equal(tab .. ": search cleared", view.search, "")
    bench.Equal(tab .. ": box empty", view.searchBox:GetText(), "")
    bench.HasNot(tab .. ": no chip", table.concat(bench.Screen(), "\n"), "Filtered:", true)
end
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
