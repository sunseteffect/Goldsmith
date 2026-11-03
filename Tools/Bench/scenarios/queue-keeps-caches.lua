-- Queueing a craft keeps the worked-out to-dos and craft lists: they only
-- read the queue for their "queued" label. Every queued to-do reloaded
-- the whole Characters tab (user, 2026-11-03). The queue, Buy next and
-- the label still follow.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local key = "Mysticmead-Sargeras"
db.queues[key] = {}
local addon = bench.Login("Mysticmead", { db = db })
addon:ToggleWindow()
addon:ShowTab("characters")
bench.Advance(5)

-- A recipe this character knows, with an output to queue
local recipe
for id, r in pairs(GoldsmithDB.recipes) do
    if not recipe and r.outputName and r.profession == "Alchemy" then recipe = r end
end
bench.Check("an Alchemy recipe", recipe ~= nil)
local version = addon.dataVersion
addon:QueueSuggestion(key, recipe, nil, false, 2)
bench.Advance(2)
bench.Equal("caches kept", addon.dataVersion, version)
bench.Check("in the queue", addon:FindQueueEntry(key, recipe.recipeID, nil, false) ~= nil)
local rows = addon:BuildQueue(key).rows
bench.Equal("the queue plans it", rows[1] and rows[1].recipe and rows[1].recipe.recipeID, recipe.recipeID)
bench.Done()
