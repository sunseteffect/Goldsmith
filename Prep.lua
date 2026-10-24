local addon = _G.Goldsmith or {}

-- Before a craft: the right profession tool on, and the crafting buff up
--
-- Maddoxynn has two Inscription tools: one with resourcefulness for
-- milling, one with multicraft for everything else. Goldsmith offers the
-- swap as a button, never swaps by itself (user, 2026-10-23: "use button
-- ... and not a silent swap"). And Shattered Essence in one click instead
-- of finding Enchanting's shatter recipe by hand ("it isn't that quick").
--
-- addon:CraftPrep(state, recipe) gives one action at a time, the tool
-- first: { label, lines (for the hover), run }, or nil. It shows where the
-- buff warning is: above the plan's Craft button and in the queue panel.

-- The two main professions' tool slots (INVSLOT_PROF0TOOL, INVSLOT_PROF1TOOL)
local TOOL_SLOTS = { 20, 23 }
local PROFESSION_CLASS = 19 -- Enum.ItemClass.Profession
-- Enum.ItemProfessionSubclass, by profession name
local SUBCLASS = {
    Blacksmithing = 0, Leatherworking = 1, Alchemy = 2, Herbalism = 3, Cooking = 4, Mining = 5,
    Tailoring = 6, Engineering = 7, Enchanting = 8, Fishing = 9, Skinning = 10, Jewelcrafting = 11,
    Inscription = 12,
}
-- The stat a step wants, picked per step (user, 2026-10-24) rather than
-- "multicraft for every craft", which was only right for Maddoxynn:
--   mill or prospect      resourcefulness (saves herbs and ore)
--   with concentration    ingenuity (gives concentration back), then as
--                         other crafts when no tool has it (user,
--                         2026-10-24)
--   other crafts          multicraft, or resourcefulness when the recipe
--                         has no multicraft (gear can't multicraft)
-- and only a stat the game says the recipe has (its bonus stats). The
-- first of these any of your tools has (on you or in your bags) is the
-- one: a tool on you that's best for ingenuity isn't swapped off for
-- multicraft.
local STAT_NAMES = { RESOURCEFULNESS = "Resourcefulness", MULTICRAFT = "Multicraft", INGENUITY = "Ingenuity" }
local STAT_HELP = {
    RESOURCEFULNESS = "Resourcefulness saves materials.",
    MULTICRAFT = "Multicraft makes extra items on a craft.",
    INGENUITY = "Ingenuity gives back some of the concentration a craft uses.",
}

-- The salvage recipe that gives a profession's crafting buff, by part of
-- its name: shattering a mote gives Shattered Essence (Milling.lua). The
-- buff itself is Quality.lua's CRAFT_BUFFS.
local BUFF_SALVAGE = { Enchanting = "Shatter" }

local function StatName(key)
    return _G["ITEM_MOD_" .. key .. "_SHORT"] or STAT_NAMES[key]
end

-- The stats a recipe has, as a set of names ("Multicraft"), from the game;
-- nil when it can't say (the profession isn't open)
local function RecipeStats(recipeID, concentrate)
    if not (recipeID and C_TradeSkillUI.GetCraftingOperationInfo) then return nil end
    local ok, op = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, nil, concentrate == true)
    if not (ok and op and op.bonusStats) then return nil end
    local set = {}
    for _, s in ipairs(op.bonusStats) do
        if s.bonusStatName then set[s.bonusStatName] = true end
    end
    return set
end

-- The stats this step could want, best first
local function Wanted(kind, recipe, concentrate)
    if kind == "salvage" then return { "RESOURCEFULNESS" } end
    local has = RecipeStats(recipe.recipeID, concentrate)
    if not has then return nil end
    local order = concentrate and { "INGENUITY", "MULTICRAFT", "RESOURCEFULNESS" }
        or { "MULTICRAFT", "RESOURCEFULNESS" }
    local list = {}
    for _, key in ipairs(order) do
        if has[STAT_NAMES[key]] or has[_G["ITEM_MOD_" .. key .. "_SHORT"] or ""] then table.insert(list, key) end
    end
    return #list > 0 and list or nil
end

local function IsTool(itemID, subclass)
    local _, _, _, equipLoc, _, classID, subclassID = C_Item.GetItemInfoInstant(itemID)
    return classID == PROFESSION_CLASS and subclassID == subclass and equipLoc == "INVTYPE_PROFESSION_TOOL"
end

-- How much of a stat an item's hover lists ("+110 Multicraft"), and
-- whether its enchant gives the stat. The enchant line has no number
-- ("Enchanted: Enchant Tool - Amani Resourcefulness"): two quills with
-- +110 Multicraft each, one enchanted for resourcefulness, read as a tie
-- and no button showed (user, 2026-10-24).
local ENCHANTED = (ENCHANTED_TOOLTIP_LINE or "Enchanted: %s"):match("^(.-)%%s") or "Enchanted:"
local function StatOn(data, stat)
    local total, enchant = 0, false
    for _, line in ipairs(data and data.lines or {}) do
        local text = line.leftText
        if type(text) == "string" and text:find(stat, 1, true) then
            if text:find(ENCHANTED, 1, true) == 1 then
                enchant = true
            else
                local n = text:match("%+([%d,]+)")
                if n then total = total + (tonumber((n:gsub(",", ""))) or 0) end
            end
        end
    end
    return total, enchant
end

-- Better for the step: the enchant for its stat first (its amount isn't
-- shown, and it's what the second tool is for), then more of the stat
local function Better(value, enchant, thanValue, thanEnchant)
    if enchant ~= thanEnchant then return enchant end
    return value > thanValue
end

local function ItemName(itemID)
    return C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
end

-- A better tool in your bags for this kind of step: more of the stat it
-- wants, and no lower item level (an old tool would cost skill, and so
-- quality). Only when one of the profession's tools is on: that's the slot.
local function ToolAction(profession, kind, recipe, concentrate)
    local subclass = SUBCLASS[profession]
    if not subclass or not (C_TooltipInfo and C_TooltipInfo.GetBagItem) then return nil end
    local wanted = Wanted(kind, recipe, concentrate)
    if not wanted then return nil end
    local slot, equippedID
    for _, s in ipairs(TOOL_SLOTS) do
        local id = GetInventoryItemID("player", s)
        if id and IsTool(id, subclass) then slot, equippedID = s, id break end
    end
    if not slot then return nil end
    local okE, data = pcall(C_TooltipInfo.GetInventoryItem, "player", slot)
    local equippedLevel = C_Item.GetCurrentItemLevel(ItemLocation:CreateFromEquipmentSlot(slot)) or 0
    -- The tools in your bags you could swap to (no lower item level)
    local tools = {}
    for bag = 0, NUM_BAG_SLOTS or 4 do
        for bagSlot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, bagSlot)
            if info and info.itemID and IsTool(info.itemID, subclass) then
                local level = C_Item.GetCurrentItemLevel(ItemLocation:CreateFromBagAndSlot(bag, bagSlot)) or 0
                local ok, bagData = pcall(C_TooltipInfo.GetBagItem, bag, bagSlot)
                if ok and level >= equippedLevel then
                    table.insert(tools, { bag = bag, slot = bagSlot, itemID = info.itemID, data = bagData })
                end
            end
        end
    end
    -- The first wanted stat any tool has
    local want, stat, have, haveEnchant, best
    for _, key in ipairs(wanted) do
        local name = StatName(key)
        local h, he = 0, false
        if okE then h, he = StatOn(data, name) end
        local found = h > 0 or he
        local top
        for _, t in ipairs(tools) do
            local value, enchant = StatOn(t.data, name)
            if value > 0 or enchant then found = true end
            if Better(value, enchant, h, he) and (not top or Better(value, enchant, top.value, top.enchant)) then
                top = { bag = t.bag, slot = t.slot, value = value, enchant = enchant, itemID = t.itemID }
            end
        end
        if found then
            want, stat, have, haveEnchant, best = key, name, h, he, top
            break
        end
    end
    if not best then return nil end
    local name = ItemName(best.itemID)
    return {
        -- With the stat: both of Maddoxynn's tools are "Sin'dorei Quill"
        label = string.format("Equip %s (%s)", name, stat),
        -- When a long name doesn't fit the button (SetPrepLabel)
        short = string.format("Equip %s tool", stat),
        lines = {
            best.enchant ~= haveEnchant
                and string.format("The one in your bags is enchanted for %s; the one on you isn't.", stat)
                or string.format("%s has %d %s; the one on you has %d.", name, best.value, stat, have),
            STAT_HELP[want],
            string.format("Swaps %s for it. Goldsmith offers it back when the next step wants the other.",
                ItemName(equippedID)),
        },
        run = function()
            local info = C_Container.GetContainerItemInfo(best.bag, best.slot)
            if not (info and info.itemID == best.itemID) then return end
            ClearCursor()
            C_Container.PickupContainerItem(best.bag, best.slot)
            EquipCursorItem(slot)
            ClearCursor()
        end,
    }
end

-- What the queue's crafts need, so the buff never uses up a material a
-- queued craft needs (user, 2026-10-23: "causing the user to buy more").
-- Every quality a slot takes counts, to be safe.
local function QueueNeeds()
    local needs = {}
    for _, e in ipairs(addon:GetQueue(addon.charKey)) do
        local remaining = math.max((e.quantity or 0) - (e.made or 0), 0)
        if e.recipeID and remaining > 0 then
            local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, e.recipeID, false)
            for _, s in ipairs(ok and schematic and schematic.reagentSlotSchematics or {}) do
                for _, r in ipairs(s.reagents or {}) do
                    if r.itemID then
                        needs[r.itemID] = (needs[r.itemID] or 0) + (s.quantityRequired or 0) * remaining
                    end
                end
            end
        end
        if e.salvageID and remaining > 0 then
            needs[e.salvageID] = (needs[e.salvageID] or 0) + remaining
        end
    end
    return needs
end

-- The buff's salvage recipe for the open profession (by name), or nil.
-- Kept for the session.
local buffRecipes = {}
local function BuffRecipe(profession)
    local pattern = BUFF_SALVAGE[profession]
    if not pattern or not (Enum.TradeskillRecipeType and C_TradeSkillUI.GetSalvagableItemIDs) then return nil end
    local key = (addon.charKey or "") .. ":" .. profession
    if buffRecipes[key] ~= nil then return buffRecipes[key] or nil end
    buffRecipes[key] = false
    for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
        local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
        if info and info.learned and type(info.name) == "string" and info.name:find(pattern, 1, true) then
            local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
            if ok and schematic and schematic.recipeType == Enum.TradeskillRecipeType.Salvage then
                buffRecipes[key] = { recipeID = recipeID, perCast = math.max(schematic.quantityMax or 1, 1) }
                return buffRecipes[key]
            end
        end
    end
    return nil
end

-- The biggest stack of an item in your bags
local function BagStack(itemID)
    local best, count = nil, 0
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID == itemID and info.stackCount > count then
                best, count = ItemLocation:CreateFromBagAndSlot(bag, slot), info.stackCount
            end
        end
    end
    return best, count
end

-- The crafting buff, when it's off: the cheapest item the buff's salvage
-- takes that you can spare. With the profession open (the game salvages
-- only then; it is when you craft).
local function BuffAction(profession, recipe)
    local buff = addon:MissingCraftBuff(profession, recipe)
    if not buff or not addon.ProfessionOpen({ profession = profession }) then return nil end
    local r = BuffRecipe(profession)
    if not r then return nil end
    local ok, ids = pcall(C_TradeSkillUI.GetSalvagableItemIDs, r.recipeID)
    local needs, best = QueueNeeds(), nil
    for _, id in ipairs(ok and ids or {}) do
        local location, stack = BagStack(id)
        local spare = (C_Item.GetItemCount(id) or 0) - (needs[id] or 0)
        if location and stack >= r.perCast and spare >= r.perCast then
            local price = (addon:GetMarketPrice(id) or math.huge) * r.perCast
            if not best or price < best.price then best = { itemID = id, location = location, price = price } end
        end
    end
    if not best then return nil end
    local name = ItemName(best.itemID)
    return {
        label = string.format("%s %d %s", BUFF_SALVAGE[profession], r.perCast, name),
        lines = {
            string.format("Turns on %s: %s %d %s, the cheapest you have that the queue doesn't need.",
                buff, BUFF_SALVAGE[profession]:lower(), r.perCast, name),
        },
        run = function()
            if C_Item.DoesItemExist(best.location) then
                C_TradeSkillUI.CraftSalvage(r.recipeID, 1, best.location)
            end
        end,
    }
end

-- The action before this step, or nil. state: the Craft button's
-- (state.salvage for a mill step); recipe: the plan's or queue row's.
function addon:CraftPrep(state, recipe, concentrate)
    if not (state and recipe) or state.open or InCombatLockdown() then return nil end
    local salvage = state.salvage
    local profession = salvage and salvage.profession or recipe.profession
    if not profession then return nil end
    local tool = ToolAction(profession, salvage and "salvage" or "craft", recipe, concentrate)
    if tool then return tool end
    if salvage then return nil end
    return BuffAction(profession, recipe)
end

-- The button's label, or its short form when the tool's name is too long
-- for it ("Equip Multicraft tool")
function addon:SetPrepLabel(button, action)
    button:SetLabel(action.label)
    if action.short and button.label:GetUnboundedStringWidth() > button:GetWidth() - 16 then
        button:SetLabel(action.short)
    end
end

-- From a click (the game wants one to equip or salvage)
function addon:RunPrep(action)
    if not action or InCombatLockdown() then return end
    if UnitCastingInfo("player") then return end
    if addon:TourBlocks(action.label:lower()) then return end
    action.run()
end

-- Equipping or the buff changes what's offered: the plan screen and queue
-- panel ask again
local watch = CreateFrame("Frame")
watch:RegisterEvent("PLAYER_EQUIPMENT_CHANGED")
watch:RegisterEvent("BAG_UPDATE_DELAYED")
watch:SetScript("OnEvent", function()
    if addon.UpdatePlanPrep then addon.UpdatePlanPrep() end
    if addon.UpdateQueuePanelPrep then addon.UpdateQueuePanelPrep() end
    if addon.UpdateQueueTabPrep then addon.UpdateQueueTabPrep() end
end)
