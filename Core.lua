local ADDON_NAME = "Goldsmith"
local addon = _G.Goldsmith or {}
-- WoW Forever (project "Camelot", 18): one expansion, no qualities or
-- concentration, prices mostly silver and copper
addon.isForever = WOW_PROJECT_ID == (WOW_PROJECT_CAMELOT or 18)

-- Purchase in flight: { itemID, quantity, moneyBefore }
local pending = nil
local awaitingMoney = false

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
            plannedText = string.format(", %.2fg %s plan", math.abs(diff) / 10000, diff > 0 and "over" or "under")
        end
    end
    addon:Notify("money", "Bought %s x%d for %.2fg (%.2fg each%s)",
        p.name, p.quantity, spent / 10000, (spent / p.quantity) / 10000, plannedText)
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
    addon:Notify("money", "Bought %s x%d from a vendor for %.2fg", name, units, total / 10000)

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

local function RecordSale(sale)
    local prof = addon:GetProfessionForItemName(sale.itemName) or "Unassigned"

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
local POST_TIMEOUT = 30

local function QueuePost(itemLocation, deposit, quantity)
    if not deposit or deposit <= 0 then return end
    if not C_Item.DoesItemExist(itemLocation) then return end
    -- The exact item and its Goldsmith Data sell level when posted, to check
    -- later how well levels predict what sells (GoldsmithData
    -- tools/score-levels.js)
    local itemID = C_Item.GetItemID(itemLocation)
    table.insert(pendingPosts, {
        name = C_Item.GetItemName(itemLocation),
        itemID = itemID,
        level = addon:GetSellLevel(itemID),
        quantity = quantity,
        deposit = deposit,
        time = GetTime(),
    })
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
    table.insert(posts, { name = C_Item.GetItemName(itemLocation), itemID = C_Item.GetItemID(itemLocation),
        unitPrice = unitPrice, left = quantity, time = time() })
    local cutoff = time() - POST_DAYS * 86400
    while posts[1] and (#posts > POSTS_KEPT or posts[1].time < cutoff) do table.remove(posts, 1) end
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
    addon:Notify("info", "%s posted at %s, under break-even (%s). Cancel it if that's a mistake.",
        name or "An item", addon:FormatMoney(unitPrice), addon:FormatMoney(breakEven))
end

local function OnPostCommodity(itemLocation, duration, quantity, unitPrice)
    if not C_Item.DoesItemExist(itemLocation) then return end
    local itemID = C_Item.GetItemID(itemLocation)
    RememberPost(itemLocation, quantity, unitPrice)
    QueuePost(itemLocation, C_AuctionHouse.CalculateCommodityDeposit(itemID, duration, quantity), quantity)
    pcall(CheckPostPrice, itemLocation, quantity, unitPrice)
end

local function OnPostItem(itemLocation, duration, quantity, bid, buyout)
    local price = buyout or bid
    RememberPost(itemLocation, quantity, price and quantity and quantity > 0 and price / quantity)
    QueuePost(itemLocation, C_AuctionHouse.CalculateItemDeposit(itemLocation, duration, quantity), quantity)
    if price and quantity and quantity > 0 then pcall(CheckPostPrice, itemLocation, quantity, price / quantity) end
end

local function RecordDeposit()
    -- Drop posts that were never confirmed (e.g. the post failed)
    while pendingPosts[1] and GetTime() - pendingPosts[1].time > POST_TIMEOUT do
        table.remove(pendingPosts, 1)
    end

    local post = table.remove(pendingPosts, 1)
    if not post or not post.name then return end

    local prof = addon:GetProfessionForItemName(post.name) or "Unassigned"
    addon.ledger:addCost(prof, post.name, post.quantity, post.deposit, "DEPOSIT", nil,
        { postedID = post.itemID, sellLevel = post.level })
    addon:Notify("money", "Posted %s x%d, deposit %.2fg", post.name, post.quantity, post.deposit / 10000)

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

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("COMMODITY_PURCHASE_SUCCEEDED")
frame:RegisterEvent("COMMODITY_PURCHASE_FAILED")
frame:RegisterEvent("PLAYER_MONEY")
frame:RegisterEvent("AUCTION_HOUSE_AUCTION_CREATED")

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
        knownMoney = GetMoney()

    elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
        RecordDeposit()
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
    elseif cmd == "finishing" and GoldsmithDB.devTools then
        addon:PrintFinishing(rest)
    elseif cmd == "prep" and GoldsmithDB.devTools then
        addon:PrintPrepCheck()
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
