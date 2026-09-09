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
