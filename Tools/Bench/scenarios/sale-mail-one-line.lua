-- Collecting an AH sale from the mail says one line: the item and the
-- gold it brought in, no quantity or cost; then, once no sale is left in
-- the mailbox, the total. What it sold for, not profit: a chat line can't
-- explain profit, History does (user, 2026-10-27: "its too much text";
-- "a can of worms of complexity and questions and confusion").
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local function Mail(sales)
    bench.world.inbox = {}
    for _, s in ipairs(sales) do
        table.insert(bench.world.inbox, { sender = "Auction House", subject = "Auction successful", money = bench.Gold(s[3]),
            invoice = { type = "seller", item = s[1], bid = bench.Gold(s[3]), count = s[2] } })
    end
    bench.OpenMail()
    bench.Advance(2)
end
local function Take(i)
    TakeInboxMoney(i)
    local money = bench.world.inbox[i].money
    bench.world.inbox[i].money = 0
    bench.SetMoney(GetMoney() + money)
    bench.Advance(1)
end

-- One sale: its line, no total
Mail({ { "Light's Potential", 5, 491.97 } })
local chat = bench.Chat()
bench.HasNot("opening says nothing about sales", chat, "AH sale", true)
Take(1)
bench.Advance(2)
chat = bench.Chat()
bench.Has("item and what it sold for", chat, "Sold Light's Potential: 491.97g", true)
bench.HasNot("no quantity", chat, "x5", true)
bench.HasNot("no cost", chat, "Cost you", true)
bench.HasNot("one sale: no total", chat, "Total:", true)
bench.CloseMail()
bench.Chat()

-- Three sales, one with no cost known: every line is gold in, then the total
Mail({ { "Light's Potential", 2, 200 }, { "Light's Potential", 1, 100 }, { "Zzz Bench Widget", 1, 5 } })
bench.Chat()
local seen = {}
for i = 1, 3 do
    Take(i)
    for _, l in ipairs(bench.Chat()) do table.insert(seen, l) end
    if i == 2 then bench.HasNot("no total while sales are left", seen, "Total:", true) end
end
bench.Advance(2)
for _, l in ipairs(bench.Chat()) do table.insert(seen, l) end
bench.Has("no cost known: still what it sold for", seen, "Sold Zzz Bench Widget: 5.00g", true)
bench.Has("the total", seen, "Total: 305.00g", true)
bench.HasNot("no profit in chat", seen, "profit", true)
local totals = 0
for _, line in ipairs(seen) do if line:find("Total:", 1, true) then totals = totals + 1 end end
bench.Equal("one total", totals, 1)
bench.CloseMail()
bench.HasNot("closing doesn't repeat it", bench.Chat(), "Total:", true)

-- History still keeps each sale's profit
local sale
for _, e in ipairs(addon.ledger:getAll()) do
    if e.type == "REVENUE" and e.item == "Light's Potential" then sale = e end
end
bench.Check("History has the sale's cost", sale and sale.costBasis ~= nil)
bench.Done()
