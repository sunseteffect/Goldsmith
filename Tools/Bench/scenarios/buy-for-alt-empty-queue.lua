-- On a character with nothing queued, while another character's queue has
-- everything it needs: Buy next says so rather than vanishing (user,
-- 2026-10-24: on Mysticmead nothing showed; Maddoxynn's Sienna Ink was
-- covered by her pigments and Mana Lily to mill). Sets up its own queues,
-- so it doesn't depend on what's queued in the saved data.
local bench = dofile(BENCH_DIR .. "bench.lua")
local TEA = 1226197
local db = bench.LoadSaved()
db.settings.buyFor = "me"
for key in pairs(db.queues) do db.queues[key] = {} end
db.inMail["Mysticmead-Sargeras"] = {}
-- Maddoxynn has a queue, and holds every material it needs
db.queues["Maddoxynn-Sargeras"] = { { recipeID = TEA, quantity = 2, made = 0, added = os.time() } }
local madd = db.characters["Maddoxynn-Sargeras"]
for _, slot in ipairs(db.recipes[TEA].reagents) do
    for _, id in ipairs(slot.itemIDs) do madd.stock[id] = 100 end
end
bench.Login("Mysticmead", { db = db })
bench.OpenAH()
bench.Advance(2)
bench.Has("says their queue needs nothing", bench.Screen(), "Nothing to buy.")
bench.HasNot("no All queues box with nothing to buy", bench.Screen(), "All queues")
bench.Done()
