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

-- A total after the lines: once no sale is left in the mailbox, the sum
-- of the profits, the one with no cost not counted (user, 2026-10-27)
bench.HasNot("one sale at a time: no total", chat, "Total profit", true)
bench.CloseMail()
bench.world.inbox = {}
for _, s in ipairs({ { "Light's Potential", 2, 200 }, { "Light's Potential", 1, 100 }, { "Zzz Bench Widget", 1, 5 } }) do
    table.insert(bench.world.inbox, { sender = "Auction House", subject = "Auction successful", money = bench.Gold(s[3]),
        invoice = { type = "seller", item = s[1], bid = bench.Gold(s[3]), count = s[2] } })
end
bench.OpenMail()
bench.Chat()
local profits, seen = 0, {}
for i = 1, 3 do
    TakeInboxMoney(i)
    local money = bench.world.inbox[i].money
    bench.world.inbox[i].money = 0
    bench.SetMoney(GetMoney() + money)
    bench.Advance(1)
    local lines = bench.Chat()
    for _, l in ipairs(lines) do table.insert(seen, l) end
    if i == 2 then bench.HasNot("no total while sales are left", seen, "Total profit", true) end
end
bench.Advance(2)
for _, l in ipairs(bench.Chat()) do table.insert(seen, l) end
chat = seen
for _, line in ipairs(chat) do
    local sign, g = line:match("Sold Light's Potential: ([+-])([%d.]+)g")
    if g then profits = profits + (sign == "-" and -1 or 1) * tonumber(g) end
end
bench.Has("the total, the uncosted one left out", chat,
    string.format("Total profit: %s%.2fg (1 with no cost not counted)", profits >= 0 and "+" or "-", math.abs(profits)), true)
local totals = 0
for _, line in ipairs(chat) do if line:find("Total profit", 1, true) then totals = totals + 1 end end
bench.Equal("one total", totals, 1)
bench.CloseMail()
bench.HasNot("closing doesn't repeat it", bench.Chat(), "Total profit", true)
bench.Done()
