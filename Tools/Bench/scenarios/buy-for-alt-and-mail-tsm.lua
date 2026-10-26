-- The same with TSM's mailbox, which hides the game's MailFrame and shows its
-- own window (2026-10-24: the panel showed nothing). Then: Buy next on a bank
-- alt for another character's queue, then the mailbox
-- panel mails it over: buy, "Mail N X to Y" after "Bought", the item kept
-- for them, the panel fills in and sends the mail, their plan then counts it
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT = 236774
local AZEROOT_TEA = 1226197

local db = bench.LoadSaved()
db.settings.buyFor = "all"
-- Only Mysticmead's queue, whatever else is queued in the saved data
db.queues = {}
db.queues["Mysticmead-Sargeras"] = { { recipeID = AZEROOT_TEA, quantity = 8, made = 0, added = os.time() } }
local myst = db.characters["Mysticmead-Sargeras"]
myst.stock[AZEROOT], myst.stock[AZEROOT + 1] = nil, nil
-- The tea's Mana-Wyrm Essence held, whatever the saved data says now
myst.stock[242644] = 20
-- Tea sells well, whatever today's prices: a losing craft would stop Buy next
db.ownScan.prices[db.recipes[AZEROOT_TEA].outputItemID] = { 50 * 10000 }
db.searchPrices = {}
db.inMail["Mysticmead-Sargeras"] = {}

-- TSM installed, its mailbox window up instead of the game's
local tsmMail = false
TSM_API = { IsUIVisible = function(ui) return ui == "MAILING" and tsmMail end }
local addon = bench.Login("Maddoxynn", { db = db })
-- None held anywhere, whatever the last login saved
bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
bench.SetBags({ [AZEROOT] = nil, [AZEROOT + 1] = nil })
bench.OpenAH()
bench.Has("Buy next names the item", bench.Screen(), "Buy 8 Azeroot")

-- Click 1: asks the AH for the price
bench.Click("Buy 8 Azeroot")
bench.Has("asks the AH for 8", bench.Calls(), "StartCommoditiesPurchase(236774, 8)")
-- Under the plan's 19.89g each: bought without a second click
bench.QuotePrice(AZEROOT, bench.Gold(19), 8)
bench.Has("confirms at once under plan", bench.Calls(), "ConfirmCommoditiesPurchase(236774, 8)")
bench.PurchaseSucceeds(AZEROOT, 8, bench.Gold(19) * 8)

local chat = bench.Chat()
bench.Show(chat, "chat")
local bought, mail
for i, line in ipairs(chat) do
    if line:find("Bought Azeroot x8", 1, true) then bought = i end
    if line:find("Mail 8 Azeroot to Mysticmead", 1, true) then mail = i end
end
bench.Check("Bought line", bought ~= nil)
bench.Check("Mail line", mail ~= nil)
bench.Check("Mail line after Bought", bought and mail and mail > bought)
local kept = GoldsmithDB.boughtFor["Mysticmead-Sargeras"] and GoldsmithDB.boughtFor["Mysticmead-Sargeras"][AZEROOT]
bench.Equal("kept for Mysticmead", kept and kept.quantity, 8)
bench.Has("nothing left to buy, the purchase in the mail", bench.Screen(), "Nothing left to buy. In your mailbox: 8x Azeroot.")
bench.CloseAH()

-- The mailbox: the purchase is there; take it, then mail it on
bench.OpenMail()
tsmMail = true
MailFrame:Hide()
bench.Advance(2)
bench.TakeMail()
local screen = bench.Screen()
-- Other things their queue would buy may be listed too (what you hold today)
bench.Has("mail panel lists it", screen, "8 Azeroot")
bench.Click("Fill in a mail to Mysticmead")
local att
for _, a in pairs(bench.world.sendItems) do if a[1] == AZEROOT then att = a end end
bench.Check("8 Azeroot attached", att and att[2] == 8, att and ("x" .. att[2]) or "no Azeroot attached")
bench.Click("Send to Mysticmead")
bench.Advance(2)
bench.Has("mail sent", bench.Calls(), "SendMail(Mysticmead")
local book = GoldsmithDB.inMail["Mysticmead-Sargeras"][AZEROOT]
bench.Equal("now in their mail", book and book.quantity, 8)
local left = GoldsmithDB.boughtFor["Mysticmead-Sargeras"] and GoldsmithDB.boughtFor["Mysticmead-Sargeras"][AZEROOT]
bench.Check("no longer waiting to be mailed", not left or (left.quantity or 0) == 0)
bench.HasNot("panel gone once sent", bench.Screen(), "Fill in a mail to Mysticmead")

-- Their queue, planned from here, now buys nothing
local plan = addon:BuildQueue("Mysticmead-Sargeras")
bench.Equal("Mysticmead's queue buys nothing", #plan.buyAH, 0)
bench.Done()
