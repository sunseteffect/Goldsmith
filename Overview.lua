local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Overview tab
--
-- "How am I doing, and what should I do now?" Four numbers, a "Do this
-- next" list, a chart you can cycle through, and a row per profession.
-- Everything covers all your characters; the header's profession and date
-- filters apply. The numbers come from Insights.lua and Data.lua.

local WIDTH = 860
local GAP = 12
local TILE_WIDTH = (WIDTH - 3 * GAP) / 4
local MIDDLE_TOP = -(76 + GAP)
local MIDDLE_HEIGHT = 290
local HALF_WIDTH = (WIDTH - GAP) / 2
local BOTTOM_TOP = MIDDLE_TOP - MIDDLE_HEIGHT - GAP
local BOTTOM_HEIGHT = 116
local ACTION_COUNT = 3
local CRAFTS_SHOWN = 3
local ACTION_ROW_GAP = 8
local CRAFTS_LISTED = 5
local PROFESSION_CELLS = 6

local CHARTS = {
    { key = "profit", title = "Profit by day" },
    { key = "gold", title = "Total gold" },
    { key = "perHour", title = "Gold per hour" },
}

local Money, Signed = function(c) return addon:FormatMoney(c) end, function(c) return addon:FormatSignedMoney(c) end

-- "2026-09-25" -> "Sep 25"
local function ShortDay(day)
    local y, m, d = day:match("(%d+)-(%d+)-(%d+)")
    return date("%b %d", time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))
end

local function HoursText(minutes)
    if not minutes then return "full" end
    if minutes < 60 then return string.format("full in %dm", math.ceil(minutes)) end
    return string.format("full in %.1fh", minutes / 60)
end

-- Character name, only when it isn't you (you're the default)
local function OnWho(charKey)
    if not charKey or charKey == addon.charKey then return "" end
    local c = GoldsmithDB.characters[charKey]
    return " on " .. (c and c.name or charKey)
end

local function ItemText(itemID, name, tier, tierCount)
    local icon = tier and tierCount and addon:TierIconText(tier, tierCount) or ""
    return (name or C_Item.GetItemNameByID(itemID) or "?") .. icon
end

-- Tiles

local function FillProfitTile(tile, s)
    local note = s.margin and string.format("%.0f%% margin", s.margin) or (s.sales > 0 and "cost unknown" or "no sales yet")
    tile:Set("Profit on sales", Signed(s.profit), addon:MoneyColor(s.profit), note)
    tile.tooltip = function(tooltip)
        tooltip:AddLine("Profit on sales", 1, 1, 1)
        tooltip:AddDoubleLine("Sales", Money(s.sales), 0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddDoubleLine("What the items sold cost you", "-" .. Money(s.soldCost), 0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddDoubleLine("AH deposits", "-" .. Money(s.deposits), 0.8, 0.8, 0.8, 1, 1, 1)
        if s.unknownSales > 0 then
            tooltip:AddLine(string.format("%d sale%s without cost data left out.", s.unknownSales,
                s.unknownSales == 1 and "" or "s"), 1, 0.6, 0.2, true)
        end
        if s.estimated then
            tooltip:AddLine("Some older sales use today's cost estimate.", 0.6, 0.6, 0.6, true)
        end
    end
end

local function FillSalesTile(tile, s)
    tile:Set("Sales", Money(s.sales), "text", "after the AH cut")
    tile.tooltip = function(tooltip)
        tooltip:AddLine("Sales", 1, 1, 1)
        tooltip:AddDoubleLine("Spent on materials", Money(s.spent), 0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddLine("Materials you still hold aren't a loss until they're used or sold.", 0.6, 0.6, 0.6, true)
    end
end

local function FillStockTile(tile, stock, prof)
    -- Say which profession is counted, so a filtered total isn't mistaken
    -- for everything
    local scope = prof == "All" and "All professions" or (addon:ProfessionIconText(prof) .. prof .. " only")
    local held = #stock.heldLong
    if held > 0 then
        tile:Set("Gold in stock", Money(stock.value), "text",
            string.format("%s, %d item%s held 7+ days", scope, held, held == 1 and "" or "s"), "warning")
    else
        tile:Set("Gold in stock", Money(stock.value), "text",
            #stock.items > 0 and (scope .. ", all characters") or "nothing tracked in your bags yet")
    end
    tile.tooltip = function(tooltip)
        tooltip:AddLine("Gold in stock", 1, 1, 1)
        if prof ~= "All" then
            tooltip:AddLine("Only " .. prof .. " items. Pick All professions at the top to see everything.", 1, 0.82, 0, true)
        end
        tooltip:AddLine("Valued at what it cost you, or the AH price when there's no cost.", 0.6, 0.6, 0.6, true)
        for i = 1, math.min(#stock.items, 8) do
            local item = stock.items[i]
            tooltip:AddDoubleLine(string.format("%s x%d", item.name, item.count), Money(item.value),
                0.9, 0.9, 0.9, 1, 1, 1)
        end
        if #stock.items > 8 then
            tooltip:AddLine(string.format("and %d more", #stock.items - 8), 0.6, 0.6, 0.6)
        end
        if held > 0 then
            tooltip:AddLine(" ")
            tooltip:AddLine("Held 7+ days", 1, 0.6, 0.2)
            for i = 1, math.min(held, 6) do
                local item = stock.heldLong[i]
                local days = math.floor((time() - item.heldSince) / 86400)
                tooltip:AddDoubleLine(string.format("%s x%d", item.name, item.count),
                    string.format("%d days", days), 0.9, 0.9, 0.9, 1, 0.6, 0.2)
            end
        end
    end
end

local function FillConcentrationTile(tile, conc)
    if #conc.rows == 0 then
        tile:Set("Concentration", "-", "muted", "open each profession once to load it")
        tile.tooltip = nil
        return
    end
    local note = conc.gain > 0 and ("worth " .. Signed(conc.gain) .. " right now") or "nothing worth it right now"
    tile:Set("Concentration", string.format("%d / %d", conc.current, conc.max), "conc", note)
    tile.tooltip = function(tooltip)
        tooltip:AddLine("Concentration on all characters", 1, 1, 1)
        for _, row in ipairs(conc.rows) do
            tooltip:AddDoubleLine(
                string.format("%s - %s%s", row.name, addon:ProfessionIconText(row.profession), row.profession),
                string.format("%d / %d, %s", row.current, row.max, HoursText(row.minutesToFull)),
                0.9, 0.9, 0.9, 0.91, 0.76, 0.35)
            if row.gain > 0 then
                tooltip:AddDoubleLine("    worth", Signed(row.gain), 0.6, 0.6, 0.6, 0.37, 0.81, 0.48)
            end
        end
        tooltip:AddLine("Alts' concentration is worked out from when you last logged in on them.", 0.6, 0.6, 0.6, true)
    end
end

-- Do this next

local function ConcentrationAction(conc)
    local best
    for _, row in ipairs(conc.rows) do
        if row.gain > 0 and row.plan and row.plan[1] and (not best or row.gain > best.gain) then
            best = row
        end
    end
    if not best then return nil end
    local first = best.plan[1]
    return {
        highlight = true,
        title = string.format("%sCraft %dx %s with concentration%s", addon:ProfessionIconText(best.profession),
            first.crafts, ItemText(first.row.itemID, first.recipe.outputName, first.row.tier, first.tierCount),
            OnWho(best.key)),
        detail = string.format("%d concentration for %s extra, %s profit in total",
            first.points, Signed(first.gain), Signed(first.profit)),
        tooltip = function(tooltip)
            tooltip:AddLine(string.format("Best use of %s's %d concentration", best.name, best.current), 1, 1, 1)
            for _, p in ipairs(best.plan) do
                tooltip:AddDoubleLine(string.format("%dx %s", p.crafts,
                    ItemText(p.row.itemID, p.recipe.outputName, p.row.tier, p.tierCount)),
                    string.format("%d conc, %s", p.points, Signed(p.gain)), 0.9, 0.9, 0.9, 0.37, 0.81, 0.48)
            end
            tooltip:AddLine("Extra = profit on top of crafting the same thing without concentration.", 0.6, 0.6, 0.6, true)
            tooltip:AddLine("Click to plan it: materials and shopping list.", 0.37, 0.81, 0.48)
        end,
        onClick = function()
            addon:OpenCraftPlan(first.recipe, first.row, best.key,
                math.max(math.floor(first.crafts * (first.row.outputPerCraft or 1)), 1))
        end,
    }
end

local function CraftsAction(crafts, prof)
    if #crafts == 0 then return nil end
    -- One craft per line; the row has room for CRAFTS_SHOWN, the hover lists
    -- them all
    local parts = {}
    for i = 1, math.min(#crafts, CRAFTS_SHOWN) do
        local c = crafts[i]
        local icon = prof == "All" and addon:ProfessionIconText(c.recipe.profession) or ""
        local roi = c.margin and string.format("  ·  %.0f%% ROI", c.margin) or ""
        table.insert(parts, string.format("%s%s   %s%s", icon,
            ItemText(c.itemID, c.recipe.outputName, c.row.tier, c.row.tierCount),
            addon:Colorize(Signed(c.profit), "profit"), roi))
    end
    return {
        title = "Best crafts right now",
        detail = table.concat(parts, "\n"),
        tooltip = function(tooltip)
            tooltip:AddLine("Best crafts right now", 1, 1, 1)
            tooltip:AddLine("Current-expansion items with a 15%+ ROI (profit as a share of cost) that sell at least once a day, with no unknown costs. A craft drops off once you hold about a day's sales of it.", 0.6, 0.6, 0.6, true)
            for _, c in ipairs(crafts) do
                tooltip:AddLine(" ")
                tooltip:AddLine(ItemText(c.itemID, c.recipe.outputName, c.row.tier, c.row.tierCount)
                    .. OnWho(c.charKey), 1, 0.82, 0)
                tooltip:AddDoubleLine("Profit each", string.format("%s (%.0f%% ROI)", Signed(c.profit), c.margin or 0),
                    0.8, 0.8, 0.8, 0.37, 0.81, 0.48)
                if c.demand then
                    tooltip:AddDoubleLine("Sold per day", addon:FormatDemand(c.demand), 0.8, 0.8, 0.8, 1, 1, 1)
                end
                if c.have > 0 then
                    tooltip:AddDoubleLine("You have", tostring(c.have), 0.8, 0.8, 0.8, 1, 1, 1)
                end
            end
            tooltip:AddLine(" ")
            tooltip:AddLine("Click to see these in Crafts.", 0.37, 0.81, 0.48)
        end,
        onClick = function()
            local keys = {}
            for _, c in ipairs(crafts) do keys[c.key] = true end
            addon:OpenCrafts({ keys = keys, label = "Best crafts right now" })
        end,
    }
end

local DEAL_THRESHOLD = -0.10

local function DealsAction(prof)
    local deals, earliest, minDays = addon:GetDeals(prof)
    local cheap = {}
    for _, d in ipairs(deals) do
        if d.diff <= DEAL_THRESHOLD then table.insert(cheap, d) end
    end
    if #deals == 0 then
        return {
            title = "Cheap materials today",
            detail = string.format("Appear after %d days of price history, saved each time Auctionator updates. History started %s.",
                minDays, earliest and ShortDay(earliest) or "today"),
            muted = true,
        }
    end
    if #cheap == 0 then return nil end
    local parts = {}
    for i = 1, math.min(#cheap, 3) do
        table.insert(parts, string.format("%s %s", cheap[i].name,
            addon:Colorize(string.format("%.0f%%", cheap[i].diff * 100), "profit")))
    end
    return {
        title = "Cheap materials today",
        detail = table.concat(parts, "   ") .. " vs usual",
        tooltip = function(tooltip)
            tooltip:AddLine("Cheap materials today", 1, 1, 1)
            for i = 1, math.min(#cheap, 8) do
                local d = cheap[i]
                tooltip:AddDoubleLine(d.name, string.format("%s (usually %s)", Money(d.now), Money(d.usual)),
                    0.9, 0.9, 0.9, 0.37, 0.81, 0.48)
            end
        end,
    }
end

local function CreateActionRow(parent, i)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    -- Height and position are set in FillActionRow / Refresh, to fit the text
    row:SetSize(HALF_WIDTH - 32, 72)
    row.number = UI.Text(row, "heading", "muted")
    row.number:SetPoint("TOPLEFT", 12, -12)
    row.number:SetText(tostring(i))
    row.title = UI.Text(row, "body")
    row.title:SetPoint("TOPLEFT", 34, -11)
    row.title:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.detail = UI.Text(row, "small", "muted")
    row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -5)
    row.detail:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.detail:SetWordWrap(true)
    row.detail:SetMaxLines(CRAFTS_SHOWN)
    row.detail:SetJustifyV("TOP")
    row:EnableMouse(true)
    UI.SetTooltip(row, function(tooltip)
        if row.action and row.action.tooltip then row.action.tooltip(tooltip) end
    end)
    -- Rows that lead somewhere get a gold border on hover
    row:HookScript("OnEnter", function(self)
        if self.action and self.action.onClick then self:SetBackdropBorderColor(addon:Color("gold")) end
    end)
    row:HookScript("OnLeave", function(self)
        if self.action and self.action.onClick then
            self:SetBackdropBorderColor(addon:Color(self.action.highlight and "borderGold" or "borderStrong"))
        end
    end)
    row:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.action and self.action.onClick then self.action.onClick() end
    end)
    return row
end

local function FillActionRow(row, action)
    row.action = action
    if action.highlight then
        UI.Style(row, "highlight", "borderGold")
        row.number:SetTextColor(addon:Color("gold"))
    else
        UI.Style(row, "panelRaised", action.onClick and "borderStrong" or nil)
        row.number:SetTextColor(addon:Color("muted"))
    end
    row.title:SetText(action.title)
    row.title:SetTextColor(addon:Color(action.muted and "muted" or "text"))
    row.detail:SetText(action.detail or "")
    -- Tall enough for the title and however many detail lines there are
    local textHeight = row.title:GetStringHeight() + 5 + row.detail:GetStringHeight()
    row:SetHeight(math.max(56, math.ceil(11 + textHeight + 12)))
    row:Show()
end

-- Chart

local function ChartDays(range)
    return range == "30d" and 30 or 14
end

-- Returns points, subtitle, kind ("bar" or "line") and an empty message
-- (when there's nothing to draw)
local function ChartData(key, state)
    local days = ChartDays(state.range)
    if key == "profit" then
        local data = addon:GetDailyProfit(state.profession, days)
        local points, best, any = {}, nil, false
        for _, d in ipairs(data) do
            if d.profit ~= 0 or d.sales ~= 0 then any = true end
            if not best or d.profit > best.profit then best = d end
            table.insert(points, { value = d.profit, day = d.day, tooltip = function(tooltip)
                tooltip:AddLine(ShortDay(d.day), 1, 1, 1)
                tooltip:AddDoubleLine("Profit", Signed(d.profit), 0.8, 0.8, 0.8, 1, 1, 1)
                tooltip:AddDoubleLine("Sales", Money(d.sales), 0.8, 0.8, 0.8, 1, 1, 1)
            end })
        end
        local subtitle = string.format("last %d days", days)
        if best and best.profit > 0 then subtitle = subtitle .. ", best day " .. Signed(best.profit) end
        return points, subtitle, "bar", not any and "Profit by day shows here once you've sold something."
    elseif key == "gold" then
        local history = addon:GetAccountGoldHistory(days)
        local points, recorded = {}, 0
        for _, d in ipairs(history) do
            if d.copper > 0 then
                recorded = recorded + 1
                table.insert(points, { value = d.copper, day = d.day, tooltip = function(tooltip)
                    tooltip:AddLine(ShortDay(d.day), 1, 1, 1)
                    tooltip:AddDoubleLine("Total gold", Money(d.copper), 0.8, 0.8, 0.8, 1, 1, 1)
                end })
            end
        end
        local now = history[#history] and history[#history].copper or 0
        local subtitle = "all characters and warband bank, now " .. Money(now)
        return points, subtitle, "line",
            recorded < 2 and "Your total gold is saved each day you play. The line starts tomorrow."
    else
        local data = addon:GetRollingGoldPerHour(state.profession, days)
        local points, latest = {}, nil
        for _, d in ipairs(data) do
            if d.perHour then latest = d end
            table.insert(points, { value = d.perHour or 0, day = d.day, tooltip = function(tooltip)
                tooltip:AddLine(ShortDay(d.day) .. ", 7 days to then", 1, 1, 1)
                if d.perHour then
                    tooltip:AddDoubleLine("Gold per hour", Signed(d.perHour) .. "/h", 0.8, 0.8, 0.8, 1, 1, 1)
                end
                tooltip:AddDoubleLine("Profit", Signed(d.profit), 0.8, 0.8, 0.8, 1, 1, 1)
                tooltip:AddDoubleLine("Goldmaking time", string.format("%dh %02dm",
                    math.floor(d.seconds / 3600), math.floor(d.seconds % 3600 / 60)), 0.8, 0.8, 0.8, 1, 1, 1)
            end })
        end
        local subtitle = "per hour of goldmaking, 7-day average"
        if latest then subtitle = subtitle .. ", now " .. Signed(latest.perHour) .. "/h" end
        return points, subtitle, "bar", not latest
            and "Counts time with a profession, the AH, the mailbox, a vendor or the bank open. It fills in as you make gold."
    end
end

-- By profession

local function CreateProfessionCell(parent, i)
    local width = (WIDTH - 32 - (PROFESSION_CELLS - 1) * 8) / PROFESSION_CELLS
    local cell = CreateFrame("Button", nil, parent, "BackdropTemplate")
    cell:SetSize(width, 60)
    cell:SetPoint("TOPLEFT", 16 + (i - 1) * (width + 8), -42)
    cell.name = UI.Text(cell, "small", "text")
    cell.name:SetPoint("TOPLEFT", 10, -8)
    cell.name:SetPoint("RIGHT", cell, "RIGHT", -6, 0)
    cell.profit = UI.Text(cell, "body")
    cell.profit:SetPoint("TOPLEFT", cell.name, "BOTTOMLEFT", 0, -4)
    cell.conc = UI.Text(cell, "label", "conc")
    cell.conc:SetPoint("TOPLEFT", cell.profit, "BOTTOMLEFT", 0, -3)
    UI.SetTooltip(cell, function(tooltip)
        if not cell.item then return end
        tooltip:AddLine(cell.item.profession, 1, 1, 1)
        tooltip:AddDoubleLine("Profit on sales", Signed(cell.item.profit), 0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddDoubleLine("Sales", Money(cell.item.sales), 0.8, 0.8, 0.8, 1, 1, 1)
        if cell.item.concMax > 0 then
            tooltip:AddDoubleLine("Concentration", string.format("%d / %d", cell.item.concCurrent, cell.item.concMax),
                0.8, 0.8, 0.8, 0.91, 0.76, 0.35)
        end
        tooltip:AddLine(cell.selected and "Click to show all professions." or "Click to show only this profession.",
            0.6, 0.6, 0.6)
    end)
    return cell
end

-- View

local function Create(parent)
    local view = {}

    view.tiles = {}
    for i = 1, 4 do
        local tile = UI.StatTile(parent, i == 4 and "highlight" or "panel")
        tile:SetWidth(TILE_WIDTH)
        tile:SetPoint("TOPLEFT", (i - 1) * (TILE_WIDTH + GAP), 0)
        view.tiles[i] = tile
    end

    -- Do this next
    local actions = UI.Panel(parent)
    actions:SetPoint("TOPLEFT", 0, MIDDLE_TOP)
    actions:SetSize(HALF_WIDTH, MIDDLE_HEIGHT)
    local actionsTitle = UI.Text(actions, "heading")
    actionsTitle:SetPoint("TOPLEFT", 16, -16)
    actionsTitle:SetText("Do this next")
    view.actionRows = {}
    for i = 1, ACTION_COUNT do
        view.actionRows[i] = CreateActionRow(actions, i)
    end
    view.actionsEmpty = UI.Text(actions, "body", "muted", "CENTER")
    view.actionsEmpty:SetPoint("CENTER", 0, -10)
    view.actionsEmpty:SetWidth(HALF_WIDTH - 60)
    view.actionsEmpty:SetWordWrap(true)
    view.actionsEmpty:SetText("Nothing to do yet. Open your professions to load recipes, and scan the AH with Auctionator for prices.")

    -- Chart
    local chartPanel = UI.Panel(parent)
    chartPanel:SetPoint("TOPLEFT", HALF_WIDTH + GAP, MIDDLE_TOP)
    chartPanel:SetSize(HALF_WIDTH, MIDDLE_HEIGHT)
    view.chartTitle = UI.Text(chartPanel, "heading")
    view.chartTitle:SetPoint("TOPLEFT", 16, -16)
    view.chartSubtitle = UI.Text(chartPanel, "label", "dim")
    view.chartSubtitle:SetPoint("TOPLEFT", view.chartTitle, "BOTTOMLEFT", 0, -5)

    local function CycleChart(step)
        local ui = GoldsmithDB.ui2
        ui.chart = ((ui.chart or 1) - 1 + step) % #CHARTS + 1
        addon.RefreshWindow()
    end
    local nextButton = UI.IconButton(chartPanel, 26, ">", "Next chart", function() CycleChart(1) end)
    nextButton:SetPoint("TOPRIGHT", -10, -10)
    local prevButton = UI.IconButton(chartPanel, 26, "<", "Previous chart", function() CycleChart(-1) end)
    prevButton:SetPoint("RIGHT", nextButton, "LEFT", -2, 0)
    view.chartPage = UI.Text(chartPanel, "label", "dim", "RIGHT")
    view.chartPage:SetPoint("RIGHT", prevButton, "LEFT", -4, 0)

    local chartArea = CreateFrame("Frame", nil, chartPanel)
    chartArea:SetPoint("TOPLEFT", 16, -62)
    chartArea:SetPoint("BOTTOMRIGHT", -16, 30)
    view.barChart = UI.BarChart(chartArea)
    view.barChart:SetAllPoints()
    view.lineChart = UI.LineChart(chartArea)
    view.lineChart:SetAllPoints()
    view.chartEmpty = UI.Text(chartArea, "small", "muted", "CENTER")
    view.chartEmpty:SetPoint("CENTER")
    view.chartEmpty:SetWidth(HALF_WIDTH - 80)
    view.chartEmpty:SetWordWrap(true)
    view.chartStart = UI.Text(chartPanel, "label", "dim")
    view.chartStart:SetPoint("TOPLEFT", chartArea, "BOTTOMLEFT", 0, -6)
    view.chartEnd = UI.Text(chartPanel, "label", "dim", "RIGHT")
    view.chartEnd:SetPoint("TOPRIGHT", chartArea, "BOTTOMRIGHT", 0, -6)

    -- By profession
    local professions = UI.Panel(parent)
    professions:SetPoint("TOPLEFT", 0, BOTTOM_TOP)
    professions:SetSize(WIDTH, BOTTOM_HEIGHT)
    local professionsTitle = UI.Text(professions, "heading")
    professionsTitle:SetPoint("TOPLEFT", 16, -16)
    professionsTitle:SetText("By profession")
    view.professionsNote = UI.Text(professions, "label", "dim")
    view.professionsNote:SetPoint("LEFT", professionsTitle, "RIGHT", 10, -1)
    view.cells = {}
    for i = 1, PROFESSION_CELLS do
        view.cells[i] = CreateProfessionCell(professions, i)
    end

    return view
end

local function Refresh(view, state)
    local prof, range = state.profession, state.range

    local summary = addon:GetSummary(prof, range)
    local stock = addon:GetStockValue(prof)
    local conc = addon:GetConcentrationOverview(prof)
    FillProfitTile(view.tiles[1], summary)
    FillSalesTile(view.tiles[2], summary)
    FillStockTile(view.tiles[3], stock, prof)
    FillConcentrationTile(view.tiles[4], conc)

    -- Do this next
    local list = {}
    local concAction = ConcentrationAction(conc)
    if concAction then table.insert(list, concAction) end
    local craftsAction = CraftsAction(addon:GetBestCrafts(prof, CRAFTS_LISTED), prof)
    if craftsAction then table.insert(list, craftsAction) end
    local dealsAction = DealsAction(prof)
    if dealsAction then table.insert(list, dealsAction) end
    local top = -44
    for i, row in ipairs(view.actionRows) do
        if list[i] then
            FillActionRow(row, list[i])
            row:SetPoint("TOPLEFT", 16, top)
            top = top - row:GetHeight() - ACTION_ROW_GAP
        else
            row:Hide()
        end
    end
    view.actionsEmpty:SetShown(#list == 0)

    -- Chart
    local index = GoldsmithDB.ui2.chart or 1
    if not CHARTS[index] then index = 1 end
    local chart = CHARTS[index]
    local points, subtitle, kind, empty = ChartData(chart.key, state)
    view.chartTitle:SetText(chart.title)
    view.chartSubtitle:SetText(subtitle or "")
    view.chartPage:SetFormattedText("%d / %d", index, #CHARTS)
    view.barChart:SetShown(kind == "bar" and not empty)
    view.lineChart:SetShown(kind == "line" and not empty)
    if not empty then
        (kind == "bar" and view.barChart or view.lineChart):SetData(points)
    end
    view.chartEmpty:SetShown(empty and true or false)
    view.chartEmpty:SetText(empty or "")
    local first, last = points[1], points[#points]
    view.chartStart:SetText((not empty and first) and ShortDay(first.day) or "")
    view.chartEnd:SetText((not empty and last) and ShortDay(last.day) or "")

    -- By profession
    local breakdown = addon:GetProfessionBreakdown(range, prof == "All" and conc or addon:GetConcentrationOverview("All"))
    view.professionsNote:SetText(#breakdown > PROFESSION_CELLS
        and string.format("top %d by profit, click one to filter", PROFESSION_CELLS) or "click one to filter")
    for i, cell in ipairs(view.cells) do
        local item = breakdown[i]
        cell.item = item
        if item then
            cell.selected = item.profession == prof
            UI.Style(cell, cell.selected and "highlight" or "panelRaised", cell.selected and "borderGold" or nil)
            cell.name:SetText(addon:ProfessionIconText(item.profession) .. item.profession)
            cell.profit:SetText(Signed(item.profit))
            cell.profit:SetTextColor(addon:Color(addon:MoneyColor(item.profit)))
            cell.conc:SetText(item.concMax > 0 and string.format("Conc %d / %d", item.concCurrent, item.concMax) or "")
            cell:SetScript("OnClick", function()
                state.setProfession(cell.selected and "All" or item.profession)
            end)
            cell:Show()
        else
            cell:Hide()
        end
    end
end

addon:RegisterView("overview", { create = Create, refresh = Refresh })

_G.Goldsmith = addon
