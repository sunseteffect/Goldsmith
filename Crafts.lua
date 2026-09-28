local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Crafts tab
--
-- "What's worth crafting?" Every craft you know, in a simple view (Item,
-- Cost, AH price, Profit, ROI, Sold/day, Sale rate). The Concentration
-- switch adds the ways that use concentration, their Conc and g/conc
-- columns, and a budget bar. One cost number, estimated from your stats; the hover shows the worst
-- case and what yours cost you. Clicking a craft opens the planner.
--
-- Crafts the Overview wouldn't recommend (old expansion, slow sellers) are
-- shown dimmed with the reason in the hover, so the two tabs agree.
-- The numbers come from GetCraftRows (Insights.lua), GetTierRows
-- (Quality.lua) and BuildPlan (Planner.lua).

local AH_CUT = 0.05
local STALE_PRICE_DAYS = 3
local TOP_HEIGHT = 26
local FOOTER_HEIGHT = 44
local PLAN_SUMMARY_HEIGHT = 140

local Money, Signed = function(c) return addon:FormatMoney(c) end, function(c) return addon:FormatSignedMoney(c) end

local SIMPLE_COLUMNS = {
    { key = "item", label = "Item" },
    { key = "cost", label = "Cost", width = 78, justify = "RIGHT" },
    { key = "price", label = "AH price", width = 80, justify = "RIGHT" },
    { key = "profit", label = "Profit", width = 84, justify = "RIGHT" },
    { key = "margin", label = "ROI", width = 56, justify = "RIGHT" },
    { key = "demand", label = "Sold/day", width = 70, justify = "RIGHT" },
    { key = "saleRate", label = "Sale rate", width = 64, justify = "RIGHT" },
}
local CONC_COLUMNS = {
    { key = "item", label = "Item" },
    { key = "cost", label = "Cost", width = 78, justify = "RIGHT" },
    { key = "price", label = "AH price", width = 80, justify = "RIGHT" },
    { key = "profit", label = "Profit", width = 84, justify = "RIGHT" },
    { key = "margin", label = "ROI", width = 56, justify = "RIGHT" },
    { key = "conc", label = "Conc", width = 50, justify = "RIGHT" },
    { key = "gpc", label = "g/conc", width = 60, justify = "RIGHT" },
    { key = "demand", label = "Sold/day", width = 70, justify = "RIGHT" },
    { key = "saleRate", label = "Sale rate", width = 64, justify = "RIGHT" },
}

local function ItemText(item)
    local tier = item.tier and (" " .. addon:TierIconText(item.tier, item.info.tierCount)) or ""
    return addon:ProfessionIconText(item.recipe.profession) .. item.recipe.outputName .. tier
end

local function CharName(charKey)
    local c = GoldsmithDB.characters[charKey]
    return c and c.name or charKey
end

-- Expansion filter. GoldsmithDB.ui2.expansions is a set of expansion IDs
-- to show; until it's changed, only the current expansion is shown.

local function IsExpansionShown(expansionID)
    -- Items not in the game's cache yet are shown until their data loads
    if expansionID == nil then return true end
    local selected = GoldsmithDB.ui2.expansions
    if not selected then return expansionID == addon:GetCurrentExpansion() end
    return selected[expansionID] == true
end

local function SetExpansionShown(expansionID, shown)
    local ui = GoldsmithDB.ui2
    ui.expansions = ui.expansions or { [addon:GetCurrentExpansion()] = true }
    ui.expansions[expansionID] = shown or nil
end

-- Expansions with at least one saved (sellable) recipe, newest first; the
-- current expansion is always offered
local function GetRecipeExpansions()
    local seen, list = {}, {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        local expansionID = addon:GetItemExpansion(recipe.outputItemID)
        if expansionID and not seen[expansionID] and addon:CanAuction(recipe.outputItemID) ~= false then
            seen[expansionID] = true
            table.insert(list, expansionID)
        end
    end
    local current = addon:GetCurrentExpansion()
    if not seen[current] then table.insert(list, current) end
    table.sort(list, function(a, b) return a > b end)
    return list
end

local function ExpansionLabel()
    local shown = {}
    for _, expansionID in ipairs(GetRecipeExpansions()) do
        if IsExpansionShown(expansionID) then table.insert(shown, expansionID) end
    end
    if #shown == 1 then return addon:GetExpansionName(shown[1]) end
    return string.format("Expansions (%d)", #shown)
end

-- Sorting. Clicking a header sorts by it; clicking again reverses. Each
-- column starts the most useful way round (names A-Z, cheapest first,
-- highest profit first). Rows with no value for the column go last.

local SORTS = {
    item   = { firstDescending = false, value = function(i) return i.recipe.outputName .. (i.tier or "") end },
    cost   = { firstDescending = false, value = function(i) return i.info.cost end },
    price  = { firstDescending = true,  value = function(i) return i.info.price end },
    profit = { firstDescending = true,  value = function(i) return i.info.profit end },
    margin = { firstDescending = true,  value = function(i) return i.info.margin end },
    conc   = { firstDescending = false, value = function(i) return i.info.concentrate and i.info.concentration or nil end },
    gpc    = { firstDescending = true,  value = function(i) return i.info.concentrate and i.info.concentrationValue or nil end },
    demand = { firstDescending = true,  value = function(i) return i.info.demand end },
    saleRate = { firstDescending = true, value = function(i) return i.info.saleRate end },
}
local DEFAULT_SORT = { key = "profit", descending = true }

local function GetSort()
    local sort = GoldsmithDB.ui2.craftSort
    if not sort or not SORTS[sort.key] then return DEFAULT_SORT end
    return sort
end

local function SortItems(items)
    local sort = GetSort()
    local getValue = SORTS[sort.key].value
    table.sort(items, function(a, b)
        local va, vb = getValue(a), getValue(b)
        if va ~= nil and vb ~= nil and va ~= vb then
            if sort.descending then return va > vb end
            return va < vb
        end
        if (va == nil) ~= (vb == nil) then return va ~= nil end
        if a.recipe.outputName ~= b.recipe.outputName then return a.recipe.outputName < b.recipe.outputName end
        if (a.tier or 0) ~= (b.tier or 0) then return (a.tier or 0) < (b.tier or 0) end
        -- Same tier: the way without concentration first
        return (not a.info.concentrate) and (b.info.concentrate == true)
    end)
end

-- Crafts list: rows and hover

local function FillCraftRow(row, item)
    local info, cells = item.info, row.cells
    cells.item:SetText(ItemText(item))
    if item.whyNot then cells.item:SetTextColor(addon:Color("muted")) end

    cells.cost:SetText(Money(info.cost) .. (info.partial and "+" or ""))
    if info.price then
        cells.price:SetText(Money(info.price))
        if info.priceAge and info.priceAge >= STALE_PRICE_DAYS then
            cells.price:SetTextColor(addon:Color("warning"))
        end
    else
        cells.price:SetText("-")
        cells.price:SetTextColor(addon:Color("dim"))
    end

    if info.profit then
        cells.profit:SetText(Signed(info.profit) .. (info.partial and "*" or ""))
        cells.profit:SetTextColor(addon:Color(addon:MoneyColor(info.profit)))
        cells.margin:SetText(info.margin and string.format("%.0f%%", info.margin) or "-")
        cells.margin:SetTextColor(addon:Color("muted"))
    else
        cells.profit:SetText("-")
        cells.profit:SetTextColor(addon:Color("dim"))
        cells.margin:SetText("-")
        cells.margin:SetTextColor(addon:Color("dim"))
    end

    if cells.conc and cells.conc:IsShown() then
        if info.concentrate then
            cells.conc:SetText(string.format("%d", info.concentration))
            cells.conc:SetTextColor(addon:Color("conc"))
            if info.concentrationValue then
                cells.gpc:SetText(Money(info.concentrationValue))
                local good = info.concentrationValue > 0 and info.profit and info.profit > 0
                cells.gpc:SetTextColor(addon:Color(good and "conc" or "loss"))
            else
                cells.gpc:SetText("-")
                cells.gpc:SetTextColor(addon:Color("dim"))
            end
        else
            cells.conc:SetText("-")
            cells.conc:SetTextColor(addon:Color("dim"))
            cells.gpc:SetText("-")
            cells.gpc:SetTextColor(addon:Color("dim"))
        end
    end

    cells.demand:SetText(addon:FormatDemand(info.demand))
    if item.whyNot then
        cells.demand:SetTextColor(addon:Color("warning"))
    elseif info.demandSource == "your sales" then
        -- Only your own sales, which undercount the market
        cells.demand:SetTextColor(addon:Color("muted"))
    end

    cells.saleRate:SetText(addon:FormatSaleRate(info.saleRate))
    cells.saleRate:SetTextColor(addon:Color(info.saleRate and "text" or "dim"))
end

local LABEL, VALUE = { 0.8, 0.8, 0.8 }, { 1, 1, 1 }

local function Line(tooltip, left, right, rightColor)
    local r = rightColor and { addon:Color(rightColor) } or VALUE
    tooltip:AddDoubleLine(left, right, LABEL[1], LABEL[2], LABEL[3], r[1], r[2], r[3])
end

local function Note(tooltip, text, colorName)
    local r, g, b = addon:Color(colorName or "muted")
    tooltip:AddLine(text, r, g, b, true)
end

local function StatsText(stats)
    if not stats then return "Base recipe numbers. Open the profession to use your stats." end
    local parts = {}
    if stats.multicraft > 0 then table.insert(parts, string.format("multicraft %.1f%%", stats.multicraft)) end
    if stats.resourcefulness > 0 then table.insert(parts, string.format("resourcefulness %.1f%%", stats.resourcefulness)) end
    if #parts == 0 then return "Your stats: no multicraft or resourcefulness yet." end
    return "From your stats: " .. table.concat(parts, ", ") .. "."
end

local function CraftTooltip(tooltip, item)
    local info, recipe = item.info, item.recipe
    tooltip:AddLine(ItemText(item), 1, 1, 1)
    if item.charKey ~= addon.charKey then
        Note(tooltip, "Crafted on " .. CharName(item.charKey) .. ", using their stats.")
    end
    if item.tier then
        Line(tooltip, "How", (info.description or "") .. (info.concentrate and " + concentration" or ""))
    end

    tooltip:AddLine(" ")
    Line(tooltip, "Cost (estimated)", Money(info.cost) .. (info.partial and "+" or ""), "gold")
    local stats = GoldsmithDB.characters[item.charKey] and GoldsmithDB.characters[item.charKey].recipeStats[recipe.recipeID]
    Note(tooltip, StatsText(stats))
    local worst = addon:WithCharacter(item.charKey, addon.GetWorstCaseCost, addon, recipe, info)
    if worst then Line(tooltip, "Worst case (no procs)", Money(worst)) end
    local yours = item.itemID and addon:GetCraftedCost(item.itemID)
    Line(tooltip, "Your latest crafts cost you", yours and Money(yours) or "not crafted yet")
    Line(tooltip, "Break-even AH price", Money(info.cost / (1 - AH_CUT)))
    if info.partial then
        Note(tooltip, "Some material costs are unknown, so the real cost is higher and the profit at most this.", "warning")
    end

    tooltip:AddLine(" ")
    if info.price then
        local stale = info.priceAge and info.priceAge >= STALE_PRICE_DAYS
        Line(tooltip, "AH price", Money(info.price) .. ", " .. (addon:PriceAgeText(item.itemID) or ""),
            stale and "warning" or nil)
        Line(tooltip, "Profit each", string.format("%s%s", Signed(info.profit),
            info.margin and string.format(" (%.0f%% ROI)", info.margin) or ""), addon:MoneyColor(info.profit))
    else
        Note(tooltip, "No AH price yet. Scan the AH with Auctionator.")
    end
    if info.demand then
        Line(tooltip, "Sold per day", string.format("%s (%s)", addon:FormatDemand(info.demand), info.demandSource or "?"))
    end
    if info.saleRate then
        Line(tooltip, "Sale rate", addon:FormatSaleRate(info.saleRate) .. " of listings sell")
    end
    local have = item.itemID and addon:GetStock(item.itemID) or 0
    if have > 0 then Line(tooltip, "You have", tostring(have)) end

    if info.concentrate then
        tooltip:AddLine(" ")
        Line(tooltip, "Concentration", string.format("about %d per craft", info.concentration), "conc")
        if info.concentrationValue then
            Line(tooltip, "Worth", Money(info.concentrationValue) .. " per point", "conc")
        end
    end

    if item.whyNot then
        tooltip:AddLine(" ")
        Note(tooltip, "Not recommended: " .. item.whyNot, "warning")
    end
    tooltip:AddLine(" ")
    Note(tooltip, "Click to plan: materials, quantity, shopping list", "profit")
    Note(tooltip, "Right-click for the item's page")
end

-- Planner

local METHOD_COLORS = { Buy = "text", Vendor = "gold", Craft = "profit", Mill = "profit" }
local METHOD_LABELS = {
    { key = "buy",    method = "Buy",    label = "Buy on the AH" },
    { key = "craft",  method = "Craft",  label = "Craft it" },
    { key = "mill",   method = "Mill",   label = "Mill it" },
    { key = "vendor", method = "Vendor", label = "Vendor" },
}

local PLAN_COLUMNS = {
    { key = "item", label = "Material" },
    { key = "need", label = "Need", width = 56, justify = "RIGHT" },
    { key = "have", label = "Have", width = 56, justify = "RIGHT" },
    { key = "source", label = "Best way", width = 76, justify = "RIGHT" },
    { key = "each", label = "Each", width = 84, justify = "RIGHT" },
    { key = "total", label = "Total", width = 90, justify = "RIGHT" },
}

-- Quantities can be fractional (e.g. herbs per pigment); round up, since
-- you can't buy part of an item
local function Whole(q)
    return math.ceil(q - 0.0001)
end

local function FillPlanRow(row, node)
    local cells = row.cells
    local indent = string.rep("    ", node.depth - 1) .. (node.depth > 1 and "> " or "")
    local quality = node.qualityTier and (" " .. addon:TierIconText(node.qualityTier, node.tierCount or 2)) or ""
    cells.item:SetText(indent .. node.name .. quality)
    cells.need:SetText(Whole(node.need))
    cells.have:SetText(node.have > 0 and Whole(node.have) or "-")
    if node.have <= 0 then cells.have:SetTextColor(addon:Color("dim")) end
    local best = node.best
    if best then
        -- * marks your own choice (right-click) rather than the cheapest
        cells.source:SetText(best.method .. (node.options.override and "*" or ""))
        cells.source:SetTextColor(addon:Color(METHOD_COLORS[best.method] or "text"))
        cells.each:SetText(Money(best.unit))
        cells.total:SetText(Money(best.unit * node.need))
    else
        cells.source:SetText("no price")
        cells.source:SetTextColor(addon:Color("loss"))
        cells.each:SetText("-")
        cells.total:SetText("-")
    end
    -- Sub-materials are detail; their cost is already in the parent
    if node.depth > 1 then
        cells.item:SetTextColor(addon:Color("muted"))
        cells.total:SetTextColor(addon:Color("dim"))
    end
end

-- Every way to get the material, the cheapest marked, and why
local function PlanTooltip(tooltip, node)
    local o = node.options
    tooltip:AddLine(node.name, 1, 1, 1)
    if node.qualityTier then
        Line(tooltip, "Quality", string.format("tier %d of %d %s", node.qualityTier, node.tierCount or 2,
            addon:TierIconText(node.qualityTier, node.tierCount or 2)))
    end
    Line(tooltip, "Need", tostring(Whole(node.need)))
    if node.have > 0 then
        Line(tooltip, "You have", tostring(Whole(node.have)))
        Line(tooltip, "To get", tostring(Whole(node.toGet)))
    end
    tooltip:AddLine(" ")
    tooltip:AddLine("Ways to get it (each)", 1, 0.82, 0)
    local function Option(option, label, detail)
        if not option then return end
        local tags = {}
        if o.cheapest == option then table.insert(tags, "cheapest") end
        if o.override and node.best == option then table.insert(tags, "your choice") end
        Line(tooltip, "  " .. label, Money(option.unit) .. (#tags > 0 and ("  (" .. table.concat(tags, ", ") .. ")") or ""),
            o.cheapest == option and "profit" or nil)
        if detail then Note(tooltip, "    " .. detail) end
    end
    Option(o.buy, "Buy on the AH", o.buy and ("AH price " .. (o.buy.ageText or "")))
    Option(o.vendor, "Vendor", o.vendor and o.vendor.detail)
    Option(o.craft, "Craft it", o.craft and "From its cheapest materials")
    Option(o.mill, "Mill it", o.mill and string.format("%.2f per %s; cost shared with its other pigments",
        o.mill.perHerb, o.mill.herbName))
    if not node.best then Note(tooltip, "  No price found. Scan the AH with Auctionator.", "loss") end

    if o.cheapest and o.buy and o.cheapest ~= o.buy and o.buy.unit > o.cheapest.unit then
        tooltip:AddLine(" ")
        Note(tooltip, string.format("%s it instead of buying saves %s here",
            o.cheapest.method == "Mill" and "Milling" or "Crafting", Money((o.buy.unit - o.cheapest.unit) * node.need)),
            "profit")
    end
    if o.override and o.cheapest and node.best ~= o.cheapest then
        Note(tooltip, string.format("Your choice (%s) costs %s more here", node.best.method,
            Money((node.best.unit - o.cheapest.unit) * node.need)), "warning")
    end
    Note(tooltip, "Right-click to choose how to get it, click for its item page")
end

-- Right-click a material: pick how to get it. The choice applies to that
-- item in every plan until changed back to "Cheapest way".
local function PlanMenu(node)
    local o = node.options
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle(node.name)
        local cheapestLabel = "Cheapest way"
        if o.cheapest then
            cheapestLabel = string.format("Cheapest way (%s, %s)", o.cheapest.method, Money(o.cheapest.unit))
        end
        root:CreateRadio(cheapestLabel, function() return o.override == nil end, function()
            addon:SetMethodOverride(node.itemID, nil)
            addon.Refresh()
        end)
        for _, m in ipairs(METHOD_LABELS) do
            local option = o[m.key]
            if option then
                root:CreateRadio(string.format("%s (%s each)", m.label, Money(option.unit)),
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

-- The tier row being planned, with current prices: the same way of making
-- it (scenario) if it's still there (the concentration planner can pick
-- one that isn't a Crafts row), else the same tier with or without
-- concentration as asked. When the tier can't be made that way, the other
-- way is used and a note says why: some tiers are only reachable with
-- concentration, and concentration adds nothing to a tier you already
-- reach without it. Returns the row and the note (or nil).
local function FindTierInfo(p)
    if not p.tier then return nil end
    local rows = addon:GetTierRows(p.recipe) or {}
    if p.scenario then
        for _, t in ipairs(rows) do
            if t.scenario == p.scenario then return t end
        end
        for _, e in ipairs(rows[1] and rows[1].scenarios or {}) do
            if e.scenario == p.scenario then return e end
        end
    end
    local plain, concentrated
    for _, t in ipairs(rows) do
        if t.tier == p.tier then
            if t.concentrate then concentrated = t else plain = t end
        end
    end
    if p.concentrate then
        if concentrated then return concentrated end
        return plain, plain and "you reach this tier without concentration"
    end
    if plain then return plain end
    return concentrated, concentrated and "this tier needs concentration"
end

-- Screen

-- Set by addon:OpenCrafts / addon:OpenCraftPlan before the tab is shown
local pending = nil
local view -- the created view

-- Opens Crafts showing only some crafts. focus = { keys = set of CraftKey,
-- label }. nil shows everything.
function addon:OpenCrafts(focus)
    pending = { focus = focus }
    addon:ShowTab("crafts")
end

-- Opens the planner for a craft. info is a Crafts row, tier row or
-- concentration plan row; charKey whose stats to use; quantity optional.
function addon:OpenCraftPlan(recipe, info, charKey, quantity)
    pending = {
        plan = {
            recipe = recipe, charKey = charKey or addon:GetCrafter(recipe.recipeID) or addon.charKey,
            tier = info and info.tier, concentrate = info and info.concentrate == true or false,
            scenario = info and info.scenario,
        },
        quantity = quantity,
    }
    addon:ShowTab("crafts")
end

local function CreatePlanScreen(parent)
    local ui = GoldsmithDB.ui2
    ui.planQty = ui.planQty or {}
    local screen = CreateFrame("Frame", nil, parent)
    screen:SetAllPoints()
    screen:Hide()

    screen.back = UI.Button(screen, "< Back", 76, 26, function() view:ClosePlan() end)
    screen.back:SetPoint("TOPLEFT", 0, 0)
    screen.title = UI.Text(screen, "heading")
    screen.title:SetPoint("LEFT", screen.back, "RIGHT", 14, 0)
    -- The title opens the item's page
    local titleButton = CreateFrame("Button", nil, screen)
    titleButton:SetAllPoints(screen.title)
    titleButton:SetScript("OnClick", function()
        if screen.plan then addon:OpenItem(screen.plan.recipe.outputName, screen.tierItemID) end
    end)
    UI.SetTooltip(titleButton, function(tooltip)
        tooltip:AddLine("Click for the item's page", 1, 1, 1)
    end)
    screen.subtitle = UI.Text(screen, "small", "muted")
    screen.subtitle:SetPoint("LEFT", screen.title, "RIGHT", 10, 0)

    local makeLabel = UI.Text(screen, "body", "muted")
    makeLabel:SetPoint("TOPLEFT", 2, -44)
    makeLabel:SetText("Make")
    screen.qty = UI.NumberBox(screen, 70, function(quantity)
        if screen.plan and quantity and quantity > 0 then ui.planQty[screen.plan.recipe.recipeID] = quantity end
        screen:Update()
    end)
    screen.qty:SetPoint("LEFT", makeLabel, "RIGHT", 10, 0)
    screen.crafts = UI.Text(screen, "small", "muted")
    screen.crafts:SetPoint("LEFT", screen.qty, "RIGHT", 10, 0)

    screen.useHave = UI.Checkbox(screen, "Use materials I have", function(checked)
        ui.planUseOnHand = checked
        screen:Update()
    end)
    screen.useHave:SetPoint("TOPRIGHT", 0, -44)

    -- For crafts with tiers: plan the tier with or without concentration
    screen.useConc = UI.Checkbox(screen, "Use concentration", function(checked)
        local p = screen.plan
        if not p then return end
        p.concentrate = checked
        p.scenario = nil -- the chosen mix belongs to the other way
        screen:Update()
    end)
    screen.useConc:SetPoint("RIGHT", screen.useHave, "LEFT", -20, 0)
    UI.SetTooltip(screen.useConc, function(tooltip)
        tooltip:AddLine("Use concentration", 1, 1, 1)
        tooltip:AddLine("Plan this tier with concentration, using the mix of material qualities that earns the most. Some tiers can only be reached with it.", 0.6, 0.6, 0.6, true)
    end)

    screen.list = UI.List(screen, {
        fill = FillPlanRow,
        tooltip = PlanTooltip,
        onClick = function(node, button)
            if button == "RightButton" then PlanMenu(node) else addon:OpenItem(node.name, node.itemID) end
        end,
        empty = "Enter how many to make.",
    })
    screen.list:SetPoint("TOPLEFT", 0, -80)
    screen.list:SetPoint("BOTTOMRIGHT", 0, PLAN_SUMMARY_HEIGHT + 12)
    screen.list:SetColumns(PLAN_COLUMNS)

    -- Summary: cost, sells for, profit; then sales, shopping and the button
    local summary = UI.Panel(screen)
    summary:SetPoint("BOTTOMLEFT")
    summary:SetPoint("BOTTOMRIGHT")
    summary:SetHeight(PLAN_SUMMARY_HEIGHT)
    local third = 860 / 3
    local function Figure(i)
        local f = {}
        f.label = UI.Text(summary, "label", "muted")
        f.label:SetPoint("TOPLEFT", 16 + (i - 1) * third, -14)
        f.value = UI.Text(summary, "value")
        f.value:SetPoint("TOPLEFT", f.label, "BOTTOMLEFT", 0, -5)
        f.note = UI.Text(summary, "small", "muted")
        f.note:SetPoint("TOPLEFT", f.value, "BOTTOMLEFT", 0, -4)
        f.note:SetWidth(third - 24)
        return f
    end
    screen.cost, screen.sells, screen.profit = Figure(1), Figure(2), Figure(3)
    screen.cost.label:SetText("COST")
    screen.sells.label:SetText("SELLS FOR")
    screen.profit.label:SetText("PROFIT")

    local function SummaryLine(y)
        local fs = UI.Text(summary, "small", "muted")
        fs:SetPoint("BOTTOMLEFT", 16, y)
        fs:SetPoint("RIGHT", summary, "RIGHT", -200, 0)
        return fs
    end
    screen.demandLine = SummaryLine(46)
    screen.spendLine = SummaryLine(28)
    screen.vendorLine = SummaryLine(10)

    screen.shop = UI.Button(summary, "Send to Auctionator", 170, 28, function()
        if not screen.current then return end
        local ok, result = addon:SendShoppingList(screen.current)
        if ok then
            print("|cFF00FF00[Goldsmith]|r Shopping list \"" .. result .. "\" sent to Auctionator's Shopping tab.")
        else
            print("|cFF00FF00[Goldsmith]|r Couldn't create the shopping list: " .. result)
        end
    end)
    screen.shop:SetPoint("BOTTOMRIGHT", -14, 12)

    local function ClearSummary(message)
        for _, f in ipairs({ screen.cost, screen.sells, screen.profit }) do
            f.value:SetText("-")
            f.value:SetTextColor(addon:Color("dim"))
            f.note:SetText("")
        end
        screen.demandLine:SetText(message or "")
        screen.spendLine:SetText("")
        screen.vendorLine:SetText("")
        screen.shop:Disable()
        screen.shop:SetAlpha(0.5)
    end

    function screen:Open(p, quantity)
        screen.plan = p
        local saved = quantity or ui.planQty[p.recipe.recipeID]
        screen.qty:SetText(tostring(saved or math.max(math.floor(p.recipe.outputQty), 1)))
        if quantity then ui.planQty[p.recipe.recipeID] = quantity end
        screen.list:ScrollToTop()
    end

    function screen:Update()
        local p = screen.plan
        if not p then return end
        local recipe = p.recipe
        screen.useHave:SetChecked(ui.planUseOnHand ~= false)

        local tierInfo, tierNote = addon:WithCharacter(p.charKey, FindTierInfo, p)
        screen.tierItemID = tierInfo and tierInfo.itemID or recipe.outputItemID
        local tierIcon = tierInfo and (" " .. addon:TierIconText(tierInfo.tier, tierInfo.tierCount)) or ""
        screen.title:SetText(addon:ProfessionIconText(recipe.profession) .. recipe.outputName .. tierIcon)
        -- The checkbox shows the way actually planned (a tier may need
        -- concentration, or not benefit from it)
        local concentrating = tierInfo and tierInfo.concentrate == true
        screen.useConc:SetShown(p.tier ~= nil)
        screen.useConc:SetChecked(concentrating)
        local sub = {}
        if concentrating then table.insert(sub, "with concentration, best mix of material qualities") end
        if tierNote then table.insert(sub, tierNote) end
        if p.charKey ~= addon.charKey then table.insert(sub, "on " .. CharName(p.charKey)) end
        if p.tier and not tierInfo then table.insert(sub, "this tier isn't reachable right now") end
        screen.subtitle:SetText(table.concat(sub, ", "))

        local quantity = tonumber(screen.qty:GetText()) or 0
        if quantity <= 0 then
            screen.current = nil
            screen.list:SetItems({})
            screen.crafts:SetText("")
            ClearSummary("Enter how many to make.")
            return
        end

        local plan = addon:WithCharacter(p.charKey, addon.BuildPlan, addon, recipe, quantity,
            ui.planUseOnHand ~= false, tierInfo)
        screen.current = plan
        screen.list:SetItems(addon:FlattenPlan(plan))
        screen.crafts:SetFormattedText("%d craft%s, about %.1f made", plan.crafts,
            plan.crafts == 1 and "" or "s", plan.expectedOutput)

        local made = math.max(plan.expectedOutput, 0.0001)
        screen.cost.value:SetText(Money(plan.cost) .. (plan.complete and "" or "+"))
        screen.cost.value:SetTextColor(addon:Color("text"))
        local costNote = Money(plan.cost / made) .. " each"
        if tierInfo and tierInfo.concentrate then
            costNote = costNote .. string.format(", about %d concentration", tierInfo.concentration * plan.crafts)
        end
        if not plan.complete then
            costNote = costNote .. ". Some materials have no price."
        elseif plan.choiceExtra and plan.choiceExtra > 0.5 then
            costNote = costNote .. ". Your choices add " .. Money(plan.choiceExtra) .. "."
        end
        screen.cost.note:SetText(costNote)
        screen.cost.note:SetTextColor(addon:Color(plan.complete and "muted" or "warning"))

        if plan.price then
            screen.sells.value:SetText(Money(plan.revenue))
            screen.sells.value:SetTextColor(addon:Color("text"))
            screen.sells.note:SetText(string.format("%s each after the AH cut, AH price %s",
                Money(plan.price * (1 - AH_CUT)),
                addon:PriceAgeText((tierInfo and tierInfo.itemID) or recipe.outputItemID) or ""))
            screen.profit.value:SetText(Signed(plan.profit))
            screen.profit.value:SetTextColor(addon:Color(addon:MoneyColor(plan.profit)))
            screen.profit.note:SetText(plan.margin and string.format("%.0f%% ROI", plan.margin) or "")
        else
            screen.sells.value:SetText("-")
            screen.sells.value:SetTextColor(addon:Color("dim"))
            screen.sells.note:SetText("No AH price yet. Scan with Auctionator.")
            screen.profit.value:SetText("-")
            screen.profit.value:SetTextColor(addon:Color("dim"))
            screen.profit.note:SetText("")
        end

        if plan.demand and plan.demand > 0 then
            local days = quantity / plan.demand
            local rate = plan.saleRate and (", " .. addon:FormatSaleRate(plan.saleRate) .. " of listings sell") or ""
            local text = string.format("Sells about %s a day (%s%s). Making %d is ",
                addon:FormatDemand(plan.demand), plan.demandSource or "?", rate, quantity)
            if days >= 1 then
                text = text .. string.format("about %.1f days of sales, so it may be slow to sell.", days)
            elseif days < 0.01 then
                text = text .. "under 1% of a day's sales."
            else
                text = text .. string.format("%.0f%% of a day's sales.", days * 100)
            end
            screen.demandLine:SetText(text)
            screen.demandLine:SetTextColor(addon:Color(days >= 1 and "warning" or "muted"))
        else
            screen.demandLine:SetText("Sold per day: no data")
            screen.demandLine:SetTextColor(addon:Color("dim"))
        end

        local spend, live, short = 0, 0, false
        for _, entry in ipairs(plan.buyAH) do
            spend = spend + entry.cost
            if entry.live then live = live + 1 end
            if entry.short then short = true end
        end
        local spendText = string.format("To buy on the AH: %d item%s, about %s",
            #plan.buyAH, #plan.buyAH == 1 and "" or "s", Money(spend))
        if live > 0 then spendText = spendText .. string.format(" (%d priced from live listings)", live) end
        if short then spendText = spendText .. ". Not enough listed for all of it." end
        screen.spendLine:SetText(spendText)
        screen.spendLine:SetTextColor(addon:Color(short and "warning" or "muted"))

        if #plan.buyVendor > 0 then
            local parts = {}
            for _, entry in ipairs(plan.buyVendor) do table.insert(parts, entry.quantity .. " " .. entry.name) end
            screen.vendorLine:SetText("From a vendor: " .. table.concat(parts, ", "))
        else
            screen.vendorLine:SetText("")
        end

        screen.shop:SetEnabled(#plan.buyAH > 0)
        screen.shop:SetAlpha(#plan.buyAH > 0 and 1 or 0.5)
    end

    return screen
end

-- Concentration budget bar (Concentration switch on): concentration across
-- your characters and the best way to spend it, as on the Overview

local function BestConcentration(conc)
    local best
    for _, row in ipairs(conc.rows) do
        if row.gain > 0 and row.plan and row.plan[1] and (not best or row.gain > best.gain) then best = row end
    end
    return best
end

local function CreateBudget(parent)
    local bar = CreateFrame("Button", nil, parent, "BackdropTemplate")
    UI.Style(bar, "highlight", "borderGold")
    bar:SetHeight(FOOTER_HEIGHT - 8)
    bar.amount = UI.Text(bar, "body", "conc")
    bar.amount:SetPoint("LEFT", 14, 0)
    bar.track = bar:CreateTexture(nil, "ARTWORK")
    bar.track:SetColorTexture(addon:Color("borderGold"))
    bar.track:SetHeight(8)
    bar.track:SetPoint("LEFT", 110, 0)
    bar.track:SetWidth(260)
    bar.fill = bar:CreateTexture(nil, "OVERLAY")
    bar.fill:SetColorTexture(addon:Color("conc"))
    bar.fill:SetHeight(8)
    bar.fill:SetPoint("LEFT", bar.track, "LEFT")
    bar.best = UI.Text(bar, "small", "text", "RIGHT")
    bar.best:SetPoint("LEFT", bar.track, "RIGHT", 14, 0)
    bar.best:SetPoint("RIGHT", -14, 0)

    function bar:Set(conc)
        bar.conc = conc
        if #conc.rows == 0 then
            bar.amount:SetText("-")
            bar.fill:Hide()
            bar.best:SetText("Open each profession once to load its concentration.")
            bar.best:SetTextColor(addon:Color("muted"))
            bar.target = nil
            return
        end
        bar.amount:SetFormattedText("%d / %d", conc.current, conc.max)
        local share = conc.max > 0 and conc.current / conc.max or 0
        bar.fill:SetShown(share > 0)
        bar.fill:SetWidth(math.max(260 * share, 1))
        local best = BestConcentration(conc)
        bar.target = best
        if best then
            local first = best.plan[1]
            local tier = first.row.tier and (" " .. addon:TierIconText(first.row.tier, first.tierCount)) or ""
            local who = best.key ~= addon.charKey and (" on " .. best.name) or ""
            bar.best:SetText(string.format("Best use: %dx %s%s%s  %s", first.crafts, first.recipe.outputName, tier, who,
                addon:Colorize(Signed(first.gain) .. " extra", "profit")))
            bar.best:SetTextColor(addon:Color("text"))
        else
            bar.best:SetText("Nothing worth concentration right now.")
            bar.best:SetTextColor(addon:Color("muted"))
        end
    end

    bar:SetScript("OnClick", function()
        local best = bar.target
        if not best then return end
        local first = best.plan[1]
        addon:OpenCraftPlan(first.recipe, first.row, best.key,
            math.max(math.floor(first.crafts * (first.row.outputPerCraft or 1)), 1))
    end)
    UI.SetTooltip(bar, function(tooltip)
        local conc = bar.conc
        if not conc then return end
        tooltip:AddLine("Concentration on all characters", 1, 1, 1)
        for _, row in ipairs(conc.rows) do
            Line(tooltip, string.format("%s - %s%s", row.name, addon:ProfessionIconText(row.profession), row.profession),
                string.format("%d / %d", row.current, row.max), "conc")
            for _, p in ipairs(row.plan or {}) do
                local tier = p.row.tier and (" " .. addon:TierIconText(p.row.tier, p.tierCount)) or ""
                Line(tooltip, string.format("    %dx %s%s", p.crafts, p.recipe.outputName, tier),
                    string.format("%d conc, %s", p.points, Signed(p.gain)), "profit")
                if p.row.description then Note(tooltip, "        " .. p.row.description) end
            end
        end
        Note(tooltip, "Mixes of lower and higher quality materials are compared for each craft, to get the most gold from your concentration.", "gold")
        Note(tooltip, "Extra = profit on top of crafting the same thing without concentration. Each craft is capped at about a day of that item's sales.")
        if bar.target then Note(tooltip, "Click to plan the best use.", "profit") end
    end, "ANCHOR_TOP")
    return bar
end

local function Create(parent)
    local ui = GoldsmithDB.ui2
    view = { focus = nil }

    local list = CreateFrame("Frame", nil, parent)
    list:SetAllPoints()
    view.listScreen = list

    view.expansion = UI.Dropdown(list, 160, function(root)
        root:CreateTitle("Show items from")
        for _, expansionID in ipairs(GetRecipeExpansions()) do
            root:CreateCheckbox(addon:GetExpansionName(expansionID),
                function() return IsExpansionShown(expansionID) end,
                function()
                    SetExpansionShown(expansionID, not IsExpansionShown(expansionID))
                    addon.RefreshWindow()
                end)
        end
        root:CreateDivider()
        root:CreateButton("Current expansion only", function()
            ui.expansions = nil
            addon.RefreshWindow()
        end)
        root:CreateButton("All expansions", function()
            ui.expansions = {}
            for _, expansionID in ipairs(GetRecipeExpansions()) do ui.expansions[expansionID] = true end
            addon.RefreshWindow()
        end)
    end)
    view.expansion:SetPoint("TOPLEFT", 0, 0)

    view.profitable = UI.Checkbox(list, "Profitable only", function(checked)
        ui.profitableOnly = checked or nil
        addon.RefreshWindow()
    end)
    view.profitable:SetPoint("LEFT", view.expansion, "RIGHT", 16, 0)

    -- "Showing: Best crafts right now (5)  x" after following a link from
    -- the Overview; click to show everything again
    view.focusChip = UI.Button(list, "", 260, 24, function()
        view.focus = nil
        addon.RefreshWindow()
    end)
    UI.Style(view.focusChip, "highlight", "borderGold")
    view.focusChip:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    view.focusChip.label:SetTextColor(addon:Color("gold"))
    view.focusChip:SetPoint("LEFT", view.profitable, "RIGHT", 16, 0)

    view.concSwitch = UI.Switch(list, "Concentration", function(on)
        ui.craftsConcentration = on or nil
        addon.RefreshWindow()
    end)
    view.concSwitch:SetPoint("TOPRIGHT", 0, 0)

    -- Hover explanations for the two options (hooked, so the widgets keep
    -- their own hover colors)
    local function Explain(frame, fill)
        frame:HookScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_BOTTOM")
            fill(GameTooltip)
            GameTooltip:Show()
        end)
        frame:HookScript("OnLeave", GameTooltip_Hide)
    end
    Explain(view.concSwitch, function(tooltip)
        tooltip:AddLine("Concentration", 1, 1, 1)
        Note(tooltip, "Adds the ways to craft with concentration: how much each uses (Conc) and the extra gold it earns per point (g/conc).")
        Note(tooltip, "The bar at the bottom shows your concentration on all characters and the best way to spend it.")
        Note(tooltip, "Goldsmith tries mixes of lower and higher quality materials. Better materials cost more but need less concentration, so the same concentration can make more crafts. It picks the mix that earns the most.", "gold")
    end)
    Explain(view.profitable, function(tooltip)
        tooltip:AddLine("Profitable only", 1, 1, 1)
        Note(tooltip, "Hides crafts that lose gold at current AH prices, and ones with no AH price yet.")
    end)
    view.count = UI.Text(list, "label", "dim", "RIGHT")
    view.count:SetPoint("RIGHT", view.concSwitch, "LEFT", -12, 0)

    view.list = UI.List(list, {
        fill = FillCraftRow,
        tooltip = CraftTooltip,
        onClick = function(item, button)
            if button == "LeftButton" then
                addon:OpenCraftPlan(item.recipe, item.info, item.charKey)
            else
                addon:OpenItem(item.recipe.outputName, item.itemID)
            end
        end,
        onSort = function(key)
            local current = GetSort()
            if current.key == key then
                ui.craftSort = { key = key, descending = not current.descending }
            else
                ui.craftSort = { key = key, descending = SORTS[key].firstDescending }
            end
            addon.RefreshWindow()
        end,
    })
    view.list:SetPoint("TOPLEFT", 0, -(TOP_HEIGHT + 12))
    view.list:SetPoint("BOTTOMRIGHT", 0, FOOTER_HEIGHT)

    view.footnote = UI.Text(list, "small", "dim")
    view.footnote:SetPoint("BOTTOMLEFT", 2, 14)
    view.budget = CreateBudget(list)
    view.budget:SetPoint("BOTTOMLEFT", 0, 0)
    view.budget:SetPoint("BOTTOMRIGHT", 0, 0)

    view.plan = CreatePlanScreen(parent)

    function view:ClosePlan()
        view.plan.plan = nil
        view.plan.current = nil
        view.plan.qty:ClearFocus()
        addon.RefreshWindow()
    end
    return view
end

local function Refresh(v, state)
    local ui = GoldsmithDB.ui2
    if pending then
        if pending.plan then
            v.plan:Open(pending.plan, pending.quantity)
        else
            v.plan.plan = nil
            v.focus = pending.focus
            v.list:ScrollToTop()
        end
        pending = nil
    end

    local planning = v.plan.plan ~= nil
    v.plan:SetShown(planning)
    v.listScreen:SetShown(not planning)
    if planning then
        v.plan:Update()
        return
    end

    local concOn = ui.craftsConcentration == true
    v.concSwitch:SetOn(concOn)
    v.profitable:SetChecked(ui.profitableOnly == true)
    v.expansion:SetLabel(ExpansionLabel())

    -- Following a link from the Overview shows just those crafts, whatever
    -- the filters say
    local focus = v.focus
    local items = addon:GetCraftRows(state.profession, {
        concentration = concOn,
        profitableOnly = not focus and ui.profitableOnly,
        showExpansion = not focus and IsExpansionShown or nil,
    })
    if focus then
        local kept = {}
        for _, item in ipairs(items) do
            if focus.keys[item.key] then table.insert(kept, item) end
        end
        items = kept
        v.focusChip:SetLabel(string.format("Showing: %s (%d)   x", focus.label, #items))
        v.focusChip:Show()
    else
        v.focusChip:Hide()
    end
    SortItems(items)

    local sort = GetSort()
    v.list:SetSort(sort.key, sort.descending)
    v.list:SetColumns(concOn and CONC_COLUMNS or SIMPLE_COLUMNS)
    if next(GoldsmithDB.recipes) == nil then
        v.list:SetEmptyText("No recipes yet. Open your professions so Goldsmith can load them.")
    elseif focus then
        v.list:SetEmptyText("Those crafts aren't worth it any more. Click the button above to see everything.")
    else
        v.list:SetEmptyText("No crafts match. Try All expansions, turn off Profitable only, or pick All professions at the top.")
    end
    v.list:SetItems(items)
    v.count:SetText(string.format("%d craft%s", #items, #items == 1 and "" or "s"))

    v.budget:SetShown(concOn)
    v.footnote:SetShown(not concOn)
    if concOn then
        v.budget:Set(addon:GetConcentrationOverview(state.profession))
    else
        local partial = false
        for _, item in ipairs(items) do
            if item.info.partial then partial = true break end
        end
        v.footnote:SetText("Hover a craft for how its cost is worked out, click it to plan."
            .. (partial and "   + some material costs unknown,  * profit is at most this" or ""))
    end
end

addon:RegisterView("crafts", { create = Create, refresh = Refresh })

_G.Goldsmith = addon
