-- Settings > Buy next > Use what's in the bank (user, 2026-11-13: "a
-- setting to ignore items in bank for use in crafts"), for each character
-- ("Should it be per character?"). On, as before: plans, the queue and
-- Buy next count the bank and warband bank. Off: only bags and the
-- mailbox, for that character alone.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
for key in pairs(db.queues) do db.queues[key] = {} end
local addon = bench.Login("Mysticmead", { db = db })
GoldsmithDB.inMail[addon.charKey] = {}

-- A recipe Mysticmead knows with a material bought on the AH
local recipe, itemID
for id in pairs(addon.char.knownRecipes) do
    local r = GoldsmithDB.recipes[id]
    if r and r.outputItemID and not recipe then
        for _, rg in ipairs(r.reagents or {}) do
            local ids = rg.itemIDs or { rg.itemID }
            if #ids == 1 and ids[1] and addon:GetAHPrice(ids[1], true) and not addon:GetVendorPrice(ids[1])
                and (rg.quantity or 1) >= 1 then
                recipe, itemID = r, ids[1]
                break
            end
        end
    end
end
bench.Check("a recipe with an AH material", recipe ~= nil)
if not recipe then bench.Done() return end

bench.SetBags({ [itemID] = 1 })
bench.world.bank[itemID] = 500
bench.world.warband[itemID] = 300
local function ToBuy()
    addon:DataChanged()
    local q = addon:BuildQueue(addon.charKey)
    for _, e in ipairs(q.buyAH or {}) do
        if e.itemID == itemID then return e.quantity or 0 end
    end
    return 0
end
GoldsmithDB.queues[addon.charKey] = {}
addon:QueueSuggestion(addon.charKey, recipe, nil, false, 5)

bench.Equal("on by default", addon:UsesBank(addon.charKey), true)
bench.Equal("on: bags, bank and warband", addon:CraftCount(itemID), 801)
bench.Equal("on: the character's bank only", addon:CraftCount(itemID, false), 501)
bench.Equal("on: nothing to buy", ToBuy(), 0)

addon:SetUsesBank(addon.charKey, false)
bench.Equal("off: bags only", addon:CraftCount(itemID), 1)
bench.Equal("off: bags only (character)", addon:CraftCount(itemID, false), 1)
bench.Check("off: the queue buys it", ToBuy() > 0, tostring(ToBuy()))

bench.Has("the report lists it", table.concat(addon:ChangedSettings(), "\n"), "1 characters leave the bank out")

-- Another character: their own choice, not this one's
local other
for key, c in pairs(GoldsmithDB.characters) do
    if key ~= addon.charKey and c.stockBank and next(c.stockBank) and not other then other = key end
end
if other then
    local c = GoldsmithDB.characters[other]
    local id, bank = next(c.stockBank)
    c.stock[id] = math.max(c.stock[id] or 0, bank + 2)
    local function Held() addon:DataChanged() return addon:WithCharacter(other, function() return addon:GetOnHand(id) end) end
    local on = Held()
    bench.Check("another character's bank still counts", on >= bank, on .. " held, " .. bank .. " banked")
    addon:SetUsesBank(other, false)
    local off = Held()
    bench.Check("left out once they set it", off <= on - bank, on .. " vs " .. off)
    addon:SetUsesBank(other, true)
end
addon:SetUsesBank(addon.charKey, true)
bench.Equal("on again: nothing saved", addon.char.leaveBank, nil)
bench.Equal("no errors", #bench.TakeErrors(), 0)
bench.Done()
