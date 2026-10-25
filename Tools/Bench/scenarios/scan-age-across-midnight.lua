-- A scan from before midnight: "yesterday 23:35", not "1 day ago" an hour
-- later (user, 2026-10-25), and the header isn't orange for it
local bench = dofile(BENCH_DIR .. "bench.lua")
local function At(y, m, d, h, min) return os.time({ year = y, month = m, day = d, hour = h, min = min }) end

local db = bench.LoadSaved()
local scanAt = At(2026, 10, 24, 23, 35)
db.ownScan.time = scanAt
local addon = bench.Login("Mysticmead", { db = db, time = At(2026, 10, 25, 0, 40) - 20 })

bench.Equal("an hour later, after midnight", addon:WhenText(scanAt), "yesterday 23:35")
bench.Equal("same day", addon:WhenText(At(2026, 10, 25, 0, 10)), "at 00:10")
bench.Equal("same day, AH panel wording", addon:WhenText(At(2026, 10, 25, 0, 10), "today "), "today 00:10")
bench.Equal("two calendar days back", addon:WhenText(At(2026, 10, 23, 23, 50)), "2 days ago")
bench.Equal("a week back", addon:WhenText(At(2026, 10, 18, 9, 0)), "7 days ago")

addon:ToggleWindow()
bench.Advance(2)
local header
for _, l in ipairs(bench.Screen()) do if l:find("^Prices:") then header = l end end
bench.Log("header: %s", tostring(header))
bench.Has("header says yesterday", tostring(header), "yesterday 23:35")
bench.HasNot("not a day ago", tostring(header), "day ago")
bench.Done()
