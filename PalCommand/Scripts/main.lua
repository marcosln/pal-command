-- PalCommand :: main.lua
-- Server-side companion for the Pal Command app.
--
--   * publishes whole-server storage inventory + station list as JSON
--   * accepts immediate craft orders and standing rules
--   * places legitimate orders (real recipe, real material cost, a Pal does the work)
--
-- Transport is file-based (data/*.json, fetched/pushed via the host's file API or a
-- Cloudflare Worker). No player inventory, saves, or PBA state is touched.

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
    max_orders_per_flush = util.as_int(ini.maxordersperflush, 8, 1, 64),
    default_transport = util.as_bool(ini.defaulttransporttostorage, true),
    include_guild = util.as_bool(ini.includeguildchest, true),
    max_attempts = util.as_int(ini.maxorderattempts, 6, 1, 100),
    worker_url = ini.workerbaseurl or "",
    server_token = ini.servertoken or "",
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

--- Pull immediate orders the app dropped into orders.json, enqueue, clear the file.
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
    util.write_file(PATHS.orders, "[]")
    if added > 0 then
        util.log("ingested " .. added .. " immediate order(s)")
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
        write_stations(stations)

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

        if engine.backend() == "native" and #S.queue > 0 then
            engine.flush({ pid = discovery.any_player_id() or 0 })
        end

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
local function schedule_loop()
    local delay = CFG.scan_interval * 1000
    local tick = 0
    -- full inventory walk every 4th tick; stations + queue only in between
    local function run_once()
        tick = tick + 1
        local light = (tick % 4 ~= 1)
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function() scan_cycle("interval", light) end)
        else
            scan_cycle("interval", light)
        end
    end
    if type(LoopAsync) == "function" then
        LoopAsync(delay, function() run_once(); return false end)
        util.log("scan loop: LoopAsync every " .. CFG.scan_interval .. "s")
        return
    end
    if type(ExecuteWithDelay) == "function" then
        local function again() run_once(); ExecuteWithDelay(delay, again) end
        ExecuteWithDelay(delay, again)
        util.log("scan loop: ExecuteWithDelay every " .. CFG.scan_interval .. "s")
        return
    end
    util.log("WARN: no repeating timer API; scan runs once at startup only")
end

-- Fast, light loop: pokes the native trigger + reaps the bridge response while a
-- native order is in flight. A no-op (single nil check) when nothing is pending,
-- so it is safe to run at ~1.5 Hz without touching the game thread otherwise.
local function schedule_native_poll()
    if type(engine.native_tick) ~= "function" then return end
    local function tick_once()
        if type(ExecuteInGameThread) == "function" then
            ExecuteInGameThread(function() pcall(engine.native_tick) end)
        else
            pcall(engine.native_tick)
        end
    end
    if type(LoopAsync) == "function" then
        LoopAsync(650, function() tick_once(); return false end)
        util.log("native poll: LoopAsync every 650ms")
    elseif type(ExecuteWithDelay) == "function" then
        local function again() tick_once(); ExecuteWithDelay(650, again) end
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
    engine.install_hook()

    -- one delayed startup scan, then the repeating loop
    if type(MakeActionHandle) == "function" and type(ExecuteInGameThreadWithDelay) == "function" then
        ExecuteInGameThreadWithDelay(MakeActionHandle(), 12000, function() scan_cycle("startup") end)
    elseif type(ExecuteWithDelay) == "function" then
        ExecuteWithDelay(12000, function()
            if ExecuteInGameThread then ExecuteInGameThread(function() scan_cycle("startup") end) else scan_cycle("startup") end
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

local armed = false
local function arm() if not armed then armed = true; pcall(boot) end end
pcall(function() RegisterHook("/Script/Engine.PlayerController:ServerAcknowledgePossession", arm) end)
if ExecuteWithDelay then ExecuteWithDelay(15000, arm) end
