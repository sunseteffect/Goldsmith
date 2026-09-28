local addon = _G.Goldsmith or {}

-- Insights
--
-- Account-wide answers for the Overview: gold in stock, concentration
-- across characters, the best crafts right now, and gold per hour. Every
-- function takes a profession ("All" for every one) and works across all
-- your characters, using each character's own stats.

local HELD_TOO_LONG_DAYS = 7
local MIN_MARGIN = 15          -- % margin for a craft to count as worth doing
local MIN_DEMAND = 1           -- sold per day
local ENOUGH_STOCK_CAP = 20    -- see GetBestCrafts

-- Whether a craft is worth recommending: an item from the current
-- expansion that sells at least MIN_DEMAND a day. Items nobody buys (no
-- demand data, or old-expansion items with a few shelf listings) often show
-- huge "profits" from listings that never sell, so they're left out.
-- Items the game hasn't loaded yet are left out until it has.
-- Returns nil if it's worth recommending, otherwise why not (plain words).
function addon:WhyNotRecommended(recipe, row)
    local itemID = row.itemID or recipe.outputItemID
    local expansion = itemID and addon:GetItemExpansion(itemID)
    if not expansion then return "The game hasn't loaded this item yet." end
    if expansion ~= addon:GetCurrentExpansion() then
        return "From an older expansion. Its listings often sit unsold, so the profit may not be real."
    end
    local demand = row.demand or addon:GetDemand(itemID, recipe.outputName)
    if demand == nil then return "No sales data, so there's no telling whether it sells." end
    if demand < MIN_DEMAND then
        return string.format("Sells under %d a day, so it may take a long time to sell.", MIN_DEMAND)
    end
end

local function IsRecommendable(recipe, row)
    return addon:WhyNotRecommended(recipe, row) == nil
end

-- Crafted items: item ID -> recipe, for every recipe output including each
-- quality tier's item (from any character's tier data)
local function GetOutputRecipes()
    local outputs = {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        if recipe.outputItemID then outputs[recipe.outputItemID] = recipe end
    end
    for _, c in pairs(GoldsmithDB.characters) do
        for recipeID, td in pairs(c.tierData) do
            local recipe = GoldsmithDB.recipes[recipeID]
            if recipe then
                for _, out in pairs(td.outputs or {}) do
                    if out.itemID then outputs[out.itemID] = recipe end
                end
            end
        end
    end
    return outputs
end

-- When the oldest copy of an item you still hold was made or bought,
-- assuming you sell the oldest first. Newest crafts and purchases are
-- counted back until they cover what you hold; if they don't, you've held
-- some since before the earliest record. Returns a time, or nil if there
-- are no records.
local function HeldSince(itemID, count)
    local acquired = {}
    for _, lot in ipairs(GoldsmithDB.craftLots[itemID] or {}) do
        table.insert(acquired, { time = lot.time, qty = lot.qty })
    end
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "COST" and (e.kind or "PURCHASE") == "PURCHASE" and e.itemID == itemID then
            table.insert(acquired, { time = e.timestamp, qty = e.quantity })
        end
    end
    if #acquired == 0 then return nil end
    table.sort(acquired, function(a, b) return a.time > b.time end)
    local covered = 0
    for _, a in ipairs(acquired) do
        covered = covered + a.qty
        if covered >= count then return a.time end
    end
    return acquired[#acquired].time
end

-- Gold in stock: everything Goldsmith tracks, on every character and in the
-- warband bank, valued at what it cost you (crafted items at your latest
-- crafts' cost, materials at what you paid or milled), or the AH price when
-- there's no cost.
-- Returns { value, items = { { itemID, name, count, unitValue, value,
-- crafted, heldSince, byCharacter } } (most valuable first),
-- heldLong = crafted items held HELD_TOO_LONG_DAYS or more, heldLongValue }.
function addon:GetStockValue(prof)
    local outputs = GetOutputRecipes()
    local materials = addon:GetTrackedMaterials()
    local ids = {}
    for _, c in pairs(GoldsmithDB.characters) do
        for itemID in pairs(c.stock) do ids[itemID] = true end
    end
    for itemID in pairs(GoldsmithDB.warbandStock) do ids[itemID] = true end

    local result = { value = 0, items = {}, heldLong = {}, heldLongValue = 0 }
    local cutoff = time() - HELD_TOO_LONG_DAYS * 86400
    for itemID in pairs(ids) do
        local recipe = outputs[itemID]
        local name = materials[itemID] or (recipe and recipe.outputName) or C_Item.GetItemNameByID(itemID)
        local itemProf = recipe and recipe.profession or (name and GoldsmithDB.reagents[name])
        if prof == "All" or itemProf == prof then
            local count, byCharacter = addon:GetStock(itemID)
            if count > 0 then
                local unit
                if recipe then
                    unit = addon:GetCraftedCost(itemID, count)
                elseif name then
                    unit = addon:GetOwnCost(name)
                end
                unit = unit or addon:GetMarketPrice(itemID)
                local item = {
                    itemID = itemID, name = name or ("item " .. itemID), profession = itemProf,
                    count = count, unitValue = unit, value = unit and unit * count or 0,
                    crafted = recipe ~= nil, byCharacter = byCharacter,
                }
                result.value = result.value + item.value
                table.insert(result.items, item)
                if recipe then
                    item.heldSince = HeldSince(itemID, count)
                    if item.heldSince and item.heldSince <= cutoff then
                        table.insert(result.heldLong, item)
                        result.heldLongValue = result.heldLongValue + item.value
                    end
                end
            end
        end
    end
    table.sort(result.items, function(a, b) return a.value > b.value end)
    table.sort(result.heldLong, function(a, b) return (a.heldSince or 0) < (b.heldSince or 0) end)
    return result
end

-- Concentration on every character, for professions that use it, and what
-- each character's current concentration is worth spent the best way (see
-- PlanConcentration), using that character's stats.
-- Returns { current, max, gain, rows = { { key, name, profession, current,
-- max, minutesToFull, updated, plan, used, gain } } (most gain first) }.
function addon:GetConcentrationOverview(prof)
    local result = { current = 0, max = 0, gain = 0, rows = {} }
    for _, entry in ipairs(addon:GetCharacters()) do
        for profession in pairs(entry.data.professions) do
            if prof == "All" or profession == prof then
                local current, max, minutesToFull, updated
                if entry.key == addon.charKey then
                    current, max, minutesToFull = addon:GetConcentration(profession)
                    updated = time()
                end
                if not current then
                    current, max, minutesToFull, updated = addon:GetCharacterConcentration(entry.key, profession)
                end
                if current and max and max > 0 then
                    local plan, used, gain = addon:WithCharacter(entry.key,
                        addon.PlanConcentration, addon, profession, current, IsRecommendable)
                    table.insert(result.rows, {
                        key = entry.key, name = entry.data.name, profession = profession,
                        current = current, max = max, minutesToFull = minutesToFull, updated = updated,
                        plan = plan, used = used, gain = gain or 0,
                    })
                    result.current = result.current + current
                    result.max = result.max + max
                    result.gain = result.gain + (gain or 0)
                end
            end
        end
    end
    -- By character, then profession, so each one is always in the same place
    table.sort(result.rows, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return a.profession < b.profession
    end)
    return result
end

-- Who can craft a recipe: the logged-in character if it knows it,
-- otherwise the first character (by name) that does, or nil
function addon:GetCrafter(recipeID)
    if addon.char.knownRecipes[recipeID] then return addon.charKey end
    local best
    for key, c in pairs(GoldsmithDB.characters) do
        if c.knownRecipes[recipeID] and (not best or key < best) then best = key end
    end
    return best
end
local function CrafterFor(recipeID) return addon:GetCrafter(recipeID) end

-- Identifies one way of making a craft (recipe, tier, with or without
-- concentration), so the Overview can point the Crafts tab at it
function addon:CraftKey(recipeID, row)
    return string.format("%d:%d:%s", recipeID, row.tier or 0, row.concentrate and "c" or "")
end

-- The best way to make a recipe without concentration: its most
-- profitable tier, or its single row for crafts without tiers
local function BestPlainRow(recipe)
    local rows = addon:GetTierRows(recipe)
    if rows and #rows > 0 then
        local best
        for _, row in ipairs(rows) do
            if not row.concentrate and row.profit and (not best or row.profit > best.profit) then
                best = row
            end
        end
        return best
    end
    return addon:GetRecipeProfit(recipe)
end

-- The most profitable crafts right now, across professions and characters:
-- a profit of at least MIN_MARGIN %, worth recommending (IsRecommendable),
-- with all material costs known. Most profit per item first.
--
-- A craft drops off the list once you hold about a day's sales of it
-- (capped at ENOUGH_STOCK_CAP), and comes back once those sell.
-- Returns up to `count` { recipe, row, charKey, profit, margin, demand,
-- have }.
function addon:GetBestCrafts(prof, count)
    local list = {}
    for recipeID, recipe in pairs(GoldsmithDB.recipes) do
        if (prof == "All" or recipe.profession == prof) and addon:CanAuction(recipe.outputItemID) ~= false then
            local charKey = CrafterFor(recipeID)
            if charKey then
                local row = addon:WithCharacter(charKey, BestPlainRow, recipe)
                if row and row.profit and row.profit > 0 and not row.partial
                    and (row.margin or 0) >= MIN_MARGIN and IsRecommendable(recipe, row) then
                    local itemID = row.itemID or recipe.outputItemID
                    local have = itemID and addon:GetStock(itemID) or 0
                    local enough = math.min(math.max(math.ceil(row.demand or 1), 1), ENOUGH_STOCK_CAP)
                    if have < enough then
                        table.insert(list, {
                            key = addon:CraftKey(recipeID, row),
                            recipe = recipe, row = row, charKey = charKey, itemID = itemID,
                            profit = row.profit, margin = row.margin, demand = row.demand, have = have,
                        })
                    end
                end
            end
        end
    end
    table.sort(list, function(a, b) return a.profit > b.profit end)
    for i = #list, count + 1, -1 do list[i] = nil end
    return list
end

-- Every craft for the Crafts tab, worked out with the stats of whoever
-- crafts it (see GetCrafter). Crafts with quality tiers get a row per
-- reachable tier (see GetTierRows), the rest a single row. Crafts that
-- can't be listed on the AH (bind on pickup, warbound) are left out; items
-- not in the game's cache yet are shown until their bind type loads.
-- opts:
--   concentration  - include the ways that use concentration
--   profitableOnly - only rows with a profit at current prices (including
--                    ones with unknown costs, whose profit is at most that)
--   showExpansion  - function(expansionID) -> whether to include it
-- Returns { { key, recipe, info (the tier row or GetRecipeProfit), tier,
-- charKey, itemID, whyNot (see WhyNotRecommended) } }, unsorted.
function addon:GetCraftRows(prof, opts)
    local list = {}
    for recipeID, recipe in pairs(GoldsmithDB.recipes) do
        if (prof == "All" or recipe.profession == prof)
            and addon:CanAuction(recipe.outputItemID) ~= false
            and (not opts.showExpansion or opts.showExpansion(addon:GetItemExpansion(recipe.outputItemID))) then
            local charKey = CrafterFor(recipeID) or addon.charKey
            local rows = addon:WithCharacter(charKey, function()
                local tierRows = addon:GetTierRows(recipe)
                if tierRows and #tierRows > 0 then return tierRows end
                return { addon:GetRecipeProfit(recipe) }
            end)
            for _, info in ipairs(rows) do
                if (opts.concentration or not info.concentrate)
                    and (not opts.profitableOnly or (info.profit and info.profit > 0)) then
                    table.insert(list, {
                        key = addon:CraftKey(recipeID, info),
                        recipe = recipe, info = info, tier = info.tier, charKey = charKey,
                        itemID = info.itemID or recipe.outputItemID,
                        whyNot = addon:WhyNotRecommended(recipe, info),
                    })
                end
            end
        end
    end
    return list
end

-- Gold per hour for each of the last `days` days (oldest first), each
-- averaged over the 7 days up to it: sales land days after the crafting
-- time, so single days jump around. Profit is for `prof`; goldmaking time
-- is all of it (it isn't split by profession).
-- Returns { { day, perHour, profit, seconds } }; perHour nil without time.
function addon:GetRollingGoldPerHour(prof, days)
    local window = 7
    local daily = addon:GetGoldPerHour(prof, days + window - 1)
    local list = {}
    for i = window, #daily do
        local profit, seconds = 0, 0
        for j = i - window + 1, i do
            profit = profit + daily[j].profit
            seconds = seconds + daily[j].seconds
        end
        table.insert(list, {
            day = daily[i].day, profit = profit, seconds = seconds,
            perHour = seconds > 0 and (profit / seconds * 3600) or nil,
        })
    end
    return list
end

-- Professions to show in the Overview's "by profession" row: any with
-- sales, deposits or concentration. Professions with nothing going on
-- (Fishing, Archaeology, a crafting profession you don't use) are left out.
-- Returns { { profession, profit, sales, concCurrent, concMax } }, most
-- profit first.
function addon:GetProfessionBreakdown(rangeKey, concentration)
    local seen = {}
    for _, c in pairs(GoldsmithDB.characters) do
        for profession in pairs(c.professions) do seen[profession] = true end
    end
    local since = addon:DateRangeStart(rangeKey)
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.profession and e.profession ~= "Unassigned" and (not since or e.timestamp >= since) then
            seen[e.profession] = true
        end
    end

    local list = {}
    for profession in pairs(seen) do
        local s = addon:GetSummary(profession, rangeKey)
        local item = { profession = profession, profit = s.profit, sales = s.sales, concCurrent = 0, concMax = 0 }
        for _, row in ipairs(concentration and concentration.rows or {}) do
            if row.profession == profession then
                item.concCurrent = item.concCurrent + row.current
                item.concMax = item.concMax + row.max
            end
        end
        if item.profit ~= 0 or item.sales ~= 0 or item.concMax > 0 then
            table.insert(list, item)
        end
    end
    table.sort(list, function(a, b)
        if a.profit ~= b.profit then return a.profit > b.profit end
        return a.profession < b.profession
    end)
    return list
end

-- Items tab
--
-- AH sale mail only names the item, not its tier, so what you've earned is
-- worked out per item name. Prices, stock and costs are per item (each
-- quality tier is its own item); an item page can switch between tiers.

local AH_CUT = 0.05
local BOARD_SIZE = 6
local MIN_SALES_FOR_ROI = 2    -- sales before an item's ROI is ranked
local PRICE_DAYS = 30

-- Every item Goldsmith knows: recipe outputs (each tier, from any
-- character's tier data), materials (each quality) and anything you've
-- bought. Returns byID[itemID] = { itemID, name, recipe, tier, tierCount,
-- profession, material } and byName[name] = { itemID, ... } (lowest tier
-- first).
local indexFrame, indexByID, indexByName
local function BuildItemIndex()
    local byID, byName = {}, {}
    local function Add(itemID, name, fields)
        if not itemID or not name then return end
        local item = byID[itemID]
        if not item then
            item = { itemID = itemID, name = name }
            byID[itemID] = item
            byName[name] = byName[name] or {}
            table.insert(byName[name], itemID)
        end
        for k, v in pairs(fields) do
            if item[k] == nil then item[k] = v end
        end
    end
    for _, c in pairs(GoldsmithDB.characters) do
        for recipeID, td in pairs(c.tierData) do
            local recipe = GoldsmithDB.recipes[recipeID]
            if recipe then
                -- Gear shares one item ID across tiers, so it has no single tier
                local shared = td.outputs[1] and td.outputs[#td.qualities]
                    and td.outputs[1].itemID == td.outputs[#td.qualities].itemID
                for tier, out in pairs(td.outputs or {}) do
                    Add(out.itemID, recipe.outputName, {
                        recipe = recipe, profession = recipe.profession,
                        tier = not shared and tier or nil, tierCount = not shared and #td.qualities or nil,
                    })
                end
            end
        end
    end
    for _, recipe in pairs(GoldsmithDB.recipes) do
        Add(recipe.outputItemID, recipe.outputName, { recipe = recipe, profession = recipe.profession })
        for _, slot in ipairs(recipe.reagents) do
            local ids = slot.itemIDs or {}
            for i, itemID in ipairs(ids) do
                Add(itemID, slot.names[i], {
                    material = true, profession = GoldsmithDB.reagents[slot.names[i]],
                    tier = #ids > 1 and i or nil, tierCount = #ids > 1 and #ids or nil,
                })
            end
        end
    end
    for herbID, record in pairs(GoldsmithDB.milling) do
        Add(herbID, record.name, { material = true, profession = GoldsmithDB.reagents[record.name] })
    end
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "COST" and e.itemID then
            Add(e.itemID, e.item, { profession = e.profession ~= "Unassigned" and e.profession or nil })
        end
    end
    for _, ids in pairs(byName) do
        table.sort(ids, function(a, b) return (byID[a].tier or 0) < (byID[b].tier or 0) end)
    end
    return byID, byName
end

-- Built at most once a frame; lists look items up row by row
local function ItemIndex()
    local now = GetTime()
    if indexFrame ~= now then
        indexByID, indexByName = BuildItemIndex()
        indexFrame = now
    end
    return indexByID, indexByName
end

-- An item's quality tier and how many tiers it has, or nil
function addon:GetItemTier(itemID)
    local item = itemID and ItemIndex()[itemID]
    if item then return item.tier, item.tierCount end
end

-- What you've sold of each item name: { [name] = { name, profession,
-- units, sales, cost, deposits, profit, roi, salesCount, firstSale } }.
-- Sales without cost data use today's estimate; if there's none they're
-- left out of profit (as in the Overview's summary).
local function SalesByItem(prof, since)
    local items = {}
    local function Item(e)
        local item = items[e.item]
        if not item then
            item = { name = e.item, profession = e.profession, units = 0, sales = 0, cost = 0, costedSales = 0,
                deposits = 0, salesCount = 0 }
            items[e.item] = item
        end
        return item
    end
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.item and (prof == "All" or e.profession == prof) and (not since or e.timestamp >= since) then
            if e.type == "REVENUE" then
                local item = Item(e)
                item.units = item.units + e.quantity
                item.sales = item.sales + e.totalCopper
                item.salesCount = item.salesCount + 1
                item.firstSale = math.min(item.firstSale or e.timestamp, e.timestamp)
                local cost = e.costBasis
                if not cost then
                    local unit = addon:GetUnitCostBasis(e.item)
                    cost = unit and unit * e.quantity
                end
                if cost then
                    item.cost = item.cost + cost
                    item.costedSales = item.costedSales + e.totalCopper
                end
            elseif e.kind == "DEPOSIT" then
                local item = Item(e)
                item.deposits = item.deposits + e.totalCopper
            end
        end
    end
    for _, item in pairs(items) do
        item.profit = item.costedSales - item.cost - item.deposits
        item.roi = item.cost > 0 and (item.profit / item.cost * 100) or nil
    end
    return items
end

-- The Items tab's landing page: four leaderboards for a profession and
-- date range key. Returns { profit, roi, fastest, held, days }; each list
-- holds up to BOARD_SIZE { name, itemID (may be nil), value, ... }.
function addon:GetItemBoards(prof, rangeKey)
    local since = addon:DateRangeStart(rangeKey)
    local _, byName = ItemIndex()
    local sold = SalesByItem(prof, since)

    local list = {}
    for _, item in pairs(sold) do
        item.itemID = byName[item.name] and byName[item.name][#byName[item.name]]
        if item.salesCount > 0 then table.insert(list, item) end
    end
    -- Days the range covers: all time counts from your first sale
    local first
    for _, item in ipairs(list) do first = math.min(first or item.firstSale, item.firstSale) end
    local days = addon:GetDateRange(rangeKey).days
        or (first and math.max(math.ceil((time() - first) / 86400), 1)) or 1

    local function Top(filter, key)
        local out = {}
        for _, item in ipairs(list) do
            if filter(item) then table.insert(out, item) end
        end
        table.sort(out, function(a, b) return a[key] > b[key] end)
        for i = #out, BOARD_SIZE + 1, -1 do out[i] = nil end
        return out
    end
    for _, item in ipairs(list) do item.perDay = item.units / days end

    local boards = {
        days = days,
        profit = Top(function(i) return i.profit > 0 end, "profit"),
        roi = Top(function(i) return i.roi and i.roi > 0 and i.salesCount >= MIN_SALES_FOR_ROI end, "roi"),
        fastest = Top(function() return true end, "perDay"),
        held = {},
    }
    local stock = addon:GetStockValue(prof)
    for i = 1, math.min(#stock.heldLong, BOARD_SIZE) do
        local item = stock.heldLong[i]
        table.insert(boards.held, {
            name = item.name, itemID = item.itemID, count = item.count, value = item.value,
            days = math.floor((time() - item.heldSince) / 86400),
        })
    end
    return boards
end

-- Items whose name contains `text` (any case), for the search box: a row
-- per tier. Returns up to `limit` { name, itemID, tier, profession, have,
-- price, demand }, names A-Z, lowest tier first.
function addon:SearchItems(text, prof, limit)
    local byID, byName = ItemIndex()
    local needle = text:lower()
    local list = {}
    for name, ids in pairs(byName) do
        local profession = byID[ids[#ids]].profession
        if name:lower():find(needle, 1, true) and (prof == "All" or profession == prof) then
            for _, id in ipairs(ids) do
                table.insert(list, {
                    name = name, itemID = id, tier = byID[id].tier, profession = profession,
                    have = (addon:GetStock(id)), price = addon:GetMarketPrice(id), demand = addon:GetDemand(id, name),
                })
            end
        end
    end
    table.sort(list, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return (a.tier or 0) < (b.tier or 0)
    end)
    for i = #list, limit + 1, -1 do list[i] = nil end
    return list
end

-- Saved daily prices for the last `days` days (oldest first, days with no
-- price skipped) and the usual range: the middle half of those prices
-- (25th to 75th percentile). Returns points { day, value }, low, high.
local function PriceSeries(itemID, days)
    local history = GoldsmithDB.priceHistory[itemID] or {}
    local points, values = {}, {}
    for i = days - 1, 0, -1 do
        local day = date("%Y-%m-%d", time() - i * 86400)
        if history[day] then
            table.insert(points, { day = day, value = history[day] })
            table.insert(values, history[day])
        end
    end
    if #values < 4 then return points end
    table.sort(values)
    local function At(p) return values[math.max(math.floor(#values * p + 0.5), 1)] end
    return points, At(0.25), At(0.75)
end

-- Everything on an item's page. name is the item's name; itemID picks the
-- tier (default: the tier you hold most of, else the highest).
-- Returns { name, itemID, tier, tierCount, profession, recipe, material,
--   tiers = { { itemID, tier, price, have } },
--   price, priceSource, priceAge, priceText, insight (GetPriceInsight),
--   historyDays, history = { { day, value } }, bandLow, bandHigh,
--   demand, demandSource, saleRate, have, byCharacter, heldSince,
--   crafted: charKey, estimated, partial, worst, stats, concentration,
--            yours (nil if never crafted)
--   bought:  paid, paidSource
--   breakEven, breakEvenFrom ("yours", "paid" or "estimated"),
--   earned = { units, sales, profit } (all time),
--   activity = { { time, kind ("Sold", "Bought", "Posted", "Crafted"),
--                 qty, gold (signed, or unit cost for crafts), partial } } }
function addon:GetItemDetails(name, itemID)
    local byID, byName = ItemIndex()
    local ids = byName[name] or (itemID and { itemID }) or {}
    if not itemID or not byID[itemID] then
        if #ids > 0 then itemID = nil end
        local most = 0
        for _, id in ipairs(ids) do
            local have = addon:GetStock(id)
            if have > most then most, itemID = have, id end
        end
        itemID = itemID or ids[#ids]
    end
    local info = (itemID and byID[itemID]) or {}
    local d = {
        name = name, itemID = itemID, tier = info.tier, tierCount = info.tierCount,
        recipe = info.recipe or addon:FindRecipeByOutput(name), material = info.material,
        tiers = {},
    }
    d.profession = info.profession or (d.recipe and d.recipe.profession) or addon:GetProfessionForItemName(name)
    for _, id in ipairs(ids) do
        table.insert(d.tiers, { itemID = id, tier = byID[id] and byID[id].tier,
            price = addon:GetMarketPrice(id), have = (addon:GetStock(id)) })
    end

    if itemID then
        d.price, d.priceSource, d.priceAge = addon:GetMarketPriceInfo(itemID)
        d.priceText = d.price and addon:PriceAgeText(itemID)
        d.insight, d.historyDays = addon:GetPriceInsight(itemID)
        d.history, d.bandLow, d.bandHigh = PriceSeries(itemID, PRICE_DAYS)
        d.demand, d.demandSource = addon:GetDemand(itemID, name)
        d.saleRate = addon:GetSaleRate(itemID)
        d.have, d.byCharacter = addon:GetStock(itemID)
        d.heldSince = d.have > 0 and HeldSince(itemID, d.have) or nil
    else
        d.history, d.have, d.byCharacter = {}, 0, {}
    end

    local recipe = d.recipe
    if recipe then
        d.charKey = addon:GetCrafter(recipe.recipeID) or addon.charKey
        addon:WithCharacter(d.charKey, function()
            local row
            for _, t in ipairs(addon:GetTierRows(recipe) or {}) do
                if t.tier == d.tier and (not row or (row.concentrate and not t.concentrate)) then row = t end
            end
            row = row or addon:GetRecipeProfit(recipe, itemID)
            d.estimated, d.partial = row.cost, row.partial
            d.worst = addon:GetWorstCaseCost(recipe, row)
            d.concentration = row.concentrate and row.concentration or nil
            d.stats = addon:StatsChar().recipeStats[recipe.recipeID]
        end)
        d.yours = itemID and addon:GetCraftedCost(itemID)
    end
    if not recipe or d.material then
        d.paid, d.paidSource = addon:GetOwnCost(name)
    end
    local basis = d.yours or d.paid or d.estimated
    d.breakEvenFrom = (d.yours and "yours") or (d.paid and "paid") or (d.estimated and "estimated")
    d.breakEven = basis and basis / (1 - AH_CUT)

    local sold = SalesByItem("All")[name]
    d.earned = sold and { units = sold.units, sales = sold.sales, profit = sold.profit } or nil

    d.activity = {}
    local own = {}
    for _, id in ipairs(ids) do own[id] = true end
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.item == name or (e.itemID and own[e.itemID]) then
            local kind = e.type == "REVENUE" and "Sold" or (e.kind == "DEPOSIT" and "Posted" or "Bought")
            table.insert(d.activity, { time = e.timestamp, kind = kind, qty = e.quantity,
                gold = e.type == "REVENUE" and e.totalCopper or -e.totalCopper })
        end
    end
    for _, id in ipairs(ids) do
        for _, lot in ipairs(GoldsmithDB.craftLots[id] or {}) do
            table.insert(d.activity, { time = lot.time, kind = "Crafted", qty = lot.qty, gold = lot.unitCost,
                partial = lot.partial, tier = byID[id] and byID[id].tier })
        end
    end
    table.sort(d.activity, function(a, b) return a.time > b.time end)
    return d
end

_G.Goldsmith = addon
