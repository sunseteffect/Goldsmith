local addon = _G.Goldsmith or {}

local AH_CUT = 0.05

-- Quality tiers
--
-- For crafts with quality tiers, Goldsmith asks the game (while the
-- profession window is open) which tier a given set of materials reaches,
-- with and without concentration, and works out the cheapest way to reach
-- each tier.
--
-- Better-quality materials add crafting skill, a fixed amount per unit. So
-- Goldsmith measures how much skill one better unit of each material adds,
-- then for each tier builds the cheapest mix that reaches it: upgrade the
-- units that buy skill most cheaply first, stopping part way through a
-- material if that's enough (e.g. 8 of 20 pigments at the better quality).
-- The game confirms each mix really reaches the tier.
--
-- With concentration, more spent on materials means less concentration per
-- craft, so more crafts from the same concentration. The tier and the
-- concentration cost depend only on the total skill the better materials
-- add, and MixForSkill gives the cheapest mix for any amount of skill, so
-- instead of trying every combination Goldsmith samples SWEEP_POINTS
-- amounts from none to everything, plus one unit short of each tier's mix
-- (just under a threshold, where concentrating to the tier above is
-- usually cheapest). PlanConcentration then picks among them.
--
-- Saved in addon.char.tierData[recipeID]:
--   { qualities = { qualityID, ... } (lowest first),
--     outputs   = { [tier] = { itemID, link } },
--     scenarios = { { mix = { [lowest-quality itemID] = better units },
--                     concentrate, tier, concentration, ingenuityRefund } },
--     updated }
-- Only materials that come in qualities go in the game's materials list;
-- fixed materials (like a vendor solvent) are left out, as the game needs.
-- "Better" is the highest quality of a material; middle qualities of older
-- 3-tier materials aren't used.

local MAX_TIER_STEPS = 6
local SWEEP_POINTS = 10

-- GetTierRows results per character (the stats used), kept until data
-- changes (see addon:NewCache) and cleared whenever tier data changes
local tierRowsCache = addon:NewCache()

-- Quality materials from the recipe's schematic, in order
local function QualitySlots(schematic)
    local slots = {}
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        if slot.required and slot.reagents and #slot.reagents > 1 then
            local low = slot.reagents[1].itemID
            local high = slot.reagents[#slot.reagents].itemID
            if low and high then
                table.insert(slots, {
                    dataSlotIndex = slot.dataSlotIndex,
                    quantity = slot.quantityRequired,
                    low = low,
                    high = high,
                })
            end
        end
    end
    return slots
end

-- The game's materials list for a mix; highUnits[i] = better-quality units
-- in quality slot i, the rest at the lowest quality
local function BuildList(qslots, highUnits)
    local list = {}
    for i, s in ipairs(qslots) do
        local high = math.min(highUnits[i] or 0, s.quantity)
        local low = s.quantity - high
        if low > 0 then
            table.insert(list, { reagent = { itemID = s.low }, quantity = low, dataSlotIndex = s.dataSlotIndex })
        end
        if high > 0 then
            table.insert(list, { reagent = { itemID = s.high }, quantity = high, dataSlotIndex = s.dataSlotIndex })
        end
    end
    return list
end

local function Operation(recipeID, list, concentrate, allocationGUID)
    local ok, op = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, list, allocationGUID, concentrate)
    if ok and op and op.craftingQualityID then
        return op
    end
end

local function Skill(op)
    return (op.baseSkill or 0) + (op.bonusSkill or 0)
end

-- Enchants make a scroll when put on a vellum, and the game only reports
-- the scroll (and enchant quality) with that vellum as the target. So a
-- vellum in your bags is used when checking enchants.
local function FindItemGUIDInBags(itemID)
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID then
                local ok, guid = pcall(C_Item.GetItemGUID, ItemLocation:CreateFromBagAndSlot(bag, slot))
                if ok then return guid end
            end
        end
    end
end

-- Scroll items for each enchant tier. With a vellum GUID the game may
-- report them directly; otherwise look at item IDs next to the scroll
-- you've made (tiers of a scroll are usually numbered together), keeping
-- only scrolls with the same name, and read each one's quality.
local function FindScrollTiers(recipeID, qualities, allocationGUID)
    local outputs = {}
    local scroll = GoldsmithDB.scrollOutputs[recipeID]
    if allocationGUID then
        for tier, qualityID in ipairs(qualities) do
            local ok, out = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, {}, allocationGUID, qualityID)
            if ok and out and out.itemID and out.itemID ~= scroll.vellumID then
                outputs[tier] = { itemID = out.itemID, link = out.hyperlink }
            end
        end
    end
    if outputs[1] and outputs[#qualities] and outputs[1].itemID ~= outputs[#qualities].itemID then
        return outputs
    end

    outputs = {}
    local name = C_Item.GetItemNameByID(scroll.itemID)
    local qualityFn = C_TradeSkillUI.GetItemCraftedQualityByItemInfo
    if not name or not qualityFn then return nil end
    for id = scroll.itemID - 3, scroll.itemID + 3 do
        local otherName = C_Item.GetItemNameByID(id)
        if not otherName then
            C_Item.RequestLoadItemDataByID(id)
        elseif otherName == name then
            local ok, tier = pcall(qualityFn, id)
            if ok and tier and qualities[tier] then
                outputs[tier] = { itemID = id }
            end
        end
    end
    if outputs[1] and outputs[#qualities] then
        return outputs
    end
end

function addon:RefreshTierData(recipeID)
    local okQ, qualities = pcall(C_TradeSkillUI.GetQualitiesForRecipe, recipeID)
    if not okQ or type(qualities) ~= "table" or #qualities < 2 then return end
    local okS, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not okS or not schematic then return end

    local tierOf = {}
    for tier, qualityID in ipairs(qualities) do
        tierOf[qualityID] = tier
    end

    -- Outputs per tier (enchants: their scrolls)
    local outputs = {}
    local allocationGUID
    local scroll = GoldsmithDB.scrollOutputs[recipeID]
    if scroll then
        allocationGUID = FindItemGUIDInBags(scroll.vellumID)
        outputs = FindScrollTiers(recipeID, qualities, allocationGUID)
        if not outputs then return end
    else
        for tier, qualityID in ipairs(qualities) do
            local okO, out = pcall(C_TradeSkillUI.GetRecipeOutputItemData, recipeID, {}, nil, qualityID)
            if okO and out then
                outputs[tier] = { itemID = out.itemID, link = out.hyperlink }
            end
        end
    end

    local qslots = QualitySlots(schematic)
    local base = Operation(recipeID, BuildList(qslots, {}), false, allocationGUID)
    if not base then return end
    local baseSkill = Skill(base)

    local scenarios = {}
    local seen = {}
    local function AddScenario(highUnits, concentrate)
        local key = (concentrate and "c" or "n")
        for i = 1, #qslots do key = key .. ":" .. (highUnits[i] or 0) end
        if seen[key] then return seen[key] end
        local op = Operation(recipeID, BuildList(qslots, highUnits), concentrate, allocationGUID)
        if not op or not tierOf[op.craftingQualityID] then return end
        local mix = {}
        for i, s in ipairs(qslots) do
            if (highUnits[i] or 0) > 0 then mix[s.low] = math.min(highUnits[i], s.quantity) end
        end
        local scenario = {
            mix = mix,
            concentrate = concentrate,
            tier = tierOf[op.craftingQualityID],
            concentration = concentrate and (op.concentrationCost or 0) or 0,
            ingenuityRefund = op.ingenuityRefund or 0,
            upper = op.upperSkillTreshold,
            skill = Skill(op),
        }
        table.insert(scenarios, scenario)
        seen[key] = scenario
        return scenario
    end

    local baseScenario = AddScenario({}, false)
    AddScenario({}, true)

    -- Skill added by one better-quality unit of each material, and what
    -- that upgrade costs per unit at current prices
    local upgrades = {}
    for i, s in ipairs(qslots) do
        local full = {}
        full[i] = s.quantity
        local op = Operation(recipeID, BuildList(qslots, full), false, allocationGUID)
        local gained = op and (Skill(op) - baseSkill) or 0
        local lowPrice = addon:GetMarketPrice(s.low)
        local highPrice = addon:GetMarketPrice(s.high)
        if gained > 0 and highPrice then
            table.insert(upgrades, {
                slot = i,
                max = s.quantity,
                skillPerUnit = gained / s.quantity,
                costPerUnit = math.max(highPrice - (lowPrice or 0), 0),
            })
        end
    end
    table.sort(upgrades, function(a, b)
        return a.costPerUnit / a.skillPerUnit < b.costPerUnit / b.skillPerUnit
    end)

    -- Cheapest mix adding at least `extra` skill, or nil if the better
    -- materials can't add that much
    local function MixForSkill(extra)
        local highUnits, remaining = {}, extra
        for _, u in ipairs(upgrades) do
            if remaining <= 0 then break end
            local take = math.min(u.max, math.ceil(remaining / u.skillPerUnit - 0.0001))
            highUnits[u.slot] = take
            remaining = remaining - take * u.skillPerUnit
        end
        if remaining > 0 then return nil end
        return highUnits
    end

    -- One more unit of the cheapest upgrade that still has room
    local function AddOneUnit(highUnits)
        for _, u in ipairs(upgrades) do
            if (highUnits[u.slot] or 0) < u.max then
                highUnits[u.slot] = (highUnits[u.slot] or 0) + 1
                return true
            end
        end
        return false
    end

    -- Walk up the tiers: each tier's threshold is the upper skill limit of
    -- the tier below
    local mixes = {}
    local current = baseScenario
    local steps = 0
    while current and current.tier < #qualities and current.upper and steps < MAX_TIER_STEPS do
        steps = steps + 1
        local mix = MixForSkill(current.upper - baseSkill)
        if not mix then break end
        local reached = AddScenario(mix, false)
        local tries = 0
        while reached and reached.tier <= current.tier and tries < 3 and AddOneUnit(mix) do
            tries = tries + 1
            reached = AddScenario(mix, false)
        end
        if not reached or reached.tier <= current.tier then break end
        table.insert(mixes, mix)
        current = reached
    end

    -- All best materials, and concentration on top of each mix
    local all = {}
    for i, s in ipairs(qslots) do all[i] = s.quantity end
    AddScenario(all, false)
    AddScenario(all, true)
    for _, mix in ipairs(mixes) do
        AddScenario(mix, true)
        -- One unit short of the mix: the most expensive upgrade it uses
        local short = {}
        for slot, units in pairs(mix) do short[slot] = units end
        for i = #upgrades, 1, -1 do
            local slot = upgrades[i].slot
            if (short[slot] or 0) > 0 then
                short[slot] = short[slot] - 1
                break
            end
        end
        AddScenario(short, true)
    end

    -- Concentration sweep across everything the better materials can add
    -- (see the top of this file)
    local maxExtra = 0
    for _, u in ipairs(upgrades) do maxExtra = maxExtra + u.max * u.skillPerUnit end
    for k = 1, SWEEP_POINTS - 1 do
        local mix = MixForSkill(maxExtra * k / SWEEP_POINTS)
        if mix then AddScenario(mix, true) end
    end

    addon:DataChanged()
    addon.char.tierData[recipeID] = {
        qualities = qualities,
        outputs = outputs,
        scenarios = scenarios,
        updated = time(),
    }
end

-- Price of one tier's item. Materials and consumables have a separate item
-- per tier; gear shares one item ID across tiers, so it's priced by link.
local function GetTierPrice(td, tier)
    local out = td.outputs[tier]
    if not out or not out.itemID then return nil end

    local sharedID = true
    for t, other in pairs(td.outputs) do
        if t ~= tier and other.itemID ~= out.itemID then
            sharedID = false
        end
    end
    if not sharedID then
        local price, source, age = addon:GetMarketPriceInfo(out.itemID)
        return price, source, age, out.itemID
    end

    local api = Auctionator and Auctionator.API and Auctionator.API.v1
    if out.link and api and api.GetAuctionPriceByItemLink then
        local ok, price = pcall(api.GetAuctionPriceByItemLink, "Goldsmith", out.link)
        if ok and price and price > 0 then
            -- Gear tiers are often thinly listed; check for outliers against
            -- the item's usual price across tiers
            -- Auctionator only gives an age per item ID, so every tier of
            -- the item shares it
            local checked, source, age = addon:CheckAgainstMarket(out.itemID, price, "Auctionator",
                addon:GetAuctionatorAge(out.itemID))
            return checked, source, age, out.itemID
        end
    end
end

-- Better-quality units a scenario uses for a recipe slot. Older saved
-- scenarios used mats = "high" for all best materials.
function addon:ScenarioHighUnits(scenario, slot)
    local ids = slot.itemIDs or {}
    if #ids < 2 then return 0 end
    if scenario.mix then
        return math.min(scenario.mix[ids[1]] or 0, slot.quantity)
    end
    return scenario.mats == "high" and slot.quantity or 0
end

-- Cost per crafted item for a scenario's materials: each quality material
-- split between its lowest and best quality as the mix says (priced by
-- those exact items), everything else at its cheapest known cost. Uses the
-- craft model (your stats, or none with noProcs).
local function ScenarioCost(recipe, scenario, noProcs)
    local outputPerCraft, modelSlots = addon:GetCraftModel(recipe, noProcs)
    local perCraft, complete = 0, true
    for _, m in ipairs(modelSlots) do
        local ids = m.slot.itemIDs or {}
        local useFactor = m.slot.quantity > 0 and (m.quantity / m.slot.quantity) or 1
        if #ids > 1 then
            local high = addon:ScenarioHighUnits(scenario, m.slot)
            local low = m.slot.quantity - high
            local lowPrice = addon:GetMarketPrice(ids[1]) or addon:GetOwnCost(m.slot.names[1])
            local highPrice = addon:GetMarketPrice(ids[#ids]) or addon:GetOwnCost(m.slot.names[#ids])
            if (low > 0 and not lowPrice) or (high > 0 and not highPrice) then
                complete = false
            end
            perCraft = perCraft + ((lowPrice or 0) * low + (highPrice or 0) * high) * useFactor
        else
            local unit = addon:GetSlotUnitCost(m.slot)
            if unit then
                perCraft = perCraft + unit * m.quantity
            else
                complete = false
            end
        end
    end
    return perCraft / outputPerCraft, complete, outputPerCraft
end

-- The worst case for a Crafts row (a tier row or GetRecipeProfit's
-- result): cost per item with no multicraft or resourcefulness, like TSM's
-- crafting cost. Worked out on request (hover) rather than for every row.
function addon:GetWorstCaseCost(recipe, info)
    if info.scenario then
        return (ScenarioCost(recipe, info.scenario, true))
    end
    return (addon:GetRecipeCost(recipe, true))
end

-- Crafting from Goldsmith: the materials list to give the game for a
-- scenario's mix of qualities (nil scenario: all lowest quality), built
-- the same way as the lists the game was asked about, from the recipe's
-- schematic (the profession must be open). Only quality materials go in
-- it; the game adds the fixed ones itself.
-- Returns the list and what one craft needs of every material, quality and
-- fixed ({ [itemID] = quantity }), or nil.
function addon:GetCraftReagents(recipeID, scenario)
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok or not schematic then return nil end
    local qslots = QualitySlots(schematic)
    local highUnits = {}
    for i, s in ipairs(qslots) do
        if scenario and scenario.mix then
            highUnits[i] = scenario.mix[s.low] or 0
        elseif scenario and scenario.mats == "high" then
            highUnits[i] = s.quantity
        end
    end
    local list = BuildList(qslots, highUnits)
    local needs = {}
    for _, entry in ipairs(list) do
        needs[entry.reagent.itemID] = (needs[entry.reagent.itemID] or 0) + entry.quantity
    end
    for _, slot in ipairs(schematic.reagentSlotSchematics or {}) do
        local only = slot.reagents and #slot.reagents == 1 and slot.reagents[1].itemID
        if slot.required and only then
            needs[only] = (needs[only] or 0) + slot.quantityRequired
        end
    end
    return list, needs
end

-- Plain description of a scenario's materials, e.g. "cheapest materials",
-- "best materials", or "8 better Powder Pigment, 2 better Sanguithorn Pigment"
function addon:DescribeMix(recipe, scenario)
    local parts, anyLow, anyHigh = {}, false, false
    for _, slot in ipairs(recipe.reagents) do
        if slot.itemIDs and #slot.itemIDs > 1 then
            local high = addon:ScenarioHighUnits(scenario, slot)
            if high > 0 then
                anyHigh = true
                table.insert(parts, string.format("%d better %s", high, slot.names[1]))
            end
            if high < slot.quantity then anyLow = true end
        end
    end
    if not anyHigh then return "cheapest materials" end
    if not anyLow then return "best materials" end
    return table.concat(parts, ", ")
end

-- Expected concentration spent per craft, after ingenuity refunds
local function ExpectedConcentration(recipe, scenario)
    if scenario.concentration <= 0 then return 0 end
    local stats = addon:StatsChar().recipeStats[recipe.recipeID]
    local ingenuity = stats and stats.ingenuity or 0
    return math.max(scenario.concentration - ingenuity / 100 * scenario.ingenuityRefund, 0)
end

-- One row per reachable tier, for the Crafts tab and plans. For each tier,
-- the cheapest way to reach it without concentration is preferred
-- (concentration is limited); otherwise the concentration option that earns
-- the most per concentration point. Returns nil for crafts without tier
-- data (they show as a single row).
--   { tier, tierCount, itemID, scenario, mix, concentrate, concentration
--     (expected per craft), cost, partial, price, priceSource, priceAge,
--     profit, margin, demand, demandSource, concentrationValue, scenarios }
-- Rows are shared until data changes (see tierRowsCache); don't change them.
local function BuildTierRows(recipe)
    local td = addon:StatsChar().tierData[recipe.recipeID]
    if not td then return nil end

    local evaluated = {}
    for _, s in ipairs(td.scenarios) do
        local cost, complete, outputPerCraft = ScenarioCost(recipe, s)
        local price, source, age, itemID = GetTierPrice(td, s.tier)
        local e = {
            scenario = s, tier = s.tier, mix = s.mix, concentrate = s.concentrate,
            concentration = ExpectedConcentration(recipe, s),
            cost = cost, partial = not complete, outputPerCraft = outputPerCraft,
            price = price, priceSource = source, priceAge = age, itemID = itemID,
        }
        if price then
            e.profit = price * (1 - AH_CUT) - cost
            e.margin = cost > 0 and (e.profit / cost * 100) or nil
        end
        table.insert(evaluated, e)
    end

    -- Concentration value: extra profit per craft from concentrating,
    -- compared with the most profitable way without concentration, per
    -- point of concentration spent
    local bestPlain
    for _, e in ipairs(evaluated) do
        if not e.concentrate and e.profit and (not bestPlain or e.profit > bestPlain) then
            bestPlain = e.profit
        end
    end
    for _, e in ipairs(evaluated) do
        if e.concentrate and e.concentration > 0 and e.profit and bestPlain then
            e.concentrationValue = (e.profit - bestPlain) * e.outputPerCraft / e.concentration
        end
    end

    -- Up to two rows per tier: the cheapest way without concentration, and
    -- the concentration option earning the most per point. Both are shown
    -- so a loss-making way without concentration never hides a profitable
    -- one with it (and "Profitable only" hides just the one that loses).
    local plain, concentrated = {}, {}
    for _, e in ipairs(evaluated) do
        if e.concentrate then
            local current = concentrated[e.tier]
            if not current or (e.concentrationValue or -math.huge) > (current.concentrationValue or -math.huge) then
                concentrated[e.tier] = e
            end
        else
            local current = plain[e.tier]
            if not current or e.cost < current.cost then
                plain[e.tier] = e
            end
        end
    end

    local rows = {}
    for tier = 1, #td.qualities do
        -- Both checked by index: ipairs stops at the first nil, which
        -- dropped tiers only reachable with concentration (no plain row)
        local options = { plain[tier], concentrated[tier] }
        for i = 1, 2 do
            local row = options[i]
            -- Concentration that lands on a tier you can already reach
            -- without it at the same cost adds nothing; skip it
            local redundant = row and row.concentrate and plain[tier] and plain[tier].cost <= row.cost
            if row and not redundant then
                row.tierCount = #td.qualities
                row.scenarios = evaluated
                row.description = addon:DescribeMix(recipe, row.scenario)
                if row.itemID then
                    row.demand, row.demandSource = addon:GetDemand(row.itemID, recipe.outputName)
                    row.saleRate = addon:GetSaleRate(row.itemID)
                end
                table.insert(rows, row)
            end
        end
    end
    for _, e in ipairs(evaluated) do
        e.description = e.description or addon:DescribeMix(recipe, e.scenario)
        e.tierCount = #td.qualities
    end
    return rows
end

function addon:GetTierRows(recipe)
    local store = tierRowsCache:Get()
    local char = addon:StatsChar()
    local byChar = store[char]
    if not byChar then
        byChar = {}
        store[char] = byChar
    end
    local rows = byChar[recipe.recipeID]
    if rows == nil then
        rows = BuildTierRows(recipe) or false
        byChar[recipe.recipeID] = rows
    end
    return rows or nil
end

-- Concentration budget
--
-- Your current concentration for a profession, read from its currency.
-- Returns current, max, and minutes until full (nil if unknown), or nil if
-- the profession's concentration currency isn't known yet (open it once).
function addon:GetConcentration(profession)
    local currencyID = GoldsmithDB.concentrationCurrency and GoldsmithDB.concentrationCurrency[profession]
    if not currencyID or currencyID == 0 then return nil end
    local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, currencyID)
    if not ok or not info then return nil end
    local current, max = info.quantity or 0, info.maxQuantity or 0
    local minutesToFull
    local cycleMS, perCycle = info.rechargingCycleDurationMS, info.rechargingAmountPerCycle
    if cycleMS and perCycle and cycleMS > 0 and perCycle > 0 and max > current then
        minutesToFull = (max - current) / perCycle * cycleMS / 60000
    end
    return current, max, minutesToFull
end

-- The best way to spend `budget` concentration on a profession's crafts.
--
-- Every way of concentrating on every craft is an option: each tier, and
-- each material mix the sweep in RefreshTierData found (richer mixes cost
-- more in materials but less concentration). Only options that make a
-- profit with concentration are used, and only those accept(recipe, row)
-- allows, if given. Each item is capped at about a day of its sales.
--
-- 1. Fill: most extra gold per concentration point first, as many crafts
--    as fit, then the next. For a budget that runs out, this is what earns
--    the most.
-- 2. Improve: whole crafts leave concentration over (700 left and 343 per
--    craft makes 2 and wastes 14). Repeatedly make the single change that
--    earns the most: add a craft that fits, or switch one craft to another
--    mix of the same recipe (e.g. richer, freeing concentration for one
--    more craft; or pricier but earning more, when an item's sales cap is
--    what's limiting). Stops when nothing earns more. Small searches, so
--    no stutter.
--
-- Starting a craft needs its full concentration cost; ingenuity refunds
-- some afterwards, so the points counted are the expected cost.
-- Returns { { recipe, row, tierCount, crafts, points, gain, profit } }
-- (most gain first), points used, and total extra profit from
-- concentrating.
local MAX_IMPROVEMENTS = 30
local MAX_CRAFTS_TRIED = 200

function addon:PlanConcentration(profession, budget, accept)
    -- Only recipes that spend this concentration (each expansion's version
    -- of a profession has its own)
    local currencyID = GoldsmithDB.concentrationCurrency and GoldsmithDB.concentrationCurrency[profession]
    local found, caps = {}, {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        local stats = addon:StatsChar().recipeStats[recipe.recipeID]
        if recipe.profession == profession and stats and stats.concentrationCurrencyID == currencyID then
            local rows = addon:GetTierRows(recipe) or {}
            for _, e in ipairs(rows[1] and rows[1].scenarios or {}) do
                if e.concentrate and e.concentration > 0 and e.concentrationValue and e.concentrationValue > 0
                    and e.profit and e.profit > 0 and (not accept or accept(recipe, e)) then
                    -- One cap per item made (each tier is its own item)
                    local capKey = e.itemID or (recipe.recipeID .. ":" .. e.tier)
                    if caps[capKey] == nil then
                        local demand = e.demand or (e.itemID and addon:GetDemand(e.itemID, recipe.outputName))
                        caps[capKey] = (demand and e.outputPerCraft > 0)
                            and math.max(math.floor(demand / e.outputPerCraft), 1) or math.huge
                    end
                    found[capKey] = found[capKey] or {}
                    table.insert(found[capKey], {
                        recipe = recipe, row = e, tierCount = e.tierCount, capKey = capKey,
                        full = e.scenario.concentration, points = e.concentration,
                        gain = e.concentrationValue * e.concentration,
                    })
                end
            end
        end
    end

    -- Drop mixes never worth using: another mix of the same item costs no
    -- more concentration and earns at least as much per craft
    local options, byRecipe = {}, {}
    for _, list in pairs(found) do
        table.sort(list, function(a, b)
            if a.full ~= b.full then return a.full < b.full end
            return a.gain > b.gain
        end)
        local bestGain = -math.huge
        for _, o in ipairs(list) do
            if o.gain > bestGain then
                bestGain = o.gain
                table.insert(options, o)
                byRecipe[o.recipe] = byRecipe[o.recipe] or {}
                table.insert(byRecipe[o.recipe], o)
            end
        end
    end

    local counts, used, left = {}, {}, budget
    local function Room(capKey, adjust)
        return caps[capKey] - (used[capKey] or 0) - (adjust or 0)
    end
    local function Crafts(option, n)
        counts[option] = (counts[option] or 0) + n
        used[option.capKey] = (used[option.capKey] or 0) + n
        left = left - n * option.points
    end
    -- How many crafts of an option fit in `amount` concentration
    local function Fit(option, amount)
        if amount < option.full then return 0 end
        return math.floor((amount - option.full) / option.points) + 1
    end

    -- 1. Fill by gold per point
    table.sort(options, function(a, b) return a.gain / a.points > b.gain / b.points end)
    for _, o in ipairs(options) do
        local n = math.min(Room(o.capKey), Fit(o, left))
        if n > 0 then Crafts(o, n) end
    end

    -- 2. Improve
    local byGain = {}
    for _, o in ipairs(options) do table.insert(byGain, o) end
    table.sort(byGain, function(a, b) return a.gain > b.gain end)
    local minFull = math.huge
    for _, o in ipairs(options) do minFull = math.min(minFull, o.full) end

    -- The option of another recipe than `skip` earning the most per craft
    -- that fits in `amount`
    local function BestAdd(amount, skip)
        if amount < minFull then return nil end
        for _, o in ipairs(byGain) do
            if o.recipe ~= skip and amount >= o.full and Room(o.capKey) > 0 then return o end
        end
    end

    -- A recipe's crafts now: points used, extra gold, and crafts per item
    local function RecipeUse(recipe)
        local points, gain, perItem = 0, 0, {}
        for _, o in ipairs(byRecipe[recipe]) do
            local n = counts[o] or 0
            points = points + n * o.points
            gain = gain + n * o.gain
            perItem[o.capKey] = (perItem[o.capKey] or 0) + n
        end
        return points, gain, perItem
    end

    for _ = 1, MAX_IMPROVEMENTS do
        local bestValue, bestMove = 1, nil -- at least 1 copper better
        local add = BestAdd(left)
        if add and add.gain > bestValue then
            bestValue, bestMove = add.gain, { add = add }
        end
        -- Re-plan one recipe: its concentration plus what's left, split
        -- between up to two of its mixes (i of a, then j of b), then the
        -- best craft of another recipe that fits in what remains
        for recipe, list in pairs(byRecipe) do
            local points, gain, own = RecipeUse(recipe)
            if points > 0 then
                local amount = points + left
                for _, a in ipairs(list) do
                    local roomA = Room(a.capKey) + (own[a.capKey] or 0)
                    for i = 0, math.min(roomA, Fit(a, amount), MAX_CRAFTS_TRIED) do
                        local afterA = amount - i * a.points
                        for _, b in ipairs(list) do
                            local j = 0
                            if b ~= a then
                                local roomB = Room(b.capKey) + (own[b.capKey] or 0) - (b.capKey == a.capKey and i or 0)
                                j = math.max(math.min(roomB, Fit(b, afterA)), 0)
                            end
                            local extra = BestAdd(afterA - j * b.points, recipe)
                            local total = i * a.gain + j * b.gain - gain + (extra and extra.gain or 0)
                            if total > bestValue then
                                bestValue = total
                                bestMove = { recipe = recipe, a = a, i = i, b = b, j = j, add = extra }
                            end
                        end
                    end
                end
            end
        end
        if not bestMove then break end
        if bestMove.recipe then
            for _, o in ipairs(byRecipe[bestMove.recipe]) do
                if (counts[o] or 0) > 0 then Crafts(o, -counts[o]) end
            end
            if bestMove.i > 0 then Crafts(bestMove.a, bestMove.i) end
            if bestMove.j > 0 then Crafts(bestMove.b, bestMove.j) end
        end
        if bestMove.add then Crafts(bestMove.add, 1) end
    end

    local plan, totalGain = {}, 0
    for o, n in pairs(counts) do
        if n > 0 then
            table.insert(plan, {
                recipe = o.recipe, row = o.row, tierCount = o.tierCount,
                crafts = n, points = n * o.points, gain = n * o.gain,
                profit = o.row.profit * o.row.outputPerCraft * n,
            })
            totalGain = totalGain + n * o.gain
        end
    end
    table.sort(plan, function(a, b) return a.gain > b.gain end)
    return plan, budget - left, totalGain
end

-- Inline quality icon for a tier, e.g. the silver/gold icon
function addon:TierIconText(tier, tierCount)
    if tierCount == 2 then
        return string.format("|A:Professions-ChatIcon-Quality-12-Tier%d:14:14|a", tier)
    end
    return string.format("|A:Professions-ChatIcon-Quality-Tier%d:14:14|a", tier)
end

function addon:InitializeQuality()
end

_G.Goldsmith = addon
