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
-- shown dimmed with the reason in the hover, so the two tabs agree. Shows
-- Recommended by default. Crafts say their expansion after the name when
-- the list can mix expansions (a search, or several picked in the header);
-- with an older expansion picked its crafts are judged on sales.
-- The numbers come from GetCraftRows (Insights.lua), GetTierRows
-- (Quality.lua) and BuildPlan (Planner.lua).

local AH_CUT = 0.05
local STALE_PRICE_DAYS = 3
local TOP_HEIGHT = 26
local FOOTER_HEIGHT = 44
local PLAN_SUMMARY_HEIGHT = 158
-- The planner's "Why this mix" panel: mixes shown, and its height
local MIX_SHOWN = 3
local MIX_HEIGHT = 158
local MIX_BAR_HEIGHT = 34
-- The planner's sales line turns orange past this many days of sales
local PLAN_DAYS_WARN = 3
-- Search box: seconds to wait after typing, letters before searching
local SEARCH_DELAY = 0.3
local SEARCH_MIN_LETTERS = 2

local Money, Signed = function(c) return addon:FormatMoney(c) end, function(c) return addon:FormatSignedMoney(c) end

local SIMPLE_COLUMNS = {
    { key = "item", label = "Item" },
    { key = "cost", label = "Cost", width = 78, justify = "RIGHT" },
    { key = "price", label = "AH price", width = 80, justify = "RIGHT" },
    { key = "profit", label = "Profit", width = 84, justify = "RIGHT" },
    { key = "margin", label = "ROI", width = 56, justify = "RIGHT" },
    { key = "demand", label = "Sold/day", width = 70, justify = "RIGHT" },
    { key = "saleRate", label = "Sale rate", width = 64, justify = "RIGHT", tsm = true },
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
    { key = "saleRate", label = "Sale rate", width = 64, justify = "RIGHT", tsm = true },
}

-- The tier goes before the name, so a long name cut short never hides it
local function ItemText(item)
    local tier = item.tier and (addon:TierIconText(item.tier, item.info.tierCount) .. " ") or ""
    return addon:ProfessionIconText(item.recipe.profession) .. tier .. item.recipe.outputName
end

-- A material's name with its quality icon. fallbackName is used while the
-- game hasn't loaded the item (asked to load it for next time).
local function MaterialName(itemID, fallbackName)
    local tier, tierCount = addon:GetItemTier(itemID)
    local name = C_Item.GetItemNameByID(itemID)
    if not name and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
    return (tier and (addon:TierIconText(tier, tierCount) .. " ") or "")
        .. (name or fallbackName or ("item " .. itemID))
end

local function CharName(charKey)
    local c = GoldsmithDB.characters[charKey]
    return c and c.name or charKey
end

-- Sorting. Clicking a header sorts by it; clicking again reverses. Each
-- column starts the most useful way round (names A-Z, cheapest first,
-- highest profit first). Rows with no value for the column go last.

-- Gold per concentration point as shown and sorted: the extra gold
-- concentration adds, or, for a craft that loses gold, the loss spread over
-- its concentration (negative), so a losing craft never looks like a good
-- use of it and sorts to the bottom.
local function GoldPerConc(info)
    if not info.concentrate or not info.concentrationValue then return nil end
    if info.profit and info.profit < 0 then
        return info.profit / math.max(info.concentration or 1, 1)
    end
    return info.concentrationValue
end

local SORTS = {
    item   = { firstDescending = false, value = function(i) return i.recipe.outputName .. (i.tier or "") end },
    cost   = { firstDescending = false, value = function(i) return i.info.cost end },
    price  = { firstDescending = true,  value = function(i) return i.info.price end },
    profit = { firstDescending = true,  value = function(i) return i.info.profit end },
    margin = { firstDescending = true,  value = function(i) return i.info.margin end },
    conc   = { firstDescending = false, value = function(i) return i.info.concentrate and i.info.concentration or nil end },
    gpc    = { firstDescending = true,  value = function(i) return GoldPerConc(i.info) end },
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
    -- Can wait for a frame on long lists (Settings.lua)
    addon:Sort(items, function(a, b)
        local va, vb = getValue(a), getValue(b)
        if va ~= nil and vb ~= nil and va ~= vb then
            if sort.descending then return va > vb end
            return va < vb
        end
        if (va == nil) ~= (vb == nil) then return va ~= nil end
        if a.recipe.outputName ~= b.recipe.outputName then return a.recipe.outputName < b.recipe.outputName end
        if (a.tier or 0) ~= (b.tier or 0) then return (a.tier or 0) < (b.tier or 0) end
        -- Same tier: the way without concentration first, then you, then
        -- other characters by name
        if (a.info.concentrate and true or false) ~= (b.info.concentrate and true or false) then
            return not a.info.concentrate
        end
        if (a.charKey == addon.charKey) ~= (b.charKey == addon.charKey) then return a.charKey == addon.charKey end
        return (a.charKey or "") < (b.charKey or "")
    end)
end

-- Crafts list: rows and hover

-- Rows are tall enough for the crafter's name under the item's
local ROW_HEIGHT = 32
local WHO_INDENT = 18

local function FillCraftRow(row, item)
    local info, cells = item.info, row.cells
    -- Which expansion it's from (by the recipe's expansion; salvage by
    -- what's salvaged), when the list can hold more than one: a search, or
    -- several expansions picked at the top
    local expansionID = item.labelExpansion and (item.salvage and addon:GetItemExpansion(item.itemID)
        or addon:GetRecipeExpansion(item.recipe))
    local label = expansionID
        and addon:Colorize("  " .. addon:GetExpansionName(expansionID), "expansion") or ""
    cells.item:SetText(ItemText(item) .. label .. (item.ignored and addon:Colorize("  ignored", "dim") or ""))
    if item.ignored then
        cells.item:SetTextColor(addon:Color("dim"))
    elseif item.whyNot then
        cells.item:SetTextColor(addon:Color("muted"))
    end

    -- Who makes it, when it isn't you: a second line, indented under the
    -- name. The list places the name in the middle of the row each time, so
    -- it's moved up here when there's a second line.
    if not row.who then
        row.who = UI.Text(row, "label", "dim")
        row.who:SetWordWrap(false)
    end
    if item.charKey ~= addon.charKey then
        local _, _, _, x = cells.item:GetPoint(1)
        cells.item:SetPoint("LEFT", row, "LEFT", x, 7)
        row.who:ClearAllPoints()
        row.who:SetPoint("TOPLEFT", cells.item, "BOTTOMLEFT", WHO_INDENT, -2)
        row.who:SetWidth(cells.item:GetWidth() - WHO_INDENT)
        row.who:SetText((item.unlearned and "to learn on " or info.concentrate and "concentration on " or "on ")
            .. CharName(item.charKey))
        row.who:Show()
    else
        row.who:Hide()
    end

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
            local perPoint = GoldPerConc(info)
            if perPoint then
                cells.gpc:SetText(perPoint < 0 and Signed(perPoint) or Money(perPoint))
                cells.gpc:SetTextColor(addon:Color(perPoint > 0 and "conc" or "loss"))
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

    -- Without TSM: Goldsmith Data's sell level (Sells, Slow, Hardly sells)
    -- instead of a number
    local level = not addon:HasTSM() and addon:GetSellLevel(item.itemID)
    if level then
        cells.demand:SetText(addon:SellLevelText(level))
        cells.demand:SetTextColor(addon:Color(addon:SellLevelColor(level)))
    else
        cells.demand:SetText(addon:FormatDemand(info.demand))
        local demandColor = addon:DemandColor(info.demand, item.itemID)
        if demandColor == "text" and info.demandSource == "your sales" then
            -- Only your own sales, which undercount the market
            demandColor = "muted"
        end
        cells.demand:SetTextColor(addon:Color(demandColor))
    end

    -- Not there without TSM (see AvailableColumns)
    if cells.saleRate then
        cells.saleRate:SetText(addon:FormatSaleRate(info.saleRate))
        cells.saleRate:SetTextColor(addon:Color(addon:SaleRateColor(info.saleRate)))
    end
end

local LABEL, VALUE = { 0.8, 0.8, 0.8 }, { 1, 1, 1 }

local function Line(tooltip, left, right, rightColor)
    local r = rightColor and { addon:Color(rightColor) } or VALUE
    tooltip:AddDoubleLine(left, right, LABEL[1], LABEL[2], LABEL[3], r[1], r[2], r[3])
end

-- An explanation: shown only when hover explanations are on, or Ctrl is
-- held (addon:Explain, Widgets.lua). Numbers and warnings use Note.
local function Why(tooltip, text, colorName)
    local r, g, b = addon:Color(colorName or "muted")
    addon:Explain(tooltip, text, r, g, b)
end

local function Note(tooltip, text, colorName)
    local r, g, b = addon:Color(colorName or "muted")
    tooltip:AddLine(text, r, g, b, true)
end

local function StatsText(stats)
    -- Recipes from before Dragonflight have no crafting stats at all
    if not stats then return "Base recipe numbers: older recipes have no multicraft or resourcefulness. For newer ones, open the profession." end
    local parts = {}
    if stats.multicraft > 0 then table.insert(parts, string.format("multicraft %.1f%%", stats.multicraft)) end
    if stats.resourcefulness > 0 then table.insert(parts, string.format("resourcefulness %.1f%%", stats.resourcefulness)) end
    if #parts == 0 then return "Your stats: no multicraft or resourcefulness yet." end
    return "From your stats: " .. table.concat(parts, ", ") .. "."
end

-- Hover for a salvage row (see GetSalvageRows in Milling.lua)
local function SalvageTooltip(tooltip, item)
    local s, info = item.salvage, item.info
    tooltip:AddLine(ItemText(item), 1, 1, 1)
    if item.charKey ~= addon.charKey then
        Note(tooltip, "Salvaged on " .. CharName(item.charKey) .. ", with their yields and resourcefulness.")
    end
    Line(tooltip, "Uses", s.resourcefulness > 0
        and string.format("about %.1f %s (%d, less %.1f%% resourcefulness)", s.inputPerCast, s.inputName,
            s.perCast, s.resourcefulness)
        or string.format("%d %s", s.perCast, s.inputName))
    Line(tooltip, "Cost", info.cost and string.format("%s (%s each, %s)", Money(info.cost), Money(s.unitPrice),
        addon:PriceAgeText(s.inputID)) or "no AH price", (not info.cost) and "warning" or nil)

    tooltip:AddLine(" ")
    tooltip:AddLine("What comes out of one, on average", 1, 0.82, 0)
    for _, o in ipairs(s.outputs) do
        tooltip:AddDoubleLine("    " .. MaterialName(o.itemID, o.name),
            o.value and string.format("%.2f x %s = %s", o.perCast, Money(o.unit), Money(o.value))
                or string.format("%.2f, no price", o.perCast),
            0.9, 0.9, 0.9, addon:Color(o.value and "text" or "dim"))
    end
    tooltip:AddLine(" ")
    if info.price then
        Line(tooltip, "Worth", string.format("%s, %s after the AH cut", Money(info.price), Money(info.price * 0.95)))
    end
    if info.profit then
        Line(tooltip, "Profit each", string.format("%s%s%s", Signed(info.profit),
            info.margin and string.format(" (%.0f%% ROI)", info.margin) or "", info.partial and ", at least" or ""),
            addon:MoneyColor(info.profit))
        Line(tooltip, "Per 1,000 " .. s.inputName, Signed(info.profit / s.inputPerCast * 1000),
            addon:MoneyColor(info.profit))
    end

    tooltip:AddLine(" ")
    if s.estimated then
        Note(tooltip, string.format("Estimated: your average pigment per herb from %s (%d herbs milled).",
            s.estimatedFrom, s.sample))
    else
        Note(tooltip, string.format("Your yields from %d %s salvaged%s.", s.sample, s.inputName,
            s.sampleFrom and (" on " .. CharName(s.sampleFrom)) or ", all characters"))
    end
    if s.resourcefulness > 0 then
        Why(tooltip, s.procMeasured
            and string.format("A resourcefulness proc saves about %.0f%% of the input (measured from your salvage).", s.procSave * 100)
            or string.format("A resourcefulness proc is assumed to save %.0f%% of the input until there's enough of your salvage to measure it.", s.procSave * 100))
    end
    if item.whyNot then
        Note(tooltip, "Not recommended: " .. item.whyNot, "warning")
    end
    addon:ClickHint(tooltip, string.format("Click to plan it (buy or %s?)",
        (item.recipe.outputName:match("^(%S+)") or "Salvage"):lower()))
    addon:RightClickHint(tooltip, "Right-click to queue a batch")
    addon:ShiftClickHint(tooltip, string.format("Shift-click for %s's page", s.inputName))
end

local function CraftTooltip(tooltip, item)
    if item.salvage then return SalvageTooltip(tooltip, item) end
    local info, recipe = item.info, item.recipe
    tooltip:AddLine(ItemText(item), 1, 1, 1)
    addon:AddItemDescription(tooltip, item.itemID or recipe.outputItemID)
    if item.unlearned then
        -- Not learned yet: what it'd make if learned today, and where
        Note(tooltip, string.format("Not learned yet. Costed with %s skill and stats as they are now, as if learned today.",
            item.charKey == addon.charKey and "your" or (CharName(item.charKey) .. "'s")), "warning")
        if recipe.source then
            tooltip:AddLine(" ")
            tooltip:AddLine(recipe.source, 1, 1, 1, true)
        end
    elseif item.charKey ~= addon.charKey and info.concentrate then
        Note(tooltip, "With " .. CharName(item.charKey) .. "'s concentration and stats.")
    elseif item.charKey ~= addon.charKey then
        -- Made by whoever makes it best; say by how much when you know it too
        local better = addon:BetterCrafterText(recipe.recipeID)
        Note(tooltip, "Crafted on " .. CharName(item.charKey) .. ", using their stats"
            .. (better and (": " .. better .. ".") or "."))
    end
    if item.tier then
        -- Short: the full mix is long, and the planner shows it with the
        -- alternatives ("Why this mix")
        local how = info.description
        -- "all silver" / "all gold" are short enough; a mix isn't
        if how and not how:find("^all ") then how = "a mix of material qualities" end
        Line(tooltip, "How", (how or "") .. (info.concentrate and " + concentration" or ""))
        Why(tooltip, info.concentrate
            and "The mix of material qualities earning the most per concentration point. Open the plan to see it and the others compared."
            or "The mix of material qualities that reaches this tier for the least gold. Open the plan to see it and the others compared.")
    end

    tooltip:AddLine(" ")
    local stats = GoldsmithDB.characters[item.charKey] and GoldsmithDB.characters[item.charKey].recipeStats[recipe.recipeID]
    if info.costMode == "worst" then
        -- "Show cost as: Worst case" (Settings)
        Line(tooltip, "Cost (worst case, no procs)", Money(info.cost) .. (info.partial and "+" or ""), "gold")
        Why(tooltip, "Materials for one item if no multicraft or resourcefulness ever happens. Settings > Show cost as picks this or the estimate.")
        Line(tooltip, "Estimated", Money(info.estimatedCost))
        Why(tooltip, StatsText(stats))
    else
        Line(tooltip, "Cost (estimated)", Money(info.cost) .. (info.partial and "+" or ""), "gold")
        Why(tooltip, "Materials for one item: what you paid for ones you hold, otherwise today's AH price. Less what resourcefulness saves on average, spread over the extra items multicraft makes.")
        Why(tooltip, StatsText(stats))
        local worst = addon:WithCharacter(item.charKey, addon.GetWorstCaseCost, addon, recipe, info)
        if worst then
            Line(tooltip, "Worst case (no procs)", Money(worst))
            Why(tooltip, "The most the item can cost you.")
        end
    end
    local yours = item.itemID and addon:GetCraftedCost(item.itemID)
    Line(tooltip, "Your latest crafts cost you", yours and Money(yours) or "not crafted yet")
    if yours then
        Why(tooltip, "What the ones you've made and still hold actually cost, from Goldsmith's record of your crafts. Profit on their sale uses this.")
    end
    Line(tooltip, "Break-even AH price", Money(info.cost / (1 - AH_CUT)))
    Why(tooltip, "The lowest price that still covers the cost once the AH takes its 5% cut. The deposit isn't in it: you get that back when it sells, and lose it only if it expires.")
    if info.partial then
        Note(tooltip, "Some material costs are unknown, so the real cost is higher and the profit at most this.", "warning")
    end

    tooltip:AddLine(" ")
    if info.price then
        local stale = info.priceAge and info.priceAge >= STALE_PRICE_DAYS
        Line(tooltip, "AH price", Money(info.price))
        -- Where the price came from, on its own row: "Goldsmith Data, 09:15",
        -- "Auctionator, 2 days old", "TSM". From the row's own price, since
        -- gear tiers are priced by link, not by their shared item ID.
        Line(tooltip, "Price data", addon:PriceSourceText(item.itemID, info.priceSource, info.priceAge),
            stale and "warning" or "muted")
        Why(tooltip, "What it sells for now: the lowest listing, or the usual price when the lowest is far below it (a stray cheap listing). Price data says where it came from and how old it is.")
        Line(tooltip, "Profit each", string.format("%s%s", Signed(info.profit),
            info.margin and string.format(" (%.0f%% ROI)", info.margin) or ""), addon:MoneyColor(info.profit))
        Why(tooltip, "AH price less the 5% cut, less the cost. ROI is that profit as a share of the cost: 100% doubles your gold.")
    else
        Note(tooltip, "No AH price yet. Scan the AH with Auctionator.")
    end
    -- Without TSM: how well it sells (Goldsmith Data)
    local sellLevel = not addon:HasTSM() and addon:GetSellLevel(item.itemID)
    if sellLevel then
        Line(tooltip, "Sells", addon:SellLevelText(sellLevel) .. " (Goldsmith Data, last 7 days)",
            addon:SellLevelColor(sellLevel))
        Why(tooltip, "From the region's AH every hour: how often it sells, and how much is listed near the lowest price. Sells: often, with little stock ahead of you. Slow: now and then. Hardly sells: rarely.")
    end
    if info.demand then
        Line(tooltip, "Sold per day", string.format("%s (%s)", addon:FormatDemand(info.demand), info.demandSource or "?"),
            addon:DemandColor(info.demand, item.itemID))
        Why(tooltip, info.demandSource == "your sales"
            and "How many you've sold a day lately. The whole market sells more."
            or "TSM: the average sold per day across your region by players who use TSM, shared by every seller.")
    end
    if info.saleRate then
        Line(tooltip, "Sale rate", addon:FormatSaleRate(info.saleRate) .. " of listings sell",
            addon:SaleRateColor(info.saleRate))
        Why(tooltip, "TSM: of the auctions TSM players post, the share that sell. The rest expire or are cancelled, so a low rate means listings often sit.")
    end
    local have = item.itemID and addon:GetStock(item.itemID) or 0
    if have > 0 then
        Line(tooltip, "You have", tostring(have))
        Why(tooltip, "In bags and banks on your counted characters, and the warband bank.")
    end

    if info.concentrate then
        tooltip:AddLine(" ")
        Line(tooltip, "Concentration", string.format("about %d per craft", info.concentration), "conc")
        Why(tooltip, "Ingenuity sometimes refunds some, so it's an average.")
        local perPoint = GoldPerConc(info)
        if perPoint and perPoint < 0 then
            Line(tooltip, "Worth", Signed(perPoint) .. " per point: the craft loses gold", "loss")
            Why(tooltip, "The loss spread over the concentration it uses.")
        elseif perPoint then
            Line(tooltip, "Worth", Money(perPoint) .. " per point", "conc")
            Why(tooltip, "The extra gold concentration earns over making the same thing without it, per point. Compare it between crafts to spend concentration where it pays most.")
        end
    end

    -- Higher tiers only concentration reaches aren't listed while the
    -- Concentration switch is off: say they exist
    if item.tier and not info.concentrate and GoldsmithDB.ui2.craftsConcentration ~= true then
        local rows = addon:WithCharacter(item.charKey, addon.GetTierRows, addon, recipe) or {}
        local plainTiers = {}
        for _, row in ipairs(rows) do
            if not row.concentrate then plainTiers[row.tier] = true end
        end
        local shown = false
        for _, row in ipairs(rows) do
            if row.concentrate and row.tier > item.tier and not plainTiers[row.tier] then
                if not shown then tooltip:AddLine(" ") shown = true end
                Note(tooltip, string.format("%s tier needs concentration: about %d per craft, %s profit each. Turn on Concentration (top right) to see it.",
                    addon:TierIconText(row.tier, row.tierCount), row.concentration or 0,
                    row.profit and Signed(row.profit) or "no price"), "conc")
            end
        end
    end

    if item.whyNot then
        tooltip:AddLine(" ")
        Note(tooltip, "Not recommended: " .. item.whyNot, "warning")
    end
    tooltip:AddLine(" ")
    if item.unlearned then
        Why(tooltip, "Once learned, open the profession and it moves to your crafts.")
        addon:ClickHint(tooltip, "Click for the item's page")
        return
    end
    addon:ClickHint(tooltip, "Click to plan: materials, quantity, shopping list")
    addon:RightClickHint(tooltip, "Right-click to add it to the queue")
    addon:ShiftClickHint(tooltip, "Shift-click for the item's page")
end

-- Planner

local METHOD_COLORS = { Buy = "text", Vendor = "gold", Craft = "profit", Mill = "profit" }
-- "Milling", "Prospecting", "Crushing"
local function Gerund(verb)
    return (verb:gsub("e$", "")) .. "ing"
end

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
    local quality = node.qualityTier and (addon:TierIconText(node.qualityTier, node.tierCount or 2) .. " ") or ""
    cells.item:SetText(indent .. quality .. node.name)
    cells.need:SetText(Whole(node.need))
    -- Gold you hold counted for this silver row: a gold icon after the count
    local goldIcon = node.gold and (" " .. addon:TierIconText(node.tierCount or 2, node.tierCount or 2)) or ""
    cells.have:SetText(node.have > 0 and (Whole(node.have) .. goldIcon) or "-")
    if node.have <= 0 then cells.have:SetTextColor(addon:Color("dim")) end
    local best = node.best
    if best then
        -- * marks your own choice (right-click) rather than the cheapest
        -- Salvage says how ("Prospect", "Crush"), not "Mill" for everything
        cells.source:SetText((best.verb or best.method) .. (node.options.override and "*" or ""))
        cells.source:SetTextColor(addon:Color(METHOD_COLORS[best.method] or "text"))
        cells.each:SetText(Money(best.unit))
        -- Priced on what's expected to be used up (node.use, the craft's own
        -- materials), so the totals add up to the craft's cost
        cells.total:SetText(Money(best.unit * (node.use or node.need)))
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
    addon:AddItemDescription(tooltip, node.itemID)
    if node.qualityTier then
        Line(tooltip, "Quality", string.format("tier %d of %d %s", node.qualityTier, node.tierCount or 2,
            addon:TierIconText(node.qualityTier, node.tierCount or 2)))
    end
    Line(tooltip, "Need", tostring(Whole(node.need)))
    -- A gold row chosen because gold is cheaper than silver right now
    if node.lowID and node.lowID ~= node.itemID and node.qualityTier and node.qualityTier == node.tierCount then
        local low, high = addon:GetMarketPrice(node.lowID), addon:GetMarketPrice(node.itemID)
        if low and high and high <= low then
            Note(tooltip, string.format("Gold is cheaper than silver right now: %s vs %s.", Money(high), Money(low)), "profit")
        end
    end
    if node.gold then
        local chosen = GoldsmithDB.ui2.useHeldGold and GoldsmithDB.ui2.useHeldGold[node.gold.itemID]
        Note(tooltip, string.format("Using %d gold %s you have in place of silver%s.", node.gold.units, node.name,
            chosen and " (your choice)" or ": about the same price"))
    elseif node.goldKept then
        Note(tooltip, string.format("You have %d gold %s, kept: it's worth more than silver, so buying silver is cheaper. Right-click to use it anyway.",
            node.goldKept.units, node.name))
    end
    if node.use and node.need - node.use >= 0.5 then
        Why(tooltip, string.format("Each craft takes the full amount. About %s come back from resourcefulness and stay in your bags; the cost counts only what's used up.",
            Whole(node.need - node.use)))
    end
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
        -- Wrapped text loses the indent, so details come as short lines
        -- ("\n" between them), each indented
        for line in (detail or ""):gmatch("[^\n]+") do Note(tooltip, "    " .. line) end
    end
    Option(o.buy, "Buy on the AH", o.buy and ("AH price " .. (o.buy.ageText or "")))
    Option(o.vendor, "Vendor", o.vendor and o.vendor.detail)
    Option(o.craft, "Craft it", o.craft and "From its cheapest materials")
    -- A herb that gives several pigments has its price split between them
    -- by AH value (Planner.lua), so say this one's part
    local millDetail
    if o.mill and (o.mill.share or 1) < 0.999 then
        millDetail = string.format("%.2f per %s\nat %.0f%% of its AH price\n(what else it gives pays the rest,\nby AH value)",
            o.mill.perHerb, o.mill.herbName, o.mill.share * 100)
    elseif o.mill then
        millDetail = string.format("%.2f per %s\nat its AH price", o.mill.perHerb, o.mill.herbName)
    end
    Option(o.mill, (o.mill and o.mill.verb or "Mill") .. " it", millDetail)
    if not node.best then Note(tooltip, "  No price found. Scan the AH with Auctionator.", "loss") end

    if o.cheapest and o.buy and o.cheapest ~= o.buy and o.buy.unit > o.cheapest.unit then
        tooltip:AddLine(" ")
        Note(tooltip, string.format("%s it instead of buying saves %s here",
            o.cheapest.method == "Mill" and Gerund(o.cheapest.verb or "Mill") or "Crafting", Money((o.buy.unit - o.cheapest.unit) * node.need)),
            "profit")
    end
    if o.override and o.cheapest and node.best ~= o.cheapest then
        Note(tooltip, string.format("Your choice (%s) costs %s more here", node.best.verb or node.best.method,
            Money((node.best.unit - o.cheapest.unit) * node.need)), "warning")
    end
    addon:ClickHint(tooltip, "Click for its item page")
    addon:RightClickHint(tooltip, "Right-click to choose how to get it")
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
                local label = m.key == "mill" and ((option.verb or "Mill") .. " it") or m.label
                root:CreateRadio(string.format("%s (%s each)", label, Money(option.unit)),
                    function() return o.override == m.method end,
                    function()
                        addon:SetMethodOverride(node.itemID, m.method)
                        addon.Refresh()
                    end)
            end
        end
        -- Gold you hold for this silver row: use it, or keep it to sell
        local g = node.gold or node.goldKept
        if g then
            local useGold = GoldsmithDB.ui2.useHeldGold or {}
            GoldsmithDB.ui2.useHeldGold = useGold
            root:CreateDivider()
            root:CreateCheckbox(string.format("Use my gold %s here", node.name),
                function() return node.gold ~= nil end,
                function()
                    useGold[g.itemID] = node.gold == nil
                    addon.Refresh()
                end)
        end
        root:CreateDivider()
        root:CreateButton("Reset all my choices", function()
            addon:ClearMethodOverrides()
            if GoldsmithDB.ui2.useHeldGold then wipe(GoldsmithDB.ui2.useHeldGold) end
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
-- returnTab: where Back goes (e.g. "queue"), else the Crafts list.
function addon:OpenCraftPlan(recipe, info, charKey, quantity, returnTab)
    pending = {
        plan = {
            recipe = recipe, charKey = charKey or addon:GetCrafter(recipe.recipeID) or addon.charKey,
            tier = info and info.tier, concentrate = info and info.concentrate == true or false,
            scenario = info and info.scenario, returnTab = returnTab,
        },
        quantity = quantity,
    }
    addon:ShowTab("crafts")
end

-- Opens the mill planner for a salvage row (milling, prospecting): itemID
-- is what's salvaged; charKey whose yields to use (default: whoever the
-- Crafts row uses); quantity optional; returnTab as for OpenCraftPlan
function addon:OpenSalvagePlan(itemID, charKey, quantity, returnTab)
    local found
    for _, r in ipairs(addon:GetSalvageRows("All", {})) do
        if r.itemID == itemID then found = r break end
    end
    local s = found and found.salvage
    pending = {
        salvage = {
            itemID = itemID,
            name = (s and s.inputName) or C_Item.GetItemNameByID(itemID) or ("item " .. itemID),
            verb = found and found.recipe.outputName:match("^(%S+)") or "Salvage",
            profession = found and found.recipe.profession,
            estimated = s and s.estimated,
            charKey = charKey or (found and found.charKey) or addon.charKey,
            returnTab = returnTab,
        },
        quantity = quantity,
    }
    addon:ShowTab("crafts")
end

-- Crafting from the planner
--
-- The Craft button crafts the plan: its tier's mix of material qualities,
-- with concentration if the plan uses it, as many crafts as the plan says.
-- The game only crafts with the profession open, so until then the button
-- opens it at this recipe. Everything is checked first; if something's
-- missing the button stays off and its hover says why. Enchant scrolls
-- aren't crafted from here: they need a vellum passed as the target.

local function ProfessionOpen(recipe)
    if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then return false end
    local info = C_TradeSkillUI.GetBaseProfessionInfo and C_TradeSkillUI.GetBaseProfessionInfo()
    return info ~= nil and info.professionName == recipe.profession
end

-- The game's profession window shows what Goldsmith will craft: the
-- recipe, the plan's mix of material qualities, concentration on or off,
-- and how many. Uses the window's own recipe form (Blizzard's
-- ProfessionsRecipeTransactionMixin); if the game changes it, this quietly
-- does nothing and crafting still works. state is a CraftState.
local function Reagent(itemID)
    if Professions and Professions.CreateCraftingReagentByItemID then
        return Professions.CreateCraftingReagentByItemID(itemID)
    end
    return { itemID = itemID }
end

local function SyncProfessionWindow(recipeID, state)
    local page = ProfessionsFrame and ProfessionsFrame.CraftingPage
    local form = page and page.SchematicForm
    if not (form and page.SelectRecipe and form.GetTransaction) then return end
    local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
    if not info then return end
    local function Apply()
        local tx = form:GetTransaction()
        if not tx then return end

        if state.reagents and #state.reagents > 0 then
            local schematic = tx:GetRecipeSchematic()
            local slotFor = {}
            for i, slot in ipairs(schematic and schematic.reagentSlotSchematics or {}) do
                slotFor[slot.dataSlotIndex] = i
            end
            -- Keep the window from swapping in its own choice of qualities
            if tx.SetManuallyAllocated then tx:SetManuallyAllocated(true) end
            local cleared = {}
            for _, entry in ipairs(state.reagents) do
                local i = slotFor[entry.dataSlotIndex]
                local allocations = i and tx:GetAllocations(i)
                if allocations then
                    if not cleared[i] then allocations:Clear(); cleared[i] = true end
                    allocations:Allocate(Reagent(entry.reagent.itemID), entry.quantity)
                end
            end
        end
        tx:SetApplyConcentration(state.concentrate == true)
        if form.UpdateAllSlots then form:UpdateAllSlots() end
        if form.OnAllocationsChanged then form:OnAllocationsChanged() end
        if state.crafts and state.crafts > 0 and page.CreateMultipleInputBox then
            page.CreateMultipleInputBox:SetValue(state.crafts)
        end
    end

    local shown = form.GetRecipeInfo and form:GetRecipeInfo()
    if shown and shown.recipeID == recipeID then
        pcall(Apply)
    else
        -- Picking the recipe sets up a fresh form; fill it in once that's
        -- done, so the window's own defaults don't replace the plan's
        pcall(page.SelectRecipe, page, info)
        C_Timer.After(0.1, function() pcall(Apply) end)
    end
end

-- After "Open <profession>": opening takes a moment, so check a few times
-- and update the plan once it's open (which shows the plan in the window,
-- see SetCraftState)
local function UpdateWhenOpen(recipe, update, tries)
    tries = tries or 10
    C_Timer.After(0.3, function()
        if ProfessionOpen(recipe) then
            update()
        elseif tries > 1 then
            UpdateWhenOpen(recipe, update, tries - 1)
        end
    end)
end


-- Materials whose AH price is missing or a day or more old. Every quality
-- of the recipe's own materials is checked, not just what the plan buys:
-- the best mix can switch to a quality whose price was out of date once
-- buying rescans it. Vendor items are skipped.
local function StalePrices(plan)
    local seen, stale = {}, {}
    local function Check(itemID)
        if not itemID or seen[itemID] then return end
        seen[itemID] = true
        if addon:GetVendorPrice(itemID) then return end
        local price, source, age = addon:GetAHPriceInfo(itemID)
        if not price or ((source == "Auctionator" or source == "Blizzard") and (age or 0) >= 1) then
            table.insert(stale, { itemID = itemID })
        end
    end
    for _, slot in ipairs(plan.recipe.reagents or {}) do
        for _, itemID in ipairs(slot.itemIDs or {}) do Check(itemID) end
    end
    for _, node in ipairs(addon:FlattenPlan(plan)) do
        if not node.best or node.best.method == "Buy" then Check(node.itemID) end
    end
    return stale
end

-- The warning line above the summary, and what the Send button's hover
-- lists: { more, extra, stale }, or nil when there's nothing to say
local function ShoppingWarnings(plan)
    local more, extra = addon:ShoppingListChanges(plan)
    local w = { more = more or {}, extra = extra or {}, stale = StalePrices(plan) }
    if #w.more > 0 then
        local parts = {}
        for i, item in ipairs(w.more) do
            if i > 2 then
                table.insert(parts, string.format("%d more", #w.more - 2))
                break
            end
            table.insert(parts, item.quantity .. " " .. MaterialName(item.itemID))
        end
        w.text = "The plan changed since you sent the list. Also needs " .. table.concat(parts, ", ") .. ": send it again."
    elseif #w.extra > 0 then
        w.text = "The plan changed since you sent the list (it needs less now). Hover Send for details."
    elseif #w.stale > 0 then
        w.text = string.format("Old or missing AH prices for %d material%s (hover Send). Scan the AH first, or the plan may change after you buy.",
            #w.stale, #w.stale == 1 and "" or "s")
    else
        return nil
    end
    return w
end

-- Materials: enough to start each craft (resourcefulness may give some
-- back along the way, so you may get further than this). Adds notes and
-- blockers to state; returns how many crafts the materials allow.
local function CheckMaterials(state, needs, crafts)
    local missing = {}
    for itemID, per in pairs(needs) do
        local have = C_Item.GetItemCount(itemID, true, false, true, true) or 0
        local possible = math.floor(have / per)
        if possible == 0 then
            table.insert(missing, string.format("%d %s", per - have, MaterialName(itemID)))
        elseif possible < crafts then
            table.insert(state.notes, string.format("Materials for %d crafts: %s runs out.", possible, MaterialName(itemID)))
            crafts = possible
        end
    end
    if #missing > 0 then
        table.insert(state.blockers, "Missing for one craft: " .. table.concat(missing, ", ")
            .. ". Send the shopping list to Auctionator.")
    end
    return crafts
end

-- Gold you hold standing in for silver you're short of (GetCraftReagents):
-- say so, and if the game says it lifts the craft a tier, that too
local function SwapNotes(state, swapped, tierInfo)
    if not swapped then return end
    for _, s in ipairs(swapped.swaps) do
        table.insert(state.notes, string.format("Uses %d gold %s you have in place of silver.",
            s.units, s.name or "material"))
    end
    if tierInfo and swapped.tier and swapped.tier > tierInfo.tier then
        table.insert(state.notes, string.format("With it, this makes %s instead of %s.",
            addon:TierIconText(swapped.tier, tierInfo.tierCount), addon:TierIconText(tierInfo.tier, tierInfo.tierCount)))
    end
end

-- Steps before the final craft: plan rows you'll mill or craft yourself
-- that you don't have enough of yet, deepest first (pigments are milled
-- before the ink that uses them is made)
local function CollectSteps(nodes, steps)
    for _, node in ipairs(nodes) do
        if node.toGet > 0 and node.best then
            CollectSteps(node.children, steps)
            if node.best.method == "Mill" or node.best.method == "Craft" then
                table.insert(steps, node)
            end
        end
    end
    return steps
end

-- The salvage recipe (milling, prospecting) that takes an item, for the
-- open profession: recipe ID and how many items one cast uses, or nil
local salvageRecipes = {}
local function FindSalvageRecipe(itemID)
    local info = C_TradeSkillUI.GetBaseProfessionInfo()
    local key = table.concat({ addon.charKey or "", info and info.professionName or "", itemID }, ":")
    if salvageRecipes[key] ~= nil then
        return salvageRecipes[key] and salvageRecipes[key].recipeID, salvageRecipes[key] and salvageRecipes[key].perCast
    end
    salvageRecipes[key] = false
    if C_TradeSkillUI.GetSalvagableItemIDs and Enum.TradeskillRecipeType then
        for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
            local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
            if ok and schematic and schematic.recipeType == Enum.TradeskillRecipeType.Salvage then
                local okI, ids = pcall(C_TradeSkillUI.GetSalvagableItemIDs, recipeID)
                local recipeInfo = C_TradeSkillUI.GetRecipeInfo(recipeID)
                for _, id in ipairs(okI and ids or {}) do
                    if id == itemID and recipeInfo and recipeInfo.learned then
                        salvageRecipes[key] = { recipeID = recipeID, perCast = math.max(schematic.quantityMax or 1, 1) }
                        -- The planner rounds herbs up to whole mills
                        local record = GoldsmithDB.milling[itemID]
                        if record then record.perCast = salvageRecipes[key].perCast end
                        return recipeID, salvageRecipes[key].perCast
                    end
                end
            end
        end
    end
end

-- The biggest stack of an item in your bags (salvage needs one to use up)
local function LargestBagStack(itemID)
    local best, count = nil, 0
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and info.stackCount > count then
                best, count = ItemLocation:CreateFromBagAndSlot(bag, slot), info.stackCount
            end
        end
    end
    return best, count
end

-- A vellum for an enchant scroll: the biggest stack in your bags and how
-- many you have there, or nil
local function FindVellum(vellumID)
    if not vellumID then return nil end
    local location = LargestBagStack(vellumID)
    if not location then return nil end
    return location, C_Item.GetItemCount(vellumID) or 0
end

-- Button label: "Mill 15 Tranquility Bloom", shortened if it won't fit
local function StepLabel(verb, count, name)
    local label = string.format("%s %d %s", verb, count, name)
    if #label > 22 then label = string.format("%s %d", verb, count) end
    return label
end

-- A salvage step (mill, prospect, crush): salvage enough items for what's
-- still needed, from one stack at a time. node.best = { herbID, herbName,
-- perHerb (outputs per item), verb ("Mill" unless given) }.
local function MillStepState(node, state)
    local herbID, herbName = node.best.herbID, node.best.herbName
    local verb = node.best.verb or "Mill"
    local lower = verb:lower()
    local record = GoldsmithDB.milling[herbID]
    local profession = record and record.profession or "Inscription"
    if not ProfessionOpen({ profession = profession }) then
        table.insert(state.blockers, string.format("Open %s to %s %s first.", profession, lower, herbName))
        return state
    end
    local recipeID, perCast = FindSalvageRecipe(herbID)
    if not recipeID then
        table.insert(state.blockers, string.format("This character can't %s %s.", lower, herbName))
        return state
    end
    local location, stack = LargestBagStack(herbID)
    local wanted = math.ceil(node.toGet / math.max(node.best.perHerb, 0.01) / perCast - 0.0001)
    local casts = math.min(wanted, math.floor(stack / perCast))
    if casts <= 0 then
        local inBags = C_Item.GetItemCount(herbID) or 0
        local inBank = (C_Item.GetItemCount(herbID, true, false, true, true) or 0) - inBags
        if inBank >= perCast then
            table.insert(state.blockers, string.format("Take %s out of the bank to %s it.", herbName, lower))
        else
            table.insert(state.blockers, string.format("Not enough %s to %s (%d at a time). Send the shopping list to Auctionator.",
                herbName, lower, perCast))
        end
        state.label = StepLabel(verb, wanted * perCast, herbName)
        return state
    end
    local inBags = C_Item.GetItemCount(herbID) or 0
    table.insert(state.notes, string.format("Uses %d %s per %s; you have %d in your bags.", perCast, herbName, lower, inBags))
    if casts < wanted and inBags >= (casts + 1) * perCast then
        table.insert(state.notes, verb .. "s one stack per click.")
    end
    state.salvage = { recipeID = recipeID, casts = casts, location = location }
    state.enabled = #state.blockers == 0
    state.label = StepLabel(verb, casts * perCast, herbName)
    return state
end

-- A queued salvage batch (Queue.lua): salvage `count` more of an item
function addon.SalvageState(itemID, name, count, verb)
    local node = { toGet = count, best = { herbID = itemID, herbName = name, perHerb = 1, verb = verb } }
    local state = { label = verb, blockers = {}, notes = {} }
    return MillStepState(node, state)
end

-- A craft step: make the material, using the qualities the plan picked
-- for its own materials
local function CraftStepState(node, state)
    local recipe = node.best.recipe
    if not ProfessionOpen(recipe) then
        table.insert(state.blockers, string.format("Open %s to make %s first.", recipe.profession, node.name))
        return state
    end
    local info = C_TradeSkillUI.GetRecipeInfo(recipe.recipeID)
    if not (info and info.learned) then
        table.insert(state.blockers, string.format("This character doesn't know %s.", node.name))
        return state
    end
    local chosen = {}
    for _, child in ipairs(node.children) do chosen[child.itemID] = true end
    local outputPerCraft = addon:GetCraftModel(recipe)
    local wanted = math.max(math.ceil(node.toGet / math.max(outputPerCraft, 0.01) - 0.0001), 1)
    local reagents, needs, swapped = addon:GetCraftReagents(recipe.recipeID, { chosen = chosen },
        GoldsmithDB.ui2.planUseOnHand ~= false and { crafts = wanted } or nil)
    if not reagents then
        table.insert(state.blockers, "The game didn't give this recipe's materials. Try closing and reopening the profession.")
        return state
    end
    SwapNotes(state, swapped)
    local crafts = CheckMaterials(state, needs, wanted)
    state.recipeID, state.reagents, state.crafts = recipe.recipeID, reagents, crafts
    state.enabled = #state.blockers == 0 and crafts > 0
    state.label = StepLabel("Craft", crafts, node.name)
    return state
end

-- The Craft button while there are steps left: the first step, with the
-- full list for the tooltip
local function StepState(steps, plan)
    local state = { label = "Craft", blockers = {}, notes = {}, steps = {} }
    for _, node in ipairs(steps) do
        local verb = node.best.method == "Mill" and (node.best.verb or "Mill") or "Craft"
        local what = node.best.method == "Mill" and node.best.herbName or node.name
        table.insert(state.steps, string.format("%s %s", verb, what))
    end
    table.insert(state.steps, string.format("Craft %d %s", plan.crafts, plan.recipe.outputName))
    local node = steps[1]
    if node.best.method == "Mill" then
        return MillStepState(node, state)
    end
    return CraftStepState(node, state)
end

-- What the Craft button can do for a plan. Returns { label, enabled,
-- open (opens the profession instead), blockers (why it can't), notes,
-- crafts, reagents, concentrate, points }. While materials still need
-- milling or crafting, it's that step instead: steps (labels, the last is
-- the final craft), and salvage = { recipeID, casts, location } for a mill
-- or recipeID for a craft.
local function CraftState(p, tierInfo, plan)
    local recipe = p.recipe
    local state = { label = "Craft", blockers = {}, notes = {} }
    local learned = addon:KnowsRecipe(recipe.recipeID)
    if not learned and ProfessionOpen(recipe) then
        local info = C_TradeSkillUI.GetRecipeInfo(recipe.recipeID)
        learned = info and info.learned
    end
    if not learned then
        local c = GoldsmithDB.characters[p.charKey]
        table.insert(state.blockers, string.format("Log in on %s to craft this.",
            c and p.charKey ~= addon.charKey and c.name or "a character who knows it"))
        return state
    end
    if not ProfessionOpen(recipe) then
        state.label, state.enabled, state.open = "Open " .. recipe.profession, true, true
        table.insert(state.notes, "Opens " .. recipe.profession .. " at this recipe. The game only crafts with the profession open.")
        return state
    end

    -- Enchant scrolls are an enchant put on a vellum from your bags
    local scroll = GoldsmithDB.scrollOutputs[recipe.recipeID]
    if scroll then
        local location, vellums = FindVellum(scroll.vellumID)
        if not location then
            table.insert(state.blockers, string.format("Needs %s in your bags to put the enchant on.",
                (scroll.vellumID and C_Item.GetItemNameByID(scroll.vellumID)) or "an Enchanting Vellum"))
            return state
        end
        state.vellum, state.vellums = location, vellums
    end

    -- Materials you'll mill or craft yourself come first, one step per
    -- click; the button moves on as your bags fill up
    local steps = GoldsmithDB.ui2.planUseOnHand ~= false and CollectSteps(plan.nodes, {}) or {}
    if #steps > 0 then
        return StepState(steps, plan)
    end

    if C_TradeSkillUI.GetRecipeRequirements then
        local ok, requirements = pcall(C_TradeSkillUI.GetRecipeRequirements, recipe.recipeID)
        for _, r in ipairs(ok and requirements or {}) do
            if not r.met then table.insert(state.blockers, "Needs " .. (r.name or "something") .. " nearby.") end
        end
    end

    local reagents, needs, swapped = addon:GetCraftReagents(recipe.recipeID, tierInfo and tierInfo.scenario,
        GoldsmithDB.ui2.planUseOnHand ~= false
            and { crafts = plan.crafts, concentrate = tierInfo and tierInfo.concentrate == true } or nil)
    if not reagents then
        table.insert(state.blockers, "The game didn't give this recipe's materials. Try closing and reopening the profession.")
        return state
    end
    SwapNotes(state, swapped, tierInfo)
    state.reagents = reagents
    local crafts = plan.crafts

    -- Concentration: the full cost is needed to start each craft;
    -- ingenuity refunds some afterwards (the expected cost)
    state.concentrate = tierInfo and tierInfo.concentrate == true
    if state.concentrate then
        local current = addon:GetConcentration(recipe.profession) or 0
        local full = tierInfo.scenario and tierInfo.scenario.concentration or tierInfo.concentration
        local expected = math.max(tierInfo.concentration or full, 1)
        local affordable = current >= full and (math.floor((current - full) / expected) + 1) or 0
        if affordable == 0 then
            table.insert(state.blockers, string.format("Not enough concentration: %d to start, you have %d.", full, current))
        elseif affordable < crafts then
            table.insert(state.notes, string.format("Concentration for %d of the %d crafts.", affordable, crafts))
            crafts = affordable
        end
        state.points = crafts * expected
    end

    crafts = CheckMaterials(state, needs, crafts)
    -- One vellum per scroll
    if state.vellums and state.vellums < crafts then
        table.insert(state.notes, string.format("Vellums for %d scroll%s.", state.vellums, state.vellums == 1 and "" or "s"))
        crafts = state.vellums
    end
    state.crafts = crafts
    state.enabled = #state.blockers == 0 and crafts > 0
    state.label = string.format("Craft %d", crafts)
    -- The plan's own item (not a step): its crafts get a "Craft complete"
    -- notice (CraftDone.lua). planCrafts is the whole plan, which can be
    -- more than one batch (concentration or materials for fewer).
    state.final, state.planCrafts = true, plan.crafts
    return state
end

-- Does what a CraftState says: opens the profession at the recipe (then
-- calls onOpened once it's open), mills, or crafts. Needs a click or key
-- press (the game only crafts from one).
local function PerformCraftState(state, recipe, onOpened)
    if not (state and state.enabled) then return end
    if state.open then
        if C_TradeSkillUI.OpenRecipe then
            C_TradeSkillUI.OpenRecipe(recipe.recipeID)
            if onOpened then UpdateWhenOpen(recipe, onOpened) end
        else
            print("|cFF00FF00[Goldsmith]|r Open " .. recipe.profession .. ", then click Craft.")
        end
        return
    end
    if state.salvage then
        -- CraftSalvage(recipeID, casts, itemLocation)
        C_TradeSkillUI.CraftSalvage(state.salvage.recipeID, state.salvage.casts, state.salvage.location)
        return
    end
    if state.final then addon:StartCraftBatch(recipe, state) end
    if state.vellum then
        -- CraftEnchant(recipeID, count, reagents, itemTarget, concentrate):
        -- an enchant scroll, put on the vellum
        C_TradeSkillUI.CraftEnchant(recipe.recipeID, state.crafts, state.reagents, state.vellum, state.concentrate)
        return
    end
    -- CraftRecipe(recipeID, count, reagents, recipeLevel, orderID, concentrate)
    C_TradeSkillUI.CraftRecipe(state.recipeID or recipe.recipeID, state.crafts, state.reagents, nil, nil,
        state.concentrate)
end

-- For the queue (Queue.lua): the same plan lookups and Craft button
addon.FindTierInfo = FindTierInfo
addon.GetCraftState = CraftState
addon.PerformCraftState = PerformCraftState
addon.SyncProfessionWindow = SyncProfessionWindow
addon.StalePrices = StalePrices
addon.ProfessionOpen = ProfessionOpen

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
    -- The item and what it does; the click hint always shows (it's the
    -- only thing to explain here)
    UI.SetTooltip(titleButton, function(tooltip)
        if not screen.plan then return end
        tooltip:AddLine(screen.title:GetText() or screen.plan.recipe.outputName, 1, 1, 1)
        addon:AddItemDescription(tooltip, screen.tierItemID)
        addon:ClickHint(tooltip, "Click for the item's page", true)
    end)
    screen.subtitle = UI.Text(screen, "small", "muted")
    screen.subtitle:SetPoint("LEFT", screen.title, "RIGHT", 10, 0)

    -- Adds this plan (how many, tier, concentration) to the crafting
    -- character's queue, or changes how many if it's already there
    screen.queue = UI.Button(screen, "Add to queue", 130, 26, function()
        local p = screen.plan
        local quantity = tonumber(screen.qty:GetText()) or 0
        if not p or quantity <= 0 then return end
        local concentrate = screen.tierInfo and screen.tierInfo.concentrate == true or false
        local updated = addon:AddToQueue(p.charKey, p.recipe.recipeID, quantity, p.tier, concentrate)
        addon:Notify("info", "%s %d %s %s %s's queue.", updated and "Set" or "Added", quantity,
            p.recipe.outputName, updated and "in" or "to", CharName(p.charKey))
        screen:Update()
    end)
    screen.queue:SetPoint("TOPRIGHT", 0, 0)
    UI.SetTooltip(screen.queue, function(tooltip)
        local p = screen.plan
        if not p then return end
        tooltip:AddLine(screen.queue.label:GetText(), 1, 1, 1)
        tooltip:AddLine(string.format("Queue this craft for %s: shop for everything in the queue at once, then craft it all from the Queue tab or the button on the profession window.",
            CharName(p.charKey)), 0.8, 0.8, 0.8, true)
        if screen.queued then
            tooltip:AddLine(string.format("Already queued: %d (%d made so far). Clicking sets it to the number above.",
                screen.queued.quantity, screen.queued.made or 0), 0.6, 0.6, 0.6, true)
        end
    end, "ANCHOR_BOTTOM")
    screen.subtitle:SetPoint("RIGHT", screen.queue, "LEFT", -10, 0)

    local makeLabel = UI.Text(screen, "body", "muted")
    makeLabel:SetPoint("TOPLEFT", 2, -44)
    makeLabel:SetText("Make")
    screen.qty = UI.NumberBox(screen, 70, function(quantity)
        if screen.plan and quantity and quantity > 0 then ui.planQty[screen.plan.recipe.recipeID] = quantity end
        screen.allMade = nil
        screen:Update()
    end)
    screen.qty:SetPoint("LEFT", makeLabel, "RIGHT", 10, 0)

    -- Crafts from this screen's Craft button finished or stopped
    -- (CraftDone.lua): what was made comes off Make, so the plan is for
    -- what's left (Make 15, 5 made: Make 10). All made: Make 0, and the
    -- plan says so instead of offering to craft it all again.
    function screen:CraftsDone(recipeID, made)
        if not (screen.plan and screen.plan.recipe.recipeID == recipeID) or made <= 0 then return end
        local left = math.max((tonumber(screen.qty:GetText()) or 0) - made, 0)
        screen.qty:SetText(tostring(left))
        if left > 0 then ui.planQty[recipeID] = left end
        screen.allMade = left == 0 or nil
        screen:Update()
    end
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
        addon:Explain(tooltip, "Plan this tier with concentration, using the mix of material qualities that earns the most. Some tiers can only be reached with it.", 0.6, 0.6, 0.6, true)
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

    -- Why this mix of material qualities: the best few the game confirmed
    -- for this tier, so the choice can be checked (see UpdateMixes)
    local mixes = UI.Panel(screen)
    mixes:SetPoint("BOTTOMLEFT", 0, PLAN_SUMMARY_HEIGHT + 10)
    mixes:SetPoint("BOTTOMRIGHT", 0, PLAN_SUMMARY_HEIGHT + 10)
    mixes:SetHeight(MIX_HEIGHT)
    mixes:Hide()
    screen.mixes = mixes
    -- Closed by default: one bar saying what was picked; click to open
    -- the comparison (remembered in ui.planMixOpen)
    mixes.bar = CreateFrame("Button", nil, mixes)
    mixes.bar:SetPoint("TOPLEFT")
    mixes.bar:SetPoint("TOPRIGHT")
    mixes.bar:SetHeight(MIX_BAR_HEIGHT)
    mixes.bar:SetScript("OnClick", function()
        ui.planMixOpen = not ui.planMixOpen
        screen:UpdateMixes(screen.tierInfo)
    end)
    mixes.bar:SetScript("OnEnter", function() mixes:SetBackdropBorderColor(addon:Color("gold")) end)
    mixes.bar:SetScript("OnLeave", function() mixes:SetBackdropBorderColor(addon:Color("border")) end)
    mixes.title = UI.Text(mixes.bar, "label", "muted")
    mixes.title:SetPoint("LEFT", 16, 0)
    mixes.title:SetText("WHY THIS MIX OF MATERIAL QUALITIES")
    mixes.toggle = UI.Text(mixes.bar, "small", "hint", "RIGHT")
    mixes.toggle:SetPoint("RIGHT", -16, 0)
    mixes.picked = UI.Text(mixes.bar, "small", "text")
    mixes.picked:SetPoint("LEFT", mixes.title, "RIGHT", 14, 0)
    mixes.picked:SetPoint("RIGHT", mixes.toggle, "LEFT", -14, 0)
    -- The comparison, shown when open
    mixes.body = CreateFrame("Frame", nil, mixes)
    mixes.body:SetPoint("TOPLEFT", 0, -MIX_BAR_HEIGHT + 6)
    mixes.body:SetPoint("BOTTOMRIGHT")
    mixes.why = UI.Text(mixes.body, "small", "muted")
    mixes.why:SetPoint("TOPLEFT", 16, 0)
    mixes.why:SetPoint("RIGHT", -16, 0)
    -- Columns: right edges, from the panel's left
    local MIX_COLUMNS = {
        { key = "cost", label = "Cost each", right = 520 },
        { key = "conc", label = "Concentration", right = 630 },
        { key = "profit", label = "Profit each", right = 735 },
        { key = "perPoint", label = "Per point", right = 840 },
    }
    local function Cell(parent, y, font, color, column)
        local fs = UI.Text(parent, font, color, column and "RIGHT" or "LEFT")
        if column then
            fs:SetPoint("TOPRIGHT", parent, "TOPLEFT", column.right, y)
            fs:SetWidth(100)
        else
            fs:SetPoint("TOPLEFT", 16, y)
            fs:SetWidth(MIX_COLUMNS[1].right - 120)
        end
        return fs
    end
    local body = mixes.body
    mixes.header = { mix = Cell(body, -22, "label", "muted") }
    mixes.header.mix:SetText("MIX")
    for _, c in ipairs(MIX_COLUMNS) do
        mixes.header[c.key] = Cell(body, -22, "label", "muted", c)
        mixes.header[c.key]:SetText(c.label:upper())
    end
    mixes.rows = {}
    -- The top mixes, then two lines without concentration
    for i = 1, MIX_SHOWN + 2 do
        local y = -40 - (i - 1) * 18
        local row = { mix = Cell(body, y, "small", "text") }
        for _, c in ipairs(MIX_COLUMNS) do row[c.key] = Cell(body, y, "small", "text", c) end
        mixes.rows[i] = row
    end

    -- Fills the panel from the tier row the plan uses (GetTierRows: its
    -- scenarios are every mix the game confirmed, with cost, concentration
    -- and profit). Ranked the way the choice was made: with concentration,
    -- most extra gold per concentration point; without, cheapest to reach
    -- the tier. With concentration, the two extremes without it (all
    -- silver, all gold) are the last lines, each with the tier it reaches,
    -- to show what concentrating adds (often even all gold can't reach the
    -- tier). Hidden for crafts without material qualities, and the
    -- materials list takes the space back.
    -- planCostEach (once the plan is built): the plan's cost per item. The
    -- tier rows value materials that come in one quality at what yours cost
    -- you, the plan at today's price, so every row is shifted by the
    -- difference: the mixes differ only in quality materials, so the order
    -- and the gaps stay, and the picked row matches the cost below.
    function screen:UpdateMixes(tierInfo, planCostEach)
        -- Opening or closing the panel redraws it without the plan's cost:
        -- keep the last one for the same mix, so the numbers don't jump
        if planCostEach then
            screen.mixPlanCost = { scenario = tierInfo and tierInfo.scenario, cost = planCostEach }
        elseif screen.mixPlanCost and tierInfo and screen.mixPlanCost.scenario == tierInfo.scenario then
            planCostEach = screen.mixPlanCost.cost
        end
        local candidates, baselines = {}, {}
        if tierInfo and tierInfo.scenarios then
            local seen, allLow, allHigh = {}, nil, nil
            for _, e in ipairs(tierInfo.scenarios) do
                local fits = e.tier == tierInfo.tier and (e.concentrate == true) == (tierInfo.concentrate == true)
                    and (not tierInfo.concentrate or e.concentrationValue)
                local key = e.description or tostring(e)
                if fits and not seen[key] then
                    seen[key] = true
                    table.insert(candidates, e)
                end
                if tierInfo.concentrate and not e.concentrate and e.description then
                    if e.description == "all gold" then
                        allHigh = allHigh or e
                    elseif e.description:find("^all ") then
                        allLow = allLow or e
                    end
                end
            end
            if allLow then table.insert(baselines, allLow) end
            if allHigh then table.insert(baselines, allHigh) end
            if tierInfo.concentrate then
                table.sort(candidates, function(a, b) return a.concentrationValue > b.concentrationValue end)
            else
                table.sort(candidates, function(a, b) return a.cost < b.cost end)
            end
        end
        local shown = #candidates >= 2 or (#candidates == 1 and #baselines > 0)
        mixes:SetShown(shown)
        screen.list:ClearAllPoints()
        screen.list:SetPoint("TOPLEFT", 0, -80)
        local open = ui.planMixOpen == true
        local height = open and MIX_HEIGHT or MIX_BAR_HEIGHT
        mixes:SetHeight(height)
        mixes.body:SetShown(open)
        screen.list:SetPoint("BOTTOMRIGHT", 0, PLAN_SUMMARY_HEIGHT + 12 + (shown and height + 8 or 0))
        if not shown then return end

        -- Ranks 1-3; the one the plan uses is always listed (with its
        -- real rank if that's lower)
        local list, ranks = {}, {}
        for i = 1, math.min(#candidates, MIX_SHOWN) do list[i], ranks[i] = candidates[i], i end
        local chosenShown = false
        for _, e in ipairs(list) do
            if e.scenario == tierInfo.scenario then chosenShown = true end
        end
        if not chosenShown and tierInfo.built then
            -- A mix built in between: its own line under the top ones
            -- (without concentration, so the baseline lines aren't there)
            table.insert(list, tierInfo)
        elseif not chosenShown then
            list[#list] = tierInfo
            for i, e in ipairs(candidates) do
                if e.scenario == tierInfo.scenario then ranks[#list] = i end
            end
        end

        local conc = tierInfo.concentrate == true
        local offset = (planCostEach and tierInfo.cost) and (planCostEach - tierInfo.cost) or 0
        local top = math.min(#candidates, MIX_SHOWN)
        local pickedRank
        for i, e in ipairs(candidates) do
            if e.scenario == tierInfo.scenario then pickedRank = i end
        end
        mixes.why:SetText(string.format(conc
            and "The top %d of %d mixes that reach this tier, ranked by extra gold per concentration point.%s"
            or "The top %d of %d mixes that reach this tier, cheapest first.%s", top, #candidates,
            (tierInfo.built and " Picked: a mix in between that uses materials you have.")
            or ((tierInfo.heldPick and pickedRank) and string.format(" Picked #%d: it uses materials you have.", pickedRank))
            or ""))
        mixes.header.mix:SetText(string.format("TOP %d MIXES", top))
        mixes.header.conc:SetShown(conc)
        mixes.header.perPoint:SetShown(conc)

        -- The bar, open or closed: what was picked, in a line
        local pickedText = (tierInfo.description or "?"):gsub("^%l", string.upper)
        local pickedNumbers = conc and tierInfo.concentrationValue
            and string.format("%s per point", Money(tierInfo.concentrationValue)) or Money(tierInfo.cost + offset) .. " each"
        mixes.picked:SetText(string.format("Picked: %s  %s", pickedText,
            addon:Colorize(string.format(tierInfo.heldPick and "(%s, uses materials you have)" or "(%s, best of %d)",
                pickedNumbers, #candidates), "muted")))
        mixes.toggle:SetText(open and "Hide" or "Compare")

        local function Fill(row, e, label, color)
            row.mix:SetText(label)
            row.mix:SetTextColor(addon:Color(color))
            row.cost:SetText(Money(e.cost + offset) .. (e.partial and "+" or ""))
            row.cost:SetTextColor(addon:Color(color))
            row.conc:SetText(e.concentrate and string.format("%d", e.concentration) or "-")
            row.conc:SetTextColor(addon:Color(color))
            row.conc:SetShown(conc)
            if e.profit then
                row.profit:SetText(Signed(e.profit - offset))
                row.profit:SetTextColor(addon:Color(addon:MoneyColor(e.profit - offset)))
            else
                row.profit:SetText("-")
                row.profit:SetTextColor(addon:Color("dim"))
            end
            row.perPoint:SetText(e.concentrationValue and Money(e.concentrationValue) or "-")
            row.perPoint:SetTextColor(addon:Color(color))
            row.perPoint:SetShown(conc)
            for _, fs in pairs(row) do if fs ~= row.conc and fs ~= row.perPoint then fs:Show() end end
        end
        local function Clear(row)
            for _, fs in pairs(row) do fs:Hide() end
        end

        for i, row in ipairs(mixes.rows) do
            local e = list[i]
            if e then
                local picked = e.scenario == tierInfo.scenario
                -- A mix built in between has no rank
                local label = ((e.description or "?"):gsub("^%l", string.upper))
                local text = e.built and ("     " .. label) or string.format("%d.  %s", ranks[i] or i, label)
                -- Gold picked because it's cheaper than silver right now
                local recipe = screen.plan and screen.plan.recipe
                if recipe and addon:MixUsesCheaperGold(recipe, e.scenario) then
                    text = text .. addon:Colorize("  (gold is cheaper)", "dim")
                end
                Fill(row, e, picked and (text .. addon:Colorize("  (picked)", "dim")) or text, picked and "gold" or "text")
            elseif baselines[i - #list] then
                -- Without concentration, each extreme and the tier it reaches
                local b = baselines[i - #list]
                Fill(row, b, string.format("Without concentration, %s makes %s", b.description,
                    addon:TierIconText(b.tier, b.tierCount)), "muted")
            else
                Clear(row)
            end
        end
    end

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
    -- Shopping warnings: old or missing prices, or the plan changed since
    -- its list was sent (see ShoppingWarnings)
    screen.warnLine = SummaryLine(64)
    screen.warnLine:SetTextColor(addon:Color("warning"))
    screen.demandLine = SummaryLine(46)
    screen.spendLine = SummaryLine(28)
    screen.vendorLine = SummaryLine(10)

    screen.shop = UI.Button(summary, "Send to Auctionator", 170, 28, function()
        if not screen.current then return end
        local ok, result = addon:SendShoppingList(screen.current)
        if ok then
            print("|cFF00FF00[Goldsmith]|r Shopping list \"" .. result .. "\" sent to Auctionator's Shopping tab.")
            screen:Update()
        else
            print("|cFF00FF00[Goldsmith]|r Couldn't create the shopping list: " .. result)
        end
    end)
    screen.shop:SetPoint("BOTTOMRIGHT", -14, 12)
    UI.SetTooltip(screen.shop, function(tooltip)
        tooltip:AddLine("Send to Auctionator", 1, 1, 1)
        tooltip:AddLine("Makes a shopping list of what to buy. Items come off it as you buy them, and it's deleted once everything's bought.",
            0.8, 0.8, 0.8, true)
        local w = screen.warnings
        if not w then return end
        local r, g, b = addon:Color("warning")
        local function Section(title, items, describe)
            if #items == 0 then return end
            tooltip:AddLine(" ")
            tooltip:AddLine(title, r, g, b, true)
            for _, item in ipairs(items) do
                tooltip:AddDoubleLine("    " .. MaterialName(item.itemID), describe(item), 0.9, 0.9, 0.9, 1, 1, 1)
            end
        end
        Section("The plan changed since you sent the list. Now also needs:", w.more,
            function(item) return "x" .. item.quantity end)
        Section("On the list but no longer needed:", w.extra,
            function(item) return "x" .. item.quantity end)
        Section("Old or missing AH prices. Scan the AH first, or the plan may change after you buy:", w.stale,
            function(item) return addon:AHPriceAgeText(item.itemID) end)
    end, "ANCHOR_TOP")

    -- Craft (or open the profession first); see CraftState
    screen.craft = UI.Button(summary, "Craft", 170, 28, function()
        local state, p = screen.craftState, screen.plan
        if not (state and state.enabled and p) then return end
        -- So its crafts come off Make when they're done (CraftsDone)
        state.fromPlan = true
        PerformCraftState(state, p.recipe, function()
            if screen.plan == p and screen:IsVisible() then screen:Update() end
        end)
    end)
    screen.craft:SetPoint("BOTTOMRIGHT", screen.shop, "TOPRIGHT", 0, 8)
    UI.Style(screen.craft, "highlight", "borderGold")
    screen.craft.label:SetTextColor(addon:Color("gold"))
    screen.craft:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    UI.SetTooltip(screen.craft, function(tooltip)
        local state = screen.craftState
        if not state then return end
        tooltip:AddLine(state.open and state.label or "Craft from Goldsmith", 1, 1, 1)
        if state.steps then
            tooltip:AddLine("One click per step; the button moves on as your bags fill up:", 0.8, 0.8, 0.8, true)
            for i, step in ipairs(state.steps) do
                local r, g, b = 0.6, 0.6, 0.6
                if i == 1 then r, g, b = addon:Color("gold") end
                tooltip:AddLine(string.format("    %d. %s", i, step), r, g, b)
            end
        end
        -- No materials list: the plan above already shows them
        if state.concentrate and state.points then
            local r, g, b = addon:Color("conc")
            tooltip:AddLine(string.format("With concentration: about %d in all.", state.points), r, g, b, true)
        end
        for _, line in ipairs(state.notes) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
        for _, line in ipairs(state.blockers) do tooltip:AddLine(line, 1, 0.6, 0.2, true) end
    end, "ANCHOR_TOP")

    -- With the profession open, the window is set to match the plan whenever
    -- the plan changes (recipe, mix, concentration, how many), but not after
    -- each craft, so it's never changed mid-craft
    local function SyncWindow(state)
        local p = screen.plan
        if not (state and state.reagents and p and ProfessionOpen(p.recipe)) then
            screen.syncedKey = nil
            return
        end
        -- A craft step shows that step's recipe
        local recipeID = state.recipeID or p.recipe.recipeID
        local parts = { recipeID, tostring(state.concentrate), screen.qty:GetText() }
        for _, e in ipairs(state.reagents) do table.insert(parts, e.reagent.itemID .. "x" .. e.quantity) end
        local key = table.concat(parts, "|")
        if key ~= screen.syncedKey then
            screen.syncedKey = key
            SyncProfessionWindow(recipeID, state)
        end
    end

    local function SetCraftState(state)
        screen.craftState = state
        screen.craft:SetLabel(state and state.label or "Craft")
        local enabled = state ~= nil and state.enabled == true
        screen.craft:SetEnabled(enabled)
        screen.craft:SetAlpha(enabled and 1 or 0.5)
        SyncWindow(state)
    end

    local function ClearSummary(message)
        for _, f in ipairs({ screen.cost, screen.sells, screen.profit }) do
            f.value:SetText("-")
            f.value:SetTextColor(addon:Color("dim"))
            f.note:SetText("")
        end
        screen.demandLine:SetText(message or "")
        screen.warnLine:SetText("")
        screen.warnings = nil
        screen.spendLine:SetText("")
        screen.vendorLine:SetText("")
        screen.shop:Disable()
        screen.shop:SetAlpha(0.5)
        SetCraftState(nil)
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
        -- Using what you hold: a mix of the same tier that needs less buying
        if ui.planUseOnHand ~= false and tierInfo then
            tierInfo = addon:WithCharacter(p.charKey, addon.PreferHeldMix, addon, recipe, tierInfo,
                tonumber(screen.qty:GetText()) or 0)
        end
        screen.tierInfo = tierInfo
        screen.tierItemID = tierInfo and tierInfo.itemID or recipe.outputItemID
        screen.queued = addon:FindQueueEntry(p.charKey, recipe.recipeID, p.tier,
            tierInfo and tierInfo.concentrate == true or false)
        screen.queue:SetLabel(screen.queued and "Update queue" or "Add to queue")
        local tierIcon = tierInfo and (addon:TierIconText(tierInfo.tier, tierInfo.tierCount) .. " ") or ""
        screen.title:SetText(addon:ProfessionIconText(recipe.profession) .. tierIcon .. recipe.outputName)
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
        screen:UpdateMixes(tierInfo)

        local quantity = tonumber(screen.qty:GetText()) or 0
        if quantity <= 0 then
            screen.current = nil
            screen.list:SetItems({})
            screen.crafts:SetText("")
            ClearSummary(screen.allMade and "All made. Enter a number to make more." or "Enter how many to make.")
            return
        end

        local plan = addon:WithCharacter(p.charKey, addon.BuildPlan, addon, recipe, quantity,
            ui.planUseOnHand ~= false, tierInfo)
        screen.current = plan
        screen.list:SetItems(addon:FlattenPlan(plan))
        screen.crafts:SetFormattedText("%d craft%s, about %.1f made", plan.crafts,
            plan.crafts == 1 and "" or "s", plan.expectedOutput)

        local made = math.max(plan.expectedOutput, 0.0001)
        -- The mix table, lined up with this plan's cost
        screen:UpdateMixes(tierInfo, plan.cost / made)
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

        -- How it sells, the same rating as the Crafts list (Goldsmith Data's
        -- sell level without TSM), then how long this many lasts at the
        -- daily sales. Orange only for a slow seller or more than
        -- PLAN_DAYS_WARN days' worth: a couple of days of a good seller is fine.
        local itemID = (tierInfo and tierInfo.itemID) or plan.recipe.outputItemID
        local level = not addon:HasTSM() and addon:GetSellLevel(itemID)
        if level or (plan.demand and plan.demand > 0) then
            local parts, warn = {}, false
            if level then
                table.insert(parts, addon:Colorize(addon:SellLevelText(level), addon:SellLevelColor(level)) .. " (Goldsmith Data).")
                warn = level ~= addon.SELL_LEVEL.sells
            end
            if plan.demand and plan.demand > 0 then
                local days = quantity / plan.demand
                local worth
                if days < 1 then
                    worth = "less than a day's worth"
                elseif days < 1.5 then
                    worth = "about a day's worth"
                else
                    worth = string.format("about %.0f days' worth", days)
                end
                table.insert(parts, string.format("%s about %s a day (%s): %d is %s.",
                    level and "You sell" or "Sells", addon:FormatDemand(plan.demand), plan.demandSource or "?", quantity, worth))
                warn = warn or days > PLAN_DAYS_WARN
            end
            screen.demandLine:SetText(table.concat(parts, " "))
            screen.demandLine:SetTextColor(addon:Color(warn and "warning" or "muted"))
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
        -- Old prices only matter while there's something to buy
        local warnings = ShoppingWarnings(plan)
        if warnings and #warnings.more == 0 and #warnings.extra == 0 and #plan.buyAH == 0 then
            warnings = nil
        end
        screen.warnings = warnings
        screen.warnLine:SetText(warnings and warnings.text or "")
        SetCraftState(CraftState(p, tierInfo, plan))
    end

    return screen
end

-- Mill planner
--
-- Clicking a salvage row (mill, prospect) opens this: how many to salvage,
-- what to buy, what should come out, and whether salvaging beats buying
-- what comes out. Planned like a queued batch (BuildSalvagePlan, Queue.lua).
local SALVAGE_COLUMNS = {
    { key = "item", label = "Item" },
    { key = "amount", label = "Amount", width = 70, justify = "RIGHT" },
    { key = "have", label = "Have", width = 56, justify = "RIGHT" },
    { key = "each", label = "Each", width = 84, justify = "RIGHT" },
    { key = "total", label = "Total", width = 90, justify = "RIGHT" },
}

-- Rows: what's salvaged first, then what should come out (output = true)
local function FillSalvageRow(row, item)
    local c = row.cells
    c.item:SetText((item.output and "    > " or "") .. MaterialName(item.itemID, item.name))
    c.item:SetTextColor(addon:Color("text"))
    c.amount:SetText((item.output and "~" or "") .. Whole(item.amount))
    c.have:SetText(item.have and item.have > 0 and Whole(item.have) or "-")
    c.have:SetTextColor(addon:Color(item.have and item.have > 0 and "text" or "dim"))
    c.each:SetText(item.unit and Money(item.unit) or "no price")
    c.each:SetTextColor(addon:Color(item.unit and "text" or "dim"))
    c.total:SetText(item.total and Money(item.total) or "-")
    c.total:SetTextColor(addon:Color(item.total and "text" or "dim"))
end

local function SalvageRowTooltip(tooltip, item)
    tooltip:AddLine(MaterialName(item.itemID, item.name), 1, 1, 1)
    addon:AddItemDescription(tooltip, item.itemID)
    if item.output then
        Line(tooltip, "Should come out", "about " .. Whole(item.amount))
        Line(tooltip, "AH price", item.unit and string.format("%s (%s)", Money(item.unit), addon:PriceAgeText(item.itemID))
            or "no price")
        if item.millUnit then
            Line(tooltip, "By salvaging", Money(item.millUnit) .. " each", item.millUnit < item.unit and "profit" or "warning")
            Why(tooltip, "The cost of what's salvaged, split across what comes out by AH value.")
        end
    else
        Line(tooltip, "To salvage", Whole(item.amount))
        if item.have and item.have > 0 then Line(tooltip, "You have", Whole(item.have)) end
        Line(tooltip, "To buy", Whole(item.toBuy))
        Line(tooltip, "AH price", item.unit and string.format("%s (%s)", Money(item.unit), addon:PriceAgeText(item.itemID))
            or "no price", (not item.unit) and "warning" or nil)
    end
    addon:ClickHint(tooltip, "Click for the item's page")
end

-- A salvage recipe for an item from saved salvage runs, so the profession
-- can be opened at it while it's closed (the game only lists recipes with
-- it open): this character's run of the item, else their latest salvage in
-- the same profession, else anyone's
local function KnownSalvageRecipe(itemID, profession)
    local own, same, any
    for _, run in pairs(GoldsmithDB.salvageRuns or {}) do
        local record = GoldsmithDB.milling[run.itemID]
        local runProfession = record and record.profession or "Inscription"
        if run.recipeID and runProfession == profession then
            local mine = run.character == addon.charKey
            if mine and run.itemID == itemID then
                if not own or run.time > own.time then own = run end
            elseif mine then
                if not same or run.time > same.time then same = run end
            elseif not any or run.time > any.time then
                any = run
            end
        end
    end
    local run = own or same or any
    return run and run.recipeID
end

local function CreateSalvageScreen(parent)
    local ui = GoldsmithDB.ui2
    local screen = CreateFrame("Frame", nil, parent)
    screen:SetAllPoints()
    screen:Hide()

    screen.back = UI.Button(screen, "< Back", 76, 26, function() view:CloseSalvage() end)
    screen.back:SetPoint("TOPLEFT", 0, 0)
    screen.title = UI.Text(screen, "heading")
    screen.title:SetPoint("LEFT", screen.back, "RIGHT", 14, 0)
    local titleButton = CreateFrame("Button", nil, screen)
    titleButton:SetAllPoints(screen.title)
    titleButton:SetScript("OnClick", function()
        local t = screen.target
        if t then addon:OpenItem(t.name, t.itemID) end
    end)
    UI.SetTooltip(titleButton, function(tooltip)
        local t = screen.target
        if not t then return end
        tooltip:AddLine(screen.title:GetText() or t.name, 1, 1, 1)
        addon:AddItemDescription(tooltip, t.itemID)
        addon:ClickHint(tooltip, "Click for the item's page", true)
    end)
    screen.subtitle = UI.Text(screen, "small", "muted")
    screen.subtitle:SetPoint("LEFT", screen.title, "RIGHT", 10, 0)

    screen.queue = UI.Button(screen, "Add to queue", 130, 26, function()
        local t = screen.target
        local quantity = tonumber(screen.qty:GetText()) or 0
        if not t or quantity <= 0 then return end
        local updated = addon:AddSalvageToQueue(t.charKey, t.itemID, quantity)
        addon:Notify("info", "%s %s's queue: %s %d %s.", updated and "Changed in" or "Added to",
            CharName(t.charKey), t.verb:lower(), quantity, t.name)
        screen:Update()
    end)
    screen.queue:SetPoint("TOPRIGHT", 0, 0)
    UI.SetTooltip(screen.queue, function(tooltip)
        local t = screen.target
        if not t then return end
        tooltip:AddLine(screen.queue.label:GetText(), 1, 1, 1)
        tooltip:AddLine(string.format("Queue this batch for %s: shop for everything in the queue at once, then work through it from the Queue tab or the button on the profession window.",
            CharName(t.charKey)), 0.8, 0.8, 0.8, true)
        if screen.queued then
            tooltip:AddLine(string.format("Already queued: %d (%d done so far). Clicking sets it to the number above.",
                screen.queued.quantity, screen.queued.made or 0), 0.6, 0.6, 0.6, true)
        end
    end, "ANCHOR_BOTTOM")
    screen.subtitle:SetPoint("RIGHT", screen.queue, "LEFT", -10, 0)

    screen.verbLabel = UI.Text(screen, "body", "muted")
    screen.verbLabel:SetPoint("TOPLEFT", 2, -44)
    screen.qty = UI.NumberBox(screen, 70, function(quantity)
        local t = screen.target
        if t and quantity and quantity > 0 then
            ui.salvageBatch = ui.salvageBatch or {}
            ui.salvageBatch[t.itemID] = quantity
        end
        screen:Update()
    end)
    screen.qty:SetPoint("LEFT", screen.verbLabel, "RIGHT", 10, 0)
    screen.casts = UI.Text(screen, "small", "muted")
    screen.casts:SetPoint("LEFT", screen.qty, "RIGHT", 10, 0)

    screen.useHave = UI.Checkbox(screen, "Use materials I have", function(checked)
        ui.planUseOnHand = checked
        screen:Update()
    end)
    screen.useHave:SetPoint("TOPRIGHT", 0, -44)

    screen.list = UI.List(screen, {
        fill = FillSalvageRow,
        tooltip = SalvageRowTooltip,
        onClick = function(item) addon:OpenItem(item.name, item.itemID) end,
        empty = "Enter how many to salvage.",
    })
    screen.list:SetPoint("TOPLEFT", 0, -80)
    screen.list:SetPoint("BOTTOMRIGHT", 0, PLAN_SUMMARY_HEIGHT + 12)
    screen.list:SetColumns(SALVAGE_COLUMNS)

    -- Summary: cost, worth, profit; then buy-or-salvage, shopping, buttons
    local summary = UI.Panel(screen)
    summary:SetPoint("BOTTOMLEFT")
    summary:SetPoint("BOTTOMRIGHT")
    summary:SetHeight(PLAN_SUMMARY_HEIGHT)
    local third = 860 / 3
    local function Figure(i, label)
        local f = {}
        f.label = UI.Text(summary, "label", "muted")
        f.label:SetPoint("TOPLEFT", 16 + (i - 1) * third, -14)
        f.label:SetText(label)
        f.value = UI.Text(summary, "value")
        f.value:SetPoint("TOPLEFT", f.label, "BOTTOMLEFT", 0, -5)
        f.note = UI.Text(summary, "small", "muted")
        f.note:SetPoint("TOPLEFT", f.value, "BOTTOMLEFT", 0, -4)
        f.note:SetWidth(third - 24)
        return f
    end
    screen.cost, screen.worth, screen.profit = Figure(1, "COST"), Figure(2, "WORTH"), Figure(3, "PROFIT")

    local function SummaryLine(y)
        local fs = UI.Text(summary, "small", "muted")
        fs:SetPoint("BOTTOMLEFT", 16, y)
        fs:SetPoint("RIGHT", summary, "RIGHT", -200, 0)
        return fs
    end
    screen.warnLine = SummaryLine(64)
    screen.compareLine = SummaryLine(46)
    screen.spendLine = SummaryLine(28)
    screen.noteLine = SummaryLine(10)

    screen.shop = UI.Button(summary, "Send to Auctionator", 170, 28, function()
        if not screen.current then return end
        local ok, result = addon:SendShoppingList(screen.current)
        if ok then
            print("|cFF00FF00[Goldsmith]|r Shopping list \"" .. result .. "\" sent to Auctionator's Shopping tab.")
            screen:Update()
        else
            print("|cFF00FF00[Goldsmith]|r Couldn't create the shopping list: " .. result)
        end
    end)
    screen.shop:SetPoint("BOTTOMRIGHT", -14, 12)
    UI.SetTooltip(screen.shop, function(tooltip)
        tooltip:AddLine("Send to Auctionator", 1, 1, 1)
        tooltip:AddLine("Makes a shopping list of what to buy. Items come off it as you buy them, and it's deleted once everything's bought.",
            0.8, 0.8, 0.8, true)
    end, "ANCHOR_TOP")

    -- Salvage (one stack per click), like the Craft button on a plan
    screen.action = UI.Button(summary, "Mill", 170, 28, function()
        local state, t = screen.actionState, screen.target
        if not (state and state.enabled and t) then return end
        PerformCraftState(state, { recipeID = state.recipeID, profession = t.profession or "Inscription" }, function()
            if screen.target == t and screen:IsVisible() then screen:Update() end
        end)
    end)
    screen.action:SetPoint("BOTTOMRIGHT", screen.shop, "TOPRIGHT", 0, 8)
    UI.Style(screen.action, "highlight", "borderGold")
    screen.action.label:SetTextColor(addon:Color("gold"))
    screen.action:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    UI.SetTooltip(screen.action, function(tooltip)
        local state = screen.actionState
        if not state then return end
        tooltip:AddLine(state.label or "Salvage", 1, 1, 1)
        for _, line in ipairs(state.notes or {}) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
        for _, line in ipairs(state.blockers or {}) do tooltip:AddLine(line, 1, 0.6, 0.2, true) end
    end, "ANCHOR_TOP")

    local function SetAction(state, label)
        screen.actionState = state
        screen.action:SetLabel((state and state.label) or label or "Salvage")
        local enabled = state ~= nil and state.enabled == true
        screen.action:SetEnabled(enabled)
        screen.action:SetAlpha(enabled and 1 or 0.5)
    end

    local function Clear(message)
        for _, f in ipairs({ screen.cost, screen.worth, screen.profit }) do
            f.value:SetText("-")
            f.value:SetTextColor(addon:Color("dim"))
            f.note:SetText("")
        end
        screen.warnLine:SetText("")
        screen.compareLine:SetText(message or "")
        screen.compareLine:SetTextColor(addon:Color("muted"))
        screen.spendLine:SetText("")
        screen.noteLine:SetText("")
        screen.shop:Disable()
        screen.shop:SetAlpha(0.5)
        SetAction(nil)
    end

    function screen:Open(target, quantity)
        screen.target = target
        local remembered = ui.salvageBatch and ui.salvageBatch[target.itemID]
        screen.qty:SetText(tostring(quantity or remembered or 100))
        screen.list:ScrollToTop()
    end

    function screen:Update()
        local t = screen.target
        if not t then return end
        local mine = t.charKey == addon.charKey
        screen.useHave:SetChecked(ui.planUseOnHand ~= false)
        screen.useHave:SetShown(mine)
        screen.queued = addon:FindQueueEntry(t.charKey, nil, nil, nil, t.itemID)
        screen.queue:SetLabel(screen.queued and "Update queue" or "Add to queue")
        screen.verbLabel:SetText(t.verb)
        screen.title:SetText((t.profession and addon:ProfessionIconText(t.profession) or "") .. t.verb .. " " .. t.name)
        local sub = {}
        if t.estimated then table.insert(sub, "yields are an estimate") end
        if not mine then table.insert(sub, "on " .. CharName(t.charKey)) end
        screen.subtitle:SetText(table.concat(sub, ", "))

        local quantity = tonumber(screen.qty:GetText()) or 0
        if quantity <= 0 then
            screen.current = nil
            screen.list:SetItems({})
            screen.casts:SetText("")
            Clear("Enter how many to " .. t.verb:lower() .. ".")
            return
        end

        local plan = addon:BuildSalvagePlan(t.itemID, quantity, mine and ui.planUseOnHand ~= false)
        screen.current = plan
        local found = plan.row.salvageRow
        local s = found and found.salvage
        local perCast = s and s.perCast or 1
        local verb = t.verb:lower()
        local castsText = string.format("%d %s at %d each", plan.crafts, verb .. (plan.crafts == 1 and "" or "s"), perCast)
        if plan.casts - plan.crafts >= 1 then
            castsText = castsText .. string.format(", about %.0f with resourcefulness", plan.casts)
        end
        if quantity % perCast ~= 0 then
            castsText = castsText .. string.format(". %d at a time, so %d won't be used", perCast, quantity % perCast)
        end
        screen.casts:SetText(castsText)

        -- Rows, and what each output costs by salvaging (the cost split by
        -- AH value, so it's comparable with buying it)
        local unit = s and s.unitPrice
        local toBuy = math.max(quantity - plan.have, 0)
        local items = { { itemID = t.itemID, name = t.name, amount = quantity, have = plan.have, toBuy = toBuy,
                          unit = unit, total = unit and unit * quantity } }
        local value, allPriced = 0, #plan.outputs > 0
        for _, o in ipairs(plan.outputs) do
            if o.value then value = value + o.value else allPriced = false end
        end
        for _, o in ipairs(plan.outputs) do
            local item = { output = true, itemID = o.itemID, name = o.name, amount = o.quantity,
                           unit = o.value and o.quantity > 0 and o.value / o.quantity or nil, total = o.value }
            if allPriced and value > 0 and unit and o.quantity > 0 then
                item.millUnit = plan.cost * (o.value / value) / o.quantity
            end
            table.insert(items, item)
        end
        screen.list:SetItems(items)

        -- Figures
        if unit then
            screen.cost.value:SetText(Money(plan.cost))
            screen.cost.value:SetTextColor(addon:Color("text"))
            screen.cost.note:SetText(string.format("%s each, AH price %s", Money(unit), addon:PriceAgeText(t.itemID)))
            screen.cost.note:SetTextColor(addon:Color("muted"))
        else
            screen.cost.value:SetText("-")
            screen.cost.value:SetTextColor(addon:Color("dim"))
            screen.cost.note:SetText("No AH price for " .. t.name .. ". Scan with Auctionator.")
            screen.cost.note:SetTextColor(addon:Color("warning"))
        end
        if value > 0 then
            screen.worth.value:SetText(Money(value) .. (allPriced and "" or "+"))
            screen.worth.value:SetTextColor(addon:Color("text"))
            screen.worth.note:SetText(allPriced and string.format("%s after the AH cut", Money(value * (1 - AH_CUT)))
                or "Some of what comes out has no price.")
        else
            screen.worth.value:SetText("-")
            screen.worth.value:SetTextColor(addon:Color("dim"))
            screen.worth.note:SetText(#plan.outputs == 0 and ("No yields yet: " .. verb .. " some first.") or "No AH prices yet.")
        end
        if plan.profit then
            screen.profit.value:SetText(Signed(plan.profit))
            screen.profit.value:SetTextColor(addon:Color(addon:MoneyColor(plan.profit)))
            screen.profit.note:SetText(plan.cost > 0 and string.format("%.0f%% ROI, selling what comes out", plan.profit / plan.cost * 100) or "")
        else
            screen.profit.value:SetText("-")
            screen.profit.value:SetTextColor(addon:Color("dim"))
            screen.profit.note:SetText("")
        end

        -- Buy or salvage: buying the same outputs on the AH (no AH cut) vs
        -- the cost of salvaging for them
        if allPriced and value > 0 and unit then
            local cheaper = plan.cost < value
            local pct = math.abs(value - plan.cost) / value * 100
            local text
            if #plan.outputs == 1 then
                local o = items[2]
                text = string.format("%sing makes %s for about %s each, vs %s each to buy: %s is %.0f%% cheaper.",
                    t.verb, MaterialName(o.itemID, o.name), Money(o.millUnit), Money(o.unit),
                    cheaper and verb .. "ing" or "buying", pct)
            else
                text = string.format("Buying what comes out would cost about %s, vs %s to %s it: %s is %.0f%% cheaper.",
                    Money(value), Money(plan.cost), verb, cheaper and verb .. "ing" or "buying", pct)
            end
            screen.compareLine:SetText(text)
            screen.compareLine:SetTextColor(addon:Color(cheaper and "profit" or "warning"))
        else
            screen.compareLine:SetText("")
        end

        -- Warnings: the list changed since it was sent, estimate or thin
        -- yields, an old price
        local warn
        local more, extra = addon:ShoppingListChanges(plan)
        if more and #more > 0 then
            warn = "The plan changed since you sent the list (it needs more now): send it again."
        elseif extra and #extra > 0 then
            warn = "The plan changed since you sent the list (it needs less now)."
        elseif found and found.whyNot then
            warn = found.whyNot
        else
            local _, source, age = addon:GetAHPriceInfo(t.itemID)
            if (source == "Auctionator" or source == "Blizzard") and (age or 0) >= 1 then
                warn = "Old AH price for " .. t.name .. ". Scan the AH first, or the numbers may change after you buy."
            end
        end
        screen.warnLine:SetText(warn or "")
        screen.warnLine:SetTextColor(addon:Color("warning"))

        local buy = plan.buyAH[1]
        screen.spendLine:SetText(buy and string.format("To buy on the AH: %d %s, about %s", buy.quantity, t.name, Money(buy.cost))
            or "Nothing to buy: you have enough.")
        screen.shop:SetEnabled(buy ~= nil)
        screen.shop:SetAlpha(buy and 1 or 0.5)

        local profession = t.profession or "Inscription"
        if mine and not ProfessionOpen({ profession = profession }) then
            -- Opens the profession first, like a craft plan's button
            screen.noteLine:SetText("")
            local recipeID = KnownSalvageRecipe(t.itemID, profession)
            SetAction({ label = "Open " .. profession, enabled = recipeID ~= nil, open = true, recipeID = recipeID,
                        notes = { string.format("Opens %s so you can %s from here.", profession, verb) },
                        blockers = recipeID and {} or { string.format("Open %s yourself (press K), then %s from here.", profession, verb) } })
        elseif mine then
            screen.noteLine:SetText("")
            SetAction(addon.SalvageState(t.itemID, t.name, quantity, t.verb))
        else
            screen.noteLine:SetText(string.format("Planned with %s's yields. Log in on them to %s.", CharName(t.charKey), verb))
            SetAction(nil, t.verb)
        end
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
            local tier = first.row.tier and (addon:TierIconText(first.row.tier, first.tierCount) .. " ") or ""
            local who = best.key ~= addon.charKey and (" on " .. best.name) or ""
            bar.best:SetText(string.format("Best use: %dx %s%s%s  %s", first.crafts, tier, first.recipe.outputName, who,
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
                local tier = p.row.tier and (addon:TierIconText(p.row.tier, p.tierCount) .. " ") or ""
                Line(tooltip, string.format("    %dx %s%s", p.crafts, tier, p.recipe.outputName),
                    string.format("%d conc, %s", p.points, Signed(p.gain)), "profit")
                if p.row.description then Note(tooltip, "        " .. p.row.description) end
            end
        end
        Why(tooltip, "Mixes of lower and higher quality materials are compared for each craft, to get the most gold from your concentration.", "gold")
        Why(tooltip, "Extra = profit on top of crafting the same thing without concentration. Each craft is capped at about a day of that item's sales.")
        if bar.target then addon:ClickHint(tooltip, "Click to plan the best use") end
    end, "ANCHOR_TOP")
    return bar
end

-- Right-click a craft: queue it (as many as its plan last had) or open
-- its item page
local function RowMenu(item)
    local recipe = item.recipe
    local quantity = GoldsmithDB.ui2.planQty and GoldsmithDB.ui2.planQty[recipe.recipeID]
        or math.max(math.floor(recipe.outputQty or 1), 1)
    local concentrate = item.info and item.info.concentrate == true or false
    local tier = item.info and item.info.tier
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle(recipe.outputName)
        local queued = addon:FindQueueEntry(item.charKey, recipe.recipeID, tier, concentrate)
        root:CreateButton(queued and string.format("In %s's queue (%d): set to %d", CharName(item.charKey), queued.quantity, quantity)
            or string.format("Add %d to %s's queue", quantity, CharName(item.charKey)), function()
            addon:AddToQueue(item.charKey, recipe.recipeID, quantity, tier, concentrate)
            addon:Notify("info", "Queued %d %s for %s.", quantity, recipe.outputName, CharName(item.charKey))
            addon.RefreshWindow()
        end)
        root:CreateButton("Item page", function() addon:OpenItem(recipe.outputName, item.itemID) end)
        root:CreateDivider()
        if addon:IsIgnored(recipe.outputItemID) then
            root:CreateButton("Stop ignoring", function()
                addon:SetIgnored(recipe.outputItemID, recipe.outputName, false)
            end)
        else
            root:CreateButton("Ignore this item", function()
                addon:SetIgnored(recipe.outputItemID, recipe.outputName, true)
            end)
        end
    end)
end

-- Right-click a salvage row: queue a batch (asks how many) or open the
-- input's page
local function SalvageMenu(item)
    local s = item.salvage
    local verb = item.recipe.outputName:match("^(%S+)") or "Salvage"
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle(verb .. " " .. s.inputName)
        local queued = addon:FindQueueEntry(item.charKey, nil, nil, nil, s.inputID)
        root:CreateButton(queued and string.format("In %s's queue (%d): change...", CharName(item.charKey), queued.quantity)
            or string.format("Add a batch to %s's queue...", CharName(item.charKey)), function()
            addon:AskSalvageBatch(item.charKey, s.inputID, s.inputName, verb)
        end)
        root:CreateButton("Item page", function() addon:OpenItem(s.inputName, s.inputID) end)
    end)
end

-- The Show filter's choices (ui.craftsShow)
local SHOW_CHOICES = {
    { value = "all", label = "All crafts" },
    { value = "profitable", label = "Profitable" },
    { value = "recommended", label = "Recommended" },
    -- Recipes you could learn (GetUnlearnedRows)
    { value = "unlearned", label = "Not learned yet" },
}

-- The Show filter, with the old Profitable only checkbox carried over.
-- Recommended until changed (user, 2026-10-07).
local function CraftsShow()
    local ui = GoldsmithDB.ui2
    return ui.craftsShow or (ui.profitableOnly and "profitable") or "recommended"
end

local function ShowLabel(value)
    for _, choice in ipairs(SHOW_CHOICES) do
        if choice.value == value then return choice.label end
    end
    return "All crafts"
end

local function Create(parent)
    local ui = GoldsmithDB.ui2
    view = { focus = nil }

    local list = CreateFrame("Frame", nil, parent)
    list:SetAllPoints()
    view.listScreen = list

    -- Show: all crafts, profitable ones, or recommended ones (profitable and
    -- they sell: what Do this next would suggest). ui.craftsShow; the old
    -- Profitable only checkbox (ui.profitableOnly) carries over.
    view.show = UI.Dropdown(list, 220, function(root)
        root:CreateTitle("Show")
        for _, choice in ipairs(SHOW_CHOICES) do
            root:CreateRadio(choice.label, function() return CraftsShow() == choice.value end, function()
                ui.craftsShow = choice.value
                ui.profitableOnly = nil
                addon.RefreshWindow()
            end)
        end
        -- Gear (armor, weapons, profession tools): often clutter, so it can
        -- be hidden, or shown on its own (ui.craftsGear = nil / "hide" /
        -- "only")
        root:CreateDivider()
        root:CreateTitle("Gear")
        for _, choice in ipairs({ { nil, "All items" }, { "hide", "Hide gear" }, { "only", "Gear only" } }) do
            root:CreateRadio(choice[2], function() return ui.craftsGear == choice[1] end, function()
                ui.craftsGear = choice[1]
                addon.RefreshWindow()
            end)
        end
        -- Ignored items (right-click a craft) are hidden unless this is on
        root:CreateDivider()
        root:CreateCheckbox(string.format("Show ignored (%d)", #addon:GetIgnoredItems()),
            function() return ui.craftsShowIgnored == true end,
            function()
                ui.craftsShowIgnored = (not ui.craftsShowIgnored) or nil
                addon.RefreshWindow()
            end)
    end)

    -- Only what the character you're on can make, with their own stats
    view.onlyMine = UI.Checkbox(list, "Only " .. (addon.char.name or "me"), function(checked)
        ui.craftsOnlyMine = checked or nil
        addon.RefreshWindow()
    end)

    -- Search by craft or salvage name. Ignores the expansion and Profitable
    -- only filters, so whatever you type for is found. Waits for a pause in
    -- typing: a search costs every matching craft in every expansion.
    view.search = ""
    view.searchBox = UI.SearchBox(list, 170, "Find a craft", function(text)
        view.search = text
        if view.searchTimer then view.searchTimer:Cancel() end
        view.searchTimer = C_Timer.NewTimer(text == "" and 0 or SEARCH_DELAY, function()
            view.searchTimer = nil
            view.list:ScrollToTop()
            addon.RefreshWindow()
        end)
    end)
    -- Far left, before the filters (the focus chip takes its place while
    -- it's hidden). The expansion filter is in the window's header.
    view.searchBox:SetPoint("TOPLEFT", 0, 0)
    -- Then Show and Only <name> to its right (anchored here: the search box
    -- has to exist first)
    view.show:SetPoint("LEFT", view.searchBox, "RIGHT", 16, 0)
    view.onlyMine:SetPoint("LEFT", view.show, "RIGHT", 16, 0)

    -- "Showing: Best crafts right now (5)  x" after following a link from
    -- the Overview; click to show everything again
    view.focusChip = UI.Button(list, "", 260, 24, function()
        view.focus = nil
        addon.RefreshWindow()
    end)
    UI.Style(view.focusChip, "highlight", "borderGold")
    view.focusChip:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    view.focusChip.label:SetTextColor(addon:Color("gold"))
    -- In place of the search and filters, which don't apply while it's
    -- showing
    view.focusChip:SetPoint("TOPLEFT", 0, 0)

    view.concSwitch = UI.Switch(list, "Concentration", function(on)
        ui.craftsConcentration = on or nil
        addon.RefreshWindow()
    end)
    view.concSwitch:SetPoint("TOPRIGHT", 0, 0)

    -- Hover explanations for the two options (hooked, so the widgets keep
    -- their own hover colors)
    local function Explain(frame, fill)
        UI.SetTooltip(frame, fill, "ANCHOR_BOTTOM")
    end
    Explain(view.concSwitch, function(tooltip)
        tooltip:AddLine("Concentration", 1, 1, 1)
        Why(tooltip, "Adds the ways to craft with concentration: how much each uses (Conc) and the extra gold it earns per point (g/conc).")
        Why(tooltip, "The bar at the bottom shows your concentration on all characters and the best way to spend it.")
        Why(tooltip, "Goldsmith tries mixes of lower and higher quality materials. Better materials cost more but need less concentration, so the same concentration can make more crafts. It picks the mix that earns the most.", "gold")
    end)
    Explain(view.show, function(tooltip)
        -- One short line per choice; the detail is in each craft's hover
        tooltip:AddLine("Show", 1, 1, 1)
        local minROI = addon:Setting("minROI")
        Line(tooltip, "Recommended", "profitable, and it sells")
        Line(tooltip, "Not learned yet", "recipes to go learn, and what they'd make")
        Line(tooltip, "Profitable", minROI > 0 and string.format("%d%%+ ROI at AH prices", minROI) or "makes gold at AH prices")
        Line(tooltip, "All crafts", "everything you can make")
        Line(tooltip, "Show ignored", "adds your ignored crafts")
        tooltip:AddLine(" ")
        Why(tooltip, "Recommended is what Do this next suggests. Pick older expansions at the top to judge their crafts on sales too. Hover a greyed-out craft for why it isn't recommended.")
    end)
    Explain(view.searchBox, function(tooltip)
        tooltip:AddLine("Find a craft", 1, 1, 1)
        Why(tooltip, "Type two letters or more. Matches crafts by name, and salvage by what's salvaged or what it gives, across every expansion and whether or not they're profitable.")
        Why(tooltip, "Only " .. (addon.char.name or "me") .. " and the profession picked at the top still apply. Escape clears it.")
    end)
    Explain(view.onlyMine, function(tooltip)
        tooltip:AddLine(view.onlyMine.label and view.onlyMine.label:GetText() or "Only this character", 1, 1, 1)
        Why(tooltip, "Shows only the crafts the character you're logged in on knows, costed with their own stats, even where another character makes it better.")
        Why(tooltip, "Untick to see every character's crafts, each made by whoever makes it best.")
    end)
    view.count = UI.Text(list, "label", "dim", "RIGHT")
    view.count:SetPoint("RIGHT", view.concSwitch, "LEFT", -12, 0)

    view.list = UI.List(list, {
        rowHeight = ROW_HEIGHT,
        fill = FillCraftRow,
        tooltip = CraftTooltip,
        onClick = function(item, button)
            -- Shift-click: the item's page (salvage: what's salvaged), or
            -- its link into chat while you're typing a message
            if IsShiftKeyDown() then
                local itemID = item.salvage and item.salvage.inputID or item.itemID
                local name = item.salvage and item.salvage.inputName or item.recipe.outputName
                local link = itemID and select(2, C_Item.GetItemInfo(itemID))
                -- Old and newer names of the chat functions
                local chat = (ChatEdit_GetActiveWindow and ChatEdit_GetActiveWindow())
                    or (ChatFrameUtil and ChatFrameUtil.GetActiveWindow and ChatFrameUtil.GetActiveWindow())
                local insert = (ChatFrameUtil and ChatFrameUtil.InsertLink) or ChatEdit_InsertLink
                if chat and link and insert then
                    insert(link)
                else
                    addon:OpenItem(name, itemID)
                end
                return
            end
            if item.unlearned then
                addon:OpenItem(item.recipe.outputName, item.itemID)
            elseif item.salvage then
                -- Click for the mill planner; right-click to queue a
                -- batch or open the item's page
                if button == "RightButton" and MenuUtil and MenuUtil.CreateContextMenu then
                    SalvageMenu(item)
                else
                    addon:OpenSalvagePlan(item.salvage.inputID, item.charKey)
                end
            elseif button == "LeftButton" then
                addon:OpenCraftPlan(item.recipe, item.info, item.charKey)
            elseif MenuUtil and MenuUtil.CreateContextMenu then
                RowMenu(item)
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
    view.salvage = CreateSalvageScreen(parent)
    -- The planner's crafts finished or stopped (CraftDone.lua)
    addon.PlanCraftsDone = function(recipeID, made) view.plan:CraftsDone(recipeID, made) end

    function view:CloseSalvage()
        local returnTab = view.salvage.target and view.salvage.target.returnTab
        view.salvage.target = nil
        view.salvage.current = nil
        view.salvage.qty:ClearFocus()
        if returnTab then addon:ShowTab(returnTab) else addon.RefreshWindow() end
    end

    -- Back goes to the Queue tab for a plan opened from there
    function view:ClosePlan()
        local returnTab = view.plan.plan and view.plan.plan.returnTab
        view.plan.plan = nil
        view.plan.current = nil
        view.plan.qty:ClearFocus()
        if returnTab then addon:ShowTab(returnTab) else addon.RefreshWindow() end
    end
    return view
end

local function Refresh(v, state)
    local ui = GoldsmithDB.ui2
    if pending then
        if pending.plan then
            v.salvage.target = nil
            v.plan:Open(pending.plan, pending.quantity)
        elseif pending.salvage then
            v.plan.plan = nil
            v.salvage:Open(pending.salvage, pending.quantity)
        else
            v.plan.plan = nil
            v.salvage.target = nil
            v.focus = pending.focus
            v.list:ScrollToTop()
        end
        pending = nil
    end

    local planning = v.plan.plan ~= nil
    local salvaging = not planning and v.salvage.target ~= nil
    v.plan:SetShown(planning)
    v.salvage:SetShown(salvaging)
    v.listScreen:SetShown(not planning and not salvaging)
    -- Runs as work over frames (Window.lua): the part being worked out
    -- shows "Loading" if it takes more than a frame; the filters and
    -- search box above the list stay usable
    local loading = state.loading
    if planning then
        loading:Begin(v.plan)
        v.plan:Update()
        loading:Done(v.plan)
        return
    elseif salvaging then
        loading:Begin(v.salvage)
        v.salvage:Update()
        loading:Done(v.salvage)
        return
    end
    loading:Begin(v.list)

    local concOn = ui.craftsConcentration == true
    -- The Cost column says which cost it shows (Settings: Show cost as)
    local costLabel = addon:Setting("costMode") == "worst" and "Worst cost" or "Cost"
    SIMPLE_COLUMNS[2].label, CONC_COLUMNS[2].label = costLabel, costLabel
    v.concSwitch:SetOn(concOn)
    v.show:SetLabel("Show: " .. ShowLabel(CraftsShow())
        .. (ui.craftsGear == "hide" and ", no gear" or ui.craftsGear == "only" and ", gear only" or ""))
    v.onlyMine:SetChecked(ui.craftsOnlyMine == true)

    -- Following a link from the Overview shows just those crafts, whatever
    -- the filters say
    local focus = v.focus
    v.show:SetShown(not focus)
    v.onlyMine:SetShown(not focus)
    v.searchBox:SetShown(not focus)
    local needle = not focus and v.search:lower():match("^%s*(.-)%s*$") or ""
    -- One letter matches nearly everything, so a search starts at two
    local searching = #needle >= SEARCH_MIN_LETTERS
    local show = (focus or searching) and "all" or CraftsShow()
    -- Not learned yet: its own rows (searchable); concentration works as
    -- for your crafts (most enchant profit is with it)
    local unlearnedMode = not focus and CraftsShow() == "unlearned"
    local rowOpts = {
        concentration = concOn,
        profitableOnly = show ~= "all",
        onlyMine = not focus and ui.craftsOnlyMine,
        showExpansion = not focus and not searching
            and function(expansionID) return addon:IsExpansionShown(expansionID) end or nil,
        shownExpansions = true,
        -- A search finds ignored crafts too, so they're easy to get back
        showIgnored = ui.craftsShowIgnored or searching,
        -- Names are matched before costing, so only matches are worked out
        match = searching and function(names)
            for _, name in pairs(names) do
                if name:lower():find(needle, 1, true) then return true end
            end
        end or nil,
    }
    local items
    if unlearnedMode then
        items = addon:GetUnlearnedRows(state.profession, rowOpts)
    else
        items = addon:GetCraftRows(state.profession, rowOpts)
        -- Milling, prospecting and other salvage, as rows of their own
        for _, item in ipairs(addon:GetSalvageRows(state.profession, rowOpts)) do
            table.insert(items, item)
        end
    end
    -- Recommended: what Do this next would suggest (no reason against it,
    -- every material priced)
    if show == "recommended" then
        local kept = {}
        for _, item in ipairs(items) do
            if not item.whyNot and not item.info.partial then table.insert(kept, item) end
        end
        items = kept
    end
    local mixed = searching or focus ~= nil
    if not mixed then
        local shown = 0
        for _, expansionID in ipairs(addon:GetFilterExpansions()) do
            if addon:IsExpansionShown(expansionID) then shown = shown + 1 end
        end
        mixed = shown > 1
    end
    -- Gear filter (Show menu): salvage is never gear
    if ui.craftsGear and not focus then
        local only, kept = ui.craftsGear == "only", {}
        for _, item in ipairs(items) do
            local gear = not item.salvage and addon:IsGear(item.itemID)
            if (only and gear) or (not only and not gear) then table.insert(kept, item) end
        end
        items = kept
    end
    if mixed then
        for _, item in ipairs(items) do item.labelExpansion = true end
    end
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
    v.list:SetColumns(addon:AvailableColumns(concOn and CONC_COLUMNS or SIMPLE_COLUMNS))
    if unlearnedMode then
        v.list:SetEmptyText(searching and "No recipe you haven't learned matches."
            or string.format("No %s recipes left to learn found yet. Open each profession's window on the character who has it, so Goldsmith can see which recipes you haven't learned.",
                addon:GetExpansionName(addon:GetCurrentExpansion())))
    elseif next(GoldsmithDB.recipes) == nil then
        v.list:SetEmptyText("No recipes yet. Open your professions so Goldsmith can load them.")
    elseif focus then
        v.list:SetEmptyText("Those crafts aren't worth it any more. Click the button above to see everything.")
    elseif searching then
        v.list:SetEmptyText(ui.craftsOnlyMine
            and "No craft matches. " .. (addon.char.name or "This character") .. " may not know it: untick Only " .. (addon.char.name or "me") .. ", or pick All professions at the top."
            or "No craft matches. Try All professions at the top, or open the profession that makes it so Goldsmith can load the recipe.")
    elseif show == "recommended" then
        v.list:SetEmptyText("Nothing to recommend right now: no craft both makes a profit and sells. Set Show to Profitable or All crafts, or pick more expansions at the top.")
    else
        v.list:SetEmptyText(ui.craftsOnlyMine
            and "No crafts match. This character may not know these recipes: untick Only " .. (addon.char.name or "me") .. ", pick All expansions at the top, or set Show to All crafts."
            or "No crafts match. Set Show to All crafts, or pick All expansions or All professions at the top.")
    end
    v.list:SetItems(items)
    v.count:SetText(string.format("%d craft%s", #items, #items == 1 and "" or "s"))
    loading:Done(v.list)

    v.budget:SetShown(concOn)
    v.footnote:SetShown(not concOn)
    if concOn then
        loading:Begin(v.budget)
        v.budget:Set(addon:GetConcentrationOverview(state.profession))
        loading:Done(v.budget)
    else
        local partial = false
        for _, item in ipairs(items) do
            if item.info.partial then partial = true break end
        end
        v.footnote:SetText((unlearnedMode
            and "Recipes you haven't learned, costed with your skill today. Hover one for where to learn it, click for its page."
            or "Hover a craft for how its cost is worked out, click it to plan, right-click to queue it, shift-click for its page.")
            .. (partial and "   + some material costs unknown,  * profit is at most this" or ""))
    end
end

-- Clicking the Crafts tab again: out of a plan or a focused list, back to
-- the whole list at the top (filters stay as set)
local function Reset(v)
    v.plan.plan, v.plan.current = nil, nil
    v.plan.qty:ClearFocus()
    v.salvage.target, v.salvage.current = nil, nil
    v.salvage.qty:ClearFocus()
    v.focus = nil
    v.list:ScrollToTop()
end

addon:RegisterView("crafts", { create = Create, refresh = Refresh, reset = Reset, ownLoading = true })

-- Keep the planner's Craft button current while it's showing: the
-- profession opening or closing, bags changing as you craft or buy,
-- concentration being spent. A short wait lets the profession window
-- finish opening, and groups bursts of bag updates.
local craftEvents = CreateFrame("Frame")
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "BAG_UPDATE_DELAYED", "CURRENCY_DISPLAY_UPDATE" }) do
    craftEvents:RegisterEvent(event)
end
local craftUpdatePending = false
craftEvents:SetScript("OnEvent", function()
    if craftUpdatePending or not view then return end
    local planShown = view.plan and view.plan:IsVisible() and view.plan.plan
    local salvageShown = view.salvage and view.salvage:IsVisible() and view.salvage.target
    if not (planShown or salvageShown) then return end
    craftUpdatePending = true
    C_Timer.After(0.3, function()
        craftUpdatePending = false
        if view.plan:IsVisible() and view.plan.plan then view.plan:Update() end
        if view.salvage:IsVisible() and view.salvage.target then view.salvage:Update() end
    end)
end)

_G.Goldsmith = addon
