-- Buy next for every queue, on a character holding what another's queue
-- needs: what you hold counts, so nothing more is bought, and the mailbox
-- panel says to mail it (2026-10-24, Maddoxynn's 18 Azeroot for
-- Mysticmead; counted since 2026-10-27, buy-for-alt-own-stock)
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT = 236774
local AZEROOT_TEA = 1226197

local db = bench.LoadSaved()
db.settings.buyFor = "all"
db.queues = {}
db.queues["Mysticmead-Sargeras"] = { { recipeID = AZEROOT_TEA, quantity = 8, made = 0, added = os.time() } }
db.characters["Mysticmead-Sargeras"].stock[AZEROOT] = nil
db.characters["Mysticmead-Sargeras"].stock[AZEROOT + 1] = nil
db.inMail["Mysticmead-Sargeras"] = {}
db.inMail["Maddoxynn-Sargeras"] = {}
db.boughtFor = {}

bench.Login("Maddoxynn", { db = db })
bench.SetBags({ [AZEROOT] = 18, [AZEROOT + 1] = 0 })
bench.OpenAH()
local screen = bench.Screen()
bench.Show(screen)
bench.Has("Buy next shows", screen, "BUY NEXT")
bench.HasNot("no Azeroot bought: yours cover it", screen, "Azeroot")
bench.CloseAH()
bench.OpenMail()
bench.Has("mailbox panel: mail 8", bench.Screen(), "8 Azeroot")
bench.Done()
