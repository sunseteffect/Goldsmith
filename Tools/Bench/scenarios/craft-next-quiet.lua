-- Craft next with nothing craftable: a chat line, no sound (user,
-- 2026-10-25: chat and the Craft button already say why)
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
-- Azeroot Tea x4 with no Azeroot anywhere
local AZEROOT = 236774
db.queues = { ["Mysticmead-Sargeras"] = { { recipeID = 1226197, quantity = 4, made = 0, added = os.time() } } }
db.inMail["Mysticmead-Sargeras"] = {}
for _, c in pairs(db.characters) do
    for _, held in ipairs({ c.stock or {}, c.stockBank or {} }) do held[AZEROOT], held[AZEROOT + 1] = nil, nil end
end
if db.warbandStock then db.warbandStock[AZEROOT], db.warbandStock[AZEROOT + 1] = nil, nil end
local addon = bench.Login("Mysticmead", { db = db })
bench.SetBags({ [AZEROOT] = nil, [AZEROOT + 1] = nil })
bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
bench.OpenProfession("Cooking")
bench.Chat()
bench.Calls()
addon:CraftNext()
bench.Check("says why in chat", #bench.Chat() > 0)
bench.HasNot("no sound", bench.Calls(), "PlaySound(")
bench.Done()
