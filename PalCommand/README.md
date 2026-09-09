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
| **replay** (default, pure Lua) | nothing | Queued orders are placed the next time **any player changes a recipe** at any station. On an active server this happens every session. |
| **native** (optional) | `PalCommand/dlls/main.dll` (the C++ companion) | Orders are placed on the next scan cycle, **no player needed**. |

Both produce identical, legitimate orders. The C++ companion is a drop-in upgrade —
install the DLL and PalCommand switches to `native` automatically.

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
[{ "recipe": "Pal_crystal_S", "count": 50, "transport": true }]
```

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
