-- A material whose cheap listings sold out costs what's listed now, on the
-- Crafts list too, not what it sold for before. After Small Lustrous
-- Pearls went from 2.46s to 14.30s, Crafts costed them at TSM's 2.95s
-- sale average: Pearl-handled Dagger read +20s there and -1s in the queue
-- once bought (user, 2026-11-18).
local bench = dofile(BENCH_DIR .. "bench.lua")
local PEARL, DAGGER = 990061, 990062
local db = bench.LoadSaved()
db.recipes[990160] = { recipeID = 990160, name = "Bench Pearl Dagger", outputName = "Bench Pearl Dagger",
    outputItemID = DAGGER, outputQty = 1, outputMin = 1, outputMax = 1, profession = "Blacksmithing",
    skillLine = "Midnight Blacksmithing",
    reagents = { { itemIDs = { PEARL }, names = { "Bench Pearl" }, quantity = 2 } } }
local addon = bench.Login("Mysticmead", { db = db })
bench.AddItem(PEARL, "Bench Pearl", { stack = 20 })
bench.AddItem(DAGGER, "Bench Pearl Dagger", {})
-- TSM: the pearl used to sell for 2.95s, the dagger for 60s
local values = { [PEARL] = { dbregionsaleavg = 295, dbmarket = 360 },
    [DAGGER] = { dbregionsaleavg = 6000, dbmarket = 6000 } }
TSM_API = { GetCustomPriceValue = function(source, item)
    local id = tonumber(item:match("i:(%d+)"))
    return values[id] and values[id][source:lower()]
end }
-- A full scan: 676 pearls, the cheapest 14.30s
GoldsmithDB.ownScan = { time = time() - 60, method = "full", items = 2, auctions = 700, group = addon:RealmGroup(),
    realm = GetRealmName(), seconds = 1, prices = { [PEARL] = { 1430, 1430, 676 }, [DAGGER] = { 6000, 6000, 2 } } }
addon:DataChanged()

local row = addon:GetRecipeProfit(db.recipes[990160])
bench.Equal("costed at what's listed", row and row.cost, 2 * 1430)
bench.Equal("profit from that cost", row and row.profit and math.floor(row.profit + 0.5), 6000 * 0.95 - 2 * 1430)
local pearl = row and row.breakdown and row.breakdown[1]
bench.Check("says where the price is from, not 'adjusted'", pearl and pearl.ageText
    and not pearl.ageText:find("adjusted") and not pearl.ageText:find("sale average"), pearl and pearl.ageText)
-- What it sells for is still checked against what it sold for: a 600s
-- dagger listing with 60s sales isn't the price
GoldsmithDB.ownScan.prices[DAGGER] = { 60000, 60000, 1 }
addon:DataChanged()
row = addon:GetRecipeProfit(db.recipes[990160])
bench.Equal("output still capped at its sale average", row and row.price, 6000)
TSM_API = nil
bench.Done()
