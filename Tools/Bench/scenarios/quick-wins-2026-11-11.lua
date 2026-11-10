-- Idea Board quick wins (user, 2026-11-10): the Version tile opens What's
-- new, "cooldown" as a Crafts search word, craft cost on History rows
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local ui = GoldsmithDB.ui2
ui.craftsOnlyMine, ui.craftsGear, ui.profession, ui.historyKind, ui.historyCharacter = nil, nil, "All", nil, nil
addon:ToggleWindow()
bench.Advance(1)

-- "cooldown": every recipe with a cooldown, ready or not
addon:ShowTab("crafts")
bench.Advance(3)
local crafts = addon:GetTabScreen("crafts").view
local function Names()
    local out = {}
    for _, it in ipairs(crafts.list.items or {}) do out[#out + 1] = it.recipe and it.recipe.outputName or "?" end
    return table.concat(out, ", ")
end
crafts.search = "cooldown"
addon.RefreshWindow()
bench.Advance(10)
bench.Has("School of Gems listed", Names(), "School of Gems", true)
bench.Has("a Mote listed", Names(), "Mote of", true)
crafts.search = "school"
addon.RefreshWindow()
bench.Advance(10)
bench.HasNot("other words still match names only", Names(), "Mote of", true)
crafts.search = ""
addon.RefreshWindow()
bench.Advance(3)

-- History: a craft row's Gold is its batch cost, grey, not in the totals
local rows, totals = addon:GetHistory({ prof = "All", kind = "Craft" })
local row
for _, r in ipairs(rows) do if r.cost and r.qty then row = r break end end
bench.Check("a craft row", row ~= nil)
if row then
    local cells = {}
    local holder = CreateFrame("Frame")
    for _, key in ipairs({ "when", "kind", "item", "qty", "gold", "profit" }) do cells[key] = holder:CreateFontString() end
    addon.HistoryFillRow({ cells = cells }, row)
    bench.Has("its batch cost shows", cells.gold:GetText() or "", addon:FormatMoney(row.cost * row.qty), true)
    bench.HasNot("no minus: no gold moved", cells.gold:GetText() or "", "-", true)
    bench.Equal("not in gold out", totals.goldOut, 0)
end

-- Settings: the Version tile opens What's new
addon:ShowSettings()
bench.Advance(2)
local tile
for _, f in ipairs(bench.wow.frames) do
    if f._text == "Click: what's new" and f:IsVisible() then
        local p = f
        while p and not p._scripts.OnMouseUp do p = p._parent end
        tile = p
    end
end
bench.Check("tile says click", tile ~= nil)
if tile then tile._scripts.OnMouseUp(tile, "LeftButton") end
bench.Advance(1)
bench.Check("Settings closed", not GoldsmithSettings:IsShown())
bench.Has("What's new shows", table.concat(bench.Screen(), "\n"), "Got it", true)
bench.Done()
