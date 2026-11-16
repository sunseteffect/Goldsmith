-- Forever: the surname isn't known yet when the addon loads. Goldsmith waits
-- for login rather than save under the first name (GitHub #6, 2026-11-16).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local ready = false
RegionalUniqueNamesEnabled = function() return true end
local plain = UnitName
UnitName = function(unit)
    if unit == "player" then return (plain(unit)), ready and "Alpha" or nil end
    return plain(unit)
end
local fire = bench.Fire
bench.Fire = function(event, ...)
    if event == "PLAYER_LOGIN" then
        bench.Check("not set up before the surname", _G.Goldsmith.char == nil)
        ready = true
    end
    return fire(event, ...)
end

local addon = bench.Login("Mysticmead", { db = db })
bench.Equal("key has the surname", addon.charKey, "Mysticmead Alpha-Sargeras")
bench.Equal("nothing under the first name", GoldsmithDB.characters["Mysticmead-Sargeras"], nil)
addon:ToggleWindow()
bench.Advance(2)
bench.Check("window shows", addon.window and addon.window:IsShown())
bench.Done()
