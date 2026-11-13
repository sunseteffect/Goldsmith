-- A profession you drop leaves the Characters tab, with its concentration
-- and the recipes it taught, and the one you learn shows. The old one
-- stayed forever (and reinstalling kept it: saved data stays) (TheShua,
-- CurseForge, 2026-11-12).
local bench = dofile(BENCH_DIR .. "bench.lua")
local CHAR = "Mysticmead"
local db = bench.LoadSaved()
local charKey
for key in pairs(db.characters) do
    if key:match("^" .. CHAR .. "%-") then charKey = key end
end
local c = db.characters[charKey]
-- The profession to drop: one this character has, with a known recipe
local old, recipeID
for name in pairs(c.professions or {}) do
    for id in pairs(c.knownRecipes or {}) do
        if db.recipes[id] and db.recipes[id].profession == name then old, recipeID = name, id break end
    end
    if old then break end
end
bench.Check("a profession with a known recipe (what this tests)", old ~= nil)
c.concentration = c.concentration or {}
c.concentration[old] = { currencyID = 1, current = 500, max = 1000, time = os.time() }
local keep = {}
for name in pairs(c.professions) do if name ~= old then keep[#keep + 1] = name end end

-- The game: the old one gone, Herbalism learned
local list = { "Herbalism" }
for _, name in ipairs(keep) do list[#list + 1] = name end
GetProfessions = function()
    local idx = {}
    for i in ipairs(list) do idx[i] = i end
    return unpack(idx)
end
GetProfessionInfo = function(i) return list[i], 134400, 1, 100, nil, nil, 100 + i end

local addon = bench.Login(CHAR, { db = db })
bench.Fire("SKILL_LINES_CHANGED")
bench.Advance(3)
c = GoldsmithDB.characters[charKey]
bench.Equal("the dropped one is gone", c.professions[old], nil)
bench.Equal("its concentration too", c.concentration[old], nil)
bench.Equal("its recipes aren't known", c.knownRecipes[recipeID], nil)
bench.Check("the new one shows", c.professions.Herbalism ~= nil)
for _, name in ipairs(keep) do bench.Check("kept: " .. name, c.professions[name] ~= nil) end

-- At login the game can list nothing yet: nothing is dropped then
GetProfessions = function() return nil end
bench.Fire("SKILL_LINES_CHANGED")
bench.Advance(3)
bench.Check("nothing listed: Herbalism stays", GoldsmithDB.characters[charKey].professions.Herbalism ~= nil)
bench.Done()
