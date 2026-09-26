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
local function IsRecommendable(recipe, row)
    local itemID = row.itemID or recipe.outputItemID
    if not itemID or addon:GetItemExpansion(itemID) ~= addon:GetCurrentExpansion() then
        return false
    end
    local demand = row.demand or addon:GetDemand(itemID, recipe.outputName)
    return demand ~= nil and demand >= MIN_DEMAND
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
-- otherwise the first character (by name) that does
local function CrafterFor(recipeID)
    if addon.char.knownRecipes[recipeID] then return addon.charKey end
    local best
    for key, c in pairs(GoldsmithDB.characters) do
        if c.knownRecipes[recipeID] and (not best or key < best) then best = key end
    end
    return best
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

_G.Goldsmith = addon
