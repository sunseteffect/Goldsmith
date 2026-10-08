-- Compares what crafts really made with what the estimate expects, per
-- profession, from the saved craft lots (dev only, not in the release).
--
--   lua Check-Yields.lua <path to SavedVariables\Goldsmith.lua>
--
-- Expected items per craft = normal output x (1 + multicraft% x extra per
-- proc), extra per proc calibrated as in Pricing.lua GetCalibration. Lots
-- saved since 2026-10-08 carry the crafter's multicraft at craft time
-- (lot.mc); older ones fall back to today's stats, which overstates
-- crafts made while levelling. Both are counted separately.
time = os.time; date = os.date
dofile(arg[1])
local DB = GoldsmithDB

local BASE_MULTICRAFT_EXTRA, PRIOR_WEIGHT = 1.5, 5

-- Recipe by output item, every quality tier included
local byOutput = {}
for _, r in pairs(DB.recipes) do
    if r.outputItemID then byOutput[r.outputItemID] = r end
end
for _, c in pairs(DB.characters) do
    for recipeID, tiers in pairs(c.tierData or {}) do
        if type(tiers) == "table" and DB.recipes[recipeID] then
            for _, t in pairs(tiers) do
                if type(t) == "table" and t.itemID then
                    byOutput[t.itemID] = byOutput[t.itemID] or DB.recipes[recipeID]
                end
            end
        end
    end
end

local function TodayStats(recipeID)
    for key, c in pairs(DB.characters) do
        local s = c.recipeStats and c.recipeStats[recipeID]
        if s and s.multicraft then return s, key end
    end
end

local function McExtra(charKey, profession)
    local c = DB.characters[charKey]
    local cal = c and c.calibration and c.calibration[profession]
    return (BASE_MULTICRAFT_EXTRA * PRIOR_WEIGHT + (cal and cal.mcExtraRatio or 0))
        / (PRIOR_WEIGHT + (cal and cal.mcProcs or 0))
end

local groups = {}
local function Group(name)
    groups[name] = groups[name] or { crafts = 0, actual = 0, expected = 0, procs = 0, expProcs = 0 }
    return groups[name]
end

for itemID, lots in pairs(DB.craftLots) do
    local r = byOutput[itemID]
    if r and (r.outputQty or 0) > 0 then
        for _, lot in ipairs(lots) do
            local mc, charKey, when = lot.mc, lot.char, "saved at craft"
            if not mc then
                local s, key = TodayStats(r.recipeID)
                mc, charKey, when = s and s.multicraft, key, "today's stats"
            end
            if mc then
                local extra = McExtra(charKey, r.profession)
                for _, g in ipairs({ Group(r.profession .. " (" .. when .. ")"), Group("ALL (" .. when .. ")") }) do
                    g.crafts = g.crafts + 1
                    g.actual = g.actual + lot.qty
                    g.expected = g.expected + r.outputQty * (1 + mc / 100 * extra)
                    if lot.qty > r.outputQty then g.procs = g.procs + 1 end
                    g.expProcs = g.expProcs + mc / 100
                end
            end
        end
    end
end

local names = {}
for name in pairs(groups) do names[#names + 1] = name end
table.sort(names)
for _, name in ipairs(names) do
    local g = groups[name]
    print(string.format("%-40s crafts %4d  items %5d vs expected %7.1f (%+.0f%%)  multicraft procs %d vs expected %.1f",
        name, g.crafts, g.actual, g.expected, (g.actual / g.expected - 1) * 100, g.procs, g.expProcs))
end
