-- The Horde theme (the game's look plus a faction frame) in Forever mode:
-- every tab and Settings draw without an error (2.8 release, 2026-11-06).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
db.foreverTest = true
db.settings = db.settings or {}
db.settings.theme = "horde"
local addon = bench.Login("Mysticmead", { db = db })
bench.Equal("theme kept", addon:Setting("theme"), "horde")
addon:ToggleWindow()
bench.Advance(2)
for _, tab in ipairs({ "overview", "characters", "crafts", "queue", "items", "history", "stats" }) do
    addon:ShowTab(tab)
    bench.Advance(5)
    bench.Equal(tab .. " tab opens", addon:CurrentTab(), tab)
end
bench.Done()
