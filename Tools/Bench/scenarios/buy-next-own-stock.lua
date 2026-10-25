-- Buy next for every queue, on a character holding what another's queue
-- needs: it should say to mail them, not buy more (OwnStockNote, Shop.lua;
-- 2026-10-24, Maddoxynn's 18 Azeroot for Mysticmead)
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT = 236774
local AZEROOT_TEA = 1226197

local db = bench.LoadSaved()
db.settings.buyFor = "all"
db.queues["Maddoxynn-Sargeras"] = {}
db.queues["Mysticmead-Sargeras"] = { { recipeID = AZEROOT_TEA, quantity = 8, made = 0, added = os.time() } }
db.characters["Mysticmead-Sargeras"].stock[AZEROOT] = nil
db.characters["Mysticmead-Sargeras"].stock[AZEROOT + 1] = nil

local addon = bench.Login("Maddoxynn", { db = db })
bench.SetBags({ [AZEROOT] = 18, [AZEROOT + 1] = nil })
bench.OpenAH()
local screen = bench.Screen()
bench.Show(screen)
bench.Has("Buy next shows", screen, "BUY NEXT")
bench.Has("the list says whose it is", screen, "Mysticmead")
bench.Has("says to mail your own instead", screen, "You have 18 Azeroot: mail")
bench.Done()
