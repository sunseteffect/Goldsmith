-- The Crafts page for a craft queued from Do this next shows the queued
-- mix, so its "to buy" matches the queue and Buy next (user, 2026-10-24:
-- Maddoxynn's Sienna Ink was queued with the 17 gold mix, which needs
-- nothing bought; the page showed the 20 gold mix and 2 items to buy).
-- Clicking another mix moves the queued entry to it.
local bench = dofile(BENCH_DIR .. "bench.lua")
-- The mix row marked as used: "(picked)", "(your pick)" or "(queued)"
-- after its name (the "Picked:" line is hidden with the panel open)
local function PickedRow(screen, label)
    if type(screen) == "table" then screen = table.concat(screen, "\n") end
    for line in screen:gmatch("[^\n]+") do
        if line:find(label, 1, true) and (line:find("(picked)", 1, true) or line:find("(your pick)", 1, true)
            or line:find("(queued)", 1, true)) then return line end
    end
end
local SIENNA_INK = 1230016
local MADDOXYNN = "Maddoxynn-Sargeras"

local db = bench.LoadSaved()
db.queues[MADDOXYNN] = { { recipeID = SIENNA_INK, quantity = 6, made = 0, tier = 2, concentrate = true,
                           prefMix = "17 gold Powder Pigment", added = os.time() } }
if db.ui2 and db.ui2.planMix then db.ui2.planMix[SIENNA_INK] = nil end
-- The mix list open (Compare), whatever it was left at in game
db.ui2 = db.ui2 or {}
db.ui2.planMixOpen = true
-- Silver Powder Pigment held, as on 2026-10-24 (used up since)
db.characters[MADDOXYNN].stock[245808] = 60
-- and the silver Argentleaf for the rest (milled since)
db.characters[MADDOXYNN].stock[236776] = 200
local addon = bench.Login("Mysticmead", { db = db })

addon:OpenCraftPlan(GoldsmithDB.recipes[SIENNA_INK], { tier = 2, concentrate = true }, MADDOXYNN, 6, "queue")
bench.Advance(2)
local screen = bench.Screen()
bench.Check("shows the queued mix", PickedRow(screen, "17 gold Powder Pigment") ~= nil)
bench.Has("says it's the queued mix", screen, "in your queue")
bench.Has("nothing to buy, as the queue", screen, "Nothing to buy on the AH")
bench.Equal("the queue buys nothing", #addon:BuildQueue(MADDOXYNN).buyAH, 0)

-- Clicking another mix: the queue follows it. Its row is a click area
-- over the text, not a labeled button, so it's found by its mix: any one
-- not picked (which mixes are listed follows today's prices; the 20 gold
-- one this was written for was gone by 2026-10-26)
local hit
for _, f in ipairs(bench.wow.frames) do
    if f.entry and f.entry.description and not f.picked and f:IsVisible() and not hit then hit = f end
end
bench.Check("another mix row shows", hit ~= nil)
if hit then
    local clicked = hit.entry.description
    hit:Click()
    bench.Advance(1)
    local e = GoldsmithDB.queues[MADDOXYNN][1]
    -- The clicked mix, not the queue's own pick (2026-10-28)
    bench.Equal("queue keeps the clicked mix", e.prefMix, clicked)
    bench.Check("page shows the clicked mix", PickedRow(bench.Screen(), (clicked:gsub("^%l", string.upper))) ~= nil)
end
bench.Done()
