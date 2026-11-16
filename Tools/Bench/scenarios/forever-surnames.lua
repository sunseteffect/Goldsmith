-- Forever characters have a surname, and two can share a first name: they
-- were saved as one character (GitHub #6, 2026-11-16). The record saved
-- under the first name becomes the full name's, with everything keyed to it;
-- old ledger entries follow while only one character has that first name.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local OLD, NEW, TWIN = "Mysticmead-Sargeras", "Mysticmead Alpha-Sargeras", "Mysticmead Beta-Sargeras"
db.queues = db.queues or {}
db.queues[OLD] = { { recipeID = 1226197, quantity = 8, made = 0, added = os.time() } }
db.settings = db.settings or {}
db.settings.excluded = db.settings.excluded or {}
db.settings.excluded[OLD] = true
table.insert(db.entries, { id = 999999, type = "COST", kind = "PURCHASE", item = "Bench Herb", quantity = 1,
    totalCopper = 10, timestamp = os.time() - 86400, character = "Mysticmead", realm = "Sargeras" })
-- A namesake who already logged in on this version
db.characters[TWIN] = { name = "Mysticmead Beta", realm = "Sargeras" }

RegionalUniqueNamesEnabled = function() return true end
local plain = UnitName
UnitName = function(unit)
    if unit == "player" then return (plain(unit)), "Alpha" end
    if unit == "NPC" then return "Mysticmead", "Beta" end
    return plain(unit)
end

local addon = bench.Login("Mysticmead", { db = db })
bench.Equal("key has the surname", addon.charKey, NEW)
bench.Equal("first-name record is gone", GoldsmithDB.characters[OLD], nil)
bench.Equal("record carries the full name", GoldsmithDB.characters[NEW].name, "Mysticmead Alpha")
bench.Check("it is the same record", GoldsmithDB.characters[NEW] == addon.char and next(addon.char.professions) ~= nil)
bench.Check("queue moved", GoldsmithDB.queues[NEW] ~= nil and GoldsmithDB.queues[OLD] == nil)
bench.Check("setting moved", GoldsmithDB.settings.excluded[NEW] == true and GoldsmithDB.settings.excluded[OLD] == nil)

-- New records carry the full name
addon.ledger:addCost("Unassigned", "Bench Herb", 1, 10)
local all = addon.ledger:getAll()
bench.Equal("new entry has the full name", all[#all].character, "Mysticmead Alpha")

-- Two namesakes: an old first-name entry is nobody's for sure
bench.Equal("old entry stays under the first name", addon:CharKeyFor("Mysticmead", "Sargeras"), OLD)
bench.Equal("first name alone: no mail match", addon:FindOwnCharacter("Mysticmead", "Sargeras"), nil)
bench.Equal("full name: the namesake", addon:FindOwnCharacter("mysticmead beta", "Sargeras"), TWIN)
bench.Equal("someone else's surname: nobody", addon:FindOwnCharacter("Mysticmead Gamma", "Sargeras"), nil)
bench.Equal("trade partner's full name", (addon:FullName("NPC")), "Mysticmead Beta")

-- One character with that first name: old entries are theirs
addon:RemoveCharacter(TWIN)
bench.Equal("old entry counts for the only one", addon:CharKeyFor("Mysticmead", "Sargeras"), NEW)
bench.Equal("first name alone finds them", addon:FindOwnCharacter("Mysticmead", "Sargeras"), NEW)
-- An alt not logged in since: still saved under the first name
bench.Equal("alt saved before surnames", addon:FindOwnCharacter("Raikozaan Delta", "Sargeras"), "Raikozaan-Sargeras")

addon:ToggleWindow()
for _, tab in ipairs({ "overview", "characters", "history", "stats" }) do
    addon:ShowTab(tab)
    bench.Advance(5)
    bench.Equal(tab .. " tab opens", addon:CurrentTab(), tab)
end
bench.Done()
