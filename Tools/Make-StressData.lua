-- Makes a big fake account from real saved data, for performance tests.
--
--   lua Make-StressData.lua <real Goldsmith.lua> <output file> [characters] [days] [entries]
--
-- Reads a real SavedVariables file and writes an inflated copy:
--   characters  - total characters, made by copying ones with crafting data
--                 under new names (default 24)
--   days        - days of history: price history (Goldsmith keeps 60 at
--                 most, so it stops there), daily gold per character and
--                 the warband (default 365)
--   entries     - transactions, made by copying the real ones further back
--                 in time and spreading them over every character
--                 (default 20000)
-- The input file is only read. GoldsmithDB.stressTest marks the output so
-- Goldsmith warns at login that fake data is loaded. Use Stress-Swap.ps1
-- to swap it in and back out.
-- Run with Lua 5.1 (WoW's version).

local input, output = arg[1], arg[2]
local CHARACTERS = tonumber(arg[3]) or 24
local DAYS = tonumber(arg[4]) or 365
local ENTRIES = tonumber(arg[5]) or 20000
local PRICE_HISTORY_DAYS = 60 -- Stock.lua HISTORY_DAYS
local DAY = 86400

if not input or not output then
    print("Usage: lua Make-StressData.lua <real Goldsmith.lua> <output file> [characters] [days] [entries]")
    os.exit(1)
end
math.randomseed(42)

dofile(input)
local db = GoldsmithDB
assert(type(db) == "table", "No GoldsmithDB in " .. input)
assert(not db.stressTest, "That file is already fake data")
local now = os.time()

local function Copy(t)
    if type(t) ~= "table" then return t end
    local c = {}
    for k, v in pairs(t) do c[k] = Copy(v) end
    return c
end

local function Count(t)
    local n = 0
    for _ in pairs(t or {}) do n = n + 1 end
    return n
end

-- A price near `price`, so fake history looks like a market moving around
local function Jitter(price)
    return math.max(1, math.floor(price * (0.8 + math.random() * 0.4)))
end

-- Daily tables keyed "YYYY-MM-DD": fill every missing day back to `days`
-- ago, from the oldest real value
local function FillDays(daily, days)
    if type(daily) ~= "table" then return end
    local base
    for day, value in pairs(daily) do
        if type(value) == "number" and (not base or day < base[1]) then base = { day, value } end
    end
    if not base then return end
    for i = 0, days - 1 do
        local day = os.date("%Y-%m-%d", now - i * DAY)
        if daily[day] == nil then daily[day] = Jitter(base[2]) end
    end
end

-- Characters: copies of the ones with crafting data (recipe tiers)
local real, names = {}, {}
for key, c in pairs(db.characters) do
    names[#names + 1] = c.name
    if next(c.tierData or {}) then real[#real + 1] = key end
end
table.sort(real)
assert(#real > 0, "No character with crafting data to copy")
local LETTERS = "abcdefghijklmnopqrstuvwxyz"
local made = 0
while Count(db.characters) < CHARACTERS do
    made = made + 1
    local source = db.characters[real[(made - 1) % #real + 1]]
    local c = Copy(source)
    -- Stressa, Stressb ... Stressaa, Stressab
    local suffix, n = "", made
    repeat
        local i = (n - 1) % 26 + 1
        suffix = LETTERS:sub(i, i) .. suffix
        n = math.floor((n - 1) / 26)
    until n == 0
    c.name = "Stress" .. suffix
    c.lastSeen = now - math.random(0, 20) * DAY
    db.characters[c.name .. "-" .. (c.realm or "Fake")] = c
    names[#names + 1] = c.name
end

-- Daily history
for _, c in pairs(db.characters) do
    FillDays(c.gold, DAYS)
    FillDays(c.goldTime, DAYS)
end
FillDays(db.warbandGold, DAYS)
for _, days in pairs(db.priceHistory or {}) do
    FillDays(days, PRICE_HISTORY_DAYS)
end

-- Transactions: the real ones copied further back, round after round,
-- each copy on a random character
local entries = db.entries or {}
db.entries = entries
local realEntries = Copy(entries)
assert(#realEntries > 0, "No transactions to copy")
local oldest, newest = math.huge, 0
for _, e in ipairs(realEntries) do
    oldest, newest = math.min(oldest, e.timestamp), math.max(newest, e.timestamp)
end
local span = math.max(newest - oldest, DAY) + DAY
local nextId = db.nextId or (#entries + 1)
local round = 0
while #entries < ENTRIES do
    round = round + 1
    for _, e in ipairs(realEntries) do
        if #entries >= ENTRIES then break end
        local c = Copy(e)
        c.timestamp = e.timestamp - round * span
        c.id = nextId
        c.character = names[math.random(#names)]
        nextId = nextId + 1
        entries[#entries + 1] = c
    end
end
db.nextId = nextId
table.sort(entries, function(a, b) return a.timestamp < b.timestamp end)

db.stressTest = {
    made = now, characters = Count(db.characters), days = DAYS, entries = #entries,
    oldestEntry = entries[1] and entries[1].timestamp,
}

-- Write it the way WoW does: GoldsmithDB = { ... }
local file = assert(io.open(output, "w"))
local function Key(k)
    if type(k) == "string" then return string.format("[%q]", k) end
    return "[" .. tostring(k) .. "]"
end
local function Value(v)
    if type(v) == "string" then return string.format("%q", v) end
    if type(v) == "number" then
        if v == math.floor(v) and math.abs(v) < 2^53 then return string.format("%d", v) end
        return string.format("%.17g", v)
    end
    return tostring(v)
end
local function Write(t, depth)
    file:write("{\n")
    for k, v in pairs(t) do
        if type(v) == "table" then
            file:write(Key(k), " = ")
            Write(v, depth + 1)
            file:write(",\n")
        elseif type(v) ~= "function" then
            file:write(Key(k), " = ", Value(v), ",\n")
        end
    end
    file:write("}")
end
file:write("\nGoldsmithDB = ")
Write(db, 0)
file:write("\n")
file:close()

local s = db.stressTest
print(string.format("Wrote %s: %d characters, %d transactions back to %s, %d days of history.",
    output, s.characters, s.entries, os.date("%Y-%m-%d", s.oldestEntry), s.days))
