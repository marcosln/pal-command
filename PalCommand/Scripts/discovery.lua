-- PalCommand :: discovery.lua
-- Read-only reflection over the live game:
--   * whole-server storage inventory (all base chests + guild chest)
--   * production stations (PalMapObjectConvertItemModel: crushers, furnaces, ...)
--
-- The inventory path mirrors PalworldMobileBridge, which is known-good on this
-- server. Nothing here mutates game state.

local util = require("util")
local ok, valid, fstr = util.ok, util.valid, util.fstr

local M = {}

-- ---------------------------------------------------------------- helpers

local function unwrap(v)
    if v == nil then return nil end
    local r = ok(function() return v:get() end)
    if r ~= nil then return r end
    return v
end

local function full_name(o)
    return ok(function() return o:GetFullName() end) or tostring(o)
end

local function not_default(o)
    return not full_name(o):find("Default__", 1, true)
end

-- ---------------------------------------------------------------- bases

local function base_id(base)
    local id = ok(function() return base:GetId() end)
    if id ~= nil then
        local a = ok(function() return tonumber(id.A) end)
        local b = ok(function() return tonumber(id.B) end)
        local c = ok(function() return tonumber(id.C) end)
        local d = ok(function() return tonumber(id.D) end)
        if a and b and c and d then
            return string.format("%08x-%08x-%08x-%08x", a & 0xffffffff, b & 0xffffffff, c & 0xffffffff, d & 0xffffffff)
        end
    end
    return full_name(base)
end

local function base_name(base, ordinal)
    local name = ok(function() return base:GetBaseCampName():ToString() end)
    if type(name) == "string" then
        name = name:gsub("^%s*(.-)%s*$", "%1")
        if name ~= "" then return name end
    end
    return "Base " .. tostring(ordinal)
end

function M.bases()
    local result = {}
    for _, b in ipairs(util.find_all("PalBaseCampModel")) do
        if valid(b) and not_default(b) then result[#result + 1] = b end
    end
    table.sort(result, function(l, r) return base_id(l) < base_id(r) end)
    return result
end

M.base_id = base_id
M.base_name = base_name

-- ---------------------------------------------------------------- inventory

local function storage_module_for(base)
    local found
    pcall(function()
        base.ModuleArray:ForEach(function(_, mv)
            local m = unwrap(mv)
            if valid(m) and full_name(m):find("PalBaseCampModuleItemStorage", 1, true) then
                found = m
            end
        end)
    end)
    return found
end

local function read_container(container)
    local n = ok(function() return container:Num() end)
    n = tonumber(n)
    if not n or n < 0 or n > 100000 then return nil, "slot count unavailable" end

    local items = {}
    for i = 0, n - 1 do
        local slot = unwrap(ok(function() return container:Get(i) end))
        if valid(slot) then
            local count = tonumber(ok(function() return slot:GetStackCount() end))
            if count and count > 0 then
                local item_id = unwrap(ok(function() return slot:GetItemId() end))
                local static_id = item_id and unwrap(ok(function() return item_id.StaticId end))
                local id = static_id and fstr(static_id) or ""
                if id ~= "" and id ~= "None" then
                    items[id] = (items[id] or 0) + math.floor(count)
                end
            end
        end
    end
    return items
end
M.read_container = read_container

--- Full inventory snapshot.
-- @return snapshot table  { schemaVersion, generatedAt, scope, totals={id=count},
--                           bases=[{id,name,containers=[{id,name,kind,items}]}],
--                           guildChest={available,items}, diagnostics={...} }
function M.inventory(include_guild)
    local snap = {
        schemaVersion = 2,
        generatedAt = os.date("!%Y-%m-%dT%H:%M:%SZ"),
        scope = "server_storage_only_no_player_inventory",
        totals = {},
        bases = {},
        guildChest = { available = false, items = {} },
        diagnostics = { baseCount = 0, containerCount = 0, errorCount = 0, errors = {}, complete = true },
    }
    local function err(msg)
        local d = snap.diagnostics
        d.errorCount = d.errorCount + 1
        d.complete = false
        if #d.errors < 25 then d.errors[#d.errors + 1] = tostring(msg) end
    end
    local function add_total(items)
        for id, c in pairs(items) do snap.totals[id] = (snap.totals[id] or 0) + c end
    end

    local manager = util.find_first("PalItemContainerManager")
    if not valid(manager) then
        err("PalItemContainerManager unavailable")
        return snap
    end

    local guild_done = false
    local bases = M.bases()
    for index, base in ipairs(bases) do
        local row = { id = base_id(base), name = base_name(base, index), containers = {} }
        local storage = storage_module_for(base)
        if not valid(storage) then
            err(row.name .. ": storage module unavailable")
        else
            local seen = {}
            local ci = 0
            local list_ok = pcall(function()
                storage.ContainerInfos:ForEach(function(_, iv)
                    local info = unwrap(iv)
                    if info == nil then return end
                    local cont = ok(function() return manager:GetContainer(info.ContainerIdCache) end)
                    if not valid(cont) then
                        err(row.name .. ": a container did not resolve")
                        return
                    end
                    local key = full_name(cont)
                    if seen[key] then return end
                    seen[key] = true
                    ci = ci + 1
                    local items, rerr = read_container(cont)
                    local crow = { id = key, name = "Chest " .. ci, kind = "base_storage", items = items or {}, readable = items ~= nil }
                    if items then add_total(items) else err(row.name .. " chest " .. ci .. ": " .. tostring(rerr)) end
                    row.containers[#row.containers + 1] = crow
                    snap.diagnostics.containerCount = snap.diagnostics.containerCount + 1
                end)
            end)
            if not list_ok then err(row.name .. ": container list unreadable") end

            if include_guild and not guild_done then
                local ginfo = unwrap(ok(function() return storage.GuildContainerInfo end))
                local gcont = ginfo and ok(function() return manager:GetContainer(ginfo.ContainerIdCache) end)
                if valid(gcont) then
                    guild_done = true
                    local items = read_container(gcont)
                    snap.guildChest = { available = true, id = full_name(gcont), items = items or {} }
                    if items then add_total(items) end
                    snap.diagnostics.containerCount = snap.diagnostics.containerCount + 1
                end
            end
        end
        snap.bases[#snap.bases + 1] = row
    end
    snap.diagnostics.baseCount = #snap.bases
    if #snap.bases == 0 then err("no base camps discovered") end
    return snap
end

-- ---------------------------------------------------------------- stations

local function station_recipes(st)
    local out = {}
    pcall(function()
        local arr = st.RecipeIds
        local n = ok(function() return arr:GetArrayNum() end) or 0
        for i = 1, n do
            local r = fstr(arr[i])
            if r ~= "" and r ~= "None" then out[#out + 1] = r end
        end
    end)
    return out
end
M.station_recipes = station_recipes

function M.station_state(st)
    return {
        recipe = fstr(ok(function() return st.CurrentRecipeId end)),
        requested = tonumber(ok(function() return st.RequestedProductNum end)) or 0,
        remaining = tonumber(ok(function() return st.RemainProductNum end)) or 0,
        workable = ok(function() return st.bIsWorkable end) == true,
    }
end

local function station_base(st)
    return ok(function() return st:GetBaseCampModelBelongTo() end)
end
M.station_base = station_base

--- All production stations, annotated.
-- @return list of { obj, name, baseId, baseName, recipes=[id], state={...}, key }
function M.stations()
    local base_names = {}
    for i, b in ipairs(M.bases()) do base_names[base_id(b)] = base_name(b, i) end

    local out = {}
    for _, st in ipairs(util.find_all("PalMapObjectConvertItemModel")) do
        if valid(st) and not_default(st) then
            local recipes = station_recipes(st)
            if #recipes > 0 then
                local base = station_base(st)
                local bid = base and base_id(base) or "unknown"
                local sorted = { table.unpack(recipes) }
                table.sort(sorted)
                out[#out + 1] = {
                    obj = st,
                    name = util.short_name(st),
                    baseId = bid,
                    baseName = base_names[bid] or "Base ?",
                    recipes = recipes,
                    state = M.station_state(st),
                    -- stable across restarts: base + its recipe set (object ids regenerate)
                    key = bid .. "|" .. table.concat(sorted, ","),
                }
            end
        end
    end
    return out
end

--- Find the station that should fulfil an order for `recipe_id`.
-- Prefers a station on `base_id` (if given) that is currently idle.
function M.station_for(recipe_id, want_base_id)
    local candidates = {}
    for _, s in ipairs(M.stations()) do
        for _, r in ipairs(s.recipes) do
            if r == recipe_id then candidates[#candidates + 1] = s; break end
        end
    end
    if #candidates == 0 then return nil end

    local function score(s)
        local n = 0
        if want_base_id and s.baseId == want_base_id then n = n + 100 end
        if not s.state.workable and s.state.requested == 0 then n = n + 10 end   -- idle
        if s.state.recipe == recipe_id then n = n + 5 end                        -- already set
        return n
    end
    table.sort(candidates, function(l, r) return score(l) > score(r) end)
    return candidates[1]
end

--- Resolve the acting player id (int32 net id) for autonomous / fallback use.
function M.any_player_id()
    local p = M.player_id_probe()
    return p and p.id or nil
end

--- Try every source for a usable RequestPlayerId. Returns { id, source, candidates }.
function M.player_id_probe()
    local cands = {}
    local function add(src, v)
        if v ~= nil then
            local n = tonumber(v)
            if n and n ~= 0 then cands[#cands + 1] = { source = src, id = math.floor(n) } end
        end
    end

    -- 1. connected player states
    for _, ps in ipairs(util.find_all("PalPlayerState")) do
        if valid(ps) then
            add("PalPlayerState:GetPlayerId", ok(function() return ps:GetPlayerId() end))
            add("PalPlayerState.PlayerId", ok(function() return ps.PlayerId end))
            add("PalPlayerState.PlayerIdOnServer", ok(function() return ps.PlayerIdOnServer end))
        end
    end

    -- 2. character / player controllers
    for _, pc in ipairs(util.find_all("PalPlayerController")) do
        if valid(pc) then
            local ps = ok(function() return pc.PlayerState end)
            if ps then add("PalPlayerController.PlayerState:GetPlayerId", ok(function() return ps:GetPlayerId() end)) end
        end
    end

    -- 3. persistent player records (offline members) -- these survive logout
    for _, rec in ipairs(util.find_all("PalPlayerDataStorage")) do
        if valid(rec) then
            local list = ok(function() return rec.PlayerDataContainerMap end)
                or ok(function() return rec.PlayerDataContainer end)
            -- best-effort: many builds expose GetAllPlayerUId / GetPlayerList
            add("PalPlayerDataStorage:GetLastPlayerUId", ok(function() return rec:GetLastPlayerUId() end))
        end
    end

    -- 4. group / guild manager -- a base always belongs to a group with members
    for _, gm in ipairs(util.find_all("PalGroupManager")) do
        if valid(gm) then
            local ok_iter = pcall(function()
                gm:ForEachGroup(function(g)
                    local players = ok(function() return g.players end) or ok(function() return g.RawGroupData and g.RawGroupData.players end)
                    if players then
                        players:ForEach(function(_, entry)
                            local e = entry:get()
                            add("PalGroupManager.group.player", ok(function() return e.player_uid end) or ok(function() return e.PlayerUId end))
                        end)
                    end
                end)
            end)
        end
    end

    local pick = cands[1]
    return { id = pick and pick.id or nil, source = pick and pick.source or "none", candidates = cands }
end

--- RequestPlayerId of a CURRENTLY CONNECTED player only.
-- ChangeRecipe_ServerInternal resolves the player's guild via the live
-- PlayerController list; a stale/offline id resolves to a zero guid and the RPC
-- silently no-ops. So the native backend must use this, never a persisted id.
-- Returns int32 id or nil (nil => do not arm a native call, keep the order queued).
function M.connected_player_id()
    for _, pc in ipairs(util.find_all("PalPlayerController")) do
        if valid(pc) and not_default(pc) then
            -- a live controller must have a possessed pawn OR an active net connection
            local has_pawn = ok(function() return pc:GetPawn() end) ~= nil
                or ok(function() return pc.Pawn end) ~= nil
            local has_conn = ok(function() return pc.NetConnection end) ~= nil
                or ok(function() return pc:GetNetConnection() end) ~= nil
            if has_pawn or has_conn then
                local ps = ok(function() return pc.PlayerState end)
                    or ok(function() return pc:GetPlayerState() end)
                if ps and valid(ps) then
                    local pid = ok(function() return ps:GetPlayerId() end)
                    if pid == nil then pid = ok(function() return ps.PlayerId end) end
                    local n = tonumber(pid)
                    if n and n ~= 0 then return math.floor(n) end
                end
            end
        end
    end
    return nil
end

return M
