-- A new player: no saved data, no price addon. Welcome message, every tab
-- and command without a Lua error, the getting started checklist
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Newplayer", { fresh = true, money = bench.Gold(1234) })
bench.Has("welcome message", bench.loginChat, "Welcome! Type /gsm")
bench.Check("saved data made", type(GoldsmithDB) == "table" and GoldsmithDB.characters["Newplayer-Sargeras"] ~= nil)

addon:ToggleWindow()
bench.Advance(2)
bench.Has("getting started checklist", bench.Screen(), "price", true)
for _, tab in ipairs({ "overview", "characters", "crafts", "queue", "items", "history", "stats" }) do
    addon:ShowTab(tab)
    bench.Advance(5)
    bench.Equal(tab .. " tab opens", addon:CurrentTab(), tab)
end
addon:ShowSettings()
bench.Advance(1)
for _, cmd in ipairs({ "chars", "data", "recipes", "milling", "cooldowns", "gathered", "buffs", "report" }) do
    bench.Slash("/gsm " .. cmd)
    bench.Advance(5)
end
bench.Chat()
bench.OpenAH()
bench.OpenMail()
bench.OpenVendor({})
bench.Done()
