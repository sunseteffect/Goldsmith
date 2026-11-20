-- Best crafts on the Overview: most gold for the batch first, as the
-- Characters to-do lists them, and its click shows all of them in
-- Crafts. It showed the top 5 by profit each while the to-do had 12
-- (user, 2026-11-18). Its number to make carries over too.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
-- More Best crafts on one character
db.settings.minROI, db.settings.minLine = 0, 0
local addon = bench.Login("Mysticmead", { db = db })
local best = {}
for _, c in ipairs(addon:GetBestCrafts("All", math.huge)) do
    if c.charKey == addon.charKey then table.insert(best, c) end
end
bench.Check("has Best crafts to show", #best >= 2, #best)
local top = best[1]
for _, c in ipairs(best) do
    if c.profit * c.make > top.profit * top.make then top = c end
end
addon:ToggleWindow()
addon:ShowTab("overview")
bench.Advance(5)
local screen = table.concat(bench.Screen(), "\n")
local overview = screen
-- Your own sort, by name, one that wouldn't put it first
local firstByName = top.recipe.outputName
for _, c in ipairs(best) do
    if c.recipe.outputName < firstByName then firstByName = c.recipe.outputName end
end
GoldsmithDB.ui2.craftSort = { key = "item", descending = firstByName == top.recipe.outputName }
local savedSort = GoldsmithDB.ui2.craftSort
bench.Has("first line: most gold for the batch", screen,
    string.format("%dx %s", top.make, top.recipe.outputName:sub(1, 20)), true)
-- The card isn't a button: it takes the mouse-up
local card
for _, f in ipairs(bench.wow.frames) do
    if f._text and f:IsVisible() and bench.wow.Strip(f._text) == "Best crafts right now" then
        card = f
        while card and not card._scripts.OnMouseUp do card = card._parent end
        break
    end
end
bench.Check("the card", card ~= nil)
if card then card._scripts.OnMouseUp(card, "LeftButton") end
bench.Advance(5)
screen = table.concat(bench.Screen(), "\n")
bench.Has("click shows all of them", screen, string.format("Best crafts right now (%d)", #best), true)

-- The card's number carries over: its plan opens on 6 axes, not 1
-- (user, 2026-11-18)
local id = top.recipe.recipeID
GoldsmithDB.ui2.planCrafts = GoldsmithDB.ui2.planCrafts or {}
GoldsmithDB.ui2.planCrafts[id] = nil
-- The list row (the concentration bar above names it too). The bench's
-- frames are 20 high: make room for the rows.
local list = addon:GetTabScreen("crafts").view.list
for _, child in ipairs({ list:GetChildren() }) do child:SetHeight(600) end
list:Update()
local row
for _, r in ipairs(list.rows) do
    if r:IsShown() and r.data and r.data.key == top.key then row = r break end
end
bench.Check("the row", row ~= nil)
-- In the card's order, most batch profit first; your own sort untouched
local first
for _, r in ipairs(list.rows) do if r:IsShown() and r.data then first = r break end end
bench.Equal("sorted like the card", first and first.data.key, top.key)
bench.Equal("your sort untouched", GoldsmithDB.ui2.craftSort, savedSort)
-- Its Make and Batch columns say what the card said (user, 2026-11-18:
-- "6x Massive Iron Axe +1g93" lost both in Crafts)
if row then
    bench.Equal("Make column: the card's number", row.cells.make and row.cells.make:GetText(), tostring(top.make))
    local batch = row.cells.batch and bench.wow.Strip(row.cells.batch:GetText()) or "-"
    bench.Check("Batch column: a total", batch ~= "-", batch)
    bench.Has("Batch column: the card's total", overview, batch, true)
end
if row then row:Click("LeftButton") end
bench.Advance(3)
local want = addon:WithCharacter(top.charKey, addon.CraftsForItems, addon, top.recipe, top.make)
bench.Equal("plan opens on the card's number", GoldsmithDB.ui2.planCrafts[id], want)
bench.Done()
