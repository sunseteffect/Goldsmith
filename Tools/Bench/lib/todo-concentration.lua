-- Shared by the todo-concentration-* scenarios: queue every concentration
-- line of a character's to-do the way its right-click does, then the
-- queue must fit their concentration (2026-10-24: Trypttamine's to-do
-- queued to 693 with 587, Mysticmead's to 599 with 450).
-- oldWay = true queues without the planned mix (before the prefMix fix),
-- to see the scenario catch the bug.
return function(bench, who, oldWay)
    local db = bench.LoadSaved()
    local key
    for k in pairs(db.characters) do if k:match("^([^-]+)") == who then key = k end end
    db.queues[key] = {}
    -- Some to spend, whatever the saved data has left: Mysticmead had 37
    -- and 73 by evening (2026-10-27), nothing to test
    for _, snap in pairs(db.characters[key].concentration or {}) do
        snap.current, snap.time = math.max(snap.current or 0, 450), os.time()
    end
    -- None held of what they craft: the to-do skips what you hold, and a
    -- batch made that day left nothing to test (Maddoxynn's Soul Cipher and
    -- inks, 2026-11-13)
    local outputs = {}
    for recipeID in pairs(db.characters[key].knownRecipes or {}) do
        local r = db.recipes[recipeID]
        if r and r.outputItemID then outputs[r.outputItemID] = true end
        for _, out in pairs((db.characters[key].tierData[recipeID] or {}).outputs or {}) do
            if out.itemID then outputs[out.itemID] = true end
        end
    end
    for _, c in pairs(db.characters) do
        for id in pairs(outputs) do
            if c.stock then c.stock[id] = nil end
            if c.auctions then c.auctions[id] = nil end
        end
    end
    for id in pairs(outputs) do
        if db.warbandStock then db.warbandStock[id] = nil end
        for _, book in pairs(db.inMail or {}) do book[id] = nil end
    end
    local addon = bench.Login(who, { db = db })
    for id in pairs(outputs) do bench.world.bags[id], bench.world.bank[id] = nil, nil end

    local todo = addon:GetCharacterTodo("All")
    local mine = todo[key]
    local lines = 0
    for _, item in ipairs(mine and mine.items or {}) do
        if item.concentration then
            lines = lines + 1
            local mix = item.leftoverOf and item.row.description or nil
            local prefMix = not oldWay and not mix and item.row.description or nil
            addon:QueueSuggestion(key, item.recipe, item.row.tier, true, item.crafts, nil, mix, prefMix)
            bench.Log("queued %dx %s (%s), %d concentration planned",
                item.crafts, item.recipe.outputName, item.row.description or "?", item.concentration)
        end
    end
    bench.Check(who .. "'s to-do has concentration lines", lines > 0, "none: nothing to test")
    bench.Advance(1)

    addon:ToggleWindow()
    addon:ShowTab("queue")
    bench.Advance(5)
    local screen = bench.Screen()
    local needs
    for _, l in ipairs(screen) do if l:find("^needs") and l:find("concentration") then needs = l end end
    bench.Log("queue tab: %s", tostring(needs))
    bench.Check("queue tab says what it needs", needs ~= nil)
    bench.HasNot("queue fits " .. who .. "'s concentration", screen, "(you have", true)
    bench.Done()
end
