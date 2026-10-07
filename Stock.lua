local addon = _G.Goldsmith or {}

-- Materials on hand and price history

-- Every material Goldsmith knows about: reagents from saved recipes and
-- herbs you've milled. Returns { [itemID] = name }.
function addon:GetTrackedMaterials()
    local materials = {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        for _, slot in ipairs(recipe.reagents) do
            for i, itemID in ipairs(slot.itemIDs or {}) do
                materials[itemID] = slot.names[i]
            end
        end
    end
    for herbID, record in pairs(GoldsmithDB.milling) do
        materials[herbID] = record.name
    end
    return materials
end

-- Crafting quality tier of a reagent (1, 2, ...), or nil if it has none
local function GetQualityTier(itemID)
    local fn = C_TradeSkillUI.GetItemReagentQualityByItemInfo
    if not fn then return nil end
    local ok, tier = pcall(fn, itemID)
    if ok and tier and tier > 0 then
        return tier
    end
end

-- Materials in your bags, bank, reagent bank and warband bank, valued at
-- what they cost you (or the AH price if you have no cost for them).
-- prof filters to one profession's materials, or "All".
-- Returns a list of { itemID, name, count, unitValue, value, source }
-- sorted by value, and the total value.
function addon:GetMaterialsOnHand(prof)
    local list, total = {}, 0
    for itemID, name in pairs(addon:GetTrackedMaterials()) do
        local materialProf = GoldsmithDB.reagents[name]
        if prof == "All" or materialProf == prof then
            local count = C_Item.GetItemCount(itemID, true, false, true, true) or 0
            if count > 0 then
                local unit, source = addon:GetOwnCost(name)
                if not unit then
                    unit = addon:GetMarketPrice(itemID)
                    source = unit and "AH price"
                end
                local value = unit and unit * count
                local tier = GetQualityTier(itemID)
                table.insert(list, {
                    itemID = itemID,
                    name = tier and string.format("%s (tier %d)", name, tier) or name,
                    profession = materialProf,
                    count = count,
                    unitValue = unit,
                    value = value,
                    source = source,
                })
                total = total + (value or 0)
            end
        end
    end
    table.sort(list, function(a, b)
        return (a.value or 0) > (b.value or 0)
    end)
    return list, total
end

-- Price history
--
-- Auctionator's own price history isn't available to other addons, so each
-- time Auctionator updates its prices Goldsmith saves one price per day for
-- every material and crafted item it knows. Kept for HISTORY_DAYS days in
-- GoldsmithDB.priceHistory[itemID]["YYYY-MM-DD"]. Not shown anywhere yet;
-- it builds up so later features can compare today's prices with the past.
local HISTORY_DAYS = 60

-- The same pass also notes when each item's Auctionator price was seen, as
-- GoldsmithDB.priceSeen[itemID] = { time, price }, because Auctionator only
-- gives ages in whole days. A full scan stamps every item priced today. A
-- search doesn't say which items it saw, so it only stamps items whose
-- price changed: an item it saw at the same price keeps its older time,
-- so a time is never newer than it should be.
function addon:RecordPriceHistory(isFullScan)
    local history = GoldsmithDB.priceHistory
    local seen = GoldsmithDB.priceSeen
    local now = time()
    local today = date("%Y-%m-%d")
    local cutoff = date("%Y-%m-%d", now - HISTORY_DAYS * 86400)

    local items = addon:GetTrackedMaterials()
    for _, recipe in pairs(GoldsmithDB.recipes) do
        items[recipe.outputItemID] = recipe.outputName
    end
    -- Each quality tier of a crafted item is its own item (gold Draught of
    -- Rampant Abandon isn't the silver one), known from any character's
    -- tier data
    for _, c in pairs(GoldsmithDB.characters) do
        for recipeID, td in pairs(c.tierData or {}) do
            local recipe = GoldsmithDB.recipes[recipeID]
            for _, out in pairs(td.outputs or {}) do
                if out.itemID and not items[out.itemID] then
                    items[out.itemID] = recipe and recipe.outputName or true
                end
            end
        end
    end

    for itemID in pairs(items) do
        -- Only prices Auctionator saw today, so old prices aren't saved as new
        local price = addon:GetAuctionatorPrice(itemID)
        if price and addon:GetAuctionatorAge(itemID) == 0 then
            history[itemID] = history[itemID] or {}
            history[itemID][today] = price
            local last = seen[itemID]
            if isFullScan or not last or last[2] ~= price then
                seen[itemID] = { now, price }
            end
        end
    end

    -- A day on, Auctionator's own age in days takes over
    for itemID, entry in pairs(seen) do
        if now - entry[1] > 2 * 86400 then seen[itemID] = nil end
    end

    for itemID, days in pairs(history) do
        for day in pairs(days) do
            if day < cutoff then
                days[day] = nil
            end
        end
        if next(days) == nil then
            history[itemID] = nil
        end
    end
end

-- Stock-up insights
--
-- Today's price compared with the item's usual price: the median of its
-- saved daily prices, not counting today. Needs INSIGHT_MIN_DAYS days of
-- history first. Returns { now, usual, diff (-0.18 = 18% below usual),
-- days, low, high } or nil, plus the number of days of history.
local INSIGHT_MIN_DAYS = 5

function addon:GetPriceInsight(itemID)
    local days = GoldsmithDB.priceHistory[itemID]
    if not days then return nil, 0 end
    local today = date("%Y-%m-%d")
    local prices = {}
    for day, price in pairs(days) do
        if day ~= today then
            table.insert(prices, price)
        end
    end
    if #prices < INSIGHT_MIN_DAYS then return nil, #prices end
    table.sort(prices)
    local mid = math.floor(#prices / 2)
    local usual = (#prices % 2 == 1) and prices[mid + 1] or (prices[mid] + prices[mid + 1]) / 2

    local now = addon:GetMarketPrice(itemID)
    if not now or usual <= 0 then return nil, #prices end
    return {
        now = now, usual = usual, diff = (now - usual) / usual,
        days = #prices, low = prices[1], high = prices[#prices],
    }, #prices
end

-- Materials with enough history, for the Deals tab, and the earliest date
-- any history was saved (so the tab can say how long until it's ready).
-- prof filters to one profession's materials, or "All". Vendor items and
-- materials the expansion filter hides (IsItemShown) are left out (user,
-- 2026-10-06: old pigments and Darkmoon decks filled the list). Kept until
-- data changes (the Overview asks every time it's shown); callers mustn't
-- change the list or its entries.
local dealsCache = addon:NewCache()
local Deals

function addon:GetDeals(prof)
    local store = dealsCache:Get()
    local id = prof .. "|" .. addon:ExpansionFilterKey()
    store[id] = store[id] or { Deals(prof) }
    return store[id][1], store[id][2], store[id][3]
end

Deals = function(prof)
    local list = {}
    local earliest
    -- A list rather than pairs(), so the work can wait for a frame
    local history = GoldsmithDB.priceHistory
    for n, itemID in ipairs(addon:Keys(history)) do
        if n % 64 == 0 then addon:Yield() end
        for day in pairs(history[itemID] or {}) do
            if not earliest or day < earliest then earliest = day end
        end
    end
    local everything = addon:AllExpansionsShown()
    for itemID, name in pairs(addon:GetTrackedMaterials()) do
        addon:Yield()
        local materialProf = GoldsmithDB.reagents[name]
        if (prof == "All" or materialProf == prof) and not addon:IsVendorItem(itemID)
            and (everything or addon:IsItemShown(itemID, name)) then
            local insight = addon:GetPriceInsight(itemID)
            if insight then
                insight.itemID = itemID
                insight.name = name
                insight.profession = materialProf
                insight.have = C_Item.GetItemCount(itemID, true, false, true, true) or 0
                table.insert(list, insight)
            end
        end
    end
    table.sort(list, function(a, b) return a.diff < b.diff end)
    return list, earliest, INSIGHT_MIN_DAYS
end

function addon:InitializeStock()
    GoldsmithDB.priceHistory = GoldsmithDB.priceHistory or {}
    GoldsmithDB.priceSeen = GoldsmithDB.priceSeen or {}
end

_G.Goldsmith = addon
