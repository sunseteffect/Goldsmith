-- Soulbound gear in the bank isn't for sale. The game shows the bank's
-- slots (where "bound" is) only while it's open, so what was bound there
-- is remembered: Trypttamine's Apprentice Jeweler's Apron, put in the
-- bank, was back on the Held board (user, 2026-10-29).
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local KEY = "Trypttamine-Sargeras"
local APRON = 244629
local c = db.characters[KEY]
c.boundBank = nil
-- One apron, in the bank
c.stock[APRON], c.stockBank = 1, c.stockBank or {}
c.stockBank[APRON] = 1
local addon = bench.Login("Trypttamine", { db = db })
-- A profession tool (Enum.ItemClass.Profession), so gear
bench.AddItem(APRON, "Apprentice Jeweler's Apron", { classID = Enum.ItemClass.Profession, stack = 1 })
bench.world.bound[APRON] = true

local function Recount()
    bench.Fire("BAG_UPDATE_DELAYED")
    addon:CountStockIfStale()
    bench.Advance(2)
end
local function OnBoard()
    addon:DataChanged()
    for _, h in ipairs(addon:GetStockValue("All").heldLong) do
        if h.itemID == APRON then return true end
    end
    return false
end

-- Bank open: its slots say bound
bench.world.bankOpen = true
Recount()
bench.Equal("bank open: not stock", GoldsmithDB.characters[KEY].stock[APRON], nil)
bench.Equal("remembered as bound in the bank", (GoldsmithDB.characters[KEY].boundBank or {})[APRON], 1)

-- Closed: still not stock
bench.world.bankOpen = false
Recount()
bench.Equal("bank closed: still not stock", GoldsmithDB.characters[KEY].stock[APRON], nil)
bench.Check("not on the Held board", not OnBoard())

-- Taken out of the bank and gone (sold to a vendor): nothing to subtract from
bench.world.bank[APRON] = nil
Recount()
bench.Equal("gone: nothing counted", GoldsmithDB.characters[KEY].stock[APRON], nil)
bench.Done()
