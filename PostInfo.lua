local addon = _G.Goldsmith or {}

-- Break-even on the AH posting screen
--
-- Under the Post button on the game's sell screens (commodities and
-- items) and Auctionator's Selling tab: the break-even of the item you're posting and the profit each
-- at the price typed in, so you don't have to hover the item to check
-- (Idea Board, 2026-10-29; built 2026-11-10, user: "i find myself mostly
-- look at break even cost"). The same cost as the "posted under
-- break-even" warning (Core.lua's PostCost): your crafts or what you paid,
-- never an estimate; nothing shows for gathered or looted items.

local AH_CUT = 0.05
local CHECK_EVERY = 0.25

local lines = {} -- sell frame -> its font string

-- Each sell screen: its frame, Post button, and how to read the item,
-- price each and quantity. Under the Post button: above it, the text sat
-- on the game's Total Price (user, 2026-11-10). Auctionator's Selling tab
-- too (user, 2026-11-10: "lets support auctionator selling"): one line
-- after the item's name on its title line. Under its Post button it sat
-- against the price list's headers (user, 2026-11-10: "i don't like the
-- auctionator break even text placement").
local function Get(fn, ...)
    local ok, value = pcall(fn, ...)
    if ok then return value end
end
local function Screens()
    local ah, list = AuctionHouseFrame, {}
    for _, frame in ipairs({ ah and ah.CommoditiesSellFrame, ah and ah.ItemSellFrame }) do
        if frame then table.insert(list, {
            frame = frame, button = frame.PostButton, oneLine = false,
            item = function() return frame:GetItem() end,
            price = function() return frame.PriceInput:GetAmount() end,
            quantity = function() return frame.QuantityInput:GetQuantity() end,
        }) end
    end
    -- Auctionator's modern-AH Selling tab (its sale item frame)
    local post = _G.AuctionatorPostButton
    local sale = post and post:GetParent()
    if sale then
        table.insert(list, {
            frame = sale, button = post, oneLine = true,
            title = sale.TitleArea and sale.TitleArea.Text,
            item = function() return sale.itemInfo and sale.itemInfo.location end,
            price = function() return sale.Price:GetAmount() end,
            quantity = function() return sale.Quantity:GetNumber() end,
        })
    end
    return list
end

local function LineFor(screen)
    local frame = screen.frame
    if lines[frame] then return lines[frame] end
    if not screen.button then return nil end
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    if screen.title then
        text:SetPoint("LEFT", screen.title, "RIGHT", 24, 0)
        text:SetWidth(420)
        text:SetJustifyH("LEFT")
    else
        text:SetPoint("TOP", screen.button, "BOTTOM", 0, screen.oneLine and -4 or -8)
        text:SetWidth(screen.oneLine and 360 or math.max((frame:GetWidth() or 0) - 30, 200))
        text:SetJustifyH("CENTER")
    end
    text:SetWordWrap(not screen.oneLine)
    lines[frame] = text
    return text
end

-- The text for what's in the sell screen now, or ""
local function TextFor(screen)
    local item = Get(screen.item)
    if not (item and C_Item.DoesItemExist(item)) then return "" end
    local itemID, name = C_Item.GetItemID(item), C_Item.GetItemName(item)
    local quantity = Get(screen.quantity)
    local cost = addon:PostCost(itemID, name, quantity and quantity > 0 and quantity or 1)
    if not cost then return "" end
    local text = addon:Colorize("Goldsmith break-even " .. addon:FormatMoney(cost / (1 - AH_CUT)), "gold")
    local price = Get(screen.price)
    if price and price > 0 then
        local each = price * (1 - AH_CUT) - cost
        text = text .. (screen.oneLine and addon:Colorize("  ·  ", "muted") or "\n")
            .. addon:Colorize(string.format("At %s: %s each", addon:FormatMoney(price),
                addon:FormatSignedMoney(each)), addon:MoneyColor(each))
    end
    return text
end

local function Update()
    for _, screen in ipairs(Screens()) do
        if screen.frame and screen.frame:IsShown() then
            local line = LineFor(screen)
            if line then
                local ok, text = pcall(TextFor, screen)
                line:SetText(ok and text or "")
                line:SetShown(ok and text ~= "")
            end
        end
    end
end
addon.UpdatePostInfo = Update -- for the bench

-- Checked a few times a second while the AH is open: typing a price fires
-- no event an addon can count on
local ticker
local events = CreateFrame("Frame")
events:RegisterEvent("AUCTION_HOUSE_SHOW")
events:RegisterEvent("AUCTION_HOUSE_CLOSED")
events:SetScript("OnEvent", function(_, event)
    if event == "AUCTION_HOUSE_SHOW" then
        if not ticker then ticker = C_Timer.NewTicker(CHECK_EVERY, Update) end
    elseif ticker then
        ticker:Cancel()
        ticker = nil
    end
end)

_G.Goldsmith = addon
