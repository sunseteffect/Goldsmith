-- Break-even on the AH posting screen, above the Post button (Idea Board;
-- user, 2026-11-10): the break-even and the profit each at the price typed
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
local BAG = 990071
bench.AddItem(BAG, "Bench Bag", { sellPrice = 100, stack = 1 })
-- Made for 3s 59c each: break-even 3s 78c
addon.GetUnitCostBasis = function() return 359, false, "crafted" end

-- Stand-in sell frame: an item in it, a price typed, a Post button
local sell = CreateFrame("Frame", nil, AuctionHouseFrame)
sell:SetSize(300, 400)
sell.PostButton = CreateFrame("Button", nil, sell)
local price = 500
sell.PriceInput = { GetAmount = function() return price end }
sell.QuantityInput = { GetQuantity = function() return 1 end }
local item = { bag = 0, slot = 1 }
sell.GetItem = function() return item end
AuctionHouseFrame.ItemSellFrame = sell
C_Item.DoesItemExist = function(loc) return loc == item end
C_Item.GetItemID = function() return BAG end
C_Item.GetItemName = function() return "Bench Bag" end
sell:Show()

addon.UpdatePostInfo()
local text = table.concat(bench.TextOf(sell), "\n")
bench.Has("break-even shown", text, "break-even " .. addon:FormatMoney(378), true)
bench.Has("profit at 5s", text, "At " .. addon:FormatMoney(500) .. ": +" .. addon:FormatMoney(500 * 0.95 - 359), true)

-- Under break-even: a loss, with a minus
price = 300
addon.UpdatePostInfo()
text = table.concat(bench.TextOf(sell), "\n")
bench.Has("loss at 3s", text, "-" .. addon:FormatMoney(359 - 300 * 0.95), true)

-- No price typed yet: just the break-even
price = 0
addon.UpdatePostInfo()
text = table.concat(bench.TextOf(sell), "\n")
bench.HasNot("no price: no profit line", text, "each", true)

-- Gathered or looted (no gold spent): nothing
addon.GetUnitCostBasis = function() return 359, false, "gathered" end
addon.UpdatePostInfo()
bench.Equal("gathered: nothing shown", #bench.TextOf(sell), 0)
-- Back to a crafted cost for the Auctionator part
addon.GetUnitCostBasis = function() return 359, false, "crafted" end
price = 500

-- Auctionator's Selling tab: its sale item frame and AuctionatorPostButton
local sale = CreateFrame("Frame", nil, AuctionHouseFrame)
_G.AuctionatorPostButton = CreateFrame("Button", nil, sale)
sale.itemInfo = { location = item }
sale.Price = { GetAmount = function() return 450 end }
sale.Quantity = { GetNumber = function() return 5 end }
sell:Hide()
sale:Show()
addon.UpdatePostInfo()
local atext = table.concat(bench.TextOf(sale), "\n")
bench.Has("Auctionator: break-even", atext, "break-even " .. addon:FormatMoney(378), true)
bench.Has("Auctionator: one line with the profit", atext, "At " .. addon:FormatMoney(450), true)
bench.HasNot("Auctionator: one line", atext, "\n", true)
sale.itemInfo = nil
addon.UpdatePostInfo()
bench.Equal("Auctionator, no item: nothing", #bench.TextOf(sale), 0)
bench.Done()
