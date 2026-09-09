# PalCommand (server mod)

Server-side UE4SS companion for the **Pal Command** app. Runs on a Palworld
dedicated server. Publishes the whole-server storage inventory and lets you place
**legitimate** craft orders (real recipe, real material cost, a Pal does the work)
from your phone — including standing "keep topped up" rules.

It does **not** touch player inventories, world saves, or PBA/other mods.

## Install

```
<server>/Pal/Binaries/Win64/ue4ss/Mods/PalCommand/
  enabled.txt
  config.ini
  Scripts/*.lua
  data/            (created on first run)
```

Restart the server. Check `data/palcommand.log` for `PalCommand loading`.

## How ordering works

| Backend | Requires | Behaviour |
|---|---|---|
| **native** (default when the DLL is present) | `PalCommand/dlls/main.dll` (the C++ companion) | Places any recipe on any/all production machines across every base. Drains the whole queue order-by-order. Needs **at least one player connected** — anyone, AFK is fine, they never craft anything. Orders queue until someone connects, then flush automatically. |
| **replay** (pure-Lua fallback) | nothing | Queued orders are placed the next time **any player changes a recipe** at any station. Same-length recipe ids only. |

Both produce identical, legitimate orders (real machine, real material cost, a Pal
does the work). The C++ companion is a drop-in upgrade — install the DLL and
PalCommand switches to `native` automatically.

## Data files (`data/`)

| File | Direction | Contents |
|---|---|---|
| `inventory.json` | mod → app | totals + per-base + guild chest |
| `stations.json` | mod → app | production stations, recipes, current state |
| `state.json` | mod → app | queue depth, recent placements, backend, errors |
| `orders.json` | app → mod | list of immediate orders; consumed each cycle |
| `rules.json` | app → mod | standing rules |
| `queue.json` | internal | persisted pending queue (survives restart) |
| `palcommand.log` | internal | activity log |

### Immediate order

```json
[{ "recipe": "Pal_crystal_S", "count": 50, "transport": true, "target": "<machine mapId>" }]
```
`target` (optional) pins one machine — its `mapId`, `key#index`, or `key` from
`stations.json`. If that machine is busy or gone, the order routes to the next
capable one.

### Cancel

A list entry with a `cancel` field is a cancel directive, not an order:

```json
[{ "cancel": "Pal_crystal_S" }]     // by recipe id
[{ "cancel": "<order id>" }]        // by order id
[{ "cancel": "<machine mapId>" }]   // whatever we set on that machine
[{ "cancel": "all" }]               // every queued + in-flight order we placed
```
Drops matching pending orders, aborts a matching in-flight submit, and clears the
recipe on any machine **PalCommand** set for a match (never a machine a player set).

### `state.json` result kinds (`recent[]`)

`placed` · `dropped` (no station makes it / gave up after retries) · `cancelled` ·
`cancel-failed`.

A placed order that isn't producing yet (the machine has no power, no kindling
Pal, or no fuel) is **not** a failure — the game crafts it once the base can.
`state.json` → `engine.placedWatch[]` carries `{ recipe, target, working, stalled }`
so the app can show a soft "waiting on the base" badge; the order is never
re-queued or retried.

### Standing rule

```json
{
  "rules": [
    { "id": "paldium", "item": "Pal_crystal_S", "min": 500, "target": 1000, "batch": 200 }
  ]
}
```
`item` = inventory id to watch, `recipe` defaults to `item`, `target` defaults to
`min`, `batch` caps one top-up. When `have + inflight < min`, an order for
`target - have - inflight` (capped at `batch`) is queued.

## config.ini

See the file — scan interval, per-flush cap, guild chest toggle, retry cap, and
optional Cloudflare Worker URL/token for cloud sync.
