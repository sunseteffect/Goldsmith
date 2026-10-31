-- A queue already below zero (losing orders taken on purpose): a price a
-- little over plan is bought without asking, like any queue, and a bigger
-- one waits without the "puts the queue at" popup. 0.06g over on a -90g
-- patron order queue asked and popped up the loss (user, 2026-10-30).
-- A queue that made money still asks when the price takes it below zero.
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT, TEA = 236774, 1226197

local function Start(order, sellsFor)
    local db = bench.LoadSaved()
    db.settings.buyOver = 2
    db.settings.autoScan = false
    db.inMail["Mysticmead-Sargeras"] = {}
    db.queues = {}
    db.queues["Mysticmead-Sargeras"] = { { recipeID = TEA, quantity = 8, made = 0, added = os.time(), orderID = order } }
    if sellsFor then
        db.ownScan.prices[db.recipes[TEA].outputItemID] = { sellsFor }
        db.searchPrices, db.orderBooks = {}, {}
    end
    for _, c in pairs(db.characters) do
        for _, held in ipairs({ c.stock or {}, c.stockBank or {} }) do held[AZEROOT], held[AZEROOT + 1] = nil, nil end
    end
    if db.warbandStock then db.warbandStock[AZEROOT], db.warbandStock[AZEROOT + 1] = nil, nil end
    local addon = bench.Login("Mysticmead", { db = db })
    bench.world.bank[AZEROOT], bench.world.bank[AZEROOT + 1] = nil, nil
    bench.SetBags({ [AZEROOT] = 0, [AZEROOT + 1] = 0, [242644] = 20 })
    local plan = addon:BuildQueue("Mysticmead-Sargeras")
    return plan.profit, plan.rows[1].plan.buyAH[1].cost / 8
end

-- An order that loses gold: a little over plan buys on the first click
local profit, unit = Start(1, 1)
bench.Check("the order loses gold", profit < 0)
bench.OpenAH()
bench.Click("Buy 8 Azeroot")
bench.Calls()
bench.QuotePrice(AZEROOT, math.ceil(unit * 1.005), 8)
local calls = bench.Calls()
bench.Has("0.5% over: bought without asking", calls, "ConfirmCommoditiesPurchase(236774, 8)")
bench.HasNot("no raid warning", calls, "PlaySound(RAID_WARNING)")
bench.HasNot("no loss popup", calls, "RaidNotice")
bench.CloseAH()

-- Well over plan: waits for a click, says it's over, no loss popup
Start(1, 1)
bench.OpenAH()
bench.Click("Buy 8 Azeroot")
bench.Calls()
bench.QuotePrice(AZEROOT, math.ceil(unit * 1.2), 8)
calls = bench.Calls()
bench.HasNot("20% over: waits", calls, "Confirm")
bench.HasNot("no \"puts the queue at\" popup", calls, "puts the queue at")
bench.Has("says over plan", bench.Screen(), "over plan")
bench.CloseAH()

-- A queue that makes money (the tea at 40g): a price that takes it
-- below zero still asks. Not 100g: over 3x its usual 19.74g, the jump
-- check prices it at usual once there are 4 days of history (2026-10-30)
profit, unit = Start(nil, bench.Gold(40))
bench.Check("the queue makes money", profit > 0)
bench.OpenAH()
bench.Click("Buy 8 Azeroot")
bench.Calls()
bench.QuotePrice(AZEROOT, math.ceil(unit + (profit + 10000) / 8), 8)
calls = bench.Calls()
bench.HasNot("below zero: waits", calls, "Confirm")
bench.Has("loss popup", calls, "puts the queue at")
bench.Has("says the queue would lose", bench.Screen(), "Queue would lose")
bench.Done()
