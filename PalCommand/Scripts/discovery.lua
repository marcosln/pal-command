-- PalCommand :: discovery.lua
-- Read-only reflection over the live game:
--   * whole-server storage inventory (all base chests + guild chest)
--   * production stations (PalMapObjectConvertItemModel: crushers, furnaces, ...)
--
-- The inventory path is the standard Palworld storage-reflection sequence
-- (base camp module -> container manager -> per-slot item ids). Read-only:
-- nothing here mutates game state.

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

--- FGuid {A,B,C,D int32} -> stable 32-hex string.
local function guid_str(g)
    if g == nil then return nil end
    local a = ok(function() return tonumber(g.A) end)
    local b = ok(function() return tonumber(g.B) end)
    local c = ok(function() return tonumber(g.C) end)
    local d = ok(function() return tonumber(g.D) end)
    if a and b and c and d then
        return string.format("%08x%08x%08x%08x", a & 0xffffffff, b & 0xffffffff, c & 0xffffffff, d & 0xffffffff)
    end
    return nil
end
M.guid_str = guid_str

--- Per-machine identity + world position. `InstanceId` (FGuid on
--- PalMapObjectConcreteModelBase) is persistent across restarts; the world
--- position comes from the owning actor (`st:GetActor()`).
local function station_identity(st)
    local id = {}

    id.mapId = guid_str(unwrap(ok(function() return st.InstanceId end)))
           or guid_str(ok(function() return st:GetInstanceId() end))
    id.modelId = guid_str(unwrap(ok(function() return st.ModelInstanceId end)))

    local actor = ok(function() return st:GetActor() end)
    if actor and valid(actor) then
        id.machineType = ok(function() return actor:GetClass():GetFName():ToString() end)
        local function xyz(v)
            if v == nil then return nil end
            local x = ok(function() return tonumber(v.X) end)
            local y = ok(function() return tonumber(v.Y) end)
            local z = ok(function() return tonumber(v.Z) end)
            if x and y then return { x = x, y = y, z = z or 0 } end
        end
        id.pos = xyz(ok(function() return actor:K2_GetActorLocation() end))
              or xyz(ok(function() return actor:GetActorLocation() end))
    end
    return id
end
M.station_identity = station_identity

--- All production stations, annotated.
-- @return list of { obj, name, baseId, baseName, recipes=[id], state={...}, key, mapId?, pos?, machineType?, index }
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
                local ident = station_identity(st)
                out[#out + 1] = {
                    obj = st,
                    name = util.short_name(st),
                    baseId = bid,
                    baseName = base_names[bid] or "Base ?",
                    recipes = recipes,
                    state = M.station_state(st),
                    -- stable across restarts: base + its recipe set (object ids regenerate)
                    key = bid .. "|" .. table.concat(sorted, ","),
                    mapId = ident.mapId,
                    modelId = ident.modelId,
                    pos = ident.pos,
                    machineType = ident.machineType,
                }
            end
        end
    end
    -- stable per-machine ordinal within a (key) group: sort identical machines by
    -- mapId, else by position, else leave enumeration order.
    local groups = {}
    for _, s in ipairs(out) do groups[s.key] = groups[s.key] or {}; table.insert(groups[s.key], s) end
    for _, g in pairs(groups) do
        table.sort(g, function(l, r)
            local lk = l.mapId or (l.pos and string.format("%d,%d", l.pos.x, l.pos.y)) or ""
            local rk = r.mapId or (r.pos and string.format("%d,%d", r.pos.x, r.pos.y)) or ""
            return lk < rk
        end)
        for i, s in ipairs(g) do s.index = i end
    end
    return out
end

--- Every station that can make `recipe_id`, best-first: preferred base, then
--- idle, then already-on-this-recipe. `target` (if given) pins one machine --
--- matched against its mapId, its "key#index", or its key.
function M.stations_for(recipe_id, want_base_id, target)
    local candidates = {}
    for _, s in ipairs(M.stations()) do
        for _, r in ipairs(s.recipes) do
            if r == recipe_id then candidates[#candidates + 1] = s; break end
        end
    end
    local function score(s)
        local n = 0
        if target and (s.mapId == target or s.key == target
                       or (s.key .. "#" .. tostring(s.index)) == target) then n = n + 1000 end
        if want_base_id and s.baseId == want_base_id then n = n + 100 end
        if not s.state.workable and (tonumber(s.state.requested) or 0) == 0 then n = n + 10 end  -- idle
        if s.state.recipe == recipe_id then n = n + 5 end                                        -- already set
        return n
    end
    table.sort(candidates, function(l, r) return score(l) > score(r) end)
    return candidates
end

--- Best single station for an order (back-compat wrapper).
function M.station_for(recipe_id, want_base_id, station_key)
    return M.stations_for(recipe_id, want_base_id, station_key)[1]
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

--- UFunctions declared on PalMapObjectConvertItemModel + its superclasses.
-- Hunt for a no-player recipe/work entry (Load/PostLoad/OnRep/Restore/...).
-- Walks each UClass's own function list -- NO full-object iteration.
function M.dump_convert_api()
    local classes = {
        "PalMapObjectConvertItemModel", "PalMapObjectDeployItemModel",
        "PalMapObjectConcreteModelBase", "PalMapObjectModelBase",
        "PalWorkableBase", "PalWorkBase", "PalMapObjectItemStorageModel",
        "PalMapObjectModel",
    }
    local seen, out = {}, {}
    for _, cn in ipairs(classes) do
        local cls = ok(function() return StaticFindObject("/Script/Pal." .. cn) end)
        if cls and valid(cls) then
            local walked = pcall(function()
                cls:ForEachFunction(function(fn)
                    local n = fstr(ok(function() return fn:GetFName() end))
                    local k = cn .. ":" .. n
                    if n ~= "" and not seen[k] then seen[k] = true; out[#out + 1] = k end
                end)
            end)
            if not walked then out[#out + 1] = cn .. ":<ForEachFunction unavailable>" end
        end
    end
    table.sort(out)
    return out
end

--- One-shot reflection dump of a station: every property (name/type/value) up the
--- class chain + a set of candidate identity/position getters. For wiring the
--- per-machine id + world position without guessing.
function M.probe_station(st)
    if not valid(st) then return { error = "no station" } end
    local out = { class = full_name(st), props = {}, getters = {} }

    local function strval(v)
        v = unwrap(v)
        if v == nil then return nil end
        local tv = type(v)
        if tv == "number" or tv == "boolean" then return v end
        if tv == "string" then return v end
        -- struct-ish: try common shapes
        local x = ok(function() return tonumber(v.X) end)
        if x then return { X = x, Y = ok(function() return tonumber(v.Y) end), Z = ok(function() return tonumber(v.Z) end) } end
        local a = ok(function() return tonumber(v.A) end)
        if a then return { A = a, B = ok(function() return tonumber(v.B) end), C = ok(function() return tonumber(v.C) end), D = ok(function() return tonumber(v.D) end) } end
        local s = ok(function() return v:ToString() end)
        if type(s) == "string" then return s end
        return tostring(v)
    end

    local cls = ok(function() return st:GetClass() end)
    local guard = 0
    while cls and valid(cls) and guard < 12 do
        guard = guard + 1
        local cn = fstr(ok(function() return cls:GetFName() end))
        pcall(function()
            cls:ForEachProperty(function(prop)
                local pn = fstr(ok(function() return prop:GetFName() end))
                local pt = fstr(ok(function() return prop:GetClass():GetFName() end))
                if pn ~= "" and out.props[pn] == nil then
                    out.props[pn] = { owner = cn, type = pt, value = strval(ok(function() return st[pn] end)) }
                end
            end)
        end)
        cls = ok(function() return cls:GetSuperStruct() end) or ok(function() return cls:GetSuperClass() end)
    end

    for _, g in ipairs({
        "GetMapObjectId", "GetConcreteModelInstanceId", "GetInstanceId", "GetMapObjectInstanceId",
        "GetWorldLocation", "K2_GetActorLocation", "GetComponentLocation", "GetActorLocation",
        "GetConcreteModelActor", "GetActor", "GetOwnerMapObjectModel", "GetMapObjectConcreteModel",
        "GetBaseCampIdBelongTo", "GetSpawnPointId",
    }) do
        out.getters[g] = strval(ok(function() return st[g](st) end))
    end
    return out
end

--- Iterate live (connected) player controllers. cb(pc, ps, pid).
local function for_each_connected(cb)
    for _, pc in ipairs(util.find_all("PalPlayerController")) do
        if valid(pc) and not_default(pc) then
            local live = ok(function() return pc:GetPawn() end) ~= nil
                or ok(function() return pc.Pawn end) ~= nil
                or ok(function() return pc.NetConnection end) ~= nil
                or ok(function() return pc:GetNetConnection() end) ~= nil
            if live then
                local ps = ok(function() return pc.PlayerState end)
                    or ok(function() return pc:GetPlayerState() end)
                if ps and valid(ps) then
                    local pid = ok(function() return ps:GetPlayerId() end)
                    if pid == nil then pid = ok(function() return ps.PlayerId end) end
                    local n = tonumber(pid)
                    if n and n ~= 0 then cb(pc, ps, math.floor(n)) end
                end
            end
        end
    end
end

--- Any connected player's RequestPlayerId, or nil. (Gate/diagnostics only.)
function M.connected_player_id()
    local found
    for_each_connected(function(_, _, pid) found = found or pid end)
    return found
end

local function group_id_of(o)
    if not o then return nil end
    local g = fstr(ok(function() return o.GroupIdBelongTo end))
    if g == "" then g = fstr(ok(function() return o.GroupID end)) end
    if g == "" then g = fstr(ok(function() return o:GetGroupID() end)) end
    if g == "" then g = fstr(ok(function() return o:GetGroupId() end)) end
    return (g ~= "" and g) or nil
end

--- RequestPlayerId of a connected player who is in the SAME guild/group as the
-- station's base camp. ChangeRecipe_ServerInternal resolves the caller's guild
-- and matches it against the station's -- a wrong-guild id is a silent no-op.
-- Returns id, reason. reason "guild-match" is confirmed; "any-connected" is a
-- best-effort fallback (the strict verifier re-queues if the RPC no-ops).
function M.connected_player_for_station(station_obj)
    local base = ok(function() return station_obj:GetBaseCampModelBelongTo() end)
    local st_group = group_id_of(base)
    local any
    local match
    for_each_connected(function(pc, ps, pid)
        any = any or pid
        if st_group then
            local pg = group_id_of(ps)
            if pg and pg == st_group then match = match or pid end
        end
    end)
    if match then return match, "guild-match" end
    if any then return any, "any-connected(guild " .. tostring(st_group) .. " unverified)" end
    return nil, "no-connected-player"
end

return M
