local ADDON_NAME = "Goldsmith"
local addon = _G.Goldsmith or {}

-- Purchase in flight: { itemID, quantity, moneyBefore }
local pending = nil
local awaitingMoney = false

local function Print(msg, ...)
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

-- Ways to open the window besides /gsm: a key (Bindings.xml; these name it
-- in Options > Keybindings > AddOns) and the addon compartment next to the
-- minimap (## AddonCompartmentFunc in the TOC)
BINDING_HEADER_GOLDSMITH = "Goldsmith"
BINDING_NAME_GOLDSMITH_TOGGLE = "Show or hide Goldsmith"
BINDING_NAME_GOLDSMITH_CRAFT_NEXT = "Craft next in the queue"

function Goldsmith_OnAddonCompartmentClick()
    addon:ToggleWindow()
end

-- Called when the player confirms a commodity purchase on the AH.
-- Snapshot gold now so the actual cost can be taken from the change in money.
-- Every commodity purchase is recorded so average costs are available for any
-- reagent; items not in a tracked list are saved as Unassigned.
local function OnConfirmCommoditiesPurchase(itemID, quantity)
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
    }
    awaitingMoney = false
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
    addon:Notify("money", "Bought %s x%d for %.2fg (%.2fg each)",
        p.name, p.quantity, spent / 10000, (spent / p.quantity) / 10000)
    addon:ShoppingListBought(p.itemID, p.quantity)

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

local function RecordSale(sale)
    local prof = addon:GetProfessionForItemName(sale.itemName) or "Unassigned"

    -- Snapshot what the items cost you now, so the sale's profit doesn't
    -- shift later as material prices change
    local unitCost, partial, costSource = addon:GetUnitCostBasis(sale.itemName, sale.count)
    local costBasis = unitCost and math.floor(unitCost * sale.count + 0.5)
    addon.ledger:addRevenue(prof, sale.itemName, sale.count, sale.net, costBasis, partial, sale.depositRefund,
        costBasis and costSource)
    addon:AuctionSold(sale.itemName, sale.count)

    if prof == "Unassigned" then
        addon:Notify("money", "Sold %s x%d for %.2fg after AH cut, incl. deposit refund (not a tracked item, saved as Unassigned)",
            sale.itemName, sale.count, sale.net / 10000)
    else
        addon:Notify("money", "Sold %s x%d for %.2fg after AH cut, incl. deposit refund (%.2fg each)",
            sale.itemName, sale.count, sale.net / 10000, (sale.net / sale.count) / 10000)
    end
    if costBasis then
        local profit = sale.net - costBasis
        addon:Notify("money", "  Cost you %.2fg, profit %s%.2fg%s", costBasis / 10000,
            profit >= 0 and "+" or "-", math.abs(profit) / 10000, partial and " (at most)" or "")
    end
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
    table.insert(pendingPosts, {
        name = C_Item.GetItemName(itemLocation),
        quantity = quantity,
        deposit = deposit,
        time = GetTime(),
    })
end

local function OnPostCommodity(itemLocation, duration, quantity)
    if not C_Item.DoesItemExist(itemLocation) then return end
    local itemID = C_Item.GetItemID(itemLocation)
    QueuePost(itemLocation, C_AuctionHouse.CalculateCommodityDeposit(itemID, duration, quantity), quantity)
end

local function OnPostItem(itemLocation, duration, quantity)
    QueuePost(itemLocation, C_AuctionHouse.CalculateItemDeposit(itemLocation, duration, quantity), quantity)
end

local function RecordDeposit()
    -- Drop posts that were never confirmed (e.g. the post failed)
    while pendingPosts[1] and GetTime() - pendingPosts[1].time > POST_TIMEOUT do
        table.remove(pendingPosts, 1)
    end

    local post = table.remove(pendingPosts, 1)
    if not post or not post.name then return end

    local prof = addon:GetProfessionForItemName(post.name) or "Unassigned"
    addon.ledger:addCost(prof, post.name, post.quantity, post.deposit, "DEPOSIT")
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
        -- Gold may already be deducted; if not, wait for PLAYER_MONEY
        if GetMoney() < pending.moneyBefore then
            addon:RecordPurchase()
        else
            awaitingMoney = true
        end

    elseif event == "COMMODITY_PURCHASE_FAILED" then
        pending = nil
        awaitingMoney = false

    elseif event == "PLAYER_MONEY" then
        if awaitingMoney then
            addon:RecordPurchase()
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
    addon:InitializeQuality()
    addon:InitializeCooldowns()

    addon.ledger = addon:CreateLedger(GoldsmithDB)
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
        Print("All transactions deleted.")
        if addon.Refresh then addon.Refresh() end
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3,
}

-- Accepts a shift-clicked item link or a typed name. Strips the brackets,
-- colour codes and the crafting-quality icon that item links carry.
local function ParseItemName(text)
    local name = text:match("%[(.-)%]") or text
    name = name:gsub("|A.-|a", ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    return strtrim(name)
end

local function ListProducts()
    local names = {}
    for name in pairs(GoldsmithDB.products) do
        table.insert(names, name)
    end
    table.sort(names)
    if #names == 0 then
        Print("No crafted items tracked yet. Use /gsm add [item].")
        return
    end
    Print("Tracked crafted items:")
    for _, name in ipairs(names) do
        print("  " .. name)
    end
end

local function PrintHelp()
    Print("Commands:")
    print("  /gsm - show or hide the window")
    print("  /gsm add [item] - track a crafted item (shift-click it or type its name)")
    print("  /gsm remove [item] - stop tracking a crafted item")
    print("  /gsm list - show tracked crafted items")
    print("  /gsm recipes - show saved recipes and their material cost")
    print("  /gsm milling - show your milling yields and pigment costs")
    print("  /gsm chars - list your characters, professions and concentration")
    print("  /gsm data - check the numbers behind the window")
    print("  /gsm setup - show the getting started checklist again")
    print("  /gsm tour - a short tour of the window")
    print("  /gsm cooldowns - craft cooldowns on every character")
    print("  /gsm perf - time each tab and show memory use (freezes the game briefly)")
    print("  /gsm report - copy a bug report (versions, settings and recent errors) for GitHub")
    print("  /gsm reset - delete all transactions")
    print("  Right-click an entry on the History tab to delete it.")
end

SLASH_GOLDSMITH1 = "/goldsmith"
SLASH_GOLDSMITH2 = "/gsm"
SlashCmdList["GOLDSMITH"] = function(msg)
    local cmd, rest = strtrim(msg or ""):match("^(%S*)%s*(.-)$")
    cmd = cmd:lower()

    if cmd == "" then
        addon:ToggleWindow()
    elseif cmd == "add" and rest ~= "" then
        local name = ParseItemName(rest)
        GoldsmithDB.products[name] = true
        addon:ReassignProfessions()
        Print("Now tracking %s as an Inscription item.", name)
    elseif cmd == "remove" and rest ~= "" then
        local name = ParseItemName(rest)
        if GoldsmithDB.products[name] then
            GoldsmithDB.products[name] = nil
            addon:ReassignProfessions()
            Print("Stopped tracking %s.", name)
        else
            Print("%s isn't in your tracked items. See /gsm list.", name)
        end
    elseif cmd == "list" then
        ListProducts()
    elseif cmd == "recipes" then
        addon:ListRecipes()
    elseif cmd == "milling" then
        addon:ListMilling()
    elseif cmd == "chars" then
        addon:ListCharacters()
    elseif cmd == "data" then
        addon:ListData()
    elseif cmd == "setup" then
        addon:ShowSetup()
    elseif cmd == "tour" then
        addon:StartTour()
    elseif cmd == "stats" then
        addon:DumpCraftingStats()
    elseif cmd == "salvage" then
        addon:DumpSalvageStats()
    elseif cmd == "cooldowns" or cmd == "cd" then
        addon:ListCooldowns()
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

_G.Goldsmith = addon
