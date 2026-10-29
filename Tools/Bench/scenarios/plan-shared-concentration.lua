-- A plan whose mix the day's concentration plan lowered to make room for
-- another craft says so (user, 2026-10-29: 384 concentration, the to-do
-- took the 248 Lightfused Mana Potion mix over the better-per-point 278
-- one, leaving 120 for Refreshing Serum, and the plan didn't say why)
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.setupDone = true
db.queues = {}
db.ui2 = db.ui2 or {}
db.ui2.planMixOpen = true
local key
for k in pairs(db.characters) do if k:match("^Mysticmead") then key = k end end
local addon
-- The concentration where the to-do shares it out, whatever prices did:
-- try a few amounts until one to-do line uses a lower-ranked mix
local found
for _, amount in ipairs({ 384, 400, 450, 350, 520, 600 }) do
    for _, snap in pairs(db.characters[key].concentration or {}) do snap.current, snap.time = amount, os.time() end
    addon = bench.Login("Mysticmead", { db = db })
    local items = addon:GetCharacterTodo("All")[key].items
    local conc = 0
    for _, item in ipairs(items) do if item.concentration then conc = conc + 1 end end
    for _, item in ipairs(items) do
        if item.concentration and conc > 1 and not found then
            local rows = addon:WithCharacter(key, addon.GetTierRows, addon, item.recipe) or {}
            local best
            for _, e in ipairs(rows[1] and rows[1].scenarios or {}) do
                if e.tier == item.row.tier and e.concentrate and e.concentrationValue
                    and (not best or addon:BetterConcentration(e, best)) then best = e end
            end
            if best and best.description ~= item.row.description then
                found = { item = item, amount = amount }
            end
        end
    end
    if found then break end
end
if not found then
    bench.Log("no to-do shares its concentration with a lower mix today: nothing to test")
    return bench.Done()
end
local item = found.item
bench.Log("%d concentration: %s with %s", found.amount, item.recipe.outputName, item.row.description)
addon:ToggleWindow()
bench.Advance(2)
addon:OpenCraftPlan(item.recipe, item.row, key, nil, nil, item.crafts, item.row.description)
bench.Advance(5)
local screen = table.concat(bench.Screen(), "\n")
for line in screen:gmatch("[^\n]+") do
    if line:find("The top ", 1, true) then bench.Log("%s", line) end
end
bench.Has("says what the concentration is left for", screen, ", more in all.")
bench.Done()
