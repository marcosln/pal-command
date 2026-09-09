-- PalCommand :: engine.lua
-- Places legitimate craft orders on production stations.
--
-- Backends (auto-selected, best first):
--
--   native   -- the C++ companion (PalCommand/dlls/main.dll). We hand it the
--               station address, the ChangeRecipe UFunction address, the param
--               offsets (from live reflection) and the recipe bytes via
--               data/native-request.ini, then poke a trigger so it dispatches
--               ChangeRecipe_ServerInternal on the game thread. Works for ANY
--               recipe on ANY station across every base, and drains the whole
--               queue order-by-order.
--               NEEDS: at least one player connected (AFK is fine -- they never
--               have to craft anything). ChangeRecipe_ServerInternal is a silent
--               no-op with nobody online; orders stay queued and flush the moment
--               someone connects. (Zero-player autonomy is a separate, later goal
--               -- see notes/para-codex-*.md.)
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

--- Resolve a list of "/Script/Pal.Class:Function" paths to their UFunction
--- address (GetAddress) + native Func pointer (UFunction+0xD8 on this build).
--- Diagnostic only -- for disassembling the OnRep_* / work-entry candidates.
function M.resolve_fn_addrs(paths)
    local out = {}
    for _, p in ipairs(paths or {}) do
        local fn = ok(function() return StaticFindObject(p) end)
        local uf = fn and ok(function() return fn:GetAddress() end)
        local flags = fn and ok(function() return fn:GetFunctionFlags() end)
        out[p] = {
            ufunction = uf and string.format("%X", uf) or nil,
            flags = flags and string.format("%X", flags) or nil,
        }
    end
    return out
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

-- Native orders whose recipe the game accepted, kept until that recipe leaves the
-- machine (completed / cancelled). Doubles as the ledger of "recipes we set" so
-- M.cancel() only ever touches our own crafts, never a player's.
M._placed_watch = {}      -- [{ station, recipe, count, target, at, ever_workable, progressed, stalled }]

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

    M._native_pending = {
        rid = rid, station = station_obj, order = order, at = os.time(), pokes = 0,
        expect_recipe = order.recipe,
        expect_count = math.max(1, math.floor(tonumber(order.count) or 1)),
        before = discovery.station_state(station_obj),   -- snapshot to verify against
    }
    poke_trigger(station_obj)
    return true
end

--- Diagnostic (Codex step 3): ask the bridge to walk the r12b chain for a station.
--- Result lands in data/native-inspect.ini. Reaped by M.native_tick().
--- All addresses are exe-base (0x140000000) + rva; Wine = no ASLR = deterministic.
--- Disasm sources: notes/para-codex-03..06.md.
M.INSPECT_OBJA_FN = "142EA97D0"   -- 0x2EA97D0  getObjA(station) module getter
M.CP_SUB_FN       = "142F2D830"   -- 0x2F2D830  objA -> *(objA+0x78) resolver (out param)
M.CP_SENTINEL     = "148BE8AC0"   -- global compared against [elem+0x12C] in virt_2B8
M.CP_VIRT_OFF     = "2B8"         -- vtable slot of virt_2B8 on sub

function M.request_inspect(station_obj)
    if M._native_pending then return false, "busy" end
    local L = M.resolve_layout()
    if not L or not L.trigger_addr then return false, "no layout" end
    local st_addr = ok(function() return station_obj:GetAddress() end)
    if not st_addr then return false, "no station addr" end
    local p = native_paths()
    M._req_seq = M._req_seq + 1
    local rid = os.time() * 1000 + (M._req_seq % 1000)
    local body = table.concat({
        "[request]", "complete=1", "request_id=" .. rid, "operation=inspect",
        string.format("trigger_function=%X", L.trigger_addr),
        string.format("station=%X", st_addr),
        "inspect_fn=" .. M.INSPECT_OBJA_FN,
        "",
    }, "\n")
    if not util.write_file(p.request, body) then return false, "write failed" end
    M._native_pending = { rid = rid, station = station_obj, at = os.time(), pokes = 0, is_inspect = true }
    poke_trigger(station_obj)
    util.log("native inspect requested for station " .. string.format("%X", st_addr))
    return true
end

--- Diagnostic: run the r12b predicate chain for real (read-only) and report the
--- bool + the sub+0x70 assignment array. Result -> data/native-callpred.ini.
function M.request_callpred(station_obj)
    if M._native_pending then return false, "busy" end
    local L = M.resolve_layout()
    if not L or not L.trigger_addr then return false, "no layout" end
    local st_addr = ok(function() return station_obj:GetAddress() end)
    if not st_addr then return false, "no station addr" end
    local p = native_paths()
    M._req_seq = M._req_seq + 1
    local rid = os.time() * 1000 + (M._req_seq % 1000)
    local body = table.concat({
        "[request]", "complete=1", "request_id=" .. rid, "operation=callpred",
        string.format("trigger_function=%X", L.trigger_addr),
        string.format("station=%X", st_addr),
        "objA_fn=" .. M.INSPECT_OBJA_FN,
        "sub_fn=" .. M.CP_SUB_FN,
        "sentinel_addr=" .. M.CP_SENTINEL,
        "virt_off=" .. M.CP_VIRT_OFF,
        "",
    }, "\n")
    if not util.write_file(p.request, body) then return false, "write failed" end
    M._native_pending = { rid = rid, station = station_obj, at = os.time(), pokes = 0, is_callpred = true }
    poke_trigger(station_obj)
    util.log("native callpred requested for station " .. string.format("%X", st_addr))
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
        if pend.is_inspect or pend.is_callpred then
            local kind = pend.is_callpred and "callpred" or "inspect"
            if status == "inspected" or status == "callpred" or (status and status ~= "call-armed") then
                M._native_pending = nil
                util.log("native " .. kind .. ": " .. tostring(detail))
            end
            return
        end
        if status == "called" then
            -- `called` only means ProcessEvent returned. Verify the game actually
            -- applied the recipe -- with an offline/rejected player it is a silent
            -- no-op and we must NOT drop the order.
            M._native_pending = nil
            local now = valid(pend.station) and discovery.station_state(pend.station) or {}
            local before = pend.before or {}
            -- the station was idle at submit (M.place enforces it), so any of these
            -- is an unambiguous "the game took our order":
            local before_idle = (before.recipe == nil or before.recipe == "" or before.recipe == "None")
                and (tonumber(before.requested) or 0) == 0
            local recipe_ok = now.recipe == pend.expect_recipe
            local changed = recipe_ok
                and ((tonumber(now.requested) or 0) >= pend.expect_count
                     or (tonumber(now.remaining) or 0) >= pend.expect_count
                     or now.workable == true)
            if before_idle and changed then
                M._stats.placed = M._stats.placed + 1
                util.log(string.format("native: %s x%s VERIFIED after %d pokes (recipe=%s req=%s workable=%s)",
                    tostring(pend.expect_recipe), tostring(pend.expect_count), pend.pokes,
                    tostring(now.recipe), tostring(now.requested), tostring(now.workable)))
                if type(M._on_result) == "function" then
                    pcall(M._on_result, pend.order, true,
                        string.format("native: verified %s req=%s", tostring(now.recipe), tostring(now.requested)), false)
                end
                -- Track it: our ledger for M.cancel(), and a soft "is it actually
                -- producing?" check (see M.sweep_placed_watch).
                M._placed_watch[#M._placed_watch + 1] = {
                    station = pend.station, recipe = pend.expect_recipe, count = pend.expect_count,
                    target = pend.order and (pend.order.target or pend.order.baseId) or nil,
                    at = os.time(), ever_workable = (now.workable == true), progressed = false, stalled = false,
                }
                -- Queue-drain: if more orders wait and a player is still connected,
                -- submit the next one right away instead of waiting a scan cycle.
                if not M._native_pending and type(M._provider) == "function"
                   and discovery.connected_player_id() then
                    local more = M._provider()
                    if type(more) == "table" and #more > 0 then pcall(M.flush, {}) end
                end
            else
                M._stats.lastError = string.format(
                    "native: ProcessEvent returned but station unchanged (recipe=%s want=%s) -- re-queued",
                    tostring(now.recipe), tostring(pend.expect_recipe))
                util.log(M._stats.lastError)
                if type(M._on_result) == "function" then
                    pcall(M._on_result, pend.order, false, M._stats.lastError, true)   -- SOFT: keep the order
                end
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

    if (pend.is_inspect or pend.is_callpred) and os.time() - pend.at > 20 then
        M._native_pending = nil
        util.log("native " .. (pend.is_callpred and "callpred" or "inspect") .. ": timeout after " .. pend.pokes .. " pokes")
        return
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

local function is_idle(s)
    return (s.recipe == nil or s.recipe == "" or s.recipe == "None")
        and (tonumber(s.requested) or 0) == 0 and not s.workable
end

--- @param order { recipe, count, transport, baseId?, target? }  target = mapId / "key#index" / key
--- @param ctx   { pid, archive? }
--- @return placed:boolean, detail:string, soft:boolean  (soft = not placed but not a real failure -- keep waiting)
function M.place(order, ctx)
    local recipe = order.recipe
    local count = math.max(1, math.floor(tonumber(order.count) or 1))
    local transport = order.transport
    if transport == nil then transport = true end
    local tgt = order.target or order.stationKey

    local candidates = {}
    for _, s in ipairs(discovery.stations_for(recipe, order.baseId, tgt)) do
        if valid(s.obj) then candidates[#candidates + 1] = s end
    end
    if #candidates == 0 then
        return false, "no station makes '" .. tostring(recipe) .. "'"
    end

    -- An explicit machine target is a HARD PIN: use only that machine, and if it's
    -- busy the order WAITS (stays queued, FIFO) -- it never falls through to another.
    -- The one exception: if the target resolves to no live machine (demolished /
    -- typo) we degrade to any capable machine rather than wait forever.
    local pinned = ""
    if tgt and tgt ~= "" then
        local only = {}
        for _, s in ipairs(candidates) do
            if s.mapId == tgt or s.key == tgt or (s.key .. "#" .. tostring(s.index)) == tgt then
                only[#only + 1] = s
            end
        end
        if #only > 0 then candidates = only; pinned = " [pinned]"
        else pinned = " [pin target gone -> any capable]" end
    end

    local want = bytes.build(recipe, count, transport)

    -- ---- native backend: pick the first IDLE candidate and dispatch there ----
    if M.native_ready() then
        if M._native_pending then
            return false, "native: busy with " .. tostring(M._native_pending.expect_recipe), true
        end
        local anyone = discovery.connected_player_id()
        if not anyone then
            return false, "native: no player connected -- order queued (any player online, AFK ok)", true
        end
        local busy_seen
        for _, station in ipairs(candidates) do
            local s0 = discovery.station_state(station.obj)
            if is_idle(s0) then
                -- prefer a guild-matched pid for this station; fall back to any connected
                local pid = select(1, discovery.connected_player_for_station(station.obj)) or anyone
                local okk, serr = native_submit(station.obj, pid, want, order)
                if okk then
                    return false, string.format("native: submitted %s x%d @ %s (station %s)%s pid=%d -- verifying",
                        recipe, count, station.baseName, station.key, pinned, pid), true
                end
                if not (ctx and ctx.archive) then return false, "native: " .. tostring(serr) end
                util.log("native submit failed (" .. tostring(serr) .. "); trying replay")
                break
            else
                busy_seen = string.format("%s@%s(recipe=%s req=%s)", station.key, station.baseName,
                    tostring(s0.recipe), tostring(s0.requested))
            end
        end
        if not (ctx and ctx.archive) then
            return false, string.format("native: %s busy [%s] -- waiting%s",
                pinned ~= "" and "pinned machine" or "all matching stations",
                tostring(busy_seen), pinned), true
        end
    end

    -- ---- replay backend: rewrite a live player archive to an idle candidate ----
    local pid = (ctx and ctx.pid) or 0
    local archive = ctx and ctx.archive
    if archive == nil then
        return false, "replay backend needs a live archive (waiting for a player craft)", true
    end
    for _, station in ipairs(candidates) do
        local r0 = discovery.station_state(station.obj)
        if is_idle(r0) then
            local w, werr = overwrite_archive(archive, want)
            if not w then return false, tostring(werr), true end   -- size mismatch: wait for a fitting craft
            local fired = pcall(function() station.obj:ChangeRecipe_ServerInternal(pid, archive) end)
            if not fired then return false, "ChangeRecipe dispatch threw" end
            local after = discovery.station_state(station.obj)
            if after.recipe == recipe then
                return true, string.format("replay: %s x%d @ %s (verified req=%s)", recipe, count, station.baseName, tostring(after.requested))
            end
            return false, "replay: dispatched but station shows " .. tostring(after.recipe), true
        end
    end
    return false, "replay: all matching stations busy -- need an idle one", true
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
        -- native dispatches one order at a time; once one is in flight, stop --
        -- native_tick() submits the next as soon as this one verifies.
        if M._native_pending then break end
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
                    local pid = a:get()   -- a real, connected RequestPlayerId (this craft)
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

-- ---------------------------------------------------------------- placement watch / cancel

--- Track native orders whose recipe we set. Two jobs:
---  1. the ledger of "recipes WE set" -> M.cancel() only ever touches our own.
---  2. a soft, informational `stalled` flag: the recipe is placed and legit but
---     nothing is actually being produced (no power / no kindling Pal / no fuel /
---     no free work slot). This is NOT a failure -- the game produces it once the
---     base can -- so we never re-queue, never retry; we note it once (log +
---     state.json) so the app can show a soft "waiting on the base" badge.
--- The real "it's producing" signal is `remaining` dropping below the request.
--- `workable` alone isn't enough (a furnace can be workable with no Pal assigned),
--- so it only delays the stalled call, it doesn't clear it. Entries drop when the
--- recipe leaves the machine (completed / cancelled). Pure reads.
function M.sweep_placed_watch()
    if #M._placed_watch == 0 then return end
    local t = os.time()
    for i = #M._placed_watch, 1, -1 do
        local w = M._placed_watch[i]
        local st = valid(w.station) and discovery.station_state(w.station) or nil
        if not st or st.recipe ~= w.recipe then
            table.remove(M._placed_watch, i)
        else
            if st.workable == true then w.ever_workable = true end
            local rem = tonumber(st.remaining)
            if rem and rem > 0 and rem < (w.count or math.huge) then w.progressed = true end
            local age = t - w.at
            -- producing = remaining is going down. give a workable-but-not-yet-moving
            -- station longer (a Pal may still be walking over) before calling it stalled.
            local grace = w.ever_workable and 180 or 90
            if w.progressed then
                w.stalled = false
            elseif age > grace and not w.stalled then
                w.stalled = true
                util.log(string.format(
                    "note: %s x%s @ %s placed but not producing (no power / kindling Pal / fuel / free work slot) -- the base will craft it when it can",
                    tostring(w.recipe), tostring(w.count), tostring(w.target or "?")))
            end
        end
    end
    while #M._placed_watch > 60 do table.remove(M._placed_watch, 1) end
end

--- One-shot: log the param layout + flags of Cancel_ServerInternal so we know how
--- to call it. Cheap; run once at startup.
function M.probe_cancel()
    local fn = ok(function() return StaticFindObject("/Script/Pal.PalMapObjectConvertItemModel:Cancel_ServerInternal") end)
    if not fn then util.log("probe_cancel: UFunction not found"); return end
    local flags = ok(function() return fn:GetFunctionFlags() end)
    local params = {}
    pcall(function()
        fn:ForEachProperty(function(p)
            params[#params + 1] = string.format("%s@%s(%s)",
                util.fstr(ok(function() return p:GetFName() end)),
                tostring(tonumber(ok(function() return p:GetOffset() end)) or "?"),
                util.fstr(ok(function() return p:GetClass():GetFName() end)))
        end)
    end)
    util.log(string.format("probe_cancel: flags=%s params=[%s]",
        flags and string.format("%X", flags) or "?", table.concat(params, ", ")))
end

--- Clear the recipe on one station (cancel an in-flight craft). Tries the plain
--- Cancel_ServerInternal call from Lua (no FPalNetArchive -> no #378 problem).
--- Needs a connected pid, same as ChangeRecipe.
function M.cancel_station(station_obj)
    if not valid(station_obj) then return false, "invalid station" end
    local s0 = discovery.station_state(station_obj)
    if s0.recipe == nil or s0.recipe == "" or s0.recipe == "None" then
        return true, "already idle"
    end
    local pid = select(1, discovery.connected_player_for_station(station_obj))
        or discovery.connected_player_id()
    for _, args in ipairs({ { pid or 0 }, {} }) do
        local fired = pcall(function() station_obj:Cancel_ServerInternal(table.unpack(args)) end)
        if fired then
            for _ = 1, 4 do
                local a = discovery.station_state(station_obj)
                if a.recipe == nil or a.recipe == "" or a.recipe == "None" then
                    return true, "Cancel_ServerInternal(" .. (#args > 0 and "pid" or "") .. ")"
                end
            end
        end
    end
    return false, "Cancel_ServerInternal did not clear (pid=" .. tostring(pid) .. ", recipe=" .. tostring(s0.recipe) .. ")"
end

function M.stats()
    local s = {}
    for k, v in pairs(M._stats) do s[k] = v end
    s.backend = M.backend()
    s.hooked = M._hooked
    s.nativeStatus = M.native_status()
    s.nativeDiag = M.native_diag()
    s.nativePending = M._native_pending and {
        recipe = M._native_pending.expect_recipe, count = M._native_pending.expect_count,
        rid = M._native_pending.rid, pokes = M._native_pending.pokes,
        age = os.time() - M._native_pending.at,
    } or nil
    s.connectedPid = discovery.connected_player_id()
    s.layout = M._layout
    s.placedWatch = {}
    for _, w in ipairs(M._placed_watch) do
        s.placedWatch[#s.placedWatch + 1] = {
            recipe = w.recipe, count = w.count, target = w.target, age = os.time() - w.at,
            producing = w.progressed or false,        -- remaining is going down
            workable = w.ever_workable or false,      -- game says it can be worked
            stalled = w.stalled or false,             -- placed, not producing (no power / Pal / fuel / slot)
        }
    end
    return s
end

return M
