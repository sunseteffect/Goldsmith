-- Salvaging on another character is never picked on its own: an
-- enchanter's plan said "Prospect" and its step "This character can't
-- prospect" (TheShua, CurseForge, 2026-11-12). Mailing ore to the
-- jewelcrafter and back isn't worth the margin (user: "probably not worth
-- the time it takes to mail switch prospect mail switch"). The plan buys
-- instead; a jewelcrafter's own plan still prospects; picking it
-- yourself still works, named for who'd do it.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.searchPrices, db.orderBooks = {}, {}
local STONE, STONE2, ORE, WEIGHTSTONE = 242788, 242789, 237364, 1230759
local SCRIBE, JC = "Maddoxynn-Sargeras", "Trypttamine-Sargeras"
bench.Check("the scribe has no Jewelcrafting (what this tests)", db.characters[SCRIBE] and not db.characters[SCRIBE].professions.Jewelcrafting)
bench.Check("the jewelcrafter has it", db.characters[JC] and db.characters[JC].professions.Jewelcrafting ~= nil)
-- None of the stone or ore held anywhere
for _, c in pairs(db.characters) do
    for _, t in ipairs({ c.stock, c.stockBank }) do
        if t then t[STONE], t[STONE2], t[ORE] = nil, nil, nil end
    end
end
if db.warbandStock then db.warbandStock[STONE], db.warbandStock[STONE2], db.warbandStock[ORE] = nil, nil, nil end
local addon = bench.Login("Maddoxynn", { db = db })
-- Prospecting far cheaper than buying the stone
local prices = {}
for id in pairs(GoldsmithDB.milling[ORE].outputs) do prices[id] = { 1, 1, 9999 } end
prices[STONE], prices[STONE2] = { 50000, 50000, 9999 }, { 60000, 60000, 9999 }
prices[ORE] = { 100, 100, 9999 }
GoldsmithDB.ownScan = { time = time() - 60, method = "pages", items = 9, group = addon:RealmGroup(), prices = prices }
addon:DataChanged()

-- Refulgent Weightstone takes 4 of the stone; whoever plans it
local recipe = GoldsmithDB.recipes[WEIGHTSTONE]
local function Buys(key, choices)
    local plan = addon:WithChoices(choices or {}, addon.WithCharacter, addon, key, addon.BuildPlan, addon, recipe, 1, true, nil, {})
    local out = {}
    for _, e in ipairs(plan and plan.buyAH or {}) do out[e.itemID] = e.quantity end
    return out
end

local scribe = Buys(SCRIBE)
bench.Check("scribe: buys the stone", scribe[STONE] ~= nil)
bench.Check("scribe: no ore to prospect", scribe[ORE] == nil)
bench.Equal("scribe: Crafts list doesn't count prospecting",
    addon:WithCharacter(SCRIBE, addon.SalvageUnitCost, addon, STONE, "Dusk-Shrouded Stone"), nil)

local jc = Buys(JC)
bench.Check("jewelcrafter: prospects (buys ore)", jc[ORE] ~= nil)
bench.Check("jewelcrafter: doesn't buy the stone", jc[STONE] == nil)
bench.Check("jewelcrafter: Crafts list counts prospecting",
    addon:WithCharacter(JC, addon.SalvageUnitCost, addon, STONE, "Dusk-Shrouded Stone") ~= nil)

-- Picked on the scribe (right-click: Prospect it on Trypttamine)
local picked = Buys(SCRIBE, { [STONE] = "Mill" })
bench.Check("picked: the scribe's plan prospects", picked[ORE] ~= nil and picked[STONE] == nil)
bench.Done()
