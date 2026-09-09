# PalCommand — Roadmap

**Read this first every session.** Source of truth for what's done and what's next.
Check items off with `[x]` + a `<!-- done YYYY-MM-DD: note -->` comment. Keep the
prose short; deep detail lives in `para-codex-*.md` and the auto-memory.

Goal: a publishable **iPhone app (PWA)** + distributable **UE4SS mod** for any
Palworld dedicated server — see whole-server storage, order crafts on any machine,
set standing rules. Crafting stays legit (real machine, real cost, a Pal works).

**Order of work (user, 2026-09-09):** 1) perfect the crafting → 2) easy 2D map →
3) cloud + app wiring → 4) polish/publish. **Zero-player autonomy is DEFERRED**
(research saved; `r12b=TRUE` offline confirmed — resume at the offline self-test).

---

## STAGE 1 — Crafting must be perfect (CONNECTED-PLAYER MODE)  ← CURRENT

Native backend, works whenever ANY player is online (AFK, never crafts).

- [x] 1.1 Multi-machine place + whole-queue drain <!-- done 2026-09-09: commit 761d03c; M.place iterates all stations for a recipe (discovery.stations_for), native_tick chains the next order on a verified placement. Deployed. Not yet stress-tested live (that's 1.3/1.6). -->
- [x] 1.2 Per-machine identity (persistent mapId) + world position + machine type
      <!-- done 2026-09-09: commit d1b9434, deployed + verified. data/stations.json: all 40 machines have mapId (32-hex FGuid from st.InstanceId, persistent), pos {x,y,z} world cm (from st:GetActor():K2_GetActorLocation()), machineType (BP class, e.g. BP_BuildObject_IceCrusher_C / _FlourMill_C / _CompositeDesk_C), and a per-key `index`. Orders can pin a machine via `target` = mapId / "key#index" / key (rules.normalize_order keeps it). -->
      Also captured: `GetBaseCampIdBelongTo()` → base FGuid; `CurrentRecipeRequestPlayerUId` (FGuid) = the stored recipe-setter — may matter for 1.4. Positions look like y≈-136000..-137000, x≈-240..3300 (UE cm) for these 2 bases.
- [x] 1.3 **Live test** — 3 orders, 3 recipes, 3 machine types, one orders.json, one scan → all placed.
      <!-- done 2026-09-09 16:06Z: base B/名2, player pid 256 connected. orders.json = Pal_crystal_S x3 → Crusher mapId 9fe83cf6, Charcoal x5 → BlastFurnace4 56997cb5, Flour x5 → FlourMill 00103ddd (CopperIngot from the example swapped for Flour — only 1 idle furnace at 名2, would collide w/ Charcoal). Log: "ingested 3", then Pal_crystal_S/Charcoal/Flour each "VERIFIED after 2 pokes" at 16:05:59 / 16:06:00 / 16:06:01 (1s apart). Native drained order-by-order via native_tick chain; bridge arms=3 execs=3 (no runaway); state.json placed=3 failed=0 queueDepth=0. Per-machine target confirmed: Crusher set Pal_crystal_S not Fiber (both in its recipe set); each recipe on the exact target instance. Storage deltas match order counts exactly: Pal_crystal_S 605→608 (+3), Charcoal 1613→1618 (+5), Flour 2328→2332 (+4→5); real Stone/Wood/Wheat cost. Machines returned to recipe=None on finite-batch completion. Full record: scratchpad test-1.3-record.md.
      RUN 2 (16:36Z, x10 each, same 3 machines, USER WATCHING): ingested 3 -> VERIFIED Pal_crystal_S/Flour/Charcoal 16:36:29/30/31 (1s apart). placed=6 failed=0. User eyewitness: "hizo todo" - saw a Pal at the Crusher + a Pal at the Mill work the full batch; furnace ran 10 in ~25s. Cost EXACT: Stone -50, Wood -20. Storage: Charcoal +10, Flour +10 exact; Pal_crystal_S +8 (user hand-picked ~2 - mod scope = server_storage_only_no_player_inventory). Run-1 Flour +4/5 was a kitchen elsewhere eating 1, not a bug. Authoritative = per-machine requested/remaining + VERIFIED lines; material deltas noisy (players/kitchens touch chests). -->
      Order file shape: `[{"recipe":"Pal_crystal_S","count":3,"transport":true,"target":"<mapId>"}, ...]` (mod ingests each scan / on the native chain; `target` = mapId / "key#index" / key).
- [ ] 1.4 Edge cases — 4/6 verified live (2026-09-09), 2 code-done pending a live check.
      <!-- LIVE-VERIFIED (base B, pid 256):
        * target machine busy -> falls to the next capable machine, even cross-base. Ordered Pal_crystal_S x3 at busy CrusherB 9fe83cf6 (req20) -> placed on CrusherA 8c53a7e9 (other base), VERIFIED.
        * recipe nobody can make -> "FAIL (no station makes 'X')" immediately, never touches the bridge, dropped after 6 attempts, recent[] = "dropped". (minor: under queue traffic the 6 attempts burn in ~3s; log noise only.)
        * stale/nonexistent target mapId -> no bonus, routes to best available capable machine. Ordered Charcoal x2 with target 0000..0000 -> placed on BlastFurnace3 0fdd2d10.
        * cancel by recipe/id -> engine.cancel_station -> PalMapObjectConvertItemModel:Cancel_ServerInternal(int32 pid), plain Lua call. {"cancel":"Pal_crystal_S"} cleared CrusherB (Pal_crystal_S x15 -> None), recent[] = "cancelled". probe_cancel logged: Cancel_ServerInternal takes ONE int32 RequestPlayerId, no archive.
      CODE DONE, NOT YET LIVE-CHECKED (deployed db33c12, needs a connected player):
        * cancel by explicit mapId when it's not in engine._placed_watch (e.g. after a restart wiped the in-mem ledger) -> clears that one station directly.
        * "not enough materials / no Pal / no power" -> soft `stalled` flag on state.json engine.placedWatch[] ({producing, workable, stalled}); NEVER a failure, never re-queued, never retried. One log line. (Design change from user: placing a recipe on a machine that can't work right now IS correct -- the game crafts it when the base can.) Couldn't reproduce a stall live: base B was healthy, IronIngot produced fine once Pals were free.
      CORRECTION: the earlier "1.4-c: no material for IronIngot" was a misdiagnosis -- IronIngot = "Refined Ingot" = 2x CopperOre + 2x Coal, both plentiful; it stalled on NO FREE PAL, then produced normally once Pals freed up. `CopperOre` is Palworld's internal id for the common grey "Ore" / ES "Mineral de metal", NOT copper. Mod inventory reading was correct throughout. See [[palworld-item-id-quirks]].
      TO FINISH (paste into data/orders.json when a player is on):
        [{"cancel":"8c53a7e99567433bb363ca12226836b8"},{"cancel":"0fdd2d104f4bd80419c88284e51c1839"}]   -- clears the 2 pre-restart leftovers via mapId
        then order e.g. Charcoal x5 -> a Base A furnace with no free Pal, wait ~3min, confirm placedWatch[].stalled=true and NO "warning" in recent[]. -->
      Full detail: scratchpad test-1.4-record.md.
- [ ] 1.5 "Craft X on ALL machines that can" — batch order fan-out
- [ ] 1.6 Stress: full queue (8+), verify drain, timing, and that joins never block
- [ ] 1.7 Replay fallback still correct when native is off (same-length recipe ids)
- [ ] 1.8 **Two targeting modes, user-picked per order (user, 2026-09-09):**
      (a) **PIN** — `target` + `pin:true`: this exact machine only. If it's busy, the
          order WAITS in a per-machine FIFO sub-queue and places when that machine
          frees — never falls through to another. Multiple pinned orders for one
          machine = an ordered backlog on it.
      (b) **ANY** (default, exists today as a soft `target`): place on the best free
          capable machine now; `target` (no `pin`) only nudges the choice.
      Engine: `M.place` respects `pin` (return soft-wait, don't scan other candidates);
      queue keeps pinned orders in arrival order per `target`. Surfaced in the app
      (Stage 4) + the map order-sheet (3.4).

## STAGE 2 — Standing rules polished

- [ ] 2.1 Rule eval vs live inventory verified end-to-end
- [ ] 2.2 Rule types: keep item ≥ N; keep ≤ N in progress; scope to a base/machine
- [ ] 2.3 No spam — respect in-flight + cooldowns
- [ ] 2.4 Rules survive restart; test with a real low-stock trigger

## STAGE 3 — Easy 2D map (schematic)

- [ ] 3.1 Read positions: bases, machines, chests, Pals (needs 1.2 position work)
- [ ] 3.2 `map.json` published by the mod (normalized coords + labels)
- [ ] 3.3 PWA canvas: bases as regions, machines as icons by type, Pals as dots.
      Each machine shows its live state: current recipe + remaining, or idle, or
      `stalled` (placed, not producing — no power/Pal/fuel), from `state.json`.
- [ ] 3.4 Tap a machine → order sheet prefilled, with the 1.8 mode toggle:
      "this machine (queue if busy)" vs "any free machine".
- [ ] 3.5 (later) overlay on the real Palworld map image

## STAGE 4 — Cloud Worker + PWA wired to live data

- [ ] 4.1 User gives DatHost API token → `wrangler secret put` (APP_TOKEN, DATHOST_*)
- [ ] 4.2 `wrangler kv namespace create` → fill `cloud/wrangler.toml`
- [ ] 4.3 `wrangler deploy`; test /api/snapshot /orders /rules /health
- [ ] 4.4 Mod ↔ Worker sync (poll orders/rules, post inventory/state) via config WorkerBaseUrl+ServerToken
- [ ] 4.5 PWA points at the live Worker; inventory view real
- [ ] 4.6 PWA order flow: create → shows "placed" from state.json
- [ ] 4.7 PWA rules editor
- [ ] 4.8 Auth: per-server token, entered once

## STAGE 5 — Polish + publish

**Distribution plan (user, 2026-09-09):** PWA-first the whole way; the App Store IS
the eventual target (user will pay the $99/yr Apple Developer Program — open the
account a few days before this stage). At 5.4 wrap the existing PWA with **Capacitor**
(no rewrite — same web code) → TestFlight → App Store. Build the PWA wrapper-friendly
from the start: relative asset paths, no desktop-only assumptions, nothing that
breaks in WKWebView, and one small real native capability so it clears App Review
guideline 4.2 ("not just a web view"). Name already avoids the Palworld trademark
("Pal Command") — matters more for App Review than for a PWA link.

- [ ] 5.1 PWA install / icon / offline / theme — built Capacitor-ready
- [ ] 5.2 Mod packaging + install README for strangers
- [ ] 5.3 Publish mod (Nexus)
- [ ] 5.4 Capacitor wrap → TestFlight → App Store submission (needs the Apple Developer account)

## DEFERRED — Zero-player autonomy

Research complete through `para-codex-07.md`. `r12b = TRUE` offline (guild gate is
NOT the blocker). Next step when resumed: the one offline self-test (pid 0, idle
station, cheap recipe x1, save backup first) to decide branch 1 (works → done) vs
branch 3 (blocker is pre-tail: deserializer / param frame). Bridge ops `dump` /
`inspect` / `callpred` still in the v3 DLL. Do NOT touch `OnRep_` or fake a
PlayerController (Codex).

---

## Environment quick ref

- Repo: `github.com/marcosln/pal-command` (public). Working dir: `/Users/marcosleon/Palworld claude`.
- Test server: DatHost id `6a9966f03a02c380ecdb8e18`, drive via `dathost.com` API in the in-app browser (`credentials:"include"`), `POST /mount-overlay` before file reads.
- Deploy: push → CDN lag ~30-90s → verify a marker string in `raw.githubusercontent.com/marcosln/pal-command/master/...` → multipart POST to `.../files/Binaries/Win64/ue4ss/Mods/PalCommand/...` → stop, wait for `on:false`, start.
- Native DLL: GitHub Actions builds it; `gh run download <id>` → copy into `PalCommand/dlls/main.dll` → commit.
- Restart cost: ~60-90s boot. Mod one-shots fire 12-20s after "PalCommand loading".
- Bridge `dump` op needs a **numeric** `request_id` (underscore = ignored).
