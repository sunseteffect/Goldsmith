-- History's summary line leaves out a side with nothing in it: Sales
-- alone read "out 0.00g", as if something were broken (user, 2026-10-27)
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
addon:ToggleWindow()
addon:ShowTab("history")
bench.Advance(3)
local function Summary()
    for _, line in ipairs(bench.Screen()) do
        if line:match("^%d+ entr") then return line end
    end
    return ""
end
GoldsmithDB.ui2.historyKind = nil
addon.RefreshWindow()
bench.Advance(3)
local all = Summary()
bench.Has("All: gold in", all, "in ", true)
bench.Has("All: gold out", all, "out ", true)
GoldsmithDB.ui2.historyKind = "Sale"
addon.RefreshWindow()
bench.Advance(3)
local sales = Summary()
bench.Has("Sales: gold in", sales, "in ", true)
bench.HasNot("Sales: no out", sales, "out ", true)
GoldsmithDB.ui2.historyKind = "Purchase"
addon.RefreshWindow()
bench.Advance(3)
local bought = Summary()
bench.Has("Purchases: gold out", bought, "out ", true)
bench.HasNot("Purchases: no in", bought, " in ", true)
bench.Done()
