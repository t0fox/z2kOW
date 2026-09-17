#!/bin/sh
# tests/test_panel_state_groups.sh — группировка строк ротатора по домену.
#
# Ключ ротации у служебных пулов — полное имя хоста, и таблица «Автоподбор»
# показывала каждый поддомен отдельной строкой: 18 строк apple.com, до сотни у
# discord.media. Строки теперь собраны под заголовком родительского домена.
#
# Что здесь охраняется и почему именно это:
#
#   * Группировка — только ВИД. Строка внутри группы обязана уходить в API с
#     тем же сырым ключом (имя|семейство), иначе удаление и заморозка молча
#     промахнутся мимо записи.
#   * Родитель считается с учётом национальных зон второго уровня: без этого
#     все сайты *.co.uk слиплись бы в одну «группу co.uk».
#   * Адрес вместо имени не группируется — «3.4» из 1.2.3.4 бессмыслица.
#   * Заголовок получает только группа из РАЗНЫХ имён: v4 и v6 одного хоста —
#     не повод для раскрывашки.
#   * По умолчанию свёрнуто, раскрытие переживает перерисовку (после любой
#     правки таблица рисуется заново) и не ходит в сеть.
#   * Сортировка по домену ставит группы по имени родителя, а равные строки
#     в любой сортировке идут по домену — иначе группы перемешаны случайно.
#
# Поведение проверяется исполнением страницы в заглушке DOM, и каждый случай
# продублирован мутантом: сломанная строка обязана дать красный.
#
# POSIX sh.

HERE=$(cd "$(dirname "$0")/.." && pwd)
JS=$(sh "$(cd "$(dirname "$0")" && pwd)/lib/panel_js.sh")
CSS="$HERE/webpanel/www/style.css"
TMP=$(mktemp -d "${TMPDIR:-/tmp}/pgroups.XXXXXX") || exit 1
trap 'rm -rf "$TMP"' EXIT

PASS=0; FAIL=0; SKIP=0
ok()   { PASS=$((PASS+1)); printf '[PASS] %s\n' "$1"; }
no()   { FAIL=$((FAIL+1)); printf '[FAIL] %s (want=%s got=%s)\n' "$1" "$2" "$3"; }
skip() { SKIP=$((SKIP+1)); printf '[SKIP] %s (%s)\n' "$1" "$2"; }

[ -f "$JS" ] && [ -f "$CSS" ] || { printf '[FAIL] missing panel sources\n'; exit 1; }

# --- CSS: свёрнутая группа прячет строки, и правило не проигрывает карточкам --
# На телефоне `.state-table tr { display: block }` стоит ПОЗЖЕ по файлу. Правило
# скрытия обязано быть специфичнее, иначе свёрнутая группа на телефоне
# показывает всё содержимое, а на десктопе прячет — и тест в браузере на
# широком экране этого не увидит.
grep -q '^\.state-table tbody\.sg-closed tr\.sg-member { display: none; }' "$CSS" \
    && ok "свёрнутая группа прячет свои строки (специфичнее мобильной карточки)" \
    || no "правило скрытия строк свёрнутой группы" ".state-table tbody.sg-closed tr.sg-member" "нет"
# Подпись поля на телефоне живёт в td::before. Направляющая группы, нарисованная
# тем же псевдоэлементом, затёрла бы подпись «Домен».
if grep -q 'td\.sg-leaf::before' "$CSS"; then
    no "направляющая группы не занимает td::before" "фон" "::before"
else
    ok "направляющая группы не занимает td::before (там подпись поля на телефоне)"
fi

if ! command -v node >/dev/null 2>&1; then
    skip "поведенческие сценарии" "node не найден"
    printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
    [ "$FAIL" = 0 ]
    exit
fi

# --- родитель домена ---------------------------------------------------------
awk '/const SLD_GENERIC = new Set/,/\]\);/{print} /function groupDomain\(/,/^  \}/{print}' "$JS" \
    | sed 's/^  //' > "$TMP/gd.js"
cat >> "$TMP/gd.js" <<'JS'
const cases = [
  ["finland10000.discord.media", "discord.media"],
  ["discord.media",              "discord.media"],
  ["gs-loc.apple.com",           "apple.com"],
  ["gspe35-ssl.ls.apple.com",    "apple.com"],
  ["news.bbc.co.uk",             "bbc.co.uk"],
  ["bbc.co.uk",                  "bbc.co.uk"],
  ["www.mos.msk.ru",             "mos.msk.ru"],
  ["x.t.co",                     "t.co"],
  ["rr2---sn-xguxaxjvh-8vbs.gvt1.com", "gvt1.com"],
  ["1.2.3.4",                    "1.2.3.4"],
  ["2a00:1450::200e",            "2a00:1450::200e"],
  ["localhost",                  "localhost"],
  ["API.X.COM",                  "x.com"],
];
for (const [inp, want] of cases) {
  const got = groupDomain(inp);
  console.log((got === want ? "OK " : "BAD ") + inp + " -> " + got + (got === want ? "" : " (ждали " + want + ")"));
}
JS
out=$(node "$TMP/gd.js" 2>&1)
nb=$(printf '%s\n' "$out" | grep -c '^BAD' || true)
nk=$(printf '%s\n' "$out" | grep -c '^OK' || true)
if [ "$nb" = 0 ] && [ "$nk" -ge 13 ]; then
    ok "родитель домена: $nk случаев (поддомены, co.uk, адреса, регистр)"
else
    no "родитель домена" "0 плохих из 13" "$(printf '%s' "$out" | tr '\n' ' ')"
fi

# --- отрисовка ---------------------------------------------------------------
DRV="$TMP/driver.js"
cat > "$DRV" <<'DRIVER'
const fs = require("fs");
const APP = process.argv[2];
const SCEN = process.argv[3];

const REG = new Map();
function canon(s) {
  const parts = String(s).trim().split(/\s*>\s*|\s+/);
  const last = parts[parts.length - 1];
  return /^#[A-Za-z0-9_-]+$/.test(last) ? last : String(s);
}
function mkEl(key) {
  const cls = new Set();
  return {
    _sel: key, _h: "", style: {}, dataset: {}, attributes: {}, children: [],
    hidden: false, disabled: false, value: "", listeners: {},
    classList: {
      add(...c) { c.forEach(x => cls.add(x)); }, remove(...c) { c.forEach(x => cls.delete(x)); },
      toggle(c, on) { if (on === undefined ? !cls.has(c) : on) cls.add(c); else cls.delete(c); },
      contains(c) { return cls.has(c); },
    },
    set innerHTML(v) { this._h = String(v); }, get innerHTML() { return this._h; },
    set textContent(v) { this._h = String(v); }, get textContent() { return this._h; },
    addEventListener(t, fn) { (this.listeners[t] = this.listeners[t] || []).push(fn); },
    removeEventListener() {}, appendChild() {}, removeChild() {}, remove() {},
    setAttribute(k, v) { this.attributes[k] = String(v); }, getAttribute(k) { return this.attributes[k]; },
    removeAttribute(k) { delete this.attributes[k]; },
    querySelector(s) { return sel(this._sel + ">" + s); },
    querySelectorAll(s) { return String(s).split(",").map(p => sel(this._sel + ">" + p.trim())); },
    closest() { return null; }, focus() {}, blur() {}, click() {}, insertAdjacentHTML() {}, scrollIntoView() {},
    fire(t, ev) { (this.listeners[t] || []).slice().forEach(f => f(ev || {})); },
  };
}
function sel(s) { const k = canon(s); if (!REG.has(k)) REG.set(k, mkEl(k)); return REG.get(k); }
global.document = {
  documentElement: mkEl("html"), body: mkEl("body"), head: mkEl("head"), listeners: {},
  getElementById(id) { return sel("#" + id); }, querySelector(s) { return sel(s); },
  querySelectorAll(s) { return String(s).split(",").map(x => sel(x.trim())); },
  createElement(t) { return mkEl("new:" + t); }, addEventListener() {}, removeEventListener() {},
};
global.location = { hash: "#/dashboard", href: "http://r/", reload() {} };
global.history = { replaceState() {}, pushState() {} };
const mkStorage = () => {
  const m = new Map();
  return { getItem(k) { return m.has(String(k)) ? m.get(String(k)) : null; },
           setItem(k, v) { m.set(String(k), String(v)); }, removeItem(k) { m.delete(String(k)); },
           clear() { m.clear(); }, key(i) { return Array.from(m.keys())[i] ?? null; }, get length() { return m.size; } };
};
global.localStorage = mkStorage();
global.sessionStorage = mkStorage();
global.window = {
  addEventListener(t, fn) { if (t === "hashchange") global.__nav = fn; }, removeEventListener() {},
  matchMedia() { return { matches: false, addEventListener() {}, addListener() {} }; },
  location: global.location, localStorage: global.localStorage, sessionStorage: global.sessionStorage,
  document: global.document,
};
global.requestAnimationFrame = fn => setTimeout(fn, 0);
global.cancelAnimationFrame = id => clearTimeout(id);
global.getComputedStyle = () => ({ getPropertyValue: () => "" });
global.navigator = { clipboard: { writeText: async () => {} }, userAgent: "node" };
global.confirm = () => true;

const NOW = Math.floor(Date.now() / 1000);
// Порядок в ответе намеренно перемешан: сортировка обязана его навести сама.
const ENTRIES = [
  { key: "rkn_tcp", host: "latency.discord.media|6",       strategy: "1", ts: NOW - 50,  mode: "auto" },
  { key: "rkn_tcp", host: "chatgpt.com|6",                 strategy: "2", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "news.bbc.co.uk|4",              strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "finland10001.discord.media|4",  strategy: "4", ts: NOW - 900, mode: "frozen" },
  { key: "rkn_tcp", host: "1.2.3.4|4",                     strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "sport.other.co.uk|4",           strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "finland10000.discord.media|4",  strategy: "2", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "chatgpt.com|4",                 strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "www.bbc.co.uk|4",               strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "2a00:1450::200e|6",             strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "rkn_tcp", host: "cdn.discordapp.com|4",          strategy: "1", ts: NOW - 900, mode: "auto" },
  { key: "discord_udp", host: "nohost",                    strategy: "1", ts: NOW - 900, mode: "auto" },
  // Тот же домен в ДРУГОМ пуле: у quic свой арсенал, и складывать такие строки
  // в одну группу нельзя — сводка стратегий стала бы про разные наборы.
  { key: "quic", host: "latency.discord.media|4",           strategy: "3", ts: NOW - 900, mode: "auto" },
  { key: "quic", host: "finland10000.discord.media|4",      strategy: "1", ts: NOW - 900, mode: "auto" },
];
const CALLS = {};
const REQS = [];
global.fetch = async (url, init) => {
  const full = String(url).replace(/^.*\/cgi-bin\/api/, "");
  const p = full.split("?")[0];
  CALLS[p] = (CALLS[p] || 0) + 1;
  REQS.push({ path: p, url: full, body: init && init.body ? String(init.body) : "" });
  let body = { ok: true };
  if (p === "/state") body = { ok: true, entries: ENTRIES };
  if (p === "/pools") body = { ok: true, pools: { rkn_tcp: 50 } };
  return { ok: true, status: 200, json: async () => body, text: async () => JSON.stringify(body) };
};
const sleep = ms => new Promise(r => setTimeout(r, ms));
const check = (label, cond, got) => console.log((cond ? "OK " : "BAD ") + label + (cond ? "" : " — " + got));

// Разбор отрисованного: tbody-блоки по порядку, с классом, группой и строками.
function blocks(html) {
  const out = [];
  const re = /<tbody([^>]*)>([\s\S]*?)<\/tbody>/g;
  let m;
  while ((m = re.exec(html))) {
    const attrs = m[1];
    // data-group с 16.09.2026 — СОСТАВНОЙ ключ «пул\u0000домен»: один и тот же
    // домен в разных пулах это разные группы (номера стратегий у пулов свои).
    // Раскладываем, чтобы проверки ниже оставались про домен.
    const graw = (attrs.match(/data-group="([^"]*)"/) || [])[1] || "";
    const gparts = graw.split("\u0000");
    const g = gparts.length > 1 ? gparts[1] : graw;
    const gpool = gparts.length > 1 ? gparts[0] : "";
    const cls = (attrs.match(/class="([^"]*)"/) || [])[1] || "";
    const hosts = [...m[2].matchAll(/class="btn btn-danger btn-icon state-del"[\s\S]*?data-host="([^"]*)"/g)].map(x => x[1]);
    const head = (m[2].match(/<tr class="sg-head">([\s\S]*?)<\/tr>/) || [])[1] || "";
    out.push({ group: g, pool: gpool, raw: graw, cls, hosts, head,
               members: (m[2].match(/class="sg-member"/g) || []).length });
  }
  return out;
}

const SC = {
  render: {
    setup() { localStorage.setItem("z2k-state-sort", JSON.stringify({ key: "host", dir: "asc" })); },
    async run() {
      const html = sel("#state-body").innerHTML;
      const b = blocks(html);
      const dm = b.find(x => x.group === "discord.media" && x.pool === "rkn_tcp");
      const dmq = b.find(x => x.group === "discord.media" && x.pool === "quic");
      check("один домен в двух пулах — две группы, а не одна",
            !!dm && !!dmq && dm.members === 3 && dmq.members === 2,
            JSON.stringify(b.map(x => x.raw)));
      check("группа помнит свой пул", !!dmq && dmq.pool === "quic", dmq && dmq.raw);
      // Кнопки пакетных действий: адресуются составным ключом, иначе действие
      // уедет в группу того же домена из соседнего пула.
      check("в шапке есть сброс группы с составным ключом",
            dm && /class="btn btn-danger btn-icon sg-reset"[\s\S]*?data-gkey="rkn_tcp&#0;discord\.media"/.test(dm.head)
               || (dm && dm.head.indexOf('sg-reset') >= 0 && dm.head.indexOf(dm.raw) >= 0),
            dm && dm.head.replace(/\s+/g, " ").slice(0, 300));
      check("в шапке есть заморозка группы",
            dm && /class="btn btn-icon sg-freeze"/.test(dm.head) && dm.head.indexOf('data-frozen="0"') >= 0,
            dm && dm.head.replace(/\s+/g, " ").slice(0, 300));
      check("частичная заморозка не выдаётся за полную",
            dm && /1 из 3/.test(dm.head), dm && dm.head.replace(/\s+/g, " ").slice(0, 300));
      check("поддомены discord.media собраны в одну группу", dm && dm.members === 3, JSON.stringify(b.map(x => x.group)));
      check("в группе уходят сырые ключи записей (имя|семейство)",
            dm && dm.hosts.join(",") === "finland10000.discord.media|4,finland10001.discord.media|4,latency.discord.media|6",
            dm && dm.hosts.join(","));
      check("по умолчанию группа свёрнута", dm && /\bsg-closed\b/.test(dm.cls), dm && dm.cls);
      check("в заголовке число записей", dm && /class="sg-count"[^>]*>3</.test(dm.head), dm && dm.head.slice(0, 300));
      check("в заголовке сводка стратегий", dm && />1, 2, 4</.test(dm.head), dm && dm.head.replace(/\s+/g, " ").slice(0, 400));
      check("в заголовке виден замороженный", dm && /1 из 3/.test(dm.head), dm && dm.head.replace(/\s+/g, " ").slice(0, 400));
      check("заголовок раскрывается с клавиатуры (кнопка с aria-expanded)",
            dm && /<button type="button" class="sg-toggle" aria-expanded="false"/.test(dm.head), dm && dm.head.slice(0, 200));
      check("bbc.co.uk — своя группа, не «co.uk»",
            b.some(x => x.group === "bbc.co.uk" && x.members === 2) && !b.some(x => x.group === "co.uk"),
            JSON.stringify(b.map(x => x.group)));
      check("одиночный поддомен другой зоны не получает заголовка", !b.some(x => x.group === "other.co.uk"),
            JSON.stringify(b.map(x => x.group)));
      check("v4 и v6 одного имени — не группа", !b.some(x => x.group === "chatgpt.com"),
            JSON.stringify(b.map(x => x.group)));
      check("адреса не группируются", !b.some(x => /1\.2\.3\.4|2a00|3\.4/.test(x.group)),
            JSON.stringify(b.map(x => x.group)));
      check("запись без имени (Discord-войс) в таблицу не попала", html.indexOf('data-host="nohost"') < 0, "nohost в таблице");
      const order = b.flatMap(x => x.group ? ["[" + x.group + "]"] : x.hosts);
      // Две группы discord.media подряд: домен первый ключ, пул второй —
      // quic перед rkn_tcp по алфавиту пула.
      const want = ["1.2.3.4|4", "2a00:1450::200e|6", "[bbc.co.uk]", "chatgpt.com|4", "chatgpt.com|6",
                    "[discord.media]", "[discord.media]", "cdn.discordapp.com|4", "sport.other.co.uk|4"];
      check("по домену группы стоят по имени родителя", JSON.stringify(order) === JSON.stringify(want), JSON.stringify(order));
    },
  },
  tiebreak: {
    setup() { localStorage.setItem("z2k-state-sort", JSON.stringify({ key: "key", dir: "asc" })); },
    async run() {
      const b = blocks(sel("#state-body").innerHTML);
      const order = b.flatMap(x => x.group ? ["[" + x.group + "]"] : x.hosts);
      // Сортировка по профилю: quic идёт раньше rkn_tcp, поэтому его группа
      // стоит первой, а внутри rkn_tcp порядок прежний — по домену.
      const want = ["[discord.media]", "1.2.3.4|4", "2a00:1450::200e|6", "[bbc.co.uk]", "chatgpt.com|4",
                    "chatgpt.com|6", "[discord.media]", "cdn.discordapp.com|4", "sport.other.co.uk|4"];
      check("равные по профилю строки идут по домену", JSON.stringify(order) === JSON.stringify(want), JSON.stringify(order));
    },
  },
  remembered: {
    // Ключ памяти с 16.09.2026 составной: «пул\u0000домен». Старые записи от
    // прежних версий просто не совпадут, и группа отрисуется свёрнутой — это
    // разовая косметика, состояние ротации к ней отношения не имеет.
    setup() { localStorage.setItem("z2k-state-open-groups", JSON.stringify(["rkn_tcp\u0000discord.media"])); },
    async run() {
      const b = blocks(sel("#state-body").innerHTML);
      const dm = b.find(x => x.group === "discord.media" && x.pool === "rkn_tcp");
      check("раскрытая раньше группа рисуется раскрытой", dm && !/\bsg-closed\b/.test(dm.cls), dm && dm.cls);
      const bbc = b.find(x => x.group === "bbc.co.uk");
      check("остальные группы по-прежнему свёрнуты", bbc && /\bsg-closed\b/.test(bbc.cls), bbc && bbc.cls);
    },
  },
  toggle: {
    setup() {},
    async run() {
      const tb = sel("#state-body>tbody.sg");
      tb.dataset.group = "discord.media";
      tb.classList.add("sg-closed");
      const before = CALLS["/state"] || 0;
      sel("#state-body>tbody.sg>.sg-head").fire("click");
      await sleep(20);
      check("клик раскрывает группу", !tb.classList.contains("sg-closed"), "sg-closed остался");
      check("кнопка сообщает, что раскрыто", sel("#state-body>tbody.sg>.sg-toggle").getAttribute("aria-expanded") === "true",
            sel("#state-body>tbody.sg>.sg-toggle").getAttribute("aria-expanded"));
      check("раскрытие запомнено", /discord\.media/.test(localStorage.getItem("z2k-state-open-groups") || ""),
            localStorage.getItem("z2k-state-open-groups"));
      check("раскрытие не ходит в сеть", (CALLS["/state"] || 0) === before, "запросов /state: " + CALLS["/state"]);
      sel("#state-body>tbody.sg>.sg-head").fire("click");
      await sleep(20);
      check("второй клик сворачивает", tb.classList.contains("sg-closed"), "не свернулось");
      check("свёрнутая группа из памяти убрана", !/discord\.media/.test(localStorage.getItem("z2k-state-open-groups") || ""),
            localStorage.getItem("z2k-state-open-groups"));
    },
  },
};

(async () => {
  const s = SC[SCEN];
  s.setup();
  try { new Function(fs.readFileSync(APP, "utf8"))(); }
  catch (e) { console.log("BAD загрузка панели: " + e.message); process.exit(1); }
  await sleep(50);
  global.location.hash = "#/state";
  global.__nav && global.__nav();
  await sleep(120);
  await s.run();
  process.exit(0);
})().catch(e => { console.log("BAD сценарий упал: " + (e && e.stack || e)); process.exit(1); });
DRIVER

run_scen() {
    node "$DRV" "$1" "$2" 2>&1 | while IFS= read -r line; do
        case "$line" in
            "OK "*)  printf '[PASS] %s\n' "${line#OK }" ;;
            "BAD "*) printf '[FAIL] %s\n' "${line#BAD }" ;;
            *)       printf '       %s\n' "$line" ;;
        esac
    done
}
for scen in render tiebreak remembered toggle; do
    out=$(run_scen "$JS" "$scen")
    printf '%s\n' "$out"
    PASS=$((PASS + $(printf '%s\n' "$out" | grep -c '^\[PASS\]')))
    FAIL=$((FAIL + $(printf '%s\n' "$out" | grep -c '^\[FAIL\]')))
    printf '%s\n' "$out" | grep -q '^\[PASS\]' || no "сценарий $scen что-то проверил" ">=1 PASS" "0"
done

# --- мутанты -----------------------------------------------------------------
meta() {
    _label="$1"; _scen="$2"; _sed="$3"
    _mut="$TMP/mutant.js"
    sed "$_sed" "$JS" > "$_mut"
    if cmp -s "$_mut" "$JS"; then
        no "мутант собрался: $_label" "файл изменён" "не изменился"
        return
    fi
    # Краснеть обязана ПРОВЕРКА, а не загрузка: мутант, сломавший синтаксис,
    # тоже дал бы BAD и выдал бы себя за пойманную поломку.
    if node "$DRV" "$_mut" "$_scen" 2>&1 | grep '^BAD' | grep -vq 'загрузка панели\|сценарий упал'; then
        ok "тест ловит поломку: $_label"
    else
        no "тест ловит поломку: $_label" "сценарий краснеет" "зелёный"
    fi
}
meta "заголовок над парой v4/v6 одного имени" render 's/if (b\.names\.size >= 2) {/if (b.rows.length >= 2) {/'
meta "зоны второго уровня не учитываются" render 's/(tld\.length === 2 && SLD_GENERIC\.has(sld)) ? -3 : -2/-2/'
meta "группы раскрыты по умолчанию" render 's/<tbody class="sg\${open ? "" : " sg-closed"}"/<tbody class="sg"/'
meta "сортировка по домену без родителя" render 's/case "host":     av = meta\.get(a)\.group + "\\u0000" + String(a\.key || "") + "\\u0000" + /case "host":     av = /'
meta "равные строки снова в порядке файла" tiebreak 's/return ah < bh ? -1 : ah > bh ? 1 : 0;/return 0;/'
meta "раскрытие не запоминается" remembered 's/const open = stateOpenGroups\.has(b\.gkey);/const open = false;/'
meta "клик не сохраняет раскрытие" toggle 's/^ *saveOpenGroups();$//'

printf '\nPASSED: %d\nFAILED: %d\nSKIPPED: %d\n' "$PASS" "$FAIL" "$SKIP"
[ "$FAIL" = 0 ]
