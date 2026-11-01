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

-- Media\Ring.tga: a white ring for the portrait of a faction frame that has
-- no ring of its own (Window.lua), with a dark edge each side so it reads
-- on any background. 64 texels, the ring 52 to 60 across.
local RING = 64
local function RingTexel(i, j)
    local line, edge = 0, 0
    for a = 0, SUB - 1 do
        for b = 0, SUB - 1 do
            local x = i + (a + 0.5) / SUB - RING / 2
            local y = j + (b + 0.5) / SUB - RING / 2
            local d = math.sqrt(x * x + y * y)
            if d >= 26.5 and d <= 30 then line = line + 1
            elseif d >= 25.5 and d <= 31 then edge = edge + 1 end
        end
    end
    local n = SUB * SUB
    local alpha = (line + edge) / n
    -- Bright in the middle of the ring, dark at its edges
    local bright = (line + edge) > 0 and line / (line + edge) or 0
    local v = math.floor(bright * 255 + 0.5)
    return v, math.floor(alpha * 255 + 0.5)
end
local out = { string.char(0, 0, 2, 0, 0, 0, 0, 0, 0, 0, 0, 0, RING, 0, RING, 0, 32, 0x28) }
for j = 0, RING - 1 do
    for i = 0, RING - 1 do
        local v, alpha = RingTexel(i, j)
        out[#out + 1] = string.char(v, v, v, alpha)
    end
end
local f = assert(io.open("Media\\Ring.tga", "wb"))
f:write(table.concat(out))
f:close()
print("Corners and ring written")
