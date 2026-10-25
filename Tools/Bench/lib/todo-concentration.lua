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
    local addon = bench.Login(who, { db = db })

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
