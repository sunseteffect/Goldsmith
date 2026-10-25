local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Craft queue
--
-- Each character has a queue of crafts: what to make, how many, which
-- tier, with or without concentration. Add from the plan screen ("Add to
-- queue") or by right-clicking a craft on the Crafts tab. Salvage goes in
-- as batches ("prospect 1,000 Umbral Tin Ore"): right-click a salvage row.
-- The queue is planned as a whole: each entry uses what's left of your
-- materials after the ones above it, and one Auctionator list covers
-- everything to buy. Then "Craft next" (the Queue tab, a panel by the
-- profession window, or a key) does one step per press: mill, make the
-- materials, then the craft, going through the queue in order, starting
-- with the profession that's open. A craft leaves the queue once enough are
-- made (counted from craft results, so multicraft extras count); a batch
-- once that many items are salvaged.
--
-- Saved in GoldsmithDB.queues[charKey] = list of { recipeID, quantity,
-- made, tier, concentrate, added } for crafts, or { salvageID, quantity
-- (items to salvage), made, added } for salvage batches. A crafting order
-- (patron orders: user, 2026-10-23, "queue up all the mats i need") is a
-- craft with orderID, provided ({ [itemID] = qty } the customer gives),
-- customer, commission, rewardsValue and expires: shopping only, crafted
-- in the game's order window, and off the queue once crafted.
-- A stock-up ({ stockID = the material, quantity, made = bought so far,
-- added }, from Cheap materials: user, 2026-10-23) is shopping only: Buy
-- next buys it on top of what the crafts need, and it's off the queue once
-- that many are bought.
-- The panel's position: GoldsmithDB.ui2.queuePanel = { x, y } from the
-- profession window's top left (nil: under it, right edges lined up).

local AH_CUT = 0.05
local PANEL_WIDTH = 280
local PANEL_LINES = 8
local LINE_HEIGHT = 16
local DEFAULT_BATCH = 500

local function Queue(charKey, create)
    GoldsmithDB.queues = GoldsmithDB.queues or {}
    local q = GoldsmithDB.queues[charKey]
    if not q and create then
        q = {}
        GoldsmithDB.queues[charKey] = q
    end
    return q
end

local function CharName(charKey)
    local c = GoldsmithDB.characters[charKey]
    return (c and c.name) or (charKey and charKey:match("^[^%-]+")) or "?"
end
addon.QueueCharName = CharName

local UpdateSoon -- defined below

local function Changed()
    UpdateSoon()
    -- Buy next at the AH lists what the queue needs (user, 2026-10-19: a
    -- craft added with the AH open didn't show until it was reopened)
    if addon.ShopQueueChanged then addon.ShopQueueChanged() end
    if addon.VendorQueueChanged then addon.VendorQueueChanged() end
    if addon.Refresh then addon.Refresh() end
end

-- A queue entry changed in place (its choices, from the plan)
function addon:QueueEntryChanged()
    Changed()
end

function addon:GetQueue(charKey)
    return Queue(charKey) or {}
end

-- Characters with something queued, you first
function addon:GetQueuedCharacters()
    local keys = {}
    for key, entries in pairs(GoldsmithDB.queues or {}) do
        if #entries > 0 and key ~= addon.charKey then table.insert(keys, key) end
    end
    table.sort(keys)
    table.insert(keys, 1, addon.charKey)
    return keys
end

-- mix: an entry made with a set mix of material qualities (its
-- description), for a concentration split's other mix: the same item and
-- quality as the main entry, with the concentration left after it (user,
-- 2026-10-19: "it doesn't let me add the same item to the queue of a
-- different mix"). Entries without one pick their mix as they're planned.
local function Same(e, recipeID, tier, concentrate, salvageID, mix)
    if salvageID then return e.salvageID == salvageID end
    return e.recipeID ~= nil and e.recipeID == recipeID and e.tier == tier and not e.orderID
        and (e.concentrate == true) == (concentrate == true) and e.mix == mix
end

-- The queued craft (recipe, tier, concentration, set mix) or salvage
-- batch (salvageID = the item salvaged), or nil
function addon:FindQueueEntry(charKey, recipeID, tier, concentrate, salvageID, mix)
    for _, e in ipairs(Queue(charKey) or {}) do
        if Same(e, recipeID, tier, concentrate, salvageID, mix) then return e end
    end
end

-- Queues `quantity` of a craft, or, if it's already queued the same way,
-- sets it to make `quantity` more from now. Returns true when it was
-- already queued.
function addon:AddToQueue(charKey, recipeID, quantity, tier, concentrate, mix)
    local e = addon:FindQueueEntry(charKey, recipeID, tier, concentrate, nil, mix)
    if e then
        -- Queued again (the plan screen, a suggestion): its own pick of mix
        -- now, not an earlier suggestion's (QueueSuggestion sets it again)
        e.quantity, e.made, e.prefMix = quantity, 0, nil
    else
        table.insert(Queue(charKey, true), { recipeID = recipeID, quantity = quantity, made = 0, tier = tier,
                                             concentrate = concentrate == true, mix = mix, added = time() })
    end
    Changed()
    return e ~= nil
end

-- A suggestion queued straight from its line (right-click on the
-- Characters tab's to-do or the Overview's Do this next; user, 2026-10-19:
-- "less clicks once i know i can trust goldsmith"): `crafts` crafts, or
-- `items` when the suggestion counts items, queued as the items those
-- crafts are sure to make, the way the plan's Add to queue does.
-- prefMix: the mix the suggestion was planned with, for its first line
-- (a split's other mix is `mix`, which also tells the entries apart). The
-- concentration plan fits a day's concentration with its picks; queued
-- without one, the queue picked all silver (it "uses materials you have")
-- and needed 693 with 586 (Gloaming Alloy) and 599 with 450 (Lightfused
-- Mana Potion; user, 2026-10-24: "why are we recommending something we
-- can't craft?"). The queue uses it while the game still offers it.
function addon:QueueSuggestion(charKey, recipe, tier, concentrate, crafts, items, mix, prefMix)
    local quantity = items or addon:WithCharacter(charKey, addon.ItemsForCrafts, addon, recipe, crafts)
    quantity = math.max(math.floor(quantity + 0.0001), 1)
    local updated = addon:AddToQueue(charKey, recipe.recipeID, quantity, tier, concentrate == true, mix)
    local e = addon:FindQueueEntry(charKey, recipe.recipeID, tier, concentrate == true, nil, mix)
    if e and not mix then e.prefMix = prefMix end
    addon:Notify("info", "%s %d %s %s %s's queue.", updated and "Set" or "Added", quantity, recipe.outputName,
        updated and "in" or "to", CharName(charKey))
    if addon.RefreshWindow then addon.RefreshWindow() end
end

-- Same for a salvage batch: `quantity` items to salvage
function addon:AddSalvageToQueue(charKey, itemID, quantity)
    local e = addon:FindQueueEntry(charKey, nil, nil, nil, itemID)
    if e then
        e.quantity, e.made = quantity, 0
    else
        table.insert(Queue(charKey, true), { salvageID = itemID, quantity = quantity, made = 0, added = time() })
    end
    GoldsmithDB.ui2.salvageBatch = GoldsmithDB.ui2.salvageBatch or {}
    GoldsmithDB.ui2.salvageBatch[itemID] = quantity
    Changed()
    return e ~= nil
end

-- Stocking up on a material: buys `quantity` of it (set again if it's
-- already queued)
function addon:FindStockEntry(charKey, itemID)
    for _, e in ipairs(Queue(charKey) or {}) do
        if e.stockID == itemID then return e end
    end
end

function addon:AddStockToQueue(charKey, itemID, quantity, name)
    local e = addon:FindStockEntry(charKey, itemID)
    if e then
        e.quantity, e.made = quantity, 0
    else
        table.insert(Queue(charKey, true), { stockID = itemID, quantity = quantity, made = 0, name = name, added = time() })
    end
    Changed()
    addon:Notify("info", "%s stocking up on %d %s in %s's queue. Buy next buys it at the AH.",
        e and "Set" or "Added", quantity, name or "items", CharName(charKey))
    return e ~= nil
end

-- Asks how many to stock up on (suggested: `quantity`), then queues it
-- (the salvage popup's PopupBox is further down)
local function StockBox(popup)
    return popup.GetEditBox and popup:GetEditBox() or popup.editBox
end

-- What buying n of it costs: the listings walked with a fresh search, else
-- today's price for each
local function StockCost(itemID, n)
    if not n or n <= 0 then return nil end
    local unit = addon:GetLiveBuyCost(itemID, n) or addon:GetMarketPrice(itemID, true)
    return unit and unit * n
end

-- The question with what the amount typed costs, kept up as you type
-- (user, 2026-10-23: "so i know how much 100 would cost before clicking ok")
local function StockPrompt(popup, data)
    data = data or popup.data
    if not data then return end
    local n = tonumber(StockBox(popup):GetText())
    local cost = n and StockCost(data.itemID, n)
    local text = data.question .. "\n\n" .. (cost and string.format("About %s for %d", addon:FormatMoney(cost), n) or " ")
    local fs = (popup.GetTextFontString and popup:GetTextFontString()) or popup.Text or popup.text
    if fs and fs.SetText then fs:SetText(text) end
    if StaticPopup_Resize then pcall(StaticPopup_Resize, popup, popup.which) end
end

local function AcceptStock(popup, data)
    data = data or popup.data
    local n = tonumber(StockBox(popup):GetText())
    if data and n and n > 0 then addon:AddStockToQueue(data.charKey, data.itemID, n, data.name) end
end

StaticPopupDialogs["GOLDSMITH_STOCK_UP"] = {
    text = "%s",
    button1 = OKAY or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    OnShow = function(self, data)
        data = data or self.data
        local box = StockBox(self)
        box:SetNumeric(true)
        box:SetText(tostring(data and data.quantity or 1))
        box:HighlightText()
        box:SetFocus()
        StockPrompt(self, data)
    end,
    EditBoxOnTextChanged = function(box, data)
        StockPrompt(box:GetParent(), data)
    end,
    OnAccept = AcceptStock,
    EditBoxOnEnterPressed = function(box, data)
        local popup = box:GetParent()
        AcceptStock(popup, data)
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function addon:AskStockUp(charKey, itemID, name, quantity)
    local question = string.format("How many %s to stock up on? (Buy next buys them for %s)", name or "items", CharName(charKey))
    StaticPopup_Show("GOLDSMITH_STOCK_UP", question, nil,
        { charKey = charKey, itemID = itemID, name = name, quantity = quantity, question = question })
end

-- How many of a material your queue still has to buy to stock up
function addon:QueuedStock(itemID)
    local e = addon:FindStockEntry(addon.charKey, itemID)
    return e and math.max(e.quantity - (e.made or 0), 0) or 0
end

-- Asks how many to salvage, then queues the batch
local function PopupBox(popup)
    return popup.GetEditBox and popup:GetEditBox() or popup.editBox
end

local function AcceptBatch(popup, data)
    data = data or popup.data
    local n = tonumber(PopupBox(popup):GetText())
    if data and n and n > 0 then
        addon:AddSalvageToQueue(data.charKey, data.itemID, n)
        addon:Notify("info", "Queued: %s %d %s for %s.", data.verb, n, data.name, CharName(data.charKey))
    end
end

StaticPopupDialogs["GOLDSMITH_SALVAGE_BATCH"] = {
    text = "%s",
    button1 = OKAY or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    OnShow = function(self, data)
        data = data or self.data
        local box = PopupBox(self)
        box:SetNumeric(true)
        box:SetText(tostring(data and data.quantity or DEFAULT_BATCH))
        box:HighlightText()
        box:SetFocus()
    end,
    OnAccept = AcceptBatch,
    EditBoxOnEnterPressed = function(box, data)
        local popup = box:GetParent()
        AcceptBatch(popup, data)
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

function addon:AskSalvageBatch(charKey, itemID, name, verb)
    local queued = addon:FindQueueEntry(charKey, nil, nil, nil, itemID)
    local remembered = GoldsmithDB.ui2.salvageBatch and GoldsmithDB.ui2.salvageBatch[itemID]
    local quantity = queued and math.max(queued.quantity - (queued.made or 0), 1) or remembered or DEFAULT_BATCH
    StaticPopup_Show("GOLDSMITH_SALVAGE_BATCH",
        string.format("How many %s to %s? (for %s)", name, (verb or "salvage"):lower(), CharName(charKey)), nil,
        { charKey = charKey, itemID = itemID, name = name, verb = verb or "Salvage", quantity = quantity })
end

-- A crafting order from the game's order window (OrderCost.lua's Add to
-- queue): preview is its GetOrderPreview (provided, commission, rewards)
function addon:AddOrderToQueue(order, preview)
    local recipeID = type(order) == "table" and order.spellID
    local recipe = recipeID and GoldsmithDB.recipes[recipeID]
    if not recipe then
        addon:Notify("info", "Goldsmith hasn't read this recipe yet. Find it in your profession window once, then try again.")
        return
    end
    if addon:FindOrderEntry(order.orderID) then
        addon:Notify("info", "That order is already in the queue.")
        return
    end
    local expires = tonumber(order.expirationTime)
    table.insert(Queue(addon.charKey, true), {
        orderID = order.orderID, recipeID = recipeID, quantity = 1, made = 0,
        -- An order that asks for a quality: planned to reach it
        tier = (order.minQuality or 0) > 1 and order.minQuality or nil, concentrate = false,
        provided = preview and preview.provided or {}, customer = order.customerName,
        commission = preview and preview.commission or 0, rewardsValue = preview and preview.rewardsValue or 0,
        expires = expires and expires > time() and expires or nil, added = time(),
    })
    Changed()
    addon:Notify("info", "Added the order for %s to %s's queue. Buy next shops for it; craft it in the order window.",
        recipe.outputName, CharName(addon.charKey))
end

-- A crafting order for this recipe in this character's queue, or nil
function addon:QueuedOrderFor(recipeID)
    for _, e in ipairs(Queue(addon.charKey) or {}) do
        if e.orderID and e.recipeID == recipeID then return e end
    end
end

-- This character's queue entry for a crafting order, or nil
function addon:FindOrderEntry(orderID)
    if not orderID then return nil end
    for _, e in ipairs(Queue(addon.charKey) or {}) do
        if e.orderID == orderID then return e end
    end
end

local function RemoveOrder(orderID, why)
    local q = Queue(addon.charKey)
    for i, e in ipairs(q or {}) do
        if e.orderID == orderID then
            table.remove(q, i)
            local recipe = GoldsmithDB.recipes[e.recipeID]
            addon:Notify("info", "Queue: the order for %s, %s.", recipe and recipe.outputName or "an item", why)
            Changed()
            return
        end
    end
end

-- An order's recipe without what the customer provides: those slots
-- (or that much of them) aren't yours to buy
local function OrderRecipe(recipe, provided)
    if not (provided and next(provided)) then return recipe end
    local copy, left = {}, {}
    for k, v in pairs(recipe) do copy[k] = v end
    for id, qty in pairs(provided) do left[id] = qty end
    copy.reagents = {}
    for _, slot in ipairs(recipe.reagents or {}) do
        local qty = slot.quantity or 0
        for _, id in ipairs(slot.itemIDs or {}) do
            local take = math.min(left[id] or 0, qty)
            if take > 0 then left[id], qty = left[id] - take, qty - take end
        end
        if qty > 0 then
            local s = {}
            for k, v in pairs(slot) do s[k] = v end
            s.quantity = qty
            table.insert(copy.reagents, s)
        end
    end
    return copy
end

function addon:RemoveQueueEntry(charKey, entry)
    local q = Queue(charKey) or {}
    for i, e in ipairs(q) do
        if e == entry then table.remove(q, i) break end
    end
    Changed()
end

-- delta -1 moves it up, 1 down
function addon:MoveQueueEntry(charKey, entry, delta)
    local q = Queue(charKey) or {}
    for i, e in ipairs(q) do
        local j = i + delta
        if e == entry and q[j] then
            q[i], q[j] = q[j], q[i]
            break
        end
    end
    Changed()
end

function addon:ClearQueue(charKey)
    if GoldsmithDB.queues then GoldsmithDB.queues[charKey] = nil end
    Changed()
end

-- Counts toward the first matching entry on this character; it leaves
-- the queue once its quantity is reached
local function Progress(match, quantity, describe, finished)
    local q = Queue(addon.charKey)
    if not q then return end
    for i, e in ipairs(q) do
        if match(e) then
            e.made = (e.made or 0) + (quantity or 0)
            local done = e.made >= e.quantity or (finished and finished(e))
            if done then
                table.remove(q, i)
                addon:Notify("info", "Queue: %s, done.", describe(e))
                -- Said as the last entry did it: a queue of stock-ups said
                -- "everything's crafted" (user, 2026-10-23)
                if #q == 0 then
                    local word = (e.stockID and "bought") or (e.salvageID and "salvaged") or "crafted"
                    addon:Notify("info", "Queue: everything's %s.", word)
                end
            end
            Changed()
            return e, done
        end
    end
end

-- A craft finished (Pricing.lua's craft result; not order crafts, which
-- go to the customer). itemID is what it made: a different quality than
-- the entry's tier doesn't count toward it (silver made by hand isn't the
-- gold queued). Recipes without tiers, gear (one item for every tier) or
-- tiers not read yet match on the recipe alone.
function addon:QueueCrafted(recipeID, quantity, itemID)
    -- Made by Craft next as a material for another entry (Crafts.lua)
    local step = addon.materialStep
    if step and step.recipeID == recipeID and GetTime() < step.untilTime then return end
    local madeTier
    local td = addon.char.tierData and addon.char.tierData[recipeID]
    for tier, out in pairs(td and td.outputs or {}) do
        if out.itemID == itemID then
            if madeTier then madeTier = nil break end -- gear: same item every tier
            madeTier = tier
        end
    end
    Progress(function(e)
        return e.recipeID == recipeID and not e.orderID and (not e.tier or not madeTier or e.tier == madeTier)
    end, quantity, function(e)
        local recipe = GoldsmithDB.recipes[recipeID]
        return string.format("made %d %s", e.made, recipe and recipe.outputName or "items")
    end)
end

-- Bought at the AH (Core.lua, every purchase, Buy next or not): counts
-- toward a stock-up of it
function addon:QueueBought(itemID, quantity)
    if not itemID then return end
    Progress(function(x) return x.stockID == itemID end, quantity, function(e)
        return string.format("stocked up on %d %s", e.made, e.name or C_Item.GetItemNameByID(itemID) or "items")
    end)
end

-- Items used up by salvaging (Milling.lua, as bags change)
-- A batch is done once what's left of it is under one cast and you hold
-- under one cast: resourcefulness saves items, so 500 Tranquility Bloom
-- ended with a few that can't be milled and no "done" (user, 2026-10-21)
-- gained: what came out with them ({ [itemID] = qty }), kept on the entry
-- for the "Mill complete" notice (CraftDone.lua). Pigment can arrive a
-- moment after the last herbs go, so a batch just done still takes it.
local salvageDone = {} -- [itemID] = { entry, at }
function addon:QueueSalvaged(itemID, used, gained)
    local record = GoldsmithDB.milling and GoldsmithDB.milling[itemID]
    local perCast = record and record.perCast or 1
    local e, done
    if used > 0 then
        e, done = Progress(function(x) return x.salvageID == itemID end, used, function(x)
            return string.format("salvaged %d %s", x.made, C_Item.GetItemNameByID(itemID) or "items")
        end, function(x)
            return perCast > 1 and x.quantity - x.made < perCast
                and (C_Item.GetItemCount(itemID) or 0) < perCast
        end)
    end
    if not e then
        local recent = salvageDone[itemID]
        if recent and GetTime() - recent.at < 10 then e = recent.entry end
    end
    if e and gained then
        e.got = e.got or {}
        for id, qty in pairs(gained) do e.got[id] = (e.got[id] or 0) + qty end
    end
    if done then
        salvageDone[itemID] = { entry = e, at = GetTime() }
        C_Timer.After(2, function()
            if addon.ShowSalvageDone then addon:ShowSalvageDone(itemID, e) end
        end)
    end
end

-- Planning

local function Merge(map, entry)
    local m = map[entry.itemID]
    if not m then
        m = { itemID = entry.itemID, name = entry.name, quantity = 0, cost = 0, unit = entry.unit,
              qualityTier = entry.qualityTier, tierCount = entry.tierCount }
        map[entry.itemID] = m
    end
    m.quantity = m.quantity + entry.quantity
    m.cost = m.cost + (entry.cost or 0)
    m.live = m.live or entry.live
    m.short = m.short or entry.short
end

local function Sorted(map)
    local list = {}
    for _, m in pairs(map) do table.insert(list, m) end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- A salvage batch as a plan: buy what you don't have of the input; cost,
-- worth and profit from the salvage row's yields (GetSalvageRows), scaled
-- to the batch. Resourcefulness stretches the input, so the batch gets
-- through more salvages than items ÷ items per salvage.
local function SalvagePlan(row, salvageRows, useOnHand, pool)
    local itemID, remaining = row.entry.salvageID, row.remaining
    local found = salvageRows[itemID]
    local s = found and found.salvage
    local name = (s and s.inputName) or C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
    row.verb = found and found.recipe.outputName:match("^(%S+)") or "Salvage"
    row.inputName = name
    row.recipe = { outputName = row.verb .. " " .. name,
                   profession = found and found.recipe.profession or (GoldsmithDB.milling[itemID] or {}).profession }
    row.salvageRow = found

    local have = 0
    if useOnHand then
        -- Bought with Buy next and still in the mailbox counts too: a mill
        -- batch kept asking for the 494 herbs just bought (user, 2026-10-21)
        local held = addon:GetOnHand(itemID)
        have = math.max(held - (pool[itemID] or 0), 0)
        have = math.min(have, remaining)
        pool[itemID] = (pool[itemID] or 0) + have
    end
    local perCast = s and s.perCast or 1
    local casts = remaining / math.max(s and s.inputPerCast or perCast, 0.01)
    local plan = { salvage = true, crafts = math.ceil(remaining / perCast - 0.0001), casts = casts, have = have,
                   buyAH = {}, buyVendor = {}, cost = 0, complete = false, outputs = {} }
    local unit = s and s.unitPrice
    if unit then
        plan.cost = unit * remaining
        if remaining > have then
            -- With a fresh search, walk the listings for all of it, as a
            -- craft's plan does: 160 Malleable Root was planned at the
            -- lowest 14.93g with 31 listed there (user, 2026-10-23)
            local qty = remaining - have
            local live, enough = addon:GetLiveBuyCost(itemID, qty)
            table.insert(plan.buyAH, { itemID = itemID, name = name, quantity = qty, unit = live or unit,
                                       cost = (live or unit) * qty, live = live and true or nil,
                                       short = live and not enough or nil })
        end
    end
    if found and found.info.price and unit then
        plan.revenue = found.info.price * (1 - AH_CUT) * casts
        plan.profit = plan.revenue - plan.cost
        plan.complete = not found.info.partial
    end
    for _, o in ipairs(s and s.outputs or {}) do
        table.insert(plan.outputs, { itemID = o.itemID, name = o.name, quantity = o.perCast * casts,
                                     value = o.unit and o.unit * o.perCast * casts })
    end
    return plan
end

-- A stock-up as a plan: all of it bought at the AH, on top of what the
-- crafts need (it doesn't take from what you hold). Not a cost of the
-- queue's crafts, so it's left out of the queue's cost and profit; Buy
-- next's spend includes it.
local function StockPlan(row)
    local itemID = row.entry.stockID
    local name = row.entry.name or C_Item.GetItemNameByID(itemID) or ("item " .. itemID)
    row.recipe = { outputName = "Stock up: " .. name }
    row.stockName = name
    -- With a fresh search, the listings walked for all of it (SalvagePlan)
    local live, enough = addon:GetLiveBuyCost(itemID, row.remaining)
    local unit = live or addon:GetMarketPrice(itemID, true)
    local plan = { stock = true, crafts = 0, buyAH = {}, buyVendor = {}, cost = unit and unit * row.remaining or 0,
                   complete = unit ~= nil }
    table.insert(plan.buyAH, { itemID = itemID, name = name, quantity = row.remaining, unit = unit,
                               cost = unit and unit * row.remaining or 0, live = live and true or nil,
                               short = live and not enough or nil })
    return plan
end

-- One salvage batch planned on its own, for the mill planner on the Crafts
-- tab: SalvagePlan's plan plus row (verb, inputName, salvageRow) and what
-- a shopping list needs (recipe, quantity, listName, listKey)
function addon:BuildSalvagePlan(itemID, quantity, useOnHand)
    local salvageRows = {}
    for _, r in ipairs(addon:GetSalvageRows("All", {})) do salvageRows[r.itemID] = r end
    local row = { entry = { salvageID = itemID }, remaining = quantity }
    local plan = SalvagePlan(row, salvageRows, useOnHand, {})
    plan.row, plan.recipe, plan.quantity = row, row.recipe, quantity
    plan.listName = string.format("Goldsmith: %s x%d", row.recipe.outputName, quantity)
    plan.listKey = "salvage:" .. itemID
    return plan
end

-- The whole queue planned in order. Returns { charKey, mine, rows = { {
-- entry, recipe, remaining, p, tierInfo, plan, state } }, cost, revenue,
-- profit, complete, buyAH, buyVendor, spend, listName, listKey }.
-- Another character's queue counts what they held at their last login
-- (Planner.lua's GetOnHand) and has no craft states.
function addon:BuildQueue(charKey)
    local mine = charKey == addon.charKey
    local useOnHand = true
    local pool = {}
    local q = { charKey = charKey, mine = mine, rows = {}, cost = 0, revenue = 0, profit = 0, complete = true,
                listName = "Goldsmith: Queue (" .. CharName(charKey) .. ")", listKey = "queue:" .. charKey }
    local ah, vendor = {}, {}
    -- Items bought only to stock up (not for any craft): Buy next doesn't
    -- weigh their price against the queue's profit (Shop.lua)
    local stockOnly = {}
    q.stockOnly = stockOnly
    local salvageRows
    -- Orders past their time are gone from the game too
    local entries = Queue(charKey) or {}
    for i = #entries, 1, -1 do
        local e = entries[i]
        if e.orderID and e.expires and e.expires <= time() then
            table.remove(entries, i)
            local recipe = GoldsmithDB.recipes[e.recipeID]
            addon:Notify("info", "Queue: the order for %s expired, so it's off the queue.",
                recipe and recipe.outputName or "an item")
        end
    end
    for _, e in ipairs(entries) do
        local row = { entry = e, remaining = math.max(e.quantity - (e.made or 0), 0) }
        local plan
        if e.stockID then
            if row.remaining > 0 then plan = StockPlan(row) end
        elseif e.salvageID and row.remaining > 0 then
            if not salvageRows then
                salvageRows = {}
                for _, r in ipairs(addon:GetSalvageRows("All", {})) do salvageRows[r.itemID] = r end
            end
            plan = addon:WithCharacter(charKey, SalvagePlan, row, salvageRows, useOnHand, pool)
            if mine then
                row.state = addon.SalvageState(e.salvageID, row.inputName, row.remaining, row.verb)
            end
        else
            row.recipe = e.recipeID and GoldsmithDB.recipes[e.recipeID]
            if row.recipe and row.remaining > 0 then
                row.p = { recipe = row.recipe, charKey = charKey, tier = e.tier, concentrate = e.concentrate }
                if e.orderID and e.tier then
                    -- An order's quality is a minimum: the lowest quality at
                    -- or above it that can be planned. Exactly 2 of 5 for a
                    -- Toolbox had no way to make it, so the entry had no
                    -- plan and Buy next bought nothing for it (user,
                    -- 2026-10-23). None readable: the plain recipe, rather
                    -- than shop for nothing.
                    local c = GoldsmithDB.characters[charKey]
                    local td = c and c.tierData and c.tierData[e.recipeID]
                    for tier = e.tier, math.max(td and td.qualities and #td.qualities or 0, e.tier) do
                        row.p.tier = tier
                        row.tierInfo = addon:WithCharacter(charKey, addon.FindTierInfo, row.p)
                        if row.tierInfo then break end
                    end
                    if not row.tierInfo then row.p.tier = nil end
                else
                    row.tierInfo = addon:WithCharacter(charKey, addon.FindTierInfo, row.p)
                end
                if row.p.tier and not row.tierInfo then
                    -- The queued quality isn't among the recipe's ways to make
                    -- it right now (after a relog, before the profession's
                    -- data is read). Planning without a tier showed a silver
                    -- plan at a loss for a gold entry and would craft
                    -- whatever came out (2026-10-14): wait instead.
                    row.tierMissing = true
                    if mine then
                        row.state = { enabled = false, notes = {}, steps = {},
                            blockers = { "Open " .. (row.recipe.profession or "the profession")
                                .. " so Goldsmith can read this quality again." } }
                    end
                else
                    -- The mix the planner shows: what you hold, or your pick
                    if row.tierInfo then
                        -- A set mix (a split's other mix) while the game
                        -- still offers it, else the usual pick
                        local set = (e.mix or e.prefMix) and addon:MixByDescription(row.tierInfo, e.mix or e.prefMix)
                        row.tierInfo = set or addon:WithCharacter(charKey, addon.ChooseMix, addon, row.recipe,
                            row.tierInfo, row.remaining)
                    end
                    local planRecipe = e.orderID and OrderRecipe(row.recipe, e.provided) or row.recipe
                    plan = addon:WithChoices(e.choices, addon.WithCharacter, addon, charKey, addon.BuildPlan, addon,
                        planRecipe, row.remaining, useOnHand, row.tierInfo, pool)
                    if mine then row.state = addon.GetCraftState(row.p, row.tierInfo, plan) end
                    if e.orderID and plan then
                        -- What the order pays, not what the item sells for
                        plan.revenue = (e.commission or 0) + (e.rewardsValue or 0)
                        plan.profit = plan.revenue - plan.cost
                        -- The craft itself happens in the game's order
                        -- window; steps before it (materials to make) don't
                        local s = row.state
                        if s and s.final then
                            local missing = {}
                            for _, list in ipairs({ plan.buyAH or {}, plan.buyVendor or {} }) do
                                for _, item in ipairs(list) do
                                    table.insert(missing, item.quantity .. " " .. (item.name or ("item " .. item.itemID)))
                                end
                            end
                            row.state = { enabled = false, notes = {}, orderReady = #missing == 0,
                                blockers = { #missing > 0
                                    and string.format("Missing for the order: %s.", table.concat(missing, ", "))
                                    or "Everything's ready: craft it in the crafting orders window." } }
                        end
                    end
                end
                if row.tierMissing then q.complete = false end
            end
        end
        row.plan = plan
        if plan and plan.stock then
            for _, entry in ipairs(plan.buyAH) do
                Merge(ah, entry)
                stockOnly[entry.itemID] = stockOnly[entry.itemID] ~= false
            end
        elseif plan then
            for _, entry in ipairs(plan.buyAH) do stockOnly[entry.itemID] = false end
            q.cost = q.cost + plan.cost
            if not plan.complete then q.complete = false end
            if plan.revenue then
                q.revenue = q.revenue + plan.revenue
                q.profit = q.profit + plan.profit
            else
                q.complete = false
            end
            for _, entry in ipairs(plan.buyAH) do Merge(ah, entry) end
            for _, entry in ipairs(plan.buyVendor) do Merge(vendor, entry) end
        end
        table.insert(q.rows, row)
    end
    q.buyAH, q.buyVendor = Sorted(ah), Sorted(vendor)
    -- For hovers: what the vendor panel buys for your whole queue
    if mine then addon.lastQueueVendor = q.buyVendor end
    q.spend = 0
    for _, entry in ipairs(q.buyAH) do q.spend = q.spend + entry.cost end
    return q
end

-- Materials across the queue with a missing or old AH price
function addon:QueueStalePrices(q)
    local seen, stale = {}, {}
    local function Add(itemID)
        if seen[itemID] then return end
        seen[itemID] = true
        table.insert(stale, { itemID = itemID })
    end
    for _, row in ipairs(q.rows) do
        local plan = row.plan
        if plan and plan.stock then
            local price, source, age = addon:GetAHPriceInfo(row.entry.stockID)
            if not price or addon:IsPriceOld(source, age) then Add(row.entry.stockID) end
        elseif plan and plan.salvage then
            -- The input and what comes out
            local ids = { row.entry.salvageID }
            for _, o in ipairs(plan.outputs) do table.insert(ids, o.itemID) end
            for _, itemID in ipairs(ids) do
                local price, source, age = addon:GetAHPriceInfo(itemID)
                if not price or addon:IsPriceOld(source, age) then
                    Add(itemID)
                end
            end
        elseif plan then
            for _, item in ipairs(addon.StalePrices(plan)) do Add(item.itemID) end
        end
    end
    return stale
end

-- The crafting buff (Shattered Essence, Everburning Ignition) that's off
-- for the next craft, as the plan says above its Craft button; nil when
-- it's on, not that profession's, or another character's queue (user,
-- 2026-10-19: Maddoxynn's queue didn't say Shattered Essence was off)
function addon:QueueMissingBuff(row, mine)
    local recipe = mine and row and not row.entry.salvageID and row.recipe
    return recipe and recipe.profession and addon:MissingCraftBuff(recipe.profession, recipe) or nil
end

-- A queued entry's name, with tier icon
function addon:QueueRowName(row)
    if row.entry.stockID then
        local tier, tierCount = addon:GetItemTier(row.entry.stockID)
        return "Stock up: " .. (tier and (addon:TierIconText(tier, tierCount) .. " ") or "") .. (row.stockName or "?")
    end
    local name = row.recipe and row.recipe.outputName
        or (row.entry.recipeID and ("recipe " .. row.entry.recipeID)) or "?"
    local icon = row.tierInfo and (addon:TierIconText(row.tierInfo.tier, row.tierInfo.tierCount) .. " ") or ""
    if row.tierMissing then
        -- The queued quality, waiting to be read again (BuildQueue)
        local c = row.p and GoldsmithDB.characters[row.p.charKey]
        local td = c and c.tierData and c.tierData[row.entry.recipeID]
        icon = addon:TierIconText(row.entry.tier, td and td.qualities and #td.qualities or nil) .. " "
    elseif not row.tierInfo and row.recipe and row.recipe.recipeID then
        -- A refine: the one quality it makes
        local tier, tierCount = addon:FixedTier(row.recipe)
        icon = tier and (addon:TierIconText(tier, tierCount) .. " ") or ""
    end
    -- A set mix says which, so it doesn't read as a repeat
    local mix = row.entry.mix and ("  " .. addon:MixIcon(row.entry.mix)) or ""
    if row.entry.orderID then mix = mix .. " (order)" end
    return icon .. name .. mix
end

-- A short status for a queued entry and its color: what Craft next would
-- do for it, or why it can't
function addon:QueueRowStatus(row, q)
    if row.entry.stockID then return "Buy at the AH", "muted" end
    if not row.recipe then return "Recipe not loaded", "warning" end
    if not q.mine then return "On " .. CharName(q.charKey), "muted" end
    local s = row.state
    if not s then return "", "muted" end
    if s.enabled and s.open then return s.label, "muted" end
    if s.enabled then return s.label, "profit" end
    return addon:BlockedLabel(s)
end

-- Why a craft state can't craft, short, and its color ("Needs Alchemist's
-- Lab Bench"): the queue's statuses and the plan's Craft button (user,
-- 2026-10-18: the plan's button still said "Craft 1")
function addon:BlockedLabel(s)
    if s.orderReady then return "Craft in order window", "profit" end
    if s.orderBlocked then return "Queued as an order", "warning" end
    local blocker = s.blockers and s.blockers[1] or ""
    -- Short on concentration beats a missing station: walking to the
    -- table wouldn't let it craft (user, 2026-10-16)
    -- Then a missing station over materials, so the queue panel and the
    -- Queue tab say the same (user, 2026-10-22: the panel said Needs
    -- materials, the tab Needs Alchemist's Lab Bench)
    local station
    for _, b in ipairs(s.blockers or {}) do
        if b:find("concentration") then blocker, station = b, nil break end
        if not station and b:find("^Needs .+ nearby") then station = b end
    end
    blocker = station or blocker
    local station = blocker:match("^Needs (.+) nearby")
    if station then
        return "Needs " .. station, "warning"
    elseif blocker:find("^Missing") or blocker:find("^Not enough") and not blocker:find("concentration") then
        -- One thing short: name it, without the count ("Needs Luminant Flux"):
        -- the step needed 19, the vendor line said 53 for the whole queue
        local what = blocker:match("^Missing for [^:]+: (.-)%.$")
        -- Bought and still in the mail: say where it is, short. "Needs
        -- Sienna Ink (20 in your mailbox)" ran off the button (user,
        -- 2026-10-24); the hover has the whole line.
        if what and what:find("in your mailbox") then return "In the mailbox", "warning" end
        if what and what:find("not mailed yet") then return "Not mailed yet", "warning" end
        if what and not what:find(",") then return "Needs " .. (what:gsub("^%d+ ", "")), "warning" end
        return "Needs materials", "warning"
    elseif blocker:find("concentration") then
        return "Needs concentration", "warning"
    elseif blocker:find("^Open") then
        return blocker:match("^(Open %S+)") or "Open profession", "muted"
    elseif blocker:find("mailbox") then
        return "In the mailbox", "warning"
    elseif blocker:find("bank") then
        return "In the bank", "warning"
    end
    return "Can't craft yet", "warning"
end

-- A "Missing for 10 crafts: 20 Luminant Flux." blocker in a tooltip, with
-- vendor materials given as the plan's whole amount: the step's 20 next to
-- the plan's 26 and the shopping line's 54 confused (user, 2026-10-22: say
-- what the whole craft needs)
-- One item per line, under its heading: run together, "Missing for 2
-- crafts: 12 Ominous Octopus, 2 Earthy Garnish. Buy 30 A Big Ol' Stick of
-- Butter (6 for this craft) from a vendor…" was hard to read (user,
-- 2026-10-25). Vendor items show only the whole queue's amount, what the
-- vendor panel buys: queueing, you care about the total (user, 2026-10-25:
-- "6 for this craft" dropped)
local function ListLines(head, items)
    return head .. "\n  " .. table.concat(items, "\n  ")
end

function addon:ShoppingBlocker(line, plan)
    local head, list = line:match("^(Missing for [^:]+): (.-)%.$")
    if not list then return line end
    local items = {}
    for part in list:gmatch("[^,]+") do table.insert(items, (part:gsub("^%s+", ""))) end
    local vendor = plan and plan.buyVendor
    if not vendor or #vendor == 0 then return ListLines(head .. ":", items) end
    local fromVendor, other = {}, {}
    for _, part in ipairs(items) do
        local name = part:match("^%d+ (.+)$") or part
        -- Without the quality icon and any "(20 in your mailbox)": "3 ◆
        -- Sunglass Vial" never matched the vendor list's "Sunglass Vial",
        -- so the hover said Missing, not "from a vendor" (user, 2026-10-24)
        local plain = name:gsub("|A.-|a", ""):gsub("%s*%(.-%)$", ""):gsub("^%s+", "")
        local total
        for _, entry in ipairs(vendor) do
            if entry.name == plain then total = entry.quantity end
        end
        -- The whole queue's, which the vendor panel buys: the hover said 3
        -- Sunglass Vial and the vendor 18 (user, 2026-10-24)
        local all
        for _, entry in ipairs(addon.lastQueueVendor or {}) do
            if entry.name == plain and total and entry.quantity > total then all = entry.quantity end
        end
        table.insert(total and fromVendor or other, total and ((all or total) .. " " .. name) or part)
    end
    if #fromVendor == 0 then return ListLines(head .. ":", items) end
    local text = ListLines("Buy from vendor:", fromVendor)
    if #other > 0 then text = ListLines(head .. ":", other) .. "\n" .. text end
    return text
end

-- Into a hover in orange: a list a line each, unwrapped so the hover
-- widens to fit (wrapped in the narrow hover, "(6 for this craft)" broke
-- across lines; user, 2026-10-25); any other blocker wraps as before
function addon:AddShoppingBlocker(tooltip, line, plan)
    local text = addon:ShoppingBlocker(line, plan)
    if not text:find("\n") then
        tooltip:AddLine(text, 1, 0.6, 0.2, true)
        return
    end
    for part in text:gmatch("[^\n]+") do tooltip:AddLine(part, 1, 0.6, 0.2, false) end
end

-- Over the button when it gives a reason instead of the step: which entry
-- it's on, "Next: Munsell Ink x2". The button stays short ("In the
-- mailbox"); this says what it's about (user, 2026-10-24: the middle
-- ground over a grayed "Craft" with the reason elsewhere)
-- A step before the craft itself (materials to make, a mill) says what
-- it's for: "Craft 2" was Entropic Extract for Bouquet of Herbs, and
-- nothing said so (user, 2026-10-24)
function addon:QueueNextLine(row)
    local s = row and row.state
    if not s or not row.recipe or addon.QueueBusy() then return nil end
    local name = row.recipe.outputName or "?"
    if s.enabled then
        -- The craft itself too: "Craft 2" alone didn't say what (user,
        -- 2026-10-24: "i like the label above the button its missing here")
        if s.step and not s.final then return string.format("Next: %s, for %s", s.step, name) end
        return "Next: " .. name
    end
    return "Next: " .. name .. ((row.remaining or 0) > 1 and (" x" .. row.remaining) or "")
end

-- What the Craft next button says for the entry it's on: the step, or why
-- it can't ("Needs Alchemist's Lab Bench")
function addon:QueueButtonLabel(row, q)
    if addon.QueueBusy() then return "Crafting..." end
    local s = row and row.state
    if not s then return "Craft next" end
    if s.enabled then return s.label end
    local status = addon:QueueRowStatus(row, q)
    return (status:gsub("^%l", string.upper))
end

-- The entry Craft next would work on: the first one ready to craft (or
-- salvage) with the profession that's open, else the first that needs a
-- profession opened, else the first that's stuck (for its reason). A
-- stuck entry above those (Needs Anvil, Needs materials) beats opening
-- another profession: Blacksmithing open, Gloaming Alloy first, and the
-- button said Open Jewelcrafting (user, 2026-10-22: it should say why)
-- Stuck only on concentration: nothing to do about it but wait. Another
-- stuck entry you can fix now (the mailbox, a vendor) comes first: the
-- button said Light's Potential, Needs concentration, while Bouquet of
-- Herbs only needed its mail taken (user, 2026-10-24).
local function WaitsOnConcentration(s)
    for _, b in ipairs(s.blockers or {}) do
        if b:find("concentration") then return true end
    end
    return false
end

function addon:QueueNextRow(q)
    local open, stuck, station, waiting
    for _, row in ipairs(q.rows) do
        local s = row.state
        if s then
            if s.enabled and not s.open then return row end
            if s.enabled then
                open = open or row
            elseif WaitsOnConcentration(s) then
                waiting = waiting or row
            else
                if not open and not stuck then station = row end
                stuck = stuck or row
            end
        end
    end
    return station or open or stuck or waiting
end

-- Crafting in progress (a batch still casting)
local function Busy()
    if C_TradeSkillUI.IsRecipeRepeating and C_TradeSkillUI.IsRecipeRepeating() then return true end
    return UnitCastingInfo("player") ~= nil
end
addon.QueueBusy = Busy

-- One step of the queue: from a click or the key binding (the game only
-- crafts from one)
function addon:CraftNext()
    if Busy() then return end
    local q = addon:BuildQueue(addon.charKey)
    if #q.rows == 0 then
        addon:Notify("info", "Nothing in the queue.")
        return
    end
    -- Can't craft: chat and the Craft button say why, no sound (user,
    -- 2026-10-25)
    local row = addon:QueueNextRow(q)
    if not row then
        addon:Notify("info", "Nothing in the queue can be crafted yet.")
        return
    end
    if not row.state.enabled then
        addon:Notify("info", "%s: %s", row.recipe.outputName, row.state.blockers[1] or "can't craft yet")
        return
    end
    addon.PerformCraftState(row.state, row.recipe, UpdateSoon)
end

-- Panel by the profession window

local panel

local function PanelLine(i)
    local line = CreateFrame("Frame", nil, panel)
    line:SetHeight(LINE_HEIGHT)
    line:SetPoint("TOPLEFT", 10, -(30 + (i - 1) * LINE_HEIGHT))
    line:SetPoint("RIGHT", panel, "RIGHT", -10, 0)
    line.status = UI.Text(line, "small", "muted", "RIGHT")
    line.status:SetPoint("RIGHT")
    line.text = UI.Text(line, "small", "text")
    line.text:SetPoint("LEFT")
    line.text:SetPoint("RIGHT", line.status, "LEFT", -6, 0)
    return line
end

-- The buff line, or in its place a button for what to do first
-- (Prep.lua): a tool to swap, the crafting buff to turn on
local function SetPanelPrep(row)
    local action = row and addon:CraftPrep(row.state, row.recipe or {}, row.entry and row.entry.concentrate) or nil
    panel.prepAction = action
    local buff = not action and addon:QueueMissingBuff(row, true)
    -- The Next line goes above the tool button when both show (user,
    -- 2026-10-24: the Equip button hid it)
    local nextLine = not buff and addon:QueueNextLine(row)
    panel.buff:SetText(buff and (buff .. " isn't active") or nextLine or "")
    panel.buff:SetTextColor(addon:Color(buff and "warning" or "muted"))
    local y = 56 + (action and 26 or 0)
    panel.buff:ClearAllPoints()
    panel.buff:SetPoint("BOTTOMLEFT", 10, y)
    buff = buff or nextLine
    panel.prep:SetShown(action ~= nil)
    if action then addon:SetPrepLabel(panel.prep, action) end
    -- Its own height, from its fixed width: sized by two corners it was
    -- measured as one line and the second ran over the Craft button
    -- (2026-10-25)
    local textHeight = math.ceil(panel.buff:GetStringHeight())
    panel.buff:SetHeight(math.max(textHeight, 1))
    local buffHeight = buff and math.max(textHeight + 4, 16) or 0
    panel:SetHeight(30 + (panel.shownLines or 0) * LINE_HEIGHT + 64 + (action and 26 or 0) + buffHeight)
end
addon.UpdateQueuePanelPrep = function()
    if panel and panel:IsShown() and panel.row then SetPanelPrep(panel.row) end
end

local function KeyText()
    local key = GetBindingKey and GetBindingKey("GOLDSMITH_CRAFT_NEXT")
    return key and GetBindingText and GetBindingText(key) or key
end

-- Saved spot (dragged there), or under the profession window with the
-- right edges lined up
local function PlacePanel()
    panel:ClearAllPoints()
    local pos = GoldsmithDB.ui2.queuePanel
    if pos then
        panel:SetPoint("TOPLEFT", ProfessionsFrame, "TOPLEFT", pos.x, pos.y)
    else
        panel:SetPoint("TOPRIGHT", ProfessionsFrame, "BOTTOMRIGHT", 0, -4)
    end
end

local function PanelMenu()
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(panel, function(_, root)
        root:CreateTitle("Goldsmith queue")
        root:CreateButton("Open the Queue tab", function() addon:ShowTab("queue") end)
        root:CreateButton("Put it back under the profession window", function()
            GoldsmithDB.ui2.queuePanel = nil
            PlacePanel()
        end)
    end)
end

local function CreatePanel()
    if panel or not ProfessionsFrame then return end
    panel = CreateFrame("Frame", nil, ProfessionsFrame, "BackdropTemplate")
    -- Above the whole profession window when dragged over it
    UI.RaiseAbove(panel, ProfessionsFrame)
    panel:SetWidth(PANEL_WIDTH)
    UI.Style(panel, "panel", "borderGold")
    panel:EnableMouse(true)

    -- Drag it anywhere; it stays put relative to the profession window
    panel:SetMovable(true)
    panel:SetClampedToScreen(true)
    panel:RegisterForDrag("LeftButton")
    panel:SetScript("OnDragStart", function(self) self:StartMoving() end)
    panel:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        GoldsmithDB.ui2.queuePanel = { x = self:GetLeft() - ProfessionsFrame:GetLeft(),
                                       y = self:GetTop() - ProfessionsFrame:GetTop() }
        PlacePanel()
    end)
    panel:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" then PanelMenu() end
    end)
    PlacePanel()

    panel.title = UI.Text(panel, "label", "gold")
    panel.title:SetPoint("TOPLEFT", 10, -10)
    panel.title:SetText("GOLDSMITH QUEUE")
    panel.open = UI.IconButton(panel, 18, ">", "Open the Queue tab", function() addon:ShowTab("queue") end,
        { font = "small" })
    panel.open:SetPoint("TOPRIGHT", -6, -6)
    -- Left of the > button, which has the corner
    panel.move = UI.MoveIcon(panel, 28, 7)

    UI.SetTooltip(panel, function(tooltip)
        tooltip:AddLine("Goldsmith queue", 1, 1, 1)

        addon:Explain(tooltip, "Drag to move it. Right-click to put it back or open the Queue tab.", 0.6, 0.6, 0.6, true)
    end)

    panel.lines = {}
    for i = 1, PANEL_LINES do panel.lines[i] = PanelLine(i) end

    panel.button = UI.Button(panel, "Craft next", PANEL_WIDTH - 20, 28, function(_, mouseButton)
        if mouseButton == "RightButton" then addon:ShowTab("queue") else addon:CraftNext() end
    end)
    panel.button:SetPoint("BOTTOMLEFT", 10, 24)
    UI.Style(panel.button, "highlight", "borderGold")
    panel.button.label:SetTextColor(addon:Color("gold"))
    panel.button:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderGold")) end)
    -- The next craft's crafting buff when it's off (QueueMissingBuff)
    panel.buff = UI.Text(panel, "small", "warning", "CENTER")
    panel.buff:SetPoint("BOTTOMLEFT", 10, 56)
    panel.buff:SetWidth(PANEL_WIDTH - 20)
    panel.buff:SetJustifyV("BOTTOM")
    -- Two lines rather than cut off ("for Gloaming..."; user, 2026-10-24)
    panel.buff:SetWordWrap(true)
    panel.buff:SetMaxLines(2)
    panel.prep = UI.Button(panel, "", PANEL_WIDTH - 20, 22, function() addon:RunPrep(panel.prepAction) end)
    panel.prep:SetPoint("BOTTOMLEFT", 10, 56)
    panel.prep.label:SetTextColor(addon:Color("warning"))
    panel.prep:Hide()
    UI.SetTooltip(panel.prep, function(tooltip)
        local action = panel.prepAction
        if not action then return end
        tooltip:AddLine(action.label, 1, 1, 1)
        for _, line in ipairs(action.lines or {}) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
    end, "ANCHOR_RIGHT")
    panel.hint = UI.Text(panel, "small", "dim", "CENTER")
    panel.hint:SetPoint("BOTTOMLEFT", 10, 8)
    panel.hint:SetPoint("BOTTOMRIGHT", -10, 8)

    UI.SetTooltip(panel.button, function(tooltip)
        local row = panel.row
        tooltip:AddLine("Craft next", 1, 1, 1)
        addon:Explain(tooltip, "One step per click: mill, make materials, then the craft, down the queue.", 0.8, 0.8, 0.8, true)
        if row and row.state then
            tooltip:AddLine(" ")
            tooltip:AddLine(row.recipe.outputName, addon:Color("gold"))
            for i, step in ipairs(row.state.steps or {}) do
                local r, g, b = 0.6, 0.6, 0.6
                if i == 1 then r, g, b = addon:Color("gold") end
                tooltip:AddLine(string.format("    %d. %s", i, step), r, g, b)
            end
            for _, line in ipairs(row.state.notes) do tooltip:AddLine(line, 0.8, 0.8, 0.8, true) end
            for _, line in ipairs(row.state.blockers) do
                addon:AddShoppingBlocker(tooltip, line, row.plan)
            end
        end
        tooltip:AddLine(" ")
        tooltip:AddLine(KeyText() and ("Key: " .. KeyText()) or "Set a key: Options > Keybindings > Goldsmith.",
            0.6, 0.6, 0.6, true)
        addon:Explain(tooltip, "Right-click for the Queue tab.", 0.6, 0.6, 0.6)
    end, "ANCHOR_BOTTOM")
end

local syncedKey

local function UpdatePanel()
    if not (ProfessionsFrame and ProfessionsFrame:IsShown()) then return end
    CreatePanel()
    if not panel then return end
    -- Stock-ups are shopping, done at the AH: a queue of only those has
    -- nothing to craft, so no panel (user, 2026-10-23)
    local crafting = 0
    for _, e in ipairs(Queue(addon.charKey) or {}) do
        if not e.stockID then crafting = crafting + 1 end
    end
    if crafting == 0 then
        -- Multicraft can fill the last entry before the game's batch ends;
        -- it keeps crafting (materials were bought for the unlucky case),
        -- so the panel stays until it stops (user, 2026-10-20: Sienna Ink)
        if Busy() and panel:IsShown() then
            panel.row, panel.nearby = nil, nil
            for i, line in ipairs(panel.lines) do
                if i == 1 then
                    line.text:SetText("Queue done")
                    line.text:SetTextColor(addon:Color("gold"))
                    line.status:SetText("")
                    line:Show()
                else
                    line:Hide()
                end
            end
            panel.shownLines = 1
            panel.buff:SetText("")
            panel.prep:Hide()
            panel.prepAction = nil
            panel:SetHeight(30 + LINE_HEIGHT + 64)
            panel.button:SetLabel("Finishing the batch")
            panel.button:SetEnabled(false)
            panel.button:SetAlpha(0.5)
            panel.hint:SetText("made enough early; the rest are extra")
            return
        end
        panel:Hide()
        return
    end
    local q = addon:BuildQueue(addon.charKey)
    local row = addon:QueueNextRow(q)
    panel.row = row
    -- Blocked by "Needs Anvil nearby": checked every second (below)
    panel.nearby = row and row.state and row.state.nearby or nil

    -- Without stock-ups (the Queue tab and Buy next show those)
    local rows = {}
    for _, r in ipairs(q.rows) do
        if not r.entry.stockID then table.insert(rows, r) end
    end
    local shown = math.min(#rows, PANEL_LINES)
    for i, line in ipairs(panel.lines) do
        local r = rows[i]
        if r and i <= shown then
            line.text:SetText(string.format("%dx %s", r.remaining, addon:QueueRowName(r)))
            line.text:SetTextColor(addon:Color(r == row and "gold" or "text"))
            local status, color = addon:QueueRowStatus(r, q)
            -- The button below says it for the row it's on, and the long
            -- ones cut the name short (user, 2026-10-22)
            line.status:SetText(r == row and "" or status)
            line.status:SetTextColor(addon:Color(color))
            line:Show()
        else
            line:Hide()
        end
    end
    if #rows > PANEL_LINES then
        local last = panel.lines[PANEL_LINES]
        last.text:SetText(string.format("and %d more", #rows - PANEL_LINES + 1))
        last.text:SetTextColor(addon:Color("muted"))
        last.status:SetText("")
    end
    -- Room for the buff line when it shows; kept for the aura watch below
    panel.shownLines = shown
    SetPanelPrep(row)

    local busy = Busy()
    local state = row and row.state
    local enabled = not busy and state ~= nil and state.enabled == true
    panel.button:SetLabel(addon:QueueButtonLabel(row, q))
    panel.button:SetEnabled(enabled)
    panel.button:SetAlpha(enabled and 1 or 0.5)
    panel.hint:SetText(KeyText() and ("or press " .. KeyText()) or "set a key in Keybindings > Goldsmith")
    panel:Show()

    -- Show the next craft in the profession window, once per change (never
    -- mid-craft)
    if not busy and state and state.enabled and state.reagents and not state.open then
        local recipeID = state.recipeID or row.recipe.recipeID
        local parts = { recipeID, tostring(state.concentrate), state.crafts or 0 }
        for _, e in ipairs(state.reagents) do table.insert(parts, e.reagent.itemID .. "x" .. e.quantity) end
        local key = table.concat(parts, "|")
        if key ~= syncedKey then
            syncedKey = key
            addon.SyncProfessionWindow(recipeID, state)
        end
    end
end

-- Bags, professions, concentration and casting all change what Craft next
-- does; a short wait groups bursts of updates
local updatePending = false
UpdateSoon = function()
    if updatePending then return end
    updatePending = true
    C_Timer.After(0.3, function()
        updatePending = false
        UpdatePanel()
        if addon.window and addon.window:IsShown() and GoldsmithDB.ui2.tab == "queue" and addon.RefreshWindow then
            addon.RefreshWindow()
        end
    end)
end

local events = CreateFrame("Frame")
for _, event in ipairs({ "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "BAG_UPDATE_DELAYED", "CURRENCY_DISPLAY_UPDATE" }) do
    events:RegisterEvent(event)
end
for _, event in ipairs({ "UNIT_SPELLCAST_START", "UNIT_SPELLCAST_STOP", "UNIT_SPELLCAST_INTERRUPTED" }) do
    events:RegisterUnitEvent(event, "player")
end
events:SetScript("OnEvent", function(_, event)
    if event == "TRADE_SKILL_CLOSE" then syncedKey = nil end
    -- A cast starting only greys the button: nothing it plans has changed
    -- yet, and rebuilding the queue on every start and stop of a batch was
    -- twice the work (code review, 2026-10-14). The stop rebuilds it.
    if event == "UNIT_SPELLCAST_START" then
        if panel and panel:IsShown() then
            panel.button:SetEnabled(false)
            panel.button:SetAlpha(0.5)
        end
        return
    end
    UpdateSoon()
end)

-- Your buffs changed: just the buff line, not the whole queue (planning
-- on every aura change would be the frame drops again)
local auraWatch = CreateFrame("Frame")
auraWatch:RegisterUnitEvent("UNIT_AURA", "player")
auraWatch:SetScript("OnEvent", function()
    if not (panel and panel:IsShown() and panel.row) then return end
    SetPanelPrep(panel.row)
end)

-- Walking up to an anvil fires no event, so while the next craft needs one
-- nearby the panel is checked every second
C_Timer.NewTicker(1, function()
    -- Only once the station is there: planning every second dropped frames
    -- (Crafts.lua's StationsMet)
    local state = panel and panel.row and panel.row.state
    if panel and panel:IsShown() and panel.nearby and addon.StationsMet(state and state.nearbyRecipes) then
        UpdateSoon()
    end
end)

-- A queued order crafted in the game's order window leaves the queue: the
-- craft is sent with its order ID, and the result (or the order being
-- completed) takes it off
local craftingOrder
hooksecurefunc(C_TradeSkillUI, "CraftRecipe", function(_, _, _, _, orderID)
    craftingOrder = type(orderID) == "number" and orderID > 0 and orderID or nil
end)
local orderEvents = CreateFrame("Frame")
orderEvents:RegisterEvent("TRADE_SKILL_ITEM_CRAFTED_RESULT")
pcall(orderEvents.RegisterEvent, orderEvents, "CRAFTINGORDERS_FULFILL_ORDER_RESPONSE")
orderEvents:SetScript("OnEvent", function(_, event, result, orderID)
    if event == "TRADE_SKILL_ITEM_CRAFTED_RESULT" then
        if craftingOrder then
            RemoveOrder(craftingOrder, "crafted")
            craftingOrder = nil
        end
    elseif result == 0 and orderID then
        RemoveOrder(orderID, "done")
    end
end)

_G.Goldsmith = addon
