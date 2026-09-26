local addon = _G.Goldsmith or {}

local function Print(msg, ...)
    print("|cFF00FF00[Goldsmith]|r " .. string.format(msg, ...))
end

local function FormatGold(copper)
    return string.format("%.2fg", copper / 10000)
end

-- Milling tracking
--
-- Milling is a salvage recipe: you pick a herb in the profession window and
-- it's used up in exchange for pigments. Pigment amounts are random, so
-- instead of reading them from events Goldsmith compares your bags before
-- and after. Herbs that disappear are the input; items that appear within a
-- few seconds of that are the output. Totals build up in
-- GoldsmithDB.milling, keyed by herb item ID:
--   { name, milled = n, outputs = { [itemID] = { name, qty } } }
-- This works for any salvage recipe (e.g. prospecting), not just milling.

local OUTPUT_WINDOW = 3   -- seconds after herbs are used up to count new items
local SUMMARY_DELAY = 3   -- seconds of quiet before printing what was milled

local session = nil
local summaryTimer = nil

local function SnapshotBags()
    local counts = {}
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID then
                counts[info.itemID] = (counts[info.itemID] or 0) + info.stackCount
            end
        end
    end
    return counts
end

local function PrintSummary()
    summaryTimer = nil
    if not session or session.summaryMilled == 0 then return end

    local parts = {}
    for itemID, qty in pairs(session.summaryOutputs) do
        table.insert(parts, string.format("%d %s", qty, C_Item.GetItemNameByID(itemID) or ("item " .. itemID)))
    end
    Print("Milled %d %s: %s", session.summaryMilled, session.herbName,
        #parts > 0 and table.concat(parts, ", ") or "nothing yet")

    session.summaryMilled = 0
    session.summaryOutputs = {}
end

local function EndSession()
    if summaryTimer then
        summaryTimer:Cancel()
    end
    PrintSummary()
    session = nil
end

local function OnCraftSalvage(recipeID, numCasts, itemTarget)
    if not itemTarget or not C_Item.DoesItemExist(itemTarget) then return end
    local herbID = C_Item.GetItemID(itemTarget)
    if not herbID then return end

    if session and session.herbID ~= herbID then
        EndSession()
    end
    if session then return end

    local herbName = C_Item.GetItemNameByID(herbID) or ("item " .. herbID)
    local profInfo = C_TradeSkillUI.GetBaseProfessionInfo()
    local profession = (profInfo and profInfo.professionName) or "Inscription"

    -- Herbs you mill are that profession's materials, so buying them counts
    -- toward its costs
    if not GoldsmithDB.reagents[herbName] then
        GoldsmithDB.reagents[herbName] = profession
        addon:ReassignProfessions()
    end

    session = {
        herbID = herbID,
        herbName = herbName,
        profession = profession,
        baseline = SnapshotBags(),
        lastMill = 0,
        summaryMilled = 0,
        summaryOutputs = {},
    }
end

local function OnBagsChanged()
    if not session then return end

    local now = SnapshotBags()
    local herbID = session.herbID
    local t = GetTime()
    local changed = false

    local record = GoldsmithDB.milling[herbID]
    if not record then
        record = { name = session.herbName, profession = session.profession, milled = 0, outputs = {} }
        GoldsmithDB.milling[herbID] = record
    end

    local used = (session.baseline[herbID] or 0) - (now[herbID] or 0)
    if used > 0 then
        record.milled = record.milled + used
        session.summaryMilled = session.summaryMilled + used
        session.lastMill = t
        changed = true
    end

    -- Only items that appear right after herbs were used up count as output,
    -- so loot or mail picked up mid-session isn't mistaken for pigment.
    if t - session.lastMill <= OUTPUT_WINDOW then
        for itemID, count in pairs(now) do
            local gained = count - (session.baseline[itemID] or 0)
            if itemID ~= herbID and gained > 0 then
                local out = record.outputs[itemID]
                if not out then
                    out = { name = C_Item.GetItemNameByID(itemID) or ("item " .. itemID), qty = 0 }
                    record.outputs[itemID] = out
                end
                out.qty = out.qty + gained
                session.summaryOutputs[itemID] = (session.summaryOutputs[itemID] or 0) + gained
                changed = true
            end
        end
    end

    session.baseline = now

    if changed then
        if summaryTimer then
            summaryTimer:Cancel()
        end
        summaryTimer = C_Timer.NewTimer(SUMMARY_DELAY, PrintSummary)
    end
end

-- Costs

-- What one herb costs you: your average purchase price, or the current AH
-- price for herbs you gathered yourself (what you could have sold them for).
function addon:GetHerbUnitCost(herbID, herbName)
    local paid = addon:GetAverageCost(herbName)
    if paid then
        return paid, "paid"
    end
    local market = addon:GetMarketPrice(herbID)
    if market then
        return market, "AH price"
    end
end

-- Cost per unit of a pigment from your own milling, or nil if you haven't
-- milled any. Each herb's cost is split across the pigments it gave you by
-- their AH value (or by count if a pigment has no AH price), then averaged
-- over every herb that produced this pigment.
function addon:GetMilledCost(itemName)
    local totalCost, totalQty = 0, 0

    for herbID, record in pairs(GoldsmithDB.milling) do
        local target
        for _, out in pairs(record.outputs) do
            if out.name == itemName then
                target = out
            end
        end

        local herbCost = target and record.milled > 0 and addon:GetHerbUnitCost(herbID, record.name)
        if herbCost then
            local batchCost = herbCost * record.milled

            local sumValue, sumQty, allPriced = 0, 0, true
            local targetValue
            for outID, out in pairs(record.outputs) do
                sumQty = sumQty + out.qty
                local price = addon:GetMarketPrice(outID)
                if price then
                    sumValue = sumValue + price * out.qty
                    if out == target then
                        targetValue = price * out.qty
                    end
                else
                    allPriced = false
                end
            end

            local share
            if allPriced and sumValue > 0 then
                share = targetValue / sumValue
            else
                share = target.qty / sumQty
            end

            totalCost = totalCost + batchCost * share
            totalQty = totalQty + target.qty
        end
    end

    if totalQty == 0 then return nil end
    return totalCost / totalQty, totalQty
end

-- Tooltip lines for herbs (your yield) and pigments (your milled cost).
function addon:AddMillingTooltipLines(tooltip, itemID, itemName)
    local record = GoldsmithDB.milling[itemID]
    if record and record.milled > 0 then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r milling yield",
            string.format("per herb (%d milled)", record.milled), 1, 1, 1, 1, 1, 1)
        for _, out in pairs(record.outputs) do
            tooltip:AddDoubleLine("  " .. out.name, string.format("%.2f", out.qty / record.milled),
                0.8, 0.8, 0.8, 0.8, 0.8, 0.8)
        end
    end

    local milledCost, qty = addon:GetMilledCost(itemName)
    if milledCost then
        tooltip:AddDoubleLine("|cFF00FF00Goldsmith|r milled cost",
            string.format("%s (%d milled)", FormatGold(milledCost), qty), 1, 1, 1, 1, 1, 1)
    end
end

function addon:ListMilling()
    local any = false
    for herbID, record in pairs(GoldsmithDB.milling) do
        if record.milled > 0 then
            if not any then
                Print("Milling results:")
                any = true
            end
            local herbCost, source = addon:GetHerbUnitCost(herbID, record.name)
            local costText = herbCost and string.format("%s each, %s", FormatGold(herbCost), source) or "no herb cost"
            print(string.format("  %s: %d milled (%s)", record.name, record.milled, costText))
            for _, out in pairs(record.outputs) do
                local cost = addon:GetMilledCost(out.name)
                print(string.format("    %s: %d (%.2f per herb)%s", out.name, out.qty, out.qty / record.milled,
                    cost and (", costs " .. FormatGold(cost) .. " each") or ""))
            end
        end
    end
    if not any then
        Print("Nothing milled yet. Mill some herbs from the profession window and it's tracked automatically.")
    end
end

function addon:InitializeMilling()
    GoldsmithDB.milling = GoldsmithDB.milling or {}

    -- Herbs milled before herbs were marked as materials. Records from then
    -- have no profession saved; milling is Inscription, so use that.
    for _, record in pairs(GoldsmithDB.milling) do
        if not GoldsmithDB.reagents[record.name] then
            GoldsmithDB.reagents[record.name] = record.profession or "Inscription"
        end
    end

    hooksecurefunc(C_TradeSkillUI, "CraftSalvage", OnCraftSalvage)
    -- A regular craft uses up materials too, so milling tracking stops there
    hooksecurefunc(C_TradeSkillUI, "CraftRecipe", EndSession)

    local frame = CreateFrame("Frame")
    frame:RegisterEvent("BAG_UPDATE_DELAYED")
    frame:RegisterEvent("TRADE_SKILL_CLOSE")
    frame:SetScript("OnEvent", function(_, event)
        if event == "BAG_UPDATE_DELAYED" then
            OnBagsChanged()
        else
            EndSession()
        end
    end)
end

_G.Goldsmith = addon
