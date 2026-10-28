local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Overview tab
--
-- "How am I doing, and what should I do now?" Four numbers, a "Do this
-- next" list, a chart you can cycle through, and profit by profession.
-- The header's profession and date filters apply.
--
-- Two kinds of part, and each says which it is (user, 2026-10-15): Do
-- this next and the Concentration tile are for the character you're on;
-- profit, sales, stock, the charts and profit by profession are the whole
-- account. Do this next was every character's best, and a friend testing
-- it missed that a suggestion was for another character, and thought the
-- tile's 2000 concentration was all his to spend. Nobody logs out to chase
-- a suggestion: other characters get one line, most gold waiting first,
-- that opens the Characters tab (how the user plays: one character at a
-- time). The numbers come from Insights.lua and Data.lua.

local WIDTH = 860
local GAP = 12
local TILE_WIDTH = (WIDTH - 3 * GAP) / 4
local MIDDLE_TOP = -(76 + GAP)
-- Tall enough for four Do this next cards and the other characters line
local MIDDLE_HEIGHT = 432
local HALF_WIDTH = (WIDTH - GAP) / 2
local BOTTOM_TOP = MIDDLE_TOP - MIDDLE_HEIGHT - GAP
local BOTTOM_HEIGHT = 64
local ACTION_COUNT = 5
local CRAFTS_SHOWN = 3
local ACTION_ROW_GAP = 8
local CRAFTS_LISTED = 5
local OTHERS_HEIGHT = 30
local OTHERS_SHOWN = 2
-- The tile's profession icons: the value font draws icons about twice
-- this size (20 came out bigger than the numbers; user, 2026-10-15)
local CONC_ICON = 9
local PROFESSION_CELLS = 6
local PROFESSION_LEFT = 190

local CHARTS = {
    { key = "profit", title = "Profit by day" },
    { key = "gold", title = "Total gold" },
    { key = "perHour", title = "Gold per hour" },
}

local Money, Signed = function(c) return addon:FormatMoney(c) end, function(c) return addon:FormatSignedMoney(c) end

-- "2026-09-25" -> "Sep 25"
local function ShortDay(day)
    local y, m, d = day:match("(%d+)-(%d+)-(%d+)")
    return date("%b %d", time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))
end

-- "full in 40m", "full in 6h", "full in 2.4 days"
local function HoursText(minutes)
    if not minutes then return "full" end
    if minutes < 60 then return string.format("full in %dm", math.ceil(minutes)) end
    if minutes < 48 * 60 then return string.format("full in %dh", math.floor(minutes / 60 + 0.5)) end
    return string.format("full in %.1f days", minutes / 1440)
end

-- The character you're on
local function MyName()
    local c = GoldsmithDB.characters[addon.charKey]
    return (c and c.name) or UnitName("player") or "you"
end

-- Only the entries for the character you're on (their key is in `field`,
-- charKey unless said)
local function Mine(list, field)
    local mine = {}
    for _, entry in ipairs(list) do
        if entry[field or "charKey"] == addon.charKey then table.insert(mine, entry) end
    end
    return mine
end

-- "  queued" when it's already in that character's queue, as the
-- Characters tab's to-do says it (user, 2026-10-19)
local function Queued(charKey, recipe, tier, concentrate)
    local e = addon:FindQueueEntry(charKey or addon.charKey, recipe.recipeID, tier, concentrate == true)
    return e and addon:Colorize("  queued", "muted") or ""
end

-- Character name, only when it isn't you (you're the default)
local function OnWho(charKey)
    if not charKey or charKey == addon.charKey then return "" end
    local c = GoldsmithDB.characters[charKey]
    return " on " .. (c and c.name or charKey)
end

-- A name cut to `max` letters with "..." (nil stays nil)
local function ShortName(name, max)
    if name and #name > max then return name:sub(1, max - 3) .. "..." end
    return name
end

-- The tier goes before the name, so a long name cut short never hides it
local function ItemText(itemID, name, tier, tierCount)
    if not tier and itemID then tier, tierCount = addon:GetItemTier(itemID) end -- a refine's one quality
    local icon = tier and tierCount and (addon:TierIconText(tier, tierCount) .. " ") or ""
    return icon .. (name or (itemID and addon:KnownItemName(itemID)) or "?")
end

-- Tiles

local function FillProfitTile(tile, s)
    local note = s.margin and string.format("%.0f%% margin, all characters", s.margin)
        or (s.sales > 0 and "cost unknown" or "no sales yet")
    tile:Set("Profit on sales", Signed(s.profit), addon:MoneyColor(s.profit), note)
    tile.tooltip = function(tooltip)
        tooltip:AddLine("Profit on sales", 1, 1, 1)
        tooltip:AddLine("All your characters.", 0.6, 0.6, 0.6)
        tooltip:AddDoubleLine("Sales", Money(s.sales), 0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddDoubleLine("What the items sold cost you", "-" .. Money(s.soldCost), 0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddDoubleLine("AH deposits", "-" .. Money(s.deposits), 0.8, 0.8, 0.8, 1, 1, 1)
        if s.unknownSales > 0 then
            tooltip:AddLine(string.format("%d sale%s without cost data left out.", s.unknownSales,
                s.unknownSales == 1 and "" or "s"), 1, 0.6, 0.2, true)
        end
        if s.estimated then
            addon:Explain(tooltip, "Some older sales use today's cost estimate.", 0.6, 0.6, 0.6, true)
        end
    end
end

local function FillSalesTile(tile, s)
    tile:Set("Sales", Money(s.sales), "text", "after the AH cut, all characters")
    tile.tooltip = function(tooltip)
        tooltip:AddLine("Sales", 1, 1, 1)
        tooltip:AddLine("All your characters.", 0.6, 0.6, 0.6)
        tooltip:AddDoubleLine("Spent on materials", Money(s.spent), 0.8, 0.8, 0.8, 1, 1, 1)
        addon:Explain(tooltip, "Materials you still hold aren't a loss until they're used or sold.", 0.6, 0.6, 0.6, true)
    end
end

local function FillStockTile(tile, stock, prof)
    -- Say which profession is counted, so a filtered total isn't mistaken
    -- for everything
    local scope = prof == "All" and "All professions" or (addon:ProfessionIconText(prof) .. prof .. " only")
    local held = #stock.heldLong
    if held > 0 then
        tile:Set("Gold in stock", Money(stock.value), "text",
            string.format("%s, %d item%s held %d+ days", scope, held, held == 1 and "" or "s",
                addon:Setting("heldDays")), "warning")
    else
        tile:Set("Gold in stock", Money(stock.value), "text",
            #stock.items > 0 and (scope .. ", all characters")
                or next(GoldsmithDB.recipes) == nil and "open your professions to start tracking"
                or "nothing tracked in your bags yet")
    end
    tile.tooltip = function(tooltip)
        tooltip:AddLine("Gold in stock", 1, 1, 1)
        if prof ~= "All" then
            tooltip:AddLine("Only " .. prof .. " items. Pick All professions at the top to see everything.", 1, 0.82, 0, true)
        end
        addon:Explain(tooltip, "Valued at what it cost you, or the AH price when there's no cost.", 0.6, 0.6, 0.6, true)
        for i = 1, math.min(#stock.items, 8) do
            local item = stock.items[i]
            tooltip:AddDoubleLine(string.format("%s x%d", item.name, item.count), Money(item.value),
                0.9, 0.9, 0.9, 1, 1, 1)
        end
        if #stock.items > 8 then
            tooltip:AddLine(string.format("and %d more", #stock.items - 8), 0.6, 0.6, 0.6)
        end
        if held > 0 then
            tooltip:AddLine(" ")
            tooltip:AddLine(string.format("Held %d+ days", addon:Setting("heldDays")), 1, 0.6, 0.2)
            for i = 1, math.min(held, 6) do
                local item = stock.heldLong[i]
                local days = math.floor((time() - item.heldSince) / 86400)
                tooltip:AddDoubleLine(string.format("%s x%d", item.name, item.count),
                    string.format("%d days", days), 0.9, 0.9, 0.9, 1, 0.6, 0.2)
            end
        end
        addon:ClickHint(tooltip, "Click to see everything you hold.")
    end
end

-- The character you're on (each profession's own: they don't add up, so
-- two read "450 · 800"); every character is in the hover
local function FillConcentrationTile(tile, conc)
    -- Forever has no concentration: the last AH scan instead
    if addon.isForever then
        local last = addon:GetOwnScanTime()
        local mins = last and math.floor((time() - last) / 60)
        tile:Set("Last AH scan", last and (mins < 1 and "just now" or mins < 60 and (mins .. " min ago")
            or (math.floor(mins / 60) .. " h ago")) or "-",
            last and (mins < 60 and "text" or "muted") or "muted", last and "your own scan, this realm" or "open the AH to scan it")
        tile.tooltip = nil
        return
    end
    local label = "Concentration, " .. MyName()
    if #conc.rows == 0 then
        tile:Set(label, "-", "muted", "open each profession once to load it")
        tile.tooltip = nil
        return
    end
    local mine = Mine(conc.rows, "key")
    -- Crafts worth concentration that were held back (you hold some unsold):
    -- said here too, so "nothing" always comes with why (design review)
    local heldBack, gain, amounts = 0, 0, {}
    for _, row in ipairs(mine) do
        heldBack = heldBack + #(row.capped or {})
        gain = gain + (row.gain or 0)
        -- Each with its profession's icon, so two say which is which (user,
        -- 2026-10-15)
        local icon = addon:GetProfessionIcon(row.profession)
        table.insert(amounts, (icon and ("|T" .. icon .. ":" .. CONC_ICON .. ":" .. CONC_ICON .. "|t ") or "")
            .. (#mine == 1 and string.format("%d / %d", row.current, row.max) or tostring(math.floor(row.current))))
    end
    local note
    if #mine == 0 then
        note = "none on this character (hover for all)"
    elseif gain > 0 then
        note = "worth " .. Signed(gain) .. " extra right now"
    elseif heldBack > 0 then
        note = string.format("nothing planned: %d held back (hover)", heldBack)
    else
        note = "nothing worth it right now"
    end
    tile:Set(label, #mine > 0 and table.concat(amounts, "   ") or "-", #mine > 0 and "conc" or "muted", note)
    tile.tooltip = function(tooltip)
        -- A table: concentration, when it's full and what it's worth each in
        -- its own column (user, 2026-10-12: the right side was hard to read)
        local rows = {}
        for _, row in ipairs(conc.rows) do
            -- Out of 1000 goes without saying (user, 2026-10-10); a different
            -- maximum is still shown
            local amount = row.max == 1000 and tostring(math.floor(row.current))
                or string.format("%d / %d", row.current, row.max)
            local full = HoursText(row.minutesToFull):gsub("^full in ", "")
            table.insert(rows, { left = string.format("%s  %s%s", row.name, addon:ProfessionIconText(row.profession), row.profession),
                0.9, 0.9, 0.9, cells = { { amount, 0.91, 0.76, 0.35 }, { full, 0.8, 0.8, 0.8 } } })
            -- What it's best spent on, rather than a bare "worth" (user,
            -- 2026-10-10: not sold on the formatting)
            if row.gain > 0 then
                local first = row.plan and row.plan[1]
                local what = first and string.format("    %dx %s%s", first.crafts,
                    ItemText(first.row.itemID, first.recipe.outputName, first.row.tier, first.tierCount),
                    #row.plan > 1 and string.format(" +%d more", #row.plan - 1) or "") or "    best use"
                table.insert(rows, { left = what, 0.6, 0.6, 0.6, cells = { [3] = { Signed(row.gain), 0.37, 0.81, 0.48 } } })
            end
            for _, c in ipairs(row.capped or {}) do
                table.insert(rows, { left = "    held back: " .. ItemText(c.row.itemID, c.recipe.outputName, c.row.tier, c.tierCount),
                    0.6, 0.6, 0.6, cells = { [3] = { addon:FormatMoney(c.row.concentrationValue) .. " a point", 0.91, 0.76, 0.35 } } })
                -- Why, with Ctrl (user, 2026-10-12: the hover was long);
                -- without it Explain only notes something is left out
                if addon:ExplanationsShown() then
                    table.insert(rows, { line = "        " .. addon:HeldBackReason(c), 0.6, 0.6, 0.6, wrap = true })
                else
                    addon:Explain(tooltip, "")
                end
            end
        end
        UI.TooltipTable(tooltip, "Concentration, every character", { "Now", "Full in", "Extra" }, rows)
        -- With Ctrl: the tile's title already names the character (user)
        addon:Explain(tooltip, string.format("The tile shows %s only: concentration can only be spent on the character who has it.",
            MyName()), 0.6, 0.6, 0.6, true)
        addon:Explain(tooltip, "Extra = profit on top of crafting the same things without concentration.", 0.6, 0.6, 0.6, true)
        addon:Explain(tooltip, "Alts' concentration is worked out from when you last logged in on them.", 0.6, 0.6, 0.6, true)
    end
end

-- Do this next

local function ConcentrationAction(conc)
    local best
    for _, row in ipairs(conc.rows) do
        if row.gain > 0 and row.plan and row.plan[1] and (not best or row.gain > best.gain) then
            best = row
        end
    end
    if not best then return nil end
    local first = best.plan[1]
    local items, queue, seen = {}, {}, {}
    for _, p in ipairs(best.plan) do
        table.insert(items, { itemID = p.recipe.outputItemID, name = p.recipe.outputName,
            qty = math.floor(p.crafts * (p.row.outputPerCraft or 1)) })
        -- A split's other mix is its own queue entry with that mix set
        local id = tostring(p.recipe.recipeID) .. ":" .. tostring(p.row.tier)
        local mix = seen[id] and p.row.description or nil
        seen[id] = true
        table.insert(queue, { charKey = best.key, recipe = p.recipe, tier = p.row.tier, tierCount = p.tierCount,
            itemID = p.row.itemID, concentrate = true, crafts = p.crafts, mix = mix,
            prefMix = not mix and p.row.description or nil })
    end
    return {
        items = items,
        queue = queue,
        highlight = true,
        title = string.format("%sCraft %dx %s%s", addon:ProfessionIconText(best.profession),
            first.crafts, ItemText(first.row.itemID, ShortName(first.recipe.outputName, 34), first.row.tier, first.tierCount),
            Queued(best.key, first.recipe, first.row.tier, true)),
        detail = string.format("With %d concentration%s  ·  %s profit",
            math.floor(first.points + 0.5), OnWho(best.key), addon:Colorize(Signed(first.profit), "profit")),
        tooltip = function(tooltip)
            tooltip:AddLine(string.format("Best use of %s's %d concentration", best.name, best.current), 1, 1, 1)
            -- What to expect: what's left, and when it's full again (it comes
            -- back a point every 5.76 minutes, 250 a day)
            if best.used and best.max then
                local left = math.max(math.floor(best.current - best.used), 0)
                local hours = (best.max - left) * 5.76 / 60
                tooltip:AddLine(string.format("Leaves %d; full again in about %s", left,
                    hours >= 48 and string.format("%.1f days", hours / 24) or string.format("%.0f hours", math.max(hours, 1))),
                    0.6, 0.6, 0.6, true)
            end
            for _, p in ipairs(best.plan) do
                tooltip:AddDoubleLine(string.format("%dx %s", p.crafts,
                    ItemText(p.row.itemID, p.recipe.outputName, p.row.tier, p.tierCount)),
                    string.format("%d conc, %s", p.points, Signed(p.gain)), 0.9, 0.9, 0.9, 0.37, 0.81, 0.48)
                if p.row.description then
                    tooltip:AddLine("    " .. p.row.description, 0.6, 0.6, 0.6, true)
                end
            end
            addon:Explain(tooltip, "Extra = profit on top of crafting the same thing without concentration.", 0.6, 0.6, 0.6, true)
            addon:ClickHint(tooltip, "Click to plan it: materials and shopping list.")
        end,
        onClick = function()
            addon:OpenCraftPlan(first.recipe, first.row, best.key, nil, nil, first.crafts)
        end,
    }
end

-- Cooldown crafts ready now and worth making (GetCooldownCrafts): time
-- matters, since a cooldown not used is lost, so it goes near the top
local function CooldownAction(prof)
    local crafts = Mine(addon:GetCooldownCrafts(prof))
    if #crafts == 0 then return nil end
    local parts = {}
    for i = 1, math.min(#crafts, CRAFTS_SHOWN) do
        local c = crafts[i]
        local icon = prof == "All" and addon:ProfessionIconText(c.recipe.profession) or ""
        local who = OnWho(c.charKey)
        table.insert(parts, string.format("%s%dx %s   %s%s%s", icon, c.crafts,
            ItemText(c.itemID, ShortName(c.recipe.outputName, 26), c.row.tier, c.row.tierCount),
            addon:Colorize(Signed(c.profit * c.crafts * (c.outputPerCraft or 1)), "profit"),
            who ~= "" and ("  ·" .. who) or "", Queued(c.charKey, c.recipe, c.row.tier, false)))
    end
    local first = crafts[1]
    local items, queue = {}, {}
    for i = 1, math.min(#crafts, CRAFTS_SHOWN) do
        table.insert(items, { itemID = crafts[i].recipe.outputItemID, name = crafts[i].recipe.outputName,
            qty = math.floor(crafts[i].crafts * (crafts[i].outputPerCraft or 1)) })
    end
    for _, c in ipairs(crafts) do
        table.insert(queue, { charKey = c.charKey, recipe = c.recipe, tier = c.row.tier, tierCount = c.row.tierCount,
            itemID = c.itemID, concentrate = false, crafts = c.crafts })
    end
    return {
        items = items,
        queue = queue,
        title = addon:CooldownsLabel() .. " ready",
        detail = table.concat(parts, "\n"),
        tooltip = function(tooltip)
            tooltip:AddLine(addon:CooldownsLabel() .. " ready", 1, 1, 1)
            tooltip:AddLine("Crafts with a cooldown that can be made now and are worth it (the same rules as Best crafts). A cooldown not used is lost.",
                0.6, 0.6, 0.6, true)
            for _, c in ipairs(crafts) do
                tooltip:AddDoubleLine(string.format("%dx %s%s", c.crafts,
                    ItemText(c.itemID, c.recipe.outputName, c.row.tier, c.row.tierCount), OnWho(c.charKey)),
                    Signed(c.profit * c.crafts * (c.outputPerCraft or 1)), 0.9, 0.9, 0.9, 0.37, 0.81, 0.48)
            end
            tooltip:AddLine(" ")
            addon:ClickHint(tooltip, "Click to plan the first one. Your other characters' cooldowns are on the Characters tab.")
        end,
        onClick = function()
            addon:OpenCraftPlan(first.recipe, first.row, first.charKey, nil, nil, first.crafts)
        end,
    }
end

local function CraftsAction(crafts, prof)
    if #crafts == 0 then return nil end
    -- One craft per line; the row has room for CRAFTS_SHOWN, the hover lists
    -- them all with ROI and sales. Names are shortened so a line never wraps;
    -- who makes it goes last, when it isn't you.
    local parts = {}
    for i = 1, math.min(#crafts, CRAFTS_SHOWN) do
        local c = crafts[i]
        local icon = prof == "All" and addon:ProfessionIconText(c.recipe.profession) or ""
        local who = OnWho(c.charKey)
        table.insert(parts, string.format("%s%s   %s each%s%s", icon,
            ItemText(c.itemID, ShortName(c.recipe.outputName, 26), c.row.tier, c.row.tierCount),
            addon:Colorize(Signed(c.profit), "profit"), who ~= "" and ("  ·" .. who) or "",
            Queued(c.charKey, c.recipe, c.row.tier, false)))
    end
    local items = {}
    for i = 1, math.min(#crafts, CRAFTS_SHOWN) do
        table.insert(items, { itemID = crafts[i].recipe.outputItemID, name = crafts[i].recipe.outputName,
            qty = crafts[i].make })
    end
    local queue = {}
    for _, c in ipairs(crafts) do
        if c.make and c.make > 0 then
            table.insert(queue, { charKey = c.charKey, recipe = c.recipe, tier = c.row.tier, tierCount = c.row.tierCount,
                itemID = c.itemID, concentrate = false, items = c.make })
        end
    end
    return {
        items = items,
        queue = #queue > 0 and queue or nil,
        title = "Best crafts right now",
        detail = table.concat(parts, "\n"),
        tooltip = function(tooltip)
            tooltip:AddLine("Best crafts right now", 1, 1, 1)
            addon:Explain(tooltip, string.format("Current-expansion crafts with %d%%+ ROI (Settings) that sell at least once a day, with every cost known. A craft drops off once made and comes back when all have sold.",
                addon:Setting("minROI")), 0.6, 0.6, 0.6, true)
            for _, c in ipairs(crafts) do
                tooltip:AddLine(" ")
                tooltip:AddLine(ItemText(c.itemID, c.recipe.outputName, c.row.tier, c.row.tierCount)
                    .. OnWho(c.charKey), 1, 0.82, 0)
                tooltip:AddDoubleLine("Profit each", string.format("%s (%.0f%% ROI)", Signed(c.profit), c.margin or 0),
                    0.8, 0.8, 0.8, 0.37, 0.81, 0.48)
                -- What to expect before crafting: how many, the gold, and
                -- why that many (your batches' pace)
                if c.make and c.make > 0 then
                    tooltip:AddDoubleLine("Make", string.format("%d: about %s", c.make, Signed(c.profit * c.make)),
                        0.8, 0.8, 0.8, 0.37, 0.81, 0.48)
                    if c.makeReason then tooltip:AddLine("    " .. c.makeReason, 0.6, 0.6, 0.6, true) end
                end
                if c.demand then
                    local r, g, b = addon:Color(addon:DemandColor(c.demand, c.itemID))
                    tooltip:AddDoubleLine("Sold per day", addon:FormatDemand(c.demand), 0.8, 0.8, 0.8, r, g, b)
                end
                if c.row.saleRate then
                    local r, g, b = addon:Color(addon:SaleRateColor(c.row.saleRate))
                    tooltip:AddDoubleLine("Sale rate", addon:FormatSaleRate(c.row.saleRate) .. " of listings sell",
                        0.8, 0.8, 0.8, r, g, b)
                end
                if c.have > 0 then
                    tooltip:AddDoubleLine("You have", tostring(c.have), 0.8, 0.8, 0.8, 1, 1, 1)
                end
            end
            tooltip:AddLine(" ")
            addon:ClickHint(tooltip, "Click to see these in Crafts.")
        end,
        onClick = function()
            local keys = {}
            for _, c in ipairs(crafts) do keys[c.key] = true end
            addon:OpenCrafts({ keys = keys, label = "Best crafts right now" })
        end,
    }
end

-- Milling, prospecting and other salvage that's clearly worth it (see
-- GetBestSalvage in Milling.lua): profit per salvage, best ROI first
local function SalvageAction(prof)
    local rows = Mine(addon:GetBestSalvage(prof))
    if #rows == 0 then return nil end
    local parts = {}
    for i = 1, math.min(#rows, CRAFTS_SHOWN) do
        local r = rows[i]
        local icon = prof == "All" and addon:ProfessionIconText(r.recipe.profession) or ""
        local who = OnWho(r.charKey)
        table.insert(parts, string.format("%s%s   %s (%.0f%%)%s", icon, ShortName(r.recipe.outputName, 30),
            addon:Colorize(Signed(r.info.profit), "profit"), r.info.margin, who ~= "" and ("  ·" .. who) or ""))
    end
    local items = {}
    for i = 1, math.min(#rows, CRAFTS_SHOWN) do
        local s = rows[i].salvage
        if s and s.inputID then
            table.insert(items, { itemID = s.inputID, name = rows[i].recipe.outputName })
        end
    end
    return {
        items = items,
        title = "Worth salvaging",
        detail = table.concat(parts, "\n"),
        tooltip = function(tooltip)
            tooltip:AddLine("Worth salvaging", 1, 1, 1)
            addon:Explain(tooltip, "Milling, prospecting and crushing that pays: yields measured from 200+ of your own salvages, every output priced, 20%+ ROI (or your Worth crafting setting) and 1g+ profit per salvage, after the AH cut.",
                0.6, 0.6, 0.6, true)
            for _, r in ipairs(rows) do
                tooltip:AddDoubleLine(r.recipe.outputName .. OnWho(r.charKey),
                    string.format("%s (%.0f%% ROI)", Signed(r.info.profit), r.info.margin), 0.9, 0.9, 0.9, 0.37, 0.81, 0.48)
            end
            tooltip:AddLine(" ")
            addon:ClickHint(tooltip, "Click to see these in Crafts.")
        end,
        onClick = function()
            local keys = {}
            for _, r in ipairs(rows) do keys[r.key] = true end
            addon:OpenCrafts({ keys = keys, label = "Worth salvaging" })
        end,
    }
end

-- What you've held a while that today's AH price sells above break-even
-- (GetSellNow, Insights.lua): on every character, since that's where
-- stock sits; the hover says how long and at what
local function SellAction()
    local list = addon:GetSellNow()
    if #list == 0 then return nil end
    local parts = {}
    for i = 1, math.min(#list, 2) do
        table.insert(parts, string.format("%d %s %s", list[i].count, ItemText(list[i].itemID, list[i].name),
            addon:Colorize(Signed(list[i].gain), "profit")))
    end
    return {
        title = "Sell now: above break-even",
        detail = table.concat(parts, "   "),
        tooltip = function(tooltip)
            tooltip:AddLine("Sell now: above break-even", 1, 1, 1)
            addon:Explain(tooltip, "Things you've held a while that today's AH price sells for more than they cost you, after the 5% cut. Prices like this may not last.",
                0.6, 0.6, 0.6, true)
            for i = 1, math.min(#list, 8) do
                local s = list[i]
                tooltip:AddDoubleLine(string.format("%d %s", s.count, ItemText(s.itemID, s.name)),
                    string.format("%s (break-even %s) · %d days  %s", Money(s.price), Money(s.breakEven), s.days,
                        Signed(s.gain)), 0.9, 0.9, 0.9, 0.37, 0.81, 0.48)
            end
            addon:ClickHint(tooltip, "Click for the item's page: price history, where yours are, break-even.")
        end,
        onClick = function() addon:OpenItem(list[1].name, list[1].itemID) end,
    }
end

-- How far below usual counts as cheap is a setting (dealPercent)
local function DealsAction(prof)
    local deals, earliest, minDays = addon:GetDeals(prof)
    local cheap, all = {}, {}
    local threshold = -addon:Setting("dealPercent") / 100
    -- Not what you'd make for less than today's price (as on the Items list)
    for _, d in ipairs(deals) do
        if d.diff <= threshold then
            local make = addon:MakeUnitCost(d.itemID, d.name)
            if not (make and d.now and make < d.now) then table.insert(all, d) end
        end
    end
    -- Only what you use: a cheap material you never use is no deal, and
    -- what you buy isn't what you use (stock-ups would count; user,
    -- 2026-10-23). The Items list still has the rest. Everything while no
    -- use is recorded at all (a fresh install).
    local perWeek = {}
    for _, d in ipairs(all) do
        local _, _, rate = addon:GetRecentUse(d.itemID)
        if rate > 0 then
            perWeek[d] = rate
            table.insert(cheap, d)
        end
    end
    local buys = #cheap > 0
    if not buys then
        if addon:UsedAnythingLately() and #all > 0 then return nil end
        cheap = all
    end
    if #deals == 0 then
        return {
            title = "Cheap materials today",
            detail = string.format("Appear after %d days of price history, saved each time Auctionator updates. History started %s.",
                minDays, earliest and ShortDay(earliest) or "today"),
            muted = true,
        }
    end
    if #cheap == 0 then return nil end
    local parts = {}
    for i = 1, math.min(#cheap, 3) do
        -- With its quality icon: two qualities of one material read as the
        -- same item twice without it (Void-Tempered Hide, user 2026-10-15)
        table.insert(parts, string.format("%s %s", ItemText(cheap[i].itemID, cheap[i].name),
            addon:Colorize(string.format("%.0f%%", cheap[i].diff * 100), "profit")))
    end
    return {
        title = "Cheap materials today",
        detail = table.concat(parts, "   ") .. " vs usual",
        tooltip = function(tooltip)
            tooltip:AddLine("Cheap materials today", 1, 1, 1)
            addon:Explain(tooltip, string.format("%d%% or more below their usual price (Settings > Cheap materials)%s",
                addon:Setting("dealPercent"), buys and ", only ones your crafts used in the last 30 days" or ""), 0.6, 0.6, 0.6, true)
            for i = 1, math.min(#cheap, 8) do
                local d = cheap[i]
                local rate = perWeek[d] and ("  · you use " .. (addon:FormatBuyRate(perWeek[d]))) or ""
                tooltip:AddDoubleLine(ItemText(d.itemID, d.name), string.format("%.0f%%  %s (usually %s)%s", d.diff * 100, Money(d.now), Money(d.usual), rate),
                    0.9, 0.9, 0.9, 0.37, 0.81, 0.48)
            end
            addon:ClickHint(tooltip, "Click to see them on the Items tab: what you have, what they're used in, price history.")
        end,
        onClick = function() addon:OpenItems({ cheap = true }) end,
    }
end

-- "Not this": hide one of a card's suggestions for a day (SetSnoozed),
-- or bring hidden ones back. On the card, where the suggestion is (design
-- review, 2026-10-10).
local function NotThisMenu(owner, items)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Not this: hide it for a day")
        for _, item in ipairs(items or {}) do
            root:CreateButton(item.name, function() addon:SetSnoozed(item.itemID, item.name, true) end)
        end
        local hidden = addon:GetSnoozedItems()
        if #hidden > 0 then
            root:CreateDivider()
            root:CreateButton(string.format("Bring back hidden ones (%d)", #hidden), function() addon:ClearSnoozed() end)
        end
    end)
end

-- Right-click a suggestion: queue it without opening its plan (user,
-- 2026-10-19: "less clicks once i know i can trust goldsmith"), one line
-- per craft it suggests, or all of them
local function QueueMenu(owner, queue)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle("Add to the queue")
        for _, s in ipairs(queue) do
            local tier = s.tier and s.tierCount and (addon:TierIconText(s.tier, s.tierCount) .. " ") or ""
            local count = s.crafts and string.format("%d craft%s", s.crafts, s.crafts == 1 and "" or "s")
                or string.format("%d", s.items)
            local queued = addon:FindQueueEntry(s.charKey or addon.charKey, s.recipe.recipeID, s.tier,
                s.concentrate == true, nil, s.mix)
            root:CreateButton(string.format("%s %s%s%s%s%s", count, tier, s.recipe.outputName,
                s.mix and (", " .. addon:ShortMix(s.mix)) or "", OnWho(s.charKey),
                queued and " (queued: set it)" or ""), function()
                addon:QueueSuggestion(s.charKey, s.recipe, s.tier, s.concentrate, s.crafts, s.items, s.mix, s.prefMix)
            end)
        end
        if #queue > 1 then
            root:CreateDivider()
            root:CreateButton("All of these", function()
                for _, s in ipairs(queue) do
                    addon:QueueSuggestion(s.charKey, s.recipe, s.tier, s.concentrate, s.crafts, s.items, s.mix, s.prefMix)
                end
            end)
        end
    end)
end

local function CreateActionRow(parent, i)
    local row = CreateFrame("Frame", nil, parent, "BackdropTemplate")
    -- Height and position are set in FillActionRow / Refresh, to fit the text
    row:SetSize(HALF_WIDTH - 32, 72)
    row.number = UI.Text(row, "heading", "muted")
    row.number:SetPoint("TOPLEFT", 12, -12)
    row.number:SetText(tostring(i))
    row.title = UI.Text(row, "body")
    row.title:SetPoint("TOPLEFT", 34, -11)
    row.title:SetPoint("RIGHT", row, "RIGHT", -30, 0)
    -- Not this (cards with suggestions); above the row, so its click
    -- doesn't open the plan
    row.notThis = UI.IconButton(row, 20, "x", nil, function(self) NotThisMenu(self, row.action and row.action.items) end,
        { font = "small" })
    row.notThis:SetPoint("TOPRIGHT", -6, -6)
    row.notThis:SetFrameLevel(row:GetFrameLevel() + 5)
    UI.SetTooltip(row.notThis, function(tooltip)
        tooltip:AddLine("Not this", 1, 1, 1)
        tooltip:AddLine("Hide one of these suggestions for a day. It comes back after that if it's still a good bet.", 0.8, 0.8, 0.8, true)
    end, "ANCHOR_BOTTOM")
    row.detail = UI.Text(row, "small", "muted")
    row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -5)
    row.detail:SetPoint("RIGHT", row, "RIGHT", -10, 0)
    row.detail:SetWordWrap(true)
    row.detail:SetMaxLines(CRAFTS_SHOWN)
    row.detail:SetJustifyV("TOP")
    row:EnableMouse(true)
    UI.SetTooltip(row, function(tooltip)
        if row.action and row.action.tooltip then row.action.tooltip(tooltip) end
        if row.action and row.action.queue then addon:RightClickHint(tooltip, "Right-click to add to the queue") end
    end)
    -- Rows that lead somewhere get a gold border on hover
    row:HookScript("OnEnter", function(self)
        if self.action and self.action.onClick then self:SetBackdropBorderColor(addon:Color("gold")) end
    end)
    row:HookScript("OnLeave", function(self)
        if self.action and self.action.onClick then
            self:SetBackdropBorderColor(addon:Color(self.action.highlight and "borderGold" or "borderStrong"))
        end
    end)
    row:SetScript("OnMouseUp", function(self, button)
        if button == "LeftButton" and self.action and self.action.onClick then self.action.onClick() end
        if button == "RightButton" and self.action and self.action.queue then QueueMenu(self, self.action.queue) end
    end)
    return row
end

local function FillActionRow(row, action)
    row.action = action
    if action.highlight then
        UI.Style(row, "highlight", "borderGold")
        row.number:SetTextColor(addon:Color("gold"))
    else
        UI.Style(row, "panelRaised", action.onClick and "borderStrong" or nil)
        row.number:SetTextColor(addon:Color("muted"))
    end
    row.title:SetText(action.title)
    row.title:SetTextColor(addon:Color(action.muted and "muted" or "text"))
    row.notThis:SetShown(action.items ~= nil and #action.items > 0)
    row.detail:SetText(action.detail or "")
    -- Tall enough for the title and however many detail lines there are
    local textHeight = row.title:GetStringHeight() + 5 + row.detail:GetStringHeight()
    row:SetHeight(math.max(56, math.ceil(11 + textHeight + 12)))
    row:Show()
end

-- Gold goal (user, 2026-10-11: "that seems fun")
--
-- Gold to make, counted from when it's set, in total gold (all characters
-- and the warband bank, the same as the Total gold chart): beside that
-- chart's title, "42% of 5,000g" with a small bar, and a dashed line on the
-- chart at where you'll be once you're GOAL_LINE_FROM of the way. It was a
-- total to reach at first; the user typed 5,000g meaning gold to make, and
-- a total starts most of the way there (93% of 2.5M), so it counts from 0%
-- now (user, 2026-10-11). Saved as GoldsmithDB.goldGoal = { make (copper),
-- set (time), start (total gold then) }; the first version's goals (no
-- make) are dropped. No deadline for now (user).
local GOAL_LINE_FROM = 0.5
local GOAL_BAR_WIDTH = 60

-- "10000", "10,000g", "10k", "1.5m" -> copper; nil if it isn't a number
local function ParseGold(text)
    text = (text or ""):lower():gsub("[,%s]", ""):gsub("g$", "")
    local number, suffix = text:match("^(%d*%.?%d+)([km]?)$")
    number = tonumber(number)
    if not number then return nil end
    if suffix == "k" then number = number * 1000 elseif suffix == "m" then number = number * 1000000 end
    return math.floor(number * 10000 + 0.5)
end

local function CurrentGold()
    local history = addon:GetAccountGoldHistory(1)
    return history[1] and history[1].copper or 0
end

local function GoalBox(popup)
    return popup.GetEditBox and popup:GetEditBox() or popup.editBox
end

-- The goal, or nil (a first-version goal without `make` is dropped)
local function Goal()
    local goal = GoldsmithDB.goldGoal
    if goal and not goal.make then
        GoldsmithDB.goldGoal = nil
        return nil
    end
    return goal
end

-- Gold made toward it so far (can be below 0 after spending)
local function GoalMade(goal, now)
    return now - (goal.start or now)
end

-- "in 3 days", "in under a day": how long reaching it took (goal.reached
-- is saved the first time it's reached, user 2026-10-11)
local function GoalTookText(goal)
    local days = math.floor(((goal.reached or time()) - goal.set) / 86400)
    if days < 1 then return "in under a day" end
    return string.format("in %d day%s", days, days == 1 and "" or "s")
end

local function AcceptGoal(popup)
    local copper = ParseGold(GoalBox(popup):GetText())
    if not copper then
        addon:Notify("info", "Gold goal not changed: enter an amount like 5000 or 5k.")
        return
    end
    if copper <= 0 then
        GoldsmithDB.goldGoal = nil
    else
        GoldsmithDB.goldGoal = { make = copper, set = time(), start = CurrentGold() }
    end
    addon.RefreshWindow()
end

StaticPopupDialogs["GOLDSMITH_GOLD_GOAL"] = {
    text = "How much gold do you want to make?\nCounted from now, across all your characters and the warband bank\n(e.g. 5000 or 5k; 0 clears it)",
    button1 = OKAY or "OK",
    button2 = CANCEL or "Cancel",
    hasEditBox = true,
    OnShow = function(self)
        local box = GoalBox(self)
        local goal = Goal()
        box:SetText(goal and tostring(math.floor(goal.make / 10000)) or "")
        box:HighlightText()
        box:SetFocus()
    end,
    OnAccept = AcceptGoal,
    EditBoxOnEnterPressed = function(box)
        local popup = box:GetParent()
        AcceptGoal(popup)
        popup:Hide()
    end,
    EditBoxOnEscapePressed = function(box) box:GetParent():Hide() end,
    timeout = 0, whileDead = true, hideOnEscape = true, preferredIndex = 3,
}

-- The chart's goal line (the total you'll have), once you're close enough
-- for it to fit
local function GoalLineOpts(now)
    local goal = Goal()
    if not goal or GoalMade(goal, now) < goal.make * GOAL_LINE_FROM then return nil end
    return { goal = goal.start + goal.make, goalText = "goal +" .. Money(goal.make) }
end

local function CreateGoal(parent)
    local f = CreateFrame("Button", nil, parent)
    f:SetSize(GOAL_BAR_WIDTH, 18)
    f.track = f:CreateTexture(nil, "BACKGROUND")
    f.track:SetColorTexture(addon:Color("barEmpty"))
    f.track:SetSize(GOAL_BAR_WIDTH, 6)
    f.track:SetPoint("LEFT", 0, 0)
    f.fill = f:CreateTexture(nil, "ARTWORK")
    f.fill:SetHeight(6)
    f.fill:SetPoint("LEFT", f.track, "LEFT")
    f.text = UI.Text(f, "small", "muted")

    function f:Update(now)
        self.now = now
        local goal = Goal()
        self.text:ClearAllPoints()
        if not goal then
            self.track:Hide(); self.fill:Hide()
            self.text:SetPoint("LEFT", 0, 0)
            self.text:SetText("Set a goal")
            self.text:SetTextColor(addon:Color("muted"))
        else
            local made = GoalMade(goal, now)
            local share = math.max(math.min(made / goal.make, 1), 0)
            local reached = made >= goal.make or goal.reached ~= nil
            if made >= goal.make and not goal.reached then goal.reached = time() end
            if reached then share = 1 end
            self.track:Show()
            self.fill:SetColorTexture(addon:Color(reached and "profit" or "gold"))
            self.fill:SetWidth(math.max(GOAL_BAR_WIDTH * share, 1))
            self.fill:Show()
            self.text:SetPoint("LEFT", self.track, "RIGHT", 8, 0)
            self.text:SetText(reached and string.format("+%s reached %s", Money(goal.make), GoalTookText(goal))
                or string.format("%d%% of %s", math.floor(share * 100), Money(goal.make)))
            self.text:SetTextColor(addon:Color(reached and "profit" or "text"))
        end
        self:SetWidth((goal and (GOAL_BAR_WIDTH + 8) or 0) + self.text:GetStringWidth())
        self:Show()
    end

    UI.SetTooltip(f, function(tooltip)
        local goal = Goal()
        if not goal then
            tooltip:AddLine("Set a gold goal", 1, 1, 1)
            tooltip:AddLine("How much gold you want to make, counted from when you set it, across all your "
                .. "characters and the warband bank. The chart shows it as a line once you're halfway.",
                0.6, 0.6, 0.6, true)
            addon:ClickHint(tooltip, "Click to set one.")
            return
        end
        local now = f.now or 0
        local made = GoalMade(goal, now)
        tooltip:AddLine("Gold goal: make " .. Money(goal.make), 1, 1, 1)
        local r, g, b = addon:Color(addon:MoneyColor(made))
        tooltip:AddDoubleLine("Made since " .. date("%b %d", goal.set), Signed(made), 0.8, 0.8, 0.8, r, g, b)
        if goal.reached then
            tooltip:AddDoubleLine("Reached " .. date("%b %d", goal.reached), GoalTookText(goal),
                0.8, 0.8, 0.8, addon:Color("profit"))
        else
            tooltip:AddDoubleLine("To go", Money(goal.make - made), 0.8, 0.8, 0.8, 1, 1, 1)
        end
        tooltip:AddDoubleLine("Total gold then / now", Money(goal.start) .. " / " .. Money(now),
            0.8, 0.8, 0.8, 1, 1, 1)
        addon:Explain(tooltip, "Counts any change in your total gold: sales and orders, but also gold spent on materials or anything else.")
        tooltip:AddLine(" ")
        addon:ClickHint(tooltip, goal.reached and "Click to set the next one."
            or "Click to change it (starts counting again; 0 clears it).")
    end)
    f:SetScript("OnClick", function() StaticPopup_Show("GOLDSMITH_GOLD_GOAL") end)
    -- "Set a goal" turns gold under the mouse, like a link
    f:HookScript("OnEnter", function(self)
        if not Goal() then self.text:SetTextColor(addon:Color("gold")) end
    end)
    f:HookScript("OnLeave", function(self)
        if not Goal() then self.text:SetTextColor(addon:Color("muted")) end
    end)
    f:Hide()
    return f
end

-- Chart

local function ChartDays(range)
    return range == "30d" and 30 or 14
end

-- Returns points, subtitle, kind ("bar" or "line") and an empty message
-- (when there's nothing to draw)
local function ChartData(key, state)
    local days = ChartDays(state.range)
    if key == "profit" then
        local data = addon:GetDailyProfit(state.profession, days)
        local points, best, any = {}, nil, false
        for _, d in ipairs(data) do
            if d.profit ~= 0 or d.sales ~= 0 then any = true end
            if not best or d.profit > best.profit then best = d end
            table.insert(points, { value = d.profit, day = d.day, tooltip = function(tooltip)
                tooltip:AddLine(ShortDay(d.day), 1, 1, 1)
                tooltip:AddDoubleLine("Profit", Signed(d.profit), 0.8, 0.8, 0.8, 1, 1, 1)
                tooltip:AddDoubleLine("Sales", Money(d.sales), 0.8, 0.8, 0.8, 1, 1, 1)
            end })
        end
        local subtitle = string.format("last %d days", days)
        if best and best.profit > 0 then subtitle = subtitle .. ", best day " .. Signed(best.profit) end
        return points, subtitle, "bar", not any and "Profit by day shows here once you've sold something."
    elseif key == "gold" then
        local history = addon:GetAccountGoldHistory(days)
        local points, recorded = {}, 0
        for _, d in ipairs(history) do
            if d.copper > 0 then
                recorded = recorded + 1
                table.insert(points, { value = d.copper, day = d.day, tooltip = function(tooltip)
                    tooltip:AddLine(ShortDay(d.day), 1, 1, 1)
                    tooltip:AddDoubleLine("Total gold", Money(d.copper), 0.8, 0.8, 0.8, 1, 1, 1)
                    -- Where it is: the warband bank, then each character
                    -- (class color), most gold first
                    tooltip:AddLine(" ")
                    if d.warband > 0 then
                        tooltip:AddDoubleLine("Warband bank", Money(d.warband), 0.8, 0.8, 0.8, 1, 1, 1)
                    end
                    for _, ch in ipairs(d.characters) do
                        local c = GoldsmithDB.characters[ch.key]
                        local color = c and c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
                        local r, g, b = 0.8, 0.8, 0.8
                        if color then r, g, b = color.r, color.g, color.b end
                        tooltip:AddDoubleLine((c and c.name) or ch.key, Money(ch.copper), r, g, b, 1, 1, 1)
                    end
                end })
            end
        end
        local now = history[#history] and history[#history].copper or 0
        local subtitle = "all characters and warband bank, now " .. Money(now)
        return points, subtitle, "line",
            recorded < 2 and "Your total gold is saved each day you play. The line starts tomorrow."
    else
        local data = addon:GetRollingGoldPerHour(state.profession, days)
        local points, latest = {}, nil
        for _, d in ipairs(data) do
            if d.perHour then latest = d end
            table.insert(points, { value = d.perHour or 0, day = d.day, tooltip = function(tooltip)
                tooltip:AddLine(ShortDay(d.day) .. ", 7 days to then", 1, 1, 1)
                if d.perHour then
                    tooltip:AddDoubleLine("Gold per hour", Signed(d.perHour) .. "/h", 0.8, 0.8, 0.8, 1, 1, 1)
                end
                tooltip:AddDoubleLine("Profit", Signed(d.profit), 0.8, 0.8, 0.8, 1, 1, 1)
                tooltip:AddDoubleLine("Goldmaking time", string.format("%dh %02dm",
                    math.floor(d.seconds / 3600), math.floor(d.seconds % 3600 / 60)), 0.8, 0.8, 0.8, 1, 1, 1)
            end })
        end
        local subtitle = "per hour of goldmaking, 7-day average"
        if latest then subtitle = subtitle .. ", now " .. Signed(latest.perHour) .. "/h" end
        return points, subtitle, "bar", not latest
            and "Counts time with a profession, the AH, the mailbox, a vendor or the bank open. It fills in as you make gold."
    end
end

-- Profit by profession
--
-- Which professions make the most, to know where to put your time: a
-- ranked strip. Its bars (share of the best one) were dropped: they
-- needed explaining and only repeated the ranked numbers (user,
-- 2026-10-16). Was a row
-- of cards that filtered the window on click; the user never filtered
-- with them, only read the ranking, and they took a lot of room (user,
-- 2026-10-15). The header's profession menu still filters.

local function CreateProfessionCell(parent, i)
    local width = (WIDTH - PROFESSION_LEFT - 16 - (PROFESSION_CELLS - 1) * 10) / PROFESSION_CELLS
    local cell = CreateFrame("Frame", nil, parent)
    cell:SetSize(width, BOTTOM_HEIGHT - 20)
    cell:SetPoint("TOPLEFT", PROFESSION_LEFT + (i - 1) * (width + 10), -10)
    cell.name = UI.Text(cell, "small", "text")
    cell.name:SetPoint("TOPLEFT", 0, -4)
    cell.name:SetPoint("RIGHT", cell, "RIGHT", 0, 0)
    cell.name:SetWordWrap(false)
    cell.profit = UI.Text(cell, "body")
    cell.profit:SetPoint("TOPLEFT", cell.name, "BOTTOMLEFT", 0, -4)
    cell:EnableMouse(true)
    UI.SetTooltip(cell, function(tooltip)
        if not cell.item then return end
        tooltip:AddLine(addon:ProfessionIconText(cell.item.profession) .. cell.item.profession, 1, 1, 1)
        tooltip:AddLine("All your characters, in the dates picked at the top.", 0.6, 0.6, 0.6, true)
        tooltip:AddDoubleLine("Profit on sales", Signed(cell.item.profit), 0.8, 0.8, 0.8, 1, 1, 1)
        tooltip:AddDoubleLine("Sales", Money(cell.item.sales), 0.8, 0.8, 0.8, 1, 1, 1)
        if cell.share then
            tooltip:AddDoubleLine("Share of your profit", string.format("%.0f%%", cell.share * 100), 0.8, 0.8, 0.8, 1, 1, 1)
        end
    end)
    return cell
end

-- Getting started
--
-- Until Goldsmith has prices and recipes, "Do this next" is a checklist of
-- the steps that get it there, each ticked off from data Goldsmith already
-- collects. Once it has been shown it stays, all ticked, until it's closed,
-- so finishing the last step doesn't make it vanish mid-read. An account
-- that already has everything never sees it. /gsm setup brings it back.

-- Gathering professions have no recipes to load
local NO_RECIPES = { [182] = true, [393] = true }   -- Herbalism, Skinning
local READY_ICON = "Interface\\RaidFrame\\ReadyCheck-Ready"
local WAITING_ICON = "Interface\\RaidFrame\\ReadyCheck-Waiting"

local function HasAuctionator() return addon:HasAuctionator() end

-- This character's crafting professions, in the order the game lists them,
-- and which of them have recipes loaded
local function CraftingProfessions()
    local loaded = {}
    for recipeID in pairs(addon.char.knownRecipes) do
        local recipe = GoldsmithDB.recipes[recipeID]
        if recipe then loaded[recipe.profession] = true end
    end
    -- Only the two main professions: not cooking, fishing or archaeology.
    -- Either can be nil (not learned).
    local list = {}
    local first, second = GetProfessions()
    for _, index in pairs({ first, second }) do
        local name, _, _, _, _, _, skillLine = GetProfessionInfo(index)
        if name and not NO_RECIPES[skillLine] then
            table.insert(list, { name = name, loaded = loaded[name] })
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- { { done, title, detail } } for each step
local function SetupSteps()
    local steps = {}
    local hasTSM = addon:HasTSM()
    local hasAuctionator = HasAuctionator()

    -- Goldsmith Data first: the region's prices before any scan. Auctionator
    -- isn't recommended any more: Goldsmith scans the AH and Buy next does
    -- the shopping (user, 2026-10-26: "shouldn't encourage using it"). The
    -- old step "Recommended: Auctionator" also kept the checklist from ever
    -- finishing without it.
    -- Forever: no Goldsmith Data (retail prices), so no step for it
    if addon.isForever then
        -- prices come from the scan step below
    elseif addon:GetBlizzardDataTime() then
        table.insert(steps, { true, "Goldsmith Data found", "The region's AH prices, updated daily, from the start." })
    else
        table.insert(steps, { false, "Install Goldsmith Data",
            "CurseForge installs it with Goldsmith: the region's AH prices, updated daily, so prices show before your first scan." })
    end

    local professions = CraftingProfessions()
    local missing, done = {}, {}
    for _, p in ipairs(professions) do
        table.insert(p.loaded and done or missing, p.name)
    end
    if #professions == 0 then
        local any = next(GoldsmithDB.recipes) ~= nil
        table.insert(steps, { any, "Load your recipes", any and "Recipes loaded on another character."
            or "This character has no crafting profession. Log in on one that does and open its professions." })
    elseif #missing > 0 then
        table.insert(steps, { false, "Open " .. table.concat(missing, " and "),
            "Open each profession once (press K) so Goldsmith can load your recipes and crafting stats. Wait for the chat message." })
    else
        table.insert(steps, { true, "Recipes loaded",
            table.concat(done, " and ") .. ". Open the professions on your other crafters too." })
    end

    local scanned = hasAuctionator and GoldsmithDB.lastPriceUpdate
    local ownScan = addon:GetOwnScanTime()
    if ownScan or scanned or hasTSM or addon:GetBlizzardDataTime() then
        table.insert(steps, { true, "AH prices in",
            ownScan and "Goldsmith has scanned the AH. It scans again when you open the AH and the last scan is over an hour old."
            or scanned and "Auctionator has prices. Scan again whenever you're at the AH."
            or hasTSM and "Using TSM's prices."
            or "Using Goldsmith Data: the region's AH prices for materials, updated daily. Open the AH and Goldsmith scans everything else." })
    else
        table.insert(steps, { false, "Scan the auction house",
            "Open the AH: Goldsmith scans it by itself (or press Scan the AH on the Goldsmith panel beside it)." })
    end
    return steps
end

-- /gsm setup
function addon:ShowSetup()
    GoldsmithDB.setupDone = nil
    GoldsmithDB.setupShown = true
    addon:ShowTab("overview")
end

local function CreateSetup(panel)
    local setup = CreateFrame("Frame", nil, panel)
    setup:SetPoint("TOPLEFT", 0, -40)
    setup:SetPoint("BOTTOMRIGHT")
    setup.rows = {}
    local above
    for i = 1, 3 do
        local row = {}
        row.icon = setup:CreateTexture(nil, "ARTWORK")
        row.icon:SetSize(18, 18)
        row.title = UI.Text(setup, "body", "text")
        row.title:SetPoint("LEFT", row.icon, "RIGHT", 8, 0)
        row.title:SetPoint("RIGHT", -16, 0)
        row.detail = UI.Text(setup, "small", "muted")
        row.detail:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -4)
        row.detail:SetPoint("RIGHT", -16, 0)
        row.detail:SetWordWrap(true)
        if above then
            row.icon:SetPoint("TOPLEFT", above.detail, "BOTTOMLEFT", -26, -14)
        else
            row.icon:SetPoint("TOPLEFT", 16, -6)
        end
        setup.rows[i] = row
        above = row
    end

    setup.keyButton = UI.Button(setup, "Set key", 90, 22, function() addon:OpenKeybindings() end)
    setup.keyButton:SetPoint("BOTTOMRIGHT", -16, 14)
    setup.keyNote = UI.Text(setup, "small", "muted")
    setup.keyNote:SetPoint("LEFT", 16, 0)
    setup.tourButton = UI.Button(setup, "Take the tour", 110, 22, function() addon:StartTour() end)
    setup.tourButton:SetPoint("RIGHT", setup.keyButton, "LEFT", -8, 0)
    UI.SetTooltip(setup.tourButton, function(tooltip)
        tooltip:AddLine("Take the tour", 1, 1, 1)
        tooltip:AddLine("A short walk through the window: what each part is for. /gsm tour starts it too.", 0.8, 0.8, 0.8, true)
    end)
    setup.keyNote:SetPoint("RIGHT", setup.tourButton, "LEFT", -10, 0)
    setup.keyNote:SetPoint("BOTTOM", setup.keyButton, "BOTTOM", 0, 5)

    setup.close = UI.IconButton(panel, 22, "X", "Hide getting started (/gsm setup shows it again)", function()
        GoldsmithDB.setupDone = true
        addon.RefreshWindow()
    end, { font = "body" })
    setup.close:SetPoint("TOPRIGHT", -10, -10)
    return setup
end

-- Fills the checklist; returns true when every step is done
local function FillSetup(setup)
    local steps = SetupSteps()
    local allDone = true
    for i, row in ipairs(setup.rows) do
        -- Forever has one step fewer (no Goldsmith Data)
        for _, part in ipairs({ row.icon, row.title, row.detail }) do
            if steps[i] then part:Show() else part:Hide() end
        end
        local done, title, detail = unpack(steps[i] or { true, "", "" })
        allDone = allDone and done
        row.icon:SetTexture(done and READY_ICON or WAITING_ICON)
        row.title:SetText(title)
        row.title:SetTextColor(addon:Color(done and "muted" or "text"))
        row.detail:SetText(detail)
    end
    local key = addon:ToggleKeyText()
    setup.keyNote:SetText(key and ("Goldsmith opens with " .. key .. ".") or "Tip: open Goldsmith with a key.")
    setup.keyButton:SetLabel(key and "Change key" or "Set key")
    return allDone
end

-- View

local function Create(parent)
    local view = {}

    view.tiles = {}
    for i = 1, 4 do
        local tile = UI.StatTile(parent, i == 4 and "highlight" or "panel")
        tile:SetWidth(TILE_WIDTH)
        tile:SetPoint("TOPLEFT", (i - 1) * (TILE_WIDTH + GAP), 0)
        view.tiles[i] = tile
        -- Gold in stock opens what you hold on the Items tab
        if i == 3 then
            tile:SetScript("OnMouseUp", function(_, button)
                if button == "LeftButton" then addon:OpenItems({ inBags = true }) end
            end)
            tile:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(addon:Color("gold")) end)
            tile:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("border")) end)
        end
    end

    -- Do this next
    local actions = UI.Panel(parent)
    view.actionsPanel = actions
    actions:SetPoint("TOPLEFT", 0, MIDDLE_TOP)
    actions:SetSize(HALF_WIDTH, MIDDLE_HEIGHT)
    view.actionsTitle = UI.Text(actions, "heading")
    view.actionsTitle:SetPoint("TOPLEFT", 16, -16)
    -- How last week's suggestions turned out, beside the title:
    -- "followed: +320g" (FollowedLabel, also on the Characters tab)
    view.followed = addon:FollowedLabel(actions)
    view.followed:SetPoint("LEFT", view.actionsTitle, "RIGHT", 10, -1)
    -- "2 hidden": suggestions hidden with Not this, so they can always be
    -- brought back, even once their card is gone
    view.hidden = addon:HiddenSuggestionsButton(actions)
    view.hidden:SetPoint("TOPRIGHT", -12, -13)
    view.actionRows = {}
    for i = 1, ACTION_COUNT do
        view.actionRows[i] = CreateActionRow(actions, i)
    end
    view.actionsEmpty = UI.Text(actions, "body", "muted", "CENTER")
    view.actionsEmpty:SetPoint("CENTER", 0, 4)
    view.actionsEmpty:SetWidth(HALF_WIDTH - 60)
    view.actionsEmpty:SetWordWrap(true)

    -- Your other characters, most gold waiting first: the way to the
    -- Characters tab's to-do lists (was a "By character" button)
    local others = CreateFrame("Button", nil, actions, "BackdropTemplate")
    view.others = others
    others:SetPoint("BOTTOMLEFT", 16, 12)
    others:SetPoint("BOTTOMRIGHT", -16, 12)
    others:SetHeight(OTHERS_HEIGHT)
    others.text = UI.Text(others, "small", "text")
    others.text:SetPoint("LEFT", 12, 0)
    others.text:SetPoint("RIGHT", -12, 0)
    others.text:SetWordWrap(false)
    others:SetScript("OnClick", function() addon:ShowTab("characters") end)
    others:HookScript("OnEnter", function(self) self:SetBackdropBorderColor(addon:Color("gold")) end)
    others:HookScript("OnLeave", function(self) self:SetBackdropBorderColor(addon:Color("borderStrong")) end)
    UI.SetTooltip(others, function(tooltip)
        tooltip:AddLine("Your other characters", 1, 1, 1)
        tooltip:AddLine("What their to-do lists are worth, most first. Log in on one to do it there.", 0.6, 0.6, 0.6, true)
        for _, o in ipairs(others.list or {}) do
            tooltip:AddDoubleLine(o.name, string.format("%d to do  ·  %s", o.count, Signed(o.total)),
                0.9, 0.9, 0.9, 0.37, 0.81, 0.48)
        end
        addon:ClickHint(tooltip, "Click for every character's to-do list (Characters tab).")
    end, "ANCHOR_BOTTOM")
    view.setup = CreateSetup(actions)

    -- Chart
    local chartPanel = UI.Panel(parent)
    view.chartPanel = chartPanel
    chartPanel:SetPoint("TOPLEFT", HALF_WIDTH + GAP, MIDDLE_TOP)
    chartPanel:SetSize(HALF_WIDTH, MIDDLE_HEIGHT)
    view.chartTitle = UI.Text(chartPanel, "heading")
    view.chartTitle:SetPoint("TOPLEFT", 16, -16)
    view.chartSubtitle = UI.Text(chartPanel, "label", "dim")
    view.chartSubtitle:SetPoint("TOPLEFT", view.chartTitle, "BOTTOMLEFT", 0, -5)

    local function CycleChart(step)
        local ui = GoldsmithDB.ui2
        ui.chart = ((ui.chart or 1) - 1 + step) % #CHARTS + 1
        addon.RefreshWindow()
    end
    local nextButton = UI.IconButton(chartPanel, 26, ">", "Next chart", function() CycleChart(1) end)
    nextButton:SetPoint("TOPRIGHT", -10, -10)
    local prevButton = UI.IconButton(chartPanel, 26, "<", "Previous chart", function() CycleChart(-1) end)
    prevButton:SetPoint("RIGHT", nextButton, "LEFT", -2, 0)
    view.chartPage = UI.Text(chartPanel, "label", "dim", "RIGHT")
    view.chartPage:SetPoint("RIGHT", prevButton, "LEFT", -4, 0)
    view.goal = CreateGoal(chartPanel)
    view.goal:SetPoint("LEFT", view.chartTitle, "RIGHT", 14, 0)

    local chartArea = CreateFrame("Frame", nil, chartPanel)
    chartArea:SetPoint("TOPLEFT", 16, -62)
    chartArea:SetPoint("BOTTOMRIGHT", -16, 30)
    view.barChart = UI.BarChart(chartArea)
    view.barChart:SetAllPoints()
    view.lineChart = UI.LineChart(chartArea)
    view.lineChart:SetAllPoints()
    view.chartEmpty = UI.Text(chartArea, "small", "muted", "CENTER")
    view.chartEmpty:SetPoint("CENTER")
    view.chartEmpty:SetWidth(HALF_WIDTH - 80)
    view.chartEmpty:SetWordWrap(true)
    view.chartStart = UI.Text(chartPanel, "label", "dim")
    view.chartStart:SetPoint("TOPLEFT", chartArea, "BOTTOMLEFT", 0, -6)
    view.chartEnd = UI.Text(chartPanel, "label", "dim", "RIGHT")
    view.chartEnd:SetPoint("TOPRIGHT", chartArea, "BOTTOMRIGHT", 0, -6)

    -- By profession
    local professions = UI.Panel(parent)
    view.professionsPanel = professions
    professions:SetPoint("TOPLEFT", 0, BOTTOM_TOP)
    professions:SetSize(WIDTH, BOTTOM_HEIGHT)
    local professionsTitle = UI.Text(professions, "heading")
    professionsTitle:SetPoint("TOPLEFT", 16, -14)
    professionsTitle:SetText("Profit by profession")
    view.professionsNote = UI.Text(professions, "label", "dim")
    view.professionsNote:SetPoint("TOPLEFT", professionsTitle, "BOTTOMLEFT", 0, -5)
    view.professionsEmpty = UI.Text(professions, "small", "muted")
    view.professionsEmpty:SetPoint("LEFT", PROFESSION_LEFT, 0)
    view.professionsEmpty:SetText("Shows here once you've sold something.")
    view.cells = {}
    for i = 1, PROFESSION_CELLS do
        view.cells[i] = CreateProfessionCell(professions, i)
    end

    return view
end

-- Runs as work spread over frames (Window.lua): each part is filled in as
-- soon as its numbers are worked out, and shows "Loading" until then if
-- that takes more than a frame
local function Refresh(view, state)
    local prof, range = state.profession, state.range
    local loading = state.loading
    for _, tile in ipairs(view.tiles) do loading:Begin(tile) end
    loading:Begin(view.actionsPanel)
    loading:Begin(view.chartPanel)
    loading:Begin(view.professionsPanel)

    local summary = addon:GetSummary(prof, range)
    FillProfitTile(view.tiles[1], summary)
    FillSalesTile(view.tiles[2], summary)
    loading:Done(view.tiles[1])
    loading:Done(view.tiles[2])
    local stock = addon:GetStockValue(prof)
    FillStockTile(view.tiles[3], stock, prof)
    loading:Done(view.tiles[3])
    local conc = addon:GetConcentrationOverview(prof)
    FillConcentrationTile(view.tiles[4], conc)
    loading:Done(view.tiles[4])

    -- Getting started, until it's closed
    local inSetup, allDone = false, false
    if not GoldsmithDB.setupDone then
        allDone = FillSetup(view.setup)
        if allDone and not GoldsmithDB.setupShown then
            GoldsmithDB.setupDone = true
        else
            inSetup = true
            GoldsmithDB.setupShown = true
        end
    end
    view.setup:SetShown(inSetup)
    view.setup.close:SetShown(inSetup)
    view.hidden:Update(inSetup)
    view.actionsTitle:SetText(not inSetup and ("Do this next on " .. MyName())
        or allDone and "Getting started: all done, close this with X" or "Getting started")

    -- Do this next, for the character you're on
    local list = {}
    local concAction = ConcentrationAction({ rows = Mine(conc.rows, "key") })
    if concAction then table.insert(list, concAction) end
    local cooldownAction = CooldownAction(prof)
    if cooldownAction then table.insert(list, cooldownAction) end
    local best = Mine(addon:GetBestCrafts(prof, math.huge))
    for i = #best, CRAFTS_LISTED + 1, -1 do best[i] = nil end
    local craftsAction = CraftsAction(best, prof)
    if craftsAction then table.insert(list, craftsAction) end
    -- Note what's suggested, so a craft of it soon after counts as followed
    if not inSetup then
        local items = {}
        for _, action in ipairs({ concAction, cooldownAction, craftsAction }) do
            for _, item in ipairs(action and action.items or {}) do table.insert(items, item) end
        end
        addon:MarkSuggested(items)
    end
    view.followed:Update(inSetup)
    -- Order: concentration, cooldowns, best crafts, sell now, salvage,
    -- cheap materials; the last ones are left out when they don't fit.
    -- Sell now before salvage: a price over break-even may not last a day
    -- (Light's Potential, user 2026-10-27)
    local sellAction = SellAction()
    if sellAction then table.insert(list, sellAction) end
    local salvageAction = SalvageAction(prof)
    if salvageAction then table.insert(list, salvageAction) end
    local dealsAction = DealsAction(prof)
    if dealsAction then table.insert(list, dealsAction) end
    -- A card that wouldn't fit in the panel is left out rather than spill
    -- over the other characters line
    local top = -44
    for i, row in ipairs(view.actionRows) do
        local shown = false
        if list[i] and not inSetup then
            FillActionRow(row, list[i])
            if top - row:GetHeight() >= -(MIDDLE_HEIGHT - 12 - OTHERS_HEIGHT - ACTION_ROW_GAP) then
                row:SetPoint("TOPLEFT", 16, top)
                top = top - row:GetHeight() - ACTION_ROW_GAP
                shown = true
            end
        end
        row:SetShown(shown)
    end

    -- Your other characters, most gold waiting first
    local others = {}
    if not inSetup then
        for key, t in pairs(addon:GetCharacterTodo(prof, conc)) do
            local c = GoldsmithDB.characters[key]
            if key ~= addon.charKey and c and t.total > 0 then
                local color = c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
                table.insert(others, { name = c.name or key, total = t.total, count = #t.items,
                    colored = color and ("|c" .. color.colorStr .. (c.name or key) .. "|r") or (c.name or key) })
            end
        end
        table.sort(others, function(a, b) return a.total > b.total end)
    end
    view.others.list = others
    if #others > 0 then
        local parts = {}
        for i = 1, math.min(#others, OTHERS_SHOWN) do
            table.insert(parts, string.format("%s %s", others[i].colored, addon:Colorize(Signed(others[i].total), "profit")))
        end
        view.others.text:SetText("Other characters:  " .. table.concat(parts, "   ·   ")
            .. (#others > OTHERS_SHOWN and string.format("   +%d more", #others - OTHERS_SHOWN) or "") .. "   >")
    else
        view.others.text:SetText(addon:Colorize("Nothing waiting on your other characters.", "muted") .. "   >")
    end
    UI.Style(view.others, "panelRaised", "borderStrong")
    view.others:SetShown(not inSetup)

    if #list == 0 and not inSetup then
        view.actionsEmpty:SetText(next(GoldsmithDB.recipes) == nil
            and "Nothing to do yet. Open your professions to load recipes."
            or #others > 0 and string.format("Nothing worth doing on %s right now. %s has the most waiting.", MyName(), others[1].colored)
            or string.format("Nothing worth doing on %s right now.", MyName()))
    end
    view.actionsEmpty:SetShown(#list == 0 and not inSetup)
    loading:Done(view.actionsPanel)

    -- Chart
    local index = GoldsmithDB.ui2.chart or 1
    if not CHARTS[index] then index = 1 end
    local chart = CHARTS[index]
    local points, subtitle, kind, empty = ChartData(chart.key, state)
    -- Always "Total gold": "Gold goal" is the bar beside it (user, 2026-10-13)
    view.chartTitle:SetText(chart.title)
    view.chartSubtitle:SetText(subtitle or "")
    view.chartPage:SetFormattedText("%d / %d", index, #CHARTS)
    view.barChart:SetShown(kind == "bar" and not empty)
    view.lineChart:SetShown(kind == "line" and not empty)
    -- The gold goal: beside the Total gold title, and a line on its chart
    local goalOpts
    if chart.key == "gold" then
        local last = points[#points]
        local now = last and last.value or 0
        view.goal:Update(now)
        goalOpts = GoalLineOpts(now)
    else
        view.goal:Hide()
    end
    if not empty then
        (kind == "bar" and view.barChart or view.lineChart):SetData(points, goalOpts)
    end
    view.chartEmpty:SetShown(empty and true or false)
    view.chartEmpty:SetText(empty or "")
    local first, last = points[1], points[#points]
    view.chartStart:SetText((not empty and first) and ShortDay(first.day) or "")
    view.chartEnd:SetText((not empty and last) and ShortDay(last.day) or "")
    loading:Done(view.chartPanel)

    -- Profit by profession: only ones with sales, best first (whatever the
    -- header's profession: it's the ranking that matters here)
    local ranked = {}
    for _, item in ipairs(addon:GetProfessionBreakdown(range)) do
        if item.sales ~= 0 or item.profit ~= 0 then table.insert(ranked, item) end
    end
    local totalProfit = 0
    for _, item in ipairs(ranked) do
        if item.profit > 0 then totalProfit = totalProfit + item.profit end
    end
    view.professionsNote:SetText(addon:GetDateRange(range).label .. ", all characters")
    for i, cell in ipairs(view.cells) do
        local item = ranked[i]
        cell.item = item
        if item then
            cell.name:SetText(addon:ProfessionIconText(item.profession) .. item.profession)
            cell.profit:SetText(Signed(item.profit))
            cell.profit:SetTextColor(addon:Color(addon:MoneyColor(item.profit)))
            cell.share = totalProfit > 0 and item.profit > 0 and item.profit / totalProfit or nil
            cell:Show()
        else
            cell:Hide()
        end
    end
    view.professionsEmpty:SetShown(#ranked == 0)
    loading:Done(view.professionsPanel)
end

-- What clicks do, for the window's click legend
local function Legend()
    return {
        { "click", "a suggestion: its plan" },
        { "right", "a suggestion: queue it" },
        { "click", "other characters: their to-do lists" },
        { "hover", ": details" },
        { "ctrl", "in a hover: explain" },
    }
end

addon:RegisterView("overview", { create = Create, refresh = Refresh, legend = Legend, ownLoading = true })

_G.Goldsmith = addon
