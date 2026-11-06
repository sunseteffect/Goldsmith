-- Forever crafts from your bags only: materials in the bank don't count
-- for the Craft button, which says "In the bank" (user, 2026-11-05: the
-- plan said From stock, the button Craft 3, and it wouldn't start).
-- Retail crafts from the bank, so nothing changes there.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local LINEN, THREAD = 990101, 990102
bench.AddItem(LINEN, "Bench Linen")
bench.AddItem(THREAD, "Bench Thread")
local world = bench.world
local function Check(forever, bags, bank)
    addon.isForever = forever
    world.bags[LINEN], world.bank[LINEN] = bags, bank
    local state = { blockers = {}, notes = {} }
    local allowed = addon.CheckMaterials(state, { [LINEN] = 2 }, 3)
    return state, allowed
end

local state, allowed = Check(true, 0, 6)
bench.Equal("Forever, all in the bank: blocked", #state.blockers, 1)
bench.Has("says where", state.blockers[1] or "", "6 in the bank", true)
bench.Equal("the button says so", (addon:BlockedLabel(state)), "In the bank")

state, allowed = Check(true, 2, 4)
bench.Equal("Forever, some in bags: one craft", allowed, 1)
bench.Has("the note says where the rest are", state.notes[1] or "", "4 in the bank", true)

state, allowed = Check(true, 6, 0)
bench.Equal("Forever, all in bags: nothing in the way", #state.blockers, 0)
bench.Equal("all three crafts", allowed, 3)

state, allowed = Check(false, 0, 6)
bench.Equal("Retail crafts from the bank", #state.blockers, 0)
bench.Equal("all three crafts on retail", allowed, 3)
addon.isForever = false
bench.Done()
