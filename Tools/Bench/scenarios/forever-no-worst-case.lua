-- Forever has no multicraft or resourcefulness: a craft's hover says no
-- "Worst case (no procs)" and doesn't explain procs (user, 2026-11-18).
-- Retail still does.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local addon = bench.Login("Mysticmead", { db = db })
local ui = GoldsmithDB.ui2
ui.craftsShow, ui.craftsOnlyMine, ui.profession, ui.craftsGear = "all", true, "All", nil
addon:ToggleWindow()
addon:ShowTab("crafts")
bench.Advance(3)
local view = addon:GetTabScreen("crafts").view
local function Hover()
    for _, child in ipairs({ view.list:GetChildren() }) do child:SetHeight(4000) end
    view.list:Update()
    local text = {}
    for _, r in ipairs(view.list.rows) do
        if r:IsShown() and r.data and not r.data.salvage and not r.data.unlearned then
            local lines = {}
            local addLine, addDouble = GameTooltip.AddLine, GameTooltip.AddDoubleLine
            GameTooltip.AddDoubleLine = function(_, l, rt) table.insert(lines, tostring(l) .. " " .. tostring(rt)) end
            GameTooltip.AddLine = function(_, t) table.insert(lines, tostring(t)) end
            r:GetScript("OnEnter")(r)
            GameTooltip.AddLine, GameTooltip.AddDoubleLine = addLine, addDouble
            table.insert(text, table.concat(lines, " | "))
        end
    end
    return table.concat(text, "\n")
end
local retail = Hover()
bench.Has("retail: worst case", retail, "Worst case (no procs)", true)
addon.isForever = true
addon:DataChanged()
addon.RefreshWindow()
bench.Advance(3)
local forever = Hover()
bench.Check("forever: rows hovered", forever ~= "")
bench.HasNot("forever: no worst case", forever, "Worst case", true)
bench.HasNot("forever: no multicraft talk", forever, "multicraft", true)
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
