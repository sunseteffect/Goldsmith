-- With TSM's mailbox the game's send window is hidden, so the panel shows
-- what the mail holds after Fill, read back from the game (user,
-- 2026-10-24: "i cant verify anything before i send"); right-click takes
-- the items out again. Closing TSM's window hides the panel at once.
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT = 236774
local db = bench.LoadSaved()
db.queues["Mysticmead-Sargeras"] = { { recipeID = 1226197, quantity = 8, made = 0, added = os.time() } }
db.boughtFor["Mysticmead-Sargeras"] = { [AZEROOT] = { quantity = 8, holder = "Maddoxynn-Sargeras", time = os.time() } }
local tsmMail = true
TSM_API = { IsUIVisible = function(ui) return ui == "MAILING" and tsmMail end }
bench.Login("Maddoxynn", { db = db })
bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
bench.SetBags({ [AZEROOT] = 8, [AZEROOT + 1] = 0 })

bench.OpenMail()
MailFrame:Hide()
bench.Advance(1)
bench.HasNot("nothing shown as in the mail yet", bench.Screen(), "In the mail now")
bench.Click("Fill in a mail to Mysticmead")
local screen = bench.Screen()
bench.Has("shows what the mail holds", screen, "In the mail now: 8 Azeroot")
bench.Has("ready to send", screen, "Send to Mysticmead")

-- Changed your mind: right-click takes them out
bench.Click("Send to Mysticmead", "RightButton")
bench.Advance(1)
bench.Equal("attachments taken out", next(bench.world.sendItems), nil)
bench.HasNot("no longer shown as in the mail", bench.Screen(), "In the mail now")
bench.Has("back to filling in", bench.Screen(), "Fill in a mail to Mysticmead")
bench.HasNot("nothing sent", bench.Calls(), "SendMail(")

-- Fill again and send
bench.Click("Fill in a mail to Mysticmead")
bench.Click("Send to Mysticmead")
bench.Advance(2)
bench.Has("sent", bench.Calls(), "SendMail(Mysticmead")

-- Closing TSM's window hides the panel on the next frame
tsmMail = false
bench.Advance(0.1)
bench.HasNot("hidden at once when TSM's window closes", bench.Screen(), "GOLDSMITH: MAIL")
bench.Done()
