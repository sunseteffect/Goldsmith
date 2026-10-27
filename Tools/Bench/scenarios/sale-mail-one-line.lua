-- Collecting an AH sale from the mail says one line: the item and its
-- profit, no quantity, price or cost (user, 2026-10-27: "just tell me the
-- profit"). With no cost known, what it sold for.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local function Sell(item, count, bid)
    bench.world.inbox = { { sender = "Auction House", subject = "Auction successful: " .. item, money = bid,
        invoice = { type = "seller", item = item, bid = bid, count = count } } }
    bench.OpenMail()
    bench.Chat()
    TakeInboxMoney(1)
    bench.SetMoney(GetMoney() + bid)
    bench.Advance(1)
    return bench.Chat()
end

local chat = Sell("Light's Potential", 5, bench.Gold(491.97))
bench.Has("item and profit", chat, "Sold Light.s Potential: [+-][%d.]+g", false)
bench.HasNot("one line, not two", chat, "  ", true)
bench.HasNot("no quantity", chat, "x5", true)
bench.HasNot("no cost line", chat, "Cost you", true)
bench.HasNot("no price each", chat, "each", true)

chat = Sell("Zzz Bench Widget", 1, bench.Gold(11.40))
bench.Has("no cost known: what it sold for", chat, "Sold Zzz Bench Widget for 11.40g", true)
bench.HasNot("no Unassigned note", chat, "Unassigned", true)
bench.Done()
