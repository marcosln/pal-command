-- PalCommand :: bytes.lua
-- Serialization of a craft order into the PalNetArchive byte payload that
-- PalMapObjectConvertItemModel:ChangeRecipe_ServerInternal expects.
--
-- Layout (little-endian), reverse-engineered from live captures on Palworld
-- v1.0.4.x and verified byte-for-byte:
--
--   int32   string length, including the null terminator   (= #recipe + 1)
--   UTF-16  recipe id, one 0x00 high byte per ascii char
--   uint16  0x0000                                          (string null terminator)
--   int32   product count
--   uint8   transport-to-storage flag (1 = deliver output to base storage)
--
-- This layout is game-version specific, not server specific. If a Palworld update
-- changes it, only this file (or a cloud-delivered override) needs to change.

local M = {}

M.FORMAT_VERSION = "1.0"
M.FORMAT_GAME = "palworld-1.0.4"

--- Build the byte array (1-indexed Lua table of 0-255 integers).
-- @param recipe_id string  e.g. "Pal_crystal_S"
-- @param count integer     product count (>= 1)
-- @param transport boolean deliver output to storage
function M.build(recipe_id, count, transport)
    assert(type(recipe_id) == "string" and #recipe_id > 0, "recipe_id must be a non-empty string")
    count = math.max(1, math.floor(tonumber(count) or 1))

    local b = {}
    local function put_i32(v)
        v = v & 0xFFFFFFFF
        b[#b + 1] = v & 0xFF
        b[#b + 1] = (v >> 8) & 0xFF
        b[#b + 1] = (v >> 16) & 0xFF
        b[#b + 1] = (v >> 24) & 0xFF
    end

    put_i32(#recipe_id + 1)          -- strlen incl null
    for i = 1, #recipe_id do
        b[#b + 1] = recipe_id:byte(i) -- low byte
        b[#b + 1] = 0                 -- high byte (UTF-16LE, ascii)
    end
    b[#b + 1] = 0                     -- null terminator low
    b[#b + 1] = 0                     -- null terminator high
    put_i32(count)
    b[#b + 1] = transport and 1 or 0

    return b
end

--- Hex dump helper for logs.
function M.hex(bytes, limit)
    local out = {}
    for i = 1, math.min(#bytes, limit or #bytes) do
        out[#out + 1] = string.format("%02X", bytes[i])
    end
    return table.concat(out, " ")
end

--- Sanity check our encoder against a captured real payload (array of ints).
-- Returns true, or false + a description of the first divergence.
function M.matches_capture(recipe_id, count, transport, captured)
    local ours = M.build(recipe_id, count, transport)
    if #ours ~= #captured then
        return false, string.format("length %d vs captured %d", #ours, #captured)
    end
    for i = 1, #ours do
        if ours[i] ~= captured[i] then
            return false, string.format("byte %d: %02X vs %02X", i, ours[i], captured[i])
        end
    end
    return true
end

return M
