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
local SLOW_MIN_ROI = 50        -- ROI (%) a slow seller needs (Goldsmith Data, no TSM)
local SLOW_MAX_BATCH = 2       -- and how many of it to make at a time
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
    -- Without TSM it's your own sales (GetDemand), which only show it sells
    -- at least that fast, so a low number isn't a warning
    if not addon:HasTSM() then return "text" end
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
-- shownExpansions: the Crafts tab judges older crafts on their sales too
-- when you've picked their expansion in the header (user, 2026-10-07);
-- everything else (Do this next, to-dos, concentration) stays current only.
-- Returns nil if it's worth recommending, otherwise why not (plain words).

-- Your sales over the last 14 days averaged at least what the craft costs
-- now (row.cost, per item). A sale at a loss shows people buy it cheap,
-- not that making it pays (a Deadly Amethyst sold for 5.64g against a 46g
-- craft cost).
local function SoldAtProfit(recipe, row)
    local got = addon:GetOwnSalePrice(recipe.outputName)
    return got ~= nil and row.cost ~= nil and got >= row.cost
end

local WhyNotBase

-- How many to make in one batch of an item: SuggestedQuantity on the
-- region's sales, at most SLOW_MAX_BATCH of a slow seller. Returns make
-- and why.
function addon:SuggestedBatch(recipe, itemID)
    local demand, source = addon:GetDemand(itemID, recipe.outputName)
    local make, makeReason = addon:SuggestedQuantity(recipe.outputName,
        source == "TSM region" and demand or nil)
    if not addon:HasTSM() and addon:GetSellLevel(itemID) == addon.SELL_LEVEL.slow
        and make > SLOW_MAX_BATCH then
        make = SLOW_MAX_BATCH
        makeReason = makeReason .. string.format(", at most %d: it sells slowly", SLOW_MAX_BATCH)
    end
    return make, makeReason
end

-- Also "Worth a to-do at": a batch has to make that much in all, on the
-- Crafts list too, not only the to-dos (user, 2026-10-22: Spellfire Filet
-- at +0.31g was recommended with the setting at 5g)
function addon:WhyNotRecommended(recipe, row, shownExpansions)
    local why = WhyNotBase(recipe, row, shownExpansions)
    if why then return why end
    local minLine = (addon:Setting("minLine") or 0) * 10000
    if minLine > 0 and row.profit and row.profit > 0 then
        local make = addon:SuggestedBatch(recipe, row.itemID or recipe.outputItemID)
        if row.profit * make < minLine then
            return string.format("A batch of %d makes about %s, under your %s (Settings > Worth a to-do at).",
                make, addon:FormatMoney(row.profit * make), addon:FormatMoney(minLine))
        end
    end
end

WhyNotBase = function(recipe, row, shownExpansions)
    if addon:IsIgnored(recipe.outputItemID) then
        return "You're ignoring this item. Right-click it to stop, or Settings > Ignored crafts."
    end
    local snoozed, untilTime = addon:IsSnoozed(recipe.outputItemID)
    if snoozed then
        return string.format("You hid it from suggestions (Not this) until %s. 'N hidden' by Do this next brings it back sooner.",
            date("%a %H:%M", untilTime))
    end
    local itemID = row.itemID or recipe.outputItemID
    local expansion = itemID and addon:GetItemExpansion(itemID)
    if not expansion then return "The game hasn't loaded this item yet." end
    -- The recipe's expansion too: the game tags some old items as current
    -- (Relic of the Past II, made by Classic to Kul Tiran recipes, was
    -- recommended at +256g, 2026-10-11)
    local current = addon:GetCurrentExpansion()
    if (expansion ~= current or addon:GetRecipeExpansion(recipe) ~= current)
        and not (shownExpansions and addon:IsExpansionShown(addon:GetRecipeExpansion(recipe))) then
        return "From an older expansion. Its listings often sit unsold, so the profit may not be real. Pick its expansion at the top to judge it on its sales."
    end
    -- A bound box you've opened (Bouquet of Herbs): no sales of its own, it's
    -- worth the materials inside, which sell (user, 2026-10-11: worth making
    -- for what's inside)
    if addon:CanAuction(itemID) == false and addon:GetBoxValue(itemID) then return nil end
    -- Its gold tier, not opened yet: "No sales data" read wrong (2026-10-27)
    if addon:IsBox(itemID, recipe.outputItemID) then return "No worth yet: open one and Goldsmith notes what's inside." end
    -- Without TSM, Goldsmith Data's sell level decides (TSM comes first
    -- when it's installed). Gear isn't in it (realm by realm), so it goes on
    -- to the rules below.
    local level = not addon:HasTSM() and addon:GetSellLevel(itemID)
    if level == addon.SELL_LEVEL.hardly and not SoldAtProfit(recipe, row) then
        return "Hardly sells: few sales across the region this past week (Goldsmith Data)."
    elseif level == addon.SELL_LEVEL.slow and (row.margin or 0) < SLOW_MIN_ROI and not SoldAtProfit(recipe, row) then
        return string.format("Sells slowly across the region (Goldsmith Data): worth it from %d%% ROI.", SLOW_MIN_ROI)
    elseif level then
        return nil
    end
    local demand, source = row.demand, row.demandSource
    if not demand then demand, source = addon:GetDemand(itemID, recipe.outputName) end
    if demand == nil then return "No sales data, so there's no telling whether it sells." end
    -- Only the region's sales (TSM) can say it sells too slowly: your own
    -- only show what you made and sold (user, 2026-10-09)
    if demand < MIN_DEMAND and source == "TSM region" then
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

-- Mass Mill and Mass Prospect recipes report the herb or ore they use up
-- as what they make (20 Elethium Ore -> 1 Elethium Ore). They're salvage,
-- shown as salvage rows (Milling.lua), not crafts.
function addon:IsSalvageRecipe(recipe)
    local output = recipe.outputItemID
    if not output then return false end
    for _, reagent in ipairs(recipe.reagents or {}) do
        for _, itemID in pairs(reagent.itemIDs or {}) do
            if itemID == output then return true end
        end
    end
    return false
end

-- Only current-expansion items are recommended (WhyNotRecommended), so
-- lists of recommendations skip other recipes before costing them: costing
-- every expansion's recipes on every character was most of the work
local function MakesCurrentItem(recipe)
    return recipe.outputItemID ~= nil
        and addon:GetItemExpansion(recipe.outputItemID) == addon:GetCurrentExpansion()
        and addon:GetRecipeExpansion(recipe) == addon:GetCurrentExpansion()
        and not addon:IsSalvageRecipe(recipe)
end

-- Crafted items: item ID -> recipe, for every recipe output including each
-- quality tier's item (from any character's tier data)
local function GetOutputRecipes()
    local outputs = {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        if recipe.outputItemID then outputs[recipe.outputItemID] = recipe end
    end
    -- Lists rather than pairs(), so the work can wait for a frame
    for _, key in ipairs(addon:Keys(GoldsmithDB.characters)) do
        local tierData = GoldsmithDB.characters[key].tierData
        for n, recipeID in ipairs(addon:Keys(tierData)) do
            if n % 8 == 0 then addon:Yield() end
            local td = tierData[recipeID]
            local recipe = GoldsmithDB.recipes[recipeID]
            if recipe and td then
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
    for _, e in ipairs(addon.ledger:index().purchasesByID[itemID] or {}) do
        table.insert(acquired, { time = e.timestamp, qty = e.quantity })
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

-- Held time only means something for stock you're trying to sell, so it's
-- only worked out for items that are (user, 2026-10-06: vendor items,
-- soulbound treatises and inks kept for crafting made it noise):
--   crafted by you (craft lots), and
--   sellable on the AH (not soulbound or warbound, not sold by vendors), and
--   not a material for your own crafts, unless some are listed on the AH
--     now or were posted in the last LISTED_DAYS days (then it's for sale)
local LISTED_DAYS = 7
local postedCache = addon:NewCache()

-- Names of items you posted on the AH in the last LISTED_DAYS days
local function RecentlyPosted()
    local store = postedCache:Get()
    if not store.names then
        local names, since = {}, time() - LISTED_DAYS * 86400
        for _, e in ipairs(addon.ledger:getAll()) do
            if e.type == "COST" and e.kind == "DEPOSIT" and e.timestamp >= since and e.item then
                names[e.item] = true
            end
        end
        store.names = names
    end
    return store.names
end

local function ListedNow(itemID)
    for _, c in pairs(GoldsmithDB.characters) do
        if c.auctions and (c.auctions[itemID] or 0) > 0 then return true end
    end
    return false
end

-- materials: GetTrackedMaterials(), passed in when the caller has it
local function IsForSale(itemID, name, materials)
    local lots = GoldsmithDB.craftLots[itemID]
    if not lots or #lots == 0 then return false end
    if addon:IsKept(itemID) then return false end
    if addon:CanAuction(itemID) == false or addon:IsVendorItem(itemID) then return false end
    materials = materials or addon:GetTrackedMaterials()
    if materials[itemID] then
        return ListedNow(itemID) or (name ~= nil and RecentlyPosted()[name] == true)
    end
    return true
end

-- Gold in stock: everything Goldsmith tracks, on every character and in the
-- warband bank, valued at what it cost you (crafted items at your latest
-- crafts' cost, materials at what you paid or milled), or the AH price when
-- there's no cost.
-- Returns { value, items = { { itemID, name, count, unitValue, value,
-- crafted, heldSince, byCharacter } } (most valuable first),
-- heldLong = items for sale (IsForSale) held the heldDays setting or more,
-- heldLongValue }. heldSince is only set for items for sale.
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

-- Sell now: what you've held the heldDays setting or more (the Held board)
-- that today's AH price would sell above its break-even. Light's Potential,
-- held 26 days at a 17.08g break-even, was 20.60g for one day (Oct 18) and
-- nobody noticed; the user sold all 54 under cost a week later (2026-10-27).
-- Returns { { itemID, name, count, price, cost, breakEven, each, gain,
-- days } }, most gold first. Only from a real cost (crafted or paid), as
-- the post warning, and a profit of at least SELL_NOW_MIN of the cost and
-- SELL_NOW_MIN_GOLD in all.
local SELL_NOW_MIN = 0.02
-- Gear, tools and accessories (IsGear: anything you can equip but bags):
-- an Apprentice Jeweler's Apron and a Repair Hammer were told "sell now"
-- (2026-10-27)
local function Wearable(itemID)
    return addon:IsGear(itemID)
end
-- Not worth a callout under this in all (2 Repair Hammers, +4.60g)
local SELL_NOW_MIN_GOLD = 10 * 10000
-- Posted in the last SELL_NOW_POSTED_HOURS, or on the AH now: already being
-- sold. 2 Soul Cipher were told "sell now" right after they were posted
-- (the stock count hadn't caught up; user, 2026-10-27).
local SELL_NOW_POSTED_HOURS = 24
local function PostedLately()
    local names, since = {}, time() - SELL_NOW_POSTED_HOURS * 3600
    local all = addon.ledger:getAll()
    for i = #all, 1, -1 do
        local e = all[i]
        if e.timestamp and e.timestamp >= since and e.type == "COST" and e.kind == "DEPOSIT" and e.item then
            names[e.item] = true
        end
    end
    return names
end

function addon:GetSellNow()
    local list = {}
    local posted = PostedLately()
    for _, item in ipairs(addon:GetStockValue("All").heldLong) do
        addon:Yield()
        -- Not gear or tools: one realm's listing that may never sell (an
        -- Apprentice Jeweler's Apron "above break-even" at 953g, 2026-10-27)
        local selling = posted[item.name] or ListedNow(item.itemID)
        local price = not selling and not Wearable(item.itemID) and addon:GetAHPrice(item.itemID)
        local cost, _, source = addon:GetUnitCostBasis(item.name, item.count, item.itemID)
        if price and cost and cost > 0 and (source == "crafted" or source == "paid") then
            local each = price * (1 - AH_CUT) - cost
            if each >= cost * SELL_NOW_MIN and each * item.count >= SELL_NOW_MIN_GOLD then
                table.insert(list, { itemID = item.itemID, name = item.name, count = item.count, price = price,
                    cost = cost, breakEven = cost / (1 - AH_CUT), each = each, gain = each * item.count,
                    days = math.floor((time() - item.heldSince) / 86400) })
            end
        end
    end
    table.sort(list, function(a, b) return a.gain > b.gain end)
    return list
end

-- /gsm sellnow (dev tools): each held item, its price and break-even, and
-- why Sell now did or didn't name it (2026-10-27: no line after a scan,
-- and the bench's prices weren't the game's)
function addon:PrintSellNow()
    local M = function(c) return c and addon:FormatMoney(c) or "-" end
    local stock = addon:GetStockValue("All")
    local posted = PostedLately()
    print(string.format("Goldsmith: %d held %d+ days, %d kept for yourself", #stock.heldLong,
        addon:Setting("heldDays"), #addon:GetKeptItems()))
    for _, item in ipairs(stock.heldLong) do
        local price = addon:GetAHPrice(item.itemID)
        local cost, _, source = addon:GetUnitCostBasis(item.name, item.count, item.itemID)
        local why
        if posted[item.name] or ListedNow(item.itemID) then why = "posted in the last day or on the AH now"
        elseif Wearable(item.itemID) then why = "gear or a tool"
        elseif not price then why = "no price"
        elseif not (cost and cost > 0) or (source ~= "crafted" and source ~= "paid") then why = "no real cost (" .. tostring(source) .. ")"
        else
            local each = price * (1 - AH_CUT) - cost
            why = each < cost * SELL_NOW_MIN and "under break-even"
                or each * item.count < SELL_NOW_MIN_GOLD and "under 10g in all"
                or ("SELL NOW " .. addon:FormatSignedMoney(each * item.count))
        end
        print(string.format("  %d %s: price %s, break-even %s, held %d days: %s", item.count, item.name, M(price),
            M(cost and cost / (1 - AH_CUT)), math.floor((time() - item.heldSince) / 86400), why))
    end
end

-- New prices (login, Goldsmith's scan, an Auctionator scan): say so for
-- each item newly worth selling, in chat (green, a coin) and once in the
-- middle of the screen, with no sound (good news doesn't beep; user,
-- 2026-10-27: "chat is easily missed"). Once per item a day
-- (GoldsmithDB.sellNowTold[itemID] = day). Worked out over frames.
function addon:CheckSellNow()
    if not GoldsmithDB or addon:UsingTourData() then return end
    addon:RunWork(function()
        local today = date("%Y-%m-%d")
        GoldsmithDB.sellNowTold = GoldsmithDB.sellNowTold or {}
        local told = GoldsmithDB.sellNowTold
        for id, day in pairs(told) do if day ~= today then told[id] = nil end end
        local fresh = {}
        for _, s in ipairs(addon:GetSellNow()) do
            if told[s.itemID] ~= today then
                told[s.itemID] = today
                table.insert(fresh, s)
                addon:Notify("gain", "%s is above break-even: %s (break-even %s). You hold %d, held %d days: about %s if they sell now.",
                    s.name, addon:FormatMoney(s.price), addon:FormatMoney(s.breakEven), s.count, s.days,
                    addon:FormatSignedMoney(s.gain))
            end
        end
        if #fresh > 0 and RaidNotice_AddMessage and RaidWarningFrame then
            local top = fresh[1]
            local more = #fresh > 1 and string.format(" (and %d more)", #fresh - 1) or ""
            local r, g, b = addon:Color("profit")
            RaidNotice_AddMessage(RaidWarningFrame, string.format("Goldsmith: sell %s now, about %s%s",
                top.name, addon:FormatSignedMoney(top.gain), more), { r = r, g = g, b = b })
        end
    end, nil, nil, "sell now", true)
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
        addon:Yield()
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
                if recipe and IsForSale(itemID, name, materials) then
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
-- max, minutesToFull, updated, plan, used, gain, capped } } (most gain
-- first) }. capped: crafts worth concentration that their sales left out
-- (see PlanConcentration).
--
-- Plans are cached until data changes, per character, profession and
-- amount of concentration (which only goes up a point every few minutes).
--
-- Concentration comes back slowly, so it's only worth spending on crafts
-- that earn at least MIN_CONC_VALUE extra gold per point. When it's full,
-- or will be within NEAR_FULL_MINUTES, what comes back would be wasted, so
-- the floor drops to FULL_CONC_VALUE: not to nothing (user, 2026-10-09:
-- with enchanting full, crafts at 0.05g a point were recommended).
local MIN_CONC_VALUE = 0.5 * 10000   -- copper per concentration point
local FULL_CONC_VALUE = 0.25 * 10000
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

-- The least extra gold per point worth suggesting for a character's
-- profession: lower when its concentration is (nearly) full. For the
-- Crafts tab's Recommended, the same as Do this next.
function addon:ConcentrationFloor(charKey, profession)
    local current, max, minutesToFull
    if charKey == addon.charKey then current, max, minutesToFull = addon:GetConcentration(profession) end
    if not current then current, max, minutesToFull = addon:GetCharacterConcentration(charKey, profession) end
    if current and max and max > 0 and NearFull(current, max, minutesToFull) then return FULL_CONC_VALUE end
    return MIN_CONC_VALUE
end

local function CachedPlan(key, profession, current, nearFull)
    local store = planCache:Get()
    local id = string.format("%s:%s:%d:%s", key, profession, current, tostring(nearFull))
    local cached = store[id]
    if not cached then
        local floor = nearFull and FULL_CONC_VALUE or MIN_CONC_VALUE
        local minROI = addon:Setting("minROI")
        local function Accept(recipe, row)
            if (row.concentrationValue or 0) < floor then return false end
            -- The minimum ROI too, as Best crafts and Crafts > Recommended
            -- (a 14.9% scroll was a to-do but not recommended, 2026-10-09)
            if (row.margin or 0) < minROI then return false end
            return IsRecommendable(recipe, row)
        end
        local plan, used, gain, capped = addon:WithCharacter(key, addon.PlanConcentration, addon,
            profession, current, Accept)
        cached = { plan = plan, used = used, gain = gain, capped = capped }
        store[id] = cached
    end
    return cached.plan, cached.used, cached.gain, cached.capped
end

-- Why a craft worth concentration was held back (a row's capped entry):
-- "You hold 2 unsold: more once they sell", or (TSM) "The region sells
-- about 1 every 3 days (TSM region)"
function addon:HeldBackReason(c)
    if c.held and c.held >= 1 then
        return string.format("You hold %d unsold: more once %s", c.held, c.held == 1 and "it sells" or "they sell")
    end
    local source = c.demandSource and (" (" .. c.demandSource .. ")") or ""
    if c.demand and c.demand > 0 and c.demand < 1 then
        return string.format("The region sells about 1 every %d days%s", math.floor(1 / c.demand + 0.5), source)
    end
    return string.format("The region sells under 1 a day%s", source)
end

function addon:GetConcentrationOverview(prof)
    local result = { current = 0, max = 0, gain = 0, rows = {} }
    for _, entry in ipairs(addon:GetCharacters()) do
        -- Characters excluded in Settings have no professions here
        local professions = addon:IsCharacterIncluded(entry.key) and entry.data.professions or {}
        for _, profession in ipairs(addon:Keys(professions)) do
            -- A plan for each, so work may wait for a frame between them
            addon:Yield()
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
                    local plan, used, gain, capped = CachedPlan(entry.key, profession, math.floor(current),
                        NearFull(current, max, minutesToFull))
                    table.insert(result.rows, {
                        key = entry.key, name = entry.data.name, profession = profession,
                        current = current, max = max, minutesToFull = minutesToFull, updated = updated,
                        plan = plan, used = used, gain = gain or 0, capped = capped or {},
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

-- Was the "Show cost as" setting (worst case everywhere). Removed (design
-- review trimming, user 2026-10-10): a hidden mode changing every number,
-- and the worst case is in each craft's hover anyway. Costs are always the
-- estimate from your stats; kept as a pass-through for its callers.
local function ApplyCostMode(recipe, row)
    return row
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

-- A character's best plain row for a recipe (estimated cost),
-- and items made per craft
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
-- first.
--
-- Suggests how many to make (SuggestedQuantity). Once you've made it, the
-- craft drops off, and it comes back only when you've sold every one you
-- hold: never more while some sit unsold, in case the market turns.
-- Crafts whose crafter is excluded aren't recommended.
-- Returns up to `count` { recipe, row, charKey, profit, margin, demand,
-- have, make (items to make), makeReason, outputPerCraft }.
function addon:GetBestCrafts(prof, count)
    local list = {}
    for _, recipeID in ipairs(addon:Keys(GoldsmithDB.recipes)) do
        addon:Yield()
        local recipe = GoldsmithDB.recipes[recipeID]
        if recipe and (prof == "All" or recipe.profession == prof) and MakesCurrentItem(recipe)
            and addon:CanAuction(recipe.outputItemID) ~= false then
            local charKey = CrafterFor(recipeID)
            if charKey and addon:IsCharacterIncluded(charKey) then
                local row, outputPerCraft = PlainRowFor(charKey, recipe)
                if row and row.profit and row.profit > 0 and not row.partial
                    and (row.margin or 0) >= addon:Setting("minROI") and IsRecommendable(recipe, row) then
                    local itemID = row.itemID or recipe.outputItemID
                    -- In bags, banks or listed on the AH, on any character
                    local have = itemID and addon:GetHeld(itemID, row.tier) or 0
                    if have == 0 then
                        -- Region sales only: your own are what the batch
                        -- size follows already; a slow seller a couple at
                        -- a time (SuggestedBatch)
                        local make, makeReason = addon:SuggestedBatch(recipe, itemID)
                        -- The whole batch must make "Worth a to-do at"
                        if row.profit * make >= (addon:Setting("minLine") or 0) * 10000 then
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
    end
    table.sort(list, function(a, b) return a.profit > b.profit end)
    for i = #list, count + 1, -1 do list[i] = nil end
    return list
end

-- Cooldown crafts ready now that are worth making: the same rules as Best
-- crafts (profit at the "Worth crafting at" ROI, every cost known, worth
-- recommending), on the character whose cooldown it is, with their stats.
-- Unlike Best crafts they don't wait until you've sold out: a cooldown not
-- used is lost. Returns { recipe, row, charKey, itemID, crafts (charges
-- ready), outputPerCraft, profit (each item), cooldown (see GetCooldowns) },
-- most total profit first.
function addon:GetCooldownCrafts(prof)
    local list = {}
    for _, cd in ipairs(addon.GetCooldowns and addon:GetCooldowns(prof) or {}) do
        local recipe = cd.recipe
        if cd.ready and recipe and (addon:CanAuction(recipe.outputItemID) ~= false
                or addon:GetBoxValue(recipe.outputItemID) ~= nil) then
            local row, outputPerCraft = PlainRowFor(cd.charKey, recipe)
            if row and row.profit and row.profit > 0 and not row.partial
                and (row.margin or 0) >= addon:Setting("minROI") and IsRecommendable(recipe, row) then
                table.insert(list, {
                    recipe = recipe, row = row, charKey = cd.charKey, cooldown = cd,
                    itemID = row.itemID or recipe.outputItemID, crafts = math.max(cd.charges or 1, 1),
                    outputPerCraft = outputPerCraft, profit = row.profit,
                })
            end
        end
    end
    table.sort(list, function(a, b)
        return a.profit * a.crafts * a.outputPerCraft > b.profit * b.crafts * b.outputPerCraft
    end)
    return list
end

-- Recipes by the materials they use: { [itemID] = { [recipeID] = recipe } },
-- rebuilt when a recipe is saved or removed (the cheap materials list
-- looked up every recipe for each material, every time it was shown)
local byMaterial, byMaterialVersion
local function RecipesByMaterial()
    if not byMaterial or byMaterialVersion ~= addon.recipesVersion then
        byMaterial, byMaterialVersion = {}, addon.recipesVersion
        for recipeID, recipe in pairs(GoldsmithDB.recipes) do
            for _, slot in ipairs(recipe.reagents or {}) do
                for _, id in ipairs(slot.itemIDs or {}) do
                    byMaterial[id] = byMaterial[id] or {}
                    byMaterial[id][recipeID] = recipe
                end
            end
        end
    end
    return byMaterial
end

-- GetOutputRecipes, kept until data changes
local outputsCache = addon:NewCache()
local function OutputRecipes()
    local store = outputsCache:Get()
    if not store.outputs then store.outputs = GetOutputRecipes() end
    return store.outputs
end

-- Whether an item passes the expansion filter (IsExpansionShown): shown
-- if its own expansion is shown, if it's made by a recipe from a shown
-- expansion (Enchanting Vellum: a Classic recipe, a Midnight item), or if
-- a recipe from a shown expansion uses it (older materials still in use).
-- name is used when there's no item ID. An expansion not known yet counts
-- as shown, so an item is only hidden when something known says it's from
-- a hidden expansion and nothing says otherwise.
-- Callers can skip this when addon:AllExpansionsShown().
function addon:IsItemShown(itemID, name)
    local known = false
    local function Shown(expansionID)
        if expansionID == nil then return false end
        known = true
        return addon:IsExpansionShown(expansionID)
    end
    local recipe = (itemID and OutputRecipes()[itemID]) or (name and addon:FindRecipeByOutput(name))
    if recipe and Shown(addon:GetRecipeExpansion(recipe)) then return true end
    if itemID then
        if Shown(addon:GetItemExpansion(itemID)) then return true end
        for _, r in pairs(RecipesByMaterial()[itemID] or {}) do
            if Shown(addon:GetRecipeExpansion(r)) then return true end
        end
    end
    return not known
end

-- For a material: whether a recipe from a shown expansion uses it. The
-- recipes decide, not the item's own expansion: the game re-tags some old
-- materials as new (Curing Salt 183955 says Midnight, but only Classic and
-- Legion recipes use it). With no known recipe using it, as IsItemShown.
function addon:IsMaterialShown(itemID, name)
    local users = itemID and RecipesByMaterial()[itemID]
    if users and next(users) then
        for _, r in pairs(users) do
            local expansionID = addon:GetRecipeExpansion(r)
            if expansionID == nil or addon:IsExpansionShown(expansionID) then return true end
        end
        return false
    end
    return addon:IsItemShown(itemID, name)
end

-- Recipes a material goes into, that a counted character knows, each made
-- by whoever makes it best, with its profit without concentration. Only
-- crafts worth recommending (WhyNotRecommended): gear nobody buys and
-- old-expansion items are left out, but ones selling at a loss today stay.
-- Returns { { recipe, charKey, profit (nil without a price), demand (sold
-- per day), saleRate } }, most profit first.
function addon:GetRecipesUsing(itemID)
    local list = {}
    -- The index is never changed once built, so pairs() is safe while the
    -- work waits for a frame
    for recipeID, recipe in pairs(RecipesByMaterial()[itemID] or {}) do
        addon:Yield()
        local charKey = MakesCurrentItem(recipe) and CrafterFor(recipeID)
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
-- Follows how fast your own batches sell, both ways. Region sales (TSM)
-- are every seller's, so they only cap it. A craft is only suggested once
-- you hold none (GetBestCrafts), so the last batch you made has sold or
-- gone by then; its pace sets the next one:
--   sold out within SELL_OUT_FAST_DAYS: GROWTH times as many (at least one
--     more), so a fast seller ramps up batch by batch
--   slower: a day's worth at the pace it sold (at least 1), so a slowdown
--     shrinks the next batch straight away
-- Up to MAX_BATCH, and never more than the region sells in a day (TSM).
-- Without a batch sold in the last STALE_DAYS days, the cautious default:
-- a day's worth of your sales over SALES_DAYS days, else a first batch of
-- FIRST_BATCH, capped at ENOUGH_STOCK_CAP.
-- Returns the count and why, in plain words.
local SALES_DAYS = 7
local FIRST_BATCH = 3
local SELL_OUT_FAST_DAYS = 1
local GROWTH = 1.5
local MAX_BATCH = 100
local STALE_DAYS = 30
-- Crafts this close together are one batch (a queue, or crafting 5 at once)
local BATCH_GAP = 3600
-- Units still unsold this long after crafting went another way (used,
-- mailed, vendored), so later sales aren't put down to them
local MAX_SELL_DAYS = 14
-- A batch that sold within minutes still counts as this long
local MIN_SELL_DAYS = 1 / 24
local salesCache = addon:NewCache()

-- Your sales, by item name: { { time, qty } }, oldest first
local function SalesByName()
    local store = salesCache:Get()
    if not store.sales then
        -- The ledger's index is already by name, oldest first
        local sales = {}
        for name, list in pairs(addon.ledger:index().sales) do
            local out = {}
            for i, e in ipairs(list) do out[i] = { time = e.timestamp, qty = e.quantity or 1 } end
            sales[name] = out
        end
        store.sales = sales
    end
    return store.sales
end

-- Did the suggestions pay off? (design review: "did I reach my goal?")
--
-- What the Overview and Characters tab suggest is noted when shown, with how
-- many to make (GoldsmithDB.suggested[name] = { time, qty, used }). A craft
-- of it within SUGGESTED_WINDOW, from Goldsmith or the game's window, is
-- marked lot.suggested (RecordCraftLot) while fewer than qty have been
-- counted: making more than suggested isn't following it (user,
-- 2026-10-11; for a while only Goldsmith's Craft buttons counted, but a
-- craft from the game's window drops out of the suggestions the same
-- way). A suggestion shown again starts a new count only when it has
-- really come back (Best crafts: once every one you made has sold), not
-- when it's drawn in the moment after a craft, before the bags are read
-- again (Characters.lua, 10 s): that started the count over, so a second
-- batch of Enlightenment Tonic counted as followed after the first had
-- filled the suggestion (user, 2026-10-11: "it should only show back up
-- if they have sold"). So shown within STOCK_GRACE of a counted craft,
-- the count carries on. A craft that starts within
-- the count is counted whole (multicraft extras too). GetFollowedSummary
-- adds up those crafts and what they sold for. Lots since 2026-10-11 also
-- keep the price expected then (lot.expectedPrice), so the hover can say
-- how the suggestions held up (user: "curious how well our recommendation
-- logic is holding up").
local SUGGESTED_WINDOW = 24 * 3600
local SUGGESTED_KEEP = 8 * 86400
-- How soon after a craft the suggestions can still show it, the bags not
-- read again yet
local STOCK_GRACE = 60
-- An item "held up" when its sales made at least this share of the profit
-- expected
local HELD_UP_SHARE = 0.8

-- items: { { name, qty (items suggested) } }; the same name twice (two
-- tiers, or two characters) adds up
function addon:MarkSuggested(items)
    GoldsmithDB.suggested = GoldsmithDB.suggested or {}
    local now = time()
    local qty = {}
    for _, item in ipairs(items) do
        if item.name then qty[item.name] = (qty[item.name] or 0) + math.max(item.qty or 1, 1) end
    end
    for name, n in pairs(qty) do
        local s = GoldsmithDB.suggested[name]
        if type(s) == "table" and (s.used or 0) > 0 and now - s.time <= SUGGESTED_WINDOW
            and now - (s.usedAt or 0) < STOCK_GRACE then
            s.qty = math.max(s.qty or 0, n)
        else
            GoldsmithDB.suggested[name] = { time = now, qty = n, used = 0 }
        end
    end
    for name, s in pairs(GoldsmithDB.suggested) do
        -- Saved as a time before quantities were kept
        if type(s) ~= "table" or now - s.time > SUGGESTED_KEEP then GoldsmithDB.suggested[name] = nil end
    end
end

-- A craft of `name` making `qty` items: does it follow a suggestion? Counts
-- it toward the suggested quantity if so.
function addon:TakeSuggested(name, qty)
    local s = name and GoldsmithDB.suggested and GoldsmithDB.suggested[name]
    if type(s) ~= "table" or time() - s.time > SUGGESTED_WINDOW or s.used >= s.qty then return false end
    s.used = s.used + (qty or 1)
    s.usedAt = time()
    return true
end

-- Crafts made after a suggestion in the last `days` days, and how they
-- sold: { crafted, sold, unsold, profit, checked, heldUp, items = { { name,
-- made, sold, profit, expected, heldUp, days } } (most profit first) }. A
-- sale counts toward a followed craft when it's of that item, after the
-- craft, up to as many as were made; its profit is the sale less its
-- recorded cost (or the craft's). expected: what the ones sold were
-- expected to make (price at craft time after the AH cut, less what the
-- craft cost), when the lots kept that price. checked: items with sales
-- and an expectation; heldUp: how many of them made HELD_UP_SHARE of it.
-- made / expectedTotal: over those checked items, the profit made and the
-- profit expected, for the share of expected profit made (Stats).
-- days: since the item's first followed craft. A box that can't be sold
-- (a Bouquet of Herbs) counts when opened instead, at what came out of it
-- (worth after the AH cut, less the box's cost): opened = true, and sold
-- is how many were opened (user, 2026-10-12).

-- Opened since `since`: count, what came out (worth, cost). Opens before
-- each one's time was kept (box.openedAt) are counted from the cost
-- shares, one box's cost (unitCost) each.
local function BoxOpenedSince(boxID, since, unitCost)
    local box = GoldsmithDB.boxContents and GoldsmithDB.boxContents[boxID]
    local worth, cost = 0, 0
    for _, e in ipairs(GoldsmithDB.gathered or {}) do
        if e.box == boxID and (e.time or 0) >= since then
            worth, cost = worth + (e.value or 0), cost + (e.cost or 0)
        end
    end
    local opened = 0
    if box and box.openedAt then
        for _, t in ipairs(box.openedAt) do if t >= since then opened = opened + 1 end end
    elseif worth > 0 then
        opened = unitCost > 0 and math.max(math.floor(cost / unitCost + 0.5), 1) or 1
    end
    return opened, worth, cost
end

-- Lots kept since then had their price checked when crafted (13a4496,
-- 2026-10-27 18:37 PDT); newer ones say so (lot.priceChecked)
local PRICE_CHECKED_SINCE = 1793151420

function addon:GetFollowedSummary(days)
    local since = time() - (days or 7) * 86400
    local byName = {}
    for itemID, lots in pairs(GoldsmithDB.craftLots or {}) do
        for _, lot in ipairs(lots) do
            if lot.suggested and lot.time and lot.time >= since and lot.name and (lot.qty or 0) > 0 then
                local s = byName[lot.name]
                if not s then
                    s = { name = lot.name, made = 0, cost = 0, first = lot.time, lots = {} }
                    byName[lot.name] = s
                end
                s.made = s.made + lot.qty
                s.cost = s.cost + lot.qty * (lot.unitCost or 0)
                s.first = math.min(s.first, lot.time)
                s.itemID = s.itemID or itemID
                table.insert(s.lots, { lot = lot, itemID = itemID })
            end
        end
    end
    local result = { crafted = 0, sold = 0, unsold = 0, profit = 0, checked = 0, heldUp = 0, made = 0, expectedTotal = 0, items = {} }
    local sales = addon.ledger:index().sales
    for name, s in pairs(byName) do
        s.sold, s.profit = 0, 0
        local unitCost = s.made > 0 and s.cost / s.made or 0
        if addon:CanAuction(s.itemID) == false and addon:GetBoxValue(s.itemID) then
            local opened, worth, cost = BoxOpenedSince(s.itemID, s.first - 60, unitCost)
            s.opened = true
            s.sold = math.min(opened, s.made)
            if opened > 0 then s.profit = (worth * (1 - AH_CUT) - cost) * s.sold / opened end
        else
            for _, e in ipairs(sales[name] or {}) do
                if s.sold >= s.made then break end
                if e.timestamp >= s.first and (e.quantity or 0) > 0 then
                    local take = math.min(e.quantity, s.made - s.sold)
                    local share = take / e.quantity
                    local cost = e.costBasis and e.costBasis * share or unitCost * take
                    s.profit = s.profit + e.totalCopper * share - cost
                    s.sold = s.sold + take
                end
            end
        end
        s.days = math.floor((time() - s.first) / 86400)
        -- Expected: from the lots the ones sold came out of, oldest first
        -- like the sales. 13 Razorstones sold from a lot that kept no
        -- price were judged on two later losing lots (expected -441.51g,
        -- 2026-10-12).
        table.sort(s.lots, function(a, b) return a.lot.time < b.lot.time end)
        local left, expQty, expProfit = s.sold, 0, 0
        for _, entry in ipairs(s.lots) do
            if left <= 0 then break end
            local lot = entry.lot
            local take = math.min(lot.qty, left)
            left = left - take
            if lot.expectedPrice then
                -- A price spike kept as the expectation is judged at the
                -- usual price, as plans do: Enchant Ring - Thalassian Haste
                -- kept 2,488g (usually 9g), half of all the "missing"
                -- profit (2026-10-27). Lots before the craft-time check,
                -- against the prices of their day: today's moved "expected"
                -- with the market (2026-10-29). Checked lots keep theirs.
                local price = lot.expectedPrice
                if not (lot.priceChecked or lot.time >= PRICE_CHECKED_SINCE) then
                    price = addon:PriceJumpAt(entry.itemID, price, lot.time) or price
                end
                expQty = expQty + take
                expProfit = expProfit + take * (price * (1 - AH_CUT) - (lot.unitCost or 0))
            end
        end
        if expQty > 0 then
            -- Expected each (from the lots that kept it), for the ones sold
            s.expected = expProfit / expQty * s.sold
            if s.sold > 0 then
                result.checked = result.checked + 1
                result.made = result.made + s.profit
                result.expectedTotal = result.expectedTotal + s.expected
                if s.profit >= (s.expected > 0 and s.expected * HELD_UP_SHARE or s.expected) then
                    s.heldUp = true
                    result.heldUp = result.heldUp + 1
                end
            end
        end
        result.crafted = result.crafted + s.made
        result.sold = result.sold + s.sold
        result.profit = result.profit + s.profit
        table.insert(result.items, s)
    end
    result.unsold = result.crafted - result.sold
    table.sort(result.items, function(a, b) return a.profit > b.profit end)
    return result
end

-- Units of an item you sold in the last SALES_DAYS days
local function RecentSold(itemName)
    local sold, since = 0, time() - SALES_DAYS * 86400
    for _, s in ipairs(SalesByName()[itemName] or {}) do
        if s.time >= since then sold = sold + s.qty end
    end
    return sold
end

-- Your batches of an item (every quality, by name), oldest first, with
-- your sales matched to them oldest first: { time, qty, sold, last (time
-- of its last sale) }. Crafts for orders aren't in craftLots, so they
-- don't count.
local function Batches(itemName)
    local store = salesCache:Get()
    store.batches = store.batches or {}
    if store.batches[itemName] then return store.batches[itemName] end

    -- Oldest first (GetCraftLotsByName)
    local lots = {}
    local byName = addon:GetCraftLotsByName(itemName)
    for _, lot in ipairs(byName and byName.lots or {}) do
        if lot.time and (lot.qty or 0) > 0 then table.insert(lots, lot) end
    end
    local batches = {}
    for _, lot in ipairs(lots) do
        local b = batches[#batches]
        if b and lot.time - b.lastCraft <= BATCH_GAP then
            b.qty, b.left, b.lastCraft = b.qty + lot.qty, b.left + lot.qty, lot.time
        else
            table.insert(batches, { time = lot.time, lastCraft = lot.time, qty = lot.qty, left = lot.qty, sold = 0 })
        end
    end

    local i = 1
    for _, sale in ipairs(SalesByName()[itemName] or {}) do
        local units = sale.qty
        while units > 0 and batches[i] and batches[i].time <= sale.time do
            local b = batches[i]
            if b.left == 0 or sale.time - b.time > MAX_SELL_DAYS * 86400 then
                b.left, i = 0, i + 1
            else
                local take = math.min(b.left, units)
                b.left, b.sold, b.last = b.left - take, b.sold + take, sale.time
                units = units - take
            end
        end
    end
    store.batches[itemName] = batches
    return batches
end

-- "5 hours", "2 days"
local function Duration(days)
    if days < 1 then
        local hours = math.max(math.floor(days * 24 + 0.5), 1)
        return string.format("%d hour%s", hours, hours == 1 and "" or "s")
    end
    local whole = math.floor(days + 0.5)
    return string.format("%d day%s", whole, whole == 1 and "" or "s")
end

-- itemName: the craft's output; regionDemand: units sold per day across
-- the region (TSM), or nil
function addon:SuggestedQuantity(itemName, regionDemand)
    local make, why, cap
    local last
    for _, b in ipairs(itemName and Batches(itemName) or {}) do
        if b.sold > 0 then last = b end
    end
    if last and time() - last.last <= STALE_DAYS * 86400 then
        local days = math.max((last.last - last.time) / 86400, MIN_SELL_DAYS)
        if last.sold >= last.qty and days <= SELL_OUT_FAST_DAYS then
            -- Never below a first batch: selling out is better than no data
            make = math.max(math.ceil(last.qty * GROWTH), last.qty + 1, FIRST_BATCH)
            why = string.format("more than last time: your last %d sold out in %s", last.qty, Duration(days))
        else
            -- A day's worth, counted over at least a day, so a batch that
            -- didn't sell out never suggests more than it sold
            make = math.max(math.floor(last.sold / math.max(days, 1)), 1)
            if last.sold >= last.qty then
                why = string.format("a day's worth at your pace: your last %d took %s to sell", last.qty, Duration(days))
            else
                why = string.format("a day's worth at your pace: only %d of your last %d sold", last.sold, last.qty)
            end
        end
        cap = MAX_BATCH
    else
        -- Your sales without a batch to time them against only show it sells
        -- at least this fast: you may not have had more to sell, or it
        -- wasn't worth making then (user, 2026-10-09). So they can raise a
        -- first batch, never lower it.
        local sold = itemName and RecentSold(itemName) or 0
        local perDay = math.floor(sold / SALES_DAYS)
        if perDay > FIRST_BATCH then
            make = perDay
            why = string.format("a day's worth (you sold %d in the last %d days)", sold, SALES_DAYS)
        elseif sold > 0 then
            make = FIRST_BATCH
            why = string.format("a first batch of %d (you sold %d in the last %d days)", FIRST_BATCH, sold, SALES_DAYS)
        else
            make = FIRST_BATCH
            why = string.format("a first batch of %d (you haven't sold any in the last %d days)", FIRST_BATCH, SALES_DAYS)
        end
        cap = ENOUGH_STOCK_CAP
    end
    if make > cap then
        make = cap
        why = why .. string.format(", capped at %d", cap)
    end
    -- More than the whole region buys in a day would sit unsold
    if regionDemand and regionDemand >= 1 and make > regionDemand then
        make = math.floor(regionDemand)
        why = why .. string.format(", capped at the region's %d sold a day", make)
    end
    return make, why
end

-- A to-do list per character: what "Do this next" suggests, split by who
-- should do it. Each character's concentration plan (see
-- GetConcentrationOverview), cooldown crafts ready to use
-- (GetCooldownCrafts; item.cooldown set), and the best crafts (GetBestCrafts) they make
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

    -- A concentration plan can split one item between two mixes of
    -- material qualities: the cheaper one runs out of concentration or of
    -- the gold materials you hold. Each mix is its own line, the second
    -- marked as the leftover (item.leftoverOf, kept right under the first):
    -- one line of "5x" read as 5 of one mix, and the plan it opened showed
    -- 4 (user, 2026-10-19; one line since 2026-10-16, when two looked like
    -- a repeat). Both open the same plan for all the crafts (planCrafts),
    -- since the queue holds one entry per item and quality.
    for _, r in ipairs(conc.rows) do
        local byItem = {}
        for _, p in ipairs(r.plan or {}) do
            local itemID = p.row.itemID or p.recipe.outputItemID
            local quantity = math.max(math.floor(p.crafts * (p.row.outputPerCraft or 1)), 1)
            if itemID then planned[itemID] = (planned[itemID] or 0) + quantity end
            local id = tostring(p.recipe.recipeID) .. ":" .. tostring(itemID) .. ":" .. tostring(p.row.tier)
            local item = {
                recipe = p.recipe, row = p.row, itemID = itemID, tierCount = p.tierCount,
                crafts = p.crafts, quantity = quantity, profit = p.profit, concentration = p.points,
                planCrafts = p.crafts, leftovers = {}, made = p.crafts * (p.row.outputPerCraft or 1),
            }
            local first = byItem[id]
            if first then
                item.leftoverOf = first
                first.planCrafts = first.planCrafts + p.crafts
                table.insert(first.leftovers, item)
            else
                byItem[id] = item
            end
            Add(r.key, item)
        end
    end

    -- Cooldowns ready to use, before best crafts so the same item isn't
    -- suggested twice
    for _, c in ipairs(addon:GetCooldownCrafts(prof)) do
        local quantity = math.max(math.floor(c.crafts * (c.outputPerCraft or 1)), 1)
        if c.itemID then planned[c.itemID] = (planned[c.itemID] or 0) + quantity end
        -- Profit for what the crafts make on average, as the queue counts it
        -- (and the concentration lines above)
        Add(c.charKey, {
            recipe = c.recipe, row = c.row, itemID = c.itemID, tierCount = c.row.tierCount,
            crafts = c.crafts, quantity = quantity, profit = c.profit * c.crafts * (c.outputPerCraft or 1),
            made = c.crafts * (c.outputPerCraft or 1), cooldown = c.cooldown,
        })
    end

    for _, c in ipairs(addon:GetBestCrafts(prof, math.huge)) do
        local make = c.make - (c.itemID and planned[c.itemID] or 0)
        if make > 0 then
            -- Profit for what the crafts make on average, not the items
            -- asked for: 1 Missive's +49.29g was 1 craft making about 1.3,
            -- +72.61g in the queue (user, 2026-10-25)
            local crafts = math.max(math.ceil(make / c.outputPerCraft), 1)
            Add(c.charKey, {
                recipe = c.recipe, row = c.row, itemID = c.itemID, tierCount = c.row.tierCount,
                crafts = crafts, quantity = make, made = crafts * c.outputPerCraft,
                profit = c.profit * crafts * c.outputPerCraft, why = c.makeReason,
            })
        end
    end

    for _, t in pairs(todo) do
        table.sort(t.items, function(a, b) return a.profit > b.profit end)
        -- A leftover mix right under its first line
        local ordered = {}
        for _, item in ipairs(t.items) do
            if not item.leftoverOf then
                table.insert(ordered, item)
                for _, l in ipairs(item.leftovers or {}) do table.insert(ordered, l) end
            end
        end
        t.items = ordered
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
-- Costs are the estimate from your stats.
--   showExpansion  - function(expansionID) -> whether to include it
--   showIgnored    - include ignored items (Settings > Ignored crafts)
--   shownExpansions - older crafts from expansions picked in the header are
--                    judged on sales, not left out for their age
--   match          - function(names) -> whether to include it, checked
--                    before any costing so a search only works out matches
-- Returns { { key, recipe, info (the tier row or GetRecipeProfit), tier,
-- charKey, itemID, whyNot (see WhyNotRecommended) } }, unsorted.
local craftRowsCache = addon:NewCache()

function addon:GetCraftRows(prof, opts)
    local list = {}
    for _, recipeID in ipairs(addon:Keys(GoldsmithDB.recipes)) do
        addon:Yield()
        local recipe = GoldsmithDB.recipes[recipeID]
        if recipe and (prof == "All" or recipe.profession == prof)
            and (not opts.onlyMine or addon.char.knownRecipes[recipeID])
            -- Bound boxes once opened (worth what's inside, Gathered.lua)
            and (addon:CanAuction(recipe.outputItemID) ~= false or addon:GetBoxValue(recipe.outputItemID) ~= nil)
            and not addon:IsSalvageRecipe(recipe)
            and (not opts.showExpansion or opts.showExpansion(addon:GetRecipeExpansion(recipe)))
            and (opts.showIgnored or not addon:IsIgnored(recipe.outputItemID))
            and (not opts.match or opts.match({ recipe.outputName, recipe.name }))
            -- Recipes only excluded characters know are left out, and so are
            -- recipes nobody knows (saved from a link or another profession's
            -- window: Amani Resourcefulness showed as a craft, 2026-10-09)
            and (opts.onlyMine or (#addon:GetCrafters(recipeID) > 0
                and addon:IsCharacterIncluded(CrafterFor(recipeID) or addon.charKey))) then
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
                            whyNot = addon:WhyNotRecommended(recipe, info, opts.shownExpansions),
                            ignored = addon:IsIgnored(recipe.outputItemID),
                        })
                    end
                end
            end
        end
    end
    return list
end

-- Recipes not learned yet (GoldsmithDB.unlearned, the current expansion's),
-- for the Crafts tab's "Not learned yet": what each would make if learned
-- today, costed with the stats of a character who has the profession (the
-- one you're on first). Never recommended, planned or queued.
-- opts: onlyMine (only recipes this character could learn), concentration
-- (add the ways with concentration), match (as for GetCraftRows). Rows as
-- GetCraftRows', plus unlearned = true.
function addon:GetUnlearnedRows(prof, opts)
    local list = {}
    for _, recipeID in ipairs(addon:Keys(GoldsmithDB.unlearned or {})) do
        addon:Yield()
        local recipe = GoldsmithDB.unlearned[recipeID]
        if recipe and not GoldsmithDB.recipes[recipeID]
            and (prof == "All" or recipe.profession == prof)
            and addon:CanAuction(recipe.outputItemID) ~= false
            and (not opts.match or opts.match({ recipe.outputName, recipe.name })) then
            -- Who'd learn it: you if you can, otherwise the first counted
            -- character with the profession
            local learners = recipe.learners or {}
            local charKey
            if learners[addon.charKey] then
                charKey = addon.charKey
            elseif not opts.onlyMine then
                for _, key in ipairs(addon:Keys(learners)) do
                    if GoldsmithDB.characters[key] and addon:IsCharacterIncluded(key) then
                        charKey = key
                        break
                    end
                end
            end
            if charKey then
                local rows = addon:WithCharacter(charKey, function()
                    local tierRows = addon:GetTierRows(recipe)
                    if not tierRows or #tierRows == 0 then tierRows = { addon:GetRecipeProfit(recipe) } end
                    local shown = {}
                    for _, row in ipairs(tierRows) do
                        if opts.concentration or not row.concentrate then
                            table.insert(shown, ApplyCostMode(recipe, row))
                        end
                    end
                    return shown
                end)
                for _, info in ipairs(rows) do
                    table.insert(list, {
                        key = "unlearned:" .. addon:CraftKey(recipeID, info),
                        recipe = recipe, info = info, tier = info.tier, charKey = charKey,
                        itemID = info.itemID or recipe.outputItemID,
                        unlearned = true,
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
    for i, e in ipairs(addon.ledger:getAll()) do
        if i % 64 == 0 then addon:Yield() end
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

-- 8 fill a board; 6 left half of each empty (user, 2026-10-27)
local BOARD_SIZE = 8
local MIN_SALES_FOR_ROI = 2    -- sales before an item's ROI is ranked
local PRICE_DAYS = 30

-- Every item Goldsmith knows: recipe outputs (each tier, from any
-- character's tier data), materials (each quality) and anything you've
-- bought. Returns byID[itemID] = { itemID, name, recipe, tier, tierCount,
-- profession, material } and byName[name] = { itemID, ... } (lowest tier
-- first).
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
    -- Lists rather than pairs(), so the work can wait for a frame
    for _, key in ipairs(addon:Keys(GoldsmithDB.characters)) do
        local tierData = GoldsmithDB.characters[key].tierData
        for n, recipeID in ipairs(addon:Keys(tierData)) do
            -- Every 8, not 64: each is a recipe's tier mixes, and 64 of them
            -- made a 33.8 ms frame on an older laptop (2026-10-12)
            if n % 8 == 0 then addon:Yield() end
            local td = tierData[recipeID]
            local recipe = GoldsmithDB.recipes[recipeID]
            if recipe and td then
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
    for n, recipeID in ipairs(addon:Keys(GoldsmithDB.recipes)) do
        if n % 8 == 0 then addon:Yield() end
        local recipe = GoldsmithDB.recipes[recipeID] or { reagents = {} }
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
    -- Refines make one quality of an item from a lower one (Refine
    -- Duskshrouded Stone: 18 silver stones make 1 gold). Their slots have a
    -- single item, so when no other recipe lists both qualities, the tier
    -- comes from the quality icon in the recipe's name; the material is the
    -- quality below (only sure with 2 tiers). Without icons it read "18
    -- Dusk-Shrouded Stone make a Dusk-Shrouded Stone" (user, 2026-10-13).
    for n, recipeID in ipairs(addon:Keys(GoldsmithDB.recipes)) do
        if n % 64 == 0 then addon:Yield() end
        local recipe = GoldsmithDB.recipes[recipeID]
        local tier, tierCount = addon:NameTier(recipe.name)
        if tier and recipe.outputItemID then
            Add(recipe.outputItemID, recipe.outputName, { tier = tier, tierCount = tierCount })
            for _, slot in ipairs(recipe.reagents or {}) do
                local ids = slot.itemIDs or {}
                if #ids == 1 and slot.names[1] == recipe.outputName and tier == 2 and tierCount == 2 then
                    Add(ids[1], slot.names[1], { tier = 1, tierCount = 2 })
                end
            end
        end
    end
    for herbID, record in pairs(GoldsmithDB.milling) do
        Add(herbID, record.name, { material = true, profession = GoldsmithDB.reagents[record.name] })
    end
    -- What you've bought, sold or posted: Mentor's Helpful Handiwork, sold
    -- 19 times, wasn't found (user, 2026-10-27). Sales and deposits often
    -- carry only the name; the game knows the ID of a cached item.
    local idByName = {}
    local instant = C_Item.GetItemInfoInstant
    for i, e in ipairs(addon.ledger:getAll()) do
        if i % 64 == 0 then addon:Yield() end
        local itemID = e.itemID
        if not itemID and e.item and instant and (e.type == "REVENUE" or e.kind == "DEPOSIT") then
            if idByName[e.item] == nil then idByName[e.item] = instant(e.item) or false end
            itemID = idByName[e.item] or nil
        end
        if itemID and e.item then
            Add(itemID, e.item, { profession = e.profession ~= "Unassigned" and e.profession or nil })
        end
    end
    for _, ids in pairs(byName) do
        table.sort(ids, function(a, b) return (byID[a].tier or 0) < (byID[b].tier or 0) end)
    end
    return byID, byName
end

-- Kept until data changes (it was rebuilt every frame, and every item
-- page and list asks for it); lists look items up row by row
local itemIndexCache = addon:NewCache()
local function ItemIndex()
    local store = itemIndexCache:Get()
    if not store.byID then store.byID, store.byName = BuildItemIndex() end
    return store.byID, store.byName
end

-- An item's quality tier and how many tiers it has, or nil
function addon:GetItemTier(itemID)
    local item = itemID and ItemIndex()[itemID]
    if item then return item.tier, item.tierCount end
end

-- The quality icon in a recipe's name (refines: "Refine Duskshrouded Stone
-- |A:Professions-ChatIcon-Quality-12-Tier2:20:20|a"): tier, tierCount or nil.
-- "Quality-12" icons are Midnight's 2 tiers, the others The War Within's 3.
function addon:NameTier(name)
    if not name then return nil end
    local tier = name:match("Quality%-12%-Tier(%d)")
    if tier then return tonumber(tier), 2 end
    tier = name:match("Quality%-Tier(%d)")
    if tier then return tonumber(tier), 3 end
end

-- A recipe that makes one quality only (a refine): its output's tier and
-- tierCount, or nil. Crafts with a choice of quality have tier rows instead
-- (and no icon in their name, so one whose tiers haven't loaded gets none).
function addon:FixedTier(recipe)
    if not (recipe and recipe.outputItemID) then return nil end
    local nameTier, nameCount = addon:NameTier(recipe.name)
    if not nameTier then return nil end
    local tier, tierCount = addon:GetItemTier(recipe.outputItemID)
    if tier then return tier, tierCount end
    return nameTier, nameCount
end

-- What you've sold of each item name: { [name] = { name, profession,
-- units, sales, cost, deposits, profit, roi, salesCount, firstSale } }.
-- Sales without cost data use today's estimate; if there's none they're
-- left out of profit (as in the Overview's summary).
-- Kept until data changes (every item page asked for all of it); callers
-- may add fields to an item but not change its numbers.
local salesByItemCache = addon:NewCache()
local BuildSalesByItem

local function SalesByItem(prof, since)
    local store = salesByItemCache:Get()
    local id = prof .. "|" .. tostring(since)
    store[id] = store[id] or BuildSalesByItem(prof, since)
    return store[id]
end

BuildSalesByItem = function(prof, since)
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
    for i, e in ipairs(addon.ledger:getAll()) do
        if i % 8 == 0 then addon:Yield() end
        if e.item and (prof == "All" or e.profession == prof) and (not since or e.timestamp >= since) then
            if e.type == "REVENUE" then
                local item = Item(e)
                item.units = item.units + e.quantity
                item.sales = item.sales + e.totalCopper
                item.salesCount = item.salesCount + 1
                item.firstSale = math.min(item.firstSale or e.timestamp, e.timestamp)
                local cost = e.costBasis
                if not cost then
                    -- Once per item, cached (Data.lua)
                    local unit = addon:EstimateSaleCost(e.item)
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
-- Kept until data changes; callers mustn't change it.
local boardsCache = addon:NewCache()
local ItemBoards

function addon:GetItemBoards(prof, rangeKey)
    local store = boardsCache:Get()
    local id = prof .. "|" .. tostring(rangeKey) .. "|" .. addon:ExpansionFilterKey()
    store[id] = store[id] or ItemBoards(prof, rangeKey)
    return store[id]
end

ItemBoards = function(prof, rangeKey)
    local since = addon:DateRangeStart(rangeKey)
    local _, byName = ItemIndex()
    local sold = SalesByItem(prof, since)

    local everything = addon:AllExpansionsShown()
    local function Shown(itemID, name) return everything or addon:IsItemShown(itemID, name) end
    local list = {}
    for _, item in pairs(sold) do
        item.itemID = byName[item.name] and byName[item.name][#byName[item.name]]
        if item.salesCount > 0 and Shown(item.itemID, item.name) then table.insert(list, item) end
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
    -- What you could sell above break-even now (GetSellNow) goes first,
    -- with its gain: the chat line at login was easy to miss (user,
    -- 2026-10-27). The rest follow, longest held first as before.
    local sellNow = {}
    for _, s in ipairs(addon:GetSellNow()) do sellNow[s.itemID] = s end
    local stock = addon:GetStockValue(prof)
    local sellable, rest = {}, {}
    for _, item in ipairs(stock.heldLong) do
        if Shown(item.itemID, item.name) then
            local s = sellNow[item.itemID]
            table.insert(s and sellable or rest, {
                name = item.name, itemID = item.itemID, count = item.count, value = item.value,
                days = math.floor((time() - item.heldSince) / 86400), sell = s,
            })
        end
    end
    table.sort(sellable, function(a, b) return a.sell.gain > b.sell.gain end)
    boards.heldSell = #sellable
    for _, list in ipairs({ sellable, rest }) do
        for _, item in ipairs(list) do
            if #boards.held < BOARD_SIZE then table.insert(boards.held, item) end
        end
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
    -- The index is never changed once built, so pairs() is safe while the
    -- work waits for a frame
    local everything = addon:AllExpansionsShown()
    local n = 0
    for name, ids in pairs(byName) do
        n = n + 1
        if n % 256 == 0 then addon:Yield() end
        local profession = byID[ids[#ids]].profession
        if name:lower():find(needle, 1, true) and (prof == "All" or profession == prof)
            and (everything or addon:IsItemShown(ids[#ids], name)) then
            for _, id in ipairs(ids) do
                table.insert(list, { name = name, itemID = id, tier = byID[id].tier, profession = profession })
            end
        end
    end
    table.sort(list, function(a, b)
        if a.name ~= b.name then return a.name < b.name end
        return (a.tier or 0) < (b.tier or 0)
    end)
    for i = #list, limit + 1, -1 do list[i] = nil end
    -- Stock, price and sales only for the rows shown (a short search can
    -- match thousands of items)
    for i, item in ipairs(list) do
        if i % 16 == 0 then addon:Yield() end
        item.have = (addon:GetStock(item.itemID))
        item.price = addon:GetMarketPrice(item.itemID)
        item.demand = addon:GetDemand(item.itemID, item.name)
    end
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
--   bought:  paid, paidSource, paidHow ("salvaged" or "bought and salvaged" when some came from your salvage runs)
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
        d.price, d.priceSource, d.priceAge, d.priceNote = addon:GetMarketPriceInfo(itemID)
        d.priceText = d.price and addon:PriceAgeText(itemID)
        d.insight, d.historyDays = addon:GetPriceInsight(itemID)
        d.history, d.bandLow, d.bandHigh = PriceSeries(itemID, PRICE_DAYS)
        d.demand, d.demandSource = addon:GetDemand(itemID, name)
        d.saleRate = addon:GetSaleRate(itemID)
        d.have, d.byCharacter = addon:GetStock(itemID)
        d.heldSince = d.have > 0 and IsForSale(itemID, name) and HeldSince(itemID, d.have) or nil
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
            -- The finishing reagents the estimate counts (Bazaar Bites):
            -- without them, 286g against a 619g worst case read as unexplained
            local choice = addon:GetFinishingChoice(recipe)
            d.finishing = {}
            for _, pick in ipairs(choice and choice.picks or {}) do
                table.insert(d.finishing, C_Item.GetItemNameByID(pick.option.itemID) or "a finishing reagent")
            end
        end)
        if itemID then
            d.yours, d.yoursCount = addon:GetCraftedCost(itemID)
            d.yoursHeld = addon:GetHeld(itemID)
        end
    end
    -- This quality, like the item tooltip (by name if nothing has its ID)
    if not recipe or d.material then
        local sources
        d.paid, d.paidSource, sources = addon:GetOwnCost(name, nil, itemID)
        if not d.paid then d.paid, d.paidSource, sources = addon:GetOwnCost(name) end
        -- Of the "paid" ones, how many you salvaged rather than bought
        for _, s in ipairs(sources or {}) do
            if s[1] == "paid" and (s.salvaged or 0) > 0 then
                d.paidHow = s.salvaged >= s[3] and "salvaged" or "bought and salvaged"
            end
        end
    end
    -- Not crafted yet: the estimated cost. Gathered ones count at their AH
    -- price, as in every cost (user, 2026-10-11: "we are looking for cost
    -- not spent"; they were free here). All gathered: no break-even, since
    -- selling them at any price is gold you didn't have (2026-10-09).
    local paid = d.paid
    if d.paidSource == "gathered" then
        paid = nil
        d.free = true
    end
    -- A material you also craft: what yours cost you covers your crafts and
    -- purchases together (shown as "Yours cost you"); the crafts alone made
    -- Mote of Light's break-even 2.34g against 0.60g (2026-10-11)
    -- Only while you hold some: with all of them sold, your last crafts' cost
    -- (Harandar Celebration, 105.83g on Oct 19) judged today's at 67g
    -- (user, 2026-10-27). The next ones cost the estimate.
    local yours = (not d.material) and (d.have or 0) > 0 and d.yours or nil
    local basis = yours or paid or (not d.free and d.estimated) or nil
    d.breakEvenFrom = (yours and "yours") or (paid and "paid")
        or (basis and "estimated")
    d.breakEven = basis and basis / (1 - AH_CUT)

    local sold = SalesByItem("All")[name]
    d.earned = sold and { units = sold.units, sales = sold.sales, profit = sold.profit } or nil

    d.activity = {}
    local own = {}
    for _, id in ipairs(ids) do own[id] = true end
    for i, e in ipairs(addon.ledger:getAll()) do
        if i % 64 == 0 then addon:Yield() end
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
-- Gathered materials (GoldsmithDB.gathered) are one "Gathered" row a day
-- with worth (at the AH price when gathered), items ({ itemID, name, qty,
-- value, profession }, most valuable first) and entries (to delete them).
-- Returns rows newest first: { kind, time, item, itemID, qty, gold (signed;
-- nil for crafts), profit, costSource (sales: see GetUnitCostBasis, or
-- "today" for today's estimate), profitEstimated, cost (crafts: per item),
-- partial, profession, character (key), entry (the ledger entry), lot
-- (crafts) }, and totals { gold in, gold out }.
-- Kept until data changes (it reads the whole ledger, and the tab asks
-- every time it's shown); callers may sort the rows but not change them.
local historyCache = addon:NewCache()
local History

function addon:GetHistory(filters)
    local store = historyCache:Get()
    local id = string.format("%s|%s|%s|%s|%s|%s", tostring(filters.prof), tostring(filters.since),
        tostring(filters.kind), tostring(filters.character), tostring(filters.item),
        filters.item and "" or addon:ExpansionFilterKey())
    store[id] = store[id] or { History(filters) }
    return store[id][1], store[id][2]
end

History = function(filters)
    -- Once per session, when prices are in (see RepairOrderLots)
    if not addon.orderLotsRepaired then
        addon.orderLotsRepaired = true
        addon:RepairOrderLots()
    end
    local rows, totals = {}, { goldIn = 0, goldOut = 0, worth = 0 }
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
    -- The expansion filter, except for one item's history (from its page)
    local everything = filters.item ~= nil or addon:AllExpansionsShown()
    local shown = {}
    local function Shown(itemID, name)
        if everything then return true end
        local key = itemID or name
        if key == nil then return true end
        if shown[key] == nil then shown[key] = addon:IsItemShown(itemID, name) end
        return shown[key]
    end
    local function Keep(kind, t, item, profession, character, itemID)
        return (not filters.kind or filters.kind == kind)
            and (not filters.since or t >= filters.since)
            and (not filters.item or filters.item == item)
            and (filters.prof == "All" or profession == filters.prof)
            and (not filters.character or filters.character == character)
            and Shown(itemID, item)
    end

    for i, e in ipairs(addon.ledger:getAll()) do
        if i % 64 == 0 then addon:Yield() end
        local kind = e.type == "REVENUE" and "Sale" or (e.kind == "DEPOSIT" and "Deposit" or "Purchase")
        local character = e.character and e.realm and (e.character .. "-" .. e.realm)
        if Keep(kind, e.timestamp, e.item, e.profession, character, e.itemID) then
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
                if lot.name and Keep("Craft", lot.time, lot.name, profession, nil, itemID) then
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
            if lot.name and Keep("Order", lot.time, lot.name, profession, nil, lot.itemID) then
                -- The commission is gold in; profit adds the materials you
                -- kept and sellable rewards, less your own materials
                -- (orders saved before commissions were recorded have neither)
                local commission = lot.commission
                table.insert(rows, {
                    kind = "Order", time = lot.time, item = lot.name, itemID = lot.itemID, qty = lot.qty,
                    cost = lot.unitCost, partial = lot.partial, profession = profession, lot = lot,
                    gold = commission,
                    profit = commission and (commission + (lot.kept or 0) + addon:LotRewardsValue(lot)
                        - (lot.unitCost or 0) * (lot.qty or 0)),
                })
                if commission then totals.goldIn = totals.goldIn + commission end
            end
        end
    end

    -- Gathered materials: one row a day, whatever and whoever gathered them.
    -- No gold changed hands, so they're not in gold in or out; what they
    -- were worth is totals.worth (user, 2026-10-27: "i feel like it should
    -- not be zero").
    local days = {}
    for i, e in ipairs(GoldsmithDB.gathered or {}) do
        if i % 64 == 0 then addon:Yield() end
        local character = e.character and e.realm and (e.character .. "-" .. e.realm)
        local profession = addon:GetProfessionForItemName(e.name) or "Unassigned"
        -- What came out of a box you crafted: an "Opened" row a day per box,
        -- with what the box cost (user, 2026-10-11: they weren't free)
        local kind = e.box and "Opened" or "Gathered"
        if Keep(kind, e.time or 0, e.name, profession, character, e.itemID) then
            local key = e.box and (e.day .. "|" .. e.box) or e.day
            local row = days[key]
            if not row then
                row = { kind = kind, time = 0, qty = 0, worth = 0, entries = {}, items = {} }
                if e.box then
                    local boxName = addon:KnownItemName(e.box) -- from your recipes when the game has it unloaded (user, 2026-10-12)
                    local recipe = addon:FindRecipeByOutput(boxName)
                    row.item, row.itemID, row.box = boxName, e.box, true
                    row.boxProfession = recipe and recipe.profession
                end
                days[key] = row
                table.insert(rows, row)
            end
            row.time = math.max(row.time, e.time or 0)
            row.qty = row.qty + e.qty
            row.worth = row.worth + (e.value or 0)
            if not e.box then totals.worth = totals.worth + (e.value or 0) end
            if e.cost then row.cost = (row.cost or 0) + e.cost end
            table.insert(row.entries, e)
            local item = row.items[e.itemID]
            if not item then
                item = { itemID = e.itemID, name = e.name, qty = 0, value = 0, profession = profession }
                row.items[e.itemID] = item
            end
            item.qty = item.qty + e.qty
            item.value = item.value + (e.value or 0)
            if e.cost then item.cost = (item.cost or 0) + e.cost end
        end
    end
    for _, row in pairs(days) do
        local list, professions = {}, {}
        for _, item in pairs(row.items) do
            table.insert(list, item)
            professions[item.profession] = true
        end
        table.sort(list, function(a, b) return a.value > b.value end)
        row.items = list
        if row.box then
            -- Worth after the AH cut less what the box cost
            if row.cost then row.profit = row.worth * (1 - AH_CUT) - row.cost end
            if row.boxProfession then professions = { [row.boxProfession] = true } end
        -- One kind of material shows as itself; several as a count
        elseif #list == 1 then
            row.item, row.itemID = list[1].name, list[1].itemID
        else
            row.item = string.format("%d materials", #list)
        end
        local only = next(professions)
        if only and not next(professions, only) then row.profession = only end
    end

    -- Can be thousands of rows: a sort that can wait for a frame
    addon:Sort(rows, addon.HistoryNewest)
    return rows, totals
end

-- History's order: newest first, and a fixed order for rows with the same
-- time (sales collected from one mailbox visit share a second, and swapped
-- places on every redraw, user 2026-10-14): ledger order, then type, name
function addon.HistoryNewest(a, b)
    if (a.time or 0) ~= (b.time or 0) then return (a.time or 0) > (b.time or 0) end
    local ida, idb = a.entry and a.entry.id or 0, b.entry and b.entry.id or 0
    if ida ~= idb then return ida > idb end
    if (a.kind or "") ~= (b.kind or "") then return (a.kind or "") < (b.kind or "") end
    return tostring(a.item) < tostring(b.item)
end

-- Characters with ledger entries, for History's filter: { { key, name } }
-- by name
local historyCharsCache = addon:NewCache()

function addon:GetHistoryCharacters()
    local store = historyCharsCache:Get()
    if store.list then return store.list end
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
    store.list = list
    return list
end

_G.Goldsmith = addon
