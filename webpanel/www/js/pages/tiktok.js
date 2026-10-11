import { apiGet, apiPost, errHtml, toastErr } from "../core/api.js";
import { $app, escapeHtml, humanAgo } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { JOB_FAIL, jobOutcome, jobUnresolved, openJobModal, setLockAware, unresolvedMsg } from "../job.js";
import { toast } from "../core/toast.js";

function tiktokReasonLabel(reason) {
  return ({
    healthy: "Проверка прошла успешно",
    "current-ip-fast-path": "Текущий узел подтвердил доступность",
    "no-current": "Подтверждён первый рабочий узел",
    "current-unhealthy": "Текущий узел не прошёл проверку",
    "material-latency-improvement": "Найден заметно более быстрый узел",
    "hysteresis-not-met": "Переключение отложено: разница в задержке недостаточна",
    "alternative-unhealthy": "Альтернативный узел не прошёл проверку",
    "active-probe": "Проверена доступность текущего IP",
    "active-probe-failed": "Текущий IP не прошёл проверку",
    "confirmed-failover": "После двух отказов включён проверенный резерв",
    "dns-apply-failed": "DNS-подмена не применена; прежняя запись сохранена",
    "initial-selection": "Выбран первый проверенный IP",
    "legacy-date-unknown": "Историческая дата выбора неизвестна",
    "legacy-strict-selection": "Сохранена строгая фиксация из старой настройки",
    "no-verified-candidate": "Для домена не найден проверенный кандидат",
    "policy-updated": "Политика выбора обновлена",
    "preferred-recovered": "Предпочтительный IP восстановлен после стабильных проверок",
    "preferred-selection": "IP задан как предпочтительный",
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
let tiktokSelectedDomain = "v77.tiktokcdn.com";

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
  const host = tiktokSelectedDomain;
  const hostSlug = host.replace(/[.-]/g, "_");
  const hostScanAt = tiktokValue(data[`domain_${hostSlug}_candidates_checked_epoch`]);
  const hostScopedScan = Boolean(hostScanAt);
  const hostPool = tiktokValue(data[`domain_${hostSlug}_candidate_pool`]);
  const hostObservations = tiktokValue(data[`domain_${hostSlug}_candidate_observations`]);
  const legacyV77 = host === "v77.tiktokcdn.com" && !hostScopedScan;
  const candidates = new Map();
  String(hostScopedScan ? hostPool : (data.candidate_pool || "")).split(";").forEach(raw => {
    const fields = raw.split("|");
    const ip = tiktokValue(fields[0]);
    if (ip && /^\d{1,3}(?:\.\d{1,3}){3}$/.test(ip) && !candidates.has(ip)) {
      candidates.set(ip, fields);
    }
  });
  const probes = new Map();
  String(hostScopedScan ? hostObservations : (data.probe_observations || "")).split(";").forEach(raw => {
    const fields = raw.split("|");
    const ip = tiktokValue(fields[0]);
    if (ip) probes.set(ip, fields);
  });
  const selectedIp = tiktokValue(data[`domain_${hostSlug}_selected_ip`]) || (legacyV77 ? tiktokValue(data.selected_ip) : "");
  const rows = [...candidates.entries()].map(([ip, candidate], index) => {
    const probe = probes.get(ip) || [];
    const selected = selectedIp === ip;
    const unavailable = selected && data.state === "manual-unavailable";
    const domainVerified = hostScopedScan && probe[10] === "verified";
    const v77Verified = probe[10] === "verified";
    const euVerified = probe[20] === "verified";
    const verified = !unavailable && (hostScopedScan ? domainVerified : legacyV77 && probe[21] === "compatible" && v77Verified && euVerified);
    const checked = hostScopedScan ? probe.length >= 11 : legacyV77 && probe.length >= 22;
    const checkNodes = Number.parseInt(candidate[11], 10) || 0;
    const checkCountries = Number.parseInt(candidate[12], 10) || 0;
    const checkAsns = Number.parseInt(candidate[13], 10) || 0;
    const hint = tiktokValue(candidate[6]) || "";
    const source = [candidate[7], candidate[4]].map(tiktokValue).filter(Boolean).join(" · ");
    const latencyValue = verified ? Number.parseInt(probe[1], 10) : 0;
    const category = verified ? "working" : checked ? "unavailable" : "unknown";
    const icmp = legacyV77 ? tiktokLatency(probe[22]) : "";
    const targetCell = (label, latencyIndex, verifiedIndex) => {
      if (hostScopedScan) {
        if (label !== "v77") return "";
        return probe[10] === "verified"
          ? `<span class="tiktok-target-probe good">TLS/SNI · ${escapeHtml(host)} <b>✓ ${escapeHtml(tiktokLatency(probe[1]) || "подтверждены")}</b></span>`
          : `<span class="tiktok-target-probe bad">TLS/SNI · ${escapeHtml(host)} <b>✕ не подтверждены</b></span>`;
      }
      if (!legacyV77) return label === "v77" ? `<span class="tiktok-target-probe pending">TLS/SNI · ${escapeHtml(host)} <b>Не проверены</b></span>` : "";
      if (probe.length < 22) return `<span class="tiktok-target-probe pending">${label} <b>Не проверен</b></span>`;
      return probe[verifiedIndex] === "verified"
        ? `<span class="tiktok-target-probe good">${label} <b>✓ ${escapeHtml(tiktokLatency(probe[latencyIndex]) || "TLS")}</b></span>`
        : `<span class="tiktok-target-probe bad">${label} <b>✕ timeout</b></span>`;
    };
    const tcpLabel = (value) => value === "ok" ? "Доступен" : value === "failed" ? "Нет ответа" : "—";
    const tlsLabel = (value) => value === "ok" ? "Проверен" : value === "failed" ? "Не прошёл" : "—";
    const targetFacts = (name, offset) => {
      if (hostScopedScan || !legacyV77) {
        if (offset !== 0) return "";
        if (!hostScopedScan) return `<span>Проверка · ${escapeHtml(host)}<b>Не выполнена для этого домена</b></span>`;
        return [
          `<span>TCP 443 · ${escapeHtml(host)}<b>${escapeHtml(tcpLabel(probe[8]))}</b></span>`,
          `<span>TLS/SNI · ${escapeHtml(host)}<b>${escapeHtml(tlsLabel(probe[9]))}</b></span>`,
          `<span>HTTPS · ${escapeHtml(host)}<b>${escapeHtml(tiktokLatency(probe[1]) || "—")}</b></span>`,
          `<span>HTTP · ${escapeHtml(host)}<b>${escapeHtml(tiktokValue(probe[4]) || "—")}</b></span>`,
          `<span>POP / сервер · ${escapeHtml(host)}<b>${escapeHtml([probe[5] ? `POP ${probe[5]}` : "", probe[7] || ""].filter(Boolean).join(" · ") || "—")}</b></span>`,
        ].join("");
      }
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
    const canCheckForDomain = !legacyV77;
    const buttonLabel = verified ? "Выбрать" : "Проверить и выбрать";
    const button = ip && (verified || (canCheckForDomain && !checked))
      ? `<button type="button" class="btn btn-secondary tiktok-select-cdn" data-tiktok-action="select" data-ip="${escapeHtml(ip)}" data-host="${escapeHtml(host)}" aria-label="${buttonLabel} CDN ${escapeHtml(ip)}${canCheckForDomain ? ` для ${escapeHtml(host)}` : ""}"${pending ? " disabled" : ""}>${buttonLabel}</button>`
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
      ? `<span class="tiktok-candidate-verified">Проверен для ${escapeHtml(host)}</span>`
      : row.checked ? `<span>TLS/SNI для ${escapeHtml(host)} не подтверждены</span>` : "";
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
  const checked = hostScopedScan || (legacyV77 && [...probes.values()].some(probe => probe.length >= 22));
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
      <label class="tiktok-mode-control"><span class="tiktok-mode-label">Домен</span><select data-tiktok-domain-select aria-label="Домен TikTok для проверки и выбора">${[
        "v77.tiktokcdn.com", "v77.tiktokcdn-eu.com", "v16-cla.tiktokcdn.com", "v16-ies-music.tiktokcdn.com", "sf16-music.tiktokcdn-eu.com",
      ].map(host => `<option value="${host}"${host === tiktokSelectedDomain ? " selected" : ""}>${host}</option>`).join("")}</select></label>
      <button type="button" class="btn btn-primary" data-tiktok-action="probe-all" data-host="${escapeHtml(host)}"${pending ? " disabled" : ""}>Проверить все</button>
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
    const endpoints = { "probe-all": "/tiktok/probe-all", select: "/tiktok/select", manual: "/tiktok/select", auto: "/tiktok/auto", policy: "/tiktok/policy" };
    const labels = { "probe-all": "Проверка CDN-кандидатов", select: "Проверка и выбор CDN", manual: "Фиксация текущего CDN", auto: "Автоматический выбор CDN", policy: "Обновление политики CDN" };
    if (!endpoints[action]) return;
    const actionHost = button.dataset.host || ((action === "probe-all" || action === "select") ? tiktokSelectedDomain : "");
    tiktokPendingAction = { action, ip: action === "select" ? button.dataset.ip : "", host: actionHost, policy: button.dataset.policy || "" };
    renderTikTokStatus(tiktokStatusSnapshot, tiktokTogglesSnapshot, tiktokPlatformSnapshot, tiktokServerNowEpoch);
    const buttons = [...card.querySelectorAll("[data-tiktok-action]")];
    buttons.forEach(item => { item.disabled = true; });
    try {
      const params = action === "select" || action === "manual"
        ? { ip: button.dataset.ip, host: button.dataset.host || tiktokSelectedDomain }
        : action === "policy" ? { host: button.dataset.host, policy: button.dataset.policy }
          : action === "probe-all" ? { host: actionHost } : {};
      const response = await apiPost(endpoints[action], params);
      openJobModal(labels[action], response.job, {
        tolerateOutage: action === "select" || action === "auto" || action === "policy",
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
  card.addEventListener("change", event => {
    const select = event.target.closest("[data-tiktok-domain-select]");
    if (!select) return;
    tiktokSelectedDomain = select.value;
    renderTikTokStatus(tiktokStatusSnapshot, tiktokTogglesSnapshot, tiktokPlatformSnapshot, tiktokServerNowEpoch);
  });
}

function tiktokDomainCardsMarkup(data, serverNowEpoch, pending) {
  const hosts = [
    "v77.tiktokcdn.com", "v77.tiktokcdn-eu.com", "v16-cla.tiktokcdn.com",
    "v16-ies-music.tiktokcdn.com", "sf16-music.tiktokcdn-eu.com",
  ];
  const policies = { auto: "Авто", preferred: "Предпочтительный", strict: "Строгий" };
  const healthLabels = {
    unverified: "Ожидает проверки",
    "transport-confirmed": "TCP/TLS/SNI подтверждены",
    unavailable: "Домен не прошёл проверку",
    "dns-apply-error": "Ошибка применения DNS",
    degraded: "Нестабильно",
  };
  return `<section class="tiktok-domains" aria-label="Состояние CDN по доменам">
    <p class="desc">Состояние проверяется отдельно по каждому домену. DNS и TLS сами по себе не подтверждают передачу видео.</p>
    ${hosts.map(host => {
      const slug = host.replace(/[.-]/g, "_");
      const value = field => tiktokValue(data[`domain_${slug}_${field}`]);
      const policy = value("policy") || "auto";
      const selectedIp = value("selected_ip");
      const preferredIp = value("preferred_ip");
      const health = value("health") || "unverified";
      const reason = value("reason");
      const dnsApplied = value("dns_override_applied") === "1" ? "DNS роутера применён" : "DNS роутера не подтверждён";
      const selectedAt = tiktokTime(value("selected_at_epoch"), true, serverNowEpoch);
      const verifiedAt = tiktokTime(value("last_verified_epoch"), true, serverNowEpoch);
      const evaluatedAt = tiktokTime(value("last_evaluation_epoch"), true, serverNowEpoch);
      const candidatePool = value("candidate_pool");
      const candidateCount = candidatePool ? candidatePool.split(";").filter(Boolean).length : 0;
      const selectedCandidate = candidatePool.split(";").map(row => row.split("|")).find(candidate => candidate[0] === selectedIp);
      const selectedSource = selectedCandidate
        ? [tiktokValue(selectedCandidate[7]), tiktokValue(selectedCandidate[4])].filter(Boolean).join(" · ") : "";
      const candidatesAt = tiktokTime(value("candidates_checked_epoch"), true, serverNowEpoch);
      const latency = tiktokLatency(value("latency_ms"));
      const http = value("http_status");
      const failoverFrom = value("last_failover_from");
      const failoverTo = value("last_failover_to");
      const rowPending = pending && pending.host === host;
      return `<article class="tiktok-domain-card">
        <div class="tiktok-domain-heading"><code>${escapeHtml(host)}</code><span class="tiktok-domain-health">${escapeHtml(rowPending ? "Обновляется…" : (healthLabels[health] || health))}</span></div>
        <div class="tiktok-domain-facts">
          <span>IP <b>${selectedIp ? `<code>${escapeHtml(selectedIp)}</code>` : "—"}</b></span>
          <span>Предпочтительный IP <b>${preferredIp ? `<code>${escapeHtml(preferredIp)}</code>` : "нет"}</b></span>
          <span>Политика <b>${escapeHtml(policies[policy] || policy)}</b></span>
          <span>${escapeHtml(dnsApplied)}</span>
          <span>TLS <b>${escapeHtml(latency || "—")}</b></span>
          <span>HTTP <b>${escapeHtml(http || "—")}</b></span>
          <span>Видео <b>не проверено</b></span>
          <span>IP выбран <b>${escapeHtml(selectedAt || "время неизвестно")}</b></span>
          <span>Последняя проверка <b>${escapeHtml(verifiedAt || "нет успешной проверки")}</b></span>
          <span>Последняя оценка <b>${escapeHtml(evaluatedAt || "ещё не выполнялась")}</b></span>
          <span>Кандидаты <b>${candidateCount} · ${escapeHtml(candidatesAt || "ещё не сканировались")}</b></span>
          ${selectedSource ? `<span>Источник выбранного IP <b>${escapeHtml(selectedSource)}</b></span>` : ""}
          ${reason ? `<span>Причина состояния <b>${escapeHtml(tiktokReasonLabel(reason))}</b></span>` : ""}
          ${failoverFrom && failoverTo ? `<span>Последний failover <b><code>${escapeHtml(failoverFrom)} → ${escapeHtml(failoverTo)}</code></b></span>` : ""}
        </div>
        <div class="tiktok-domain-policies" role="group" aria-label="Политика для ${escapeHtml(host)}">
          ${Object.entries(policies).map(([key, label]) => `<button type="button" class="tiktok-policy-button${key === policy ? " active" : ""}" data-tiktok-action="policy" data-host="${escapeHtml(host)}" data-policy="${key}" aria-pressed="${key === policy}"${pending || key === policy ? " disabled" : ""}>${label}</button>`).join("")}
        </div>
      </article>`;
    }).join("")}
  </section>`;
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
    title = "CDN доступен"; kind = "good";
    copy = "Транспорт и TLS подтверждены, HTTP проверен, DNS применён на роутере. Передача видео и работа ленты не проверены; устройство должно использовать DNS роутера.";
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
    ${tiktokDomainCardsMarkup(data, serverNowEpoch, pending)}
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


async function refreshTikTokPage() {
  if (!document.getElementById("tiktok-toggle")) return;
  const seq = _newLoad("tiktok");
  try {
    const state = await apiGet("/status");
    if (_stale("tiktok", seq) || !document.getElementById("tiktok-toggle")) return;
    const toggle = document.getElementById("tiktok-toggle");
    const supported = state.platform === "openwrt";
    toggle.disabled = !supported;
    toggle.checked = !!(state.toggles && state.toggles.tiktok_feed === "1");
    const nav = document.querySelector('a[data-route="tiktok"]');
    if (nav) nav.style.display = supported ? "" : "none";
    const unsupported = document.getElementById("tiktok-unsupported");
    if (unsupported) unsupported.hidden = supported;
    renderTikTokStatus(state.tiktok_feed_status, state.toggles, state.platform, state.server_now_epoch);
  } catch (error) {
    const note = document.getElementById("tiktok-error");
    if (note) note.innerHTML = `Не удалось прочитать состояние: ${errHtml(error)}`;
    setLockAware(document.getElementById("tiktok-toggle"), true);
  }
}

async function changeTikTok(enabled) {
  const toggle = document.getElementById("tiktok-toggle");
  if (!toggle) return;
  toggle.disabled = true;
  try {
    const response = await apiPost("/toggle/tiktok-feed", { value: enabled ? "1" : "0" });
    if (!response.job) {
      toast(enabled ? "TikTok Fix включён" : "TikTok Fix выключен");
      await refreshTikTokPage();
      return;
    }
    openJobModal(enabled ? "Включаю TikTok Fix" : "Отключаю TikTok Fix", response.job, {
      tolerateOutage: true,
      onDone: async result => {
        if (jobOutcome(result) === JOB_FAIL) toast("Не удалось изменить TikTok Fix", "bad");
        else if (jobUnresolved(jobOutcome(result))) {
          const message = unresolvedMsg(jobOutcome(result));
          if (message) toast(message, "bad");
        }
        await refreshTikTokPage();
      },
    });
  } catch (error) {
    toggle.checked = !enabled;
    toggle.disabled = false;
    toastErr("Не удалось изменить TikTok Fix: ", error);
  }
}

export async function renderTikTok() {
  $app.innerHTML = `
    <h1 class="page-title">TikTok Fix</h1>
    <div class="card">
      <h3>Исправление ленты TikTok</h3>
      <p class="desc">Автоматически подбирает рабочий CDN. Можно выбрать проверенный узел вручную и настроить политику для каждого управляемого домена.</p>
      <div class="toggle-row"><div class="t-text"><div class="t-name">Исправление ленты</div><div class="t-desc">DNS-подмена применяется только к пяти управляемым CDN-доменам.</div></div><label class="switch"><input id="tiktok-toggle" type="checkbox" disabled><span class="slider"></span></label></div>
      <p id="tiktok-error" class="desc" role="alert"></p>
      <p id="tiktok-unsupported" class="desc" hidden>Этот раздел доступен только на OpenWrt.</p>
    </div>
    <div class="card tiktok-feed-status-card" id="tiktok-feed-status-card" hidden></div>`;
  document.getElementById("tiktok-toggle").addEventListener("change", event => changeTikTok(event.currentTarget.checked));
  await refreshTikTokPage();
}
