-- The plan's Update queue button is greyed out when the queue already has
-- what the plan shows (same number, none made, same mix), and comes back
-- when the number or the mix changes (user, 2026-10-29: it looked
-- clickable with nothing to send).
local bench = dofile(BENCH_DIR .. "bench.lua")
local SIENNA_INK = 1230016
local MADDOXYNN = "Maddoxynn-Sargeras"

local db = bench.LoadSaved()
db.queues[MADDOXYNN] = {}
local addon = bench.Login("Mysticmead", { db = db })

local function QueueButton()
    for _, f in ipairs(bench.wow.frames) do
        local text = f.label and f.label.GetText and f.label:GetText()
        if (text == "Add to queue" or text == "Update queue") and f:IsVisible() then return f, text end
    end
end

addon:OpenCraftPlan(GoldsmithDB.recipes[SIENNA_INK], { tier = 2, concentrate = true }, MADDOXYNN, 6)
bench.Advance(2)
local button, text = QueueButton()
bench.Equal("not queued: Add to queue", text, "Add to queue")
bench.Check("Add to queue can be clicked", button and button:IsEnabled())

button:Click()
bench.Advance(1)
button, text = QueueButton()
bench.Equal("queued: Update queue", text, "Update queue")
bench.Check("nothing to update: greyed out", button and not button:IsEnabled())
local entry = GoldsmithDB.queues[MADDOXYNN][1]

-- Another number: something to send
local screen = button:GetParent()
local asked = screen.qty:GetText()
-- As typing in the box does (its handler clears the earlier ask)
local function Type(text)
    screen.qty:SetText(text)
    screen.askedCrafts = nil
    screen:Update()
end
Type("1")
bench.Check("new number: clickable", button:IsEnabled())
Type(asked)
bench.Check("back to the queued number: greyed out", not button:IsEnabled())

-- Some made: Update sets it back to the full number, so it's a change
entry.made = 1
screen:Update()
bench.Check("some made: clickable", button:IsEnabled())
entry.made = 0

-- Another mix queued than shown: clickable
entry.prefMix = "a mix nobody shows"
screen:Update()
bench.Check("other mix queued: clickable", button:IsEnabled())
bench.Done()
