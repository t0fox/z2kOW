// Sort state shared across loadState() invocations so a refresh
// (manual button or after delete) preserves the chosen column.
// Defaults: profile asc — same order as the previous unsorted view.
//
// Persisted per browser under z2k-state-sort next to the theme key: it is a
// display preference, not router configuration, and one
// value is shared by the desktop headers and the mobile sheet — two different
// orders on the same screen surprise more than they help.
const STATE_SORT_KEY = "z2k-state-sort";

// The labels double as the mobile sheet's option list, so the set of sortable
// keys is declared once and cannot drift between the two controls.
export const STATE_SORT_LABELS = { key: "Профиль", host: "Домен", strategy: "Стратегия", frozen: "Заморозка", age: "Возраст" };

function loadStateSort() {
  // Anything unrecognised falls back to the default. A stale value (a column
  // renamed in a later release) would otherwise leave the table sorted by
  // nothing at all, which reads as a broken load rather than a stale setting.
  const fallback = { key: "key", dir: "asc" };
  try {
    const raw = localStorage.getItem(STATE_SORT_KEY);
    if (!raw) return fallback;
    const v = JSON.parse(raw);
    if (!v || !STATE_SORT_LABELS[v.key]) return fallback;
    if (v.dir !== "asc" && v.dir !== "desc") return fallback;
    return { key: v.key, dir: v.dir };
  } catch (_) { return fallback; }
}

export function saveStateSort() {
  try { localStorage.setItem(STATE_SORT_KEY, JSON.stringify(stateSort)); } catch (_) {}
}

export let stateSort = loadStateSort();

// Размеры пулов, прочитанные с /pools. Живут здесь, а меняет их страница
// стратегий — единственное место во всём файле, где значение присваивалось
// через границу раздела (замер связности нашёл ровно одно). В модулях
// импортированное имя менять нельзя, поэтому запись идёт через сеттер: так
// владение остаётся у модели, а не размазывается по странице.
export let statePools = {};

export function setStatePools(v) { statePools = v || {}; }

// ГРУППИРОВКА СТРОК РОТАТОРА ПО ДОМЕНУ.
//
// Ключ ротации у доменных пулов — домен второго уровня (z2k_service_hostkey
// в files/lua/z2k-modern-core.lua ставит nld=2). Публичные суффиксы здесь
// используются только для удобной группировки строк в таблице, не для выбора
// ключа двигателя.
//
// Группировка — только вид. Движок по-прежнему держит отдельную ячейку на
// каждое имя, и правка строки уходит в API с тем же сырым ключом; родитель
// нигде не хранится и вычисляется здесь при отрисовке.
//
// Родитель — последние две метки имени, и три, если предпоследняя — служебный
// уровень национальной зоны (news.bbc.co.uk → bbc.co.uk). Полного списка
// публичных суффиксов тут нет сознательно: это ~230 КБ, которые пришлось бы
// отдавать с роутера ради подписи над строками. Промах эвристики здесь стоит
// дёшево — строки не теряются, а оказываются под соседним заголовком. В движке
// та же эвристика была бы ошибкой другого масштаба: чужие сайты делили бы одну
// стратегию, поэтому там её и нет (комментарий у z2k_service_hostkey).
const SLD_GENERIC = new Set([
  "ac", "biz", "co", "com", "edu", "go", "gob", "gov", "info", "int", "ltd",
  "mil", "msk", "ne", "net", "nhs", "nic", "nom", "or", "org", "plc", "pp",
  "sch", "spb",
]);

export function groupDomain(name) {
  const s = String(name == null ? "" : name).toLowerCase();
  // Адрес вместо имени (запись без SNI) не группируется: «3.4» из 1.2.3.4
  // было бы бессмыслицей, а у IPv6 меток нет вовсе.
  if (s.indexOf(":") >= 0 || /^[0-9.]+$/.test(s)) return s;
  const p = s.split(".");
  if (p.length <= 2) return s;
  const tld = p[p.length - 1];
  const sld = p[p.length - 2];
  return p.slice((tld.length === 2 && SLD_GENERIC.has(sld)) ? -3 : -2).join(".");
}

// Раскрытые группы. По умолчанию всё свёрнуто: смысл группировки в том, чтобы
// 109 строк стали 42, а не в том, чтобы добавить к ним ещё 19 заголовков.
// Запоминается в браузере рядом с сортировкой — это настройка вида, а не
// роутера. Без памяти любая правка строки внутри группы сворачивала бы её:
// после каждого изменения таблица перерисовывается целиком.
const STATE_OPEN_KEY = "z2k-state-open-groups";
// Потолок, чтобы список не рос вечно: имена групп после очистки стейта
// остаются в хранилище. Set хранит порядок вставки, отрезаются самые старые.
const STATE_OPEN_MAX = 200;

function loadOpenGroups() {
  try {
    const v = JSON.parse(localStorage.getItem(STATE_OPEN_KEY));
    return new Set(Array.isArray(v) ? v.filter(x => typeof x === "string") : []);
  } catch (_) { return new Set(); }
}

export const stateOpenGroups = loadOpenGroups();

export function saveOpenGroups() {
  const all = Array.from(stateOpenGroups);
  try { localStorage.setItem(STATE_OPEN_KEY, JSON.stringify(all.slice(-STATE_OPEN_MAX))); } catch (_) {}
}

export function stateAge(ts, nowSec) {
  const timestamp = Number(ts);
  return Number.isFinite(timestamp) && timestamp > 0 ? Math.max(0, nowSec - timestamp) : null;
}

export function buildStateBlocks(entries, meta) {
  const sorted = entries.slice().sort((a, b) => {
    let av, bv;
    switch (stateSort.key) {
      case "key": av = String(a.key || ""); bv = String(b.key || ""); break;
      case "host":
        av = meta.get(a).group + "\u0000" + String(a.key || "") + "\u0000" + String(a.host || "");
        bv = meta.get(b).group + "\u0000" + String(b.key || "") + "\u0000" + String(b.host || "");
        break;
      case "strategy": av = Number(a.strategy) || 0; bv = Number(b.strategy) || 0; break;
      case "frozen": av = a.mode === "frozen" ? 0 : 1; bv = b.mode === "frozen" ? 0 : 1; break;
      case "age":
        av = meta.get(a).age; bv = meta.get(b).age;
        if (av === null || bv === null) return av === bv ? 0 : av === null ? 1 : -1;
        break;
      default: return 0;
    }
    if (av < bv) return stateSort.dir === "asc" ? -1 : 1;
    if (av > bv) return stateSort.dir === "asc" ? 1 : -1;
    const ah = meta.get(a).group + "\u0000" + String(a.key || "") + "\u0000" + String(a.host || "");
    const bh = meta.get(b).group + "\u0000" + String(b.key || "") + "\u0000" + String(b.host || "");
    return ah < bh ? -1 : ah > bh ? 1 : 0;
  });

  const blocks = [];
  const byGroup = new Map();
  for (const entry of sorted) {
    const metaEntry = meta.get(entry);
    let block = byGroup.get(metaEntry.gkey);
    if (!block) {
      block = { group: metaEntry.group, gkey: metaEntry.gkey, pool: String(entry.key || ""), rows: [], names: new Set() };
      byGroup.set(metaEntry.gkey, block);
      blocks.push(block);
    }
    block.rows.push(entry);
    block.names.add(metaEntry.name);
  }

  for (const block of blocks) {
    block.age = null;
    for (const entry of block.rows) {
      const age = meta.get(entry).age;
      if (age !== null && (block.age === null || age < block.age)) block.age = age;
    }
  }
  if (stateSort.key !== "age") return blocks;

  // Одиночные имена (в том числе пара IPv4/IPv6) не имеют общего заголовка,
  // поэтому при сортировке по возрасту должны остаться отдельными строками.
  const ageBlocks = blocks.flatMap(block => block.names.size >= 2 ? [block] : block.rows.map(entry => ({
    ...block, rows: [entry], age: meta.get(entry).age,
  })));
  return ageBlocks.sort((a, b) => {
    if (a.age === null || b.age === null) return a.age === b.age ? 0 : a.age === null ? 1 : -1;
    return stateSort.dir === "asc" ? a.age - b.age : b.age - a.age;
  });
}
