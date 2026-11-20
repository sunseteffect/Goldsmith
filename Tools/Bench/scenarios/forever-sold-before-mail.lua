-- Forever: a sale counts toward how fast an item sells from the moment
-- the game says "A buyer has been found for your auction of X", not when
-- the gold is taken from the mail an hour or a night later. 3 Big Bronze
-- Knives gone with the gold in the mail read "only 1 of your last 3
-- sold", so the next batch was 1 (user, 2026-11-18). Taken mail sales
-- count from when the mail came (soldAt), not when it was opened.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
WOW_PROJECT_ID = 18
local SOLD = Enum.AuctionHouseNotification.AuctionSold
local function Sold(name) bench.Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", SOLD, name, 1) end
local addon = bench.Login("Mysticmead", { db = db })
local ID, NAME = 990901, "Test Bench Blade"
bench.AddItem(ID, NAME)
local t0 = time()
GoldsmithDB.craftLots = GoldsmithDB.craftLots or {}
GoldsmithDB.craftLots[ID] = { { time = t0, qty = 3, name = NAME, unitCost = 1000 } }
GoldsmithDB.ahSoldPending = nil
addon:DataChanged()
local _, before = addon:SuggestedQuantity(NAME, nil)
bench.Has("nothing sold yet: a first batch", before, "first batch", true)

-- Half an hour later all 3 sell; the gold is still on its way
bench.world.baseTime = bench.world.baseTime + 1800
for _ = 1, 3 do Sold(NAME) end
-- Other notifications and the chat line are not sales
bench.Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", Enum.AuctionHouseNotification.AuctionExpired, NAME, 2)
bench.Fire("CHAT_MSG_SYSTEM", "A buyer has been found for your auction of " .. NAME .. ".")
bench.Fire("CHAT_MSG_SYSTEM", "Some other system message.")
bench.Equal("3 pending", #addon:GetPendingSales(), 3)
local make, why = addon:SuggestedQuantity(NAME, nil)
bench.Has("counts as sold out", why, "your last 3 sold out", true)
bench.Check("so more next time", make > 3, make)

-- Mail taken the next morning: the sales from when the mail came
local soldAt = time() + 3600
bench.world.baseTime = bench.world.baseTime + 10 * 3600
for _ = 1, 3 do
    addon.ledger:addRevenue("Unassigned", NAME, 1, 5000, 3000, false, 0, "crafted", ID, { soldAt = soldAt })
end
addon:ClearPendingSale(NAME, 3)
addon:DataChanged()
bench.Equal("mail taken: none pending", #addon:GetPendingSales(), 0)
local make2, why2 = addon:SuggestedQuantity(NAME, nil)
bench.Has("still sold out fast", why2, "sold out in 2 hours", true)
bench.Equal("same batch as before the mail", make2, make)

-- Mail for a sale never seen as pending (sold while logged off) leaves a
-- later pending sale alone (Truesilver Rod, 2026-11-18)
Sold(NAME)
local pendingAt = time()
addon.ledger:addRevenue("Unassigned", NAME, 1, 5000, 3000, false, 0, "crafted", ID, { soldAt = pendingAt - 3600 })
addon:ClearPendingSale(NAME, 1, pendingAt - 3600)
bench.Equal("older mail: still pending", #addon:GetPendingSales(), 1)
addon:ClearPendingSale(NAME, 1, pendingAt + 60)
bench.Equal("its own mail: cleared", #addon:GetPendingSales(), 0)

-- The mail opened hours later reads a full 30 days left: the sale keeps
-- the time it sold, not when the mail was opened (Heavy Weightstone sold
-- 17:06, saved as 00:45; 2026-11-19)
local ID2, NAME2 = 990902, "Test Bench Stone"
bench.AddItem(ID2, NAME2)
GoldsmithDB.craftLots[ID2] = { { time = time(), qty = 1, name = NAME2, unitCost = 1000 } }
addon:RecipesSwapped() -- rebuild the craft index after setting lots by hand
bench.world.baseTime = bench.world.baseTime + 1800
Sold(NAME2)
bench.world.baseTime = bench.world.baseTime + 8 * 3600
bench.world.inbox = { { sender = "Auction House", subject = "Auction successful", money = 5000,
    invoice = { type = "seller", item = NAME2, bid = 5000, count = 1 } } }
bench.OpenMail()
TakeInboxMoney(1)
bench.world.inbox[1].money = 0
bench.SetMoney(GetMoney() + 5000)
bench.Advance(3)
bench.CloseMail()
addon:DataChanged()
bench.Equal("its mail taken: none pending", #addon:GetPendingSales(), 0)
local _, why3 = addon:SuggestedQuantity(NAME2, nil)
bench.Has("sold within the hour, not 8 hours later", why3, "sold out in 1 hour", true)

-- A stack of 10 posted as one auction sells whole: one notice, 10 sold
-- (Solid Sharpening Stone counted as 1, "a batch of 1"; 2026-11-19)
local ID3, NAME3 = 990903, "Test Bench Whetstone"
bench.AddItem(ID3, NAME3)
GoldsmithDB.craftLots[ID3] = { { time = time(), qty = 10, name = NAME3, unitCost = 100 } }
addon:RecipesSwapped()
bench.world.ownedAuctions = { { auctionID = 77, itemKey = { itemID = ID3 }, quantity = 10,
    status = Enum.AuctionStatus.Active } }
bench.Fire("OWNED_AUCTIONS_UPDATED")
bench.world.baseTime = bench.world.baseTime + 600
bench.Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", SOLD, NAME3, 77)
local pend = addon:GetPendingSales()
bench.Equal("one notice, the whole stack", pend[#pend] and pend[#pend].qty, 10)
addon:DataChanged()
local make4, why4 = addon:SuggestedQuantity(NAME3, nil)
bench.Has("the stack sold out", why4, "your last 10 sold out", true)
bench.Check("more than 10 next", make4 > 10, make4)
-- Its mail: 10 taken, nothing left pending
addon:ClearPendingSale(NAME3, 10, time())
bench.Equal("stack's mail: none pending", #addon:GetPendingSales(), 0)

-- Sold is no longer on the AH: off the count at the notice, not the mail,
-- and the mail doesn't take it off again (Inlaid Mithril Cylinder read
-- "1 on the AH" after it sold, so Make waited; 2026-11-19)
local ID4, NAME4 = 990904, "Test Bench Cylinder"
bench.AddItem(ID4, NAME4)
bench.world.ownedAuctions = {
    { auctionID = 81, itemKey = { itemID = ID4 }, quantity = 1, status = Enum.AuctionStatus.Active },
    { auctionID = 82, itemKey = { itemID = ID4 }, quantity = 1, status = Enum.AuctionStatus.Active },
}
bench.Fire("OWNED_AUCTIONS_UPDATED")
bench.Equal("2 listed", addon.char.auctions[ID4], 2)
bench.Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", SOLD, NAME4, 81)
bench.Equal("one sold: 1 listed", addon.char.auctions[ID4], 1)
bench.Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", SOLD, NAME4, 81)
bench.Equal("the same notice twice: still 1", addon.char.auctions[ID4], 1)
GoldsmithDB.ahSoldPending[#GoldsmithDB.ahSoldPending] = nil
bench.world.baseTime = bench.world.baseTime + 3600
bench.world.inbox = { { sender = "Auction House", subject = "Auction successful", money = 5000,
    invoice = { type = "seller", item = NAME4, bid = 5000, count = 1 } } }
bench.OpenMail()
TakeInboxMoney(1)
bench.world.inbox[1].money = 0
bench.SetMoney(GetMoney() + 5000)
bench.Advance(3)
bench.CloseMail()
bench.Equal("its mail: the other still listed", addon.char.auctions[ID4], 1)
-- The list read with both sold, then the second one's notice: nothing more off
for _, a in ipairs(bench.world.ownedAuctions) do a.status = Enum.AuctionStatus.Sold end
bench.Fire("OWNED_AUCTIONS_UPDATED")
bench.Equal("list read: none listed", addon.char.auctions[ID4], nil)
bench.Fire("AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", SOLD, NAME4, 82)
bench.Equal("its notice after: no error, none listed", addon.char.auctions[ID4], nil)
GoldsmithDB.ahSoldPending = nil

-- Not on retail: the message is ignored there
addon.isForever = false
Sold(NAME)
bench.Equal("retail: not counted", #addon:GetPendingSales(), 0)
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
