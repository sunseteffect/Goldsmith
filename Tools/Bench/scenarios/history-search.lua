-- History's search: a line of its own above the filters, matching item
-- names; the entry count and gold follow it (user, 2026-11-10)
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
GoldsmithDB.ui2.historyKind, GoldsmithDB.ui2.historyCharacter = nil, nil
addon:ToggleWindow()
addon:ShowTab("history")
bench.Advance(10)
local view = addon:GetTabScreen("history").view

local function Count()
    for _, line in ipairs(bench.Screen()) do
        local n = line:match("^(%d+) entr")
        if n then return tonumber(n) end
    end
end
local function Search(text)
    view.searchBox:SetText(text)
    view.search = text
    addon.RefreshWindow()
    bench.Advance(3)
end

-- An item name from the history itself, part of it typed
local all = Count()
local rows = addon:GetHistory({ prof = "All", kind = nil })
local name
for _, r in ipairs(rows) do if r.item and #r.item > 6 and r.kind == "Sale" then name = r.item break end end
bench.Check("history has a sale to find", name ~= nil)
local part = name:sub(2, 5):lower()
Search(part:upper())
local found = Count()
bench.Check("fewer entries than all", found and all and found < all, tostring(found) .. " of " .. tostring(all))
local ok = true
for _, r in ipairs(view.list.items or {}) do
    local names = r.item or ""
    for _, it in ipairs(r.items or {}) do names = names .. " " .. (it.name or "") end
    if not names:lower():find(part, 1, true) then ok = false bench.Log("no match: %s %s", tostring(r.kind), names) end
end
bench.Check("every row has it in its name", ok)
bench.Has("named as a filter", table.concat(bench.Screen(), "\n"), "Filtered", true)

-- One letter: everything still
Search(part:sub(1, 1))
bench.Equal("one letter doesn't filter", Count(), all)

-- Nothing matches: says so
Search("zzqqxx")
bench.Has("says nothing matches the search", table.concat(bench.Screen(), "\n"), "No item matching", true)

-- Clicking History again clears it
Search(part)
bench.Click("History")
bench.Advance(3)
bench.Equal("tab click clears the search", view.search, "")
bench.Equal("all entries back", Count(), all)

-- The search line sits above the filters
bench.Check("filters under the search", select(5, view.chips[1]:GetPoint(1)) < 0)
-- One item from its page: the "Item: ... x" chip sits on the search line
-- (user, 2026-11-10), left, right after the box
addon:OpenHistory({ item = name })
bench.Advance(3)
bench.Check("item chip shows", view.itemChip:IsShown())
local _, relativeTo = view.itemChip:GetPoint(1)
bench.Check("on the search line, after the box", relativeTo == view.searchBox)
bench.Has("names the item", table.concat(bench.Screen(), "\n"), "Item: " .. name, true)
bench.Done()
