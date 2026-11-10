-- What's new opens without an error in every theme (2026-11-10: the box
-- asked UI.Panel for a "floating" style it doesn't have, a Lua error from
-- the Version tile that BugSack caught)
local bench = dofile(BENCH_DIR .. "bench.lua")
for _, theme in ipairs({ "clean", "game", "alliance", "horde" }) do
    local db = bench.LoadSaved()
    db.settings = db.settings or {}
    db.settings.theme = theme
    local addon = bench.Login("Mysticmead", { db = db })
    addon:ToggleWindow()
    bench.Advance(1)
    local ok, err = pcall(addon.ShowNews, addon)
    bench.Check(theme .. ": What's new opens", ok, tostring(err))
    bench.Advance(1)
    bench.Has(theme .. ": Got it shows", table.concat(bench.Screen(), "\n"), "Got it", true)
end
bench.Done()
