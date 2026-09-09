# PalCommand — Roadmap

**Read this first every session.** Source of truth for what's done and what's next.
Check items off with `[x]` + a `<!-- done YYYY-MM-DD: note -->` comment. Keep the
prose short; deep detail lives in `para-codex-*.md` and the auto-memory.

Goal: a publishable **iPhone app (PWA)** + distributable **UE4SS mod** for any
Palworld dedicated server — see whole-server storage, order crafts on any machine,
set standing rules. Crafting stays legit (real machine, real cost, a Pal works).

**BUILD ORDER (revised 2026-09-09 — supersedes the stage numbers below):**
Stage 1 (crafting) → Stage 2 (rules) → **Stage 4 (cloud + PWA wired = the phone
works)** → **Stage 3 (2D map)** → Stage 5 (polish/publish). The map moved AFTER the
app because 3.3/3.4 are PWA features (canvas, tap-a-machine-to-order) that need the
connected PWA from Stage 4 to exist first; only 3.1/3.2 (mod publishes map.json) are
independent and slot in just before 3.3.
**Zero-player autonomy is DEFERRED** (research saved; `r12b=TRUE` offline confirmed —
resume at the offline self-test).

---

## STAGE 1 — Crafting must be perfect (CONNECTED-PLAYER MODE)  ✅ effectively DONE

Native backend, works whenever ANY player is online (AFK, never crafts).
1.1-1.4, 1.6, 1.8 all verified live. 1.5 deferred (user: manual per-machine, not fan-out).
1.7 deferred to Stage 5 (replay fallback only matters for the no-DLL packaging).
**← NEXT: Stage 2 (rules), then Stage 4 (cloud + PWA).**

- [x] 1.1 Multi-machine place + whole-queue drain <!-- done 2026-09-09: commit 761d03c; M.place iterates all stations for a recipe (discovery.stations_for), native_tick chains the next order on a verified placement. Deployed. Not yet stress-tested live (that's 1.3/1.6). -->
- [x] 1.2 Per-machine identity (persistent mapId) + world position + machine type
      <!-- done 2026-09-09: commit d1b9434, deployed + verified. data/stations.json: all 40 machines have mapId (32-hex FGuid from st.InstanceId, persistent), pos {x,y,z} world cm (from st:GetActor():K2_GetActorLocation()), machineType (BP class, e.g. BP_BuildObject_IceCrusher_C / _FlourMill_C / _CompositeDesk_C), and a per-key `index`. Orders can pin a machine via `target` = mapId / "key#index" / key (rules.normalize_order keeps it). -->
      Also captured: `GetBaseCampIdBelongTo()` → base FGuid; `CurrentRecipeRequestPlayerUId` (FGuid) = the stored recipe-setter — may matter for 1.4. Positions look like y≈-136000..-137000, x≈-240..3300 (UE cm) for these 2 bases.
- [x] 1.3 **Live test** — 3 orders, 3 recipes, 3 machine types, one orders.json, one scan → all placed.
      <!-- done 2026-09-09 16:06Z: base B/名2, player pid 256 connected. orders.json = Pal_crystal_S x3 → Crusher mapId 9fe83cf6, Charcoal x5 → BlastFurnace4 56997cb5, Flour x5 → FlourMill 00103ddd (CopperIngot from the example swapped for Flour — only 1 idle furnace at 名2, would collide w/ Charcoal). Log: "ingested 3", then Pal_crystal_S/Charcoal/Flour each "VERIFIED after 2 pokes" at 16:05:59 / 16:06:00 / 16:06:01 (1s apart). Native drained order-by-order via native_tick chain; bridge arms=3 execs=3 (no runaway); state.json placed=3 failed=0 queueDepth=0. Per-machine target confirmed: Crusher set Pal_crystal_S not Fiber (both in its recipe set); each recipe on the exact target instance. Storage deltas match order counts exactly: Pal_crystal_S 605→608 (+3), Charcoal 1613→1618 (+5), Flour 2328→2332 (+4→5); real Stone/Wood/Wheat cost. Machines returned to recipe=None on finite-batch completion. Full record: scratchpad test-1.3-record.md.
      RUN 2 (16:36Z, x10 each, same 3 machines, USER WATCHING): ingested 3 -> VERIFIED Pal_crystal_S/Flour/Charcoal 16:36:29/30/31 (1s apart). placed=6 failed=0. User eyewitness: "hizo todo" - saw a Pal at the Crusher + a Pal at the Mill work the full batch; furnace ran 10 in ~25s. Cost EXACT: Stone -50, Wood -20. Storage: Charcoal +10, Flour +10 exact; Pal_crystal_S +8 (user hand-picked ~2 - mod scope = server_storage_only_no_player_inventory). Run-1 Flour +4/5 was a kitchen elsewhere eating 1, not a bug. Authoritative = per-machine requested/remaining + VERIFIED lines; material deltas noisy (players/kitchens touch chests). -->
      Order file shape: `[{"recipe":"Pal_crystal_S","count":3,"transport":true,"target":"<mapId>"}, ...]` (mod ingests each scan / on the native chain; `target` = mapId / "key#index" / key).
- [x] 1.4 Edge cases — all 6 verified live (2026-09-09).
      <!-- LIVE-VERIFIED (base B + base A, pid 256; deploy db33c12):
        * target machine busy -> falls to the next capable machine, even cross-base. Pal_crystal_S x3 at busy CrusherB 9fe83cf6 (req20) -> placed on CrusherA 8c53a7e9 (other base), VERIFIED.
        * recipe nobody can make -> "FAIL (no station makes 'X')" immediately, never touches the bridge, dropped after 6 attempts, recent[] = "dropped". (minor: under queue traffic the 6 attempts burn in ~3s; log noise only.)
        * stale/nonexistent target mapId -> no bonus, routes to best available capable machine. Charcoal x2 with target 0000..0000 -> placed on BlastFurnace3 0fdd2d10.
        * cancel by recipe/id -> engine.cancel_station -> PalMapObjectConvertItemModel:Cancel_ServerInternal(int32 pid), plain Lua call. {"cancel":"Pal_crystal_S"} cleared CrusherB (x15 -> None). probe_cancel: Cancel_ServerInternal takes ONE int32 RequestPlayerId, no archive.
        * cancel by explicit mapId NOT in the ledger (post-restart) -> clears that one station directly. {"cancel":"8c53a7e9..."} + {"cancel":"0fdd2d10..."} cleared both pre-restart leftovers, recent[] = "cancelled" / "explicit mapId: Cancel_ServerInternal(pid)".
        * placed but not producing (no power / no kindling Pal / no fuel) -> soft `stalled` flag only. Charcoal x5 on a Pal-less Base A furnace: recent[] = "placed" (NOT a failure), then at age>90s `state.json engine.placedWatch[] = {producing:false, workable:false, stalled:true}` + one `note:` log line. Never re-queued, never retried, no "warning". (Design per user: placing a recipe a machine can't work yet IS correct -- the game crafts it when the base can.)
      CORRECTION: the earlier "1.4-c: no material for IronIngot" was a misdiagnosis -- IronIngot = "Refined Ingot" = 2x CopperOre + 2x Coal, both plentiful; it stalled on NO FREE PAL, then produced normally once Pals freed up. `CopperOre` is Palworld's internal id for the common grey "Ore" / ES "Mineral de metal", NOT copper. Mod inventory reading was correct throughout. See [[palworld-item-id-quirks]].
      COSMETIC BUG (fix in the next deploy): scan_cycle calls write_stations() BEFORE ingest_orders(), so the published stations.json shows pre-cancel/pre-placement state for one scan (~30s) after any order or cancel. Move write_stations() after the flush, or write it twice. -->
      Full detail: notes/test-1.4-record.md.
- [~] 1.5 "Craft X on ALL machines that can" (fan-out) — **DEFERRED** (user 2026-09-09:
      wants manual per-machine control, not broadcast). Revisit as an optional
      power-user action after the map/app exist.
- [x] 1.6 Stress: full queue (8+), drain, timing, joins.
      <!-- done 2026-09-09 21:29 (deploy 62bc06d, dynamic scan): wrote 8 orders (7 pinned to
      distinct machines across all 3 bases incl. the outpost, 1 unpinned). "ingested 8" ->
      all 8 VERIFIED 21:28:56..21:29:06 = **~10s total**, one-by-one via the native_tick chain.
      placed=8 failed=0 queueDepth=0, all recent[]="placed". [pinned] tag confirms 1.8 routing;
      FIFO held (array order); unpinned one fell to a free furnace. No scan_cycle error / no
      traceback / no game-thread stall during the drain. {"cancel":"all"} then cleared all 6
      still-tracked -> every machine back to idle. Couldn't test a live join mid-drain (need a
      2nd player) but 10s of non-blocking async activity + the design (650ms poke, no forced
      disk sync) cover it. Minor: an unpinned order's cancel logs "@ nil" instead of the real
      mapId (cosmetic). Note: tiny test batches showed producing=false for a while because the
      base was saturated (Salad x1948 + Cake03 x202 + Plastic x2) -- not a bug, Pals were busy. -->
- [ ] 1.7 Replay fallback still correct when native is off (same-length recipe ids).
      Needs: DLL renamed off + restart + the USER manually crafts a recipe in-game (replay
      borrows that live PalNetArchive). Lower priority — native is the deployed default and
      solid. Do when the no-DLL path actually matters (Stage 5 packaging).
- [x] 1.8 Targeting: an explicit machine `target` is a HARD PIN.
      <!-- done 2026-09-09 (code 62bc06d, DEPLOYED to server, restart pending): user settled it -- picking a machine
      means "use THIS machine". engine.M.place: if `target` (mapId / "key#index" / key)
      resolves to >=1 live machine, restrict candidates to ONLY those; if all busy ->
      soft-wait (stays queued, retried each scan; FIFO falls out of queue order, and a
      later order for a free machine still jumps ahead so it doesn't block). If the
      target resolves to NO live machine (demolished / typo) -> degrade to any capable.
      No `pin:true` flag -- the target IS the pin. No wait-timeout (user: "sin limite").
      "ANY machine" = just omit `target`. `baseId` (no `target`) still = soft base
      preference. Surfaced in the app (Stage 4) + map order-sheet (3.4). -->
      Also this deploy: dynamic scan pacing (ScanIntervalSeconds active / 
      IdleScanIntervalSeconds idle -> fewer game-thread passes, lighter on the map-open
      hitch) + fix the cosmetic bug (stations.json published after ingest now).

## STAGE 2 — Standing rules polished   ✅ done (2 fixes pending a restart)

Code: rules.lua `M.evaluate` + main.lua `apply_rules` / `inflight_for`. Deploy 8fb0ef0
+ a70c827 (uploaded, restart pending). `RuleCooldownSeconds` config (default 90).

- [x] 2.1 Rule eval vs live inventory. <!-- 2026-09-09 21:36 live: rules.json in the
      {"rules":[...]} form (was SILENTLY IGNORED before — apply_rules ipairs'd the dict)
      now read. Rule {item:Flour,min:900,target:1000,batch:100}: have 715 < 900 ->
      "rules enqueued 1" -> Flour x100 queued (source rule:rtest-flour) -> placed on a
      mill -> producing. state.json rules[] = {have,min,target,inProgress,low,onCooldown,lastFired}. -->
- [x] 2.2 Rule fields: `min`/`target`/`batch` (had), + `maxInProgress` (cap queued+producing),
      `baseId` (had, passed through), `machine` (pin top-ups to one mapId). All coded;
      maxInProgress exercised in eval, machine/baseId reuse the proven 1.8 `target` path.
- [x] 2.3 No thrash: per-rule cooldown (`RuleCooldownSeconds`) after a fire + `inflight_for`
      counts queue + station `remaining` + `_placed_watch`. Live: rule fired exactly once,
      held through inventory wobble (Cake03 eating Flour). <!-- fix a70c827: inflight_for was
      double-counting a station (dedup by tostring(wrapper) fails across scans) -> use
      GetAddress(); apply_rules sets S.lastOrderAt so the scan loop stays fast while a rule acts. -->
- [x] 2.4 rules.json is on disk -> survives restart; apply_rules re-reads it every scan.
      Cooldown state is in-memory (worst case: one extra fire right after a restart — fine).

## STAGE 3 — Easy 2D map (schematic)   ← BUILD AFTER STAGE 4 (see BUILD ORDER up top)

- [ ] 3.1 Read positions: bases, machines, chests, Pals (needs 1.2 position work)
- [ ] 3.2 `map.json` published by the mod (normalized coords + labels)
- [ ] 3.3 PWA canvas: bases as regions, machines as icons by type, Pals as dots.
      Each machine shows its live state: current recipe + remaining, or idle, or
      `stalled` (placed, not producing — no power/Pal/fuel), from `state.json`.
- [ ] 3.4 Tap a machine → order sheet prefilled, with the 1.8 mode toggle:
      "this machine (queue if busy)" vs "any free machine".
- [ ] 3.5 (later) overlay on the real Palworld map image

## STAGE 4 — Cloud Worker + PWA wired to live data

**Architecture note (2026-09-09):** for a published app the Worker must be
**multi-tenant** — ONE Worker (we host it), each user pastes their own credentials
in the app; never "deploy your own Worker". Two connection paths, offered in the app:
  - **Host API** (DatHost etc.): user generates an API key in their host panel,
    pastes it in the app. Worker talks to the host's file API. No FTP. Works today
    for DatHost (`api/0.1/game-servers/{id}/files`, key auth).
  - **Mod push** (any host, incl. self-host): user sets `WorkerBaseUrl` + a
    `ServerToken` in `config.ini` once. The mod does outbound HTTPS — POSTs
    inventory/state, polls orders/rules. App only ever talks to the Worker, keyed
    by that token. No host API, no FTP, host-agnostic. NEEDS: outbound HTTP from
    UE4SS-Lua — not built in; likely via the C++ bridge or `FHttpModule` reflection.

- [ ] 4.1 Multi-tenant Worker: per-user record (host+id+key OR serverToken) in KV; `APP_TOKEN` becomes a per-user thing
- [ ] 4.2 `wrangler kv namespace create` → fill `cloud/wrangler.toml`; `wrangler deploy`
- [ ] 4.3 Test /api/snapshot /orders /rules /health (both connection paths)
- [ ] 4.4 Mod → Worker push: outbound HTTPS from the mod (bridge or FHttpModule); config WorkerBaseUrl+ServerToken
- [ ] 4.5 PWA points at the live Worker; inventory view real
- [ ] 4.6 PWA order flow: create → shows "placed" from state.json
- [ ] 4.7 PWA rules editor
- [ ] 4.8 Onboarding: "connect your server" — pick path, paste key/token, verify, done. One time.
      The hard part isn't the token — it's getting the mod ONTO the server:
      * DatHost (+ API key): near-zero-touch — the app can toggle UE4SS on and
        upload the PalCommand mod folder itself via the API, then configure it.
        User only pastes a key.
      * Other hosts / self-host: user installs the mod manually (standard UE4SS
        mod install — a documented ~10-min step), then connects. Ship a short
        install guide + the packaged mod zip (5.2).
      RCON is not a shortcut: Palworld RCON has no inventory/crafting verbs, the
      mod is required either way.

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
- [x] 5.5 LICENSE + tidy comments <!-- done 2026-09-09 (commit next): MIT LICENSE at
      repo root (Copyright 2026 marcosln). "PalworldMobileBridge" was Codex's own
      earlier working name for THIS project (per user), not a third party -> no
      external attribution owed; reworded the comments in json.lua / discovery.lua /
      main.lua ("standard storage-reflection sequence", "standard compact serializer").
      README: dropped "PBA" from the disclaimer, added a factual "an alternative to a
      client-side automation UI (e.g. PBA)" line + a License section. No PBA code in
      the mod (grep clean). -->

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
- Server was HEAVILY modded (see [[palworld-command-center]]). 2026-09-09 cleanup: PBA
  disabled (deleted its `enabled.txt`), removed CCProbe / PalworldMobileBridge /
  StockSnapshotBridge / RosterProbe. PBA was the lag culprit + fought PalCommand for
  the same stations. DatHost API `DELETE /files/<path>` works (folders too, not blocked).
