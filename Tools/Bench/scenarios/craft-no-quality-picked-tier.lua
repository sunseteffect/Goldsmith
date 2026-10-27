-- A craft whose item has no quality (bags, treatises, teas) crafts with the
-- qualities the plan picked: gold Azeroot when it's the cheaper one and
-- it's what you hold. The Craft button gave the game all lowest quality,
-- so a bag's plan with Tier 2 materials in the bags said to buy Tier 1,
-- and the sale was costed at those (a user's report, 2026-10-25). A middle
-- quality (three-quality materials) goes in as picked too.
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT, GOLD_AZEROOT, TEA = 236774, 236775, 1226197
local db = bench.LoadSaved()
db.queues = { ["Mysticmead-Sargeras"] = { { recipeID = TEA, quantity = 4, made = 0, added = os.time() } } }
db.inMail["Mysticmead-Sargeras"] = {}
for _, c in pairs(db.characters) do
    for _, held in ipairs({ c.stock or {}, c.stockBank or {} }) do held[AZEROOT], held[GOLD_AZEROOT] = nil, nil end
end
if db.warbandStock then db.warbandStock[AZEROOT], db.warbandStock[GOLD_AZEROOT] = nil, nil end
local addon = bench.Login("Mysticmead", { db = db })
bench.world.bank[AZEROOT], bench.world.bank[GOLD_AZEROOT] = nil, nil
-- Only gold Azeroot held, and gold the cheaper one
bench.SetBags({ [AZEROOT] = 0, [GOLD_AZEROOT] = 40, ["Mana-Wyrm Essence"] = 40 })
local AHPrice = addon.GetAHPriceInfo
function addon:GetAHPriceInfo(itemID, buying)
    if itemID == AZEROOT then return bench.Gold(20), "Goldsmith scan", 0 end
    if itemID == GOLD_AZEROOT then return bench.Gold(15), "Goldsmith scan", 0 end
    return AHPrice(self, itemID, buying)
end
addon.dataVersion = addon.dataVersion + 1

-- The window's form shows no recipe (a stand-in frame answers 0)
local page = ProfessionsFrame.CraftingPage
if page and page.SchematicForm then page.SchematicForm.GetRecipeInfo = function() return nil end end
bench.OpenProfession("Cooking")
bench.Chat()
bench.Calls()
addon:CraftNext()
bench.Advance(1)
local chat = bench.Chat()
bench.Show(chat, "chat")
bench.Has("crafts the tea", bench.Calls(), "CraftRecipe(" .. TEA)
local used = {}
for _, e in ipairs(bench.world.lastCraftReagents or {}) do used[e.reagent.itemID] = (used[e.reagent.itemID] or 0) + e.quantity end
bench.Check("with gold Azeroot", (used[GOLD_AZEROOT] or 0) > 0, bench.Serialize(used))
bench.Check("no silver Azeroot", not used[AZEROOT], bench.Serialize(used))
bench.HasNot("doesn't ask for Azeroot", chat, "Azeroot.")

-- Three qualities: the middle one picked goes in as the middle one
bench.OpenProfession("Alchemy")
local courage
for id, r in pairs(GoldsmithDB.recipes) do
    if r.outputName == "Formulated Courage" and bench.world.schematics[id] then courage = id end
end
bench.Check("Mysticmead knows Formulated Courage", courage ~= nil)
if courage then
    local slot = GoldsmithDB.recipes[courage].reagents[1]
    local mid = slot.itemIDs[2]
    local list = addon:GetCraftReagents(courage, { chosen = { [mid] = true } })
    local got = {}
    for _, e in ipairs(list or {}) do got[e.reagent.itemID] = e.quantity end
    bench.Equal("middle quality " .. slot.names[2] .. " used", got[mid], slot.quantity)
    bench.Check("not the lowest", not got[slot.itemIDs[1]], bench.Serialize(got))
end
bench.Done()
