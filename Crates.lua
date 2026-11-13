local addon = _G.Goldsmith or {}

-- Forever's Waylaid Crates: fill one with any one of its listed materials
-- and hand it in for Merchant's Favor. The tooltip says what each way of
-- filling it costs at today's prices, cheapest first (user, 2026-11-11:
-- "so i know how much it costs in materials to fill up"). The game doesn't
-- give the list to addons; it's from method.gg's crate table (2026-11-03).
-- IDs are checked against the name in game; a wrong one falls back to
-- looking the name up.

local CRATES = {
    ["Apprentice Ore"] = { { 20, 2770, "Copper Ore" }, { 20, 2771, "Tin Ore" } },
    ["Journeyman Ore"] = { { 10, 2775, "Silver Ore" }, { 20, 2772, "Iron Ore" } },
    ["Expert Ore"] = { { 10, 2776, "Gold Ore" }, { 20, 3858, "Mithril Ore" } },
    ["Artisan Ore"] = { { 10, 7911, "Truesilver Ore" }, { 20, 10620, "Thorium Ore" }, { 20, 11370, "Dark Iron Ore" } },

    ["Apprentice Ingots"] = { { 20, 2840, "Copper Bar" }, { 20, 3576, "Tin Bar" }, { 10, 2841, "Bronze Bar" } },
    ["Journeyman Ingots"] = { { 10, 2842, "Silver Bar" }, { 20, 3575, "Iron Bar" } },
    ["Expert Ingots"] = { { 20, 3860, "Mithril Bar" }, { 15, 3859, "Steel Bar" }, { 10, 3577, "Gold Bar" } },
    ["Artisan Ingots"] = { { 2, 11371, "Dark Iron Bar" }, { 10, 6037, "Truesilver Bar" }, { 20, 12359, "Thorium Bar" } },

    ["Apprentice Herbs"] = { { 20, 2447, "Peacebloom" }, { 20, 765, "Silverleaf" }, { 10, 2449, "Earthroot" },
        { 10, 785, "Mageroyal" }, { 10, 2450, "Briarthorn" } },
    ["Journeyman Herbs"] = { { 10, 3820, "Stranglekelp" }, { 10, 2453, "Bruiseweed" }, { 10, 3355, "Wild Steelbloom" },
        { 10, 3369, "Grave Moss" }, { 10, 3356, "Kingsblood" } },
    ["Earthly Expert Herbs"] = { { 20, 3357, "Liferoot" }, { 10, 3818, "Fadeleaf" }, { 10, 3821, "Goldthorn" },
        { 10, 3358, "Khadgar's Whisker" } },
    ["Flowering Expert Herbs"] = { { 10, 3819, "Wintersbite" }, { 10, 4625, "Firebloom" }, { 20, 8831, "Purple Lotus" },
        { 10, 8836, "Arthas' Tears" } },
    ["Earthly Artisan Herbs"] = { { 10, 13464, "Golden Sansam" }, { 20, 8838, "Sungrass" }, { 10, 8839, "Blindweed" },
        { 10, 8845, "Ghost Mushroom" }, { 10, 8846, "Gromsblood" } },
    ["Flowering Artisan Herbs"] = { { 20, 13463, "Dreamfoil" }, { 20, 13465, "Mountain Silversage" },
        { 20, 13466, "Plaguebloom" }, { 20, 13467, "Icecap" } },

    ["Apprentice Parts"] = { { 16, 4359, "Handful of Copper Bolts" }, { 16, 4361, "Copper Tube" },
        { 4, 4363, "Copper Modulator" } },
    ["Journeyman Parts"] = { { 8, 4371, "Bronze Tube" }, { 7, 4375, "Whirring Bronze Gizmo" },
        { 4, 4382, "Bronze Framework" }, { 45, 10558, "Gold Power Core" } },
    ["Expert Parts"] = { { 8, 4387, "Iron Strut" }, { 5, 10559, "Mithril Tube" }, { 12, 10560, "Unstable Trigger" },
        { 5, 10561, "Mithril Casing" } },
    ["Artisan Parts"] = { { 5, 15994, "Thorium Widget" }, { 5, 18631, "Truesilver Transformer" },
        { 2, 16000, "Thorium Tube" } },

    ["Apprentice Textiles"] = { { 40, 2589, "Linen Cloth" }, { 20, 2318, "Light Leather" } },
    ["Journeyman Textiles"] = { { 20, 2592, "Wool Cloth" }, { 40, 4306, "Silk Cloth" }, { 20, 2319, "Medium Leather" } },
    ["Expert Textiles"] = { { 40, 4338, "Mageweave Cloth" }, { 20, 4234, "Heavy Leather" } },
    ["Artisan Textiles"] = { { 40, 14047, "Runecloth" }, { 20, 4304, "Thick Leather" }, { 20, 8170, "Rugged Leather" } },

    ["Apprentice Fabrics"] = { { 2, 4231, "Cured Light Hide" }, { 20, 2996, "Bolt of Linen Cloth" } },
    ["Journeyman Fabrics"] = { { 6, 2997, "Bolt of Woolen Cloth" }, { 10, 4305, "Bolt of Silk Cloth" },
        { 2, 4233, "Cured Medium Hide" } },
    ["Expert Fabrics"] = { { 8, 4339, "Bolt of Mageweave" }, { 2, 4236, "Cured Heavy Hide" } },
    ["Artisan Fabrics"] = { { 8, 14048, "Bolt of Runecloth" }, { 2, 8172, "Cured Thick Hide" } },

    ["Apprentice Curiosities"] = { { 20, 10940, "Strange Dust" }, { 4, 10939, "Greater Magic Essence" },
        { 6, 10978, "Small Glimmering Shard" }, { 2, 11084, "Large Glimmering Shard" } },
    ["Journeyman Curiosities"] = { { 20, 11083, "Soul Dust" }, { 4, 11082, "Greater Astral Essence" },
        { 6, 11138, "Small Glowing Shard" }, { 2, 11139, "Large Glowing Shard" } },
    ["Expert Curiosities"] = { { 20, 11137, "Vision Dust" }, { 4, 11135, "Greater Mystic Essence" },
        { 6, 11177, "Small Radiant Shard" }, { 2, 11178, "Large Radiant Shard" } },
    ["Artisan Curiosities"] = { { 20, 11176, "Dream Dust" }, { 4, 11175, "Greater Nether Essence" },
        { 6, 14343, "Small Brilliant Shard" }, { 2, 14344, "Large Brilliant Shard" } },
}

local function FormatGold(copper)
    if addon.isForever then return addon:FormatMoney(copper) end
    return string.format("%.2fg", copper / 10000)
end

-- The item ID for a material: the table's, unless the game names that ID
-- something else, then the name looked up (once it's been seen)
local function MaterialID(id, name)
    local known = C_Item.GetItemNameByID(id)
    if not known or known == name then return id end
    local byName = C_Item.GetItemInfoInstant and C_Item.GetItemInfoInstant(name)
    return byName or id
end

-- The ways to fill a crate by its item name, cheapest first: { count, name,
-- itemID, cost of what you'd buy, have in bags }. cost is nil without a
-- price. Nil for anything that isn't a Waylaid Crate.
function addon:CrateFillCosts(itemName)
    local kind = itemName and itemName:match("^Waylaid Crate: (.+)$")
    local options = kind and CRATES[kind]
    if not options then return end
    local list = {}
    for _, o in ipairs(options) do
        local count, name = o[1], o[3]
        local id = MaterialID(o[2], name)
        -- Bags only: the crate is filled from your bags
        local have = math.min(C_Item.GetItemCount(id, false) or 0, count)
        local price = addon:GetAHPrice(id, true)
        local buy = count - have
        local cost = (buy == 0 and 0) or (price and price * buy) or nil
        table.insert(list, { count = count, name = name, itemID = id, cost = cost, have = have })
    end
    -- Cheapest first; no price last
    table.sort(list, function(a, b)
        if (a.cost == nil) ~= (b.cost == nil) then return a.cost ~= nil end
        if a.cost and a.cost ~= b.cost then return a.cost < b.cost end
        return a.name < b.name
    end)
    return list
end

-- "to fill" with the cheapest way, then every way one per line. short: the
-- first line only.
function addon:AddCrateTooltipLines(tooltip, itemName, short)
    local list = addon:CrateFillCosts(itemName)
    if not list then return end
    local best = list[1]
    local function Label(o)
        if o.have > 0 then return string.format("%d %s (have %d)", o.count, o.name, o.have) end
        return string.format("%d %s", o.count, o.name)
    end
    local function Cost(o)
        if not o.cost then return "no price" end
        if o.cost == 0 then return "in bags" end
        return FormatGold(o.cost)
    end
    tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r cost to fill",
        best.cost and (Cost(best) .. " (" .. best.name .. ")") or "no prices", 1, 1, 1, 1, 0.82, 0)
    if short then return end
    for i, o in ipairs(list) do
        local c = i == 1 and 1 or 0.8
        tooltip:AddDoubleLine("  " .. Label(o), Cost(o), c, c, c, c, c, c)
    end
end
