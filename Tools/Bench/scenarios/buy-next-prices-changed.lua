-- Prices that change while the AH is open (an AH search, a scan) plan Buy
-- next again: searching each herb for Plant Protein moved the plan to
-- Winged Stalk, and Buy next kept the old list until the AH was reopened
-- (user, 2026-10-31). Once per change, not over and over.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.settings.autoScan = false
db.queues = {}
db.queues["Mysticmead-Sargeras"] = { { recipeID = 1226197, quantity = 8, made = 0, added = os.time() } }
local addon = bench.Login("Mysticmead", { db = db })
bench.OpenAH()
bench.Advance(3)

local planned = 0
local build = addon.BuildQueue
addon.BuildQueue = function(...) planned = planned + 1 return build(...) end

addon.Refresh() -- what an AH search's prices do (Pricing.lua)
bench.Advance(3)
bench.Check("planned again after new prices", planned > 0)
planned = 0
bench.Advance(10)
bench.Equal("not again without a change", planned, 0)

bench.CloseAH()
addon.Refresh()
bench.Advance(3)
bench.Equal("AH closed: not planned", planned, 0)
bench.Done()
