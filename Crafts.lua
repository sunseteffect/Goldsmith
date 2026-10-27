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
-- Before a price only your realm's listings back (DoubtPrice, Pricing.lua)
local UNCONFIRMED_ICON = "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:0|t "
local TOP_HEIGHT = 26
local FOOTER_HEIGHT = 44
-- 172 (was 158): the notes under Cost, Sells for and Profit wrap onto a
-- second line instead of being cut off (user, 2026-10-10)
local PLAN_SUMMARY_HEIGHT = 172
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
-- ROI as a whole percent, rounded toward zero: 14.9% shown as "15%" looked
-- like it met a 15% minimum it didn't (2026-10-09)
local function Roi(margin)
    return string.format("%d%%", margin >= 0 and math.floor(margin) or math.ceil(margin))
end

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

-- The tier goes before the name, so a long name cut short never hides it.
-- iconSize: the list uses a bigger one (TIER_ICON_LIST)
local TIER_ICON_LIST = 18
local function ItemText(item, iconSize)
    local tier = item.tier and (addon:TierIconText(item.tier, item.info.tierCount, iconSize) .. " ") or ""
    if item.salvage then
        -- The quality of what's salvaged: gold and silver Mana Lily were two
        -- "Mill 10 Mana Lily" rows (user, 2026-10-23)
        local t, count = addon:GetItemTier(item.salvage.inputID)
        tier = t and (addon:TierIconText(t, count, iconSize) .. " ") or ""
    elseif not item.tier then
        -- A refine: the one quality it makes
        local fixed, fixedCount = addon:FixedTier(item.recipe)
        tier = fixed and (addon:TierIconText(fixed, fixedCount, iconSize) .. " ") or ""
    end
    return addon:ProfessionIconText(item.recipe.profession) .. tier .. item.recipe.outputName
end

-- A material's name with its quality icon. fallbackName is used while the
-- game hasn't loaded the item (asked to load it for next time).
local function MaterialName(itemID, fallbackName)
    local tier, tierCount = addon:GetItemTier(itemID)
    local name = C_Item.GetItemNameByID(itemID) or fallbackName or addon:KnownItemName(itemID)
    return (tier and (addon:TierIconText(tier, tierCount) .. " ") or "") .. name
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
        -- A search lists every expansion: the ones picked at the top first
        if (a.pinned or false) ~= (b.pinned or false) then return a.pinned or false end
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
    -- A daily or out of charges, right after the name: profitable but not
    -- makeable yet (user, 2026-10-17; from what was saved, no game call)
    local cooldown = not item.salvage and item.recipe and addon.GetRecipeCooldown
        and addon:GetRecipeCooldown(item.recipe.recipeID, item.charKey)
    if cooldown and not cooldown.ready then
        label = label .. "  " .. UNCONFIRMED_ICON .. addon:Colorize(cooldown.readyAt
            and ("on cooldown " .. addon:CooldownWait(cooldown.readyAt)) or "on cooldown", "warning")
    end
    cells.item:SetText(ItemText(item, TIER_ICON_LIST) .. label .. (item.ignored and addon:Colorize("  ignored", "dim") or ""))
    -- A stripe at the row's left edge in the quality's color (gold, silver,
    -- bronze for gear's middle tiers): with the bigger icon, two cues, so
    -- silver and gold rows of the same item tell apart at a glance (user,
    -- 2026-10-10: try it, to review)
    if not row.tierStripe then
        row.tierStripe = row:CreateTexture(nil, "ARTWORK")
        row.tierStripe:SetWidth(3)
        row.tierStripe:SetPoint("TOPLEFT", 0, -4)
        row.tierStripe:SetPoint("BOTTOMLEFT", 0, 4)
    end
    local tierColor = addon:TierColor(item.tier, item.info and item.info.tierCount)
    if tierColor then
        row.tierStripe:SetColorTexture(addon:Color(tierColor))
        row.tierStripe:SetAlpha(item.whyNot and 0.45 or 0.9)
        row.tierStripe:Show()
    else
        row.tierStripe:Hide()
    end
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
        -- ~ marks a price Goldsmith adjusted (an undercut or shelf listing
        -- replaced by the usual price); the hover says why
        -- A warning icon marks a price only your realm's listings back (DoubtPrice)
        cells.price:SetText((info.unconfirmed and UNCONFIRMED_ICON or addon:PriceAdjusted(info.priceNote) and "~" or "")
            .. Money(info.price))
        if info.priceAge and info.priceAge >= STALE_PRICE_DAYS then
            cells.price:SetTextColor(addon:Color("warning"))
        end
    elseif info.doubtPrice then
        -- A lone listing far above cost that nothing can check (DoubtPrice)
        cells.price:SetText(UNCONFIRMED_ICON .. Money(info.doubtPrice))
        cells.price:SetTextColor(addon:Color("dim"))
    else
        cells.price:SetText("-")
        cells.price:SetTextColor(addon:Color("dim"))
    end

    if info.profit then
        cells.profit:SetText(Signed(info.profit) .. (info.partial and "*" or ""))
        cells.profit:SetTextColor(addon:Color(addon:MoneyColor(info.profit)))
        cells.margin:SetText(info.margin and Roi(info.margin) or "-")
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
    if not info.demand and addon:IsBox(item.itemID, item.recipe and item.recipe.outputItemID) then
        cells.demand:SetText(addon.OPENS_TEXT)
        cells.demand:SetTextColor(addon:Color("text"))
    elseif level then
        cells.demand:SetText(addon:SellLevelText(level))
        cells.demand:SetTextColor(addon:Color(addon:SellLevelColor(level)))
    elseif not info.demand and (info.unconfirmed or info.doubtPrice) then
        -- Goes with the price's warning icon: "-" read as "doesn't sell". Gray, not
        -- orange: Slow is a known risk, this is unknown (the icon warns)
        -- (user, 2026-10-16)
        cells.demand:SetText("No data")
        cells.demand:SetTextColor(addon:Color("muted"))
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
            info.margin and (" (" .. Roi(info.margin) .. " ROI)") or "", info.partial and ", at least" or ""),
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

-- When the best quality is out of reach for the crafter: the skill it
-- needs, the most they reach (any mix, with concentration), and what it
-- sells for. Its row is simply missing otherwise, which looked like a bug
-- on unlearned Midnight enchants (gold needs 480; user, 2026-10-16).
-- Concentration only closes part of the gap, so more of it doesn't help.
local function TopTierOutOfReach(tooltip, item)
    local c = GoldsmithDB.characters[item.charKey]
    local td = c and c.tierData and c.tierData[item.recipe.recipeID]
    if not (td and td.qualities and td.scenarios) then return end
    local top = #td.qualities
    local bestTier, bestSkill, needed = 0, 0, nil
    for _, s in ipairs(td.scenarios) do
        if s.tier > bestTier then bestTier, bestSkill = s.tier, 0 end
        if s.tier == bestTier and (s.skill or 0) > bestSkill then
            bestSkill, needed = s.skill or 0, s.upper
        end
    end
    if bestTier >= top or item.tier ~= bestTier or not needed then return end
    local name = top == 2 and "Gold" or "The top quality"
    tooltip:AddLine(" ")
    Note(tooltip, string.format("%s needs %d skill: %s reach %d at best, with concentration and better materials. More concentration won't close it, more skill will.",
        name, needed, item.charKey == addon.charKey and "you" or CharName(item.charKey), bestSkill), "warning")
    local out = td.outputs and td.outputs[top]
    local price = out and out.itemID and addon:GetMarketPrice(out.itemID)
    if price then Line(tooltip, name .. " sells for", Money(price)) end
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
    do
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
    local box = addon:IsBox(item.itemID, item.recipe and item.recipe.outputItemID)
    if info.price then
        local stale = info.priceAge and info.priceAge >= STALE_PRICE_DAYS
        -- A box can't be listed: what's inside is what it's worth (user,
        -- 2026-10-27)
        Line(tooltip, info.priceSource == "Contents" and "Worth" or "AH price", Money(info.price))
        -- Where the price came from, on its own row: "Goldsmith Data, 09:15",
        -- "Auctionator, 2 days old", "TSM". From the row's own price, since
        -- gear tiers are priced by link, not by their shared item ID.
        Line(tooltip, "Price data", addon:PriceSourceText(item.itemID, info.priceSource, info.priceAge, info.priceNote),
            (stale or addon:PriceAdjusted(info.priceNote)) and "warning" or "muted")
        addon:AddPriceNote(tooltip, info.priceNote)
        if info.unconfirmed then Note(tooltip, addon:UnconfirmedPriceText(info), "warning") end
        Why(tooltip, "The lowest listing, or the usual price when the lowest is far below it (a stray cheap listing) or far above what sells (a shelf price). A ~ before the price means it was adjusted.")
        Line(tooltip, "Profit each", string.format("%s%s", Signed(info.profit),
            info.margin and (" (" .. Roi(info.margin) .. " ROI)") or ""), addon:MoneyColor(info.profit))
        Why(tooltip, "AH price after the 5% cut, minus the cost. ROI is that profit as a share of the cost: 100% doubles your gold.")
    elseif info.doubtPrice then
        Line(tooltip, "AH listing", Money(info.doubtPrice), "dim")
        Note(tooltip, addon:UnconfirmedPriceText(info) .. " Goldsmith Data covers materials and consumables, not gear or tools.", "warning")
    elseif box then
        Note(tooltip, "No worth yet: open one and Goldsmith notes what's inside.")
    else
        Note(tooltip, "No AH price yet. Scan the AH.")
    end
    -- After the price, not under "How": next to "all silver" it read as
    -- part of the mix (user, 2026-10-16)
    if item.tier then TopTierOutOfReach(tooltip, item) end
    -- Without TSM: how well it sells (Goldsmith Data)
    local sellLevel = not addon:HasTSM() and addon:GetSellLevel(item.itemID)
    if not info.demand and box then
        local _, opened = addon:GetBoxValue(item.itemID)
        Line(tooltip, "Sells", "Bound: you open it")
        if opened then
            Why(tooltip, string.format("Its profit is the average of what came out over %d openings, and those sell.", opened))
        end
    elseif sellLevel then
        Line(tooltip, "Sells", addon:SellLevelText(sellLevel) .. " (Goldsmith Data, last 7 days)",
            addon:SellLevelColor(sellLevel))
        Why(tooltip, "From the region's AH every hour: how often it sells, and how much is listed near the lowest price. Sells: often, with little stock ahead of you. Slow: now and then. Hardly sells: rarely.")
    end
    if info.demand then
        Line(tooltip, "Sold per day", string.format("%s (%s)", addon:FormatDemand(info.demand), info.demandSource or "?"),
            addon:DemandColor(info.demand, item.itemID))
        Why(tooltip, info.demandSource == "your sales"
            and "How many you've sold a day lately. The whole market sells more."
            or "TSM: average sold per day in your region by TSM users, shared by every seller.")
    end
    if info.saleRate then
        Line(tooltip, "Sale rate", addon:FormatSaleRate(info.saleRate) .. " of listings sell",
            addon:SaleRateColor(info.saleRate))
        Why(tooltip, "TSM: the share of TSM players' auctions that sell. A low rate means listings often sit.")
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
                -- No price: "no price profit each" read as garbled (Bouquet of
                -- Herbs, only silver ones opened, user 2026-10-27)
                Note(tooltip, string.format("%s tier needs concentration: about %d per craft, %s. Turn on Concentration (top right) to see it.",
                    addon:TierIconText(row.tier, row.tierCount), row.concentration or 0,
                    row.profit and (Signed(row.profit) .. " profit each") or "no price yet"), "conc")
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
    addon:ShiftClickHint(tooltip, "Shift-click for the item's page, or to search the AH while it's open")
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
    { key = "vendor", method = "Vendor", label = "Buy from vendor" },
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

-- Concentration a crafted material's tier row spends per item, and the gold
-- each point saves against buying it (or, with no AH price, its own extra
-- per point). nil when the craft doesn't use concentration.
local function CraftConcValue(node)
    local craft = node.options and node.options.craft
    local row = craft and craft.tierRow
    if not (row and row.concentrate and row.concentration and row.concentration > 0) then return nil end
    local perItem = row.concentration / math.max(row.outputPerCraft or 1, 1)
    local buy = node.options.buy and node.options.buy.unit
    if buy and buy > craft.unit then
        return (buy - craft.unit) / perItem, perItem, buy
    end
    return row.concentrationValue, perItem, nil
end

-- Finishing reagents (Pricing.lua ChooseFinishing): the one a plan uses is
-- a material row; with none worth it, a row says so, so the choice can
-- still be seen and changed (user, 2026-10-17)
local function FinishingName(entry)
    return entry.slot and entry.slot.names[1] or C_Item.GetItemNameByID(entry.option.itemID) or "a finishing reagent"
end

-- What one does: "multicraft 2.7% to 100.0%"
local function FinishingEffect(choice, o)
    local parts = {}
    for _, key in ipairs({ "multicraft", "resourcefulness", "ingenuity" }) do
        local from, to = choice.base[key] or 0, o[key] or 0
        if math.abs(to - from) > 0.05 then
            table.insert(parts, string.format("%s %.1f%% to %.1f%%", key, from, to))
        end
    end
    return #parts > 0 and table.concat(parts, ", ") or "no change to multicraft or resourcefulness"
end

local function BestFinishing(choice)
    local best
    for _, e in ipairs(choice.options) do
        if e.value and e.value > 0 and (not best or e.value > best.value) then best = e end
    end
    return best
end

local function FinishingMenu(choice)
    if not (choice and MenuUtil and MenuUtil.CreateContextMenu) then return end
    local function Pick(value)
        addon:SetFinishingPick(choice.recipeID, value)
        addon.Refresh()
    end
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle("Finishing reagent")
        local best = BestFinishing(choice)
        root:CreateRadio(string.format("Goldsmith's pick (%s)", best and FinishingName(best) or "none, not worth it"),
            function() return choice.yours == nil end, function() Pick(nil) end)
        root:CreateRadio("None", function() return choice.yours == false end, function() Pick(false) end)
        for _, e in ipairs(choice.options) do
            local itemID = e.option.itemID
            root:CreateRadio(string.format("%s (%s per craft)", FinishingName(e), e.value and Signed(e.value) or "no price"),
                function() return choice.yours == itemID end, function() Pick(itemID) end)
        end
    end)
end

local function FillFinishingRow(row, node)
    local cells, choice = row.cells, node.finishingChoice
    cells.item:SetText("Finishing reagent: " .. addon:Colorize(choice.yours == false and "none (your pick)"
        or "none", "muted"))
    for _, key in ipairs({ "need", "have", "each", "total" }) do
        cells[key]:SetText("-")
        cells[key]:SetTextColor(addon:Color("dim"))
    end
    cells.source:SetText("None")
    cells.source:SetTextColor(addon:Color("muted"))
end

local function FillPlanRow(row, node)
    if node.finishingRow then return FillFinishingRow(row, node) end
    local cells = row.cells
    local indent = string.rep("    ", node.depth - 1) .. (node.depth > 1 and "> " or "")
    local quality = node.qualityTier and (addon:TierIconText(node.qualityTier, node.tierCount or 2) .. " ") or ""
    if not node.qualityTier then
        -- One quality only, as a refine's material: from what's known of it
        local tier, tierCount = addon:GetItemTier(node.itemID)
        quality = tier and (addon:TierIconText(tier, tierCount) .. " ") or ""
    end
    -- Crafted on someone else (a Jewelcrafting vial in an Alchemy plan), and
    -- what its concentration earns: on the row, not only in the hover (user,
    -- 2026-10-10)
    local extra = ""
    local best = node.best
    if best and best.method == "Craft" and node.toGet > 0 then
        local parts = {}
        if best.crafterKey and best.crafterKey ~= addon.charKey then
            local c = GoldsmithDB.characters[best.crafterKey]
            table.insert(parts, "on " .. (c and c.name or "another character"))
        end
        local value = CraftConcValue(node)
        if value then
            table.insert(parts, addon:Colorize(Money(value) .. "/conc", addon:ConcentrationValueColor(value)))
        end
        if node.concShort and node.concNote then
            table.insert(parts, addon:Colorize(string.format("a craft needs %d concentration", node.concNote.perCraft), "warning"))
        end
        if #parts > 0 then extra = addon:Colorize("  · ", "dim") .. addon:Colorize(table.concat(parts, ", "), "gold") end
    elseif node.concNote and node.toGet > 0 then
        -- Would be crafted, but its crafter is out of concentration now
        extra = addon:Colorize("  · ", "dim") .. addon:Colorize(string.format("%s has %s concentration, a craft needs %d",
            node.concNote.name, node.concNote.available and tostring(node.concNote.available) or "too little",
            node.concNote.perCraft), "warning")
    end
    if node.finishing and node.finishingChoice then
        extra = extra .. addon:Colorize("  · ", "dim") .. addon:Colorize(node.finishingChoice.yours
            and "finishing, your pick" or "finishing", "gold")
    end
    cells.item:SetText(indent .. quality .. node.name .. extra)
    cells.need:SetText(Whole(node.need))
    -- Gold you hold counted for this silver row: a gold icon after the count
    local goldIcon = node.gold and (" " .. addon:TierIconText(node.tierCount or 2, node.tierCount or 2)) or ""
    cells.have:SetText(node.have > 0 and (Whole(node.have) .. goldIcon) or "-")
    if node.have <= 0 then cells.have:SetTextColor(addon:Color("dim")) end
    if best then
        -- * marks your own choice (right-click) rather than the cheapest
        -- Salvage says how ("Prospect", "Crush"), not "Mill" for everything
        if node.toGet <= 0 and node.have > 0 then
            -- Nothing left to get: say so, not how you'd get more (gemdust
            -- turned from "Crush" to "Buy" once crushed, 2026-10-09)
            cells.source:SetText("From stock")
            cells.source:SetTextColor(addon:Color("muted"))
        else
            cells.source:SetText((best.verb or best.method) .. (node.options.override and "*" or ""))
            cells.source:SetTextColor(addon:Color(METHOD_COLORS[best.method] or "text"))
        end
        -- What you hold at what you paid (NodeCost, Planner.lua)
        local unit = node.paidTotal and node.need > 0 and node.paidTotal / node.need or best.unit
        cells.each:SetText(Money(unit))
        -- Priced on what's expected to be used up (node.use, the craft's own
        -- materials), so the totals add up to the craft's cost
        cells.total:SetText(Money(unit * (node.use or node.need)))
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
-- Every finishing reagent tried and what each earns per craft
local function FinishingTooltip(tooltip, choice)
    tooltip:AddLine(" ")
    tooltip:AddLine("Finishing reagents, per craft", 1, 1, 1)
    for _, e in ipairs(choice.options) do
        local r, g, b = addon:Color(e.value and addon:MoneyColor(e.value) or "dim")
        tooltip:AddDoubleLine(FinishingName(e) .. (e.picked and " (used)" or ""),
            e.value and Signed(e.value) or "no price", 0.8, 0.8, 0.8, r, g, b)
        addon:Explain(tooltip, "    " .. FinishingEffect(choice, e.option)
            .. (e.unit and (", costs " .. Money(e.unit * e.option.quantity)) or ""))
        -- Learned from your crafts with it (Pricing.lua FinishingCrafted):
        -- on the line itself, not only with Ctrl
        if e.learnedCrafts then
            tooltip:AddLine(string.format("    about %.1f more items a craft, from %d of your crafts with it",
                e.extraItems, e.learnedCrafts), 0.6, 0.6, 0.6)
        end
    end
    if not choice.priced then
        Note(tooltip, "No AH price for what this makes, so none is used: its extra items can't be valued.", "warning")
    end
    Why(tooltip, "Per craft: the extra items its multicraft makes and the materials its resourcefulness saves, minus what it costs. Its multicrafts are counted as ordinary ones until your crafts show otherwise.")
    if choice.yours ~= nil then Note(tooltip, "Your pick. Right-click to change it.") end
end

local function PlanTooltip(tooltip, node)
    if node.finishingRow then
        tooltip:AddLine("Finishing reagent: none", 1, 1, 1)
        FinishingTooltip(tooltip, node.finishingChoice)
        addon:ClickHint(tooltip, "Click to choose a finishing reagent", true)
        return
    end
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
        local low, high = addon:GetMarketPrice(node.lowID, true), addon:GetMarketPrice(node.itemID, true)
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
        -- What the ones you hold cost you, which the row's each counts
        -- (Planner.lua NodeCost): 11.29g each over the AH's 11.30g needed
        -- saying why (user, 2026-10-22)
        local own = addon:GetOwnCost(node.name, nil, node.itemID)
        if own then Line(tooltip, "Yours cost you", Money(own) .. " each") end
        Line(tooltip, "To get", tostring(Whole(node.toGet)))
    end
    tooltip:AddLine(" ")
    tooltip:AddLine("Ways to get it (each)", 1, 0.82, 0)
    -- The plan's own best when it held too few to salvage (node.cheapest)
    local cheapest = node.cheapest or o.cheapest
    local function Option(option, label, detail)
        if not option then return end
        local tags = {}
        if cheapest == option then
            -- Picked for the materials you hold, not price (Planner.lua)
            local held = ((o.craftHeld and option == o.craft) or (o.millHeld and option == o.mill))
                and o.buy and o.buy.unit < option.unit
            table.insert(tags, held and "you have the materials" or "cheapest")
        end
        if node.heldTooFew and option == o.mill then table.insert(tags, "you hold too few") end
        if o.override and node.best == option then table.insert(tags, "your choice") end
        Line(tooltip, "  " .. label, Money(option.unit) .. (#tags > 0 and ("  (" .. table.concat(tags, ", ") .. ")") or ""),
            cheapest == option and "profit" or nil)
        -- Wrapped text loses the indent, so details come as short lines
        -- ("\n" between them), each indented
        for line in (detail or ""):gmatch("[^\n]+") do Note(tooltip, "    " .. line) end
    end
    Option(o.buy, "Buy on the AH", o.buy and ("AH price " .. (o.buy.ageText or "")))
    Option(o.vendor, "Vendor", o.vendor and o.vendor.detail)
    -- Another character's craft (a Jewelcrafting vial in an Alchemy plan):
    -- say whose, since the Craft button can only make it on them
    local craftDetail = o.craft and "From its cheapest materials"
    if o.craft and o.craft.crafterKey and o.craft.crafterKey ~= addon.charKey then
        local c = GoldsmithDB.characters[o.craft.crafterKey]
        craftDetail = craftDetail .. string.format("\nwith %s's skill: make it on %s", c and c.name or "another character",
            c and c.name or "them")
    end
    -- With concentration: how much, and what each point earns
    local concValue, concPerItem, buyPrice = CraftConcValue(node)
    if concValue then
        craftDetail = craftDetail .. string.format("\nuses about %d concentration each", math.floor(concPerItem + 0.5))
            .. (buyPrice and string.format("\nsaves %s a point vs buying at %s", Money(concValue), Money(buyPrice))
                or string.format("\nearns %s a point", Money(concValue)))
    end
    Option(o.craft, "Craft it", craftDetail)
    -- A herb that gives several pigments has its price split between them
    -- by AH value (Planner.lua), so say this one's part
    local millDetail
    if o.mill and (o.mill.share or 1) < 0.999 then
        millDetail = string.format("%.2f per %s\nat %.0f%% of its AH price\n(what else it gives pays the rest,\nby AH value)",
            o.mill.perHerb, o.mill.herbName, o.mill.share * 100)
    elseif o.mill then
        millDetail = string.format("%.2f per %s\nat its AH price", o.mill.perHerb, o.mill.herbName)
    end
    if o.mill and o.mill.estimateFrom then
        millDetail = millDetail .. string.format("\nestimate: the yield of %s,\nuntil you've salvaged this one", o.mill.estimateFrom)
    end
    Option(o.mill, (o.mill and o.mill.verb or "Mill") .. " it", millDetail)
    if not node.best then Note(tooltip, "  No price found. Scan the AH.", "loss") end

    -- Savings only on what can be made now: crafting held back by its
    -- crafter's concentration (Planner.lua) saves on those crafts alone, or
    -- nothing when they're all bought (user, 2026-10-10: "saves 970g" for 4
    -- vials when only 1 could be made was beside the point)
    local savedUnits = node.need
    if node.best and node.best.split then
        savedUnits = node.best.split.craftItems
    elseif node.concNote and o.cheapest ~= node.best then
        savedUnits = 0
    end
    if o.cheapest and o.buy and o.cheapest ~= o.buy and o.buy.unit > o.cheapest.unit and savedUnits > 0 then
        tooltip:AddLine(" ")
        -- A vendor is buying too: "Crafting it instead" read wrong for
        -- Cooking Spirits (user, 2026-10-24)
        local saved = Money((o.buy.unit - o.cheapest.unit) * savedUnits)
        Note(tooltip, o.cheapest.method == "Vendor"
            and string.format("The vendor instead of the AH saves %s here", saved)
            or string.format("%s it instead of buying saves %s here",
                o.cheapest.method == "Mill" and Gerund(o.cheapest.verb or "Mill") or "Crafting", saved),
            "profit")
    end
    -- Held back by concentration: say how much of it can be crafted now
    if node.concNote then
        local craftable = node.best and node.best.split and node.best.split.craftItems or 0
        Note(tooltip, string.format("%s has %s concentration, enough to craft %d of %d now (a craft needs %d to start).",
            node.concNote.name, node.concNote.available and tostring(node.concNote.available) or "too little",
            math.floor(craftable + 0.5), math.ceil(node.toGet - 0.0001), node.concNote.perCraft), "warning")
    end
    if o.override and o.cheapest and node.best ~= o.cheapest then
        Note(tooltip, string.format("Your choice (%s) costs %s more here", node.best.verb or node.best.method,
            Money((node.best.unit - o.cheapest.unit) * node.need)), "warning")
    end
    if node.finishing and node.finishingChoice then
        FinishingTooltip(tooltip, node.finishingChoice)
        addon:ClickHint(tooltip, "Click for its item page")
        addon:RightClickHint(tooltip, "Right-click to use another finishing reagent, or none")
        addon:ShiftClickHint(tooltip, "Shift-click to search the AH for it (or link it in chat)")
        return
    end
    addon:ClickHint(tooltip, "Click for its item page")
    addon:RightClickHint(tooltip, "Right-click to choose how to get it")
    addon:ShiftClickHint(tooltip, "Shift-click to search the AH for it (or link it in chat)")
end

-- Right-click a material: pick how to get it. The choice applies to that
-- item in every plan until changed back to the cheapest way. The cheapest
-- way is marked on its own line rather than listed again on a line of its
-- own (user, 2026-10-19: "Cheapest way (Mill, 3.05g)" above "Salvage it
-- (3.05g each)"; it also named the method, Mill, not the item's verb).
-- Picking that line clears the choice, so it follows the cheapest way as
-- prices change.
local function PlanMenu(node, screen)
    local o = node.options
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(UIParent, function(_, root)
        root:CreateTitle(node.name)
        -- Crafting from what you hold can be picked over a cheaper buy;
        -- the plan's own best when it held too few to salvage
        local cheapest = node.cheapest or o.cheapest
        local held = ((o.craftHeld and cheapest == o.craft) or (o.millHeld and cheapest == o.mill))
            and o.buy and o.buy.unit < cheapest.unit
        for _, m in ipairs(METHOD_LABELS) do
            local option = o[m.key]
            if option then
                local label = m.key == "mill" and ((option.verb or "Mill") .. " it") or m.label
                local text = string.format("%s (%s each)", label, Money(option.unit))
                local isCheapest = option == cheapest
                if isCheapest then
                    text = text .. (held and ", best: you have the materials" or ", cheapest")
                end
                root:CreateRadio(text,
                    function() return o.override == m.method or (o.override == nil and isCheapest) end,
                    function()
                        local choices = screen:Choices(true)
                        choices[node.itemID] = (not isCheapest) and m.method or nil
                        if choices.salvageFrom then choices.salvageFrom[node.itemID] = nil end
                        screen:ChoicesChanged()
                    end)
            end
        end
        -- Which item to salvage for it: what you've salvaged, and others in
        -- your bags the same spell takes (user, 2026-10-22: recycle the
        -- potions I don't care about)
        local list = o.millList
        if list and (#list > 1 or not o.mill) then
            local verb = (o.mill or list[1]).verb or "Salvage"
            local sub = root:CreateButton(verb .. " which item")
            for _, m in ipairs(list) do
                local tags = { m.noPrice and "no price" or (Money(m.unit) .. " each") }
                if m.held > 0 then table.insert(tags, "you have " .. m.held) end
                if m.estimateFrom then table.insert(tags, "estimate") end
                -- Its quality icon: two Silvermoon Health Potions looked the same
                local tier, tierCount = addon:GetItemTier(m.herbID)
                if not tier and C_TradeSkillUI.GetItemCraftedQualityByItemInfo then
                    local ok, t = pcall(C_TradeSkillUI.GetItemCraftedQualityByItemInfo, m.herbID)
                    if ok and t and t > 0 then tier, tierCount = t, 2 end
                end
                local icon = tier and (" " .. addon:TierIconText(tier, tierCount)) or ""
                sub:CreateRadio(m.herbName .. icon .. " (" .. table.concat(tags, ", ") .. ")",
                    function() return o.override == "Mill" and o.mill ~= nil and o.mill.herbID == m.herbID end,
                    function()
                        local choices = screen:Choices(true)
                        choices[node.itemID] = "Mill"
                        choices.salvageFrom = choices.salvageFrom or {}
                        choices.salvageFrom[node.itemID] = m.herbID
                        screen:ChoicesChanged()
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
        root:CreateButton("Reset my choices", function()
            local choices = screen:Choices()
            if choices then wipe(choices) end
            if GoldsmithDB.ui2.useHeldGold then wipe(GoldsmithDB.ui2.useHeldGold) end
            screen:ChoicesChanged()
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
            if e.scenario == p.scenario then
                -- A mix that isn't a row: with the recipe's other mixes and
                -- its tier's sales, or the plan had no "Why this mix" bar
                -- (to-do Sterling Alloy, user 2026-10-16)
                local mine = {}
                for k, v in pairs(e) do mine[k] = v end
                mine.scenarios = rows[1].scenarios
                for _, t in ipairs(rows) do
                    if t.tier == e.tier then
                        mine.demand, mine.demandSource, mine.saleRate = t.demand, t.demandSource, t.saleRate
                        break
                    end
                end
                return mine
            end
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
-- selectedRecipeID: the recipe Goldsmith last picked in the profession
-- window (see the end of SyncProfessionWindow); opening a plan picks it
-- again even if it's the same one.
local selectedRecipeID

function addon:OpenCraftPlan(recipe, info, charKey, quantity, returnTab, crafts)
    selectedRecipeID = nil
    pending = {
        crafts = crafts,
        plan = {
            recipe = recipe, charKey = charKey or addon:GetCrafter(recipe.recipeID) or addon.charKey,
            tier = info and info.tier, concentrate = info and info.concentrate == true or false,
            scenario = info and info.scenario, returnTab = returnTab,
            -- A queued crafting order: planned and changed as that entry
            order = info and info.order,
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
    elseif recipeID ~= selectedRecipeID then
        -- Picking the recipe sets up a fresh form; fill it in once that's
        -- done, so the window's own defaults don't replace the plan's
        selectedRecipeID = recipeID
        pcall(page.SelectRecipe, page, info)
        C_Timer.After(0.1, function() pcall(Apply) end)
    end
    -- Else the player moved to another recipe after Goldsmith picked this
    -- one: leave the window alone. Picking it again on every change of
    -- materials or count expanded the categories they'd collapsed (a
    -- friend's report, 2026-10-16)
end

-- Picked again after the profession closes and opens
local selectedFrame = CreateFrame("Frame")
selectedFrame:RegisterEvent("TRADE_SKILL_CLOSE")
selectedFrame:SetScript("OnEvent", function() selectedRecipeID = nil end)

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


-- Materials whose AH price is missing or old: an Auctionator scan a day or
-- more old, Goldsmith Data two or more (it's released about once a day, so
-- a day old is normal). Every quality of the recipe's own materials is
-- checked, not just what the plan buys: the best mix can switch to a
-- quality whose price was out of date once buying rescans it. Vendor
-- items are skipped.
local STALE_DATA_DAYS = 2
-- The one rule for an old price (the planner, salvage and the queue all
-- use it; salvage and the queue had Goldsmith Data old at a day, 2026-10-14)
function addon:IsPriceOld(source, age)
    return (source == "Auctionator" and (age or 0) >= 1)
        or (source == "Blizzard" and (age or 0) >= STALE_DATA_DAYS)
end

local function StalePrices(plan)
    local seen, stale = {}, {}
    local function Check(itemID)
        if not itemID or seen[itemID] then return end
        seen[itemID] = true
        -- Soulbound materials (Stabilized Derivate) never have an AH price
        if addon:GetVendorPrice(itemID) or addon:CanAuction(itemID) == false then return end
        local price, source, age = addon:GetAHPriceInfo(itemID)
        if not price or addon:IsPriceOld(source, age) then
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
        -- The materials by name ("hover Send" pointed at the Send to
        -- Auctionator button, which meant nothing without Auctionator)
        local parts = {}
        for i, item in ipairs(w.stale) do
            if i > 2 then
                table.insert(parts, string.format("%d more", #w.stale - 2))
                break
            end
            table.insert(parts, MaterialName(item.itemID))
        end
        w.text = string.format("Old or missing AH prices: %s. Search the AH for %s before buying.",
            table.concat(parts, ", "), #w.stale == 1 and "it" or "them")
    else
        return nil
    end
    return w
end

-- Materials: enough to start each craft (resourcefulness may give some
-- back along the way, so you may get further than this). Adds notes and
-- blockers to state; returns how many crafts the materials allow.
-- What's short is given for all the crafts asked for, not one: "4 Tavern
-- Fixings" for one craft was bought, then the queue of 5 stopped again
-- (user, 2026-10-19: the goal is to finish the queue).
local function CheckMaterials(state, needs, crafts)
    local short, stuck, allowed = {}, false, crafts
    for itemID, per in pairs(needs) do
        local have = C_Item.GetItemCount(itemID, true, false, true, true) or 0
        local possible = math.floor(have / per)
        if possible < crafts then
            -- Bought and still in the mailbox: say so, it's why it's
            -- "missing" (error review, 2026-10-23; user forgot the mail once)
            local mail = addon.InMailCount and addon:InMailCount(itemID) or 0
            -- Bought for you by Buy next on another character, not mailed yet
            local away, holder = 0, nil
            if addon.OnTheWayFor then away, holder = addon:OnTheWayFor(addon.charKey, itemID) end
            table.insert(short, string.format("%d %s%s", per * crafts - have, MaterialName(itemID),
                mail > 0 and string.format(" (%d in your mailbox)", mail)
                or away > 0 and string.format(" (%d bought on %s, not mailed yet)", away, holder or "another character")
                or ""))
        end
        if possible == 0 then
            stuck = true
        elseif possible < allowed then
            allowed = possible
        end
    end
    local all = string.format("%d craft%s", crafts, crafts == 1 and "" or "s")
    if stuck then
        table.insert(state.blockers, string.format("Missing for %s: %s.", all, table.concat(short, ", ")))
        return crafts
    elseif allowed < crafts then
        table.insert(state.notes, string.format("Materials for %d of the %d crafts. Still to get for all %s: %s.",
            allowed, crafts, all, table.concat(short, ", ")))
    end
    return allowed
end

-- Gold you hold standing in for silver you're short of (GetCraftReagents):
-- say so, and if the game says it lifts the craft a tier, that too
local function SwapNotes(state, swapped, tierInfo)
    if not swapped then return end
    for _, s in ipairs(swapped.swaps) do
        table.insert(state.notes, string.format(s.down and "Uses %d silver %s you have in place of gold (same tier)."
            or "Uses %d gold %s you have in place of silver.", s.units, s.name or "material"))
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

-- Button label: "Mill 15 Tranquility Bloom", shortened if it won't fit;
-- and the whole step (state.step), for the line over the button
local function StepLabel(verb, count, name)
    local full = string.format("%s %d %s", verb, count, name)
    local label = full
    if #label > 22 then label = string.format("%s %d", verb, count) end
    return label, full
end

-- A salvage step (mill, prospect, crush): salvage enough items for what's
-- still needed, from one stack at a time. node.best = { herbID, herbName,
-- perHerb (outputs per item), verb ("Mill" unless given) }.
local function MillStepState(node, state)
    local herbID, herbName = node.best.herbID, node.best.herbName
    local verb = node.best.verb or "Mill"
    local lower = verb:lower()
    local record = GoldsmithDB.milling[herbID]
    local profession = node.best.profession or record and record.profession or "Inscription"
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
        elseif addon.InMailCount and addon:InMailCount(herbID) > 0 then
            -- Bought with Buy next, still in the mailbox (Shop.lua)
            table.insert(state.blockers, string.format("Get %s from your mailbox to %s it.", herbName, lower))
        else
            table.insert(state.blockers, string.format("Not enough %s to %s (%d at a time). Buy next at the AH buys it.",
                herbName, lower, perCast))
        end
        state.label, state.step = StepLabel(verb, wanted * perCast, herbName)
        return state
    end
    local inBags = C_Item.GetItemCount(herbID) or 0
    table.insert(state.notes, string.format("Uses %d %s per %s; you have %d in your bags.", perCast, herbName, lower, inBags))
    if casts < wanted and inBags >= (casts + 1) * perCast then
        table.insert(state.notes, verb .. "s one stack per click.")
    end
    state.salvage = { recipeID = recipeID, casts = casts, location = location, profession = profession }
    state.enabled = #state.blockers == 0
    state.label, state.step = StepLabel(verb, casts * perCast, herbName)
    return state
end

-- A queued salvage batch (Queue.lua): salvage `count` more of an item
-- With the profession closed, the button opens it at the salvage recipe
-- you last used on the item (the game only lists salvage recipes while
-- it's open), as a craft's button opens its recipe; it was a greyed-out
-- "Open Inscription" (user, 2026-10-23)
function addon.SalvageState(itemID, name, count, verb)
    local node = { toGet = count, best = { herbID = itemID, herbName = name, perHerb = 1, verb = verb } }
    local state = MillStepState(node, { label = verb, blockers = {}, notes = {} })
    local record = GoldsmithDB.milling[itemID]
    local profession = record and record.profession or "Inscription"
    if not ProfessionOpen({ profession = profession }) and C_TradeSkillUI.OpenRecipe then
        local recipeID = addon.KnownSalvageRecipe and addon.KnownSalvageRecipe(itemID, profession)
        if recipeID then
            state.label, state.enabled, state.open, state.openRecipeID = "Open " .. profession, true, true, recipeID
            state.blockers = {}
            table.insert(state.notes, string.format("Opens %s to %s %s. The game only salvages with the profession open.",
                profession, (verb or "salvage"):lower(), name))
        end
    end
    return state
end

-- A craft step: make the material, using the qualities the plan picked
-- for its own materials
-- "Needs Anvil nearby" and the like, as blockers. Walking up to it fires no
-- event, so state.nearby has it checked again every second. Material steps
-- too: Craft 24 (copper ingots for weightstones) showed with no anvil
-- nearby and failed (user, 2026-10-16).
local function CheckStation(state, recipeID)
    if not C_TradeSkillUI.GetRecipeRequirements then return end
    local ok, requirements = pcall(C_TradeSkillUI.GetRecipeRequirements, recipeID)
    for _, r in ipairs(ok and requirements or {}) do
        if not r.met then
            table.insert(state.blockers, "Needs " .. (r.name or "something") .. " nearby.")
            state.nearby = true
            state.nearbyRecipes = state.nearbyRecipes or {}
            table.insert(state.nearbyRecipes, recipeID)
        end
    end
end

-- Whether every station those recipes wanted is nearby now: the
-- every-second check asks only this, and plans again once it's true.
-- Planning again every second (the queue, and the Queue tab with it)
-- dropped frames while walking to an anvil (user, 2026-10-19).
function addon.StationsMet(recipes)
    if not (recipes and C_TradeSkillUI.GetRecipeRequirements) then return true end
    for _, recipeID in ipairs(recipes) do
        local ok, requirements = pcall(C_TradeSkillUI.GetRecipeRequirements, recipeID)
        for _, r in ipairs(ok and requirements or {}) do
            if not r.met then return false end
        end
    end
    return true
end

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
    CheckStation(state, recipe.recipeID)
    local outputPerCraft = addon:GetCraftModel(recipe)
    local wanted = math.max(math.ceil(node.toGet / math.max(outputPerCraft, 0.01) - 0.0001), 1)
    -- A tier item (gold ingot): the tier row's mix, and its concentration
    -- when only that reaches the tier; else the qualities the plan chose
    local row = node.best.tierRow
    local scenario
    if row then
        scenario = row.scenario
    else
        local chosen = {}
        for _, child in ipairs(node.children) do chosen[child.itemID] = true end
        scenario = { chosen = chosen }
    end
    local concentrate = row and row.concentrate == true
    local reagents, needs, swapped = addon:GetCraftReagents(recipe.recipeID, scenario,
        { crafts = wanted, concentrate = concentrate, tier = row and row.tier })
    if not reagents then
        table.insert(state.blockers, "The game didn't give this recipe's materials. Try closing and reopening the profession.")
        return state
    end
    SwapNotes(state, swapped, row)
    if concentrate then
        -- The full cost to start each craft, for every craft: ingenuity's
        -- refund is luck, not promised (planned 3 with 1000, only 2 started
        -- at 340 each; user 2026-10-16)
        local current = addon:GetConcentration(recipe.profession) or 0
        local full = row.scenario.concentration or row.concentration or 0
        local expected = math.max(row.concentration or full, 1)
        local affordable = full > 0 and math.floor(current / full) or math.huge
        if affordable == 0 then
            table.insert(state.blockers, string.format("Not enough concentration to make %s: %d to start, you have %d.",
                node.name, full, current))
        elseif affordable < wanted then
            table.insert(state.notes, string.format("Concentration for %d of the %d crafts.", affordable, wanted))
            wanted = affordable
        end
        table.insert(state.notes, string.format("Makes %s with concentration (about %d a craft): your materials alone don't reach that quality.",
            node.name, expected))
    end
    local crafts = CheckMaterials(state, needs, wanted)
    state.recipeID, state.reagents, state.crafts = recipe.recipeID, reagents, crafts
    state.concentrate = concentrate
    state.enabled = #state.blockers == 0 and crafts > 0
    state.label, state.step = StepLabel("Craft", crafts, node.name)
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
    -- A daily (Bouquet of Herbs) or out of charges: nothing to open or make
    -- until it's back (user, 2026-10-17)
    local cooldown = addon.GetRecipeCooldown and addon:GetRecipeCooldown(recipe.recipeID, addon.charKey, ProfessionOpen(recipe))
    if cooldown and not cooldown.ready then
        state.label = "On cooldown"
        state.onCooldown = addon:CooldownWarning(recipe.recipeID, cooldown)
        table.insert(state.blockers, state.onCooldown)
        return state
    end
    -- Short on concentration: said before "Open Alchemy", which would only
    -- have opened it to say so (user, 2026-10-24). Concentration can be
    -- read with the profession closed.
    if tierInfo and tierInfo.concentrate == true and not ProfessionOpen(recipe) then
        local current = addon:GetConcentration(recipe.profession)
        local full = tierInfo.scenario and tierInfo.scenario.concentration or tierInfo.concentration
        if current and full and full > 0 and current < full then
            table.insert(state.blockers, string.format("Not enough concentration: %d to start, you have %d.",
                full, current))
            return state
        end
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
    local steps = CollectSteps(plan.nodes, {})
    if #steps > 0 then
        return StepState(steps, plan)
    end

    CheckStation(state, recipe.recipeID)

    -- No quality tier (bags, treatises, teas): the qualities the plan
    -- picked, as the shopping list buys them. It was all lowest quality: a
    -- plan picked Tier 2 materials for a bag, held in the bags, and the
    -- button said to buy Tier 1, then the sale was costed at those (a
    -- user's report, 2026-10-25).
    local scenario = tierInfo and tierInfo.scenario
    if not tierInfo then
        local chosen = {}
        for _, node in ipairs(plan.nodes) do chosen[node.itemID] = true end
        scenario = { chosen = chosen }
    end
    local reagents, needs, swapped = addon:GetCraftReagents(recipe.recipeID, scenario,
        { crafts = plan.crafts, concentrate = tierInfo and tierInfo.concentrate == true, tier = tierInfo and tierInfo.tier })
    if not reagents then
        table.insert(state.blockers, "The game didn't give this recipe's materials. Try closing and reopening the profession.")
        return state
    end
    SwapNotes(state, swapped, tierInfo)
    state.reagents = reagents
    local crafts = plan.crafts

    -- Concentration: the full cost is needed to start each craft, and
    -- crafts are counted at it (ingenuity's refund is luck); points spent
    -- are the expected cost
    state.concentrate = tierInfo and tierInfo.concentrate == true
    if state.concentrate then
        local current = addon:GetConcentration(recipe.profession) or 0
        local full = tierInfo.scenario and tierInfo.scenario.concentration or tierInfo.concentration
        local expected = math.max(tierInfo.concentration or full, 1)
        local affordable = full > 0 and math.floor(current / full) or math.huge
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
    -- Charges: as many crafts as are ready
    if cooldown and cooldown.maxCharges and cooldown.charges < crafts then
        table.insert(state.notes, string.format("%d charge%s ready.", cooldown.charges, cooldown.charges == 1 and "" or "s"))
        crafts = cooldown.charges
    end
    state.crafts = crafts
    state.enabled = #state.blockers == 0 and crafts > 0
    state.label = string.format("Craft %d", crafts)
    -- The plan's own item (not a step): its crafts get a "Craft complete"
    -- notice (CraftDone.lua). planCrafts is the whole plan, which can be
    -- more than one batch (concentration or materials for fewer).
    state.final, state.planCrafts, state.planQuantity = true, plan.crafts, plan.quantity
    return state
end

-- Does what a CraftState says: opens the profession at the recipe (then
-- calls onOpened once it's open), mills, or crafts. Needs a click or key
-- press (the game only crafts from one).
local function PerformCraftState(state, recipe, onOpened)
    if not (state and state.enabled) then return end
    if addon:TourBlocks(state.open and ("open " .. (recipe.profession or "the profession")) or "craft") then return end
    if state.open then
        if C_TradeSkillUI.OpenRecipe then
            -- A salvage batch opens at its salvage recipe (SalvageState)
            C_TradeSkillUI.OpenRecipe(state.openRecipeID or recipe.recipeID)
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
    -- A material made for this entry (ingots for an alloy) isn't the
    -- queue's own entry for that item: 5 gold ingots made for Gloaming
    -- Alloy finished the queued "Refulgent Copper Ingot x4" to sell, and it
    -- left the queue (user, 2026-10-24). QueueCrafted skips these.
    if state.final then
        addon.materialStep = nil
    elseif state.recipeID then
        addon.materialStep = { recipeID = state.recipeID, untilTime = GetTime() + 30 + 6 * (state.crafts or 1) }
    end
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
    -- The title opens the item's page; shift-click searches the AH for it
    -- (or links it in chat), like the material rows: without Auctionator
    -- that's how to get its live price (user, 2026-10-11)
    local titleButton = CreateFrame("Button", nil, screen)
    titleButton:SetAllPoints(screen.title)
    titleButton:SetScript("OnClick", function()
        if not screen.plan then return end
        local name = screen.plan.recipe.outputName
        if IsShiftKeyDown() and addon:ShiftClickItem(screen.tierItemID, name) then return end
        addon:OpenItem(name, screen.tierItemID)
    end)
    -- The item and what it does; the click hint always shows (it's the
    -- only thing to explain here)
    UI.SetTooltip(titleButton, function(tooltip)
        if not screen.plan then return end
        tooltip:AddLine(screen.title:GetText() or screen.plan.recipe.outputName, 1, 1, 1)
        addon:AddItemDescription(tooltip, screen.tierItemID)
        addon:ClickHint(tooltip, "Click for the item's page", true)
        addon:ShiftClickHint(tooltip, "Shift-click to search the AH for it (or link it in chat)", true)
    end)
    screen.subtitle = UI.Text(screen, "small", "muted")
    screen.subtitle:SetPoint("LEFT", screen.title, "RIGHT", 10, 0)

    -- Adds this plan (how many, tier, concentration) to the crafting
    -- character's queue, or changes how many if it's already there
    -- Your choices on this plan (right-click a row): the queue entry's once
    -- it's queued, so Buy next and the queue follow them until it's
    -- crafted or removed; before that, the plan's own (see WithChoices)
    function screen:Choices(create)
        local p = screen.plan
        if not p then return nil end
        local owner = screen.queued or p
        if create and not owner.choices then owner.choices = {} end
        return owner.choices
    end

    function screen:ChoicesChanged()
        if screen.queued then addon:QueueEntryChanged() else addon.Refresh() end
    end

    screen.queue = UI.Button(screen, "Add to queue", 130, 26, function()
        local p = screen.plan
        -- The queue counts items: what these crafts are sure to make
        local quantity = p and screen:PlannedItems() or 0
        if not p or quantity <= 0 then return end
        local concentrate = screen.tierInfo and screen.tierInfo.concentrate == true or false
        local updated = addon:AddToQueue(p.charKey, p.recipe.recipeID, quantity, p.tier, concentrate)
        -- The choices made before queuing go with it
        local entry = addon:FindQueueEntry(p.charKey, p.recipe.recipeID, p.tier, concentrate)
        if entry and p.choices and next(p.choices) then
            entry.choices = CopyTable(p.choices)
            addon:QueueEntryChanged()
        end
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

    -- How many crafts, not items (user, 2026-10-12: "we usually think in
    -- crafts"; the line beside it says what they make). Remembered per
    -- recipe in ui.planCrafts; ui.planQty (items) was the old box.
    ui.planCrafts = ui.planCrafts or {}
    local makeLabel = UI.Text(screen, "body", "muted")
    makeLabel:SetPoint("TOPLEFT", 2, -44)
    makeLabel:SetText("Crafts")
    screen.qty = UI.NumberBox(screen, 70, function(crafts)
        if screen.plan and crafts and crafts > 0 then ui.planCrafts[screen.plan.recipe.recipeID] = crafts end
        screen.askedCrafts = nil
        screen.allMade = nil
        screen:Update()
    end)
    screen.qty:SetPoint("LEFT", makeLabel, "RIGHT", 10, 0)

    -- When concentration covers fewer crafts than asked for, the box shows
    -- what will be crafted and askedCrafts keeps the number asked for: the
    -- box said 2 while the plan made 1 (user, 2026-10-18; it used to keep
    -- your number). Typing a number clears it.
    function screen:AskedCrafts()
        return screen.askedCrafts or tonumber(screen.qty:GetText()) or 0
    end

    -- Items for the crafts asked for (what they're sure to make)
    function screen:PlannedItems(crafts)
        local p = screen.plan
        crafts = crafts or screen:AskedCrafts()
        if not p or crafts <= 0 then return 0 end
        return addon:WithCharacter(p.charKey, addon.ItemsForCrafts, addon, p.recipe, crafts)
    end

    -- Crafts from this screen's Craft button finished or stopped
    -- (CraftDone.lua): they come off the box, so the plan is for what's
    -- left (3 crafts, 1 done: 2). All done: 0, and the plan says so
    -- instead of offering to craft it all again.
    function screen:CraftsDone(recipeID, made, crafts)
        if not (screen.plan and screen.plan.recipe.recipeID == recipeID) or (crafts or 0) <= 0 then return end
        local left = math.max(screen:AskedCrafts() - crafts, 0)
        screen.askedCrafts = nil
        screen.qty:SetText(tostring(left))
        if left > 0 then ui.planCrafts[recipeID] = left end
        screen.allMade = left == 0 or nil
        screen:Update()
    end
    screen.crafts = UI.Text(screen, "small", "muted")
    screen.crafts:SetPoint("LEFT", screen.qty, "RIGHT", 10, 0)

    -- (A "Use materials I have" checkbox was here: always on now, user
    -- 2026-10-09. Off, the plan hid what you held and picked mixes you
    -- hadn't bought, so the Craft button blocked after shopping.)

    -- For crafts with tiers: plan the tier with or without concentration
    screen.useConc = UI.Checkbox(screen, "Use concentration", function(checked)
        local p = screen.plan
        if not p then return end
        -- The tour's steps show the plan with concentration (user, 2026-10-13)
        if addon:UsingTourData() and not checked then
            addon:Notify("info", "Concentration stays on during the tour.")
            return
        end
        p.concentrate = checked
        p.scenario = nil -- the chosen mix belongs to the other way
        screen:Update()
    end)
    screen.useConc:SetPoint("TOPRIGHT", 0, -44)
    UI.SetTooltip(screen.useConc, function(tooltip)
        tooltip:AddLine("Use concentration", 1, 1, 1)
        addon:Explain(tooltip, "Plan this tier with concentration, using the mix of material qualities that earns the most. Some tiers can only be reached with it.", 0.6, 0.6, 0.6, true)
    end)

    screen.list = UI.List(screen, {
        fill = FillPlanRow,
        tooltip = PlanTooltip,
        onClick = function(node, button)
            if node.finishingRow or (button == "RightButton" and node.finishing and node.finishingChoice) then
                FinishingMenu(node.finishingChoice)
            elseif button == "RightButton" then
                PlanMenu(node, screen)
            elseif IsShiftKeyDown() and addon:ShiftClickItem(node.itemID, node.name) then
                -- Into the AH search or chat
            else
                addon:OpenItem(node.name, node.itemID)
            end
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
        -- Click a mix to use it instead (user, 2026-10-12: use the silver
        -- you have rather than shop again for a few gold stones)
        local hit = CreateFrame("Button", nil, body)
        hit:SetPoint("TOPLEFT", 8, y + 3)
        hit:SetPoint("RIGHT", body, "LEFT", MIX_COLUMNS[#MIX_COLUMNS].right + 8, 0)
        hit:SetHeight(18)
        local glow = hit:CreateTexture(nil, "BACKGROUND")
        glow:SetAllPoints()
        glow:SetColorTexture(1, 1, 1, 0.06)
        glow:Hide()
        hit:SetScript("OnEnter", function(self) if self.entry then glow:Show() end end)
        hit:SetScript("OnLeave", function() glow:Hide() end)
        UI.SetTooltip(hit, function(tooltip, self)
            if not self.entry then return end
            if self.picked and self.yours then
                tooltip:AddLine("Your pick", 1, 1, 1)
                addon:ClickHint(tooltip, "Click to go back to Goldsmith's pick")
            elseif self.picked then
                tooltip:AddLine("Goldsmith's pick", 1, 1, 1)
            else
                tooltip:AddLine("Use this mix instead", 1, 1, 1)
                addon:ClickHint(tooltip, "Click to plan and craft with it")
            end
        end)
        hit:SetScript("OnClick", function(self)
            local p, base = screen.plan, screen.baseTierInfo
            if not (self.entry and p and base) then return end
            -- Clicking your own pick again goes back to Goldsmith's
            -- (an if, since "x and nil or y" is always y)
            local e = self.entry
            if self.picked and self.yours then e = nil end
            if self.picked and not self.yours then return end
            addon:WithCharacter(p.charKey, addon.SetPlanMix, addon, p.recipe, base, e,
                screen:PlannedItems())
            -- The queued entry follows your click, as the queue uses your
            -- pick once its Do this next mix is gone
            if screen.queued and screen.queued.prefMix then
                screen.queued.prefMix = nil
                addon:QueueEntryChanged()
            end
            screen:Update()
        end)
        row.hit = hit
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
                table.sort(candidates, function(a, b) return addon:BetterConcentration(a, b) end)
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
            and "The top %d of %d mixes that reach this tier, by gold per concentration point, then profit.%s"
            or "The top %d of %d mixes that reach this tier, cheapest first.%s", top, #candidates,
            ((tierInfo.built and " Picked: a mix in between that uses materials you have.")
            or ((tierInfo.yourPick and pickedRank) and string.format(" Using #%d, your pick.", pickedRank))
            or ((tierInfo.heldPick and pickedRank and pickedRank > 1) and string.format(" Picked #%d: it uses materials you have.", pickedRank))
            or ((tierInfo.fitPick and pickedRank) and string.format(" Picked #%d: your concentration starts every craft with it.", pickedRank))
            -- A to-do's mix (PlanConcentration): chosen for what the whole
            -- day's concentration earns, which can be a lower-ranked mix
            -- (2 gold Missives beat 1 silver with 494; user, 2026-10-18)
            or ((conc and pickedRank and pickedRank > 1)
                and string.format(" Picked #%d: earns the most from your concentration.", pickedRank))
            or "") .. " Click a mix to use it."))
        mixes.header.mix:SetText(string.format("TOP %d MIXES", top))
        mixes.header.conc:SetShown(conc)
        mixes.header.perPoint:SetShown(conc)

        -- The bar, open or closed: what was picked, in a line
        local pickedText = (tierInfo.description or "?"):gsub("^%l", string.upper)
        local pickedNumbers = conc and tierInfo.concentrationValue
            and string.format("%s per point", Money(tierInfo.concentrationValue))
            or Money(tierInfo.cost + offset) .. " each" .. (math.abs(offset) >= 100 and " with your stock" or "")
        mixes.picked:SetText(string.format("Picked: %s  %s", pickedText,
            addon:Colorize(string.format(tierInfo.yourPick and "(%s, your pick)"
                or tierInfo.heldPick and "(%s, uses materials you have)"
                or tierInfo.fitPick and "(%s, your concentration covers every craft)" or "(%s, best of %d)",
                pickedNumbers, #candidates), "muted")))
        mixes.toggle:SetText(open and "Hide" or "Compare")

        -- Rows are at AH prices, so they compare the same whichever is
        -- picked; what you hold at your cost (offset) is only in the
        -- "Picked" line and the summary. Given to every row, gold showed
        -- 5.90g with all silver picked, 14.82g once picked; given to the
        -- picked row, silver went 20.22g to 11.30g (user, 2026-10-21).
        local function Fill(row, e, label, color)
            local offset = 0
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
                Fill(row, e, picked and (text .. addon:Colorize(tierInfo.yourPick and "  (your pick)" or "  (picked)", "dim"))
                    or text, picked and "gold" or "text")
                row.hit.entry, row.hit.picked, row.hit.yours = (not e.built) and e or nil, picked, tierInfo.yourPick
            elseif baselines[i - #list] then
                -- Without concentration, each extreme and the tier it reaches
                local b = baselines[i - #list]
                Fill(row, b, string.format("Without concentration, %s makes %s", b.description,
                    addon:TierIconText(b.tier, b.tierCount)), "muted")
                row.hit.entry = nil
            else
                Clear(row)
            end
        end
        -- Open: as tall as its rows, so the materials keep the room (2
        -- mixes left half of it blank and the materials scrolled; user,
        -- 2026-10-27)
        if open then
            local used = math.min(#list + #baselines, #mixes.rows)
            height = MIX_HEIGHT - (#mixes.rows - used) * 18
            mixes:SetHeight(height)
            screen.list:SetPoint("BOTTOMRIGHT", 0, PLAN_SUMMARY_HEIGHT + 12 + height + 8)
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
        f.note:SetWordWrap(true)
        f.note:SetMaxLines(2)
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
    -- Long lists of materials wrap onto a second line (growing upward,
    -- there's room under the figures) instead of running off
    screen.warnLine:SetWordWrap(true)
    screen.warnLine:SetMaxLines(2)
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
        -- Without Auctionator the button is greyed out; the hover says
        -- what it would do (user, 2026-10-09: encourage Auctionator)
        if not addon:HasAuctionator() then
            addon:AuctionatorPitch(tooltip)
            return
        end
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
        -- So its crafts come off the box when they're done (CraftsDone)
        state.fromPlan = true
        PerformCraftState(state, p.recipe, function()
            if screen.plan == p and screen:IsVisible() then screen:Update() end
        end)
    end)
    screen.craft:SetPoint("BOTTOMRIGHT", screen.shop, "TOPRIGHT", 0, 8)
    UI.Style(screen.craft, "highlight", "borderGold")
    screen.craft.label:SetTextColor(addon:Color("gold"))
    screen.craft:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    -- A profession's crafting buff isn't on: said above the button, in case
    -- you want it first (user, 2026-10-12)
    screen.buffWarn = UI.Text(summary, "small", "warning", "RIGHT")
    screen.buffWarn:SetPoint("BOTTOMRIGHT", screen.craft, "TOPRIGHT", 0, 6)
    screen.buffWarn:SetWidth(320)
    -- In the same spot, a button for what to do first (Prep.lua): the
    -- right tool to equip, or the buff to turn on (user, 2026-10-23)
    screen.prep = UI.Button(summary, "", 260, 22, function()
        addon:RunPrep(screen.prepAction)
    end)
    -- The Craft button's size, as on the Queue tab
    screen.prep:SetPoint("BOTTOMLEFT", screen.craft, "TOPLEFT", 0, 6)
    screen.prep:SetPoint("BOTTOMRIGHT", screen.craft, "TOPRIGHT", 0, 6)
    screen.prep:SetHeight(screen.craft:GetHeight())
    screen.prep.label:SetTextColor(addon:Color("warning"))
    screen.prep:Hide()
    UI.SetTooltip(screen.prep, function(tooltip)
        local action = screen.prepAction
        if not action then return end
        tooltip:AddLine(action.label, 1, 1, 1)
        for _, line in ipairs(action.lines or {}) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
    end, "ANCHOR_TOP")
    function screen:UpdateBuffWarning()
        local p = screen.plan
        local mine = p and p.charKey == addon.charKey
        local action = mine and addon:CraftPrep(screen.craftState, p.recipe,
            screen.tierInfo and screen.tierInfo.concentrate == true) or nil
        screen.prepAction = action
        screen.prep:SetShown(action ~= nil)
        if action then addon:SetPrepLabel(screen.prep, action) end
        local name = not action and mine and addon:MissingCraftBuff(p.recipe.profession, p.recipe)
        screen.buffWarn:SetText(name and (name .. " isn't active") or "")
    end
    addon.UpdatePlanPrep = function()
        if screen:IsVisible() then screen:UpdateBuffWarning() end
    end
    local buffEvents = CreateFrame("Frame", nil, screen)
    buffEvents:RegisterUnitEvent("UNIT_AURA", "player")
    buffEvents:SetScript("OnEvent", function()
        if screen:IsVisible() then screen:UpdateBuffWarning() end
    end)

    UI.SetTooltip(screen.craft, function(tooltip)
        local state = screen.craftState
        if not state then return end
        local missing = screen.plan and screen.plan.charKey == addon.charKey
            and addon:MissingCraftBuff(screen.plan.recipe.profession, screen.plan.recipe)
        if missing then
            local r, g, b = addon:Color("warning")
            tooltip:AddLine(missing .. " isn't active. It adds crafting stats; turn it on first if you want them.",
                r, g, b, true)
        end
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
        for _, line in ipairs(state.blockers) do
            addon:AddShoppingBlocker(tooltip, line, screen.builtPlan)
        end
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
        screen:UpdateBuffWarning()
        local enabled = state ~= nil and state.enabled == true
        -- Stuck says why, as the queue does ("Needs Alchemist's Lab Bench")
        local label = state and state.label or "Craft"
        if state and not enabled and state.blockers and #state.blockers > 0 then
            label = addon:BlockedLabel(state)
        end
        screen.craft:SetLabel(label)
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
        screen.builtPlan = nil
        screen.shop:Disable()
        screen.shop:SetAlpha(0.5)
        addon:PlaceShopButton(screen.shop, screen.craft)
        SetCraftState(nil)
    end

    -- quantity: items (a to-do or "make more" decides in items), turned
    -- into the crafts they take; else the crafts last planned, or 1
    -- crafts (optional) wins over quantity: suggestions give their crafts,
    -- since items made on average (multicraft) turned 2 crafts into 3
    -- (user, 2026-10-16: 1026 concentration for a to-do of 2 weightstones)
    function screen:Open(p, quantity, crafts)
        screen.plan = p
        local given = crafts and crafts > 0 and math.floor(crafts)
        crafts = given or (quantity and quantity > 0
            and addon:WithCharacter(p.charKey, addon.CraftsForItems, addon, p.recipe, quantity))
        crafts = crafts or ui.planCrafts[p.recipe.recipeID] or 1
        screen.askedCrafts = nil
        screen.qty:SetText(tostring(crafts))
        if quantity or given then ui.planCrafts[p.recipe.recipeID] = crafts end
        screen.list:ScrollToTop()
    end

    function screen:Update()
        local p = screen.plan
        if not p then return end
        local recipe = p.recipe
        screen:UpdateBuffWarning()

        local tierInfo, tierNote = addon:WithCharacter(p.charKey, FindTierInfo, p)
        -- Using what you hold: a mix of the same tier that needs less buying,
        -- or the one you clicked (ChooseMix)
        screen.baseTierInfo = tierInfo
        -- Queued with Do this next's mix: show that one, as the queue plans
        -- and buys with it. The page picked another, so its "2 items to
        -- buy" read as the queue's while Buy next had nothing (user,
        -- 2026-10-24: Sienna Ink queued with 17 gold, shown with 20 gold)
        -- A queued order is its own entry (FindQueueEntry skips orders): a
        -- right-click Buy on its plan stayed on the plan, and Buy next
        -- still planned to craft the part (user, 2026-10-26)
        local order = p.order and addon:FindOrderEntry(p.order.orderID)
        local queued = order or (tierInfo and addon:FindQueueEntry(p.charKey, recipe.recipeID, p.tier, tierInfo.concentrate == true))
        local set = queued and queued.prefMix and addon:MixByDescription(tierInfo, queued.prefMix)
        if set then
            tierInfo = set
        elseif tierInfo then
            tierInfo = addon:WithCharacter(p.charKey, addon.ChooseMix, addon, recipe, tierInfo,
                screen:PlannedItems())
        end
        screen.tierInfo = tierInfo
        screen.tierItemID = tierInfo and tierInfo.itemID or recipe.outputItemID
        screen.queued = order or addon:FindQueueEntry(p.charKey, recipe.recipeID, p.tier,
            tierInfo and tierInfo.concentrate == true or false)
        screen.queue:SetLabel(screen.queued and "Update queue" or "Add to queue")
        -- An order's queued once, from the orders window
        screen.queue:SetShown(not p.order)
        local tierIcon = tierInfo and (addon:TierIconText(tierInfo.tier, tierInfo.tierCount) .. " ") or ""
        if not tierInfo then
            -- A refine: the one quality it makes
            local tier, tierCount = addon:FixedTier(recipe)
            tierIcon = tier and (addon:TierIconText(tier, tierCount) .. " ") or ""
        end
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

        local quantity = screen:PlannedItems()
        if quantity <= 0 then
            screen.current = nil
            screen.list:SetItems({})
            screen.crafts:SetText("")
            ClearSummary(screen.allMade and "All crafted. Enter a number to craft more." or "Enter how many crafts.")
            return
        end

        -- An order: without what the customer provides, as the queue plans it
        local planRecipe = order and addon:OrderRecipe(recipe, order.provided) or recipe
        local plan = addon:WithChoices(screen:Choices(), addon.WithCharacter, addon, p.charKey, addon.BuildPlan,
            addon, planRecipe, quantity, true, tierInfo)
        -- With concentration, plan only the crafts it covers now, like the
        -- Craft button: 2 crafts were planned and shopped for with enough
        -- for 1 (user, 2026-10-12). The box keeps your number. Counted at
        -- the full cost: ingenuity's refund is luck (user, 2026-10-16)
        local concLimit, leftover
        if tierInfo and tierInfo.concentrate then
            local current = p.charKey == addon.charKey and addon:GetConcentration(recipe.profession)
                or addon:GetCharacterConcentration(p.charKey, recipe.profession)
            local full = tierInfo.scenario and tierInfo.scenario.concentration or tierInfo.concentration
            if current and full then
                local affordable = full > 0 and math.floor(current / full) or math.huge
                if affordable > 0 and plan.crafts > affordable then
                    concLimit = { crafts = affordable, current = current }
                    local q = screen:PlannedItems(affordable)
                    local capped = addon:WithChoices(screen:Choices(), addon.WithCharacter, addon, p.charKey,
                        addon.BuildPlan, addon, planRecipe, q, true, tierInfo)
                    -- The mix for the crafts planned, not the number typed:
                    -- Make 30 picked one using less of the gold dust you
                    -- hold, though 2 crafts were planned (user, 2026-10-12)
                    local base = screen.baseTierInfo
                    local repick = base and not set and addon:WithCharacter(p.charKey, addon.ChooseMix, addon, recipe, base, q)
                    if repick and repick.scenario ~= tierInfo.scenario then
                        local again = addon:WithChoices(screen:Choices(), addon.WithCharacter, addon, p.charKey,
                            addon.BuildPlan, addon, planRecipe, q, true, repick)
                        local full2 = repick.scenario and repick.scenario.concentration or repick.concentration
                        local fits = full2 and (full2 > 0 and math.floor(current / full2) or math.huge) or 0
                        if again.crafts <= fits then
                            tierInfo, capped = repick, again
                            screen.tierInfo = repick
                        end
                    end
                    plan = capped
                elseif affordable == 0 then
                    concLimit = { crafts = 0, current = current, full = full }
                end
                -- What the concentration left after these crafts covers with
                -- a cheaper mix, as the to-do's "other mix, conc left" line
                -- (4 Sterling Alloy at 1 gold ingot, then 1 at 2 gold; user
                -- 2026-10-19)
                local usedFull = tierInfo.scenario and tierInfo.scenario.concentration or tierInfo.concentration or full
                local left = current - plan.crafts * usedFull
                if plan.crafts > 0 and left > 0 then
                    for _, e in ipairs(tierInfo.scenarios or {}) do
                        local eFull = e.scenario and e.scenario.concentration or e.concentration
                        if e.tier == tierInfo.tier and e.concentrate and eFull and eFull > 0 and eFull <= left
                            and (e.profit or 0) > 0 and e.description ~= tierInfo.description
                            and (not leftover or (e.profit or 0) > (leftover.mix.profit or 0)) then
                            leftover = { mix = e, left = math.floor(left) }
                        end
                    end
                end
            end
        end
        if order then
            -- What the order pays, not what the item sells for (Queue.lua)
            plan.revenue = (order.commission or 0) + (order.rewardsValue or 0)
            plan.profit = plan.revenue - plan.cost
            plan.margin = plan.cost > 0 and plan.profit / plan.cost * 100 or nil
        end
        screen.current = plan
        local nodes = addon:FlattenPlan(plan)
        -- Finishing reagents tried but none used: a row says so
        local finishing = plan.finishing
        if finishing and #finishing.options > 0 and #finishing.picks == 0 then
            table.insert(nodes, { finishingRow = true, finishingChoice = finishing, depth = 1,
                name = "Finishing reagent", need = 0, have = 0, toGet = 0 })
        end
        screen.list:SetItems(nodes)
        screen.crafts:SetFormattedText("about %.1f made", plan.expectedOutput)
        if concLimit and concLimit.crafts > 0 then
            -- The box shows what will be crafted (AskedCrafts)
            local asked = screen:AskedCrafts()
            screen.askedCrafts = asked
            screen.qty:SetText(tostring(plan.crafts))
            screen.crafts:SetText(screen.crafts:GetText() .. addon:Colorize(string.format(
                "  (%d asked: concentration covers %d now)", asked, plan.crafts), "warning"))
        elseif screen.askedCrafts then
            -- Back to the number asked for: concentration came back, or
            -- there's none at all now (the note below says so)
            screen.qty:SetText(tostring(screen.askedCrafts))
            screen.askedCrafts = nil
        end
        if leftover then
            -- Short: "2 gold mix" for "2 gold Refulgent Copper Ingot"
            local d = leftover.mix.description or "another mix"
            local short = d:match("^(%d+ gold)") and (d:match("^(%d+ gold)") .. " mix") or d
            screen.crafts:SetText(screen.crafts:GetText() .. addon:Colorize(string.format(
                "  ·  %d conc left: 1 more with the %s", leftover.left, short), "muted"))
        end
        if concLimit and concLimit.crafts == 0 then
            screen.crafts:SetText(screen.crafts:GetText() .. addon:Colorize(string.format(
                "  (not enough concentration now: %d to start, you have %d)", concLimit.full, concLimit.current), "warning"))
        end

        local made = math.max(plan.expectedOutput, 0.0001)
        -- The mix table, lined up with this plan's cost
        screen:UpdateMixes(tierInfo, plan.cost / made)
        screen.cost.value:SetText(Money(plan.cost) .. (plan.complete and "" or "+"))
        screen.cost.value:SetTextColor(addon:Color("text"))
        local costNote = Money(plan.cost / made) .. " each"
        -- Concentration the materials' crafts spend too, by who spends it: a
        -- gold Draught's 299 hid about 1,490 more for its gold vials on
        -- Trypttamine (2026-10-10)
        local subConc, subOrder = {}, {}
        for _, node in ipairs(nodes) do
            local best = node.best
            local row = best and best.method == "Craft" and best.tierRow
            if row and row.concentrate and (node.toGet or 0) > 0 and (row.outputPerCraft or 0) > 0 then
                local key = best.crafterKey or p.charKey
                if not subConc[key] then table.insert(subOrder, key) end
                -- The crafts the planner gave concentration to (it plans no
                -- more than the crafter has now; Planner.lua)
                local crafts = node.concCrafts or math.ceil(node.toGet / row.outputPerCraft)
                subConc[key] = (subConc[key] or 0) + crafts * row.concentration
            end
        end
        local concParts = {}
        if tierInfo and tierInfo.concentrate then
            table.insert(concParts, string.format("%d", tierInfo.concentration * plan.crafts))
        end
        for _, key in ipairs(subOrder) do
            local c = GoldsmithDB.characters[key]
            table.insert(concParts, string.format("%d%s", subConc[key],
                key ~= p.charKey and (" on " .. (c and c.name or key)) or " for materials"))
        end
        if #concParts > 0 then
            costNote = costNote .. ", about " .. table.concat(concParts, " + ") .. " concentration after ingenuity"
        end
        -- The concentration these crafts need to start, at the top too:
        -- under the cost alone it was easy to miss (user, 2026-10-16).
        -- The full cost, which is what crafts are counted at; the cost
        -- line's is the average after ingenuity gives some back.
        if tierInfo and tierInfo.concentrate then
            local full = tierInfo.scenario and tierInfo.scenario.concentration or tierInfo.concentration
            if full then
                local text = screen.subtitle:GetText() or ""
                screen.subtitle:SetText((text:gsub("^with concentration", string.format("with %d concentration",
                    math.floor(full * plan.crafts + 0.5)))))
            end
        end
        if not plan.complete then
            costNote = costNote .. ". Some materials have no price."
        elseif plan.choiceExtra and plan.choiceExtra > 0.5 then
            costNote = costNote .. ". Your choices add " .. Money(plan.choiceExtra) .. "."
        end
        screen.cost.note:SetText(costNote)
        screen.cost.note:SetTextColor(addon:Color(plan.complete and "muted" or "warning"))

        if order then
            screen.sells.value:SetText(Money(plan.revenue))
            screen.sells.value:SetTextColor(addon:Color("text"))
            screen.sells.note:SetText("The order's commission and rewards")
            screen.profit.value:SetText(Signed(plan.profit))
            screen.profit.value:SetTextColor(addon:Color(addon:MoneyColor(plan.profit)))
            screen.profit.note:SetText(plan.margin and (Roi(plan.margin) .. " ROI") or "")
            screen.profit.note:SetTextColor(addon:Color("muted"))
        elseif plan.price then
            screen.sells.value:SetText((plan.unconfirmed and UNCONFIRMED_ICON or "") .. Money(plan.revenue))
            screen.sells.value:SetTextColor(addon:Color("text"))
            local age = addon:PriceAgeText((tierInfo and tierInfo.itemID) or recipe.outputItemID)
            screen.sells.note:SetText(string.format("%s each after AH cut%s",
                Money(plan.price * (1 - AH_CUT)), age and (" · " .. age) or ""))
            screen.profit.value:SetText(Signed(plan.profit))
            screen.profit.value:SetTextColor(addon:Color(addon:MoneyColor(plan.profit)))
            screen.profit.note:SetText(plan.margin and (Roi(plan.margin) .. " ROI") or "")
            screen.profit.note:SetTextColor(addon:Color("muted"))
            -- What you hold cost clearly more or less than today: the
            -- to-do's number (today's prices) and why, in plain sight
            -- (HeldGap, Planner.lua). A gold or more, as the queue's star:
            -- a starred feast opened a plan that said nothing (2026-10-26)
            local gap, gapItem = addon:HeldGap(plan, true)
            if gap then
                local today = plan.profit + gap
                screen.profit.note:SetText(string.format("%s%s at today's prices\n%s",
                    plan.margin and (Roi(plan.margin) .. " ROI · ") or "",
                    addon:Colorize(Signed(today), addon:MoneyColor(today)), addon:HeldGapText(gap, gapItem)))
                screen.profit.note:SetTextColor(addon:Color("text"))
            end
            -- Profit counts what you hold at what you paid (Planner.lua);
            -- when selling those materials today would make clearly more
            -- than the craft, say so (user, 2026-10-22: "whatever makes me
            -- the most gold, within a threshold"; cheaper materials since
            -- don't matter, you use what you have)
            local sellMats = plan.marketCost and plan.marketCost * (1 - AH_CUT) - plan.revenue
            if sellMats and sellMats >= math.max(100000, plan.marketCost * 0.10) then
                screen.profit.note:SetText(string.format("Selling the materials instead makes about %s more today",
                    Money(sellMats)))
                screen.profit.note:SetTextColor(addon:Color("warning"))
            end
        else
            screen.sells.value:SetText("-")
            screen.sells.value:SetTextColor(addon:Color("dim"))
            screen.sells.note:SetText(plan.doubtPrice
                and string.format("Listed at %s, not counted: nothing backs it", Money(plan.doubtPrice))
                or addon:IsBox(screen.tierItemID, screen.plan and screen.plan.recipe and screen.plan.recipe.outputItemID)
                    and "No worth yet: open one and Goldsmith notes what's inside."
                or "No AH price yet. Scan the AH (Goldsmith panel beside it).")
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
                -- "Slow" alone is unclear outside the Crafts column
                local levelText = level == addon.SELL_LEVEL.slow and "Slow seller" or addon:SellLevelText(level)
                table.insert(parts, addon:Colorize(levelText, addon:SellLevelColor(level)) .. " (Goldsmith Data).")
                warn = level ~= addon.SELL_LEVEL.sells
            end
            -- Your own sales say how many you posted, not what the region
            -- buys: gold gems sell, though you sold 0.1 a day (user,
            -- 2026-10-16). When Goldsmith Data says it sells, your rate is
            -- shown as a fact, with no days' worth and no warning.
            local ownOnly = level == addon.SELL_LEVEL.sells and plan.demandSource == "your sales"
            if ownOnly and plan.demand and plan.demand > 0 then
                table.insert(parts, string.format("You've sold about %s a day.", addon:FormatDemand(plan.demand)))
            elseif plan.demand and plan.demand > 0 then
                local made = plan.expectedOutput or quantity
                local days = made / plan.demand
                -- The batch against a day's sales only when it's more
                -- than a day's worth (C29 cut, 2026-10-25)
                local worth = days >= 1.5
                    and string.format(": %d is about %.0f days' worth", math.floor(made + 0.5), days) or ""
                table.insert(parts, string.format("%s %s a day (%s)%s.",
                    level and "You sell" or "Sells", addon:FormatDemand(plan.demand), plan.demandSource or "?", worth))
                warn = warn or days > PLAN_DAYS_WARN
            end
            screen.demandLine:SetText(table.concat(parts, " "))
            screen.demandLine:SetTextColor(addon:Color(warn and "warning" or "muted"))
        elseif plan.unconfirmed then
            -- No sales data and only realm listings for the price: say so
            -- where you'd buy the materials (user, 2026-10-16)
            screen.demandLine:SetText(UNCONFIRMED_ICON .. "Price not confirmed: no sales data, only your realm's listings. Check the AH before you buy.")
            screen.demandLine:SetTextColor(addon:Color("warning"))
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
        local spendText = #plan.buyAH == 0 and "Nothing to buy on the AH"
            or string.format("AH: %d item%s, about %s",
            #plan.buyAH, #plan.buyAH == 1 and "" or "s", Money(spend))
        if live > 0 then spendText = spendText .. string.format(" (%d priced from live listings)", live) end
        if short then spendText = spendText .. ". Not enough listed for all of it." end
        screen.spendLine:SetText(spendText)
        screen.spendLine:SetTextColor(addon:Color(short and "warning" or "muted"))

        -- For the Craft button's hover (ShoppingBlocker): screen.plan is the
        -- recipe row, with no vendor list, so it said "Missing" (user, 2026-10-24)
        screen.builtPlan = plan
        if #plan.buyVendor > 0 then
            local parts = {}
            for _, entry in ipairs(plan.buyVendor) do table.insert(parts, entry.quantity .. " " .. entry.name) end
            screen.vendorLine:SetText("Vendor: " .. table.concat(parts, ", "))
            screen.vendorLine:SetTextColor(addon:Color("warning"))
        else
            screen.vendorLine:SetText("")
        end

        local canSend = #plan.buyAH > 0 and addon:HasAuctionator()
        screen.shop:SetEnabled(canSend)
        screen.shop:SetAlpha(canSend and 1 or 0.5)
        addon:PlaceShopButton(screen.shop, screen.craft)
        -- Old prices only matter while there's something to buy
        local warnings = ShoppingWarnings(plan)
        if warnings and #warnings.more == 0 and #warnings.extra == 0 and #plan.buyAH == 0 then
            warnings = nil
        end
        screen.warnings = warnings
        local state = CraftState(p, tierInfo, plan)
        -- A crafting order for this recipe in your queue: no crafting it
        -- here by accident, using the order's materials for one of your
        -- own (user, 2026-10-23). Steps before it (bars) still craft.
        if state.final and p.charKey == addon.charKey and addon:QueuedOrderFor(p.recipe.recipeID) then
            state = { enabled = false, notes = {}, orderBlocked = true,
                blockers = { "A crafting order for this is in your queue. Craft it in the game's crafting orders window, or take the order off the queue to craft one here." } }
        end
        -- On cooldown goes first, where it can't be missed
        local lines = {}
        if state.onCooldown then table.insert(lines, UNCONFIRMED_ICON .. state.onCooldown) end
        -- A spiked price, and listings that mostly expire: Felberry Figs made
        -- at 10g each sell for 1.40g, and 3% of listings sell (user, 2026-10-18)
        if plan.jumped then
            table.insert(lines, UNCONFIRMED_ICON .. plan.jumped:gsub("^%l", string.upper) .. ". Valued at the usual price.")
        end
        if plan.saleRate and plan.saleRate < addon.LOW_SALE_RATE then
            table.insert(lines, UNCONFIRMED_ICON .. string.format("Only %s of listings sell (TSM): most expire.",
                addon:FormatSaleRate(plan.saleRate)))
        end
        if warnings and warnings.text then table.insert(lines, warnings.text) end
        screen.warnLine:SetText(table.concat(lines, " "))
        SetCraftState(state)
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
-- For a queued salvage batch's button (SalvageState, above)
addon.KnownSalvageRecipe = KnownSalvageRecipe

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
        if not t then return end
        if IsShiftKeyDown() and addon:ShiftClickItem(t.itemID, t.name) then return end
        addon:OpenItem(t.name, t.itemID)
    end)
    UI.SetTooltip(titleButton, function(tooltip)
        local t = screen.target
        if not t then return end
        tooltip:AddLine(screen.title:GetText() or t.name, 1, 1, 1)
        addon:AddItemDescription(tooltip, t.itemID)
        addon:ClickHint(tooltip, "Click for the item's page", true)
        addon:ShiftClickHint(tooltip, "Shift-click to search the AH for it (or link it in chat)", true)
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
        f.note:SetWordWrap(true)
        f.note:SetMaxLines(2)
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
    screen.warnLine:SetWordWrap(true)
    screen.warnLine:SetMaxLines(2)
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
        -- Without Auctionator the button is greyed out; the hover says
        -- what it would do (user, 2026-10-09: encourage Auctionator)
        if not addon:HasAuctionator() then
            addon:AuctionatorPitch(tooltip)
            return
        end
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
        addon:PlaceShopButton(screen.shop, screen.action)
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

        local plan = addon:BuildSalvagePlan(t.itemID, quantity, mine)
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
            -- Where the buying price came from (not the selling checks)
            screen.cost.note:SetText(string.format("%s each, AH price %s", Money(unit), addon:PriceAgeText(t.itemID, true)))
            screen.cost.note:SetTextColor(addon:Color("muted"))
        else
            screen.cost.value:SetText("-")
            screen.cost.value:SetTextColor(addon:Color("dim"))
            screen.cost.note:SetText("No AH price for " .. t.name .. ". Scan the AH (Goldsmith panel beside it).")
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
                -- Gerund: "Salvageing" (2026-10-22)
                text = string.format("%s makes %s for about %s each, vs %s each to buy: %s is %.0f%% cheaper.",
                    Gerund(t.verb), MaterialName(o.itemID, o.name), Money(o.millUnit), Money(o.unit),
                    cheaper and Gerund(verb) or "buying", pct)
            else
                text = string.format("Buying what comes out would cost about %s, vs %s to %s it: %s is %.0f%% cheaper.",
                    Money(value), Money(plan.cost), verb, cheaper and Gerund(verb) or "buying", pct)
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
            if addon:IsPriceOld(source, age) then
                warn = "Old AH price for " .. t.name .. ". Scan the AH first, or the numbers may change after you buy."
            end
        end
        screen.warnLine:SetText(warn or "")
        screen.warnLine:SetTextColor(addon:Color("warning"))

        local buy = plan.buyAH[1]
        screen.spendLine:SetText(buy and string.format("AH: %d %s, about %s", buy.quantity, t.name, Money(buy.cost))
            or "Nothing to buy: you have enough.")
        local canSend = buy ~= nil and addon:HasAuctionator()
        screen.shop:SetEnabled(canSend)
        screen.shop:SetAlpha(canSend and 1 or 0.5)
        addon:PlaceShopButton(screen.shop, screen.action)

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

-- Crafts worth concentration that their sales left out of every plan
-- (GetConcentrationOverview's capped), with the character's name, most
-- gold per point first
local function CappedConcentration(conc)
    local list = {}
    for _, row in ipairs(conc.rows) do
        for _, c in ipairs(row.capped or {}) do
            table.insert(list, { recipe = c.recipe, row = c.row, tierCount = c.tierCount, demand = c.demand,
                demandSource = c.demandSource, held = c.held, name = row.name })
        end
    end
    table.sort(list, function(a, b) return a.row.concentrationValue > b.row.concentrationValue end)
    return list
end

-- Why one was held back (Insights.lua, shared with the Overview)
local function CappedReason(c)
    return addon:HeldBackReason(c)
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
            -- Crafts worth concentration that their sales left out: say so,
            -- instead of "nothing" while the list shows good g/conc rows
            -- (design review follow-up, 2026-10-09)
            local capped = CappedConcentration(conc)
            if #capped > 0 then
                local first = capped[1]
                bar.best:SetText(string.format("Nothing planned: %s%s held back (hover for why)",
                    first.recipe.outputName, #capped > 1 and string.format(" +%d", #capped - 1) or ""))
            else
                bar.best:SetText("Nothing worth concentration right now.")
            end
            bar.best:SetTextColor(addon:Color("muted"))
        end
    end

    bar:SetScript("OnClick", function()
        local best = bar.target
        if not best then return end
        local first = best.plan[1]
        addon:OpenCraftPlan(first.recipe, first.row, best.key, nil, nil, first.crafts)
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
        -- Worth concentration, but its sales leave no room to make more
        local capped = CappedConcentration(conc)
        if #capped > 0 then
            tooltip:AddLine(" ")
            tooltip:AddLine("Worth it, but held back", 1, 1, 1)
            for i, c in ipairs(capped) do
                if i > 6 then
                    Note(tooltip, string.format("    and %d more", #capped - 6))
                    break
                end
                local tier = c.row.tier and (addon:TierIconText(c.row.tier, c.tierCount) .. " ") or ""
                Line(tooltip, string.format("    %s%s (%s)", tier, c.recipe.outputName, c.name),
                    string.format("%s a point", Money(c.row.concentrationValue)), "gold")
                Note(tooltip, "        " .. CappedReason(c))
            end
            Why(tooltip, "An item you still hold unsold isn't made again until it sells. Your own sales never limit a plan: they only show what you could make.")
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
    local planned = GoldsmithDB.ui2.planCrafts and GoldsmithDB.ui2.planCrafts[recipe.recipeID]
    local quantity = planned and addon:WithCharacter(item.charKey, addon.ItemsForCrafts, addon, recipe, planned)
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
-- Profitable was dropped (design review trimming, user 2026-10-10): it sat
-- between Recommended and All crafts
local SHOW_CHOICES = {
    { value = "all", label = "All crafts" },
    { value = "recommended", label = "Recommended" },
    -- Recipes you could learn (GetUnlearnedRows)
    { value = "unlearned", label = "Not learned yet" },
}

-- The Show filter. Recommended until changed (user, 2026-10-07); a saved
-- Profitable (or the old Profitable only checkbox) becomes All crafts, the
-- wider of the two it sat between.
local function CraftsShow()
    local ui = GoldsmithDB.ui2
    if ui.craftsShow == "profitable" or (not ui.craftsShow and ui.profitableOnly) then
        ui.craftsShow, ui.profitableOnly = "all", nil
    end
    -- Gear only was dropped too: back to all items
    if ui.craftsGear == "only" then ui.craftsGear = nil end
    return ui.craftsShow or "recommended"
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

    -- Show: all crafts, recommended ones (profitable and they sell: what Do
    -- this next would suggest), or recipes not learned yet. ui.craftsShow
    -- (see CraftsShow).
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
        -- be hidden (ui.craftsGear = nil / "hide"). Gear only was dropped
        -- (user, 2026-10-10: high-end gear money is soulbound, made through
        -- crafting orders for the tip, not sold on the AH)
        root:CreateDivider()
        root:CreateTitle("Gear")
        for _, choice in ipairs({ { nil, "All items" }, { "hide", "Hide gear" } }) do
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

    -- Search by craft or salvage name. Ignores the expansion and Show
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
    -- Hidden until a refresh says otherwise: while the first load ran it
    -- showed empty over the search box (user, 2026-10-27)
    view.focusChip:Hide()

    view.concSwitch = UI.Switch(list, "Concentration", function(on)
        -- The tour's steps show crafts with concentration (user, 2026-10-13)
        if addon:UsingTourData() and not on then
            addon:Notify("info", "Concentration stays on during the tour.")
            return
        end
        ui.craftsConcentration = on or nil
        addon.RefreshWindow()
    end)
    view.concSwitch:SetPoint("TOPRIGHT", 0, 0)
    if addon.isForever then view.concSwitch:SetAlpha(0); view.concSwitch:EnableMouse(false) end

    -- Hover explanations for the two options (hooked, so the widgets keep
    -- their own hover colors)
    local function Explain(frame, fill)
        UI.SetTooltip(frame, fill, "ANCHOR_BOTTOM")
    end
    Explain(view.concSwitch, function(tooltip)
        tooltip:AddLine("Concentration", 1, 1, 1)
        Why(tooltip, "Adds the ways to craft with concentration: how much each uses (Conc) and the extra gold it earns per point (g/conc).")
        Why(tooltip, "The bar at the bottom shows your concentration on all characters and the best way to spend it.")
        Why(tooltip, "Better materials cost more but need less concentration, so the same concentration makes more crafts. Goldsmith picks the mix that earns the most.", "gold")
    end)
    Explain(view.show, function(tooltip)
        -- One short line per choice; the detail is in each craft's hover
        tooltip:AddLine("Show", 1, 1, 1)
        local minROI = addon:Setting("minROI")
        Line(tooltip, "Recommended", "profitable, and it sells")
        Line(tooltip, "Not learned yet", "recipes to go learn, and what they'd make")
        Line(tooltip, "All crafts", "everything you can make")
        Line(tooltip, "Show ignored", "adds your ignored crafts")
        tooltip:AddLine(" ")
        Why(tooltip, "Recommended is what Do this next suggests. Pick older expansions at the top to judge their crafts on sales too. Hover a greyed-out craft for why it isn't recommended.")
    end)
    Explain(view.searchBox, function(tooltip)
        tooltip:AddLine("Find a craft", 1, 1, 1)
        Why(tooltip, "Two letters or more. Matches crafts by name and salvage by what goes in or comes out, in every expansion, profitable or not.")
        Why(tooltip, "Only " .. (addon.char.name or "me") .. " and the profession picked at the top still apply. Escape clears it.")
    end)
    Explain(view.onlyMine, function(tooltip)
        tooltip:AddLine(view.onlyMine.label and view.onlyMine.label:GetText() or "Only this character", 1, 1, 1)
        Why(tooltip, "Only crafts this character knows, costed with their stats, even where another character makes it better.")
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
                if not addon:ShiftClickItem(itemID, name) then addon:OpenItem(name, itemID) end
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
    addon.PlanCraftsDone = function(recipeID, made, crafts) view.plan:CraftsDone(recipeID, made, crafts) end

    -- Back to the list shows the row you were at, not where the list was
    -- left (user, 2026-10-11: from a to-do item or History, Back meant
    -- searching or scrolling for it again)
    function view:CloseSalvage()
        local target = view.salvage.target
        local returnTab = target and target.returnTab
        if target and not returnTab then
            view.list:ScrollToItem({ function(item) return item.salvage and item.itemID == target.itemID end })
        end
        view.salvage.target = nil
        view.salvage.current = nil
        view.salvage.qty:ClearFocus()
        if returnTab then addon:ShowTab(returnTab) else addon.RefreshWindow() end
    end

    -- Back goes to the Queue tab for a plan opened from there
    function view:ClosePlan()
        local plan = view.plan.plan
        local returnTab = plan and plan.returnTab
        if plan and not returnTab then
            local recipeID = plan.recipe and plan.recipe.recipeID
            local function Same(item)
                return not item.salvage and item.recipe and item.recipe.recipeID == recipeID
            end
            -- The same way of crafting it (concentration or not) first
            view.list:ScrollToItem({
                function(item) return Same(item) and (item.info and item.info.concentrate == true) == plan.concentrate end,
                Same,
            })
        end
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
            v.plan:Open(pending.plan, pending.quantity, pending.crafts)
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
    v.concSwitch:SetOn(concOn)
    v.show:SetLabel("Show: " .. ShowLabel(CraftsShow())
        .. (ui.craftsGear == "hide" and ", no gear" or ""))
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
        -- Concentration ways need enough extra gold per point, like Do this
        -- next (less when that character's concentration is full)
        local floors = {}
        local function GoodUse(item)
            local info = item.info
            if not (info.concentrate and item.recipe) then return true end
            local key = (item.charKey or addon.charKey) .. ":" .. tostring(item.recipe.profession)
            if floors[key] == nil then
                floors[key] = addon:ConcentrationFloor(item.charKey or addon.charKey, item.recipe.profession)
            end
            return (info.concentrationValue or 0) >= floors[key]
        end
        local kept = {}
        for _, item in ipairs(items) do
            addon:Yield()
            if not item.whyNot and not item.info.partial and GoodUse(item) then table.insert(kept, item) end
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
    -- Hide gear (Show menu): salvage is never gear
    if ui.craftsGear == "hide" and not focus then
        local kept = {}
        -- A frame may pass between items: on a slower laptop the steps
        -- from here to the list took 23.6 ms in one frame (2026-10-12)
        for _, item in ipairs(items) do
            addon:Yield()
            if item.salvage or not addon:IsGear(item.itemID) then table.insert(kept, item) end
        end
        items = kept
    end
    if mixed then
        for _, item in ipairs(items) do item.labelExpansion = true end
    end
    -- Searching ignores the expansions picked at the top, so those go
    -- first (user, 2026-10-11: "transmute" listed every expansion's)
    for _, item in ipairs(items) do
        addon:Yield()
        item.pinned = searching and addon:IsExpansionShown(item.salvage and addon:GetItemExpansion(item.itemID)
            or addon:GetRecipeExpansion(item.recipe)) or nil
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
        v.list:SetEmptyText("Nothing to recommend. Set Show to All crafts to see everything.")
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
        -- What clicks do is in the window's click legend (Legend below)
        v.footnote:SetText((unlearnedMode
            and "Recipes you haven't learned, costed with your skill today." or "")
            .. (partial and ((unlearnedMode and "   " or "") .. "+ some material costs unknown,  * profit is at most this") or ""))
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

-- What narrows the list right now, for the window's Filtered marker.
-- Show (Recommended by default) isn't one: it's the list's purpose, and
-- its own dropdown names it.
local function Filters(v)
    local ui, list = GoldsmithDB.ui2, {}
    if ui.craftsOnlyMine then
        table.insert(list, { label = "Only " .. (addon.char.name or "me"), clear = function() ui.craftsOnlyMine = nil end })
    end
    if ui.craftsGear == "hide" then
        table.insert(list, { label = "No gear", clear = function() ui.craftsGear = nil end })
    end
    return list
end

-- What clicks do on the screen showing, for the window's click legend.
-- The thing clicked is named once, in the first part, to keep it on one
-- line.
local function Legend(v)
    if v.plan.plan then
        return {
            { "click", "a material: its page" },
            { "right", ": choose buy, craft or mill" },
            { "shift", ": search the AH" },
            { "hover", ": how it's worked out" },
        }
    elseif v.salvage.target then
        return { { "click", "an output: its page" }, { "hover", ": how it's worked out" } }
    elseif not v.focus and CraftsShow() == "unlearned" then
        return { { "click", "a recipe: its item's page" }, { "hover", ": where to learn it" } }
    end
    return {
        { "click", "a craft: plan it" },
        { "right", ": queue or ignore" },
        { "shift", ": item page" },
        { "hover", ": how it's worked out" },
        { "ctrl", "in a hover: explain" },
    }
end

addon:RegisterView("crafts", { create = Create, refresh = Refresh, reset = Reset, filters = Filters,
    legend = Legend, ownLoading = true })

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

-- "Needs Anvil nearby": nothing tells an addon you walked up to it, so
-- while that's what blocks the Craft button it's checked every second
-- (user, 2026-10-09: still greyed out next to the anvil)
C_Timer.NewTicker(1, function()
    local screen = view and view.plan
    local state = screen and screen.craftState
    if state and screen:IsVisible() and screen.plan and state.nearby and addon.StationsMet(state.nearbyRecipes) then
        screen:Update()
    end
end)

_G.Goldsmith = addon
