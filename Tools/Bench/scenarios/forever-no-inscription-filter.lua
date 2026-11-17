-- Forever has no Inscription: it was in the profession filter anyway, with
-- nothing under it (user, 2026-11-17). Retail keeps it.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local addon = bench.Login("Mysticmead", { db = db })
local function Has(list, name)
    for _, p in ipairs(list) do if p == name then return true end end
    return false
end
bench.Check("retail: listed", Has(addon:GetProfessions(), "Inscription"))
addon.isForever = true
for _, r in pairs(GoldsmithDB.recipes) do if r.profession == "Inscription" then r.profession = "Alchemy" end end
for k, p in pairs(GoldsmithDB.products or {}) do if p == "Inscription" or p == true then GoldsmithDB.products[k] = nil end end
for k, p in pairs(GoldsmithDB.reagents or {}) do if p == "Inscription" then GoldsmithDB.reagents[k] = nil end end
for _, e in ipairs(addon.ledger:getAll()) do if e.profession == "Inscription" then e.profession = "Unassigned" end end
for _, c in pairs(GoldsmithDB.characters) do if c.professions then c.professions.Inscription = nil end end
bench.Check("Forever: not listed", not Has(addon:GetProfessions(), "Inscription"))
bench.Done()
