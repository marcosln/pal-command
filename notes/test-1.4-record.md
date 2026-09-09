# Stage 1.4 — edge cases (live 2026-09-09, base B, pid 256; deploy db33c12)

Full orderable recipe set = **1217 distinct recipe ids** (union of `RecipeIds` across all 40 machines).

## LIVE-VERIFIED (4/6)

| case | result | evidence |
|------|--------|----------|
| **target machine busy → fall to next** | ✅ PASS | `Pal_crystal_S x3` targeting busy CrusherB `9fe83cf6` (req20 workable) → engine skipped it, submitted to **CrusherA `8c53a7e9` at the OTHER base**, VERIFIED req=3. Cross-base fallback works. |
| **recipe nobody can make** | ✅ PASS (minor) | `NotARealRecipe_PalCmd x1` → `FAIL (no station makes ...)` immediately, **never touches the bridge**. `order dropped after 6 attempts`, `recent[]` = "dropped". Minor: under queue traffic the 6 attempts burn in ~3s (4 during a drain chain + 2 at next scan) → log spam only. |
| **stale / nonexistent target mapId** | ✅ PASS | `Charcoal x2` with `target: "00000…0000"` → no bonus, routed to `BlastFurnace3 0fdd2d10` (idle, capable). Covers "machine gone after restart" from the mod's POV (a demolished machine = a non-matching mapId). |
| **cancel a placed order (by recipe/id)** | ✅ PASS | `{"cancel":"Pal_crystal_S"}` → `engine.cancel_station` → `PalMapObjectConvertItemModel:Cancel_ServerInternal(256)` (plain Lua call). Crusher B went `Pal_crystal_S x15 workable=true` → **`None`** (verified seq 11). `recent[]` = "cancelled", `placedWatch` entry removed. `probe_cancel`: `Cancel_ServerInternal` takes **one int32 `RequestPlayerId`, no archive** (flags 40401). |

## LIVE-VERIFIED (cont.) — 2026-09-09 ~20:21-20:27Z, base A, pid 256

| case | result | evidence |
|------|--------|----------|
| **cancel by explicit mapId, not in the ledger** | ✅ PASS | `_placed_watch` empty (post-restart). `[{"cancel":"8c53a7e9…"},{"cancel":"0fdd2d10…"}]` → log `cancel (explicit mapId) Pal_crystal_S @ 8c53a7e9 -> true` + same for Charcoal @ 0fdd2d10. Both machines `recipe → None` (next scan). `recent[]` = 2× "cancelled" / "explicit mapId: Cancel_ServerInternal(pid)". |
| **placed but not producing** | ✅ PASS | `Charcoal x5` → Pal-less Base A furnace `0fdd2d10`. VERIFIED → `recent[]` = **"placed"** (not a failure). At age 119s: `placedWatch[] = {producing:false, workable:false, stalled:true}` + one log line `note: … placed but not producing (no power / kindling Pal / fuel / free work slot) -- the base will craft it when it can`. **NO "warning" in recent[]**, never re-queued. Cleaned up with `{"cancel":"Charcoal"}` (ledger path this time). |

## 1.4 VERDICT: COMPLETE — all 6 edge cases pass

## Cosmetic bug found (fix next deploy)

`main.lua scan_cycle` calls `write_stations()` **before** `ingest_orders()`, so for one
scan (~30s) after any order/cancel the published `stations.json` shows the old machine
state (e.g. a cancelled recipe still listed). `state.json` and the log are correct
immediately. Fix: move `write_stations()` to after the flush, or write it twice.

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
