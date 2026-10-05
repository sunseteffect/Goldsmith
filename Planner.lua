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

local function GetOnHand(itemID)
    return C_Item.GetItemCount(itemID, true, false, true, true) or 0
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

local function GetSlotChoice(slot, depth, memo, visiting)
    local best
    for i, itemID in ipairs(slot.itemIDs or {}) do
        local options = GetOptions(itemID, slot.names[i], depth, memo, visiting)
        if options.best and (not best or options.best.unit < best.options.best.unit) then
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

    -- Vendor: a recorded vendor price. Buying on the AH is only offered
    -- when it's cheaper than the vendor.
    local vendorPrice = addon:GetVendorPrice(itemID)
    local ahPrice = addon:GetAHPrice(itemID)
    if vendorPrice then
        options.vendor = { method = "Vendor", unit = vendorPrice, detail = "Vendor price" }
    end
    if ahPrice and (not vendorPrice or ahPrice < vendorPrice) then
        options.buy = { method = "Buy", unit = ahPrice, ageText = addon:AHPriceAgeText(itemID) }
    end
    if not vendorPrice and not ahPrice and name then
        -- No prices at all: if you've bought it before it's likely a vendor
        -- item you haven't opened the vendor for since
        local paid = addon:GetAverageCost(name)
        if paid then
            options.vendor = { method = "Vendor", unit = paid, detail = "What you paid; open the vendor to record its price" }
        end
    end

    -- Craft it
    local recipe = depth < MAX_DEPTH and not visiting[itemID] and FindRecipeForItem(itemID, name)
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

    -- Mill it from a herb you've milled before
    for herbID, record in pairs(GoldsmithDB.milling) do
        local out = record.outputs[itemID]
        if out and out.qty > 0 and record.milled > 0 then
            local herbCost = addon:GetMarketPrice(herbID) or addon:GetAverageCost(record.name)
            if herbCost then
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
                local unit = herbCost * record.milled * share / out.qty
                if not options.mill or unit < options.mill.unit then
                    options.mill = {
                        method = "Mill", unit = unit,
                        herbID = herbID, herbName = record.name,
                        perHerb = out.qty / record.milled,
                        share = share,
                    }
                end
            end
        end
    end

    for _, key in ipairs({ "buy", "vendor", "craft", "mill" }) do
        local option = options[key]
        if option and (not options.cheapest or option.unit < options.cheapest.unit) then
            options.cheapest = option
        end
    end

    -- Your own choice (right-click a plan row) wins over the cheapest, if
    -- that way is available for this item. memo.ignoreOverrides is used to
    -- price the plan the cheapest way, for comparison.
    local override = not memo.ignoreOverrides and GoldsmithDB.ui.methodOverrides[itemID]
    local chosen = override and options[string.lower(override)]
    options.best = chosen or options.cheapest
    options.override = chosen and override or nil

    memo[itemID] = options
    return options
end

-- Your choice of how to get an item in plans ("Buy", "Craft", "Mill",
-- "Vendor"), or nil to use the cheapest way.
function addon:SetMethodOverride(itemID, method)
    GoldsmithDB.ui.methodOverrides[itemID] = method
end

function addon:ClearMethodOverrides()
    wipe(GoldsmithDB.ui.methodOverrides)
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
local function BuildNode(itemID, name, need, depth, ctx, quality)
    local options = GetOptions(itemID, name, depth, ctx.memo, {})
    -- In a queue, what earlier crafts already count on isn't yours to use again
    local have = ctx.useOnHand and math.max(GetOnHand(itemID) - (ctx.pool and ctx.pool[itemID] or 0), 0) or 0
    local node = {
        itemID = itemID,
        name = name,
        depth = depth,
        need = need,
        have = math.min(have, need),
        toGet = math.max(need - have, 0),
        options = options,
        best = options.best,
        children = {},
    }
    if ctx.pool then ctx.pool[itemID] = (ctx.pool[itemID] or 0) + node.have end
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

    local best = options.best
    if best and best.method == "Craft" and node.toGet > 0 then
        local outputQty, slots = GetCraftNumbers(best.recipe)
        local crafts = WholeCrafts(node.toGet, SurePerCraft(best.recipe, outputQty))
        for _, s in ipairs(slots) do
            local choice = GetSlotChoice(s.slot, depth + 1, ctx.memo, {})
            if choice then
                table.insert(node.children,
                    BuildNode(choice.itemID, choice.name, MaterialNeed(s, crafts), depth + 1, ctx, choice))
            end
        end
    elseif best and best.method == "Mill" and node.toGet > 0 then
        local herbs = node.toGet / best.perHerb
        -- Each mill uses a fixed number of herbs (10 in Midnight), so you
        -- need whole mills' worth
        local record = GoldsmithDB.milling[best.herbID]
        local perCast = record and record.perCast
        if perCast and perCast > 1 then
            herbs = math.ceil(herbs / perCast - 0.0001) * perCast
        end
        table.insert(node.children, BuildNode(best.herbID, best.herbName, herbs, depth + 1, ctx))
    end
    return node
end

-- Walk the tree collecting what to buy on the AH and from vendors
local function CollectPurchases(node, ah, vendor)
    if node.toGet <= 0 then return end
    local best = node.best
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

-- Plan for making `quantity` of a recipe's item. Returns:
--   nodes     - top-level material rows (each with children)
--   cost      - cost of all materials at the cheapest options, whether
--               you'd buy them or already have them (the craft's true cost)
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
    GoldsmithDB.ui.methodOverrides = GoldsmithDB.ui.methodOverrides or {}
    local ctx = { memo = {}, useOnHand = useOnHand, pool = pool }
    local outputQty, slots = GetCraftNumbers(recipe)
    local crafts = WholeCrafts(quantity, SurePerCraft(recipe, outputQty))

    -- expectedOutput: what `crafts` whole crafts should make on average
    local plan = { recipe = recipe, quantity = quantity, crafts = crafts, nodes = {}, cost = 0, complete = true,
                   expectedOutput = crafts * outputQty }
    for _, s in ipairs(slots) do
        for _, part in ipairs(TopSlotParts(s.slot, tier, ctx.memo, recipe)) do
            local choice = part.choice
            local node = BuildNode(choice.itemID, choice.name, PartNeed(s, part.units, crafts), 1, ctx, choice)
            node.use = PartUse(s, part.units, crafts)
            table.insert(plan.nodes, node)
            if node.best then
                plan.cost = plan.cost + node.best.unit * node.use
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
    if plan.complete and cheapestComplete then
        plan.choiceExtra = plan.cost - cheapestCost
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

    if tier then
        plan.price = tier.price
    else
        plan.price = addon:GetMarketPrice(recipe.outputItemID)
    end
    plan.tier = tier
    if plan.price then
        plan.revenue = plan.price * (1 - AH_CUT) * plan.expectedOutput
        plan.profit = plan.revenue - plan.cost
        plan.margin = plan.cost > 0 and (plan.profit / plan.cost * 100) or nil
    end
    plan.demand, plan.demandSource = addon:GetDemand((tier and tier.itemID) or recipe.outputItemID, recipe.outputName)
    plan.saleRate = addon:GetSaleRate((tier and tier.itemID) or recipe.outputItemID)
    return plan
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

_G.Goldsmith = addon
