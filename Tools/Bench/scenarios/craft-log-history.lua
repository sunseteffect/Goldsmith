-- History's crafts reach back 90 days: a craft log keeps one entry a
-- batch. Each item keeps only its last 30 crafts (for costs), so History
-- showed 61 Harandar Celebration crafted against about 300 sold (Reddit
-- tester; Idea Board "Craft log for History"). Recent batches still come
-- from the crafts kept (Move to Orders works on them); older ones from the
-- log, never both.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local ITEM = 990040
bench.AddItem(ITEM, "Bench Feast", { stack = 200 })
local recipe = { recipeID = 990041, profession = "Cooking", outputItemID = ITEM, outputName = "Bench Feast",
    outputQty = 2, outputMax = 2, reagents = {} }
GoldsmithDB.recipes[recipe.recipeID] = recipe
-- GoldsmithDB.craftLog is the game's craft results (another log): kept as
-- it is. Clearing it here hid that the batches first went there too, and
-- every craft errored in game (2026-11-13)
GoldsmithDB.craftLog = GoldsmithDB.craftLog or { { recipeID = 1 } }
local rawBefore = #GoldsmithDB.craftLog
GoldsmithDB.craftBatches = nil

-- Crafting logs it: 3 crafts a minute apart are one batch
local now = time()
for i = 1, 3 do
    addon:RecordCraftLot(recipe, { itemID = ITEM, quantity = 2 }, {})
end
local log = GoldsmithDB.craftBatches
bench.Equal("no errors crafting", #bench.TakeErrors(), 0)
bench.Check("the craft results log is still a list", GoldsmithDB.craftLog.entries == nil and #GoldsmithDB.craftLog >= rawBefore)
bench.Check("a log", log ~= nil and log.entries ~= nil)
local e = log and log.entries[#log.entries]
bench.Equal("one batch", e and e.crafts, 3)
bench.Equal("made", e and e.qty, 6)
bench.Equal("who", e and e.char, addon.charKey)

local function Crafts()
    addon:DataChanged()
    local rows = addon:GetHistory({ prof = "All", kind = "Craft" })
    local out = {}
    for _, r in ipairs(rows) do if r.itemID == ITEM then out[#out + 1] = r end end
    return out
end
-- Recent: from the crafts kept, not the log as well
local rows = Crafts()
bench.Equal("recent batch: one row", #rows, 1)
bench.Check("from the crafts kept", rows[1] and not rows[1].fromLog)

-- A batch from 40 days ago: its crafts are gone from craftLots, the log has it
table.insert(log.entries, 1, { time = now - 40 * 86400, last = now - 40 * 86400 + 60, itemID = ITEM,
    name = "Bench Feast", crafts = 30, qty = 60, cost = 60 * 5000, char = addon.charKey })
rows = Crafts()
bench.Equal("old batch shows too", #rows, 2)
local old
for _, r in ipairs(rows) do if r.fromLog then old = r end end
bench.Equal("its crafts", old and old.crafts, 30)
bench.Equal("its cost each", old and old.cost, 5000)
bench.Equal("its character", old and old.character, addon.charKey)

-- A log batch overlapping the crafts kept isn't shown twice
table.insert(log.entries, { time = now - 30, last = now + 30, itemID = ITEM, name = "Bench Feast",
    crafts = 3, qty = 6, cost = 0, char = addon.charKey })
bench.Equal("overlap: not twice", #Crafts(), 2)

-- By character: crafts show for that character now
addon:DataChanged()
local mine = addon:GetHistory({ prof = "All", kind = "Craft", character = addon.charKey })
local n = 0
for _, r in ipairs(mine) do if r.itemID == ITEM then n = n + 1 end end
bench.Equal("for this character", n, 2)
bench.Done()
