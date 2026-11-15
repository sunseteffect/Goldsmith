-- A recipe from an older expansion spends that expansion's concentration,
-- not the profession's current one: a War Within Entropy Enhancer was
-- checked against Midnight's 138 while The War Within's was 1000 (tflo,
-- GitHub, 2026-11-14).
local bench = dofile(BENCH_DIR .. "bench.lua")
local OLD = 99001 -- a stand-in for an older expansion's currency
local db = bench.LoadSaved()
local key
for k in pairs(db.characters) do if k:match("^Mysticmead") then key = k end end
local c = db.characters[key]

-- A concentration recipe Mysticmead knows, moved to the older currency
local prof, recipe
for recipeID, stats in pairs(c.recipeStats or {}) do
    local r = db.recipes[recipeID]
    local current = r and db.concentrationCurrency and db.concentrationCurrency[r.profession]
    if not recipe and r and c.knownRecipes and c.knownRecipes[recipeID] and current
        and stats.concentrationCurrencyID == current then
        prof, recipe = r.profession, r
        stats.concentrationCurrencyID = OLD
    end
end
bench.Check("a known concentration recipe", recipe ~= nil)
local current = db.concentrationCurrency[prof]
bench.world.currencies = { [current] = { quantity = 138 }, [OLD] = { quantity = 1000 } }
local addon = bench.Login("Mysticmead", { db = db })
bench.Advance(2)
bench.Log("%s (%s)", recipe.outputName or recipe.recipeID, prof)

bench.Equal("the profession: current expansion's", (addon:GetConcentration(prof)), 138)
bench.Equal("the recipe: its own expansion's", (addon:GetConcentration(prof, recipe)), 1000)

-- Saved for when another character is logged in
local snap = c.concentrationByCurrency and c.concentrationByCurrency[OLD]
bench.Equal("older expansion's saved", snap and snap.current, 1000)
bench.Equal("worked out for the character", (addon:GetCharacterConcentration(key, prof, recipe)), 1000)
bench.Equal("profession still the current one", (addon:GetCharacterConcentration(key, prof)), 138)
bench.Done()
