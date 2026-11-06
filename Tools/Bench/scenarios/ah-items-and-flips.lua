-- AH items (gear) are recorded when bought, and selling one to a vendor is
-- a flip: a sale marked vendor, with what you paid as its cost. Junk sold
-- to a vendor stays out, and Buy to vendor honours its minimum (user,
-- 2026-11-05).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local world = bench.world

local SWORD, AXE, JUNK = 990001, 990002, 990003
bench.AddItem(SWORD, "Bench Sword", { sellPrice = 500 })
bench.AddItem(AXE, "Bench Axe", { sellPrice = 300 })
bench.AddItem(JUNK, "Bench Junk", { sellPrice = 100 })
local function Listing(id, itemID, name, buyout)
    return { auctionID = id, itemKey = { itemID = itemID }, quantity = 1, buyoutAmount = buyout,
        itemLink = "|cffffffff|Hitem:" .. itemID .. "|h[" .. name .. "]|h|r" }
end
local function Count(name)
    local n, last = 0, nil
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.item == name then n, last = n + 1, e end
    end
    return n, last
end

world.itemResults = { Listing(1, SWORD, "Bench Sword", 400), Listing(2, SWORD, "Bench Sword", 450),
    Listing(3, AXE, "Bench Axe", 1000) }
bench.Fire("ITEM_SEARCH_RESULTS_UPDATED", { itemID = SWORD })
bench.SetMoney(GetMoney())

-- Bought: the game says so, then the gold leaves. Recorded once.
C_AuctionHouse.PlaceBid(1, 400)
bench.Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 1)
bench.SetMoney(GetMoney() - 400)
local n, e = Count("Bench Sword")
bench.Equal("recorded once", n, 1)
bench.Equal("what it cost", e and e.totalCopper, 400)
bench.Equal("its item", e and e.itemID, SWORD)
bench.Has("says so in chat", bench.Chat(), "Bought Bench Sword", true)

-- Bought: only the gold leaves
C_AuctionHouse.PlaceBid(2, 450)
bench.SetMoney(GetMoney() - 450)
n = Count("Bench Sword")
bench.Equal("recorded from the gold", n, 2)

-- A bid under buyout isn't a purchase
C_AuctionHouse.PlaceBid(3, 200)
bench.Fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 3)
bench.SetMoney(GetMoney() - 200)
n = Count("Bench Axe")
bench.Equal("a bid isn't recorded", n, 0)

-- Sold to a vendor
local real = C_Container.GetContainerItemInfo
local slotItem = SWORD
C_Container.GetContainerItemInfo = function() return { itemID = slotItem, stackCount = 1 } end
C_Container.UseContainerItem(0, 1)
bench.Equal("not at a vendor: no sale", select(2, Count("Bench Sword")).type, "COST")
bench.Fire("MERCHANT_SHOW")
C_Container.UseContainerItem(0, 1)
local sale = select(2, Count("Bench Sword"))
bench.Equal("a sale", sale.type, "REVENUE")
bench.Equal("marked vendor", sale.vendor, true)
bench.Equal("vendor's price", sale.totalCopper, 500)
bench.Equal("oldest purchase's cost", sale.costBasis, 400)
bench.Has("flip line", bench.Chat(), "Flipped Bench Sword", true)
C_Container.UseContainerItem(0, 1)
sale = select(2, Count("Bench Sword"))
bench.Equal("second sword's cost", sale.costBasis, 450)
C_Container.UseContainerItem(0, 1)
bench.Equal("nothing bought left: no sale", (Count("Bench Sword")), 4)
slotItem = JUNK
C_Container.UseContainerItem(0, 1)
bench.Equal("junk stays out", (Count("Bench Junk")), 0)
bench.Fire("MERCHANT_CLOSED")
C_Container.GetContainerItemInfo = real

-- Not sell speed or sale price
bench.Check("vendor sales aren't demand", addon:GetOwnDemand("Bench Sword") == nil)
bench.Check("or a sale price", addon:GetOwnSalePrice("Bench Sword") == nil)

-- Buy to vendor's minimum
C_AuctionHouse.GetBrowseResults = function()
    return { { itemKey = { itemID = SWORD }, minPrice = 480 }, { itemKey = { itemID = AXE }, minPrice = 200 } }
end
addon:SetSetting("flipMin", 50)
bench.Chat()
addon:FindVendorFlips("pages")
bench.Advance(3)
bench.Has("only the one over 50c", bench.Chat(), "1 items on the AH", true)
addon:SetSetting("flipMin", 0)
addon:FindVendorFlips("pages")
bench.Advance(3)
bench.Has("Any profit lists both", bench.Chat(), "2 items on the AH", true)
bench.Done()
