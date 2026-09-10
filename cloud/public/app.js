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
let forcing = false;
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
  Medicines: "Suministros médicos", LuxuryMedicines: "Suministros médicos de alta calidad", Herbs: "Hierbas medicinales",
  PalFluid: "Fluido Pal", PalOil: "Aceite Pal de alta calidad", CrudeOil: "Petróleo crudo", Cement: "Cemento",
  Horn: "Cuerno", Venom: "Glándula venenosa", Poppy: "Amapola", NightStone: "Piedra nocturna",
  PredatorCrystal: "Cristal depredador", BeastBone_Ancient: "Hueso de bestia antiguo",
  PalUpgradeStone: "Piedra de estatua ancestral", GunPowder2: "Pólvora", CarbonFiber: "Fibra de carbono",
};
const nice = (id) => NAMES[id] || String(id || "")
  .replace(/^Pal_|^Blueprint_|^SkillCard_/, "")
  .replace(/_/g, " ")
  .replace(/([a-z])([A-Z])/g, "$1 $2")     // camelCase -> spaced
  .replace(/([A-Za-z]) ?(\d)/g, "$1 $2")   // trailing tier number
  .replace(/\s+/g, " ").trim();

// ---- bases: Palworld shows an un-renamed base as a locale template string
// ("新規生成拠点テンプレート名1(仮)"). Number them 1..N by size and label in Spanish.
const BASE_TEMPLATE = /新規生成拠点|拠点テンプレート|base\s*template\s*name|nouvelle\s*base|neue\s*basis/i;
let baseNames = {};
function rebuildBaseNames(inv) {
  baseNames = {};
  [...(inv?.bases || [])]
    .sort((a, b) => (b.containers?.length || 0) - (a.containers?.length || 0))
    .forEach((b, i) => { if (b.id) baseNames[b.id] = "Base " + (i + 1); });
}
function baseLabel(id, rawName) {
  if (id && baseNames[id]) return baseNames[id];
  const s = String(rawName ?? id ?? "").trim();
  if (!s) return "Base";
  if (BASE_TEMPLATE.test(s)) { const n = s.match(/(\d+)/); return "Base" + (n ? " " + n[1] : ""); }
  return s;
}

// ---- machines: internal BP class -> Spanish
const MACHINES = [
  [/BlastFurnace/i, "Horno"], [/IceCrusher/i, "Trituradora de hielo"], [/Crusher/i, "Trituradora"],
  [/FlourMill/i, "Molino"], [/WorkBench_SkillUnlock/i, "Mesa de tecnología"], [/CompositeDesk/i, "Mesa de montaje"],
  [/WorkBench/i, "Mesa de trabajo"], [/ElectricKitchen/i, "Cocina eléctrica"], [/HugeKitchen/i, "Cocina grande"],
  [/CookingStove/i, "Fogón"], [/CampFire/i, "Hoguera"], [/MedicineFacility/i, "Fábrica de medicina"],
  [/WeaponFactory/i, "Fábrica de armas"], [/SphereFactory/i, "Fábrica de esferas"], [/Factory_Hard/i, "Línea de producción"],
  [/ProductionLine|AssemblyLine/i, "Línea de producción"], [/Ranch/i, "Rancho"], [/Mining/i, "Mina"],
];
function machineName(bp) {
  const s = String(bp || "");
  for (const [rx, es] of MACHINES) if (rx.test(s)) return es;
  return s.replace(/^BP_BuildObject_|_C$/g, "").replace(/_/g, " ").trim() || "Máquina";
}

// Checked in order — specific families (gear, consumables, blueprints) win over
// the generic Recursos/Materiales catch-alls, so "ClothArmor" lands in Armadura,
// not Recursos. Display order is CAT_ORDER below, which is different on purpose.
const CATS = [
  ["Planos",     /^Blueprint_/i],
  ["Cartas",     /^SkillCard_/i],
  ["Pals",       /(PalSummon|PalItem_|PalEgg_|Pal_Egg)/i],
  ["Mejora",     /(WorkSuitability_|PalUpgradeStone|ExpBoost|SkillUnlock|SkillFruit|Lotus_|Elixir_|AffectionFruit|Unlock_|UnlockEquipmentSlot|StatusPointReset|Additional(Inventory|Equipment)|AutoMealPouch|PalStatue|Statue_)/i],
  ["Munición",   /(Bullet|Arrow|Shell|Rocket|Grenade|Cartridge|Ammo\b|_Ammo)/i],
  ["Esferas",    /(PalSphere|SphereModule|_Sphere\b|GigaSphere|MegaSphere)/i],
  ["Medicina",   /(Potion|Medicine|Medicines|Herbs?\b|Bandage|Antidote|Splint|Ointment|Opium|Revive|MedicalSupplies|Nostrum|Narcotic|Doping)/i],
  ["Armadura",   /(Armor|Helmet|Shield|Head(Equip|\d{3})|BodyEquip|Mask\d)/i],
  ["Armas",      /(Bow|Gun|Rifle|Pistol|Sword|Axe|Spear|Knife|Launcher|Shotgun|Musket|Katana|Hammer|Pickaxe|Revolver|Blade|Handgun|SMG|FlameThrower|Flamethrower|Grappling|Fishing|Gatling|Baton|Bazooka|Missile\b|^Torch$|^Bat\d*(_\d+)?$|Meat.?Cut)/i],
  ["Accesorios", /(Accessory|Otomo_|Ring\b|Amulet|Pendant|Lantern|Glider|Homeward|Whistle|Muffler|Cloak|Necklace)/i],
  ["Comida",     /(Bak(ed|e)|Soup|Salad|Salada|Cake|Bread|Meat|Egg|Milk|Honey|Berries|Juice|Jam|Pie|Stew|Pizza|Roast|Fried|Pancake|Omelet|Mushroom|Flour|Tomato|Lettuce|Onion|Potato|Carrot|Corn|Fruit|Grilled|Hot(Milk|Cocoa)|Yakisoba|Curry|Bacon|Chip|Bun|Pan\b|Sweet|Sandwich|Cheese|Burger|HotDog|LocoMoco|SpringRoll|GenghisKhan|Chowder|Gratin|Gyoza|Quiche|Minestrone|Carbonara|Takoyaki|jelly|Saute|Seafood|Cutlass|Sashimi|Nigiri)/i],
  ["Materiales", /(Ingot|Steel|Steal|Plastic|Polymer|Carbon.?Fiber|Cement|Nail|MachineParts|Computer|Circuit|Processed_Wood|Gun.?[Pp]owder|Cloth2|StainlessSteel|Bio_|Thermal_|Corrosive|Ancient.?Civ|AncientParts|Wood_Ancient|Yakushima\w*Ingot|WorldTreeIngot|SkyislandIngot|AIcore)/i],
  ["Recursos",   /(Stone|Wood|Fiber|Leather|Wool|Cloth|Sulfur|Quartz|Coal|CrudeOil|PalFluid|PalOil|bone|Bone|Horn|crystal|RainbowCrystal|MeteorDrop|Diamond|Ruby|Sapphire|Emerald|CaveMushroom|Venom|Poppy|Wheat|Organ\b|Chromium|Ore\b|Ingot_Raw)/i],
  ["Varios",     /(Key|TreasureBox|DogCoin|Money|Coin|Ticket|Proof|QuestItem|Salvage|Voucher)/i],
];
function catOf(id) {
  for (const [name, rx] of CATS) if (rx.test(id)) return name;
  return "Otros";
}
// chip order — the categories people actually browse first
const CAT_ORDER = ["Recursos", "Materiales", "Comida", "Medicina", "Munición", "Esferas",
  "Armas", "Armadura", "Accesorios", "Mejora", "Planos", "Cartas", "Pals", "Varios", "Otros"];

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
// the b1 segment is a cache epoch — bump it if a wrong icon ever gets pinned in
// the CDN edge cache (the worker ignores the value, it just freshens the URL).
const iconUrl = (id) => "/icon/b1/" + encodeURIComponent(id);
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
  // re-render on entry so lazy <img> observers attach while the section is visible
  if (tab === "stock" && SNAP) renderStock();
  if (tab === "order" && SNAP) renderOrder();
  if (tab === "rules") renderRules();
  window.scrollTo({ top: 0 });
}

function conn() {
  const c = $("#conn"); c.hidden = false;
  if (forcing) return;                       // leave the "actualizando…" label alone
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
  c.title = "Tocar para actualizar el inventario ahora";
  $("#connText").textContent = txt + (s?.lastScan ? " · " + ago(s.lastScan) : "") + (cfg.demo ? "" : " ↻");
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
  const s = el("div", { class: "slot noimg", "data-l": (nice(id)[0] || "?").toUpperCase() });
  if (!opts.noimg) mountIcon(s, id, "big");
  if (qty != null) s.append(el("span", { class: "qty" }, shortNum(qty)));
  return s;
}

// Per-session memory of what resolved, so the 20s re-render doesn't re-probe
// every icon. Value: "ok", or a number = how many render cycles it has failed.
// A big inventory has ~100+ cold icons on first load; the worker warms them into
// KV over the next few polls, so we give each id 3 cycles before giving up.
// Cleared on reload.
const iconSeen = new Map();
const ICON_GIVE_UP = 4;   // render cycles before a cold icon falls back to its letter
// families paldb has no item art for — skip the <img> entirely, just show the letter
const NO_ICON = /^(SkillCard_|WorkSuitability_AddTicket_|PalSummon_|Emote_|Record_|DesignFile_)/i;

// The letter tile is the *default* — a slot is never blank. Drop an <img> on top
// and reveal it only once it truly decodes.
function mountIcon(host, id, kind) {
  if (NO_ICON.test(id)) return null;
  const seen = iconSeen.get(id);
  if (typeof seen === "number" && seen >= ICON_GIVE_UP) return null;
  const img = el("img", kind === "mini" ? { alt: "" } : { decoding: "async", alt: "" });
  const wasOk = seen === "ok";
  let tries = 0, timer, done = false;
  const good = () => {
    if (img.naturalWidth <= 2) return again();
    done = true; clearTimeout(timer); iconSeen.set(id, "ok");
    host.classList.remove("noimg");
  };
  const again = () => {
    if (done) return;
    clearTimeout(timer);
    const sched = wasOk ? [800, 4000] : [1500, 6000];
    if (tries >= sched.length) {
      if (!wasOk) iconSeen.set(id, (typeof seen === "number" ? seen : 0) + 1);
      return;
    }
    timer = setTimeout(() => { if (!done) img.src = iconUrl(id) + "?r=" + (++tries); }, sched[tries]);
  };
  img.addEventListener("load", good);
  img.addEventListener("error", again);
  host.append(img);
  img.src = iconUrl(id);
  timer = setTimeout(again, wasOk ? 4000 : 6500);   // stalled: no load, no error
  return img;
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
    if (c) where.push([baseLabel(base.id, base.name), c]);
  }
  if (inv?.guildChest?.items?.[id]) where.push(["Cofre de gremio", inv.guildChest.items[id]]);
  where.sort((a, b) => b[1] - a[1]);

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
    onclick: () => { closeSheet(); ord.recipe = id; ord.target = ""; show("order"); },
  }, "Craftear esto"));
  openSheet(body);
}

// ------------------------------------------------------------------ order

const ord = { recipe: null, target: "", count: 50, transport: true, cat: null, gear: false };
let ordGridSig = "";
// prefer the categories people actually bulk-craft as the landing view
const ORD_CAT_PREF = ["Materiales", "Comida", "Munición", "Medicina", "Esferas", "Recursos"];
// you don't bulk-craft schematics or skill fruits — keep them out of the order picker
const ORD_SKIP = /^(Blueprint_|SkillCard_|WorkSuitability_AddTicket_|PalSummon_|PalEgg_)/i;
// worth ordering in a batch — shown by default. Gear (Armas/Armadura/Accesorios/
// Mejora/Otros) sits behind the "Equipo" toggle since you craft those one at a time.
const ORD_BULK = new Set(["Recursos", "Materiales", "Comida", "Medicina", "Munición", "Esferas", "Varios"]);

const mBusy = (s) => !!(s?.state?.workable || (s?.state?.requested || 0) > 0);
const mState = (s) => mBusy(s) ? `${nice(s.state.recipe)} ×${s.state.remaining ?? "?"}` : "libre";
const mFull = (s) => `${machineName(s.machineType)} · ${baseLabel(s.baseId, s.baseName)}`;

function craftMap() {
  const m = new Map();                    // recipe id -> [stations]
  for (const s of SNAP?.stations?.stations || [])
    for (const r of s.recipes || []) (m.get(r) || m.set(r, []).get(r)).push(s);
  return m;
}

const stepFor = (n) => (n >= 500 ? 100 : n >= 100 ? 25 : n >= 20 ? 10 : 1);
function setCount(n) {
  ord.count = Math.max(1, Math.min(99999, Math.floor(Number(String(n).replace(/\D/g, "")) || 1)));
  const f = $("#ordCount"); if (f) f.value = ord.count;
  syncGo();
}

function syncGo() {
  const go = $("#ordGo");
  if (!ord.recipe) { go.hidden = true; return; }
  go.hidden = false;
  const where = ord.target ? mFull((SNAP?.stations?.stations || []).find((x) => x.mapId === ord.target) || {}) : "cualquier máquina libre";
  go.innerHTML = "";
  go.append(document.createTextNode(`Pedir · ${nice(ord.recipe)} ×${ord.count}`), el("small", {}, "→ " + where));
}

function renderOrder() {
  const craft = craftMap();
  const ids = [...craft.keys()].filter((id) => !ORD_SKIP.test(id));
  if (ord.recipe && !craft.has(ord.recipe)) { ord.recipe = null; ord.target = ""; }

  // split: bulk (shown by default) vs gear (behind the "Equipo" toggle)
  const catOfCache = new Map(ids.map((id) => [id, catOf(id)]));
  const inScope = (id) => ord.gear || ORD_BULK.has(catOfCache.get(id));
  const counts = {};
  for (const id of ids) if (inScope(id)) { const c = catOfCache.get(id); counts[c] = (counts[c] || 0) + 1; }
  const gearCount = ids.filter((id) => !ORD_BULK.has(catOfCache.get(id))).length;

  if (ord.cat == null) ord.cat = ORD_CAT_PREF.find((c) => counts[c]) || "*";
  if (!(ord.cat === "*" || counts[ord.cat])) ord.cat = "*";

  const cb = $("#ordCats"); cb.innerHTML = "";
  const catBtn = (key, label, n, extra) => cb.append(el("button", {
    "aria-current": ord.cat === key, class: extra || null,
    onclick: () => { ord.cat = key; renderOrder(); },
  }, [label, n != null ? el("span", { class: "c" }, n) : null]));
  catBtn("*", "Todo", Object.values(counts).reduce((a, b) => a + b, 0));
  for (const c of CAT_ORDER) if (counts[c]) catBtn(c, c, counts[c]);
  if (gearCount) cb.append(el("button", {
    class: "gear" + (ord.gear ? " on" : ""),
    onclick: () => { ord.gear = !ord.gear; if (!ord.gear && !ORD_BULK.has(ord.cat)) ord.cat = "*"; renderOrder(); },
  }, ord.gear ? "− equipo" : `+ equipo ${gearCount}`));

  const q = ($("#ordSearch")?.value || "").toLowerCase().trim();
  const catRank = (id) => { const i = CAT_ORDER.indexOf(catOfCache.get(id)); return i < 0 ? 99 : i; };
  const matches = ids
    .filter((id) => q ? (id.toLowerCase().includes(q) || nice(id).toLowerCase().includes(q))
                      : (inScope(id) && (ord.cat === "*" || catOfCache.get(id) === ord.cat)))
    .sort((a, b) => (q || ord.cat !== "*" ? 0 : catRank(a) - catRank(b))
      || nice(a).localeCompare(nice(b)) || a.length - b.length || a.localeCompare(b));
  const CAP = 120;
  const shown = matches.slice(0, CAP);
  const overflow = matches.length - shown.length;

  // recipe grid — rebuild only when the set or selection changes (keeps scroll on polls)
  const sig = shown.join("|") + "»" + ord.recipe + "»" + overflow;
  if (sig !== ordGridSig) {
    ordGridSig = sig;
    const g = $("#ordRecipes"); g.innerHTML = "";
    if (!shown.length) g.append(el("div", { class: "empty", style: "grid-column:1/-1" }, ids.length ? "Nada coincide." : "Sin máquinas."));
    shown.forEach((id, i) => g.append(el("button", {
      class: "rtile", "aria-pressed": ord.recipe === id, style: `animation-delay:${Math.min(i * 8, 180)}ms`,
      onclick: () => { ord.recipe = ord.recipe === id ? null : id; ord.target = ""; renderOrder(); if (ord.recipe) $("#ordConfig")?.scrollIntoView({ behavior: "smooth", block: "start" }); },
    }, [slotEl(id, null), el("div", { class: "lbl" }, nice(id))])));
    if (overflow > 0) g.append(el("div", { class: "empty", style: "grid-column:1/-1;padding:14px 6px" }, `+${overflow} más — usá el buscador`));
  }

  const scopeN = ids.filter(inScope).length;
  $("#ordPick").textContent = ord.recipe ? nice(ord.recipe) : (scopeN ? `${scopeN} recetas` : "");
  $("#ordConfig").hidden = !ord.recipe;
  $("#ordCount").value = ord.count;
  $("#ordTransport").checked = ord.transport;

  renderShop(craft);
  syncGo();
}

function renderShop(craft) {
  const all = (SNAP?.stations?.stations || []).slice();
  $("#floorCount").textContent = all.length ? `${all.length} máquinas` : "";
  const fg = $("#floorGrid"); fg.innerHTML = "";

  const card = (s, dim) => el("button", {
    class: "mcard " + (mBusy(s) ? "busy" : "free") + (dim ? " dim" : ""),
    "aria-pressed": ord.target === s.mapId,
    onclick: () => {
      if (dim) { toast(`${machineName(s.machineType)} no hace ${nice(ord.recipe)}`, true); return; }
      ord.target = ord.target === s.mapId ? "" : s.mapId;
      if (!ord.recipe) ord.recipe = (s.recipes || [])[0] || null;
      renderOrder();
    },
  }, [
    el("div", {}, [el("div", { class: "mt" }, machineName(s.machineType)), el("div", { class: "mb" }, baseLabel(s.baseId, s.baseName))]),
    el("span", { class: "mstate" }, mState(s)),
  ]);

  if (!ord.recipe) {
    $("#ordHint").textContent = all.length ? "Tocá una máquina para empezar por ahí, o elegí una receta arriba." : "";
    all.sort((a, b) => (mBusy(a) ? 1 : 0) - (mBusy(b) ? 1 : 0)).forEach((s) => fg.append(card(s, false)));
    return;
  }

  const cap = new Set((craft.get(ord.recipe) || []).map((s) => s.mapId));
  $("#ordHint").textContent = "“Cualquiera” toma la primera libre. Una máquina fija espera su turno si está ocupada.";
  fg.append(el("button", {
    class: "any", "aria-pressed": !ord.target,
    onclick: () => { ord.target = ""; renderOrder(); },
  }, [el("span", {}, "▸ Cualquier máquina libre"), el("span", { class: "tag" }, `${cap.size} pueden`)]));

  const yes = all.filter((s) => cap.has(s.mapId)).sort((a, b) => (mBusy(a) ? 1 : 0) - (mBusy(b) ? 1 : 0));
  const no = all.filter((s) => !cap.has(s.mapId));
  if (yes.length) { fg.append(el("div", { class: "mdiv" }, "que lo pueden hacer")); yes.forEach((s) => fg.append(card(s, false))); }
  if (no.length) { fg.append(el("div", { class: "mdiv" }, "otras")); no.forEach((s) => fg.append(card(s, true))); }
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
// mini icon for ledger rows: a letter chip with the <img> layered on top
function slotEl2(id) {
  const chip = el("span", { class: "ic noimg", "data-l": (nice(id)[0] || "?").toUpperCase() });
  mountIcon(chip, id, "mini");
  return chip;
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
    rebuildBaseNames(SNAP?.inventory);
    if ($("#rulesSave").hidden) rulesDraft = null;
    renderAll();
  } catch (e) {
    if (/unauthorized/i.test(e.message)) return gotoSetup();
    toast(e.message, true);
  }
}

// Tap the status pill -> ask the mod for an immediate full inventory walk, then
// poll for it to land (its loop ticks every ~10s).
async function forceRefresh() {
  if (forcing || cfg.demo || !cfg.url) return;
  forcing = true;
  const c = $("#conn");
  c.classList.add("busy");
  $("#connText").textContent = "actualizando…";
  const before = SNAP?.state?.lastScan;
  try {
    await api("/api/snapshot?fresh=1&pulse=force");
    for (let i = 0; i < 4; i++) {
      await new Promise((r) => setTimeout(r, 4000));
      await refresh({ fresh: true });
      if (SNAP?.state?.lastScan && SNAP.state.lastScan !== before) break;
    }
    toast("Inventario al día");
  } catch (e) {
    toast(e.message, true);
  } finally {
    forcing = false;
    c.classList.remove("busy");
    conn();
  }
}

async function order() {
  setCount($("#ordCount").value);
  if (!ord.recipe || !ord.count) return;
  const { recipe, count } = ord;
  $("#ordGo").disabled = true;
  try {
    await api("/api/orders", { method: "POST", body: JSON.stringify({ recipe, count, target: ord.target || undefined, transport: ord.transport }) });
    toast(`En cola: ${nice(recipe)} ×${count}`);
    ord.target = "";
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
    const h = await api("/api/health?probe=1");
    const miss = ["appToken", "dathostUser", "dathostKey"].filter((k) => !h.config?.[k]);
    if (miss.length) throw new Error("Al Worker le faltan secrets: " + miss.join(", "));
    if (!h.tokenOk) throw new Error("Ese token no coincide con el APP_TOKEN del Worker.");
    if (typeof h.dathost === "string" && h.dathost.startsWith("FAIL")) {
      throw new Error("DatHost rechazó la conexión (" + h.dathost.replace("FAIL: ", "") +
        "). Revisá el email/contraseña de los secrets.");
    }
    await api("/api/snapshot");
    localStorage.setItem(LS.url, url); localStorage.setItem(LS.token, token);
    gotoApp();
  } catch (e) {
    $("#cfgErr").textContent = e.message; $("#cfgErr").hidden = false;
  }
  btn.disabled = false; btn.textContent = "Conectar";
});
$("#cfgDemo").addEventListener("click", () => { cfg.demo = true; gotoApp(); toast("Demo con datos de ejemplo"); });
$("#forget").addEventListener("click", () => { localStorage.clear(); location.reload(); });
$("#ordGo").addEventListener("click", order);
$("#ordSearch").addEventListener("input", renderOrder);
$("#qMinus").addEventListener("click", () => setCount(ord.count - stepFor(ord.count)));
$("#qPlus").addEventListener("click", () => setCount(ord.count + stepFor(ord.count)));
$("#ordCount").addEventListener("input", (e) => { const n = parseInt(e.target.value.replace(/\D/g, ""), 10); if (!isNaN(n)) { ord.count = Math.min(99999, n); syncGo(); } });
$("#ordCount").addEventListener("blur", () => setCount($("#ordCount").value));
$("#ordTransport").addEventListener("change", (e) => { ord.transport = e.target.checked; });
$("#qChips").addEventListener("click", (e) => {
  const b = e.target.closest("button"); if (!b) return;
  if (b.dataset.reset != null) setCount(1);
  else if (b.dataset.add) setCount(ord.count + Number(b.dataset.add));
});
$("#rulesSave").addEventListener("click", saveRules);
$("#ruleAdd").addEventListener("click", () => { (rulesDraft ||= []).push({ item: "", min: 0, target: 0, enabled: true }); renderRules(); $("#rulesSave").hidden = false; });
$("#q").addEventListener("input", renderStock);
$("#conn").addEventListener("click", forceRefresh);
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
