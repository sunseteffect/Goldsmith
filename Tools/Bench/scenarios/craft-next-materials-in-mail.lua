-- Craft next when the materials Buy next bought are still in the mailbox:
-- it says so instead of a bare "Missing" (error review #7), and plays the
-- stop sound
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT, TEA = 236774, 1226197
local db = bench.LoadSaved()
db.queues["Mysticmead-Sargeras"] = { { recipeID = TEA, quantity = 8, made = 0, added = os.time() } }
-- 8 Azeroot bought with Buy next, not taken from the mailbox yet
db.inMail["Mysticmead-Sargeras"] = { [AZEROOT] = { quantity = 8, last = 0, time = os.time() } }
local myst = db.characters["Mysticmead-Sargeras"]
myst.stock[AZEROOT], myst.stock[AZEROOT + 1] = nil, nil
local addon = bench.Login("Mysticmead", { db = db })
bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
bench.SetBags({ [AZEROOT] = nil, [AZEROOT + 1] = nil })

bench.OpenProfession("Cooking")
bench.Chat()
bench.Calls()
addon:CraftNext()
bench.Advance(1)
local chat = bench.Chat()
bench.Show(chat, "chat")
bench.Has("says they're in the mailbox", chat, "in your mailbox")
bench.HasNot("crafts nothing", bench.Calls(), "CraftRecipe(")
bench.Done()
