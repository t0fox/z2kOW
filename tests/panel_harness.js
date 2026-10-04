// Прогон КАЖДОЙ страницы панели с исполнением её кода.
// Грепом такое не ловится: STRATEGY_POOL_NAMES — не вызов функции, а обращение
// к константе, и статическая проверка по вызовам его пропустила.
const fs = require("fs");
const path = process.argv[2];
const routes = process.argv.slice(3);
const BRAND_CASE = process.env.Z2K_BRAND_CASE || "";

const errors = [];
const domById = new Map();

// Ловим ошибки, которые код ПОЙМАЛ и отрисовал вместо того, чтобы бросить.
// Без этого харнесс защищал ровно один маршрут из девяти: почти каждый
// загрузчик обёрнут в try/catch и на исключении пишет текст в DOM, а наружу
// ничего не выходит — прогон отвечает «ok». Именно так выглядела бы регрессия
// r-71.1, случись она в любой странице кроме «Свои стратегии».
//
// Список шаблонов узкий намеренно. Ловим ТОЛЬКО признаки поломки кода —
// обращение к несуществующему имени или вызов не-функции. Общие маркеры вроде
// «Ошибка» или класса var(--bad) брать нельзя: ими штатно сообщают «сервис не
// запущен» и «не удалось загрузить», и тест краснел бы на здоровой панели.
const RENDERED_BUG = /(is not defined|is not a function|undefined is not|Cannot read propert|of undefined|of null)/;
function noteRendered(html) {
  const m = String(html).match(RENDERED_BUG);
  if (m) errors.push("отрисована ошибка: " + m[0]);
}
const mkEl = () => {
  const el = {
    // value ОБЯЗАН быть, и обязан быть строкой. У настоящего поля ввода он
    // есть всегда, поэтому код, читающий его при ОТРИСОВКЕ (а не в
    // обработчике события, куда харнесс не заходит), в браузере работает, а
    // здесь падал на `.trim() of undefined`. Наружу это выходило как
    // «страница не отрисовалась: Cannot read propert» — сообщение, по
    // которому до причины ещё надо докопаться, хотя ломался мок, а не панель.
    value: "",
    _h: "", style: { setProperty(k,v){ this[k]=String(v); }, getPropertyValue(k){ return this[k] || ""; } }, dataset: {}, classList: { add(){}, remove(){}, toggle(){}, contains(){return false} },
    children: [], attributes: {},
    // Все mock-узлы считаются живыми (isConnected): telemetry-guard
    // host.isConnected === false обязан пропускать их, иначе карточка
    // статистики никогда не исполнится в харнессе.
    isConnected: true,
    set innerHTML(v){ this._h = String(v); noteRendered(this._h); },
    get innerHTML(){ return this._h; },
    set textContent(v){ this._h = String(v); noteRendered(this._h); },
    get textContent(){ return this._h; },
    addEventListener(){}, removeEventListener(){}, appendChild(child){ this.children.push(child); if (child && child.id) domById.set(child.id, child); return child; }, removeChild(child){ this.children = this.children.filter(x => x !== child); },
    setAttribute(k,v){ this.attributes[k]=String(v); this[k]=String(v); if (k === "id" && BRAND_CASE) domById.set(String(v), this); }, getAttribute(k){ return this.attributes[k]; },
    removeAttribute(){}, querySelector(){ return mkEl(); }, querySelectorAll(){ return []; },
    closest(){ return null; }, focus(){}, blur(){}, click(){}, insertAdjacentHTML(){},
    scrollIntoView(){}, remove(){},
  };
  return el;
};
function mockNode(id, properties) {
  const el = mkEl(); el.id = id; Object.assign(el, properties || {}); domById.set(id, el); return el;
}
// app.js imports the browser select enhancement in Node-based route checks.
// These runs have no form-control DOM; Chromium covers the real widget.
global.HTMLSelectElement = class HTMLSelectElement {
  get value() { return this._value || ""; }
  set value(value) { this._value = String(value); }
  get selectedIndex() { return this._selectedIndex ?? -1; }
  set selectedIndex(value) { this._selectedIndex = Number(value); }
};
global.HTMLOptGroupElement = class HTMLOptGroupElement {};
global.HTMLOptionElement = class HTMLOptionElement {};
if (BRAND_CASE) {
  mockNode("panel-brand", { attributes: { "aria-label": "z2kOW" } });
  mockNode("brand-profile-logo", { hidden: false, src: "/favicon.svg?v=p-86.1" });
  mockNode("brand-wordmark", { textContent: "z2kOW" });
  mockNode("brand-favicon", { href: "/favicon.svg?v=p-86.1" });
  mockNode("brand-mask-icon", { href: "/favicon.svg?v=p-86.1" });
}
if (process.env.Z2K_WARP_DOMAIN_MOCK) mockNode("warp-domain-state");
const head = mkEl();
global.document = {
  documentElement: mkEl(), body: mkEl(), head,
  title: "z2kOW",
  getElementById(id){
    if (id === "brand-profile-theme") return domById.get(id) || null;
    return domById.get(id) || mkEl();
  },
  querySelector(selector){
    const byId = /^#([A-Za-z0-9_-]+)$/.exec(selector);
    if (byId) return domById.get(byId[1]) || mkEl();
    const rel = /^link\[rel=["']?([^"'\]]+)["']?\]$/.exec(selector);
    if (rel) return Array.from(domById.values()).find(el => el.rel === rel[1]) || mkEl();
    return mkEl();
  }, querySelectorAll(){ return []; },
  createElement(tag){ const el=mkEl(); el.tagName=String(tag).toUpperCase(); return el; }, addEventListener(){}, removeEventListener(){},
};
if (BRAND_CASE) {
  const favicon = domById.get("brand-favicon"); favicon.rel = "icon";
  const mask = domById.get("brand-mask-icon"); mask.rel = "mask-icon";
}
global.location = { hash: "#/dashboard", href: "http://r/", reload(){} };
global.history = { replaceState(){}, pushState(){} };
// Заглушки задаются ЯВНО и перекрывают хостовые, даже если node их предоставляет.
// Иначе тест зависит от версии node: локальный v25 отдаёт настоящий
// sessionStorage, и падение «sessionStorage is not defined» вылезло только на
// CI, где node старее. Тест, который проходит из-за окружения, а не из-за кода,
// хуже отсутствующего — он даёт ложную уверенность.
const mkStorage = () => {
  const m = new Map();
  return {
    getItem(k){ return m.has(String(k)) ? m.get(String(k)) : null; },
    setItem(k, v){ m.set(String(k), String(v)); },
    removeItem(k){ m.delete(String(k)); },
    clear(){ m.clear(); },
    key(i){ return Array.from(m.keys())[i] ?? null; },
    get length(){ return m.size; },
  };
};
global.localStorage = mkStorage();
global.sessionStorage = mkStorage();
// URL.createObjectURL/revokeObjectURL в node отсутствуют — их зовёт выгрузка
// диагностики в файл (app.js:1348).
if (typeof global.URL.createObjectURL !== "function") {
  global.URL.createObjectURL = () => "blob:stub";
  global.URL.revokeObjectURL = () => {};
}
if (typeof global.Blob !== "function") { global.Blob = class { constructor(){} }; }
global.window = {
  addEventListener(t, fn){ if (t === "hashchange") global.__nav = fn; },
  removeEventListener(){}, matchMedia(){ return { matches:false, addEventListener(){}, addListener(){} }; },
  location: global.location, localStorage: global.localStorage,
  sessionStorage: global.sessionStorage, document: global.document,
};
// The VM harness checks route rendering, not browser mutation delivery. The
// real Chromium acceptance suite covers MutationObserver-driven tab updates.
global.MutationObserver = class {
  constructor(callback) { this.callback = callback; }
  observe() {}
  disconnect() {}
  takeRecords() { return []; }
};
global.requestAnimationFrame = fn => setTimeout(fn, 0);
global.cancelAnimationFrame = id => clearTimeout(id);
global.getComputedStyle = () => ({ getPropertyValue: () => "" });
global.navigator = { clipboard: { writeText: async () => {} }, userAgent: "node" };
// Ответы должны быть ПРАВДОПОДОБНЫМИ, иначе тест бесполезен: с пустым {ok:true}
// список пулов приходит пустым, .map() не выполняется, и обращение к
// STRATEGY_POOL_NAMES внутри него никогда не происходит — ровно поэтому первая
// версия этой заглушки пропустила реальную поломку страницы «Свои стратегии».
const statusFixture = (process.env.Z2K_OW_CAPS === "1")
    ? { ok:true, installed:true, running:true, service:"active",
        toggles:{game_warp:"0",customd:"0",dynamic_ttl:"1",
                 stats:"1",stats_ack:"0",ppe:"1",auto_update:"1",autohostlist:"0"},
        tunnel:{running:false}, platform:"openwrt",
        capabilities:{policy:false,ppe:false,tcp16:false,diag:false,
                      warp:true,telegram:true,uninstall:false} }
    : { ok:true, installed:"r-71.1", running:true, service:"running",
        toggles:{game_warp:"0",customd:"0",dynamic_ttl:"1",
                 stats:"1",ppe:"1",auto_update:"1",autohostlist:"0"}, tunnel:{running:true} };
if (process.env.Z2K_TEST_RELEASE_STATE_ERROR === "1") {
  statusFixture.installed = false;
  statusFixture.installed_state = "error";
  statusFixture.installed_state_error = "installed release metadata is missing";
  mockNode("status-grid");
}
if (BRAND_CASE === "openwrt") {
  statusFixture.brand = { name:"z2kOW", subtitle:"OpenWrt edition",
    logo:"/assets/openwrt/logo.png", favicon:"/assets/openwrt/favicon.svg",
    theme:"/assets/openwrt/theme.css" };
} else if (BRAND_CASE === "unsafe") {
  statusFixture.brand = { name:"z2kOW", subtitle:"OpenWrt edition",
    logo:"https://evil.example/mark.svg", favicon:"//evil.example/favicon.svg",
    theme:"/../outside.css" };
}
if (process.env.Z2K_TEST_UPDATE_UNKNOWN === "1" || process.env.Z2K_TEST_RELEASE_SEQ_MISMATCH === "1") mockNode("update-banner");
const FIXTURES = {
  // Z2K_OW_CAPS=1 — OpenWrt-форма /status (platform + capabilities) для
  // tests/openwrt/test_ow_webpanel_pages.sh: исполняет OW-ветки фронта
  // (applyCapabilities, OW-текст dynamic_ttl, title). Дефолт — Keenetic 1-в-1.
  "/status": statusFixture,
  "/toggles": { ok:true, game_warp:"0",customd:"0",dynamic_ttl:"1",
                stats:"1",stats_ack:"0",ppe:"1",auto_update:"1",autohostlist:"0" },
  "/strategy/pools": { ok:true, pools:[
    {pool:"rkn_tcp",custom:0,line:""},{pool:"yt_tcp",custom:1,line:"--filter-tcp=443"},
    {pool:"gv_tcp",custom:0,line:""},{pool:"quic",custom:0,line:""}] },
  "/strategy/pool": { ok:true, pool:"rkn_tcp", custom:0, line:"" },
  "/state": { ok:true, entries:[
    {key:"rkn_tcp",host:"example.com|4",strategy:"3",ts:1785830000,mode:"auto"},
    {key:"yt_tcp",host:"youtube.com|4",strategy:"7",ts:1785830100,mode:"frozen"},
    {key:"discord_udp",host:"nohost",strategy:"2",ts:1785830200,mode:"auto"}] },
  "/pools": { ok:true, pools:{rkn_tcp:50,yt_tcp:22,gv_tcp:22,quic:13,discord_udp:9} },
  "/whitelist": { ok:true, domains:["gosuslugi.ru","sberbank.ru","keenetic.link"] },
  "/exclude": { ok:true, entries:["tiandycloud.com","203.0.113.0/24","2001:db8::1"] },
  "/extra-domains": { ok:true, domains:["example.org","cdnbase.com"] },
  "/warp/status": (process.env.Z2K_WARP_MOCK === "uninstalled")
    ? { ok:true, enabled:"0", installed:false, ready:false, transport:"", endpoint:"", iface:"", addr:"", entries:0, devices:0, error:"" }
    : { ok:true, enabled:"1", installed:true, ready:true, route_ready:true, transport:"wg", endpoint:"8.6.112.0:2408", iface:"z2ktun0", addr:"172.16.0.2", entries:1234, devices:2, error:"",
        domain_active: process.env.Z2K_WARP_DOMAIN_MOCK === "active",
        domain_rules: process.env.Z2K_WARP_DOMAIN_MOCK === "empty" ? 0 : 4,
        domain_pairs: process.env.Z2K_WARP_DOMAIN_MOCK === "active" ? 3 : 0,
        domain_error: process.env.Z2K_WARP_DOMAIN_MOCK === "error" ? "observer-unavailable" : "" },
  "/warp/devices": "192.168.1.50\naa:bb:cc:dd:ee:ff\n",
  "/warp/neighbors": { ok:true, devices:[{mac:"aa:bb:cc:dd:ee:ff",ip:"192.168.1.77",label:"PS5",net:"Home",active:true,on:true},
    {mac:"11:22:33:44:55:66",ip:"192.168.1.78",label:"iPhone",net:"Home",active:false,on:false}] },
  "/warp/games": { ok:true, games:[{name:"ApexLegends",entries:42,on:1},{name:"Valorant",entries:13,on:0}] },
  "/warp/lists": { ok:true, lists:[{name:"custom",entries:5,size:120,mtime:1785830000}] },
  "/warp/list": { ok:true, name:"custom", content:"1.2.3.4\n5.6.7.8" },
  "/update/status": process.env.Z2K_TEST_UPDATE_UNKNOWN === "1"
    ? { ok:true, installed:"unknown", available:"r-86.7", behind:0, last_check:1785830000, pending:[] }
    : process.env.Z2K_TEST_RELEASE_SEQ_MISMATCH === "1"
      ? { ok:true, installed:"p-86.13", available:"p-86.13", installed_seq:135,
          available_seq:136, release_seq_mismatch:true, behind:1,
          last_check:1785830000, pending:[] }
      : { ok:true, installed:"r-71.1", available:"r-71.1", behind:0,
        last_check:1785830000, pending:[] },
  "/policy/status": { ok:true, enabled:false, policy:"" },
  "/diag": { ok:true, diag:"=== что не так ===\n  явных проблем не найдено\n" },
  "/job": { ok:true, done:true, exit:0, log:"" },
};
global.fetch = async (url) => {
  const p = String(url).replace(/^.*\/cgi-bin\/api/, "").split("?")[0];
  const body = FIXTURES[p] || { ok:true };
  // Строковая фикстура — text/plain эндпоинт (/warp/devices): text() отдаёт как есть.
  return { ok:true, status:200, json: async () => body,
           text: async () => (typeof body === "string" ? body : JSON.stringify(body)) };
};
process.on("unhandledRejection", e => errors.push("async: " + (e && e.message || e)));

try { new Function(fs.readFileSync(path, "utf8"))(); }
catch (e) { console.log("ЗАГРУЗКА УПАЛА: " + e.message); process.exit(1); }

(async () => {
  for (const r of routes) {
    global.location.hash = "#/" + r;
    const before = errors.length;
    try { global.__nav && global.__nav(); await new Promise(res => setTimeout(res, 30)); }
    catch (e) { errors.push(r + ": " + e.message); }
    const bad = errors.slice(before);
    console.log(`  ${bad.length ? "ПАДАЕТ" : "ok    "}  #/${r}${bad.length ? "  — " + bad[0] : ""}`);
  }
  if (process.env.Z2K_TEST_UPDATE_UNKNOWN === "1") {
    const banner = domById.get("update-banner").innerHTML;
    if (banner.includes("актуален")) errors.push("unknown installed release was rendered as up to date");
    if (!banner.includes("Не удалось проверить обновления z2k")) errors.push("unknown installed release did not render a state error");
  }
  if (process.env.Z2K_TEST_RELEASE_STATE_ERROR === "1") {
    const statusGrid = domById.get("status-grid").innerHTML;
    if (!statusGrid.includes("ошибка состояния")) errors.push("missing release metadata was rendered as a normal not-installed state");
    if (statusGrid.includes('<div class="label">Установлен</div><div class="value">Нет')) errors.push("missing release metadata was rendered as merely not installed");
  }
  if (process.env.Z2K_WARP_DOMAIN_MOCK) {
    const domainState = domById.get("warp-domain-state").textContent;
    if (process.env.Z2K_WARP_DOMAIN_MOCK === "empty") {
      if (!domainState.includes("не настроены")) errors.push("empty domain rules were rendered as unavailable instead of not configured");
      if (domainState.includes("недоступны")) errors.push("empty domain rules were falsely rendered as unavailable");
    } else if (process.env.Z2K_WARP_DOMAIN_MOCK === "active") {
      if (!domainState.includes("активных пар устройство/IP: 3")) errors.push("active domain rule counts were not rendered");
    } else if (process.env.Z2K_WARP_DOMAIN_MOCK === "error") {
      if (!domainState.includes("недоступны") || !domainState.includes("observer unavailable")) errors.push("domain observer error was hidden");
    }
  }
  if (process.env.Z2K_TEST_RELEASE_SEQ_MISMATCH === "1") {
    const banner = domById.get("update-banner").innerHTML;
    if (!banner.includes("Нужно синхронизировать установленный выпуск")) errors.push("sequence drift was not shown as a release synchronization");
    if (!banner.includes("p-86.13 · seq 135") || !banner.includes("p-86.13 · seq 136")) errors.push("sequence drift did not show both canonical and controlled release identities");
    if (banner.includes("актуален")) errors.push("sequence drift was rendered as current");
  }
  if (BRAND_CASE) {
    const expect = (condition, label) => {
      if (condition) console.log("  brand ok    " + label);
      else { console.log("  brand FAIL  " + label); errors.push("branding: " + label); }
    };
    const profile = BRAND_CASE === "openwrt";
    const unsafe = BRAND_CASE === "unsafe";
    const brandLink = domById.get("panel-brand");
    const profileLogo = domById.get("brand-profile-logo");
    const wordmark = domById.get("brand-wordmark");
    const favicon = domById.get("brand-favicon");
    const mask = domById.get("brand-mask-icon");
    const theme = domById.get("brand-profile-theme");
    if (profile) {
      expect(profileLogo && profileLogo.hidden === false && profileLogo.src === "/assets/openwrt/logo.png", "OpenWrt profile updates the exact z2kOW lockup");
      expect(wordmark && wordmark.textContent === "z2kOW", "OpenWrt profile updates the HTML wordmark");
      expect(brandLink && brandLink.getAttribute("aria-label") === "z2kOW — OpenWrt edition", "brand name and subtitle are accessible");
      expect(favicon && favicon.href === "/assets/openwrt/favicon.svg" && mask && mask.href === "/assets/openwrt/favicon.svg", "favicon and mask icon use the profile asset");
      expect(theme && theme.href === "/assets/openwrt/theme.css", "profile theme loads from a same-origin stylesheet");
      for (const [route, title] of [["dashboard","Дашборд"],["strategies","Стратегии"],["warp","WARP"]]) {
        global.location.hash = "#/" + route; global.__nav && global.__nav();
        expect(global.document.title === `z2kOW · ${title}`, `route title for #/${route} starts with the profile name`);
      }
    } else if (unsafe) {
      expect(profileLogo && profileLogo.src === "/favicon.svg?v=p-86.1", "unsafe profile keeps the local default mark");
      expect(wordmark && wordmark.textContent === "z2kOW", "unsafe profile keeps the default HTML wordmark");
      expect(favicon && favicon.href === "/favicon.svg?v=p-86.1" && mask && mask.href === "/favicon.svg?v=p-86.1", "unsafe profile cannot replace local icons");
      expect(!theme, "unsafe profile cannot load a non-local theme");
      global.location.hash = "#/strategies"; global.__nav && global.__nav();
      expect(global.document.title === "z2kOW · Стратегии", "rejected profile keeps the default tab brand");
    } else {
      expect(profileLogo && profileLogo.src === "/favicon.svg?v=p-86.1" && wordmark && wordmark.textContent === "z2kOW", "missing profile preserves the single default lockup");
      expect(favicon && favicon.href === "/favicon.svg?v=p-86.1" && mask && mask.href === "/favicon.svg?v=p-86.1", "missing profile preserves default icons");
      expect(!theme, "missing profile does not add a theme stylesheet");
      global.location.hash = "#/strategies"; global.__nav && global.__nav();
      expect(global.document.title === "z2kOW · Стратегии", "missing profile keeps the default tab brand");
    }
  }
  process.exit(errors.length ? 1 : 0);
})();
