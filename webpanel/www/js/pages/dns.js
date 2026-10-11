import { apiGet, apiPost, apiPostText, toastErr } from "../core/api.js";
import { $app, escapeHtml } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { JOB_FAIL, awaitPanelBack, jobOutcome, jobUnresolved, openJobModal, unresolvedMsg } from "../job.js";
import { toast } from "../core/toast.js";
import { DNS_PROVIDER_CATALOG } from "../data/dns-providers.js?v=p-0.0";

export async function renderDns() {
  $app.innerHTML = `
    <h1 class="page-title">DNS</h1>
    <div class="card" id="doh-card">
      <h2>Настройка</h2>
      <p class="desc">Выберите один или несколько upstream из каталога. Протоколы и адреса показаны только там, где они подтверждены; fallback настраивается отдельно.</p>
      <div class="doh-controls">
        <label class="field" for="dns-protocol"><span class="field-label">Протокол</span><select class="t-sub-select" id="dns-protocol"><option value="doh">DoH (HTTPS)</option><option value="doh3">DoH3 (HTTP/3)</option><option value="dot">DoT (TLS)</option><option value="doq">DoQ (QUIC)</option><option value="dnscrypt">DNSCrypt (stamp)</option></select></label>
        <label class="field" for="doh-provider"><span class="field-label">Провайдер</span>
          <select class="t-sub-select" id="doh-provider"></select>
        </label>
      </div>
      <label class="field" id="dns-nextdns-profile-field" for="dns-nextdns-profile" hidden><span class="field-label">ID профиля NextDNS</span><input id="dns-nextdns-profile" type="text" inputmode="text" autocomplete="off" placeholder="abcdef" spellcheck="false"><span class="field-hint">ID из панели NextDNS. Он подставляется в адрес DoH или DoT.</span></label>
      <p class="desc" id="dns-protocol-help" aria-live="polite"></p>
      <div class="doh-custom-fields" id="doh-custom-fields" hidden>
        <p class="desc" id="dns-custom-compatibility"></p>
        <label class="field" for="doh-endpoint"><span class="field-label" id="doh-endpoint-label">HTTPS endpoint</span><input id="doh-endpoint" type="url" inputmode="url" autocomplete="url" placeholder="https://dns.example/dns-query" spellcheck="false"></label>
        <label class="field" for="doh-bootstrap"><span class="field-label">Bootstrap DNS (IPv4/IPv6 через запятую или с новой строки)</span><input id="doh-bootstrap" type="text" inputmode="text" autocomplete="off" placeholder="9.9.9.9,8.8.8.8" spellcheck="false"></label>
      </div>
      <div class="dns-profile-add">
        <label class="field" for="doh-upstream-role"><span class="field-label">Добавить как</span><select class="t-sub-select" id="doh-upstream-role"><option value="upstream">Основной upstream</option><option value="fallback">Аварийный fallback</option></select></label>
        <button class="btn btn-secondary" id="doh-add-upstream" type="button">Добавить выбранный сервер</button>
      </div>
      <div id="dns-profile-queue" aria-live="polite"></div>
      <div class="dns-profile-settings">
        <label class="field" for="dns-upstream-mode"><span class="field-label">Стратегия upstream</span><select class="t-sub-select" id="dns-upstream-mode"><option value="load_balance">Распределять запросы между upstream</option><option value="parallel">Отправлять параллельно и брать первый ответ</option><option value="fastest_addr">Выбирать самый быстрый IP из ответа</option></select></label>
        <label class="field" for="dns-profile-bootstrap"><span class="field-label">Bootstrap резолверы (IP через запятую или с новой строки)</span><textarea id="dns-profile-bootstrap" spellcheck="false" placeholder="9.9.9.9&#10;8.8.8.8"></textarea><span class="field-hint">Независимые DNS адреса, которыми dnsproxy разрешает имена upstream. Список можно заменить; его запросы идут напрямую к указанным IP, не через dnsmasq.</span></label>
      </div>
      <div class="dns-profile-warning" id="dns-profile-warning" aria-live="polite">DNS upstream по умолчанию не имеет незашифрованного fallback. Bootstrap — глобальный параметр пакета dnsproxy, общий для всех upstream.</div>
      <div class="dns-profile-rules">
        <h3>Доменные правила</h3>
        <div class="doh-controls"><label class="field" for="dns-route-domain"><span class="field-label">Домен</span><input id="dns-route-domain" autocomplete="off" placeholder="example.com"></label><label class="field" for="dns-route-upstream"><span class="field-label">Направлять через</span><select class="t-sub-select" id="dns-route-upstream"></select></label><button class="btn btn-secondary" id="dns-route-add" type="button">Добавить правило</button></div>
        <div id="dns-profile-rules-list"></div>
      </div>
      <p class="doh-ownership-warning" id="doh-ownership-warning" hidden>Найдена пользовательская конфигурация dnsproxy. При применении она будет сохранена для восстановления после удаления.</p>
      <div class="doh-status" id="doh-status" data-state="unknown" role="status" aria-live="polite">Статус: проверяется…</div>
      <div class="btn-row" id="doh-actions"></div>
    </div>
    <section class="card" id="dns-advanced">
      <h2>Дополнительно</h2>
      <div class="dns-adapter-diagnostics" id="dns-adapter-diagnostics" aria-live="polite"></div>
      <div class="dns-cache-controls" id="dns-cache-controls" hidden>
        <h3>Кэш dnsproxy</h3>
        <label class="field" for="dns-cache-enabled"><span class="field-label">Кэш ответов</span><select class="t-sub-select" id="dns-cache-enabled"><option value="1">Включён</option><option value="0">Выключен</option></select></label>
        <label class="field" for="dns-cache-size"><span class="field-label">Размер кэша, байт (4096–1048576)</span><input type="number" id="dns-cache-size" min="4096" max="1048576" step="1" inputmode="numeric"></label>
        <button class="btn btn-secondary" id="dns-cache-save" data-doh-action="settings">Сохранить кэш</button>
      </div>
      <div class="dns-redirect-controls" id="dns-redirect-controls" hidden>
        <h3>DNS для LAN</h3>
        <p class="desc">Управляемое правило fw4 перехватывает запросы клиентов LAN по IPv4 TCP/UDP 53 и направляет их к dnsmasq. IPv6-перенаправление не включено.</p>
        <label class="field" for="dns-force-redirect"><span class="field-label">Принудительный IPv4 DNS redirect</span><select class="t-sub-select" id="dns-force-redirect"><option value="0">Выключен</option><option value="1">Включён</option></select></label>
        <p class="desc" id="dns-redirect-state"></p>
        <button class="btn btn-secondary" id="dns-redirect-save" data-doh-action="redirect">Сохранить redirect</button>
      </div>
      <p class="desc" id="dns-adapter-capability-note">Отдельные upstream-переключатели IPv4/IPv6 в dnsproxy 0.83.0 отсутствуют; это не влияет на выбранный upstream-протокол.</p>
      <div class="btn-row" id="dns-recovery-actions"></div>
      <p class="desc" id="dns-recovery-note"></p>
    </section>
    <section class="card" id="dns-check">
      <div class="row-between"><div><h2>Проверка</h2><p class="desc">Сравнивает обычный DNS, DoH и DoT; быстрый ответ ещё не подтверждает подлинность сервера. Проверка занимает около минуты.</p></div><button class="btn btn-primary" id="dns-run">Проверить</button></div>
      <div id="dns-result"></div>
      <div class="dns-own"><label for="dns-own-text">Свои DNS-серверы для проверки</label><textarea id="dns-own-text" spellcheck="false" autocapitalize="none" placeholder="1.1.1.2&#10;https://dns.example.org/dns-query"></textarea><p class="desc" style="margin:6px 0 10px">По одному в строке: адрес для обычного DNS или ссылка для DoH. Проверяются вместе с остальными.</p><button class="btn" id="dns-own-save">Сохранить</button></div>
    </section>`;
  document.getElementById("dns-run").addEventListener("click", dnsRun);
  document.getElementById("dns-own-save").addEventListener("click", dnsOwnSave);
  wireDohCard();
  loadDnsLast();
  try {
    const state = await apiGet("/status");
    const nav = document.querySelector('a[data-route="dns"]');
    if (nav) nav.style.display = state.platform === "openwrt" ? "" : "none";
    if (!document.getElementById("doh-card")) return;
    if (state.platform !== "openwrt") {
      document.getElementById("doh-card").hidden = true;
      document.getElementById("dns-run").disabled = true;
      document.getElementById("dns-result").innerHTML = '<p class="desc">DNS-инструменты доступны только на OpenWrt.</p>';
    } else renderDohStatus(state.doh, true);
  } catch (error) {
    toastErr("Не удалось прочитать состояние DNS: ", error);
  }
}


function dohReasonLabel(reason) {
  const labels = {"package-missing":"Пакет dnsproxy не установлен.","resolver-config-missing":"Не найдена активная конфигурация DNS-провайдера.","proxy-not-running":"Сервис dnsproxy не запущен.","dnsmasq-not-running":"Сервис dnsmasq не запущен.","listener-query-failed":"Локальный DNS listener не ответил. Нажмите «Проверить» для диагностики."};
  return labels[reason] || "Сервис или конфигурация DNS-провайдера недоступны. Нажмите «Проверить» для диагностики.";
}
const DNS_PROTOCOL_LABELS = {doh:"DoH", doh3:"DoH3", dot:"DoT", doq:"DoQ", dnscrypt:"DNSCrypt"};
const DNS_CATEGORY_LABELS = {universal:"Универсальные", filtering:"С фильтрацией", regional:"Региональные и Smart DNS", personal:"Персональные"};
const DNS_DEFAULT_BOOTSTRAP = ["9.9.9.9", "149.112.112.112", "8.8.8.8", "8.8.4.4", "2620:fe::fe", "2620:fe::9", "2001:4860:4860::8888", "2001:4860:4860::8844"];
const DNS_PROFILE = {upstreams:[], fallbacks:[], routes:[], touched:false};
let dnsProfileWarningRequired = false;
function selectedCatalogEntry(provider = $app.querySelector("#doh-provider")?.value) {
  return DNS_PROVIDER_CATALOG.find(entry => entry.id === provider) || null;
}
function populateProviderCatalog(select) {
  const previous = select.value;
  select.replaceChildren();
  for (const category of Object.keys(DNS_CATEGORY_LABELS)) {
    const group = document.createElement("optgroup"); group.label = DNS_CATEGORY_LABELS[category];
    for (const entry of DNS_PROVIDER_CATALOG.filter(item => item.category === category)) {
      const option = document.createElement("option"); option.value = entry.id;
      option.textContent = `${entry.name}${entry.verified ? "" : " · источник не подтверждён"}`;
      group.append(option);
    }
    if (group.children.length) select.append(group);
  }
  const custom = document.createElement("option"); custom.value = "custom"; custom.textContent = "Свой endpoint"; select.append(custom);
  select.value = [...select.options].some(option => option.value === previous) ? previous : "xbox";
}
function updateDnsProtocolUi(card, provider = card.querySelector("#doh-provider").value) {
  const protocol = card.querySelector("#dns-protocol"), custom = provider === "custom";
  const entry = selectedCatalogEntry(provider);
  const allowed = custom ? Object.keys(DNS_PROTOCOL_LABELS) : (entry?.protocols || ["doh"]);
  for (const option of protocol.options) option.hidden = !allowed.includes(option.value);
  if (!allowed.includes(protocol.value)) protocol.value = allowed[0] || "doh";
  const scheme = protocol.value;
  const label = $app.querySelector("#doh-endpoint-label"), input = $app.querySelector("#doh-endpoint");
  const nextdns = $app.querySelector("#dns-nextdns-profile-field");
  nextdns.hidden = provider !== "nextdns";
  const formats = {
    doh: ["HTTPS endpoint", "https://dns.example/dns-query", "url", "DoH требует https:// URL."],
    doh3: ["DoH3 endpoint (h3://)", "h3://dns.example/dns-query", "text", "DoH3 доступен только если ваш endpoint поддерживает HTTP/3 (h3://)."],
    dot: ["DoT endpoint (tls://)", "tls://dns.example:853", "text", "DoT требует TLS endpoint (tls://host[:port])."],
    doq: ["DoQ endpoint (quic://)", "quic://dns.example:853", "text", "DoQ требует QUIC endpoint (quic://host[:port])."],
    dnscrypt: ["DNSCrypt stamp (sdns://)", "sdns://…", "text", "DNSCrypt stamp содержит адрес resolver. Bootstrap для адреса из stamp не используется."],
  }[scheme] || ["Endpoint", "", "text", ""];
  $app.querySelector("#doh-custom-fields").hidden = !custom;
  label.textContent = formats[0]; input.type = formats[2]; input.inputMode = formats[2] === "url" ? "url" : "text"; input.placeholder = formats[1];
  input.autocomplete = formats[2] === "url" ? "url" : "off";
  const configured = entry?.endpoints?.[scheme];
  const endpointText = Array.isArray(configured) ? configured.join(" · ") : configured;
  const details = custom
    ? `${formats[3]} Проверка покажет, подтвердился ли защищённый upstream.`
    : `${entry?.notes || ""}${endpointText ? ` Endpoint: ${endpointText}.` : ""}${entry?.verified === false ? " Источник endpoint не подтверждён; используйте только если доверяете этому серверу." : ""}`;
  card.querySelector("#dns-protocol-help").textContent = details;
  $app.querySelector("#dns-custom-compatibility").textContent = custom ? formats[3] : "";
}
function splitList(value) { return String(value || "").split(/[\n,]/).map(item => item.trim()).filter(Boolean); }
function mergeProfileBootstrap(values) {
  const area = $app.querySelector("#dns-profile-bootstrap");
  const current = splitList(area.value), next = splitList(values);
  area.value = [...new Set([...current, ...next])].join("\n");
}
function profileItemFor(endpoint, protocol, entry = null, extra = {}) {
  const name = entry?.name || "Свой endpoint";
  let host = "";
  try { host = new URL(endpoint.replace(/^(h3|tls|quic):\/\//, "https://")).hostname; } catch (_) { }
  const itemName = entry?.id === "default" && host ? `${name} — ${host}` : extra.custom && host ? `Свой endpoint — ${host}` : name;
  return { endpoint, protocol, name: itemName, provider: entry?.id || (extra.custom ? "custom" : "unknown"), category: entry?.category || "universal", verified: entry?.verified !== false };
}
function renderProfileQueue() {
  const host = $app.querySelector("#dns-profile-queue");
  const group = (title, role, items) => `<section class="dns-profile-group"><h3>${title} <span>${items.length}</span></h3>${items.length ? `<ul>${items.map((item, index) => `<li><div><strong>${escapeHtml(item.name)}</strong><span>${escapeHtml(DNS_PROTOCOL_LABELS[item.protocol] || item.protocol)} · ${escapeHtml(item.endpoint)}</span></div><button class="btn btn-secondary" type="button" data-profile-remove="${role}" data-profile-index="${index}" aria-label="Удалить ${escapeHtml(item.name)}">Удалить</button></li>`).join("")}</ul>` : '<p class="desc">Серверы не добавлены.</p>'}</section>`;
  host.innerHTML = group("Основные upstream", "upstreams", DNS_PROFILE.upstreams) + group("Аварийный fallback", "fallbacks", DNS_PROFILE.fallbacks);
  const options = $app.querySelector("#dns-route-upstream");
  options.replaceChildren();
  for (const [role, items] of [["upstreams", DNS_PROFILE.upstreams], ["fallbacks", DNS_PROFILE.fallbacks]]) {
    items.forEach((item, index) => {
      const option = document.createElement("option"); option.value = `${role}:${index}`;
      option.textContent = `${role === "upstreams" ? "Основной" : "Fallback"}: ${item.name} (${DNS_PROTOCOL_LABELS[item.protocol] || item.protocol})`;
      options.append(option);
    });
  }
  if (!options.options.length) { const option = document.createElement("option"); option.value = ""; option.textContent = "Сначала добавьте upstream"; options.append(option); }
  $app.querySelector("#dns-profile-rules-list").innerHTML = DNS_PROFILE.routes.length
    ? `<ul>${DNS_PROFILE.routes.map((route, index) => `<li><span><strong>${escapeHtml(route.domain)}</strong> → ${escapeHtml(route.endpoint)}</span><button class="btn btn-secondary" type="button" data-route-remove="${index}" aria-label="Удалить правило для ${escapeHtml(route.domain)}">Удалить</button></li>`).join("")}</ul>`
    : '<p class="desc">Правила не добавлены.</p>';
  renderProfileWarnings();
}
function renderProfileWarnings() {
  const box = $app.querySelector("#dns-profile-warning");
  const entries = [...DNS_PROFILE.upstreams, ...DNS_PROFILE.fallbacks];
  const categories = new Set(entries.map(item => item.category));
  const unverified = entries.some(item => !item.verified);
  const regional = entries.some(item => item.category === "regional");
  const mixed = categories.size > 1;
  dnsProfileWarningRequired = Boolean(unverified || regional || mixed);
  const notes = ["Незашифрованный fallback отключён. Bootstrap задаётся глобально для всех upstream."];
  if (regional) notes.push("Smart DNS и региональные серверы могут возвращать адреса прокси вместо обычных адресов сайта.");
  if (mixed) notes.push("В профиле смешаны разные политики; балансировка может дать разные ответы на один домен. Для разделения используйте доменные правила.");
  if (unverified) notes.push("Есть endpoint без подтверждённого официального источника; проверьте адрес до применения.");
  box.innerHTML = `${notes.map(note => `<p>${escapeHtml(note)}</p>`).join("")}${dnsProfileWarningRequired ? '<label class="dns-profile-ack"><input type="checkbox" id="dns-profile-ack"> Я проверил предупреждение и осознанно применяю этот набор серверов</label>' : ""}`;
}
function catalogItemByEndpoint(endpoint, protocol) {
  return DNS_PROVIDER_CATALOG.find(entry => {
    const configured = entry.endpoints?.[protocol];
    if (configured === endpoint || (Array.isArray(configured) && configured.includes(endpoint))) return true;
    if (typeof configured !== "string" || !configured.includes("{profile_id}")) return false;
    const [prefix, suffix] = configured.split("{profile_id}");
    const profile = endpoint.slice(prefix.length, endpoint.length - suffix.length);
    return endpoint.startsWith(prefix) && endpoint.endsWith(suffix) && /^[a-z0-9-]{1,63}$/i.test(profile);
  }) || null;
}
function decodeProfileList(value) {
  if (!value) return [];
  try { return atob(value).split("\n").map(item => item.trim()).filter(Boolean); } catch (_) { return []; }
}
function syncProfileFromStatus(status) {
  if (DNS_PROFILE.touched) return;
  let upstreams = decodeProfileList(status.profile_upstreams_b64);
  let fallbacks = decodeProfileList(status.profile_fallbacks_b64);
  let routes = decodeProfileList(status.profile_routes_b64);
  if (!upstreams.length && status.endpoint) {
    const legacyEntry = DNS_PROVIDER_CATALOG.find(entry => entry.id === status.provider);
    const configured = status.provider === "custom" ? [status.endpoint] : legacyEntry?.endpoints?.[status.protocol];
    upstreams = (Array.isArray(configured) ? configured : configured ? [configured] : [status.endpoint]).filter(Boolean);
    if (status.bootstrap) $app.querySelector("#dns-profile-bootstrap").value = splitList(status.bootstrap).join("\n");
  }
  const protocolOf = endpoint => {
    if (/^h3:\/\//.test(endpoint)) return "doh3";
    if (/^tls:\/\//.test(endpoint)) return "dot";
    if (/^quic:\/\//.test(endpoint)) return "doq";
    if (/^sdns:\/\//.test(endpoint)) return "dnscrypt";
    return "doh";
  };
  DNS_PROFILE.upstreams = upstreams.map(endpoint => { const protocol = protocolOf(endpoint); return profileItemFor(endpoint, protocol, catalogItemByEndpoint(endpoint, protocol), {custom: status.provider === "custom"}); });
  const nextdnsItem = DNS_PROFILE.upstreams.find(item => item.provider === "nextdns");
  if (nextdnsItem) {
    const configured = DNS_PROVIDER_CATALOG.find(entry => entry.id === "nextdns")?.endpoints?.[nextdnsItem.protocol];
    const [prefix, suffix] = String(configured || "").split("{profile_id}");
    if (configured?.includes("{profile_id}")) $app.querySelector("#dns-nextdns-profile").value = nextdnsItem.endpoint.slice(prefix.length, nextdnsItem.endpoint.length - suffix.length);
  }
  DNS_PROFILE.fallbacks = fallbacks.map(endpoint => { const protocol = protocolOf(endpoint); return profileItemFor(endpoint, protocol, catalogItemByEndpoint(endpoint, protocol)); });
  DNS_PROFILE.routes = routes.map(line => { const divider = line.indexOf("="); const domain = line.slice(0, divider); const endpoint = line.slice(divider + 1); return {domain, endpoint}; }).filter(route => route.domain && route.endpoint);
  const savedBootstrap = decodeProfileList(status.profile_bootstrap_b64);
  if (savedBootstrap.length) $app.querySelector("#dns-profile-bootstrap").value = savedBootstrap.join("\n");
  if (status.profile_mode && ["load_balance", "parallel", "fastest_addr"].includes(status.profile_mode)) $app.querySelector("#dns-upstream-mode").value = status.profile_mode;
  if (!DNS_PROFILE.touched) {
    renderProfileQueue();
    if (DNS_PROFILE.upstreams.length) {
      const first = DNS_PROFILE.upstreams[0];
      const provider = cardProviderFor(first);
      if (provider) $app.querySelector("#doh-provider").value = provider;
      $app.querySelector("#dns-protocol").value = first.protocol;
    }
  }
}
function cardProviderFor(item) { return item.provider !== "unknown" && item.provider !== "custom" ? item.provider : item.provider === "custom" ? "custom" : ""; }
function addSelectedUpstream() {
  const provider = $app.querySelector("#doh-provider").value;
  const protocol = $app.querySelector("#dns-protocol").value;
  const custom = provider === "custom";
  const entry = selectedCatalogEntry(provider);
  let endpoints = custom ? [$app.querySelector("#doh-endpoint").value.trim()] : entry?.endpoints?.[protocol];
  if (provider === "nextdns") {
    const profile = $app.querySelector("#dns-nextdns-profile").value.trim();
    if (!/^[a-z0-9-]{1,63}$/i.test(profile)) { toast("Введите ID профиля NextDNS (буквы, цифры и дефис).", "bad"); return; }
    endpoints = [endpoints.replace("{profile_id}", profile)];
  }
  const list = Array.isArray(endpoints) ? endpoints : endpoints ? [endpoints] : [];
  if (!list.length) { toast("Для выбранного провайдера нет подтверждённого endpoint этого протокола.", "bad"); return; }
  if (custom) {
    const invalid = validateCustomEndpoint(protocol, list[0]);
    if (invalid) { toast(invalid, "bad"); return; }
  }
  const role = $app.querySelector("#doh-upstream-role").value === "fallback" ? "fallbacks" : "upstreams";
  const target = DNS_PROFILE[role];
  for (const endpoint of list) {
    if ([...DNS_PROFILE.upstreams, ...DNS_PROFILE.fallbacks].some(item => item.endpoint === endpoint)) continue;
    target.push(profileItemFor(endpoint, protocol, entry, {custom}));
  }
  if (custom) mergeProfileBootstrap($app.querySelector("#doh-bootstrap").value);
  DNS_PROFILE.touched = true;
  renderProfileQueue();
}
function addDomainRoute() {
  const domainInput = $app.querySelector("#dns-route-domain"), domain = domainInput.value.trim().toLowerCase();
  const target = $app.querySelector("#dns-route-upstream").value;
  if (!/^(?:[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\.)*[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?$/.test(domain)) { toast("Введите корректный домен, например example.com.", "bad"); return; }
  const [role, indexText] = target.split(":"); const item = DNS_PROFILE[role]?.[Number(indexText)];
  if (!item) { toast("Сначала добавьте основной upstream или fallback.", "bad"); return; }
  if (DNS_PROFILE.routes.some(route => route.domain === domain)) { toast("Для этого домена правило уже есть.", "bad"); return; }
  DNS_PROFILE.routes.push({domain, endpoint:item.endpoint}); DNS_PROFILE.touched = true; domainInput.value = ""; renderProfileQueue();
}
function validateCustomEndpoint(protocol, endpoint) {
  const schemes = {doh:"https://", doh3:"h3://", dot:"tls://", doq:"quic://", dnscrypt:"sdns://"};
  if (!endpoint.startsWith(schemes[protocol] || "https://")) return `Для ${DNS_PROTOCOL_LABELS[protocol] || "DNS"} нужен endpoint с префиксом ${schemes[protocol] || "https://"}`;
  if (protocol === "dnscrypt" && endpoint.length <= "sdns://".length) return "Укажите DNSCrypt stamp целиком";
  if (["doh", "doh3", "dot", "doq"].includes(protocol)) {
    try { const url = new URL(endpoint.replace(/^(h3|tls|quic):\/\//, "https://")); if (!url.hostname) throw new Error(); }
    catch (_) { return "Укажите корректный endpoint с именем сервера"; }
  }
  return "";
}
function renderDohStatus(status, syncControls = false) {
  const card = $app.querySelector("#doh-card");
  const line = card.querySelector("#doh-status"), actions = card.querySelector("#doh-actions");
  const protocolSelect = card.querySelector("#dns-protocol");
  const providerSelect = card.querySelector("#doh-provider");
  syncProfileFromStatus(status || {});
  let provider = status && status.provider || "xbox";
  if (provider === "unknown" || provider === "profile") provider = DNS_PROFILE.upstreams[0]?.provider || "xbox";
  if (syncControls) {
    providerSelect.value = [...providerSelect.options].some(option => option.value === provider) ? provider : "xbox";
    protocolSelect.value = ["doh", "doh3", "dot", "doq", "dnscrypt"].includes(status && status.protocol) ? status.protocol : DNS_PROFILE.upstreams[0]?.protocol || "doh";
    $app.querySelector("#doh-endpoint").value = status && status.provider === "custom" ? status.endpoint || "" : "";
    $app.querySelector("#doh-bootstrap").value = status && status.provider === "custom" ? status.bootstrap || "" : "";
  }
  updateDnsProtocolUi(card, providerSelect.value);
  const state = status && status.state || "error", installed = status && status.installed === "1";
  const externallyManaged = status && status.external_config === "1";
  card.querySelector("#doh-ownership-warning").hidden = !installed || !externallyManaged;
  if (!card.querySelector("#doh-ownership-warning").hidden) card.querySelector("#doh-ownership-warning").textContent = "Найдена пользовательская конфигурация dnsproxy. При применении она будет сохранена для восстановления после удаления.";
  card.dataset.confirmRemove = installed && (externallyManaged || status && status.confirm_remove === "1") ? "1" : "0";
  renderDnsAdapterDetails(status || {});
  if (state === "not-installed" || !installed) {
    line.dataset.state = "not-installed"; line.textContent = "Статус: Не установлен";
    if (actions.dataset.actionSet !== "install") { actions.innerHTML = '<button class="btn btn-primary" data-doh-action="install">Установить</button>'; actions.dataset.actionSet = "install"; }
    return;
  }
  const label = state === "working" || state === "healthy" ? "Работает" : state === "disabled" || state === "installed-disabled" ? "Выключен" : "Ошибка";
  line.dataset.state = label === "Работает" ? "working" : label === "Ошибка" ? "error" : "disabled";
  const protocol = {doh:"DoH", doh3:"DoH3", dot:"DoT", doq:"DoQ", dnscrypt:"DNSCrypt"}[status && status.protocol] || "не выбран";
  const local = status && status.local_dns_state === "working" ? "ответы DNS подтверждены" : status && status.local_dns_state === "failed" ? "ответы DNS не проходят" : "ответ DNS не проверен";
  const actualProtocol = {doh:"DoH", doh3:"DoH3", dot:"DoT", doq:"DoQ", dnscrypt:"DNSCrypt"}[status && status.actual_protocol] || "не подтверждён";
  const upstream = status && status.upstream_state === "confirmed" ? `подтверждён · фактически: ${actualProtocol}` : status && status.upstream_state === "failed" ? "проверка завершилась ошибкой" : "не подтверждён";
  line.innerHTML = `Статус: ${escapeHtml(label)}${label === "Ошибка" ? ` · ${escapeHtml(dohReasonLabel(status && status.reason))}` : ""}<br>DNS роутера: ${escapeHtml(local)}<br>Выбранный протокол: ${escapeHtml(protocol)}<br>Защищённый upstream: ${escapeHtml(upstream)}`;
  if (actions.dataset.actionSet !== "manage") { actions.innerHTML = '<button class="btn btn-primary" data-doh-action="apply">Применить</button><button class="btn btn-secondary" data-doh-action="check">Проверить</button><button class="btn btn-secondary" data-doh-service-toggle hidden></button><button class="btn btn-danger" data-doh-action="uninstall">Удалить</button>'; actions.dataset.actionSet = "manage"; }
  const service = actions.querySelector("[data-doh-service-toggle]"), stop = status && (status.enabled === "1" || status.running === "1"), canStart = Boolean(status && status.endpoint);
  service.hidden = !stop && !canStart;
  if (!service.hidden) { service.dataset.dohAction = stop ? "disable" : "enable"; service.textContent = stop ? "Остановить" : "Запустить"; }
  else delete service.dataset.dohAction;
}
function wireDohCard() {
  const card = $app.querySelector("#doh-card");
  populateProviderCatalog(card.querySelector("#doh-provider"));
  $app.querySelector("#dns-profile-bootstrap").value = DNS_DEFAULT_BOOTSTRAP.join("\n");
  card.addEventListener("click", event => { const button = event.target.closest("[data-doh-action]"); if (button) runDohAction(button.dataset.dohAction); });
  $app.querySelector("#dns-recovery-actions").addEventListener("click", event => { const button = event.target.closest("[data-doh-action]"); if (button) runDohAction(button.dataset.dohAction); });
  $app.querySelector("#dns-cache-controls").addEventListener("click", event => { const button = event.target.closest("[data-doh-action]"); if (button) runDohAction(button.dataset.dohAction); });
  $app.querySelector("#dns-redirect-controls").addEventListener("click", event => { const button = event.target.closest("[data-doh-action]"); if (button) runDohAction(button.dataset.dohAction); });
  $app.querySelector("#dns-adapter-diagnostics").addEventListener("click", event => { const button = event.target.closest("[data-doh-action]"); if (button) runDohAction(button.dataset.dohAction); });
  const provider = card.querySelector("#doh-provider");
  provider.addEventListener("change", () => updateDnsProtocolUi(card, provider.value));
  card.querySelector("#dns-protocol").addEventListener("change", () => updateDnsProtocolUi(card, provider.value));
  card.querySelector("#doh-add-upstream").addEventListener("click", addSelectedUpstream);
  card.querySelector("#dns-route-add").addEventListener("click", addDomainRoute);
  $app.querySelector("#dns-profile-queue").addEventListener("click", event => {
    const button = event.target.closest("[data-profile-remove]"); if (!button) return;
    DNS_PROFILE[button.dataset.profileRemove].splice(Number(button.dataset.profileIndex), 1);
    DNS_PROFILE.touched = true; renderProfileQueue();
  });
  $app.querySelector("#dns-profile-rules-list").addEventListener("click", event => {
    const button = event.target.closest("[data-route-remove]"); if (!button) return;
    DNS_PROFILE.routes.splice(Number(button.dataset.routeRemove), 1); DNS_PROFILE.touched = true; renderProfileQueue();
  });
}
async function runDohAction(action) {
  const card = $app.querySelector("#doh-card");
  const specs = {install:["/doh/install","Установка DNS"],uninstall:["/doh/uninstall","Удаление DNS"],check:["/doh/check","Проверка DNS"],apply:["/doh/profile","Применение DNS профиля"],enable:["/doh/enable","Запуск DNS"],disable:["/doh/disable","Остановка DNS"],settings:["/doh/settings","Настройка кэша DNS"],redirect:["/doh/force-dns","Настройка IPv4 DNS redirect"],diagnostics:["/doh/diagnostics","Диагностика DNS"],recover:["/doh/recover","Восстановление DNS"]};
  const spec = specs[action]; if (!spec || !card || card.hidden) return;
  const warning = card.querySelector("#doh-ownership-warning").hidden === false;
  if (action === "apply" && dnsProfileWarningRequired && !$app.querySelector("#dns-profile-ack")?.checked) { toast("Подтвердите предупреждение о совместимости профиля перед применением.", "bad"); return; }
  if (action === "apply" && warning && !window.confirm("Обнаружена пользовательская конфигурация dnsproxy. Она будет сохранена и заменена выбранным DNS профилем. При удалении DNS исходная конфигурация восстановится. Продолжить?")) return;
  if (action === "uninstall" && card.dataset.confirmRemove === "1" && !window.confirm("dnsproxy или его конфигурация были установлены до управления z2kOW. Конфигурация будет сохранена для последующего восстановления, но пакет и работающий DNS будут удалены. Продолжить?")) return;
  const buttons = [...$app.querySelectorAll("[data-doh-action]")]; buttons.forEach(button => button.disabled = true);
  let body;
  if (action === "apply") {
    if (!DNS_PROFILE.upstreams.length) { toast("Добавьте хотя бы один основной upstream.", "bad"); buttons.forEach(button => button.disabled = false); return; }
    body = {upstreams: DNS_PROFILE.upstreams.map(item => item.endpoint).join("\n"), fallbacks: DNS_PROFILE.fallbacks.map(item => item.endpoint).join("\n"), routes: DNS_PROFILE.routes.map(item => `${item.domain}=${item.endpoint}`).join("\n"), mode: $app.querySelector("#dns-upstream-mode").value, bootstrap: splitList($app.querySelector("#dns-profile-bootstrap").value).join("\n")};
    if (warning) body.replace = "1";
  } else if (action === "uninstall") body = {confirm: card.dataset.confirmRemove === "1" ? "1" : "0"};
  else if (action === "settings") {
    const cacheSize = Number($app.querySelector("#dns-cache-size").value);
    if (!Number.isInteger(cacheSize) || cacheSize < 4096 || cacheSize > 1048576) {
      toast("Размер кэша должен быть от 4096 до 1048576 байт.", "bad");
      buttons.forEach(button => button.disabled = false);
      return;
    }
    body = {cache_enabled: $app.querySelector("#dns-cache-enabled").value, cache_size: String(cacheSize)};
  } else if (action === "redirect") body = {value: $app.querySelector("#dns-force-redirect").value};
  try {
    const response = action === "diagnostics" ? await apiGet(spec[0]) : await apiPost(spec[0], body);
    const done = async () => { buttons.forEach(button => { if (button.isConnected) button.disabled = false; }); await refreshDnsStatus(); };
    if (response && response.job) openJobModal(spec[1], response.job, {onDone: done});
    else { toast(spec[1] + " — готово"); await done(); }
  } catch (error) { buttons.forEach(button => { if (button.isConnected) button.disabled = false; }); toastErr("Ошибка: ", error); }
}
async function refreshDnsStatus() {
  if (!document.getElementById("doh-card")) return;
  try { const state = await apiGet("/status"); if (document.getElementById("doh-card")) renderDohStatus(state.doh, false); }
  catch (error) { toastErr("Не удалось обновить состояние DNS: ", error); }
}
function renderDnsAdapterDetails(status) {
  const box = $app.querySelector("#dns-adapter-diagnostics"), recovery = $app.querySelector("#dns-recovery-actions"), note = $app.querySelector("#dns-recovery-note");
  if (!box || !recovery || !note) return;
  const process = status.proxy === "available" ? "работает" : status.proxy === "unavailable" ? "не работает / не установлен" : "нет данных";
  const route = status.dnsmasq === "available" ? "dnsmasq направляет запросы в локальный dnsproxy" : status.dnsmasq === "route-missing" ? "маршрут в dnsproxy не подтверждён" : "нет данных";
  const force = status.force_lan_dns === "1" ? "включён" : status.force_lan_dns === "0" ? "выключен" : "не предоставлен адаптером";
  const redirectState = {active:"активен", disabled:"выключен", drift:"правило изменено вручную", "unowned-conflict":"обнаружен чужой конфликт"}[status.redirect_state] || "нет данных";
  const family = status.upstream_family === "unsupported" ? "выбор IPv4/IPv6 upstream не поддерживается" : "не сообщён адаптером";
  const owner = status.package_owner === "external" ? "внешний пакет; удаление требует подтверждения" : status.package_owner === "z2kow" ? "под управлением z2kOW" : "не установлен / неизвестен";
  const config = status.external_config === "1" ? "внешняя конфигурация сохранится при применении" : status.confirm_remove === "1" ? "снимок конфигурации восстановится при удалении" : "изменения управляются z2kOW";
  box.innerHTML = `<h3>Состояние адаптера</h3><dl class="dns-adapter-status"><dt>dnsproxy</dt><dd>${escapeHtml(process)}</dd><dt>DNS-маршрут LAN</dt><dd>${escapeHtml(route)}</dd><dt>Upstream family</dt><dd>${escapeHtml(family)}</dd><dt>Принудительный IPv4 redirect</dt><dd>${escapeHtml(force)} · ${escapeHtml(redirectState)}</dd><dt>Владение пакетом</dt><dd>${escapeHtml(owner)}</dd><dt>Конфигурация</dt><dd>${escapeHtml(config)}</dd></dl>${status.installed === "1" ? '<button class="btn btn-secondary" data-doh-action="diagnostics">Собрать диагностику DNS</button>' : ""}`;
  const cache = $app.querySelector("#dns-cache-controls");
  const cacheSupported = status.cache_enabled === "0" || status.cache_enabled === "1";
  cache.hidden = !cacheSupported;
  if (cacheSupported) {
    $app.querySelector("#dns-cache-enabled").value = status.cache_enabled;
    $app.querySelector("#dns-cache-size").value = status.cache_size || "65535";
    $app.querySelector("#dns-cache-save").disabled = status.installed !== "1";
  }
  const redirect = $app.querySelector("#dns-redirect-controls");
  const redirectSupported = (status.force_lan_dns === "0" || status.force_lan_dns === "1") && status.installed === "1";
  redirect.hidden = !redirectSupported;
  if (redirectSupported) {
    $app.querySelector("#dns-force-redirect").value = status.force_lan_dns;
    $app.querySelector("#dns-redirect-state").textContent = `Правило: ${redirectState}; снимок для восстановления: ${status.redirect_snapshot === "1" ? "есть" : status.redirect_snapshot === "0" ? "нет" : "нет данных"}.`;
    $app.querySelector("#dns-redirect-save").disabled = status.redirect_state === "unowned-conflict";
  }
  const routeSnapshot = status.route_snapshot === "1";
  recovery.innerHTML = routeSnapshot ? '<button class="btn btn-secondary" data-doh-action="recover">Проверить и восстановить DNS-маршрут</button>' : "";
  if (status.confirm_remove === "1" || status.external_config === "1") {
    note.textContent = "Сохранённая пользовательская конфигурация dnsproxy восстанавливается существующей командой «Удалить» после подтверждения.";
  } else if (routeSnapshot) {
    note.textContent = "Снимок маршрута dnsmasq сохранён. Восстановление проверит dnsproxy и вернёт сохранённый DNS-маршрут.";
  } else if (status.migration_available === "1") {
    note.textContent = "Обнаружены сохранённые параметры прежней DNS-конфигурации; адаптер управляет их переносом и восстановлением.";
  } else {
    note.textContent = "Снимок прежнего DNS-маршрута пока не создан. Он сохраняется при первом включении dnsproxy.";
  }
}
// ---- проверка DNS -----------------------------------------------------------
//
// Раскладка «сначала вывод»: крупная строка о том, что происходит, под ней три
// группы — работают / подменяют / молчат. Человек приходит сюда с вопросом
// «что мне делать», а не «покажи таблицу»; цифры доступны, но не первыми.

// ГРУППИРУЕМ ПО ПУТИ, А НЕ ПО СЕРВЕРУ.
//
// Сначала группы были «доходят целыми / ответы подменяются», то есть про
// сервер, а состояние в строке — про путь. Quad9 с подменённым обычным ответом
// и целым DoH попадал в «доходят целыми», и заголовок спорил с собственным
// содержимым: «доходят целыми» напротив «ответ подменён».
//
// Спорить нечему, когда группа и строка говорят об одном. Путь — это и есть
// то, что проверяется и что человек меняет: обычный DNS отравлен, шифрованный
// цел, и вывод «включите DoH» читается прямо из структуры, а не из сносок.

const DNS_STATE = {
  works: { cls: "good", label: "честно" },
  spoof: { cls: "bad", label: "ответ подменён" },
  // «Умный» DNS (xbox-dns.ru и подобные): на каждый сайт свой прокси-адрес,
  // заглушки нет, и без этого состояния он выглядел бы честным.
  proxy: { cls: "bad", label: "свой прокси вместо сайта" },
  // Порт 53 завёрнут (роутером или кем-то на пути): отвечает не этот сервер,
  // и оценивать его ответ бессмысленно — иначе вся таблица ходила бы вслед за
  // DNS самого роутера.
  hijack: { cls: "warn", label: "перехвачено на пути" },
  silent: { cls: "warn", label: "не ответил" },
};

function dnsPathGroup(title, sub, list, openIt) {
  if (!list.length) return "";
  const bad = list.filter(x => x.state === "spoof" || x.state === "proxy").length;
  const mute = list.filter(x => x.state === "silent").length;
  const ok = list.filter(x => x.state === "works").length;

  // Состояние группы — по её содержимому: если целых нет вовсе, путь мёртв.
  const cls = ok === 0 ? (bad ? "bad" : "warn") : bad ? "bad" : "good";
  const tally = [
    ok ? `${ok} целых` : "",
    bad ? `${bad} подменено` : "",
    mute ? `${mute} без ответа` : "",
  ].filter(Boolean).join(" · ");

  const rows = list.map(x => {
    const st = DNS_STATE[x.state] || DNS_STATE.silent;
    const ms = x.ms != null ? ` <span class="dns-metric">${x.ms} мс</span>` : "";
    const tag = x.current ? ` <span class="dns-cur">используется сейчас</span>` : "";
    // Отдельная пометка: сервер жив и честен, но адреса для ютуба не даёт.
    // Снаружи это выглядит как «интернет есть, а видео не открывается», и по
    // состоянию пути такое не видно — путь-то в порядке.
    const yt = x.yt === "empty" ? ` <span class="dns-yt">нет адреса для youtube.com</span>` : "";
    return `<li>
      <span>${escapeHtml(x.name)}${tag}${yt}</span>
      <span class="dns-state dns-${st.cls}">${st.label}${ms}</span>
    </li>`;
  }).join("");

  return `
    <details class="dns-group"${openIt ? " open" : ""}>
      <summary>
        <span class="dns-path">${escapeHtml(title)}</span>
        <span class="dns-count">${escapeHtml(sub)}</span>
        <span class="dns-tally dns-${cls}">${escapeHtml(tally)}</span>
      </summary>
      <ul>${rows}</ul>
    </details>`;
}

function renderDnsResult(d) {
  const host = document.getElementById("dns-result");
  if (!host) return;
  if (!d) {
    host.innerHTML = `<p class="desc" style="margin-top:12px">Проверка ещё не запускалась.</p>`;
    return;
  }
  const srv = d.servers || [];
  // У обычного DNS время появилось: его печатает dig, если он установлен
  // (пакет bind-dig, ставится отдельно). Нет dig — приходит null, и строка
  // выглядит как раньше, без числа. Своими руками UDP-запрос с роутера не
  // послать, а время nslookup врёт на порядок: он делает обратный запрос на
  // каждый адрес ответа.
  const plain = srv.filter(s => s.udp !== "none").map(s => ({ name: s.name, state: s.udp, ms: s.udp_ms, current: s.current, yt: s.yt }));
  const doh = srv.filter(s => s.doh !== "none").map(s => ({ name: s.name, state: s.doh, ms: s.doh_ms, current: s.current, yt: s.yt }));
  // У DoT время ЕСТЬ: счётчик опросов с шагом 10 мс меряет полный обмен —
  // TCP, TLS и сам запрос. Раньше здесь стоял null, потому что я счёл
  // измерение невозможным; невозможен был только посекундный опрос.
  const dot = srv.filter(s => s.dot !== "none").map(s => ({ name: s.name, state: s.dot, ms: s.dot_ms, current: s.current, yt: s.yt }));

  // Сводного блока здесь БОЛЬШЕ НЕТ, и это снятие, а не пропажа.
  //
  // Он повторял то, что и так стоит в заголовках групп: сколько путей целы,
  // сколько подменено. Свой резолвер помечен прямо в строке, ютуб — ярлыком у
  // имени. Единственный факт, которого больше нигде не было, — адрес заглушки;
  // он переехал в подпись группы обычного DNS, где и объясняет её состояние.
  const who = d.intercept_by === "router" ? "роутером (перехват DNS прошивки)" : "на пути к серверам";
  const stubTail = d.stub ? ` · заглушка ${escapeHtml(d.stub)}` : "";
  const stubNote = (d.intercept ? `порт 53 завёрнут ${who} — ответы не от серверов` : "порт 53, без шифрования") + stubTail;
  host.innerHTML = `
    ${dnsPathGroup("Обычный DNS", stubNote, plain, false)}
    ${dnsPathGroup("Шифрованный DoH", "запрос внутри HTTPS", doh, false)}
    ${dnsPathGroup("Шифрованный DoT", "запрос внутри TLS, порт 853", dot, false)}`;
}

async function loadDnsLast() {
  const seq = _newLoad("dnsCheck");
  let d;
  try {
    d = await apiGet("/dns/check");
  } catch (e) {
    return;
  }
  if (_stale("dnsCheck", seq)) return;
  const ta = document.getElementById("dns-own-text");
  if (ta && typeof d.own === "string") ta.value = d.own;
  renderDnsResult(d.result);
}

async function dnsRun() {
  const btn = document.getElementById("dns-run");
  btn.disabled = true;
  let resp;
  try {
    resp = await apiPost("/dns/check", {});
  } catch (e) {
    btn.disabled = false;
    toastErr("Не удалось запустить проверку: ", e);
    return;
  }
  openJobModal("Проверяю серверы имён", resp.job, {
    onDone: (d) => {
      btn.disabled = false;
      const outcome = jobOutcome(d);
      if (outcome === JOB_FAIL) toast("Проверка не прошла — причина в логе выше", "bad");
      else if (jobUnresolved(outcome)) {
        const m = unresolvedMsg(outcome);
        if (m) toast(m, "bad");
        awaitPanelBack().then(() => loadDnsLast());
        return;
      }
      loadDnsLast();
    },
  });
}

async function dnsOwnSave() {
  const btn = document.getElementById("dns-own-save");
  const ta = document.getElementById("dns-own-text");
  btn.disabled = true;
  try {
    const r = await apiPostText("/dns/own", ta.value);
    toast("Сохранено");
    if (r && r.saved) {
      const dropped = /dropped=(\d+)/.exec(r.saved);
      if (dropped && dropped[1] !== "0") toast(`Строк отброшено: ${dropped[1]} — не адрес и не ссылка`, "bad");
    }
  } catch (e) {
    toastErr("Не сохранилось: ", e);
  } finally {
    btn.disabled = false;
  }
}
