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
for (const section of ["Соединение", "Выбранный узел", "Проверка", "Последний failover"]) {
  assert.match(markup, new RegExp(`<h4>${section}<\\/h4>`), `diagnostics include the ${section} section`);
}

const withoutFailover = vm.runInContext("tiktokStatusMarkup({ state: 'checking', latency_ms: '0', selected_ip: '', reason: 'checking' })", context);
assert.doesNotMatch(withoutFailover, /CDN переключён|Последний failover/,
  "an event section is omitted when there is no complete failover record");
const withoutFailoverSummary = withoutFailover.split("<details", 1)[0];
assert.doesNotMatch(withoutFailoverSummary, /0 мс|undefined|null|class="flow-fact"/,
  "unknown fields do not render zero latency, null values, or empty summary rows");
console.log("PASS: TikTok feed status formats latency once and keeps raw failover codes in diagnostics");
