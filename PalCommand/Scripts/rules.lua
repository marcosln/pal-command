-- PalCommand :: rules.lua
-- Standing rules ("keep item X topped up") + the immediate-order queue.
--
-- Rule shape (from the app, stored in data/rules.json):
--   {
--     "id": "paldium",                 -- stable id (dedup / edit)
--     "item": "Pal_crystal_S",         -- inventory id to watch
--     "recipe": "Pal_crystal_S",       -- recipe to craft (defaults to item)
--     "min": 500,                      -- craft when total drops below this
--     "target": 1000,                  -- craft up to this (defaults to min)
--     "batch": 200,                    -- max to request per top-up (optional)
--     "baseId": "....",                -- restrict to a base (optional)
--     "transport": true,               -- deliver to storage (optional)
--     "enabled": true
--   }
--
-- Immediate order shape (data/orders.json is a list of these):
--   { "id": "uuid", "recipe": "Pal_crystal_S", "count": 50, "transport": true,
--     "baseId": "...", "createdAt": "..." }

local util = require("util")

local M = {}

--- Evaluate rules against an inventory snapshot; return a list of orders to enqueue.
-- @param rules   list of rule tables
-- @param totals  { itemId = count }  (snapshot.totals)
-- @param inflight function(recipe) -> number already queued/being produced for recipe
function M.evaluate(rules, totals, inflight)
    local orders = {}
    if type(rules) ~= "table" then return orders end
    inflight = inflight or function() return 0 end

    for _, rule in ipairs(rules) do
        local okrule = type(rule) == "table"
            and rule.enabled ~= false
            and type(rule.item) == "string" and rule.item ~= ""
        if okrule then
            local have = tonumber(totals[rule.item]) or 0
            local min = tonumber(rule.min) or 0
            local target = tonumber(rule.target) or min
            local pending = inflight(rule.recipe or rule.item)

            if have + pending < min and target > 0 then
                local deficit = math.max(0, math.ceil(target - have - pending))
                local batch = tonumber(rule.batch)
                local count = batch and math.min(deficit, math.max(1, math.floor(batch))) or deficit
                if count >= 1 then
                    orders[#orders + 1] = {
                        source = "rule:" .. tostring(rule.id or rule.item),
                        recipe = rule.recipe or rule.item,
                        count = count,
                        transport = rule.transport ~= false,
                        baseId = rule.baseId,
                    }
                end
            end
        end
    end
    return orders
end

--- Normalize an immediate order coming from the app.
function M.normalize_order(raw)
    if type(raw) ~= "table" then return nil end
    local recipe = raw.recipe or raw.item
    if type(recipe) ~= "string" or recipe == "" then return nil end
    local count = math.floor(tonumber(raw.count) or 0)
    if count < 1 then return nil end
    return {
        id = tostring(raw.id or (recipe .. "-" .. tostring(os.time()) .. "-" .. tostring(math.random(1000, 9999)))),
        source = "order",
        recipe = recipe,
        count = math.min(count, 100000),
        transport = raw.transport ~= false,
        baseId = raw.baseId,
        createdAt = raw.createdAt or os.date("!%Y-%m-%dT%H:%M:%SZ"),
    }
end

return M
