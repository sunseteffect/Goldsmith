-- On a client whose writing Goldsmith's fonts don't have, the game's own
-- fonts are used: names from the game (至暗之夜, a profession) showed as
-- boxes on zhTW (TCBeliever, GitHub, 2026-11-14). English is unchanged.
local bench = dofile(BENCH_DIR .. "bench.lua")
local zhFont = "Fonts\\bLEI00D.ttf"
local zhChat = "Fonts\\bHEI01B.ttf"
STANDARD_TEXT_FONT = zhFont
ChatFontNormal.GetFont = function() return zhChat, 14, "" end
GetLocale = function() return "zhTW" end
local addon = bench.Login("Mysticmead")
local title = addon:Font("title"):GetFont()
local body = addon:Font("body"):GetFont()
bench.Equal("titles: the game's standard font", title, zhFont)
bench.Equal("body: the game's chat font", body, zhChat)
bench.Done()
