-- A craft queued while it made gold that's a loss now (its price fell):
-- the row says "Now a loss", and Craft next asks once (chat, raid warning)
-- before crafting it. One queued at a loss on purpose isn't flagged (user,
-- 2026-11-09: 2 Woolen Bags made at -4s 39c each, queued at 15s).
-- Setup as craft-no-quality-picked-tier (Azeroot Tea, gold Azeroot held).
local bench = dofile(BENCH_DIR .. "bench.lua")
local AZEROOT, GOLD_AZEROOT, TEA = 236774, 236775, 1226197

local sellsFor
local function Start(price)
    local db = bench.LoadSaved()
    db.settings.autoScan = false
    db.queues = { ["Mysticmead-Sargeras"] = { { recipeID = TEA, quantity = 4, made = 0, added = os.time() } } }
    db.inMail["Mysticmead-Sargeras"] = {}
    for _, c in pairs(db.characters) do
        for _, held in ipairs({ c.stock or {}, c.stockBank or {} }) do held[AZEROOT], held[GOLD_AZEROOT] = nil, nil end
    end
    if db.warbandStock then db.warbandStock[AZEROOT], db.warbandStock[GOLD_AZEROOT] = nil, nil end
    local addon = bench.Login("Mysticmead", { db = db })
    bench.world.bank[AZEROOT], bench.world.bank[GOLD_AZEROOT] = nil, nil
    bench.SetBags({ [AZEROOT] = 0, [GOLD_AZEROOT] = 40, ["Mana-Wyrm Essence"] = 40 })
    sellsFor = price
    local AHPrice = addon.GetAHPriceInfo
    function addon:GetAHPriceInfo(itemID, buying)
        if itemID == AZEROOT then return bench.Gold(20), "Goldsmith scan", 0 end
        if itemID == GOLD_AZEROOT then return bench.Gold(15), "Goldsmith scan", 0 end
        return AHPrice(self, itemID, buying)
    end
    -- What the tea sells for, set straight on the plan (its price comes
    -- from tier data and the jump check, not one call)
    local Build = addon.BuildPlan
    function addon:BuildPlan(...)
        local plan = Build(self, ...)
        if plan and plan.revenue then
            plan.revenue = sellsFor * (plan.expectedOutput or 1)
            plan.profit = plan.revenue - plan.cost
        end
        return plan
    end
    addon.dataVersion = addon.dataVersion + 1
    local page = ProfessionsFrame.CraftingPage
    if page and page.SchematicForm then page.SchematicForm.GetRecipeInfo = function() return nil end end
    bench.OpenProfession("Cooking")
    bench.Advance(2)
    return addon
end

local addon = Start(bench.Gold(500))
local q = addon:BuildQueue(addon.charKey)
bench.Check("makes gold when queued", q.rows[1].plan.profit > 0, q.rows[1].plan.profit)
bench.Check("ready to craft (what this tests)", q.rows[1].state and q.rows[1].state.enabled)
bench.Check("no warning while it makes gold", not addon:QueueAsksLoss(q.rows[1]))

-- The price falls
sellsFor = 1
addon.dataVersion = addon.dataVersion + 1
q = addon:BuildQueue(addon.charKey)
bench.Check("a loss now", q.rows[1].plan.profit < 0)
bench.Equal("row says so", (addon:QueueRowStatus(q.rows[1], q)), "Now a loss")
bench.Equal("button asks", addon:QueueButtonLabel(q.rows[1], q), "Craft anyway")
bench.Chat()
bench.Calls()
addon:CraftNext()
bench.Advance(1)
bench.Has("first press warns in chat", bench.Chat(), "now loses")
local calls = bench.Calls()
bench.Has("with the raid warning", calls, "RaidNotice")
bench.HasNot("doesn't craft yet", calls, "CraftRecipe(")
q = addon:BuildQueue(addon.charKey)
bench.Check("okayed: no more asking", not addon:QueueAsksLoss(q.rows[1]))
addon:CraftNext()
bench.Advance(1)
bench.Has("second press crafts", bench.Calls(), "CraftRecipe(" .. TEA)

-- Queued at a loss on purpose (never made gold): no warning
addon = Start(1)
-- Login planned it at the tea's real price (it makes gold) before the
-- stand-in price was set: start over as if queued at 1c
GoldsmithDB.queues["Mysticmead-Sargeras"][1].wasProfitable = nil
q = addon:BuildQueue(addon.charKey)
bench.Check("a loss from the start", q.rows[1].plan.profit < 0)
bench.Check("not flagged", not addon:QueueAsksLoss(q.rows[1]))
bench.Done()
