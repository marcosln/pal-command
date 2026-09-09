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

    -- every reflected value must be coerced to a plain number; UE4SS can hand back
    -- wrapper ("TrivialObject") values that error on arithmetic.
    local function rnum(f) return tonumber(ok(f)) end

    local player_off, archive_off, archive_size, max_end
    pcall(function()
        fn:ForEachProperty(function(p)
            local nm = util.fstr(ok(function() return p:GetFName() end))
            local off = rnum(function() return p:GetOffset() end)
                or rnum(function() return p:GetOffset_Internal() end)
            local sz = rnum(function() return p:GetSize() end)
                or rnum(function() return p:GetPropertySize() end)
            if off and sz then
                local e = off + sz
                if not max_end or e > max_end then max_end = e end
            end
            if nm == "RequestPlayerId" and off then player_off = off end
            if nm == "Archive" and off then archive_off = off; archive_size = sz end
        end)
    end)
    if player_off == nil or archive_off == nil then
        return nil, "could not read param offsets (player=" .. tostring(player_off) .. " archive=" .. tostring(archive_off) .. ")"
    end

    -- UFunction ParmsSize: prefer the reflected value, else largest (offset+size),
    -- else archive_off + a generous FPalNetArchive size.
    local parms = rnum(function() return fn:GetParmsSize() end)
        or rnum(function() return fn.ParmsSize end)
        or rnum(function() return fn:GetPropertiesSize() end)
    local params_size = parms or max_end or (archive_off + (archive_size or 16))
    params_size = math.ceil(params_size / 16) * 16

    -- introspect the FPalNetArchive struct itself: its inner fields tell us whether
    -- Bytes really is the only member (and at offset 0).
    local archive_fields = {}
    pcall(function()
        fn:ForEachProperty(function(p)
            if util.fstr(ok(function() return p:GetFName() end)) ~= "Archive" then return end
            local strc = ok(function() return p:GetStruct() end)
                or ok(function() return p.Struct end)
                or ok(function() return p:GetPropertyClass() end)
            if not strc then return end
            strc:ForEachProperty(function(ip)
                archive_fields[#archive_fields + 1] = {
                    name = util.fstr(ok(function() return ip:GetFName() end)),
                    off = rnum(function() return ip:GetOffset() end) or rnum(function() return ip:GetOffset_Internal() end),
                    size = rnum(function() return ip:GetSize() end),
                    class = util.fstr(ok(function() return ip:GetClass():GetFName() end)),
                }
            end)
        end)
    end)

    M._layout = {
        rpc_addr = ok(function() return fn:GetAddress() end),
        trigger_addr = trig and ok(function() return trig:GetAddress() end) or nil,
        player_off = player_off,
        archive_off = archive_off,
        archive_size = archive_size,
        bytes_off = 0,                       -- FPalNetArchive.Bytes (TArray) is the first field
        params_size = params_size,
        parms_reflected = parms,
        max_end = max_end,
        archive_fields = archive_fields,
    }
    util.log("native layout resolved: " .. json.encode(M._layout))
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

function M.native_status_raw()
    local p = native_paths()
    if not p then return nil end
    return util.read_file(p.status)
end

function M.native_status()
    local raw = M.native_status_raw()
    if not raw then return nil end
    return raw:match("state%s*=%s*([%w%-]+)")
end

--- Bridge counters from native-status.ini (arms / hook_fires / execs / trigger).
function M.native_diag()
    local raw = M.native_status_raw()
    if not raw then return nil end
    local d = {}
    for k, v in raw:gmatch("([%w_]+)%s*=%s*([^\r\n]*)") do d[k] = v end
    return d
end

function M.native_ready()
    local s = M.native_status()
    return s == "ready" or s == "armed" or s == "call-armed" or s == "executing" or s == "done"
end

local function hex_of(arr)
    local t = {}
    for i = 1, #arr do t[i] = string.format("%02X", arr[i]) end
    return table.concat(t)
end

-- One native order can be in flight at a time. The bridge arms on the request
-- file, then needs the trigger UFunction (GetCurrentRecipeId) invoked ON THE GAME
-- THREAD to run ProcessEvent. We must not block the game thread waiting, so the
-- request is *submitted* here and *reaped* by M.native_tick() on a fast timer.
M._native_pending = nil   -- { rid, station, order, at, pokes }

local function poke_trigger(station_obj)
    pcall(function() if station_obj then station_obj:GetCurrentRecipeId() end end)
end

--- Submit one order to the bridge. Returns true if the request was written.
local function native_submit(station_obj, pid, want, order)
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

    if not util.write_file(p.request, body) then return false, "could not write native-request.ini" end

    if not M._layout_logged then
        M._layout_logged = true
        util.log(string.format("native layout: player_off=%s archive_off=%s archive_size=%s params_size=%s parms_reflected=%s max_end=%s | pid=%s",
            tostring(L.player_off), tostring(L.archive_off), tostring(L.archive_size), tostring(L.params_size),
            tostring(L.parms_reflected), tostring(L.max_end), tostring(pid)))
    end

    M._native_pending = { rid = rid, station = station_obj, order = order, at = os.time(), pokes = 0 }
    poke_trigger(station_obj)
    return true
end

--- Poke the trigger + reap the bridge response. Cheap; safe to call ~1x/sec from
--- the game thread. Resolves M._native_pending via M._on_result.
function M.native_tick()
    if M._flushing then return end
    local pend = M._native_pending
    if not pend then return end
    local p = native_paths()
    if not p then return end

    pend.pokes = pend.pokes + 1
    poke_trigger(valid(pend.station) and pend.station or nil)

    local raw = util.read_file(p.response)
    if raw and raw:match("request_id%s*=%s*" .. pend.rid) then
        local status = raw:match("status%s*=%s*([%w%-]+)")
        local detail = raw:match("detail%s*=%s*([^\r\n]*)")
        if status == "called" then
            M._native_pending = nil
            M._stats.placed = M._stats.placed + 1
            util.log(string.format("native: %s x%s placed after %d pokes (%s)",
                tostring(pend.order.recipe), tostring(pend.order.count), pend.pokes, tostring(detail)))
            if type(M._on_result) == "function" then
                pcall(M._on_result, pend.order, true, "native: " .. tostring(detail), false)
            end
            return
        elseif status and status ~= "call-armed" then
            M._native_pending = nil
            M._stats.failed = M._stats.failed + 1
            M._stats.lastError = "native: " .. tostring(status) .. " " .. tostring(detail)
            if type(M._on_result) == "function" then
                pcall(M._on_result, pend.order, false, M._stats.lastError, false)
            end
            return
        end
    end

    if os.time() - pend.at > 25 then
        local order = pend.order
        M._native_pending = nil
        M._stats.failed = M._stats.failed + 1
        M._stats.lastError = "native: no confirm after " .. pend.pokes .. " pokes / " .. (os.time() - pend.at) .. "s"
        util.log(M._stats.lastError)
        if type(M._on_result) == "function" then
            pcall(M._on_result, order, false, M._stats.lastError, false)
        end
    end
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

--- Best RequestPlayerId for an autonomous order: a pid seen this session, then a
--- persisted one, then a live probe. nil if nothing found (caller falls back to 0).
function M.acting_pid()
    if M._last_real_pid and M._last_real_pid ~= 0 then return M._last_real_pid end
    if M._cfg.data_dir then
        local raw = util.read_file(M._cfg.data_dir .. "\\last-pid.txt")
        local n = raw and tonumber((raw:gsub("%s", "")))
        if n and n ~= 0 then M._last_real_pid = math.floor(n); return M._last_real_pid end
    end
    local probed = discovery.any_player_id()
    if probed and probed ~= 0 then return probed end
    return nil
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
    -- note: 0 is truthy in Lua, so treat a 0/absent ctx pid as "resolve one"
    local pid = ctx and ctx.pid
    if not pid or pid == 0 then pid = M.acting_pid() end
    pid = pid or 0

    if M.native_ready() then
        if M._native_pending then
            -- one native order in flight; M.native_tick() will clear it
            return false, "native: bridge busy with " .. tostring(M._native_pending.order and M._native_pending.order.recipe), true
        end
        local okk, serr = native_submit(station.obj, pid, want, order)
        if okk then
            return false, string.format("native: submitted %s x%d @ %s (awaiting game thread)", recipe, count, station.baseName), true
        end
        if not (ctx and ctx.archive) then return false, "native: " .. tostring(serr) end
        util.log("native submit failed (" .. tostring(serr) .. "); trying replay")
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
                    -- remember a real RequestPlayerId for autonomous (native) orders
                    if pid and tonumber(pid) and tonumber(pid) ~= 0 then
                        M._last_real_pid = math.floor(tonumber(pid))
                        if M._cfg.data_dir then
                            pcall(function() util.write_file(M._cfg.data_dir .. "\\last-pid.txt", tostring(M._last_real_pid)) end)
                        end
                    end
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
    s.nativeDiag = M.native_diag()
    s.nativePending = M._native_pending and {
        recipe = M._native_pending.order and M._native_pending.order.recipe,
        rid = M._native_pending.rid, pokes = M._native_pending.pokes,
        age = os.time() - M._native_pending.at,
    } or nil
    s.layout = M._layout
    return s
end

return M
