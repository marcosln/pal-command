/* Pal Command PWA */
"use strict";

const LS = { url: "pc.url", token: "pc.token", tab: "pc.tab" };
const cfg = {
  url: localStorage.getItem(LS.url) || "",
  token: localStorage.getItem(LS.token) || "",
  demo: false,
};

let SNAP = null;
let rulesDraft = null;
let timer = null;

const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const el = (t, p = {}, kids = []) => {
  const n = document.createElement(t);
  for (const [k, v] of Object.entries(p)) {
    if (k === "class") n.className = v;
    else if (k === "html") n.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") n.addEventListener(k.slice(2), v);
    else if (v != null) n.setAttribute(k, v);
  }
  for (const c of [].concat(kids)) if (c != null) n.append(c.nodeType ? c : document.createTextNode(String(c)));
  return n;
};

const NAMES = {
  Pal_crystal_S: "Fragmento de Paldium", Stone: "Piedra", Wood: "Madera", Ingot: "Lingote",
  CopperIngot: "Lingote de cobre", CharcoalFragment: "Carbón", Charcoal: "Carbón", Nail: "Clavo",
  Cloth: "Tela", Gunpowder: "Pólvora", RefinedIngot: "Lingote refinado", PalMetalIngot: "Lingote de metal Pal",
  CrudeOil: "Petróleo crudo", HighQualityPalOil: "Aceite Pal de alta calidad", Flour: "Harina", Bread: "Pan",
  CarbonFiber: "Fibra de carbono", CementConcrete: "Cemento", Cement: "Cemento", PolymerMaterial: "Polímero",
  ElectronicCircuit: "Circuito", Sulfur: "Azufre", Quartz: "Cuarzo", Coal: "Carbón mineral", PalSphere: "Pal Sphere",
};
const nice = (id) => NAMES[id] || String(id || "").replace(/^Pal_/, "").replace(/_/g, " ");
const num = (n) => String(Math.round(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, " ");
const ago = (iso) => {
  if (!iso) return "";
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (s < 60) return "hace " + Math.round(s) + "s";
  if (s < 3600) return "hace " + Math.round(s / 60) + "m";
  return "hace " + Math.round(s / 3600) + "h";
};

// ------------------------------------------------------------------ api

async function api(path, opts = {}) {
  if (cfg.demo) return demoApi(path, opts);
  const r = await fetch(cfg.url.replace(/\/$/, "") + path, {
    ...opts,
    headers: { "content-type": "application/json", authorization: "Bearer " + cfg.token, ...(opts.headers || {}) },
  });
  const body = await r.json().catch(() => ({}));
  if (!r.ok) throw new Error(body.error || body.detail || "HTTP " + r.status);
  return body;
}

// ------------------------------------------------------------------ chrome

const VIEWS = ["stock", "order", "rules", "status"];

function show(tab) {
  if (!VIEWS.includes(tab)) tab = "stock";
  localStorage.setItem(LS.tab, tab);
  VIEWS.forEach((t) => ($("#v-" + t).hidden = t !== tab));
  $$("#tabs button").forEach((b) => b.setAttribute("aria-selected", b.dataset.tab === tab));
  if (tab === "rules") renderRules();
}

function strip() {
  const s = SNAP?.state;
  const box = $("#strip");
  box.hidden = false;
  const b = s?.backend || s?.engine?.backend;
  const dot = box.querySelector(".dot");
  box.className = "strip " + (b === "native" ? "native" : b === "replay" ? "replay" : "");
  let t = !b ? "Sin datos del servidor"
    : b === "native" ? "Autónomo · las órdenes se colocan solas"
    : "Al craftear · se colocan cuando alguien fabrica";
  if (s?.lastError) { box.classList.add("bad"); t = "Aviso: " + s.lastError; }
  $("#stripText").textContent = t;
  $("#stripSync").textContent = s?.lastScan ? ago(s.lastScan) : SNAP ? ago(SNAP.fetchedAt) : "";
  const depth = s?.queueDepth ?? 0;
  $("#ver").textContent = depth > 0 ? depth + " en cola" : "";
}

function toast(msg, bad = false) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "toast show" + (bad ? " bad" : "");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => (t.className = "toast"), 2800);
}

// ------------------------------------------------------------------ render

function renderStock() {
  const inv = SNAP?.inventory;
  const list = $("#stockList");
  const bases = $("#stockBases");
  list.innerHTML = "";
  bases.innerHTML = "";
  $("#stockCount").textContent = inv ? `${inv.diagnostics?.baseCount ?? 0} bases · ${inv.diagnostics?.containerCount ?? 0} cofres` : "";
  if (!inv) { list.append(el("div", { class: "empty" }, "El mod aún no publicó inventario.")); return; }

  const q = ($("#stockSearch").value || "").toLowerCase().trim();
  const rows = Object.entries(inv.totals || {})
    .filter(([id]) => !q || id.toLowerCase().includes(q) || nice(id).toLowerCase().includes(q))
    .sort((a, b) => b[1] - a[1]);
  if (!rows.length) list.append(el("div", { class: "empty" }, q ? "Nada coincide." : "Almacén vacío."));
  for (const [id, n] of rows) {
    list.append(el("div", { class: "row" }, [
      el("span", { class: "name" }, [el("span", { class: "n" }, nice(id)), el("span", { class: "id" }, id)]),
      el("span", { class: "qty" }, num(n)),
    ]));
  }

  for (const base of inv.bases || []) {
    const card = el("div", { class: "card" });
    card.append(el("div", { class: "head" }, [el("h3", {}, base.name)]));
    for (const c of base.containers || []) {
      const items = Object.entries(c.items || {}).sort((a, b) => b[1] - a[1]);
      const d = el("details");
      d.append(el("summary", {}, `${c.name} · ${items.length}`));
      const led = el("div", { class: "ledger" });
      for (const [id, n] of items) led.append(el("div", { class: "row" }, [
        el("span", { class: "name" }, [el("span", { class: "n" }, nice(id))]),
        el("span", { class: "qty" }, num(n)),
      ]));
      d.append(led);
      card.append(d);
    }
    bases.append(card);
  }
  if (inv.guildChest?.available) {
    const items = Object.entries(inv.guildChest.items || {}).sort((a, b) => b[1] - a[1]);
    const card = el("div", { class: "card" });
    card.append(el("div", { class: "head" }, [el("h3", {}, "Cofre de gremio")]));
    const led = el("div", { class: "ledger" });
    for (const [id, n] of items) led.append(el("div", { class: "row" }, [
      el("span", { class: "name" }, [el("span", { class: "n" }, nice(id))]),
      el("span", { class: "qty" }, num(n)),
    ]));
    card.append(led);
    bases.append(card);
  }
}

function renderOrder() {
  const st = SNAP?.stations;
  const sel = $("#ordRecipe");
  const floor = $("#floorList");
  floor.innerHTML = "";
  $("#floorCount").textContent = st ? String(st.stations?.length ?? 0) : "";

  const recipes = new Map();
  for (const s of st?.stations || []) {
    for (const r of s.recipes || []) {
      if (!recipes.has(r)) recipes.set(r, new Set());
      recipes.get(r).add(s.baseName);
    }
    floor.append(el("div", { class: "row" }, [
      el("span", { class: "name" }, [el("span", { class: "n" }, s.baseName)]),
      el("span", { class: "chip " + (s.state?.workable ? "run" : "idle") },
        s.state?.workable ? `${nice(s.state.recipe)} ·${s.state.remaining}` : "libre"),
    ]));
  }
  if (!recipes.size) floor.append(el("div", { class: "empty" }, "Sin estaciones. ¿El mod está activo y hay un mundo cargado?"));

  const cur = sel.value;
  sel.innerHTML = "";
  [...recipes.keys()].sort((a, b) => nice(a).localeCompare(nice(b))).forEach((id) => {
    sel.append(el("option", { value: id }, `${nice(id)}  —  ${[...recipes.get(id)].join(", ")}`));
  });
  if (cur && recipes.has(cur)) sel.value = cur;
  $("#ordHint").textContent = recipes.size ? "El pedido entra a la cola y se coloca en una estación libre." : "";
}

function ruleRow(rule, i) {
  const dirty = () => ($("#rulesSave").hidden = false);
  const set = (k, v) => { rule[k] = v; dirty(); };
  const card = el("div", { class: "card", style: "margin:0;padding:12px" });
  card.append(el("div", { class: "inline" }, [
    el("input", { class: "grow", value: rule.item || "", placeholder: "Item (p.ej. Pal_crystal_S)", oninput: (e) => set("item", e.target.value.trim()) }),
    el("label", { class: "chk" }, [el("input", { type: "checkbox", checked: rule.enabled !== false ? "" : null, onchange: (e) => set("enabled", e.target.checked) }), "on"]),
  ]));
  const g = el("div", { class: "trio", style: "margin-top:9px" });
  for (const [k, lbl] of [["min", "mínimo"], ["target", "objetivo"], ["batch", "tanda"]]) {
    g.append(el("label", {}, [
      lbl,
      el("input", { type: "number", inputmode: "numeric", value: rule[k] ?? "", oninput: (e) => set(k, e.target.value === "" ? undefined : Number(e.target.value)) }),
    ]));
  }
  card.append(g);
  card.append(el("button", { class: "link", onclick: () => { rulesDraft.splice(i, 1); renderRules(); dirty(); } }, "Borrar regla"));
  return card;
}

function renderRules() {
  if (!rulesDraft) rulesDraft = JSON.parse(JSON.stringify(SNAP?.rules?.rules || []));
  const wrap = $("#rulesList");
  wrap.innerHTML = "";
  if (!rulesDraft.length) wrap.append(el("div", { class: "empty" }, "Sin reglas todavía."));
  rulesDraft.forEach((r, i) => wrap.append(ruleRow(r, i)));
}

function renderStatus() {
  const s = SNAP?.state;
  const body = $("#statusBody");
  body.innerHTML = "";
  const line = (k, v, cls) => body.append(el("div", { class: "row" }, [
    el("span", { class: "name" }, [el("span", { class: "n" }, k)]),
    el("span", { class: cls || "qty" }, String(v)),
  ]));
  if (!s) body.append(el("div", { class: "empty" }, "Sin estado."));
  else {
    line("Modo", s.backend === "native" ? "autónomo" : "al craftear");
    line("Hook", s.hookInstalled ? "instalado" : "no");
    line("En cola", s.queueDepth ?? 0);
    line("Colocadas", s.engine?.placed ?? 0);
    line("Fallidas", s.engine?.failed ?? 0);
    line("Último escaneo", s.lastScan ? ago(s.lastScan) : "—");
    if (s.lastError) line("Aviso", s.lastError, "err");
  }
  const q = $("#queueList");
  q.innerHTML = "";
  $("#queueCount").textContent = String((s?.queue || []).length);
  for (const o of s?.queue || []) q.append(el("div", { class: "row" }, [
    el("span", { class: "name" }, [el("span", { class: "n" }, `${nice(o.recipe)} ×${o.count}`), o.source ? el("span", { class: "chip src" }, o.source) : null]),
    el("button", { class: "mini ghost", onclick: () => removeOrder(o.id) }, "Quitar"),
  ]));
  if (!(s?.queue || []).length) q.append(el("div", { class: "empty" }, "Nada en cola."));
  const r = $("#recentList");
  r.innerHTML = "";
  const recent = (s?.recent || []).slice().reverse();
  for (const x of recent) r.append(el("div", { class: "row" }, [
    el("span", { class: "name" }, [el("span", { class: "n" }, `${nice(x.recipe)} ×${x.count}`)]),
    el("span", { class: "chip " + (x.result === "placed" ? "run" : "idle"), style: x.result !== "placed" ? "color:var(--bad)" : "" }, x.result),
  ]));
  if (!recent.length) r.append(el("div", { class: "empty" }, "—"));
}

function renderAll() {
  strip();
  renderStock();
  renderOrder();
  renderStatus();
  if (!$("#v-rules").hidden) renderRules();
}

// ------------------------------------------------------------------ actions

async function refresh(opts = {}) {
  try {
    SNAP = await api("/api/snapshot" + (opts.fresh ? "?fresh=1" : ""));
    if ($("#rulesSave").hidden) rulesDraft = null; // no unsaved edits -> adopt server rules
    renderAll();
  } catch (e) {
    if (/unauthorized/i.test(e.message)) return gotoSetup();
    toast(e.message, true);
  }
}

async function order() {
  const recipe = $("#ordRecipe").value;
  const count = Math.max(1, Math.floor(Number($("#ordCount").value) || 0));
  if (!recipe || !count) return;
  $("#ordGo").disabled = true;
  try {
    await api("/api/orders", { method: "POST", body: JSON.stringify({ recipe, count, transport: $("#ordTransport").checked }) });
    toast(`En cola: ${nice(recipe)} ×${count}`);
    await refresh({ fresh: true });
  } catch (e) { toast(e.message, true); }
  $("#ordGo").disabled = false;
}

async function removeOrder(id) {
  try { await api("/api/orders/" + encodeURIComponent(id), { method: "DELETE" }); await refresh({ fresh: true }); }
  catch (e) { toast(e.message, true); }
}

async function saveRules() {
  try {
    const res = await api("/api/rules", { method: "PUT", body: JSON.stringify({ rules: rulesDraft }) });
    rulesDraft = res.rules || rulesDraft;
    $("#rulesSave").hidden = true;
    toast("Reglas guardadas");
    await refresh({ fresh: true });
  } catch (e) { toast(e.message, true); }
}

// ------------------------------------------------------------------ boot

function gotoSetup() {
  stop();
  $("#strip").hidden = true;
  $("#tabs").hidden = true;
  $("#v-setup").hidden = false;
  VIEWS.forEach((t) => ($("#v-" + t).hidden = true));
}

function gotoApp() {
  $("#v-setup").hidden = true;
  $("#tabs").hidden = false;
  show(localStorage.getItem(LS.tab) || "stock");
  refresh();
  start();
}

function start() { stop(); timer = setInterval(() => refresh(), 20000); }
function stop() { if (timer) clearInterval(timer); timer = null; }

$("#cfgSave").addEventListener("click", async () => {
  const url = $("#cfgUrl").value.trim();
  const token = $("#cfgToken").value.trim();
  $("#cfgErr").hidden = true;
  if (!url || !token) { $("#cfgErr").textContent = "Faltan datos."; $("#cfgErr").hidden = false; return; }
  cfg.url = url; cfg.token = token; cfg.demo = false;
  try {
    await api("/api/snapshot");
    localStorage.setItem(LS.url, url);
    localStorage.setItem(LS.token, token);
    gotoApp();
  } catch (e) {
    $("#cfgErr").textContent = "No conecta: " + e.message;
    $("#cfgErr").hidden = false;
  }
});
$("#cfgDemo").addEventListener("click", () => { cfg.demo = true; gotoApp(); toast("Demostración con datos de ejemplo"); });
$("#forget").addEventListener("click", () => { localStorage.clear(); location.reload(); });
$("#ordGo").addEventListener("click", order);
$("#rulesSave").addEventListener("click", saveRules);
$("#ruleAdd").addEventListener("click", () => { (rulesDraft ||= []).push({ item: "", min: 0, target: 0, enabled: true }); renderRules(); $("#rulesSave").hidden = false; });
$("#stockSearch").addEventListener("input", renderStock);
$$("#tabs button").forEach((b) => b.addEventListener("click", () => show(b.dataset.tab)));
document.addEventListener("visibilitychange", () => { if (!document.hidden && $("#v-setup").hidden) refresh(); });

if ("serviceWorker" in navigator && location.protocol === "https:") {
  navigator.serviceWorker.register("/sw.js").catch(() => {});
}

if (cfg.url && cfg.token) gotoApp();
else gotoSetup();

// ------------------------------------------------------------------ demo

function demoApi(path, opts) {
  if (path.startsWith("/api/snapshot")) return Promise.resolve(structuredClone(DEMO));
  if (path.startsWith("/api/orders") && opts.method === "POST") {
    const b = JSON.parse(opts.body);
    DEMO.state.queue.push({ id: "d" + Date.now(), recipe: b.recipe, count: b.count, source: "orden" });
    DEMO.state.queueDepth = DEMO.state.queue.length;
    return Promise.resolve({ ok: true });
  }
  if (path.startsWith("/api/orders/") && opts.method === "DELETE") {
    const id = decodeURIComponent(path.split("/").pop());
    DEMO.state.queue = DEMO.state.queue.filter((o) => o.id !== id);
    DEMO.state.queueDepth = DEMO.state.queue.length;
    return Promise.resolve({ ok: true });
  }
  if (path.startsWith("/api/rules")) {
    DEMO.rules.rules = JSON.parse(opts.body).rules;
    return Promise.resolve({ ok: true, rules: DEMO.rules.rules });
  }
  return Promise.resolve({});
}

const DEMO = {
  fetchedAt: new Date().toISOString(),
  inventory: {
    diagnostics: { baseCount: 2, containerCount: 5, complete: true },
    totals: { Stone: 5720, Wood: 1840, Nail: 210, Sulfur: 178, Pal_crystal_S: 128, Ingot: 96, CrudeOil: 79, CharcoalFragment: 40, Cloth: 12 },
    bases: [
      { name: "Base principal", containers: [
        { name: "Cofre 1", items: { Stone: 5200, Wood: 1500 } },
        { name: "Cofre 2", items: { Ingot: 96, Nail: 210, Cloth: 12 } },
      ] },
      { name: "Base minera", containers: [
        { name: "Cofre 1", items: { Stone: 520, Sulfur: 178, CrudeOil: 79, CharcoalFragment: 40 } },
      ] },
    ],
    guildChest: { available: true, items: { Pal_crystal_S: 128 } },
  },
  stations: {
    stations: [
      { key: "b1|crush", baseName: "Base principal", recipes: ["Pal_crystal_S", "CharcoalFragment"], state: { recipe: "None", remaining: 0, workable: false } },
      { key: "b1|furn", baseName: "Base principal", recipes: ["Ingot", "CopperIngot", "RefinedIngot"], state: { recipe: "Ingot", remaining: 32, workable: true } },
      { key: "b2|crush", baseName: "Base minera", recipes: ["Pal_crystal_S"], state: { recipe: "None", remaining: 0, workable: false } },
    ],
  },
  state: {
    backend: "replay", hookInstalled: true, queueDepth: 1,
    lastScan: new Date(Date.now() - 42000).toISOString(),
    queue: [{ id: "d0", recipe: "Pal_crystal_S", count: 200, source: "regla:paldium" }],
    recent: [
      { recipe: "Nail", count: 100, result: "placed" },
      { recipe: "Ingot", count: 50, result: "placed" },
      { recipe: "Cloth", count: 20, result: "dropped" },
    ],
    engine: { backend: "replay", placed: 12, failed: 1 },
  },
  rules: { rules: [{ id: "paldium", item: "Pal_crystal_S", recipe: "Pal_crystal_S", min: 300, target: 1000, batch: 200, enabled: true }] },
  orders: [],
};
