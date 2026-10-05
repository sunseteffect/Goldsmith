local addon = _G.Goldsmith or {}

-- Insights
--
-- Account-wide answers for the Overview: gold in stock, concentration
-- across characters, the best crafts right now, and gold per hour. Every
-- function takes a profession ("All" for every one) and works across all
-- your characters, using each character's own stats.

-- Days unsold before a crafted item is held too long is a setting (heldDays)
local AH_CUT = 0.05
-- The ROI a craft needs to count as worth doing is a setting (minROI)
local MIN_DEMAND = 1           -- sold per day
local GEAR_MIN_DEMAND = 10     -- sold per day across the region, for gear
local MIN_SALE_RATE = 0.10     -- share of listings that sell (TSM region)
local GOOD_SALE_RATE = 0.25    -- above this, most listings sell (green)

-- Colors for sale rate and sold per day wherever they're shown, from the
-- same thresholds as WhyNotRecommended so the colors and recommendations
-- agree. Sale rate: orange under the cutoff, gold decent, green good. Sold
-- per day: orange under what a recommendation needs, otherwise plain: a
-- big region number is shared by every seller, so it isn't "good" for you.
function addon:SaleRateColor(rate)
    if not rate then return "dim" end
    if rate < MIN_SALE_RATE then return "warning" end
    if rate < GOOD_SALE_RATE then return "gold" end
    return "profit"
end

function addon:DemandColor(demand, itemID)
    if not demand then return "dim" end
    if demand < MIN_DEMAND or (itemID and addon:IsGear(itemID) and demand < GEAR_MIN_DEMAND) then
        return "warning"
    end
    return "text"
end
local ENOUGH_STOCK_CAP = 20    -- see GetBestCrafts

-- Whether a craft is worth recommending: an item from the current
-- expansion that sells at least MIN_DEMAND a day. Items nobody buys (no
-- demand data, or old-expansion items with a few shelf listings) often show
-- huge "profits" from listings that never sell, so they're left out.
-- Gear sells realm by realm, so TSM's region sales are spread over every
-- realm (1 a day region-wide is a sale every few months on yours): it needs
-- GEAR_MIN_DEMAND, or sales of your own at a profit in the last 14 days.
-- Items where few listings ever sell (under MIN_SALE_RATE, from TSM) are
-- left out too: most get relisted or expire, so the profit rarely arrives.
-- Your own profitable sales override that, as for gear.
-- Items the game hasn't loaded yet are left out until it has.
-- Returns nil if it's worth recommending, otherwise why not (plain words).

-- Your sales over the last 14 days averaged at least what the craft costs
-- now (row.cost, per item). A sale at a loss shows people buy it cheap,
-- not that making it pays (a Deadly Amethyst sold for 5.64g against a 46g
-- craft cost).
local function SoldAtProfit(recipe, row)
    local got = addon:GetOwnSalePrice(recipe.outputName)
    return got ~= nil and row.cost ~= nil and got >= row.cost
end

function addon:WhyNotRecommended(recipe, row)
    if addon:IsIgnored(recipe.outputItemID) then
        return "You're ignoring this item. Right-click it to stop, or Settings > Ignored items."
    end
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
    if addon:IsGear(itemID) and demand < GEAR_MIN_DEMAND and not SoldAtProfit(recipe, row) then
        return string.format("Gear sells realm by realm: about %s a day across the whole region is a sale every few weeks or months on yours. Recommended once you've sold one yourself at a profit.",
            addon:FormatDemand(demand))
    end
    local saleRate = row.saleRate or addon:GetSaleRate(itemID)
    if saleRate and saleRate < MIN_SALE_RATE and not SoldAtProfit(recipe, row) then
        local got = addon:GetOwnSalePrice(recipe.outputName)
        return string.format("Only %s of listings sell (TSM region): most sit until they expire.%s",
            addon:FormatSaleRate(saleRate),
            (got and row.cost and got < row.cost)
                and string.format(" Yours sold for %s each lately, less than it costs to make.", addon:FormatMoney(got))
                or " Recommended once you've sold one yourself at a profit.")
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
-- heldLong = crafted items held the heldDays setting or more, heldLongValue }.
-- Cached until data changes, per profession and which characters count.
local stockCache = addon:NewCache()
local StockValue

function addon:GetStockValue(prof)
    local excluded = {}
    for key in pairs(addon:Setting("excluded") or {}) do table.insert(excluded, key) end
    table.sort(excluded)
    local id = prof .. "|" .. table.concat(excluded, ",")
    local store = stockCache:Get()
    store[id] = store[id] or StockValue(prof)
    return store[id]
end

StockValue = function(prof)
    local outputs = GetOutputRecipes()
    local materials = addon:GetTrackedMaterials()
    local ids = {}
    for _, c in pairs(GoldsmithDB.characters) do
        for itemID in pairs(c.stock) do ids[itemID] = true end
    end
    for itemID in pairs(GoldsmithDB.warbandStock) do ids[itemID] = true end

    local result = { value = 0, items = {}, heldLong = {}, heldLongValue = 0 }
    local cutoff = time() - addon:Setting("heldDays") * 86400
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
--
-- Plans are cached until data changes, per character, profession and
-- amount of concentration (which only goes up a point every few minutes).
--
-- Concentration comes back slowly, so it's only worth spending on crafts
-- that earn at least MIN_CONC_VALUE extra gold per point. When it's full,
-- or will be within NEAR_FULL_MINUTES, what comes back would be wasted, so
-- any profitable use is suggested.
local MIN_CONC_VALUE = 0.5 * 10000   -- copper per concentration point
local NEAR_FULL_MINUTES = 24 * 60
local GOOD_CONC_VALUE = 1.5 * 10000  -- copper per point; above this it's a good use
local planCache = addon:NewCache()

-- The theme color for a rate of extra gold per concentration point:
-- "warning" under the floor (only suggested because concentration is
-- nearly full), "gold" for decent, "profit" for good. No red: a planned
-- craft always makes a profit.
function addon:ConcentrationValueColor(copper)
    if not copper or copper < MIN_CONC_VALUE then return "warning" end
    if copper < GOOD_CONC_VALUE then return "gold" end
    return "profit"
end

local function NearFull(current, max, minutesToFull)
    return current >= max or (minutesToFull ~= nil and minutesToFull <= NEAR_FULL_MINUTES)
end

local function CachedPlan(key, profession, current, nearFull)
    local store = planCache:Get()
    local id = string.format("%s:%s:%d:%s", key, profession, current, tostring(nearFull))
    local cached = store[id]
    if not cached then
        local function Accept(recipe, row)
            if not nearFull and (row.concentrationValue or 0) < MIN_CONC_VALUE then return false end
            return IsRecommendable(recipe, row)
        end
        local plan, used, gain = addon:WithCharacter(key, addon.PlanConcentration, addon,
            profession, current, Accept)
        cached = { plan = plan, used = used, gain = gain }
        store[id] = cached
    end
    return cached.plan, cached.used, cached.gain
end

function addon:GetConcentrationOverview(prof)
    local result = { current = 0, max = 0, gain = 0, rows = {} }
    for _, entry in ipairs(addon:GetCharacters()) do
        -- Characters excluded in Settings have no professions here
        local professions = addon:IsCharacterIncluded(entry.key) and entry.data.professions or {}
        for profession in pairs(professions) do
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
                    local plan, used, gain = CachedPlan(entry.key, profession, math.floor(current),
                        NearFull(current, max, minutesToFull))
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

-- Characters who know a recipe: you first, then by name. Excluded
-- characters only count when nobody else knows it (for item tooltips and
-- pages); the Crafts tab and recommendations leave those recipes out.
function addon:GetCrafters(recipeID)
    local included, excluded = {}, {}
    for key, c in pairs(GoldsmithDB.characters) do
        if c.knownRecipes[recipeID] then
            table.insert(addon:IsCharacterIncluded(key) and included or excluded, key)
        end
    end
    local list = #included > 0 and included or excluded
    table.sort(list, function(a, b)
        if (a == addon.charKey) ~= (b == addon.charKey) then return a == addon.charKey end
        return a < b
    end)
    return list
end
local function CrafterFor(recipeID) return addon:GetCrafter(recipeID) end

-- Identifies one way of making a craft (recipe, tier, with or without
-- concentration), so the Overview can point the Crafts tab at it
function addon:CraftKey(recipeID, row)
    return string.format("%d:%d:%s", recipeID, row.tier or 0, row.concentrate and "c" or "")
end

-- The "Show cost as" setting (Settings.lua). With "worst", a copy of a
-- Crafts row with cost, profit and ROI worked out from the worst case (no
-- procs), keeping the estimate as estimatedCost. Rows are shared (tier
-- rows are cached per frame), so they're copied, never changed. Call it
-- with the crafter's stats in use (WithCharacter).
local function ApplyCostMode(recipe, row)
    if not row or addon:Setting("costMode") ~= "worst" then return row end
    local worst = addon:GetWorstCaseCost(recipe, row)
    if not worst then return row end
    local copy = {}
    for k, v in pairs(row) do copy[k] = v end
    copy.estimatedCost, copy.cost, copy.costMode = row.cost, worst, "worst"
    if row.price then
        copy.profit = row.price * (1 - AH_CUT) - worst
        copy.margin = worst > 0 and (copy.profit / worst * 100) or nil
    end
    return copy
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

-- Who makes a recipe best without concentration: of the characters who
-- know it, the one whose stats give the most profit (or, with no AH price,
-- the lowest cost). Ties go to you, then by name. Each character's row is
-- cached until data changes; who's excluded is applied on top, so
-- excluding a character needs no new work.
-- Returns the crafter's key and { [charKey] = best plain row } for each
-- character who could make it, or nil if nobody does.
local plainRowCache = addon:NewCache()

-- A character's best plain row for a recipe, with the "Show cost as"
-- setting applied, and items made per craft
local function PlainRowFor(charKey, recipe)
    local store = plainRowCache:Get()
    local key = charKey .. ":" .. recipe.recipeID
    local cached = store[key]
    if not cached then
        local row, outputPerCraft = addon:WithCharacter(charKey, function()
            local r = ApplyCostMode(recipe, BestPlainRow(recipe))
            return r, r and (r.outputPerCraft or addon:GetCraftModel(recipe))
        end)
        cached = { row = row or false, outputPerCraft = outputPerCraft or 1 }
        store[key] = cached
    end
    return cached.row or nil, cached.outputPerCraft
end

local function Better(a, b)
    if not b then return true end
    if a.profit and b.profit then return a.profit > b.profit + 0.5 end
    if a.cost and b.cost then return a.cost < b.cost - 0.5 end
    return false
end

function addon:GetCrafterInfo(recipeID)
    local recipe = GoldsmithDB.recipes[recipeID]
    local crafters = addon:GetCrafters(recipeID)
    local best, bestRow, rows = crafters[1], nil, {}
    if recipe and #crafters > 1 then
        -- Sorted with you first, so a tie keeps you
        for _, key in ipairs(crafters) do
            local row = PlainRowFor(key, recipe)
            rows[key] = row
            if row and Better(row, bestRow) then best, bestRow = key, row end
        end
    end
    return best, rows
end

-- The character who makes a recipe best (see GetCrafterInfo), or nil
function addon:GetCrafter(recipeID)
    return (addon:GetCrafterInfo(recipeID))
end

-- When someone else makes a recipe better than you and you know it too:
-- their key, how much better per item, and "profit" (more profit) or
-- "cost" (cheaper, when there's no AH price). Else nil.
function addon:GetBetterCrafter(recipeID)
    local best, rows = addon:GetCrafterInfo(recipeID)
    if not best or best == addon.charKey then return nil end
    local mine, theirs = rows[addon.charKey], rows[best]
    if not (mine and theirs) then return nil end
    if mine.profit and theirs.profit then return best, theirs.profit - mine.profit, "profit" end
    if mine.cost and theirs.cost then return best, mine.cost - theirs.cost, "cost" end
end

-- "12.34g more profit each than you" / "12.34g cheaper each than you", or
-- nil when you don't know the recipe or make it best yourself
function addon:BetterCrafterText(recipeID)
    local _, gain, kind = addon:GetBetterCrafter(recipeID)
    if not gain or gain <= 0 then return nil end
    return string.format(kind == "profit" and "%s more profit each than you" or "%s cheaper each than you",
        addon:FormatMoney(gain))
end

-- The most profitable crafts right now, across professions and characters:
-- an ROI of at least the "Worth crafting at" setting, worth recommending
-- (IsRecommendable), with all material costs known. Most profit per item
-- first. Costs follow the "Show cost as" setting.
--
-- Suggests how many to make (SuggestedQuantity). Once you've made it, the
-- craft drops off, and it comes back only when you've sold every one you
-- hold: never more while some sit unsold, in case the market turns.
-- Crafts whose crafter is excluded aren't recommended.
-- Returns up to `count` { recipe, row, charKey, profit, margin, demand,
-- have, make (items to make), makeReason, outputPerCraft }.
function addon:GetBestCrafts(prof, count)
    local list = {}
    for recipeID, recipe in pairs(GoldsmithDB.recipes) do
        if (prof == "All" or recipe.profession == prof) and addon:CanAuction(recipe.outputItemID) ~= false then
            local charKey = CrafterFor(recipeID)
            if charKey and addon:IsCharacterIncluded(charKey) then
                local row, outputPerCraft = PlainRowFor(charKey, recipe)
                if row and row.profit and row.profit > 0 and not row.partial
                    and (row.margin or 0) >= addon:Setting("minROI") and IsRecommendable(recipe, row) then
                    local itemID = row.itemID or recipe.outputItemID
                    -- In bags, banks or listed on the AH, on any character
                    local have = itemID and addon:GetHeld(itemID, row.tier) or 0
                    if have == 0 then
                        local make, makeReason = addon:SuggestedQuantity(recipe.outputName)
                        table.insert(list, {
                            key = addon:CraftKey(recipeID, row),
                            recipe = recipe, row = row, charKey = charKey, itemID = itemID,
                            profit = row.profit, margin = row.margin, demand = row.demand, have = have,
                            make = make, makeReason = makeReason, outputPerCraft = outputPerCraft,
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

-- Recipes a material goes into, that a counted character knows, each made
-- by whoever makes it best, with its profit without concentration. Only
-- crafts worth recommending (WhyNotRecommended): gear nobody buys and
-- old-expansion items are left out, but ones selling at a loss today stay.
-- Returns { { recipe, charKey, profit (nil without a price), demand (sold
-- per day), saleRate } }, most profit first.
function addon:GetRecipesUsing(itemID)
    local list = {}
    for recipeID, recipe in pairs(GoldsmithDB.recipes) do
        local uses = false
        for _, slot in ipairs(recipe.reagents or {}) do
            for _, id in ipairs(slot.itemIDs or {}) do
                if id == itemID then uses = true end
            end
        end
        local charKey = uses and CrafterFor(recipeID)
        if charKey and addon:IsCharacterIncluded(charKey) then
            local row = PlainRowFor(charKey, recipe)
            if row and IsRecommendable(recipe, row) then
                local outputID = row.itemID or recipe.outputItemID
                table.insert(list, {
                    recipe = recipe, charKey = charKey, profit = row.profit, itemID = outputID,
                    demand = row.demand or addon:GetDemand(outputID, recipe.outputName),
                    saleRate = row.saleRate or addon:GetSaleRate(outputID),
                })
            end
        end
    end
    table.sort(list, function(a, b)
        if (a.profit ~= nil) ~= (b.profit ~= nil) then return a.profit ~= nil end
        if a.profit and a.profit ~= b.profit then return a.profit > b.profit end
        return a.recipe.outputName < b.recipe.outputName
    end)
    return list
end

-- How many to make
--
-- Deliberately cautious: better to sell out and make more than to sit on
-- items the market has moved away from. Region sales (TSM) are every
-- seller's, so they aren't used; your own are:
--   sold some in the last SALES_DAYS days: a day's worth of your sales
--     (the average, rounded down, at least 1)
--   never sold it: a first batch of FIRST_BATCH
-- Capped at ENOUGH_STOCK_CAP. Returns the count and why, in plain words.
local SALES_DAYS = 7
local FIRST_BATCH = 3
local salesCache = addon:NewCache()

-- Units of each item (by name) you sold in the last SALES_DAYS days
local function RecentSales()
    local store = salesCache:Get()
    if not store.sold then
        local sold, since = {}, time() - SALES_DAYS * 86400
        for _, e in ipairs(addon.ledger:getAll()) do
            if e.type == "REVENUE" and e.timestamp >= since and e.item then
                sold[e.item] = (sold[e.item] or 0) + (e.quantity or 1)
            end
        end
        store.sold = sold
    end
    return store.sold
end

function addon:SuggestedQuantity(itemName)
    local sold = itemName and RecentSales()[itemName] or 0
    if sold > 0 then
        local perDay = math.max(math.floor(sold / SALES_DAYS), 1)
        return math.min(perDay, ENOUGH_STOCK_CAP),
            string.format("a day's worth (you sold %d in the last %d days)", sold, SALES_DAYS)
    end
    return FIRST_BATCH, string.format("a first batch of %d (you haven't sold any in the last %d days)", FIRST_BATCH, SALES_DAYS)
end

-- A to-do list per character: what "Do this next" suggests, split by who
-- should do it. Each character's concentration plan (see
-- GetConcentrationOverview), and the best crafts (GetBestCrafts) they make
-- best, as many as cover about a day's sales less what you hold. Items
-- already in a concentration plan count toward that, so the two don't add
-- up to more than sells.
-- Returns { [charKey] = { total, items = { { recipe, row, itemID,
-- tierCount, crafts, quantity (items made), profit (all crafts),
-- concentration (points, or nil) } } (most profit first) } } for included
-- characters with something to do.
function addon:GetCharacterTodo(prof, conc)
    conc = conc or addon:GetConcentrationOverview(prof)
    local todo, planned = {}, {}
    local function Add(charKey, item)
        todo[charKey] = todo[charKey] or { total = 0, items = {} }
        table.insert(todo[charKey].items, item)
        todo[charKey].total = todo[charKey].total + item.profit
    end

    for _, r in ipairs(conc.rows) do
        for _, p in ipairs(r.plan or {}) do
            local itemID = p.row.itemID or p.recipe.outputItemID
            local quantity = math.max(math.floor(p.crafts * (p.row.outputPerCraft or 1)), 1)
            if itemID then planned[itemID] = (planned[itemID] or 0) + quantity end
            Add(r.key, {
                recipe = p.recipe, row = p.row, itemID = itemID, tierCount = p.tierCount,
                crafts = p.crafts, quantity = quantity, profit = p.profit, concentration = p.points,
            })
        end
    end

    for _, c in ipairs(addon:GetBestCrafts(prof, math.huge)) do
        local make = c.make - (c.itemID and planned[c.itemID] or 0)
        if make > 0 then
            Add(c.charKey, {
                recipe = c.recipe, row = c.row, itemID = c.itemID, tierCount = c.row.tierCount,
                crafts = math.max(math.ceil(make / c.outputPerCraft), 1), quantity = make,
                profit = c.profit * make, why = c.makeReason,
            })
        end
    end

    for _, t in pairs(todo) do
        table.sort(t.items, function(a, b) return a.profit > b.profit end)
    end
    return todo
end

-- Every craft for the Crafts tab. The ways without concentration are
-- worked out with the stats of whoever makes it best (see GetCrafter); the
-- ways with concentration get a row for each character who knows it, with
-- their own stats, since each has their own concentration to spend.
-- Crafts with quality tiers get a row per
-- reachable tier (see GetTierRows), the rest a single row. Crafts that
-- can't be listed on the AH (bind on pickup, warbound) are left out; items
-- not in the game's cache yet are shown until their bind type loads.
-- opts:
--   concentration  - include the ways that use concentration
--   onlyMine       - only recipes the logged-in character knows, all made
--                    by them with their stats (not whoever makes it best)
--   profitableOnly - only rows with a profit at current prices and an ROI
--                    of at least the "Worth crafting at" setting (including
--                    ones with unknown costs, whose profit is at most that)
-- Costs follow the "Show cost as" setting.
--   showExpansion  - function(expansionID) -> whether to include it
--   showIgnored    - include ignored items (Settings > Ignored items)
--   match          - function(names) -> whether to include it, checked
--                    before any costing so a search only works out matches
-- Returns { { key, recipe, info (the tier row or GetRecipeProfit), tier,
-- charKey, itemID, whyNot (see WhyNotRecommended) } }, unsorted.
local craftRowsCache = addon:NewCache()

function addon:GetCraftRows(prof, opts)
    local list = {}
    for recipeID, recipe in pairs(GoldsmithDB.recipes) do
        if (prof == "All" or recipe.profession == prof)
            and (not opts.onlyMine or addon.char.knownRecipes[recipeID])
            and addon:CanAuction(recipe.outputItemID) ~= false
            and (not opts.showExpansion or opts.showExpansion(addon:GetRecipeExpansion(recipe)))
            and (opts.showIgnored or not addon:IsIgnored(recipe.outputItemID))
            and (not opts.match or opts.match({ recipe.outputName, recipe.name }))
            -- Recipes only excluded characters know are left out
            and (opts.onlyMine or addon:IsCharacterIncluded(CrafterFor(recipeID) or addon.charKey)) then
            local charKey = opts.onlyMine and addon.charKey or CrafterFor(recipeID) or addon.charKey
            -- Rows for one character: the plain ways or the concentration
            -- ways (cached until data changes)
            local function RowsFor(key, concentrate)
                local store = craftRowsCache:Get()
                local id = string.format("%s:%d:%s", key, recipeID, concentrate and "c" or "")
                if store[id] then return store[id] end
                store[id] = addon:WithCharacter(key, function()
                    local tierRows = addon:GetTierRows(recipe)
                    if not tierRows or #tierRows == 0 then tierRows = { addon:GetRecipeProfit(recipe) } end
                    local shown = {}
                    for _, row in ipairs(tierRows) do
                        if (row.concentrate and true or false) == concentrate then
                            table.insert(shown, ApplyCostMode(recipe, row))
                        end
                    end
                    return shown
                end)
                return store[id]
            end
            local sets = { { key = charKey, rows = RowsFor(charKey, false) } }
            if opts.concentration then
                local crafters = opts.onlyMine and { charKey } or addon:GetCrafters(recipeID)
                if #crafters == 0 then crafters = { charKey } end
                for _, key in ipairs(crafters) do
                    if opts.onlyMine or addon:IsCharacterIncluded(key) then
                        table.insert(sets, { key = key, rows = RowsFor(key, true) })
                    end
                end
            end
            local minROI = addon:Setting("minROI")
            for _, set in ipairs(sets) do
                for _, info in ipairs(set.rows) do
                    if not opts.profitableOnly
                        or (info.profit and info.profit > 0 and (not info.margin or info.margin >= minROI)) then
                        table.insert(list, {
                            key = addon:CraftKey(recipeID, info),
                            recipe = recipe, info = info, tier = info.tier, charKey = set.key,
                            itemID = info.itemID or recipe.outputItemID,
                            whyNot = addon:WhyNotRecommended(recipe, info),
                            ignored = addon:IsIgnored(recipe.outputItemID),
                        })
                    end
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
    -- Not crafted yet: the cost the "Show cost as" setting picks
    local worstMode = addon:Setting("costMode") == "worst" and d.worst
    local basis = d.yours or d.paid or (worstMode and d.worst) or d.estimated
    d.breakEvenFrom = (d.yours and "yours") or (d.paid and "paid") or (worstMode and "worst")
        or (d.estimated and "estimated")
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

-- History tab
--
-- Every sale, purchase and AH deposit from the ledger, plus crafts from the
-- craft lots (the last 30 crafts of each item; they're kept for costs, so
-- they can't be deleted here, and don't record who crafted them).
-- filters: prof ("All" or one), since (a time or nil), kind ("Sale",
-- "Purchase", "Deposit", "Craft" or nil for all), character ("Name-Realm"
-- or nil), item (a name or nil).
-- Crafts for crafting orders (GoldsmithDB.orderCrafts) are "Order" rows.
-- Returns rows newest first: { kind, time, item, itemID, qty, gold (signed;
-- nil for crafts), profit, costSource (sales: see GetUnitCostBasis, or
-- "today" for today's estimate), profitEstimated, cost (crafts: per item),
-- partial, profession, character (key), entry (the ledger entry), lot
-- (crafts) }, and totals { gold in, gold out }.
function addon:GetHistory(filters)
    -- Once per session, when prices are in (see RepairOrderLots)
    if not addon.orderLotsRepaired then
        addon.orderLotsRepaired = true
        addon:RepairOrderLots()
    end
    local rows, totals = {}, { goldIn = 0, goldOut = 0 }
    local estimates = {}
    local function Estimate(name)
        if estimates[name] == nil then estimates[name] = addon:GetUnitCostBasis(name) or false end
        return estimates[name] or nil
    end
    -- Sales saved before sales kept their cost's source: a crafted item
    -- sold before Goldsmith saw you craft it had its cost estimated
    local firstCraft, recipes = {}, {}
    for _, lots in pairs(GoldsmithDB.craftLots) do
        for _, lot in ipairs(lots) do
            if lot.name then firstCraft[lot.name] = math.min(firstCraft[lot.name] or lot.time, lot.time) end
        end
    end
    local function WasEstimated(e)
        if recipes[e.item] == nil then recipes[e.item] = addon:FindRecipeByOutput(e.item) ~= nil end
        return recipes[e.item] and not (firstCraft[e.item] and firstCraft[e.item] <= e.timestamp)
    end
    local function Keep(kind, t, item, profession, character)
        return (not filters.kind or filters.kind == kind)
            and (not filters.since or t >= filters.since)
            and (not filters.item or filters.item == item)
            and (filters.prof == "All" or profession == filters.prof)
            and (not filters.character or filters.character == character)
    end

    for _, e in ipairs(addon.ledger:getAll()) do
        local kind = e.type == "REVENUE" and "Sale" or (e.kind == "DEPOSIT" and "Deposit" or "Purchase")
        local character = e.character and e.realm and (e.character .. "-" .. e.realm)
        if Keep(kind, e.timestamp, e.item, e.profession, character) then
            local row = {
                kind = kind, time = e.timestamp, item = e.item, itemID = e.itemID, qty = e.quantity,
                gold = kind == "Sale" and e.totalCopper or -e.totalCopper,
                profession = e.profession, character = character, entry = e,
            }
            if kind == "Sale" then
                local cost = e.costBasis
                if cost then
                    row.partial = e.costPartial
                    row.costSource = e.costSource or (WasEstimated(e) and "estimated") or nil
                else
                    local unit = Estimate(e.item)
                    cost = unit and unit * e.quantity
                    row.costSource = cost and "today"
                end
                row.profitEstimated = row.costSource == "estimated" or row.costSource == "today"
                row.cost = cost
                row.profit = cost and (e.totalCopper - cost)
                totals.goldIn = totals.goldIn + e.totalCopper
            else
                totals.goldOut = totals.goldOut + e.totalCopper
            end
            table.insert(rows, row)
        end
    end

    -- Crafts have no character, so they only show for all characters
    if not filters.character then
        for itemID, lots in pairs(GoldsmithDB.craftLots) do
            for _, lot in ipairs(lots) do
                local recipe = lot.name and addon:FindRecipeByOutput(lot.name)
                local profession = recipe and recipe.profession or addon:GetProfessionForItemName(lot.name or "")
                if lot.name and Keep("Craft", lot.time, lot.name, profession, nil) then
                    table.insert(rows, {
                        kind = "Craft", time = lot.time, item = lot.name, itemID = itemID, qty = lot.qty,
                        cost = lot.unitCost, partial = lot.partial, profession = profession, lot = lot,
                    })
                end
            end
        end
        for _, lot in ipairs(GoldsmithDB.orderCrafts or {}) do
            local recipe = lot.name and addon:FindRecipeByOutput(lot.name)
            local profession = recipe and recipe.profession or addon:GetProfessionForItemName(lot.name or "")
            if lot.name and Keep("Order", lot.time, lot.name, profession, nil) then
                -- The commission is gold in; profit adds the materials you
                -- kept and sellable rewards, less your own materials
                -- (orders saved before commissions were recorded have neither)
                local commission = lot.commission
                table.insert(rows, {
                    kind = "Order", time = lot.time, item = lot.name, itemID = lot.itemID, qty = lot.qty,
                    cost = lot.unitCost, partial = lot.partial, profession = profession, lot = lot,
                    gold = commission,
                    profit = commission and (commission + (lot.kept or 0) + (lot.rewardsValue or 0)
                        - (lot.unitCost or 0) * (lot.qty or 0)),
                })
                if commission then totals.goldIn = totals.goldIn + commission end
            end
        end
    end
    table.sort(rows, function(a, b) return a.time > b.time end)
    return rows, totals
end

-- Characters with ledger entries, for History's filter: { { key, name } }
-- by name
function addon:GetHistoryCharacters()
    local seen, list = {}, {}
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.character and e.realm then
            local key = e.character .. "-" .. e.realm
            if not seen[key] then
                seen[key] = true
                table.insert(list, { key = key, name = e.character })
            end
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

_G.Goldsmith = addon
