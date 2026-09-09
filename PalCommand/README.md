# PalCommand (server mod)

Server-side UE4SS companion for the **Pal Command** app. Runs on a Palworld
dedicated server. Publishes the whole-server storage inventory and lets you place
**legitimate** craft orders (real recipe, real material cost, a Pal does the work)
from your phone — including standing "keep topped up" rules.

It does **not** touch player inventories, world saves, or other server mods.

An alternative to a client-side automation UI (e.g. PBA) for setups where a
`.pak` LogicMod isn't an option — crossplay servers where console players can't
load client mods, or driving crafting entirely from a phone.

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

- **`target`** (optional) — pin to one machine: its `mapId`, `"key#index"`, or `key`
  from `stations.json`. It's a **hard pin**: the order goes to that machine and
  **waits in its queue if it's busy** (FIFO — several pinned orders stack up and
  run in order), never falling through to another machine. If the target no longer
  exists (demolished / typo) the order degrades to any capable machine.
- **no `target`** — any free capable machine, best-first (idle > already-on-recipe).
- **`baseId`** (optional) — restrict to one base without pinning a machine.

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

`data/rules.json` — a bare list, or `{ "rules": [...] }`:

```json
[
  { "id": "paldium", "item": "Pal_crystal_S", "min": 500, "target": 1000,
    "batch": 200, "maxInProgress": 400 }
]
```
`item` = inventory id to watch · `recipe` defaults to `item` · `target` defaults to
`min` · `batch` caps one top-up · `maxInProgress` caps queued+producing at once ·
`baseId` / `machine` restrict where it crafts · `transport` (default true).

When `have + inProgress < min`, an order for `target - have - inProgress` (capped
at `batch` and `maxInProgress`) is queued. `inProgress` counts queued orders +
`remaining` on stations set to it + our just-placed orders. After a rule fires it
waits `RuleCooldownSeconds` (config, default 90) before it can fire again.
`state.json` → `rules[]` shows each rule's `{ have, min, target, inProgress, low,
onCooldown }`.

## config.ini

See the file. Scan pacing is **dynamic**: `ScanIntervalSeconds` (default 20) while
there's queue activity or a fresh order, backing off to `IdleScanIntervalSeconds`
(default 120) when idle — fewer game-thread reflection passes when nobody's using
the app. Also: per-flush cap, guild chest toggle, retry cap, and optional
Cloudflare Worker URL/token for cloud sync.

## License

MIT — see [`LICENSE`](../LICENSE) at the repo root.
