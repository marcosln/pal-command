// Pal Command -- Cloudflare Worker
//
// Serves the PWA (static assets) and a small JSON API. The API is an
// authenticated bridge to the PalCommand mod's data files, which it reads/writes
// through the host's file API (DatHost for v1). Secrets never reach the browser.
//
// Routes
//   GET  /api/snapshot          -> { inventory, stations, state, rules, orders }
//   POST /api/orders            -> add an immediate craft order
//   DELETE /api/orders/:id      -> remove a queued order
//   PUT  /api/rules             -> replace the standing-rules list
//   GET  /api/health
//
// Auth: every /api call needs  Authorization: Bearer <APP_TOKEN>
//
// Bindings: ASSETS (static), CACHE (KV)
// Secrets:  APP_TOKEN, DATHOST_USER, DATHOST_KEY
// Vars:     DATHOST_SERVER_ID, MOD_DATA_PATH, SNAPSHOT_TTL_SECONDS

const JSON_HEADERS = { "content-type": "application/json; charset=utf-8" };

export default {
  async fetch(request, env, ctx) {
    const url = new URL(request.url);
    if (url.pathname.startsWith("/icon/")) {
      return iconProxy(url.pathname.slice("/icon/".length), request, ctx);
    }
    if (!url.pathname.startsWith("/api/")) {
      return env.ASSETS.fetch(request);
    }
    try {
      return await handleApi(request, env, ctx, url);
    } catch (err) {
      return json({ error: "internal", detail: String(err && err.message || err) }, 500);
    }
  },
};

// ------------------------------------------------------------------ item icons
// GET /icon/<ItemId>  ->  the item's icon (webp), proxied + edge-cached from
// paldb.cc. First hit resolves the CDN url (see resolveIcon); a miss returns a
// text/plain 404 and the app draws a letter tile in its place.

// paldb.cc slugs are display-name based, not the game's internal ids. Map the
// mismatches; everything else we try as-is (many ids do resolve).
const ICON_ALIAS = {
  Pal_crystal_S: "Paldium_Fragment", Pal_crystal_S_2: "Paldium_Fragment", Pal_crystal_S_3: "Paldium_Fragment",
  CopperIngot: "Ingot", IronIngot: "Refined_Ingot", StealIngot: "Pal_Metal_Ingot", StainlessSteel: "Pal_Metal_Ingot",
  CopperOre: "Ore", ManganeseOre: "Ore", GunPowder2: "Gunpowder", Cloth2: "Cloth", MachineParts2: "MachineParts",
  Wood_Fine: "Lumber", Processed_Wood: "Lumber", HighGrade_Processed_Wood: "Lumber",
  Computer: "Circuit_Board", CarbonFiber: "Carbon_Fiber", Plastic: "Polymer",
  ElectricOrgan: "Electric_Organ", FireOrgan: "Flame_Organ", IceOrgan: "Ice_Organ", bone: "Bone",
  PalOil: "High_Quality_Pal_Oil", CrudeOil: "Crude_Oil", PalFluid: "Pal_Fluid",
  RainbowCrystal: "Rainbow_Crystal", PalCrystal_Ex: "Large_Pal_Soul", MeteorDrop: "Meteorite_Fragment",
  AncientParts3: "Ancient_Civilization_Part", AncientParts2: "Ancient_Civilization_Part",
  Berries: "Red_Berries", BerrySeeds: "Berry_Seeds", Medicines: "Low_Grade_Medical_Supplies",
  LuxuryMedicines: "High_Grade_Medical_Supplies", Herbs: "Medicinal_Herbs",
  Honey: "Honey", Wheat: "Wheat", Egg: "Egg", Milk: "Milk", Flour: "Flour",
};

// bump the version segment to flush the edge cache after a resolver change
const ICON_KEY = "/icon/v9/";

function iconCandidates(id) {
  const out = [];
  const push = (s) => { if (s && !out.includes(s)) out.push(s); };
  push(ICON_ALIAS[id]);
  push(id);
  push(id.replace(/_\d+$/, ""));                       // Katana_2 -> Katana
  const noBp = id.replace(/^Blueprint_/, "");
  if (noBp !== id) { push(noBp); push(noBp.replace(/_\d+$/, "")); }
  return out.slice(0, 4);
}

async function warmIcons(inventory, origin, ctx) {
  const ids = Object.keys((inventory && inventory.totals) || {}).slice(0, 60);
  const cache = caches.default;
  let inflight = 0, i = 0;
  // keep it gentle — paldb 429s a burst, and a cached miss is retried on the
  // next snapshot anyway (short 404 TTL).
  const next = async () => {
    while (i < ids.length && inflight < 2) {
      const id = ids[i++]; inflight++;
      const key = new Request(origin + ICON_KEY + id, { method: "GET" });
      cache.match(key).then(async (hit) => {
        // retry misses too — the first pass often 429s a few, and the negative
        // cache is short, so the next snapshot's pass mops them up.
        if (!hit || !hit.ok) { try { await resolveIcon(id, cache, key); } catch {} }
        inflight--; next();
      });
    }
  };
  await next();
}

// shared by /icon and the pre-warm.
//   1) canonical og:image off the paldb item page (authoritative; skips the
//      per-page nav icons that made every unknown item resolve to a cleaver)
//   2) direct CDN name guess for textures paldb has but doesn't index by slug
//      (Sulfur, Coal, Quartz ...)
//   3) 404 -> the app draws a letter tile
async function resolveIcon(id, cache, key) {
  const UA = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/126.0 Safari/537.36";
  const CDN = "https://cdn.paldb.cc/image/Others/InventoryItemIcon/Texture/T_itemicon_";

  const asIcon = async (u) => {
    try {
      const img = await fetch(u, { cf: { cacheTtl: 604800, cacheEverything: true } });
      const ct = img.headers.get("content-type") || "";
      // the paldb CDN serves webp with an empty content-type, so trust img.ok and
      // just reject an HTML/JSON error body served with a 200.
      if (img.ok && !/text\/html|application\/json/i.test(ct)) {
        return new Response(img.body, { status: 200, headers: {
          "content-type": ct && /image\//i.test(ct) ? ct : "image/webp",
          // long-lived but revalidatable — never 'immutable', so a bad resolve
          // can still be corrected without a namespace bump.
          "cache-control": "public, max-age=604800, stale-while-revalidate=86400" } });
      }
    } catch { /* miss */ }
    return null;
  };

  const getPage = async (cand) => {
    const u = "https://paldb.cc/en/" + encodeURIComponent(cand);
    const opt = { headers: { "user-agent": UA, "accept": "text/html", "accept-language": "en" }, cf: { cacheTtl: 86400, cacheEverything: true } };
    let r = await fetch(u, opt);
    if ((r.status === 429 || r.status === 503) ) { await new Promise((s) => setTimeout(s, 800)); r = await fetch(u, opt); }
    return r;
  };

  let out = null;

  for (const cand of iconCandidates(id)) {
    try {
      const page = await getPage(cand);
      if (!page.ok) continue;
      const html = await page.text();
      const m = html.match(/property=["']og:image["'][^>]*content=["']([^"']+)["']/i)
             || html.match(/content=["']([^"']+)["'][^>]*property=["']og:image["']/i);
      if (m && /T_itemicon_/i.test(m[1]) && !/unknown/i.test(m[1])) {
        out = await asIcon(m[1]);
        if (out) break;
      }
    } catch { /* next candidate */ }
  }

  if (!out) {
    // paldb's texture names mirror the game's internal ids
    // (T_itemicon_Material_CopperIngot, T_itemicon_Ammo_RifleBullet); the raw id
    // is the best guess, the alias slug the runner-up.
    const names = [...new Set([id, id.replace(/_\d+$/, ""), ICON_ALIAS[id]].filter(Boolean))];
    outer: for (const n of names) {
      for (const g of [`Material_${n}`, `Food_${n}`, `Consume_${n}`, `Ammo_${n}`, `Weapon_${n}`, `Armor_${n}`, n]) {
        out = await asIcon(CDN + g + ".webp");
        if (out) break outer;
      }
    }
  }

  // cache a miss only very briefly — paldb 429s under a cold-start burst, so a
  // miss is often transient; a short negative TTL lets the next request (or the
  // next snapshot's warm pass) retry without hammering on every hit.
  if (!out) out = new Response("no icon", { status: 404, headers: { "content-type": "text/plain", "cache-control": "public, max-age=45" } });
  await cache.put(key, out.clone());
  return out;
}

async function iconProxy(rawId, request, ctx) {
  // path may carry a cache-epoch segment: /icon/<epoch>/<id>. It only exists to
  // give the whole icon namespace a fresh URL when a bad resolve got pinned in
  // the edge cache with immutable; we don't otherwise care about its value.
  rawId = rawId.replace(/^[a-z]\d+\//i, "");
  const id = rawId.replace(/[^A-Za-z0-9_.-]/g, "").slice(0, 80);
  if (!id) return new Response("bad id", { status: 404, headers: { "content-type": "text/plain" } });
  const cache = caches.default;
  const key = new Request(new URL(request.url).origin + ICON_KEY + id, { method: "GET" });
  return (await cache.match(key)) || resolveIcon(id, cache, key);
}

// ------------------------------------------------------------------ helpers

function json(body, status = 200, extraHeaders = {}) {
  return new Response(JSON.stringify(body), { status, headers: { ...JSON_HEADERS, ...extraHeaders } });
}

function authorized(request, env) {
  const h = request.headers.get("authorization") || "";
  const m = h.match(/^Bearer\s+(.+)$/i);
  return m && env.APP_TOKEN && timingSafeEqual(m[1], env.APP_TOKEN);
}

function timingSafeEqual(a, b) {
  if (typeof a !== "string" || typeof b !== "string" || a.length !== b.length) return false;
  let r = 0;
  for (let i = 0; i < a.length; i++) r |= a.charCodeAt(i) ^ b.charCodeAt(i);
  return r === 0;
}

// ------------------------------------------------------------------ DatHost file API

function dathost(env) {
  const id = env.DATHOST_SERVER_ID;
  const base = `https://dathost.com/api/0.1/game-servers/${id}`;
  const auth = "Basic " + btoa(`${env.DATHOST_USER}:${env.DATHOST_KEY}`);
  const dataPath = (env.MOD_DATA_PATH || "Binaries/Win64/ue4ss/Mods/PalCommand/data").replace(/\/$/, "");

  async function mountOverlay() {
    // DatHost serves a cached overlay view of the filesystem; nudge it before reads.
    await fetch(`${base}/mount-overlay`, { method: "POST", headers: { authorization: auth } }).catch(() => {});
  }

  async function readFile(name) {
    const r = await fetch(`${base}/files/${dataPath}/${name}?_=${Date.now()}`, {
      headers: { authorization: auth }, cf: { cacheTtl: 0 },
    });
    if (r.status === 404) return null;
    if (!r.ok) throw new Error(`dathost read ${name}: ${r.status}`);
    return await r.text();
  }

  async function writeFile(name, content) {
    const fd = new FormData();
    fd.append("file", new Blob([content], { type: "application/json" }), name);
    const r = await fetch(`${base}/files/${dataPath}/${name}`, {
      method: "POST", headers: { authorization: auth }, body: fd,
    });
    if (!r.ok) throw new Error(`dathost write ${name}: ${r.status}`);
  }

  return { mountOverlay, readFile, writeFile };
}

async function readJson(dh, name, fallback) {
  const raw = await dh.readFile(name);
  if (raw == null || raw.trim() === "") return fallback;
  try { return JSON.parse(raw); } catch { return fallback; }
}

// ------------------------------------------------------------------ API

async function handleApi(request, env, ctx, url) {
  const path = url.pathname.replace(/^\/api\//, "");

  if (path === "health") {
    return json({ ok: true, server: env.DATHOST_SERVER_ID ? "configured" : "missing", now: new Date().toISOString() });
  }

  if (!authorized(request, env)) {
    return json({ error: "unauthorized" }, 401);
  }

  const dh = dathost(env);

  // ---- GET /api/snapshot
  if (path === "snapshot" && request.method === "GET") {
    const ttl = parseInt(env.SNAPSHOT_TTL_SECONDS || "15", 10);
    const cacheKey = `snap:${env.DATHOST_SERVER_ID}`;
    if (!url.searchParams.has("fresh")) {
      const cached = await env.CACHE.get(cacheKey, "json");
      if (cached) return json({ ...cached, cached: true });
    }
    await dh.mountOverlay();
    const [inventory, stations, state, rules, orders] = await Promise.all([
      readJson(dh, "inventory.json", null),
      readJson(dh, "stations.json", null),
      readJson(dh, "state.json", null),
      readJson(dh, "rules.json", { rules: [] }),
      readJson(dh, "orders.json", []),
    ]);
    const payload = { inventory, stations, state, rules, orders, fetchedAt: new Date().toISOString() };
    ctx.waitUntil(env.CACHE.put(cacheKey, JSON.stringify(payload), { expirationTtl: Math.max(ttl, 5) }));
    // warm the icon cache for this snapshot's items so the stock tab paints fast.
    // cache-aware + throttled, so after the first poll this is ~free.
    ctx.waitUntil(warmIcons(inventory, new URL(request.url).origin, ctx));
    return json(payload);
  }

  // ---- POST /api/orders   (also accepts { cancel: "<id|recipe|mapId>" | true })
  if (path === "orders" && request.method === "POST") {
    const body = await request.json().catch(() => null);
    await dh.mountOverlay();
    const list = await readJson(dh, "orders.json", []);

    if (body && body.cancel != null) {
      list.push({ cancel: body.cancel });
      await dh.writeFile("orders.json", JSON.stringify(list));
      await env.CACHE.delete(`snap:${env.DATHOST_SERVER_ID}`);
      return json({ ok: true, cancel: body.cancel });
    }
    if (!body || typeof body.recipe !== "string" || !(body.count > 0)) {
      return json({ error: "bad-order", need: "{ recipe, count, transport?, target?, baseId? }" }, 400);
    }
    const order = {
      id: crypto.randomUUID(),
      recipe: body.recipe,
      count: Math.min(Math.floor(body.count), 100000),
      transport: body.transport !== false,
      target: (typeof body.target === "string" && body.target) || undefined,   // machine mapId (hard pin)
      baseId: body.baseId || undefined,
      createdAt: new Date().toISOString(),
    };
    list.push(order);
    await dh.writeFile("orders.json", JSON.stringify(list));
    await env.CACHE.delete(`snap:${env.DATHOST_SERVER_ID}`);
    return json({ ok: true, order });
  }

  // ---- DELETE /api/orders/:id
  const delMatch = path.match(/^orders\/(.+)$/);
  if (delMatch && request.method === "DELETE") {
    const id = decodeURIComponent(delMatch[1]);
    await dh.mountOverlay();
    const list = await readJson(dh, "orders.json", []);
    const next = list.filter((o) => o && o.id !== id);
    await dh.writeFile("orders.json", JSON.stringify(next));
    await env.CACHE.delete(`snap:${env.DATHOST_SERVER_ID}`);
    return json({ ok: true, removed: list.length - next.length });
  }

  // ---- PUT /api/rules
  if (path === "rules" && request.method === "PUT") {
    const body = await request.json().catch(() => null);
    const rules = Array.isArray(body?.rules) ? body.rules : Array.isArray(body) ? body : null;
    if (!rules) return json({ error: "bad-rules", need: "{ rules: [...] }" }, 400);
    const clean = rules
      .filter((r) => r && typeof r.item === "string" && r.item)
      .map((r) => ({
        id: String(r.id || r.item),
        item: r.item,
        recipe: r.recipe || r.item,
        min: Number(r.min) || 0,
        target: Number(r.target) || Number(r.min) || 0,
        batch: r.batch ? Math.max(1, Math.floor(Number(r.batch))) : undefined,
        maxInProgress: r.maxInProgress ? Math.max(1, Math.floor(Number(r.maxInProgress))) : undefined,
        baseId: r.baseId || undefined,
        machine: (typeof r.machine === "string" && r.machine) || undefined,
        transport: r.transport !== false,
        enabled: r.enabled !== false,
      }));
    await dh.writeFile("rules.json", JSON.stringify({ rules: clean }));
    await env.CACHE.delete(`snap:${env.DATHOST_SERVER_ID}`);
    return json({ ok: true, rules: clean });
  }

  return json({ error: "not-found", path, method: request.method }, 404);
}
