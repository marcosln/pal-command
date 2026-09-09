-- PalCommand :: util.lua
-- Shared helpers: safe UE calls, logging, ini parsing, file IO, paths.

local M = {}

M.PREFIX = "[PalCommand]"

-- ---------------------------------------------------------------- logging

local _logfile = nil
function M.set_logfile(path) _logfile = path end

function M.log(...)
    local parts = {}
    for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
    local line = M.PREFIX .. " " .. table.concat(parts, " ")
    pcall(function() print(line .. "\n") end)
    if _logfile then
        local f = io.open(_logfile, "ab")
        if f then
            f:write(os.date("!%Y-%m-%dT%H:%M:%SZ ") .. line .. "\n")
            f:close()
        end
    end
end

-- ---------------------------------------------------------------- safe UE

--- pcall wrapper: returns the result of fn() or nil on error.
function M.ok(fn)
    local success, result = pcall(fn)
    if success then return result end
    return nil
end

function M.valid(o)
    if o == nil then return false end
    return M.ok(function() return o:IsValid() end) == true
end

function M.full_name(o)
    return M.ok(function() return o:GetFullName() end) or "<none>"
end

function M.short_name(o)
    local s = M.full_name(o)
    return s:match("([^.]+)$") or s
end

--- Turn an FName / FString / userdata into a plain Lua string.
function M.fstr(v)
    if v == nil then return "" end
    if type(v) == "string" then return v end
    return M.ok(function() return v:ToString() end)
        or M.ok(function() return v:get():ToString() end)
        or tostring(v)
end

function M.find_all(class_name)
    local list = M.ok(function() return FindAllOf(class_name) end)
    if type(list) == "table" then return list end
    return {}
end

function M.find_first(class_name)
    return M.ok(function() return FindFirstOf(class_name) end)
end

-- ---------------------------------------------------------------- ini

--- Parse a flat INI (one [section]) into a { key = value } table (lowercased keys).
function M.parse_ini(path)
    local values = {}
    local f = io.open(path, "r")
    if not f then return values end
    local section = ""
    for line in f:lines() do
        local heading = line:match("^%s*%[([^%]]+)%]%s*$")
        if heading then
            section = heading:lower()
        else
            local key, val = line:match("^%s*([%w_%.%-]+)%s*=%s*(.-)%s*$")
            if key and not line:match("^%s*[;#]") then
                values[key:lower()] = val
            end
        end
    end
    f:close()
    return values
end

function M.as_bool(v, default)
    if v == nil then return default end
    local s = tostring(v):lower():gsub("%s", "")
    if s == "true" or s == "1" or s == "yes" or s == "on" then return true end
    if s == "false" or s == "0" or s == "no" or s == "off" then return false end
    return default
end

function M.as_int(v, default, min, max)
    local n = tonumber(v)
    if not n then return default end
    n = math.floor(n)
    if min and n < min then return default end
    if max and n > max then return default end
    return n
end

-- ---------------------------------------------------------------- files

function M.read_file(path)
    local f = io.open(path, "rb")
    if not f then return nil end
    local content = f:read("*a")
    f:close()
    return content
end

--- Atomic-ish write: write to <path>.tmp then rename over <path>.
function M.write_file(path, content)
    local tmp = path .. ".tmp"
    local f, err = io.open(tmp, "wb")
    if not f then return false, tostring(err) end
    f:write(content)
    f:close()
    os.remove(path)
    local ok, rerr = os.rename(tmp, path)
    if not ok then
        -- fall back to a direct write if rename is unavailable
        local f2 = io.open(path, "wb")
        if not f2 then return false, tostring(rerr) end
        f2:write(content)
        f2:close()
        os.remove(tmp)
    end
    return true
end

--- Resolve <mod root> from a script's debug source (".../Mods/PalCommand/Scripts/x.lua").
function M.mod_root(script_source)
    local src = tostring(script_source or ""):gsub("^@", ""):gsub("/", "\\")
    return src:match("^(.*)\\Scripts\\[^\\]+$")
end

return M
