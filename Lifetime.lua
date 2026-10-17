local addon = _G.Goldsmith or {}

-- Lifetime stats (the Stats tab)
--
-- Everything Goldsmith has seen, added up for fun and for comparing with
-- friends (user, 2026-10-17). Most of it comes from what's already saved:
-- sales, purchases and deposits (the ledger), crafts per recipe
-- (craftStats, never trimmed), proc counts (calibration), gathered
-- materials, opened boxes and each character's gold by day.
--
-- Two things would otherwise be lost, so they're tallied as they go in
-- GoldsmithDB.lifetime:
--   trimmed  the ledger entries "Keep history for" deletes (Data.lua's
--            TrimHistory hands them here first), added up the same way as
--            the live ledger, so totals never drop when history is trimmed
--   crafts   from the craft log (its last 100 crafts only): concentration
--            spent, the biggest multicraft, ingenuity, first crafts. Each
--            log entry is marked counted once added.
--   orders   from the order crafts (the last 100 only), the same way
-- Deleting an entry in History takes it out of the stats too (it's gone
-- from the ledger and was never trimmed); deleting all transactions
-- (Settings) clears the trimmed tally with them.

local AH_CUT = 0.05
-- Sales collected within this long of each other on one character are one
-- trip to the mailbox (Biggest mailbox haul)
local HAUL_GAP = 300

-- Goldsmith titles by lifetime profit (gold), for comparing with friends:
-- "Master Goldsmith"
local TITLES = {
    { 0, "Apprentice" },
    { 1000, "Journeyman" },
    { 10000, "Expert" },
    { 50000, "Artisan" },
    { 100000, "Master" },
    { 250000, "Grand Master" },
    { 500000, "Illustrious" },
    { 1000000, "Legendary" },
    { 5000000, "Mythic" },
    { 10000000, "Ascended" },
}
addon.GOLDSMITH_TITLES = TITLES

local function Store()
    GoldsmithDB.lifetime = GoldsmithDB.lifetime or {}
    local l = GoldsmithDB.lifetime
    l.started = l.started or time()
    l.crafts = l.crafts or { crafts = 0, conc = 0, ingenuity = 0, firsts = 0, resProcs = 0, crits = 0 }
    l.orders = l.orders or {}
    for _, kind in ipairs({ "player", "patron" }) do
        l.orders[kind] = l.orders[kind] or { count = 0, commission = 0, profit = 0, days = {}, byProf = {}, byChar = {} }
    end
    return l
end

-- Sales, purchases and deposits, added up
--
-- agg = { sales, units, revenue, costed (sales with a cost), costedRevenue,
-- cost, wins, ahCut, refunds, purchases, bought, spent, posts, posted,
-- deposits, first, byProf / byChar = { [key] = { sales, revenue,
-- costedRevenue, cost, deposits } }, byItem = { [name] = { sales, units,
-- revenue, profit } }, days = { [YYYY-MM-DD] = profit }, best, worst
-- (sales by profit), biggest (by gold), priciest (by gold each),
-- bigPurchase }. Saved for the trimmed tally, so only plain values.
local function NewAgg()
    return { sales = 0, units = 0, revenue = 0, costed = 0, costedRevenue = 0, cost = 0, wins = 0,
             ahCut = 0, refunds = 0, purchases = 0, bought = 0, spent = 0, posts = 0, posted = 0,
             deposits = 0, byProf = {}, byChar = {}, byItem = {}, days = {} }
end

local function Group(map, key)
    local g = map[key]
    if not g then
        g = { sales = 0, revenue = 0, costedRevenue = 0, cost = 0, deposits = 0 }
        map[key] = g
    end
    return g
end

local function Record(e, extra)
    local r = { item = e.item, itemID = e.itemID, qty = e.quantity, time = e.timestamp,
                char = e.character }
    for k, v in pairs(extra) do r[k] = v end
    return r
end

local function Accumulate(agg, e, estimateCost)
    local t = e.timestamp or 0
    if not agg.first or t < agg.first then agg.first = t end
    local day = date("%Y-%m-%d", t)
    local prof = Group(agg.byProf, e.profession or "Unassigned")
    local char = Group(agg.byChar, (e.character and e.realm) and (e.character .. "-" .. e.realm) or "?")
    local qty, gold = e.quantity or 0, e.totalCopper or 0
    if e.type == "REVENUE" then
        agg.sales, agg.units, agg.revenue = agg.sales + 1, agg.units + qty, agg.revenue + gold
        prof.sales, prof.revenue = prof.sales + 1, prof.revenue + gold
        char.sales, char.revenue = char.sales + 1, char.revenue + gold
        local refund = e.depositRefund or 0
        agg.refunds = agg.refunds + refund
        agg.ahCut = agg.ahCut + math.max(gold - refund, 0) / (1 - AH_CUT) * AH_CUT
        local cost = e.costBasis
        if not cost and estimateCost then
            local unit = estimateCost(e.item)
            cost = unit and unit * qty
        end
        local item = e.item and agg.byItem[e.item]
        if e.item and not item then
            item = { sales = 0, units = 0, revenue = 0, profit = 0 }
            agg.byItem[e.item] = item
        end
        if item then item.sales, item.units, item.revenue = item.sales + 1, item.units + qty, item.revenue + gold end
        if not agg.biggest or gold > agg.biggest.gold then agg.biggest = Record(e, { gold = gold }) end
        local each = qty > 0 and gold / qty or gold
        if not agg.priciest or each > agg.priciest.each then agg.priciest = Record(e, { each = each, gold = gold }) end
        if cost then
            local profit = gold - cost
            agg.costed, agg.costedRevenue, agg.cost = agg.costed + 1, agg.costedRevenue + gold, agg.cost + cost
            prof.costedRevenue, prof.cost = prof.costedRevenue + gold, prof.cost + cost
            char.costedRevenue, char.cost = char.costedRevenue + gold, char.cost + cost
            if profit > 0 then agg.wins = agg.wins + 1 end
            if item then item.profit = item.profit + profit end
            agg.days[day] = (agg.days[day] or 0) + profit
            if not agg.best or profit > agg.best.profit then agg.best = Record(e, { profit = profit, gold = gold }) end
            if not agg.worst or profit < agg.worst.profit then agg.worst = Record(e, { profit = profit, gold = gold }) end
        end
    elseif e.kind == "DEPOSIT" then
        agg.posts, agg.posted, agg.deposits = agg.posts + 1, agg.posted + qty, agg.deposits + gold
        prof.deposits, char.deposits = prof.deposits + gold, char.deposits + gold
        agg.days[day] = (agg.days[day] or 0) - gold
    else
        agg.purchases, agg.bought, agg.spent = agg.purchases + 1, agg.bought + qty, agg.spent + gold
        if not agg.bigPurchase or gold > agg.bigPurchase.gold then agg.bigPurchase = Record(e, { gold = gold }) end
    end
end

local SUMS = { "sales", "units", "revenue", "costed", "costedRevenue", "cost", "wins", "ahCut", "refunds",
               "purchases", "bought", "spent", "posts", "posted", "deposits" }
local GROUP_SUMS = { "sales", "revenue", "costedRevenue", "cost", "deposits" }
local ITEM_SUMS = { "sales", "units", "revenue", "profit" }

local function AddSums(into, from, keys)
    for _, k in ipairs(keys) do into[k] = (into[k] or 0) + (from[k] or 0) end
end

local function Higher(a, b, field) if not a then return b end if not b then return a end return b[field] > a[field] and b or a end
local function Lower(a, b, field) if not a then return b end if not b then return a end return b[field] < a[field] and b or a end

-- from's numbers added into `into`
local function Merge(into, from)
    if not from then return into end
    AddSums(into, from, SUMS)
    if from.first and (not into.first or from.first < into.first) then into.first = from.first end
    for key, g in pairs(from.byProf or {}) do AddSums(Group(into.byProf, key), g, GROUP_SUMS) end
    for key, g in pairs(from.byChar or {}) do AddSums(Group(into.byChar, key), g, GROUP_SUMS) end
    for name, g in pairs(from.byItem or {}) do
        into.byItem[name] = into.byItem[name] or { sales = 0, units = 0, revenue = 0, profit = 0 }
        AddSums(into.byItem[name], g, ITEM_SUMS)
    end
    for day, p in pairs(from.days or {}) do into.days[day] = (into.days[day] or 0) + p end
    into.best = Higher(into.best, from.best, "profit")
    into.worst = Lower(into.worst, from.worst, "profit")
    into.biggest = Higher(into.biggest, from.biggest, "gold")
    into.priciest = Higher(into.priciest, from.priciest, "each")
    into.bigPurchase = Higher(into.bigPurchase, from.bigPurchase, "gold")
    return into
end

-- Ledger entries "Keep history for" is about to delete (TrimHistory)
function addon:LifetimeTrimmed(entries)
    if #entries == 0 or addon:UsingTourData() then return end
    local l = Store()
    local agg = NewAgg()
    for _, e in ipairs(entries) do Accumulate(agg, e, addon.EstimateSaleCost and function(name)
        return addon:EstimateSaleCost(name) end) end
    l.trimmed = Merge(l.trimmed or NewAgg(), agg)
end

-- Delete all transactions (Settings): the trimmed ones go too
function addon:LifetimeLedgerCleared()
    if GoldsmithDB.lifetime then GoldsmithDB.lifetime.trimmed = nil end
end

-- Crafts and orders from the logs that only keep the latest 100, added to
-- the tally once each (log entries and order lots marked counted)
function addon:LifetimeCatchUp()
    if not GoldsmithDB or addon:UsingTourData() then return end
    local l = Store()
    local c, o = l.crafts, l.orders
    for _, e in ipairs(GoldsmithDB.craftLog or {}) do
        if not e.counted then
            e.counted = true
            c.conc = c.conc + (tonumber(e.concentrationSpent) or 0)
            if e.hasIngenuityProc then c.ingenuity = c.ingenuity + 1 end
            if e.firstCraftReward then c.firsts = c.firsts + 1 end
            if e.isCrit then c.crits = c.crits + 1 end
            if type(e.resourcesReturned) == "table" and next(e.resourcesReturned) then c.resProcs = c.resProcs + 1 end
            local extra = tonumber(e.multicraft) or 0
            if extra > 0 and (not c.bestMc or extra > c.bestMc.extra) then
                c.bestMc = { extra = extra, qty = e.quantity, itemID = e.itemID, recipeID = e.recipeID, time = e.time,
                             char = e.char }
            end
            c.since = math.min(c.since or e.time or time(), e.time or time())
        end
    end
    for _, lot in ipairs(GoldsmithDB.orderCrafts or {}) do
        if not lot.counted then
            lot.counted = true
            -- A patron (NPC) order, or a player's: the type is saved since
            -- 2.5.15; before that only patron orders had rewards
            local npc = Enum.CraftingOrderType and Enum.CraftingOrderType.Npc
            local patron
            if lot.orderType ~= nil then patron = lot.orderType == npc else patron = lot.rewards ~= nil end
            local g = patron and o.patron or o.player
            o.since = math.min(o.since or lot.time or time(), lot.time or time())
            g.count = g.count + 1
            if lot.commission then
                local profit = lot.commission + (lot.kept or 0) + (addon.LotRewardsValue and addon:LotRewardsValue(lot) or 0)
                    - (lot.unitCost or 0) * (lot.qty or 0)
                g.commission, g.profit = g.commission + lot.commission, g.profit + profit
                if not patron then
                    -- Player orders count in lifetime profit, on their day,
                    -- profession and character
                    local day = date("%Y-%m-%d", lot.time or time())
                    g.days[day] = (g.days[day] or 0) + profit
                    local recipe = lot.name and addon:FindRecipeByOutput(lot.name)
                    local prof = recipe and recipe.profession or "Unassigned"
                    g.byProf[prof] = (g.byProf[prof] or 0) + profit
                    if lot.char then g.byChar[lot.char] = (g.byChar[lot.char] or 0) + profit end
                end
                if not g.bestTip or lot.commission > g.bestTip.gold then
                    g.bestTip = { gold = lot.commission, item = lot.name, itemID = lot.itemID, time = lot.time, char = lot.char }
                end
            end
        end
    end
end

-- Days

-- Longest run of profitable days in a row, and the one going now (today
-- or yesterday counts as now, so a day not sold yet doesn't end it)
local function Streaks(days)
    local list = {}
    for day, p in pairs(days) do if p > 0 then table.insert(list, day) end end
    table.sort(list)
    local function DayNumber(day)
        local y, m, d = day:match("(%d+)-(%d+)-(%d+)")
        return math.floor(time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) / 86400)
    end
    local longest, run, last = 0, 0, nil
    for _, day in ipairs(list) do
        local n = DayNumber(day)
        run = (last and n == last + 1) and run + 1 or 1
        longest = math.max(longest, run)
        last = n
    end
    local today = DayNumber(date("%Y-%m-%d"))
    local current = (last and today - last <= 1) and run or 0
    return longest, current
end

-- The best 7 days in a row (by calendar), the best calendar month and the
-- best day: { profit, from (day), to }
local function BestPeriods(days)
    local bestDay, bestWeek, bestMonth
    local months = {}
    for day, p in pairs(days) do
        if not bestDay or p > bestDay.profit then bestDay = { profit = p, from = day } end
        local month = day:sub(1, 7)
        months[month] = (months[month] or 0) + p
        -- The week ending on this day
        local y, m, d = day:match("(%d+)-(%d+)-(%d+)")
        local noon = time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 })
        local sum = 0
        for i = 0, 6 do sum = sum + (days[date("%Y-%m-%d", noon - i * 86400)] or 0) end
        if not bestWeek or sum > bestWeek.profit then
            bestWeek = { profit = sum, from = date("%Y-%m-%d", noon - 6 * 86400), to = day }
        end
    end
    for month, p in pairs(months) do
        if not bestMonth or p > bestMonth.profit then bestMonth = { profit = p, from = month } end
    end
    return bestDay, bestWeek, bestMonth
end

-- The biggest trip to the mailbox: sales one character collected within
-- HAUL_GAP of each other, added up. Live ledger only.
local function BiggestHaul(entries)
    local byChar = {}
    for _, e in ipairs(entries) do
        if e.type == "REVENUE" and e.character then
            byChar[e.character] = byChar[e.character] or {}
            table.insert(byChar[e.character], e)
        end
    end
    local best
    for char, list in pairs(byChar) do
        table.sort(list, function(a, b) return a.timestamp < b.timestamp end)
        local total, count, start, last = 0, 0, nil, nil
        local function Close()
            if count > 0 and (not best or total > best.gold) then
                best = { gold = total, count = count, time = start, char = char }
            end
        end
        for _, e in ipairs(list) do
            if last and e.timestamp - last > HAUL_GAP then
                Close()
                total, count, start = 0, 0, nil
            end
            total, count = total + e.totalCopper, count + 1
            start = start or e.timestamp
            last = e.timestamp
        end
        Close()
        addon:Yield()
    end
    return best
end

-- The most gold you've had on all your characters and the warband bank
-- together (characters you excluded aren't counted), and the day
local function PeakGold()
    local histories = {}
    local days = {}
    local function Add(history)
        local list = {}
        for day, copper in pairs(history or {}) do
            table.insert(list, { day = day, copper = copper })
            days[day] = true
        end
        table.sort(list, function(a, b) return a.day < b.day end)
        table.insert(histories, { list = list, at = 0, value = 0 })
    end
    Add(GoldsmithDB.warbandGold)
    for key, c in pairs(GoldsmithDB.characters or {}) do
        if addon:IsCharacterIncluded(key) then Add(c.gold) end
    end
    local order = {}
    for day in pairs(days) do table.insert(order, day) end
    table.sort(order)
    local best
    for i, day in ipairs(order) do
        if i % 64 == 0 then addon:Yield() end
        local total = 0
        for _, h in ipairs(histories) do
            while h.list[h.at + 1] and h.list[h.at + 1].day <= day do
                h.at = h.at + 1
                h.value = h.list[h.at].copper
            end
            total = total + h.value
        end
        if not best or total > best.copper then best = { copper = total, day = day } end
    end
    return best
end

-- Title

function addon:GoldsmithTitle(profitCopper)
    local gold = math.max(profitCopper or 0, 0) / 10000
    local at, nextTitle = TITLES[1], nil
    for i, t in ipairs(TITLES) do
        if gold >= t[1] then at, nextTitle = t, TITLES[i + 1] end
    end
    return at[2], nextTitle and nextTitle[2], nextTitle and (nextTitle[1] * 10000 - math.max(profitCopper or 0, 0))
end

-- Everything for the Stats tab. Kept until data changes; callers mustn't
-- change what's returned.
local statsCache

local function ProfitOf(g) return g.costedRevenue - g.cost - g.deposits + (g.orders or 0) end
local function SalesProfitOf(g) return g.costedRevenue - g.cost - g.deposits end

local function Compute()
    addon:LifetimeCatchUp()
    local l = GoldsmithDB.lifetime or {}
    local s = {}

    -- Sales, purchases and deposits
    local live = NewAgg()
    local estimate = function(name) return addon:EstimateSaleCost(name) end
    local entries = addon.ledger:getAll()
    for i, e in ipairs(entries) do
        if i % 32 == 0 then addon:Yield() end
        Accumulate(live, e, estimate)
    end
    local agg = Merge(Merge(NewAgg(), l.trimmed), live)
    s.agg = agg
    -- Orders for players count in lifetime profit (user, 2026-10-17);
    -- patron orders are shown on their own: they're often taken at a loss
    -- on purpose, for knowledge
    local po = l.orders and l.orders.player or {}
    for day, p in pairs(po.days or {}) do agg.days[day] = (agg.days[day] or 0) + p end
    for prof, p in pairs(po.byProf or {}) do Group(agg.byProf, prof).orders = p end
    for char, p in pairs(po.byChar or {}) do Group(agg.byChar, char).orders = p end
    s.salesProfit = agg.costedRevenue - agg.cost - agg.deposits
    s.orderProfit = po.profit or 0
    s.profit = s.salesProfit + s.orderProfit
    s.roi = agg.cost > 0 and (s.salesProfit / agg.cost * 100) or nil
    s.depositsLost = math.max(agg.deposits - agg.refunds, 0)
    s.winRate = agg.costed > 0 and (agg.wins / agg.costed * 100) or nil
    s.sellThrough = agg.posted > 0 and math.min(agg.units / agg.posted * 100, 100) or nil
    s.perSale = agg.costed > 0 and (s.salesProfit / agg.costed) or nil
    s.first = agg.first
    s.daysTracked = agg.first and (math.floor((time() - agg.first) / 86400) + 1) or 0
    s.perDay = s.daysTracked > 0 and s.profit / s.daysTracked or nil
    s.haul = BiggestHaul(entries)

    -- Items
    local items, uniqueSold = {}, 0
    for name, g in pairs(agg.byItem) do
        uniqueSold = uniqueSold + 1
        table.insert(items, { name = name, units = g.units, revenue = g.revenue, profit = g.profit, sales = g.sales })
    end
    s.uniqueSold = uniqueSold
    table.sort(items, function(a, b) return a.units > b.units end)
    s.mostSold = items[1]
    table.sort(items, function(a, b) return a.profit > b.profit end)
    s.topEarner = items[1]
    s.topItems = {}
    for i = 1, math.min(5, #items) do s.topItems[i] = items[i] end
    addon:Yield()

    -- Days
    s.bestDay, s.bestWeek, s.bestMonth = BestPeriods(agg.days)
    s.longestStreak, s.currentStreak = Streaks(agg.days)
    local active, good = 0, 0
    for _, p in pairs(agg.days) do
        active = active + 1
        if p > 0 then good = good + 1 end
    end
    s.activeDays, s.goodDays = active, good
    addon:Yield()

    -- Time spent making gold
    local seconds = 0
    for _, c in pairs(GoldsmithDB.characters or {}) do
        for _, sec in pairs(c.goldTime or {}) do seconds = seconds + sec end
    end
    s.seconds = seconds
    s.perHour = seconds >= 600 and (s.profit / seconds * 3600) or nil
    s.peakGold = PeakGold()

    -- Professions and characters, most profit first
    s.professions = {}
    for prof, g in pairs(agg.byProf) do
        if prof ~= "Unassigned" then
            table.insert(s.professions, { name = prof, profit = ProfitOf(g), sales = g.sales, revenue = g.revenue,
                orders = g.orders, roi = g.cost > 0 and (SalesProfitOf(g) / g.cost * 100) or nil })
        end
    end
    table.sort(s.professions, function(a, b) return a.profit > b.profit end)
    s.characters = {}
    for key, g in pairs(agg.byChar) do
        if key ~= "?" then
            local c = GoldsmithDB.characters and GoldsmithDB.characters[key]
            table.insert(s.characters, { key = key, name = key:match("^([^-]+)") or key, class = c and c.class,
                profit = ProfitOf(g), sales = g.sales, revenue = g.revenue, orders = g.orders, money = c and c.money })
        end
    end
    table.sort(s.characters, function(a, b) return a.profit > b.profit end)
    local richest
    for key, c in pairs(GoldsmithDB.characters or {}) do
        if c.money and (not richest or c.money > richest.money) then
            richest = { key = key, name = c.name or key, class = c.class, money = c.money }
        end
    end
    s.richest = richest

    -- Crafting: craftStats has every craft Goldsmith has seen
    local crafts, made, extra, recipes, byProf = 0, 0, 0, 0, {}
    local mostCrafted
    for recipeID, st in pairs(GoldsmithDB.craftStats or {}) do
        local recipe = GoldsmithDB.recipes and GoldsmithDB.recipes[recipeID]
        crafts, made = crafts + (st.crafts or 0), made + (st.output or 0)
        recipes = recipes + 1
        if recipe and (recipe.outputQty or 0) > 0 then
            extra = extra + math.max((st.output or 0) - (st.crafts or 0) * recipe.outputQty, 0)
        end
        if recipe and recipe.profession then byProf[recipe.profession] = (byProf[recipe.profession] or 0) + (st.crafts or 0) end
        if not mostCrafted or (st.crafts or 0) > mostCrafted.crafts then
            mostCrafted = { crafts = st.crafts or 0, made = st.output or 0, recipeID = recipeID,
                name = recipe and (recipe.outputName or recipe.name) }
        end
    end
    s.crafts, s.made, s.extraItems, s.recipesCrafted, s.mostCrafted = crafts, made, extra, recipes, mostCrafted
    for _, p in ipairs(s.professions) do p.crafts = byProf[p.name] end
    local busiest
    for prof, n in pairs(byProf) do
        if not busiest or n > busiest.crafts then busiest = { name = prof, crafts = n } end
    end
    s.busiestProfession = busiest
    local mcProcs = 0
    for _, c in pairs(GoldsmithDB.characters or {}) do
        for _, cal in pairs(c.calibration or {}) do
            mcProcs = mcProcs + (cal.mcProcs or 0)
            for _, f in pairs(cal.finishing or {}) do mcProcs = mcProcs + (f.crafts or 0) end
        end
    end
    s.mcProcs = mcProcs
    s.craftTally = l.crafts or {}
    s.orders = l.orders or {}
    s.orders.player = s.orders.player or {}
    s.orders.patron = s.orders.patron or {}

    -- Gathered and opened
    local gathered, worth, byMaterial = 0, 0, {}
    for i, e in ipairs(GoldsmithDB.gathered or {}) do
        if i % 64 == 0 then addon:Yield() end
        if not e.box then
            gathered, worth = gathered + (e.qty or 0), worth + (e.value or 0)
            if e.name then
                local m = byMaterial[e.name] or { name = e.name, itemID = e.itemID, qty = 0, value = 0 }
                byMaterial[e.name] = m
                m.qty, m.value = m.qty + (e.qty or 0), m.value + (e.value or 0)
            end
        end
    end
    local topMaterial
    for _, m in pairs(byMaterial) do
        if not topMaterial or m.value > topMaterial.value then topMaterial = m end
    end
    local opened = 0
    for _, box in pairs(GoldsmithDB.boxContents or {}) do opened = opened + (box.opened or 0) end
    s.gathered, s.gatheredWorth, s.topMaterial, s.boxesOpened = gathered, worth, topMaterial, opened
    s.salvageRuns = #(GoldsmithDB.salvageRuns or {})

    -- Goldsmith's picks: crafts made after a suggestion, and how they sold
    s.followed = addon:GetFollowedSummary(3650)

    s.title, s.nextTitle, s.toNextTitle = addon:GoldsmithTitle(s.profit)
    return s
end

function addon:GetLifetimeStats()
    statsCache = statsCache or addon:NewCache()
    local store = statsCache:Get()
    store.stats = store.stats or Compute()
    return store.stats
end

_G.Goldsmith = addon
