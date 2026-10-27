-- Selling a crafting order's reward: its cost is what the order counted
-- it at (in the order's profit already), so the sale's profit is only
-- what it sold for over that, and it's in the mail's total. A
-- Void-Touched Augment Rune sold for 1,115.92g read "no cost" and was
-- left out; the newest orders counted each at 389.46g (user, 2026-10-27). Sales
-- saved before get that cost once at login.
local bench = dofile(BENCH_DIR .. "bench.lua")
local RUNE = "Void-Touched Augment Rune"
local db = bench.LoadSaved()
local counted
for _, lot in ipairs(db.orderCrafts or {}) do
    for _, r in ipairs(lot.rewards or {}) do
        -- The newest: a sale takes the newest rewards first
        if r.itemID == 259085 and (r.value or 0) > 0 then counted = r.value / r.count end
    end
end
bench.Check("an order counted a rune (what this tests)", counted ~= nil)
counted = counted or 0
-- A rune sale saved with no cost, as before this change
db.rewardSalesRepaired = nil
table.insert(db.entries, { id = -1, type = "REVENUE", item = RUNE, quantity = 1, totalCopper = bench.Gold(1115.93),
    timestamp = os.time() - 60, profession = "Unassigned", character = "Maddoxynn", realm = "Sargeras" })
local addon = bench.Login("Maddoxynn", { db = db })
local repaired
for _, e in ipairs(addon.ledger:getAll()) do
    if e.id == -1 then repaired = e end
end
bench.Equal("old sale: the order's value as its cost", repaired and repaired.costSource, "reward")
bench.Near("old sale: the newest order's value", repaired and repaired.costBasis or 0, counted, 1)

local cost, _, source = addon:GetUnitCostBasis(RUNE, 1)
bench.Equal("a rune's cost source", source, "reward")
bench.Near("a rune costs what the order counted", cost or 0, counted, 1)

-- Two sales at the mailbox: the rune's line is its profit over that, and
-- the total counts it
bench.world.inbox = {}
for _, s in ipairs({ { RUNE, 1, 1115.92 }, { "Light's Potential", 1, 100 } }) do
    table.insert(bench.world.inbox, { sender = "Auction House", subject = "Auction successful", money = bench.Gold(s[3]),
        invoice = { type = "seller", item = s[1], bid = bench.Gold(s[3]), count = s[2] } })
end
bench.OpenMail()
bench.Chat()
local seen = {}
for i = 1, 2 do
    TakeInboxMoney(i)
    local money = bench.world.inbox[i].money
    bench.world.inbox[i].money = 0
    bench.SetMoney(GetMoney() + money)
    bench.Advance(2)
    for _, l in ipairs(bench.Chat()) do table.insert(seen, l) end
end
-- The rune's sale in History: its profit over what the order counted
local runeSale
for _, e in ipairs(addon.ledger:getAll()) do
    if e.type == "REVENUE" and e.item == RUNE and e.totalCopper == bench.Gold(1115.92) and e.quantity == 1 and e.id ~= -1 then runeSale = e end
end
bench.Equal("rune sale costed as a reward", runeSale and runeSale.costSource, "reward")
bench.Near("rune sale's profit: over the order's value", runeSale and (runeSale.totalCopper - runeSale.costBasis) or 0,
    bench.Gold(1115.92) - counted, 1)

-- An old sale takes the orders finished before it, not later ones; a
-- sale from before any order Goldsmith saw a rune from keeps no cost
local function NewestBefore(t)
    local value
    for _, lot in ipairs(GoldsmithDB.orderCrafts or {}) do
        if (lot.time or 0) <= t then
            for _, r in ipairs(lot.rewards or {}) do if r.itemID == 259085 then value = r.value / r.count end end
        end
    end
    return value
end
local checked = 0
for _, e in ipairs(addon.ledger:getAll()) do
    if e.type == "REVENUE" and e.item == RUNE and e.id ~= -1 and e.quantity == 1 then
        local want = NewestBefore(e.timestamp)
        if want then
            checked = checked + 1
            bench.Near("sale " .. date("%m-%d %H:%M", e.timestamp) .. ": a rune counted before it", e.costBasis or 0, want, 1)
        else
            bench.Equal("sale " .. date("%m-%d %H:%M", e.timestamp) .. ": no order before it, no cost", e.costBasis, nil)
        end
    end
end
bench.Check("old sales to check", checked > 0)
bench.Done()
