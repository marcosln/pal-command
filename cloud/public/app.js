/* Pal Command — base ops console */
"use strict";

const LS = { url: "pc.url", token: "pc.token", tab: "pc.tab", cat: "pc.cat" };
const cfg = {
  url: localStorage.getItem(LS.url) || "",
  token: localStorage.getItem(LS.token) || "",
  demo: false,
};

let SNAP = null;
let rulesDraft = null;
let timer = null;
let activeCat = localStorage.getItem(LS.cat) || "*";
const prevQty = {};

const $ = (s) => document.querySelector(s);
const $$ = (s) => [...document.querySelectorAll(s)];
const el = (t, p = {}, kids = []) => {
  const n = document.createElement(t);
  for (const [k, v] of Object.entries(p)) {
    if (v == null) continue;
    if (k === "class") n.className = v;
    else if (k === "html") n.innerHTML = v;
    else if (k.startsWith("on") && typeof v === "function") n.addEventListener(k.slice(2), v);
    else n.setAttribute(k, v);
  }
  for (const c of [].concat(kids)) if (c != null) n.append(c.nodeType ? c : document.createTextNode(String(c)));
  return n;
};

// ------------------------------------------------------------------ names + categories

const NAMES = {
  Pal_crystal_S: "Fragmento de Paludio", Pal_crystal_S_2: "Fragmento de Paludio", Pal_crystal_S_3: "Fragmento de Paludio",
  Stone: "Piedra", Wood: "Madera", Wood_Fine: "Madera fina", Fiber: "Fibra", PalFluid: "Fluido Pal",
  CopperOre: "Mineral de metal", CopperIngot: "Lingote de metal", IronIngot: "Lingote de metal refinado",
  IronOre: "Mineral de hierro", StealIngot: "Lingote de acero", StainlessSteel: "Acero inoxidable",
  ManganeseOre: "Mineral de manganeso", ManganeseIngot: "Lingote de manganeso", Chromium: "Cromo",
  Charcoal: "Carbón", Coal: "Carbón mineral", Sulfur: "Azufre", Quartz: "Cuarzo", CrudeOil: "Petróleo crudo",
  Cloth: "Tela", Cloth2: "Tela", Leather: "Cuero", Wool: "Lana", Nail: "Clavo", GunPowder2: "Pólvora",
  Plastic: "Plástico", Polymer: "Polímero", CarbonFiber: "Fibra de carbono", Cement: "Cemento",
  MachineParts: "Piezas de máquina", MachineParts2: "Piezas de máquina", Computer: "Circuito",
  Flour: "Harina", Wheat: "Trigo", Bread: "Pan", Berries: "Bayas", Honey: "Miel", Egg: "Huevo", Milk: "Leche",
  Tomato: "Tomate", Lettuce: "Lechuga", Onion: "Cebolla", Potato: "Patata", Carrot: "Zanahoria", Salad: "Ensalada",
  PalSphere: "Pal Sphere", PalSphere_Mega: "Mega Sphere", PalSphere_Giga: "Giga Sphere", PalSphere_Tera: "Tera Sphere",
  Processed_Wood: "Madera procesada", HighGrade_Processed_Wood: "Madera de alta calidad",
  ElectricOrgan: "Órgano eléctrico", FireOrgan: "Llama ardiente", IceOrgan: "Cubito de hielo", bone: "Hueso",
  RainbowCrystal: "Cristal arcoíris", PalCrystal_Ex: "Cristal Pal grande", MeteorDrop: "Fragmento de meteorito",
  AncientParts3: "Pieza de tecnología antigua", Diamond: "Diamante", Ruby: "Rubí", Sapphire: "Zafiro",
};
const nice = (id) => NAMES[id] || String(id || "")
  .replace(/^Pal_|^Blueprint_|^SkillCard_/, "").replace(/_/g, " ").replace(/\b\w/g, (m) => m);

const CATS = [
  ["Recursos",   /^(Stone|Wood|Wood_|Fiber|Leather|Wool|Cloth|Sulfur|Quartz|Coal|CrudeOil|PalFluid|PalOil|bone|Horn|Pal_crystal|RainbowCrystal|PalCrystal|MeteorDrop|Diamond|Ruby|Sapphire|Eemerald|Emerald|CaveMushroom|Venom|Poppy|Wheat|BeastBone|ElectricOrgan|FireOrgan|IceOrgan|Chromium|ManganeseOre|CopperOre|IronOre)/i],
  ["Materiales", /(Ingot|Steel|Steal|Plastic|Polymer|CarbonFiber|Cement|Nail|MachineParts|Computer|Processed_Wood|GunPowder|Cloth2|StainlessSteel|Bio_|Thermal_|Corrosive|Circuit|AncientParts|Wood_Ancient|YakushimaIngot)/i],
  ["Comida",     /(Bak(ed|e)|Soup|Salad|Cake|Bread|Meat|Egg|Milk|Honey|Berries|Juice|Jam|Pie|Stew|Pizza|Roast|Fried|Pancake|Omelet|Mushroom|Flour|Tomato|Lettuce|Onion|Potato|Carrot|Corn|Fruit|Grilled|Hot(Milk|Cocoa)|Yakisoba|Curry|Bacon|Chip|Bun|Pan\b|Sweet|Sandwich|Cheese)/i],
  ["Medicina",   /(Potion|Medicine|Herb|Bandage|Antidote|Splint|Ointment|Opium)/i],
  ["Munición",   /(Bullet|Arrow|Shell|Rocket|Grenade|RoughBullet|BowGun|Ammo)/i],
  ["Esferas",    /(Sphere|SphereModule)/i],
  ["Armas",      /(Bow|Gun|Rifle|Pistol|Sword|Axe|Spear|Knife|Launcher|Shotgun|Musket|Katana|^Bat|Hammer|Pickaxe|Revolver|Blade|Handgun|SMG|FlameThrower|Grappling|Fishing|WeakerBow|SFBow)/i],
  ["Armadura",   /(Armor|Helmet|Shield|Head(Equip|001|002)|ClothArmor|FurArmor|Metal(Armor|Helmet))/i],
  ["Accesorios", /(Accessory|Otomo_|Ring|Amulet|Pendant|Lantern|Glider|Torch|Homeward|Whistle)/i],
  ["Planos",     /^Blueprint_/i],
  ["Cartas",     /^SkillCard_/i],
  ["Pals",       /(PalSummon|PalItem_|PalEgg_|Pal_Egg)/i],
  ["Mejora",     /(PalUpgradeStone|WorkSuitability_|ExpBoost|SkillUnlock|SkillFruit|Lotus_|AffectionFruit|Unlock_|Additional(Inventory|Equipment)|AutoMealPouch)/i],
  ["Varios",     /(Key|TreasureBox|DogCoin|Money|Coin|Ticket|Proof|BountyProof|QuestItem|Salvage)/i],
];
function catOf(id) {
  for (const [name, rx] of CATS) if (rx.test(id)) return name;
  return "Otros";
}
const CAT_ORDER = [...CATS.map((c) => c[0]), "Otros"];

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
const iconUrl = (id) => "/icon/" + encodeURIComponent(id);
const num = (n) => String(Math.round(Number(n) || 0)).replace(/\B(?=(\d{3})+(?!\d))/g, " ");
const shortNum = (n) => { n = Number(n) || 0; return n >= 100000 ? (n / 1000).toFixed(0) + "k" : n >= 10000 ? (n / 1000).toFixed(1).replace(/\.0$/, "") + "k" : num(n); };
const ago = (iso) => {
  if (!iso) return "";
  const s = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  return s < 60 ? Math.round(s) + "s" : s < 3600 ? Math.round(s / 60) + "m" : Math.round(s / 3600) + "h";
};

// ------------------------------------------------------------------ chrome

const VIEWS = ["stock", "order", "rules", "status"];
function show(tab) {
  if (!VIEWS.includes(tab)) tab = "stock";
  localStorage.setItem(LS.tab, tab);
  VIEWS.forEach((t) => ($("#v-" + t).hidden = t !== tab));
  $$("#tabs button").forEach((b) => b.setAttribute("aria-selected", b.dataset.tab === tab));
  if (tab === "rules") renderRules();
  window.scrollTo({ top: 0 });
}

function conn() {
  const c = $("#conn"); c.hidden = false;
  const s = SNAP?.state, b = s?.backend || s?.engine?.backend;
  const player = s?.engine?.connectedPid != null;
  let cls = "", txt = "sin datos", glow = "rgba(234,169,74,.14)";
  if (b === "native") {
    cls = player ? "live" : "wait";
    txt = player ? "en línea" : "sin jugador";
    glow = player ? "rgba(116,207,136,.16)" : "rgba(234,181,74,.15)";
  } else if (b === "replay") { cls = "wait"; txt = "al craftear"; glow = "rgba(234,181,74,.15)"; }
  if (s?.lastError) { cls = "bad"; txt = "aviso"; glow = "rgba(229,113,90,.16)"; }
  c.className = "conn " + cls;
  $("#connText").textContent = txt + (s?.lastScan ? " · " + ago(s.lastScan) : "");
  $("#ambient").style.setProperty("--glow", glow);
}

function toast(msg, bad = false) {
  const t = $("#toast");
  t.textContent = msg;
  t.className = "toast on" + (bad ? " bad" : "");
  clearTimeout(toast._t);
  toast._t = setTimeout(() => (t.className = "toast" + (bad ? " bad" : "")), 2600);
}

function openSheet(nodes) {
  const s = $("#sheet");
  s.innerHTML = "";
  s.append(el("div", { class: "grab" }));
  [].concat(nodes).forEach((n) => s.append(n));
  s.hidden = false; $("#scrim").hidden = false;
  requestAnimationFrame(() => { s.classList.add("on"); $("#scrim").classList.add("on"); });
}
function closeSheet() {
  $("#sheet").classList.remove("on"); $("#scrim").classList.remove("on");
  setTimeout(() => { $("#sheet").hidden = true; $("#scrim").hidden = true; }, 280);
}

// ------------------------------------------------------------------ stock

function slotEl(id, qty, opts = {}) {
  const s = el("div", { class: "slot" + (opts.noimg ? " noimg" : ""), "data-l": (nice(id)[0] || "?").toUpperCase() });
  if (!opts.noimg) {
    const img = el("img", { loading: "lazy", alt: "", src: iconUrl(id) });
    const fail = () => { img.remove(); s.classList.add("noimg"); };
    img.addEventListener("error", fail);
    img.addEventListener("load", () => { if (img.naturalWidth <= 2) fail(); });
    s.append(img);
  }
  if (qty != null) s.append(el("span", { class: "qty" }, shortNum(qty)));
  return s;
}

function renderCatbar(counts) {
  const bar = $("#catbar");
  bar.innerHTML = "";
  const total = Object.values(counts).reduce((a, b) => a + b, 0);
  const mk = (key, label, n) => {
    const b = el("button", { "aria-current": activeCat === key, onclick: () => { activeCat = key; localStorage.setItem(LS.cat, key); renderStock(); } },
      [label, el("span", { class: "c" }, n)]);
    bar.append(b);
  };
  mk("*", "Todo", Object.keys(counts).length ? total : 0);
  for (const c of CAT_ORDER) if (counts[c]) mk(c, c, counts[c]);
}

function renderStock() {
  const inv = SNAP?.inventory;
  const grid = $("#grid");
  const q = ($("#q").value || "").toLowerCase().trim();

  if (!inv) {
    grid.innerHTML = "";
    for (let i = 0; i < 9; i++) grid.append(el("div", { class: "sk" }));
    $("#totline").hidden = true;
    $("#catbar").innerHTML = "";
    return;
  }

  const entries = Object.entries(inv.totals || {});
  const byCat = {};
  for (const [id] of entries) { const c = catOf(id); byCat[c] = (byCat[c] || 0) + 1; }
  renderCatbar(byCat);

  const rows = entries
    .filter(([id]) => activeCat === "*" || catOf(id) === activeCat)
    .filter(([id]) => !q || id.toLowerCase().includes(q) || nice(id).toLowerCase().includes(q))
    .sort((a, b) => b[1] - a[1]);

  const canMake = new Set();
  for (const s of SNAP?.stations?.stations || []) for (const r of s.recipes || []) canMake.add(r);

  $("#totN").textContent = num(rows.reduce((a, [, n]) => a + n, 0));
  $("#totLbl").textContent = `en ${rows.length} items` + (activeCat !== "*" ? ` · ${activeCat}` : "");
  $("#totline").hidden = !rows.length;

  grid.innerHTML = "";
  if (!rows.length) { grid.append(el("div", { class: "empty", style: "grid-column:1/-1" }, q ? "Nada coincide." : "Vacío.")); return; }
  rows.forEach(([id, n], i) => {
    const flash = prevQty[id] != null && prevQty[id] !== n;
    prevQty[id] = n;
    const cell = el("div", {
      class: "cell" + (canMake.has(id) ? " can" : ""),
      style: `animation-delay:${Math.min(i * 12, 260)}ms`,
      onclick: () => itemSheet(id, n),
    }, [slotEl(id, n), el("div", { class: "lbl" }, nice(id))]);
    if (flash) cell.querySelector(".qty").animate(
      [{ background: "var(--brass)", color: "var(--brass-ink)" }, {}], { duration: 900, easing: "ease-out" });
    grid.append(cell);
  });
}

function itemSheet(id, n) {
  const inv = SNAP?.inventory;
  const where = [];
  for (const base of inv?.bases || []) {
    let c = 0;
    for (const ct of base.containers || []) c += (ct.items || {})[id] || 0;
    if (c) where.push([base.name, c]);
  }
  if (inv?.guildChest?.items?.[id]) where.push(["Cofre de gremio", inv.guildChest.items[id]]);

  const canMake = (SNAP?.stations?.stations || []).some((s) => (s.recipes || []).includes(id));
  const body = [
    el("div", { class: "big" }, [
      slotEl(id, null),
      el("div", {}, [el("h2", {}, nice(id)), el("div", { class: "sub" }, `${id} · ${catOf(id)}`)]),
    ]),
    el("div", { class: "totline", style: "margin:14px 0 4px" }, [el("b", {}, num(n)), el("span", {}, "en total")]),
    el("div", { class: "rows" }, where.map(([b, c]) => el("div", { class: "lr" }, [
      el("span", { class: "l" }, [el("span", { class: "n" }, b)]),
      el("span", { class: "num" }, num(c)),
    ]))),
  ];
  if (canMake) body.push(el("button", {
    class: "btn wide", style: "margin-top:14px",
    onclick: () => { closeSheet(); show("order"); const sel = $("#ordRecipe"); if ([...sel.options].some((o) => o.value === id)) { sel.value = id; renderMachines(); } },
  }, "Craftear esto"));
  openSheet(body);
}

// ------------------------------------------------------------------ order

function mLabel(s) {
  const t = String(s.machineType || "").replace(/^BP_BuildObject_|_C$/g, "").replace(/_/g, " ");
  return `${s.baseName} · ${t}`;
}
function mState(s) {
  const st = s.state || {};
  const busy = st.workable || (st.requested || 0) > 0;
  return busy ? `${nice(st.recipe)} ×${st.remaining}` : "libre";
}

function renderMachines() {
  const sel = $("#ordMachine");
  const recipe = $("#ordRecipe").value;
  const forRecipe = (SNAP?.stations?.stations || []).filter((s) => (s.recipes || []).includes(recipe));
  const cur = sel.value;
  sel.innerHTML = "";
  sel.append(el("option", { value: "" }, "▸ Cualquier máquina libre"));
  forRecipe.slice().sort((a, b) => (a.baseName + a.machineType).localeCompare(b.baseName + b.machineType))
    .forEach((s) => s.mapId && sel.append(el("option", { value: s.mapId }, `${mLabel(s)} — ${mState(s)}`)));
  if (cur && [...sel.options].some((o) => o.value === cur)) sel.value = cur;
}

function renderOrder() {
  const st = SNAP?.stations;
  const sel = $("#ordRecipe");
  $("#floorCount").textContent = st ? `${st.stations?.length ?? 0} máquinas` : "";

  const recipes = new Map();
  for (const s of st?.stations || []) for (const r of s.recipes || []) {
    if (!recipes.has(r)) recipes.set(r, new Set());
    recipes.get(r).add(s.baseName);
  }
  const cur = sel.value;
  sel.innerHTML = "";
  [...recipes.keys()].sort((a, b) => nice(a).localeCompare(nice(b)))
    .forEach((id) => sel.append(el("option", { value: id }, nice(id))));
  if (cur && recipes.has(cur)) sel.value = cur;
  renderMachines();
  $("#ordHint").textContent = recipes.size ? "Máquina fija = espera si está ocupada. “Cualquiera” = la primera libre." : "";

  const fg = $("#floorGrid");
  fg.innerHTML = "";
  const list = (st?.stations || []).slice().sort((a, b) => (b.state?.workable ? 1 : 0) - (a.state?.workable ? 1 : 0));
  for (const s of list) {
    const busy = s.state?.workable || (s.state?.requested || 0) > 0;
    fg.append(el("button", {
      class: "mch" + (busy ? " run" : ""),
      onclick: () => {
        show("order");
        const has = (s.recipes || [])[0];
        if (has && [...sel.options].some((o) => o.value === has)) sel.value = has;
        renderMachines();
        if (s.mapId) $("#ordMachine").value = s.mapId;
        toast(`Fijado: ${mLabel(s)}`);
      },
    }, [
      el("span", { class: "t" }, mLabel(s).split(" · ")[1] || "?"),
      el("span", { class: "s" }, `${mLabel(s).split(" · ")[0]} — ${mState(s)}`),
    ]));
  }
  if (!list.length) fg.append(el("div", { class: "empty", style: "grid-column:1/-1" }, "Sin estaciones."));
}

// ------------------------------------------------------------------ rules

function ruleRow(rule, i) {
  const dirty = () => ($("#rulesSave").hidden = false);
  const set = (k, v) => { rule[k] = v; dirty(); };
  const status = (SNAP?.state?.rules || []).find((r) => r.id === (rule.id || rule.item));
  const card = el("div", { class: "card", style: "margin:0;padding:13px;background:var(--surf-2)" });

  card.append(el("div", { class: "row2" }, [
    el("input", { class: "in", value: rule.item || "", placeholder: "Item (p.ej. Pal_crystal_S)", oninput: (e) => set("item", e.target.value.trim()) }),
    el("label", { class: "chk" }, [el("input", { type: "checkbox", checked: rule.enabled !== false ? "" : null, onchange: (e) => set("enabled", e.target.checked) }), "on"]),
  ]));

  if (status) {
    const pct = Math.min(100, (status.have / Math.max(1, status.target || status.min)) * 100);
    const lvl = status.have < status.min ? "low" : status.have < (status.target || status.min) ? "mid" : "";
    const g = el("div", { class: "gauge" }, [el("i", { class: lvl, style: `width:${pct}%` })]);
    if (status.target) g.append(el("span", { class: "min", style: `left:${Math.min(100, (status.min / status.target) * 100)}%` }));
    card.append(g);
    card.append(el("div", { class: "lr", style: "border:0;padding:6px 0 0" }, [
      el("span", { class: "sub" }, `${num(status.have)} / min ${num(status.min)} → ${num(status.target)}`),
      el("span", { class: "pill " + (status.low ? (status.onCooldown ? "hold" : "no") : "go") },
        !status.enabled ? "off" : status.low ? (status.onCooldown ? "espera" : "bajo") : "ok"),
    ]));
  }

  const g2 = el("div", { class: "mgrid", style: "margin-top:11px" });
  for (const [k, lbl] of [["min", "mínimo"], ["target", "objetivo"], ["batch", "tanda"], ["maxInProgress", "máx. a la vez"]]) {
    g2.append(el("label", { class: "ff" }, [
      lbl,
      el("input", { class: "in", type: "number", inputmode: "numeric", placeholder: k === "min" || k === "target" ? "0" : "—", value: rule[k] ?? "", oninput: (e) => set(k, e.target.value === "" ? undefined : Number(e.target.value)) }),
    ]));
  }
  card.append(g2);
  card.append(el("button", { class: "btn ghost sm", style: "margin-top:10px;color:var(--dead);border-color:transparent", onclick: () => { rulesDraft.splice(i, 1); renderRules(); dirty(); } }, "Borrar"));
  return card;
}

function renderRules() {
  if (!rulesDraft) rulesDraft = JSON.parse(JSON.stringify(SNAP?.rules?.rules || []));
  const wrap = $("#rulesList");
  wrap.innerHTML = "";
  if (!rulesDraft.length) wrap.append(el("div", { class: "empty" }, "Sin reglas todavía."));
  rulesDraft.forEach((r, i) => wrap.append(ruleRow(r, i)));
}

// ------------------------------------------------------------------ status

function renderStatus() {
  const s = SNAP?.state;
  const body = $("#turnBody");
  body.innerHTML = "";
  $("#turnSync").textContent = s?.lastScan ? "hace " + ago(s.lastScan) : "";
  const line = (k, v, pill) => body.append(el("div", { class: "lr" }, [
    el("span", { class: "l" }, [el("span", { class: "n" }, k)]),
    pill ? el("span", { class: "pill " + pill }, String(v)) : el("span", { class: "num" }, String(v)),
  ]));
  if (!s) body.append(el("div", { class: "empty" }, "Sin estado."));
  else {
    const player = s.engine?.connectedPid != null;
    line("Modo", s.backend === "native" ? (player ? "autónomo" : "en espera") : "al craftear",
      s.backend === "native" ? (player ? "go" : "hold") : "hold");
    line("En cola", s.queueDepth ?? 0);
    line("Colocadas", s.engine?.placed ?? 0);
    line("Fallidas", s.engine?.failed ?? 0);
    if (s.lastError) line("Aviso", s.lastError, "no");
  }

  const put = (sel, items, render, emptyTxt) => {
    const box = $(sel); box.innerHTML = "";
    if (!items.length) return box.append(el("div", { class: "empty" }, emptyTxt));
    items.forEach((x) => box.append(render(x)));
  };

  const queue = s?.queue || [];
  $("#queueCount").textContent = String(queue.length);
  put("#queueList", queue, (o) => el("div", { class: "lr" }, [
    el("span", { class: "l" }, [slotEl2(o.recipe), el("span", {}, [el("span", { class: "n" }, `${nice(o.recipe)} ×${o.count}`), o.source ? el("div", { class: "sub" }, o.source) : null])]),
    el("button", { class: "btn ghost sm", onclick: () => removeOrder(o.id) }, "Quitar"),
  ]), "Nada en cola.");

  const pw = s?.engine?.placedWatch || [];
  $("#watchCount").textContent = String(pw.length);
  put("#watchList", pw, (w) => el("div", { class: "lr" }, [
    el("span", { class: "l" }, [slotEl2(w.recipe), el("span", { class: "n" }, `${nice(w.recipe)} ×${w.count}`)]),
    el("span", { class: "pill " + (w.producing ? "go" : w.stalled ? "hold" : "") }, w.producing ? "fabricando" : w.stalled ? "sin Pal / energía" : "puesta"),
  ]), "—");

  const rs = s?.rules || [];
  $("#ruleStatusCard").hidden = !rs.length;
  put("#ruleStatusList", rs, (r) => el("div", { class: "lr" }, [
    el("span", { class: "l" }, [slotEl2(r.item), el("span", {}, [el("span", { class: "n" }, nice(r.item)), el("div", { class: "sub" }, `${num(r.have)} / ${num(r.min)}`)])]),
    el("span", { class: "pill " + (r.low ? (r.onCooldown ? "hold" : "no") : "go") }, !r.enabled ? "off" : r.low ? (r.onCooldown ? "espera" : "bajo") : "ok"),
  ]), "");

  const recent = (s?.recent || []).slice().reverse();
  put("#recentList", recent, (x) => el("div", { class: "lr" }, [
    el("span", { class: "l" }, [slotEl2(x.recipe), el("span", { class: "n" }, `${nice(x.recipe)} ×${x.count}`)]),
    el("span", { class: "pill " + (/fail|drop/.test(x.result) ? "no" : /cancel/.test(x.result) ? "hold" : "go") }, x.result),
  ]), "—");
}
function slotEl2(id) {
  const img = el("img", { class: "ic", loading: "lazy", alt: "", src: iconUrl(id) });
  const fail = () => img.replaceWith(el("span", { class: "ic", style: "display:grid;place-items:center;font:700 12px Oswald;color:var(--ink-3)" }, (nice(id)[0] || "?").toUpperCase()));
  img.addEventListener("error", fail);
  img.addEventListener("load", () => { if (img.naturalWidth <= 2) fail(); });
  return img;
}

// ------------------------------------------------------------------ render + actions

function renderAll() {
  conn();
  renderStock();
  renderOrder();
  renderStatus();
  if (!$("#v-rules").hidden) renderRules();
}

async function refresh(opts = {}) {
  try {
    SNAP = await api("/api/snapshot" + (opts.fresh ? "?fresh=1" : ""));
    if ($("#rulesSave").hidden) rulesDraft = null;
    renderAll();
  } catch (e) {
    if (/unauthorized/i.test(e.message)) return gotoSetup();
    toast(e.message, true);
  }
}

async function order() {
  const recipe = $("#ordRecipe").value;
  const count = Math.max(1, Math.floor(Number($("#ordCount").value) || 0));
  const target = $("#ordMachine").value || undefined;
  if (!recipe || !count) return;
  $("#ordGo").disabled = true;
  try {
    await api("/api/orders", { method: "POST", body: JSON.stringify({ recipe, count, target, transport: $("#ordTransport").checked }) });
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
  $("#conn").hidden = true; $("#tabs").hidden = true;
  $("#v-setup").hidden = false;
  VIEWS.forEach((t) => ($("#v-" + t).hidden = true));
}
function gotoApp() {
  $("#v-setup").hidden = true; $("#tabs").hidden = false;
  show(localStorage.getItem(LS.tab) || "stock");
  refresh(); start();
}
function start() { stop(); timer = setInterval(() => refresh(), 20000); }
function stop() { if (timer) clearInterval(timer); timer = null; }

$("#cfgSave").addEventListener("click", async () => {
  const url = $("#cfgUrl").value.trim().replace(/\/$/, "");
  const token = $("#cfgToken").value.trim();
  $("#cfgErr").hidden = true;
  if (!url || !token) { $("#cfgErr").textContent = "Faltan datos."; $("#cfgErr").hidden = false; return; }
  cfg.url = url; cfg.token = token; cfg.demo = false;
  const btn = $("#cfgSave"); btn.disabled = true; btn.textContent = "Conectando…";
  try {
    await api("/api/snapshot");
    localStorage.setItem(LS.url, url); localStorage.setItem(LS.token, token);
    gotoApp();
  } catch (e) {
    $("#cfgErr").textContent = "No conecta: " + e.message; $("#cfgErr").hidden = false;
  }
  btn.disabled = false; btn.textContent = "Conectar";
});
$("#cfgDemo").addEventListener("click", () => { cfg.demo = true; gotoApp(); toast("Demo con datos de ejemplo"); });
$("#forget").addEventListener("click", () => { localStorage.clear(); location.reload(); });
$("#ordGo").addEventListener("click", order);
$("#ordRecipe").addEventListener("change", renderMachines);
$("#rulesSave").addEventListener("click", saveRules);
$("#ruleAdd").addEventListener("click", () => { (rulesDraft ||= []).push({ item: "", min: 0, target: 0, enabled: true }); renderRules(); $("#rulesSave").hidden = false; });
$("#q").addEventListener("input", renderStock);
$("#scrim").addEventListener("click", closeSheet);
$$("#tabs button").forEach((b) => b.addEventListener("click", () => show(b.dataset.tab)));
document.addEventListener("visibilitychange", () => { if (!document.hidden && $("#v-setup").hidden) refresh(); });

if ("serviceWorker" in navigator && location.protocol === "https:") navigator.serviceWorker.register("/sw.js").catch(() => {});
if (cfg.url && cfg.token) gotoApp(); else gotoSetup();

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
  if (path.startsWith("/api/rules")) { DEMO.rules.rules = JSON.parse(opts.body).rules; return Promise.resolve({ ok: true, rules: DEMO.rules.rules }); }
  return Promise.resolve({});
}

const DEMO = {
  fetchedAt: new Date().toISOString(),
  inventory: {
    diagnostics: { baseCount: 2, containerCount: 6, complete: true },
    totals: {
      Stone: 5720, Wood: 12840, Fiber: 3120, CopperOre: 4740, Charcoal: 1610, Coal: 530, Sulfur: 9740,
      Pal_crystal_S: 605, CopperIngot: 10540, IronIngot: 122, Cloth: 77, Leather: 250, Wool: 251,
      Flour: 2330, Wheat: 3980, Berries: 49190, Honey: 2150, Egg: 1730, Tomato: 11140, Salad: 1230,
      PalSphere: 61, Nail: 0, Plastic: 2, Polymer: 222, MachineParts: 866, Medicines: 31,
      Blueprint_Katana_2: 3, SkillCard_Apocalypse: 7, RoughBullet: 144, Arrow: 714,
    },
    bases: [
      { name: "Base principal", containers: [
        { name: "Cofre 1", items: { Stone: 5200, Wood: 9000, CopperOre: 4600 } },
        { name: "Cofre 2", items: { CopperIngot: 10000, Cloth: 77, Flour: 2330 } },
      ] },
      { name: "Base minera", containers: [
        { name: "Cofre 1", items: { Stone: 520, Sulfur: 9740, Charcoal: 1610, Pal_crystal_S: 605 } },
      ] },
    ],
    guildChest: { available: true, items: { CopperIngot: 540, IronIngot: 122 } },
  },
  stations: { stations: [
    { key: "b1|crush", mapId: "d-crush-1", machineType: "BP_BuildObject_Crusher_C", baseName: "Base principal", recipes: ["Pal_crystal_S", "Charcoal", "Fiber"], state: { recipe: "None", remaining: 0, requested: 0, workable: false } },
    { key: "b1|furn", mapId: "d-furn-1", machineType: "BP_BuildObject_BlastFurnace_C", baseName: "Base principal", recipes: ["CopperIngot", "IronIngot", "Charcoal"], state: { recipe: "CopperIngot", remaining: 32, requested: 50, workable: true } },
    { key: "b1|mill", mapId: "d-mill-1", machineType: "BP_BuildObject_FlourMill_C", baseName: "Base principal", recipes: ["Flour"], state: { recipe: "Flour", remaining: 88, requested: 100, workable: true } },
    { key: "b2|crush", mapId: "d-crush-2", machineType: "BP_BuildObject_Crusher_C", baseName: "Base minera", recipes: ["Pal_crystal_S"], state: { recipe: "None", remaining: 0, requested: 0, workable: false } },
  ] },
  state: {
    backend: "native", hookInstalled: true, queueDepth: 1,
    lastScan: new Date(Date.now() - 24000).toISOString(),
    queue: [{ id: "d0", recipe: "Pal_crystal_S", count: 200, source: "rule:paldium" }],
    recent: [
      { recipe: "Charcoal", count: 100, result: "placed" },
      { recipe: "CopperIngot", count: 50, result: "placed" },
      { recipe: "Flour", count: 30, result: "cancelled" },
      { recipe: "IronIngot", count: 10, result: "dropped" },
    ],
    rules: [{ id: "paldium", item: "Pal_crystal_S", enabled: true, have: 605, min: 500, target: 1000, inProgress: 200, low: false, onCooldown: false }],
    engine: { backend: "native", connectedPid: 256, placed: 42, failed: 1,
      placedWatch: [
        { recipe: "CopperIngot", count: 50, producing: true, workable: true, stalled: false },
        { recipe: "Flour", count: 100, producing: false, workable: false, stalled: true },
      ] },
  },
  rules: { rules: [{ id: "paldium", item: "Pal_crystal_S", recipe: "Pal_crystal_S", min: 500, target: 1000, batch: 200, maxInProgress: 400, enabled: true }] },
  orders: [],
};
