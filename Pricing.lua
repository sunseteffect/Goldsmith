local addon = _G.Goldsmith or {}

local function Print(msg, ...)
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

local function FormatGold(copper)
    return string.format("%.2fg", copper / 10000)
end

-- Average cost

-- Weighted average price paid per unit, from recorded AH purchases.
-- Returns copper per unit and units bought, or nil if never bought.
function addon:GetAverageCost(itemName)
    local totalCopper, totalQty = 0, 0
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "COST" and (e.kind or "PURCHASE") == "PURCHASE" and e.item == itemName then
            totalCopper = totalCopper + e.totalCopper
            totalQty = totalQty + e.quantity
        end
    end
    if totalQty == 0 then return nil end
    return totalCopper / totalQty, totalQty
end

-- Market prices (Auctionator, optional)

local AH_CUT = 0.05

-- AH prices come from Auctionator or TSM, whichever is more recent.
--
-- TSM doesn't tell other addons when its data was downloaded, but it only
-- loads new data at login or /reload. So an Auctionator scan made since this
-- session started is always newer than TSM's data. Without one, TSM's data
-- (refreshed by its app, typically hourly) is usually newer than an older
-- Auctionator scan, so TSM is used, falling back to Auctionator.
local sessionStart = time()

-- Auctionator's price for an item, regardless of TSM
function addon:GetAuctionatorPrice(itemID)
    if not itemID then return nil end
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.GetAuctionPriceByItemID) then return nil end
    local ok, price = pcall(api.GetAuctionPriceByItemID, "Goldsmith", itemID)
    if ok and price and price > 0 then
        return price
    end
end

-- True if Auctionator has updated its prices since this login/reload,
-- i.e. its prices are newer than TSM's
function addon:ScannedThisSession()
    return GoldsmithDB.lastPriceUpdate ~= nil and GoldsmithDB.lastPriceUpdate >= sessionStart
end

local function GetAuctionatorAge(itemID)
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if not (api and api.GetAuctionAgeByItemID) then return nil end
    local ok, age = pcall(api.GetAuctionAgeByItemID, "Goldsmith", itemID)
    if ok and type(age) == "number" then
        return age
    end
end

local function GetTSMValue(source, itemID)
    if not (TSM_API and TSM_API.GetCustomPriceValue) then return nil end
    local ok, price = pcall(TSM_API.GetCustomPriceValue, source, "i:" .. itemID)
    if ok and price and price > 0 then
        return price
    end
end

-- Live order books
--
-- When an AH search shows a commodity's listings (e.g. clicking an item in
-- Auctionator's shopping list), every price level and its quantity are
-- recorded. For ORDER_BOOK_FRESH seconds that item is priced from this real
-- depth, which is more accurate than any scan's single lowest price:
--   - tiny undercuts are ignored: the price used is where at least
--     THIN_MIN_UNITS units (or THIN_SHARE of everything listed) are
--     available at or below it, so 10 units listed cheap don't count
--   - buying N units (planner) costs what walking the listings costs
-- Kept in GoldsmithDB.orderBooks[itemID] = { time, total, levels = {{price, qty}} }
local ORDER_BOOK_FRESH = 30 * 60
local ORDER_BOOK_KEEP = 24 * 60 * 60
local ORDER_BOOK_LEVELS = 100
local THIN_MIN_UNITS = 20
local THIN_SHARE = 0.002

local function RecordOrderBook(itemID)
    local count = C_AuctionHouse.GetNumCommoditySearchResults(itemID)
    if not count or count == 0 then return end
    local levels, total = {}, 0
    for i = 1, count do
        local info = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
        if info and info.unitPrice and info.quantity then
            total = total + info.quantity
            local last = levels[#levels]
            if last and last.price == info.unitPrice then
                last.qty = last.qty + info.quantity
            elseif #levels < ORDER_BOOK_LEVELS then
                table.insert(levels, { price = info.unitPrice, qty = info.quantity })
            end
        end
    end
    if #levels > 0 then
        GoldsmithDB.orderBooks[itemID] = { time = time(), total = total, levels = levels }
    end
end

local function GetFreshOrderBook(itemID)
    local book = GoldsmithDB.orderBooks and GoldsmithDB.orderBooks[itemID]
    if book and time() - book.time <= ORDER_BOOK_FRESH then
        return book
    end
end

-- Lowest price with meaningful quantity behind it
local function GetRobustBookPrice(book)
    local threshold = math.max(THIN_MIN_UNITS, book.total * THIN_SHARE)
    local cumulative = 0
    for _, level in ipairs(book.levels) do
        cumulative = cumulative + level.qty
        if cumulative >= threshold then
            return level.price
        end
    end
    return book.levels[#book.levels].price
end

-- Average price per unit to buy `quantity` from the live listings, whether
-- enough were listed, and the book's time; nil without a fresh order book.
function addon:GetLiveBuyCost(itemID, quantity)
    local book = GetFreshOrderBook(itemID)
    if not book or quantity <= 0 then return nil end
    local remaining, cost = quantity, 0
    for _, level in ipairs(book.levels) do
        local take = math.min(remaining, level.qty)
        cost = cost + take * level.price
        remaining = remaining - take
        if remaining <= 0 then break end
    end
    local bought = quantity - remaining
    if bought <= 0 then return nil end
    return cost / bought, remaining <= 0, book.time
end

-- Undercut check for scan prices: a lowest price below UNDERCUT_RATIO of
-- TSM's market value is treated as a small undercut rather than the real
-- price, and the market value is used instead.
local UNDERCUT_RATIO = 0.6

-- Vendor prices
--
-- The game only shows what a vendor charges while you're at the vendor, so
-- every vendor you open is recorded: price per unit for each item bought
-- with gold (items costing currencies or tokens are skipped). Kept in
-- GoldsmithDB.vendorPrices[itemID]. Includes any reputation discount you had.
local function RecordVendorPrices()
    local count = GetMerchantNumItems and GetMerchantNumItems() or 0
    for i = 1, count do
        local itemID = GetMerchantItemID(i)
        local price, stackCount, hasExtendedCost
        if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
            local info = C_MerchantFrame.GetItemInfo(i)
            if info then
                price, stackCount, hasExtendedCost = info.price, info.stackCount, info.hasExtendedCost
            end
        elseif GetMerchantItemInfo then
            local _
            _, _, price, stackCount, _, _, _, hasExtendedCost = GetMerchantItemInfo(i)
        end
        if itemID and price and price > 0 and not hasExtendedCost then
            GoldsmithDB.vendorPrices[itemID] = price / math.max(stackCount or 1, 1)
        end
    end
end

function addon:GetVendorPrice(itemID)
    return itemID and GoldsmithDB.vendorPrices and GoldsmithDB.vendorPrices[itemID]
end

-- AH price only (no vendor cap). Returns price per unit, source, the
-- price's age in days (Auctionator only), and a note when the price was
-- adjusted. Sources:
--   "Live"         - a fresh order book from an AH search
--   "Auctionator"  - Auctionator's last scan
--   "TSM"          - TSM's minimum buyout
--   "TSM market"   - TSM's market value, used because the lowest price
--                    looked like a small undercut or far too high
--   "TSM sale avg" - TSM's region sale average, used because the price
--                    was far above what the item actually sells for
-- nil if nothing has a price.
function addon:GetAHPriceInfo(itemID)
    if not itemID then return nil end

    local book = GetFreshOrderBook(itemID)
    if book then
        return GetRobustBookPrice(book), "Live", nil
    end

    local auctionator = addon:GetAuctionatorPrice(itemID)
    local age = auctionator and GetAuctionatorAge(itemID)
    local price, source
    if auctionator and age == 0 and addon:ScannedThisSession() then
        price, source = auctionator, "Auctionator"
    else
        local tsm = GetTSMValue("DBMinBuyout", itemID)
        if tsm then
            price, source, age = tsm, "TSM", nil
        elseif auctionator then
            price, source = auctionator, "Auctionator"
        end
    end
    if not price then return nil end

    return addon:CheckAgainstMarket(itemID, price, source, age)
end

-- Outlier check against TSM's market value: a lowest price far below it
-- looks like a small undercut; far above it (e.g. a 9,999,999g listing when
-- nothing else is up) isn't a real price either. Either way TSM's market
-- value is used instead, with a note. Without TSM the price is unchanged.
--
-- Market value comes from listings, so for items that rarely sell it's as
-- unrealistic as the listings themselves (an item-level-15 staff listed at
-- 81,484g). TSM's region sale average is what it actually sold for, so a
-- price more than SALE_HIGH_RATIO times that is capped at it.
local OUTLIER_HIGH_RATIO = 5
local SALE_HIGH_RATIO = 3

function addon:CheckAgainstMarket(itemID, price, source, age)
    local listed, note = price, nil
    local market = GetTSMValue("DBMarket", itemID)
    if market and price < market * UNDERCUT_RATIO then
        price, source, age = market, "TSM market", nil
        note = string.format("lowest listing %s looked like a small undercut", FormatGold(listed))
    elseif market and price > market * OUTLIER_HIGH_RATIO then
        price, source, age = market, "TSM market", nil
        note = string.format("lowest listing %s is far above the usual price", FormatGold(listed))
    end
    local saleAvg = GetTSMValue("DBRegionSaleAvg", itemID)
    if saleAvg and price > saleAvg * SALE_HIGH_RATIO then
        return saleAvg, "TSM sale avg", nil,
            string.format("listed at %s, but it usually sells for %s", FormatGold(listed), FormatGold(saleAvg))
    end
    return price, source, age, note
end

function addon:GetAHPrice(itemID)
    return (addon:GetAHPriceInfo(itemID))
end

-- What an item costs to get: the AH price, unless a vendor sells it for
-- less (or it isn't on the AH), in which case the vendor price with source
-- "Vendor". Same returns as GetAHPriceInfo.
function addon:GetMarketPriceInfo(itemID)
    if not itemID then return nil end
    local price, source, age, note = addon:GetAHPriceInfo(itemID)
    local vendor = addon:GetVendorPrice(itemID)
    if vendor and (not price or vendor <= price) then
        return vendor, "Vendor", nil
    end
    return price, source, age, note
end

function addon:GetMarketPrice(itemID)
    return (addon:GetMarketPriceInfo(itemID))
end

-- Auctionator's own age for an item's price, regardless of which source is
-- in use (price history only records prices Auctionator saw today)
function addon:GetAuctionatorAge(itemID)
    return GetAuctionatorAge(itemID)
end

function addon:HasAuctionator()
    return Auctionator and Auctionator.API and Auctionator.API.v1 and true or false
end

-- Days since the item's price was seen (0 = today), when the price in use
-- is Auctionator's. nil when the price is TSM's (it doesn't share its age).
function addon:GetMarketAge(itemID)
    local _, source, age = addon:GetMarketPriceInfo(itemID)
    if source == "Auctionator" then
        return age
    end
end

-- Where the price in use came from, and how old: "from 14:32",
-- "2 days old", "from TSM", "live, 5m ago", "TSM market value (...)"
function addon:PriceAgeText(itemID)
    local price, source, age, note = addon:GetMarketPriceInfo(itemID)
    if not price then return "no price" end
    if source == "Live" then
        local book = GoldsmithDB.orderBooks[itemID]
        return string.format("live, %dm ago", math.floor((time() - book.time) / 60))
    end
    if source == "TSM" then return "from TSM" end
    if source == "TSM market" then return "TSM market value (" .. note .. ")" end
    if source == "TSM sale avg" then return "TSM region sale average (" .. note .. ")" end
    if source == "Vendor" then return "vendor price" end
    return addon:FormatAge(age)
end

-- Same as PriceAgeText, for the AH price only (ignoring vendor prices)
function addon:AHPriceAgeText(itemID)
    local price, source, age, note = addon:GetAHPriceInfo(itemID)
    if not price then return "no price" end
    if source == "Live" then
        local book = GoldsmithDB.orderBooks[itemID]
        return string.format("live, %dm ago", math.floor((time() - book.time) / 60))
    end
    if source == "TSM" then return "from TSM" end
    if source == "TSM market" then return "TSM market value (" .. note .. ")" end
    if source == "TSM sale avg" then return "TSM region sale average (" .. note .. ")" end
    return addon:FormatAge(age)
end

-- Time of the last Auctionator price update if it happened today ("14:32"),
-- else nil. Auctionator only reports item ages in whole days, so this is
-- the best "when" available for prices seen today.
function addon:GetTodayScanTime()
    local ts = GoldsmithDB.lastPriceUpdate
    if ts and date("%Y-%m-%d", ts) == date("%Y-%m-%d") then
        return date("%H:%M", ts)
    end
end

function addon:FormatAge(days)
    if not days then return "age unknown" end
    if days == 0 then
        local scanTime = addon:GetTodayScanTime()
        return scanTime and ("from " .. scanTime) or "from today"
    end
    if days == 1 then return "1 day old" end
    return days .. " days old"
end

-- Demand
--
-- Units sold per day. From TSM's region data when TSM is installed (built
-- from many players' scans; commodity markets are region-wide), otherwise
-- from your own sales over the last OWN_SALES_DAYS days.
local OWN_SALES_DAYS = 14

local function GetTSMSoldPerDay(itemID)
    if not (TSM_API and TSM_API.GetCustomPriceValue) then return nil end
    -- TSM returns whole numbers, so scale up to keep fractions like 0.4/day
    local ok, value = pcall(TSM_API.GetCustomPriceValue, "dbregionsoldperday*1000", "i:" .. itemID)
    if ok and value then
        return value / 1000
    end
end

local function GetOwnSoldPerDay(itemName)
    local since = time() - OWN_SALES_DAYS * 86400
    local units = 0
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "REVENUE" and e.item == itemName and e.timestamp >= since then
            units = units + e.quantity
        end
    end
    if units == 0 then return nil end
    return units / OWN_SALES_DAYS
end

function addon:HasTSM()
    return TSM_API and TSM_API.GetCustomPriceValue and true or false
end

-- Returns units sold per day and where it came from ("TSM region" or
-- "your sales"), or nil if there's no data.
function addon:GetDemand(itemID, itemName)
    local tsm = itemID and GetTSMSoldPerDay(itemID)
    if tsm then
        return tsm, "TSM region"
    end
    local own = itemName and GetOwnSoldPerDay(itemName)
    if own then
        return own, "your sales"
    end
end

function addon:FormatDemand(perDay)
    if not perDay then return "-" end
    if perDay >= 10000 then return string.format("%.0fk", perDay / 1000) end
    if perDay >= 1000 then return string.format("%.1fk", perDay / 1000) end
    if perDay >= 10 then return string.format("%.0f", perDay) end
    return string.format("%.1f", perDay)
end

-- Share of an item's auctions that sell (0 to 1), from TSM's region data,
-- or nil without TSM or data. A low rate means most listings expire.
function addon:GetSaleRate(itemID)
    if not (itemID and TSM_API and TSM_API.GetCustomPriceValue) then return nil end
    -- TSM returns whole numbers, so scale up to keep the decimals
    local ok, value = pcall(TSM_API.GetCustomPriceValue, "dbregionsalerate*1000", "i:" .. itemID)
    if ok and value then
        return value / 1000
    end
end

-- As a percent: 25%, or <1% for rates that round to nothing
function addon:FormatSaleRate(rate)
    if not rate then return "-" end
    if rate > 0 and rate < 0.005 then return "<1%" end
    return string.format("%.0f%%", rate * 100)
end

-- Expansions

-- Expansion an item comes from (0 = Classic), or nil if not cached yet.
function addon:GetItemExpansion(itemID)
    return select(15, C_Item.GetItemInfo(itemID))
end

function addon:GetExpansionName(expansionID)
    return _G["EXPANSION_NAME" .. expansionID] or ("Expansion " .. expansionID)
end

function addon:GetCurrentExpansion()
    return (GetServerExpansionLevel and GetServerExpansionLevel()) or GetExpansionLevel()
end

-- Whether an item can be listed on the AH, from its bind type. Bind on
-- pickup, quest items and account/warband-bound items can't be. Returns nil
-- if the item isn't in the game's cache yet (it's requested for next time).
local UNSELLABLE_BINDS = { [1] = true, [4] = true, [7] = true, [8] = true, [9] = true }

function addon:CanAuction(itemID)
    local bindType = select(14, C_Item.GetItemInfo(itemID))
    if bindType == nil then
        C_Item.RequestLoadItemDataByID(itemID)
        return nil
    end
    return not UNSELLABLE_BINDS[bindType]
end

-- Recipes

-- Recipes are saved automatically when you craft them, from the game's own
-- recipe data. Stored in GoldsmithDB.recipes keyed by recipe ID:
--   { name, profession, outputItemID, outputName, outputQty,
--     reagents = { { names = {...}, itemIDs = {...}, quantity = n }, ... } }
-- A reagent slot can list several items (e.g. different qualities); the
-- cheapest one with a known cost is used.
-- Recipes with quality tiers may not fill in schematic.outputItemID, so fall
-- back to the output data the profession window uses.
local function IsEnchantRecipe(schematic)
    local types = Enum.TradeskillRecipeType
    return types and schematic.recipeType == types.Enchant
end

local function GetOutputItemID(recipeID, schematic)
    -- Enchants don't report their scroll; it's learned from your first
    -- scroll craft (see OnCraftResult)
    if IsEnchantRecipe(schematic) then
        local scroll = GoldsmithDB.scrollOutputs[recipeID]
        return scroll and scroll.itemID
    end
    if schematic.outputItemID then
        return schematic.outputItemID
    end
    local ok, output = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID)
    if not ok or not output then return nil end
    if output.itemID then
        return output.itemID
    end
    if output.hyperlink then
        return (C_Item.GetItemInfoInstant(output.hyperlink))
    end
end

-- Only recipes that make an item are saved: normal crafts, and enchants
-- once you've put one on a scroll. Salvage (milling, prospecting) is tracked
-- by Milling.lua; recrafts don't make a new item.
local function IsCraftRecipe(schematic)
    local types = Enum.TradeskillRecipeType
    if not types or not schematic.recipeType then return true end
    return schematic.recipeType == types.Item or schematic.recipeType == types.Enchant
end

-- quiet is true when saving from a spell cast or from viewing a recipe, where
-- failures and "Saved recipe" messages would just be noise.
-- Item names come from the game's item cache. When viewing recipes you've
-- never crafted, some names may not be loaded yet, so the save is retried a
-- few times rather than storing a recipe with materials missing.
local MAX_RETRIES = 3

-- profession is passed when saving outside the profession window (enchants
-- matched to scrolls after an AH scan); otherwise it's the open profession.
local function SaveRecipe(recipeID, quiet, attempt, profession)
    attempt = attempt or 1
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok or not schematic or not IsCraftRecipe(schematic) then return end

    if not profession then
        local profInfo = C_TradeSkillUI.GetBaseProfessionInfo()
        profession = (profInfo and profInfo.professionName) or "Unassigned"
    end

    local outputItemID = GetOutputItemID(recipeID, schematic)
    if not outputItemID then
        if IsEnchantRecipe(schematic) then
            -- Remember it so its scroll can be matched by name later
            if schematic.name then
                GoldsmithDB.pendingEnchants[recipeID] = { name = schematic.name, profession = profession }
            end
        elseif not quiet then
            Print("Couldn't save recipe %s: the game didn't report what it makes.", schematic.name or recipeID)
        end
        return
    end
    GoldsmithDB.pendingEnchants[recipeID] = nil

    local reagents = {}
    local namesMissing = false
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        if slot.required and slot.reagents then
            local names, itemIDs = {}, {}
            for _, reagent in ipairs(slot.reagents) do
                if reagent.itemID then
                    local name = C_Item.GetItemNameByID(reagent.itemID)
                    if name then
                        table.insert(names, name)
                        table.insert(itemIDs, reagent.itemID)
                    else
                        namesMissing = true
                        C_Item.RequestLoadItemDataByID(reagent.itemID)
                    end
                end
            end
            if #names > 0 then
                table.insert(reagents, { names = names, itemIDs = itemIDs, quantity = slot.quantityRequired })
            end
        end
    end

    -- A scroll uses up the vellum the enchant was put on, so it's a material
    local scroll = IsEnchantRecipe(schematic) and GoldsmithDB.scrollOutputs[recipeID]
    if scroll and scroll.vellumID then
        local vellumName = C_Item.GetItemNameByID(scroll.vellumID)
        if vellumName then
            table.insert(reagents, { names = { vellumName }, itemIDs = { scroll.vellumID }, quantity = 1 })
        else
            namesMissing = true
            C_Item.RequestLoadItemDataByID(scroll.vellumID)
        end
    end

    local outputName = C_Item.GetItemNameByID(outputItemID)
    if not outputName then
        namesMissing = true
        C_Item.RequestLoadItemDataByID(outputItemID)
    end

    if namesMissing then
        if attempt < MAX_RETRIES then
            C_Timer.After(1, function() SaveRecipe(recipeID, quiet, attempt + 1, profession) end)
        end
        return
    end

    for _, slot in ipairs(reagents) do
        for _, name in ipairs(slot.names) do
            GoldsmithDB.reagents[name] = GoldsmithDB.reagents[name] or profession
        end
    end

    local isNew = GoldsmithDB.recipes[recipeID] == nil

    GoldsmithDB.recipes[recipeID] = {
        recipeID = recipeID,
        name = schematic.name,
        profession = profession,
        outputItemID = outputItemID,
        outputName = outputName,
        outputQty = ((schematic.quantityMin or 1) + (schematic.quantityMax or 1)) / 2,
        outputMin = schematic.quantityMin or 1,
        outputMax = schematic.quantityMax or 1,
        reagents = reagents,
    }
    GoldsmithDB.products[outputName] = GoldsmithDB.products[outputName] or profession
    addon:RefreshRecipeStats(recipeID)

    if isNew and not quiet then
        Print("Saved recipe: %s", outputName)
    end
    if isNew and addon.RefreshCrafts then
        addon.RefreshCrafts()
    end
end

-- Enchant scrolls by name
--
-- An enchant scroll has the same name as its enchant ("Enchant Ring - ..."),
-- so a scroll can be found without crafting it first. The game only looks
-- items up by name once they've been loaded, e.g. seen in an Auctionator
-- scan, so enchants are matched after scans and whenever the profession
-- window is opened. A match only counts if the item really is an item
-- enhancement (scroll), not something else with the same name.
local ENCHANTING_VELLUM = 38682

local function GetVellumID()
    for _, scroll in pairs(GoldsmithDB.scrollOutputs) do
        if scroll.vellumID then
            return scroll.vellumID
        end
    end
    return ENCHANTING_VELLUM
end

function addon:MatchEnchantScrolls()
    local itemEnhancement = Enum.ItemClass and Enum.ItemClass.ItemEnhancement or 8
    local matched = 0
    for recipeID, pending in pairs(GoldsmithDB.pendingEnchants) do
        local link = select(2, C_Item.GetItemInfo(pending.name))
        local itemID = link and C_Item.GetItemInfoInstant(link)
        local classID = itemID and select(6, C_Item.GetItemInfoInstant(itemID))
        if itemID and classID == itemEnhancement then
            GoldsmithDB.scrollOutputs[recipeID] = { itemID = itemID, vellumID = GetVellumID() }
            SaveRecipe(recipeID, true, 1, pending.profession)
            matched = matched + 1
        end
    end
    if matched > 0 then
        Print("Found scrolls for %d enchant%s. See the Crafts tab in /gsm.", matched, matched == 1 and "" or "s")
    end
end

-- Crafting stats
--
-- Your multicraft, resourcefulness and ingenuity chances, concentration cost
-- and expected quality come straight from the game for each recipe
-- (C_TradeSkillUI.GetCraftingOperationInfo). They're read whenever you open
-- a profession and kept in addon.char.recipeStats[recipeID]:
--   { multicraft = %, resourcefulness = %, ingenuity = %,
--     concentrationCost, ingenuityRefund, quality, qualityID,
--     isQualityCraft, updated }
-- The game doesn't report how big a proc is (how many extra items a
-- multicraft gives, how much resourcefulness saves), since that depends on
-- specialization bonuses. Those start at common base values and are
-- corrected from your own crafts (see calibration below).
--
-- Stat names come from the game in your client's language; this matches the
-- English names.
local STAT_KEYS = {
    Multicraft = "multicraft",
    Resourcefulness = "resourcefulness",
    Ingenuity = "ingenuity",
}

function addon:RefreshRecipeStats(recipeID)
    if not C_TradeSkillUI.GetCraftingOperationInfo then return end
    local ok, op = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, nil, false)
    if not ok or not op then return end
    local stats = {
        multicraft = 0, resourcefulness = 0, ingenuity = 0,
        concentrationCost = op.concentrationCost,
        ingenuityRefund = op.ingenuityRefund,
        quality = op.quality,
        qualityID = op.craftingQualityID,
        isQualityCraft = op.isQualityCraft,
        updated = time(),
    }
    for _, stat in ipairs(op.bonusStats or {}) do
        local key = STAT_KEYS[stat.bonusStatName]
        if key and stat.ratingPct then
            stats[key] = stat.ratingPct
        end
    end
    addon.char.recipeStats[recipeID] = stats

    -- Each expansion's version of a profession has its own concentration,
    -- stored as a currency (0 for recipes that don't use concentration).
    -- Remember each recipe's currency, and for the profession the current
    -- expansion's one, so its amount can be read any time (Quality.lua).
    local currencyID = op.concentrationCurrencyID
    if currencyID and currencyID > 0 then
        stats.concentrationCurrencyID = currencyID
        local recipe = GoldsmithDB.recipes[recipeID]
        if recipe and recipe.profession then
            GoldsmithDB.concentrationCurrency = GoldsmithDB.concentrationCurrency or {}
            local known = GoldsmithDB.concentrationCurrency[recipe.profession]
            local isCurrent = addon:GetItemExpansion(recipe.outputItemID) == addon:GetCurrentExpansion()
            if isCurrent or not known or known == 0 then
                GoldsmithDB.concentrationCurrency[recipe.profession] = currencyID
            end
        end
    end

    -- Quality crafts: work out which tiers are reachable (Quality.lua).
    -- Enchants included once their scroll is known (their tiers are found
    -- from it)
    if op.isQualityCraft and GoldsmithDB.recipes[recipeID] and addon.RefreshTierData then
        addon:RefreshTierData(recipeID)
    end
end

-- Calibration
--
-- Proc sizes, learned from your crafts and pooled per profession so they're
-- learned quickly. Kept in addon.char.calibration[profession]:
--   mcProcs, mcExtraRatio  - multicraft procs, and the sum of
--                            (extra items / normal output) per proc
--   resProcs, resSavedRatio - resourcefulness returns, and the sum of
--                            (amount returned / amount required) per return
-- Blended with the base values below, which count as PRIOR_WEIGHT
-- observations, so a few lucky procs don't swing the numbers.
local BASE_MULTICRAFT_EXTRA = 1.5    -- extra items per proc, times normal output
local BASE_RESOURCEFULNESS_SAVE = 0.30 -- share of a material saved per proc
local PRIOR_WEIGHT = 5

local function GetCalibration(profession)
    local c = addon:StatsChar().calibration[profession]
    local mcExtra, resSave = BASE_MULTICRAFT_EXTRA, BASE_RESOURCEFULNESS_SAVE
    if c then
        mcExtra = (BASE_MULTICRAFT_EXTRA * PRIOR_WEIGHT + (c.mcExtraRatio or 0)) / (PRIOR_WEIGHT + (c.mcProcs or 0))
        resSave = (BASE_RESOURCEFULNESS_SAVE * PRIOR_WEIGHT + (c.resSavedRatio or 0)) / (PRIOR_WEIGHT + (c.resProcs or 0))
    end
    return mcExtra, resSave, c
end

function addon:GetCalibration(profession)
    return GetCalibration(profession)
end

-- The craft model for a recipe: expected items per craft and expected
-- amount of each material per craft, with your stats and calibrated proc
-- sizes. Without stats for the recipe, or with noProcs (the worst case:
-- no multicraft or resourcefulness), the recipe's base numbers.
-- Returns outputPerCraft, slots ({ slot, quantity }), and the stats used.
function addon:GetCraftModel(recipe, noProcs)
    local stats = not noProcs and recipe.recipeID and addon:StatsChar().recipeStats[recipe.recipeID]
    local base = recipe.outputQty
    local slots = {}
    if not stats then
        for _, slot in ipairs(recipe.reagents) do
            table.insert(slots, { slot = slot, quantity = slot.quantity })
        end
        return base, slots, nil
    end

    local mcExtra, resSave = GetCalibration(recipe.profession)
    local outputPerCraft = base * (1 + stats.multicraft / 100 * mcExtra)
    local useFactor = 1 - stats.resourcefulness / 100 * resSave
    for _, slot in ipairs(recipe.reagents) do
        table.insert(slots, { slot = slot, quantity = slot.quantity * useFactor })
    end
    return outputPerCraft, slots, stats
end

-- Crafting results
--
-- Each finished craft reports what it made, any multicraft extras and any
-- materials resourcefulness gave back. Used for calibration, per-recipe
-- totals (GoldsmithDB.craftStats), and a log of the last CRAFT_LOG_SIZE raw
-- results (GoldsmithDB.craftLog) for checking the numbers.
local CRAFT_LOG_SIZE = 100
local currentCraftRecipeID = nil
local currentEnchantTarget = nil   -- item ID of the vellum an enchant went on
local currentCraftReagents = nil   -- the materials list the game was given (qualities used)

-- Item ID of a material resourcefulness returned. The game nests it in a
-- reagent table ({ reagent = { itemID = ... }, quantity = n }); older
-- versions had it at the top level.
local function GetReturnedItemID(ret)
    if ret.itemID then return ret.itemID end
    if type(ret.reagent) == "table" then return ret.reagent.itemID end
end

-- Plain copy of a table, a couple of levels deep, for the log
local function CopyForLog(t, depth)
    local copy = {}
    for k, v in pairs(t) do
        if type(v) == "table" then
            if (depth or 0) < 2 then copy[k] = CopyForLog(v, (depth or 0) + 1) end
        elseif k ~= "hyperlink" and k ~= "itemGUID" then
            copy[k] = v
        end
    end
    return copy
end

local function LogCraftResult(recipeID, resultData)
    local entry = CopyForLog(resultData)
    entry.time = time()
    entry.recipeID = recipeID
    table.insert(GoldsmithDB.craftLog, entry)
    while #GoldsmithDB.craftLog > CRAFT_LOG_SIZE do
        table.remove(GoldsmithDB.craftLog, 1)
    end
end

local function OnCraftResult(resultData)
    if not currentCraftRecipeID or not resultData or not resultData.itemID then return end
    LogCraftResult(currentCraftRecipeID, resultData)

    -- First scroll from an enchant: now we know which item it makes
    if currentEnchantTarget and not GoldsmithDB.scrollOutputs[currentCraftRecipeID] then
        GoldsmithDB.scrollOutputs[currentCraftRecipeID] = {
            itemID = resultData.itemID,
            vellumID = currentEnchantTarget,
        }
        SaveRecipe(currentCraftRecipeID, false)
        return
    end

    local recipe = GoldsmithDB.recipes[currentCraftRecipeID]
    if not recipe then return end
    -- Ignore results that aren't this recipe's item (e.g. a different craft)
    if C_Item.GetItemNameByID(resultData.itemID) ~= recipe.outputName then return end

    local stats = GoldsmithDB.craftStats[currentCraftRecipeID]
    if not stats then
        stats = { crafts = 0, output = 0, returned = {} }
        GoldsmithDB.craftStats[currentCraftRecipeID] = stats
    end
    stats.crafts = stats.crafts + 1
    stats.output = stats.output + (resultData.quantity or 0)

    local c = addon.char.calibration[recipe.profession]
    if not c then
        c = { mcProcs = 0, mcExtraRatio = 0, resProcs = 0, resSavedRatio = 0 }
        addon.char.calibration[recipe.profession] = c
    end

    -- Multicraft: extra items beyond the recipe's normal output
    local extra = resultData.multicraft
    if type(extra) == "number" and extra > 0 and recipe.outputQty > 0 then
        c.mcProcs = c.mcProcs + 1
        c.mcExtraRatio = c.mcExtraRatio + extra / recipe.outputQty
    end

    -- Resourcefulness: each returned material, as a share of what the
    -- recipe needs of it
    for _, ret in ipairs(resultData.resourcesReturned or {}) do
        local returnedID = GetReturnedItemID(ret)
        if returnedID and ret.quantity then
            stats.returned[returnedID] = (stats.returned[returnedID] or 0) + ret.quantity
            for _, slot in ipairs(recipe.reagents) do
                for _, itemID in ipairs(slot.itemIDs or {}) do
                    if itemID == returnedID and slot.quantity > 0 then
                        c.resProcs = c.resProcs + 1
                        c.resSavedRatio = c.resSavedRatio + ret.quantity / slot.quantity
                    end
                end
            end
        end
    end

    addon:RecordCraftLot(recipe, resultData, currentCraftReagents)
end

-- Crafted lots
--
-- What each craft actually cost: the materials and qualities used, minus
-- anything resourcefulness gave back, valued at what they cost you (or the
-- current price if you have no cost for them), divided by how many it made.
-- Kept per item (each quality tier is its own item) in
-- GoldsmithDB.craftLots[itemID] = { { time, qty, unitCost, partial, name } },
-- the last CRAFT_LOT_LIMIT crafts. Concentration isn't a gold cost, so it
-- isn't included.
local CRAFT_LOT_LIMIT = 30

function addon:RecordCraftLot(recipe, resultData, usedReagents)
    local made = resultData.quantity or 0
    if made <= 0 then return end
    -- Multicraft extras: the game reports them separately. If the quantity
    -- doesn't already include them (it's no more than the recipe's normal
    -- maximum), add them, so a multicraft spreads the cost over every item
    -- it made. Recipes saved before the range was stored use the average.
    local extra = resultData.multicraft
    if type(extra) == "number" and extra > 0 then
        local normalMax = recipe.outputMax or math.ceil(recipe.outputQty)
        if made <= normalMax then
            made = made + extra
        end
    end

    local used, names = {}, {}
    for _, slot in ipairs(recipe.reagents) do
        local ids = slot.itemIDs or {}
        for i, id in ipairs(ids) do names[id] = slot.names[i] end
        if #ids > 1 then
            -- Quality material: the qualities actually used, from the
            -- materials list given to the game
            local counted = 0
            for _, entry in ipairs(usedReagents or {}) do
                local id = (type(entry.reagent) == "table" and entry.reagent.itemID) or entry.itemID
                for _, slotID in ipairs(ids) do
                    if slotID == id and entry.quantity then
                        used[id] = (used[id] or 0) + entry.quantity
                        counted = counted + entry.quantity
                    end
                end
            end
            if counted == 0 then
                used[ids[1]] = (used[ids[1]] or 0) + slot.quantity
            end
        elseif ids[1] then
            used[ids[1]] = (used[ids[1]] or 0) + slot.quantity
        end
    end

    for _, ret in ipairs(resultData.resourcesReturned or {}) do
        local id = GetReturnedItemID(ret)
        if id and used[id] and ret.quantity then
            used[id] = math.max(used[id] - ret.quantity, 0)
        end
    end

    local cost, complete = 0, true
    for id, qty in pairs(used) do
        if qty > 0 then
            local unit = (names[id] and addon:GetOwnCost(names[id], resultData.itemID)) or addon:GetMarketPrice(id)
            if unit then
                cost = cost + unit * qty
            else
                complete = false
            end
        end
    end

    local lots = GoldsmithDB.craftLots[resultData.itemID] or {}
    GoldsmithDB.craftLots[resultData.itemID] = lots
    table.insert(lots, {
        time = time(), qty = made, unitCost = cost / made,
        partial = not complete, name = recipe.outputName,
    })
    while #lots > CRAFT_LOT_LIMIT do
        table.remove(lots, 1)
    end
end

-- Average cost of the newest lots covering `units` items (you'd normally
-- still have your most recent crafts). Returns cost per item, units
-- covered, and whether any lot had unknown material costs.
local function LotAverage(lots, units)
    local remaining, total, covered, partial = math.max(units or 1, 1), 0, 0, false
    for i = #lots, 1, -1 do
        local lot = lots[i]
        local take = math.min(lot.qty, remaining)
        total = total + take * lot.unitCost
        covered = covered + take
        partial = partial or lot.partial
        remaining = remaining - take
        if remaining <= 0 then break end
    end
    if covered == 0 then return nil end
    return total / covered, covered, partial
end

-- What the copies of this exact item (quality tier) in your bags and banks
-- cost you to craft, from your latest crafts of it (or the newest `units`
-- of them). nil if never crafted.
function addon:GetCraftedCost(itemID, units)
    local lots = GoldsmithDB.craftLots[itemID]
    if not lots or #lots == 0 then return nil end
    local onHand = C_Item.GetItemCount(itemID, true, false, true, true) or 0
    return LotAverage(lots, units or onHand)
end

-- Same, for every quality of an item with this name (sale mail and
-- material costs only know the name). Newest crafts first, covering what
-- you have on hand, or `units` if given.
function addon:GetCraftedCostByName(itemName, units)
    local combined, onHand, counted = {}, 0, {}
    for itemID, lots in pairs(GoldsmithDB.craftLots) do
        for _, lot in ipairs(lots) do
            if lot.name == itemName then
                table.insert(combined, lot)
                if not counted[itemID] then
                    counted[itemID] = true
                    onHand = onHand + (C_Item.GetItemCount(itemID, true, false, true, true) or 0)
                end
            end
        end
    end
    if #combined == 0 then return nil end
    table.sort(combined, function(a, b) return a.time < b.time end)
    return LotAverage(combined, units or onHand)
end

-- What an item has cost you: purchases, your own milling and your own
-- crafts combined, weighted by how many you got each way. Returns cost and
-- source ("paid", "milled", "crafted", or several joined with "+"), or nil.
-- excludeItemID leaves out that item's own crafts (so a craft's cost isn't
-- worked out from itself).
function addon:GetOwnCost(itemName, excludeItemID)
    local sources = {}
    local paid, paidQty = addon:GetAverageCost(itemName)
    if paid then table.insert(sources, { "paid", paid, paidQty }) end
    local milled, milledQty = addon:GetMilledCost(itemName)
    if milled then table.insert(sources, { "milled", milled, milledQty }) end
    local crafted, craftedQty = addon:GetCraftedCostByName(itemName)
    if crafted and not (excludeItemID and C_Item.GetItemNameByID(excludeItemID) == itemName) then
        table.insert(sources, { "crafted", crafted, craftedQty })
    end
    if #sources == 0 then return nil end

    local total, qty, labels = 0, 0, {}
    for _, s in ipairs(sources) do
        total = total + s[2] * s[3]
        qty = qty + s[3]
        table.insert(labels, s[1])
    end
    return total / qty, table.concat(labels, "+")
end

-- Unit cost of one reagent slot, from the first source that has data:
--   1. what it cost you (purchases and milling)
--   2. Auctionator's current AH price
-- Returns cost, source and the item name used, or nil.
local function GetSlotCost(slot)
    local best, bestSource, bestName
    for _, name in ipairs(slot.names) do
        local cost, source = addon:GetOwnCost(name)
        if cost and (not best or cost < best) then
            best, bestSource, bestName = cost, source, name
        end
    end
    if best then
        return best, bestSource, bestName
    end

    -- Recipes saved before item IDs were stored have no itemIDs until re-crafted
    -- Market price: the AH, or the vendor when it's cheaper
    local bestID, bestMarketSource
    for i, itemID in ipairs(slot.itemIDs or {}) do
        local price, source = addon:GetMarketPriceInfo(itemID)
        if price and (not best or price < best) then
            best, bestName, bestID, bestMarketSource = price, slot.names[i], itemID, source
        end
    end
    if best then
        if bestMarketSource == "Vendor" then
            return best, "vendor", bestName
        end
        return best, "AH price", bestName, bestID
    end
end

-- Cheapest known unit cost for a recipe slot (what you paid or milled, else
-- the AH price), for other files. Returns cost and source, or nil.
function addon:GetSlotUnitCost(slot)
    local cost, source = GetSlotCost(slot)
    return cost, source
end

-- Cost of the materials for one crafted item, using the craft model (your
-- stats: extra items from multicraft, materials saved by resourcefulness).
-- Returns copper per item, a list of reagents with no cost, a breakdown of
-- { name, quantity, unitCost, source } per reagent, and the stats used (nil
-- if the recipe's base numbers were used). noProcs: the worst case, with no
-- multicraft or resourcefulness.
function addon:GetRecipeCost(recipe, noProcs)
    local outputPerCraft, modelSlots, stats = addon:GetCraftModel(recipe, noProcs)
    local perCraft = 0
    local missing = {}
    local breakdown = {}
    for _, m in ipairs(modelSlots) do
        local slot, quantity = m.slot, m.quantity

        local cost, source, name, marketItemID = GetSlotCost(slot)
        if cost then
            perCraft = perCraft + cost * quantity
        else
            table.insert(missing, slot.names[1])
        end
        table.insert(breakdown, {
            name = name or slot.names[1],
            quantity = quantity,
            unitCost = cost,
            source = source,
            -- how old the AH price is, when the cost came from the AH
            ageText = marketItemID and addon:PriceAgeText(marketItemID),
        })
    end
    return perCraft / outputPerCraft, missing, breakdown, stats
end

-- Everything needed to judge a recipe, for tooltips and the Crafts tab.
-- profit and margin are nil without an AH price for the item.
function addon:GetRecipeProfit(recipe, itemID)
    local cost, missing, breakdown, stats = addon:GetRecipeCost(recipe)
    local priceItemID = itemID or recipe.outputItemID
    local price, priceSource, priceAge = addon:GetMarketPriceInfo(priceItemID)
    local demand, demandSource = addon:GetDemand(priceItemID, recipe.outputName)
    local profit, margin
    if price then
        profit = price * (1 - AH_CUT) - cost
        margin = cost > 0 and (profit / cost * 100) or nil
    end
    return {
        cost = cost,
        missing = missing,
        partial = #missing > 0,
        breakdown = breakdown,
        stats = stats,
        price = price,
        priceSource = priceSource,
        priceAge = priceAge,
        priceAgeText = price and addon:PriceAgeText(priceItemID),
        demand = demand,
        demandSource = demandSource,
        saleRate = addon:GetSaleRate(priceItemID),
        profit = profit,
        margin = margin,
    }
end

-- What one unit of an item cost you, for working out profit on a sale:
-- the craft cost for things you make, otherwise what you paid or milled.
-- Returns cost per unit and whether it's partial (some material costs
-- unknown), or nil if there's no cost data at all.
function addon:GetUnitCostBasis(itemName, units)
    -- Items you crafted: what your latest crafts actually cost
    local crafted, _, craftedPartial = addon:GetCraftedCostByName(itemName, units)
    if crafted then
        return crafted, craftedPartial
    end
    local recipe = addon:FindRecipeByOutput(itemName)
    if recipe then
        local cost, missing = addon:GetRecipeCost(recipe)
        return cost, #missing > 0
    end
    local own = addon:GetOwnCost(itemName)
    if own then
        return own, false
    end
end

function addon:FindRecipeByOutput(itemName)
    for _, recipe in pairs(GoldsmithDB.recipes) do
        if recipe.outputName == itemName then
            return recipe
        end
    end
end

function addon:ListRecipes()
    local list = {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        table.insert(list, recipe)
    end
    if #list == 0 then
        Print("No recipes saved yet. Craft something once and it's saved automatically.")
        return
    end
    table.sort(list, function(a, b) return a.outputName < b.outputName end)

    Print("Saved recipes (material cost per item, profit at current AH price):")
    for _, recipe in ipairs(list) do
        local cost, missing = addon:GetRecipeCost(recipe)
        local line = "  " .. recipe.outputName .. ": " .. FormatGold(cost)
        if #missing > 0 then
            line = line .. "+"
        end
        local price = addon:GetMarketPrice(recipe.outputItemID)
        if price then
            local profit = price * (1 - AH_CUT) - cost
            line = line .. string.format(", profit %s%s", profit >= 0 and "+" or "-", FormatGold(math.abs(profit)))
            if #missing > 0 then
                line = line .. " at most"
            end
        end
        if #missing > 0 then
            line = line .. " (no cost data for " .. table.concat(missing, ", ") .. ")"
        end
        print(line)
    end
end

-- Tooltips

local function AddTooltipLines(tooltip, data)
    if tooltip ~= GameTooltip and tooltip ~= ItemRefTooltip then return end
    if not addon.ledger or not data or not data.id then return end

    local name = C_Item.GetItemNameByID(data.id)
    if not name then return end

    local avg, qty = addon:GetAverageCost(name)
    if avg then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r avg cost",
            string.format("%s (%d bought)", FormatGold(avg), qty), 1, 1, 1, 1, 1, 1)
    end

    addon:AddMillingTooltipLines(tooltip, data.id, name)

    -- Today's price vs its usual price, once there's enough history
    local insight = addon:GetPriceInsight(data.id)
    if insight then
        local pct = insight.diff * 100
        local r, g, b = 0.8, 0.8, 0.8
        if pct <= -15 then r, g, b = 0.3, 1, 0.3 elseif pct >= 15 then r, g, b = 1, 0.6, 0.2 end
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r vs usual price",
            string.format("%+.0f%% (usual %s, %d days)", pct, FormatGold(insight.usual), insight.days),
            1, 1, 1, r, g, b)
    end

    -- What the ones you crafted cost you (this exact quality), from your
    -- latest crafts of it
    local madeFor, madeUnits, madePartial = addon:GetCraftedCost(data.id)
    if madeFor then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r you made yours for",
            string.format("%s%s each (%d from your crafts)", FormatGold(madeFor), madePartial and "+" or "", madeUnits),
            1, 1, 1, 1, 1, 1)
    end

    -- Lowest AH listing price that doesn't lose money after the AH cut:
    -- based on what yours cost to make if you crafted them, else the
    -- current average cost
    local unitCost, partial = madeFor, madePartial
    if not unitCost then
        unitCost, partial = addon:GetUnitCostBasis(name)
    end
    if unitCost and unitCost > 0 then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r break-even price",
            FormatGold(unitCost / (1 - AH_CUT)) .. (partial and "+" or ""), 1, 1, 1, 1, 1, 1)
    end

    local recipe = addon:FindRecipeByOutput(name)
    if recipe then
        addon:AddRecipeTooltipLines(tooltip, recipe, data.id, IsShiftKeyDown())
    end
end

local function FormatQuantity(q)
    if q == math.floor(q) then
        return tostring(q)
    end
    return string.format("%.1f", q)
end

-- Craft cost, profit and (optionally) the per-material breakdown. Shared by
-- item tooltips and the Crafts tab.
function addon:AddRecipeTooltipLines(tooltip, recipe, itemID, showBreakdown)
    local info = addon:GetRecipeProfit(recipe, itemID)

    local costText = FormatGold(info.cost) .. (info.partial and "+" or "") .. " each"
    if info.partial then
        costText = costText .. " (missing " .. #info.missing .. ")"
    end
    tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r craft cost", costText, 1, 1, 1, 1, 1, 1)

    -- Profit if sold at the current AH price, after the AH cut
    if info.profit then
        local r, g, b = 0.3, 1, 0.3
        if info.profit < 0 then r, g, b = 1, 0.3, 0.3 end
        local profitText = string.format("%s%s each", info.profit >= 0 and "+" or "-", FormatGold(math.abs(info.profit)))
        if info.margin then
            profitText = profitText .. string.format(" (%.0f%%)", info.margin)
        end
        -- Unknown costs can only lower the profit, so it's an upper bound
        local label = info.partial and "|cFF00FF00Goldsmith|r profit (at most)" or "|cFF00FF00Goldsmith|r profit"
        tooltip:AddDoubleLine(label, profitText, 1, 1, 1, r, g, b)
        tooltip:AddLine("  AH price " .. info.priceAgeText, 0.6, 0.6, 0.6)
    end

    if info.demand then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r sold per day",
            string.format("%s (%s)", addon:FormatDemand(info.demand), info.demandSource), 1, 1, 1, 1, 1, 1)
    end
    if info.saleRate then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r sale rate",
            addon:FormatSaleRate(info.saleRate) .. " of listings sell", 1, 1, 1, 1, 1, 1)
    end

    -- Which stats the cost uses
    local s = info.stats
    if s then
        local outputPerCraft = addon:GetCraftModel(recipe)
        local parts = {}
        if s.multicraft > 0 then table.insert(parts, string.format("multicraft %.1f%%", s.multicraft)) end
        if s.resourcefulness > 0 then table.insert(parts, string.format("resourcefulness %.1f%%", s.resourcefulness)) end
        tooltip:AddLine(string.format("  Your stats: %s - %.2f made per craft",
            #parts > 0 and table.concat(parts, ", ") or "no multicraft or resourcefulness",
            outputPerCraft), 0.6, 0.6, 0.6)
    else
        tooltip:AddLine("  Base recipe numbers - open the profession to use your stats", 0.6, 0.6, 0.6)
    end

    if showBreakdown then
        for _, part in ipairs(info.breakdown) do
            local left = string.format("  %sx %s", FormatQuantity(part.quantity), part.name)
            local source = part.source
            if source == "AH price" then
                source = "AH, " .. (part.ageText or "age unknown")
            end
            local right = part.unitCost
                and string.format("%s (%s)", FormatGold(part.unitCost * part.quantity), source)
                or "no cost data"
            tooltip:AddDoubleLine(left, right, 0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        end
    else
        tooltip:AddLine("  Hold Shift for material costs", 0.6, 0.6, 0.6)
    end
end

-- Learned recipe scan
--
-- When the profession window opens (or switches expansion), every learned
-- recipe that isn't saved yet gets saved, so older-expansion crafts you sell
-- are recognised without clicking each one. Saves run in small batches to
-- avoid a hitch, and each recipe is only tried once per session.
local SCAN_BATCH = 20
local scanTimer = nil
local scanning = false
local triedThisSession = {}
local statsReadThisSession = {}

local function CountRecipes()
    local n = 0
    for _ in pairs(GoldsmithDB.recipes) do n = n + 1 end
    return n
end

local function ScanLearnedRecipes()
    scanTimer = nil
    if scanning then return end

    local ok, ids = pcall(C_TradeSkillUI.GetAllRecipeIDs)
    if not ok or not ids then return end

    -- New learned recipes to save, and saved ones whose stats haven't been
    -- read this session (stats change with gear, specialization and skill)
    -- Each recipe this character has learned is marked as known by it;
    -- stats are only read for those (they're this character's stats).
    local toSave, toStats = {}, {}
    for _, id in ipairs(ids) do
        if not statsReadThisSession[id] and not triedThisSession[id] then
            local info = C_TradeSkillUI.GetRecipeInfo(id)
            local learned = info and info.learned
            if learned then
                addon:MarkRecipeKnown(id)
            end
            if GoldsmithDB.recipes[id] then
                statsReadThisSession[id] = true
                if learned then
                    table.insert(toStats, id)
                end
            else
                triedThisSession[id] = true
                if learned then
                    table.insert(toSave, id)
                end
            end
        end
    end
    if #toSave == 0 and #toStats == 0 then
        addon:MatchEnchantScrolls()
        return
    end

    scanning = true
    local before = CountRecipes()
    local statsIndex = 1
    local i = 1
    local function Step()
        -- Stats first: quick, and they update costs for recipes you have
        for _ = 1, SCAN_BATCH do
            local id = toStats[statsIndex]
            if not id then break end
            addon:RefreshRecipeStats(id)
            statsIndex = statsIndex + 1
        end
        if toStats[statsIndex] then
            C_Timer.After(0, Step)
            return
        end

        for _ = 1, SCAN_BATCH do
            local id = toSave[i]
            if not id then
                scanning = false
                -- Saves retry for a few seconds while item names load, so
                -- wait before counting and re-sorting the log
                C_Timer.After(4, function()
                    addon:MatchEnchantScrolls()
                    if addon.Refresh then addon.Refresh() end
                    local added = CountRecipes() - before
                    if added > 0 then
                        Print("Saved %d learned recipes. See the Crafts tab in /gsm.", added)
                        addon:ReassignProfessions()
                    end
                end)
                return
            end
            SaveRecipe(id, true)
            i = i + 1
        end
        C_Timer.After(0, Step)
    end
    Step()
end

local function QueueRecipeScan()
    if scanTimer then
        scanTimer:Cancel()
    end
    scanTimer = C_Timer.NewTimer(1, ScanLearnedRecipes)
end

-- Crafting stats diagnostic (/gsm stats)
--
-- Temporary: reads what the game reports for the recipe selected in the
-- profession window (skill, difficulty, quality, concentration, and the
-- multicraft/resourcefulness/ingenuity stats), with and without
-- concentration, prints it, and saves it to GoldsmithDB.statsDump so the
-- exact values can be read from the saved variables file. Used to design
-- Goldsmith's own crafting calculations.
local function CopyTable(t, depth)
    if type(t) ~= "table" or (depth or 0) > 4 then return t end
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = CopyTable(v, (depth or 0) + 1)
    end
    return copy
end

function addon:DumpCraftingStats()
    local recipeID = addon.selectedRecipeID
    if not recipeID then
        Print("Open your profession window and click a recipe first, then run /gsm stats.")
        return
    end
    if not C_TradeSkillUI.GetCraftingOperationInfo then
        Print("The game's crafting stats function isn't available.")
        return
    end

    local ok1, normal = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, nil, false)
    local ok2, concentrated = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, nil, true)
    local okS, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    local okP, profInfo = pcall(C_TradeSkillUI.GetBaseProfessionInfo)

    GoldsmithDB.statsDump = GoldsmithDB.statsDump or {}
    GoldsmithDB.statsDump[recipeID] = {
        time = time(),
        normal = ok1 and CopyTable(normal) or ("error: " .. tostring(normal)),
        concentrated = ok2 and CopyTable(concentrated) or ("error: " .. tostring(concentrated)),
        schematic = okS and CopyTable(schematic) or nil,
        profession = okP and CopyTable(profInfo) or nil,
    }

    -- Quality tier checks: the item for each tier, and what happens with the
    -- lowest vs highest quality materials, in both reagent list formats the
    -- game has used ({ itemID = } and { reagent = { itemID = } })
    local tiers = {}
    local okQ, qualities = pcall(C_TradeSkillUI.GetQualitiesForRecipe, recipeID)
    tiers.qualities = okQ and CopyTable(qualities) or ("error: " .. tostring(qualities))
    tiers.outputs = {}
    local qualityIDs = (okQ and type(qualities) == "table" and #qualities > 0) and qualities
        or { 1, 2, 3, 4, 5, 13, 14 }
    for _, qualityID in ipairs(qualityIDs) do
        local okO, out = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, {}, nil, qualityID)
        tiers.outputs[qualityID] = okO and CopyTable(out) or ("error: " .. tostring(out))
    end

    local function BuildReagents(pickHighest, nested)
        local list = {}
        for _, slot in ipairs(okS and schematic and schematic.reagentSlotSchematics or {}) do
            -- Only materials that come in qualities; fixed materials use
            -- their own slot numbering, which clashes with these
            if slot.required and slot.reagents and #slot.reagents > 1 then
                local reagent = pickHighest and slot.reagents[#slot.reagents] or slot.reagents[1]
                if reagent.itemID then
                    local entry = { dataSlotIndex = slot.dataSlotIndex, quantity = slot.quantityRequired }
                    if nested then
                        entry.reagent = { itemID = reagent.itemID }
                    else
                        entry.itemID = reagent.itemID
                    end
                    table.insert(list, entry)
                end
            end
        end
        return list
    end
    tiers.runs = {}
    for _, case in ipairs({
        { key = "lowFlat", high = false, nested = false },
        { key = "highFlat", high = true, nested = false },
        { key = "lowNested", high = false, nested = true },
        { key = "highNested", high = true, nested = true },
    }) do
        local reagents = BuildReagents(case.high, case.nested)
        local okR, op = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, reagents, nil, false)
        local okC, opC = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, reagents, nil, true)
        tiers.runs[case.key] = {
            reagents = reagents,
            quality = okR and op and op.quality or ("error: " .. tostring(op)),
            qualityID = okR and op and op.craftingQualityID,
            bonusSkill = okR and op and op.bonusSkill,
            concentrationCost = okC and opC and opC.concentrationCost or ("error: " .. tostring(opC)),
            concentratedQualityID = okC and opC and opC.craftingQualityID,
        }
    end
    GoldsmithDB.statsDump[recipeID].tiers = tiers

    local name = (okS and schematic and schematic.name) or recipeID
    if not ok1 or not normal then
        Print("No crafting stats for %s: %s", name, tostring(normal))
        return
    end
    Print("Crafting stats for %s:", name)
    print(string.format("  Skill %s + %s, difficulty %s + %s", tostring(normal.baseSkill),
        tostring(normal.bonusSkill), tostring(normal.baseDifficulty), tostring(normal.bonusDifficulty)))
    print(string.format("  Quality %s (tier ID %s), concentration cost %s, ingenuity refund %s",
        tostring(normal.quality), tostring(normal.craftingQualityID),
        tostring(normal.concentrationCost), tostring(normal.ingenuityRefund)))
    for _, stat in ipairs(normal.bonusStats or {}) do
        print(string.format("  %s: value %s, %s%% (+%s%% bonus) - %s", tostring(stat.bonusStatName),
            tostring(stat.bonusStatValue), tostring(stat.ratingPct), tostring(stat.bonusRatingPct),
            tostring(stat.ratingDescription)))
    end
    if ok2 and concentrated then
        print(string.format("  With concentration: quality %s (tier ID %s)",
            tostring(concentrated.quality), tostring(concentrated.craftingQualityID)))
    end
    for _, key in ipairs({ "lowFlat", "highFlat", "lowNested", "highNested" }) do
        local run = tiers.runs[key]
        print(string.format("  %s materials: quality %s, skill bonus %s, concentration %s",
            key, tostring(run.quality), tostring(run.bonusSkill), tostring(run.concentrationCost)))
    end
    Print("Saved. /reload so the details are written to disk.")
end

function addon:InitializePricing()
    GoldsmithDB.recipes = GoldsmithDB.recipes or {}
    GoldsmithDB.reagents = GoldsmithDB.reagents or {}

    -- Remove salvage recipes saved before they were filtered out
    for recipeID, recipe in pairs(GoldsmithDB.recipes) do
        local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
        if ok and schematic and not IsCraftRecipe(schematic) then
            GoldsmithDB.recipes[recipeID] = nil
            GoldsmithDB.products[recipe.outputName] = nil
        end
    end

    GoldsmithDB.craftStats = GoldsmithDB.craftStats or {}
    GoldsmithDB.scrollOutputs = GoldsmithDB.scrollOutputs or {}
    GoldsmithDB.pendingEnchants = GoldsmithDB.pendingEnchants or {}
    GoldsmithDB.vendorPrices = GoldsmithDB.vendorPrices or {}
    local vendorFrame = CreateFrame("Frame")
    vendorFrame:RegisterEvent("MERCHANT_SHOW")
    vendorFrame:RegisterEvent("MERCHANT_UPDATE")
    vendorFrame:SetScript("OnEvent", function()
        -- Item info can arrive just after the vendor opens
        C_Timer.After(0.5, function()
            RecordVendorPrices()
            if addon.Refresh then
                addon.Refresh()
            end
        end)
    end)

    GoldsmithDB.orderBooks = GoldsmithDB.orderBooks or {}
    for itemID, book in pairs(GoldsmithDB.orderBooks) do
        if time() - book.time > ORDER_BOOK_KEEP then
            GoldsmithDB.orderBooks[itemID] = nil
        end
    end
    local bookFrame = CreateFrame("Frame")
    bookFrame:RegisterEvent("COMMODITY_SEARCH_RESULTS_UPDATED")
    bookFrame:SetScript("OnEvent", function(_, _, itemID)
        if itemID then
            RecordOrderBook(itemID)
            if addon.Refresh then
                addon.Refresh()
            end
        end
    end)

    GoldsmithDB.craftLog = GoldsmithDB.craftLog or {}
    GoldsmithDB.craftLots = GoldsmithDB.craftLots or {}
    -- Recipes saved before recipeID was stored in them
    for recipeID, recipe in pairs(GoldsmithDB.recipes) do
        recipe.recipeID = recipeID
    end

    hooksecurefunc(C_TradeSkillUI, "CraftRecipe", function(recipeID, _, craftingReagents)
        currentCraftRecipeID = recipeID
        currentEnchantTarget = nil
        currentCraftReagents = craftingReagents
        SaveRecipe(recipeID, false)
    end)
    hooksecurefunc(C_TradeSkillUI, "CraftSalvage", function()
        currentCraftRecipeID = nil
        currentEnchantTarget = nil
    end)
    -- Enchanting onto vellum makes a scroll; the vellum is the target item
    if C_TradeSkillUI.CraftEnchant then
        hooksecurefunc(C_TradeSkillUI, "CraftEnchant", function(recipeID, _, craftingReagents, itemTarget)
            currentCraftReagents = craftingReagents
            currentCraftRecipeID = recipeID
            currentEnchantTarget = itemTarget and C_Item.DoesItemExist(itemTarget)
                and C_Item.GetItemID(itemTarget) or nil
            -- Enchanting gear doesn't make a scroll; only a vellum does
            if currentEnchantTarget and C_Item.IsEquippableItem(currentEnchantTarget) then
                currentEnchantTarget = nil
                currentCraftRecipeID = nil
            end
            SaveRecipe(recipeID, true)
        end)
    end

    local resultFrame = CreateFrame("Frame")
    resultFrame:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT")
    resultFrame:RegisterEvent("TRADE_SKILL_SHOW")
    resultFrame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
    resultFrame:SetScript("OnEvent", function(_, event, resultData)
        if event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
            OnCraftResult(resultData)
        else
            QueueRecipeScan()
        end
    end)

    -- Auctionator tells registered addons when its price data changes, which
    -- gives an exact "prices last updated" time for the window
    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if api and api.RegisterForDBUpdate then
        pcall(api.RegisterForDBUpdate, "Goldsmith", function()
            GoldsmithDB.lastPriceUpdate = time()
            addon:RecordPriceHistory()
            -- A scan loads the items it saw, so more scrolls can be matched
            addon:MatchEnchantScrolls()
            if addon.Refresh then
                addon.Refresh()
            end
        end)
    end

    -- Save each recipe as you click it in the profession window, so costs
    -- and profit are available before you've ever crafted it.
    if EventRegistry then
        EventRegistry:RegisterCallback("ProfessionsRecipeListMixin.Event.OnRecipeSelected", function(_, recipeInfo)
            if recipeInfo and recipeInfo.recipeID then
                addon.selectedRecipeID = recipeInfo.recipeID
                SaveRecipe(recipeInfo.recipeID, true)
            end
        end, addon)
    end

    -- A craft is also a spell cast whose spell ID is the recipe ID. This
    -- catches crafts even if the profession window doesn't go through
    -- CraftRecipe. Saving is repeat-safe, so both firing is fine.
    local castFrame = CreateFrame("Frame")
    castFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    castFrame:SetScript("OnEvent", function(_, _, _, _, spellID)
        if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then return end
        if C_TradeSkillUI.GetRecipeInfo(spellID) then
            SaveRecipe(spellID, true)
        end
    end)

    TooltipDataProcessor.AddTooltipPostCall(Enum.TooltipDataType.Item, AddTooltipLines)

    -- Tooltips don't redraw on key presses, so redraw on Shift to show or
    -- hide the material breakdown while hovering.
    local modifierFrame = CreateFrame("Frame")
    modifierFrame:RegisterEvent("MODIFIER_STATE_CHANGED")
    modifierFrame:SetScript("OnEvent", function(_, _, key)
        if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
        for _, tooltip in ipairs({ GameTooltip, ItemRefTooltip }) do
            if tooltip:IsShown() and tooltip.RefreshData then
                tooltip:RefreshData()
            end
        end
    end)
end

_G.Goldsmith = addon
