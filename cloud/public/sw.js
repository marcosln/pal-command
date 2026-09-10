// Pal Command — service worker
//   app shell:  network-first (so deploys show up), cache fallback for offline
//   /icon/*:    stale-while-revalidate, but only ever cache/serve a 200
//   /api/*:     network only
const SHELL = "pc-shell-v4";
const ICONS = "pc-icons-v3";
const SHELL_URLS = ["/", "/index.html", "/app.js", "/manifest.json", "/icon.svg"];

self.addEventListener("install", (e) => {
  e.waitUntil(caches.open(SHELL).then((c) => c.addAll(SHELL_URLS)).then(() => self.skipWaiting()));
});

self.addEventListener("activate", (e) => {
  e.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== SHELL && k !== ICONS).map((k) => caches.delete(k))))
      .then(() => self.clients.claim())
  );
});

// A never-fails fallback so respondWith() always gets a real Response.
const miss = () => new Response("", { status: 504, headers: { "content-type": "text/plain" } });

async function icon(request) {
  const cache = await caches.open(ICONS);
  const hit = await cache.match(request);
  // Only trust a cached 200 — a stale 404/gif from an older build must not stick.
  if (hit && hit.ok) {
    // refresh in the background, don't block paint
    fetch(request).then((res) => { if (res && res.ok) cache.put(request, res.clone()); }).catch(() => {});
    return hit;
  }
  try {
    const res = await fetch(request);
    if (res && res.ok) cache.put(request, res.clone());
    return res || miss();
  } catch {
    return hit || miss();
  }
}

async function shell(request) {
  try {
    const res = await fetch(request);
    if (res && res.ok) { const copy = res.clone(); caches.open(SHELL).then((c) => c.put(request, copy)); }
    return res || miss();
  } catch {
    return (await caches.match(request)) || (await caches.match("/index.html")) || miss();
  }
}

self.addEventListener("fetch", (e) => {
  const { request } = e;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== location.origin) return;
  if (url.pathname.startsWith("/api/")) return;                 // network only
  if (url.pathname.startsWith("/icon/")) { e.respondWith(icon(request)); return; }
  e.respondWith(shell(request));
});
