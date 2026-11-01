-- Makes the rounded box corners for the World of Warcraft look
-- (Widgets.lua, GameBevel): Media\CornerLine.tga (the thin line, white so
-- it can take the border's color) and Media\CornerShadow.tga (the black
-- outline round it). Both are the top-left corner; the others are the same
-- texture flipped. Run from the addon folder: lua Tools\MakeCorners.lua
--
-- A texel is half a screen pixel (16 texels for 8 pixels, smoother when
-- scaled). The corner covers x and y from -1 to 7 pixels from the box's
-- edge; the line's arc is centred RADIUS in from both edges.

local RADIUS = 5
local SIZE = 16 -- texels
local SUB = 4 -- samples per texel side, for smooth edges

local function Coverage(i, j, inner, outer)
    local hits = 0
    for a = 0, SUB - 1 do
        for b = 0, SUB - 1 do
            local x = -1 + (i + (a + 0.5) / SUB) / 2
            local y = -1 + (j + (b + 0.5) / SUB) / 2
            if x < RADIUS and y < RADIUS then
                local d = math.sqrt((RADIUS - x) ^ 2 + (RADIUS - y) ^ 2)
                if d >= inner and d <= outer then hits = hits + 1 end
            end
        end
    end
    return hits / (SUB * SUB)
end

local function Write(path, inner, outer)
    local out = {}
    -- Uncompressed 32-bit TGA, rows from the top
    out[#out + 1] = string.char(0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0,
        SIZE % 256, math.floor(SIZE / 256), SIZE % 256, math.floor(SIZE / 256), 32, 0x28)
    for j = 0, SIZE - 1 do
        for i = 0, SIZE - 1 do
            local alpha = math.floor(Coverage(i, j, inner, outer) * 255 + 0.5)
            out[#out + 1] = string.char(255, 255, 255, alpha)
        end
    end
    local f = assert(io.open(path, "wb"))
    f:write(table.concat(out))
    f:close()
end

Write("Media\\CornerLine.tga", RADIUS - 1, RADIUS)
Write("Media\\CornerShadow.tga", RADIUS, RADIUS + 1)
print("Corners written")
