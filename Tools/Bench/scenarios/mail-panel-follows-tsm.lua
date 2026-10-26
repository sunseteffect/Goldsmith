-- The mailbox panel with TSM's mailbox: closing TSM's window hides it (you
-- stay at the mailbox, so no MAIL_CLOSED; user, 2026-10-24: "the mail
-- screen didn't go away after i closed tsm mail"), and TSM's switch button
-- swapping to the game's window and back keeps it showing
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT = 236774
local db = bench.LoadSaved()
db.queues["Mysticmead-Sargeras"] = { { recipeID = 1226197, quantity = 8, made = 0, added = os.time() } }
db.boughtFor["Mysticmead-Sargeras"] = { [AZEROOT] = { quantity = 8, holder = "Maddoxynn-Sargeras", time = os.time() } }
local tsmMail = false
TSM_API = { IsUIVisible = function(ui) return ui == "MAILING" and tsmMail end }
bench.Login("Maddoxynn", { db = db })
bench.SetBags({ [AZEROOT] = 8 })

local function Shown() return #bench.Screen() > 0 and table.concat(bench.Screen(), "\n"):find("GOLDSMITH: MAIL", 1, true) ~= nil end

-- TSM opens its window instead of the game's
tsmMail = true
bench.OpenMail()
MailFrame:Hide()
bench.Advance(2)
bench.Check("shows with TSM's mailbox", Shown())
-- Switch to the game's window, then back
tsmMail = false
MailFrame:Show()
bench.Advance(1)
bench.Check("shows after switching to the game's mailbox", Shown())
MailFrame:Hide()
tsmMail = true
bench.Advance(1)
bench.Check("shows after switching back to TSM's", Shown())
-- TSM's window closed, still at the mailbox
tsmMail = false
bench.Advance(1)
bench.Check("hides when TSM's window closes", not Shown())
-- Open again (TSM's minimap or /tsm mail)
tsmMail = true
bench.Advance(1)
bench.Check("back when TSM's window opens again", Shown())
bench.CloseMail()
tsmMail = false
bench.Check("hides when you leave the mailbox", not Shown())
bench.Done()
