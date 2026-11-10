-- What the whole queue needs from the bank, before you go and at the bank
-- (user, 2026-11-10: "i find myself having to go to bank twice ... i just
-- didn't know"). Forever crafts from your bags only; the Craft button only
-- named the bank for the entry it was on.
local bench = dofile(BENCH_DIR .. "bench.lua")
local BAR, KNIFE, PLATE, THREAD = 990062, 990063, 990064, 990065
local FORGE_KNIFE, FORGE_PLATE = 990162, 990163
local db = bench.LoadSaved()
db.foreverTest = true
local function Recipe(id, name, out, reagents)
    db.recipes[id] = { recipeID = id, name = name, outputName = name, outputItemID = out,
        outputQty = 1, outputMin = 1, outputMax = 1, profession = "Blacksmithing", skillLine = "Blacksmithing",
        reagents = reagents }
end
Recipe(FORGE_KNIFE, "Bench Knife", KNIFE, { { itemIDs = { BAR }, names = { "Bench Bronze Bar" }, quantity = 2 } })
Recipe(FORGE_PLATE, "Bench Plate", PLATE, { { itemIDs = { BAR }, names = { "Bench Bronze Bar" }, quantity = 4 },
                                            { itemIDs = { THREAD }, names = { "Bench Thread" }, quantity = 1 } })
db.ownScan.prices[BAR] = { bench.Gold(1) }
db.ownScan.prices[THREAD] = { 50 }
db.ownScan.prices[KNIFE] = { bench.Gold(9) }
db.ownScan.prices[PLATE] = { bench.Gold(19) }
local myst = db.characters["Mysticmead-Sargeras"]
myst.knownRecipes[FORGE_KNIFE], myst.knownRecipes[FORGE_PLATE] = true, true
db.queues["Mysticmead-Sargeras"] = {
    { recipeID = FORGE_KNIFE, quantity = 1, made = 0, added = os.time() },
    { recipeID = FORGE_PLATE, quantity = 1, made = 0, added = os.time() },
}
bench.AddItem(BAR, "Bench Bronze Bar", { stack = 20 })
bench.AddItem(THREAD, "Bench Thread", { stack = 20 })
bench.AddItem(KNIFE, "Bench Knife", { stack = 1 })
bench.AddItem(PLATE, "Bench Plate", { stack = 1 })
local addon = bench.Login("Mysticmead", { db = db })
bench.Check("Forever mode", addon.isForever == true)
bench.SetBags({ [BAR] = 1, [THREAD] = 0 })
bench.wow.world.bank[BAR] = 10
bench.wow.world.bank[THREAD] = 1

local function FromBank()
    local out = {}
    for _, it in ipairs(addon:QueueFromBank(addon:BuildQueue(addon.charKey))) do out[it.itemID] = it.quantity end
    return out
end

-- Both entries, not just the knife: 6 bars less the 1 in your bags
local need = FromBank()
bench.Equal("bars for the whole queue", need[BAR], 5)
bench.Equal("the plate's thread too", need[THREAD], 1)

-- The Queue tab says so before you go
addon:ShowTab("queue")
bench.Advance(2)
bench.Has("Queue tab names the bank", bench.Screen(), "Bank: 5 Bench Bronze Bar, 1 Bench Thread", true)

-- At the bank: the panel lists them and Take all moves just that much
bench.wow.world.bankOpen = true
bench.Fire("BANKFRAME_OPENED")
bench.Advance(1)
local screen = bench.Screen()
bench.Has("panel at the bank", screen, "GOLDSMITH: BANK", true)
bench.Has("one item per line", screen, "5 Bench Bronze Bar", true)
bench.Calls()
bench.Click("Take all", nil, 2)
local calls = bench.Calls()
bench.Has("splits 5 bars off the stack of 10", calls, "SplitContainerItem(-1", true)
bench.Has("takes the whole thread stack", calls, "PickupContainerItem(-1", true)

-- Taken: nothing left to take
bench.wow.world.bank[BAR], bench.wow.world.bank[THREAD] = 5, 0
bench.SetBags({ [BAR] = 6, [THREAD] = 1 })
bench.Equal("nothing left for the queue", next(FromBank()), nil)
bench.Fire("BAG_UPDATE_DELAYED")
bench.Advance(1)
bench.Has("says it's all in your bags", bench.Screen(), "All in your bags", true)

-- Retail crafts from the bank: no list there
bench.Fire("BANKFRAME_CLOSED")
bench.Done()
