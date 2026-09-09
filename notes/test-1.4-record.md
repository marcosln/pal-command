# Stage 1.4 — edge cases (live 2026-09-09, base B, pid 256; deploy db33c12)

Full orderable recipe set = **1217 distinct recipe ids** (union of `RecipeIds` across all 40 machines).

## LIVE-VERIFIED (4/6)

| case | result | evidence |
|------|--------|----------|
| **target machine busy → fall to next** | ✅ PASS | `Pal_crystal_S x3` targeting busy CrusherB `9fe83cf6` (req20 workable) → engine skipped it, submitted to **CrusherA `8c53a7e9` at the OTHER base**, VERIFIED req=3. Cross-base fallback works. |
| **recipe nobody can make** | ✅ PASS (minor) | `NotARealRecipe_PalCmd x1` → `FAIL (no station makes ...)` immediately, **never touches the bridge**. `order dropped after 6 attempts`, `recent[]` = "dropped". Minor: under queue traffic the 6 attempts burn in ~3s (4 during a drain chain + 2 at next scan) → log spam only. |
| **stale / nonexistent target mapId** | ✅ PASS | `Charcoal x2` with `target: "00000…0000"` → no bonus, routed to `BlastFurnace3 0fdd2d10` (idle, capable). Covers "machine gone after restart" from the mod's POV (a demolished machine = a non-matching mapId). |
| **cancel a placed order (by recipe/id)** | ✅ PASS | `{"cancel":"Pal_crystal_S"}` → `engine.cancel_station` → `PalMapObjectConvertItemModel:Cancel_ServerInternal(256)` (plain Lua call). Crusher B went `Pal_crystal_S x15 workable=true` → **`None`** (verified seq 11). `recent[]` = "cancelled", `placedWatch` entry removed. `probe_cancel`: `Cancel_ServerInternal` takes **one int32 `RequestPlayerId`, no archive** (flags 40401). |

## CODE DONE, DEPLOYED (db33c12), NOT YET LIVE-CHECKED — needs a connected player

| case | plan |
|------|------|
| **cancel by explicit mapId, not in the ledger** | after a restart the in-mem `_placed_watch` is empty, so `{"cancel":"<mapId>"}` now also clears that one station directly (explicit user action). Test: `[{"cancel":"8c53a7e99567433bb363ca12226836b8"},{"cancel":"0fdd2d104f4bd80419c88284e51c1839"}]` → the 2 pre-restart leftovers should clear. |
| **placed but not producing (no material / Pal / power)** | soft `stalled` flag only. `state.json` → `engine.placedWatch[]` = `{recipe, target, producing, workable, stalled}`. NEVER a failure, never re-queued/retried, one log line. Design (per user): placing a recipe a machine can't work yet IS correct — the game crafts it when the base can. Test: order `Charcoal x5` at a Base A furnace with no free Pal, wait ~3 min → `stalled:true`, NO "warning" in `recent[]`. |

## CORRECTION to run-1 "1.4-c: not enough materials"

That was **wrong**. `IronIngot` = in-game **"Refined Ingot" / "Lingote de metal refinado"** = 2× `CopperOre` + 2× `Coal`. Base B had 4700+ `CopperOre` and ~440 `Coal`. It stalled because **no kindling Pal was free** (IceCrusher + CrusherB were running my x8/x20 orders). Re-ordered later with Pals free → produced normally (`req=10 rem=8` in 2 min). **The mod's inventory read was correct the whole time.**

`CopperOre` is Palworld's internal id for the common grey **"Ore"** (ES "Mineral de metal"), NOT copper. `CopperIngot` = basic "Ingot" / "Lingote de metal". `IronOre` is the separate rare one. → memory `palworld-item-id-quirks`.

## Server state at handoff (2026-09-09 17:58Z)

- Rebooted clean, `probe_cancel` logged, no Lua errors, `nativeStatus: ready`, no player connected.
- Harmless leftovers on machines (persist in the world save, not in the mod ledger):
  - CrusherA `8c53a7e9`: `Pal_crystal_S x3` (workable, no Pal at Base A crusher)
  - BlastFurnace3 `0fdd2d10`: `Charcoal x2` (workable=false)
  - BlastFurnace4 `56997cb5` (Base B): `IronIngot x10` — was producing, may be done by now
- All clearable with the mapId-cancel test above.
