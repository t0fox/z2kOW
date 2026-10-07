import { apiGet, apiPost, errHtml, errMsg, toastErr } from "../core/api.js";
import { $app, escapeHtml, humanAgo } from "../core/dom.js";
import { _newLoad, _stale, applyCapabilities, refreshStatus } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { JOB_FAIL, _updateGlobalUILock, confirmModal, jobOutcome, jobUnresolved, openJobModal, setLockAware, unresolvedMsg } from "../job.js";
import { AUTOHOSTLIST_WARNING, TOGGLES_RESTART_SERVICE, resyncToggle } from "./policy.js";

const flowBenchmarkRuntime = {
  pollTimer: 0,
  inFlight: "",
  wasActive: false,
  refreshBusy: false,
  lastError: "",
};

const TOGGLE_DEFS = [
  { key: "category_youtube", name: "YouTube",
    desc: "Обход для YouTube и Googlevideo, включая QUIC. Выключите, чтобы эти сервисы работали напрямую." },
  { key: "category_rkn", name: "RKN",
    desc: "Обход сайтов из списков РКН по HTTPS, HTTP и QUIC. При выключении автоподбор новых доменов также не применяется." },
  { key: "category_discord_voice", name: "Discord Voice / STUN",
    desc: "Обход для голосовых соединений Discord. Выключение убирает всю штатную обработку STUN, в том числе для звонков других приложений." },
  // game_warp переехал в собственный раздел «WARP» (renderWarp) вместе с
  // управлением списками адресов — здесь его больше нет.
  { key: "customd", name: "Скрипты custom.d",
    desc: "Дополнительные daemons из init.d/custom.d (50-stun4all, 50-discord-media)." },
  // ТЕКСТ БЫЛ НЕ ПРОСТО НЕЯСНЫМ, А НЕВЕРНЫМ. Здесь стояло «инжекция
  // ФИКСИРОВАННОГО TTL» — ровно наоборот: смысл опции в том, что значение
  // динамическое. И назначением был назван обход обнаружения раздачи, хотя
  // раздача — единственная причина опцию ВЫКЛЮЧИТЬ. Люди сравнивали с README и
  // говорили, что там понятнее; там и было правильно.
  { key: "dynamic_ttl", name: "Динамический TTL",
    desc: "Пакеты-обманки, которыми z2k пробивает блокировку, по умолчанию уходят с одним и тем же счётчиком переходов. У настоящих пакетов с вашего роутера он другой — и по этому расхождению обманку несложно отличить от обычного трафика. Опция подгоняет счётчик под настоящий, и обманка перестаёт выделяться. Выключайте в одном случае: если на роутере включён TTL-fix Keenetic для раздачи мобильного интернета. Там счётчик всё равно переписывает прошивка, наша правка до провода не доживает и только тратит процессор." },
  { key: "ppe", name: "Аппаратный offload: per-flow исключение",
    desc: "На Keenetic (MediaTek) аппаратный ускоритель уводит поток в железо после первого пакета, и роутер не видит повторные ClientHello — стратегия залипает для блокировок без RST (mailsuite и т.п.). Эта опция держит окно рукопожатия на CPU только для нужных портов (родной firmware-механизм -j PPE), поэтому подбор стратегии снова работает, а общий трафик остаётся ускоренным. Работает только на совместимых Keenetic. Выключите, чтобы вернуть прежнее поведение." },
  { key: "fastroute", name: "Программный fastpath: выключать без аппаратного NAT",
    desc: "Выключает программный маршрутный кэш на время работы обхода, если каталог драйвера аппаратного NAT не обнаружен. Это помогает подбору стратегий видеть повторы и сбросы соединений. Выключите опцию, чтобы разрешить кэш. Остальным программным ускорением эта опция не управляет.",
    extra: '<div class="t-desc" id="fastroute-status" role="status"></div>' },
  { key: "autohostlist", name: "Автохостлист",
    desc: "Обычно обходятся только домены из списков. С этой опцией движок сам замечает, что домен не открывается, и добавляет его — найденное попадает в основной список и подхватывается штатно. Плюс: сайты вне списков начинают работать без ручных добавлений. Минус: движок судит по поведению соединения и иногда ошибается, в список может попасть домен, который просто лежал сам по себе. Это смена принципа отбора трафика целиком, поэтому по умолчанию выключено." },
  { key: "tiktok_feed", name: "TikTok — исправление ленты",
    desc: "Автоматически подбирает рабочий CDN для ленты TikTok; в карточке можно выбрать узел вручную.", openwrtOnly: true },
  // Час не зашит в текст: он настраивается ниже, и описание, называющее
  // «02:00» у человека, выбравшего 05:00, врало бы прямо над селектором.
  { key: "auto_update", name: "Автообновление z2k",
    desc: "Ночью роутер проверяет подпись контролируемого релиза z2k и устанавливает доступное обновление. Ручная проверка и запуск находятся в разделе «Обновление».",
    extra: `
      <div class="t-sub" id="au-hour-row" hidden>
        <label class="t-sub-label" for="au-hour">Время</label>
        <select class="t-sub-select" id="au-hour" disabled></select>
        <span class="t-sub-note" id="au-hour-note"></span>
      </div>` },
];

// Разброс запуска: z2k-auto-update.sh сдвигает старт на 0..60 минут
// (z2k_host_jitter 3600) — одинаково для конкретного роутера, но по флоту
// врассыпную, иначе тысяча роутеров придёт к GitHub в одну секунду.
const AU_JITTER_MIN = 60;

const PANEL_SESSION_TTLS = new Set(["7200", "43200", "86400", "604800"]);

async function loadPanelSessionTtl() {
  const sel = document.getElementById("panel-session-ttl");
  const note = document.getElementById("panel-session-ttl-note");
  if (!sel) return;
  try {
    const data = await apiGet("/auth/session-ttl");
    if (!sel.isConnected) return;
    const value = String(data && data.seconds);
    sel.value = PANEL_SESSION_TTLS.has(value) ? value : "86400";
    sel.dataset.saved = sel.value;
    sel.disabled = false;
    if (note) note.textContent = "Настройка будет действовать после следующего входа. Текущая сессия сохранит прежний срок.";
    if (!sel.dataset.wired) {
      sel.dataset.wired = "1";
      sel.addEventListener("change", () => savePanelSessionTtl(sel, note));
    }
  } catch (error) {
    if (!sel.isConnected) return;
    sel.disabled = true;
    if (note) note.textContent = "Не удалось прочитать настройку срока сессии.";
    toastErr("Не удалось прочитать срок сессии: ", error);
  }
}

async function savePanelSessionTtl(sel, note) {
  const value = sel.value;
  const previous = sel.dataset.saved || "86400";
  if (!PANEL_SESSION_TTLS.has(value) || value === previous) return;
  sel.disabled = true;
  try {
    await apiPost("/auth/session-ttl", { seconds: value });
    sel.dataset.saved = value;
    if (note) note.textContent = "Срок сохранён и начнёт действовать после следующего входа; текущая сессия завершится по прежнему сроку.";
    toast("Срок сессии изменён");
  } catch (error) {
    sel.value = previous;
    if (note) note.textContent = "Не удалось сохранить срок; оставлено прежнее значение.";
    toastErr("Не удалось сохранить срок сессии: ", error);
  } finally {
    if (sel.isConnected) sel.disabled = false;
  }
}

function auWindowText(hour) {
  const h = Number(hour);
  if (!Number.isInteger(h) || h < 0 || h > 23) return "";
  const end = (h * 60 + AU_JITTER_MIN) % (24 * 60);
  const pad = n => String(n).padStart(2, "0");
  return `z2k обновится между ${pad(h)}:00 и ${pad(Math.floor(end / 60))}:${pad(end % 60)} — разброс, чтобы роутеры не запрашивали обновление одновременно`;
}

// Выбор времени имеет смысл только при включённом автообновлении, поэтому
// строка следует за тумблером. Живёт отдельной функцией, а не внутри
// обработчика: то же самое делает загрузка состояния и откат неудавшегося
// переключения в toggleClick — иначе строка осталась бы от прошлого ответа.
function auHourSync(box) {
  const row = document.getElementById("au-hour-row");
  if (!row || !box) return;
  row.hidden = !box.checked;
}

// Часы, а не часы с минутами: разброс в час делает минутную точность
// обещанием, которого механизм не даёт.
function wireAuHour(hour, box) {
  const sel = document.getElementById("au-hour");
  const note = document.getElementById("au-hour-note");
  if (!sel) return;
  // children, а не options: список заполняется один раз, а повторный
  // /status приходит на ту же страницу — 24 варианта не должны удваиваться.
  if (!sel.children.length) {
    for (let h = 0; h < 24; h++) {
      const v = String(h).padStart(2, "0");
      const o = document.createElement("option");
      o.value = v;
      o.textContent = `${v}:00`;
      sel.appendChild(o);
    }
  }
  const cur = /^([01][0-9]|2[0-3])$/.test(String(hour || "")) ? String(hour) : "02";
  sel.value = cur;
  // Сохранённое значение держим на самом элементе: с него откатывается
  // выбор, если запись в конфиг не прошла.
  sel.dataset.saved = cur;
  setLockAware(sel, false);
  if (note) note.textContent = auWindowText(cur);
  if (!sel.dataset.wired) {
    sel.dataset.wired = "1";
    sel.addEventListener("change", () => saveAuHour(sel, note));
  }
  auHourSync(box);
}

async function saveAuHour(sel, note) {
  const val = sel.value;
  const prev = sel.dataset.saved || "02";
  if (val === prev) return;
  sel.disabled = true;
  try {
    await apiPost("/update/schedule", { hour: val });
  } catch (e) {
    // Показанный час обязан совпадать с тем, что лежит в конфиге: иначе
    // человек уходит со страницы уверенным, что выбрал время, а ночью
    // сработает старое.
    sel.value = prev;
    if (note) note.textContent = auWindowText(prev);
    toastErr("Не удалось сохранить время: ", e);
    return;
  } finally {
    sel.disabled = false;
  }
  sel.dataset.saved = val;
  if (note) note.textContent = auWindowText(val);
  toast(`Автообновление движка zapret2 в ${val}:00`);
}

const TOGGLE_API_NAME = {
  category_youtube: "category-youtube",
  category_rkn: "category-rkn",
  category_discord_voice: "category-discord-voice",
  customd: "customd",
  dynamic_ttl: "dynamic-ttl",
  ppe: "ppe",
  fastroute: "fastroute",
  auto_update: "auto-update",
  autohostlist: "autohostlist",
  tiktok_feed: "tiktok-feed",
};

function syncFastroute(box, toggles) {
  box.checked = toggles.fastroute === "1";
  setLockAware(box, toggles.fastroute_available !== "1");
  const state = $app.querySelector("#fastroute-status");
  if (state) state.textContent = toggles.fastroute_status || "Состояние маршрутного кэша недоступно.";
}

async function refreshFastroute(box) {
  setLockAware(box, true);
  try {
    const s = await apiGet("/status");
    if (box.isConnected) syncFastroute(box, s.toggles);
  } catch (_) {
    const state = $app.querySelector("#fastroute-status");
    if (state) state.textContent = "Не удалось проверить состояние маршрутного кэша.";
  }
}

// OpenWrt-вариант описания dynamic_ttl: TTL-fix Keenetic там не существует,
// и совет «выключайте, если включён TTL-fix Keenetic» вводит в заблуждение.
// Первые два предложения — те же, что в общем тексте выше; меняется только
// условие выключения. Применяется только при platform=openwrt из /status
// (на Keenetic ключа platform нет — текст 1-в-1 upstream).
const DYNAMIC_TTL_DESC_OPENWRT =
  "Пакеты-обманки, которыми z2k пробивает блокировку, по умолчанию уходят с одним и тем же счётчиком переходов. " +
  "У настоящих пакетов с вашего роутера он другой — и по этому расхождению обманку несложно отличить от обычного трафика. " +
  "Опция подгоняет счётчик под настоящий, и обманка перестаёт выделяться. " +
  "Выключайте, если на роутере настроена своя подмена TTL (например, для раздачи мобильного интернета): " +
  "тогда счётчик всё равно переписывается дальше по тракту, и наша правка только тратит процессор.";

const FLOWOFFLOAD_OPTIONS = [
  ["none", "Выключено"],
  ["software", "Программное ускорение"],
  ["hardware", "Аппаратное ускорение"],
  // Служебный режим остаётся частью существующего контракта, но не становится
  // новой пользовательской возможностью: его можно только увидеть, выбрать нельзя.
  ["donttouch", "Сохранено вне панели"],
];

const FLOWOFFLOAD_MODE_LABELS = Object.fromEntries(FLOWOFFLOAD_OPTIONS);

function flowoffloadModeLabel(mode) {
  return FLOWOFFLOAD_MODE_LABELS[mode] || "Не проверено";
}

function flowoffloadFacts(raw) {
  const facts = {};
  String(raw || "").split(";").forEach(part => {
    const i = part.indexOf("=");
    if (i < 0) return;
    const key = part.slice(0, i).trim();
    if (key) facts[key] = part.slice(i + 1).trim() || "unknown";
  });
  return facts;
}

function flowoffloadFactLabel(key, value) {
  const maps = {
    flowtable: { present: "Есть", absent: "Нет", unknown: "Не проверено" },
    flags: { offload: "Аппаратные флаги", software: "Программные флаги", none: "Нет", unknown: "Не проверено" },
    actual: { software: "Программное ускорение подтверждено", hardware: "Аппаратное ускорение подтверждено", "not-observed": "Не подтверждено", unknown: "Не проверено" },
    hardware: { observed: "Обнаружено", requested: "Запрошено", available: "Доступно", "not-observed": "Не проверено", unknown: "Не проверено" },
    owner: { none: "Нет конфликта", unknown: "Не проверено" },
    packet_visibility: { unknown: "Не проверено" },
    circular: { unknown: "Не проверено" },
  };
  if (key === "exemptions") return /^\d+$/.test(String(value)) ? String(value) : "Не проверено";
  if (key === "mode") return flowoffloadModeLabel(value);
  if (maps[key] && maps[key][value]) return maps[key][value];
  if (key === "owner" && value) {
    const ownerLabels = {
      "global_fw4+nfqueue": "fw4 и NFQUEUE одновременно",
      "global_fw4+zapret2": "fw4 и zapret2 одновременно",
      global_fw4_only: "только глобальный fw4",
    };
    return ownerLabels[value] || (value === "none" ? "Нет конфликта" : "Обнаружен конфликт владельцев");
  }
  return value || "Не проверено";
}

function flowoffloadFactMarkup(key, label, facts) {
  const raw = facts[key] || "unknown";
  return `<div class="flow-fact">
    <span class="flow-fact-label">${label}</span>
    <span class="flow-fact-value"><span>${escapeHtml(flowoffloadFactLabel(key, raw))}</span><code>${escapeHtml(raw)}</code></span>
  </div>`;
}

function flowoffloadTechnicalMarkup(facts) {
  return `<details class="flow-technical disclosure" id="flowoffload-technical">
    <summary>Техническая диагностика <span>(Selective FLOWOFFLOAD)</span></summary>
    <div class="disclosure-body"><div class="flow-technical-body">
      <div class="flow-facts">
        ${flowoffloadFactMarkup("mode", "Выбранный режим", facts)}
        ${flowoffloadFactMarkup("flowtable", "Flowtable", facts)}
        ${flowoffloadFactMarkup("flags", "Флаги ускорения", facts)}
        ${flowoffloadFactMarkup("exemptions", "Правила исключений", facts)}
        ${flowoffloadFactMarkup("actual", "Фактическое ускорение", facts)}
        ${flowoffloadFactMarkup("hardware", "Аппаратное состояние", facts)}
        ${flowoffloadFactMarkup("owner", "Владелец/конфликт", facts)}
      </div>
      <div class="flow-traffic-diagnostics">
        <div class="flow-traffic-title">Диагностика обработки трафика</div>
        <div class="flow-facts">
          ${flowoffloadFactMarkup("packet_visibility", "Видимость пакетов", facts)}
          ${flowoffloadFactMarkup("circular", "Circular", facts)}
        </div>
      </div>
    </div></div>
  </details>`;
}

function tiktokReasonLabel(reason) {
  return ({
    healthy: "Проверка прошла успешно",
    "current-ip-fast-path": "Текущий узел подтвердил доступность",
    "no-current": "Подтверждён первый рабочий узел",
    "current-unhealthy": "Текущий узел не прошёл проверку",
    "material-latency-improvement": "Найден заметно более быстрый узел",
    "hysteresis-not-met": "Переключение отложено: разница в задержке недостаточна",
    "alternative-unhealthy": "Альтернативный узел не прошёл проверку",
    "transient-probe-failure": "Временный сбой проверки текущего узла",
    "dnsmasq-prepare-failed": "Не удалось настроить DNS-подмену; обычный доступ сохранён",
    "no-verified-cdn-fail-open": "Рабочий CDN не найден; DNS-подмена не включена, обычный доступ сохранён",
    "no-verified-alternative": "Не найден стабильный альтернативный узел CDN",
    "consecutive-probe-failures": "Предыдущий узел не прошёл проверку доступности",
    disabled: "Исправление ленты выключено",
  })[reason] || "Состояние CDN требует проверки.";
}

function tiktokValue(value, { allowZero = false } = {}) {
  if (value == null) return "";
  const text = String(value).trim();
  if (!text || /^(null|undefined)$/i.test(text) || (!allowZero && /^0+(\.0+)?$/.test(text))) return "";
  return text;
}

let tiktokStatusSnapshot = null;
let tiktokTogglesSnapshot = null;
let tiktokPlatformSnapshot = "";
let tiktokServerNowEpoch = 0;
let tiktokPendingAction = null;

function tiktokFact(label, value) {
  const shown = tiktokValue(value, { allowZero: label === "Ошибок подряд" });
  if (!shown) return "";
  return `<div class="flow-fact"><span class="flow-fact-label">${label}</span><span class="flow-fact-value"><span>${escapeHtml(shown)}</span></span></div>`;
}

function tiktokReasonFact(label, reason) {
  const raw = tiktokValue(reason);
  if (!raw) return "";
  return `<div class="flow-fact tiktok-reason-fact"><span class="flow-fact-label">${label}</span><span class="flow-fact-value"><span>${escapeHtml(tiktokReasonLabel(raw))}</span><code>raw: ${escapeHtml(raw)}</code></span></div>`;
}

function tiktokDiagnosticSection(title, facts) {
  const content = facts.filter(Boolean).join("");
  return content ? `<section class="tiktok-diagnostic-section"><h4>${title}</h4><div class="flow-facts">${content}</div></section>` : "";
}

function tiktokLatency(value) {
  const latency = tiktokValue(value);
  return latency ? `${latency} мс` : "";
}

function tiktokTime(epoch, detailed = false, serverNowEpoch = 0) {
  const seconds = Number(epoch);
  if (!Number.isFinite(seconds) || seconds <= 0) return "";
  const ago = humanAgo(seconds, serverNowEpoch);
  if (ago === "время не синхронизировано") return ago;
  const date = new Date(seconds * 1000);
  return detailed ? `${date.toLocaleString()} · ${ago}` : ago;
}

function tiktokCandidatesMarkup(data, pending = null) {
  const candidates = new Map();
  String(data.candidate_pool || "").split(";").forEach(raw => {
    const fields = raw.split("|");
    const ip = tiktokValue(fields[0]);
    if (ip && /^\d{1,3}(?:\.\d{1,3}){3}$/.test(ip) && !candidates.has(ip)) {
      candidates.set(ip, fields);
    }
  });
  const probes = new Map();
  String(data.probe_observations || "").split(";").forEach(raw => {
    const fields = raw.split("|");
    const ip = tiktokValue(fields[0]);
    if (ip) probes.set(ip, fields);
  });
  const mode = data.mode === "manual" ? "manual" : "auto";
  const selectedIp = tiktokValue(data.selected_ip);
  const rows = [...candidates.entries()].map(([ip, candidate], index) => {
    const probe = probes.get(ip) || [];
    const selected = selectedIp === ip;
    const unavailable = selected && data.state === "manual-unavailable";
    const v77Verified = probe[10] === "verified";
    const euVerified = probe[20] === "verified";
    const verified = !unavailable && probe[21] === "compatible" && v77Verified && euVerified;
    const checked = probe.length >= 22;
    const checkNodes = Number.parseInt(candidate[11], 10) || 0;
    const checkCountries = Number.parseInt(candidate[12], 10) || 0;
    const checkAsns = Number.parseInt(candidate[13], 10) || 0;
    const hint = tiktokValue(candidate[6]) || "";
    const source = [candidate[7], candidate[4]].map(tiktokValue).filter(Boolean).join(" · ");
    const latencyValue = verified ? Number.parseInt(probe[1], 10) : 0;
    const category = verified ? "working" : checked ? "unavailable" : "unknown";
    const icmp = tiktokLatency(probe[22]);
    const targetCell = (label, latencyIndex, verifiedIndex) => {
      if (probe.length < 22) return `<span class="tiktok-target-probe pending">${label} <b>Не проверен</b></span>`;
      return probe[verifiedIndex] === "verified"
        ? `<span class="tiktok-target-probe good">${label} <b>✓ ${escapeHtml(tiktokLatency(probe[latencyIndex]) || "TLS")}</b></span>`
        : `<span class="tiktok-target-probe bad">${label} <b>✕ timeout</b></span>`;
    };
    const tcpLabel = (value) => value === "ok" ? "Доступен" : value === "failed" ? "Нет ответа" : "—";
    const tlsLabel = (value) => value === "ok" ? "Проверен" : value === "failed" ? "Не прошёл" : "—";
    const targetFacts = (name, offset) => {
      const eu = offset === 11;
      const tcp = probe[offset + (eu ? 7 : 8)] || "";
      const tls = probe[offset + (eu ? 8 : 9)] || "";
      const latency = tiktokLatency(probe[offset + (eu ? 0 : 1)]);
      const http = tiktokValue(probe[offset + (eu ? 3 : 4)]);
      const pop = tiktokValue(probe[offset + (eu ? 4 : 5)]);
      const server = tiktokValue(probe[offset + (eu ? 6 : 7)]);
      const popServer = [pop ? `POP ${pop}` : "", server].filter(Boolean).join(" · ");
      return [
        `<span>TCP 443 · ${name}<b>${escapeHtml(tcpLabel(tcp))}</b></span>`,
        `<span>TLS/SNI · ${name}<b>${escapeHtml(tlsLabel(tls))}</b></span>`,
        `<span>HTTPS · ${name}<b>${escapeHtml(latency || "—")}</b></span>`,
        `<span>HTTP · ${name}<b>${escapeHtml(http || "—")}</b></span>`,
        `<span>POP / сервер · ${name}<b>${escapeHtml(popServer || "—")}</b></span>`,
      ].join("");
    };
    const button = verified
      ? `<button type="button" class="btn btn-secondary tiktok-select-cdn" data-tiktok-action="select" data-ip="${escapeHtml(ip)}" aria-label="Выбрать CDN ${escapeHtml(ip)}"${pending ? " disabled" : ""}>Выбрать</button>`
      : "";
    return { ip, candidate, probe, selected, verified, checked, category, hint, source, checkNodes, checkCountries, checkAsns, latencyValue, icmp, button, targetCell, targetFacts, index };
  });
  const categoryOrder = { working: 0, unknown: 1, unavailable: 2 };
  rows.sort((a, b) => Number(b.selected) - Number(a.selected)
    || categoryOrder[a.category] - categoryOrder[b.category]
    || (a.category === "working" && b.category === "working" ? (a.latencyValue || Number.MAX_SAFE_INTEGER) - (b.latencyValue || Number.MAX_SAFE_INTEGER) : 0)
    || a.index - b.index);

  const candidateRow = (row, hidden = false) => {
    const statusLabel = row.category === "working" ? "Доступен" : row.category === "unavailable" ? "Недоступен" : "Не проверен";
    const statusKind = row.category === "working" ? "good" : row.category === "unavailable" ? "bad" : "pending";
    const selection = row.selected
      ? `<span class="tiktok-selected-label" aria-current="true">✓ Выбран</span>`
      : row.button;
    const compatibility = row.verified
      ? `<span class="tiktok-candidate-verified">TLS ✓ · v77 ✓ · v77-eu ✓</span>`
      : row.checked ? `<span>Проверка TLS не пройдена</span>` : "";
    const source = row.source ? `<span>Источники: ${escapeHtml(row.source)}</span>` : "";
    const checkhost = row.checkNodes
      ? `<span>Check-Host · ${row.checkNodes} узлов / ${row.checkCountries} стран / ${row.checkAsns} ASN</span>` : "";
    return `<article class="tiktok-candidate ${row.category}${row.selected ? " selected" : ""}" data-ip="${escapeHtml(row.ip)}" data-state="${row.category}"${hidden ? " hidden data-tiktok-overflow" : ""}>
      <div class="tiktok-candidate-head">
        <div class="tiktok-candidate-primary">
          <div class="tiktok-candidate-title"><code>${escapeHtml(row.ip)}</code><span class="tiktok-candidate-status ${statusKind}">● ${statusLabel}</span></div>
          <span class="tiktok-candidate-region">${escapeHtml(row.hint || "Регион не определён")}</span>
        </div>
        <div class="tiktok-candidate-actions">${row.verified && row.latencyValue ? `<span class="tiktok-candidate-latency">${escapeHtml(tiktokLatency(row.latencyValue))}</span>` : ""}${selection}</div>
      </div>
      ${compatibility || checkhost || source ? `<div class="tiktok-candidate-meta">${compatibility}${checkhost}${source}</div>` : ""}
      <details class="tiktok-candidate-details">
        <summary>Подробнее</summary>
        <div class="tiktok-candidate-technical">
          ${row.source || row.candidate[1] ? `<div class="tiktok-candidate-source">${row.source ? `Источники: ${escapeHtml(row.source)}` : ""}${row.candidate[1] ? ` · Домены: ${escapeHtml(row.candidate[1])}` : ""}</div>` : ""}
          ${row.checkNodes ? `<div class="tiktok-checkhost-count">Check-Host: ${row.checkNodes} узлов / ${row.checkCountries} стран / ${row.checkAsns} ASN</div>` : ""}
          <div class="tiktok-compatibility">${row.targetCell("v77", 1, 10)}${row.targetCell("v77-eu", 11, 20)}</div>
          <div class="tiktok-candidate-facts">
            <span>ICMP <b title="Ping не влияет на доступность CDN">${escapeHtml(row.icmp || "—")}</b></span>
            ${row.targetFacts("v77", 0)}${row.targetFacts("v77-eu", 11)}
          </div>
          ${row.checked && !row.verified ? `<div class="tiktok-candidate-warning">Недоступен с вашего подключения</div>` : ""}
          ${row.selected && data.state === "manual-unavailable" ? `<div class="tiktok-candidate-warning" role="status">Выбранный CDN недоступен</div>` : ""}
        </div>
      </details>
    </article>`;
  };

  const selected = rows.find(row => row.selected);
  const working = rows.filter(row => row.category === "working" && !row.selected);
  const unchecked = rows.filter(row => row.category === "unknown" && !row.selected);
  const unavailable = rows.filter(row => row.category === "unavailable" && !row.selected);
  const unavailableCount = rows.filter(row => row.category === "unavailable").length;
  const maxVisible = 8;
  const workingSlots = Math.max(0, maxVisible - (selected ? 1 : 0));
  const visibleWorking = working.slice(0, workingSlots);
  const overflowWorking = working.slice(workingSlots);
  const checked = [...probes.values()].some(probe => probe.length >= 22);
  const availableCount = rows.filter(row => row.category === "working").length;
  const bestLatency = rows.filter(row => row.category === "working" && row.latencyValue > 0)
    .reduce((best, row) => Math.min(best, row.latencyValue), Number.MAX_SAFE_INTEGER);
  const plural = candidates.size === 1 ? "кандидат" : candidates.size >= 2 && candidates.size <= 4 ? "кандидата" : "кандидатов";
  const candidateSummary = checked
    ? `${candidates.size} ${plural} · ${availableCount} доступны${bestLatency < Number.MAX_SAFE_INTEGER ? ` · лучший ${tiktokLatency(bestLatency)}` : ""}`
    : `${candidates.size} ${plural} · проверка не выполнена`;
  const visibleCount = (selected ? 1 : 0) + visibleWorking.length;
  const hasHidden = visibleCount < candidates.size;
  const modeControl = `<div class="tiktok-candidate-controls">
      <div class="tiktok-mode-control"><span class="tiktok-mode-label">Режим</span><div class="tiktok-mode-switch" role="group" aria-label="Режим выбора CDN">
        <button type="button" class="tiktok-mode-segment${mode === "auto" ? " active" : ""}" data-tiktok-action="auto" data-tiktok-mode="auto" aria-pressed="${mode === "auto"}"${pending || mode === "auto" ? " disabled" : ""}>Авто</button>
        <button type="button" class="tiktok-mode-segment${mode === "manual" ? " active" : ""}" data-tiktok-action="manual" data-tiktok-mode="manual" data-ip="${escapeHtml(selectedIp)}" aria-pressed="${mode === "manual"}"${pending || mode === "manual" || !selectedIp || data.candidate_verified !== "1" ? " disabled" : ""}>Вручную</button>
      </div></div>
      <button type="button" class="btn btn-primary" data-tiktok-action="probe-all"${pending ? " disabled" : ""}>Проверить все</button>
    </div>`;
  const filterControls = `<div class="tiktok-candidate-filters" role="group" aria-label="Фильтр CDN-кандидатов">
      <button type="button" class="tiktok-filter active" data-tiktok-action="filter" data-tiktok-filter="all" aria-pressed="true">Все <span>${candidates.size}</span></button>
      <button type="button" class="tiktok-filter" data-tiktok-action="filter" data-tiktok-filter="working" aria-pressed="false">Рабочие <span>${availableCount}</span></button>
      <button type="button" class="tiktok-filter" data-tiktok-action="filter" data-tiktok-filter="unavailable" aria-pressed="false">Недоступные <span>${unavailableCount}</span></button>
    </div>`;
  const workingGroup = `<section class="tiktok-candidate-group" data-tiktok-candidate-group="working">
      <h4>Рабочие CDN (${availableCount})</h4>
      <div class="tiktok-candidate-rows">${visibleWorking.map(row => candidateRow(row)).join("")}${overflowWorking.map(row => candidateRow(row, true)).join("")}</div>
    </section>`;
  const uncheckedGroup = unchecked.length
    ? `<details class="tiktok-candidate-group tiktok-unchecked-group" data-tiktok-candidate-group="unknown"><summary>Не проверены (${unchecked.length})</summary><div class="tiktok-candidate-rows">${unchecked.map(row => candidateRow(row)).join("")}</div></details>` : "";
  const unavailableGroup = unavailable.length
    ? `<details class="tiktok-candidate-group tiktok-unavailable-group" data-tiktok-candidate-group="unavailable"><summary>Недоступные (${unavailable.length})</summary><div class="tiktok-candidate-rows">${unavailable.map(row => candidateRow(row)).join("")}</div></details>` : "";
  const showAll = hasHidden
    ? `<button type="button" class="tiktok-show-all" data-tiktok-action="show-all">Показать все ${candidates.size}</button>` : "";
  const empty = !candidates.size ? `<p class="tiktok-candidate-empty">Кандидаты ещё не обнаружены</p>` : "";
  return `${modeControl}
    <div class="tiktok-candidate-overview">
      <div class="tiktok-candidate-summary" role="status">${escapeHtml(candidateSummary)}</div>
      ${filterControls}
      <div class="tiktok-candidate-list">
        ${empty}
        ${selected ? `<div class="tiktok-candidate-group tiktok-selected-candidate-group" data-tiktok-candidate-group="${selected.category}">${candidateRow(selected)}</div>` : ""}
        ${availableCount ? workingGroup : ""}
        ${uncheckedGroup}
        ${unavailableGroup}
        ${showAll}
      </div>
    </div>`;
}

function wireTikTokActions(card) {
  if (card.dataset.actionsWired) return;
  card.dataset.actionsWired = "1";
  card.addEventListener("click", async event => {
    const button = event.target.closest("[data-tiktok-action]");
    if (!button || button.disabled) return;
    const action = button.dataset.tiktokAction;
    if (action === "filter") {
      const filter = button.dataset.tiktokFilter;
      const allExpanded = card.dataset.tiktokAllExpanded === "1";
      card.querySelectorAll("[data-tiktok-filter]").forEach(item => {
        const active = item.dataset.tiktokFilter === filter;
        item.classList.toggle("active", active);
        item.setAttribute("aria-pressed", String(active));
      });
      card.querySelectorAll("[data-tiktok-candidate-group]").forEach(group => {
        group.hidden = filter !== "all" && group.dataset.tiktokCandidateGroup !== filter;
        if (group instanceof HTMLDetailsElement) group.open = filter === "unavailable" || (filter === "all" && allExpanded);
      });
      card.querySelectorAll("[data-tiktok-overflow]").forEach(item => {
        item.hidden = filter === "all" && !allExpanded;
      });
      const showAll = card.querySelector('[data-tiktok-action="show-all"]');
      if (showAll) showAll.hidden = filter !== "all" || allExpanded;
      return;
    }
    if (action === "show-all") {
      card.dataset.tiktokAllExpanded = "1";
      card.querySelectorAll("[data-tiktok-filter]").forEach(item => {
        const active = item.dataset.tiktokFilter === "all";
        item.classList.toggle("active", active);
        item.setAttribute("aria-pressed", String(active));
      });
      card.querySelectorAll("[data-tiktok-candidate-group]").forEach(group => {
        group.hidden = false;
        if (group instanceof HTMLDetailsElement) group.open = true;
      });
      card.querySelectorAll("[data-tiktok-overflow]").forEach(item => { item.hidden = false; });
      button.hidden = true;
      return;
    }
    const endpoints = { "probe-all": "/tiktok/probe-all", select: "/tiktok/select", manual: "/tiktok/select", auto: "/tiktok/auto" };
    const labels = { "probe-all": "Проверка CDN-кандидатов", select: "Проверка и выбор CDN", manual: "Фиксация текущего CDN", auto: "Автоматический выбор CDN" };
    if (!endpoints[action]) return;
    tiktokPendingAction = { action, ip: action === "select" ? button.dataset.ip : "" };
    renderTikTokStatus(tiktokStatusSnapshot, tiktokTogglesSnapshot, tiktokPlatformSnapshot, tiktokServerNowEpoch);
    const buttons = [...card.querySelectorAll("[data-tiktok-action]")];
    buttons.forEach(item => { item.disabled = true; });
    try {
      const params = action === "select" || action === "manual" ? { ip: button.dataset.ip } : {};
      const response = await apiPost(endpoints[action], params);
      openJobModal(labels[action], response.job, {
        tolerateOutage: action === "select" || action === "auto",
        onDone: async result => {
          if (jobOutcome(result) === JOB_FAIL) {
            toast(action === "select" ? "Выбранный CDN недоступен или не удалось применить DNS" : `${labels[action]} не выполнена`, "bad");
          } else if (!jobUnresolved(jobOutcome(result))) {
            toast(action === "auto" ? "Включён автоматический выбор CDN" : "Проверка CDN завершена");
          }
          tiktokPendingAction = { action: "refresh" };
          renderTikTokStatus(tiktokStatusSnapshot, tiktokTogglesSnapshot, tiktokPlatformSnapshot, tiktokServerNowEpoch);
          try {
            const state = await apiGet("/status");
            tiktokPendingAction = null;
            renderTikTokStatus(state.tiktok_feed_status, state.toggles, state.platform, state.server_now_epoch);
          } catch (_) {
            tiktokPendingAction = null;
            renderTikTokStatus(tiktokStatusSnapshot, tiktokTogglesSnapshot, tiktokPlatformSnapshot, tiktokServerNowEpoch);
            toastErr("Не удалось обновить состояние TikTok CDN: ", "status недоступен");
          }
        },
      });
    } catch (error) {
      tiktokPendingAction = null;
      renderTikTokStatus(tiktokStatusSnapshot, tiktokTogglesSnapshot, tiktokPlatformSnapshot, tiktokServerNowEpoch);
      buttons.forEach(item => { if (item.isConnected) item.disabled = false; });
      toastErr("Не удалось выполнить действие TikTok CDN: ", error);
    }
  });
}

function tiktokStatusMarkup(status, serverNowEpoch, pending = null) {
  const data = status || {};
  const state = tiktokValue(data.state);
  const ip = tiktokValue(data.selected_ip);
  const mode = data.mode === "manual" ? "manual" : "auto";
  const reason = tiktokValue(data.reason);
  let title = "Рабочий CDN не найден";
  let kind = "warn";
  let copy = tiktokReasonLabel(reason);
  if (state === "manual-unavailable") {
    title = "Выбранный CDN недоступен"; kind = "bad";
    copy = "Автоматическое переключение отключено; выбранный адрес не меняется.";
  } else if (state === "dns-apply-error" || (data.candidate_verified === "1" && data.dns_override_applied !== "1")) {
    title = "Ошибка применения DNS"; kind = "bad";
    copy = "CDN проверен, но эффективная DNS-подмена не подтверждена.";
  } else if (state === "healthy" && ip && data.candidate_verified === "1" && data.dns_override_applied === "1") {
    title = "Работает"; kind = "good"; copy = "";
  } else if (state === "healthy" && ip) {
    title = "DNS-применение не подтверждено"; kind = "warn";
    copy = "Эффективный адрес роутера ещё не подтверждён.";
  } else if (state === "degraded" && ip) {
    title = "Нестабильно"; copy = tiktokReasonLabel(reason);
  } else if (["searching", "discovering", "checking"].includes(state)) {
    title = "Поиск рабочего CDN"; copy = "Проверяются доступные узлы TikTok…";
  }
  if (pending) {
    if (pending.action === "select") {
      title = "Проверяю новый CDN…";
      copy = "Текущий CDN остаётся активным до успешной проверки и применения.";
    } else if (pending.action === "probe-all") {
      title = "Идёт проверка кандидатов…";
      copy = "Кандидаты проверяются; предыдущий результат остаётся доступен ниже.";
    } else if (pending.action === "auto" || pending.action === "manual") {
      title = pending.action === "auto" ? "Переключаю в автоматический режим…" : "Закрепляю текущий CDN вручную…";
      copy = "Текущий CDN остаётся активным до завершения операции.";
    } else if (pending.action === "refresh") {
      title = "Обновляю состояние CDN…";
      copy = "Операция завершена; загружаю актуальный результат.";
    }
  }

  const checkedAgo = tiktokTime(data.last_verified_epoch, false, serverNowEpoch);
  const selectedAgo = tiktokTime(data.selected_at_epoch, false, serverNowEpoch);
  const candidatesCheckedAgo = tiktokTime(data.candidates_checked_epoch, false, serverNowEpoch);
  const failoverReason = tiktokValue(data.last_failover_reason);
  const failoverFrom = tiktokValue(data.last_failover_from);
  const failoverTo = tiktokValue(data.last_failover_to);
  const failoverAgo = tiktokTime(data.last_failover_epoch, false, serverNowEpoch);
  const hasFailover = Boolean(failoverAgo && failoverFrom && failoverTo && failoverFrom !== failoverTo);
  const selectionEvent = ip
    ? `✓ Текущий CDN выбран ${mode === "manual" ? "вручную" : "автоматически"}${selectedAgo ? ` ${escapeHtml(selectedAgo)}` : ""}`
    : "";
  const currentFacts = ip || tiktokLatency(data.latency_ms)
    ? `<dl class="tiktok-current-facts">
        ${ip ? `<div><dt>Текущий CDN</dt><dd><code>${escapeHtml(ip)}</code></dd></div>` : ""}
        ${tiktokLatency(data.latency_ms) ? `<div><dt>Задержка</dt><dd>${escapeHtml(tiktokLatency(data.latency_ms))}</dd></div>` : ""}
      </dl>${selectionEvent ? `<p class="tiktok-selection-event"><span aria-hidden="true">✓</span> ${escapeHtml(selectionEvent.slice(2))}</p>` : ""}`
    : "";
  const diagnostics = [
    tiktokDiagnosticSection("Соединение", [
      tiktokFact("TCP-соединение", tiktokLatency(data.connect_latency_ms)),
      tiktokFact("TLS", tiktokLatency(data.tls_latency_ms)),
      tiktokFact("HTTP-ответ", data.http_status),
      tiktokFact("POP", data.x77_pop),
      tiktokFact("Кэш", data.x77_cache),
      tiktokFact("Сервер", data.server),
    ]),
    tiktokDiagnosticSection("Выбранный узел", [
      tiktokFact("Домен источника", data.selected_source_domain),
      tiktokFact("CNAME", data.selected_cname),
      tiktokFact("Режим", data.selected_mode),
      tiktokFact("Текущий выбор", mode === "manual" ? "manual" : "auto"),
      tiktokFact("Время выбора", tiktokTime(data.selected_at_epoch, true, serverNowEpoch)),
      tiktokFact("Регион", data.selected_geo_hint),
      tiktokFact("Источник узла", data.selected_provenance),
    ]),
    tiktokDiagnosticSection("Проверка", [
      tiktokFact("Состояние", data.health || state),
      tiktokFact("Ошибок подряд", data.failure_count),
      tiktokFact("DNS-наблюдений", data.dns_observed),
      tiktokFact("Curated-наблюдений", data.curated_observed),
      tiktokFact("Проверок стабильности", data.stability_probe_count),
      tiktokFact("Задержка узла", tiktokLatency(data.latency_ms)),
      tiktokFact("Последняя проверка текущего CDN", tiktokTime(data.last_verified_epoch, true, serverNowEpoch)),
      tiktokFact("Полная проверка кандидатов", tiktokTime(data.candidates_checked_epoch, true, serverNowEpoch)),
      tiktokReasonFact("Причина", reason),
    ]),
    hasFailover ? tiktokDiagnosticSection("Последнее автоматическое переключение", [
      tiktokFact("Маршрут", `${failoverFrom} → ${failoverTo}`),
      tiktokFact("Время", tiktokTime(data.last_failover_epoch, true, serverNowEpoch)),
      tiktokReasonFact("Причина", failoverReason),
    ]) : "",
  ].join("");
  const candidates = tiktokCandidatesMarkup(data, pending);
  const statusTime = pending && pending.action === "probe-all"
    ? candidatesCheckedAgo ? `Последняя завершённая проверка кандидатов: ${candidatesCheckedAgo}` : "Полная проверка кандидатов ещё не завершена"
    : checkedAgo ? `${pending && ip ? "Текущий CDN проверен" : "Последняя проверка текущего CDN"}: ${checkedAgo}` : "";
  const pendingIp = pending && pending.action === "select" && pending.ip
    ? `<p class="tiktok-operation-pending">Проверяется CDN <code>${escapeHtml(pending.ip)}</code></p>` : "";
  return `<h3>TikTok — состояние ленты</h3>
    <p class="desc">Автоматический подбор и контроль CDN</p>
    <div class="tiktok-status-line"><span class="tiktok-status-badge ${pending ? "warn" : kind}" role="status">● ${escapeHtml(title)}</span>${statusTime ? `<span class="tiktok-checked">${escapeHtml(statusTime)}</span>` : ""}</div>
    ${copy ? `<p class="desc">${escapeHtml(copy)}</p>` : ""}
    ${currentFacts ? `<div class="tiktok-selection-summary">${currentFacts}${pendingIp}</div>` : pendingIp ? `<div class="tiktok-selection-summary">${pendingIp}</div>` : ""}
    ${candidates}
    <details class="flow-technical disclosure" id="tiktok-feed-technical">
      <summary>Техническая диагностика</summary>
      <div class="disclosure-body"><div class="flow-technical-body">${diagnostics}</div></div>
    </details>`;
}

function renderTikTokStatus(status, toggles, platform, serverNowEpoch) {
  const card = $app.querySelector("#tiktok-feed-status-card");
  if (!card) return;
  wireTikTokActions(card);
  if (status) tiktokStatusSnapshot = status;
  if (toggles) tiktokTogglesSnapshot = toggles;
  if (platform) tiktokPlatformSnapshot = platform;
  if (serverNowEpoch !== undefined) tiktokServerNowEpoch = serverNowEpoch;
  const visible = platform === "openwrt" && toggles && toggles.tiktok_feed === "1";
  card.hidden = !visible;
  const signature = JSON.stringify({
    visible: !!visible,
    status: status || null,
    enabled: toggles && toggles.tiktok_feed,
    platform,
    pending: tiktokPendingAction,
  });
  if (card.dataset.stateSignature === signature) return;
  const openDetails = [...card.querySelectorAll("details[open]")].map((details, index) => details.id || String(index));
  const scrollState = [...card.querySelectorAll("*")]
    .map((el, index) => ({ id: el.id, index, top: el.scrollTop, left: el.scrollLeft }))
    .filter(item => item.top || item.left);
  const focused = card.contains(document.activeElement) ? document.activeElement : null;
  const focusedId = focused && focused.id;
  const focusedAction = focused && focused.getAttribute("data-tiktok-action");
  const focusedActionAttributes = focusedAction
    ? ["data-ip", "data-tiktok-mode", "data-tiktok-filter"]
      .map(name => [name, focused.getAttribute(name)])
      .filter(([, value]) => value !== null)
    : [];
  const selection = focused && typeof focused.selectionStart === "number"
    ? [focused.selectionStart, focused.selectionEnd, focused.selectionDirection] : null;
  card.innerHTML = visible ? tiktokStatusMarkup(status, tiktokServerNowEpoch, tiktokPendingAction) : "";
  card.dataset.stateSignature = signature;
  [...card.querySelectorAll("details")].forEach((details, index) => {
    if (openDetails.includes(details.id || String(index))) details.open = true;
  });
  scrollState.forEach(item => {
    const el = item.id ? card.querySelector(`#${CSS.escape(item.id)}`) : card.querySelectorAll("*")[item.index];
    if (el) { el.scrollTop = item.top; el.scrollLeft = item.left; }
  });
  if (focusedId) {
    const replacement = card.querySelector(`#${CSS.escape(focusedId)}`);
    if (replacement) {
      replacement.focus({ preventScroll: true });
      if (selection && typeof replacement.setSelectionRange === "function") {
        replacement.setSelectionRange(selection[0], selection[1], selection[2]);
      }
    }
  } else if (focusedAction) {
    const replacement = [...card.querySelectorAll("[data-tiktok-action]")].find(el =>
      el.getAttribute("data-tiktok-action") === focusedAction &&
      focusedActionAttributes.every(([name, value]) => el.getAttribute(name) === value));
    if (replacement) replacement.focus({ preventScroll: true });
  }
}

function flowoffloadApplicationMarkup(selected, raw) {
  const facts = flowoffloadFacts(raw);
  const reported = facts.mode || "unknown";
  const flowtable = facts.flowtable || "unknown";
  const actual = facts.actual || "unknown";
  const owner = facts.owner || "none";
  const selectedLabel = flowoffloadModeLabel(selected);
  const warnings = [];
  let kind = "good";
  let badge = "Не подтверждено";
  let copy;

  if (reported !== "unknown" && reported !== selected) {
    kind = "warn";
    badge = "Проверьте применение";
    warnings.push(`Выбрано «${selectedLabel}», но текущая конфигурация сообщает «${flowoffloadModeLabel(reported)}».`);
  }

  if (selected === "none") {
    if (flowtable === "absent" && actual !== "software" && actual !== "hardware") {
      badge = "Отключено";
      copy = "Правила ускорения отсутствуют.";
    } else if (flowtable === "unknown") {
      kind = "warn";
      badge = "Не проверено";
      copy = "Состояние правил ускорения не проверено.";
    } else {
      kind = "warn";
      badge = "Проверьте применение";
      copy = "Обнаружены правила или активное ускорение.";
    }
  } else if (flowtable === "absent") {
    kind = "warn";
    badge = "Проверьте применение";
    copy = "Правила ускорения отсутствуют.";
  } else if (actual === "software" || actual === "hardware") {
    if (actual !== selected) {
      kind = "warn";
      badge = "Проверьте применение";
      copy = `Фактически наблюдается «${flowoffloadModeLabel(actual)}».`;
    } else {
      badge = "Работа подтверждена";
      copy = "Подтверждено runtime-наблюдением.";
    }
  } else {
    kind = "warn";
    badge = "Не подтверждено";
    copy = "Фактическая работа не подтверждена.";
  }

  if (owner !== "none" && owner !== "unknown") {
    kind = "warn";
    warnings.push(`Обнаружен конфликт владельцев: ${flowoffloadFactLabel("owner", owner)}.`);
  }

  return `<div class="flow-application" data-kind="${kind}">
    <div class="flow-application-main">
      <div class="flow-application-title">${escapeHtml(selectedLabel)}</div>
      <div class="flow-application-copy">${escapeHtml(copy)}</div>
    </div>
    <span class="flow-application-badge">${escapeHtml(badge)}</span>
  </div>
  ${warnings.map(w => `<div class="flow-warning" role="note">${escapeHtml(w)}</div>`).join("")}
  ${flowoffloadTechnicalMarkup(facts)}`;
}

function flowoffloadSync(s, select, state, error, preserveControls = false) {
  const mode = s && s.toggles && s.toggles.flowoffload;
  if (!select || !state || !mode) return;
  if (!preserveControls || (document.activeElement !== select && select.dataset.dirty !== "1")) {
    select.value = mode;
    select.dataset.saved = mode;
  }
  const signature = JSON.stringify([mode, s.toggles.flowoffload_status || null]);
  if (state.dataset.stateSignature !== signature) {
    state.innerHTML = flowoffloadApplicationMarkup(mode, s.toggles.flowoffload_status);
    state.dataset.stateSignature = signature;
  }
  if (error) { error.hidden = true; error.textContent = ""; }
}

function flowoffloadReload(select, state, error) {
  apiGet("/status").then(s => flowoffloadSync(s, select, state, error)).catch(() => {
    if (state) state.textContent = "Не удалось проверить фактическое состояние FLOWOFFLOAD.";
  });
}

function flowBenchmarkValue(value, suffix = "") {
  if (value === null || value === undefined || !Number.isFinite(Number(value))) return "—";
  return `${Number(value).toLocaleString("ru-RU", { maximumFractionDigits: 1 })}${suffix}`;
}

function flowBenchmarkResultMarkup(result) {
  if (!result || !result.modes) return "";
  const providerLabel = result.provider === "yandex-internetometer" ? "Яндекс Интернетометр"
    : result.provider === "cloudflare" ? "Cloudflare (резервная диагностика)" : "не определён";
  const labels = { none: "Без ускорения", software: "Программное", hardware: "Аппаратное" };
  const metrics = [
    ["download_mbps", "↓ Mbps", " Mbps"], ["upload_mbps", "↑ Mbps", " Mbps"],
    ["cpu_avg", "CPU avg", "%"], ["cpu_peak", "CPU peak", "%"],
    ["idle_ms", "Ping idle", " ms"], ["download_loaded_ms", "Ping ↓", " ms"],
    ["upload_loaded_ms", "Ping ↑", " ms"], ["jitter_ms", "Jitter", " ms"],
    ["loss_pct", "Потери HTTP", "%"], ["duration_s", "Время", " с"],
  ];
  const rows = ["none", "software", "hardware"].map(mode => {
    const row = result.modes[mode] || {};
    if (mode === "hardware" && row.available === false) {
      return `<tr><th scope="row">${labels[mode]}</th><td colspan="${metrics.length}">Не поддерживается или не применилось</td></tr>`;
    }
    return `<tr><th scope="row">${labels[mode]}</th>${metrics.map(([key, , suffix]) => `<td>${flowBenchmarkValue(row[key], suffix)}</td>`).join("")}</tr>`;
  }).join("");
  const recommendation = typeof result.recommendation === "string" ? result.recommendation : result.recommendation?.mode;
  const recommendationReason = result.recommendation && typeof result.recommendation === "object" ? result.recommendation.reason : "";
  const noRecommendationReason = result.validity?.unstable
    ? "Серия нестабильна; вывод делать нельзя."
    : result.validity?.complete === false
      ? "Серия неполная; вывод делать нельзя."
      : "Разница между режимами меньше порога шума; рекомендация не требуется.";
  const recommended = recommendation ? `<div class="flow-benchmark-recommendation"><strong>Рекомендуется: ${escapeHtml(labels[recommendation] || recommendation)}</strong><span>${escapeHtml(recommendationReason || "Основано на медианах; hardware учитывается только при наблюдаемом аппаратном offload.")}</span></div>` :
    `<div class="flow-benchmark-recommendation is-muted">${escapeHtml(noRecommendationReason)}</div>`;
  const warning = result.validity?.warnings?.length ? `<p class="flow-benchmark-note">${escapeHtml(result.validity.warnings.join("; "))}</p>` : "";
  const delta = value => {
    if (value === null || value === undefined || !Number.isFinite(Number(value))) return "—";
    const n = Number(value);
    return Math.abs(n) < 5 ? "≈0%" : `${n > 0 ? "+" : "−"}${Math.abs(n)}%`;
  };
  const comparisons = result.comparisons || {};
  const comparisonMarkup = result.validity?.complete === true && result.validity?.unstable !== true && result.validity?.accepted === true ? [
    ["Программное против отключённого", comparisons.software_vs_none],
    ["Аппаратное против программного", comparisons.hardware_vs_software],
  ].filter(([, values]) => values).map(([title, values]) => `<div class="flow-benchmark-comparison"><strong>${title}</strong><span>↓ ${delta(values.download_pct)} · ↑ ${delta(values.upload_pct)} · CPU ${delta(values.cpu_pct)}</span></div>`).join("") : "";
  const diagnostics = ["none", "software", "hardware"].map(mode => {
    const modeResult = result.modes[mode] || {};
    const runs = modeResult.runs || [];
    const series = (key, suffix) => runs.map(run => flowBenchmarkValue(run[key], suffix)).join(" / ") || "нет прогонов";
    const range = modeResult.run_range_pct || {};
    const values = [
      `↓ ${series("download_mbps", " Mbps")}`,
      `↑ ${series("upload_mbps", " Mbps")}`,
      `Ping ↓ ${series("download_loaded_ms", " ms")}`,
      `Ping ↑ ${series("upload_loaded_ms", " ms")}`,
      `Размах: ↓ ${flowBenchmarkValue(range.download, "%")} · ↑ ${flowBenchmarkValue(range.upload, "%")}`,
    ].join(" · ");
    const observed = result.modes[mode]?.offload_observed === true ? "наблюдался" : "не привязан к замеру";
    return `<div class="flow-fact"><span class="flow-fact-label">${labels[mode]}</span><span class="flow-fact-value">${escapeHtml(values)} · offload ${observed}</span></div>`;
  }).join("");
  const system = result.system || {};
  const systemLabels = { router_model: "Модель роутера", openwrt_version: "OpenWrt", z2kow_version: "z2kOW", wan_interface: "WAN интерфейс" };
  const systemMarkup = Object.entries(systemLabels).map(([key, label]) => `<div class="flow-fact"><span class="flow-fact-label">${label}</span><span class="flow-fact-value">${escapeHtml(system[key] || "Не определено")}</span></div>`).join("");
  const conflictLabels = { sqm: "SQM", pbr: "PBR", warp: "WARP" };
  const conflictMarkup = Object.entries(result.conflicts || {}).map(([key, value]) => `<div class="flow-fact"><span class="flow-fact-label">${escapeHtml(conflictLabels[key] || key)}</span><span class="flow-fact-value">${escapeHtml(value)}</span></div>`).join("");
  const message = result.message ? `<p class="flow-benchmark-note">${escapeHtml(result.message)}</p>` : "";
  const timestamp = result.timestamp ? `<p class="flow-benchmark-note">Серия: ${escapeHtml(result.timestamp)}</p>` : "";
  return `${recommended}${comparisonMarkup ? `<div class="flow-benchmark-comparisons">${comparisonMarkup}</div>` : ""}${warning}<div class="flow-benchmark-table-wrap"><table class="flow-benchmark-table"><thead><tr><th>Режим</th>${metrics.map(([, label]) => `<th>${label}</th>`).join("")}</tr></thead><tbody>${rows}</tbody></table></div>
    <details class="flow-technical disclosure"><summary>Подробные прогоны и ограничения</summary><div class="disclosure-body"><div class="flow-technical-body"><div class="flow-facts">${diagnostics}${systemMarkup}${conflictMarkup}</div><p class="flow-benchmark-note">Провайдер: ${escapeHtml(providerLabel)} · CDN: ${escapeHtml(result.server || "не определён")}</p>${message}${timestamp}<p class="flow-benchmark-note">Все измерительные запросы запускает браузер LAN-клиента через роутер. Conntrack-маркеры общие для роутера и не доказывают offload именно тестового браузерного потока. Без точной корреляции hardware не подтверждается и не рекомендуется. Результат зависит от выбранного CDN, маршрута и провайдера; потери считаются по HTTP-пробам.</p></div></div></details>`;
}

async function flowBenchmarkMeasure(status) {
  const provider = status.provider || "yandex-internetometer";
  const yandex = provider === "yandex-internetometer" ? status.probe_config : null;
  const requestId = () => `${Date.now()}-${Math.random().toString(16).slice(2)}`;
  const withRequestId = raw => {
    const url = new URL(raw);
    url.searchParams.set("rid", requestId());
    return url.href;
  };
  const validateYandexConfig = config => {
    const hostPattern = /^([a-z0-9](?:[a-z0-9-]*[a-z0-9])?\.)+cdn\.yandex\.net$/i;
    if (!config || config.provider !== "yandex-internetometer" || typeof config.mid !== "string" ||
        !/^[A-Za-z0-9_-]{16,128}$/.test(config.mid) || typeof config.server !== "string" || !hostPattern.test(config.server)) {
      throw new Error("не получена проверенная probe-конфигурация Яндекс Интернетометра");
    }
    const endpoint = (raw, type) => {
      let url;
      try { url = new URL(raw); } catch (_) { throw new Error(`некорректный Yandex ${type} endpoint`); }
      if (url.protocol !== "https:" || url.hostname !== config.server || url.port || url.username || url.password || url.hash || url.searchParams.get("mid") !== config.mid) {
        throw new Error(`Yandex ${type} endpoint не совпадает с проверенным CDN`);
      }
      if (type === "latency" && !/^\/[A-Za-z0-9_-]+\/ping$/.test(url.pathname)) throw new Error("некорректный Yandex latency endpoint");
      if (type === "download" && (!/^\/[A-Za-z0-9_-]+\/probes\/50mb$/.test(url.pathname) || !/^\d+$/.test(url.searchParams.get("lid") || ""))) throw new Error("некорректный Yandex download endpoint");
      if (type === "upload" && (!/^\/[A-Za-z0-9_-]+\/upload$/.test(url.pathname) || !/^\d+$/.test(url.searchParams.get("size") || ""))) throw new Error("некорректный Yandex upload endpoint");
      return url.href;
    };
    return {
      server: config.server,
      latency: endpoint(config.latency_url, "latency"),
      download: endpoint(config.download_url, "download"),
      upload: endpoint(config.upload_url, "upload"),
    };
  };
  const yandexConfig = yandex ? validateYandexConfig(yandex) : null;
  if (provider === "yandex-internetometer" && !yandexConfig) throw new Error("не найдена probe-конфигурация Яндекс Интернетометра");
  if (provider !== "yandex-internetometer" && provider !== "cloudflare") throw new Error("неподдерживаемый benchmark provider");
  const cloudflare = "https://speed.cloudflare.com";
  const median = values => {
    const sorted = values.filter(Number.isFinite).sort((a, b) => a - b);
    if (!sorted.length) return null;
    const mid = Math.floor(sorted.length / 2);
    return sorted.length % 2 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2;
  };
  const drain = async response => {
    if (!response.ok || !response.body) throw new Error(`HTTP ${response.status || "error"}`);
    const reader = response.body.getReader();
    let bytes = 0;
    for (;;) {
      const part = await reader.read();
      if (part.done) break;
      bytes += part.value.byteLength;
    }
    return bytes;
  };
  const probe = async () => {
    const start = performance.now();
    const controller = new AbortController();
    const abortTimer = setTimeout(() => controller.abort(), 5000);
    try {
      const url = yandexConfig ? withRequestId(yandexConfig.latency) : `${cloudflare}/__down?bytes=1&cacheBust=${requestId()}`;
      const response = await fetch(url, { cache: "no-store", mode: "cors", redirect: "error", signal: controller.signal });
      if (!response.ok) throw new Error(`HTTP ${response.status || "error"}`);
      await response.arrayBuffer();
    } finally { clearTimeout(abortTimer); }
    return performance.now() - start;
  };
  const transfer = async direction => {
    const started = performance.now();
    const length = yandexConfig
      ? (direction === "download" ? 50 * 1024 * 1024 : 8 * 1024 * 1024)
      : (direction === "download" ? 16 * 1024 * 1024 : 4 * 1024 * 1024);
    const payload = direction === "upload" ? new Blob([new Uint8Array(length)]) : null;
    const controller = new AbortController();
    const abortTimer = setTimeout(() => controller.abort(), yandexConfig ? 60000 : 15000);
    let bytes = 0;
    try {
      let response;
      if (yandexConfig && direction === "upload") {
        const form = new FormData();
        form.append("data", payload);
        response = await fetch(withRequestId(yandexConfig.upload), { method: "POST", body: form, cache: "no-store", mode: "cors", redirect: "error", signal: controller.signal });
      } else {
        const url = yandexConfig
          ? withRequestId(yandexConfig.download)
          : `${cloudflare}/${direction === "download" ? `__down?bytes=${length}` : "__up?"}${direction === "download" ? "&" : ""}cacheBust=${requestId()}`;
        response = direction === "download"
          ? await fetch(url, { cache: "no-store", mode: "cors", redirect: "error", signal: controller.signal })
          : await fetch(url, { method: "POST", body: payload, cache: "no-store", mode: "cors", redirect: "error", signal: controller.signal });
      }
      if (direction === "download") bytes = await drain(response);
      else { if (!response.ok) throw new Error(`HTTP ${response.status}`); await response.arrayBuffer(); bytes = length; }
      if (yandexConfig && direction === "download" && bytes !== length) throw new Error(`Yandex CDN вернул ${bytes} байт вместо ${length}`);
    } finally { clearTimeout(abortTimer); }
    const seconds = Math.max(0.001, (performance.now() - started) / 1000);
    return { mbps: bytes * 8 / seconds / 1e6, seconds };
  };
  const idle = [], downPings = [], upPings = [];
  let failed = 0, probes = 0;
  const loaded = async direction => {
    const times = [];
    let running = true;
    const probeLoop = (async () => {
      do {
        probes++;
        try { times.push(await probe()); } catch (_) { failed++; }
        if (running) await new Promise(resolve => { setTimeout(resolve, 350); });
      } while (running);
    })();
    const result = await transfer(direction);
    running = false;
    await probeLoop;
    return { ...result, times };
  };
  for (let i = 0; i < 4; i++) {
    probes++;
    try { idle.push(await probe()); } catch (_) { failed++; }
  }
  const down = await loaded("download");
  downPings.push(...down.times);
  const up = await loaded("upload");
  upPings.push(...up.times);
  const allPings = idle.concat(downPings, upPings);
  const mean = allPings.reduce((sum, n) => sum + n, 0) / Math.max(1, allPings.length);
  const jitter = Math.sqrt(allPings.reduce((sum, n) => sum + (n - mean) ** 2, 0) / Math.max(1, allPings.length));
  return {
    session: status.session, token: status.token, nonce: status.nonce,
    download_mbps: down.mbps, upload_mbps: up.mbps, idle_ms: median(idle),
    download_loaded_ms: median(downPings), upload_loaded_ms: median(upPings),
    jitter_ms: jitter, loss_pct: probes ? failed * 100 / probes : null,
    duration_s: down.seconds + up.seconds,
    server: yandexConfig?.server || "speed.cloudflare.com", provider,
  };
}

async function flowBenchmarkRefresh() {
  const card = document.getElementById("flowoffload-benchmark");
  if (!card || card.hidden || flowBenchmarkRuntime.refreshBusy) return;
  flowBenchmarkRuntime.refreshBusy = true;
  const statusNode = card.querySelector("#flowoffload-benchmark-status");
  try {
    const state = await apiGet("/offload/benchmark?view=status");
    if (!card.isConnected) return;
    const active = state.active === true;
    const start = card.querySelector("#flowoffload-benchmark-start");
    const stop = card.querySelector("#flowoffload-benchmark-stop");
    const select = document.getElementById("flowoffload-mode");
    const provider = card.querySelector("#flowoffload-benchmark-provider");
    if (start) start.hidden = active;
    if (stop) stop.hidden = !active;
    if (!active) { if (start) start.disabled = false; if (stop) stop.disabled = false; }
    if (select) select.disabled = active;
    if (provider) provider.disabled = active;
    const result = state.result;
    if (statusNode) {
      const completedLabel = result?.validity?.accepted === true
        ? "Тест завершён; серия стабильна, исходный режим восстановлен."
        : result?.validity?.unstable === true
          ? "Тест завершён, но серия отклонена как нестабильная; вывод делать нельзя."
          : "Тест завершён, но серия неполная; вывод делать нельзя.";
      const labels = { starting: "Подготавливаю тест…", applying: "Переключаю режим…", awaiting_sample: `Тестирую: ${state.mode === "none" ? "без ускорения" : state.mode === "software" ? "software" : "hardware"}, прогон ${state.trial}/${state.total_trials || 5}`, restoring: "Восстанавливаю исходный режим…", completed: completedLabel, failed: "Тест не завершён; смотрите результат и состояние восстановления.", stopped: "Тест остановлен, исходный режим восстановлен." };
      const lastSuccess = !active && state.last_success_timestamp
        ? ` Последняя принятая стабильная серия: ${new Date(state.last_success_timestamp).toLocaleString("ru-RU")}.`
        : "";
      const measurementError = state.status === "stopped" && flowBenchmarkRuntime.lastError ? ` Ошибка измерения: ${flowBenchmarkRuntime.lastError}.` : "";
      const providerLabel = state.provider === "cloudflare" ? "Cloudflare (резервная диагностика)" : "Яндекс Интернетометр";
      statusNode.textContent = `${labels[state.status] || `Интернет-тест: ${providerLabel}`}${measurementError}${lastSuccess}`;
    }
    const resultNode = card.querySelector("#flowoffload-benchmark-result");
    if (resultNode && active) resultNode.hidden = true;
    if (resultNode && result && !active) {
      const signature = JSON.stringify(result);
      if (resultNode.dataset.signature !== signature) {
        resultNode.innerHTML = flowBenchmarkResultMarkup(result);
        resultNode.dataset.signature = signature;
      }
      resultNode.hidden = false;
    }
    const lastSuccessNode = card.querySelector("#flowoffload-benchmark-last-success");
    let lastSuccessContent = card.querySelector("#flowoffload-benchmark-last-success-content");
    const lastSuccessIsCurrent = state.status === "completed" && result?.timestamp === state.last_success_timestamp;
    if (lastSuccessNode) {
      const showLastSuccess = !active && !lastSuccessIsCurrent && Boolean(state.last_success_timestamp);
      lastSuccessNode.hidden = !showLastSuccess;
      if (showLastSuccess && !lastSuccessContent) {
        lastSuccessContent = document.createElement("div");
        lastSuccessContent.id = "flowoffload-benchmark-last-success-content";
        lastSuccessNode.append(lastSuccessContent);
      }
      if (showLastSuccess && lastSuccessContent) {
      if (lastSuccessNode.dataset.timestamp !== state.last_success_timestamp) {
        lastSuccessNode.dataset.timestamp = state.last_success_timestamp;
        lastSuccessContent.textContent = "Загружаю последнюю успешную серию…";
        try {
          const lastSuccess = await apiGet("/offload/benchmark?view=last-success");
          if (!card.isConnected) return;
          if (lastSuccess?.status === "completed") lastSuccessContent.innerHTML = flowBenchmarkResultMarkup(lastSuccess);
          else lastSuccessContent.textContent = "Последняя успешная серия недоступна.";
        } catch (_) {
          lastSuccessNode.dataset.timestamp = "";
          lastSuccessContent.textContent = "Не удалось загрузить последнюю успешную серию.";
        }
      }
      }
    }
    if (active && state.status === "awaiting_sample" && state.nonce && flowBenchmarkRuntime.inFlight !== state.nonce) {
      flowBenchmarkRuntime.inFlight = state.nonce;
      try {
        const sample = await flowBenchmarkMeasure(state);
        await apiPost("/offload/benchmark", { action: "sample", ...sample });
      } catch (error) {
        flowBenchmarkRuntime.lastError = errMsg(error);
        console.error("FLOWOFFLOAD benchmark measurement failed", error);
        if (statusNode) statusNode.textContent = `Ошибка измерения: ${flowBenchmarkRuntime.lastError}. Восстанавливаю режим…`;
        try { await apiPost("/offload/benchmark", { action: "stop" }); } catch (_) {}
        flowBenchmarkRuntime.inFlight = "";
      }
    }
    if (active) flowBenchmarkRuntime.wasActive = true;
    if (!active && start && flowBenchmarkRuntime.wasActive) {
      flowBenchmarkRuntime.wasActive = false;
      const selectNode = document.getElementById("flowoffload-mode");
      const stateView = document.getElementById("flowoffload-status");
      const errorView = document.getElementById("flowoffload-error");
      if (selectNode) selectNode.disabled = false;
      flowoffloadReload(selectNode, stateView, errorView);
    }
  } catch (_) {
    if (statusNode && !statusNode.textContent) statusNode.textContent = "Интернет-тест пока недоступен.";
  } finally {
    flowBenchmarkRuntime.refreshBusy = false;
  }
}

function startFlowBenchmarkPolling() {
  if (flowBenchmarkRuntime.pollTimer) clearInterval(flowBenchmarkRuntime.pollTimer);
  flowBenchmarkRuntime.inFlight = "";
  flowBenchmarkRuntime.wasActive = false;
  void flowBenchmarkRefresh();
  flowBenchmarkRuntime.pollTimer = setInterval(() => {
    if (!document.getElementById("tg-state-badge")) {
      clearInterval(flowBenchmarkRuntime.pollTimer); flowBenchmarkRuntime.pollTimer = 0; return;
    }
    void flowBenchmarkRefresh();
  }, 1200);
}

function wireFlowBenchmark() {
  const card = document.getElementById("flowoffload-benchmark");
  if (!card || card.dataset.wired) return;
  card.dataset.wired = "1";
  const start = card.querySelector("#flowoffload-benchmark-start");
  const stop = card.querySelector("#flowoffload-benchmark-stop");
  const provider = card.querySelector("#flowoffload-benchmark-provider");
  start?.addEventListener("click", async () => {
    if (!window.confirm("Во время теста режим ускорения будет временно переключаться. Активные соединения могут быть перезапущены. После завершения исходная конфигурация будет восстановлена.")) return;
    start.disabled = true;
    try {
      const started = await apiPost("/offload/benchmark", { action: "start", provider: provider?.value || "yandex-internetometer" });
      if (started?.job) {
        flowBenchmarkRuntime.lastError = "";
        openJobModal("Сравнение режимов FLOWOFFLOAD", started.job, {
          onDone: async () => {
            await flowBenchmarkRefresh();
            const select = document.getElementById("flowoffload-mode");
            flowoffloadReload(select, document.getElementById("flowoffload-status"), document.getElementById("flowoffload-error"));
          },
        });
      }
      await flowBenchmarkRefresh();
    } catch (error) {
      start.disabled = false;
      toastErr("Не удалось запустить сравнение: ", error);
    }
  });
  stop?.addEventListener("click", async () => {
    stop.disabled = true;
    try {
      await apiPost("/offload/benchmark", { action: "stop" });
      const statusNode = card.querySelector("#flowoffload-benchmark-status");
      if (statusNode) statusNode.textContent = "Останавливаю и восстанавливаю исходный режим…";
    } catch (error) {
      toastErr("Не удалось остановить benchmark: ", error);
      stop.disabled = false;
    }
  });
}

async function saveFlowoffload(select, state, error) {
  const wanted = select.value;
  const previous = select.dataset.saved || "none";
  if (wanted === previous || wanted === "donttouch") return;
  select.disabled = true;
  if (error) { error.hidden = true; error.textContent = ""; }
  let resp;
  try {
    resp = await apiPost("/offload", { mode: wanted });
  } catch (e) {
    select.value = previous;
    select.disabled = false;
    if (error) { error.hidden = false; error.textContent = "Не удалось применить: " + errMsg(e); }
    toastErr("FLOWOFFLOAD: ", e);
    return;
  }
  openJobModal("Переключение selective FLOWOFFLOAD", resp.job, {
    tolerateOutage: true,
    onDone: (d) => {
      select.disabled = false;
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) {
        if (error) { error.hidden = false; error.textContent = "Режим не применён; проверяю откат по конфигу."; }
        toast("FLOWOFFLOAD не применён — состояние проверяется", "bad");
      } else if (!jobUnresolved(outcome)) {
        toast("FLOWOFFLOAD: " + wanted);
      }
      select.dataset.dirty = "0";
      flowoffloadReload(select, state, error);
    },
  });
}

function dohReasonLabel(reason) {
  const labels = {
    "package-missing": "Пакет https-dns-proxy не установлен.",
    "resolver-config-missing": "Не найдена активная конфигурация DNS-провайдера.",
    "proxy-not-running": "Сервис https-dns-proxy не запущен.",
    "dnsmasq-not-running": "Сервис dnsmasq не запущен.",
    "listener-query-failed": "Локальный DoH listener не ответил. Нажмите «Проверить» для диагностики.",
  };
  return labels[reason] || "Сервис или конфигурация DNS-провайдера недоступны. Нажмите «Проверить» для диагностики.";
}

function renderDohStatus(status, platform, syncControls = false) {
  const card = $app.querySelector("#doh-card");
  if (!card) return;
  card.hidden = platform !== "openwrt";
  if (card.hidden) return;
  const line = card.querySelector("#doh-status");
  const actions = card.querySelector("#doh-actions");
  const providerSelect = card.querySelector("#doh-provider");
  const regionSelect = card.querySelector("#doh-region");
  const regionRow = card.querySelector("#doh-region-row");
  const customFields = card.querySelector("#doh-custom-fields");
  const endpointField = card.querySelector("#doh-endpoint");
  const bootstrapField = card.querySelector("#doh-bootstrap");
  const ownershipWarning = card.querySelector("#doh-ownership-warning");
  let selectedProvider = status && status.provider || "xbox";
  if (selectedProvider === "unknown") selectedProvider = "xbox";
  let geoRegion = "ru";
  if (/^geohide_(ru|eu|us)$/.test(selectedProvider)) {
    geoRegion = selectedProvider.slice("geohide_".length);
    selectedProvider = "geohide";
  }
  if (syncControls) {
    if (providerSelect) providerSelect.value = selectedProvider;
    if (regionSelect) regionSelect.value = geoRegion;
    if (endpointField) endpointField.value = status && status.provider === "custom" ? status.endpoint || "" : "";
    if (bootstrapField) bootstrapField.value = status && status.provider === "custom" ? status.bootstrap || "" : "";
  }
  if (regionRow) regionRow.hidden = !providerSelect || providerSelect.value !== "geohide";
  if (customFields) customFields.hidden = !providerSelect || providerSelect.value !== "custom";
  const state = status && status.state || "error";
  const installed = status && status.installed === "1";
  const reason = dohReasonLabel(status && status.reason);
  if (ownershipWarning) ownershipWarning.hidden = !installed || status.external_config !== "1";
  card.dataset.confirmRemove = installed && (status.confirm_remove === "1" ||
    status.package_owner === "external" || status.external_config === "1") ? "1" : "0";
  if (state === "not-installed" || !installed) {
    line.dataset.state = "not-installed";
    line.textContent = "Статус: Не установлен";
    if (actions.dataset.actionSet !== "install") {
      actions.innerHTML = '<button class="btn btn-primary" data-doh-action="install">Установить</button>';
      actions.dataset.actionSet = "install";
    }
    return;
  }
  const stateLabel = state === "working" || state === "healthy" ? "Работает"
    : state === "disabled" || state === "installed-disabled" ? "Выключен" : "Ошибка";
  line.dataset.state = stateLabel === "Работает" ? "working" : stateLabel === "Ошибка" ? "error" : "disabled";
  line.textContent = `Статус: ${stateLabel}${stateLabel === "Ошибка" ? ` · ${reason}` : ""}`;
  if (actions.dataset.actionSet !== "manage") {
    actions.innerHTML = '<button class="btn btn-primary" data-doh-action="apply">Применить</button><button class="btn btn-secondary" data-doh-action="check">Проверить</button><button class="btn btn-secondary" data-doh-service-toggle hidden></button><button class="btn btn-danger" data-doh-action="uninstall">Удалить</button>';
    actions.dataset.actionSet = "manage";
  }
  const serviceButton = actions.querySelector("[data-doh-service-toggle]");
  if (serviceButton) {
    const shouldStop = status && (status.enabled === "1" || status.running === "1");
    const canStart = Boolean(status && status.endpoint);
    serviceButton.hidden = !shouldStop && !canStart;
    if (serviceButton.hidden) {
      delete serviceButton.dataset.dohAction;
    } else {
      serviceButton.dataset.dohAction = shouldStop ? "disable" : "enable";
      serviceButton.textContent = shouldStop ? "Остановить" : "Запустить";
    }
  }
}

export async function renderToggles() {
  $app.innerHTML = `
    <h1 class="page-title">Режимы</h1>
    <div class="card">
      <div id="toggles-error" hidden></div>
      ${TOGGLE_DEFS.map(t => `
        <div class="toggle-row" data-key="${t.key}">
          <div class="t-text">
            <div class="t-name">${t.name}</div>
            <div class="t-desc">${t.desc}</div>
            ${t.extra || ""}
          </div>
          <label class="switch">
            <input type="checkbox" disabled>
            <span class="slider"></span>
          </label>
        </div>
      `).join("")}
    </div>
    <div class="card" id="tiktok-feed-status-card" hidden></div>
    <div class="card" id="doh-card" hidden>
      <h3>DNS over HTTPS</h3>
      <div class="doh-controls">
        <label class="field" for="doh-provider">
          <span class="field-label">Провайдер</span>
          <select class="t-sub-select" id="doh-provider">
            <option value="xbox">Xbox DNS</option>
            <option value="comss">Comss</option>
            <option value="google">Google</option>
            <option value="quad9">Quad9</option>
            <option value="xyz">XyZ DNS</option>
            <option value="geohide">GeoHide</option>
            <option value="cloudflare">Cloudflare</option>
            <option value="dns_ai">dns.dns-ai.ru</option>
            <option value="malw">dns.malw.link</option>
            <option value="astracat">dns.astracat.ru</option>
            <option value="mafioznik">dns.mafioznik.xyz</option>
            <option value="malw_cloudflare">malw Cloudflare Gateway</option>
            <option value="nullsproxy">dns.nullsproxy.com</option>
            <option value="default">Cloudflare + Google (по умолчанию)</option>
            <option value="custom">Свой endpoint</option>
          </select>
        </label>
        <label class="field" id="doh-region-row" for="doh-region" hidden>
          <span class="field-label">Регион GeoHide</span>
          <select class="t-sub-select" id="doh-region">
            <option value="ru">RU</option>
            <option value="eu">EU</option>
            <option value="us">US</option>
          </select>
        </label>
        <div class="doh-custom-fields" id="doh-custom-fields" hidden>
          <label class="field" for="doh-endpoint">
            <span class="field-label">HTTPS endpoint</span>
            <input id="doh-endpoint" type="url" inputmode="url" autocomplete="url" placeholder="https://dns.example/dns-query" spellcheck="false">
          </label>
          <label class="field" for="doh-bootstrap">
            <span class="field-label">Bootstrap DNS (IPv4/IPv6 через запятую)</span>
            <input id="doh-bootstrap" type="text" inputmode="text" autocomplete="off" placeholder="1.1.1.1,1.0.0.1" spellcheck="false">
          </label>
        </div>
      </div>
      <p class="doh-ownership-warning" id="doh-ownership-warning" hidden>Найдена пользовательская конфигурация https-dns-proxy. При применении она будет сохранена для восстановления после удаления DoH.</p>
      <div class="doh-status" id="doh-status" data-state="unknown" role="status" aria-live="polite">Статус: проверяется…</div>
      <div class="btn-row" id="doh-actions"></div>
    </div>
    <div class="card" id="openwrt-offload-card" hidden>
      <h3>Ускорение трафика</h3>
      <p class="desc">Управление ускорением соединений через zapret2</p>
      <label class="field flow-mode-field">
        <span class="field-label">Режим</span>
        <select class="t-sub-select" id="flowoffload-mode"></select>
      </label>
      <div id="flowoffload-status" role="status" aria-live="polite"></div>
      <div class="t-desc" id="flowoffload-error" role="alert" hidden></div>
      <section class="flow-benchmark" id="flowoffload-benchmark" data-lock-group="offload-benchmark" aria-labelledby="flowoffload-benchmark-title">
        <div class="flow-benchmark-heading">
          <div><h4 id="flowoffload-benchmark-title">Сравнение режимов</h4><p class="desc">Интернет-тест запускается браузером LAN-клиента и проходит через роутер. Основной источник: Яндекс Интернетометр.</p></div>
          <label class="field flow-benchmark-provider"><span class="field-label">Провайдер</span><select id="flowoffload-benchmark-provider" class="t-sub-select"><option value="yandex-internetometer">Яндекс Интернетометр</option><option value="cloudflare">Cloudflare — резервная диагностика</option></select></label>
        </div>
        <div class="btn-row flow-benchmark-actions">
          <button class="btn btn-primary" id="flowoffload-benchmark-start" type="button">Сравнить режимы</button>
          <button class="btn btn-danger" id="flowoffload-benchmark-stop" type="button" hidden>Остановить тест</button>
        </div>
        <div class="flow-benchmark-status" id="flowoffload-benchmark-status" role="status" aria-live="polite">Загружаю состояние benchmark…</div>
        <div class="flow-benchmark-result" id="flowoffload-benchmark-result" hidden></div>
        <details class="flow-technical disclosure" id="flowoffload-benchmark-last-success" hidden><summary>Последний успешный результат</summary><div class="disclosure-body"><div id="flowoffload-benchmark-last-success-content"></div></div></details>
        <details class="flow-technical disclosure flow-benchmark-method">
          <summary>Методика и ограничения</summary>
          <div class="disclosure-body"><div class="flow-technical-body">
            <p class="flow-benchmark-note">Проводятся пять сбалансированно чередуемых раундов с одинаковыми параметрами: каждый раунд загружает файл Яндекса 50 MiB, отправляет 8 MiB и собирает latency probes. Показаны сырые результаты и полный размах. Серия отклоняется при двух и более прогонах, которые отклоняются от медианы загрузки или отдачи более чем на 10%. Конфигурация временно переключается и восстанавливается после завершения, ошибки или остановки. Hardware пропускается, если flowtable не применился.</p>
            <p class="flow-benchmark-note">Из-за CORS списка probes <code>/internet/api/v0/get-probes</code> его получает роутер для браузера; сами latency/download/upload запросы выполняет LAN-браузер напрямую к выбранному CDN через роутер. Cloudflare доступен только как явный резервный диагностический провайдер и не нужен для запуска теста Яндекса. Результат зависит от CDN, провайдера и маршрута. Потери отражают неуспешные HTTP-пробы; исходящие запросы с самого роутера не измеряют forwarding FLOWOFFLOAD.</p>
          </div></div>
        </details>
      </section>
    </div>
    <div class="card" id="panel-session-ttl-card">
      <h3>Срок входа в веб-панель</h3>
      <label class="field" for="panel-session-ttl">
        <span class="field-label">Запрашивать пароль снова через</span>
        <select class="t-sub-select" id="panel-session-ttl" disabled>
          <option value="7200">2 часа</option>
          <option value="43200">12 часов</option>
          <option value="86400">24 часа</option>
          <option value="604800">7 дней</option>
        </select>
      </label>
      <p class="desc" id="panel-session-ttl-note" role="status" aria-live="polite">Загружаю настройку…</p>
    </div>
    <div class="card">
      <h3>Telegram туннель <span class="tg-state-badge" id="tg-state-badge" hidden></span></h3>
      <p class="desc">Прозрачный mux-прокси к Telegram DC через выделенный VPS-relay.</p>
      <div class="btn-row">
        <button class="btn btn-primary" id="tg-enable">Включить</button>
        <button class="btn btn-danger" id="tg-disable">Отключить</button>
      </div>
    </div>
    <div class="card" id="policy-card">
      <h3>Политика доступа Keenetic</h3>
      <label class="field">
        <span class="field-label">Имя политики</span>
        <input id="policy-name" type="text" placeholder="nfqws"
               inputmode="text" autocomplete="off" autocapitalize="off"
               spellcheck="false" autocorrect="off" maxlength="32">
      </label>
      <div class="policy-status" id="policy-status">
        <span class="policy-status-dot"></span>
        <span class="policy-status-text">Проверка…</span>
      </div>
      <div class="field-label" style="margin-top:14px">Применяется к устройствам</div>
      <div class="segmented" id="policy-mode" role="radiogroup" aria-label="Применяется к устройствам">
        <button type="button" class="seg-btn" data-exclude="0" role="radio" aria-checked="true">Только в политике</button>
        <button type="button" class="seg-btn" data-exclude="1" role="radio" aria-checked="false">Все, кроме политики</button>
      </div>
      <div class="btn-row" style="margin-top:14px;justify-content:space-between;align-items:center">
        <details class="policy-help disclosure">
          <summary>Как создать политику</summary>
          <div class="disclosure-body">
            <div class="how-to">
              <ol class="steps">
                <li>
                  <span class="step-num">1</span>
                  <div class="step-body">
                    <div class="step-title">Откройте раздел приоритетов</div>
                    <div class="step-desc">В админке Keenetic: <b>Интернет → Приоритеты подключений</b>.</div>
                  </div>
                </li>
                <li>
                  <span class="step-num">2</span>
                  <div class="step-body">
                    <div class="step-title">Создайте политику</div>
                    <div class="step-desc">Вкладка <b>«Конфигурация политик»</b> → кнопка <b>«+ Добавить политику»</b>.</div>
                  </div>
                </li>
                <li>
                  <span class="step-num">3</span>
                  <div class="step-body">
                    <div class="step-title">Задайте имя</div>
                    <div class="step-desc">Имя должно <b>точно совпадать</b> с тем, что введено выше — по умолчанию <code>nfqws</code>. Регистр учитывается.</div>
                  </div>
                </li>
                <li>
                  <span class="step-num">4</span>
                  <div class="step-body">
                    <div class="step-title">Выберите подключение</div>
                    <div class="step-desc">В колонке «Подключение» оставьте галки на тех интерфейсах, которыми пользуются эти устройства (обычно ваше текущее подключение к интернету).</div>
                  </div>
                </li>
                <li>
                  <span class="step-num">5</span>
                  <div class="step-body">
                    <div class="step-title">Привяжите устройства</div>
                    <div class="step-desc">Вкладка <b>«Привязка устройств к профилям»</b> → включите <b>«Показать все объекты»</b> → перетащите нужные устройства на созданную политику.</div>
                  </div>
                </li>
                <li>
                  <span class="step-num">6</span>
                  <div class="step-body">
                    <div class="step-title">Примените у нас</div>
                    <div class="step-desc">Вернитесь сюда и нажмите <b>«Сохранить и применить»</b>. Статус выше должен загореться зелёным.</div>
                  </div>
                </li>
              </ol>
              <div class="how-to-note">
                <b>Нет раздела «Приоритеты подключений»?</b><br>
                Установите компонент: <b>Управление → Общие настройки → Изменить набор компонентов</b>, найдите «Приоритеты подключений (PBR)» и установите. После перезагрузки роутера раздел появится в меню «Интернет».
              </div>
            </div>
          </div>
        </details>
        <button class="btn btn-primary" id="policy-save-btn">Сохранить и применить</button>
      </div>
    </div>
  `;

  // Load current state and wire up switches. Шаблон рендерит все свитчи
  // disabled, включаются они только здесь — поэтому упавший /status обязан
  // сказать об этом и дать повтор: иначе страница выглядит нормальной, но
  // не кликается ни один тумблер, и понять это можно только методом тыка.
  const errBox = $app.querySelector("#toggles-error");
  // Джоб завершается через 10-20 секунд, юзер за это время успевает уйти на
  // другую страницу. renderToggles() без проверки молча подменял бы $app
  // содержимым «Режимов», оставив адрес и подсветку меню от чужой страницы.
  // Она же отвечает на вопрос «мы ещё здесь?» для ответов, пришедших после
  // ухода: _stale ловит только более свежую загрузку, но не смену маршрута.
  const onTogglesPage = () => !!document.getElementById("tg-state-badge");

  function runDohAction(action, value = null) {
    const card = $app.querySelector("#doh-card");
    if (!card || card.hidden) return;
    const actions = {
      install: ["/doh/install", "Установка DoH"],
      uninstall: ["/doh/uninstall", "Удаление DoH"],
      check: ["/doh/check", "Проверка DoH"],
      apply: ["/doh/provider", "Применение DoH"],
      enable: ["/doh/enable", "Запуск DoH"],
      disable: ["/doh/disable", "Остановка DoH"],
    };
    const spec = actions[action];
    if (!spec) return;
    const providerSelect = card.querySelector("#doh-provider");
    const regionSelect = card.querySelector("#doh-region");
    const endpointField = card.querySelector("#doh-endpoint");
    const bootstrapField = card.querySelector("#doh-bootstrap");
    if (action === "apply" && card.querySelector("#doh-ownership-warning")?.hidden === false &&
        !window.confirm("Обнаружена пользовательская конфигурация https-dns-proxy. Она будет сохранена и заменена выбранным провайдером. При удалении DoH исходная конфигурация восстановится. Продолжить?")) return;
    if (action === "uninstall" && card.dataset.confirmRemove === "1" && !window.confirm(
      "https-dns-proxy или его конфигурация были установлены до управления z2kOW. " +
      "Конфигурация будет сохранена для последующего восстановления, но пакет и работающий DoH будут удалены. Продолжить?")) return;
    const buttons = [...card.querySelectorAll("[data-doh-action]")];
    buttons.forEach(button => { button.disabled = true; });
    let body;
    if (action === "apply") {
      const provider = providerSelect && providerSelect.value || "xbox";
      body = { provider: provider === "geohide" ? `geohide_${regionSelect.value}` : provider };
      if (provider === "custom") {
        body.endpoint = endpointField.value.trim();
        body.bootstrap = bootstrapField.value.trim();
      }
      if (card.querySelector("#doh-ownership-warning")?.hidden === false) body.replace = "1";
    } else if (action === "uninstall") {
      body = { confirm: card.dataset.confirmRemove === "1" ? "1" : "0" };
    }
    apiPost(spec[0], body).then(response => {
      if (response && response.job) {
        openJobModal(spec[1], response.job, {
          onDone: async () => {
            buttons.forEach(button => { if (button.isConnected) button.disabled = false; });
            if (onTogglesPage()) await refreshTogglesState();
          },
        });
      } else {
        toast(spec[1] + " — готово");
        buttons.forEach(button => { if (button.isConnected) button.disabled = false; });
        if (onTogglesPage()) refreshTogglesState();
      }
    }).catch(error => {
      buttons.forEach(button => { if (button.isConnected) button.disabled = false; });
      toastErr("Ошибка: ", error);
    });
  }

  function wireDohCard() {
    const card = $app.querySelector("#doh-card");
    if (!card || card.dataset.wired) return;
    card.dataset.wired = "1";
    card.addEventListener("click", event => {
      const button = event.target.closest && event.target.closest("[data-doh-action]");
      if (button) runDohAction(button.dataset.dohAction);
    });
    const providerSelect = card.querySelector("#doh-provider");
    const regionRow = card.querySelector("#doh-region-row");
    const customFields = card.querySelector("#doh-custom-fields");
    providerSelect.addEventListener("change", () => {
      if (regionRow) regionRow.hidden = providerSelect.value !== "geohide";
      if (customFields) customFields.hidden = providerSelect.value !== "custom";
    });
  }

  async function loadTogglesState() {
    const seq = _newLoad("toggles");
    let s;
    try {
      s = await apiGet("/status");
    } catch (e) {
      if (_stale("toggles", seq) || !onTogglesPage()) return;
      if (!errBox) return;
      // Сообщение обещает, что переключатели заблокированы — значит и кнопки
      // туннеля тоже: под ними реальные запуск и останов, а панель сейчас не
      // знает даже, что включено. Свитчи глушим тем же проходом — после
      // удачной загрузки они уже разлочены, и повторный провал оставил бы их
      // живыми под текстом «заблокированы».
      TOGGLE_DEFS.forEach(t => {
        const row = $app.querySelector(`[data-key="${t.key}"]`);
        if (row) setLockAware(row.querySelector("input"), true);
      });
      setLockAware($app.querySelector("#tg-enable"), true);
      setLockAware($app.querySelector("#tg-disable"), true);
      // Селектор времени — тот же класс: не зная состояния, панель не знает
      // и текущего часа, а запись вслепую затёрла бы выбранный.
      setLockAware($app.querySelector("#au-hour"), true);
      setLockAware($app.querySelector("#flowoffload-mode"), true);
      errBox.hidden = false;
      errBox.innerHTML = `
        <p class="desc" style="color:var(--bad)">Не удалось прочитать состояние: ${errHtml(e)}.
           Переключатели заблокированы — панель не знает, что сейчас включено.</p>
        <div class="btn-row" style="margin-bottom:10px">
          <button class="btn btn-primary" id="toggles-retry">Повторить</button>
        </div>`;
      const retry = $app.querySelector("#toggles-retry");
      if (retry) retry.addEventListener("click", () => {
        retry.disabled = true;
        retry.textContent = "Читаю…";
        loadTogglesState();
      });
      return;
    }
    if (_stale("toggles", seq)) return;
    syncTogglesState(s, true);
  }

  async function refreshTogglesState() {
    const seq = _newLoad("toggles");
    let s;
    try {
      s = await apiGet("/status");
    } catch (e) {
      if (!_stale("toggles", seq) && onTogglesPage()) toastErr("Не удалось обновить состояние режимов: ", e);
      return null;
    }
    if (_stale("toggles", seq) || !onTogglesPage()) return null;
    syncTogglesState(s, false);
    void flowBenchmarkRefresh();
    return s;
  }

  function syncTogglesState(s, initial) {
    const toggleDefs = s.platform === "openwrt" ? TOGGLE_DEFS : TOGGLE_DEFS.filter(t => !t.openwrtOnly);
    const tiktokRow = $app.querySelector('[data-key="tiktok_feed"]');
    if (tiktokRow) tiktokRow.hidden = s.platform !== "openwrt";
    applyCapabilities(s);
    // Платформенно-зависимый текст — ПОСЛЕ applyCapabilities, когда platform
    // известна. Строка политики и PPE-ряд на OpenWrt спрятаны целиком, а ряд
    // dynamic_ttl виден — ему и правим описание (см. DYNAMIC_TTL_DESC_OPENWRT).
    if (s && s.platform === "openwrt") {
      const ttlDesc = $app.querySelector('[data-key="dynamic_ttl"] .t-desc');
      if (ttlDesc) ttlDesc.textContent = DYNAMIC_TTL_DESC_OPENWRT;
    }
    // /status мог вернуться уже после ухода со страницы: $app очищен, ни
    // одного из этих элементов больше нет, и обращение к badge.hidden роняло
    // весь остаток renderToggles — вместе с привязкой кнопок туннеля,
    // секцией политики и глобальным локом.
    const badge = $app.querySelector("#tg-state-badge");
    if (!badge) return;
    if (errBox) { errBox.hidden = true; errBox.innerHTML = ""; }
    renderTikTokStatus(s.tiktok_feed_status, s.toggles, s.platform, s.server_now_epoch);
    renderDohStatus(s.doh, s.platform, initial);
    wireDohCard();
    const flowCard = $app.querySelector("#openwrt-offload-card");
    const flowSelect = $app.querySelector("#flowoffload-mode");
    const flowState = $app.querySelector("#flowoffload-status");
    const flowError = $app.querySelector("#flowoffload-error");
    if (flowSelect && !flowSelect.children.length) {
      FLOWOFFLOAD_OPTIONS.forEach(([value, label]) => {
        const option = document.createElement("option");
        option.value = value;
        option.textContent = label;
        if (value === "donttouch") option.disabled = true;
        flowSelect.appendChild(option);
      });
    }
    const flowVisible = s.platform === "openwrt" && s.capabilities &&
      s.capabilities.offload === true && !!s.toggles.flowoffload;
    if (flowCard) flowCard.hidden = !flowVisible;
    if (flowVisible && flowSelect) {
      flowoffloadSync(s, flowSelect, flowState, flowError, !initial);
      wireFlowBenchmark();
      setLockAware(flowSelect, false);
      if (!flowSelect.dataset.wired) {
        flowSelect.dataset.wired = "1";
        flowSelect.addEventListener("change", () => saveFlowoffload(flowSelect, flowState, flowError));
      }
    }
    // Чекбокс автообновления ловим здесь же: строка с временем ходит за ним,
    // и искать его вторым, другим селектором — способ однажды поехать врозь.
    let auBox = null;
    toggleDefs.forEach(t => {
      const row = $app.querySelector(`[data-key="${t.key}"]`);
      if (!row) return;
      const box = row.querySelector("input");
      if (t.key === "auto_update") auBox = box;
      const checked = s.toggles[t.key] === "1";
      if (initial || box !== document.activeElement) box.checked = checked;
      if (t.key === "fastroute") {
        const state = row.querySelector("#fastroute-status");
        if (state) state.textContent = s.toggles.fastroute_status || "Состояние маршрутного кэша недоступно.";
      }
      setLockAware(box, false);
      // Повторная загрузка не должна вешать второй обработчик: два POST'а
      // на один клик — два конкурентных рестарта сервиса.
      if (!box.dataset.wired) {
        box.dataset.wired = "1";
        box.addEventListener("change", () => {
          // Строку времени показываем сразу по клику, не дожидаясь конца
          // джоба: ответ придёт через десяток секунд, а тумблер уже стоит
          // в новом положении — расхождение выглядело бы как залипание.
          if (t.key === "auto_update") auHourSync(box);
          toggleClick(t.key, box);
        });
      }
    });
    if (initial) wireAuHour(s.toggles && s.toggles.au_hour, auBox);
    else auHourSync(auBox);
    // TG-tunnel state pill + button enable/disable matching reality.
    const tgRunning = s.tunnel && s.tunnel.running === true;
    badge.hidden = false;
    badge.textContent = tgRunning ? "Включён" : "Остановлен";
    badge.className = "tg-state-badge " + (tgRunning ? "tg-state-on" : "tg-state-off");
    const enableBtn = $app.querySelector("#tg-enable");
    const disableBtn = $app.querySelector("#tg-disable");
    setLockAware(enableBtn, tgRunning);
    setLockAware(disableBtn, !tgRunning);
    if (enableBtn) enableBtn.title = tgRunning ? "Туннель уже запущен" : "";
    if (disableBtn) disableBtn.title = tgRunning ? "" : "Туннель уже остановлен";
  }
  await loadTogglesState();
  // Пока читался /status, юзер мог уйти — вешать обработчики уже некуда, а
  // querySelector вернёт null и уронит остаток функции.
  if (!onTogglesPage()) return;
  startFlowBenchmarkPolling();
  loadPanelSessionTtl();

  async function tgAction(action, title) {
    const btns = [$app.querySelector("#tg-enable"), $app.querySelector("#tg-disable")];
    const wasDisabled = btns.map(b => b && b.disabled);
    const restoreBtns = () => btns.forEach((b, i) => { if (b) b.disabled = wasDisabled[i]; });
    // Глобальный лок включится только с приходом id задачи; до тех пор обе
    // кнопки кликабельны, и второй клик поднимал второй tunnel_enable.
    btns.forEach(b => { if (b) b.disabled = true; });
    let resp;
    try {
      resp = await apiPost("/tunnel/" + action);
    } catch (e) {
      restoreBtns();
      toastErr("Ошибка: ", e);
      return;
    }
    const expectRunning = (action === "enable");
    // Wait until tunnel state actually matches what we asked for — init
    // script может тратить 1-2 сек на cleanup iptables / conntrack
    // после stop, и /status в это время ещё видит daemon alive. Без
    // in-place refresh после завершения job подхватит итоговое состояние,
    // и badge показывает «ВКЛЮЧЁН» через секунду после клика
    // «Отключить» — юзер думает что не сработало.
    async function pollTgState() {
      const deadline = Date.now() + 10000;
      while (Date.now() < deadline) {
        try {
          const s = await apiGet("/status");
          if (s.tunnel && s.tunnel.running === expectRunning) return true;
        } catch (e) {
          // network blip — продолжим
        }
        await new Promise(r => { setTimeout(r, 500); });
      }
      return false;
    }

    // Backend returns either {ok:true,job:<id>} (async, new) or
    // {ok:true} (sync, old). Если есть job — открываем модалку с
    // live-логом; иначе toast + обновление runtime state на месте.
    if (resp && resp.job) {
      // Исходное состояние возвращаем ДО openJobModal: лок запоминает
      // текущее disabled как «правильное» и вернул бы кнопку выключенной.
      restoreBtns();
      openJobModal(title, resp.job, {
        onDone: async () => {
          await pollTgState();
          if (onTogglesPage()) await refreshTogglesState();
        },
      });
    } else {
      toast(title + " — готово");
      await pollTgState();
      if (onTogglesPage()) await refreshTogglesState();
      else restoreBtns();
    }
  }
  $app.querySelector("#tg-enable").addEventListener("click", () => tgAction("enable", "Запуск Telegram туннеля"));
  $app.querySelector("#tg-disable").addEventListener("click", () => tgAction("disable", "Остановка Telegram туннеля"));

  // ----- Policy access section -----
  const nameInput = $app.querySelector("#policy-name");
  const statusEl  = $app.querySelector("#policy-status");
  const segGroup  = $app.querySelector("#policy-mode");
  const saveBtn   = $app.querySelector("#policy-save-btn");
  // ПРАВИЛО ЗДЕСЬ ОБЯЗАНО СОВПАДАТЬ С СЕРВЕРНЫМ, И РАНЬШЕ НЕ СОВПАДАЛО.
  //
  // Стояло /^[A-Za-z0-9_-]{0,32}$/ — то есть латиница и всё. На сервере это
  // давно исправлено: политики Keenetic люди называют по-русски и с пробелами
  // («Незарегистрированные клиенты», «Через ВПН»), и обработчик их принимает.
  // А форма отбивала такое имя ДО отправки, поэтому серверная правка выглядела
  // сделанной, но пользователю по-прежнему было нельзя.
  //
  // Запрещаем ровно то же, что и сервер, и ровно по тем же причинам:
  //   " $ ` \ ;  — ломают `. config`, куда имя попадает через set_flag;
  //   '            — set_flag экранирует апостроф как '\'', а обратно это не
  //                  разворачивается: имя портится навсегда при первой же
  //                  перегенерации конфига;
  //   |            — policy_status отдаёт «name=%s|exclude=%s», и на чтении
  //                  назад имя срезалось бы по разделителю;
  //   перевод строки — по той же причине, что и всё выше.
  const NAME_BAD_RE = /["$`\\;'|\n\r]/;
  // Длина в СИМВОЛАХ, а не в кодовых единицах: '…'.length считает UTF-16, и
  // на суррогатных парах цифра разошлась бы с серверной, где считаются
  // символы UTF-8.
  const nameLen = (v) => Array.from(v).length;
  const nameOk  = (v) => v.length > 0 && !NAME_BAD_RE.test(v) && nameLen(v) <= 32;
  const NAME_HINT = "Имя политики: до 32 символов, нельзя \" $ ` \\ ; \u0027 |";

  function setPolicyStatus(state, text) {
    // state: good | warn | muted | error
    statusEl.dataset.state = state;
    statusEl.querySelector(".policy-status-text").textContent = text;
  }
  function setPolicyMode(exclude) {
    segGroup.querySelectorAll(".seg-btn").forEach(b => {
      const on = b.dataset.exclude === String(exclude);
      b.classList.toggle("seg-on", on);
      b.setAttribute("aria-checked", String(on));
    });
  }
  async function loadPolicyStatus() {
    const seq = _newLoad("policy");
    try {
      const d = await apiGet("/policy/status");
      if (_stale("policy", seq)) return;
      nameInput.value = d.name || "";
      setPolicyMode(d.exclude === "1" ? 1 : 0);
      if (!d.name) {
        setPolicyStatus("muted", "Поле пусто — фильтр выключен");
      } else if (d.exists === 1 || d.exists === true) {
        setPolicyStatus("good", `Политика «${d.name}» найдена в Keenetic`);
      } else {
        setPolicyStatus("warn", `Политика «${d.name}» не найдена — фильтр игнорируется, обрабатывается весь трафик`);
      }
    } catch (e) {
      if (_stale("policy", seq)) return;
      setPolicyStatus("error", "Ошибка: " + errMsg(e));
    }
  }
  loadPolicyStatus();

  // Validate + (опционально) повторный status check на blur
  nameInput.addEventListener("blur", () => {
    const v = nameInput.value.trim();
    if (!nameOk(v)) {
      setPolicyStatus("error", NAME_HINT);
      return;
    }
    // Запрос свежего status'а с currently-saved конфигом — input не сохранит
    // ничего пока юзер не нажмёт «Сохранить». Если хочется live-проверки
    // existence без save — на будущее можно добавить отдельный endpoint
    // /policy/check?name=. Сейчас: оставляем статус до Save.
  });

  segGroup.addEventListener("click", (e) => {
    const btn = e.target.closest(".seg-btn");
    if (!btn) return;
    setPolicyMode(parseInt(btn.dataset.exclude, 10));
  });

  saveBtn.addEventListener("click", async () => {
    if (saveBtn.disabled) return;
    const v = nameInput.value.trim();
    if (!nameOk(v)) {
      toast(NAME_HINT, "bad");
      nameInput.focus();
      return;
    }
    const exclude = segGroup.querySelector(".seg-btn.seg-on")?.dataset.exclude || "0";
    // Кнопка не входит в глобальный лок, а под ней рестарт сервиса: без
    // этого второй клик в окне ожидания ответа запускал вторую задачу.
    saveBtn.disabled = true;
    let resp;
    try {
      resp = await apiPost("/policy/save", { name: v, exclude });
    } catch (e) {
      saveBtn.disabled = false;
      toastErr("Ошибка: ", e);
      return;
    }
    if (resp && resp.job) {
      openJobModal("Применение политики доступа", resp.job, {
        onDone: () => { saveBtn.disabled = false; setTimeout(loadPolicyStatus, 500); }
      });
    } else {
      saveBtn.disabled = false;
      toast("Применено");
      loadPolicyStatus();
    }
  });

  // Если уже бежит job (юзер пришёл с другой вкладки) — сразу заблочить
  // только что отрендеренные switches/buttons. Без этого глобал-лок
  // применился бы к старым DOM-элементам которых на этой странице нет.
  _updateGlobalUILock();
}

async function toggleClick(key, box) {
  const sw = box.closest(".switch");
  const wanted = box.checked ? "1" : "0";
  if (key === "autohostlist" && wanted === "1") {
    // Тумблер блокируем на время вопроса. Подложка модалки перехватывает
    // мышь, но не клавиатуру: без этого Tab уводил фокус из модалки обратно
    // на чекбокс, пробел давал второй change, и запрос уходил на бэкенд мимо
    // подтверждения — в итоге в конфиге было включено, а галочка снята.
    box.disabled = true;
    const go = await confirmModal("Включить автохостлист?", AUTOHOSTLIST_WARNING,
                                  "Включать", "Не включать");
    // Пока висел вопрос, страницу могла перерисовать чужая фоновая задача
    // (например завершившийся туннель зовёт renderToggles): тогда наш box
    // уже отцеплен от документа, и запись в него ничего не покажет. Ответ
    // при этом остаётся в силе — состояние подтянет следующий /status.
    if (typeof document.body.contains === "function" && !document.body.contains(box)) return;
    box.disabled = false;
    if (!go) {
      // Событие change уже переставило чекбокс — возвращаем его сами.
      box.checked = false;
      return;
    }
  }
  sw.classList.add("loading");
  box.disabled = true; // блок UI до завершения, не даём кликать ещё
  const restarts = TOGGLES_RESTART_SERVICE[key] === 1;
  const verb = key === "fastroute"
    ? (wanted === "1" ? "Отключаю" : "Включаю")
    : (wanted === "1" ? "Включаю" : "Отключаю");
  const niceName = {
    category_youtube: "YouTube",
    category_rkn: "RKN",
    category_discord_voice: "Discord Voice / STUN",
    customd: "custom.d",
    dynamic_ttl: "Динамический TTL",
    ppe: "PPE de-offload",
    fastroute: "Маршрутный кэш",
    auto_update: "Автообновление движка zapret2",
    autohostlist: "Автохостлист",
    tiktok_feed: "TikTok — исправление ленты",
  }[key] || key;

  let resp;
  try {
    resp = await apiPost("/toggle/" + TOGGLE_API_NAME[key], { value: wanted });
  } catch (e) {
    box.checked = !box.checked; // revert
    box.disabled = false;
    sw.classList.remove("loading");
    toastErr("Ошибка: ", e);
    if (key === "fastroute") refreshFastroute(box);
    return;
  }
  if (!resp.job) {
    // Out-of-band preferences (auto-update) only persist one flag;
    // opening a background-job modal would take longer than the operation.
    sw.classList.remove("loading");
    box.disabled = false;
    box.checked = wanted === "1";
    if (key === "auto_update") auHourSync(box);
    toast(wanted === "1" ? "Включено" : "Выключено");
    refreshStatus();
    return;
  }
  // Backend async — открываем модалку с live-логом. Состояние switch'а
  // (loading + disabled) держится до onDone — если юзер закрыл модалку
  // раньше, badge в углу позволит снова открыть, а UI блокировка не
  // даст думать что переключение уже применилось.
  openJobModal(verb + " " + niceName, resp.job, {
    // Рестарт nfqws2 перетряхивает iptables на канале, по которому открыта
    // сама панель: обрыв на десятки секунд здесь норма, и обрывать опрос
    // через пять секунд значит объявить провалом штатный ход операции.
    tolerateOutage: restarts,
    onDone: (d) => {
      sw.classList.remove("loading");
      box.disabled = false;
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) {
        // Toggle failed — revert checkbox чтобы UI отражал реальное
        // состояние (старое значение сохранилось в config).
        box.checked = !box.checked;
        toast(key === "fastroute" ? "Не удалось применить настройку — проверьте состояние кэша и журнал" : "Не получилось — вернул как было", "bad");
      } else if (jobUnresolved(outcome)) {
        // Итог неизвестен: в конфиге ничего не откатывалось, поэтому не
        // трогаем чекбокс и не обещаем, что вернули как было.
        const m = unresolvedMsg(outcome);
        if (m) toast(m, "bad");
        if (key !== "fastroute") resyncToggle(key, box);
      } else {
        toast(key === "fastroute" ? "Настройка сохранена" : (wanted === "1" ? "Включено" : "Выключено"));
      }
      // Чекбокс мог вернуться в прежнее положение (провал или resync) —
      // строка с временем обязана поехать за ним.
      if (key === "auto_update") auHourSync(box);
      if (key === "fastroute") {
        apiGet("/status").then(s => {
          box.checked = s.toggles.fastroute === "1";
          const state = $app.querySelector("#fastroute-status");
          if (state) state.textContent = s.toggles.fastroute_status || "Состояние маршрутного кэша недоступно.";
        }).catch(() => {
          const state = $app.querySelector("#fastroute-status");
          if (state) state.textContent = "Не удалось проверить состояние маршрутного кэша.";
        });
      }
      if (key === "tiktok_feed") {
        apiGet("/status").then(s => {
          if (!box.isConnected) return;
          box.checked = s.toggles && s.toggles.tiktok_feed === "1";
          renderTikTokStatus(s.tiktok_feed_status, s.toggles, s.platform, s.server_now_epoch);
        }).catch(() => {});
      }
      if (restarts && !jobUnresolved(outcome)) setTimeout(refreshStatus, 500);
    },
  });
}
