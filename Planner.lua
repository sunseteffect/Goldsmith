local addon = _G.Goldsmith or {}

local AH_CUT = 0.05

-- Craft planner
--
-- Works out the cheapest way to get every material for a craft *right now*
-- and builds a tree of what to buy, craft or mill for a chosen quantity.
--
-- Unlike the Crafts tab's costs (which use what you actually paid), the
-- planner uses current replacement costs, because the question is "what's
-- the cheapest way to get this today":
--   Buy    - Auctionator's current AH price
--   Vendor - no AH price, but you've bought it before (e.g. from a vendor);
--            priced at what you paid
--   Craft  - a saved recipe makes it; priced from its own cheapest materials
--   Mill   - you've milled a herb that gives it; priced from the herb's AH
--            price and your yield, with the herb's cost split across the
--            pigments it gives by their AH value
-- The cheapest available option wins.

local MAX_DEPTH = 4
-- Salvage (mill, prospect, crush) is only planned from your own rates
-- after this many salvages of the item, and only when it's this much
-- cheaper than the other ways (user, 2026-10-09)
local MIN_SALVAGE_CASTS = 10
local SALVAGE_MARGIN = 0.10
local SalvageCasts -- below, sized for an unlucky run

-- A character's key from their saved table (WithCharacter passes the table)
local keyOf = setmetatable({}, { __mode = "k" })
local function KeyOf(c)
    if keyOf[c] then return keyOf[c] end
    for key, data in pairs(GoldsmithDB.characters) do
        if data == c then keyOf[c] = key return key end
    end
end

local function GetOnHand(itemID)
    -- The tour's sample (Tour.lua): what its "you" holds, not your bags
    if addon:UsingTourData() then
        return addon.char.stock and addon.char.stock[itemID] or 0
    end
    -- Another character's plan (WithCharacter): their bags and bank as
    -- counted at their last login, plus the warband bank. Planned with
    -- nothing held, Maddoxius's queue asked to buy 30 scales with 131 on
    -- them (user, 2026-10-24).
    -- Their mail (mailed to them from here) and what Buy next bought for
    -- them on another character count too (Shop.lua's boughtFor)
    local c = addon:StatsChar()
    if c ~= addon.char then
        local key = KeyOf(c)
        return (c.stock and c.stock[itemID] or 0) + (GoldsmithDB.warbandStock[itemID] or 0)
            + (key and addon.InMailCountFor and addon:InMailCountFor(key, itemID) or 0)
            + (key and addon.OnTheWayFor and addon:OnTheWayFor(key, itemID) or 0)
    end
    -- Bought with Buy next and waiting in the mailbox counts as yours
    -- (Shop.lua), so it isn't bought again or swapped for something else.
    -- Less what you bought for another character's queue (it's theirs),
    -- plus what another character bought for yours.
    local own = (C_Item.GetItemCount(itemID, true, false, true, true) or 0)
        + (addon.InMailCount and addon:InMailCount(itemID) or 0)
        - (addon.ReservedCount and addon:ReservedCount(itemID) or 0)
    return math.max(own, 0) + (addon.OnTheWayFor and addon:OnTheWayFor(addon.charKey, itemID) or 0)
end

-- Crafting from materials you already hold beats buying unless buying is
-- this much cheaper: a queue said "0 to buy" (ingots from your ore), then
-- a price update made buying 0.3% cheaper and it asked for 29 ingots with
-- 234 ore in the bags (user, 2026-10-16). Saves a trip to the AH, and a
-- plan doesn't flip mid-queue over pennies.
local HELD_CRAFT_MARGIN = 0.10
-- For buy-or-craft itself, held materials win unless buying is a quarter
-- cheaper: 10% wasn't enough when Goldsmith Data's update swapped the scan
-- for TSM prices, and the plan bought 13 gold ingots with the ore for them
-- in the bags (user, 2026-10-22: use what i have first)
local HELD_CRAFT_PREFERENCE = 0.25
-- Salvaging what you already hold (a salvage at least) is picked unless
-- another way costs under this share of it, and without the work margin:
-- 5 Hollow Grouper bought for the plan at 0.88g, once the AH showed that
-- price instead of an old 0.24g, made buying 5 fillets cheaper and the plan
-- dropped the salvage (user, 2026-10-19: "use what i have first", unless
-- the material is suddenly worth far more than what it makes)
local HELD_SALVAGE_SHARE = 0.5

-- Whether you hold enough of every material for at least one craft (any
-- quality of each). Vendor materials don't count: you buy them on the way.
-- Down to 1 Luminant Flux after a gold Refulgent Copper Ingot, the plan
-- stopped counting the ore as held and bought 13 ingots for 0.15g less
-- each than crafting them (user, 2026-10-22).
addon.GetOnHand = function(_, itemID) return GetOnHand(itemID) end

local function HoldsMaterials(recipe)
    local reagents = recipe and recipe.reagents
    if not reagents or #reagents == 0 then return false end
    local any = false
    for _, r in ipairs(reagents) do
        local have, vendor = 0, true
        for _, id in ipairs(r.itemIDs or {}) do
            have = have + GetOnHand(id)
            if not addon:IsVendorItem(id) then vendor = false end
        end
        if not vendor or #(r.itemIDs or {}) == 0 then
            if have < (r.quantity or 1) then return false end
            any = true
        end
    end
    return any
end

-- Recipe that makes an item, if one is saved
local function FindRecipeForItem(itemID, name)
    for _, recipe in pairs(GoldsmithDB.recipes) do
        if recipe.outputItemID == itemID then
            return recipe
        end
    end
    return name and addon:FindRecipeByOutput(name)
end

-- Expected items made per craft and materials used per craft, from your
-- crafting stats (see GetCraftModel in Pricing.lua)
local function GetCraftNumbers(recipe)
    local outputPerCraft, slots = addon:GetCraftModel(recipe)
    return outputPerCraft, slots
end

-- Crafts are whole: enough to expect at least `wanted` items
local function WholeCrafts(wanted, outputPerCraft)
    if wanted <= 0 or outputPerCraft <= 0 then return 0 end
    return math.ceil(wanted / outputPerCraft - 0.0001)
end

-- Items a craft is sure to make, without multicraft. Plans count crafts on
-- this, so you don't have to shop again when multicraft doesn't proc;
-- extras are a bonus. (expectedOutput still says what to expect.)
local function SurePerCraft(recipe, outputPerCraft)
    local sure = recipe.outputMin
    if sure and sure > 0 and sure < outputPerCraft then return sure end
    return outputPerCraft
end

-- The planner's box is in crafts (user, 2026-10-12: "we usually think in
-- crafts"); plans are still built for a number of items. Items to ask
-- BuildPlan for to get exactly `crafts` crafts, and the crafts `items`
-- items take. Run with the crafter's stats (WithCharacter).
function addon:ItemsForCrafts(recipe, crafts)
    return crafts * SurePerCraft(recipe, (GetCraftNumbers(recipe)))
end

function addon:CraftsForItems(recipe, items)
    return WholeCrafts(items, SurePerCraft(recipe, (GetCraftNumbers(recipe))))
end

-- Materials needed for `crafts` crafts: the full amount for every craft.
-- Starting a craft takes the full amount, and resourcefulness returns are
-- luck (three crafts in a row can return nothing), so counting on them
-- left the last craft short. What comes back stays in your bags for next
-- time. Costs still use the expected amount (see PartUse).
local function MaterialNeed(s, crafts)
    if crafts <= 0 then return 0 end
    return s.slot.quantity * crafts
end

-- All the ways to get one unit of an item, and the cheapest. memo avoids
-- working the same item out twice; visiting stops recipe loops.
local GetOptions

-- Cheapest item in a recipe slot (slots can list several qualities)
-- In a slot with several qualities, the items are listed lowest quality
-- first, so an item's position is its quality tier. Returns tier and the
-- number of tiers, or nil for materials without qualities.
local function SlotQuality(slot, index)
    local count = slot.itemIDs and #slot.itemIDs or 0
    if count > 1 then
        return index, count
    end
end

-- Qualities compare with concentration charged (compareUnit), as buying
-- and crafting do in GetOptions: a gold Smuggler's Enchanted Edge "made
-- with concentration" at the silver's 25.33g beat silver bought at 29g,
-- then the concentration ran out and the plan bought gold at 59.23g
-- (user, 2026-10-26)
local function SlotUnit(best) return best.compareUnit or best.unit end
local function GetSlotChoice(slot, depth, memo, visiting)
    local best
    for i, itemID in ipairs(slot.itemIDs or {}) do
        local options = GetOptions(itemID, slot.names[i], depth, memo, visiting)
        if options.best and (not best or SlotUnit(options.best) < SlotUnit(best.options.best)) then
            local tier, tierCount = SlotQuality(slot, i)
            best = { itemID = itemID, name = slot.names[i], options = options,
                     qualityTier = tier, tierCount = tierCount }
        end
    end
    if not best and slot.itemIDs and slot.itemIDs[1] then
        local itemID = slot.itemIDs[1]
        local tier, tierCount = SlotQuality(slot, 1)
        best = { itemID = itemID, name = slot.names[1],
                 options = GetOptions(itemID, slot.names[1], depth, memo, visiting),
                 qualityTier = tier, tierCount = tierCount }
    end
    return best
end

GetOptions = function(itemID, name, depth, memo, visiting)
    if memo[itemID] then return memo[itemID] end
    local options = {}

    -- Vendor: a recorded vendor price. The AH is picked when it's cheaper
    -- than the vendor, and is always there to choose (right-click): cooking
    -- in a raid, with no vendor but the AH on a mount (user, 2026-10-22)
    local vendorPrice = addon:GetVendorPrice(itemID)
    local ahPrice = addon:GetAHPrice(itemID, true)
    if vendorPrice then
        options.vendor = { method = "Vendor", unit = vendorPrice, detail = "Vendor price" }
    end
    if ahPrice then
        options.buy = { method = "Buy", unit = ahPrice, ageText = addon:AHPriceAgeText(itemID, true) }
    end
    if not vendorPrice and not ahPrice and name then
        -- No prices at all: if you've bought it before it's likely a vendor
        -- item you haven't opened the vendor for since
        local paid = addon:GetAverageCost(name)
        if paid then
            options.vendor = { method = "Vendor", unit = paid, detail = "What you paid\nopen the vendor to record its price" }
        end
    end

    -- Craft it
    local recipe = depth < MAX_DEPTH and not visiting[itemID] and FindRecipeForItem(itemID, name)
    -- A recipe with quality tiers makes the tier your skill and materials
    -- reach, not whichever the plan wants: a gold ingot was planned as
    -- crafted from the cheapest materials, and the step made silver ones
    -- (user, 2026-10-09). Such an item is crafted the way its tier row says
    -- (the cheapest mix reaching it, with concentration if only that
    -- reaches it), or not at all if no way does. The row is worked out with
    -- the stats of whoever makes it (CraftedTierRow): a Jewelcrafting vial in
    -- Mysticmead's Alchemy plan fell back to the plain recipe, as if crafting
    -- always reached gold (2026-10-10).
    local hasTiers = false
    if recipe then
        for _, c in pairs(GoldsmithDB.characters) do
            if c.tierData and c.tierData[recipe.recipeID] then hasTiers = true break end
        end
    end
    if hasTiers then
        local row, _, crafterKey = addon:CraftedTierRow(itemID, name)
        if row then
            -- unit is the gold it costs; compareUnit adds its concentration
            -- at CONC_POINT_COST, for choosing between crafting and buying.
            -- The row prices its materials as bought; the plan this craft
            -- gets (CraftPlanUnit) mills them when that's cheaper, as its own
            -- rows then say. A Missive's Sienna Ink cost 20.50g here with
            -- its pigment rows saying "Mill", against 18.43g on the to-do
            -- (user, 2026-10-25: "if there is a gap then it is explained").
            local unit = row.cost
            if not row.concentrate and not addon.craftUnitBusy then
                local planned = addon:CraftPlanUnit(itemID, name)
                if planned and planned < unit then unit = planned end
            end
            local concCost = addon:ConcentrationPerItem(row) * addon.CONC_POINT_COST
            options.craft = { method = "Craft", unit = unit, compareUnit = unit + concCost,
                recipe = recipe, tierRow = row, crafterKey = crafterKey,
                verb = row.concentrate and "Craft + conc" or nil }
        end
        recipe = nil
    end
    if recipe then
        visiting[itemID] = true
        local outputQty, slots = GetCraftNumbers(recipe)
        local perCraft, complete = 0, true
        for _, s in ipairs(slots) do
            local choice = GetSlotChoice(s.slot, depth + 1, memo, visiting)
            if choice and choice.options.best then
                perCraft = perCraft + choice.options.best.unit * s.quantity
            else
                complete = false
            end
        end
        visiting[itemID] = nil
        if complete and outputQty > 0 then
            options.craft = { method = "Craft", unit = perCraft / outputQty, recipe = recipe }
        end
    end

    -- Mill it from a herb you've milled before, once you've salvaged it
    -- MIN_SALVAGE_CASTS times: fewer is luck, not a rate (3 gems crushed
    -- into 1 gemdust planned crushing at a loss, 2026-10-09). Records from
    -- before perCast was kept count as no casts: herbs aren't casts.
    -- Every item you could salvage for it also goes in options.millList,
    -- for the right-click menu (user, 2026-10-22: recycle the potions in my
    -- bags for Stabilized Derivate, even if it costs more): ones you've
    -- salvaged, and ones in your bags the same salvage takes, at the yield
    -- of what you've salvaged with it (estimateFrom). Only proven ones are
    -- picked on their own.
    local millList, listed = {}, {}
    local function MillOption(herbID, herbName, record, out, verb, estimateFrom)
        -- What it costs you: today's price, else what you paid or made it
        -- for; none (a bound potion in the bags) counts as free
        local herbCost = addon:GetMarketPrice(herbID, true) or addon:GetAverageCost(herbName)
            or addon:GetOwnCost(herbName, nil, herbID)
        -- Split the herb's cost across its pigments by AH value
        local sumValue, sumQty, allPriced, ownValue = 0, 0, true, nil
        for outID, o in pairs(record.outputs) do
            sumQty = sumQty + o.qty
            local p = addon:GetMarketPrice(outID)
            if p then
                sumValue = sumValue + p * o.qty
                if outID == itemID then ownValue = p * o.qty end
            else
                allPriced = false
            end
        end
        local share = (allPriced and sumValue > 0) and (ownValue / sumValue) or (out.qty / sumQty)
        local unit = (herbCost or 0) * record.milled * share / out.qty
        local option = {
            -- One you hold gets HELD_CRAFT_MARGIN off when picking: two
            -- plant parts about the same price swapped back and forth as
            -- AH searches came in, and Buy next could buy one, then ask
            -- for the other with the first in the bags (user, 2026-10-19)
            rank = GetOnHand(herbID) > 0 and unit * (1 - HELD_CRAFT_MARGIN) or unit,
            -- verb: how it's salvaged ("Prospect" for ore)
            method = "Mill", unit = unit, verb = verb,
            herbID = herbID, herbName = herbName,
            perHerb = out.qty / record.milled,
            perCast = record.perCast, profession = record.profession,
            share = share, held = GetOnHand(herbID),
            noPrice = herbCost == nil or nil, estimateFrom = estimateFrom,
        }
        listed[herbID] = true
        table.insert(millList, option)
        return option
    end
    for herbID, record in pairs(GoldsmithDB.milling) do
        local out = record.outputs[itemID]
        local casts = record.perCast and record.milled / math.max(record.perCast, 1) or 0
        if out and out.qty > 0 and record.milled > 0 then
            local option = MillOption(herbID, record.name, record, out, addon:GetSalvageVerb(herbID))
            if casts >= MIN_SALVAGE_CASTS and not option.noPrice
                and (not options.mill or option.rank < options.mill.rank) then
                options.mill = option
            end
        end
    end
    -- Others in your bags the same salvage spell takes, at the yield of
    -- the one you've salvaged most with it
    local proven = {}
    for _, option in ipairs(millList) do table.insert(proven, option) end
    table.sort(proven, function(a, b)
        return GoldsmithDB.milling[a.herbID].milled > GoldsmithDB.milling[b.herbID].milled
    end)
    for _, known in ipairs(proven) do
        local record = GoldsmithDB.milling[known.herbID]
        local perCast = math.max(record.perCast or 1, 1)
        for recipeID in pairs(addon:SalvageRecipesFor(known.herbID)) do
            for _, inputID in ipairs(addon:SalvageInputs(recipeID)) do
                -- Salvaged before without giving this: that's real data
                if not listed[inputID] and not GoldsmithDB.milling[inputID] and GetOnHand(inputID) >= perCast then
                    local name = C_Item.GetItemNameByID(inputID)
                    if name then
                        MillOption(inputID, name, record, record.outputs[itemID], known.verb, known.herbName)
                    elseif C_Item.RequestLoadItemDataByID then
                        C_Item.RequestLoadItemDataByID(inputID)
                    end
                end
            end
        end
    end
    -- Cheapest first (user, 2026-10-22); no price at the bottom
    table.sort(millList, function(a, b)
        if (a.noPrice or false) ~= (b.noPrice or false) then return not a.noPrice end
        return a.unit < b.unit
    end)
    options.millList = #millList > 0 and millList or nil
    -- Your pick of which item to salvage (right-click menu; see WithChoices)
    local choices = not memo.ignoreOverrides and addon.planChoices
    local fromID = choices and choices[itemID] == "Mill" and choices.salvageFrom and choices.salvageFrom[itemID]
    if fromID then
        for _, option in ipairs(millList) do
            if option.herbID == fromID then options.mill = option end
        end
    end

    -- Salvaging is work: it has to beat the rest by SALVAGE_MARGIN to be
    -- the cheapest way, not by a few silver
    -- Crafting with concentration compares with its concentration charged
    -- (compareUnit); salvage with its margin
    -- Crafting from what you hold gets HELD_CRAFT_PREFERENCE off
    local craftHeld = options.craft and HoldsMaterials(options.craft.recipe)
    options.craftHeld = craftHeld or nil
    local millHeld = options.mill and GetOnHand(options.mill.herbID) >= math.max(options.mill.perCast or 1, 1)
    options.millHeld = millHeld or nil
    local cheapestUnit
    -- Vendor first, so it wins a tie with the AH
    for _, key in ipairs({ "vendor", "buy", "craft", "mill" }) do
        local option = options[key]
        local unit = option and (key == "mill" and option.unit * (1 + SALVAGE_MARGIN) or option.compareUnit or option.unit)
        if unit and key == "craft" and craftHeld then unit = unit * (1 - HELD_CRAFT_PREFERENCE) end
        -- The best way that isn't salvaging, for BuildNode's held share
        if option and key ~= "mill" and (not options.otherUnit or unit < options.otherUnit) then
            options.other, options.otherUnit = option, unit
        end
        if unit and key == "mill" and millHeld then unit = option.unit * HELD_SALVAGE_SHARE end
        if option and (not cheapestUnit or unit < cheapestUnit) then
            options.cheapest, cheapestUnit = option, unit
        end
    end

    -- Your own choice (right-click a plan row) wins over the cheapest, if
    -- that way is available for this item. Choices belong to one plan and
    -- its queue entry (WithChoices). memo.ignoreOverrides is used to price
    -- the plan the cheapest way, for comparison.
    local override = not memo.ignoreOverrides and addon.planChoices and addon.planChoices[itemID]
    local chosen = override and options[string.lower(override)]
    options.best = chosen or options.cheapest
    options.override = chosen and override or nil

    memo[itemID] = options
    return options
end

-- Making an item from today's prices, as a plan prices it, for the Crafts
-- list's material costs (SlotCost, Pricing.lua): the list had Ink of the
-- Sea at its 3.50g AH price, the plan crafted it from pigment at 3.12g, and
-- a glyph showed -1.20g in the list and -0.06g in its plan (user,
-- 2026-10-18). Kept until data changes, like SlotCost, so it's worked out
-- with the stats of whichever character asked first. While it's working,
-- craftUnitBusy is set: a tier recipe's costs come back through SlotCost,
-- which then leaves crafting out (and doesn't keep that answer) rather
-- than loop.
local craftUnitCache = addon:NewCache()
function addon:CraftUnitCost(itemID, name)
    if addon.craftUnitBusy or not itemID then return nil end
    local store = craftUnitCache:Get()
    local cached = store[itemID]
    if cached == nil then
        store.memo = store.memo or {}
        -- No pausing for a frame while busy is set: other code would see it
        addon.noYield = addon.noYield + 1
        addon.craftUnitBusy = true
        local options = GetOptions(itemID, name, 1, store.memo, {})
        addon.craftUnitBusy = false
        addon.noYield = addon.noYield - 1
        -- Not when it takes concentration: that isn't free, and the
        -- craft using it may need it all. Gold inks priced as crafted
        -- with concentration made gold Missives look +490g for 2 crafts;
        -- the plan then had none left for the inks and bought them, +341g
        -- (user, 2026-10-18).
        local craft = options.craft
        local concentrated = craft and craft.tierRow and craft.tierRow.concentrate
        cached = craft and not concentrated and craft.unit or false
        store[itemID] = cached
    end
    return cached or nil
end

-- Salvaging for an item (milling, prospecting, butchering) at today's
-- prices, as a plan prices it: the unit cost and SALVAGE_MARGIN (a plan
-- salvages only when that beats the other ways by the margin), or nil when
-- you haven't salvaged for it enough to know the yield. For the Crafts
-- list's material costs (SlotCost, QualityPrice): they left salvaging out,
-- so Munsell Ink's pigments counted at the AH's price while its plan milled
-- them, and the to-do and the queue disagreed (user, 2026-10-25: "if there
-- is a gap then it is explained"). Kept until data changes.
local salvageUnitBusy = {}
function addon:SalvageUnitCost(itemID, name)
    if not itemID or salvageUnitBusy[itemID] then return nil end
    local store = craftUnitCache:Get()
    store.salvage = store.salvage or {}
    local cached = store.salvage[itemID]
    if cached == nil then
        store.memo = store.memo or {}
        addon.noYield = addon.noYield + 1
        salvageUnitBusy[itemID] = true
        local wasBusy = addon.craftUnitBusy
        addon.craftUnitBusy = true
        local options = GetOptions(itemID, name, 1, store.memo, {})
        addon.craftUnitBusy = wasBusy
        salvageUnitBusy[itemID] = nil
        addon.noYield = addon.noYield - 1
        local mill = options.mill
        cached = mill and mill.unit and not mill.noPrice and mill.unit or false
        store.salvage[itemID] = cached
    end
    if cached then return cached, SALVAGE_MARGIN end
end

-- The cheapest way to make an item yourself: crafting it, priced by the
-- plan its crafter would get (MAKE_SAMPLE of it, without concentration,
-- nothing from your bags), or salvaging (with SALVAGE_MARGIN on top,
-- salvaging being work). Returns the unit cost and its verb ("Craft",
-- "Mill", "Prospect"...), or nil. For Cheap materials: Sienna Ink at
-- 19.28g was "Buy 65" while its plan crafts it for about 12g, milling the
-- pigments (user, 2026-10-23). Not GetOptions' craft option: worked out
-- inside CraftUnitCost's guard, that priced the pigments as bought and the
-- ink came out dearer than the AH. Kept until data changes.
local MAKE_SAMPLE = 10
local makeUnitCache = addon:NewCache()

local function PlanUnitCost(itemID, name)
    local recipe = FindRecipeForItem(itemID, name)
    local charKey = recipe and addon:GetCrafter(recipe.recipeID)
    if not charKey then return nil end
    local c = GoldsmithDB.characters[charKey]
    local td = c and c.tierData and c.tierData[recipe.recipeID]
    local tier
    for t, out in pairs(td and td.outputs or {}) do
        if out.itemID == itemID then tier = t end
    end
    -- A quality this crafter's data doesn't list: not theirs to make
    if td and not tier then return nil end
    local p = { recipe = recipe, charKey = charKey, tier = tier, concentrate = false }
    local tierInfo = addon:WithCharacter(charKey, addon.FindTierInfo, p)
    if tier and not tierInfo then return nil end
    local plan = addon:WithChoices({}, addon.WithCharacter, addon, charKey, addon.BuildPlan, addon,
        recipe, MAKE_SAMPLE, false, tierInfo, {})
    if plan and plan.complete and (plan.expectedOutput or 0) > 0 then
        return plan.cost / plan.expectedOutput
    end
end

-- PlanUnitCost alone (crafting, not salvaging), kept until data changes.
-- nil while it's being worked out, so a plan that reaches the same item
-- again doesn't go round in circles.
local planUnitBusy = {}
function addon:CraftPlanUnit(itemID, name)
    if not itemID or planUnitBusy[itemID] then return nil end
    local store = makeUnitCache:Get()
    store.plans = store.plans or {}
    local cached = store.plans[itemID]
    if cached == nil then
        addon.noYield = addon.noYield + 1
        planUnitBusy[itemID] = true
        cached = PlanUnitCost(itemID, name) or false
        planUnitBusy[itemID] = nil
        addon.noYield = addon.noYield - 1
        store.plans[itemID] = cached
    end
    return cached or nil
end

function addon:MakeUnitCost(itemID, name)
    if addon.craftUnitBusy or not itemID then return nil end
    local store = makeUnitCache:Get()
    local cached = store[itemID]
    if cached == nil then
        cached = false
        local unit = addon:CraftPlanUnit(itemID, name)
        if unit then cached = { unit = unit, way = "Craft" } end
        store.memo = store.memo or {}
        addon.noYield = addon.noYield + 1
        addon.craftUnitBusy = true
        local options = GetOptions(itemID, name, 1, store.memo, {})
        addon.craftUnitBusy = false
        addon.noYield = addon.noYield - 1
        local mill = options.mill
        if mill and mill.unit then
            local unit = mill.unit * (1 + SALVAGE_MARGIN)
            if not cached or unit < cached.unit then cached = { unit = unit, way = mill.verb or "Mill" } end
        end
        store[itemID] = cached
    end
    if cached then return cached.unit, cached.way end
end

-- Your choices of how to get items ("Buy", "Craft", "Mill", "Vendor" by
-- itemID; none = the cheapest way) for the plans fn builds. They belong to
-- one plan, and to its queue entry once queued (entry.choices), and end
-- with it. They used to be saved per item for every plan: a "Salvage"
-- picked for Thalassian Fillet while testing on 2026-10-19 still chose
-- salvaging Hollow Grouper at 3g over buying fillets at 0.90g the next day
-- (user, 2026-10-20: "we usually want the cheapest"; "per queue for sure").
-- Kept in addon.planChoices while fn runs; inside work it's the work's
-- own (RunWork swaps it like statsChar) and there's no pcall, as in
-- WithCharacter.
local function Pack(...) return { n = select("#", ...), ... } end

function addon:WithChoices(choices, fn, ...)
    local previous = addon.planChoices
    addon.planChoices = choices
    if addon:InWork() then
        local results = Pack(fn(...))
        addon.planChoices = previous
        return unpack(results, 1, results.n)
    end
    addon.noYield = addon.noYield + 1
    local results = Pack(pcall(fn, ...))
    addon.noYield = addon.noYield - 1
    addon.planChoices = previous
    if not results[1] then error(results[2], 0) end
    return unpack(results, 2, results.n)
end

-- Choices for one of the craft's own materials, as { choice, units } parts
-- (units per craft). When planning a quality tier, a material that comes in
-- qualities is split between its lowest and best quality as the tier's mix
-- says (e.g. 12 lowest + 8 best); otherwise one part at the cheapest.
local function TopSlotParts(slot, tier, memo, recipe)
    local ids = slot.itemIDs or {}
    local visiting = { [recipe.outputItemID] = true }
    if tier and tier.scenario and #ids > 1 then
        local high = addon:ScenarioHighUnits(tier.scenario, slot)
        local parts = {}
        for _, part in ipairs({ { index = 1, units = slot.quantity - high }, { index = #ids, units = high } }) do
            if part.units > 0 then
                table.insert(parts, {
                    units = part.units,
                    choice = {
                        itemID = ids[part.index],
                        name = slot.names[part.index],
                        options = GetOptions(ids[part.index], slot.names[part.index], 1, memo, visiting),
                        qualityTier = part.index,
                        tierCount = #ids,
                        -- The lowest quality, for comparing prices on the row
                        lowID = ids[1],
                    },
                })
            end
        end
        return parts
    end
    local choice = GetSlotChoice(slot, 1, memo, visiting)
    return choice and { { units = slot.quantity, choice = choice } } or {}
end

-- Materials needed for `crafts` crafts of one part of a slot: the full
-- amount for every craft (see MaterialNeed)
local function PartNeed(s, units, crafts)
    if crafts <= 0 then return 0 end
    return units * crafts
end

-- What those crafts are expected to use up, after resourcefulness returns.
-- The craft's cost is priced on this.
local function PartUse(s, units, crafts)
    if crafts <= 0 then return 0 end
    local useFactor = s.slot.quantity > 0 and (s.quantity / s.slot.quantity) or 1
    return units * useFactor * crafts
end

-- One row of the plan tree. need is how many the parent needs; toGet is
-- what's left after what you already have (if useOnHand). Children are
-- only built for the chosen method, for toGet.
-- gold (top-level silver rows only): { itemID, units } spare gold of the
-- same material you hold, used for what silver you're short of when
-- MayUseHeldGold allows (node.gold = how many), else node.goldKept.
-- The key of the character whose stats are in use (BuildPlan runs with the
-- plan's crafter, see WithCharacter)
local function StatsKey()
    local char = addon:StatsChar()
    for key, c in pairs(GoldsmithDB.characters) do
        if c == char then return key end
    end
    return addon.charKey
end

-- Concentration a character has now for a profession, less what this plan
-- has already given out (ctx.conc). Unknown (never read) counts as no limit.
local function ConcAvailable(ctx, key, profession)
    local id = key .. "|" .. tostring(profession)
    if ctx.conc[id] == nil then
        local current
        if key == addon.charKey then current = addon:GetConcentration(profession) end
        if not current then current = addon:GetCharacterConcentration(key, profession) end
        ctx.conc[id] = current or math.huge
    end
    return ctx.conc[id], id
end

-- How many crafts fit in `available` concentration, each at its full cost:
-- ingenuity's refund is luck, so it isn't counted on (planned 3 with 1000,
-- only 2 started at 340 each; user 2026-10-16)
local function CraftsThatFit(available, full)
    if available == math.huge then return math.huge end
    if not full or available < full then return 0 end
    return math.floor(available / math.max(full, 1))
end

-- A material crafted with concentration: plan only what the crafter's
-- concentration covers now, and buy the rest (user, 2026-10-10: "a to do
-- means do it now"; ~1,600 points of gold vials can't be made today).
-- Changes node.best to a split ("Craft 1, buy 3") or to buying, and sets
-- node.craftItems (what's crafted) and node.concCrafts (crafts with
-- concentration). node.concShort when there's no other way to get it.
local function LimitByConcentration(node, ctx, outputQty)
    local best = node.best
    local row = best and best.method == "Craft" and best.tierRow
    if not (row and row.concentrate and row.concentration and row.concentration > 0) or node.toGet <= 0 then return end
    local key = best.crafterKey or StatsKey()
    local available, id = ConcAvailable(ctx, key, best.recipe.profession)
    local sure = SurePerCraft(best.recipe, outputQty)
    local wanted = WholeCrafts(node.toGet, sure)
    local full = row.scenario and row.scenario.concentration or row.concentration
    local fit = CraftsThatFit(available, full)
    local crafts = math.min(wanted, fit)
    if available ~= math.huge then ctx.conc[id] = available - crafts * full end
    node.concCrafts = crafts
    if crafts >= wanted then return end
    local other = node.options.buy or node.options.vendor
    local c = GoldsmithDB.characters[key]
    -- perCraft: what starting a craft needs (its full cost; ingenuity gives
    -- some back afterwards, so 409 can be short of a "406" craft)
    node.concNote = { name = c and c.name or key, available = available ~= math.huge and math.floor(available) or nil,
        perCraft = math.floor(full + 0.5) }
    if not other then
        -- Nothing else gets it: craft them all, and say concentration is short
        node.concCrafts = wanted
        node.concShort = true
        return
    end
    local craftItems = math.min(crafts * sure, node.toGet)
    if craftItems <= 0 then
        node.best = other
        return
    end
    local buyItems = node.toGet - craftItems
    node.craftItems = craftItems
    node.best = setmetatable({
        unit = (craftItems * best.unit + buyItems * other.unit) / node.toGet,
        verb = string.format("Craft %d, %s %d", math.floor(craftItems + 0.5),
            other.method == "Vendor" and "vendor" or "buy", math.ceil(buyItems - 0.0001)),
        split = { craftItems = craftItems, buyItems = buyItems, other = other },
    }, { __index = best })
end

local function BuildNode(itemID, name, need, depth, ctx, quality, gold)
    local options = GetOptions(itemID, name, depth, ctx.memo, {})
    -- In a queue, what earlier crafts already count on isn't yours to use again
    local have = ctx.useOnHand and math.max(GetOnHand(itemID) - (ctx.pool and ctx.pool[itemID] or 0), 0) or 0
    local short = math.max(need - have, 0)
    local goldUsed, goldKept = 0, nil
    if gold and gold.units > 0 and short > 0 then
        if gold.allowed then
            goldUsed = math.min(gold.units, short)
        else
            goldKept = { itemID = gold.itemID, units = math.min(gold.units, short) }
        end
    end
    local node = {
        itemID = itemID,
        name = name,
        depth = depth,
        need = need,
        have = math.min(have, need) + goldUsed,
        toGet = short - goldUsed,
        options = options,
        best = options.best,
        children = {},
        gold = goldUsed > 0 and { itemID = gold.itemID, units = goldUsed } or nil,
        goldKept = goldKept,
        lowID = quality and quality.lowID,
    }
    if ctx.pool then
        ctx.pool[itemID] = (ctx.pool[itemID] or 0) + node.have - goldUsed
        if goldUsed > 0 then ctx.pool[gold.itemID] = (ctx.pool[gold.itemID] or 0) + goldUsed end
    end
    -- Quality tier of this exact item, so the plan and shopping list say
    -- which quality to buy. Herbs from milling aren't slot choices, so ask
    -- the game (Midnight materials have 2 tiers).
    if quality and quality.qualityTier then
        node.qualityTier, node.tierCount = quality.qualityTier, quality.tierCount
    elseif C_TradeSkillUI.GetItemReagentQualityByItemInfo then
        local ok, tier = pcall(C_TradeSkillUI.GetItemReagentQualityByItemInfo, itemID)
        if ok and tier and tier > 0 then
            node.qualityTier, node.tierCount = tier, 2
        end
    end

    -- Salvage picked for what you hold (millHeld) counts the held part at
    -- HELD_SALVAGE_SHARE and the rest at its price: 2 Hollow Grouper held
    -- made the plan salvage 109 at 3g (1.49g a fillet) over buying fillets
    -- at 0.90g (user, 2026-10-20). Holding all of it is the old rule.
    if options.millHeld and node.best == options.mill and not options.override
        and node.toGet > 0 and options.other then
        local mill = options.mill
        local perCast = mill.perCast and mill.perCast > 1 and mill.perCast or 1
        local herbs = SalvageCasts(node.toGet, mill.perHerb * perCast) * perCast
        local share = herbs > 0 and math.min(GetOnHand(mill.herbID) / herbs, 1) or 1
        if mill.unit * (1 - (1 - HELD_SALVAGE_SHARE) * share) >= options.otherUnit then
            node.best = options.other
            -- The menu and hover go by this, not options.cheapest
            node.cheapest = options.other
            node.heldTooFew = true
        end
    end
    -- An item already being made further up this branch is bought here,
    -- not made again: two materials each crafted from the other built
    -- A from B from A... until "stack overflow" (a player's Lua error,
    -- 2.7.0-beta, 2026-10-27). GetOptions stops loops while costing, but
    -- its answers are kept per item (memo) and reused at any depth.
    ctx.path = ctx.path or {}
    local making = node.best and (node.best.method == "Craft" or node.best.method == "Mill")
    if making and (ctx.path[itemID] or depth > MAX_DEPTH + 1) then
        node.best = options.buy or options.vendor
        node.loopBought = true
    end
    if node.best and node.best.method == "Craft" and node.best.tierRow then
        LimitByConcentration(node, ctx, (GetCraftNumbers(node.best.recipe)))
    end
    local best = node.best
    local onPath = best and (best.method == "Craft" or best.method == "Mill") and not ctx.path[itemID]
    if onPath then ctx.path[itemID] = true end
    if best and best.method == "Craft" and node.toGet > 0 then
        local outputQty, slots = GetCraftNumbers(best.recipe)
        local crafts = WholeCrafts(node.craftItems or node.toGet, SurePerCraft(best.recipe, outputQty))
        for _, s in ipairs(slots) do
            if best.tierRow then
                -- A tier item: its materials in the qualities its tier row uses
                for _, part in ipairs(TopSlotParts(s.slot, best.tierRow, ctx.memo, best.recipe)) do
                    local choice = part.choice
                    table.insert(node.children, BuildNode(choice.itemID, choice.name,
                        PartNeed(s, part.units, crafts), depth + 1, ctx, choice))
                end
            else
                local choice = GetSlotChoice(s.slot, depth + 1, ctx.memo, {})
                if choice then
                    table.insert(node.children,
                        BuildNode(choice.itemID, choice.name, MaterialNeed(s, crafts), depth + 1, ctx, choice))
                end
            end
        end
    elseif best and best.method == "Mill" and node.toGet > 0 then
        -- Enough salvages for an unlucky run, so one trip to the AH covers
        -- it (user, 2026-10-05: never shop twice): 23 Cellular Slab sized on
        -- the 3.35 average gave 63 Plant Protein, 2.74 each, 12 short
        -- (2026-10-19). Cost stays on the average (the parent's unit).
        local perCast = best.perCast and best.perCast > 1 and best.perCast or 1
        local casts = SalvageCasts(node.toGet, best.perHerb * perCast)
        -- Each mill uses a fixed number of herbs (10 in Midnight), so you
        -- need whole mills' worth
        local herbs = casts * perCast
        table.insert(node.children, BuildNode(best.herbID, best.herbName, herbs, depth + 1, ctx))
    end
    if onPath then ctx.path[itemID] = nil end
    return node
end

-- Salvages needed to get `need` items at `perCast` on average, even in a
-- bad run. Each salvage's yield is taken to spread SALVAGE_SPREAD of its
-- average (no per-salvage data is kept yet); the count covers the low end
-- at SALVAGE_Z standard errors (about 1 run in 100 falls short). With N
-- salvages: N * perCast - z * spread * perCast * sqrt(N) >= need.
local SALVAGE_SPREAD = 0.4
local SALVAGE_Z = 2.33

SalvageCasts = function(need, perCast)
    if perCast <= 0 then return 0 end
    local b = SALVAGE_Z * SALVAGE_SPREAD * perCast
    local x = (b + math.sqrt(b * b + 4 * perCast * need)) / (2 * perCast)
    return math.ceil(x * x - 0.0001)
end

-- Walk the tree collecting what to buy on the AH and from vendors
local function CollectPurchases(node, ah, vendor)
    if node.toGet <= 0 then return end
    local best = node.best
    -- Partly crafted (concentration ran out): the rest is bought
    if best and best.split then
        local other = best.split.other
        local map = other.method == "Vendor" and vendor or ah
        map[node.itemID] = map[node.itemID] or { name = node.name, quantity = 0, unit = other.unit,
                                                 qualityTier = node.qualityTier, tierCount = node.tierCount }
        map[node.itemID].quantity = map[node.itemID].quantity + best.split.buyItems
    end
    if best and best.method == "Buy" then
        ah[node.itemID] = ah[node.itemID] or { name = node.name, quantity = 0, unit = best.unit,
                                               qualityTier = node.qualityTier, tierCount = node.tierCount }
        ah[node.itemID].quantity = ah[node.itemID].quantity + node.toGet
    elseif best and best.method == "Vendor" then
        vendor[node.itemID] = vendor[node.itemID] or { name = node.name, quantity = 0, unit = best.unit }
        vendor[node.itemID].quantity = vendor[node.itemID].quantity + node.toGet
    end
    for _, child in ipairs(node.children) do
        CollectPurchases(child, ah, vendor)
    end
end

local function ToSortedList(map)
    local list = {}
    for itemID, entry in pairs(map) do
        entry.itemID = itemID
        entry.quantity = math.ceil(entry.quantity - 0.0001)
        table.insert(list, entry)
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- What `units` you hold of an item cost you (GetOwnCost: what you paid,
-- what your own milling or crafts cost, gathered ones at today's price),
-- the same basis as a craft's lot and the Craft complete notice;
-- `fallback` (today's price) when Goldsmith never saw how you got it.
-- A way's unit at today's prices as the to-do counts it: a craft that
-- takes concentration with that concentration at CONC_POINT_COST
-- (compareUnit). The gold vial Mysticmead held was 43.39g in the queue's
-- today's prices and about 230g on the to-do, 177g apart on Light's
-- Preservation with nothing to say why (2026-10-26). Not for marketCost:
-- Buy next's warnings and the sell-the-materials note are about gold.
local function TodayUnit(best)
    return best.compareUnit or best.unit
end

local function HeldCost(itemID, name, units, fallback)
    if units <= 0 then return 0 end
    local own = addon:GetOwnCost(name, nil, itemID)
    return units * (own or fallback)
end

-- A row's cost for all it needs, with what you hold at what you paid
-- (user, 2026-10-22: "in the real world you usually go off of what you
-- paid"; the plan lost 75g of profit when TSM's prices replaced the scan,
-- for materials bought an hour before). What you still get is at today's
-- price; a craft from held materials passes their paid share up (gold
-- ingots from ore you bought). Buy or craft is still picked on today's
-- prices (GetOptions). Sets node.paidTotal, and node.heldPaid (what you
-- hold of it, at what you paid; HeldGap).
local function NodeCost(node)
    local best = node.best
    if not best then return nil end
    local goldUnits = node.gold and node.gold.units or 0
    local cost = HeldCost(node.itemID, node.name, node.have - goldUnits, best.unit)
    if goldUnits > 0 then cost = cost + HeldCost(node.gold.itemID, node.name, goldUnits, best.unit) end
    node.heldPaid = cost
    if node.toGet > 0 then
        local made = best.split and node.craftItems or node.toGet
        local bought = best.split and best.split.buyItems or 0
        local madeUnit = best.split and node.options.best and node.options.best.unit or best.unit
        local factor = 1
        if #node.children > 0 then
            local market, paid = 0, 0
            for _, child in ipairs(node.children) do
                local childCost = NodeCost(child)
                if childCost and child.best then
                    market = market + child.best.unit * child.need
                    paid = paid + childCost
                end
            end
            if market > 0 then factor = paid / market end
        end
        cost = cost + made * madeUnit * factor
        if bought > 0 then cost = cost + bought * best.split.other.unit end
    end
    node.paidTotal = cost
    return cost
end

-- Plan for making `quantity` of a recipe's item. Returns:
--   nodes     - top-level material rows (each with children)
--   cost      - cost of all materials: what you hold at what you paid,
--               the rest at the cheapest way today (NodeCost)
--   marketCost - the same, all at today's prices
--   todayCost - marketCost with the concentration a material's craft takes
--               counted (TodayUnit), as the to-do counts it (HeldGap)
--   complete  - false if some material has no price at all
--   buyAH     - { itemID, name, quantity, unit } to buy on the AH
--   buyVendor - same, for vendor items
--   spend     - gold to spend on those purchases
--   price, revenue, profit, margin - selling `quantity` at the AH price
--   demand, demandSource - units sold per day
--   saleRate  - share of listings that sell (TSM region), or nil
-- pool (optional, for the queue): itemID -> how many of what you have
-- earlier plans already use; this plan uses what's left and adds its own.
function addon:BuildPlan(recipe, quantity, useOnHand, tier, pool)
    -- The old choices for every plan (see WithChoices) are dropped
    GoldsmithDB.ui.methodOverrides = nil
    -- One count of what you hold for the whole plan, as the queue keeps
    -- across its entries: without it each line counted your bags again.
    -- Gloaming Alloy's two ingot batches both used the same 22 ore, so the
    -- plan bought 18 where it needed 30 (user, 2026-10-24).
    local ctx = { memo = {}, useOnHand = useOnHand, pool = pool or {}, conc = {} }
    local outputQty, slots = GetCraftNumbers(recipe)
    local crafts = WholeCrafts(quantity, SurePerCraft(recipe, outputQty))
    -- The craft's own concentration comes first from its crafter's
    -- (materials of the same profession on the same character share it)
    if tier and tier.concentrate and tier.concentration then
        local available, id = ConcAvailable(ctx, StatsKey(), recipe.profession)
        -- At the full cost, like CraftsThatFit
        local full = tier.scenario and tier.scenario.concentration or tier.concentration
        if available ~= math.huge then ctx.conc[id] = available - full * crafts end
    end

    -- expectedOutput: what `crafts` whole crafts should make on average
    local plan = { recipe = recipe, quantity = quantity, crafts = crafts, nodes = {}, cost = 0, complete = true,
                   expectedOutput = crafts * outputQty,
                   -- Finishing reagents tried, and the pick (for the planner)
                   finishing = addon:GetFinishingChoice(recipe) }
    for _, s in ipairs(slots) do
        local parts = TopSlotParts(s.slot, tier, ctx.memo, recipe)
        -- Gold you hold beyond what this slot's own gold part needs can
        -- stand in for silver you're short of (see BuildNode)
        local ids = s.slot.itemIDs or {}
        local highID = #ids > 1 and ids[#ids] or nil
        local spareGold
        if highID and useOnHand then
            local highNeed = 0
            for _, part in ipairs(parts) do
                if part.choice.itemID == highID then highNeed = PartNeed(s, part.units, crafts) end
            end
            local spare = GetOnHand(highID) - (ctx.pool and ctx.pool[highID] or 0) - highNeed
            if spare > 0 then
                spareGold = { itemID = highID, units = spare, allowed = addon:MayUseHeldGold(ids[1], highID) }
            end
        end
        for _, part in ipairs(parts) do
            local choice = part.choice
            local gold = choice.itemID ~= highID and spareGold or nil
            local node = BuildNode(choice.itemID, choice.name, PartNeed(s, part.units, crafts), 1, ctx, choice, gold)
            node.use = PartUse(s, part.units, crafts)
            -- A finishing reagent (GetCraftModel): the row says so, and its
            -- menu picks another or none
            node.finishing, node.finishingChoice = s.finishing, s.finishing and plan.finishing
            table.insert(plan.nodes, node)
            if node.best then
                plan.marketCost = (plan.marketCost or 0) + node.best.unit * node.use
                plan.todayCost = (plan.todayCost or 0) + TodayUnit(node.best) * node.use
                local total = NodeCost(node)
                plan.cost = plan.cost + (node.need > 0 and total * node.use / node.need or 0)
            else
                plan.complete = false
            end
        end
    end

    -- The same plan priced the cheapest way, ignoring your choices, so the
    -- plan can say what your choices cost (e.g. buying to skip milling)
    local cheapestMemo = { ignoreOverrides = true }
    local cheapestCost, cheapestComplete = 0, true
    for _, s in ipairs(slots) do
        for _, part in ipairs(TopSlotParts(s.slot, tier, cheapestMemo, recipe)) do
            if part.choice.options.best then
                cheapestCost = cheapestCost + part.choice.options.best.unit * PartUse(s, part.units, crafts)
            else
                cheapestComplete = false
            end
        end
    end
    -- Only when you made a choice: buying because concentration ran out
    -- (LimitByConcentration) isn't one, and showed "Your choices add 342g"
    -- on a plan with none (user, 2026-10-18)
    local function AnyChoice(nodes)
        for _, node in ipairs(nodes or {}) do
            if (node.options and node.options.override) or AnyChoice(node.children) then return true end
        end
        return false
    end
    if plan.complete and cheapestComplete and AnyChoice(plan.nodes) then
        plan.choiceExtra = (plan.marketCost or plan.cost) - cheapestCost
    end

    local ah, vendor = {}, {}
    for _, node in ipairs(plan.nodes) do
        CollectPurchases(node, ah, vendor)
    end
    plan.buyAH = ToSortedList(ah)
    plan.buyVendor = ToSortedList(vendor)
    -- What the AH purchases really cost: with a fresh order book, walk the
    -- listings for the full quantity (buying 156 isn't all at the lowest
    -- price); otherwise the unit price times quantity
    for _, entry in ipairs(plan.buyAH) do
        local liveUnit, enough = addon:GetLiveBuyCost(entry.itemID, entry.quantity)
        if liveUnit then
            entry.cost = liveUnit * entry.quantity
            entry.live = true
            entry.short = not enough
        else
            entry.cost = entry.unit * entry.quantity
        end
    end
    for _, entry in ipairs(plan.buyVendor) do
        entry.cost = entry.unit * entry.quantity
    end
    plan.spend = 0
    for _, list in ipairs({ plan.buyAH, plan.buyVendor }) do
        for _, entry in ipairs(list) do
            plan.spend = plan.spend + entry.cost
        end
    end

    local priceSource
    if tier then
        plan.price, plan.unconfirmed, plan.doubtPrice = tier.price, tier.unconfirmed, tier.doubtPrice
        plan.jumped = tier.jumped
    else
        plan.price, priceSource = addon:GetMarketPriceInfo(recipe.outputItemID)
        -- The usual price when the listing jumped (PriceJump, Pricing.lua)
        local usual, jumped = addon:PriceJump(recipe.outputItemID, plan.price, priceSource)
        if usual then plan.price, plan.jumped = usual, jumped end
    end
    plan.tier = tier
    if plan.price then
        plan.revenue = plan.price * (1 - AH_CUT) * plan.expectedOutput
        plan.profit = plan.revenue - plan.cost
        plan.margin = plan.cost > 0 and (plan.profit / plan.cost * 100) or nil
        -- Same check as the Crafts list (DoubtPrice, Pricing.lua)
        if not tier then
            local check = { price = plan.price, priceSource = priceSource, margin = plan.margin }
            addon:DoubtPrice(check, recipe.outputItemID, recipe.outputName)
            plan.unconfirmed, plan.doubtPrice = check.unconfirmed, check.doubtPrice
            if check.doubtPrice then
                plan.price, plan.revenue, plan.profit, plan.margin = nil, nil, nil, nil
            end
        end
    end
    plan.demand, plan.demandSource = addon:GetDemand((tier and tier.itemID) or recipe.outputItemID, recipe.outputName)
    plan.saleRate = addon:GetSaleRate((tier and tier.itemID) or recipe.outputItemID)
    return plan
end

-- What the materials you hold add to a plan's cost against today's prices,
-- for saying why its profit isn't the to-do's: the to-do decides on
-- today's prices, plans and the queue show what you paid. Flames of the
-- Sin'dorei read +463.63g on the to-do and +341.67g in the queue, the 6
-- Petrified Root held at 81g against 60g today, and nothing said so
-- (user, 2026-10-25: "i just need to make sure the user isn't confused
-- like i was"). Only when it's at least 10g and 10% of the profit at
-- today's prices: 10% of the cost hid the Flames' 122g against a 1,342g
-- cost, a quarter of its profit.
local HELD_GAP_MIN = 100000
local HELD_GAP_SHARE = 0.10
-- The item named when it makes this much of the gap, else "what you hold"
local HELD_GAP_NAME_SHARE = 0.6

-- Each held material's part of the gap, by name, into out. A crafted
-- material's children pass theirs up at the share NodeCost gives them.
local function NodeGaps(node, scale, out)
    local best = node.best
    if not best or scale == 0 then return end
    if (node.have or 0) > 0 and node.heldPaid then
        local name = node.name or "?"
        out[name] = (out[name] or 0) + (node.heldPaid - node.have * TodayUnit(best)) * scale
    end
    -- Made with concentration for this plan: gold only in what you pay,
    -- its concentration too at today's prices
    if (node.toGet or 0) > 0 and best.compareUnit and best.compareUnit > best.unit then
        local name = node.name or "?"
        out[name] = (out[name] or 0) + (best.unit - best.compareUnit) * node.toGet * scale
    end
    if (node.toGet or 0) > 0 and #(node.children or {}) > 0 then
        local made = best.split and node.craftItems or node.toGet
        local madeUnit = best.split and node.options.best and node.options.best.unit or best.unit
        local market = 0
        for _, child in ipairs(node.children) do
            if child.best then market = market + child.best.unit * child.need end
        end
        if market > 0 then
            for _, child in ipairs(node.children) do NodeGaps(child, scale * made * madeUnit / market, out) end
        end
    end
end

-- plans: one plan or a list (the queue's). Plans without a sale price
-- (stock-ups, salvage without one) are left out, as the queue's profit
-- leaves them out. Returns the gap (copper, more paid is positive) and the
-- held item that makes most of it (or nil), or nil when it's too small.
-- always: any gap of a gold or more (a queue row, and the queue when a
-- row has one; QueueTab.lua). Profit at today's prices is the shown profit plus
-- the gap.
function addon:HeldGap(plans, always)
    if plans.nodes then plans = { plans } end
    local gap, today, byItem = 0, 0, {}
    for _, plan in ipairs(plans) do
        if plan.revenue and plan.marketCost then
            local todayCost = plan.todayCost or plan.marketCost
            gap = gap + plan.cost - todayCost
            today = today + plan.revenue - todayCost
            for _, node in ipairs(plan.nodes or {}) do
                if (node.need or 0) > 0 then NodeGaps(node, (node.use or node.need) / node.need, byItem) end
            end
        end
    end
    local least = always and 10000 or math.max(HELD_GAP_MIN, math.abs(today) * HELD_GAP_SHARE)
    if math.abs(gap) < least then return nil end
    local name, most = nil, 0
    for item, d in pairs(byItem) do
        if d * gap > 0 and math.abs(d) > most then name, most = item, math.abs(d) end
    end
    if most < math.abs(gap) * HELD_GAP_NAME_SHARE then name = nil end
    return gap, name
end

-- "You paid 122.06g more for Petrified Root"
function addon:HeldGapText(gap, name)
    return string.format("You paid %s %s for %s", addon:FormatMoney(math.abs(gap)), gap > 0 and "more" or "less",
        name or "what you hold")
end

-- Tree flattened into display rows, parents before children
function addon:FlattenPlan(plan)
    local rows = {}
    local function add(node)
        table.insert(rows, node)
        for _, child in ipairs(node.children) do
            add(child)
        end
    end
    for _, node in ipairs(plan.nodes) do
        add(node)
    end
    return rows
end

-- Auctionator shopping list

-- Goldsmith keeps one shopping list in Auctionator at a time. Sending a
-- plan replaces it; items come off as you buy them (or their quantity goes
-- down), and the list is deleted once everything's bought. Tracked in
-- GoldsmithDB.shoppingList = { name, items = { { itemID, name, tier,
-- quantity, bought, search } } }.

local function ShoppingAPI()
    return Auctionator and Auctionator.API and Auctionator.API.v1
end

local function SearchString(api, name, quantity, tier)
    if api.ConvertToSearchString then
        -- tier makes Auctionator search only the right quality
        local ok, result = pcall(api.ConvertToSearchString, "Goldsmith",
            { searchString = name, isExact = true, quantity = quantity, tier = tier })
        if ok then return result end
    end
    -- Auctionator's exact-match search syntax, if conversion isn't available
    return '"' .. name .. '"'
end

-- Auctionator's API can't delete a whole list, so this uses its list
-- manager (the same call its API uses to replace a list). If that ever
-- changes, the list just stays.
local function ListManager()
    local shopping = Auctionator and Auctionator.Shopping
    local manager = shopping and shopping.ListManager
    if manager and manager.GetIndexForName and manager.Delete then return manager end
end

local function DeleteList(name)
    local manager = ListManager()
    if not manager then return end
    local ok, index = pcall(manager.GetIndexForName, manager, name)
    if ok and index then pcall(manager.Delete, manager, name) end
end

-- Lists from before Goldsmith kept just one ("Goldsmith: <item> x<qty>")
local function DeleteOldLists(keep)
    local manager = ListManager()
    if not (manager and manager.GetCount and manager.GetByIndex) then return end
    local names = {}
    local okC, count = pcall(manager.GetCount, manager)
    for i = 1, okC and count or 0 do
        local ok, list = pcall(manager.GetByIndex, manager, i)
        local name = ok and list and list.GetName and list:GetName()
        if name and name ~= keep and name:find("^Goldsmith: ") then table.insert(names, name) end
    end
    for _, name in ipairs(names) do DeleteList(name) end
end

-- Sends the plan's AH purchases to Auctionator as a shopping list named
-- "Goldsmith: <item> x<qty>", replacing Goldsmith's previous list. A queue
-- passes its own listName and listKey (see BuildQueue in Queue.lua).
-- Returns true on success, or false and a reason.
function addon:SendShoppingList(plan)
    if addon:UsingTourData() then
        return false, "The tour shows sample data: end it to send your own list to Auctionator."
    end
    local api = ShoppingAPI()
    if not (api and api.CreateShoppingList) then
        return false, "Auctionator's shopping list API isn't available."
    end
    if #plan.buyAH == 0 then
        return false, "Nothing to buy on the AH for this plan."
    end

    local searchStrings, items = {}, {}
    for _, entry in ipairs(plan.buyAH) do
        local search = SearchString(api, entry.name, entry.quantity, entry.qualityTier)
        table.insert(searchStrings, search)
        table.insert(items, { itemID = entry.itemID, name = entry.name, tier = entry.qualityTier,
                              quantity = entry.quantity, bought = 0, search = search })
    end

    local listName = plan.listName or string.format("Goldsmith: %s x%d", plan.recipe.outputName, plan.quantity)
    local ok, err = pcall(api.CreateShoppingList, "Goldsmith", listName, searchStrings)
    if not ok then
        return false, tostring(err)
    end
    DeleteOldLists(listName)
    GoldsmithDB.shoppingList = { name = listName, items = items, recipeID = plan.listKey or plan.recipe.recipeID }
    return true, listName
end

-- Whether the plan still matches the list sent for it. The plan is worked
-- out again as prices change (buying rescans the items), so its best mix of
-- qualities can switch after the list went out. Returns what the plan now
-- needs beyond what's left to buy on the list ({ itemID, name, quantity }),
-- and what's left on the list it no longer needs; nil when no list was
-- sent for this recipe.
function addon:ShoppingListChanges(plan)
    local list = GoldsmithDB.shoppingList
    if not (list and list.recipeID == (plan.listKey or plan.recipe.recipeID)) then return nil end
    local left, names = {}, {}
    for _, item in ipairs(list.items) do
        left[item.itemID] = (left[item.itemID] or 0) + math.max(item.quantity - item.bought, 0)
        names[item.itemID] = item.name
    end
    local more, extra = {}, {}
    for _, entry in ipairs(plan.buyAH) do
        local n = entry.quantity - (left[entry.itemID] or 0)
        if n > 0 then table.insert(more, { itemID = entry.itemID, name = entry.name, quantity = n }) end
        left[entry.itemID] = math.max((left[entry.itemID] or 0) - entry.quantity, 0)
    end
    for itemID, n in pairs(left) do
        if n > 0 then table.insert(extra, { itemID = itemID, name = names[itemID], quantity = n }) end
    end
    return more, extra
end

-- An AH purchase (from Core.lua's RecordPurchase): takes it off Goldsmith's
-- shopping list, and deletes the list once everything on it is bought
function addon:ShoppingListBought(itemID, quantity)
    local list = GoldsmithDB.shoppingList
    local api = ShoppingAPI()
    if not (list and api and itemID) then return end

    for _, item in ipairs(list.items) do
        if item.itemID == itemID and item.bought < item.quantity then
            item.bought = item.bought + quantity
            local left = item.quantity - item.bought
            if left <= 0 then
                pcall(api.DeleteShoppingListItem, "Goldsmith", list.name, item.search)
            elseif api.AlterShoppingListItem then
                local search = SearchString(api, item.name, left, item.tier)
                if pcall(api.AlterShoppingListItem, "Goldsmith", list.name, item.search, search) then
                    item.search = search
                end
            end
            break
        end
    end

    for _, item in ipairs(list.items) do
        if item.bought < item.quantity then return end
    end
    DeleteList(list.name)
    GoldsmithDB.shoppingList = nil
    addon:Notify("info", "Everything on %s is bought; the list is removed from Auctionator.", list.name)
end

-- Materials you hold, when picking the mix
--
-- The tier rows pick a mix on AH prices alone, so with gold 0.04g cheaper
-- than silver a plan said to buy 15 gold while 15 silver sat in the bags
-- (2026-10-08). Plans always use materials you have: mixes reaching the same tier
-- the same way (and, with concentration, needing no more of it) are scored
-- on what you'd still spend: what you'd buy at its price, plus for what
-- you hold and would use, how much more it's worth than the other quality
-- (using pricey gold you could sell isn't free). The lowest score wins.
-- Returns the entry to plan with (a copy, with heldPick = true, when it
-- isn't tierInfo itself), or tierInfo.
local HELD_PICK_MIN_SAVING = 10000 -- 1g: not worth switching for less

-- Concentration now for the character whose stats are in use
-- (WithCharacter): live for you, worked out to now for an alt
local function ConcentrationNow(profession)
    local char = addon:StatsChar()
    if char == addon.char then return (addon:GetConcentration(profession)) end
    for key, c in pairs(GoldsmithDB.characters) do
        if c == char then return (addon:GetCharacterConcentration(key, profession)) end
    end
end

function addon:PreferHeldMix(recipe, tierInfo, quantity)
    if not (tierInfo and tierInfo.scenarios and quantity and quantity > 0) then return tierInfo end
    local outputPerCraft = GetCraftNumbers(recipe)
    local crafts = WholeCrafts(quantity, SurePerCraft(recipe, outputPerCraft))
    if crafts <= 0 then return tierInfo end

    -- Quality material slots, and one slot's score with `high` gold units
    local qslots = {}
    for _, slot in ipairs(recipe.reagents) do
        if slot.itemIDs and #slot.itemIDs > 1 then table.insert(qslots, slot) end
    end
    -- What you hold and would use is scored at what it would sell for,
    -- less the AH cut and HELD_CRAFT_MARGIN: so held wins over pennies,
    -- not over a real saving. It used to cost only its premium over the
    -- other quality, which made 400 held silver Powder Pigment (2.95g)
    -- beat buying gold at 2.00g, about 300g worse (user, 2026-10-21).
    local HELD_VALUE = (1 - AH_CUT) * (1 - HELD_CRAFT_MARGIN)
    local function SlotScore(slot, high)
        local ids, score = slot.itemIDs, 0
        local parts = { { ids[1], slot.quantity - high }, { ids[#ids], high } }
        for _, p in ipairs(parts) do
            local id, units = p[1], p[2]
            if units > 0 then
                local need = units * crafts
                local price = addon:GetMarketPrice(id, true) or 0
                local used = math.min(need, GetOnHand(id))
                score = score + (need - used) * price + used * price * HELD_VALUE
            end
        end
        return score
    end
    local function Score(scenario)
        local score = 0
        for _, slot in ipairs(qslots) do score = score + SlotScore(slot, addon:ScenarioHighUnits(scenario, slot)) end
        return score
    end
    -- A mix needing more concentration pays for it at what the picked mix
    -- earns a point: all silver at 320 a craft beat buying 6 gold stones
    -- for one at 316 (user, 2026-10-12: it used to be ruled out)
    local function ConcentrationCharge(e)
        if not (tierInfo.concentrate and e.concentration and tierInfo.concentration) then return 0 end
        return math.max(e.concentration - tierInfo.concentration, 0) * crafts * (tierInfo.concentrationValue or 0)
    end

    local same = {}
    for _, e in ipairs(tierInfo.scenarios) do
        if e.tier == tierInfo.tier and (e.concentrate == true) == (tierInfo.concentrate == true)
            and (not tierInfo.concentrate or e.scenario == tierInfo.scenario or e.concentrationValue) then
            table.insert(same, e)
        end
    end

    -- Concentration you have now. Each craft needs a mix's full cost to
    -- start, so a mix that can't start them all is cut to the crafts it
    -- covers. A to-do of 2 Missives (all gold, about 230 a craft, +490g
    -- with 492) opened as 1 all silver craft (340, +369g): you held silver
    -- ink, and the extra concentration was charged as if you had it (user,
    -- 2026-10-18). A mix that covers every craft keeps out one that
    -- doesn't, and one that can't is swapped for one that can when that
    -- earns more.
    local current = tierInfo.concentrate and ConcentrationNow(recipe.profession)
    local function Full(e) return e.scenario and e.scenario.concentration or e.concentration end
    local function Startable(e)
        local full = Full(e)
        if not (current and full and full > 0) then return crafts end
        return math.min(crafts, math.floor(current / full))
    end
    local function Earns(e) return (e.profit or 0) * (e.outputPerCraft or outputPerCraft) * Startable(e) end
    -- Whether you hold every quality material a mix needs for all crafts
    local function Holds(e)
        for _, slot in ipairs(qslots) do
            local high = addon:ScenarioHighUnits(e.scenario, slot)
            local ids = slot.itemIDs
            if GetOnHand(ids[1]) < (slot.quantity - high) * crafts or GetOnHand(ids[#ids]) < high * crafts then
                return false
            end
        end
        return true
    end
    -- Not when you hold the picked mix and the other needs buying: the
    -- crafts it can't start yet wait for concentration to come back. 2
    -- Refreshing Serum at 115 a craft, 212 after a Light's Potential, swapped
    -- to a mix with 6 gold Sanguithorn (108g) after the shopping was done
    -- (user, 2026-10-22)
    local holdsPick = current and Startable(tierInfo) < crafts and Holds(tierInfo)
    if current and Startable(tierInfo) < crafts then
        local fit
        for _, e in ipairs(same) do
            if Startable(e) == crafts and Earns(e) > Earns(tierInfo) and (not fit or Earns(e) > Earns(fit))
                and not (holdsPick and not Holds(e)) then
                fit = e
            end
        end
        if fit then
            local pick = {}
            for k, v in pairs(fit) do pick[k] = v end
            pick.scenarios, pick.fitPick = tierInfo.scenarios, true
            pick.demand, pick.demandSource, pick.saleRate = tierInfo.demand, tierInfo.demandSource, tierInfo.saleRate
            return pick
        end
    end
    local coversAll = current and Startable(tierInfo) == crafts

    local best, bestScore = tierInfo, Score(tierInfo.scenario)
    local pickedScore = bestScore
    for _, e in ipairs(same) do
        local score = Score(e.scenario) + ConcentrationCharge(e)
        if coversAll and Startable(e) < crafts then score = math.huge end
        -- Short of concentration either way: never a mix that starts fewer
        -- crafts. A to-do of 5 Sterling Alloy (4 at 1 gold ingot, 1 at 2
        -- gold) opened as 3 all silver crafts, +400g against +505g, for the
        -- silver ingots held (user, 2026-10-19)
        if current and not coversAll and Startable(e) < Startable(tierInfo) then score = math.huge end
        if score < bestScore then best, bestScore = e, score end
    end

    -- In between two confirmed mixes of this tier, slot by slot, every mix
    -- reaches it too (gold only adds skill: no less than the lower one, no
    -- more than the upper), so mixes the game wasn't asked about can be
    -- built, e.g. 1 gold and 1 silver bolt when that's what you hold.
    -- Without concentration only: its cost would change, and only the game
    -- knows by how much.
    local built
    if not tierInfo.concentrate and #qslots > 0 then
        for _, a in ipairs(same) do
            for _, b in ipairs(same) do
                local below, mix, score = a ~= b, {}, 0
                for _, slot in ipairs(qslots) do
                    if addon:ScenarioHighUnits(a.scenario, slot) > addon:ScenarioHighUnits(b.scenario, slot) then below = false end
                end
                if below then
                    for _, slot in ipairs(qslots) do
                        local lo, hi = addon:ScenarioHighUnits(a.scenario, slot), addon:ScenarioHighUnits(b.scenario, slot)
                        local bestUnits, bestSlot = lo, SlotScore(slot, lo)
                        for units = lo + 1, hi do
                            local s = SlotScore(slot, units)
                            if s < bestSlot then bestUnits, bestSlot = units, s end
                        end
                        if bestUnits > 0 then mix[slot.itemIDs[1]] = bestUnits end
                        score = score + bestSlot
                    end
                    if score < bestScore then
                        bestScore, built = score, mix
                        best = nil
                    end
                end
            end
        end
    end

    if best == tierInfo or pickedScore - bestScore < HELD_PICK_MIN_SAVING then return tierInfo end
    -- Only for materials you hold: a mix using no more of them than the
    -- pick won on AH prices alone, and the ranking already weighed those.
    -- After a rescan, Gloaming Alloy switched to all silver, bought 8 more
    -- ore than the 1-gold mix, and said it "uses materials you have"
    -- (user, 2026-10-24)
    local function HeldUsed(scenario)
        local n = 0
        for _, slot in ipairs(qslots) do
            local high, ids = addon:ScenarioHighUnits(scenario, slot), slot.itemIDs
            n = n + math.min((slot.quantity - high) * crafts, GetOnHand(ids[1]))
                + math.min(high * crafts, GetOnHand(ids[#ids]))
        end
        return n
    end
    local chosen = built and { mix = built } or best.scenario
    if HeldUsed(chosen) <= HeldUsed(tierInfo.scenario) then return tierInfo end
    local pick = {}
    if built then
        -- A mix built here: priced like the others
        for k, v in pairs(tierInfo) do pick[k] = v end
        pick.scenario = { mix = built, concentrate = false, tier = tierInfo.tier, concentration = 0, ingenuityRefund = 0 }
        pick.cost, pick.partial = addon:GetScenarioCost(recipe, pick.scenario)
        pick.partial = not pick.partial
        pick.profit = pick.price and (pick.price * (1 - AH_CUT) - pick.cost)
        pick.margin = pick.profit and pick.cost > 0 and (pick.profit / pick.cost * 100) or nil
        pick.description = addon:DescribeMix(recipe, pick.scenario)
        pick.built = true
    else
        for k, v in pairs(best) do pick[k] = v end
    end
    pick.scenarios, pick.heldPick = tierInfo.scenarios, true
    pick.demand, pick.demandSource, pick.saleRate = tierInfo.demand, tierInfo.demandSource, tierInfo.saleRate
    return pick
end

-- The mix to plan and craft with: the one you clicked in the planner's
-- "Why this mix" panel (GoldsmithDB.ui2.planMix[recipeID] = { tier,
-- concentrate, description }) while it still reaches that tier the same
-- way, else PreferHeldMix's. The planner and the queue both use it, so
-- crafting from either makes what the plan showed (user, 2026-10-12).
function addon:ChooseMix(recipe, tierInfo, quantity)
    if not tierInfo then return tierInfo end
    local pick = addon:PreferHeldMix(recipe, tierInfo, quantity)
    local saved = GoldsmithDB.ui2 and GoldsmithDB.ui2.planMix and GoldsmithDB.ui2.planMix[recipe.recipeID]
    if not (saved and saved.tier == tierInfo.tier and saved.concentrate == (tierInfo.concentrate == true)) then
        return pick
    end
    if pick.description == saved.description then return pick end
    for _, e in ipairs(tierInfo.scenarios or {}) do
        if e.tier == tierInfo.tier and (e.concentrate == true) == saved.concentrate
            and e.description == saved.description and (not saved.concentrate or e.concentrationValue) then
            local mine = {}
            for k, v in pairs(e) do mine[k] = v end
            mine.scenarios, mine.yourPick = tierInfo.scenarios, true
            mine.demand, mine.demandSource, mine.saleRate = tierInfo.demand, tierInfo.demandSource, tierInfo.saleRate
            return mine
        end
    end
    return pick
end

-- The same-tier mix with this description (a queue entry's set mix), as
-- an entry to plan with, or nil when the game no longer offers it
function addon:MixByDescription(tierInfo, description)
    for _, e in ipairs(tierInfo and tierInfo.scenarios or {}) do
        if e.tier == tierInfo.tier and (e.concentrate == true) == (tierInfo.concentrate == true)
            and e.description == description then
            local mine = {}
            for k, v in pairs(e) do mine[k] = v end
            mine.scenarios, mine.setMix = tierInfo.scenarios, true
            mine.demand, mine.demandSource, mine.saleRate = tierInfo.demand, tierInfo.demandSource, tierInfo.saleRate
            return mine
        end
    end
end

-- "2 gold mix" for "2 gold Refulgent Copper Ingot"; others as they are
function addon:ShortMix(description)
    local gold = description and description:match("^(%d+ gold)")
    return gold and (gold .. " mix") or (description or "another mix")
end

-- Shorter still, for a list column: "(1 <gold icon>)" for "1 gold ...",
-- the gold material quality icon in place of the words ("1 gold..." was cut
-- off in the Queue tab, user 2026-10-19)
function addon:MixIcon(description)
    local n = description and description:match("^(%d+) gold")
    if n then return string.format("(%s%s)", n, addon:TierIconText(2, 2, 12)) end
    if description and description:match("^All silver") then return string.format("(%s)", addon:TierIconText(1, 2, 12)) end
    return addon:ShortMix(description)
end

-- Clicking a mix: remember it, or forget it when it's the one Goldsmith
-- would pick anyway
function addon:SetPlanMix(recipe, tierInfo, e, quantity)
    local ui = GoldsmithDB.ui2
    ui.planMix = ui.planMix or {}
    local auto = addon:PreferHeldMix(recipe, tierInfo, quantity)
    if not e or (auto and auto.description == e.description) then
        ui.planMix[recipe.recipeID] = nil
    else
        ui.planMix[recipe.recipeID] = { tier = tierInfo.tier, concentrate = tierInfo.concentrate == true,
            description = e.description }
    end
end

_G.Goldsmith = addon
