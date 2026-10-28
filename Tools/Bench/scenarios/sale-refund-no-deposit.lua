-- A sale of something posted before Goldsmith recorded its deposit: the
-- deposit refund in the mail isn't income, since the deposit was never
-- counted as a cost (stress test, 2026-10-21: a 1s refund made a losing
-- sale look 1s better). With the deposit on record, the refund still counts.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local function Sell(item, bid, deposit, fee)
    bench.world.inbox = { { sender = "Auction House", subject = "Auction successful",
        money = bid + deposit - fee,
        invoice = { type = "seller", item = item, bid = bid, count = 1, deposit = deposit, fee = fee } } }
    bench.OpenMail()
    bench.Advance(2)
    TakeInboxMoney(1)
    local money = bench.world.inbox[1].money
    bench.world.inbox[1].money = 0
    bench.SetMoney(GetMoney() + money)
    bench.Advance(3)
    bench.CloseMail()
    local entries = GoldsmithDB.entries
    return entries[#entries]
end

-- Never posted with Goldsmith
local e = Sell("Zzz Bench Widget", bench.Gold(10), bench.Gold(1), bench.Gold(0.5))
bench.Check("sale recorded", e and e.type == "REVENUE" and e.item == "Zzz Bench Widget")
bench.Equal("no refund counted", e and e.totalCopper, bench.Gold(9.5))
bench.Equal("refund saved as 0", e and e.depositRefund, 0)

-- Posted with Goldsmith: the deposit is a cost, so the refund is income
addon.ledger:addCost("Unassigned", "Zzz Bench Gadget", 1, bench.Gold(1), "DEPOSIT")
e = Sell("Zzz Bench Gadget", bench.Gold(10), bench.Gold(1), bench.Gold(0.5))
bench.Equal("refund counted with a deposit on record", e and e.totalCopper, bench.Gold(10.5))
bench.Done()
