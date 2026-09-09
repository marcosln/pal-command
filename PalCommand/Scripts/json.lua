-- PalCommand :: json.lua
-- Minimal JSON encode/decode. Pure Lua 5.4, no dependencies.
-- Standard compact serializer; the decoder is a tolerant recursive-descent parser
-- for the orders/rules the app writes.

local M = {}

-- ---------------------------------------------------------------- encode

local function escape_str(s)
    s = tostring(s or "")
    s = s:gsub("\\", "\\\\")
    s = s:gsub('"', '\\"')
    s = s:gsub("\n", "\\n")
    s = s:gsub("\r", "\\r")
    s = s:gsub("\t", "\\t")
    s = s:gsub("[%z\1-\8\11\12\14-\31]", function(c)
        return string.format("\\u%04x", string.byte(c))
    end)
    return s
end

local function is_array(t)
    if type(t) ~= "table" then return false end
    local n = 0
    for k in pairs(t) do
        if type(k) ~= "number" or k < 1 or math.floor(k) ~= k then return false end
        n = n + 1
    end
    return n == #t
end

local function encode_value(v, out)
    local tv = type(v)
    if v == nil or v == M.null then
        out[#out + 1] = "null"
    elseif tv == "boolean" then
        out[#out + 1] = v and "true" or "false"
    elseif tv == "number" then
        if v ~= v or v == math.huge or v == -math.huge then
            out[#out + 1] = "null"
        elseif math.floor(v) == v and math.abs(v) < 1e15 then
            out[#out + 1] = string.format("%d", v)
        else
            out[#out + 1] = string.format("%.6g", v)
        end
    elseif tv == "string" then
        out[#out + 1] = '"' .. escape_str(v) .. '"'
    elseif tv == "table" then
        if is_array(v) then
            out[#out + 1] = "["
            for i = 1, #v do
                if i > 1 then out[#out + 1] = "," end
                encode_value(v[i], out)
            end
            out[#out + 1] = "]"
        else
            local keys = {}
            for k in pairs(v) do keys[#keys + 1] = tostring(k) end
            table.sort(keys)
            out[#out + 1] = "{"
            for i, k in ipairs(keys) do
                if i > 1 then out[#out + 1] = "," end
                out[#out + 1] = '"' .. escape_str(k) .. '":'
                encode_value(v[k], out)
            end
            out[#out + 1] = "}"
        end
    else
        out[#out + 1] = '"<' .. tv .. '>"'
    end
end

function M.encode(value)
    local out = {}
    encode_value(value, out)
    return table.concat(out)
end

-- ---------------------------------------------------------------- decode

M.null = setmetatable({}, { __tostring = function() return "null" end })

local function decode_error(s, pos, msg)
    local line = 1
    for _ in s:sub(1, pos):gmatch("\n") do line = line + 1 end
    error(string.format("json: %s at pos %d (line %d)", msg, pos, line), 0)
end

local decode_value

local function skip_ws(s, pos)
    local _, e = s:find("^[ \t\r\n]*", pos)
    return (e or pos - 1) + 1
end

local esc_map = { ['"'] = '"', ["\\"] = "\\", ["/"] = "/", b = "\b", f = "\f", n = "\n", r = "\r", t = "\t" }

local function decode_string(s, pos)
    local out, i = {}, pos + 1
    while i <= #s do
        local c = s:sub(i, i)
        if c == '"' then
            return table.concat(out), i + 1
        elseif c == "\\" then
            local nx = s:sub(i + 1, i + 1)
            if nx == "u" then
                local hex = s:sub(i + 2, i + 5)
                local code = tonumber(hex, 16)
                if not code then decode_error(s, i, "bad \\u escape") end
                if code < 0x80 then
                    out[#out + 1] = string.char(code)
                elseif code < 0x800 then
                    out[#out + 1] = string.char(0xC0 + (code >> 6), 0x80 + (code & 0x3F))
                else
                    out[#out + 1] = string.char(0xE0 + (code >> 12), 0x80 + ((code >> 6) & 0x3F), 0x80 + (code & 0x3F))
                end
                i = i + 6
            elseif esc_map[nx] then
                out[#out + 1] = esc_map[nx]
                i = i + 2
            else
                decode_error(s, i, "bad escape \\" .. nx)
            end
        else
            out[#out + 1] = c
            i = i + 1
        end
    end
    decode_error(s, pos, "unterminated string")
end

local function decode_number(s, pos)
    local _, e = s:find("^%-?%d+%.?%d*[eE]?[%+%-]?%d*", pos)
    local num = tonumber(s:sub(pos, e))
    if not num then decode_error(s, pos, "bad number") end
    return num, e + 1
end

decode_value = function(s, pos)
    pos = skip_ws(s, pos)
    local c = s:sub(pos, pos)
    if c == "{" then
        local obj = {}
        pos = skip_ws(s, pos + 1)
        if s:sub(pos, pos) == "}" then return obj, pos + 1 end
        while true do
            pos = skip_ws(s, pos)
            if s:sub(pos, pos) ~= '"' then decode_error(s, pos, "expected key string") end
            local key
            key, pos = decode_string(s, pos)
            pos = skip_ws(s, pos)
            if s:sub(pos, pos) ~= ":" then decode_error(s, pos, "expected ':'") end
            local val
            val, pos = decode_value(s, pos + 1)
            obj[key] = val
            pos = skip_ws(s, pos)
            local d = s:sub(pos, pos)
            if d == "," then
                pos = pos + 1
            elseif d == "}" then
                return obj, pos + 1
            else
                decode_error(s, pos, "expected ',' or '}'")
            end
        end
    elseif c == "[" then
        local arr = {}
        pos = skip_ws(s, pos + 1)
        if s:sub(pos, pos) == "]" then return arr, pos + 1 end
        while true do
            local val
            val, pos = decode_value(s, pos)
            arr[#arr + 1] = val
            pos = skip_ws(s, pos)
            local d = s:sub(pos, pos)
            if d == "," then
                pos = pos + 1
            elseif d == "]" then
                return arr, pos + 1
            else
                decode_error(s, pos, "expected ',' or ']'")
            end
        end
    elseif c == '"' then
        return decode_string(s, pos)
    elseif c == "t" and s:sub(pos, pos + 3) == "true" then
        return true, pos + 4
    elseif c == "f" and s:sub(pos, pos + 4) == "false" then
        return false, pos + 5
    elseif c == "n" and s:sub(pos, pos + 3) == "null" then
        return M.null, pos + 4
    elseif c:match("[%-%d]") then
        return decode_number(s, pos)
    end
    decode_error(s, pos, "unexpected character '" .. c .. "'")
end

--- Decode a JSON string. Returns (value) on success, (nil, errmsg) on failure.
function M.decode(str)
    if type(str) ~= "string" or str == "" then return nil, "empty input" end
    local ok, val, endpos = pcall(function()
        local v, p = decode_value(str, 1)
        return v, p
    end)
    if not ok then return nil, tostring(val) end
    local _ = endpos
    return val
end

return M
