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
--
-- Each session (salvaging one item until you stop or switch) is also kept
-- in GoldsmithDB.salvageRuns, with who did it and their stats at the time,
-- so yields can be compared across characters and spec changes:
--   { time, character, recipeID, itemID, casts, used, perCast,
--     outputs = { [itemID] = qty }, skill, difficulty, quality, qualityID,
--     resourcefulness, concentrated }
-- casts counts finished casts, so casts * perCast - used is the material
-- resourcefulness saved.

local OUTPUT_WINDOW = 3   -- seconds after herbs are used up to count new items
local SUMMARY_DELAY = 3   -- seconds of quiet before printing what was milled
local MAX_SALVAGE_RUNS = 500

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
    addon:Notify("info", "Milled %d %s: %s", session.summaryMilled, session.herbName,
        #parts > 0 and table.concat(parts, ", ") or "nothing yet")

    session.summaryMilled = 0
    session.summaryOutputs = {}
    -- Yields changed (the session counts before it's saved; see
    -- SalvageRuns), so the Crafts rows and mill planner catch up
    if addon.Refresh then addon.Refresh() end
end

-- The session in progress as a salvage run, or nil
local function CurrentRun()
    if not session or (session.used == 0 and session.casts == 0) then return nil end
    local run = {
        time = session.started,
        character = addon.charKey,
        recipeID = session.recipeID,
        itemID = session.herbID,
        casts = session.casts,
        used = session.used,
        perCast = session.perCast,
        outputs = session.outputs,
        concentrated = session.concentrated,
    }
    for key, value in pairs(session.stats) do
        run[key] = value
    end
    return run
end

-- Saved salvage runs plus the session in progress, which is only saved
-- when it ends (another item, logout or /reload), so yields count as you go
local function SalvageRuns()
    local runs = GoldsmithDB.salvageRuns or {}
    local current = CurrentRun()
    if not current then return runs end
    local all = {}
    for i, run in ipairs(runs) do all[i] = run end
    table.insert(all, current)
    return all
end

local function SaveRun()
    local run = CurrentRun()
    if not run then return end
    GoldsmithDB.salvageRuns = GoldsmithDB.salvageRuns or {}
    table.insert(GoldsmithDB.salvageRuns, run)
    while #GoldsmithDB.salvageRuns > MAX_SALVAGE_RUNS do
        table.remove(GoldsmithDB.salvageRuns, 1)
    end
end

local function EndSession()
    if summaryTimer then
        summaryTimer:Cancel()
    end
    PrintSummary()
    SaveRun()
    session = nil
end

-- Your skill, quality and resourcefulness for this salvage right now. The
-- game only reports resourcefulness for prospecting when it's given the
-- item being salvaged, so pass its GUID.
local function SalvageStats(recipeID, itemTarget, concentrated)
    local stats = {}
    local guid = C_Item.GetItemGUID(itemTarget)
    local ok, op = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, guid, false)
    if not ok or type(op) ~= "table" then return stats end
    stats.skill = (op.baseSkill or 0) + (op.bonusSkill or 0)
    stats.difficulty = (op.baseDifficulty or 0) + (op.bonusDifficulty or 0)
    stats.quality = op.quality
    stats.qualityID = op.craftingQualityID
    for _, stat in ipairs(op.bonusStats or {}) do
        if stat.bonusStatName == "Resourcefulness" then
            stats.resourcefulness = stat.ratingPct
        end
    end
    -- Concentration raises the quality, not your skill
    if concentrated then
        local okC, opC = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, guid, true)
        if okC and type(opC) == "table" then
            stats.quality = opC.quality
            stats.qualityID = opC.craftingQualityID
        end
    end
    return stats
end

local function OnCraftSalvage(recipeID, numCasts, itemTarget, craftingReagents, applyConcentration)
    if not itemTarget or not C_Item.DoesItemExist(itemTarget) then return end
    local herbID = C_Item.GetItemID(itemTarget)
    if not herbID then return end
    local concentrated = applyConcentration and true or false

    if session and (session.herbID ~= herbID or session.concentrated ~= concentrated) then
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

    -- A salvage recipe's quantity is how many items one cast uses up
    local okS, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)

    session = {
        herbID = herbID,
        herbName = herbName,
        profession = profession,
        baseline = SnapshotBags(),
        lastMill = 0,
        summaryMilled = 0,
        summaryOutputs = {},
        -- For GoldsmithDB.salvageRuns
        recipeID = recipeID,
        started = time(),
        concentrated = concentrated,
        stats = SalvageStats(recipeID, itemTarget, concentrated),
        perCast = okS and schematic and schematic.quantityMax or nil,
        casts = 0,
        used = 0,
        outputs = {},
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
    record.perCast = session.perCast or record.perCast
    if used > 0 then
        record.milled = record.milled + used
        session.summaryMilled = session.summaryMilled + used
        session.used = session.used + used
        session.lastMill = t
        changed = true
        addon:QueueSalvaged(herbID, used)
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
                session.outputs[itemID] = (session.outputs[itemID] or 0) + gained
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

-- Salvage profit (Crafts tab)
--
-- Each item you've salvaged (milled, prospected, crushed...) is a row in
-- the Crafts tab: one salvage's worth of it (e.g. 5 ore), what that costs
-- at today's AH price, what comes out at today's prices, and the profit
-- after the AH cut.
-- Yields are your own: the character's salvage runs (GoldsmithDB.
-- salvageRuns) once there are MIN_RUN_CASTS of them, else everyone's
-- totals for that item (GoldsmithDB.milling). Resourcefulness saves some
-- input: the character's latest resourcefulness times how much a proc
-- saves, measured from every salvage run once enough procs are expected
-- (else DEFAULT_PROC_SAVE). Yields from under SOLID_INPUTS items are a
-- rough guess, so those rows aren't recommended.
local MIN_RUN_CASTS = 10
local SOLID_INPUTS = 200
local DEFAULT_PROC_SAVE = 0.3
local MIN_EXPECTED_PROCS = 5
local SALVAGE_AH_CUT = 0.05
-- Do this next only suggests salvage that's clearly worth it: yields from
-- SOLID_INPUTS+ items, every output priced, and at least this ROI (or the
-- Worth crafting at setting, if higher), since yields swing from run to run
local SALVAGE_MIN_ROI = 20

-- Share of one salvage's input a resourcefulness proc saves
local function ProcSave()
    local saved, procs, units = 0, 0, 0
    for _, run in ipairs(SalvageRuns()) do
        if run.perCast and run.casts > 0 and run.resourcefulness then
            saved = saved + math.max(run.casts * run.perCast - run.used, 0)
            procs = procs + run.casts * run.resourcefulness / 100
            units = units + run.casts * run.resourcefulness / 100 * run.perCast
        end
    end
    if procs < MIN_EXPECTED_PROCS or units <= 0 then return DEFAULT_PROC_SAVE, false end
    return math.min(saved / units, 1), true
end

-- "Prospect", "Mill"... from the salvage recipe's name
local VERBS = { { "Prospect", "Prospect" }, { "Mill", "Mill" }, { "Crush", "Crush" },
                { "Shatter", "Shatter" }, { "Recycl", "Recycle" } }
local function SalvageVerb(recipeID, profession)
    local name = recipeID and C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(recipeID)
    for _, v in ipairs(VERBS) do
        if name and name:find(v[1]) then return v[2] end
    end
    if profession == "Inscription" then return "Mill" end
    if profession == "Jewelcrafting" then return "Prospect" end
    return "Salvage"
end

-- Salvage runs added up per item and character:
-- [itemID][charKey] = { casts, used, outputs = { [id] = qty }, perCast, recipeID, last }
local function RunTotals()
    local totals = {}
    for _, run in ipairs(SalvageRuns()) do
        if run.itemID and run.character and run.casts > 0 then
            totals[run.itemID] = totals[run.itemID] or {}
            local t = totals[run.itemID][run.character]
            if not t then
                t = { casts = 0, used = 0, outputs = {} }
                totals[run.itemID][run.character] = t
            end
            t.casts, t.used = t.casts + run.casts, t.used + run.used
            for id, qty in pairs(run.outputs or {}) do t.outputs[id] = (t.outputs[id] or 0) + qty end
            t.perCast, t.recipeID = run.perCast or t.perCast, run.recipeID or t.recipeID
            if not t.last or run.time >= t.last.time then t.last = run end
        end
    end
    return totals
end

-- The character's latest salvage run of another item in the same
-- profession (milling one herb is like milling another), or nil
local function SimilarRun(totals, charKey, profession)
    local latest
    for itemID, byChar in pairs(totals) do
        local t = byChar[charKey]
        local record = GoldsmithDB.milling[itemID]
        if t and record and (record.profession or "Inscription") == profession
            and (not latest or t.last.time > latest.time) then
            latest = t.last
        end
    end
    return latest
end

-- Who salvages an item: onlyMine, you; else the character who did it
-- most recently (counted ones only); else one with its profession
local function SalvagerFor(profession, byChar, onlyMine)
    if onlyMine then return addon.charKey end
    local best
    for key, t in pairs(byChar or {}) do
        if addon:IsCharacterIncluded(key) and (not best or t.last.time > byChar[best].last.time) then best = key end
    end
    if best then return best end
    if addon.char.professions[profession] then return addon.charKey end
    for key, c in pairs(GoldsmithDB.characters) do
        if c.professions[profession] and addon:IsCharacterIncluded(key) then return key end
    end
end

-- Estimated milling
--
-- Midnight mills every herb with one recipe and the game doesn't say what a
-- herb gives, so a herb normally only shows up once you've milled it. For
-- the herbs below, whose pigment is known, an estimate fills in until then:
-- pigment per herb from your own milling of the others in the list. Shown
-- on the Crafts tab so buying and milling can be compared, but never
-- recommended (whyNot), and plans don't use it. Azeroot is left out until
-- its pigment is confirmed.
local ESTIMATED_MILLING = {
    -- herb (lowest quality) = { pigment (lowest quality), names }
    [236761] = { 245807, "Tranquility Bloom", "Powder Pigment" },
    [236776] = { 245803, "Argentleaf", "Argentleaf Pigment" },
    [236770] = { 245865, "Sanguithorn", "Sanguithorn Pigment" },
    [236778] = { 245867, "Mana Lily", "Mana Lily Pigment" },
}

-- Estimated records (same shape as GoldsmithDB.milling's, plus estimated =
-- true) for the herbs above you haven't milled, keyed by herb item ID
function addon:GetEstimatedMilling()
    local herbs, pigments, from = 0, 0, {}
    for herbID, known in pairs(ESTIMATED_MILLING) do
        local record = GoldsmithDB.milling[herbID]
        if record and (record.milled or 0) > 0 then
            herbs = herbs + record.milled
            for _, out in pairs(record.outputs or {}) do pigments = pigments + out.qty end
            table.insert(from, known[2])
        end
    end
    local list = {}
    if herbs == 0 or pigments == 0 then return list end
    table.sort(from)
    for herbID, known in pairs(ESTIMATED_MILLING) do
        local record = GoldsmithDB.milling[herbID]
        if not (record and (record.milled or 0) > 0) then
            local pigmentID = known[1]
            list[herbID] = {
                name = C_Item.GetItemNameByID(herbID) or known[2],
                profession = "Inscription", perCast = 10, milled = herbs,
                outputs = { [pigmentID] = { name = C_Item.GetItemNameByID(pigmentID) or known[3], qty = pigments } },
                estimated = true, estimatedFrom = table.concat(from, ", "),
            }
        end
    end
    return list
end

-- Crafts tab rows for salvage, in the same shape as GetCraftRows' rows,
-- with item.salvage holding the details for the hover:
--   { inputID, inputName, perCast, inputPerCast, resourcefulness, procSave,
--     procMeasured, unitPrice, outputs = { { itemID, perCast, unit, value } },
--     sample, sampleFrom }
-- opts as for GetCraftRows (profitableOnly, onlyMine, showExpansion, match).
-- match gets the salvaged item's name, the row's name ("Prospect Umbral Tin
-- Ore", so "prospect" finds every prospecting row) and what it gives
-- (Powder Pigment finds Tranquility Bloom).
local function SalvageNames(itemID, record, byChar)
    local name = record.name or C_Item.GetItemNameByID(itemID)
    local names = { name }
    if name then
        -- Every verb a row for it can show (from each character's salvage
        -- spell, as the row does), so "crush" finds Crush 3 Amani Lapis
        local seen = {}
        for _, run in pairs(byChar or {}) do
            seen[SalvageVerb(run.recipeID, record.profession or "Inscription")] = true
        end
        if not next(seen) then seen[SalvageVerb(nil, record.profession or "Inscription")] = true end
        for verb in pairs(seen) do table.insert(names, verb .. " " .. name) end
    end
    for id, out in pairs(record.outputs or {}) do
        table.insert(names, out.name or C_Item.GetItemNameByID(id))
    end
    return names
end

function addon:GetSalvageRows(prof, opts)
    local list = {}
    local totals = RunTotals()
    local procSave, procMeasured = ProcSave()
    local minROI = addon:Setting("minROI")
    local records = {}
    for itemID, record in pairs(GoldsmithDB.milling or {}) do records[itemID] = record end
    for itemID, record in pairs(addon:GetEstimatedMilling()) do records[itemID] = record end
    for itemID, record in pairs(records) do
        local profession = record.profession or "Inscription"
        local byChar = totals[itemID]
        local charKey = (record.milled or 0) > 0 and (prof == "All" or profession == prof)
            and (not opts.showExpansion or opts.showExpansion(addon:GetItemExpansion(itemID)))
            and (not opts.match or opts.match(SalvageNames(itemID, record, byChar)))
            and SalvagerFor(profession, byChar, opts.onlyMine)
        local mine = charKey and byChar and byChar[charKey]
        if charKey and (not opts.onlyMine or mine or addon.char.professions[profession]) then
            -- Items salvaged before runs were saved: how many one salvage
            -- uses, and the character's resourcefulness, from their other
            -- salvage in the same profession
            local similar = SimilarRun(totals, charKey, profession)
            -- Yields per salvage: this character's runs, or everyone's totals
            local perCast = (mine and mine.perCast) or record.perCast or (similar and similar.perCast) or 1
            local outputs, sample, sampleFrom = {}, 0, nil
            if mine and mine.casts >= MIN_RUN_CASTS then
                for id, qty in pairs(mine.outputs) do
                    local out = record.outputs and record.outputs[id]
                    table.insert(outputs, { itemID = id, perCast = qty / mine.casts, name = out and out.name })
                end
                sample, sampleFrom = mine.used, charKey
            else
                for id, out in pairs(record.outputs or {}) do
                    table.insert(outputs, { itemID = id, perCast = out.qty / record.milled * perCast, name = out.name })
                end
                sample = record.milled
            end

            local resourcefulness = (mine and mine.last.resourcefulness)
                or (similar and similar.resourcefulness) or 0
            local inputPerCast = perCast * (1 - resourcefulness / 100 * procSave)
            local unitPrice = addon:GetMarketPrice(itemID)
            local value, partial = 0, false
            for _, o in ipairs(outputs) do
                o.unit = addon:GetMarketPrice(o.itemID)
                o.value = o.unit and o.unit * o.perCast
                if o.value then value = value + o.value else partial = true end
            end
            table.sort(outputs, function(a, b) return (a.value or 0) > (b.value or 0) end)

            local info = { price = value > 0 and value or nil, partial = partial }
            if unitPrice then
                info.cost = unitPrice * inputPerCast
                if info.price then
                    info.profit = info.price * (1 - SALVAGE_AH_CUT) - info.cost
                    info.margin = info.cost > 0 and (info.profit / info.cost * 100) or nil
                end
            end

            local inputName = record.name or C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
            local whyNot
            if record.estimated then
                whyNot = string.format("An estimate: no %s milled yet, so its yield is your average from %s. Mill some to measure it.",
                    inputName, record.estimatedFrom)
            elseif not unitPrice then
                whyNot = "No AH price for " .. inputName .. "."
            elseif sample < SOLID_INPUTS then
                whyNot = string.format("Yields from only %d %s salvaged so far, a rough guess until about %d.",
                    sample, inputName, SOLID_INPUTS)
            end

            if not opts.profitableOnly
                or (info.profit and info.profit > 0 and (not info.margin or info.margin >= minROI)) then
                local verb = SalvageVerb(mine and mine.recipeID, profession)
                table.insert(list, {
                    key = "salvage:" .. itemID,
                    recipe = { outputName = string.format("%s %d %s%s", verb, perCast, inputName,
                                   record.estimated and " (estimate)" or ""),
                               profession = profession },
                    info = info, charKey = charKey, itemID = itemID, whyNot = whyNot,
                    salvage = {
                        inputID = itemID, inputName = inputName, perCast = perCast,
                        inputPerCast = inputPerCast, resourcefulness = resourcefulness,
                        procSave = procSave, procMeasured = procMeasured, unitPrice = unitPrice,
                        outputs = outputs, sample = sample, sampleFrom = sampleFrom,
                        estimated = record.estimated, estimatedFrom = record.estimatedFrom,
                    },
                })
            end
        end
    end
    return list
end

-- Salvage for Do this next: rows with no reason against them (whyNot),
-- every output priced, and a clearly good ROI; best ROI first
function addon:GetBestSalvage(prof)
    local best = {}
    local minROI = math.max(SALVAGE_MIN_ROI, addon:Setting("minROI") or 0)
    local current = addon:GetCurrentExpansion()
    for _, row in ipairs(addon:GetSalvageRows(prof, {})) do
        local info = row.info
        if not row.whyNot and addon:GetItemExpansion(row.itemID) == current and not info.partial and info.profit and info.profit > 0
            and info.margin and info.margin >= minROI then
            table.insert(best, row)
        end
    end
    table.sort(best, function(a, b) return a.info.margin > b.info.margin end)
    return best
end

-- Salvage stats check (/gsm salvage)
--
-- Salvage recipes (prospecting, crushing, milling, shattering, recycling)
-- use up an item you pick for a random spread of outputs. This checks what
-- the game reports for them: whether GetCraftingOperationInfo gives
-- resourcefulness and the other stats for salvage, and whether it needs the
-- item being salvaged (its GUID) to do so. Each run is kept in
-- GoldsmithDB.salvageDump (last 10), so runs before and after spending
-- knowledge points can be compared.

local MAX_SALVAGE_DUMPS = 10

local function StatText(op)
    if type(op) ~= "table" then return tostring(op) end
    local parts = {}
    for _, stat in ipairs(op.bonusStats or {}) do
        table.insert(parts, string.format("%s %s%%", tostring(stat.bonusStatName), tostring(stat.ratingPct)))
    end
    return string.format("skill %s+%s, quality %s, %s", tostring(op.baseSkill), tostring(op.bonusSkill),
        tostring(op.quality), #parts > 0 and table.concat(parts, ", ") or "no bonus stats")
end

local function Operation(recipeID, guid, concentrate)
    local ok, op = pcall(C_TradeSkillUI.GetCraftingOperationInfo, recipeID, {}, guid, concentrate)
    if not ok then return "error: " .. tostring(op) end
    return op and CopyTable(op) or "nil"
end

-- Items this recipe can salvage, as a set of item IDs
local function SalvagableItems(recipeID)
    local set = {}
    if C_TradeSkillUI.GetSalvagableItemIDs then
        local ok, ids = pcall(C_TradeSkillUI.GetSalvagableItemIDs, recipeID)
        if ok and type(ids) == "table" then
            for _, id in ipairs(ids) do set[id] = true end
        end
    end
    return set
end

-- The item placed in the profession window's salvage slot, if this recipe
-- is the one showing
local function WindowSalvageItem(recipeID)
    local ok, guid = pcall(function()
        local tx = ProfessionsFrame.CraftingPage.SchematicForm:GetTransaction()
        if tx:GetRecipeID() ~= recipeID then return nil end
        return tx:GetAllocationItemGUID()
    end)
    if ok and guid then return guid end
end

-- A bag item this recipe can salvage: its GUID and item ID
local function BagSalvageItem(salvagable)
    for bag = 0, NUM_TOTAL_EQUIPPED_BAG_SLOTS or 5 do
        for slot = 1, C_Container.GetContainerNumSlots(bag) do
            local info = C_Container.GetContainerItemInfo(bag, slot)
            if info and info.itemID and salvagable[info.itemID] then
                return C_Item.GetItemGUID(ItemLocation:CreateFromBagAndSlot(bag, slot)), info.itemID
            end
        end
    end
end

function addon:DumpSalvageStats()
    if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then
        Print("Open your profession window first, then run /gsm salvage.")
        return
    end
    if not (C_TradeSkillUI.GetCraftingOperationInfo and Enum.TradeskillRecipeType) then
        Print("The game's crafting stats functions aren't available.")
        return
    end

    local okP, profInfo = pcall(C_TradeSkillUI.GetBaseProfessionInfo)
    local okC, childInfo = pcall(C_TradeSkillUI.GetChildProfessionInfo)
    local dump = {
        time = time(),
        character = UnitName("player"),
        profession = okP and profInfo and CopyTable(profInfo) or nil,
        expansion = okC and childInfo and CopyTable(childInfo) or nil,
        hasSalvagableAPI = C_TradeSkillUI.GetSalvagableItemIDs ~= nil,
        recipes = {},
    }

    local found = 0
    for _, recipeID in ipairs(C_TradeSkillUI.GetAllRecipeIDs() or {}) do
        local okS, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
        if okS and schematic and schematic.recipeType == Enum.TradeskillRecipeType.Salvage then
            local info = C_TradeSkillUI.GetRecipeInfo(recipeID)
            local salvagable = SalvagableItems(recipeID)
            local guid, itemID = WindowSalvageItem(recipeID), nil
            local from = guid and "window"
            if not guid then
                guid, itemID = BagSalvageItem(salvagable)
                from = guid and "bags"
            end
            if guid and not itemID and C_Item.GetItemIDByGUID then
                itemID = C_Item.GetItemIDByGUID(guid)
            end

            local entry = {
                name = schematic.name,
                learned = info and info.learned,
                schematic = CopyTable(schematic),
                salvagable = salvagable,
                item = itemID, itemFrom = from,
                noItem = Operation(recipeID, nil, false),
                withItem = guid and Operation(recipeID, guid, false) or nil,
                withItemConcentration = guid and Operation(recipeID, guid, true) or nil,
            }
            dump.recipes[recipeID] = entry

            if entry.learned then
                found = found + 1
                local itemName = itemID and (C_Item.GetItemNameByID(itemID) or ("item " .. itemID))
                print(string.format("  |cFFFFD100%s|r (%d)", tostring(schematic.name), recipeID))
                print("    No item: " .. StatText(entry.noItem))
                if guid then
                    print(string.format("    With %s (%s): %s", itemName, from, StatText(entry.withItem)))
                else
                    print("    No salvagable item in your bags to test with")
                end
            end
        end
    end

    GoldsmithDB.salvageDump = GoldsmithDB.salvageDump or {}
    table.insert(GoldsmithDB.salvageDump, dump)
    while #GoldsmithDB.salvageDump > MAX_SALVAGE_DUMPS do
        table.remove(GoldsmithDB.salvageDump, 1)
    end

    local skill = dump.expansion and dump.expansion.skillLevel
    if found == 0 then
        Print("No learned salvage recipes in this profession window.")
    else
        Print("%d salvage recipes checked%s. Saved; /reload so the details are written to disk.",
            found, skill and (" at skill " .. skill) or "")
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
    -- Save a session still open at /reload or logout
    frame:RegisterEvent("PLAYER_LOGOUT")
    frame:SetScript("OnEvent", function(_, event)
        if event == "BAG_UPDATE_DELAYED" then
            OnBagsChanged()
        else
            EndSession()
        end
    end)

    -- Count finished salvage casts (a recipe's ID is its spell ID)
    local castFrame = CreateFrame("Frame")
    castFrame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    castFrame:SetScript("OnEvent", function(_, _, _, _, spellID)
        if session and spellID == session.recipeID then
            session.casts = session.casts + 1
        end
    end)
end

_G.Goldsmith = addon
