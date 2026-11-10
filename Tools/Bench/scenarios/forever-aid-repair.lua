-- Forever's launch-week "Aid" (First Aid) put right once (user, 2026-11-10:
-- Stats listed "5. Aid" under First Aid)
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.aidRepaired = nil
local key = next(db.characters)
db.characters[key].professions = db.characters[key].professions or {}
db.characters[key].professions["First Aid"] = db.characters[key].professions["First Aid"] or { skill = 1, maxSkill = 75 }
table.insert(db.entries, { type = "COST", kind = "PURCHASE", item = "Bench Spices", quantity = 1, totalCopper = 10,
    profession = "Aid", timestamp = os.time() - 86400, character = "X", realm = "Y" })
db.reagents = db.reagents or {}
db.reagents["Bench Spices"] = "Aid"
db.characters[key].calibration = db.characters[key].calibration or {}
db.characters[key].calibration.Aid = { mcProcs = 0 }
local addon = bench.Login("Mysticmead", { db = db })
local left = 0
for _, e in ipairs(GoldsmithDB.entries) do if e.profession == "Aid" then left = left + 1 end end
bench.Equal("no Aid entries left", left, 0)
bench.Equal("reagent back to First Aid", GoldsmithDB.reagents["Bench Spices"], "First Aid")
bench.Equal("calibration moved", GoldsmithDB.characters[key].calibration.Aid, nil)
bench.Check("once", GoldsmithDB.aidRepaired == true)
bench.Done()
