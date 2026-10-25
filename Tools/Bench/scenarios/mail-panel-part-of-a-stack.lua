-- Mailing part of a stack: 3 Azeroot from a stack of 7 must put 3 in the
-- mail, not 7 (2026-10-24 in game: attached straight from a split, the
-- game puts in the whole stack). The split goes to an empty slot first.
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT = 236774
local db = bench.LoadSaved()
db.queues["Mysticmead-Sargeras"] = { { recipeID = 1226197, quantity = 8, made = 0, added = os.time() } }
db.boughtFor["Mysticmead-Sargeras"] = { [AZEROOT] = { quantity = 3, holder = "Maddoxynn-Sargeras", time = os.time() } }
local tsmMail = true
TSM_API = { IsUIVisible = function(ui) return ui == "MAILING" and tsmMail end }
bench.Login("Maddoxynn", { db = db })
bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
bench.world.stacks[AZEROOT] = { 7 }
bench.SetBags({ [AZEROOT] = 7, [AZEROOT + 1] = nil })

bench.OpenMail()
MailFrame:Hide()
bench.Advance(1)
bench.Click("Fill in a mail to Mysticmead", nil, 0)
bench.Has("says it's filling in while the split lands", bench.Screen(), "Filling in...")
bench.Advance(2)
local total = 0
for _, a in pairs(bench.world.sendItems) do if a[1] == AZEROOT then total = total + a[2] end end
bench.Equal("3 Azeroot in the mail, not the stack of 7", total, 3)
bench.Has("panel says 3 are in the mail", bench.Screen(), "In the mail now: 3 Azeroot")
bench.Click("Send to Mysticmead")
bench.Advance(2)
bench.Equal("4 left in the bags", bench.world.bags[AZEROOT], 4)
local book = GoldsmithDB.inMail["Mysticmead-Sargeras"][AZEROOT]
bench.Equal("3 counted as in their mail", book and book.quantity, 3)
bench.Done()
