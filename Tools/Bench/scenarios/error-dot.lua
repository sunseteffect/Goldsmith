-- A red dot on Settings, the Support entry and its card while an error is
-- newer than your last look at Support; opening Support clears it (user,
-- 2026-10-27: "like a notification icon")
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.errorLog = {}
db.errorsSeen = nil
local addon = bench.Login("Mysticmead", { db = db })
addon:ToggleWindow()
bench.Check("no errors, no dot", not addon:HasNewErrors())
table.insert(db.errorLog, { message = "Goldsmith/Planner.lua:1: test", stack = "", count = 1,
    first = os.time(), last = os.time() + 1, version = "test" })
addon:UpdateErrorDots()
bench.Check("an error: the dot shows", addon:HasNewErrors())
addon:ShowSettings()
GoldsmithSettings:Open("support")
bench.Check("Support opened: the dot goes", not addon:HasNewErrors())
bench.Done()
