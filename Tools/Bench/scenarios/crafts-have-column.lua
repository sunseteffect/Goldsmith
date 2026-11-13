-- The Crafts list's Have column: how many you own of what the row makes,
-- in bags and banks on every character, the warband bank, the mail and
-- listed on the AH ("display the current owned amount of that item
-- (already posted on AH, in the bags/bank etc.)", puvesis, CurseForge,
-- 2026-11-13). The hover says where they are.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local ui = GoldsmithDB.ui2
ui.craftsOnlyMine, ui.craftsGear, ui.profession = nil, nil, "All"
addon:ToggleWindow()
bench.Advance(1)
addon:ShowTab("crafts")
bench.Advance(3)
local crafts = addon:GetTabScreen("crafts").view

local function FindRow(itemID)
    for _, row in ipairs(crafts.list.rows) do
        if row:IsShown() and row.data and (itemID == nil and row.data.itemID and not row.data.salvage
            and not addon:IsGear(row.data.itemID) or row.data.itemID == itemID) then return row end
    end
end
-- The bench's frames are 20 high: make room for some rows
for _, child in ipairs({ crafts.list:GetChildren() }) do child:SetHeight(600) end
crafts.list:Update()
local row = FindRow()
bench.Check("a craft row shows", row ~= nil)
if not row then bench.Done() return end
local itemID = row.data.itemID

-- None anywhere, then 5 in another character's bank, 3 listed by a third,
-- 2 in this one's mail
local others = {}
for key, c in pairs(GoldsmithDB.characters) do
    c.stock[itemID], c.auctions[itemID] = nil, nil
    if c.stockBank then c.stockBank[itemID] = nil end
    if key ~= addon.charKey then others[#others + 1] = key end
end
table.sort(others)
GoldsmithDB.warbandStock[itemID] = nil
GoldsmithDB.inMail = GoldsmithDB.inMail or {}
for _, book in pairs(GoldsmithDB.inMail) do book[itemID] = nil end
addon:DataChanged()
addon.RefreshWindow()
bench.Advance(3)
crafts.list:Update()
row = FindRow(itemID)
bench.Equal("none: a dash", row and row.cells.have:GetText(), "-")

GoldsmithDB.characters[others[1]].stock[itemID] = 5
GoldsmithDB.characters[others[2]].auctions[itemID] = 3
GoldsmithDB.inMail[addon.charKey] = GoldsmithDB.inMail[addon.charKey] or {}
GoldsmithDB.inMail[addon.charKey][itemID] = { quantity = 2 }
addon:DataChanged()
addon.RefreshWindow()
bench.Advance(3)
crafts.list:Update()
row = FindRow(itemID)
bench.Equal("bank, AH and mail all count", row and row.cells.have:GetText(), "10")

-- The hover: where they are
local lines = {}
local addLine, addDouble = GameTooltip.AddLine, GameTooltip.AddDoubleLine
GameTooltip.AddDoubleLine = function(_, left, right) table.insert(lines, tostring(left) .. " " .. tostring(right)) end
GameTooltip.AddLine = function(_, text) table.insert(lines, tostring(text)) end
row:GetScript("OnEnter")(row)
GameTooltip.AddLine, GameTooltip.AddDoubleLine = addLine, addDouble
local tip = table.concat(lines, " | ")
local function Name(key) return GoldsmithDB.characters[key].name end
bench.Has("hover: the total", tip, "You have 10", true)
bench.Has("hover: in the bags", tip, Name(others[1]) .. " 5 (bags)", true)
bench.Has("hover: on the AH", tip, Name(others[2]) .. " 3 (on the AH)", true)
bench.Has("hover: in the mail", tip, Name(addon.charKey) .. " 2 (mail)", true)

-- Some in the bank too: the split on one line
GoldsmithDB.characters[others[1]].stock[itemID] = 8
GoldsmithDB.characters[others[1]].stockBank = GoldsmithDB.characters[others[1]].stockBank or {}
GoldsmithDB.characters[others[1]].stockBank[itemID] = 3
GoldsmithDB.characters[others[1]].auctions[itemID] = 1
addon:DataChanged()
lines = {}
GameTooltip.AddDoubleLine = function(_, left, right) table.insert(lines, tostring(left) .. " " .. tostring(right)) end
GameTooltip.AddLine = function(_, text) table.insert(lines, tostring(text)) end
row:GetScript("OnEnter")(row)
GameTooltip.AddLine, GameTooltip.AddDoubleLine = addLine, addDouble
bench.Has("hover: bags, bank and AH", table.concat(lines, " | "), Name(others[1]) .. " 9 (5 bags, 3 bank, 1 on the AH)", true)
GameTooltip:Hide()

-- Sorts by it, most first
ui.craftSort = { key = "have", descending = true }
addon.RefreshWindow()
bench.Advance(3)
crafts.list:Update()
local top = crafts.list.rows[1] and crafts.list.rows[1].cells.have:GetText()
bench.Check("sorted: the top row has the most", tonumber(top) and tonumber(top) >= 10, tostring(top))
ui.craftSort = nil
bench.Done()
