local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Items tab
--
-- "Tell me everything about this one item." Opens on four leaderboards
-- (most profit earned, best ROI, fastest sellers, held too long). The search
-- box finds any item Goldsmith knows; "In my bags" lists everything you
-- hold on every character (it replaces v1's Stock tab). Clicking an item
-- opens its page: price now and usually, a 30-day price chart, sold per
-- day, what it costs, break-even ("list above this"), stock and your
-- activity. The numbers come from GetItemBoards, SearchItems and
-- GetItemDetails (Insights.lua).

local WIDTH = 860
local GAP = 12
local TOP_HEIGHT = 26
local BOARD_ROWS = 6
local SEARCH_LIMIT = 100
local STALE_PRICE_DAYS = 3
local ACTIVITY_ROWS = 11
local TIER_ROWS = 5

local Money, Signed = function(c) return addon:FormatMoney(c) end, function(c) return addon:FormatSignedMoney(c) end

-- The tier goes before the name, so a long name cut short never hides it
local function ItemText(name, itemID)
    local tier, tierCount = addon:GetItemTier(itemID)
    return (tier and (addon:TierIconText(tier, tierCount) .. " ") or "") .. (name or "?")
end

local function DaysSince(t)
    return math.floor((time() - t) / 86400)
end

local function Plural(n, word)
    return string.format("%s %s%s", n, word, n == 1 and "" or "s")
end

-- Links from other screens

local pending = nil

-- Opens an item's page. itemID picks the tier (optional).
function addon:OpenItem(name, itemID)
    if not name and itemID then name = C_Item.GetItemNameByID(itemID) end
    if not name then return end
    pending = { page = { name = name, itemID = itemID } }
    addon:ShowTab("items")
end

-- Opens the Items landing page. opts.inBags shows what you hold.
function addon:OpenItems(opts)
    pending = { landing = opts or {} }
    addon:ShowTab("items")
end

-- Landing page: leaderboards

local BOARDS = {
    {
        key = "profit", title = "Most profit earned",
        empty = "Items you've sold at a profit show here.",
        value = function(i) return Signed(i.profit), "profit" end,
        tooltip = function(tooltip, i)
            tooltip:AddDoubleLine("Sold", tostring(i.units), 0.8, 0.8, 0.8, 1, 1, 1)
            tooltip:AddDoubleLine("Sales", Money(i.sales), 0.8, 0.8, 0.8, 1, 1, 1)
            tooltip:AddDoubleLine("Profit", Signed(i.profit), 0.8, 0.8, 0.8, 0.37, 0.81, 0.48)
        end,
    },
    {
        key = "roi", title = "Best ROI",
        empty = "Items sold at least twice, ranked by profit as a share of what they cost you.",
        value = function(i) return string.format("%.0f%%", i.roi), "profit" end,
        tooltip = function(tooltip, i)
            tooltip:AddDoubleLine("ROI", string.format("%.0f%%", i.roi), 0.8, 0.8, 0.8, 1, 1, 1)
            tooltip:AddDoubleLine("Profit", Signed(i.profit), 0.8, 0.8, 0.8, 0.37, 0.81, 0.48)
            tooltip:AddDoubleLine("Sold", tostring(i.units), 0.8, 0.8, 0.8, 1, 1, 1)
        end,
    },
    {
        key = "fastest", title = "Fastest sellers",
        empty = "How many of each item you sell per day shows here.",
        value = function(i) return addon:FormatDemand(i.perDay) .. " a day", "text" end,
        tooltip = function(tooltip, i)
            tooltip:AddDoubleLine("You sold", tostring(i.units), 0.8, 0.8, 0.8, 1, 1, 1)
            tooltip:AddDoubleLine("Per day", addon:FormatDemand(i.perDay), 0.8, 0.8, 0.8, 1, 1, 1)
        end,
    },
    {
        -- Functions: the number of days is a setting (heldDays)
        key = "held",
        title = function() return string.format("Held %d+ days", addon:Setting("heldDays")) end,
        empty = function()
            return string.format("Nothing you crafted has sat unsold for %d days.", addon:Setting("heldDays"))
        end,
        value = function(i) return Plural(i.days, "day"), "warning" end,
        tooltip = function(tooltip, i)
            tooltip:AddDoubleLine("You have", tostring(i.count), 0.8, 0.8, 0.8, 1, 1, 1)
            tooltip:AddDoubleLine("Worth", Money(i.value), 0.8, 0.8, 0.8, 1, 1, 1)
            tooltip:AddLine("Check its break-even on the item page before cutting the price.", 0.6, 0.6, 0.6, true)
        end,
    },
}

-- A board's title or empty text: a string, or a function for text that
-- follows a setting
local function BoardText(value)
    if type(value) == "function" then return value() end
    return value
end

local function CreateBoard(parent, def)
    local board = UI.Panel(parent)
    board.def = def
    board.title = UI.Text(board, "heading")
    board.title:SetPoint("TOPLEFT", 16, -14)
    board.subtitle = UI.Text(board, "label", "dim")
    board.subtitle:SetPoint("LEFT", board.title, "RIGHT", 10, -1)
    board.empty = UI.Text(board, "small", "muted")
    board.empty:SetPoint("TOPLEFT", 16, -46)
    board.empty:SetPoint("RIGHT", -16, 0)
    board.empty:SetWordWrap(true)
    board.rows = {}
    for i = 1, BOARD_ROWS do
        local row = CreateFrame("Button", nil, board)
        row:SetHeight(26)
        row:SetPoint("TOPLEFT", 8, -40 - (i - 1) * 26)
        row:SetPoint("RIGHT", board, "RIGHT", -8, 0)
        local hover = row:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        hover:SetColorTexture(addon:Color("hover"))
        row.rank = UI.Text(row, "small", "dim")
        row.rank:SetPoint("LEFT", 8, 0)
        row.rank:SetText(tostring(i))
        row.value = UI.Text(row, "body", nil, "RIGHT")
        row.value:SetPoint("RIGHT", -8, 0)
        row.name = UI.Text(row, "body")
        row.name:SetPoint("LEFT", 26, 0)
        row.name:SetPoint("RIGHT", row.value, "LEFT", -10, 0)
        row:SetScript("OnClick", function(self) addon:OpenItem(self.item.name, self.item.itemID) end)
        UI.SetTooltip(row, function(tooltip, self)
            tooltip:AddLine(ItemText(self.item.name, self.item.itemID), 1, 1, 1)
            def.tooltip(tooltip, self.item)
            tooltip:AddLine("Click to open its page.", 0.37, 0.81, 0.48)
        end)
        board.rows[i] = row
    end

    function board:Set(items, subtitle)
        board.title:SetText(BoardText(def.title))
        board.empty:SetText(BoardText(def.empty))
        board.subtitle:SetText(subtitle or "")
        for i, row in ipairs(board.rows) do
            local item = items[i]
            row.item = item
            if item then
                row.name:SetText(ItemText(item.name, item.itemID))
                local text, color = def.value(item)
                row.value:SetText(text)
                row.value:SetTextColor(addon:Color(color))
                row:Show()
            else
                row:Hide()
            end
        end
        board.empty:SetShown(#items == 0)
    end
    return board
end

-- Landing page: search results and stock

local SEARCH_COLUMNS = {
    { key = "item", label = "Item" },
    { key = "profession", label = "Profession", width = 130 },
    { key = "have", label = "You have", width = 70, justify = "RIGHT" },
    { key = "price", label = "AH price", width = 90, justify = "RIGHT" },
    { key = "demand", label = "Sold/day", width = 70, justify = "RIGHT" },
    { key = "saleRate", label = "Sale rate", width = 64, justify = "RIGHT", tsm = true },
}

local STOCK_COLUMNS = {
    { key = "item", label = "Item" },
    { key = "have", label = "Have", width = 56, justify = "RIGHT" },
    { key = "each", label = "Each", width = 84, justify = "RIGHT" },
    { key = "value", label = "Value", width = 90, justify = "RIGHT" },
    { key = "held", label = "Held", width = 64, justify = "RIGHT" },
    { key = "price", label = "AH price", width = 90, justify = "RIGHT" },
    { key = "demand", label = "Sold/day", width = 70, justify = "RIGHT" },
    { key = "saleRate", label = "Sale rate", width = 64, justify = "RIGHT", tsm = true },
}

-- Sold per day and sale rate for list rows, looked up once per refresh
-- so sorting by them doesn't ask TSM again for every comparison
local function AddSales(items)
    for _, item in ipairs(items) do
        if item.demand == nil then item.demand = addon:GetDemand(item.itemID, item.name) end
        item.saleRate = addon:GetSaleRate(item.itemID)
    end
end

local function FillSalesCells(c, item)
    c.demand:SetText(addon:FormatDemand(item.demand))
    c.demand:SetTextColor(addon:Color(item.demand and "text" or "dim"))
    -- Not there without TSM (see AvailableColumns)
    if c.saleRate then
        c.saleRate:SetText(addon:FormatSaleRate(item.saleRate))
        c.saleRate:SetTextColor(addon:Color(item.saleRate and "text" or "dim"))
    end
end

-- Sorting, as on the Crafts tab: clicking a header sorts by it, clicking
-- again reverses. Each column starts the most useful way round; rows with no
-- value go last. In my bags starts most valuable first; search results
-- start best match first (no column).
local SORTS = {
    stock = {
        item  = { firstDescending = false, value = function(i) return i.name end },
        have  = { firstDescending = true,  value = function(i) return i.count end },
        each  = { firstDescending = true,  value = function(i) return i.unitValue end },
        value = { firstDescending = true,  value = function(i) return i.value end },
        -- Held longest first: the oldest date
        held  = { firstDescending = false, value = function(i) return i.heldSince end },
        price = { firstDescending = true,  value = function(i) return addon:GetMarketPrice(i.itemID) end },
        demand   = { firstDescending = true, value = function(i) return i.demand end },
        saleRate = { firstDescending = true, value = function(i) return i.saleRate end },
    },
    search = {
        item       = { firstDescending = false, value = function(i) return i.name end },
        profession = { firstDescending = false, value = function(i) return i.profession end },
        have       = { firstDescending = true,  value = function(i) return i.have > 0 and i.have or nil end },
        price      = { firstDescending = true,  value = function(i) return i.price end },
        demand     = { firstDescending = true,  value = function(i) return i.demand end },
        saleRate   = { firstDescending = true,  value = function(i) return i.saleRate end },
    },
}
local DEFAULT_SORTS = { stock = { key = "value", descending = true } }

-- The sort for a list ("stock" or "search"), or nil for its own order
local function GetSort(mode)
    local sort = GoldsmithDB.ui2.itemSorts and GoldsmithDB.ui2.itemSorts[mode]
    if sort and SORTS[mode][sort.key] then return sort end
    return DEFAULT_SORTS[mode]
end

local function SetSort(mode, key)
    local ui = GoldsmithDB.ui2
    ui.itemSorts = ui.itemSorts or {}
    local current = GetSort(mode)
    if current and current.key == key then
        ui.itemSorts[mode] = { key = key, descending = not current.descending }
    else
        ui.itemSorts[mode] = { key = key, descending = SORTS[mode][key].firstDescending }
    end
end

local function SortItems(items, mode)
    local sort = GetSort(mode)
    if not sort then return end
    local getValue = SORTS[mode][sort.key].value
    local values = {}
    for _, item in ipairs(items) do values[item] = getValue(item) or false end
    table.sort(items, function(a, b)
        local va, vb = values[a], values[b]
        if va and vb and va ~= vb then
            if sort.descending then return va > vb end
            return va < vb
        end
        if (va == false) ~= (vb == false) then return vb == false end
        return a.name < b.name
    end)
end

local function FillSearchRow(row, item)
    local c = row.cells
    c.item:SetText(ItemText(item.name, item.itemID))
    c.profession:SetText(item.profession and (addon:ProfessionIconText(item.profession) .. item.profession) or "-")
    c.profession:SetTextColor(addon:Color("muted"))
    c.have:SetText(item.have > 0 and tostring(item.have) or "-")
    if item.have == 0 then c.have:SetTextColor(addon:Color("dim")) end
    c.price:SetText(item.price and Money(item.price) or "-")
    FillSalesCells(c, item)
end

local function FillStockRow(row, item)
    local c = row.cells
    c.item:SetText(ItemText(item.name, item.itemID))
    c.have:SetText(tostring(item.count))
    c.each:SetText(item.unitValue and Money(item.unitValue) or "-")
    c.value:SetText(Money(item.value))
    if item.heldSince then
        local days = DaysSince(item.heldSince)
        c.held:SetText(Plural(days, "day"))
        if days >= addon:Setting("heldDays") then c.held:SetTextColor(addon:Color("warning")) end
    else
        c.held:SetText("-")
        c.held:SetTextColor(addon:Color("dim"))
    end
    local price = addon:GetMarketPrice(item.itemID)
    c.price:SetText(price and Money(price) or "-")
    c.price:SetTextColor(addon:Color("muted"))
    FillSalesCells(c, item)
end

local function StockTooltip(tooltip, item)
    tooltip:AddLine(ItemText(item.name, item.itemID), 1, 1, 1)
    for _, entry in ipairs(item.byCharacter or {}) do
        tooltip:AddDoubleLine(entry.name, tostring(entry.count), 0.8, 0.8, 0.8, 1, 1, 1)
    end
    tooltip:AddLine(item.crafted and "Valued at what your latest crafts cost you."
        or "Valued at what you paid, or the AH price when there's no cost.", 0.6, 0.6, 0.6, true)
    tooltip:AddLine("Click to open its page.", 0.37, 0.81, 0.48)
end

-- Item page

local function CostRow(parent, top)
    local r = {}
    r.label = UI.Text(parent, "body", "text")
    r.label:SetPoint("TOPLEFT", 16, top)
    r.value = UI.Text(parent, "value", nil, "RIGHT")
    r.value:SetPoint("TOPRIGHT", -16, top + 2)
    r.note = UI.Text(parent, "small", "muted")
    r.note:SetPoint("TOPLEFT", r.label, "BOTTOMLEFT", 0, -3)
    r.note:SetPoint("RIGHT", parent, "RIGHT", -16, 0)
    r.note:SetWordWrap(true)
    r.note:SetMaxLines(2)
    function r:Set(label, value, valueColor, note)
        r.label:SetText(label or "")
        r.value:SetText(value or "")
        r.value:SetTextColor(addon:Color(valueColor or "text"))
        r.note:SetText(note or "")
        local shown = label ~= nil
        r.label:SetShown(shown); r.value:SetShown(shown); r.note:SetShown(shown)
    end
    return r
end

local function StatsText(stats)
    -- Recipes from before Dragonflight have no crafting stats at all
    if not stats then return "Base recipe numbers: older recipes have no multicraft or resourcefulness. For newer ones, open the profession." end
    local parts = {}
    if stats.multicraft > 0 then table.insert(parts, string.format("multicraft %.1f%%", stats.multicraft)) end
    if stats.resourcefulness > 0 then table.insert(parts, string.format("resourcefulness %.1f%%", stats.resourcefulness)) end
    if #parts == 0 then return "From your stats: no multicraft or resourcefulness yet." end
    return "From your stats: " .. table.concat(parts, ", ")
end

local ACTIVITY_COLORS = { Sold = "profit", Bought = "loss", Posted = "warning", Crafted = "line" }

local function CreatePage(parent)
    local page = CreateFrame("Frame", nil, parent)
    page:SetAllPoints()
    page:Hide()

    page.back = UI.Button(page, "< Items", 76, 26, function()
        page.item = nil
        addon.RefreshWindow()
    end)
    page.back:SetPoint("TOPLEFT", 0, 0)
    page.icon = page:CreateTexture(nil, "ARTWORK")
    page.icon:SetSize(36, 36)
    page.icon:SetPoint("LEFT", page.back, "RIGHT", 14, -6)
    page.name = UI.Text(page, "title")
    page.name:SetPoint("TOPLEFT", page.icon, "TOPRIGHT", 12, 0)
    page.name:SetPoint("RIGHT", page, "RIGHT", -140, 0)
    page.sub = UI.Text(page, "small", "muted")
    page.sub:SetPoint("TOPLEFT", page.name, "BOTTOMLEFT", 0, -4)
    page.sub:SetPoint("RIGHT", page, "RIGHT", -140, 0)
    page.craft = UI.Button(page, "Craft this", 120, 28, function()
        local d = page.details
        if d and d.recipe then
            -- With concentration when this tier needs it
            addon:OpenCraftPlan(d.recipe, d.tier and { tier = d.tier, concentrate = d.concentration ~= nil } or nil,
                d.charKey)
        end
    end)
    page.craft:SetPoint("TOPRIGHT", 0, 0)
    UI.SetTooltip(page.craft, function(tooltip)
        tooltip:AddLine("Open the planner: materials, quantity and a shopping list.", 1, 1, 1, true)
    end)

    -- Tiles
    local tileWidth = (WIDTH - 4 * 10) / 5
    page.tiles = {}
    for i = 1, 5 do
        local tile = UI.StatTile(page, i == 5 and "highlight" or "panel")
        tile:SetWidth(tileWidth)
        tile:SetPoint("TOPLEFT", (i - 1) * (tileWidth + 10), -52)
        page.tiles[i] = tile
    end

    local panelTop = -52 - 76 - GAP
    local panelWidth = (WIDTH - 2 * GAP) / 3

    -- What it costs
    local costs = UI.Panel(page)
    costs:SetPoint("TOPLEFT", 0, panelTop)
    costs:SetPoint("BOTTOMLEFT", 0, 0)
    costs:SetWidth(panelWidth)
    local costsTitle = UI.Text(costs, "heading")
    costsTitle:SetPoint("TOPLEFT", 16, -14)
    costsTitle:SetText("What it costs")
    page.costRows = { CostRow(costs, -44), CostRow(costs, -94), CostRow(costs, -144) }
    page.concNote = UI.Text(costs, "small", "conc")
    page.concNote:SetPoint("TOPLEFT", 16, -192)
    page.concNote:SetPoint("RIGHT", -16, 0)
    page.tiersLabel = UI.Text(costs, "label", "muted")
    page.tiersLabel:SetText("TIERS")
    page.tierRows = {}
    for i = 1, TIER_ROWS do
        local row = CreateFrame("Button", nil, costs, "BackdropTemplate")
        row:SetHeight(22)
        row:SetPoint("BOTTOMLEFT", 10, 12 + (TIER_ROWS - i) * 24)
        row:SetPoint("RIGHT", costs, "RIGHT", -10, 0)
        local hover = row:CreateTexture(nil, "HIGHLIGHT")
        hover:SetAllPoints()
        hover:SetColorTexture(addon:Color("hover"))
        row.label = UI.Text(row, "small", "text")
        row.label:SetPoint("LEFT", 6, 0)
        row.value = UI.Text(row, "small", "muted", "RIGHT")
        row.value:SetPoint("RIGHT", -6, 0)
        row:SetScript("OnClick", function(self)
            page.item.itemID = self.itemID
            addon.RefreshWindow()
        end)
        page.tierRows[i] = row
    end

    -- Price chart
    local chartPanel = UI.Panel(page)
    chartPanel:SetPoint("TOPLEFT", panelWidth + GAP, panelTop)
    chartPanel:SetPoint("BOTTOMLEFT", panelWidth + GAP, 0)
    chartPanel:SetWidth(panelWidth)
    local chartTitle = UI.Text(chartPanel, "heading")
    chartTitle:SetPoint("TOPLEFT", 16, -14)
    chartTitle:SetText("Price, 30 days")
    page.chartNote = UI.Text(chartPanel, "label", "dim", "RIGHT")
    page.chartNote:SetPoint("TOPRIGHT", -16, -16)
    local chartArea = CreateFrame("Frame", nil, chartPanel)
    chartArea:SetPoint("TOPLEFT", 16, -44)
    chartArea:SetPoint("BOTTOMRIGHT", -16, 48)
    page.chart = UI.LineChart(chartArea)
    page.chart:SetAllPoints()
    page.chartEmpty = UI.Text(chartArea, "small", "muted", "CENTER")
    page.chartEmpty:SetPoint("CENTER")
    page.chartEmpty:SetWidth(panelWidth - 50)
    page.chartEmpty:SetWordWrap(true)
    page.chartStart = UI.Text(chartPanel, "label", "dim")
    page.chartStart:SetPoint("TOPLEFT", chartArea, "BOTTOMLEFT", 0, -6)
    page.chartEnd = UI.Text(chartPanel, "label", "dim", "RIGHT")
    page.chartEnd:SetPoint("TOPRIGHT", chartArea, "BOTTOMRIGHT", 0, -6)
    page.chartRange = UI.Text(chartPanel, "small", "muted", "CENTER")
    page.chartRange:SetPoint("BOTTOM", 0, 14)

    -- Your activity
    local activity = UI.Panel(page)
    activity:SetPoint("TOPLEFT", 2 * (panelWidth + GAP), panelTop)
    activity:SetPoint("BOTTOMRIGHT", 0, 0)
    local activityTitle = UI.Text(activity, "heading")
    activityTitle:SetPoint("TOPLEFT", 16, -14)
    activityTitle:SetText("Your activity")
    page.earned = UI.Text(activity, "small", "muted")
    page.earned:SetPoint("TOPLEFT", 16, -36)
    page.earned:SetPoint("RIGHT", -16, 0)
    page.activityRows = {}
    for i = 1, ACTIVITY_ROWS do
        local row = {}
        local top = -58 - (i - 1) * 21
        row.date = UI.Text(activity, "label", "dim")
        row.date:SetPoint("TOPLEFT", 16, top - 1)
        row.date:SetWidth(44)
        row.gold = UI.Text(activity, "small", nil, "RIGHT")
        row.gold:SetPoint("TOPRIGHT", -16, top)
        row.detail = UI.Text(activity, "small")
        row.detail:SetPoint("TOPLEFT", 64, top)
        row.detail:SetPoint("RIGHT", row.gold, "LEFT", -6, 0)
        page.activityRows[i] = row
    end
    -- A link to this item's full history
    page.moreButton = CreateFrame("Button", nil, activity)
    page.moreButton:SetPoint("BOTTOMLEFT", 16, 10)
    page.moreButton:SetSize(240, 16)
    page.more = UI.Text(page.moreButton, "small", "gold")
    page.more:SetPoint("LEFT")
    page.moreButton:SetScript("OnClick", function()
        if page.details then addon:OpenHistory({ item = page.details.name }) end
    end)
    page.moreButton:SetScript("OnEnter", function() page.more:SetTextColor(addon:Color("text")) end)
    page.moreButton:SetScript("OnLeave", function() page.more:SetTextColor(addon:Color("gold")) end)

    function page:Fill()
        local d = addon:GetItemDetails(page.item.name, page.item.itemID)
        page.details = d
        page.item.itemID = d.itemID

        -- Header
        page.icon:SetTexture(d.itemID and C_Item.GetItemIconByID(d.itemID) or 134400)
        page.name:SetText(ItemText(d.name, d.itemID))
        local quality = d.itemID and C_Item.GetItemQualityByID(d.itemID)
        local qualityColor = quality and ITEM_QUALITY_COLORS and ITEM_QUALITY_COLORS[quality]
        if qualityColor then
            page.name:SetTextColor(qualityColor.r, qualityColor.g, qualityColor.b)
        else
            page.name:SetTextColor(addon:Color("text"))
        end
        local sub = {}
        if d.tier then table.insert(sub, string.format("Tier %d of %d", d.tier, d.tierCount or d.tier)) end
        if d.profession then table.insert(sub, d.profession) end
        local expansion = d.itemID and addon:GetItemExpansion(d.itemID)
        if expansion then table.insert(sub, addon:GetExpansionName(expansion)) end
        if d.recipe and d.charKey and d.charKey ~= addon.charKey then
            local c = GoldsmithDB.characters[d.charKey]
            table.insert(sub, "crafted on " .. (c and c.name or d.charKey))
        end
        page.sub:SetText(table.concat(sub, "  ·  "))
        page.craft:SetShown(d.recipe ~= nil)

        -- Tiles
        local t = page.tiles
        local stale = d.priceAge and d.priceAge >= STALE_PRICE_DAYS
        t[1]:Set("AH price", d.price and Money(d.price) or "-", d.price and "text" or "dim",
            d.price and d.priceText or "scan with Auctionator", stale and "warning" or "muted")
        t[1].tooltip = function(tooltip)
            tooltip:AddLine("AH price", 1, 1, 1)
            if d.priceSource then tooltip:AddDoubleLine("From", d.priceSource, 0.8, 0.8, 0.8, 1, 1, 1) end
            if stale then tooltip:AddLine("A few days old, so it may be off.", 1, 0.6, 0.2, true) end
        end

        local insight = d.insight
        if insight then
            local pct = insight.diff * 100
            local note = math.abs(pct) < 1 and "about usual right now"
                or string.format("now %.0f%% %s usual", math.abs(pct), pct > 0 and "above" or "below")
            t[2]:Set("Usual price", Money(insight.usual), "text", note)
        else
            t[2]:Set("Usual price", "-", "dim", string.format("needs 5 days (%d so far)", d.historyDays or 0))
        end
        t[2].tooltip = function(tooltip)
            tooltip:AddLine("Usual price", 1, 1, 1)
            tooltip:AddLine("The middle of the prices saved each day Auctionator scans, not counting today.", 0.6, 0.6, 0.6, true)
            if insight then
                tooltip:AddDoubleLine("Lowest", Money(insight.low), 0.8, 0.8, 0.8, 1, 1, 1)
                tooltip:AddDoubleLine("Highest", Money(insight.high), 0.8, 0.8, 0.8, 1, 1, 1)
                tooltip:AddDoubleLine("Days of prices", tostring(insight.days), 0.8, 0.8, 0.8, 1, 1, 1)
            end
        end

        -- Where it's from is in the hover; the tile only has room for one note
        local demandNote = d.saleRate and (addon:FormatSaleRate(d.saleRate) .. " of listings sell")
            or (d.demandSource == "your sales" and "your sales" or "region (TSM)")
        t[3]:Set("Sold per day", addon:FormatDemand(d.demand), d.demand and "text" or "dim",
            d.demand and demandNote or "no sales data")
        t[3].tooltip = function(tooltip)
            tooltip:AddLine("Sold per day", 1, 1, 1)
            if d.demand then tooltip:AddDoubleLine("Sold per day", string.format("%s (%s)",
                addon:FormatDemand(d.demand), d.demandSource or "?"), 0.8, 0.8, 0.8, 1, 1, 1) end
            if d.saleRate then tooltip:AddDoubleLine("Sale rate", addon:FormatSaleRate(d.saleRate)
                .. " of listings sell", 0.8, 0.8, 0.8, 1, 1, 1) end
        end

        local heldDays = d.heldSince and DaysSince(d.heldSince)
        local heldNote = heldDays and ("held " .. Plural(heldDays, "day"))
            or (d.have > 0 and "all characters" or "none on any character")
        t[4]:Set("You have", tostring(d.have), d.have > 0 and "text" or "dim", heldNote,
            heldDays and heldDays >= addon:Setting("heldDays") and "warning" or "muted")
        t[4].tooltip = function(tooltip)
            tooltip:AddLine("You have", 1, 1, 1)
            for _, entry in ipairs(d.byCharacter or {}) do
                tooltip:AddDoubleLine(entry.name, tostring(entry.count), 0.8, 0.8, 0.8, 1, 1, 1)
            end
            if d.have == 0 then tooltip:AddLine("None on any character or in the warband bank.", 0.6, 0.6, 0.6, true) end
            if heldDays then
                tooltip:AddLine("Held since your oldest copy was made or bought (oldest sold first).", 0.6, 0.6, 0.6, true)
            end
        end

        local fromText = { yours = "what yours cost you", paid = "what you paid", estimated = "the estimated cost",
            worst = "the worst-case cost (see Settings)" }
        if d.breakEven then
            local selling = d.price and d.price * 0.95 - (d.breakEven * 0.95)
            t[5]:Set("Break-even", Money(d.breakEven), "gold", "list above this")
            t[5].tooltip = function(tooltip)
                tooltip:AddLine("Break-even", 1, 1, 1)
                tooltip:AddLine("The lowest price that doesn't lose gold: " .. fromText[d.breakEvenFrom]
                    .. " plus the 5% AH cut.", 0.6, 0.6, 0.6, true)
                if selling then
                    tooltip:AddDoubleLine("At today's AH price", Signed(selling) .. " each", 0.8, 0.8, 0.8,
                        addon:Color(addon:MoneyColor(selling)))
                end
            end
        else
            t[5]:Set("Break-even", "-", "dim", "no cost known yet")
            t[5].tooltip = nil
        end

        -- What it costs
        local r = page.costRows
        if d.recipe and not d.material then
            if d.yours then
                r[1]:Set("Yours cost you", Money(d.yours), "text", "your latest crafts of it")
            else
                r[1]:Set("Yours cost you", "-", "dim", "not crafted yet")
            end
            r[2]:Set("Estimated", d.estimated and (Money(d.estimated) .. (d.partial and "+" or "")) or "-", "text",
                StatsText(d.stats))
            r[3]:Set("Worst case", d.worst and Money(d.worst) or "-", "muted", "no multicraft or resourcefulness")
        else
            local sources = { paid = "bought", milled = "milled", crafted = "crafted" }
            local how = {}
            for part in (d.paidSource or "paid"):gmatch("[^+]+") do table.insert(how, sources[part] or part) end
            r[1]:Set("What you paid", d.paid and Money(d.paid) or "-", d.paid and "text" or "dim",
                d.paid and ("average of what you " .. table.concat(how, " and ")) or "nothing bought yet")
            r[2]:Set("AH price now", d.price and Money(d.price) or "-", "text", d.priceText)
            r[3]:Set(nil)
        end
        page.concNote:SetText(d.concentration
            and string.format("This tier needs about %d concentration per craft.", d.concentration) or "")

        local showTiers = #d.tiers > 1
        page.tiersLabel:ClearAllPoints()
        page.tiersLabel:SetPoint("BOTTOMLEFT", page.tierRows[TIER_ROWS - math.min(#d.tiers, TIER_ROWS) + 1], "TOPLEFT", 6, 4)
        page.tiersLabel:SetShown(showTiers)
        for i, row in ipairs(page.tierRows) do
            -- Rows fill from the bottom up so the list sits at the panel's foot
            local tier = showTiers and d.tiers[i - (TIER_ROWS - math.min(#d.tiers, TIER_ROWS))]
            if tier then
                row.itemID = tier.itemID
                local selected = tier.itemID == d.itemID
                UI.Style(row, selected and "highlight" or "panelRaised", selected and "borderGold" or nil)
                row.label:SetText(ItemText(d.name, tier.itemID))
                row.value:SetText(string.format("%s%s", tier.price and Money(tier.price) or "-",
                    tier.have > 0 and ("  ·  have " .. tier.have) or ""))
                row:Show()
            else
                row:Hide()
            end
        end

        -- Price chart
        local points = {}
        for _, p in ipairs(d.history) do
            table.insert(points, { value = p.value, day = p.day, color = "line", tooltip = function(tooltip)
                local y, m, dd = p.day:match("(%d+)-(%d+)-(%d+)")
                tooltip:AddLine(date("%b %d", time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 })), 1, 1, 1)
                tooltip:AddDoubleLine("AH price", Money(p.value), 0.8, 0.8, 0.8, 1, 1, 1)
            end })
        end
        local enough = #points >= 2
        page.chart:SetShown(enough)
        page.chartEmpty:SetShown(not enough)
        page.chartEmpty:SetText("Goldsmith saves a price each day Auctionator scans. The chart starts after 2 days.")
        if enough then
            local band = d.bandLow and { low = d.bandLow, high = d.bandHigh, usual = insight and insight.usual }
            page.chart:SetData(points, { band = band })
            page.chartNote:SetText(band and "band = usual range" or "")
            local function Short(day)
                local y, m, dd = day:match("(%d+)-(%d+)-(%d+)")
                return date("%b %d", time({ year = tonumber(y), month = tonumber(m), day = tonumber(dd), hour = 12 }))
            end
            page.chartStart:SetText(Short(points[1].day))
            page.chartEnd:SetText(Short(points[#points].day))
            local low, high = math.huge, 0
            for _, p in ipairs(points) do low, high = math.min(low, p.value), math.max(high, p.value) end
            page.chartRange:SetText(string.format("low %s  ·  high %s", Money(low), Money(high)))
        else
            page.chartNote:SetText("")
            page.chartStart:SetText("")
            page.chartEnd:SetText("")
            page.chartRange:SetText("")
        end

        -- Activity
        if d.earned and d.earned.units > 0 then
            page.earned:SetText(string.format("Sold %d for %s, %s profit", d.earned.units, Money(d.earned.sales),
                addon:Colorize(Signed(d.earned.profit), addon:MoneyColor(d.earned.profit))))
        else
            page.earned:SetText("Nothing sold yet.")
        end
        for i, row in ipairs(page.activityRows) do
            local a = d.activity[i]
            if a then
                row.date:SetText(date("%b %d", a.time))
                local tier = a.tier and d.tierCount and (" " .. addon:TierIconText(a.tier, d.tierCount)) or ""
                row.detail:SetText(string.format("%s %d%s", a.kind, a.qty or 0, tier))
                row.detail:SetTextColor(addon:Color(ACTIVITY_COLORS[a.kind] or "text"))
                if a.kind == "Crafted" then
                    row.gold:SetText(Money(a.gold) .. (a.partial and "+" or "") .. " each")
                    row.gold:SetTextColor(addon:Color("muted"))
                else
                    row.gold:SetText(Signed(a.gold))
                    row.gold:SetTextColor(addon:Color(addon:MoneyColor(a.gold)))
                end
                row.date:Show(); row.detail:Show(); row.gold:Show()
            else
                row.date:Hide(); row.detail:Hide(); row.gold:Hide()
            end
        end
        if #d.activity == 0 then
            page.activityRows[1].detail:SetText("No purchases, crafts or sales recorded.")
            page.activityRows[1].detail:SetTextColor(addon:Color("muted"))
            page.activityRows[1].detail:Show()
        end
        page.more:SetText(#d.activity > ACTIVITY_ROWS
            and string.format("and %d older: see all in History  >", #d.activity - ACTIVITY_ROWS)
            or "See all in History  >")
        page.moreButton:SetShown(#d.activity > 0)
    end

    return page
end

-- View

local view

local function Create(parent)
    local ui = GoldsmithDB.ui2
    view = { search = "" }

    local landing = CreateFrame("Frame", nil, parent)
    landing:SetAllPoints()
    view.landing = landing

    view.searchBox = UI.SearchBox(landing, 280, "Find an item, or shift-click one", function(text)
        view.search = text
        view.list:ScrollToTop()
        addon.RefreshWindow()
    end)
    view.searchBox:SetPoint("TOPLEFT", 0, 0)

    -- Shift-clicking an item (bags, AH, a link in chat) searches for it, the
    -- way it would put a link in chat: when the search box has the cursor,
    -- or when the Items tab is showing and chat isn't open. The game sends
    -- shift-clicked links through the chat's insert function; Goldsmith
    -- watches it (both the old and the newer name).
    local function IsChatOpen()
        local active = (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
            or (ChatFrameUtil and ChatFrameUtil.GetActiveWindow and ChatFrameUtil.GetActiveWindow())
        return active ~= nil
    end
    local function OnInsertLink(link)
        if type(link) ~= "string" or not link:find("|Hitem:") then return end
        if not (addon.window and addon.window:IsShown()) then return end
        local focused = view.searchBox:HasFocus()
        if not focused and (GoldsmithDB.ui2.tab ~= "items" or IsChatOpen()) then return end
        local name = C_Item.GetItemInfo(link) or link:match("%[(.-)%]")
        if not name then return end
        -- Crafted items' links carry a quality icon after the name
        name = strtrim((name:gsub("|A.-|a", "")))
        view.searchBox:SetText(name)
        view.searchBox:ClearFocus()
        view.search = name
        view.page.item = nil
        view.list:ScrollToTop()
        addon:ShowTab("items")
    end
    if ChatEdit_InsertLink then hooksecurefunc("ChatEdit_InsertLink", OnInsertLink) end
    if ChatFrameUtil and ChatFrameUtil.InsertLink then hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink) end
    view.inBags = UI.Checkbox(landing, "In my bags", function(checked)
        ui.itemsInBags = checked or nil
        view.list:ScrollToTop()
        addon.RefreshWindow()
    end)
    view.inBags:SetPoint("LEFT", view.searchBox, "RIGHT", 16, 0)
    UI.SetTooltip(view.inBags, function(tooltip)
        tooltip:AddLine("In my bags", 1, 1, 1)
        tooltip:AddLine("Everything you hold on every character and in the warband bank, with what it's worth and how long you've had it.", 0.6, 0.6, 0.6, true)
    end)
    view.note = UI.Text(landing, "label", "dim", "RIGHT")
    view.note:SetPoint("TOPRIGHT", 0, -7)

    local boardWidth = (WIDTH - GAP) / 2
    local boardHeight = (506 - TOP_HEIGHT - GAP - GAP) / 2
    view.boards = {}
    for i, def in ipairs(BOARDS) do
        local board = CreateBoard(landing, def)
        board:SetSize(boardWidth, boardHeight)
        local col, rowIndex = (i - 1) % 2, math.floor((i - 1) / 2)
        board:SetPoint("TOPLEFT", col * (boardWidth + GAP), -(TOP_HEIGHT + GAP) - rowIndex * (boardHeight + GAP))
        view.boards[i] = board
    end

    view.list = UI.List(landing, {
        fill = function(row, item)
            if view.listMode == "stock" then FillStockRow(row, item) else FillSearchRow(row, item) end
        end,
        tooltip = function(tooltip, item)
            if view.listMode == "stock" then
                StockTooltip(tooltip, item)
            else
                tooltip:AddLine(ItemText(item.name, item.itemID), 1, 1, 1)
                tooltip:AddLine("Click to open its page.", 0.37, 0.81, 0.48)
            end
        end,
        onClick = function(item) addon:OpenItem(item.name, item.itemID) end,
        onSort = function(key)
            SetSort(view.listMode, key)
            view.list:ScrollToTop()
            addon.RefreshWindow()
        end,
    })
    view.list:SetPoint("TOPLEFT", 0, -(TOP_HEIGHT + GAP))
    view.list:SetPoint("BOTTOMRIGHT", 0, 22)
    view.footer = UI.Text(landing, "small", "muted")
    view.footer:SetPoint("BOTTOMLEFT", 2, 2)

    view.page = CreatePage(parent)
    return view
end

local function Refresh(v, state)
    local ui = GoldsmithDB.ui2
    if pending then
        if pending.page then
            v.page.item = pending.page
        else
            v.page.item = nil
            if pending.landing.inBags then ui.itemsInBags = true end
            v.list:ScrollToTop()
        end
        pending = nil
    end

    local onPage = v.page.item ~= nil
    v.page:SetShown(onPage)
    v.landing:SetShown(not onPage)
    if onPage then
        v.page:Fill()
        return
    end

    local inBags = ui.itemsInBags == true
    v.inBags:SetChecked(inBags)
    local search = v.search or ""
    local showList = inBags or search ~= ""
    for _, board in ipairs(v.boards) do board:SetShown(not showList) end
    v.list:SetShown(showList)
    v.footer:SetShown(showList)

    if not showList then
        local boards = addon:GetItemBoards(state.profession, state.range)
        local rangeLabel = addon:GetDateRange(state.range).label:lower()
        for _, board in ipairs(v.boards) do
            local key = board.def.key
            board:Set(boards[key], key == "held" and "all characters" or rangeLabel)
        end
        v.note:SetText("Click an item for its page")
        return
    end

    if inBags then
        local stock = addon:GetStockValue(state.profession)
        local items, value = {}, 0
        local needle = search:lower()
        for _, item in ipairs(stock.items) do
            if needle == "" or item.name:lower():find(needle, 1, true) then
                table.insert(items, item)
                value = value + item.value
            end
        end
        v.listMode = "stock"
        AddSales(items)
        SortItems(items, "stock")
        local sort = GetSort("stock")
        v.list:SetSort(sort.key, sort.descending)
        v.list:SetEmptyText(search ~= "" and "Nothing you hold matches." or "Nothing tracked in your bags yet.")
        v.list:SetColumnsAndItems(addon:AvailableColumns(STOCK_COLUMNS), items)
        v.footer:SetText(string.format("%s in %s, all characters and the warband bank", Money(value), Plural(#items, "item")))
        v.note:SetText("Click a column to sort")
    else
        local results = addon:SearchItems(search, state.profession, SEARCH_LIMIT)
        v.listMode = "search"
        AddSales(results)
        SortItems(results, "search")
        local sort = GetSort("search")
        v.list:SetSort(sort and sort.key, sort and sort.descending)
        v.list:SetEmptyText("No items match. Goldsmith knows the items in your saved recipes, their materials and what you've bought.")
        v.list:SetColumnsAndItems(addon:AvailableColumns(SEARCH_COLUMNS), results)
        v.footer:SetText(#results >= SEARCH_LIMIT and string.format("First %d matches. Type more to narrow it down.", SEARCH_LIMIT)
            or (#results == 1 and "1 match" or (#results .. " matches")))
        v.note:SetText(state.profession ~= "All" and ("Only " .. state.profession .. ", click a column to sort")
            or "Click a column to sort")
    end
end

addon:RegisterView("items", { create = Create, refresh = Refresh })

_G.Goldsmith = addon
