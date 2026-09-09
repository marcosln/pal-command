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

- [x] 1.1 Multi-machine place + whole-queue drain <!-- done 2026-09-09: commit 761d03c; M.place iterates all stations for a recipe, native_tick chains next order -->
- [ ] 1.2 Per-machine identity (persistent mapId) + world position + machine type
      <!-- in progress: station-probe one-shot deployed to read real reflection names; wire from station-probe.json -->
- [ ] 1.3 **Live test**: player connected → queue orders to ≥2 different machines/bases → every one gets its recipe + a Pal works it + product lands in a chest. Full log.
- [ ] 1.4 Edge cases: target machine busy → fall to next; recipe nobody can make; not enough materials (report, don't spin); cancel an in-flight order; order for a machine that no longer exists after restart
- [ ] 1.5 "Craft X on ALL machines that can" — batch order fan-out
- [ ] 1.6 Stress: full queue (8+), verify drain, timing, and that joins never block
- [ ] 1.7 Replay fallback still correct when native is off (same-length recipe ids)

## STAGE 2 — Standing rules polished

- [ ] 2.1 Rule eval vs live inventory verified end-to-end
- [ ] 2.2 Rule types: keep item ≥ N; keep ≤ N in progress; scope to a base/machine
- [ ] 2.3 No spam — respect in-flight + cooldowns
- [ ] 2.4 Rules survive restart; test with a real low-stock trigger

## STAGE 3 — Easy 2D map (schematic)

- [ ] 3.1 Read positions: bases, machines, chests, Pals (needs 1.2 position work)
- [ ] 3.2 `map.json` published by the mod (normalized coords + labels)
- [ ] 3.3 PWA canvas: bases as regions, machines as icons by type, Pals as dots
- [ ] 3.4 Tap a machine → order sheet prefilled
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

- [ ] 5.1 PWA install / icon / offline / theme
- [ ] 5.2 Mod packaging + install README for strangers
- [ ] 5.3 Publish mod (Nexus)
- [ ] 5.4 App distribution (PWA link / TestFlight)

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
