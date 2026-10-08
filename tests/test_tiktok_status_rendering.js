const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = path.join(__dirname, "..", "webpanel", "www", "js", "pages", "toggles.js");
const source = fs.readFileSync(sourcePath, "utf8")
  .replace(/^import .*;\s*$/gm, "")
  .replace(/^export /gm, "");
const context = vm.createContext({
  $app: {},
  escapeHtml: value => String(value).replace(/[&<>"']/g, ch => ({
    "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;", "'": "&#39;",
  })[ch]),
  humanAgo: (seconds, now) => Number(seconds) === 1791144948 ? "48 с назад" : "3 мин назад",
});

vm.runInContext(source, context, { filename: sourcePath });
context.fixture = {
  state: "healthy",
  candidate_verified: "1",
  dns_override_applied: "1",
  selected_ip: "203.0.113.35",
  selected_source_domain: "v16-cla.tiktokcdn.com",
  selected_cname: "edge.example.net",
  selected_mode: "mixed",
  selected_provenance: "resolver+tls",
  latency_ms: "131",
  http_status: "400",
  last_verified_epoch: "1791145000",
  selected_at_epoch: "1791144948",
  reason: "healthy",
  last_failover_epoch: "1791144900",
  last_failover_from: "203.0.113.8",
  last_failover_to: "203.0.113.35",
  last_failover_reason: "material-latency-improvement",
  mode: "manual",
  manual_ip: "203.0.113.35",
  candidate_pool: "203.0.113.35|v77.tiktokcdn.com,v77.tiktokcdn-eu.com|direct,check-host|1.1.1.1|system-wan,check-host|edge.example.net|Amsterdam|mixed|1|0|0|8|4|8|ru1,de1,fr1|NL,DE,FR,US|AS1,AS2,AS3,AS4|Amsterdam,Berlin|300,120;203.0.113.35|v16-cla.tiktokcdn.com|cla|8.8.8.8|provider-catalog|edge.example.net|Amsterdam|mixed|1|1|0|0|0|0|||||;203.0.113.20|v77.tiktokcdn.com,v77.tiktokcdn-eu.com|direct|1.1.1.1|system-wan||Frankfurt|domain-resolution|1|0|0|0|0|0|||||;203.0.113.8|v77.tiktokcdn.com|direct|1.1.1.1|system-wan||Frankfurt|curated|0|1|0|0|0|0|||||",
  probe_observations: "203.0.113.35|131|20|30|400|ams|HIT|edge|ok|ok|verified|117|19|27|400|fra|HIT|edge|ok|ok|verified|compatible|23;203.0.113.20|71|15|25|200|fra|HIT|edge|ok|ok|verified|69|14|24|200|fra|HIT|edge|ok|ok|verified|compatible|8;203.0.113.8||0|0|||edge|failed|failed|failed||||||||||||incompatible|",
};

const markup = vm.runInContext("tiktokStatusMarkup(fixture)", context);
const summary = markup.split('<div class="tiktok-candidate-controls"', 1)[0];
const summaryText = summary.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");

assert.equal((summary.match(/131 мс/g) || []).length, 1,
  "the primary summary shows the formatted latency exactly once");
assert.doesNotMatch(summaryText, /131 мс\s+131/,
  "the formatted latency is not followed by its raw numeric duplicate");
assert.doesNotMatch(summary, /material-latency-improvement/,
  "raw failover reason codes stay out of the user-facing summary");
assert.match(summaryText, /Текущий CDN выбран вручную 48 с назад/,
  "the primary summary describes when the current manual selection was made");
assert.doesNotMatch(summaryText, /CDN переключён|203\.0\.113\.8 → 203\.0\.113\.35/,
  "a manual selection never presents an old failover as the current event");
const diagnostics = markup.slice(markup.indexOf('<details class="flow-technical'));
assert.match(diagnostics, /Последнее автоматическое переключение[\s\S]*203\.0\.113\.8 → 203\.0\.113\.35/,
  "the old failover route remains available in technical diagnostics");
assert.match(diagnostics, /raw: material-latency-improvement/,
  "the raw failover reason remains available in technical diagnostics");
assert.match(diagnostics, /HTTP-ответ<\/span><span class="flow-fact-value"><span>400/,
  "an HTTP 400 is shown neutrally as a diagnostic response");
assert.match(markup, /data-tiktok-action="policy"[^>]*data-policy="auto"/,
  "each CDN hostname exposes its automatic policy directly");
assert.match(markup, /data-policy="preferred"[\s\S]*data-policy="strict"/,
  "the domain policy controls expose preferred-with-fallback and strict modes");
for (const host of ["v77.tiktokcdn.com", "v77.tiktokcdn-eu.com", "v16-cla.tiktokcdn.com", "v16-ies-music.tiktokcdn.com", "sf16-music.tiktokcdn-eu.com"]) {
  assert.match(markup, new RegExp(host.replace(/[.-]/g, "[.-]")), `the status card includes ${host}`);
}
assert.match(markup, /Видео <b>не проверено<\/b>/,
  "the interface never claims a successful media fetch from a transport probe");
assert.match(summaryText, /CDN доступен/,
  "the primary healthy badge describes CDN transport rather than claiming the TikTok feed works");
assert.match(summaryText, /Передача видео и работа ленты не проверены/,
  "the primary healthy status explicitly limits what the transport probe proves");
assert.doesNotMatch(summaryText, /● Работает/,
  "a successful transport probe never labels the TikTok feed as working");
assert.match(markup, /Проверить все/,
  "the card exposes the bounded live candidate scan");
assert.equal((markup.match(/<article class="tiktok-candidate[^"]*" data-ip="203\.0\.113\.35"/g) || []).length, 1,
  "duplicate discovery and curated rows merge into one candidate by IP");
assert.match(markup, /ICMP <b title="Ping не влияет на доступность CDN">23 мс/,
  "available ICMP latency is displayed as informational data");
assert.match(markup, /Check-Host: 8 узлов \/ 4 стран \/ 8 ASN/,
  "candidate rows summarize distributed node, country, and ASN evidence");
const originalFixture = context.fixture;
const noIcmpFixture = { ...originalFixture, mode: "auto", manual_ip: "", selected_ip: "", probe_observations: originalFixture.probe_observations.split(";")[0].split("|").slice(0, 22).join("|") };
context.fixture = noIcmpFixture;
const noIcmpMarkup = vm.runInContext("tiktokStatusMarkup(fixture)", context);
context.fixture = originalFixture;
assert.match(noIcmpMarkup, /ICMP <b title="Ping не влияет на доступность CDN">—<\/b>/,
  "candidates without an ICMP result show a neutral placeholder");
assert.equal((noIcmpMarkup.match(/<button[^>]*data-tiktok-action="select"[^>]*>/g) || []).filter(button => !button.includes("disabled")).length, 1,
  "lack of ICMP does not disable a candidate verified through both TLS probes");
const selectedRow = markup.match(/<article class="tiktok-candidate[^>]*data-ip="203\.0\.113\.35"[\s\S]*?<\/article>/)?.[0] || "";
assert.match(selectedRow, /class="tiktok-candidate[^"]* selected/,
  "the current candidate has an explicit selected visual state");
assert.match(selectedRow, /<summary>Подробнее<\/summary>[\s\S]*v77 <b>✓ 131 мс<\/b>/,
  "target latency details stay behind the per-candidate disclosure");
const selectedRowSummary = selectedRow.split('<details class="tiktok-candidate-details', 1)[0];
assert.doesNotMatch(selectedRowSummary, /TCP 443|TLS\/SNI|HTTP ·|POP \/ сервер/,
  "technical probe fields do not occupy the default candidate row");
assert.equal((markup.match(/<button[^>]*data-tiktok-action="select"[^>]*>/g) || []).filter(button => !button.includes("disabled")).length, 1,
  "only the live-verified candidate has an active select action");
const selectableRow = markup.match(/<article class="tiktok-candidate[^>]*data-ip="203\.0\.113\.20"[\s\S]*?<\/article>/)?.[0] || "";
assert.match(selectableRow, /aria-label="Выбрать CDN 203\.0\.113\.20"/,
  "candidate select buttons expose the IP in their accessible name");
const unavailableRow = markup.match(/<article class="tiktok-candidate[^>]*data-ip="203\.0\.113\.8"[\s\S]*?<\/article>/)?.[0] || "";
assert.doesNotMatch(unavailableRow, /data-tiktok-action="select"/,
  "unavailable candidates do not show a misleading disabled select button");
assert.match(source, /apiPost\(endpoints\[action\], params\)/,
  "candidate actions are sent through the WebPanel API");
for (const section of ["Соединение", "Выбранный узел", "Проверка", "Последнее автоматическое переключение"]) {
  assert.match(diagnostics, new RegExp(`<h4>${section}<\\/h4>`), `diagnostics include the ${section} section`);
}

const autoFixture = { ...originalFixture, mode: "auto", manual_ip: "", selected_at_epoch: "1791144948" };
context.autoFixture = autoFixture;
const autoMarkup = vm.runInContext("tiktokStatusMarkup(autoFixture)", context);
const autoSummary = autoMarkup.split('<div class="tiktok-candidate-controls"', 1)[0];
assert.match(autoSummary, /Текущий CDN выбран автоматически 48 с назад/,
  "automatic selection uses the current selected IP and selected timestamp");
assert.doesNotMatch(autoSummary, /CDN переключён|203\.0\.113\.8 → 203\.0\.113\.35/,
  "an older failover is not shown as the current automatic selection event");

const orderedFixture = {
  ...originalFixture,
  candidate_pool: `${originalFixture.candidate_pool};203.0.113.50|v77.tiktokcdn.com|check-host|1.1.1.1|system-wan||Berlin|check-host|1|1|1|2|2|2`,
  probe_observations: originalFixture.probe_observations,
};
context.orderedFixture = orderedFixture;
const orderedMarkup = vm.runInContext("tiktokStatusMarkup(orderedFixture)", context);
const orderedRows = [...orderedMarkup.matchAll(/<article class="tiktok-candidate[^"]*" data-ip="([^"]+)"/g)].map(match => match[1]);
assert.deepEqual(orderedRows, ["203.0.113.35", "203.0.113.20", "203.0.113.50", "203.0.113.8"],
  "candidates render selected first, working by latency, unchecked next, and unavailable last");
assert.match(orderedMarkup, /4 кандидата · 2 доступны · лучший 71 мс/,
  "the summary counts only probed working candidates and reports the fastest latency");
assert.match(orderedMarkup, /data-tiktok-filter="all"[\s\S]*data-tiktok-filter="working"[\s\S]*data-tiktok-filter="unavailable"/,
  "candidate filters expose all, working, and unavailable views");
assert.match(orderedMarkup, /<details class="tiktok-candidate-group tiktok-unavailable-group"[^>]*>/,
  "unavailable candidates are collapsed in the default view");
assert.match(orderedMarkup, /Показать все 4/,
  "the default candidate view offers an explicit expansion for the full list");
const cappedGoodIps = Array.from({ length: 10 }, (_, index) => `203.0.113.${60 + index}`);
const cappedCandidatePool = cappedGoodIps.map(ip => `${ip}|v77.tiktokcdn.com|direct|1.1.1.1|system-wan|edge.example.net|Amsterdam|check-host|1|1|0|8|4|8|ru1,de1|NL,DE|AS1,AS2|Amsterdam|131,117`).join(";");
const cappedProbeRows = cappedGoodIps.map(ip => `${ip}|90|23|20|400|ams|HIT|edge|ok|ok|verified|117|19|27|400|fra|HIT|edge|ok|ok|verified|compatible|23`).join(";");
const selectedUnavailableFixture = {
  ...originalFixture,
  state: "manual-unavailable", mode: "manual", selected_ip: "203.0.113.99", manual_ip: "203.0.113.99",
  candidate_pool: `${cappedCandidatePool};203.0.113.99|v77.tiktokcdn.com|direct|1.1.1.1|system-wan||Frankfurt|curated|0|1|0|0|0|0|||||`,
  probe_observations: `${cappedProbeRows};203.0.113.99||0|0|||edge|failed|failed|failed||||||||||||incompatible|`,
};
context.selectedUnavailableFixture = selectedUnavailableFixture;
const selectedUnavailableMarkup = vm.runInContext("tiktokStatusMarkup(selectedUnavailableFixture)", context);
const selectedUnavailableWorkingGroup = selectedUnavailableMarkup.match(/<section class="tiktok-candidate-group" data-tiktok-candidate-group="working">([\s\S]*?)<\/section>/)?.[1] || "";
const selectedUnavailableOverflow = (selectedUnavailableWorkingGroup.match(/data-tiktok-overflow/g) || []).length;
assert.equal((selectedUnavailableWorkingGroup.match(/<article /g) || []).length - selectedUnavailableOverflow, 7,
  "a selected unavailable CDN still counts toward the eight-row default candidate cap");
assert.match(selectedUnavailableMarkup, /Текущий CDN выбран вручную/,
  "the manual-unavailable card still identifies the selected CDN in the summary");
assert.match(selectedUnavailableMarkup, /data-tiktok-filter="unavailable"[^>]*>Недоступные <span>1<\/span>/,
  "the unavailable filter count includes a manually selected CDN that is currently unavailable");

const withoutFailover = vm.runInContext("tiktokStatusMarkup({ state: 'checking', latency_ms: '0', selected_ip: '', reason: 'checking' })", context);
assert.doesNotMatch(withoutFailover, /CDN переключён|Последнее автоматическое переключение/,
  "an event section is omitted when there is no complete failover record");
const withoutFailoverSummary = withoutFailover.split("<details", 1)[0];
assert.doesNotMatch(withoutFailoverSummary, /0 мс|undefined|null|class="flow-fact"/,
  "unknown fields do not render zero latency, null values, or empty summary rows");
const unavailableManual = vm.runInContext("tiktokStatusMarkup({ state: 'manual-unavailable', mode: 'manual', manual_ip: '203.0.113.35', selected_ip: '203.0.113.35', candidate_verified: '0', dns_override_applied: '1' })", context);
assert.match(unavailableManual, /Выбранный CDN недоступен/,
  "strict manual mode clearly reports an unavailable selection");
const unapplied = vm.runInContext("tiktokStatusMarkup({ state: 'dns-apply-error', selected_ip: '203.0.113.35', candidate_verified: '1', dns_override_applied: '0' })", context);
assert.match(unapplied, /Ошибка применения DNS/,
  "a verified CDN without effective DNS apply is not shown as working");
assert.doesNotMatch(unapplied.split("<details", 1)[0], /● Работает/,
  "the healthy badge requires both candidate and DNS proof");

const undiscovered = vm.runInContext("tiktokStatusMarkup({ state: 'checking', mode: 'auto', candidate_pool: '', probe_observations: '' })", context);
assert.match(undiscovered, /Проверить все/,
  "the first candidate scan remains available before discovery has populated the list");
assert.match(undiscovered, /Кандидаты ещё не обнаружены/,
  "an empty candidate list explains why there are no CDN rows yet");
assert.match(undiscovered, /кандидатов · проверка не выполнена/,
  "candidate availability stays unknown until a probe has run");

const pendingManual = vm.runInContext(
  "tiktokStatusMarkup(fixture, 1791145000, { action: 'select', ip: '203.0.113.20' })", context);
const pendingSummary = pendingManual.split('<div class="tiktok-candidate-controls"', 1)[0];
assert.match(pendingSummary, /Проверяю новый CDN/,
  "manual selection progress identifies the new CDN being checked");
assert.match(pendingSummary, /Проверяется CDN <code>203\.0\.113\.20<\/code>/,
  "manual selection progress shows the requested candidate IP");
assert.match(pendingSummary, /Текущий CDN проверен: 3 мин назад/,
  "the previous verification age is explicitly attributed to the current old CDN");
assert.doesNotMatch(pendingSummary, /Проверено 3 мин назад/,
  "the old verification age is not presented as the result of the active operation");
assert.match(pendingSummary, /203\.0\.113\.35/,
  "the old working CDN remains visible while the candidate is verified");

const pendingScan = vm.runInContext(
  "tiktokStatusMarkup({ ...fixture, candidates_checked_epoch: '1791144948' }, 1791145000, { action: 'probe-all' })", context);
const pendingScanSummary = pendingScan.split('<div class="tiktok-candidate-controls"', 1)[0];
assert.match(pendingScanSummary, /Идёт проверка кандидатов/,
  "probe-all progress is visible in the status card");
assert.match(pendingScanSummary, /Последняя завершённая проверка кандидатов/,
  "probe-all does not label the old current-CDN verification as a completed candidate scan");

const pendingAuto = vm.runInContext(
  "tiktokStatusMarkup(fixture, 1791145000, { action: 'auto' })", context);
assert.match(pendingAuto, /Переключаю в автоматический режим/,
  "an automatic-mode change is shown as pending");
const refreshingStatus = vm.runInContext(
  'tiktokStatusMarkup(fixture, 1791145000, { action: "refresh" })', context,
);
assert.match(refreshingStatus, /Обновляю состояние CDN/,
  "a completed operation stays distinct while its canonical status refreshes");

const failedManual = vm.runInContext("tiktokStatusMarkup(fixture, 1791145000)", context);
const failedSummary = failedManual.split('<div class="tiktok-candidate-controls"', 1)[0];
assert.match(failedSummary, /Последняя проверка текущего CDN: 3 мин назад/,
  "after a failed selection the unchanged current CDN retains its honest verification age");
assert.doesNotMatch(failedSummary, /Проверяется[^<]*203\.0\.113\.20/,
  "a completed failed selection no longer claims to be checking the candidate");

vm.runInContext('tiktokSelectedDomain = "v16-cla.tiktokcdn.com"', context);
const v16Slug = "v16_cla_tiktokcdn_com";
const hostScopedFixture = {
  ...originalFixture,
  [`domain_${v16Slug}_selected_ip`]: "203.0.113.20",
  [`domain_${v16Slug}_candidate_pool`]: "203.0.113.20|v16-cla.tiktokcdn.com|cla|1.1.1.1|host-discovery|edge-v16|Frankfurt|domain-resolution|1|0|0|0|0|0|||||",
  [`domain_${v16Slug}_candidate_observations`]: "203.0.113.20|77|18|26|206|fra|HIT|edge-v16|ok|ok|verified",
  [`domain_${v16Slug}_candidates_checked_epoch`]: "1791145000",
};
context.hostScopedFixture = hostScopedFixture;
const hostScopedMarkup = vm.runInContext("tiktokStatusMarkup(hostScopedFixture)", context);
const hostCandidateList = hostScopedMarkup.slice(hostScopedMarkup.indexOf('<div class="tiktok-candidate-overview">'), hostScopedMarkup.indexOf('<details class="flow-technical'));
assert.match(hostCandidateList, /data-ip="203\.0\.113\.20"[\s\S]*Проверен для v16-cla\.tiktokcdn\.com/,
  "a host-scoped scan shows the candidate verified for its exact hostname");
assert.doesNotMatch(hostCandidateList, /data-ip="203\.0\.113\.35"/,
  "a host-scoped scan replaces stale candidates from another CDN domain");
assert.match(hostCandidateList, /HTTPS · v16-cla\.tiktokcdn\.com/,
  "expanded probe details name the exact hostname that was checked");
const v16CardPosition = hostScopedMarkup.indexOf("<code>v16-cla.tiktokcdn.com</code>");
const v16Card = hostScopedMarkup.slice(hostScopedMarkup.lastIndexOf('<article class="tiktok-domain-card">', v16CardPosition), hostScopedMarkup.indexOf("</article>", v16CardPosition));
assert.match(v16Card, /IP <b><code>203\.0\.113\.20<\/code><\/b>/,
  "the per-domain card shows the active v16 address independently of global v77 state");
assert.match(v16Card, /Источник выбранного IP <b>domain-resolution · host-discovery<\/b>/,
  "the domain card identifies the discovered source of its active IP");
assert.doesNotMatch(hostCandidateList, /v77 <b>✓|v77-eu <b>✓/,
  "a v77 probe is never displayed as proof for a v16 hostname");
assert.match(hostScopedMarkup, /data-tiktok-action="probe-all" data-host="v16-cla\.tiktokcdn\.com"/,
  "the full discovery action carries the selected hostname");

const unscannedDomainMarkup = vm.runInContext(
  "tiktokStatusMarkup({ ...fixture, domain_v16_cla_tiktokcdn_com_selected_ip: '203.0.113.35' })", context);
const unscannedDomainList = unscannedDomainMarkup.slice(unscannedDomainMarkup.indexOf('<div class="tiktok-candidate-overview">'), unscannedDomainMarkup.indexOf('<details class="flow-technical'));
assert.match(unscannedDomainList, /Не выполнена для этого домена/,
  "legacy observations remain explicitly unverified until the selected hostname is probed");
assert.doesNotMatch(unscannedDomainList, /v77 <b>✓|v77-eu <b>✓/,
  "legacy v77 probe details stay hidden for an unscanned v16 hostname");
vm.runInContext('tiktokSelectedDomain = "v77.tiktokcdn.com"', context);
console.log("PASS: TikTok feed status formats latency once and keeps raw failover codes in diagnostics");
