local ADDON_NAME = "Goldsmith"
local addon = _G.Goldsmith or {}
-- WoW Forever (project "Camelot", 18): one expansion, no qualities or
-- concentration, prices mostly silver and copper
addon.isForever = WOW_PROJECT_ID == (WOW_PROJECT_CAMELOT or 18)

-- Purchase in flight: { itemID, quantity, moneyBefore }
local pending = nil
local awaitingMoney = false

-- Text written for retail, in Forever: it has no concentration, so lists
-- like "Gold in stock, concentration, total gold" drop it
function addon:ForeverText(text)
    if not (addon.isForever and text) then return text end
    return (text:gsub(", concentration,", ","):gsub("concentration, ", ""))
end

-- Gold in a chat line: "12.40g" on retail as always; Forever's silver and
-- copper (FormatMoney), where 0.12g told nothing (stress test, 2026-10-21)
local function ChatGold(copper)
    if addon.isForever then return addon:FormatMoney(copper) end
    return string.format("%.2fg", copper / 10000)
end

local function Print(msg, ...)
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

-- Ways to open the window besides /gsm: a key (Bindings.xml; these name it
-- in Options > Keybindings > Goldsmith) and the addon compartment next to the
-- minimap (## AddonCompartmentFunc in the TOC)
BINDING_HEADER_GOLDSMITH = "Goldsmith"
BINDING_NAME_GOLDSMITH_TOGGLE = "Show or hide the window"
BINDING_NAME_GOLDSMITH_CRAFT_NEXT = "Craft next in the queue"
BINDING_NAME_GOLDSMITH_BUY_NEXT = "Buy next for the queue"
BINDING_NAME_GOLDSMITH_OPEN_ITEM = "Open hovered item"
BINDING_NAME_GOLDSMITH_PEEK = "Hold to see through"

function Goldsmith_OnAddonCompartmentClick()
    addon:ToggleWindow()
end

-- Called when the player confirms a commodity purchase on the AH.
-- Snapshot gold now so the actual cost can be taken from the change in money.
-- Every commodity purchase is recorded so average costs are available for any
-- reagent; items not in a tracked list are saved as Unassigned.
local function OnConfirmCommoditiesPurchase(itemID, quantity)
    -- The last purchase, still waiting for its gold to settle: recorded now,
    -- or this one replaces it and it's never saved (Bazaar Bites and Blood
    -- Hunter bought back to back went missing, 2026-10-27)
    if pending and awaitingMoney and GetMoney() < pending.moneyBefore then
        addon:RecordPurchase()
    end
    local itemData = addon.INSCRIPTION_ITEMS[itemID]
    local name = (itemData and itemData.name) or C_Item.GetItemNameByID(itemID)
    if not name then
        pending = nil
        return
    end

    pending = {
        itemID = itemID,
        name = name,
        quantity = quantity,
        moneyBefore = GetMoney(),
        -- Buy next's plan for it, kept with it: the next purchase's would
        -- replace it before this one is recorded
        planned = addon.buyNextPlanned,
    }
    addon.buyNextPlanned = nil
    awaitingMoney = false
end

-- Bought, its gold not settled yet: Buy next waits (the press is ignored)
-- so the next purchase's gold can't be counted as this one's. A few
-- seconds at most, in case the gold never moves.
function addon:PurchaseSettling()
    return pending ~= nil and awaitingMoney and GetTime() - (pending.succeeded or 0) < 5
end

function addon:RecordPurchase()
    local p = pending
    pending = nil
    awaitingMoney = false
    if not p then return end

    local spent = p.moneyBefore - GetMoney()
    if spent <= 0 then return end

    local prof = addon:GetProfessionForItemName(p.name) or "Unassigned"
    addon.ledger:addCost(prof, p.name, p.quantity, spent, "PURCHASE", p.itemID)
    -- Bought with Buy next: how far from the plan, in all (user, 2026-10-19:
    -- "show the variance in price we paid vs the plan. keep it short"; the
    -- difference reads quicker than the plan's price each)
    local planned = p.planned
    local plannedText = ""
    if planned and planned.itemID == p.itemID and planned.quantity == p.quantity and planned.cost then
        local diff = spent - planned.cost
        if math.abs(diff) < 100 then
            plannedText = ", on plan"
        else
            plannedText = string.format(", %s %s plan", ChatGold(math.abs(diff)), diff > 0 and "over" or "under")
        end
    end
    addon:Notify("money", "Bought %s x%d for %s (%s each%s)",
        p.name, p.quantity, ChatGold(spent), ChatGold(spent / p.quantity), plannedText)
    addon:ShoppingListBought(p.itemID, p.quantity)
    if addon.QueueBought then addon:QueueBought(p.itemID, p.quantity) end

    if addon.Refresh then
        addon.Refresh()
    end
end

-- Vendor purchases. Only items that belong to a tracked profession (e.g.
-- reagents from a saved recipe) are recorded, so food and other shopping
-- stays out of the ledger. Items bought with currencies are skipped.
local function GetMerchantInfo(index)
    if C_MerchantFrame and C_MerchantFrame.GetItemInfo then
        local info = C_MerchantFrame.GetItemInfo(index)
        if info then
            return info.name, info.price, info.stackCount, info.hasExtendedCost
        end
    elseif GetMerchantItemInfo then
        local name, _, price, stackCount, _, _, _, hasExtendedCost = GetMerchantItemInfo(index)
        return name, price, stackCount, hasExtendedCost
    end
end

local function OnBuyMerchantItem(index, quantity)
    local name, price, stackCount, hasExtendedCost = GetMerchantInfo(index)
    if not name or not price or price <= 0 or hasExtendedCost then return end

    local prof = addon:GetProfessionForItemName(name)
    if not prof then return end

    -- price is for one stack of stackCount items
    stackCount = (stackCount and stackCount > 0) and stackCount or 1
    local units = quantity or stackCount
    local total = math.floor(price / stackCount * units + 0.5)

    addon.ledger:addCost(prof, name, units, total, "PURCHASE", GetMerchantItemID(index))
    addon:Notify("money", "Bought %s x%d from a vendor for %s", name, units, ChatGold(total))

    if addon.Refresh then
        addon.Refresh()
    end
end

-- Sales are recorded when you collect the gold from an "Auction successful"
-- mail, but only once your gold actually goes up by that mail's amount. A
-- collect that doesn't go through (e.g. the mailbox closes first) records
-- nothing, so the same mail can't be counted again later.
local pendingSales = {}
local knownMoney = nil
local SALE_TIMEOUT = 15

-- After the sale lines, the gold they brought in (user, 2026-10-27:
-- "after we display all of the lines can we have a total"): once no AH
-- sale is left in the mailbox, or it closes, for two or more sales.
-- What it sold for, not profit: a sale's profit depends on where the item
-- came from (crafted, bought, a patron bag, an order's reward), which a
-- chat line can't explain; History does (user, 2026-10-27: "a can of
-- worms of complexity and questions and confusion").
local TOTAL_CHECK = 1
local saleRun
local function FlushSaleRun()
    local r = saleRun
    saleRun = nil
    if not r or r.sales < 2 then return end
    addon:Notify("money", "Total: %s", addon:Colorize(addon:FormatMoney(r.gold), "profit"))
end
local function SalesLeftInMail()
    local shown, total = GetInboxNumItems()
    if total and shown and total > shown then return true end
    for i = 1, shown or 0 do
        local money = select(5, GetInboxHeaderInfo(i))
        if money and money > 0 and GetInboxInvoiceInfo(i) == "seller" then return true end
    end
    return false
end
local function AddToSaleRun(gold)
    saleRun = saleRun or { gold = 0, sales = 0 }
    saleRun.gold, saleRun.sales = saleRun.gold + gold, saleRun.sales + 1
    C_Timer.After(TOTAL_CHECK, function() addon:CheckSaleTotal() end)
end
function addon:FlushSaleTotal() FlushSaleRun() end
-- Also on each inbox update: the sale mail may still show its gold a
-- moment after it's taken. Not while a sale waits for its gold.
function addon:CheckSaleTotal()
    if saleRun and #pendingSales == 0 and not SalesLeftInMail() then FlushSaleRun() end
end

-- Whether Goldsmith recorded a deposit for this item in the 32 days before
-- (AH mail lasts 30 days, a listing up to 2)
local function DepositOnRecord(itemName)
    local since = time() - 32 * 86400
    for _, e in ipairs(GoldsmithDB.entries or {}) do
        if e.type == "COST" and e.kind == "DEPOSIT" and e.item == itemName and (e.timestamp or 0) >= since then
            return true
        end
    end
    return false
end

local function RecordSale(sale)
    local prof = addon:GetProfessionForItemName(sale.itemName) or "Unassigned"
    -- Posted before Goldsmith recorded deposits: its deposit was never
    -- counted as a cost, so the refund isn't income either (a 1s refund
    -- made a losing sale look 1s better; stress test, 2026-10-21)
    if (sale.depositRefund or 0) > 0 and not DepositOnRecord(sale.itemName) then
        sale.net = sale.net - sale.depositRefund
        sale.depositRefund = 0
    end

    -- Which quality it was, from your post at that price (the mail only
    -- names it), so silver and gold aren't costed as a blend
    local itemID = sale.bid and sale.count and sale.count > 0
        and addon:MatchSaleToPost(sale.itemName, sale.count, sale.bid / sale.count) or nil
    -- Snapshot what the items cost you now, so the sale's profit doesn't
    -- shift later as material prices change
    local unitCost, partial, costSource = addon:GetUnitCostBasis(sale.itemName, sale.count, itemID)
    local costBasis = unitCost and math.floor(unitCost * sale.count + 0.5)
    addon.ledger:addRevenue(prof, sale.itemName, sale.count, sale.net, costBasis, partial, sale.depositRefund,
        costBasis and costSource, itemID, { soldAt = sale.soldAt })
    addon:AuctionSold(sale.itemName, sale.count, itemID)

    -- One line: the item and the gold it brought in (user, 2026-10-27:
    -- "its too much text"). Its profit is in History, which explains it
    -- (see the total above).
    addon:Notify("money", "Sold %s: %s", sale.itemName, addon:Colorize(addon:FormatMoney(sale.net), "profit"))
    AddToSaleRun(sale.net)
end

local function OnTakeMailMoney(index)
    local _, _, _, _, money, _, daysLeft = GetInboxHeaderInfo(index)
    if not money or money <= 0 then return end

    local invoiceType, itemName, _, bid, _, deposit, consignment, _, _, _, count = GetInboxInvoiceInfo(index)
    if invoiceType ~= "seller" or not itemName then return end

    -- Clicking the gold and looting the whole mail can both fire for one mail
    local key = table.concat({ itemName, bid, count or 1, daysLeft }, ":")
    for _, sale in ipairs(pendingSales) do
        if sale.key == key then return end
    end

    if #pendingSales == 0 then
        knownMoney = GetMoney()
    end

    table.insert(pendingSales, {
        key = key,
        money = money,
        itemName = itemName,
        count = count or 1,
        -- The deposit is logged as a cost when posting, so its refund counts as revenue
        net = bid + (deposit or 0) - (consignment or 0),
        depositRefund = deposit or 0,
        -- What it sold for before the cut, to match it to your post (its quality)
        bid = bid,
        -- When it sold (the entry's timestamp is when you collected it): the
        -- mail arrived then, and AH mail lasts 30 days
        soldAt = daysLeft and daysLeft <= 30 and time() - math.floor((30 - daysLeft) * 86400) or nil,
        time = GetTime(),
    })
end

-- Match a gold increase to waiting sales: one mail's exact amount, or
-- several mails in a row if the game reports them together.
local function OnMoneyIncreased(increase)
    local now = GetTime()
    for i = #pendingSales, 1, -1 do
        if now - pendingSales[i].time > SALE_TIMEOUT then
            table.remove(pendingSales, i)
        end
    end

    local matched
    for i, sale in ipairs(pendingSales) do
        if sale.money == increase then
            matched = { i }
            break
        end
    end
    if not matched then
        local sum = 0
        for i, sale in ipairs(pendingSales) do
            sum = sum + sale.money
            if sum == increase then
                matched = {}
                for j = 1, i do
                    table.insert(matched, j)
                end
                break
            end
        end
    end
    if not matched then return end

    -- Remove from the back so indexes stay valid, then record in mail order
    local sales = {}
    for n = #matched, 1, -1 do
        table.insert(sales, 1, table.remove(pendingSales, matched[n]))
    end
    for _, sale in ipairs(sales) do
        RecordSale(sale)
    end
    if addon.Refresh then
        addon.Refresh()
    end
end

-- Deposits are worked out when an auction is posted and recorded once the AH
-- confirms it was created. Posts are confirmed in order, so a queue matches them.
local pendingPosts = {}
-- A post the game didn't confirm in POST_TIMEOUT never went up: no auction,
-- no deposit, and no message from the game (user, 2026-11-05: 5 of 9 Linen
-- Bag posts). Says so, with the game's error if there was one, and keeps
-- the details in GoldsmithDB.postFails to find out why. Forgets the post,
-- so a sale can't match a price that was never listed.
local POST_TIMEOUT = 5
local POST_FAILS_KEPT = 20
local function PostUnconfirmed(post)
    for i, p in ipairs(pendingPosts) do
        if p == post then
            table.remove(pendingPosts, i)
            local posts = GoldsmithDB.posts or {}
            for j = #posts, 1, -1 do
                if posts[j] == post.remembered then table.remove(posts, j) break end
            end
            GoldsmithDB.postFails = GoldsmithDB.postFails or {}
            local fails = GoldsmithDB.postFails
            table.insert(fails, { time = time(), name = post.name, quantity = post.quantity, deposit = post.deposit,
                bid = post.bid, buyout = post.buyout, duration = post.duration, reason = post.reason })
            while #fails > POST_FAILS_KEPT do table.remove(fails, 1) end
            -- Items take whole silver in Forever; the window lets you type
            -- copper and the game drops the post without a word (5 Linen
            -- Bag posts failed with copper, all whole silver ones worked;
            -- commodities take copper). User, 2026-11-06.
            if post.item and ((post.buyout or 0) % 100 ~= 0 or (post.bid or 0) % 100 ~= 0) then
                addon:Notify("loss", "%s didn't post: item prices can't have copper. Use whole silver.", post.name or "An item")
            elseif post.reason then
                addon:Notify("loss", "%s didn't post: %s", post.name or "An item", post.reason)
            else
                addon:Notify("loss", "%s didn't post. Check your Auctions tab.", post.name or "An item")
            end
            return
        end
    end
end

local function QueuePost(itemLocation, deposit, quantity, details)
    if not deposit or deposit <= 0 then return end
    if not C_Item.DoesItemExist(itemLocation) then return end
    -- The exact item and its Goldsmith Data sell level when posted, to check
    -- later how well levels predict what sells (GoldsmithData
    -- tools/score-levels.js)
    local itemID = C_Item.GetItemID(itemLocation)
    local post = details or {}
    post.name = C_Item.GetItemName(itemLocation)
    post.itemID = itemID
    post.level = addon:GetSellLevel(itemID)
    post.quantity = quantity
    post.deposit = deposit
    post.time = GetTime()
    table.insert(pendingPosts, post)
    C_Timer.After(POST_TIMEOUT, function() PostUnconfirmed(post) end)
end

-- What you post, by exact item and price per unit (GoldsmithDB.posts), so a
-- sale mail, which only names the item, can be matched to its quality by
-- price: silver and gold of a crafted item sell for very different prices,
-- and were costed as a blend of both (user, 2026-10-10). Kept 3 days (the
-- longest an auction runs is 2), at most POSTS_KEPT.
local POSTS_KEPT, POST_DAYS = 300, 3
local function RememberPost(itemLocation, quantity, unitPrice)
    if not (quantity and quantity > 0 and unitPrice and unitPrice > 0) then return end
    if not C_Item.DoesItemExist(itemLocation) then return end
    GoldsmithDB.posts = GoldsmithDB.posts or {}
    local posts = GoldsmithDB.posts
    local post = { name = C_Item.GetItemName(itemLocation), itemID = C_Item.GetItemID(itemLocation),
        unitPrice = unitPrice, left = quantity, time = time() }
    table.insert(posts, post)
    local cutoff = time() - POST_DAYS * 86400
    while posts[1] and (#posts > POSTS_KEPT or posts[1].time < cutoff) do table.remove(posts, 1) end
    return post
end

-- The exact item a sale was most likely of: your post of that name, still
-- on the AH, whose price per unit is closest to the sale's. Takes the sold
-- units off it. nil when nothing matches (no post seen, or only of
-- another name).
function addon:MatchSaleToPost(itemName, count, unitPrice)
    local best, bestGap
    for _, post in ipairs(GoldsmithDB.posts or {}) do
        if post.name == itemName and (post.left or 0) > 0 and unitPrice and unitPrice > 0 then
            local gap = math.abs(post.unitPrice - unitPrice) / unitPrice
            if not bestGap or gap < bestGap then best, bestGap = post, gap end
        end
    end
    if not best then return nil end
    best.left = math.max(best.left - (count or 1), 0)
    return best.itemID
end

-- Posted under what yours cost you, after the AH cut: Goldsmith doesn't
-- post (the AH window or Auctionator does), so it can't stop it, only say
-- so right after, while cancelling costs just the deposit (error review,
-- 2026-10-23). Only from a real cost (your crafts or what you paid), not
-- a recipe's estimate, so a guess never cries wolf.
-- A chat line only: no raid warning or sound. Posting a pile of patron
-- order bag loot set one off per item (user, 2026-10-26: "in current
-- state this will get annoying even with no sound"). Once per item every
-- POST_WARN_GAP, so posting the same item again stays quiet.
local AH_CUT = 0.05
local POST_WARN_GAP = 15 * 60
local postWarned = {}
local function CheckPostPrice(itemLocation, quantity, unitPrice)
    if not (unitPrice and unitPrice > 0 and C_Item.DoesItemExist(itemLocation)) then return end
    local itemID, name = C_Item.GetItemID(itemLocation), C_Item.GetItemName(itemLocation)
    local cost, _, source = addon:GetUnitCostBasis(name, quantity, itemID)
    if not cost or cost <= 0 or (source ~= "crafted" and source ~= "paid") then return end
    -- Gathered and payout bag loot count at the AH price for a sale's
    -- profit, so their break-even sat over the market and every post of
    -- patron order bag loot warned (user, 2026-10-26). Here only the gold
    -- you spent counts; those are free.
    if source == "paid" then
        local _, _, parts = addon:GetOwnCost(name, nil, itemID, true)
        if parts then
            local spent, units = 0, 0
            for _, s in ipairs(parts) do
                if s[1] ~= "gathered" and s[1] ~= "free" then spent = spent + s[2] * s[3] end
                units = units + s[3]
            end
            cost = units > 0 and spent / units or cost
        end
        if cost <= 0 then return end
    end
    local breakEven = cost / (1 - AH_CUT)
    if unitPrice >= breakEven then return end
    local key = itemID or name
    if key and postWarned[key] and GetTime() - postWarned[key] < POST_WARN_GAP then return end
    if key then postWarned[key] = GetTime() end
    -- Red with a warning icon, and the loss itself: two prices to compare
    -- didn't stand out among the game's lines (user, 2026-10-27)
    addon:Notify("loss", "%s posted at %s: a loss of %s each (break-even %s). Cancel it if that's a mistake.",
        name or "An item", addon:FormatMoney(unitPrice), addon:FormatMoney(cost - unitPrice * (1 - AH_CUT)),
        addon:FormatMoney(breakEven))
end

local function OnPostCommodity(itemLocation, duration, quantity, unitPrice)
    if not C_Item.DoesItemExist(itemLocation) then return end
    local itemID = C_Item.GetItemID(itemLocation)
    local remembered = RememberPost(itemLocation, quantity, unitPrice)
    QueuePost(itemLocation, C_AuctionHouse.CalculateCommodityDeposit(itemID, duration, quantity), quantity,
        { remembered = remembered, buyout = unitPrice, duration = duration })
    pcall(CheckPostPrice, itemLocation, quantity, unitPrice)
end

local function OnPostItem(itemLocation, duration, quantity, bid, buyout)
    local price = buyout or bid
    local remembered = RememberPost(itemLocation, quantity, price and quantity and quantity > 0 and price / quantity)
    QueuePost(itemLocation, C_AuctionHouse.CalculateItemDeposit(itemLocation, duration, quantity), quantity,
        { remembered = remembered, item = true, bid = bid, buyout = buyout, duration = duration })
    if price and quantity and quantity > 0 then pcall(CheckPostPrice, itemLocation, quantity, price / quantity) end
end

-- The game's red error while a post waits: why it didn't go up
local postErrors = CreateFrame("Frame")
postErrors:RegisterEvent("UI_ERROR_MESSAGE")
postErrors:SetScript("OnEvent", function(_, _, _, message)
    local post = pendingPosts[#pendingPosts]
    if post then post.reason = message end
end)

local function RecordDeposit()
    local post = table.remove(pendingPosts, 1)
    if not post or not post.name then return end

    local prof = addon:GetProfessionForItemName(post.name) or "Unassigned"
    addon.ledger:addCost(prof, post.name, post.quantity, post.deposit, "DEPOSIT", nil,
        { postedID = post.itemID, sellLevel = post.level })
    addon:Notify("money", "Posted %s x%d, deposit %s", post.name, post.quantity, ChatGold(post.deposit))

    if addon.Refresh then
        addon.Refresh()
    end
end

-- Professions Goldsmith knows about, from saved recipes, tracked items and
-- the log, sorted by name. Unassigned isn't included.
function addon:GetProfessions()
    local seen = { Inscription = true }
    local function add(prof)
        if type(prof) == "string" and prof ~= "Unassigned" and addon:IsCraftingProfession(prof) then
            seen[prof] = true
        end
    end
    for _, recipe in pairs(GoldsmithDB.recipes or {}) do add(recipe.profession) end
    for _, prof in pairs(GoldsmithDB.products or {}) do add(prof) end
    for _, prof in pairs(GoldsmithDB.reagents or {}) do add(prof) end
    for _, e in ipairs(addon.ledger:getAll()) do add(e.profession) end
    for _, c in pairs(GoldsmithDB.characters or {}) do
        for prof in pairs(c.professions or {}) do add(prof) end
    end

    local list = {}
    for prof in pairs(seen) do
        table.insert(list, prof)
    end
    table.sort(list)
    return list
end

-- Profession icons. Your own professions' icons come from the game and are
-- remembered in GoldsmithDB.professionIcons; the rest fall back to these.
local FALLBACK_ICONS = {
    Alchemy = "Interface\\Icons\\Trade_Alchemy",
    Blacksmithing = "Interface\\Icons\\Trade_BlackSmithing",
    Cooking = "Interface\\Icons\\INV_Misc_Food_15",
    Enchanting = "Interface\\Icons\\Trade_Engraving",
    Engineering = "Interface\\Icons\\Trade_Engineering",
    Inscription = "Interface\\Icons\\INV_Inscription_Tradeskill01",
    Jewelcrafting = "Interface\\Icons\\INV_Misc_Gem_01",
    Leatherworking = "Interface\\Icons\\Trade_LeatherWorking",
    Tailoring = "Interface\\Icons\\Trade_Tailoring",
}

local function LearnProfessionIcons()
    GoldsmithDB.professionIcons = GoldsmithDB.professionIcons or {}
    for _, index in ipairs({ GetProfessions() }) do
        local name, icon = GetProfessionInfo(index)
        if name and icon then
            GoldsmithDB.professionIcons[name] = icon
        end
    end
end

function addon:GetProfessionIcon(prof)
    return (GoldsmithDB.professionIcons and GoldsmithDB.professionIcons[prof]) or FALLBACK_ICONS[prof]
end

-- Inline icon for putting in front of text, or "" if there's none
function addon:ProfessionIconText(prof)
    local icon = addon:GetProfessionIcon(prof)
    return icon and ("|T" .. icon .. ":14:14|t ") or ""
end

-- The game's concentration icon sized to the text, with a space after, from
-- any concentration currency Goldsmith has seen (learned when a profession
-- is opened); nil until one is known. Used in place of the word "conc":
-- "conc +859.10g" read as 859 concentration (user, 2026-10-16).
local concIcon
function addon:ConcentrationIconText()
    if concIcon then return concIcon end
    for _, id in pairs(GoldsmithDB.concentrationCurrency or {}) do
        if type(id) == "number" and id > 0 then
            local ok, info = pcall(C_CurrencyInfo.GetCurrencyInfo, id)
            if ok and info and info.iconFileID then
                concIcon = "|T" .. info.iconFileID .. ":0|t "
                return concIcon
            end
        end
    end
end

-- Assign every entry for an item to a profession, now and in future.
-- "Unassigned" takes it out of every profession.
function addon:AssignItem(itemName, prof)
    GoldsmithDB.products[itemName] = prof
    addon:ReassignProfessions()
    if prof == "Unassigned" then
        Print("%s is no longer counted under a profession.", itemName)
    else
        Print("%s is now tracked as %s.", itemName, prof)
    end
end

-- Work out each entry's profession again from the current item lists.
function addon:ReassignProfessions()
    for _, e in ipairs(addon.ledger:getAll()) do
        e.profession = addon:GetProfessionForItemName(e.item) or "Unassigned"
    end
    if addon.Refresh then
        addon.Refresh()
    end
end

-- A purchase is recorded a moment after the last change in gold
local settleCount = 0
local function SettleMoney()
    settleCount = settleCount + 1
    local mine = settleCount
    C_Timer.After(1, function()
        if mine == settleCount and awaitingMoney and pending and GetMoney() < pending.moneyBefore then
            addon:RecordPurchase()
        end
    end)
end

-- AH items (anything that isn't a commodity: mostly gear, which stays worth
-- buying in Forever, user 2026-11-05). The commodity hook above never saw
-- them, so weapons bought for Buy to vendor left no record. PlaceBid names
-- the auction, and the item's listings say what it is. Only buyouts count:
-- a lower bid can be outbid and its gold comes back. Recorded when the game
-- says it went through or when that exact gold leaves, whichever is first.
local ITEM_BUY_TIMEOUT = 30
local itemBuys = {}
local searchedKey

local function FindAuction(auctionID)
    local api = C_AuctionHouse
    if not searchedKey or not api.GetNumItemSearchResults then return nil end
    local ok, count = pcall(api.GetNumItemSearchResults, searchedKey)
    for i = 1, ok and count or 0 do
        local okR, r = pcall(api.GetItemSearchResultInfo, searchedKey, i)
        if okR and type(r) == "table" and r.auctionID == auctionID then return r end
    end
    return nil
end

local function OnPlaceBid(auctionID, bid)
    local r = FindAuction(auctionID)
    local itemID = r and r.itemKey and r.itemKey.itemID
    if not itemID or type(bid) ~= "number" or bid <= 0 or not r.buyoutAmount or bid < r.buyoutAmount then return end
    local now = GetTime()
    for id, b in pairs(itemBuys) do
        if now - b.time > ITEM_BUY_TIMEOUT then itemBuys[id] = nil end
    end
    -- The link's name, so "of the Bear" stays on it as it does on sale mail
    local name = type(r.itemLink) == "string" and r.itemLink:match("%[(.-)%]")
    if name then name = name:gsub("%s*|A.-|a", "") end
    name = name or C_Item.GetItemNameByID(itemID)
    if not name or name == "" then return end
    itemBuys[auctionID] = { itemID = itemID, name = name, quantity = r.quantity or 1, spent = bid, time = now }
    knownMoney = knownMoney or GetMoney()
end

local function RecordItemBuy(auctionID)
    local b = itemBuys[auctionID]
    if not b then return end
    itemBuys[auctionID] = nil
    local prof = addon:GetProfessionForItemName(b.name) or "Unassigned"
    addon.ledger:addCost(prof, b.name, b.quantity, b.spent, "PURCHASE", b.itemID)
    if b.quantity > 1 then
        addon:Notify("money", "Bought %s x%d for %s", b.name, b.quantity, ChatGold(b.spent))
    else
        addon:Notify("money", "Bought %s for %s", b.name, ChatGold(b.spent))
    end
    if addon.Refresh then addon.Refresh() end
end

local function MatchItemBuy(drop)
    for auctionID, b in pairs(itemBuys) do
        if b.spent == drop then return RecordItemBuy(auctionID) end
    end
end

-- Selling to a vendor something bought on the AH is a flip: a sale in the
-- ledger marked vendor, so it counts in profit and titles (user,
-- 2026-10-21). Everything else sold to a vendor (junk, loot) stays out.
-- Any character on the realm can sell what another bought and mailed.
local merchantOpen = false

-- How many of count are bought and unsold, what they cost (oldest first)
-- and their name in the ledger
local function BoughtUnsold(itemID, count)
    local index = addon.ledger:index()
    local realm = GetRealmName()
    -- "of the Bear" and "of the Eagle" share an item ID but not a name
    local bought, names, name = {}, {}, nil
    for _, e in ipairs(index.purchasesByID[itemID] or {}) do
        if (not e.realm or e.realm == realm) and (e.quantity or 0) > 0 then
            bought[#bought + 1] = e
            names[e.item] = true
            name = e.item
        end
    end
    if not name then return 0, 0 end
    local sold = 0
    for itemName in pairs(names) do
        for _, e in ipairs(index.sales[itemName] or {}) do
            if not e.realm or e.realm == realm then sold = sold + (e.quantity or 0) end
        end
    end
    local units, cost = 0, 0
    for _, e in ipairs(bought) do
        local left = e.quantity
        local skip = math.min(sold, left)
        sold, left = sold - skip, left - skip
        local take = math.min(count - units, left)
        if take > 0 then
            units = units + take
            cost = cost + take * (e.totalCopper or 0) / e.quantity
        end
    end
    return units, math.floor(cost + 0.5), name
end

local function OnUseContainerItem(bag, slot)
    if not merchantOpen then return end
    local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
    if not ok or type(info) ~= "table" or (canaccesstable and not canaccesstable(info)) then return end
    local itemID = info.itemID
    if not itemID or info.hasNoValue then return end
    local sell = select(11, C_Item.GetItemInfo(itemID))
    if not sell or sell <= 0 then return end
    local units, cost, name = BoughtUnsold(itemID, info.stackCount or 1)
    if units == 0 then return end
    local total = sell * units
    local prof = addon:GetProfessionForItemName(name) or "Unassigned"
    addon.ledger:addRevenue(prof, name, units, total, cost, false, 0, "paid", itemID, { vendor = true })
    local gain = total - cost
    addon:Notify("money", "Flipped %s: %s", name,
        addon:Colorize((gain < 0 and "-" or "") .. addon:FormatMoney(math.abs(gain)), gain < 0 and "loss" or "profit"))
    if addon.Refresh then addon.Refresh() end
end

-- Sold by trade (user, 2026-11-06: "theres more trading going on these
-- days"). What's in the window is read when someone accepts, as it's gone
-- by the time the game says the trade completed, and recorded only then. A
-- sale is items for gold: nothing back but gold, and not with your own
-- characters. An enchant for a tip gives no item, so it isn't one. In
-- profit and titles, not in AH sell speed, sale price or the AH cut.
local TRADE_SLOTS = 6 -- slot 7 is "will not be traded"
local tradeSeen

local function ReadTrade()
    local seen = { gold = (GetTargetTradeMoney() or 0) - (GetPlayerTradeMoney() or 0), items = {}, partner = UnitName("NPC") }
    local byID = {}
    for slot = 1, TRADE_SLOTS do
        local name, _, count = GetTradePlayerItemInfo(slot)
        local link = name and GetTradePlayerItemLink(slot)
        local itemID = link and C_Item.GetItemInfoInstant(link)
        if itemID then
            local item = byID[itemID]
            if not item then
                item = { itemID = itemID, name = name, count = 0 }
                byID[itemID] = item
                table.insert(seen.items, item)
            end
            item.count = item.count + (count or 1)
        end
        if GetTradeTargetItemInfo(slot) then seen.gotItem = true end
    end
    return seen
end

local function IsOwnCharacter(name)
    for _, c in pairs(GoldsmithDB.characters) do
        if c.name == name then return true end
    end
    return false
end

-- Its part of a trade's gold: by what each item is worth
local function TradeWeight(item)
    local unit = addon:GetAHPrice(item.itemID) or select(11, C_Item.GetItemInfo(item.itemID)) or 1
    return math.max(unit, 1) * item.count
end

local function RecordTrade(seen)
    if seen.gold <= 0 or seen.gotItem or #seen.items == 0 or IsOwnCharacter(seen.partner) then return end
    local total = 0
    for _, item in ipairs(seen.items) do total = total + TradeWeight(item) end
    local left = seen.gold
    for i, item in ipairs(seen.items) do
        local gold = i == #seen.items and left or math.floor(seen.gold * TradeWeight(item) / total + 0.5)
        left = left - gold
        local unitCost, partial, source = addon:GetUnitCostBasis(item.name, item.count, item.itemID)
        local cost = unitCost and math.floor(unitCost * item.count + 0.5)
        local prof = addon:GetProfessionForItemName(item.name) or "Unassigned"
        addon.ledger:addRevenue(prof, item.name, item.count, gold, cost, partial, 0, cost and source, item.itemID,
            { trade = seen.partner or "A player" })
        addon:Notify("money", "Sold %s x%d to %s: %s", item.name, item.count, seen.partner or "a player",
            addon:Colorize(addon:FormatMoney(gold), "profit"))
    end
    if addon.Refresh then addon.Refresh() end
end

local tradeEvents = CreateFrame("Frame")
for _, event in ipairs({ "TRADE_SHOW", "TRADE_ACCEPT_UPDATE", "UI_INFO_MESSAGE" }) do
    tradeEvents:RegisterEvent(event)
end
tradeEvents:SetScript("OnEvent", function(_, event, arg1, arg2)
    if event == "TRADE_SHOW" then
        tradeSeen = nil
    elseif event == "TRADE_ACCEPT_UPDATE" then
        -- Both accepted: it's done and the window may be emptying
        if arg1 == 1 and arg2 == 1 then return end
        local seen = ReadTrade()
        if #seen.items > 0 or seen.gold ~= 0 or seen.gotItem then tradeSeen = seen end
    elseif arg2 == ERR_TRADE_COMPLETE then
        local seen = tradeSeen
        tradeSeen = nil
        if seen then RecordTrade(seen) end
    elseif arg2 == ERR_TRADE_CANCELLED then
        tradeSeen = nil
    end
end)

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
frame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")
frame:RegisterEvent("AUCTION_HOUSE_PURCHASE_COMPLETED")
frame:RegisterEvent("ITEM_SEARCH_RESULTS_UPDATED")
frame:RegisterEvent("ITEM_SEARCH_RESULTS_ADDED")
frame:RegisterEvent("MERCHANT_SHOW")
frame:RegisterEvent("MERCHANT_CLOSED")

frame:SetScript("OnEvent", function(self, event, arg1)
    if event == "ADDON_LOADED" and arg1 == ADDON_NAME then
        -- Timed for /gsm perf
        local start = debugprofilestop()
        addon:Initialize()
        addon.initMs = debugprofilestop() - start
        self:UnregisterEvent("ADDON_LOADED")

    elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
        if not pending then return end
        -- The gold can come off in more than one step: 23 Cellular Slab
        -- for 220.32g were saved as 206.77g, recorded at the first drop
        -- (2026-10-19). Recorded once it has been still for a moment.
        awaitingMoney = true
        pending.succeeded = GetTime()
        SettleMoney()

    elseif event == "COMMODITY_PURCHASE_FAILED" then
        pending = nil
        awaitingMoney = false

    elseif event == "PLAYER_MONEY" then
        if awaitingMoney then
            SettleMoney()
        end
        if #pendingSales > 0 and knownMoney then
            local increase = GetMoney() - knownMoney
            if increase > 0 then
                OnMoneyIncreased(increase)
            end
        end
        if next(itemBuys) and knownMoney and knownMoney > GetMoney() then
            MatchItemBuy(knownMoney - GetMoney())
        end
        knownMoney = GetMoney()

    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
        RecordDeposit()

    elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" then
        RecordItemBuy(arg1)

    elseif event == "ITEM_SEARCH_RESULTS_UPDATED" or event == "ITEM_SEARCH_RESULTS_ADDED" then
        searchedKey = arg1

    elseif event == "MERCHANT_SHOW" then
        merchantOpen = true

    elseif event == "MERCHANT_CLOSED" then
        merchantOpen = false
    end
end)

function addon:Initialize()
    if not GoldsmithDB then
        GoldsmithDB = {}
        -- First time on this account: say how to open it, once login spam
        -- has scrolled past
        C_Timer.After(8, function()
            Print("Welcome! Type /gsm or click the Goldsmith button on the minimap to open Goldsmith. Its Overview shows how to get started.")
        end)
    end

    -- Forever mode on retail, to build and check it before Forever is out
    -- (/gsm forever, dev tools): prices, data and recipes stay retail's
    if GoldsmithDB.foreverTest and not addon.isForever then
        addon.isForever = true
        addon.foreverTest = true
        addon:ApplyForeverSettings()
        C_Timer.After(8, function()
            Print("|cffff8040Forever mode test is on|r (retail data). /gsm forever turns it off.")
        end)
    end

    -- Goldsmith Data is retail's region prices. Forever has its own
    -- economy on the same item IDs (Linen Cloth is 2589 in both), so its
    -- prices would be retail's. Forever prices come from your own scans.
    -- After the test switch above, so the test drops it too.
    if addon.isForever then GoldsmithPriceData = nil end

    -- Fake data from Tools\Stress-Swap.ps1: say so, so nobody plays on it
    if GoldsmithDB.stressTest then
        C_Timer.After(8, function()
            Print("|cffff8040Fake test data is loaded.|r Run /gsm perf, then close WoW and run Stress-Swap.ps1 -Restore. Anything you do now will be lost.")
        end)
    end

    GoldsmithDB.products = GoldsmithDB.products or {}
    -- A temporary plan log from testing the Characters tab
    GoldsmithDB.debugPlans = nil
    -- The Hover explanations setting is gone (always Hold Ctrl now)
    if GoldsmithDB.settings then GoldsmithDB.settings.explain = nil end
    -- So is "Use materials I have" (always on now)
    if GoldsmithDB.ui2 then GoldsmithDB.ui2.planUseOnHand = nil end
    -- Left from v1's window; still holds the planner's Buy/Craft/Mill choices
    GoldsmithDB.ui = GoldsmithDB.ui or {}
    LearnProfessionIcons()
    -- Profession data may not be ready this early in login; try again shortly
    C_Timer.After(5, function()
        LearnProfessionIcons()
        if addon.Refresh then addon.Refresh() end
    end)
    addon:InitializeCharacters()
    addon:InitializeStock()
    addon:InitializePricing()
    addon:InitializeMilling()
    addon:InitializeGathered()
    addon:InitializeQuality()
    addon:InitializeCooldowns()

    addon.ledger = addon:CreateLedger(GoldsmithDB)
    -- Sales costed at a recipe estimate though you'd bought the item (once)
    addon:RepairEstimatedSales()
    -- Order rewards sold with no cost: what the order counted them at (once)
    addon:RepairRewardSales()
    -- A one-off repair of the developer's own Missive lots, done and removed
    GoldsmithDB.harmoniousLotsRepaired = nil
    -- Keep history for (Settings); after login settles, like the other chores
    C_Timer.After(15, function() addon:TrimHistory() end)
    addon:CreateWindow()
    addon:CreateMinimapButton()
    -- Items assigned to Archaeology or Fishing (older versions offered them)
    -- go back to Unassigned; ReassignProfessions moves their entries too
    for name, prof in pairs(GoldsmithDB.products) do
        if type(prof) == "string" and not addon:IsCraftingProfession(prof) then
            GoldsmithDB.products[name] = "Unassigned"
        end
    end
    addon:ReassignProfessions()

    hooksecurefunc(C_AuctionHouse, "ConfirmCommoditiesPurchase", OnConfirmCommoditiesPurchase)
    hooksecurefunc(C_AuctionHouse, "PlaceBid", OnPlaceBid)
    if C_Container and C_Container.UseContainerItem then
        hooksecurefunc(C_Container, "UseContainerItem", OnUseContainerItem)
    end
    hooksecurefunc(C_AuctionHouse, "PostCommodity", OnPostCommodity)
    hooksecurefunc(C_AuctionHouse, "PostItem", OnPostItem)
    hooksecurefunc("BuyMerchantItem", OnBuyMerchantItem)
    hooksecurefunc("TakeInboxMoney", OnTakeMailMoney)
    hooksecurefunc("AutoLootMailItem", OnTakeMailMoney)
end

StaticPopupDialogs["GOLDSMITH_RESET"] = {
    text = "Delete ALL Goldsmith transactions? This can't be undone.",
    button1 = YES,
    button2 = NO,
    OnAccept = function()
        addon.ledger:clear()
        if addon.LifetimeLedgerCleared then addon:LifetimeLedgerCleared() end
        Print("All transactions deleted.")
        if addon.Refresh then addon.Refresh() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- /gsm add, remove and list (v1's way to track an item) were removed
-- (trimming, user 2026-10-10): recipes are learned from your professions,
-- and History's "Assign to profession" fixes the rest. Items they tracked
-- stay in GoldsmithDB.products.
local function PrintHelp()
    Print("Commands:")
    print("  /gsm - show or hide the window")
    print("  /gsm recipes - show saved recipes and their material cost")
    print("  /gsm milling - show your milling yields and pigment costs")
    print("  /gsm chars - list your characters, professions and concentration")
    print("  /gsm data - check the numbers behind the window")
    print("  /gsm setup - show the getting started checklist again")
    print("  /gsm tour - a short tour of the window")
    print("  /gsm news - what's new in this version")
    print("  /gsm scan - scan the AH for every price (at the AH)")
    print("  /gsm cooldowns - craft cooldowns on every character")
    print("  /gsm gathered - what was counted as gathered today, and what was skipped")
    print("  /gsm buffs - your buffs, and the crafting buffs Goldsmith has seen")
    print("  /gsm perf - time each tab and show memory use")
    print("  /gsm report - copy a bug report (versions, settings and recent errors) to paste in a comment")
    print("  /gsm reset - delete all transactions")
end

SLASH_GOLDSMITH1 = "/goldsmith"
SLASH_GOLDSMITH2 = "/gsm"
SlashCmdList["GOLDSMITH"] = function(msg)
    local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "" then
        addon:ToggleWindow()
    elseif cmd == "recipes" then
        addon:ListRecipes()
    elseif cmd == "milling" then
        addon:ListMilling()
    elseif cmd == "buffs" then
        addon:PrintCraftBuffs()
    elseif cmd == "gathered" then
        addon:ListGathered()
    elseif cmd == "chars" then
        addon:ListCharacters()
    elseif cmd == "data" then
        addon:ListData()
    elseif cmd == "setup" then
        addon:ShowSetup()
    elseif cmd == "tour" then
        addon:StartTour()
    elseif cmd == "news" then
        addon:ShowNews()
    elseif cmd == "scan" then
        addon:ScanAH(false)
    elseif cmd == "stats" then
        addon:DumpCraftingStats()
    elseif cmd == "salvage" then
        addon:DumpSalvageStats()
    elseif cmd == "cooldowns" or cmd == "cd" then
        addon:ListCooldowns()
    -- Developer tools, not for players (user, 2026-10-24: "just me. ill
    -- decide what sound"). On with /run GoldsmithDB.devTools = true
    elseif (cmd == "sound" or cmd == "sounds") and GoldsmithDB.devTools then
        addon:SampleSound(rest)
    elseif cmd == "buylist" and GoldsmithDB.devTools then
        addon:PrintBuyList(rest)
    elseif cmd == "sellnow" and GoldsmithDB.devTools then
        addon:PrintSellNow()
    elseif cmd == "finishing" and GoldsmithDB.devTools then
        addon:PrintFinishing(rest)
    -- A harmless error from Goldsmith's own file, caught like a real one:
    -- to see the error dot (Report.lua). Clear errors on the bug report
    -- page forgets it.
    elseif cmd == "testerror" and GoldsmithDB.devTools then
        C_Timer.After(0, function() error("Goldsmith test error (/gsm testerror), not a real bug") end)
    elseif cmd == "forever" and GoldsmithDB.devTools then
        GoldsmithDB.foreverTest = not GoldsmithDB.foreverTest or nil
        ReloadUI()
    elseif cmd == "prep" and GoldsmithDB.devTools then
        addon:PrintPrepCheck()
    elseif cmd == "fakechars" and GoldsmithDB.devTools then
        addon:FakeCharacters(rest)
    elseif cmd == "perf" then
        addon:RunPerfCheck()
    elseif cmd == "report" or cmd == "bug" then
        addon:ShowBugReport()
    elseif cmd == "reset" then
        StaticPopup_Show("GOLDSMITH_RESET")
    else
        PrintHelp()
    end
end

-- Opening the mailbox: the AH gold waiting in it and what your AH
-- purchases in it cost, two numbers in chat, not netted (user, 2026-10-22:
-- people want to see the big number coming in). Once per opening, after
-- the inbox has stopped updating for MAIL_SETTLE seconds: the first update
-- had 8 of 15 sales in it (2026-10-22).
local MAIL_SETTLE = 1.5
local mailSummary = CreateFrame("Frame")
local mailSummed, mailOpened, mailWait = nil, 0, 0
local MailSummary
mailSummary:RegisterEvent("MAIL_SHOW")
mailSummary:RegisterEvent("MAIL_INBOX_UPDATE")
mailSummary:RegisterEvent("MAIL_CLOSED")
mailSummary:SetScript("OnEvent", function(_, event)
    if event == "MAIL_SHOW" or event == "MAIL_CLOSED" then
        if event == "MAIL_CLOSED" then addon:FlushSaleTotal() end
        mailSummed = event == "MAIL_CLOSED"
        mailOpened = mailOpened + 1
        return
    end
    addon:CheckSaleTotal()
    if mailSummed ~= false then return end
    mailWait = mailWait + 1
    local opened, wait = mailOpened, mailWait
    C_Timer.After(MAIL_SETTLE, function()
        if opened == mailOpened and wait == mailWait and mailSummed == false then MailSummary() end
    end)
end)

MailSummary = function()
    mailSummed = true
    -- Sales aren't summed here any more: the Total after their lines says
    -- it (RecordSale; user, 2026-10-27)
    local shown = GetInboxNumItems()
    local spent, buys = 0, 0
    for i = 1, shown or 0 do
        local invoiceType, _, _, bid = GetInboxInvoiceInfo(i)
        if invoiceType == "buyer" and bid then
            spent, buys = spent + bid, buys + 1
        end
    end
    if buys > 0 then
        addon:Notify("money", "Mailbox: %s spent on %d AH purchase%s waiting in it", addon:FormatMoney(spent),
            buys, buys == 1 and "" or "s")
    end
end

_G.Goldsmith = addon
