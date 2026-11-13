-- A buyout missed when it was made is recorded from its "Auction won"
-- mail when you take the item out. A Beaded Orb of Arcane Wrath from Buy
-- to vendor left no purchase, so no cost in its tooltip (user, Forever,
-- 2026-11-13). One already recorded isn't recorded twice.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local world = bench.world
local ORB, AXE = 990030, 990031
bench.AddItem(ORB, "Bench Orb of the Owl", { sellPrice = 425, stack = 1 })
bench.AddItem(AXE, "Bench Axe", { sellPrice = 500, stack = 1 })

local function Purchases(name)
    local list = {}
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "COST" and e.kind == "PURCHASE" and e.item == name then list[#list + 1] = e end
    end
    return list
end
local function WonMail(itemID, name, bid)
    return { sender = "Auction House", subject = "Auction won: " .. name, items = { { itemID, 1 } },
        invoice = { type = "buyer", item = name, bid = bid, count = 1 } }
end

bench.OpenMail()
bench.Chat()

-- Missed: recorded when taken, once
world.inbox = { WonMail(ORB, "Bench Orb of the Owl", 400) }
TakeInboxItem(1, 1)
AutoLootMailItem(1)
local orb = Purchases("Bench Orb of the Owl")
bench.Equal("missed buy: recorded once", #orb, 1)
bench.Equal("what it cost", orb[1] and orb[1].totalCopper, 400)
bench.Equal("its item", orb[1] and orb[1].itemID, ORB)
bench.Has("said in chat", bench.Chat(), "Bought Bench Orb of the Owl", true)

-- Recorded when bought: not again
addon.ledger:addCost("Unassigned", "Bench Axe", 1, 500, "PURCHASE", AXE)
world.inbox = { WonMail(AXE, "Bench Axe", 500) }
TakeInboxItem(1, 1)
bench.Equal("recorded buy: not twice", #Purchases("Bench Axe"), 1)
bench.HasNot("nothing said", bench.Chat(), "Bought Bench Axe", true)

-- Two bought and recorded, three won mails (each new: a day apart): the
-- third is the missed one
addon.ledger:addCost("Unassigned", "Bench Axe", 1, 300, "PURCHASE", AXE)
world.inbox = { WonMail(AXE, "Bench Axe", 300) }
TakeInboxItem(1, 1)
bench.Equal("second recorded: still 2", #Purchases("Bench Axe"), 2)
world.inbox = { WonMail(AXE, "Bench Axe", 300) }
local header = GetInboxHeaderInfo
GetInboxHeaderInfo = function(i) local r = { header(i) } r[7] = 29 return unpack(r) end
TakeInboxItem(1, 1)
GetInboxHeaderInfo = header
bench.Equal("third mail, none left to match: recorded", #Purchases("Bench Axe"), 3)

-- A stack bought at once can come in several mails: covered by quantity
addon.ledger:addCost("Unassigned", "Bench Orb of the Owl", 5, 2000, "PURCHASE", ORB)
for _, bid in ipairs({ 800, 1200 }) do
    world.inbox = { WonMail(ORB, "Bench Orb of the Owl", bid) }
    world.inbox[1].invoice.count = bid == 800 and 2 or 3
    TakeInboxItem(1, 1)
end
bench.Equal("a stack in two mails: not recorded again", #Purchases("Bench Orb of the Owl"), 2)

-- Your sale mail isn't a buy
world.inbox = { { sender = "Auction House", subject = "Auction successful", money = 950,
    invoice = { type = "seller", item = "Bench Orb of the Owl", bid = 1000, count = 1 } } }
TakeInboxItem(1, 1)
bench.Equal("a sale isn't a buy", #Purchases("Bench Orb of the Owl"), 2)
bench.CloseMail()
bench.Done()
