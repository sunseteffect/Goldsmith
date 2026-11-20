-- Crafts: right-click "Add N to the queue" and a click into the plan use
-- the Make column's number, not the last plan's: Big Bronze Knife offered
-- 3 with Make saying 1 (user, 2026-11-18).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.queues = {}
local addon = bench.Login("Mysticmead", { db = db })
local ui = GoldsmithDB.ui2
ui.craftsShow, ui.craftsOnlyMine, ui.profession, ui.craftsGear, ui.hiddenColumns = "all", true, "All", nil, nil
addon:ToggleWindow()
addon:ShowTab("crafts")
bench.Advance(3)
local view = addon:GetTabScreen("crafts").view
for _, child in ipairs({ view.list:GetChildren() }) do child:SetHeight(4000) end
view.list:Update()
local row, make
for _, r in ipairs(view.list.rows) do
    local n = r:IsShown() and r.data and not r.data.salvage and tonumber(r.cells.make and r.cells.make:GetText())
    if n and n > 0 then row, make = r, n break end
end
bench.Check("a row with a Make number (what this tests)", row ~= nil)
if not row then return bench.Done() end
-- Last planned something else
local recipe = row.data.recipe
ui.planCrafts = ui.planCrafts or {}
ui.planCrafts[recipe.recipeID] = make + 5

local labels = {}
row:Click("RightButton")
bench.Advance(1)
local root = { CreateTitle = function() end, CreateDivider = function() end,
    CreateButton = function(_, label) table.insert(labels, label) end, CreateCheckbox = function() end }
if bench.world.lastMenu then bench.world.lastMenu(nil, root) end
local text = table.concat(labels, " | ")
bench.Has("menu: the Make number", text, string.format("Add %d to", make), true)

-- Click: the plan opens on it too
row:Click("LeftButton")
bench.Advance(3)
local want = addon:WithCharacter(row.data.charKey, addon.CraftsForItems, addon, recipe, make)
bench.Equal("plan opens on the Make number", ui.planCrafts[recipe.recipeID], want)
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
