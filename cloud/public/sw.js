// Pal Command — service worker
//   app shell:  network-first (so deploys show up), cache fallback for offline
//   /icon/*:    cache-first (icons are effectively immutable)
//   /api/*:     network only
const SHELL = "pc-shell-v3";
const ICONS = "pc-icons-v1";
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

self.addEventListener("fetch", (e) => {
  const { request } = e;
  if (request.method !== "GET") return;
  const url = new URL(request.url);
  if (url.origin !== location.origin) return;
  if (url.pathname.startsWith("/api/")) return; // network only

  if (url.pathname.startsWith("/icon/")) {
    e.respondWith(
      caches.open(ICONS).then((c) =>
        c.match(request).then((hit) => hit || fetch(request).then((res) => {
          if (res.ok) c.put(request, res.clone());
          return res;
        }).catch(() => hit))
      )
    );
    return;
  }

  // app shell — network first
  e.respondWith(
    fetch(request)
      .then((res) => {
        if (res.ok) { const copy = res.clone(); caches.open(SHELL).then((c) => c.put(request, copy)); }
        return res;
      })
      .catch(() => caches.match(request).then((hit) => hit || caches.match("/index.html")))
  );
});
