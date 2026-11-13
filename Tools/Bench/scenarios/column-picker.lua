-- Right-click a list's column names to hide or show columns (user,
-- 2026-11-13: "hide or show which columns you want to see"). Crafts,
-- History and each Items view keep their own; the first column always
-- shows; hidden ones still get filled, so showing one again is right
-- straight away.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local ui = GoldsmithDB.ui2
ui.craftsOnlyMine, ui.craftsGear, ui.profession, ui.hiddenColumns = nil, nil, "All", nil
addon:ToggleWindow()
bench.Advance(1)
addon:ShowTab("crafts")
bench.Advance(3)
local crafts = addon:GetTabScreen("crafts").view
local list = crafts.list
for _, child in ipairs({ list:GetChildren() }) do child:SetHeight(600) child:SetWidth(860) end
list:Update()

-- The menu's checkboxes, by label
local function Menu(owner)
    list = owner or list
    list.ColumnMenu(list.headerCells.item or list)
    local boxes, buttons = {}, {}
    local root = { CreateTitle = function() end, CreateDivider = function() end,
        CreateCheckbox = function(_, label, isOn, toggle) boxes[label] = { on = isOn, toggle = toggle } end,
        CreateButton = function(_, label, fn) buttons[label] = fn end }
    bench.world.lastMenu(nil, root)
    return boxes, buttons
end
local function Shown(l, key) local c = l.headerCells[key] return c ~= nil and c:IsShown() end

local boxes, buttons = Menu()
bench.Check("Sold/day in the menu", boxes["Sold/day"] ~= nil)
bench.Check("Item isn't (always shown)", boxes.Item == nil)
bench.Check("Sold/day on", boxes["Sold/day"] and boxes["Sold/day"].on())

-- Hide Sold/day and Have
boxes["Sold/day"].toggle()
Menu()["Have"].toggle()
bench.Check("Sold/day hidden", not Shown(list, "demand"))
bench.Check("Have hidden", not Shown(list, "have"))
bench.Check("Profit still shown", Shown(list, "profit"))
bench.Check("saved", ui.hiddenColumns and ui.hiddenColumns.crafts and ui.hiddenColumns.crafts.demand == true)
local row = list.rows[1]
bench.Check("a row still fills its hidden cell", row and row.cells.demand and (row.cells.demand:GetText() or "") ~= "")
bench.Check("and the hidden cell doesn't show", row and not row.cells.demand:IsShown())
bench.Equal("no errors", #bench.TakeErrors(), 0)

-- The Item column takes the room
local before = list.headerCells.item:GetWidth()
Menu()["Sold/day"].toggle()
bench.Check("shown again", Shown(list, "demand"))
bench.Check("Item narrower with it back", list.headerCells.item:GetWidth() < before)

-- Concentration on, Conc hidden: g/conc still filled
crafts.concentration = true
ui.craftsConcentration = true
addon.RefreshWindow()
bench.Advance(5)
list:Update()
if list.headerCells.conc then
    ui.hiddenColumns.crafts.conc = true
    list:Update()
    local r = list.rows[1]
    bench.Check("Conc hidden", not Shown(list, "conc"))
    bench.Check("g/conc still filled", r and r.cells.gpc and (r.cells.gpc:GetText() or "") ~= "")
end
ui.craftsConcentration = nil
addon.RefreshWindow()
bench.Advance(5)
list:Update()

-- Columns that start hidden: Break-even, Vs usual, Make, Batch, Listed
for _, key in ipairs({ "breakEven", "vsUsual", "make", "batch", "listed" }) do
    bench.Check("starts hidden: " .. key, not Shown(list, key))
end
boxes = Menu()
bench.Check("Break-even off in the menu", boxes["Break-even"] and not boxes["Break-even"].on())
boxes["Break-even"].toggle()
Menu()["Listed"].toggle()
Menu()["Make"].toggle()
bench.Check("Break-even shown", Shown(list, "breakEven"))
bench.Equal("saved as shown", ui.hiddenColumns.crafts.breakEven, false)
-- A row with a cost: its break-even is cost / 0.95
local priced
for _, r in ipairs(list.rows) do
    if r:IsShown() and r.data and not r.data.salvage and r.data.info.cost and r.data.info.cost > 0 then priced = r break end
end
bench.Check("a row with a cost", priced ~= nil)
if priced then
    bench.Has("its break-even", priced.cells.breakEven:GetText() or "",
        addon:FormatMoney(priced.data.info.cost / 0.95), true)
end
-- Make: a number only on rows worth making with none held
for _, r in ipairs(list.rows) do
    if r:IsShown() and r.data then
        local text = r.cells.make:GetText()
        if r.data.whyNot or not (r.data.info.profit and r.data.info.profit > 0) then
            bench.Equal("not worth making: no Make (" .. r.data.recipe.outputName .. ")", text, "-")
        end
    end
end
bench.Equal("no errors with them shown", #bench.TakeErrors(), 0)
-- Hiding one that starts hidden again saves nothing
Menu()["Make"].toggle()
bench.Equal("back as it started: nothing saved", ui.hiddenColumns.crafts.make, nil)

-- Tick everything: the name always keeps its room (with every one ticked
-- the names were an icon and a letter, user 2026-11-13). What doesn't fit
-- says "(no room)" and can't be ticked.
for _ = 1, 6 do
    for label, box in pairs(Menu()) do
        if not box.on() and not label:find("(no room)", 1, true) then box.toggle() end
    end
end
bench.Check("names keep 150 or more", list.headerCells.item:GetWidth() >= 150, tostring(list.headerCells.item:GetWidth()))
local noRoom = 0
for label in pairs(Menu()) do if label:find("(no room)", 1, true) then noRoom = noRoom + 1 end end
bench.Check("some say no room", noRoom > 0)
-- Every shown column inside the list
local right = 0
for key, cell in pairs(list.headerCells) do
    if cell:IsShown() then
        local _, _, _, x = cell:GetPoint(1)
        right = math.max(right, (x or 0) + cell:GetWidth())
    end
end
bench.Check("nothing runs past the list", right <= 860, tostring(right))

-- Default columns
select(2, Menu())["Default columns"]()
bench.Equal("Default columns clears it", ui.hiddenColumns.crafts, nil)
bench.Check("Break-even hidden again", not Shown(list, "breakEven"))

-- History keeps its own
addon:ShowTab("history")
bench.Advance(3)
local history = addon:GetTabScreen("history").view.list
bench.Check("History has its own menu", Menu(history)["Gold"] ~= nil)
Menu(history)["Gold"].toggle()
bench.Check("History: Gold hidden", ui.hiddenColumns.history and ui.hiddenColumns.history.gold == true)
bench.Equal("Crafts untouched", ui.hiddenColumns.crafts, nil)
bench.Equal("no errors after", #bench.TakeErrors(), 0)

-- The Queue has a menu too, with ROI, Sells for and To buy to show
addon:ShowTab("queue")
bench.Advance(3)
local queue = addon:GetTabScreen("queue").view.list
for _, child in ipairs({ queue:GetChildren() }) do child:SetHeight(400) child:SetWidth(860) end
queue:Update()
local qBoxes = Menu(queue)
for _, label in ipairs({ "ROI", "Sells for", "To buy" }) do
    bench.Check("Queue menu: " .. label .. " (off)", qBoxes[label] and not qBoxes[label].on())
end
qBoxes["To buy"].toggle()
-- At the normal width one more fits beside To buy at most: ROI says no room
bench.Check("Queue: ROI no room beside it", Menu(queue)["ROI (no room)"] ~= nil)
bench.Check("Queue: To buy shown", Shown(queue, "toBuy"))
bench.Equal("no errors on the Queue", #bench.TakeErrors(), 0)

-- History: Character, Each and ROI start hidden
ui.hiddenColumns = nil
addon:ShowTab("history")
bench.Advance(3)
history = addon:GetTabScreen("history").view.list
for _, child in ipairs({ history:GetChildren() }) do child:SetHeight(400) child:SetWidth(860) end
history:Update()
local hBoxes = Menu(history)
for _, label in ipairs({ "Character", "Each", "ROI" }) do
    bench.Check("History menu: " .. label .. " (off)", hBoxes[label] and not hBoxes[label].on())
end
hBoxes.Each.toggle()
local sale
for _, r in ipairs(history.rows) do
    local d = r:IsShown() and r.data
    if d and not d.deleted and d.gold and d.gold ~= 0 and tonumber(d.qty) and tonumber(d.qty) > 1 then sale = r break end
end
bench.Check("a row with gold and a quantity", sale ~= nil)
if sale then
    bench.Has("its Each", sale.cells.each:GetText() or "", addon:FormatMoney(math.abs(sale.data.gold) / sale.data.qty), true)
end
bench.Equal("no errors on History", #bench.TakeErrors(), 0)

-- Items, in stock: Break-even and Sell all; cheap materials: Listed
local function ItemsList(bags, cheap)
    ui.itemsInBags, ui.itemsCheap = bags, cheap
    addon:ShowTab("items")
    addon.RefreshWindow()
    bench.Advance(5)
    local l = addon:GetTabScreen("items").view.list
    for _, child in ipairs({ l:GetChildren() }) do child:SetHeight(400) child:SetWidth(860) end
    l:Update()
    return l
end
local stock = ItemsList(true, nil)
local sBoxes = Menu(stock)
bench.Check("In stock menu: Break-even and Sell all", sBoxes["Break-even"] ~= nil and sBoxes["Sell all"] ~= nil)
sBoxes["Sell all"].toggle()
bench.Check("Sell all shown", Shown(stock, "sellAll"))
bench.Equal("saved for the stock view", ui.hiddenColumns["items-stock"].sellAll, false)
local cheapList = ItemsList(nil, true)
local cBoxes = Menu(cheapList)
-- Full at the normal width: Listed needs another hidden, or a wider window
bench.Check("Cheap materials menu: Listed", cBoxes.Listed ~= nil or cBoxes["Listed (no room)"] ~= nil)
bench.Check("Sell all isn't in the cheap view", cBoxes["Sell all"] == nil)
bench.Equal("no errors on Items", #bench.TakeErrors(), 0)
ui.itemsInBags, ui.itemsCheap = nil, nil
ui.hiddenColumns = nil
bench.Done()
