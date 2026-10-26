-- The Crafts page for a craft queued from Do this next shows the queued
-- mix, so its "to buy" matches the queue and Buy next (user, 2026-10-24:
-- Maddoxynn's Sienna Ink was queued with the 17 gold mix, which needs
-- nothing bought; the page showed the 20 gold mix and 2 items to buy).
-- Clicking another mix moves the queued entry to it.
local bench = dofile(BENCH_DIR .. "bench.lua")
local SIENNA_INK = 1230016
local MADDOXYNN = "Maddoxynn-Sargeras"

local db = bench.LoadSaved()
db.queues[MADDOXYNN] = { { recipeID = SIENNA_INK, quantity = 6, made = 0, tier = 2, concentrate = true,
                           prefMix = "17 gold Powder Pigment", added = os.time() } }
if db.ui2 and db.ui2.planMix then db.ui2.planMix[SIENNA_INK] = nil end
-- The mix list open (Compare), whatever it was left at in game
db.ui2 = db.ui2 or {}
db.ui2.planMixOpen = true
local addon = bench.Login("Mysticmead", { db = db })

addon:OpenCraftPlan(GoldsmithDB.recipes[SIENNA_INK], { tier = 2, concentrate = true }, MADDOXYNN, 6, "queue")
bench.Advance(2)
local screen = bench.Screen()
bench.Has("shows the queued mix", screen, "Picked: 17 gold Powder Pigment")
bench.Has("nothing to buy, as the queue", screen, "Nothing to buy on the AH")
bench.Equal("the queue buys nothing", #addon:BuildQueue(MADDOXYNN).buyAH, 0)

-- Clicking the 20 gold mix: the queue follows it. Its row is a click
-- area over the text, not a labeled button, so it's found by its mix.
local hit
for _, f in ipairs(bench.wow.frames) do
    if f.entry and f.entry.description == "20 gold Powder Pigment, 1 gold Mana Lily Pigment" and f:IsVisible() then hit = f end
end
bench.Check("the 20 gold mix row shows", hit ~= nil)
if hit then hit:Click() end
bench.Advance(1)
local e = GoldsmithDB.queues[MADDOXYNN][1]
bench.Equal("queued Do this next mix let go", e.prefMix, nil)
bench.Has("page shows the clicked mix", bench.Screen(), "Picked: 20 gold Powder Pigment, 1 gold Mana Lily Pigment")
bench.Check("the queue now buys for it", #addon:BuildQueue(MADDOXYNN).buyAH > 0)
bench.Done()
