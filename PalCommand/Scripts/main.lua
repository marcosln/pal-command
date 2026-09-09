-- PalCommand :: main.lua
-- Server-side companion for the Pal Command app.
--
--   * publishes whole-server storage inventory + station list as JSON
--   * accepts immediate craft orders and standing rules
--   * places legitimate orders (real recipe, real material cost, a Pal does the work)
--
-- Transport is file-based (data/*.json, fetched/pushed via the host's file API or a
-- Cloudflare Worker). No player inventory, world saves, or other mods' state is touched.

local util = require("util")
local json = require("json")
local discovery = require("discovery")
local engine = require("engine")
local rules = require("rules")

local SOURCE = tostring((debug.getinfo(1, "S") or {}).source or "")
local ROOT = util.mod_root(SOURCE)
if not ROOT then
    print("[PalCommand] FATAL: cannot resolve mod root from " .. SOURCE .. "\n")
    return
end

local PATHS = {
    config = ROOT .. "\\config.ini",
    data = ROOT .. "\\data",
    log = ROOT .. "\\data\\palcommand.log",
    inventory = ROOT .. "\\data\\inventory.json",
    stations = ROOT .. "\\data\\stations.json",
    orders = ROOT .. "\\data\\orders.json",
    rules = ROOT .. "\\data\\rules.json",
    queue = ROOT .. "\\data\\queue.json",
    state = ROOT .. "\\data\\state.json",
}
util.set_logfile(PATHS.log)

-- ---------------------------------------------------------------- config

local ini = util.parse_ini(PATHS.config)
local CFG = {
    enabled = util.as_bool(ini.enabled, true),
    scan_interval = util.as_int(ini.scanintervalseconds, 20, 5, 3600),
    idle_scan_interval = util.as_int(ini.idlescanintervalseconds, 120, 10, 7200),
    max_orders_per_flush = util.as_int(ini.maxordersperflush, 8, 1, 64),
    default_transport = util.as_bool(ini.defaulttransporttostorage, true),
    include_guild = util.as_bool(ini.includeguildchest, true),
    max_attempts = util.as_int(ini.maxorderattempts, 6, 1, 100),
    worker_url = ini.workerbaseurl or "",
    server_token = ini.servertoken or "",
    replay_hook = util.as_bool(ini.enablereplayhook, true),
    debug_diag = util.as_bool(ini.debugdiagnostics, false),   -- RE diagnostics one-shots (zero-player research)
}

-- ---------------------------------------------------------------- state

local S = {
    queue = {},                 -- pending orders (persisted)
    recent = {},                -- last N placed/failed (ring)
    lastScan = nil,
    lastError = nil,
    scanning = false,
    handle_loop = nil,
    seq = 0,
    lastOrderAt = 0,            -- os.time() of the last ingested order / cancel (drives scan pacing)
}

local function persist_queue()
    util.write_file(PATHS.queue, json.encode(S.queue))
end

local function load_queue()
    local raw = util.read_file(PATHS.queue)
    local v = raw and json.decode(raw)
    if type(v) == "table" then
        S.queue = {}
        for _, o in ipairs(v) do
            if type(o) == "table" and o.recipe then S.queue[#S.queue + 1] = o end
        end
    end
end

local function push_recent(entry)
    entry.at = os.date("!%Y-%m-%dT%H:%M:%SZ")
    S.recent[#S.recent + 1] = entry
    while #S.recent > 40 do table.remove(S.recent, 1) end
end

-- ---------------------------------------------------------------- queue ops

local function queue_has(recipe, source)
    for _, o in ipairs(S.queue) do
        if o.recipe == recipe and (source == nil or o.source == source) then return true end
    end
    return false
end

local function inflight_for(recipe, stations)
    local total = 0
    for _, o in ipairs(S.queue) do
        if o.recipe == recipe then total = total + (tonumber(o.count) or 0) end
    end
    for _, st in ipairs(stations or {}) do
        if st.state.recipe == recipe then total = total + st.state.remaining end
    end
    return total
end

--- Cancel by selector: an order id, a recipe id, a target mapId, or "all"/true.
-- Drops matching pending orders from the queue, aborts a matching in-flight native
-- submit, and clears the recipe on matching machines. Safety: "all" / by-recipe /
-- by-id only ever touch recipes WE set (engine._placed_watch), never a player's.
-- An explicit mapId is a deliberate "clear this one machine" -- honoured even if
-- it isn't in our ledger (e.g. after a restart). Returns {queued, placed}.
local function cancel_orders(sel)
    if sel == true then sel = "all" end
    sel = tostring(sel or "all")
    local all = (sel == "" or sel == "all" or sel == "*")
    local res = { queued = 0, placed = 0 }
    local is_mapid = sel:match("^%x+$") ~= nil and #sel >= 16

    local function hit(o)
        return all or o.id == sel or o.recipe == sel or o.target == sel
    end

    for i = #S.queue, 1, -1 do
        local q = S.queue[i]
        if hit(q) then
            push_recent({ recipe = q.recipe, count = q.count, result = "cancelled", detail = "removed from queue", source = q.source })
            table.remove(S.queue, i); res.queued = res.queued + 1
        end
    end

    local pend = engine._native_pending
    if pend and (all or (pend.order and hit(pend.order)) or pend.expect_recipe == sel) then
        engine._native_pending = nil
        res.queued = res.queued + 1
    end

    local cleared = {}   -- station objs already cleared this call
    for i = #(engine._placed_watch or {}), 1, -1 do
        local w = engine._placed_watch[i]
        local m = all or w.recipe == sel or w.target == sel
        if not m and is_mapid then
            local id = discovery.station_identity and discovery.station_identity(w.station)
            m = id and id.mapId == sel
        end
        if m then
            local okc, how = engine.cancel_station(w.station)
            cleared[tostring(w.station)] = true
            push_recent({ recipe = w.recipe, count = w.count,
                result = okc and "cancelled" or "cancel-failed", detail = tostring(how) })
            util.log(string.format("cancel %s @ %s -> %s (%s)", tostring(w.recipe), tostring(w.target), tostring(okc), tostring(how)))
            table.remove(engine._placed_watch, i)
            if okc then res.placed = res.placed + 1 end
        end
    end

    -- explicit mapId not in our ledger: clear that one machine directly
    if is_mapid and res.placed == 0 then
        for _, s in ipairs(discovery.stations()) do
            if s.mapId == sel and not cleared[tostring(s.obj)]
               and s.state.recipe and s.state.recipe ~= "None" and s.state.recipe ~= "" then
                local okc, how = engine.cancel_station(s.obj)
                push_recent({ recipe = s.state.recipe, count = s.state.requested,
                    result = okc and "cancelled" or "cancel-failed", detail = "explicit mapId: " .. tostring(how) })
                util.log(string.format("cancel (explicit mapId) %s @ %s -> %s (%s)", tostring(s.state.recipe), sel, tostring(okc), tostring(how)))
                if okc then res.placed = res.placed + 1 end
            end
        end
    end

    if res.queued + res.placed > 0 then persist_queue() end
    return res
end

--- Pull immediate orders the app dropped into orders.json, enqueue, clear the file.
-- A list entry with a `cancel` field (or action="cancel") is a cancel directive,
-- not an order: `{ "cancel": "<order id | recipe | target mapId>" }` or `{ "cancel": true }`.
local function ingest_orders()
    local raw = util.read_file(PATHS.orders)
    if not raw or raw:match("^%s*$") then return end
    local list = json.decode(raw)
    if type(list) ~= "table" then
        util.write_file(PATHS.orders, "[]")
        return
    end
    local added = 0
    for _, raw_order in ipairs(list) do
        if type(raw_order) == "table" and (raw_order.cancel ~= nil or raw_order.action == "cancel") then
            local sel = raw_order.cancel
            if sel == nil then sel = raw_order.target or raw_order.recipe or raw_order.id end
            local r = cancel_orders(sel)
            util.log(string.format("cancel '%s' -> %d queued, %d placed", tostring(sel), r.queued, r.placed))
            S.lastOrderAt = os.time()
        else
            local o = rules.normalize_order(raw_order)
            if o then
                local dup = false
                for _, q in ipairs(S.queue) do if q.id == o.id then dup = true end end
                if not dup then
                    o.attempts = 0
                    S.queue[#S.queue + 1] = o
                    added = added + 1
                end
            end
        end
    end
    util.write_file(PATHS.orders, "[]")
    if added > 0 then
        util.log("ingested " .. added .. " immediate order(s)")
        S.lastOrderAt = os.time()
        persist_queue()
    end
end

--- Derive orders from standing rules and enqueue any that are missing.
local function apply_rules(totals, stations)
    local raw = util.read_file(PATHS.rules)
    local rule_list = raw and json.decode(raw)
    if type(rule_list) ~= "table" then return end

    local derived = rules.evaluate(rule_list, totals, function(r) return inflight_for(r, stations) end)
    local added = 0
    for _, o in ipairs(derived) do
        if not queue_has(o.recipe, o.source) then
            o.id = o.source .. "@" .. os.time()
            o.attempts = 0
            S.queue[#S.queue + 1] = o
            added = added + 1
        end
    end
    if added > 0 then
        util.log("rules enqueued " .. added .. " order(s)")
        persist_queue()
    end
end

-- ---------------------------------------------------------------- engine wiring

engine._provider = function()
    local batch = {}
    for _, o in ipairs(S.queue) do
        batch[#batch + 1] = o
        if #batch >= CFG.max_orders_per_flush then break end
    end
    return batch
end

engine._on_result = function(order, placed, detail, soft)
    if placed then
        for i = #S.queue, 1, -1 do
            if S.queue[i] == order then table.remove(S.queue, i) end
        end
        push_recent({ recipe = order.recipe, count = order.count, result = "placed", detail = detail, source = order.source })
    elseif soft then
        order.lastError = detail   -- waiting on a fitting craft / an archive; not a failed attempt
    else
        order.attempts = (order.attempts or 0) + 1
        order.lastError = detail
        if order.attempts >= CFG.max_attempts then
            for i = #S.queue, 1, -1 do
                if S.queue[i] == order then table.remove(S.queue, i) end
            end
            push_recent({ recipe = order.recipe, count = order.count, result = "dropped", detail = detail, source = order.source })
            util.log("order dropped after " .. order.attempts .. " attempts: " .. tostring(detail))
        end
    end
    persist_queue()
end

-- ---------------------------------------------------------------- publish

local function write_state()
    S.seq = S.seq + 1
    local st = engine.stats()
    util.write_file(PATHS.state, json.encode({
        schemaVersion = 2,
        generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        sequence = S.seq,
        enabled = CFG.enabled,
        backend = st.backend,
        hookInstalled = st.hooked,
        lastScan = S.lastScan,
        lastError = S.lastError or st.lastError,
        queueDepth = #S.queue,
        queue = S.queue,
        recent = S.recent,
        engine = st,
        playerIdProbe = (st.backend == "native" and discovery.player_id_probe) and discovery.player_id_probe() or nil,
        note = st.backend == "replay"
            and "replay backend: queued orders apply next time any player changes a recipe"
            or "native backend: orders apply within one scan interval",
    }))
end

local function write_stations(list)
    list = list or discovery.stations()
    local rows = {}
    for _, s in ipairs(list) do
        rows[#rows + 1] = {
            key = s.key, name = s.name, baseId = s.baseId, baseName = s.baseName,
            recipes = s.recipes, state = s.state,
            mapId = s.mapId, pos = s.pos, machineType = s.machineType, index = s.index,
        }
    end
    util.write_file(PATHS.stations, json.encode({
        schemaVersion = 1,
        generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        stations = rows,
    }))
end

-- ---------------------------------------------------------------- scan cycle

-- One scan: read inventory + stations, publish JSON, apply rules. Runs on the
-- game thread (UE reflection requires it), so keep it lean -- discovery.stations()
-- is fetched once and shared. `light` skips the full 80-container inventory walk.
local function scan_cycle(reason, light)
    if not CFG.enabled or S.scanning then return end
    S.scanning = true
    S.lastScanAt = os.time()
    local success, err = xpcall(function()
        local stations = discovery.stations()
        local recent_n0 = #S.recent

        local totals
        if light and S.lastTotals then
            totals = S.lastTotals
        else
            local inv = discovery.inventory(CFG.include_guild)
            util.write_file(PATHS.inventory, json.encode(inv))
            totals = inv.totals or {}
            S.lastTotals = totals
            S.lastError = (inv.diagnostics and inv.diagnostics.complete == false)
                and ("inventory partial: " .. tostring((inv.diagnostics.errors or {})[1])) or nil
        end

        ingest_orders()
        apply_rules(totals, stations)

        -- native orders need a connected player; flush only then (replay flushes
        -- itself from the craft hook). Orders otherwise just wait in the queue.
        if engine.backend() == "native" and #S.queue > 0 and discovery.connected_player_id() then
            engine.flush({})
        end

        -- track recipes we set (ledger for cancel) + flag any placed-but-not-producing
        -- yet (no power / Pal / fuel) as a soft status, never a failure.
        if type(engine.sweep_placed_watch) == "function" then pcall(engine.sweep_placed_watch) end

        -- publish stations. If an order was placed/cancelled this cycle, re-read
        -- so it shows immediately (not one scan late); otherwise reuse the snapshot.
        if #S.recent ~= recent_n0 then write_stations() else write_stations(stations) end

        S.lastScan = os.date("!%Y-%m-%dT%H:%M:%SZ")
        write_state()
    end, function(e) return debug.traceback(tostring(e), 2) end)
    S.scanning = false
    if not success then
        S.lastError = tostring(err)
        util.log("scan_cycle error: " .. tostring(err))
        pcall(write_state)
    end
end

-- ---------------------------------------------------------------- lifecycle

-- Periodic scan. `ExecuteInGameThreadWithDelay` is one-shot and does not re-fire
-- on a headless server in this build, so drive the loop with `LoopAsync` (a real
-- repeating async timer) and hop to the game thread per tick. No game-thread
-- hooks trigger scans -- doing heavy reflection from a storage/finish-work hook
-- stalls the game thread and blocks joins.
-- Dynamic pacing: a short LoopAsync tick decides each time whether a heavy scan
-- (the game-thread reflection pass) is actually due. ACTIVE cadence when there's
-- queue activity or a fresh order; IDLE cadence otherwise -- fewer game-thread
-- passes when nobody's using the app, so it competes less with the game (e.g. the
-- map-open hitch). The tick itself is cheap: a couple of Lua reads + one tiny file
-- stat, never a game-thread hop unless a scan is due.
local function schedule_loop()
    local TICK = math.min(10, CFG.scan_interval)          -- loop granularity (s)
    local ACTIVE = math.max(TICK, CFG.scan_interval)
    local IDLE = math.max(ACTIVE, CFG.idle_scan_interval)
    local last_heavy = 0                                  -- os.time() of the last heavy scan
    local heavy_n = 0

    local function orders_waiting()
        local raw = util.read_file(PATHS.orders)
        return raw ~= nil and raw:match("[^%s%[%]]") ~= nil   -- non-empty and not just "[ ]"
    end

    local function tick_fn()
        local now = os.time()
        local active = (#S.queue > 0) or engine._native_pending
            or (now - (S.lastOrderAt or 0) < math.max(150, ACTIVE * 3))
            or orders_waiting()
        if now - last_heavy < (active and ACTIVE or IDLE) then return end
        last_heavy = now
        heavy_n = heavy_n + 1
        local light = (heavy_n % 4 ~= 1)                  -- full inventory every 4th heavy scan
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function() scan_cycle("interval", light) end)
        else
            scan_cycle("interval", light)
        end
    end

    if type(LoopAsync) == "function" then
        LoopAsync(TICK * 1000, function() pcall(tick_fn); return false end)
        util.log(string.format("scan loop: dynamic (tick %ds, active %ds, idle %ds)", TICK, ACTIVE, IDLE))
        return
    end
    if type(ExecuteWithDelay) == "function" then
        local function again() pcall(tick_fn); ExecuteWithDelay(TICK * 1000, again) end
        ExecuteWithDelay(TICK * 1000, again)
        util.log(string.format("scan loop: dynamic via ExecuteWithDelay (tick %ds)", TICK))
        return
    end
    util.log("WARN: no repeating timer API; scan runs once at startup only")
end

-- Pokes the native trigger + reaps the bridge response while a native order is in
-- flight. When nothing is pending the async callback only reads one Lua field and
-- returns -- it never hops to the game thread, so an idle server pays nothing.
local function schedule_native_poll()
    if type(engine.native_tick) ~= "function" then return end
    local function pump()
        if not engine._native_pending then return end
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function() pcall(engine.native_tick) end)
        else
            pcall(engine.native_tick)
        end
    end
    if type(LoopAsync) == "function" then
        LoopAsync(650, function() pump(); return false end)
        util.log("native poll: LoopAsync every 650ms (game thread only while pending)")
    elseif type(ExecuteWithDelay) == "function" then
        local function again() pump(); ExecuteWithDelay(650, again) end
        ExecuteWithDelay(650, again)
    end
end

--- Pull immediate orders (cheap: one file read). Called before every flush.
local function refresh_orders()
    return pcall(ingest_orders)
end

local function boot()
    util.log(string.format("PalCommand loading | enabled=%s scan=%ds maxFlush=%d guild=%s",
        tostring(CFG.enabled), CFG.scan_interval, CFG.max_orders_per_flush, tostring(CFG.include_guild)))
    if not CFG.enabled then
        util.write_file(PATHS.state, json.encode({ enabled = false, note = "disabled by config.ini" }))
        return
    end

    load_queue()
    engine.configure({ data_dir = PATHS.data })
    engine._pre_flush = refresh_orders        -- every player craft re-reads orders.json first
    if CFG.replay_hook then engine.install_hook() else util.log("replay hook DISABLED by config") end

    -- one delayed startup scan, then the repeating loop
    if type(MakeActionHandle) == "function" and type(ExecuteInGameThreadWithDelay) == "function" then
        ExecuteInGameThreadWithDelay(MakeActionHandle(), 12000, function() scan_cycle("startup") end)
    elseif type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(12000, function()
            if ExecuteInGameThread then ExecuteInGameThread(function() scan_cycle("startup") end) else scan_cycle("startup") end
        end)
    end

    -- one-shot: learn the Cancel_ServerInternal signature (needed for cancelling a
    -- craft the game already accepted). Cheap reflection, logs once.
    if type(engine.probe_cancel) == "function" and type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(14000, function()
            if ExecuteInGameThread then ExecuteInGameThread(function() pcall(engine.probe_cancel) end)
            else pcall(engine.probe_cancel) end
        end)
    end

    -- Optional one-shot RE diagnostics (zero-player autonomy research). Off unless
    -- config DebugDiagnostics=true. The connected-player product does not need them.
    if CFG.debug_diag and type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(20000, function()
            local function go()
                local okk, api = pcall(discovery.dump_convert_api)
                if okk then
                    util.write_file(ROOT .. "\\data\\convert-api.json", json.encode(api))
                    util.log("convert-api dumped: " .. #api .. " entries")
                end
                if engine.request_callpred then
                    local st = discovery.station_for("Pal_crystal_S")
                    if st and st.obj then engine.request_callpred(st.obj) end
                end
            end
            if ExecuteInGameThread then ExecuteInGameThread(go) else go() end
        end)
    end
    schedule_loop()
    schedule_native_poll()
end

-- Small console surface for debugging.
_G.PalCommand = _G.PalCommand or {}
_G.PalCommand.scan_now = function() scan_cycle("manual") end
_G.PalCommand.pull = function() ingest_orders(); return #S.queue end
_G.PalCommand.backend = function() return engine.backend() end
_G.PalCommand.queue = function() return S.queue end
_G.PalCommand.enqueue = function(o)
    local n = rules.normalize_order(o)
    if n then n.attempts = 0; S.queue[#S.queue + 1] = n; persist_queue(); return true end
    return false
end
_G.PalCommand.cancel = function(sel) return cancel_orders(sel) end
_G.PalCommand.watch = function() return engine._placed_watch end

local armed = false
local function arm() if not armed then armed = true; pcall(boot) end end
pcall(function() RegisterHook("/Script/Engine.PlayerController:ServerAcknowledgePossession", arm) end)
if ExecuteWithDelay then ExecuteWithDelay(15000, arm) end
