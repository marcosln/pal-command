-- PalCommand :: engine.lua
-- Places legitimate craft orders on production stations.
--
-- Backends (auto-selected, best first):
--
--   native   -- the C++ companion (PalCommand/dlls/main.dll). We hand it the
--               station address, the ChangeRecipe UFunction address, the param
--               offsets (from live reflection) and the recipe bytes via
--               data/native-request.ini, then poke a trigger so it dispatches
--               ChangeRecipe_ServerInternal on the game thread. No player needed.
--
--   replay   -- pure Lua. A persistent POST hook on ChangeRecipe_ServerInternal:
--               whenever a player changes a recipe we borrow that live
--               PalNetArchive, rewrite its bytes, and re-dispatch it to each
--               queued order's target station. Confirmed x1 / x12 / x50.
--
-- The order queue lives in queue.lua / main.lua; this module only emits an order.

local util = require("util")
local bytes = require("bytes")
local discovery = require("discovery")
local json = require("json")
local ok, valid = util.ok, util.valid

local M = {}

local RPC = "/Script/Pal.PalMapObjectConvertItemModel:ChangeRecipe_ServerInternal"
local TRIGGER = "/Script/Pal.PalMapObjectConvertItemModel:GetCurrentRecipeId"

M._flushing = false
M._provider = nil
M._pre_flush = nil        -- called (pcall'd) right before the provider is read
M._on_result = nil
M._hooked = false
M._cfg = { data_dir = nil }
M._layout = nil            -- { rpc_addr, trigger_addr, player_off, archive_off, bytes_off, params_size }
M._req_seq = 0
M._stats = { flushes = 0, placed = 0, failed = 0, lastFlushAt = nil, lastError = nil }

function M.configure(opts)
    for k, v in pairs(opts or {}) do M._cfg[k] = v end
end

-- ---------------------------------------------------------------- reflection: param layout

--- Read the ChangeRecipe param offsets + the trigger address, once.
function M.resolve_layout()
    if M._layout then return M._layout end
    local fn = ok(function() return StaticFindObject(RPC) end)
    local trig = ok(function() return StaticFindObject(TRIGGER) end)
    if not fn then return nil, "ChangeRecipe UFunction not found" end

    local player_off, archive_off
    pcall(function()
        fn:ForEachProperty(function(p)
            local nm = util.fstr(ok(function() return p:GetFName() end))
            local off = ok(function() return p:GetOffset() end)
                or ok(function() return p:GetOffset_Internal() end)
            if nm == "RequestPlayerId" then player_off = off end
            if nm == "Archive" then archive_off = off end
        end)
    end)
    if player_off == nil or archive_off == nil then
        return nil, "could not read param offsets (player=" .. tostring(player_off) .. " archive=" .. tostring(archive_off) .. ")"
    end

    M._layout = {
        rpc_addr = ok(function() return fn:GetAddress() end),
        trigger_addr = trig and ok(function() return trig:GetAddress() end) or nil,
        player_off = player_off,
        archive_off = archive_off,
        bytes_off = 0,                       -- FPalNetArchive.Bytes is the first/only field
        params_size = archive_off + 16,      -- + sizeof(FPalNetArchive) = TArray header
    }
    return M._layout
end

-- ---------------------------------------------------------------- native backend (file IPC)

local function native_paths()
    local d = M._cfg.data_dir
    if not d then return nil end
    return {
        request = d .. "\\native-request.ini",
        response = d .. "\\native-response.ini",
        status = d .. "\\native-status.ini",
    }
end

function M.native_status()
    local p = native_paths()
    if not p then return nil end
    local raw = util.read_file(p.status)
    if not raw then return nil end
    return raw:match("state%s*=%s*([%w%-]+)")
end

function M.native_ready()
    return M.native_status() == "ready" or M.native_status() == "armed" or M.native_status() == "call-armed"
end

local function hex_of(arr)
    local t = {}
    for i = 1, #arr do t[i] = string.format("%02X", arr[i]) end
    return table.concat(t)
end

--- Place one order through the native bridge. Blocks briefly for the response.
local function native_place(station_obj, pid, want)
    local L, lerr = M.resolve_layout()
    if not L then return false, "layout: " .. tostring(lerr) end
    if not L.trigger_addr then return false, "trigger UFunction unavailable" end

    local st_addr = ok(function() return station_obj:GetAddress() end)
    if not st_addr then return false, "station has no address" end

    local p = native_paths()
    M._req_seq = M._req_seq + 1
    local rid = os.time() * 1000 + (M._req_seq % 1000)

    local body = table.concat({
        "[request]",
        "complete=1",
        "request_id=" .. rid,
        "operation=call",
        string.format("trigger_function=%X", L.trigger_addr),
        string.format("station=%X", st_addr),
        string.format("target_function=%X", L.rpc_addr),
        "player_id=" .. math.floor(pid or 0),
        "player_offset=" .. L.player_off,
        "archive_offset=" .. L.archive_off,
        "bytes_offset=" .. L.bytes_off,
        "params_size=" .. L.params_size,
        "archive_hex=" .. hex_of(want),
        "",
    }, "\n")

    local wrote = util.write_file(p.request, body)
    if not wrote then return false, "could not write native-request.ini" end

    -- poke the trigger: fires the bridge's pre-hook on the game thread
    pcall(function() station_obj:GetCurrentRecipeId() end)

    -- wait for the response (bridge polls every ~5ms; the hook may need a tick)
    for _ = 1, 40 do
        local raw = util.read_file(p.response)
        if raw and raw:match("request_id%s*=%s*" .. rid) then
            local status = raw:match("status%s*=%s*([%w%-]+)")
            local detail = raw:match("detail%s*=%s*([^\r\n]*)")
            if status == "called" then return true, "native: " .. tostring(detail) end
            if status and status ~= "call-armed" then return false, "native: " .. tostring(status) .. " " .. tostring(detail) end
        end
        -- second poke in case the first missed the arm window
        pcall(function() station_obj:GetCurrentRecipeId() end)
    end
    return false, "native bridge did not confirm (timeout)"
end

-- ---------------------------------------------------------------- replay backend

-- UE4SS-Lua TArray exposes no Add/RemoveIndex -- the element count cannot be
-- changed from Lua (issue #378 territory). The replay backend can therefore only
-- reuse an incoming archive whose Bytes length already equals the payload we need
-- (i.e. the player crafted a recipe with the same id length). The native bridge
-- has no such limit. Returns ok, detail; detail carries the size mismatch.
local function overwrite_archive(archive, want)
    local arr = archive.Bytes
    local n = ok(function() return arr:GetArrayNum() end)
    if n == nil then return false, "archive.Bytes not readable" end
    if n ~= #want then
        return false, string.format("archive is %d bytes, need %d (craft a recipe whose id is %d chars, or use the native backend)",
            n, #want, math.floor((#want - 11) / 2))
    end
    local applied = pcall(function()
        for i = 1, #want do arr[i] = want[i] end
    end)
    if not applied then return false, "byte write failed" end
    return true
end

local function snapshot_archive(archive)
    local out = {}
    local arr = archive.Bytes
    local n = ok(function() return arr:GetArrayNum() end) or 0
    for i = 1, n do out[i] = ok(function() return arr[i] end) or 0 end
    return out
end

-- ---------------------------------------------------------------- public: place / flush

function M.backend()
    if M.native_ready() then return "native" end
    return "replay"
end

--- @param order { recipe, count, transport, baseId? }
--- @param ctx   { pid, archive? }
--- @return placed:boolean, detail:string, soft:boolean  (soft = not placed but not a real failure -- keep waiting)
function M.place(order, ctx)
    local recipe = order.recipe
    local count = math.max(1, math.floor(tonumber(order.count) or 1))
    local transport = order.transport
    if transport == nil then transport = true end

    local station = discovery.station_for(recipe, order.baseId)
    if not station or not valid(station.obj) then
        return false, "no station makes '" .. tostring(recipe) .. "'"
    end

    local want = bytes.build(recipe, count, transport)
    local pid = (ctx and ctx.pid) or discovery.any_player_id() or 0

    if M.native_ready() then
        local placed, detail = native_place(station.obj, pid, want)
        if placed then return true, string.format("%s x%d @ %s (%s)", recipe, count, station.baseName, detail) end
        if not (ctx and ctx.archive) then return false, detail end
        util.log("native failed (" .. tostring(detail) .. "); trying replay")
    end

    local archive = ctx and ctx.archive
    if archive == nil then
        return false, "replay backend needs a live archive (waiting for a player craft)", true
    end
    local w, werr = overwrite_archive(archive, want)
    if not w then return false, tostring(werr), true end   -- size mismatch: wait for a fitting craft
    local fired = pcall(function() station.obj:ChangeRecipe_ServerInternal(pid, archive) end)
    if not fired then return false, "ChangeRecipe dispatch threw" end
    return true, string.format("replay: %s x%d @ %s", recipe, count, station.baseName)
end

--- Emit every currently-pending order.
function M.flush(ctx)
    if M._flushing then return end
    if type(M._pre_flush) == "function" then pcall(M._pre_flush) end
    if type(M._provider) ~= "function" then return end
    local batch = M._provider()
    if type(batch) ~= "table" or #batch == 0 then return end

    M._flushing = true
    M._stats.flushes = M._stats.flushes + 1
    M._stats.lastFlushAt = os.date("!%Y-%m-%dT%H:%M:%SZ")

    for _, order in ipairs(batch) do
        local placed, detail, soft = false, "?", false
        local guarded = xpcall(function() placed, detail, soft = M.place(order, ctx) end,
            function(e) detail = "exception: " .. tostring(e); return e end)
        if not guarded then placed, soft = false, false end
        if placed then
            M._stats.placed = M._stats.placed + 1
        elseif not soft then
            M._stats.failed = M._stats.failed + 1
            M._stats.lastError = detail
        end
        util.log(string.format("order %s x%s -> %s (%s)",
            tostring(order.recipe), tostring(order.count),
            placed and "OK" or (soft and "WAIT" or "FAIL"), tostring(detail)))
        if type(M._on_result) == "function" then pcall(M._on_result, order, placed, detail, soft) end
    end

    M._flushing = false
end

-- ---------------------------------------------------------------- replay hook

function M.install_hook()
    if M._hooked then return true end
    local installed = pcall(function()
        RegisterHook(RPC,
            function() end,
            function(self, a, b)
                if M._flushing then return end
                pcall(function()
                    local pid = a:get()
                    local archive = b:get()
                    if archive == nil or archive.Bytes == nil then return end
                    local original = snapshot_archive(archive)
                    M.flush({ pid = pid, archive = archive })
                    if #original > 0 then pcall(function() overwrite_archive(archive, original) end) end
                end)
            end)
    end)
    M._hooked = installed
    util.log("replay hook install=" .. tostring(installed))
    return installed
end

function M.stats()
    local s = {}
    for k, v in pairs(M._stats) do s[k] = v end
    s.backend = M.backend()
    s.hooked = M._hooked
    s.nativeStatus = M.native_status()
    s.layout = M._layout
    return s
end

return M
