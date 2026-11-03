-- Rereads that find the same data keep the caches, so the window doesn't
-- load again for nothing (user, 2026-11-03: "goldsmith loads too much"):
-- a currency that isn't concentration, the same bags recounted, a vendor
-- opened again. A real change still reloads.
local bench = dofile(BENCH_DIR .. "bench.lua")
local db = bench.LoadSaved()
local currency = db.concentrationCurrency and db.concentrationCurrency.Alchemy
local addon = bench.Login("Mysticmead", { db = db })
bench.world.currencies = { [currency] = { quantity = 500 } }
bench.Fire("CURRENCY_DISPLAY_UPDATE")
bench.Advance(3)
addon:ToggleWindow()
addon:ShowTab("characters")
bench.Advance(15)

local function Reloads(name, want, fn)
    local version = addon.dataVersion
    fn()
    bench.Equal(name, addon.dataVersion ~= version, want)
end

-- Currency
Reloads("another currency: no reload", false, function()
    bench.Fire("CURRENCY_DISPLAY_UPDATE")
    bench.Advance(3)
end)
Reloads("concentration changed: reload", true, function()
    bench.world.currencies[currency].quantity = 450
    bench.Fire("CURRENCY_DISPLAY_UPDATE")
    bench.Advance(3)
end)

-- Bags
Reloads("same bags recounted: no reload", false, function()
    bench.Fire("BAG_UPDATE_DELAYED")
    bench.Advance(12)
end)
local some
for id in pairs(bench.world.bags) do some = some or id end
Reloads("bags changed: reload", true, function()
    bench.SetBags({ [some] = (bench.world.bags[some] or 0) + 3 })
    bench.Advance(12)
end)

-- Vendor
local VIAL = 240991 -- Sunglass Vial
local items = { { itemID = VIAL, name = "Sunglass Vial", price = 12345, stack = 1 } }
Reloads("new vendor price: reload", true, function()
    bench.OpenVendor(items)
    bench.Advance(2)
end)
bench.CloseVendor()
Reloads("same vendor again: no reload", false, function()
    bench.OpenVendor(items)
    bench.Fire("MERCHANT_UPDATE")
    bench.Advance(2)
end)
-- A vendor of things no recipe uses or makes (food, armor): saved, no reload
bench.CloseVendor()
Reloads("vendor of non-materials: no reload", false, function()
    bench.OpenVendor({ { itemID = 999999001, name = "Bench Bread", price = 500, stack = 1 } })
    bench.Advance(2)
end)
bench.Check("its price is saved", addon:GetVendorPrice(999999001) == 500)
bench.Done()
