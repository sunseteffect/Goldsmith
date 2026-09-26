local addon = _G.Goldsmith or {}

local FRAME_WIDTH = 775
local FRAME_HEIGHT = 520
local ROW_HEIGHT = 18
local LIST_WIDTH = FRAME_WIDTH - 50

-- Columns: x offset, width, justification

local LOG_COLUMNS = {
    { key = "date",  label = "Date",  x = 0,   width = 80,  justify = "LEFT" },
    { key = "type",  label = "Type",  x = 85,  width = 50,  justify = "LEFT" },
    { key = "item",  label = "Item",  x = 140, width = 175, justify = "LEFT" },
    { key = "qty",   label = "Qty",   x = 320, width = 40,  justify = "RIGHT" },
    { key = "gold",  label = "Gold",  x = 365, width = 95,  justify = "RIGHT" },
}

local CRAFT_COLUMNS = {
    { key = "item",   label = "Item",     x = 0,   width = 245, justify = "LEFT" },
    { key = "cost",   label = "Cost",     x = 249, width = 62,  justify = "RIGHT" },
    { key = "price",  label = "AH price", x = 315, width = 62,  justify = "RIGHT" },
    { key = "profit", label = "Profit",   x = 381, width = 64,  justify = "RIGHT" },
    { key = "margin", label = "Margin",   x = 449, width = 54,  justify = "RIGHT" },
    { key = "conc",   label = "Conc",     x = 507, width = 44,  justify = "RIGHT" },
    { key = "gpc",    label = "g/conc",   x = 555, width = 56,  justify = "RIGHT" },
    { key = "demand", label = "Sold/day", x = 615, width = 62,  justify = "RIGHT" },
    { key = "age",    label = "Age",      x = 681, width = 40,  justify = "RIGHT" },
}

-- Short age for the Age column: the scan time ("14:32") for prices seen
-- today, otherwise days old ("1d", "3d")
local function ShortAge(days)
    if not days then return "-" end
    if days == 0 then
        return addon:GetTodayScanTime() or "today"
    end
    return days .. "d"
end

-- Calendar days between a timestamp and today (yesterday 23:00 is 1 day)
local function DaysAgo(timestamp)
    local today = date("*t")
    local midnight = time({ year = today.year, month = today.month, day = today.day, hour = 0 })
    if timestamp >= midnight then return 0 end
    return math.floor((midnight - timestamp) / 86400) + 1
end

local function FormatGold(copper)
    return string.format("%.2fg", copper / 10000)
end

local function FormatSigned(copper)
    return (copper >= 0 and "+" or "-") .. FormatGold(math.abs(copper))
end

local function CreateColumns(parent, columns, fontObject)
    local cells = {}
    for _, col in ipairs(columns) do
        local fs = parent:CreateFontString(nil, "OVERLAY", fontObject)
        fs:SetPoint("LEFT", parent, "LEFT", col.x, 0)
        fs:SetWidth(col.width)
        fs:SetJustifyH(col.justify)
        fs:SetWordWrap(false)
        cells[col.key] = fs
    end
    return cells
end

-- A scrolling list with a header row. Rows are created as needed and reused.
-- handlers: onEnter(row), onLeftClick(row), onRightClick(row),
-- onHeaderClick(columnKey), and optional top/bottom offsets for placement.
-- Each row's data is row.data. With onHeaderClick, column headers are
-- clickable and list:SetSortIndicator marks the sorted column.
local function CreateList(parent, columns, emptyMessage, handlers)
    local list = CreateFrame("Frame", nil, parent)
    list:SetPoint("TOPLEFT", parent, "TOPLEFT", 16, handlers.top or -152)
    list:SetPoint("BOTTOMRIGHT", parent, "BOTTOMRIGHT", -34, handlers.bottom or 66)

    local header = CreateFrame("Frame", nil, list)
    header:SetPoint("TOPLEFT", list, "TOPLEFT")
    header:SetSize(LIST_WIDTH, ROW_HEIGHT)
    local headerCells = CreateColumns(header, columns, "GameFontNormalSmall")
    for _, col in ipairs(columns) do
        headerCells[col.key]:SetText(col.label)
        if handlers.onHeaderClick then
            -- A plain mouse-enabled frame using OnMouseUp, so clicks work
            -- regardless of button click registration, raised above the header
            local hit = CreateFrame("Frame", nil, header)
            hit:SetPoint("LEFT", header, "LEFT", col.x, 0)
            hit:SetSize(col.width, ROW_HEIGHT)
            hit:SetFrameLevel(header:GetFrameLevel() + 10)
            hit:EnableMouse(true)
            local highlight = hit:CreateTexture(nil, "HIGHLIGHT")
            highlight:SetAllPoints()
            highlight:SetColorTexture(1, 1, 1, 0.1)
            hit:SetScript("OnMouseUp", function(_, button)
                if button == "LeftButton" then
                    handlers.onHeaderClick(col.key)
                end
            end)
        end
    end

    -- Arrow after the sorted column's label: v for descending, ^ for ascending
    function list:SetSortIndicator(sortKey, descending)
        for _, col in ipairs(columns) do
            local label = col.label
            if col.key == sortKey then
                label = col.justify == "RIGHT"
                    and ((descending and "v " or "^ ") .. label)
                    or (label .. (descending and " v" or " ^"))
            end
            headerCells[col.key]:SetText(label)
        end
    end

    local scroll = CreateFrame("ScrollFrame", nil, list, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", header, "BOTTOMLEFT", 0, -4)
    scroll:SetPoint("BOTTOMRIGHT", list, "BOTTOMRIGHT")

    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(LIST_WIDTH, 1)
    scroll:SetScrollChild(content)

    local emptyText = content:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    emptyText:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -4)
    emptyText:SetWidth(LIST_WIDTH)
    emptyText:SetJustifyH("LEFT")
    emptyText:SetText(emptyMessage)

    local rows = {}

    local function GetRow(i)
        if rows[i] then return rows[i] end

        local row = CreateFrame("Frame", nil, content)
        row:SetSize(LIST_WIDTH, ROW_HEIGHT)
        row:SetPoint("TOPLEFT", content, "TOPLEFT", 0, -(i - 1) * ROW_HEIGHT)
        row.cells = CreateColumns(row, columns, "GameFontHighlightSmall")

        if i % 2 == 0 then
            local bg = row:CreateTexture(nil, "BACKGROUND")
            bg:SetAllPoints()
            bg:SetColorTexture(1, 1, 1, 0.05)
        end

        row:EnableMouse(true)
        row:SetScript("OnEnter", function(self)
            if self.data and handlers.onEnter then handlers.onEnter(self) end
        end)
        row:SetScript("OnLeave", GameTooltip_Hide)
        row:SetScript("OnMouseUp", function(self, button)
            if not self.data then return end
            if button == "RightButton" and handlers.onRightClick then
                handlers.onRightClick(self)
            elseif button == "LeftButton" and handlers.onLeftClick then
                handlers.onLeftClick(self)
            end
        end)

        rows[i] = row
        return row
    end

    function list:SetEmptyText(text)
        emptyText:SetText(text)
    end

    -- fill(row, item) sets the row's cell text for one item
    function list:SetItems(items, fill)
        for i, item in ipairs(items) do
            local row = GetRow(i)
            row.data = item
            for _, cell in pairs(row.cells) do
                cell:SetTextColor(1, 1, 1)
            end
            fill(row, item)
            row:Show()
        end
        for i = #items + 1, #rows do
            rows[i]:Hide()
            rows[i].data = nil
        end
        content:SetHeight(math.max(#items * ROW_HEIGHT, 1))
        emptyText:SetShown(#items == 0)
    end

    return list
end

-- Log tab

local TYPE_LABELS = {
    PURCHASE = { short = "Buy",  long = "Purchase" },
    DEPOSIT  = { short = "Deposit", long = "AH deposit" },
    REVENUE  = { short = "Sell", long = "Sale" },
}

local function GetTypeLabel(e)
    if e.type == "REVENUE" then
        return TYPE_LABELS.REVENUE
    end
    return TYPE_LABELS[e.kind or "PURCHASE"]
end

StaticPopupDialogs["GOLDSMITH_DELETE_ENTRY"] = {
    text = "Delete this entry?\n\n%s",
    button1 = YES,
    button2 = NO,
    OnAccept = function(self, id)
        addon.ledger:remove(id)
        if addon.Refresh then addon.Refresh() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

local function ShowEntryTooltip(row)
    local e = row.data
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(e.item, 1, 1, 1)
    GameTooltip:AddDoubleLine("Type", GetTypeLabel(e).long)
    GameTooltip:AddDoubleLine("Quantity", e.quantity)
    GameTooltip:AddDoubleLine("Total", FormatGold(e.totalCopper))
    GameTooltip:AddDoubleLine("Each", FormatGold(e.totalCopper / e.quantity))
    if e.costBasis then
        local profit = e.totalCopper - e.costBasis
        GameTooltip:AddDoubleLine("Cost you", FormatGold(e.costBasis) .. (e.costPartial and "+" or ""))
        local r, g, b = 0.3, 1, 0.3
        if profit < 0 then r, g, b = 1, 0.3, 0.3 end
        GameTooltip:AddDoubleLine(e.costPartial and "Profit (at most)" or "Profit",
            FormatSigned(profit), 1, 0.82, 0, r, g, b)
    end
    GameTooltip:AddDoubleLine("Profession", e.profession)
    GameTooltip:AddDoubleLine("Character", e.character .. " - " .. e.realm)
    GameTooltip:AddDoubleLine("When", date("%Y-%m-%d %H:%M", e.timestamp))
    GameTooltip:AddLine("Right-click to assign or delete", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

local function ConfirmDeleteEntry(e)
    local summary = string.format("%s %s x%d (%s)",
        GetTypeLabel(e).long, e.item, e.quantity, FormatGold(e.totalCopper))
    StaticPopup_Show("GOLDSMITH_DELETE_ENTRY", summary, nil, e.id)
end

-- Right-click menu on a log row: assign the item to a profession, or delete
-- the entry. Falls back to straight delete without the newer menu API.
local function ShowEntryMenu(row)
    local e = row.data
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        ConfirmDeleteEntry(e)
        return
    end
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(e.item)
        local assign = root:CreateButton("Assign to profession")
        for _, prof in ipairs(addon:GetProfessions()) do
            assign:CreateRadio(prof,
                function() return e.profession == prof end,
                function() addon:AssignItem(e.item, prof) end)
        end
        root:CreateButton("Delete this entry", function() ConfirmDeleteEntry(e) end)
    end)
end

local function FillLogRow(row, e)
    local isCost = e.type == "COST"
    row.cells.date:SetText(date("%m/%d %H:%M", e.timestamp))
    row.cells.type:SetText(GetTypeLabel(e).short)
    row.cells.item:SetText(addon:ProfessionIconText(e.profession) .. e.item)
    row.cells.qty:SetText(e.quantity)
    row.cells.gold:SetText((isCost and "-" or "+") .. FormatGold(e.totalCopper))
    if isCost then
        row.cells.gold:SetTextColor(1, 0.3, 0.3)
    else
        row.cells.gold:SetTextColor(0.3, 1, 0.3)
    end
end

-- Stock tab

local STOCK_COLUMNS = {
    { key = "item",   label = "Material", x = 0,   width = 190, justify = "LEFT" },
    { key = "qty",    label = "Qty",      x = 195, width = 45,  justify = "RIGHT" },
    { key = "each",   label = "Each",     x = 245, width = 70,  justify = "RIGHT" },
    { key = "value",  label = "Value",    x = 320, width = 80,  justify = "RIGHT" },
    { key = "source", label = "Valued at", x = 405, width = 60, justify = "RIGHT" },
}

local SOURCE_SHORT = {
    ["paid"] = "paid",
    ["milled"] = "milled",
    ["paid+milled"] = "paid+mill",
    ["AH price"] = "AH",
}

local function FillStockRow(row, m)
    row.cells.item:SetText(addon:ProfessionIconText(m.profession) .. m.name)
    row.cells.qty:SetText(m.count)
    row.cells.each:SetText(m.unitValue and FormatGold(m.unitValue) or "-")
    row.cells.value:SetText(m.value and FormatGold(m.value) or "-")
    row.cells.source:SetText(m.source and (SOURCE_SHORT[m.source] or m.source) or "no data")
    row.cells.source:SetTextColor(0.6, 0.6, 0.6)
end

local function ShowStockTooltip(row)
    local m = row.data
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(m.itemID)
    GameTooltip:Show()
end

-- Deals tab: materials priced below (or above) their usual price

local DEAL_COLUMNS = {
    { key = "item",  label = "Material",  x = 0,   width = 200, justify = "LEFT" },
    { key = "now",   label = "Now",       x = 204, width = 70,  justify = "RIGHT" },
    { key = "usual", label = "Usual",     x = 278, width = 70,  justify = "RIGHT" },
    { key = "diff",  label = "vs usual",  x = 352, width = 66,  justify = "RIGHT" },
    { key = "range", label = "Low - high", x = 422, width = 120, justify = "RIGHT" },
    { key = "days",  label = "Days",      x = 546, width = 40,  justify = "RIGHT" },
    { key = "have",  label = "Have",      x = 590, width = 46,  justify = "RIGHT" },
}

local function FillDealRow(row, d)
    local tier = C_TradeSkillUI.GetItemReagentQualityByItemInfo
        and C_TradeSkillUI.GetItemReagentQualityByItemInfo(d.itemID)
    local qualityIcon = (tier and tier > 0) and (" " .. addon:TierIconText(tier, 2)) or ""
    row.cells.item:SetText(addon:ProfessionIconText(d.profession) .. d.name .. qualityIcon)
    row.cells.now:SetText(FormatGold(d.now))
    row.cells.usual:SetText(FormatGold(d.usual))
    row.cells.diff:SetText(string.format("%+.0f%%", d.diff * 100))
    -- Green: a good time to stock up; orange: pricier than usual
    if d.diff <= -0.15 then
        row.cells.diff:SetTextColor(0.3, 1, 0.3)
    elseif d.diff >= 0.15 then
        row.cells.diff:SetTextColor(1, 0.6, 0.2)
    end
    row.cells.range:SetText(FormatGold(d.low) .. " - " .. FormatGold(d.high))
    row.cells.days:SetText(d.days)
    row.cells.have:SetText(d.have > 0 and d.have or "-")
end

local function ShowDealTooltip(row)
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:SetItemByID(row.data.itemID)
    GameTooltip:Show()
end

-- Crafts tab

-- Tooltip for one quality tier of a craft: how it's reached, what it costs
-- in materials and concentration, and every combination Goldsmith checked
local function ShowTierTooltip(row)
    local item = row.data
    local t = item.info
    GameTooltip:AddLine(string.format("Tier %d of %d %s", t.tier, t.tierCount,
        addon:TierIconText(t.tier, t.tierCount)), 1, 0.82, 0)
    GameTooltip:AddDoubleLine("How", (t.description or "") .. (t.concentrate and " + concentration" or ""),
        1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Cost", FormatGold(t.cost) .. (t.partial and "+" or "") .. " each", 1, 0.82, 0, 1, 1, 1)
    if t.price then
        GameTooltip:AddDoubleLine("AH price", FormatGold(t.price) .. " each", 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Profit", FormatSigned(t.profit) .. " each", 1, 0.82, 0,
            t.profit >= 0 and 0.3 or 1, t.profit >= 0 and 1 or 0.3, 0.3)
    else
        GameTooltip:AddLine("No AH price for this tier (scan with Auctionator)", 0.6, 0.6, 0.6)
    end
    if t.concentrate then
        GameTooltip:AddDoubleLine("Concentration", string.format("about %d per craft (after ingenuity)",
            t.concentration), 1, 0.82, 0, 1, 1, 1)
        if t.concentrationValue then
            -- Extra profit per craft from concentrating, per point spent
            GameTooltip:AddDoubleLine("Worth", string.format("%s per concentration point",
                FormatSigned(t.concentrationValue)), 1, 0.82, 0, 1, 1, 1)
        end
    end

    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Combinations checked (cost / profit each):", 1, 0.82, 0)
    for _, e in ipairs(t.scenarios) do
        local left = string.format("  %s%s %s", e.description or "",
            e.concentrate and string.format(" + %d conc", e.concentration) or "",
            addon:TierIconText(e.tier, e.tierCount or t.tierCount))
        local right = FormatGold(e.cost) .. " / " .. (e.profit and FormatSigned(e.profit) or "no price")
        -- The one this row uses is highlighted
        local c = (e.scenario == t.scenario) and 1 or 0.75
        GameTooltip:AddDoubleLine(left, right, c, c, c, c, c, c)
    end
end

local function ShowCraftTooltip(row)
    local item = row.data
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(item.recipe.outputName, 1, 1, 1)
    if item.tier then
        ShowTierTooltip(row)
    else
        if item.info.price then
            GameTooltip:AddDoubleLine("AH price", FormatGold(item.info.price) .. " each", 1, 0.82, 0, 1, 1, 1)
        else
            GameTooltip:AddLine("No AH price (scan with Auctionator)", 0.6, 0.6, 0.6)
        end
        addon:AddRecipeTooltipLines(GameTooltip, item.recipe, nil, true)
    end
    GameTooltip:AddLine("Click to plan: buy vs craft, quantity, shopping list", 0.3, 1, 0.3)
    GameTooltip:Show()
end

local function FillCraftRow(row, item)
    local info = item.info
    local tierIcon = item.tier and (" " .. addon:TierIconText(item.tier, info.tierCount)) or ""
    row.cells.item:SetText(addon:ProfessionIconText(item.recipe.profession) .. item.recipe.outputName .. tierIcon)
    if item.tier and info.concentrate then
        row.cells.conc:SetText(string.format("%d", info.concentration))
        row.cells.conc:SetTextColor(1, 0.82, 0)
    else
        row.cells.conc:SetText("-")
    end
    -- Gold per concentration point: extra profit per craft from
    -- concentrating, divided by the concentration it uses
    if item.tier and info.concentrate and info.concentrationValue then
        row.cells.gpc:SetText(string.format("%.2fg", info.concentrationValue / 10000))
        if info.concentrationValue <= 0 or not info.profit or info.profit <= 0 then
            row.cells.gpc:SetTextColor(1, 0.3, 0.3)
        else
            row.cells.gpc:SetTextColor(1, 0.82, 0)
        end
    else
        row.cells.gpc:SetText("-")
    end
    row.cells.cost:SetText(FormatGold(info.cost) .. (info.partial and "+" or ""))
    row.cells.price:SetText(info.price and FormatGold(info.price) or "-")

    if info.profit then
        row.cells.profit:SetText(FormatSigned(info.profit) .. (info.partial and "*" or ""))
        row.cells.margin:SetText(info.margin and string.format("%.0f%%", info.margin) or "-")
        local r, g, b = 0.3, 1, 0.3
        if info.profit < 0 then r, g, b = 1, 0.3, 0.3 end
        row.cells.profit:SetTextColor(r, g, b)
        row.cells.margin:SetTextColor(r, g, b)
    else
        row.cells.profit:SetText("-")
        row.cells.margin:SetText("-")
    end

    row.cells.demand:SetText(addon:FormatDemand(info.demand))
    -- Gray when it's only your own sales, which undercount the market
    if info.demandSource == "your sales" then
        row.cells.demand:SetTextColor(0.6, 0.6, 0.6)
    end

    -- Age column: scan time/days for Auctionator, or the source otherwise.
    -- "TSM*" means a suspected undercut was replaced by TSM's market value.
    local source = info.priceSource
    if source == "Live" then
        row.cells.age:SetText("live")
        row.cells.age:SetTextColor(0.3, 1, 0.3)
    elseif source == "TSM" then
        row.cells.age:SetText("TSM")
    elseif source == "TSM market" then
        row.cells.age:SetText("TSM*")
        row.cells.age:SetTextColor(1, 0.82, 0)
    elseif source == "Vendor" then
        row.cells.age:SetText("vendor")
    else
        row.cells.age:SetText(info.price and ShortAge(info.priceAge) or "-")
        -- Prices a few days old may be well off the current market
        if info.priceAge and info.priceAge >= 3 then
            row.cells.age:SetTextColor(1, 0.6, 0.2)
        end
    end
end

-- Expansion filter. GoldsmithDB.ui.expansions is a set of expansion IDs to
-- show; until you change it, only the current expansion is shown.
local function IsExpansionShown(expansionID)
    -- Items not in the game's cache yet are shown until their data loads
    if expansionID == nil then return true end
    local selected = GoldsmithDB.ui.expansions
    if not selected then
        return expansionID == addon:GetCurrentExpansion()
    end
    return selected[expansionID] == true
end

local function SetExpansionShown(expansionID, shown)
    if not GoldsmithDB.ui.expansions then
        GoldsmithDB.ui.expansions = { [addon:GetCurrentExpansion()] = true }
    end
    GoldsmithDB.ui.expansions[expansionID] = shown or nil
end

-- Expansions that have at least one saved (sellable) recipe, newest first
local function GetRecipeExpansions()
    local seen, list = {}, {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        local expansionID = addon:GetItemExpansion(recipe.outputItemID)
        if expansionID and not seen[expansionID] and addon:CanAuction(recipe.outputItemID) ~= false then
            seen[expansionID] = true
            table.insert(list, expansionID)
        end
    end
    -- Always offer the current expansion, even with no recipes saved yet
    local current = addon:GetCurrentExpansion()
    if not seen[current] then
        table.insert(list, current)
    end
    table.sort(list, function(a, b) return a > b end)
    return list
end

-- Crafts tab sorting. Clicking a header sorts by that column; clicking it
-- again reverses. Each column starts in the direction that's most useful:
-- names A-Z, cheapest cost first, highest price/profit/margin first,
-- freshest prices first. The default is Profit, highest first.
local CRAFT_SORTS = {
    item   = { firstDescending = false, value = function(i) return i.recipe.outputName .. (i.tier or "") end },
    conc   = { firstDescending = false, value = function(i) return i.info.concentrate and i.info.concentration or nil end },
    gpc    = { firstDescending = true,  value = function(i) return i.info.concentrate and i.info.concentrationValue or nil end },
    cost   = { firstDescending = false, value = function(i) return i.info.cost end },
    price  = { firstDescending = true,  value = function(i) return i.info.price end },
    profit = { firstDescending = true,  value = function(i) return i.info.profit end },
    margin = { firstDescending = true,  value = function(i) return i.info.margin end },
    demand = { firstDescending = true,  value = function(i) return i.info.demand end },
    age    = { firstDescending = false, value = function(i) return i.info.price and i.info.priceAge end },
}
local DEFAULT_CRAFT_SORT = { key = "profit", descending = true }

local function GetCraftSort()
    local sort = GoldsmithDB.ui.craftSort
    if not sort or not CRAFT_SORTS[sort.key] then
        return DEFAULT_CRAFT_SORT
    end
    return sort
end

local function OnCraftHeaderClick(key)
    if not CRAFT_SORTS[key] then return end
    local current = GetCraftSort()
    if current.key == key then
        GoldsmithDB.ui.craftSort = { key = key, descending = not current.descending }
    else
        GoldsmithDB.ui.craftSort = { key = key, descending = CRAFT_SORTS[key].firstDescending }
    end
    addon.Refresh()
end

-- Rows with no value for the sorted column (e.g. no AH price) always go
-- last, whichever direction; ties fall back to name.
local function SortCraftItems(items)
    local sort = GetCraftSort()
    local getValue = CRAFT_SORTS[sort.key].value
    table.sort(items, function(a, b)
        local va, vb = getValue(a), getValue(b)
        if va ~= nil and vb ~= nil and va ~= vb then
            if sort.descending then return va > vb end
            return va < vb
        end
        if (va == nil) ~= (vb == nil) then
            return va ~= nil
        end
        if a.recipe.outputName ~= b.recipe.outputName then
            return a.recipe.outputName < b.recipe.outputName
        end
        if (a.tier or 0) ~= (b.tier or 0) then
            return (a.tier or 0) < (b.tier or 0)
        end
        -- Same tier: the way without concentration first
        return (not a.info.concentrate) and (b.info.concentrate == true)
    end)
end

-- Crafts that can't be listed on the AH (bind on pickup, warbound) are left
-- out. Items not in the game's cache yet are shown until their bind type loads.
local function GetCraftItems(prof)
    local items = {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        if (prof == "All" or recipe.profession == prof)
            and addon:CanAuction(recipe.outputItemID) ~= false
            and IsExpansionShown(addon:GetItemExpansion(recipe.outputItemID)) then
            -- Crafts with quality tiers get a row per reachable tier;
            -- the rest a single row
            local tierRows = addon:GetTierRows(recipe)
            local rows = {}
            if tierRows and #tierRows > 0 then
                for _, t in ipairs(tierRows) do
                    table.insert(rows, { recipe = recipe, info = t, tier = t.tier })
                end
            else
                table.insert(rows, { recipe = recipe, info = addon:GetRecipeProfit(recipe) })
            end
            -- "Profitable only" keeps rows with a positive profit at
            -- current prices (including ones marked * with unknown costs)
            for _, r in ipairs(rows) do
                if not GoldsmithDB.ui.profitableOnly or (r.info.profit and r.info.profit > 0) then
                    table.insert(items, r)
                end
            end
        end
    end
    SortCraftItems(items)
    return items
end

-- Plan view (opened by clicking a craft)

local PLAN_COLUMNS = {
    { key = "item",   label = "Material", x = 0,   width = 200, justify = "LEFT" },
    { key = "need",   label = "Need",     x = 204, width = 50,  justify = "RIGHT" },
    { key = "have",   label = "Have",     x = 258, width = 45,  justify = "RIGHT" },
    { key = "source", label = "Best way", x = 307, width = 60,  justify = "RIGHT" },
    { key = "each",   label = "Each",     x = 371, width = 65,  justify = "RIGHT" },
    { key = "total",  label = "Total",    x = 440, width = 70,  justify = "RIGHT" },
}

local METHOD_COLORS = {
    Buy    = { 1, 1, 1 },
    Vendor = { 1, 0.82, 0 },
    Craft  = { 0.3, 1, 0.3 },
    Mill   = { 0.3, 1, 0.3 },
}

-- Quantities can be fractional (e.g. herbs per pigment); round up, since
-- you can't buy part of an item
local function WholeQuantity(q)
    return math.ceil(q - 0.0001)
end

local function FillPlanRow(row, node)
    local prefix = string.rep("    ", node.depth - 1) .. (node.depth > 1 and "> " or "")
    -- Quality icon, so it's clear which quality to buy or make
    local qualityIcon = node.qualityTier and (" " .. addon:TierIconText(node.qualityTier, node.tierCount or 2)) or ""
    row.cells.item:SetText(prefix .. node.name .. qualityIcon)
    row.cells.need:SetText(WholeQuantity(node.need))
    row.cells.have:SetText(node.have > 0 and WholeQuantity(node.have) or "-")
    local best = node.best
    if best then
        -- * marks your own choice (right-click) rather than the cheapest
        row.cells.source:SetText(best.method .. (node.options.override and "*" or ""))
        row.cells.source:SetTextColor(unpack(METHOD_COLORS[best.method] or { 1, 1, 1 }))
        row.cells.each:SetText(FormatGold(best.unit))
        row.cells.total:SetText(FormatGold(best.unit * node.need))
    else
        row.cells.source:SetText("no price")
        row.cells.source:SetTextColor(1, 0.3, 0.3)
        row.cells.each:SetText("-")
        row.cells.total:SetText("-")
    end
    -- Sub-materials are shown for detail; their cost is already in the parent
    if node.depth > 1 then
        row.cells.item:SetTextColor(0.75, 0.75, 0.75)
        row.cells.total:SetTextColor(0.6, 0.6, 0.6)
    end
end

-- Every way to get the material, cheapest marked, and why
local function ShowPlanTooltip(row)
    local node = row.data
    local o = node.options
    GameTooltip:SetOwner(row, "ANCHOR_RIGHT")
    GameTooltip:AddLine(node.name, 1, 1, 1)
    if node.qualityTier then
        GameTooltip:AddDoubleLine("Quality", string.format("tier %d of %d %s", node.qualityTier,
            node.tierCount or 2, addon:TierIconText(node.qualityTier, node.tierCount or 2)),
            1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddDoubleLine("Need", WholeQuantity(node.need), 1, 0.82, 0, 1, 1, 1)
    if node.have > 0 then
        GameTooltip:AddDoubleLine("You have", WholeQuantity(node.have), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("To get", WholeQuantity(node.toGet), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Ways to get it (each):", 1, 0.82, 0)

    local function AddOption(option, label, detail)
        if not option then return end
        local cheapest = o.cheapest == option
        local tags = {}
        if cheapest then table.insert(tags, "cheapest") end
        if o.override and node.best == option then table.insert(tags, "your choice") end
        local text = FormatGold(option.unit) .. (#tags > 0 and ("  (" .. table.concat(tags, ", ") .. ")") or "")
        local c = cheapest and 0.3 or 0.8
        GameTooltip:AddDoubleLine("  " .. label, text, 1, 1, 1, c, cheapest and 1 or c, c)
        if detail then
            GameTooltip:AddLine("    " .. detail, 0.6, 0.6, 0.6)
        end
    end
    AddOption(o.buy, "Buy on the AH", o.buy and ("AH price " .. o.buy.ageText))
    AddOption(o.vendor, "Vendor", o.vendor and o.vendor.detail)
    AddOption(o.craft, "Craft it", o.craft and ("From its cheapest materials"))
    AddOption(o.mill, "Mill it", o.mill and string.format("%.2f per %s; cost shared with its other pigments",
        o.mill.perHerb, o.mill.herbName))
    if not node.best then
        GameTooltip:AddLine("  No price found. Scan the AH with Auctionator.", 1, 0.3, 0.3)
    end

    -- How much the cheapest way saves over buying
    if o.cheapest and o.buy and o.cheapest ~= o.buy and o.buy.unit > o.cheapest.unit then
        local saving = (o.buy.unit - o.cheapest.unit) * node.need
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string.format("%s it instead of buying saves %s here",
            o.cheapest.method == "Mill" and "Milling" or "Crafting", FormatGold(saving)), 0.3, 1, 0.3)
    end
    -- What your choice costs compared with the cheapest way
    if o.override and o.cheapest and node.best ~= o.cheapest then
        local extra = (node.best.unit - o.cheapest.unit) * node.need
        GameTooltip:AddLine(string.format("Your choice (%s) costs %s more here", node.best.method,
            FormatGold(extra)), 1, 0.6, 0.2)
    end
    GameTooltip:AddLine("Right-click to choose how to get it", 0.6, 0.6, 0.6)
    GameTooltip:Show()
end

-- Right-click a plan row: pick how to get the material. The choice applies
-- to that item in every plan until changed back to "Cheapest".
local METHOD_LABELS = {
    { key = "buy",    method = "Buy",    label = "Buy on the AH" },
    { key = "craft",  method = "Craft",  label = "Craft it" },
    { key = "mill",   method = "Mill",   label = "Mill it" },
    { key = "vendor", method = "Vendor", label = "Vendor" },
}

local function ShowPlanMenu(row)
    local node = row.data
    local o = node.options
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(row, function(_, root)
        root:CreateTitle(node.name)
        local cheapestLabel = "Cheapest way"
        if o.cheapest then
            cheapestLabel = string.format("Cheapest way (%s, %s)", o.cheapest.method, FormatGold(o.cheapest.unit))
        end
        root:CreateRadio(cheapestLabel,
            function() return o.override == nil end,
            function()
                addon:SetMethodOverride(node.itemID, nil)
                addon.Refresh()
            end)
        for _, m in ipairs(METHOD_LABELS) do
            local option = o[m.key]
            if option then
                root:CreateRadio(string.format("%s (%s each)", m.label, FormatGold(option.unit)),
                    function() return o.override == m.method end,
                    function()
                        addon:SetMethodOverride(node.itemID, m.method)
                        addon.Refresh()
                    end)
            end
        end
        root:CreateDivider()
        root:CreateButton("Reset all my choices", function()
            addon:ClearMethodOverrides()
            addon.Refresh()
        end)
    end)
end

-- Window

function addon:CreateMainFrame()
    -- Saved window state: position, whether it was open, and the active tab
    GoldsmithDB.ui = GoldsmithDB.ui or { shown = false }
    local ui = GoldsmithDB.ui
    ui.tab = ui.tab or "log"

    local frame = CreateFrame("Frame", "GoldsmithMainFrame", UIParent, "BackdropTemplate")
    frame:SetSize(FRAME_WIDTH, FRAME_HEIGHT)
    if ui.point then
        frame:SetPoint(ui.point, UIParent, ui.relativePoint, ui.x, ui.y)
    else
        frame:SetPoint("CENTER")
    end
    frame:SetClampedToScreen(true)
    frame:Hide()
    frame:SetBackdrop({
        bgFile = "Interface/Tooltips/UI-Tooltip-Background",
        edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
        tile = true,
        tileSize = 16,
        edgeSize = 16,
        insets = {left = 4, right = 4, top = 4, bottom = 4}
    })
    frame:SetBackdropColor(0, 0, 0, 0.85)
    frame:SetMovable(true)
    frame:EnableMouse(true)
    frame:RegisterForDrag("LeftButton")
    frame:SetScript("OnDragStart", frame.StartMoving)
    frame:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relativePoint, x, y = self:GetPoint()
        ui.point, ui.relativePoint, ui.x, ui.y = point, relativePoint, x, y
    end)
    frame:SetScript("OnShow", function() ui.shown = true end)
    frame:SetScript("OnHide", function() ui.shown = false end)

    -- Escape closes the window
    table.insert(UISpecialFrames, "GoldsmithMainFrame")

    local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
    closeButton:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -2, -2)

    local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    title:SetPoint("TOP", frame, "TOP", 0, -15)
    title:SetText("Goldsmith")


    -- Profession selector: the summary, log, crafts and stock show one
    -- profession, or all of them
    ui.profession = ui.profession or "All"

    local professionButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    professionButton:SetSize(130, 22)
    professionButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, -12)
    professionButton:SetScript("OnClick", function(self)
        if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
        MenuUtil.CreateContextMenu(self, function(_, root)
            root:CreateTitle("Show profession")
            local options = { "All" }
            for _, prof in ipairs(addon:GetProfessions()) do
                table.insert(options, prof)
            end
            table.insert(options, "Unassigned")
            for _, prof in ipairs(options) do
                root:CreateRadio(prof == "All" and "All professions" or prof,
                    function() return ui.profession == prof end,
                    function()
                        ui.profession = prof
                        addon.Refresh()
                    end)
            end
        end)
    end)

    -- Summary: profit on what you've sold. See ledger:getSummary.

    local SUMMARY_X = 20
    local function SummaryLine(y, font)
        local fs = frame:CreateFontString(nil, "OVERLAY", font or "GameFontNormal")
        fs:SetPoint("TOPLEFT", frame, "TOPLEFT", SUMMARY_X, y)
        fs:SetJustifyH("LEFT")
        return fs
    end

    local salesValue = SummaryLine(-45)
    local soldCostValue = SummaryLine(-61)
    local depositValue = SummaryLine(-77)
    local profitValue = SummaryLine(-93)
    local extraValue = SummaryLine(-111, "GameFontNormalSmall")
    extraValue:SetTextColor(0.6, 0.6, 0.6)

    local priceAgeValue = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    priceAgeValue:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -45)
    priceAgeValue:SetJustifyH("RIGHT")

    -- Which source prices are coming from: an Auctionator scan made this
    -- session beats TSM; otherwise TSM (see GetMarketPriceInfo)
    local function UpdatePriceAge()
        local scan = GoldsmithDB.lastPriceUpdate
        local scanText
        if scan then
            local days = DaysAgo(scan)
            scanText = days == 0 and ("at " .. date("%H:%M", scan))
                or string.format("%d day%s ago", days, days == 1 and "" or "s")
        end

        if addon:ScannedThisSession() then
            priceAgeValue:SetText("AH prices: Auctionator scan " .. scanText)
            priceAgeValue:SetTextColor(0.6, 0.6, 0.6)
        elseif addon:HasTSM() then
            priceAgeValue:SetText("AH prices: TSM" .. (scanText and (" (last Auctionator scan " .. scanText .. ")") or ""))
            priceAgeValue:SetTextColor(0.6, 0.6, 0.6)
        elseif scanText then
            priceAgeValue:SetText("AH prices: Auctionator scan " .. scanText)
            priceAgeValue:SetTextColor(1, 0.6, 0.2)
        elseif addon:HasAuctionator() then
            priceAgeValue:SetText("AH prices: no scan seen yet")
            priceAgeValue:SetTextColor(0.6, 0.6, 0.6)
        else
            priceAgeValue:SetText("AH prices: install Auctionator or TSM")
            priceAgeValue:SetTextColor(1, 0.6, 0.2)
        end
    end

    local function UpdateSummary(prof)
        local s = addon.ledger:getSummary(prof, function(itemName)
            return (addon:GetUnitCostBasis(itemName))
        end)
        local _, onHand = addon:GetMaterialsOnHand(prof)

        salesValue:SetFormattedText("Sales: %s", FormatGold(s.sales))

        local soldText = "Cost of items sold: " .. FormatGold(s.soldCost)
        if s.estimated then
            soldText = soldText .. " (some estimated)"
        end
        if s.unknownSales > 0 then
            soldText = soldText .. string.format(" - %d sale%s without cost data left out",
                s.unknownSales, s.unknownSales == 1 and "" or "s")
        end
        soldCostValue:SetText(soldText)

        if s.refundsKnown then
            local lost = math.max(s.deposits - s.refunds, 0)
            depositValue:SetFormattedText("AH deposits: %s paid, %s refunded, %s lost",
                FormatGold(s.deposits), FormatGold(s.refunds), FormatGold(lost))
        else
            -- Sales from before refunds were saved don't say how much came back
            depositValue:SetFormattedText("AH deposits: %s paid (refunds tracked on new sales)",
                FormatGold(s.deposits))
        end

        local profitText = "Profit on sales: " .. FormatSigned(s.profit)
        if s.margin then
            profitText = profitText .. string.format(" (%.0f%%)", s.margin)
        end
        profitValue:SetText(profitText)
        if s.profit > 0 then
            profitValue:SetTextColor(0, 1, 0)
        elseif s.profit < 0 then
            profitValue:SetTextColor(1, 0.3, 0.3)
        else
            profitValue:SetTextColor(0.8, 0.8, 0.8)
        end

        extraValue:SetFormattedText("Spent on materials: %s   Materials on hand: %s   Entries: %d",
            FormatGold(s.spent), FormatGold(onHand), s.count)
    end

    -- Tabs

    local logList = CreateList(frame, LOG_COLUMNS, "No transactions yet.", {
        onEnter = ShowEntryTooltip,
        onRightClick = ShowEntryMenu,
    })
    local craftList = CreateList(frame, CRAFT_COLUMNS,
        "No recipes yet. Open your profession window to add your learned recipes.", {
        onEnter = ShowCraftTooltip,
        onHeaderClick = OnCraftHeaderClick,
        onLeftClick = function(row) addon:OpenPlan(row.data.recipe, row.data.tier and row.data.info) end,
    })
    local dealList = CreateList(frame, DEAL_COLUMNS, "", {
        onEnter = ShowDealTooltip,
    })
    local stockList = CreateList(frame, STOCK_COLUMNS,
        "No materials on hand. Materials from your saved recipes and milled herbs show here.", {
        onEnter = ShowStockTooltip,
    })

    local craftNote = frame:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    craftNote:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 48)
    craftNote:SetText("+ some material costs unknown  * profit is at most this")

    -- Concentration budget (Crafts tab): your current concentration and the
    -- best crafts to spend it on. Hover for the full breakdown.
    local concBudget = CreateFrame("Frame", nil, frame)
    concBudget:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", -20, 44)
    concBudget:SetSize(360, 16)
    concBudget:EnableMouse(true)
    local concBudgetText = concBudget:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    concBudgetText:SetAllPoints()
    concBudgetText:SetJustifyH("RIGHT")
    concBudgetText:SetWordWrap(false)

    local budgetPlans = {}

    local function ProfessionsForBudget(prof)
        if prof ~= "All" then return { prof } end
        local list = {}
        for name in pairs(GoldsmithDB.concentrationCurrency or {}) do
            table.insert(list, name)
        end
        table.sort(list)
        return list
    end

    local function UpdateConcentrationBudget(prof)
        wipe(budgetPlans)
        local parts = {}
        for _, profession in ipairs(ProfessionsForBudget(prof)) do
            local current, max, minutesToFull = addon:GetConcentration(profession)
            if current then
                local plan, used, gain = addon:PlanConcentration(profession, current)
                table.insert(budgetPlans, {
                    profession = profession, current = current, max = max,
                    minutesToFull = minutesToFull, plan = plan, used = used, gain = gain,
                })
                table.insert(parts, string.format("%s%d/%d conc: +%s", addon:ProfessionIconText(profession),
                    current, max, FormatGold(gain)))
            end
        end
        if #parts == 0 then
            concBudgetText:SetText("Concentration: open a profession to read it")
            concBudgetText:SetTextColor(0.6, 0.6, 0.6)
        else
            concBudgetText:SetText(table.concat(parts, "   ") .. "  (hover)")
            concBudgetText:SetTextColor(1, 0.82, 0)
        end
    end

    concBudget:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Best use of your concentration", 1, 1, 1)
        if #budgetPlans == 0 then
            GameTooltip:AddLine("Open a profession window once so Goldsmith can read it.", 0.6, 0.6, 0.6)
        end
        for _, b in ipairs(budgetPlans) do
            GameTooltip:AddLine(" ")
            GameTooltip:AddDoubleLine(addon:ProfessionIconText(b.profession) .. b.profession,
                string.format("%d / %d", b.current, b.max), 1, 0.82, 0, 1, 1, 1)
            if b.minutesToFull then
                local hours = b.minutesToFull / 60
                GameTooltip:AddLine(string.format("  Full in %s", hours >= 1 and string.format("%.1f hours", hours)
                    or string.format("%d minutes", b.minutesToFull)), 0.6, 0.6, 0.6)
            end
            if #b.plan == 0 then
                GameTooltip:AddLine("  No profitable use for concentration right now", 0.6, 0.6, 0.6)
            end
            for _, p in ipairs(b.plan) do
                local icon = addon:TierIconText(p.row.tier, p.tierCount or 2)
                GameTooltip:AddDoubleLine(
                    string.format("  %dx %s %s", p.crafts, p.recipe.outputName, icon),
                    string.format("%d conc, +%s extra", p.points, FormatGold(p.gain)),
                    1, 1, 1, 0.3, 1, 0.3)
                GameTooltip:AddLine(string.format("    %s per point, %s profit in total",
                    FormatGold(p.row.concentrationValue), FormatSigned(p.profit)), 0.6, 0.6, 0.6)
            end
            if #b.plan > 0 then
                GameTooltip:AddDoubleLine("  Total", string.format("%d conc, +%s extra", b.used, FormatGold(b.gain)),
                    1, 0.82, 0, 0.3, 1, 0.3)
            end
        end
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Extra = profit gained by concentrating vs the same craft without it.", 0.6, 0.6, 0.6)
        GameTooltip:AddLine("Each craft is capped at about a day of that item's sales.", 0.6, 0.6, 0.6)
        GameTooltip:Show()
    end)
    concBudget:SetScript("OnLeave", GameTooltip_Hide)

    -- Stock tab total, in the same spot as the Crafts footnote
    local stockTotal = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    stockTotal:SetPoint("BOTTOMLEFT", frame, "BOTTOMLEFT", 16, 46)

    -- "Profitable only" checkbox (Crafts tab)
    local profitableCheck = CreateFrame("CheckButton", nil, frame, "UICheckButtonTemplate")
    profitableCheck:SetSize(24, 24)
    profitableCheck:SetPoint("TOPLEFT", frame, "TOPLEFT", 150, -125)
    local profitableLabel = profitableCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    profitableLabel:SetPoint("LEFT", profitableCheck, "RIGHT", 0, 1)
    profitableLabel:SetText("Profitable only")
    profitableCheck:SetChecked(ui.profitableOnly == true)
    profitableCheck:SetScript("OnClick", function(self)
        ui.profitableOnly = self:GetChecked() and true or nil
        addon.Refresh()
    end)

    -- Expansion filter (Crafts and Stock tabs): a checkbox menu of the
    -- expansions you have recipes for
    local filterButton = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
    filterButton:SetSize(130, 22)
    filterButton:SetPoint("TOPLEFT", frame, "TOPLEFT", 16, -126)

    local function UpdateFilterLabel()
        local shown = {}
        for _, expansionID in ipairs(GetRecipeExpansions()) do
            if IsExpansionShown(expansionID) then
                table.insert(shown, expansionID)
            end
        end
        if #shown == 1 then
            filterButton:SetText(addon:GetExpansionName(shown[1]))
        else
            filterButton:SetText(string.format("Expansions (%d)", #shown))
        end
    end

    filterButton:SetScript("OnClick", function(self)
        if not (MenuUtil and MenuUtil.CreateContextMenu) then
            print("|cFF00FF00[Goldsmith]|r The expansion filter needs a newer game menu API.")
            return
        end
        MenuUtil.CreateContextMenu(self, function(_, root)
            root:CreateTitle("Show items from")
            for _, expansionID in ipairs(GetRecipeExpansions()) do
                root:CreateCheckbox(addon:GetExpansionName(expansionID),
                    function() return IsExpansionShown(expansionID) end,
                    function()
                        SetExpansionShown(expansionID, not IsExpansionShown(expansionID))
                        addon.Refresh()
                    end)
            end
            root:CreateDivider()
            root:CreateButton("Current expansion only", function()
                GoldsmithDB.ui.expansions = nil
                addon.Refresh()
            end)
            root:CreateButton("All expansions", function()
                GoldsmithDB.ui.expansions = {}
                for _, expansionID in ipairs(GetRecipeExpansions()) do
                    GoldsmithDB.ui.expansions[expansionID] = true
                end
                addon.Refresh()
            end)
        end)
    end)

    -- Plan view: replaces the Crafts list while a craft is being planned

    ui.planQty = ui.planQty or {}
    local planRecipe = nil
    local planTier = nil   -- quality tier being planned, if any
    local planConcentrate = false   -- and whether with concentration
    local currentPlan = nil

    local planPanel = CreateFrame("Frame", nil, frame)
    planPanel:SetAllPoints(frame)
    planPanel:Hide()

    local planList = CreateList(planPanel, PLAN_COLUMNS, "Enter how many to make.", {
        onEnter = ShowPlanTooltip,
        onRightClick = ShowPlanMenu,
        top = -182,
        bottom = 150,
    })

    local backButton = CreateFrame("Button", nil, planPanel, "UIPanelButtonTemplate")
    backButton:SetSize(70, 22)
    backButton:SetPoint("TOPLEFT", planPanel, "TOPLEFT", 16, -126)
    backButton:SetText("< Back")

    local planTitle = planPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    planTitle:SetPoint("LEFT", backButton, "RIGHT", 10, 0)
    planTitle:SetWidth(200)
    planTitle:SetJustifyH("LEFT")
    planTitle:SetWordWrap(false)

    local makeLabel = planPanel:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    makeLabel:SetPoint("TOPLEFT", planPanel, "TOPLEFT", 20, -158)
    makeLabel:SetText("Make:")

    local qtyBox = CreateFrame("EditBox", nil, planPanel, "InputBoxTemplate")
    qtyBox:SetSize(60, 20)
    qtyBox:SetPoint("LEFT", makeLabel, "RIGHT", 10, 0)
    qtyBox:SetAutoFocus(false)
    qtyBox:SetNumeric(true)
    qtyBox:SetMaxLetters(6)

    local craftsText = planPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    craftsText:SetPoint("LEFT", qtyBox, "RIGHT", 8, 0)
    craftsText:SetTextColor(0.6, 0.6, 0.6)

    local useHaveCheck = CreateFrame("CheckButton", nil, planPanel, "UICheckButtonTemplate")
    useHaveCheck:SetSize(24, 24)
    useHaveCheck:SetPoint("TOPRIGHT", planPanel, "TOPRIGHT", -170, -154)
    local useHaveLabel = useHaveCheck:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    useHaveLabel:SetPoint("LEFT", useHaveCheck, "RIGHT", 0, 1)
    useHaveLabel:SetText("Use materials I have")
    useHaveCheck:SetChecked(ui.planUseOnHand ~= false)

    local function PlanLine(y)
        local fs = planPanel:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
        fs:SetPoint("BOTTOMLEFT", planPanel, "BOTTOMLEFT", 20, y)
        fs:SetJustifyH("LEFT")
        fs:SetWidth(FRAME_WIDTH - 40)
        fs:SetWordWrap(false)
        return fs
    end
    local costLine = PlanLine(132)
    local sellLine = PlanLine(118)
    local profitLine = PlanLine(104)
    local demandLine = PlanLine(90)
    local spendLine = PlanLine(76)
    local vendorLine = PlanLine(62)

    local shopButton = CreateFrame("Button", nil, planPanel, "UIPanelButtonTemplate")
    shopButton:SetSize(170, 26)
    shopButton:SetPoint("BOTTOMRIGHT", planPanel, "BOTTOMRIGHT", -16, 12)
    shopButton:SetText("Send to Auctionator")

    local function ClearPlanLines(message)
        costLine:SetText(message or "")
        for _, line in ipairs({ sellLine, profitLine, demandLine, spendLine, vendorLine }) do
            line:SetText("")
        end
    end

    local function RefreshPlan()
        if not planRecipe then return end

        -- The tier being planned, with current prices
        local tierInfo
        if planTier then
            for _, t in ipairs(addon:GetTierRows(planRecipe) or {}) do
                if t.tier == planTier and (t.concentrate == true) == planConcentrate then tierInfo = t end
            end
        end
        local tierIcon = tierInfo and (" " .. addon:TierIconText(tierInfo.tier, tierInfo.tierCount)) or ""
        planTitle:SetText(addon:ProfessionIconText(planRecipe.profession) .. planRecipe.outputName .. tierIcon)

        local quantity = tonumber(qtyBox:GetText()) or 0
        if quantity <= 0 then
            currentPlan = nil
            planList:SetItems({}, FillPlanRow)
            craftsText:SetText("")
            ClearPlanLines("Enter how many to make.")
            shopButton:Disable()
            return
        end
        ui.planQty[planRecipe.recipeID] = quantity

        local plan = addon:BuildPlan(planRecipe, quantity, ui.planUseOnHand ~= false, tierInfo)
        currentPlan = plan
        planList:SetItems(addon:FlattenPlan(plan), FillPlanRow)
        craftsText:SetFormattedText("(%d craft%s, about %.1f made)", plan.crafts,
            plan.crafts == 1 and "" or "s", plan.expectedOutput)

        local made = math.max(plan.expectedOutput, 0.0001)
        local costText = string.format("Cost of %d craft%s: %s (%s each for about %.1f made)",
            plan.crafts, plan.crafts == 1 and "" or "s", FormatGold(plan.cost),
            FormatGold(plan.cost / made), plan.expectedOutput)
        if not plan.complete then
            costText = costText .. " - some materials have no price, so the real cost is higher"
        elseif plan.choiceExtra and plan.choiceExtra > 0.5 then
            -- Your Buy/Craft/Mill choices vs the cheapest way
            costText = costText .. string.format(" - your choices add %s", FormatGold(plan.choiceExtra))
        end
        if tierInfo and tierInfo.concentrate then
            costText = costText .. string.format(" + about %d concentration",
                tierInfo.concentration * plan.crafts)
        end
        costLine:SetText(costText)

        if plan.price then
            sellLine:SetFormattedText("Sells for: %s after the AH cut (%s each, AH price %s)",
                FormatGold(plan.revenue), FormatGold(plan.price * 0.95),
                addon:PriceAgeText((tierInfo and tierInfo.itemID) or planRecipe.outputItemID))
            local profitText = "Profit: " .. FormatSigned(plan.profit)
            if plan.margin then
                profitText = profitText .. string.format(" (%.0f%%)", plan.margin)
            end
            profitLine:SetText(profitText)
            if plan.profit >= 0 then
                profitLine:SetTextColor(0.3, 1, 0.3)
            else
                profitLine:SetTextColor(1, 0.3, 0.3)
            end
        else
            sellLine:SetText("Sells for: no AH price yet (scan with Auctionator)")
            profitLine:SetText("")
        end

        if plan.demand and plan.demand > 0 then
            local days = quantity / plan.demand
            local text = string.format("Sold per day: %s (%s). Making %d is ",
                addon:FormatDemand(plan.demand), plan.demandSource, quantity)
            if days >= 1 then
                text = text .. string.format("about %.1f days of sales - may be slow to sell", days)
                demandLine:SetTextColor(1, 0.6, 0.2)
            elseif days < 0.01 then
                text = text .. "under 1% of a day's sales"
                demandLine:SetTextColor(0.8, 0.8, 0.8)
            else
                text = text .. string.format("%.0f%% of a day's sales", days * 100)
                demandLine:SetTextColor(0.8, 0.8, 0.8)
            end
            demandLine:SetText(text)
        else
            demandLine:SetText("Sold per day: no data")
            demandLine:SetTextColor(0.6, 0.6, 0.6)
        end

        local ahSpend, liveCount, short = 0, 0, false
        for _, entry in ipairs(plan.buyAH) do
            ahSpend = ahSpend + entry.cost
            if entry.live then liveCount = liveCount + 1 end
            if entry.short then short = true end
        end
        local spendText = string.format("To buy on the AH: %d item%s, about %s",
            #plan.buyAH, #plan.buyAH == 1 and "" or "s", FormatGold(ahSpend))
        if liveCount > 0 then
            spendText = spendText .. string.format(" (%d priced from live listings)", liveCount)
        end
        if short then
            spendText = spendText .. " - not enough listed for all of it"
        end
        spendLine:SetText(spendText)

        if #plan.buyVendor > 0 then
            local parts = {}
            for _, entry in ipairs(plan.buyVendor) do
                table.insert(parts, entry.quantity .. " " .. entry.name)
            end
            vendorLine:SetText("From a vendor: " .. table.concat(parts, ", "))
        else
            vendorLine:SetText("")
        end

        shopButton:SetEnabled(#plan.buyAH > 0)
    end

    qtyBox:SetScript("OnTextChanged", function(_, userInput)
        if userInput then RefreshPlan() end
    end)
    qtyBox:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    qtyBox:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)

    useHaveCheck:SetScript("OnClick", function(self)
        ui.planUseOnHand = self:GetChecked() and true or false
        RefreshPlan()
    end)

    shopButton:SetScript("OnClick", function()
        if not currentPlan then return end
        local ok, result = addon:SendShoppingList(currentPlan)
        if ok then
            print("|cFF00FF00[Goldsmith]|r Shopping list \"" .. result .. "\" sent to Auctionator's Shopping tab.")
        else
            print("|cFF00FF00[Goldsmith]|r Couldn't create the shopping list: " .. result)
        end
    end)

    local tabs = {}
    local function SelectTab(name)
        ui.tab = name
        local planning = name == "crafts" and planRecipe ~= nil
        logList:SetShown(name == "log")
        craftList:SetShown(name == "crafts" and not planning)
        stockList:SetShown(name == "stock")
        dealList:SetShown(name == "deals")
        planPanel:SetShown(planning)
        craftNote:SetShown(name == "crafts" and not planning)
        concBudget:SetShown(name == "crafts" and not planning)
        profitableCheck:SetShown(name == "crafts" and not planning)
        stockTotal:SetShown(name == "stock")
        filterButton:SetShown((name == "crafts" and not planning) or name == "stock" or name == "deals")
        for key, tab in pairs(tabs) do
            tab:SetEnabled(key ~= name)
        end
    end

    -- tierInfo is a Crafts tab tier row; only its tier number is kept, so
    -- the plan re-reads that tier's current prices on every refresh
    function addon:OpenPlan(recipe, tierInfo)
        planRecipe = recipe
        planTier = tierInfo and tierInfo.tier or nil
        planConcentrate = tierInfo and tierInfo.concentrate == true or false
        local saved = ui.planQty[recipe.recipeID]
        qtyBox:SetText(tostring(saved or math.max(math.floor(recipe.outputQty), 1)))
        SelectTab("crafts")
        RefreshPlan()
    end

    backButton:SetScript("OnClick", function()
        planRecipe = nil
        planTier = nil
        currentPlan = nil
        qtyBox:ClearFocus()
        SelectTab("crafts")
    end)

    -- Tab buttons, right-aligned: Log, Crafts, Stock
    local tabOrder = { { "deals", "Deals" }, { "stock", "Stock" }, { "crafts", "Crafts" }, { "log", "Log" } }
    local previous
    for _, t in ipairs(tabOrder) do
        local key, label = t[1], t[2]
        local tab = CreateFrame("Button", nil, frame, "UIPanelButtonTemplate")
        tab:SetSize(70, 22)
        if previous then
            tab:SetPoint("RIGHT", previous, "LEFT", -4, 0)
        else
            tab:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -20, -126)
        end
        tab:SetText(label)
        tab:SetScript("OnClick", function() SelectTab(key) end)
        tabs[key] = tab
        previous = tab
    end
    if not tabs[ui.tab] then
        ui.tab = "log"
    end

    local function Refresh()
        local prof = ui.profession
        professionButton:SetText(prof == "All" and "All professions" or prof)

        UpdateSummary(prof)

        -- Newest first
        local entries = addon.ledger:getAll()
        local shown = {}
        for i = #entries, 1, -1 do
            if prof == "All" or entries[i].profession == prof then
                table.insert(shown, entries[i])
            end
        end
        logList:SetItems(shown, FillLogRow)
        craftList:SetItems(GetCraftItems(prof), FillCraftRow)
        local craftSort = GetCraftSort()
        craftList:SetSortIndicator(craftSort.key, craftSort.descending)
        -- Stock uses the same expansion filter as Crafts
        local stock, stockValue = {}, 0
        for _, m in ipairs((addon:GetMaterialsOnHand(prof))) do
            if IsExpansionShown(addon:GetItemExpansion(m.itemID)) then
                table.insert(stock, m)
                stockValue = stockValue + (m.value or 0)
            end
        end
        stockList:SetItems(stock, FillStockRow)

        -- Deals: same profession and expansion filters
        local deals, earliest, minDays = addon:GetDeals(prof)
        local shownDeals = {}
        for _, d in ipairs(deals) do
            if IsExpansionShown(addon:GetItemExpansion(d.itemID)) then
                table.insert(shownDeals, d)
            end
        end
        dealList:SetEmptyText(string.format(
            "Deals need %d days of price history, saved each time Auctionator updates its prices. History started %s.",
            minDays, earliest or "today"))
        dealList:SetItems(shownDeals, FillDealRow)
        stockTotal:SetFormattedText("Total stock value: %s (%d material%s)",
            FormatGold(stockValue), #stock, #stock == 1 and "" or "s")
        UpdatePriceAge()
        UpdateFilterLabel()
        UpdateConcentrationBudget(prof)
        RefreshPlan()
    end

    local button = CreateFrame("Button", nil, frame, "GameMenuButtonTemplate")
    button:SetSize(120, 30)
    button:SetPoint("BOTTOM", frame, "BOTTOM", 0, 10)
    button:SetText("Refresh")
    button:SetScript("OnClick", Refresh)

    addon.mainFrame = frame
    addon.Refresh = Refresh
    addon.RefreshCrafts = Refresh

    SelectTab(ui.tab)
    Refresh()
    if ui.shown then
        frame:Show()
    end
end

_G.Goldsmith = addon
