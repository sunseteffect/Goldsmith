local addon = _G.Goldsmith or {}
local UI = addon.UI

-- Stats tab
--
-- Lifetime stats, for fun and for comparing with friends (user,
-- 2026-10-17): a title earned by lifetime profit, four big numbers, then
-- sections of label and number rows in two columns that scroll. Always
-- every profession, character and date: the header's filters don't apply
-- here. Share in chat puts a one-line brag in the chat box to send. The
-- numbers come from addon:GetLifetimeStats (Lifetime.lua).

local GAP = 12
local SCROLL_BAR = 8
local ROW_HEIGHT = 20
local SECTION_TOP = 34
local SECTION_PAD = 10
local TILE_HEIGHT = 76

local Money = function(c) return addon:FormatMoney(c or 0) end
local Signed = function(c) return addon:FormatSignedMoney(c or 0) end

local function Count(n)
    local s = tostring(math.floor((n or 0) + 0.5))
    local result = s:reverse():gsub("(%d%d%d)", "%1,"):reverse()
    return (result:gsub("^,", ""):gsub("^%-,", "-"))
end

local function Percent(p) return p and string.format("%.0f%%", p) or "-" end

local function DateText(t) return t and date("%b %d, %Y", t) or "" end

-- "2026-10-17" -> "Oct 17, 2026"
local function DayText(day)
    local y, m, d = (day or ""):match("(%d+)-(%d+)-(%d+)")
    if not y then return day or "" end
    return date("%b %d, %Y", time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }))
end

-- "2026-10" -> "October 2026"
local function MonthText(month)
    local y, m = (month or ""):match("(%d+)-(%d+)")
    if not y then return month or "" end
    return date("%B %Y", time({ year = tonumber(y), month = tonumber(m), day = 15, hour = 12 }))
end

local function HoursText(seconds)
    local hours = (seconds or 0) / 3600
    if hours < 1 then return string.format("%d min", math.floor((seconds or 0) / 60)) end
    return string.format("%s h", Count(hours))
end

local function ClassName(name, class)
    local color = class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[class]
    if color and color.colorStr then return "|c" .. color.colorStr .. name .. "|r" end
    return name
end

local function CharName(key)
    if not key then return "" end
    local c = GoldsmithDB.characters and GoldsmithDB.characters[key]
    local name = key:match("^([^-]+)") or key
    if not c then
        -- Sales keep only the name
        for k, other in pairs(GoldsmithDB.characters or {}) do
            if (k:match("^([^-]+)")) == key then c = other break end
        end
    end
    return ClassName(name, c and c.class)
end

local function ItemName(name, itemID)
    if itemID then
        local tier, tierCount = addon:GetItemTier(itemID)
        if tier then return addon:TierIconText(tier, tierCount) .. " " .. (name or "?") end
    end
    return name or "?"
end

local function White(tooltip, text) tooltip:AddLine(text, 1, 1, 1) end
local function Grey(tooltip, text) tooltip:AddLine(text, 0.8, 0.8, 0.8, true) end
local function Pair(tooltip, left, right)
    tooltip:AddDoubleLine(left, right, 0.8, 0.8, 0.8, 1, 1, 1)
end

-- A sale record's hover (best, worst, biggest)
local function SaleTooltip(title, r, goldLabel)
    return function(tooltip)
        White(tooltip, title)
        if not r then return end
        Pair(tooltip, "Item", ItemName(r.item, r.itemID) .. (r.qty and r.qty > 1 and (" x" .. r.qty) or ""))
        if r.gold then Pair(tooltip, goldLabel or "Sold for", Money(r.gold)) end
        if r.profit then Pair(tooltip, "Profit", Signed(r.profit)) end
        if r.char then Pair(tooltip, "By", CharName(r.char)) end
        if r.time then Pair(tooltip, "When", DateText(r.time)) end
    end
end

-- Sections
--
-- Each returns its rows: { label, value, color (theme), tooltip =
-- function(tooltip) }, or { divider = true }.

local function MoneyRows(s)
    local a = s.agg
    return {
        { "Lifetime profit", Signed(s.profit), addon:MoneyColor(s.profit), tooltip = function(t)
            White(t, "Lifetime profit")
            Pair(t, "From sales", Signed(s.salesProfit))
            Pair(t, "From players' crafting orders", Signed(s.orderProfit))
            Grey(t, "Sales: what you sold for after the AH cut, less what the items cost you and AH deposits. A sale at a loss takes it down.")
            Grey(t, "Orders: the commission, plus materials you kept, less your own materials.")
            addon:Explain(t, "Patron orders aren't in it: they're often taken at a loss on purpose, for knowledge. They're under Orders and gathering. Sales with no cost known aren't in it either.")
        end },
        { "From sales", Signed(s.salesProfit), addon:MoneyColor(s.salesProfit) },
        { "From players' orders", Signed(s.orderProfit), addon:MoneyColor(s.orderProfit) },
        { "Sales after the AH cut", Money(a.revenue), "text" },
        { "What the sold items cost you", Money(a.cost), "text" },
        { "Return on what they cost (ROI)", Percent(s.roi), s.roi and (s.roi >= 0 and "profit" or "loss") or "muted",
          tooltip = function(t)
            White(t, "ROI")
            Grey(t, "Profit as a share of what the items you sold cost you. 100% means you doubled your gold.")
        end },
        { "Average profit a sale", s.perSale and Signed(s.perSale) or "-", s.perSale and addon:MoneyColor(s.perSale) or "muted" },
        { "Profit a day", s.perDay and Signed(s.perDay) or "-", s.perDay and addon:MoneyColor(s.perDay) or "muted",
          tooltip = function(t)
            White(t, "Profit a day")
            Grey(t, string.format("Lifetime profit over the %d days since Goldsmith's first record.", s.daysTracked))
        end },
        { "Gold an hour", s.perHour and Signed(s.perHour) or "-", s.perHour and addon:MoneyColor(s.perHour) or "muted",
          tooltip = function(t)
            White(t, "Gold an hour")
            Grey(t, "Lifetime profit over the time you spent at the AH, the mailbox and professions: " .. HoursText(s.seconds) .. ".")
        end },
        { "Paid to the AH goblins", Money(a.ahCut), "warning", tooltip = function(t)
            White(t, "Paid to the AH goblins")
            Grey(t, "The AH's 5% cut of everything you sold.")
        end },
        { "Deposits lost", Money(s.depositsLost), s.depositsLost > 0 and "loss" or "text", tooltip = function(t)
            White(t, "Deposits lost")
            Grey(t, "AH deposits on auctions that expired or were cancelled. Deposits on ones that sold came back.")
        end },
        { "Spent on materials", Money(a.spent), "text", tooltip = function(t)
            White(t, "Spent on materials")
            Pair(t, "Purchases", Count(a.purchases))
            Pair(t, "Items bought", Count(a.bought))
            if a.bigPurchase then
                Pair(t, "Biggest", ItemName(a.bigPurchase.item, a.bigPurchase.itemID) .. "  " .. Money(a.bigPurchase.gold))
            end
        end },
        { "Biggest purchase", a.bigPurchase and Money(a.bigPurchase.gold) or "-", "text",
          tooltip = SaleTooltip("Biggest purchase", a.bigPurchase, "Paid") },
    }
end

local function AuctionRows(s)
    local a = s.agg
    local rows = {
        { "Auctions sold", Count(a.sales), "text" },
        { "Items sold", Count(a.units), "text" },
        { "Different items sold", Count(s.uniqueSold), "text" },
        { "Auctions posted", Count(a.posts), "text", tooltip = function(t)
            White(t, "Auctions posted")
            Pair(t, "Items posted", Count(a.posted))
        end },
        { "Sold through", Percent(s.sellThrough), "text", tooltip = function(t)
            White(t, "Sold through")
            Grey(t, "Items sold as a share of items posted. Reposts count again, so it's lower than how much of your stock sells.")
        end },
        { "Sales that made a profit", Percent(s.winRate), "text" },
        { "Best sale", a.best and Signed(a.best.profit) or "-", "profit", tooltip = SaleTooltip("Best sale (most profit)", a.best) },
        { "Biggest sale", a.biggest and Money(a.biggest.gold) or "-", "gold", tooltip = SaleTooltip("Biggest sale (most gold)", a.biggest) },
        { "Priciest item sold", a.priciest and Money(a.priciest.each) or "-", "gold",
          tooltip = SaleTooltip("Priciest item sold (gold each)", a.priciest) },
        { "Worst flop", a.worst and a.worst.profit < 0 and Signed(a.worst.profit) or "none yet",
          a.worst and a.worst.profit < 0 and "loss" or "muted", tooltip = SaleTooltip("Worst flop (biggest loss)", a.worst) },
        { "Biggest mailbox haul", s.haul and Money(s.haul.gold) or "-", "gold", tooltip = function(t)
            White(t, "Biggest mailbox haul")
            Grey(t, "The most gold collected from sold auctions in one trip to the mailbox.")
            if s.haul then
                Pair(t, "Auctions", Count(s.haul.count))
                Pair(t, "By", CharName(s.haul.char))
                Pair(t, "When", DateText(s.haul.time))
            end
        end },
    }
    if s.mostSold then
        table.insert(rows, { "Most sold", s.mostSold.name, "text", tooltip = function(t)
            White(t, s.mostSold.name)
            Pair(t, "Items sold", Count(s.mostSold.units))
            Pair(t, "Profit", Signed(s.mostSold.profit))
        end })
    end
    if s.topEarner and s.topEarner.profit > 0 then
        table.insert(rows, { "Top earner", s.topEarner.name, "profit", tooltip = function(t)
            White(t, "Your most profitable items")
            for i, item in ipairs(s.topItems) do
                if item.profit > 0 then Pair(t, i .. ". " .. item.name, Signed(item.profit)) end
            end
        end })
    end
    return rows
end

local function RecordRows(s)
    local rows = {
        { "Tracking since", s.first and DateText(s.first) or "-", "text", tooltip = function(t)
            White(t, "Tracking since")
            Grey(t, string.format("Goldsmith's first record: %d days ago.", s.daysTracked))
        end },
        { "Best day", s.bestDay and s.bestDay.profit > 0 and Signed(s.bestDay.profit) or "-", "profit", tooltip = function(t)
            White(t, "Best day")
            if s.bestDay then Grey(t, DayText(s.bestDay.from)) end
        end },
        { "Best week", s.bestWeek and s.bestWeek.profit > 0 and Signed(s.bestWeek.profit) or "-", "profit", tooltip = function(t)
            White(t, "Best week")
            Grey(t, "The most profit in 7 days in a row.")
            if s.bestWeek then Grey(t, DayText(s.bestWeek.from) .. " to " .. DayText(s.bestWeek.to)) end
        end },
        { "Best month", s.bestMonth and s.bestMonth.profit > 0 and Signed(s.bestMonth.profit) or "-", "profit", tooltip = function(t)
            White(t, "Best month")
            if s.bestMonth then Grey(t, MonthText(s.bestMonth.from)) end
        end },
        { "Profitable days", string.format("%s of %s", Count(s.goodDays), Count(s.activeDays)), "text", tooltip = function(t)
            White(t, "Profitable days")
            Grey(t, "Days you sold or posted something that ended in profit.")
        end },
        { "Longest profit streak", string.format("%d day%s", s.longestStreak, s.longestStreak == 1 and "" or "s"), "gold",
          tooltip = function(t)
            White(t, "Longest profit streak")
            Grey(t, "Profitable days in a row, by the calendar.")
        end },
        { "Current streak", string.format("%d day%s", s.currentStreak, s.currentStreak == 1 and "" or "s"),
          s.currentStreak > 0 and "profit" or "muted", tooltip = function(t)
            White(t, "Current streak")
            Grey(t, "Profitable days in a row up to today. A day without a sale yet doesn't break it until it's over.")
        end },
        { "Time making gold", HoursText(s.seconds), "text", tooltip = function(t)
            White(t, "Time making gold")
            Grey(t, "Time at the AH, the mailbox and your professions, on every character.")
        end },
    }
    if s.peakGold then
        table.insert(rows, { "Richest you've been", Money(s.peakGold.copper), "gold", tooltip = function(t)
            White(t, "Richest you've been")
            Grey(t, "Gold on all your characters and the warband bank together, at its highest.")
            Grey(t, DayText(s.peakGold.day))
        end })
    end
    if s.richest then
        table.insert(rows, { "Richest character", CharName(s.richest.key), "text", tooltip = function(t)
            White(t, "Richest character")
            Pair(t, CharName(s.richest.key), Money(s.richest.money))
        end })
    end
    return rows
end

local function CraftRows(s)
    local c = s.craftTally
    local rows = {
        { "Crafts", Count(s.crafts), "text" },
        { "Items crafted", Count(s.made), "text" },
        { "Different recipes crafted", Count(s.recipesCrafted), "text" },
        { "Multicraft procs", Count(s.mcProcs), "text" },
        { "Free items from multicraft", Count(s.extraItems), "profit", tooltip = function(t)
            White(t, "Free items from multicraft")
            Grey(t, "Items crafted beyond what the recipes make, from multicraft procs and finishing reagents like Bazaar Bites.")
        end },
    }
    if c.bestMc then
        local name = c.bestMc.itemID and C_Item.GetItemNameByID(c.bestMc.itemID)
        table.insert(rows, { "Biggest multicraft", "+" .. Count(c.bestMc.extra), "gold", tooltip = function(t)
            White(t, "Biggest multicraft")
            if name then Pair(t, "Item", ItemName(name, c.bestMc.itemID)) end
            Pair(t, "Made", Count(c.bestMc.qty) .. " in one craft")
            if c.bestMc.char then Pair(t, "By", CharName(c.bestMc.char)) end
            if c.bestMc.time then Pair(t, "When", DateText(c.bestMc.time)) end
        end })
    end
    local since = c.since and ("Counted since " .. DateText(c.since) .. ".") or "Counted from your next craft."
    table.insert(rows, { "Resourcefulness procs", Count(c.resProcs), "text", tooltip = function(t)
        White(t, "Resourcefulness procs")
        Grey(t, "Crafts that gave materials back. " .. since)
    end })
    table.insert(rows, { "Ingenuity procs", Count(c.ingenuity), "conc", tooltip = function(t)
        White(t, "Ingenuity procs")
        Grey(t, "Crafts that gave concentration back. " .. since)
    end })
    table.insert(rows, { "Concentration spent", Count(c.conc), "conc", tooltip = function(t)
        White(t, "Concentration spent")
        Grey(t, since)
    end })
    table.insert(rows, { "First crafts", Count(c.firsts), "text", tooltip = function(t)
        White(t, "First crafts")
        Grey(t, "Recipes crafted for the first time, for their bonus knowledge. " .. since)
    end })
    if s.mostCrafted and s.mostCrafted.crafts > 0 then
        table.insert(rows, { "Most crafted", s.mostCrafted.name or "?", "text", tooltip = function(t)
            White(t, s.mostCrafted.name or "Most crafted")
            Pair(t, "Crafts", Count(s.mostCrafted.crafts))
            Pair(t, "Items made", Count(s.mostCrafted.made))
        end })
    end
    if s.busiestProfession then
        table.insert(rows, { "Busiest profession",
            addon:ProfessionIconText(s.busiestProfession.name) .. s.busiestProfession.name, "text", tooltip = function(t)
            White(t, "Busiest profession")
            Pair(t, "Crafts", Count(s.busiestProfession.crafts))
        end })
    end
    return rows
end

-- A leaderboard: the first few by profit, the rest in the hover
local function Ranked(list, nameOf, max, extra)
    local rows = {}
    local medals = { "|cffe8c25a1.|r", "|cffc0c4cc2.|r", "|cffb08d573.|r" }
    for i = 1, math.min(#list, max) do
        local p = list[i]
        table.insert(rows, { (medals[i] or (i .. ".")) .. " " .. nameOf(p), Signed(p.profit), addon:MoneyColor(p.profit),
            tooltip = function(t)
                t:AddLine(nameOf(p), 1, 1, 1)
                Pair(t, "Profit", Signed(p.profit))
                if p.orders then Pair(t, "  from players' orders", Signed(p.orders)) end
                Pair(t, "Auctions sold", Count(p.sales))
                Pair(t, "Sales after the AH cut", Money(p.revenue))
                if extra then extra(t, p) end
            end })
    end
    if #list == 0 then table.insert(rows, { "Nothing sold yet", "", "muted" }) end
    return rows
end

local function ProfessionRows(s)
    return Ranked(s.professions, function(p) return addon:ProfessionIconText(p.name) .. p.name end, 6, function(t, p)
        Pair(t, "ROI", Percent(p.roi))
        if p.crafts then Pair(t, "Crafts", Count(p.crafts)) end
    end)
end

local function CharacterRows(s)
    return Ranked(s.characters, function(p) return CharName(p.key) end, 6, function(t, p)
        if p.money then Pair(t, "Gold now", Money(p.money)) end
    end)
end

local function OrderRows(s)
    local o = s.orders
    local since = o.since and ("Counted since " .. DateText(o.since) .. ".") or "Counted from your next order."
    local rows = {}
    for _, kind in ipairs({ { o.player, "Players' orders", "in your lifetime profit" },
                            { o.patron, "Patron orders", "not in your lifetime profit: often taken for knowledge" } }) do
        local g, title, note = kind[1], kind[2], kind[3]
        table.insert(rows, { title .. " filled", Count(g.count), "text", tooltip = function(t)
            White(t, title)
            Pair(t, "Filled", Count(g.count))
            Pair(t, "Commissions", Money(g.commission))
            Pair(t, "Profit", Signed(g.profit))
            Grey(t, "Profit is the commission, plus materials you kept and rewards' worth, less your own materials; " .. note .. ".")
            if g.bestTip then
                Pair(t, "Biggest tip", ItemName(g.bestTip.item, g.bestTip.itemID) .. "  " .. Money(g.bestTip.gold))
            end
            Grey(t, since)
        end })
        table.insert(rows, { "  Profit", Signed(g.profit), addon:MoneyColor(g.profit or 0) })
    end
    local best = o.player.bestTip
    if o.patron.bestTip and (not best or o.patron.bestTip.gold > best.gold) then best = o.patron.bestTip end
    if best then
        table.insert(rows, { "Biggest tip", Money(best.gold), "gold", tooltip = SaleTooltip("Biggest tip", best, "Commission") })
    end
    table.insert(rows, { divider = true })
    table.insert(rows, { "Materials gathered", Count(s.gathered), "text", tooltip = function(t)
        White(t, "Materials gathered")
        Pair(t, "Worth", Money(s.gatheredWorth))
        if s.topMaterial then Pair(t, "Most valuable", s.topMaterial.name .. "  " .. Money(s.topMaterial.value)) end
    end })
    table.insert(rows, { "Worth when gathered", Money(s.gatheredWorth), "gold" })
    table.insert(rows, { "Boxes opened", Count(s.boxesOpened), "text" })
    table.insert(rows, { "Milling and salvage runs", Count(s.salvageRuns), "text" })
    return rows
end

-- How well Goldsmith's suggestions did
local MIN_CHECKED = 5
local function PickRows(s)
    local f = s.followed
    -- By gold, not by item: one small miss counted like a big win made it
    -- 44% while the gold was 59% (user: "its bad", 2026-10-27)
    local accuracy = f.checked >= MIN_CHECKED and f.expectedTotal > 0
        and (f.made / f.expectedTotal * 100) or nil
    return {
        { "Of expected profit", accuracy and Percent(accuracy) or "not enough yet",
          accuracy and (accuracy >= 100 and "profit" or accuracy >= 80 and "text" or "warning") or "muted",
          tooltip = function(t)
            White(t, "Of expected profit")
            Grey(t, "Of the suggestions you crafted that have sold: the profit they made, against what Goldsmith expected.")
            Pair(t, "Made", Signed(f.made))
            Pair(t, "Expected", Signed(f.expectedTotal))
            Pair(t, "Items on target", string.format("%d of %d", f.heldUp, f.checked))
            Grey(t, "On target: made at least 80% of what was expected.")
            if not accuracy then Grey(t, string.format("Shows once %d of them have sold.", MIN_CHECKED)) end
            addon:Explain(t, "From the crafts Goldsmith still keeps: the last 30 of each item.")
        end },
        { "Suggested items crafted", Count(f.crafted), "text" },
        { "Of those, sold", Count(f.sold), "text" },
        { "Profit from suggestions", Signed(f.profit), addon:MoneyColor(f.profit) },
    }
end

-- Midnight crafting that Forever doesn't have: crafting stats,
-- concentration, crafting orders, crafted boxes and milling (stress test,
-- 2026-10-21). Gathering stays. Rows by their label.
local FOREVER_HIDDEN = {
    ["Multicraft procs"] = true, ["Free items from multicraft"] = true, ["Biggest multicraft"] = true,
    ["Resourcefulness procs"] = true, ["Ingenuity procs"] = true, ["Concentration spent"] = true,
    ["First crafts"] = true, ["Players' orders filled"] = true, ["Patron orders filled"] = true,
    ["Biggest tip"] = true, ["Boxes opened"] = true, ["Milling and salvage runs"] = true,
}
local function ForeverRows(rows)
    if not addon.isForever then return rows end
    local kept, skipProfit = {}, false
    for _, row in ipairs(rows) do
        local label = row[1]
        -- An order kind's "  Profit" line goes with it
        if label and (FOREVER_HIDDEN[label] or (skipProfit and label == "  Profit")) then
            skipProfit = FOREVER_HIDDEN[label] and label:find("orders filled") and true or false
        else
            skipProfit = false
            table.insert(kept, row)
        end
    end
    -- A divider left at the top or bottom
    while kept[1] and kept[1].divider do table.remove(kept, 1) end
    while kept[#kept] and kept[#kept].divider do table.remove(kept) end
    return kept
end

local LEFT = {
    { key = "money", title = "Gold", rows = MoneyRows },
    { key = "auctions", title = "Auctions", rows = AuctionRows },
    { key = "records", title = "Records", rows = RecordRows },
}
local RIGHT = {
    { key = "professions", title = "Professions by profit", rows = ProfessionRows },
    { key = "characters", title = "Characters by profit", rows = CharacterRows },
    { key = "crafting", title = "Crafting", rows = CraftRows },
    { key = "picks", title = "Goldsmith's picks", rows = PickRows },
    { key = "orders", title = "Orders and gathering", foreverTitle = "Gathering", rows = OrderRows },
}

-- Building blocks

local function CreateRow(section)
    local row = CreateFrame("Frame", nil, section)
    row:SetHeight(ROW_HEIGHT)
    row:SetPoint("LEFT", SECTION_PAD, 0)
    row:SetPoint("RIGHT", -SECTION_PAD, 0)
    row.hover = row:CreateTexture(nil, "BACKGROUND")
    row.hover:SetAllPoints()
    row.hover:SetColorTexture(addon:Color("hover"))
    row.hover:Hide()
    row.label = UI.Text(row, "body", "muted")
    row.label:SetPoint("LEFT", 4, 0)
    row.value = UI.Text(row, "body", "text", "RIGHT")
    row.value:SetPoint("RIGHT", -4, 0)
    row.label:SetPoint("RIGHT", row.value, "LEFT", -8, 0)
    row.line = UI.Line(row, "border")
    row.line:SetPoint("LEFT", 4, 0)
    row.line:SetPoint("RIGHT", -4, 0)
    row.line:SetHeight(1)
    row:EnableMouse(true)
    row:SetScript("OnEnter", function(self) if self.tooltip then self.hover:Show() end end)
    row:SetScript("OnLeave", function(self) self.hover:Hide() end)
    UI.SetTooltip(row, function(tooltip) if row.tooltip then row.tooltip(tooltip) end end)
    return row
end

local function CreateSection(parent, def)
    local section = UI.Panel(parent)
    section.def = def
    section.title = UI.Text(section, "heading")
    section.title:SetPoint("TOPLEFT", SECTION_PAD + 4, -12)
    section.title:SetText(addon.isForever and def.foreverTitle or def.title)
    section.rows = {}
    return section
end

local function FillSection(section, rows)
    local y = -SECTION_TOP
    for i, data in ipairs(rows) do
        local row = section.rows[i] or CreateRow(section)
        section.rows[i] = row
        row:ClearAllPoints()
        row:SetPoint("TOPLEFT", SECTION_PAD, y)
        row:SetPoint("TOPRIGHT", -SECTION_PAD, y)
        if data.divider then
            row:SetHeight(9)
            row.label:SetText("")
            row.value:SetText("")
            row.line:Show()
            row.tooltip = nil
            y = y - 9
        else
            row:SetHeight(ROW_HEIGHT)
            row.line:Hide()
            row.label:SetText(data[1])
            row.value:SetText(data[2] or "")
            row.value:SetTextColor(addon:Color(data[3] or "text"))
            row.tooltip = data.tooltip
            y = y - ROW_HEIGHT
        end
        row:Show()
    end
    for i = #rows + 1, #section.rows do section.rows[i]:Hide() end
    section:SetHeight(-y + SECTION_PAD)
end

-- "[Goldsmith] Master · +123,456g lifetime profit · ..." for the chat box
local function BragText(s)
    local parts = { string.format("[Goldsmith] %s Goldsmith", s.title),
        Signed(s.profit) .. " lifetime profit",
        Count(s.agg.sales) .. " auctions sold" }
    if s.roi then table.insert(parts, "ROI " .. Percent(s.roi)) end
    if s.agg.best then table.insert(parts, "best sale " .. Signed(s.agg.best.profit) .. " (" .. (s.agg.best.item or "?") .. ")") end
    if s.longestStreak > 1 then table.insert(parts, s.longestStreak .. "-day profit streak") end
    local text = table.concat(parts, " · ")
    -- Chat lines stop at 255 characters
    while #text > 250 and #parts > 3 do
        table.remove(parts)
        text = table.concat(parts, " · ")
    end
    return text
end

local function OpenChat(text)
    if ChatFrame_OpenChat then
        ChatFrame_OpenChat(text)
    elseif ChatFrameUtil and ChatFrameUtil.OpenChat then
        ChatFrameUtil.OpenChat(text)
    end
end

-- View

local function Create(parent)
    local view = {}

    local scroll = CreateFrame("ScrollFrame", nil, parent)
    scroll:SetPoint("TOPLEFT")
    scroll:SetPoint("BOTTOMRIGHT", -(SCROLL_BAR + 6), 0)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(1, 1)
    scroll:SetScrollChild(content)
    view.scroll, view.content = scroll, content
    local bar = CreateFrame("Slider", nil, parent, "BackdropTemplate")
    bar:SetOrientation("VERTICAL")
    bar:SetWidth(SCROLL_BAR)
    bar:SetPoint("TOPLEFT", scroll, "TOPRIGHT", 6, 0)
    bar:SetPoint("BOTTOMLEFT", scroll, "BOTTOMRIGHT", 6, 0)
    UI.Style(bar, "panelRaised")
    local thumb = bar:CreateTexture(nil, "OVERLAY")
    thumb:SetColorTexture(addon:Color("borderStrong"))
    thumb:SetSize(SCROLL_BAR, 40)
    bar:SetThumbTexture(thumb)
    bar:SetMinMaxValues(0, 0)
    bar:SetValue(0)
    bar:SetScript("OnValueChanged", function(_, value) scroll:SetVerticalScroll(value) end)
    view.bar = bar
    local function Wheel(_, delta)
        local low, high = bar:GetMinMaxValues()
        bar:SetValue(math.max(low, math.min(high, bar:GetValue() - delta * 60)))
    end
    for _, f in ipairs({ scroll, bar }) do
        f:EnableMouseWheel(true)
        f:SetScript("OnMouseWheel", Wheel)
    end

    local title = UI.Text(content, "heading")
    title:SetPoint("TOPLEFT", 0, -4)
    title:SetText("Lifetime stats")
    view.note = UI.Text(content, "label", "dim")
    view.note:SetPoint("LEFT", title, "RIGHT", 10, -1)

    view.share = UI.Button(content, "Share in chat", 120, 24, function()
        if view.stats then OpenChat(BragText(view.stats)) end
    end)
    view.share:SetPoint("TOPRIGHT", 0, 0)
    UI.SetTooltip(view.share, function(tooltip)
        tooltip:AddLine("Share in chat", 1, 1, 1)
        tooltip:AddLine("Puts a line with your title and best numbers in the chat box, to send to friends or your guild.", 0.8, 0.8, 0.8, true)
        if view.stats then
            local r, g, b = addon:Color("gold")
            tooltip:AddLine(BragText(view.stats), r, g, b, true)
        end
        addon:ClickHint(tooltip, "Click to write it in chat (Enter sends it)")
    end, "ANCHOR_BOTTOM")

    view.tiles = {}
    for i = 1, 4 do
        view.tiles[i] = UI.StatTile(content, i == 1 and "highlight" or nil)
        view.tiles[i]:SetHeight(TILE_HEIGHT)
    end

    view.left, view.right = {}, {}
    for _, def in ipairs(LEFT) do table.insert(view.left, CreateSection(content, def)) end
    for _, def in ipairs(RIGHT) do table.insert(view.right, CreateSection(content, def)) end
    return view
end

local function Layout(view)
    local width = view.scroll:GetWidth()
    if not width or width < 100 then width = 840 end
    view.content:SetWidth(width)
    local tileWidth = (width - 3 * GAP) / 4
    for i, tile in ipairs(view.tiles) do
        tile:ClearAllPoints()
        tile:SetPoint("TOPLEFT", (i - 1) * (tileWidth + GAP), -34)
        tile:SetWidth(tileWidth)
    end
    local top = 34 + TILE_HEIGHT + GAP
    local colWidth = (width - GAP) / 2
    local bottom = 0
    for c, column in ipairs({ view.left, view.right }) do
        local y = -top
        for _, section in ipairs(column) do
            section:ClearAllPoints()
            section:SetPoint("TOPLEFT", (c - 1) * (colWidth + GAP), y)
            section:SetWidth(colWidth)
            y = y - section:GetHeight() - GAP
        end
        bottom = math.max(bottom, -y)
    end
    view.content:SetHeight(bottom)
    local range = math.max(bottom - view.scroll:GetHeight(), 0)
    view.bar:SetMinMaxValues(0, range)
    view.bar:SetShown(range > 0)
    if view.bar:GetValue() > range then view.bar:SetValue(range) end
end

local function Refresh(view, state)
    local s = addon:GetLifetimeStats()
    view.stats = s
    view.note:SetText(string.format("every profession and character, since %s", s.first and DateText(s.first) or "today"))

    view.tiles[1]:Set("Goldsmith title", s.title, "gold",
        s.nextTitle and (Money(s.toNextTitle) .. " more to " .. s.nextTitle) or "The very top")
    view.tiles[1].tooltip = function(t)
        White(t, s.title .. " Goldsmith")
        Grey(t, "Earned by lifetime profit. Compare yours with friends.")
        for _, row in ipairs(addon:GoldsmithTitles()) do
            local r, g, b = addon:Color(row[2] == s.title and "gold" or "muted")
            t:AddDoubleLine(row[2], Money(row[1] * 10000), r, g, b, r, g, b)
        end
    end
    view.tiles[2]:Set("Lifetime profit", Signed(s.profit), addon:MoneyColor(s.profit),
        s.roi and ("ROI " .. Percent(s.roi) .. " on what the items cost") or "after costs and deposits")
    view.tiles[2].tooltip = MoneyRows(s)[1].tooltip
    view.tiles[3]:Set("Sales", Money(s.agg.revenue), "text", "after the AH cut")
    view.tiles[3].tooltip = function(t)
        White(t, "Sales")
        Grey(t, "Everything you sold on the AH, after its 5% cut.")
    end
    view.tiles[4]:Set("Auctions sold", Count(s.agg.sales), "text",
        string.format("%s items, %s profitable", Count(s.agg.units), Percent(s.winRate)))
    view.tiles[4].tooltip = nil

    for _, column in ipairs({ view.left, view.right }) do
        for _, section in ipairs(column) do FillSection(section, ForeverRows(section.def.rows(s))) end
    end
    Layout(view)
end

local function Reset(view)
    if view.bar then view.bar:SetValue(0) end
end

local function Legend()
    return {
        { "hover", ": details and records" },
        { "click", "Share in chat: brag to your friends" },
    }
end

addon:RegisterView("stats", { create = Create, refresh = Refresh, reset = Reset, legend = Legend })

_G.Goldsmith = addon
