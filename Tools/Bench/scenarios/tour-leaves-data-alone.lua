-- The tour runs on sample data cut off from the game: Buy next and Craft
-- next say what they would do and do nothing, and your saved data is
-- exactly as it was when it ends (error review, 2026-10-23)
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.queues["Mysticmead-Sargeras"] = { { recipeID = 1226197, quantity = 8, made = 0, added = os.time() } }
local addon = bench.Login("Mysticmead", { db = db })
local realDB = GoldsmithDB
-- Stamped when your bags are counted again after the tour (the counts
-- themselves must match)
local function WithoutStamps(t)
    local copy = bench.Copy(t)
    for _, c in pairs(copy) do c.stockTime = nil end
    return copy
end
local before = {}
for _, key in ipairs({ "entries", "queues", "characters", "inMail", "boughtFor", "ledger", "craftLots",
    "priceHistory", "ownScan", "settings", "recipes", "lifetime" }) do
    before[key] = bench.Serialize(key == "characters" and WithoutStamps(realDB[key]) or realDB[key])
end

addon:ToggleWindow()
bench.Advance(1)
addon:StartTour()
bench.Advance(5)
bench.Check("tour on sample data", addon:UsingTourData())
bench.Check("sample data in place", GoldsmithDB ~= realDB)

bench.OpenAH()
bench.Calls()
addon:BuyNext()
bench.Advance(1)
bench.Has("Buy next says what it would do", bench.Chat(), "Tour: this would buy")
bench.HasNot("nothing asked of the AH", bench.Calls(), "CommoditiesPurchase")
if addon.CraftNext then
    addon:CraftNext()
    bench.Advance(1)
    bench.HasNot("Craft next crafts nothing", bench.Calls(), "Craft")
end
bench.CloseAH()
for _, tab in ipairs({ "overview", "characters", "crafts", "queue", "items", "history", "stats" }) do
    addon:ShowTab(tab)
    bench.Advance(3)
end

addon:EndTour()
bench.Advance(5)
bench.Check("tour ended", not addon:UsingTourData())
bench.Check("your saved data back", GoldsmithDB == realDB)
for key, s in pairs(before) do
    local now = key == "characters" and WithoutStamps(GoldsmithDB[key]) or GoldsmithDB[key]
    bench.Check(key .. " unchanged", bench.Serialize(now) == s)
end
bench.Done()
