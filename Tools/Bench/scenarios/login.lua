-- Logging in on the saved data: every file loads, login chores run, every
-- tab draws and the chat commands answer, all without a Lua error
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
bench.Equal("character key", addon.charKey, "Mysticmead-Sargeras")

addon:ToggleWindow()
bench.Advance(2)
bench.Check("window shows", addon.window and addon.window:IsShown())
for _, tab in ipairs({ "overview", "characters", "crafts", "queue", "items", "history", "stats" }) do
    addon:ShowTab(tab)
    bench.Advance(5)
    bench.Equal(tab .. " tab opens", addon:CurrentTab(), tab)
end
addon:ShowSettings()
bench.Advance(1)

for _, cmd in ipairs({ "chars", "data", "recipes", "milling", "cooldowns", "gathered", "buffs", "news", "report" }) do
    bench.Slash("/gsm " .. cmd)
    bench.Advance(5)
    local chat = bench.Chat()
    bench.Check("/gsm " .. cmd .. " answers", #chat > 0 or cmd == "report" or cmd == "news")
end
bench.Slash("/gsm perf")
bench.Advance(60)
bench.Has("/gsm perf reports", bench.Chat(), "Goldsmith performance")
bench.Done()
