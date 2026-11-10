-- Coin icons (Settings > Display, off by default; user, 2026-11-10)
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local G, S, C = "UI%-GoldIcon", "UI%-SilverIcon", "UI%-CopperIcon"
local function Plain(text) return (text:gsub("|T[^|]*|t", "#")) end

bench.Equal("off by default", addon:FormatMoney(124000), "12.40g")
GoldsmithDB.settings.coinIcons = true
local t = addon:FormatMoney(124000)
bench.Check("12.40g: gold and silver coins", t:find(G) and t:find(S) and true, t)
bench.Equal("12 gold 40 silver", Plain(t), "12# 40#")
bench.Equal("whole gold: no silver", Plain(addon:FormatMoney(120000)), "12#")
bench.Equal("silver only", Plain(addon:FormatMoney(4000)), "40#")
bench.Equal("a loss keeps its minus", Plain(addon:FormatSignedMoney(-4000)), "-40#")
bench.Equal("thousands", Plain(addon:FormatMoney(12345 * 10000)), "12,345#")
addon.isForever = true
t = addon:FormatMoney(325)
bench.Check("Forever 3s 25c: silver and copper", t:find(S) and t:find(C) and true, t)
bench.Equal("Forever 3s 25c", Plain(t), "3# 25#")
bench.Equal("Forever 3g 25s", Plain(addon:FormatMoney(32500)), "3# 25#")
addon.isForever = false
GoldsmithDB.settings.coinIcons = nil
bench.Equal("off again", addon:FormatMoney(124000), "12.40g")
bench.Done()
