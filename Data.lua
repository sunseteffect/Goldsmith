local addon = _G.Goldsmith or {}

local INSCRIPTION_ITEMS = {
    [236770] = { name = "Sanguithorn", price = 1 },
    [2447] = { name = "Silverleaf", price = 1 },
    [2449] = { name = "Earthroot", price = 1 },
    [39469] = { name = "Ethereal Pigment", price = 2 },
}

addon.INSCRIPTION_ITEMS = INSCRIPTION_ITEMS

-- Crafted goods you sell. Keyed by exact item name, because AH sale mail
-- only reports the item's name, not its ID.
local INSCRIPTION_PRODUCTS = {
    -- ["Item Name"] = true,
}

addon.INSCRIPTION_PRODUCTS = INSCRIPTION_PRODUCTS

-- Which profession an item belongs to, by name. Nil if it's not tracked.
-- Items added in game live in GoldsmithDB: products from /gsm add (value true
-- means Inscription), and recipe outputs and reagents saved when you craft
-- (value is the profession name).
function addon:GetProfessionForItemName(itemName)
    if INSCRIPTION_PRODUCTS[itemName] then
        return "Inscription"
    end
    if GoldsmithDB then
        for _, list in ipairs({ GoldsmithDB.products, GoldsmithDB.reagents }) do
            local prof = list and list[itemName]
            if prof then
                return prof == true and "Inscription" or prof
            end
        end
    end
    for _, itemData in pairs(INSCRIPTION_ITEMS) do
        if itemData.name == itemName then
            return "Inscription"
        end
    end
    return nil
end

function addon:CreateLedger(store)
    store.entries = store.entries or {}
    store.nextId = store.nextId or 1

    local entries = store.entries

    return {
        -- kind is "PURCHASE" (default) or "DEPOSIT"
        addCost = function(self, prof, item, qty, totalCopper, kind, itemID)
            table.insert(entries, {
                id = store.nextId,
                type = "COST",
                kind = kind or "PURCHASE",
                itemID = itemID,
                profession = prof,
                item = item,
                quantity = qty,
                totalCopper = totalCopper,
                timestamp = time(),
                character = UnitName("player"),
                realm = GetRealmName(),
            })
            store.nextId = store.nextId + 1
        end,

        -- costBasis is what the sold items cost you (at sale time), if known;
        -- costPartial means some of their material costs were unknown
        -- depositRefund is the deposit returned inside this sale's amount
        addRevenue = function(self, prof, item, qty, totalCopper, costBasis, costPartial, depositRefund)
            table.insert(entries, {
                costBasis = costBasis,
                costPartial = costPartial,
                depositRefund = depositRefund,
                id = store.nextId,
                type = "REVENUE",
                profession = prof,
                item = item,
                quantity = qty,
                totalCopper = totalCopper,
                timestamp = time(),
                character = UnitName("player"),
                realm = GetRealmName(),
            })
            store.nextId = store.nextId + 1
        end,

        getAll = function(self)
            return entries
        end,

        remove = function(self, id)
            for i, e in ipairs(entries) do
                if e.id == id then
                    table.remove(entries, i)
                    return true
                end
            end
            return false
        end,

        clear = function(self)
            -- wipe in place so every reference to entries stays valid
            wipe(entries)
        end,

        -- Profit on what you've sold, for one profession or "All".
        --   profit = sales - cost of the items sold - AH deposits
        -- Deposit refunds are part of each sale's amount, so deposits on
        -- items that sold cancel out and only lost deposits reduce profit.
        -- Money spent on materials is reported separately: materials you
        -- still hold aren't a loss until they're sold or wasted.
        -- estimateCost(itemName) fills in cost for sales recorded before
        -- sales kept their cost; sales with no cost data at all are left
        -- out of profit and counted in unknownSales.
        getSummary = function(self, prof, estimateCost)
            local s = {
                sales = 0, soldCost = 0, deposits = 0, spent = 0,
                profitSales = 0, unknownSales = 0, estimated = false,
                count = 0,
                -- refunds only known for sales recorded since refunds were saved
                refunds = 0, refundsKnown = true,
            }
            for _, e in ipairs(entries) do
                if prof == "All" or e.profession == prof then
                    s.count = s.count + 1
                    if e.type == "REVENUE" then
                        s.sales = s.sales + e.totalCopper
                        if e.depositRefund then
                            s.refunds = s.refunds + e.depositRefund
                        else
                            s.refundsKnown = false
                        end
                        local cost = e.costBasis
                        if not cost and estimateCost then
                            local unit = estimateCost(e.item)
                            if unit then
                                cost = unit * e.quantity
                                s.estimated = true
                            end
                        end
                        if cost then
                            s.soldCost = s.soldCost + cost
                            s.profitSales = s.profitSales + e.totalCopper
                        else
                            s.unknownSales = s.unknownSales + 1
                        end
                    elseif e.kind == "DEPOSIT" then
                        s.deposits = s.deposits + e.totalCopper
                    else
                        s.spent = s.spent + e.totalCopper
                    end
                end
            end
            s.profit = s.profitSales - s.soldCost - s.deposits
            s.margin = s.soldCost > 0 and (s.profit / s.soldCost * 100) or nil
            return s
        end,
    }
end

_G.Goldsmith = addon