-- An item page's "Craft it into": every recipe that uses the material,
-- most profit first, beside Your activity (user, 2026-11-01: gold Mana
-- Lily Pigment dropped, what to turn it into instead). Click one to plan it.
local bench = dofile(BENCH_DIR .. "bench.lua")
local addon = bench.Login("Mysticmead")
GoldsmithDB.ui2.itemPageInto = nil
addon:ToggleWindow()
bench.Advance(1)

-- A material two or more current recipes use
local material, list
addon.noYield = addon.noYield + 1
for _, recipe in pairs(GoldsmithDB.recipes) do
    for _, slot in ipairs(recipe.reagents or {}) do
        for _, id in pairs(slot.itemIDs or {}) do
            if not material then
                local l = addon:GetRecipesUsingAll(id)
                if #l >= 2 then material, list = id, l end
            end
        end
    end
end
addon.noYield = addon.noYield - 1
bench.Check("a material two recipes use", material ~= nil)
if not material then bench.Done() return end
local sorted = true
for i = 2, #list do
    if list[i].profit and list[i - 1].profit and list[i].profit > list[i - 1].profit then sorted = false end
end
bench.Check("most profit first", sorted)

addon:OpenItem(C_Item.GetItemNameByID(material) or "?", material)
bench.Advance(5)
local page = addon:GetTabScreen("items").view.page
bench.Check("the page has the list", page.intoList and #page.intoList >= 2)
bench.Check("Craft it into heading shows", page.intoTab:IsShown())
bench.Check("activity first", not page.into:IsShown())

page.intoTab:GetScript("OnClick")(page.intoTab)
bench.Check("Craft it into shows", page.into:IsShown())
bench.Check("activity hidden", not page.earned:IsShown())
local first = page.intoRows[1]
bench.Has("first row: the most profitable", first and first.name:GetText() or "", list[1].recipe.outputName, true)
bench.Equal("choice kept", GoldsmithDB.ui2.itemPageInto, true)

-- Click a row: its plan
local opened
local open = addon.OpenCraftPlan
addon.OpenCraftPlan = function(_, recipe) opened = recipe end
first:GetScript("OnClick")(first)
addon.OpenCraftPlan = open
bench.Equal("click plans it", opened and opened.recipeID, list[1].recipe.recipeID)

-- Back to the activity
page.activityTab:GetScript("OnClick")(page.activityTab)
bench.Check("activity again", page.earned:IsShown() and not page.into:IsShown())
bench.Equal("no errors", #bench.TakeErrors(), 0)
GoldsmithDB.ui2.itemPageInto = nil
bench.Done()
