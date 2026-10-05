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
  humanAgo: () => "3 мин назад",
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
  reason: "healthy",
  last_failover_epoch: "1791144900",
  last_failover_from: "203.0.113.8",
  last_failover_to: "203.0.113.35",
  last_failover_reason: "material-latency-improvement",
  mode: "manual",
  manual_ip: "203.0.113.35",
  candidate_pool: "203.0.113.35|v77.tiktokcdn.com|direct|1.1.1.1|system-wan|edge.example.net|Amsterdam|resolver+tls|1|0|0;203.0.113.35|v16-cla.tiktokcdn.com|cla|8.8.8.8|provider-catalog|edge.example.net|Amsterdam|mixed|1|1|0;203.0.113.8|v77.tiktokcdn.com|direct|1.1.1.1|system-wan||Frankfurt|curated|0|1|0",
  probe_observations: "203.0.113.35|131|20|30|400|ams|HIT|edge|ok|ok|verified;203.0.113.8||0|0|||edge|failed|failed|failed",
};

const markup = vm.runInContext("tiktokStatusMarkup(fixture)", context);
const summary = markup.split("<details", 1)[0];
const summaryText = summary.replace(/<[^>]*>/g, " ").replace(/\s+/g, " ");

assert.equal((summary.match(/131 мс/g) || []).length, 1,
  "the primary summary shows the formatted latency exactly once");
assert.doesNotMatch(summaryText, /131 мс\s+131/,
  "the formatted latency is not followed by its raw numeric duplicate");
assert.doesNotMatch(summary, /material-latency-improvement/,
  "raw failover reason codes stay out of the user-facing summary");
assert.match(summaryText, /Найден заметно более быстрый узел/,
  "the failover reason is translated for the user");
assert.match(markup, /raw: material-latency-improvement/,
  "the raw failover reason remains available in technical diagnostics");
assert.match(markup, /HTTP-ответ<\/span><span class="flow-fact-value"><span>400/,
  "an HTTP 400 is shown neutrally as a diagnostic response");
assert.match(markup, /Использовать автоматический выбор/,
  "manual mode offers a direct return to normal automatic selection");
assert.match(markup, /Проверить все/,
  "the card exposes the bounded live candidate scan");
assert.equal((markup.match(/<article class="tiktok-candidate[^\"]*" data-ip="203\.0\.113\.35"/g) || []).length, 1,
  "duplicate discovery and curated rows merge into one candidate by IP");
assert.match(markup, /ICMP <b title="Ping не влияет на доступность CDN">—/,
  "ICMP is informational and never required for candidate availability");
assert.match(markup, /TCP 443 <b>Доступен<\/b>/,
  "candidate rows expose the target TCP probe result");
assert.match(markup, /TLS\/SNI <b>Проверен<\/b>/,
  "only candidates with successful target TLS/SNI expose an enabled selection control");
assert.match(markup, /HTTP <b>400<\/b>/,
  "HTTP status remains a neutral candidate diagnostic");
assert.equal((markup.match(/data-tiktok-action="select"/g) || []).length, 1,
  "only the live-verified candidate has an active select action");
assert.match(source, /apiPost\(endpoints\[action\], params\)/,
  "candidate actions are sent through the WebPanel API");
for (const section of ["Соединение", "Выбранный узел", "Проверка", "Последний failover"]) {
  assert.match(markup, new RegExp(`<h4>${section}<\\/h4>`), `diagnostics include the ${section} section`);
}

const withoutFailover = vm.runInContext("tiktokStatusMarkup({ state: 'checking', latency_ms: '0', selected_ip: '', reason: 'checking' })", context);
assert.doesNotMatch(withoutFailover, /CDN переключён|Последний failover/,
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
console.log("PASS: TikTok feed status formats latency once and keeps raw failover codes in diagnostics");
