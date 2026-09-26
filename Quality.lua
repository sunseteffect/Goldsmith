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
-- The game confirms each mix really reaches the tier. With concentration,
-- partial mixes are tried too: more spent on materials means less
-- concentration needed.
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

    -- All best materials, and concentration on top of each mix (and half
    -- of each mix: some materials, less concentration)
    local all = {}
    for i, s in ipairs(qslots) do all[i] = s.quantity end
    AddScenario(all, false)
    AddScenario(all, true)
    for _, mix in ipairs(mixes) do
        AddScenario(mix, true)
        local half = {}
        for slot, units in pairs(mix) do half[slot] = math.floor(units / 2) end
        AddScenario(half, true)
    end

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
            local checked, source, age = addon:CheckAgainstMarket(out.itemID, price, "Auctionator", nil)
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
-- craft model (your stats).
local function ScenarioCost(recipe, scenario)
    local outputPerCraft, modelSlots = addon:GetCraftModel(recipe)
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
    local stats = addon.char.recipeStats[recipe.recipeID]
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
function addon:GetTierRows(recipe)
    local td = addon.char.tierData[recipe.recipeID]
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
        for _, row in ipairs({ plain[tier], concentrated[tier] }) do
            -- Concentration that lands on a tier you can already reach
            -- without it at the same cost adds nothing; skip it
            local redundant = row and row.concentrate and plain[tier] and plain[tier].cost <= row.cost
            if row and not redundant then
                row.tierCount = #td.qualities
                row.scenarios = evaluated
                row.description = addon:DescribeMix(recipe, row.scenario)
                if row.itemID then
                    row.demand, row.demandSource = addon:GetDemand(row.itemID, recipe.outputName)
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

-- The best way to spend `budget` concentration on a profession's crafts:
-- most gold per concentration point first, as many crafts as the budget
-- allows (capped at about one day of the item's sales), then the next.
-- Only crafts that make a profit with concentration are used.
-- Returns { { recipe, row, crafts, points, gain, profit } }, points used,
-- and total extra profit from concentrating.
function addon:PlanConcentration(profession, budget)
    -- Only recipes that spend this concentration (each expansion's version
    -- of a profession has its own)
    local currencyID = GoldsmithDB.concentrationCurrency and GoldsmithDB.concentrationCurrency[profession]
    local candidates = {}
    for _, recipe in pairs(GoldsmithDB.recipes) do
        local stats = addon.char.recipeStats[recipe.recipeID]
        if recipe.profession == profession and stats and stats.concentrationCurrencyID == currencyID then
            local best
            local rows = addon:GetTierRows(recipe) or {}
            for _, row in ipairs(rows) do
                if row.concentrate and row.concentration > 0 and row.concentrationValue
                    and row.concentrationValue > 0 and row.profit and row.profit > 0
                    and (not best or row.concentrationValue > best.concentrationValue) then
                    best = row
                end
            end
            -- Also check tiers only reachable with concentration that
            -- GetTierRows didn't pick (it prefers no-concentration ways)
            for _, e in ipairs(best and best.scenarios or {}) do
                if e.concentrate and e.concentrationValue and e.concentrationValue > best.concentrationValue
                    and e.profit and e.profit > 0 then
                    best = e
                end
            end
            if best then
                table.insert(candidates, { recipe = recipe, row = best, tierCount = rows[1] and rows[1].tierCount })
            end
        end
    end
    table.sort(candidates, function(a, b) return a.row.concentrationValue > b.row.concentrationValue end)

    local plan, remaining, totalGain = {}, budget, 0
    for _, c in ipairs(candidates) do
        local perCraft = c.row.concentration
        local crafts = math.floor(remaining / perCraft)
        if c.row.demand and c.row.outputPerCraft and c.row.outputPerCraft > 0 then
            crafts = math.min(crafts, math.max(math.floor(c.row.demand / c.row.outputPerCraft), 1))
        end
        if crafts > 0 then
            local points = crafts * perCraft
            local gain = c.row.concentrationValue * points
            table.insert(plan, {
                recipe = c.recipe, row = c.row, tierCount = c.tierCount,
                crafts = crafts, points = points, gain = gain,
                profit = c.row.profit * c.row.outputPerCraft * crafts,
            })
            remaining = remaining - points
            totalGain = totalGain + gain
        end
        if remaining <= 0 then break end
    end
    return plan, budget - remaining, totalGain
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
