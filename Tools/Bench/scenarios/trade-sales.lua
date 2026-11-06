-- Items sold in the trade window are sales: recorded when the trade
-- completes, with the gold split by what each item is worth. No AH cut, no
-- sell speed or sale price. Items you get count at their AH price, as part
-- of the sale and as a purchase with no gold spent. Your own characters,
-- gifts and cancelled trades aren't sales (user, 2026-11-06).
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")

local BAG, CLOAK, CLOTH, ODD = 990001, 990002, 990003, 990004
bench.AddItem(BAG, "Bench Bag", { sellPrice = 100 })
bench.AddItem(CLOAK, "Bench Cloak", { sellPrice = 300 })
bench.AddItem(CLOTH, "Bench Cloth", { sellPrice = 5 })
bench.AddItem(ODD, "Bench Odd", { sellPrice = 0 })
ERR_TRADE_COMPLETE, ERR_TRADE_CANCELLED = "Trade complete.", "Trade cancelled."

local window = {}
GetTradePlayerItemInfo = function(slot)
    local s = window.give and window.give[slot]
    if s then return s.name, 0, s.count end
end
GetTradePlayerItemLink = function(slot)
    local s = window.give and window.give[slot]
    return s and ("item:" .. s.id)
end
GetTradeTargetItemInfo = function(slot)
    local s = window.get and window.get[slot]
    if s then return s.name, 0, s.count end
end
GetTradeTargetItemLink = function(slot)
    local s = window.get and window.get[slot]
    return s and ("item:" .. s.id)
end
GetTargetTradeMoney = function() return window.gold or 0 end
GetPlayerTradeMoney = function() return window.pay or 0 end
C_Item.GetItemInfoInstant = function(link) return tonumber(tostring(link):match("(%d+)")) end
local realUnitName = UnitName
UnitName = function(unit)
    if unit == "NPC" then return window.partner end
    return realUnitName(unit)
end
addon.GetAHPrice = function(_, itemID) return ({ [BAG] = 400, [CLOAK] = 1200, [CLOTH] = 20 })[itemID] end

local function Trade(state, finish)
    window = state
    bench.Fire("TRADE_SHOW")
    bench.Fire("TRADE_ACCEPT_UPDATE", 1, 0)
    bench.Fire("TRADE_ACCEPT_UPDATE", 1, 1)
    window = {}
    bench.Fire("TRADE_CLOSED")
    bench.Fire("UI_INFO_MESSAGE", 0, finish or ERR_TRADE_COMPLETE)
end
local function Sales(name)
    local list = {}
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "REVENUE" and e.item == name then table.insert(list, e) end
    end
    return list
end
local function Bag(n) return { id = BAG, name = "Bench Bag", count = n } end
local function Cloak() return { id = CLOAK, name = "Bench Cloak", count = 1 } end
local function Cloth(n) return { id = CLOTH, name = "Bench Cloth", count = n } end
local function Purchases(name)
    local list = {}
    for _, e in ipairs(addon.ledger:getAll()) do
        if e.type == "COST" and e.item == name then table.insert(list, e) end
    end
    return list
end

-- One item, two slots
bench.Chat()
Trade({ partner = "Stranger", gold = 800, give = { Bag(1), Bag(1) } })
local s = Sales("Bench Bag")
bench.Equal("one sale", #s, 1)
bench.Equal("two bags", s[1] and s[1].quantity, 2)
bench.Equal("the gold", s[1] and s[1].totalCopper, 800)
bench.Equal("who", s[1] and s[1].trade, "Stranger")
bench.Equal("no deposit", s[1] and s[1].depositRefund, 0)
bench.Has("chat", bench.Chat(), "Sold Bench Bag x2 to Stranger", true)

-- Two items: split by worth (400 and 1200), all the gold kept
Trade({ partner = "Stranger", gold = 1000, give = { Bag(1), Cloak() } })
s = Sales("Bench Bag")
local c = Sales("Bench Cloak")
bench.Equal("bag's part", s[2] and s[2].totalCopper, 250)
bench.Equal("cloak's part", c[1] and c[1].totalCopper, 750)

-- Not AH sales
bench.Check("not sell speed", addon:GetOwnDemand("Bench Cloak") == nil)
bench.Check("not a sale price", addon:GetOwnSalePrice("Bench Cloak") == nil)

-- Not sales
local before = #Sales("Bench Bag")
Trade({ partner = addon.char.name, gold = 500, give = { Bag(1) } })
bench.Equal("own character", #Sales("Bench Bag"), before)
Trade({ partner = "Stranger", give = { Bag(1) } })
bench.Equal("a gift", #Sales("Bench Bag"), before)
Trade({ partner = "Stranger", gold = 500, give = { Bag(1) }, get = { { id = ODD, name = "Bench Odd", count = 1 } } })
bench.Equal("an item with no price", #Sales("Bench Bag"), before)
bench.Equal("nothing got recorded", #Purchases("Bench Odd"), 0)
Trade({ partner = "Stranger", gold = 100, pay = 500, give = { Bag(1) } })
bench.Equal("you paid", #Sales("Bench Bag"), before)
Trade({ partner = "Stranger", gold = 500 })
bench.Equal("a tip, no item", #Sales("Bench Bag"), before)
Trade({ partner = "Stranger", gold = 500, give = { Bag(1) } }, ERR_TRADE_CANCELLED)
bench.Equal("cancelled", #Sales("Bench Bag"), before)
bench.Fire("UI_INFO_MESSAGE", 0, ERR_TRADE_COMPLETE)
bench.Equal("a later trade doesn't bring it back", #Sales("Bench Bag"), before)

-- 3 bags for 18 cloth (20 each) and 90c: the favor from 2026-11-06
bench.Chat()
Trade({ partner = "Stranger", gold = 90, give = { Bag(3) }, get = { Cloth(18) } })
s = Sales("Bench Bag")
local swap = s[#s]
bench.Equal("the sale's worth", swap and swap.totalCopper, 450)
bench.Equal("marked a swap", swap and swap.swap, true)
local got = Purchases("Bench Cloth")
bench.Equal("cloth recorded", #got, 1)
bench.Equal("at its AH price", got[1] and got[1].totalCopper, 360)
bench.Equal("marked from the trade", got[1] and got[1].trade, "Stranger")
bench.Equal("its item", got[1] and got[1].itemID, CLOTH)
local chat = bench.Chat()
bench.Has("sale line", chat, "Sold Bench Bag x3 to Stranger", true)
bench.Has("got line", chat, "Got Bench Cloth x18 in the trade", true)

-- Only items back
Trade({ partner = "Stranger", give = { Cloak() }, get = { Cloth(10) } })
c = Sales("Bench Cloak")
bench.Equal("items for items", c[#c] and c[#c].totalCopper, 200)
bench.Done()
