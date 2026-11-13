-- Selling gathered materials to a vendor isn't a flip just because you once
-- bought some on the AH. Skinned Light Leather sold to a vendor said
-- "Flipped Light Leather: -36c": 34 had been bought days before and used
-- in crafts, and only sales were taken off them (user, Forever,
-- 2026-11-12). A flip is only what bought ones still make up of what you
-- hold, newest first.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local LEATHER = 990010
bench.AddItem(LEATHER, "Bench Leather", { sellPrice = 15, stack = 200 })
GoldsmithDB.reagents["Bench Leather"] = "Skinning"

local function Sales()
    local n, last = 0, nil
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.item == "Bench Leather" and e.type == "REVENUE" then n, last = n + 1, e end
    end
    return n, last
end

-- 20 bought six days ago, all used in crafts since (none held)
addon.ledger:addCost("Skinning", "Bench Leather", 20, 500, "PURCHASE", LEATHER, { timestamp = time() - 6 * 86400 })
-- 4 skinned today
bench.Check("skinning recorded", addon:RecordGathered(LEATHER, 4))
bench.SetBags({ [LEATHER] = 4 })

local real = C_Container.GetContainerItemInfo
local stack = 4
C_Container.GetContainerItemInfo = function() return { itemID = LEATHER, stackCount = stack } end
bench.Fire("MERCHANT_SHOW")
C_Container.UseContainerItem(0, 1)
bench.Equal("skinned: no flip recorded", (Sales()), 0)
bench.HasNot("skinned: no flip line", bench.Chat(), "Flipped Bench Leather", true)

-- Bought on the AH just now and sold to the vendor: that's a flip
bench.SetBags({ [LEATHER] = false })
addon.ledger:addCost("Skinning", "Bench Leather", 3, 30, "PURCHASE", LEATHER, { timestamp = time() + 60 })
bench.SetBags({ [LEATHER] = 3 })
stack = 3
C_Container.UseContainerItem(0, 1)
local n, sale = Sales()
bench.Equal("bought: a flip", n, 1)
bench.Equal("bought: all 3", sale and sale.quantity, 3)
bench.Has("bought: flip line", bench.Chat(), "Flipped Bench Leather", true)
bench.Fire("MERCHANT_CLOSED")
C_Container.GetContainerItemInfo = real
bench.Done()
