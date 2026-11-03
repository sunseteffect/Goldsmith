-- At one profession's crafting orders, an order ready there comes before
-- opening another profession: a Jewelcrafting order first in the queue
-- said "Open Jewelcrafting" at the Blacksmithing orders, just to come back
-- (user, 2026-11-03). The queue's rows as the game had them.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Trypttamine")
local function Row(name, state) return { entry = { orderID = 1 }, recipe = { outputName = name }, state = state } end
local lapis = Row("Flawless Versatile Lapis", { enabled = true, open = true, label = "Open Jewelcrafting",
    notes = {}, blockers = {} })
local charm = Row("Nocturnal Charm", { enabled = true, open = true, label = "Open Jewelcrafting",
    notes = {}, blockers = {} })
local alloy = Row("Gloaming Alloy", { enabled = false, orderReady = true, notes = {},
    blockers = { "Everything's ready: craft it in the crafting orders window." } })
local axe = Row("Primalforged Heavy Axe", { enabled = false, orderReady = true, notes = {}, blockers = {} })
local q = { mine = true, charKey = addon.charKey, rows = { lapis, charm, alloy, axe } }
bench.Equal("next: the order ready here", addon:QueueNextRow(q), alloy)
bench.Equal("button", addon:QueueButtonLabel(alloy, q), "Craft in order window")
bench.Equal("line above it", addon:QueueNextLine(alloy), "Next: Gloaming Alloy")

-- A craft you can make here still comes first
local roast = Row("Impossibly Royal Roast", { enabled = true, label = "Craft 2", notes = {}, blockers = {} })
q.rows = { lapis, alloy, roast }
bench.Equal("a craft here first", addon:QueueNextRow(q), roast)

-- Nothing ready here: opening the other profession is the step
q.rows = { lapis, charm }
bench.Equal("then: open Jewelcrafting", addon:QueueNextRow(q), lapis)
bench.Done()
