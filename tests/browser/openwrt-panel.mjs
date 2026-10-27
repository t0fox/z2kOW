// Real-browser acceptance for the OpenWrt document root and its ES-module graph.
// Run with PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node tests/browser/openwrt-panel.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const playwright = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const { chromium } = playwright.chromium ? playwright : playwright.default;
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const webpanelInit = fs.readFileSync(path.join(repo, 'platform/openwrt/files/etc/init.d/z2k-webpanel'), 'utf8');
const webpanelAdapter = fs.readFileSync(path.join(repo, 'platform/openwrt/webpanel.sh'), 'utf8');
assert.equal(/wp_panel_reconcile_http_listener/.test(webpanelInit), false,
  'the panel instance does not stop or restart stock listeners');
assert.equal(/webpanel-lifecycle\.sh/.test(webpanelAdapter), false,
  'panel helpers do not load stock HTTP service mutations');
const screenshotDir = process.env.OPENWRT_SCREENSHOT_DIR || '';
if (screenshotDir) fs.mkdirSync(screenshotDir, { recursive: true });
const switchScreenshotDir = process.env.OPENWRT_SWITCH_SCREENSHOT_DIR || '';
if (switchScreenshotDir) fs.mkdirSync(switchScreenshotDir, { recursive: true });
const screenshotPrefix = process.env.OPENWRT_SCREENSHOT_PREFIX
  ? `${process.env.OPENWRT_SCREENSHOT_PREFIX}-` : '';
const tgScreenshotOnly = process.env.OPENWRT_TG_SCREENSHOT_ONLY === '1';
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'z2k-openwrt-browser-'));
const www = path.join(root, 'www');
fs.cpSync(path.join(repo, 'webpanel/www'), www, { recursive: true });
const tgFlowFixturePath = path.join(www, 'js/tg-flow.js');
let tgFlowFixture = fs.readFileSync(tgFlowFixturePath, 'utf8');
const tgFlowInstrumentation = [
  ['export function mountTelegramFlow(canvas) {', 'export function mountTelegramFlow(canvas) {\n  const testMetrics = window.__tgFlowTestMetrics ||= { mounts: 0, destroys: 0, resizes: 0, processedEvents: 0 };\n  testMetrics.mounts += 1;'],
  ['  function processEvent(session, event, now) {', '  function processEvent(session, event, now) {\n    testMetrics.processedEvents += 1;'],
  ['  function resize() {', '  function resize() {\n    testMetrics.resizes += 1;'],
  ['    destroy() {\n      if (destroyed) return;', '    destroy() {\n      if (destroyed) return;\n      testMetrics.destroys += 1;'],
];
for (const [needle, replacement] of tgFlowInstrumentation) {
  assert.ok(tgFlowFixture.includes(needle), `тестовый стенд находит точку учёта ${needle}`);
  tgFlowFixture = tgFlowFixture.replace(needle, replacement);
}
fs.writeFileSync(tgFlowFixturePath, tgFlowFixture);
const profileDir = path.join(www, 'assets/openwrt');
fs.mkdirSync(profileDir, { recursive: true });
for (const name of ['mark.svg', 'logo.png', 'favicon.svg', 'theme.css', 'profile.json']) {
  const source = path.join(repo, 'platform/openwrt/webpanel-brand', name);
  if (fs.existsSync(source)) fs.copyFileSync(source, path.join(profileDir, name));
}

const mime = {
  '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2', '.ttf': 'font/ttf',
};
const apiRequests = [];
let statusResponsesCompleted = 0;
let holdStatusResponses = true;
let moveOnReinstall = false;
let reinstallFixtureActive = false;
let disclosurePickFixture = false;
const pendingStatusResponses = [];
const statusFixture = {
  ok: true, installed: 'p-86.1', running: true, service: 'active', platform: 'openwrt',
  toggles: {
    game_warp: '0', category_youtube: '1', category_rkn: '1', category_discord_voice: '1',
    customd: '0', dynamic_ttl: '1',
    ppe: '1', auto_update: '1', autohostlist: '0', fastroute: '0', dns_redirect: '0',
    fastroute_available: '0', flowoffload: 'hardware',
    flowoffload_status: 'configured_mode=hardware; flowtable_state=present; flowtable_flags=offload; flowtable_devices=br-lan,wan; actual_dataplane=not-observed; exemption_rules=4; nfqueue_rules=8; nfqueue_packets=26061; packet_visibility=active; circular_state=active; hardware_capability=available; hardware_requested=1; hardware_observed=not-observed; hardware_state=requested; hw_offloaded_connections=0; software_offloaded_connections=3; offloaded_connections=3; selective_state=complete; owner_state=zapret2; owner_conflict=none; runtime_health=attention; runtime_health_reason=hardware-not-observed',
    au_hour: '3',
  },
  tunnel: { running: true, workers: ['worker.example'] },
  doh: {
    state: 'not-installed', installed: '0', provider: 'xbox',
    endpoint: 'https://xbox-dns.ru/dns-query', bootstrap: '111.88.96.50,111.88.96.51',
    force_lan_dns: '0',
  },
  capabilities: { policy: false, ppe: false, tcp16: false, diag: true, warp: true, telegram: true, uninstall: false, offload: true },
};
const tgCheckedAt = Math.floor(Date.now() / 1000);
const tgCheckFixture = {
  checked_at: tgCheckedAt, state: 'partial', data_centers: [
    { dc: 1, state: 'healthy', routes: [
      { transport: 'direct-wss', domain: 'kws1.web.telegram.org', selected_ip: '149.154.175.50',
        state: 'healthy', failed_stage: null, http_status: null, reason: null,
        dns_ms: 11, tcp_ms: 21, tls_ms: 31, websocket_ms: 41, mtproto_ms: 51 },
      { transport: 'cf-proxy', domain: 'edge.example.net', selected_ip: '203.0.113.9',
        state: 'unavailable', failed_stage: 'websocket', http_status: 503, reason: 'HTTP 503 от тестового маршрута',
        dns_ms: 12, tcp_ms: 22, tls_ms: 32, websocket_ms: 42, mtproto_ms: null },
    ] },
    { dc: 2, state: 'blocked', routes: [{ transport: 'cf-worker', domain: 'worker.example', selected_ip: '203.0.113.10',
      state: 'blocked', failed_stage: 'websocket', http_status: 403, reason: 'HTTP 403 от тестового маршрута',
      dns_ms: null, tcp_ms: 24, tls_ms: 34, websocket_ms: 44, mtproto_ms: null }] },
    { dc: 3, state: 'unavailable', routes: [{ transport: 'tcp-fallback', domain: null, selected_ip: '149.154.167.91',
      state: 'unavailable', failed_stage: 'tcp', http_status: null, reason: 'timeout',
      dns_ms: null, tcp_ms: 3000, tls_ms: null, websocket_ms: null, mtproto_ms: null }] },
    { dc: 4, state: 'unverified', routes: [] },
    { dc: 5, state: 'unverified', routes: [] },
  ],
};
const tgStatsFixture = {
  process_started_at: tgCheckedAt - 600, listener_ready: true, active_connections: 5, max_connections: 64,
  active_sessions: Array.from({ length: 5 }, (_, index) => ({
    id: index + 1, dc: 2, is_media: false, stage: 'upstream_ready',
    direct_state: 'selected', fallback_state: 'idle', selected_transport: 'direct_wss',
    telegram_response_seen: false, events: [],
  })),
  accepted_connections: 17, wss_established: 14, mtproto_success: 9, mtproto_failure: 2,
  last_mtproto_response_at: tgCheckedAt - 5,
  dc_map: { generation: 7, fetched_at: tgCheckedAt - 30, freshness_seconds: 30 },
  cf_domain_pool: { domains: ['edge.example.net'], freshness_seconds: 20 },
  workers: { 'worker.example': { state: 'healthy', last_success_at: tgCheckedAt - 10, last_failure_at: 0 } },
  sessions_by_dc_transport: { 'dc203:cf-proxy': 2 },
  failures: { http_503: 2, timeout: 1 },
  ttfb: { 'dc203:cf-proxy': { count: 2, p50_ms: 80, p95_ms: 120, p99_ms: 130 } },
  rss_kib: 10240, rss_hwm_kib: 12288,
};
let tgStatsResponse = tgStatsFixture;
let tgRunningFixture = true;
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://127.0.0.1');
  if (url.pathname.startsWith('/cgi-bin/api/')) {
    const endpoint = url.pathname.slice('/cgi-bin/api/'.length);
    const apiRequest = { endpoint, method: req.method, marker: req.headers['x-z2k-panel'] || '',
      pageId: req.headers['x-z2k-test-page'] || '',
      contentType: req.headers['content-type'] || '' };
    if (req.method === 'POST') {
      const chunks = [];
      for await (const chunk of req) chunks.push(Buffer.from(chunk));
      apiRequest.body = Buffer.concat(chunks).toString('utf8');
    }
    apiRequests.push(apiRequest);
    if (req.headers['x-z2k-panel'] !== '1') {
      res.writeHead(403, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: false, error: 'missing panel marker' }));
      return;
    }
    if (endpoint === 'status') {
      // Hold the first /status response until the route and identity are
      // visibly ready. This proves boot does not wait on backend status.
      if (holdStatusResponses) {
        pendingStatusResponses.push(res);
      } else {
        statusResponsesCompleted += 1;
        res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ...statusFixture, tunnel: { ...statusFixture.tunnel, running: tgRunningFixture } }));
      }
      return;
    }
    if (endpoint === 'tunnel/enable' || endpoint === 'tunnel/disable') {
      tgRunningFixture = endpoint === 'tunnel/enable';
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ ok: true }));
      return;
    }
    if (endpoint === 'offload/benchmark') {
      const view = url.searchParams.get('view');
      const requestBody = req.method === 'POST'
        ? Object.fromEntries(new URLSearchParams(apiRequests[apiRequests.length - 1]?.body || ''))
        : {};
      const body = view === 'result' ? { ok: true, result: null }
        : req.method === 'POST' && requestBody.action === 'start'
          ? { ok: true, job: 'benchmark-fixture', session: '1', token: 'fixture' }
          : req.method === 'POST' && requestBody.action === 'stop'
            ? { ok: true, stopping: true }
            : req.method === 'POST' ? { ok: true }
              : { ok: true, active: false, status: 'idle', result: null };
      res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify(body));
      return;
    }
    const stateEntries = Array.from({ length: 140 }, (_, index) => ({
      key: index % 2 ? 'quic' : 'tcp',
      host: `host-${index}.example-${index}.net`,
      strategy: index % 4 + 1,
      mode: index % 9 === 0 ? 'frozen' : 'auto',
      sni: index % 17 === 0 ? `front-${index}.example.net` : '',
      ts: Math.floor(Date.now() / 1000) - index * 60,
    }));
    Object.assign(stateEntries[0], { host: 'api.reddit.com|4' });
    Object.assign(stateEntries[2], { host: 'old.reddit.com|6' });
    Object.assign(stateEntries[4], { host: 'www.reddit.com|4' });
    Object.assign(stateEntries[1], { host: 'api.long-group-name-for-responsive-layout-coverage.net|4' });
    Object.assign(stateEntries[3], { host: 'cdn.long-group-name-for-responsive-layout-coverage.net|6' });
    Object.assign(stateEntries[6], { host: '192.0.2.44' });
    Object.assign(stateEntries[7], { host: '2001:db8:1234:5678::44' });
    const body = endpoint === 'tunnel/check' ? tgCheckFixture
      : endpoint === 'tunnel/stats' ? (tgRunningFixture ? tgStatsResponse
        : { ...tgStatsResponse, active_connections: 0, active_sessions: [] })
      : endpoint === 'state'
      ? { ok: true, entries: stateEntries }
      : endpoint === 'pools'
        ? { ok: true, pools: { tcp: 4, quic: 4 } }
        : endpoint === 'strategy/pools'
          ? { ok: true, pools: [{ pool: 'tcp', custom: 0, line: '' }, { pool: 'quic', custom: 0, line: '' }] }
          : endpoint === 'strategy/unique-set'
            ? { ok: true, result: null }
            : endpoint === 'strategy/pick' && disclosurePickFixture
              ? { ok: true, result: { target: 'example.test', mode: 'tcp13',
                  tcp: { target: 'example.test', strategy: '--dpi-desync=fake' }, quic: null } }
            : endpoint === 'update/status' || (endpoint === 'update/check' && req.method === 'POST')
              ? (moveOnReinstall
                ? { ok: true, installed: 'p-86.13', installed_seq: 136, available: 'p-86.14', available_seq: 137,
                    behind: 1, last_check: Math.floor(Date.now() / 1000), pending: [], reinstall_supported: true }
                : reinstallFixtureActive
                  ? { ok: true, installed: 'p-86.13', installed_seq: 136, available: 'p-86.13', available_seq: 136,
                      behind: 0, last_check: Math.floor(Date.now() / 1000), pending: [], reinstall_supported: true }
                  : { ok: true, installed: 'p-86.1', available: 'p-86.1', behind: 0,
                      last_check: Math.floor(Date.now() / 1000), pending: [], reinstall_supported: true })
              : endpoint === 'update/reinstall' && req.method === 'POST'
                ? (moveOnReinstall
                  ? { ok: true, state: 'update_available', installed: 'p-86.13', installed_seq: 136,
                      available: 'p-86.14', available_seq: 137, behind: 1 }
                  : { ok: true, state: 'reinstalling', installed: 'p-86.1', installed_seq: 1,
                      available: 'p-86.1', available_seq: 1, job: 'reinstall-fixture' })
              : endpoint === 'product/update/status'
                ? { ok: true, state: 'update-available', installed: 'v0.1.1', latest: 'v0.1.3', message: '' }
                : endpoint === 'product/update/check'
                  ? { ok: true, installed: 'v0.1.1', latest: 'v0.1.3', update_available: true, skipped_releases: 2 }
                  : endpoint === 'product/update/info'
                    ? { product: 'z2kOW', schema: 2, channel: 'stable', version: '0.1.3', history: [{
                      tag: 'v0.1.3', changelog: { new: ['Подписанное обновление продукта'], fixed: ['Rollback после сбоя'], changed: [] },
                    }, {
                      tag: 'v0.1.2', changelog: { new: [], fixed: ['Исправление из пропущенного выпуска'], changed: [] },
                    }, {
                      tag: 'v0.1.1', changelog: { new: ['Уже установленный выпуск'], fixed: [], changed: [] },
                    }] }
              : endpoint === 'auth/session-ttl'
                ? { ok: true, seconds: 86400 }
                : endpoint === 'policy/status'
                  ? { ok: true, enabled: false, policy: '' }
                  : endpoint === 'warp/status'
                    ? { ok: true, enabled: '1', installed: true, ready: true, transport: 'wg', endpoint: '8.6.112.0:2408', iface: 'z2ktun0', addr: '172.16.0.2', entries: 1234, devices: 4, error: '' }
                    : endpoint === 'warp/neighbors'
                      ? { ok: true, devices: [
                        { mac: 'aa:bb:cc:dd:ee:ff', ip: '192.168.1.77', label: 'PS5', net: 'Home', active: true, on: true },
                        { mac: '11:22:33:44:55:66', ip: '192.168.1.101', label: 'Pixel 9 Pro — домашняя сеть', net: 'Home Wi-Fi', active: true, on: false },
                        { mac: '77:88:99:aa:bb:cc', ip: '192.168.1.225', label: 'MacBook Pro рабочий', net: 'Ethernet', active: false, on: false },
                        { mac: '00:11:22:33:44:55', ip: '192.168.1.180', label: 'Steam Deck OLED', net: 'Guest Wi-Fi', active: false, on: true },
                      ] }
                        : endpoint === 'warp/games'
                          ? { ok: true, games: [
                            { name: 'ApexLegends', entries: 42, enabled: 1 },
                            { name: 'Valorant', entries: 13, enabled: 0 },
                            { name: 'CounterStrike2CompetitiveCommunityServers', entries: 124, enabled: 1 },
                            { name: 'CallOfDutyModernWarfareThreeAndWarzone', entries: 387, enabled: 0 },
                            { name: 'WorldOfWarcraftTheWarWithinAndClassic', entries: 96, enabled: 0 },
                          ] }
                          : endpoint === 'warp/lists'
                          ? { ok: true, lists: [{ name: 'custom-long-list-name-for-layout-review', entries: 5, size: 120, mtime: Math.floor(Date.now() / 1000) }] }
                          : endpoint === 'autohostlist-domains'
                            ? { ok: true, domains: [
                              'rutracker.org', 'rr1---sn-4g5e6nzz.googlevideo.com', 'cdn.long-example.invalid',
                              'very-long-auto-discovered-domain-name-for-responsive-layout.example.net',
                              'api.assets.example.org', 'images.cdn.example.org', 'updates.example.net',
                            ] }
                            : endpoint === 'diag'
                              ? { ok: true, diag: [
                                '=== Диагностика z2kOW ===',
                                'Проверка маршрутизации и локальных сетевых служб',
                                'Необработанная строка для проверки горизонтальной прокрутки: ' + 'abcdefghijklmnopqrstuvwxyz0123456789'.repeat(5),
                                ...Array.from({ length: 48 }, (_, index) => `log[${String(index + 1).padStart(2, '0')}] dnsmasq[${1000 + index}]: upstream probe completed; resolver=192.0.2.${(index % 200) + 1}; elapsed=${12 + index}ms`),
                                '=== Конец краткой сводки ===',
                              ].join('\n') }
        : endpoint === 'diag/probe' && req.method === 'POST'
          ? { ok: true, report: probeReportFixture }
        : endpoint === 'exclude'
          ? { ok: true, entries: ['1.1.1.1', '192.0.2.10', '2001:db8:1234:5678::abcd', '203.0.113.64/27'],
              legacy_domains: ['legacy.example.net', 'long-legacy-domain-name-for-layout-review.example.org'] }
        : endpoint === 'whitelist'
          ? { ok: true, text: '', revision: 'fixture-r1', domains: [] }
          : endpoint === 'extra-domains'
            ? { ok: true, text: [
              'example.com', 'rutracker.org', 'rr1---sn-4g5e6nzz.googlevideo.com',
              'very-long-manually-added-domain-name-for-responsive-layout.example.net',
              'api.assets.example.org', 'images.cdn.example.org', 'updates.example.net',
              'subdomain.with.many.labels.for.internal.service.example.com',
              'cdn-one.example.invalid', 'cdn-two.example.invalid', 'mirror.example.invalid',
              'service-with-a-long-hostname.example.org', 'assets-v2.example.net',
              'media-images-edge.example.com', 'long-name-for-table-cell-alignment.example.org',
              'mirror-3.example.invalid',
            ].join('\n') + '\n', revision: 'fixture-r1', domains: [] }
            : { ok: true, text: '', revision: 'fixture-r1', domains: [], rows: [], entries: [],
                strategies: [], running: false, installed: true, platform: 'openwrt' };
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8', 'Cache-Control': 'no-store' });
    res.end(JSON.stringify(body));
    return;
  }

  const pathname = decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname);
  const target = path.resolve(www, `.${pathname}`);
  if (target !== www && !target.startsWith(www + path.sep)) {
    res.writeHead(400); res.end('bad path'); return;
  }
  if (!fs.existsSync(target) || !fs.statSync(target).isFile()) {
    res.writeHead(404, { 'Content-Type': 'text/plain; charset=utf-8' }); res.end('not found'); return;
  }
  res.writeHead(200, { 'Content-Type': mime[path.extname(target)] || 'application/octet-stream', 'Cache-Control': 'no-cache, must-revalidate' });
  fs.createReadStream(target).pipe(res);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({
  headless: true,
  ...(process.env.PLAYWRIGHT_CHANNEL ? { channel: process.env.PLAYWRIGHT_CHANNEL } : {}),
  ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {}),
});

async function screenshotComponent(page, locator, outputPath) {
  if (!screenshotDir) return;
  await page.addStyleTag({ content: '.topbar, .theme-toggle { visibility: hidden !important; }' });
  await locator.screenshot({ path: outputPath, animations: 'disabled' });
}

async function waitForRenderedRoute(page, route) {
  await page.waitForFunction(name => {
    const app = document.querySelector("#app");
    const content = app ? app.innerText.trim() : "";
    return document.body.getAttribute("data-page") === name
      && content.length > 0 && content !== "Загрузка…";
  }, route, { timeout: 2000 });
  await page.waitForFunction(() => [...document.querySelectorAll('#app .page-title, #app > .card')]
    .every(node => Number.parseFloat(getComputedStyle(node).opacity) >= 0.99
      && getComputedStyle(node).visibility !== "hidden"), null, { timeout: 5000 });
  await page.waitForFunction(name => {
    const app = document.querySelector("#app");
    const content = app ? app.innerText.trim() : "";
    return document.body.getAttribute("data-page") === name
      && content.length > 0 && content !== "Загрузка…";
  }, route, { timeout: 2000 });
  await page.locator("#app .page-title").waitFor({ state: "visible", timeout: 2000 });
  const content = (await page.locator("#app").innerText()).trim();
  assert.ok(content, route + " must render visible content");
  assert.notEqual(content, "Загрузка…", route + " must leave the initial loading state");
}

async function waitForCondition(predicate, description, timeoutMs = 5000) {
  const deadline = Date.now() + timeoutMs;
  while (!predicate()) {
    if (Date.now() >= deadline) throw new Error(`Timed out waiting for ${description}`);
    await new Promise(resolve => setTimeout(resolve, 20));
  }
}

async function waitForNavSettled(page) {
  await page.waitForFunction(() => [
    document.querySelector('#nav'), document.querySelector('#app'),
    document.querySelector('#panel-brand'), document.querySelector('.topbar > .theme-toggle'),
    document.querySelector('#nav .nav-active-indicator'),
  ].filter(Boolean).every(element => element.getAnimations().every(animation => animation.playState !== 'running')),
  null, { timeout: 1500 });
  await waitForGsapSettled(page, ['#nav a', '#nav .nav-active-indicator']);
}

async function waitForGsapSettled(page, selectors) {
  await page.waitForFunction(targetSelectors => {
    if (!window.gsap) return true;
    const targets = targetSelectors.flatMap(selector => [...document.querySelectorAll(selector)]);
    return targets.every(target => window.gsap.getTweensOf(target).every(tween => !tween.isActive()));
  }, selectors, { timeout: 1500 });
}

async function waitForDisclosureSettled(page, selector) {
  await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await page.waitForFunction(targetSelector => {
    const details = document.querySelector(targetSelector);
    if (!details) return false;
    for (let node = details; node; node = node.parentElement) {
      if (!node.matches('.disclosure')) continue;
      const body = node.querySelector(':scope > .disclosure-body');
      if (!body || body.getAnimations({ subtree: true }).some(animation => animation.playState === 'running')) return false;
      if (window.gsap?.getTweensOf(body).some(tween => tween.isActive())) return false;
    }
    return true;
  }, selector, { timeout: 1500 });
}

async function waitForDrawerSettled(page, open) {
  await page.waitForFunction(expectedOpen => {
    const nav = document.querySelector('#nav');
    const shell = document.querySelector('#menu-shell');
    const targets = [nav, document.querySelector('.topbar > .theme-toggle'), document.querySelector('#menu-backdrop')].filter(Boolean);
    const settled = targets.every(target => window.gsap.getTweensOf(target).every(tween => tween.progress() >= 1));
    const box = nav.getBoundingClientRect();
    return nav.classList.contains('menu-open') === expectedOpen
      && shell.classList.contains('mm-ocd--open') === expectedOpen
      && settled
      && (expectedOpen ? Math.abs(box.left) < 1 : Math.abs(box.right) < 1);
  }, open, { timeout: 1200 });
}

async function assertActiveStrategyTabVisible(page, label) {
  const bounds = await page.locator('.strat-tabs').evaluate(tabs => {
    const active = tabs.querySelector('.strat-tab.active, .strat-tab[aria-current="page"]');
    const tab = active.getBoundingClientRect();
    const viewport = tabs.getBoundingClientRect();
    const tabsInView = [...tabs.querySelectorAll('.strat-tab')].map(item => {
      const rect = item.getBoundingClientRect();
      return { text: item.textContent.trim(), left: rect.left, right: rect.right };
    });
    return { tabLeft: tab.left, tabRight: tab.right, viewportLeft: viewport.left, viewportRight: viewport.right, tabsInView };
  });
  assert.ok(bounds.tabLeft >= bounds.viewportLeft - 1 && bounds.tabRight <= bounds.viewportRight + 1,
    `${label}: the active strategy tab is fully visible without manual scrolling (${JSON.stringify(bounds)})`);
  assert.ok(bounds.tabsInView.every(item => item.left >= bounds.viewportLeft - 1 && item.right <= bounds.viewportRight + 1),
    `${label}: strategy tabs fit without clipped labels (${JSON.stringify(bounds)})`);
}

const probeReportFixture = [
  'Probe: dns=ok tcp=fail tls=skip (284ms)',
  'IPs: 203.0.113.8, 203.0.113.9',
  'Code: 451',
  'Reason: certificate <expired>',
  'Verdict: HOT — blocked during TLS',
  '  → Check the TLS inspection path',
].join('\n');

async function runShellMotionTests(videoDir) {
  const failures = [];
  const quickMotionProof = process.env.OPENWRT_QUICK_MOTION === '1';
  const check = (name, condition, details) => {
    if (!condition) failures.push({ name, details });
  };
  fs.mkdirSync(videoDir, { recursive: true });
  const videoSide = process.env.OPENWRT_VIDEO_SIDE === 'before' ? 'before' : 'after';
  const videoLabel = videoSide === 'before' ? 'ПРЕДЫДУЩАЯ РЕАЛИЗАЦИЯ' : 'ИСПРАВЛЕННАЯ РЕАЛИЗАЦИЯ';
  const startFrames = page => page.evaluate(() => {
    window.__shellFrames = [];
    window.__shellCapture = true;
    const selectors = ['#nav', '#nav .nav-active-indicator', '#panel-brand', '#app', '.topbar'];
    const sample = () => {
      if (!window.__shellCapture) return;
      const rootStyle = getComputedStyle(document.documentElement);
      const frame = { time: performance.now(), viewportWidth: innerWidth,
        motionReady: document.documentElement.classList.contains('motion-ready'),
        brandThemeReady: document.documentElement.classList.contains('brand-theme-ready'),
        progress: rootStyle.getPropertyValue('--sidebar-progress').trim() };
      const page = document.querySelector('#app');
      if (page) {
        const pageStyle = getComputedStyle(page);
        const matrix = new DOMMatrixReadOnly(pageStyle.transform);
        frame.content = { opacity: Number(pageStyle.opacity), y: matrix.m42,
          activeTweenDurations: window.gsap?.getTweensOf(page).filter(tween => tween.isActive())
            .map(tween => tween.duration()) || [] };
      }
      for (const selector of selectors) {
        const element = document.querySelector(selector);
        if (!element) continue;
        const style = getComputedStyle(element);
        const rect = element.getBoundingClientRect();
        frame[selector] = {
          left: style.left, transform: style.transform, transitionProperty: style.transitionProperty,
          positionTransitions: element.getAnimations().map(animation => animation.transitionProperty)
            .filter(property => /^(left|right|top|bottom|width|height|margin|margin-left|margin-right|transform)$/.test(property)),
          layout: { left: element.offsetLeft, top: element.offsetTop },
          rect: { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
            width: rect.width, height: rect.height },
        };
      }
      window.__shellFrames.push(frame);
      requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
  });
  const stopFrames = page => page.evaluate(() => {
    window.__shellCapture = false;
    return window.__shellFrames;
  });
  const saveVideo = async (page, video, name) => {
    await page.close();
    fs.copyFileSync(await video.path(), path.join(videoDir, name));
  };
  const decorateVideo = page => page.evaluate(label => {
    const badge = document.createElement('div');
    badge.textContent = label;
    badge.style.cssText = 'position:fixed;z-index:99999;top:12px;left:12px;padding:6px 10px;border-radius:6px;background:#08110d;color:#00ba78;font:600 12px/1.2 sans-serif;letter-spacing:.04em;pointer-events:none';
    document.body.append(badge);
  }, videoLabel);

  const routeVideoPage = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'dark',
    recordVideo: { dir: videoDir, size: { width: 1440, height: 900 } } });
  const routeVideo = routeVideoPage.video();
  await routeVideoPage.addInitScript(() => {
    localStorage.setItem('z2k-theme', 'dark');
    localStorage.setItem('z2k-sidebar', 'expanded');
  });
  await routeVideoPage.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(routeVideoPage, 'dashboard');
  await routeVideoPage.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
  await routeVideoPage.waitForTimeout(350);
  await decorateVideo(routeVideoPage);
  for (const route of ['toggles', 'tiktok', 'strategies', 'warp', 'dashboard']) {
    await routeVideoPage.locator(`#nav a[data-route="${route}"]`).click();
    await waitForRenderedRoute(routeVideoPage, route === 'strategies' ? 'state' : route);
    await routeVideoPage.waitForTimeout(340);
  }
  await saveVideo(routeVideoPage, routeVideo, `navigation-${videoSide}.webm`);

  const collapseVideoPage = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'dark',
    recordVideo: { dir: videoDir, size: { width: 1440, height: 900 } } });
  const collapseVideo = collapseVideoPage.video();
  await collapseVideoPage.addInitScript(() => {
    localStorage.setItem('z2k-theme', 'dark');
    localStorage.setItem('z2k-sidebar', 'expanded');
  });
  await collapseVideoPage.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(collapseVideoPage, 'dashboard');
  await collapseVideoPage.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
  await collapseVideoPage.waitForTimeout(350);
  await decorateVideo(collapseVideoPage);
  await collapseVideoPage.locator('#sidebar-collapse').click();
  await collapseVideoPage.waitForTimeout(700);
  await saveVideo(collapseVideoPage, collapseVideo, `collapse-${videoSide}.webm`);

  const expandVideoPage = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'dark',
    recordVideo: { dir: videoDir, size: { width: 1440, height: 900 } } });
  const expandVideo = expandVideoPage.video();
  await expandVideoPage.addInitScript(() => {
    localStorage.setItem('z2k-theme', 'dark');
    localStorage.setItem('z2k-sidebar', 'collapsed');
  });
  await expandVideoPage.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(expandVideoPage, 'dashboard');
  await expandVideoPage.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
  await expandVideoPage.waitForTimeout(400);
  await decorateVideo(expandVideoPage);
  await expandVideoPage.locator('#sidebar-collapse').click();
  await expandVideoPage.waitForTimeout(700);
  await saveVideo(expandVideoPage, expandVideo, `expand-${videoSide}.webm`);

  const routeTestPage = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'dark' });
  await routeTestPage.addInitScript(() => {
    localStorage.setItem('z2k-theme', 'dark');
    localStorage.setItem('z2k-sidebar', 'expanded');
  });
  await routeTestPage.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(routeTestPage, 'dashboard');
  await routeTestPage.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
  await startFrames(routeTestPage);
  await routeTestPage.waitForTimeout(350);
  await routeTestPage.evaluate(() => {
    const card = document.querySelector('#app > .card');
    window.__routeExitProbe = { app: document.querySelector('#app'), card, samples: [] };
    const sample = () => {
      const app = window.__routeExitProbe.app;
      const outgoing = window.__routeExitProbe.card;
      if (outgoing && app) {
        const style = getComputedStyle(app);
        const cardStyle = getComputedStyle(outgoing);
        const navLinks = [...document.querySelectorAll('#nav a')]
          .map(link => getComputedStyle(link).transform);
        window.__routeExitProbe.samples.push({ connected: outgoing.isConnected,
          opacity: Number(style.opacity), y: new DOMMatrixReadOnly(style.transform).m42,
          cardOpacity: Number(cardStyle.opacity), cardTransform: cardStyle.transform, navLinks });
      }
      if (window.__routeExitProbe.samples.length < 60) requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
    document.querySelector('#nav a[data-route="toggles"]').click();
  });
  await routeTestPage.waitForTimeout(80);
  const routeExitProbe = await routeTestPage.evaluate(() => ({
    samples: window.__routeExitProbe.samples,
    outgoingConnected: window.__routeExitProbe.card.isConnected,
  }));
  check('старая вкладка плавно выходит до подмены содержимого',
    routeExitProbe.outgoingConnected && routeExitProbe.samples.some(sample => sample.connected
      && sample.opacity > 0 && sample.opacity < 0.98 && sample.y < 0), routeExitProbe);
  check('карточки не двигаются отдельно от слоя страницы',
    routeExitProbe.samples.length > 0 && routeExitProbe.samples.every(sample =>
      sample.cardOpacity === 1 && sample.cardTransform === 'none'), routeExitProbe);
  check('ссылки меню не масштабируются при смене активного раздела',
    routeExitProbe.samples.length > 0 && routeExitProbe.samples.every(sample =>
      sample.navLinks.every(transform => transform === 'none')), routeExitProbe);
  await waitForRenderedRoute(routeTestPage, 'toggles');
  check('старая вкладка удаляется после завершения перехода',
    await routeTestPage.evaluate(() => !window.__routeExitProbe.card.isConnected));
  const navigationRoutes = ['toggles', 'tiktok', 'state', 'warp', 'dashboard'];
  const routeCycles = quickMotionProof ? 1 : 30;
  for (let cycle = 0; cycle < routeCycles; cycle += 1) {
    for (const route of navigationRoutes) {
      await routeTestPage.evaluate(name => { location.hash = `#/${name}`; }, route);
      try { await waitForRenderedRoute(routeTestPage, route); }
      catch (error) {
        const snapshot = await routeTestPage.evaluate(() => ({ route: document.body.dataset.page,
          title: document.querySelector('#app .page-title')?.textContent,
          nodes: [...document.querySelectorAll('#app .page-title, #app > .card')].map(node => ({
            text: node.textContent.trim().slice(0, 60), opacity: getComputedStyle(node).opacity,
            visibility: getComputedStyle(node).visibility, transform: getComputedStyle(node).transform,
          })), tweens: window.gsap?.getTweensOf(document.querySelector('#app .page-title')).map(tween => ({
            active: tween.isActive(), progress: tween.progress(), duration: tween.duration(),
          })) }));
        console.error(`Ожидание маршрута ${cycle + 1}/${route} не завершилось: ${JSON.stringify(snapshot)}`);
        throw error;
      }
    }
  }
  await waitForGsapSettled(routeTestPage, ['#app']);
  await routeTestPage.waitForTimeout(40);
  const navigationFrames = await stopFrames(routeTestPage);
  const routeContentFrames = navigationFrames.map(frame => frame.content).filter(Boolean);
  check('переход вкладки плавно вводит содержимое единым слоем',
    routeContentFrames.some(frame => frame.opacity < 0.95 && frame.y > 1)
      && routeContentFrames.some(frame => frame.opacity >= 0.99 && Math.abs(frame.y) < 0.5),
    { samples: routeContentFrames.length, first: routeContentFrames[0], last: routeContentFrames.at(-1) });
  check('вход содержимого длится не меньше 240 мс',
    routeContentFrames.some(frame => frame.activeTweenDurations.some(seconds => seconds >= 0.24 && seconds <= 0.35)),
    routeContentFrames.map(frame => frame.activeTweenDurations).filter(values => values.length));
  const routeCleanup = await routeTestPage.evaluate(() => ({
    inlineOpacity: document.querySelector('#app').style.opacity,
    inlineVisibility: document.querySelector('#app').style.visibility,
    inlineTransform: document.querySelector('#app').style.transform,
    runningAnimations: document.querySelector('#app').getAnimations().filter(animation =>
      animation.playState === 'running').length,
    runningTweens: window.gsap?.getTweensOf(document.querySelector('#app'))
      .filter(tween => tween.isActive()).length || 0,
  }));
  check('переход очищает временные стили и анимации #app',
    !routeCleanup.inlineOpacity && !routeCleanup.inlineVisibility && !routeCleanup.inlineTransform
      && routeCleanup.runningAnimations === 0 && routeCleanup.runningTweens === 0, routeCleanup);
  check('маршрут не двигает shell', navigationFrames.length > 5 &&
    ['#nav', '#panel-brand', '#app', '.topbar'].every(selector => {
      const samples = navigationFrames.map(frame => frame[selector]).filter(Boolean);
      if (!samples.length) return false;
      const first = samples[0].rect;
      const geometry = selector === '#app' ? ['left', 'top', 'right', 'width']
        : ['left', 'top', 'right', 'bottom', 'width', 'height'];
      return samples.every(item => item.left === samples[0].left
        && item.transitionProperty === 'none'
        && (selector === '#app'
          ? Math.abs(item.layout.left - samples[0].layout.left) <= 1
            && Math.abs(item.layout.top - samples[0].layout.top) <= 1
            && Math.abs(item.rect.top - first.top) <= 9
          : geometry.every(key => Math.abs(item.rect[key] - first[key]) <= 1)
            && item.transform === samples[0].transform));
    }), `${navigationFrames.length} кадров / 30 циклов`);
  check('переходы shell не включаются для left/width/margin', navigationFrames.length > 0 &&
    navigationFrames.every(frame => !/(^|,\s*)(all|left|width|margin-left|right|transform)(,|$)/
      .test(`${frame['#nav']?.transitionProperty},${frame['#panel-brand']?.transitionProperty},${frame['#app']?.transitionProperty},${frame['.topbar']?.transitionProperty}`)),
  navigationFrames[0] || {});
  fs.writeFileSync(path.join(videoDir, `navigation-frames-${videoSide}.json`), JSON.stringify(navigationFrames, null, 2));
  await routeTestPage.close();

  const coldPage = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'dark' });
  let themeRequests = 0;
  let profileRequests = 0;
  await coldPage.addInitScript(index => {
    localStorage.setItem('z2k-theme', index % 2 ? 'light' : 'dark');
    localStorage.setItem('z2k-sidebar', index % 2 ? 'collapsed' : 'expanded');
    window.__shellBootFrames = [];
    const sample = () => {
      const selectors = ['#nav', '#panel-brand', '#app', '.topbar'];
      if (selectors.every(selector => document.querySelector(selector))) {
        const frame = { time: performance.now(), ready: document.documentElement.classList.contains('brand-theme-ready'),
          motionReady: document.documentElement.classList.contains('motion-ready'),
          brandProfileReady: document.documentElement.classList.contains('brand-profile-ready'),
          viewportWidth: innerWidth };
        for (const selector of selectors) {
          const node = document.querySelector(selector);
          const style = getComputedStyle(node);
          const rect = node.getBoundingClientRect();
          frame[selector] = { left: style.left, transform: style.transform, transitionProperty: style.transitionProperty,
            positionTransitions: node.getAnimations().map(animation => animation.transitionProperty)
              .filter(property => /^(left|right|top|bottom|width|height|margin|margin-left|margin-right|transform)$/.test(property)),
            rect: { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
              width: rect.width, height: rect.height } };
        }
        window.__shellBootFrames.push(frame);
      }
      if (window.__shellBootFrames.length < 45) requestAnimationFrame(sample);
    };
    requestAnimationFrame(sample);
  }, 0);
  await coldPage.route('**/assets/openwrt/theme.css', async route => {
    themeRequests += 1;
    await new Promise(resolve => setTimeout(resolve, 120));
    await route.continue();
  });
  await coldPage.route('**/assets/openwrt/profile.json', async route => {
    profileRequests += 1;
    await new Promise(resolve => setTimeout(resolve, 120));
    await route.continue();
  });
  const coldLoadRuns = [];
  const coldLoadCount = quickMotionProof ? 1 : 20;
  for (let index = 0; index < coldLoadCount; index += 1) {
    if (index) await coldPage.goto('about:blank');
    await coldPage.goto(`${base}/#/dashboard`, { waitUntil: 'commit' });
    await waitForRenderedRoute(coldPage, 'dashboard');
    await coldPage.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
    await coldPage.waitForFunction(() => window.__shellBootFrames?.length >= 45);
    const samples = await coldPage.evaluate(() => window.__shellBootFrames);
    coldLoadRuns.push(samples);
    for (const selector of ['#nav', '#panel-brand', '#app', '.topbar']) {
      const boxes = samples.map(frame => frame[selector]).filter(Boolean);
      const first = boxes[0]?.rect;
      const geometry = selector === '#app' ? ['left', 'top', 'right', 'width']
        : ['left', 'top', 'right', 'bottom', 'width', 'height'];
      check(`холодная загрузка ${index + 1}: ${selector} не сдвигается`, Boolean(first) && boxes.every(item =>
        geometry.every(key => Math.abs(item.rect[key] - first[key]) <= 1)
        && item.left === boxes[0].left && item.transform === boxes[0].transform
        && item.positionTransitions.length === 0), { before: boxes[0], after: boxes.at(-1) });
    }
  }
  check(`все ${coldLoadCount} ответа theme.css и profile.json задерживались`,
    themeRequests === coldLoadCount && profileRequests === coldLoadCount,
    { themeRequests, profileRequests });
  fs.writeFileSync(path.join(videoDir, `cold-load-frames-${videoSide}.json`), JSON.stringify(coldLoadRuns, null, 2));
  await coldPage.close();

  const collapseTestPage = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'dark' });
  await collapseTestPage.addInitScript(() => {
    localStorage.setItem('z2k-theme', 'dark');
    localStorage.setItem('z2k-sidebar', 'expanded');
  });
  await collapseTestPage.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(collapseTestPage, 'dashboard');
  await collapseTestPage.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
  await collapseTestPage.waitForTimeout(350);
  await startFrames(collapseTestPage);
  const collapseControl = collapseTestPage.locator('#sidebar-collapse');
  const collapseControlHeight = await collapseControl.evaluate(node => node.getBoundingClientRect().height);
  await collapseControl.click();
  await collapseTestPage.waitForTimeout(80);
  const collapseControlDuringMotion = await collapseControl.evaluate(node => ({
    height: node.getBoundingClientRect().height, transform: getComputedStyle(node).transform,
  }));
  check('кнопка сворачивания сохраняет размер во время движения layout',
    collapseControlDuringMotion.transform === 'none'
      && Math.abs(collapseControlDuringMotion.height - collapseControlHeight) < 0.05,
    { before: collapseControlHeight, during: collapseControlDuringMotion });
  await collapseTestPage.waitForTimeout(420);
  const collapseFrames = await stopFrames(collapseTestPage);
  const collapseMetrics = await collapseTestPage.evaluate(() => {
    const frames = window.__shellFrames;
    const centers = [...document.querySelectorAll('#nav > a .nav-ico, #nav .sidebar-collapse .nav-ico')]
      .map(node => node.getBoundingClientRect().left + node.getBoundingClientRect().width / 2);
    return { frames, iconCenterSpread: Math.max(...centers) - Math.min(...centers),
      progress: getComputedStyle(document.documentElement).getPropertyValue('--sidebar-progress').trim(),
    state: document.body.dataset.sidebar,
      activeRootTweens: window.gsap?.getTweensOf(document.documentElement).filter(tween => tween.isActive()).length || 0 };
  });
  const collapseBoxes = collapseFrames.map(frame => ({
    nav: frame['#nav']?.rect, brand: frame['#panel-brand']?.rect, app: frame['#app']?.rect,
  })).filter(frame => frame.nav && frame.brand && frame.app);
  const initialBox = collapseBoxes[0];
  const finalBox = collapseBoxes.at(-1);
  check('при сворачивании sidebar остаётся на месте', Boolean(initialBox && finalBox) &&
    collapseBoxes.every(frame => Math.abs(frame.nav.left - initialBox.nav.left) <= 1),
  { initial: initialBox?.nav, final: finalBox?.nav });
  check('приложение занимает освобождённую ширину без изменения правого края', Boolean(initialBox && finalBox) &&
    collapseBoxes.every(frame => Math.abs(frame.app.right - initialBox.app.right) <= 1
      && Math.abs(frame.app.left - frame.nav.right - 15) <= 1
      && Math.abs(frame.app.width + frame.nav.width - initialBox.app.width - initialBox.nav.width) <= 1),
  { initial: initialBox, final: finalBox });
  check('логотип и шапка неподвижны при сворачивании', Boolean(initialBox) && collapseBoxes.every(frame =>
    Math.abs(frame.brand.left - initialBox.brand.left) <= 1 && Math.abs(frame.brand.top - initialBox.brand.top) <= 1),
  { initial: initialBox?.brand, final: finalBox?.brand });
  check('иконки меню сохраняют общий центр', collapseMetrics.iconCenterSpread <= 1,
    { spread: collapseMetrics.iconCenterSpread });
  check('состояние layout доходит до свёрнутого', collapseMetrics.progress === '1' && collapseMetrics.state === 'collapsed',
    { progress: collapseMetrics.progress, state: collapseMetrics.state });
  const frameDeltas = collapseBoxes.slice(1).map((frame, index) => Math.max(
    Math.abs(frame.nav.width - collapseBoxes[index].nav.width), Math.abs(frame.app.left - collapseBoxes[index].app.left),
    Math.abs(frame.app.width - collapseBoxes[index].app.width)));
  check('движение layout проходит кадр за кадром', frameDeltas.length > 5 && Math.max(...frameDeltas) < 45,
    { maximumPerFrame: Math.max(...frameDeltas) });
  check('после анимации нет конкурирующих shell transitions', collapseFrames.every(frame =>
    !/(^|,\s*)(left|width|margin-left|right)(,|$)/.test(
      `${frame['#nav']?.transitionProperty},${frame['#panel-brand']?.transitionProperty},${frame['#app']?.transitionProperty}`)),
  collapseFrames[0]);
  fs.writeFileSync(path.join(videoDir, `collapse-frames-${videoSide}.json`), JSON.stringify(collapseMetrics, null, 2));
  await collapseTestPage.close();

  const fastPage = await browser.newPage({ viewport: { width: 1280, height: 900 }, colorScheme: 'dark' });
  await fastPage.addInitScript(() => localStorage.setItem('z2k-sidebar', 'expanded'));
  await fastPage.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(fastPage, 'dashboard');
  await fastPage.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
  await startFrames(fastPage);
  const collapseButton = fastPage.locator('#sidebar-collapse');
  await collapseButton.click();
  await fastPage.waitForTimeout(90);
  await collapseButton.click();
  await fastPage.waitForTimeout(90);
  await collapseButton.click();
  await fastPage.waitForTimeout(500);
  const fastFrames = await stopFrames(fastPage);
  const fastFinal = await fastPage.evaluate(() => ({ state: document.body.dataset.sidebar,
    activeTweens: window.gsap?.getTweensOf(document.documentElement).filter(tween => tween.isActive()).length || 0,
    progress: getComputedStyle(document.documentElement).getPropertyValue('--sidebar-progress').trim() }));
  check('быстрые нажатия перенаправляют единую анимацию к последнему состоянию',
    fastFinal.state === 'collapsed' && fastFinal.progress === '1' && fastFinal.activeTweens <= 1,
    fastFinal);
  fs.writeFileSync(path.join(videoDir, `rapid-toggle-frames-${videoSide}.json`), JSON.stringify(fastFrames, null, 2));
  await fastPage.close();

  for (const gsapEnabled of [true, false]) {
    const resizePage = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'dark' });
    await resizePage.addInitScript(() => {
      localStorage.setItem('z2k-theme', 'dark');
      localStorage.setItem('z2k-sidebar', 'collapsed');
    });
    if (!gsapEnabled) await resizePage.route('**/assets/vendor/gsap.js', route => route.abort('failed'));
    await resizePage.goto(`${base}/#/dashboard`);
    await waitForRenderedRoute(resizePage, 'dashboard');
    await resizePage.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
    await startFrames(resizePage);
    await resizePage.setViewportSize({ width: 760, height: 900 });
    await resizePage.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const desktopResumeAt = await resizePage.evaluate(() => performance.now());
    await resizePage.setViewportSize({ width: 1440, height: 900 });
    await resizePage.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
    const resizeFrames = await stopFrames(resizePage);
    const desktopResumeFrames = resizeFrames.filter(frame => frame.time >= desktopResumeAt && frame.viewportWidth === 1440);
    const resizedShell = await resizePage.evaluate(() => {
      const root = document.documentElement;
      const nav = document.querySelector('#nav');
      const app = document.querySelector('#app');
      const navRect = nav.getBoundingClientRect();
      const appRect = app.getBoundingClientRect();
      return {
        motionReady: root.classList.contains('motion-ready'),
        brandThemeReady: root.classList.contains('brand-theme-ready'),
        progress: getComputedStyle(root).getPropertyValue('--sidebar-progress').trim(),
        activeTweens: window.gsap?.getTweensOf(root).filter(tween => tween.isActive()).length || 0,
        activeCssTransitions: root.getAnimations().filter(animation =>
          animation.transitionProperty === '--sidebar-progress' && animation.playState === 'running').length,
        sidebarMotion: root.dataset.sidebarMotion || '',
        navLeft: getComputedStyle(nav).left,
        navTransition: getComputedStyle(nav).transitionProperty,
        navRect: { left: navRect.left, right: navRect.right, width: navRect.width },
        appRect: { left: appRect.left, right: appRect.right, width: appRect.width },
      };
    });
    check(`${gsapEnabled ? 'GSAP' : 'CSS'}: viewport change не анимирует sidebar`,
      resizedShell.progress === '1' && resizedShell.activeTweens === 0
        && resizedShell.activeCssTransitions === 0 && !resizedShell.sidebarMotion
        && Math.abs(resizedShell.navRect.left - 176.7) <= 1
        && Math.abs(resizedShell.navRect.width - 72) <= 1
        && desktopResumeFrames.length >= 2 && desktopResumeFrames.every(frame =>
          frame.motionReady === gsapEnabled && frame.brandThemeReady
            && frame['#nav'].transitionProperty === 'none'
            && Math.abs(Number.parseFloat(frame['#nav'].left) - 176.7) <= 1
            && Math.abs(frame['#nav'].rect.left - 176.7) <= 1
            && Math.abs(frame['#nav'].rect.width - 72) <= 1)
        && Math.abs(resizedShell.appRect.left - resizedShell.navRect.right - 15) <= 1,
      { ...resizedShell, desktopResumeFrames: desktopResumeFrames.length,
        frameLefts: desktopResumeFrames.map(frame => frame['#nav']?.left) });
    await resizePage.close();
  }

  const cssMotionPage = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'dark' });
  await cssMotionPage.route('**/assets/vendor/gsap.js*', route => route.abort('failed'));
  await cssMotionPage.addInitScript(() => {
    localStorage.setItem('z2k-theme', 'dark');
    localStorage.setItem('z2k-sidebar', 'expanded');
  });
  await cssMotionPage.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(cssMotionPage, 'dashboard');
  await cssMotionPage.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
  await startFrames(cssMotionPage);
  await cssMotionPage.locator('#nav a[data-route="tiktok"]').click();
  await waitForRenderedRoute(cssMotionPage, 'tiktok');
  await cssMotionPage.waitForTimeout(400);
  const cssRouteFrames = await stopFrames(cssMotionPage);
  const cssRouteCleanup = await cssMotionPage.evaluate(() => ({
    inlineOpacity: document.querySelector('#app').style.opacity,
    inlineVisibility: document.querySelector('#app').style.visibility,
    inlineTransform: document.querySelector('#app').style.transform,
    runningAnimations: document.querySelector('#app').getAnimations()
      .filter(animation => animation.playState === 'running').length,
  }));
  check('CSS fallback очищает временные стили после перехода',
    !cssRouteCleanup.inlineOpacity && !cssRouteCleanup.inlineVisibility
      && !cssRouteCleanup.inlineTransform && cssRouteCleanup.runningAnimations === 0,
    cssRouteCleanup);
  const cssIndicatorFrames = cssRouteFrames.map(frame => frame['#nav .nav-active-indicator']?.rect).filter(Boolean);
  const cssIndicatorStart = cssIndicatorFrames[0]?.top;
  const cssIndicatorEnd = cssIndicatorFrames.at(-1)?.top;
  const cssIndicatorStyle = await cssMotionPage.locator('#nav .nav-active-indicator').evaluate(node => {
    const style = getComputedStyle(node);
    return { property: style.transitionProperty, duration: style.transitionDuration,
      timing: style.transitionTimingFunction };
  });
  check('без GSAP вкладка двигает CSS-индикатор, shell остаётся неподвижным',
    cssRouteFrames.length > 5 && Math.abs(cssIndicatorEnd - cssIndicatorStart) > 20
      && cssIndicatorFrames.some(rect => Math.abs(rect.top - cssIndicatorStart) > 1
        && Math.abs(rect.top - cssIndicatorEnd) > 1)
      && cssRouteFrames.some(frame => frame.content && frame.content.opacity < 0.98 && frame.content.y > 0)
      && ['#nav', '#panel-brand', '#app', '.topbar'].every(selector => {
        const samples = cssRouteFrames.map(frame => frame[selector]).filter(Boolean);
        const geometry = selector === '#app' ? ['left', 'right', 'width']
          : ['left', 'top', 'right', 'bottom', 'width', 'height'];
        return samples.length > 0 && samples.every(item => geometry
          .every(key => Math.abs(item.rect[key] - samples[0].rect[key]) <= 1)
          && (selector !== '#app' || Math.abs(item.rect.top - samples[0].rect.top) <= 9));
      }), { start: cssIndicatorStart, end: cssIndicatorEnd, frames: cssRouteFrames.length,
    tops: cssIndicatorFrames.map(rect => rect.top), style: cssIndicatorStyle });
  await startFrames(cssMotionPage);
  const cssCollapseButton = cssMotionPage.locator('#sidebar-collapse');
  await cssCollapseButton.click();
  await cssMotionPage.waitForTimeout(80);
  await cssCollapseButton.click();
  await cssMotionPage.waitForTimeout(80);
  await cssCollapseButton.click();
  await cssMotionPage.waitForFunction(() => !document.documentElement.hasAttribute('data-sidebar-motion'), null,
    { timeout: 1500 });
  const cssRapidFrames = await stopFrames(cssMotionPage);
  const cssCollapsed = await cssMotionPage.evaluate(() => ({
    gsap: Boolean(window.gsap), progress: Number(getComputedStyle(document.documentElement)
      .getPropertyValue('--sidebar-progress')), state: document.body.dataset.sidebar,
    sidebarMotion: document.documentElement.dataset.sidebarMotion || '',
    nav: document.querySelector('#nav').getBoundingClientRect().toJSON(),
    app: document.querySelector('#app').getBoundingClientRect().toJSON(),
  }));
  const cssFrameDeltas = cssRapidFrames.slice(1).map((frame, index) => Math.max(
    Math.abs(frame['#nav'].rect.width - cssRapidFrames[index]['#nav'].rect.width),
    Math.abs(frame['#app'].rect.left - cssRapidFrames[index]['#app'].rect.left),
    Math.abs(frame['#app'].rect.width - cssRapidFrames[index]['#app'].rect.width)));
  check('без GSAP сворачивание использует тот же layout-прогресс', !cssCollapsed.gsap
    && cssCollapsed.progress === 1 && cssCollapsed.state === 'collapsed'
    && !cssCollapsed.sidebarMotion && cssRapidFrames.length > 5 && Math.max(...cssFrameDeltas) < 45
    && Math.abs(cssCollapsed.nav.width - 72) < 1
    && Math.abs(cssCollapsed.app.left - cssCollapsed.nav.right - 15) < 1,
  { ...cssCollapsed, cssFrames: cssRapidFrames.length, maxPerFrame: Math.max(...cssFrameDeltas) });
  await cssMotionPage.close();

  const disclosurePages = [];
  for (const theme of ['dark', 'light']) {
    for (const gsapEnabled of [true, false]) {
      const recordDisclosure = theme === 'dark' && gsapEnabled;
      const pageId = `disclosure-${theme}-${gsapEnabled ? 'gsap' : 'css'}`;
      const page = await browser.newPage({ viewport: { width: 1280, height: 900 }, colorScheme: theme,
        ...(recordDisclosure ? { recordVideo: { dir: videoDir, size: { width: 1280, height: 900 } } } : {}) });
      await page.setExtraHTTPHeaders({ 'x-z2k-test-page': pageId });
      await page.addInitScript(mode => localStorage.setItem('z2k-theme', mode), theme);
      if (!gsapEnabled) await page.route('**/assets/vendor/gsap.js', route => route.abort('failed'));
      await page.goto(`${base}/#/toggles`);
      await waitForRenderedRoute(page, 'toggles');
      await page.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
      const details = page.locator('details.flow-benchmark-method');
      const summary = details.locator(':scope > summary');
      await summary.waitFor({ state: 'visible' });
      if (theme === 'dark' && gsapEnabled) {
        const broadSelectors = await page.evaluate(() => {
          const matches = [];
          const visit = rules => {
            for (const rule of rules) {
              if (rule.selectorText && /summary\s+span\b/.test(rule.selectorText)
                  && !rule.selectorText.includes('.disclosure-label')) matches.push(rule.selectorText);
              if (rule.cssRules) visit(rule.cssRules);
            }
          };
          for (const sheet of document.styleSheets) {
            try { visit(sheet.cssRules); } catch (_) {}
          }
          return matches;
        });
        check('CSS не содержит широких селекторов summary span', broadSelectors.length === 0, broadSelectors);
      }
      disclosurePages.push({ page, details, summary, theme, gsapEnabled, pageId,
        video: recordDisclosure ? page.video() : null });
    }
  }
  const disclosureResults = [];
  const inspectDisclosureHold = async (item, state) => {
    const summary = item.summary;
    if (await item.details.evaluate(node => node.open) !== state) await summary.click();
    await waitForDisclosureSettled(item.page, 'details.flow-benchmark-method');
    await item.page.waitForFunction(() => {
      const status = document.querySelector('#flowoffload-benchmark-status');
      return status && !status.textContent.includes('Загружаю');
    });
    await summary.scrollIntoViewIfNeeded();
    await summary.hover();
    await summary.evaluate(node => {
      const details = node.parentElement;
      const card = node.closest('#flowoffload-benchmark');
      const motionTargets = [node, node.querySelector('.disclosure-label'), node.querySelector('.disclosure-chevron')]
        .filter(Boolean);
      window.__summaryRef = node;
      window.__summaryTargets = motionTargets;
      window.__summaryCardRef = card;
      window.__summaryRecords = 0;
      window.__summaryCardRecords = 0;
      new MutationObserver(records => { window.__summaryRecords += records.length; })
        .observe(details, { subtree: true, childList: true, characterData: true, attributes: true });
      new MutationObserver(records => { window.__summaryCardRecords += records.length; })
        .observe(card, { subtree: true, childList: true, characterData: true, attributes: true });
      const rect = node.getBoundingClientRect();
      const cardRect = card.getBoundingClientRect();
      window.__summaryBase = { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
        width: rect.width, height: rect.height, cardHeight: cardRect.height };
      window.__summaryMotion = { maxDelta: 0, maxCardHeightDelta: 0, maxTweens: 0, frames: 0 };
      const sample = () => {
        if (!window.__summaryMotion) return;
        const current = node.getBoundingClientRect();
        const currentCard = card.getBoundingClientRect();
        const base = window.__summaryBase;
        window.__summaryMotion.maxDelta = Math.max(window.__summaryMotion.maxDelta,
          ...['left', 'top', 'right', 'bottom', 'width', 'height'].map(key => Math.abs(current[key] - base[key])));
        window.__summaryMotion.maxCardHeightDelta = Math.max(window.__summaryMotion.maxCardHeightDelta,
          Math.abs(currentCard.height - base.cardHeight));
        window.__summaryMotion.maxTweens = Math.max(window.__summaryMotion.maxTweens,
          ...motionTargets.map(target => window.gsap?.getTweensOf(target).filter(tween => tween.isActive()).length || 0));
        window.__summaryMotion.frames += 1;
        requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    });
    const requestsBefore = apiRequests.filter(request => request.pageId === item.pageId
      && request.endpoint === 'offload/benchmark'
      && request.method === 'GET').length;
    await item.page.waitForTimeout(quickMotionProof ? 450 : 20000);
    const result = await summary.evaluate(node => ({
      sameNode: window.__summaryRef === node,
      maxDelta: window.__summaryMotion.maxDelta,
      maxCardHeightDelta: window.__summaryMotion.maxCardHeightDelta,
      maxTweens: window.__summaryMotion.maxTweens,
      frames: window.__summaryMotion.frames,
      mutations: window.__summaryRecords,
      cardMutations: window.__summaryCardRecords,
      transform: getComputedStyle(node).transform,
      labelTransform: getComputedStyle(node.querySelector('.disclosure-label')).transform,
      labelSize: getComputedStyle(node.querySelector('.disclosure-label')).fontSize,
      summarySize: getComputedStyle(node).fontSize,
      labelFamily: getComputedStyle(node.querySelector('.disclosure-label')).fontFamily,
      summaryFamily: getComputedStyle(node).fontFamily,
      headingText: node.textContent.trim(),
      open: node.parentElement.open,
    }));
    result.theme = item.theme;
    result.gsapEnabled = item.gsapEnabled;
    result.state = state ? 'open' : 'closed';
    result.polls = apiRequests.filter(request => request.pageId === item.pageId
      && request.endpoint === 'offload/benchmark'
      && request.method === 'GET').length - requestsBefore;
    disclosureResults.push(result);
    check(`${item.theme}/${item.gsapEnabled ? 'GSAP' : 'CSS'}/${result.state}: наблюдается точный заголовок`,
      result.headingText.includes('Методика и ограничения'), result);
    check(`${item.theme}/${item.gsapEnabled ? 'GSAP' : 'CSS'}/${result.state}: summary не масштабируется и не двигается`,
      result.maxDelta <= 0.5 && result.transform === 'none' && result.labelTransform === 'none', result);
    check(`${item.theme}/${item.gsapEnabled ? 'GSAP' : 'CSS'}/${result.state}: обычная типографика`,
      result.labelSize === result.summarySize && result.labelFamily === result.summaryFamily, result);
    check(`${item.theme}/${item.gsapEnabled ? 'GSAP' : 'CSS'}/${result.state}: polling не меняет disclosure DOM`,
      result.sameNode && result.mutations === 0 && (quickMotionProof || result.polls >= 12), result);
    check(`${item.theme}/${item.gsapEnabled ? 'GSAP' : 'CSS'}/${result.state}: polling сохраняет высоту карточки`,
      result.maxCardHeightDelta <= 0.5, result);
  };
  for (const item of disclosurePages) await inspectDisclosureHold(item, false);
  for (const item of disclosurePages) await inspectDisclosureHold(item, true);
  for (const item of disclosurePages) {
    await item.page.evaluate(() => document.activeElement?.blur());
    let keyboardFocused = false;
    for (let index = 0; index < 100 && !keyboardFocused; index += 1) {
      await item.page.keyboard.press('Tab');
      keyboardFocused = await item.summary.evaluate(node => node.matches(':focus-visible'));
    }
    const keyboard = await item.summary.evaluate(node => ({ focus: node.matches(':focus-visible'),
      outline: getComputedStyle(node).outlineStyle }));
    await item.page.keyboard.press('Space');
    await item.page.waitForFunction(() => document.querySelector('details.flow-benchmark-method')?.open === false);
    await item.page.keyboard.press('Enter');
    await item.page.waitForFunction(() => document.querySelector('details.flow-benchmark-method')?.open === true);
    check(`${item.theme}/${item.gsapEnabled ? 'GSAP' : 'CSS'}: Enter/Space и focus-visible работают`,
      keyboard.focus && keyboard.outline === 'solid', keyboard);
    await item.page.close();
    if (item.video) fs.copyFileSync(await item.video.path(), path.join(videoDir, `disclosure-polling-${videoSide}.webm`));
  }
  const stalePage = await browser.newPage({ viewport: { width: 1280, height: 900 }, colorScheme: 'dark' });
  await stalePage.addInitScript(() => localStorage.setItem('z2k-theme', 'dark'));
  let releaseHeldStatus;
  let signalHeldStatusSent;
  const heldStatusGate = new Promise(resolve => { releaseHeldStatus = resolve; });
  const heldStatusSent = new Promise(resolve => { signalHeldStatusSent = resolve; });
  let heldFirstStatus = true;
  await stalePage.route(url => url.pathname === '/cgi-bin/api/offload/benchmark'
    && url.searchParams.get('view') === 'status', async route => {
    if (!heldFirstStatus) { await route.continue(); return; }
    heldFirstStatus = false;
    await heldStatusGate;
    await route.fulfill({ status: 200, contentType: 'application/json; charset=utf-8',
      body: JSON.stringify({ ok: true, active: false, status: 'idle', result: null }) });
    signalHeldStatusSent();
  });
  const heldStatusRequest = stalePage.waitForRequest(request => {
    const url = new URL(request.url());
    return url.pathname === '/cgi-bin/api/offload/benchmark' && url.searchParams.get('view') === 'status';
  }, { timeout: 5000 });
  await stalePage.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(stalePage, 'toggles');
  await heldStatusRequest;
  const staleCard = await stalePage.locator('#flowoffload-benchmark').elementHandle();
  await staleCard.evaluate(card => {
    window.__staleBenchmarkCard = card;
    window.__staleBenchmarkMutations = 0;
    window.__staleBenchmarkText = card.querySelector('#flowoffload-benchmark-status')?.textContent || '';
    new MutationObserver(records => { window.__staleBenchmarkMutations += records.length; })
      .observe(card, { subtree: true, childList: true, characterData: true, attributes: true });
  });
  await stalePage.locator('#nav a[data-route="tiktok"]').click();
  await waitForRenderedRoute(stalePage, 'tiktok');
  releaseHeldStatus();
  await heldStatusSent;
  await stalePage.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  const staleRoute = await stalePage.evaluate(() => ({ route: document.body.dataset.page,
    connected: window.__staleBenchmarkCard.isConnected,
    mutations: window.__staleBenchmarkMutations,
    statusBefore: window.__staleBenchmarkText,
    statusAfter: window.__staleBenchmarkCard.querySelector('#flowoffload-benchmark-status')?.textContent || '' }));
  check('запаздывающий ответ polling не меняет снятую со страницы карточку',
    staleRoute.route === 'tiktok' && !staleRoute.connected && staleRoute.mutations === 0
      && staleRoute.statusAfter === staleRoute.statusBefore, staleRoute);
  await stalePage.close();
  check('polling выполнялся в течение открытого и закрытого ожиданий', quickMotionProof
    || disclosureResults.every(result => result.polls >= 12),
    disclosureResults.map(({ theme, gsapEnabled, state, polls }) => ({ theme, gsapEnabled, state, polls })));
  fs.writeFileSync(path.join(videoDir, `disclosure-polling-${videoSide}.json`), JSON.stringify(disclosureResults, null, 2));

  const report = { failures, navigationFrames: navigationFrames.length, coldLoads: coldLoadRuns.length,
    themeRequests, profileRequests, collapseFrames: collapseFrames.length, fastFrames: fastFrames.length,
    disclosureResults, staleRoute };
  fs.writeFileSync(path.join(videoDir, `shell-motion-report-${videoSide}.json`), JSON.stringify(report, null, 2));
  await routeTestPage.close().catch(() => {});
  if (failures.length) {
    fs.writeFileSync(path.join(videoDir, `shell-motion-failures-${videoSide}.json`), JSON.stringify(failures, null, 2));
    throw new Error(`shell motion regressions: ${JSON.stringify(failures.slice(0, 20))}`);
  }
}

async function assertDiagDynamicStates(page, label, viewport = '1440') {
  if (await page.locator('#probe-run').count()) {
  const requestStart = apiRequests.length;
  await page.locator('#probe-domain').fill('https://example.test/path');
  await page.locator('#probe-run').click();
  await page.locator('#probe-result .probe-stage').first().waitFor({ state: 'visible' });
  const probeRequest = apiRequests.slice(requestStart).find(request => request.endpoint === 'diag/probe');
  assert.ok(probeRequest, `${label}: clicking Probe sends the local fixture request`);
  assert.equal(probeRequest.method, 'POST', `${label}: domain probe uses POST`);
  assert.equal(probeRequest.contentType, 'application/x-www-form-urlencoded',
    `${label}: normalized domain is sent as a form field`);
  assert.equal(probeRequest.body, 'domain=example.test',
    `${label}: URL scheme and path are removed before submission (${JSON.stringify(probeRequest)})`);
  assert.deepEqual(await page.locator('#probe-result .probe-stage').evaluateAll(nodes => nodes.map(node => ({
    label: node.textContent.replace(/\s+/g, ' ').trim(),
    className: node.className,
  }))), [
    { label: 'dnsok', className: 'probe-stage good' },
    { label: 'tcpfail', className: 'probe-stage bad' },
    { label: 'tlsskip', className: 'probe-stage muted' },
  ], `${label}: each probe stage carries its result state`);
  assert.equal(await page.locator('#probe-result .probe-lat').innerText(), '284 мс');
  assert.equal(await page.locator('#probe-result .probe-line').first().innerText(),
    'Адреса\n203.0.113.8, 203.0.113.9');
  assert.equal(await page.locator('#probe-result .probe-line').nth(1).innerText(),
    'Причина\ncertificate <expired>', `${label}: report content is escaped into visible text`);
  assert.equal(await page.locator('#probe-result .probe-verdict').innerText(), 'Blocked during TLS');
  assert.equal(await page.locator('#probe-result .probe-verdict').getAttribute('class'), 'probe-verdict hot');
  assert.equal(await page.locator('#probe-result script').count(), 0,
    `${label}: report text cannot inject markup`);
  await page.locator('#probe-result .probe-raw summary').click();
  assert.equal(await page.locator('#probe-result .probe-raw pre').innerText(), probeReportFixture,
    `${label}: complete dynamic report remains available verbatim`);
  if (screenshotDir) {
    await page.evaluate(() => window.scrollTo(0, 0));
    const screenshotBase = `${label.replace(/[^a-z\d]+/gi, '-').toLowerCase()}-${viewport}-diag-dynamic`;
    await page.screenshot({ path: path.join(screenshotDir, `${screenshotBase}.png`),
      fullPage: viewport === '390' });
  }
  }
}
async function assertMobileSelectedDomainEditor(page, appearance) {
  await page.waitForFunction(() => document.querySelectorAll('#wl-list .wl-row').length === 16);
  const saveCount = apiRequests.filter(request => request.endpoint === 'extra-domains/save'
    && request.method === 'POST').length;
  await page.locator('#wl-search').fill('rutracker.org');
  await page.locator('#wl-select').click();
  assert.equal(await page.locator('#wl-count').innerText(), 'Найдено 1 из 16 · Выбрано 1',
    `${appearance}/390: select-found operates on the filtered mobile list`);
  assert.deepEqual(await page.locator('#wl-list [data-row]:checked').evaluateAll(nodes =>
    nodes.map(node => ({ id: node.dataset.row, domain: node.closest('.wl-row').querySelector('span').textContent.trim() }))),
  [{ id: '1', domain: 'rutracker.org' }], `${appearance}/390: only the matching domain is selected`);
  await page.locator('#wl-edit-selected').click();
  await page.locator('#wl-editor').waitFor({ state: 'visible' });
  assert.equal(await page.locator('#wl-editor-title').innerText(), 'Редактирование выбранных: 1');
  assert.equal(await page.locator('#wl-editor-hint').innerText(),
    'Замените или удалите строки ниже. Невыбранные записи останутся на месте.');
  assert.equal(await page.locator('#wl-editor-text').inputValue(), 'rutracker.org');
  const controls = await page.locator('#wl-card').evaluate(root => ({
    searchDisabled: root.querySelector('#wl-search').disabled,
    selectDisabled: root.querySelector('#wl-select').disabled,
    editSelectedDisabled: root.querySelector('#wl-edit-selected').disabled,
    saveDisabled: root.querySelector('#wl-save').disabled,
    cancelDisabled: root.querySelector('#wl-cancel').disabled,
    editorDisabled: root.querySelector('#wl-editor-text').disabled,
  }));
  assert.deepEqual(controls, {
    searchDisabled: true, selectDisabled: true, editSelectedDisabled: true,
    saveDisabled: false, cancelDisabled: false, editorDisabled: false,
  }, `${appearance}/390: list actions lock while editor actions remain available (${JSON.stringify(controls)})`);
  assert.equal(apiRequests.filter(request => request.endpoint === 'extra-domains/save'
    && request.method === 'POST').length, saveCount,
  `${appearance}/390: opening the bulk editor performs no save request`);
  const frame = await page.evaluate(() => ({
    width: document.documentElement.clientWidth, scrollWidth: document.documentElement.scrollWidth,
  }));
  assert.ok(frame.scrollWidth <= frame.width,
    `${appearance}/390: selected editor stays within the mobile viewport (${JSON.stringify(frame)})`);
  if (screenshotDir) {
    await page.evaluate(() => window.scrollTo(0, 0));
    await page.screenshot({ path: path.join(screenshotDir,
      `${appearance}-390-extra-domains-selected-editor.png`), fullPage: true });
  }
  await page.locator('#wl-cancel').click();
  assert.equal(await page.locator('#wl-editor').evaluate(node => node.hidden), true,
    `${appearance}/390: the fixture editor closes without changing the saved list`);
}

const longStateGroupName = 'long-group-name-for-responsive-layout-coverage.net';
async function assertStateGroupDisclosure(page, label) {
  const longGroup = page.locator('.state-table tbody.sg').filter({
    has: page.locator('.sg-name', { hasText: longStateGroupName }),
  });
  assert.equal(await longGroup.count(), 1, `${label}: fixture renders one long registrable-domain group`);
  const toggle = longGroup.locator('.sg-toggle');
  if (await toggle.getAttribute('aria-expanded') === 'true') await toggle.click();
  const collapsed = await longGroup.evaluate(group => ({
    name: group.querySelector('.sg-name')?.textContent.trim(),
    isClosed: group.classList.contains('sg-closed'),
    expanded: group.querySelector('.sg-toggle')?.getAttribute('aria-expanded'),
    members: group.querySelectorAll('tr.sg-member').length,
    visibleMembers: Array.from(group.querySelectorAll('tr.sg-member'))
      .filter(row => row.getBoundingClientRect().height > 0).length,
  }));
  assert.equal(collapsed.name, longStateGroupName, `${label}: long group name remains the registrable domain`);
  assert.equal(collapsed.isClosed, true, `${label}: group can be collapsed`);
  assert.equal(collapsed.expanded, 'false');
  assert.equal(collapsed.members, 2, `${label}: long group has both address-family entries`);
  assert.equal(collapsed.visibleMembers, 0, `${label}: collapsed group hides its member rows`);
  if (screenshotDir) {
    await longGroup.locator('.sg-head').scrollIntoViewIfNeeded();
    await page.screenshot({ path: path.join(screenshotDir,
      `${label.replace(/[^a-z\d]+/gi, '-').toLowerCase()}-state-group-collapsed.png`) });
  }

  await toggle.click();
  const expanded = await longGroup.evaluate(group => {
    const members = Array.from(group.querySelectorAll('tr.sg-member'));
    const hostCells = members.map(row => {
      const cell = row.querySelector('.state-host');
      const family = cell.querySelector('.fam-tag');
      const cellRect = cell.getBoundingClientRect();
      const familyRect = family.getBoundingClientRect();
      return { family: family.textContent.trim(), cellWidth: cellRect.width,
        familyRight: familyRect.right, cellRight: cellRect.right };
    });
    const name = group.querySelector('.sg-name');
    const nameStyle = getComputedStyle(name);
    return {
      isClosed: group.classList.contains('sg-closed'),
      expanded: group.querySelector('.sg-toggle')?.getAttribute('aria-expanded'),
      visibleMembers: members.filter(row => row.getBoundingClientRect().height > 0).length,
      hostCells,
      name: { textOverflow: nameStyle.textOverflow, whiteSpace: nameStyle.whiteSpace,
        scrollWidth: name.scrollWidth, clientWidth: name.clientWidth },
      documentWidth: document.documentElement.clientWidth,
      documentScrollWidth: document.documentElement.scrollWidth,
    };
  });
  assert.equal(expanded.isClosed, false, `${label}: group expands in place`);
  assert.equal(expanded.expanded, 'true');
  assert.equal(expanded.visibleMembers, 2, `${label}: expanded group reveals both rows`);
  assert.deepEqual(expanded.hostCells.map(cell => cell.family).sort(), ['IPv4', 'IPv6'],
    `${label}: repeated domain entries keep their IPv4 and IPv6 badges (${JSON.stringify(expanded.hostCells)})`);
  assert.ok(expanded.hostCells.every(cell => cell.familyRight <= cell.cellRight + 0.5),
    `${label}: family badges stay inside the host cells (${JSON.stringify(expanded.hostCells)})`);
  assert.equal(expanded.name.textOverflow, 'ellipsis', `${label}: long group title has a bounded ellipsis`);
  assert.equal(expanded.name.whiteSpace, 'nowrap');
  assert.ok(expanded.name.scrollWidth > expanded.name.clientWidth,
    `${label}: long group title exercises actual ellipsis (${JSON.stringify(expanded.name)})`);
  assert.ok(expanded.documentScrollWidth <= expanded.documentWidth,
    `${label}: expanded group does not cause page overflow (${JSON.stringify(expanded)})`);
  if (screenshotDir) {
    await page.screenshot({ path: path.join(screenshotDir,
      `${label.replace(/[^a-z\d]+/gi, '-').toLowerCase()}-state-group-expanded.png`) });
  }

  await toggle.click();
  assert.equal(await toggle.getAttribute('aria-expanded'), 'false', `${label}: expanded group collapses again`);
  assert.equal(await longGroup.locator('tr.sg-member:visible').count(), 0,
    `${label}: the second collapse hides both rows`);
  await toggle.click();
  assert.equal(await toggle.getAttribute('aria-expanded'), 'true', `${label}: test leaves a visible data row for geometry checks`);

  const addresses = await page.locator('.state-table td.state-host').evaluateAll(cells => cells
    .filter(cell => ['192.0.2.44', '2001:db8:1234:5678::44'].includes(cell.textContent.trim()))
    .map(cell => ({ text: cell.textContent.trim(), grouped: cell.closest('tbody')?.classList.contains('sg') || false,
      familyBadge: Boolean(cell.querySelector('.fam-tag')) }))
    .sort((left, right) => left.text.localeCompare(right.text)));
  assert.deepEqual(addresses, [
    { text: '192.0.2.44', grouped: false, familyBadge: false },
    { text: '2001:db8:1234:5678::44', grouped: false, familyBadge: false },
  ], `${label}: literal IPv4 and IPv6 addresses remain standalone entries (${JSON.stringify(addresses)})`);
}

async function assertStrategyTabsAllowManualScroll(page, label) {
  const position = await page.locator('.strat-tabs').evaluate(async tabs => {
    const maxScroll = tabs.scrollWidth - tabs.clientWidth;
    tabs.scrollLeft = maxScroll;
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    tabs.scrollLeft = 0;
    await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)));
    return { maxScroll, scrollLeft: tabs.scrollLeft };
  });
  assert.ok(position.maxScroll > 0, `${label}: narrow tab row can scroll to hidden tabs (${JSON.stringify(position)})`);
  assert.equal(position.scrollLeft, 0, `${label}: manual scrolling stays at the user's selected position (${JSON.stringify(position)})`);
}

async function readSwitchVisuals(page) {
  return page.locator('#app .switch').evaluateAll(controls => {
    const tokenColor = name => {
      const probe = document.createElement('span');
      probe.style.backgroundColor = `var(${name})`;
      document.body.appendChild(probe);
      const color = getComputedStyle(probe).backgroundColor;
      probe.remove();
      return color;
    };
    return controls.map(control => {
      const input = control.querySelector('input[type="checkbox"]');
      const slider = control.querySelector('.slider');
      const thumb = getComputedStyle(slider, '::before');
      const matrix = thumb.transform === 'none' ? new DOMMatrixReadOnly() : new DOMMatrixReadOnly(thumb.transform);
      const key = control.closest('[data-key]')?.dataset.key || input.id;
      return {
        key,
        checked: input.checked,
        disabled: input.disabled,
        state: control.classList.contains('is-unknown') ? 'unknown' : 'known',
        busy: control.getAttribute('aria-busy'),
        track: getComputedStyle(slider).backgroundColor,
        trackImage: getComputedStyle(slider).backgroundImage,
        unknownMarker: getComputedStyle(control, '::after').content,
        expectedTrack: tokenColor(input.checked ? '--accent' : '--switch-track'),
        thumbX: matrix.m41,
        expectedThumbX: input.checked ? 18 : 0,
        inlineOffset: control.style.getPropertyValue('--z2k-switch-offset'),
        inlineTrack: control.style.getPropertyValue('--z2k-switch-track'),
      };
    });
  });
}

async function waitForSwitchTransitions(page) {
  await page.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'),
    null, { timeout: 5000 });
  const maxDuration = await page.evaluate(() => {
    const value = getComputedStyle(document.documentElement).getPropertyValue('--dur-base').trim();
    const number = Number.parseFloat(value) || 0;
    return number * (value.endsWith('ms') ? 1 : 1000) + 30;
  });
  await page.waitForTimeout(maxDuration);
  await page.waitForFunction(() => [...document.querySelectorAll('#app .switch .slider')]
    .every(slider => slider.getAnimations({ subtree: true }).every(animation => animation.playState !== 'running')),
  null, { timeout: 1500 });
}

function assertSwitchVisuals(visuals, expected, label) {
  const mismatches = visuals.filter(item => item.checked !== (expected[item.key] === '1')
    || item.track !== item.expectedTrack || Math.abs(item.thumbX - item.expectedThumbX) > 0.1
    || item.inlineOffset || item.inlineTrack || item.state !== 'known');
  assert.deepEqual(mismatches, [], `${label}: checked → дорожка/кружок без inline override (${JSON.stringify(mismatches)})`);
}

async function runSwitchVisualTests() {
  const switchKeys = ['category_youtube', 'category_rkn', 'category_discord_voice', 'customd',
    'dynamic_ttl', 'ppe', 'fastroute', 'auto_update', 'autohostlist'];
  const values = state => Object.fromEntries(switchKeys.map(key => [key, state[key] || '0']));
  const allOn = values(Object.fromEntries(switchKeys.map(key => [key, '1'])));
  const allOff = values({});
  const mixed = values({ category_youtube: '1', category_rkn: '0', category_discord_voice: '1',
    customd: '0', dynamic_ttl: '1', ppe: '0', fastroute: '1', auto_update: '0', autohostlist: '1' });

  async function createPage({ theme = 'dark', gsap = true, state = mixed, delayed = false, failStatus = false } = {}) {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, colorScheme: theme });
    const togglePosts = [];
    let currentState = state;
    let statusCalls = 0;
    page.on('request', request => {
      if (request.method() === 'POST' && new URL(request.url()).pathname.includes('/toggle/')) togglePosts.push(request.url());
    });
    await page.addInitScript(mode => localStorage.setItem('z2k-theme', mode), theme);
    if (!gsap) await page.route('**/assets/vendor/gsap.js*', route => route.abort('blockedbyclient'));
    let hold = delayed;
    let signalFirstStatus;
    const firstStatus = new Promise(resolve => { signalFirstStatus = resolve; });
    const pending = [];
    page.route('**/cgi-bin/api/status', async route => {
      statusCalls += 1;
      if (pending.length === 0 && hold) signalFirstStatus();
      if (hold) await new Promise(resolve => pending.push(resolve));
      if (failStatus) {
        await route.fulfill({ status: 503, contentType: 'application/json',
          body: JSON.stringify({ ok: false, error: 'Тестовая недоступность /status' }) });
        return;
      }
      const fixture = structuredClone(statusFixture);
      fixture.toggles = { ...fixture.toggles, ...currentState };
      fixture.capabilities = { ...fixture.capabilities, ppe: true };
      await route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(fixture) });
    });
    return {
      page,
      firstStatus,
      togglePosts,
      get statusCalls() { return statusCalls; },
      setState(next) { currentState = next; },
      releaseStatus() { hold = false; pending.splice(0).forEach(resolve => resolve()); },
    };
  }

  const delayed = await createPage({ state: allOn, delayed: true });
  await delayed.page.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(delayed.page, 'toggles');
  await delayed.firstStatus;
  const delayedBefore = await readSwitchVisuals(delayed.page);
  assert.ok(delayedBefore.length >= switchKeys.length, 'задержанный /status оставляет все строки режимов на странице');
  delayed.releaseStatus();
  await delayed.page.waitForFunction(() => {
    const input = document.querySelector('[data-key="category_youtube"] input');
    return input && !input.disabled;
  }, null, { timeout: 3000 });
  await waitForSwitchTransitions(delayed.page);
  const delayedAfter = await readSwitchVisuals(delayed.page);
  console.log(`Измерение задержанного /status: ${delayedAfter.filter(item => item.checked).length}/${delayedAfter.length} включены; дорожка ${delayedAfter[0].track}; кружок ${delayedAfter[0].thumbX}px; inline overrides пусты`);
  assertSwitchVisuals(delayedAfter, allOn, 'задержанный /status со всеми включёнными режимами');
  if (switchScreenshotDir) {
    const reproducedBefore = await delayed.page.evaluate(() => {
      const legacy = document.createElement('style');
      legacy.id = 'legacy-switch-variables';
      legacy.textContent = '.switch .slider { background: var(--z2k-switch-track, var(--switch-track)) !important; } .switch .slider::before { transform: translateX(var(--z2k-switch-offset, 0px)) !important; }';
      document.head.appendChild(legacy);
      document.querySelectorAll('#app .switch').forEach(control => {
        control.style.setProperty('--z2k-switch-offset', '0px');
        control.style.setProperty('--z2k-switch-track', 'var(--switch-track)');
      });
      return true;
    });
    assert.equal(reproducedBefore, true);
    await waitForSwitchTransitions(delayed.page);
    const beforeVisuals = await readSwitchVisuals(delayed.page);
    assert.ok(beforeVisuals.every(item => item.checked && item.inlineOffset === '0px' && item.inlineTrack),
      'контрольный снимок воспроизводит старое inline-состояние при checked=true');
    await delayed.page.screenshot({ path: path.join(switchScreenshotDir, 'before-stale-inline.png'), fullPage: true });
    await delayed.page.evaluate(() => {
      document.getElementById('legacy-switch-variables')?.remove();
      document.querySelectorAll('#app .switch').forEach(control => {
        control.style.removeProperty('--z2k-switch-offset');
        control.style.removeProperty('--z2k-switch-track');
      });
    });
    await waitForSwitchTransitions(delayed.page);
    const afterVisuals = await readSwitchVisuals(delayed.page);
    assertSwitchVisuals(afterVisuals, allOn, 'после удаления старого inline override');
    await delayed.page.screenshot({ path: path.join(switchScreenshotDir, 'after-backend-state.png'), fullPage: true });
    fs.writeFileSync(path.join(switchScreenshotDir, 'measurements.json'), JSON.stringify({
      note: 'До: CSS/inline variables старого syncSwitches воспроизведены при backend=1; после: реальный checked определяет вид.',
      before: beforeVisuals,
      after: afterVisuals,
    }, null, 2) + '\n');
  }
  assert.ok(delayedBefore.every(item => item.state === 'unknown' && item.busy === 'true' && item.disabled),
    `пока API отвечает, состояние помечено неизвестным (${JSON.stringify(delayedBefore)})`);
  assert.ok(delayedBefore.every(item => item.trackImage.includes('repeating-linear-gradient')
    && Math.abs(item.thumbX - 9) < 0.1 && item.unknownMarker === '"?"'),
  `до ответа API тумблеры явно показывают неизвестное состояние (${JSON.stringify(delayedBefore)})`);
  assert.equal(await delayed.page.evaluate(() => window.gsap?.version || ''), '3.15.0', 'проверка выполняется с GSAP');
  const delayedTransitions = await delayed.page.locator('#app .switch').first().evaluate(node => ({
    track: getComputedStyle(node.querySelector('.slider')).transitionProperty,
    thumb: getComputedStyle(node.querySelector('.slider'), '::before').transitionProperty,
  }));
  assert.match(delayedTransitions.track, /background/, 'GSAP не отключает CSS-переход дорожки');
  assert.match(delayedTransitions.thumb, /transform/, 'GSAP не отключает CSS-переход кружка');
  assert.deepEqual(delayed.togglePosts, [], 'GET /status не отправляет POST для визуальной синхронизации');
  await delayed.page.close();

  const off = await createPage({ state: allOff });
  await off.page.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(off.page, 'toggles');
  await off.page.waitForFunction(() => [...document.querySelectorAll('#app .switch input')]
    .every(input => !input.closest('.switch').classList.contains('is-unknown')), null, { timeout: 3000 });
  await waitForSwitchTransitions(off.page);
  assertSwitchVisuals(await readSwitchVisuals(off.page), allOff, 'все режимы выключены');
  assert.deepEqual(off.togglePosts, [], 'GET /status со всеми нулями не отправляет POST');
  await off.page.close();

  const mixedPage = await createPage({ state: mixed });
  await mixedPage.page.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(mixedPage.page, 'toggles');
  await mixedPage.page.waitForFunction(() => [...document.querySelectorAll('#app .switch input')]
    .every(input => !input.closest('.switch').classList.contains('is-unknown')), null, { timeout: 3000 });
  await waitForSwitchTransitions(mixedPage.page);
  assertSwitchVisuals(await readSwitchVisuals(mixedPage.page), mixed, 'смешанные значения backend');
  await mixedPage.page.evaluate(() => {
    document.querySelectorAll('#app .switch input').forEach(input => { input.checked = !input.checked; });
  });
  await mixedPage.page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))));
  await waitForSwitchTransitions(mixedPage.page);
  const programmatic = await readSwitchVisuals(mixedPage.page);
  const inverted = Object.fromEntries(Object.entries(mixed).map(([key, value]) => [key, value === '1' ? '0' : '1']));
  assertSwitchVisuals(programmatic, inverted, 'программное изменение checked без change');
  assert.deepEqual(mixedPage.togglePosts, [], 'присваивание checked без change не отправляет POST');
  await mixedPage.page.close();

  for (const theme of ['dark', 'light']) {
    for (const gsap of [true, false]) {
      const pageContext = await createPage({ theme, gsap, state: mixed });
      await pageContext.page.goto(`${base}/#/toggles`);
      await waitForRenderedRoute(pageContext.page, 'toggles');
      await pageContext.page.waitForFunction(() => [...document.querySelectorAll('#app .switch input')]
        .every(input => !input.closest('.switch').classList.contains('is-unknown')), null, { timeout: 3000 });
      await waitForSwitchTransitions(pageContext.page);
      assertSwitchVisuals(await readSwitchVisuals(pageContext.page), mixed, `${theme}, GSAP ${gsap ? 'включён' : 'отключён'}`);
      if (gsap) {
        const transitions = await pageContext.page.locator('#app .switch').first().evaluate(control => ({
          track: getComputedStyle(control.querySelector('.slider')).transitionProperty,
          thumb: getComputedStyle(control.querySelector('.slider'), '::before').transitionProperty,
        }));
        assert.match(transitions.track, /background/, `${theme}: CSS сохраняет переход дорожки при motion-ready`);
        assert.match(transitions.thumb, /transform/, `${theme}: CSS сохраняет переход кружка при motion-ready`);
      }
      await pageContext.page.close();
    }
  }

  const failure = await createPage({ state: allOff });
  let failedTogglePosts = 0;
  await failure.page.route('**/cgi-bin/api/toggle/**', route => {
    failedTogglePosts += 1;
    return route.fulfill({ status: 500, contentType: 'application/json', body: JSON.stringify({ ok: false, error: 'Тестовая ошибка применения' }) });
  });
  await failure.page.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(failure.page, 'toggles');
  await failure.page.locator('[data-key="category_youtube"] input').check({ force: true });
  await failure.page.waitForFunction(() => document.querySelector('[data-key="category_youtube"] input')?.checked === false,
    null, { timeout: 3000 });
  assert.equal(failedTogglePosts, 1, 'ошибка применения получена после одного пользовательского изменения');
  await waitForSwitchTransitions(failure.page);
  assertSwitchVisuals(await readSwitchVisuals(failure.page), allOff, 'откат после ошибки применения');
  await failure.page.close();

  const jobFailure = await createPage({ state: allOff });
  await jobFailure.page.route('**/cgi-bin/api/toggle/**', route => route.fulfill({
    status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, job: 'switch-failure-fixture' }),
  }));
  await jobFailure.page.route('**/cgi-bin/api/job*', route => route.fulfill({
    status: 200, contentType: 'application/json', body: JSON.stringify({ done: true, exit: 1, status: 'failed', log: 'Тестовый провал задачи' }),
  }));
  await jobFailure.page.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(jobFailure.page, 'toggles');
  await jobFailure.page.locator('[data-key="category_youtube"] input').check({ force: true });
  await jobFailure.page.waitForFunction(() => {
    const input = document.querySelector('[data-key="category_youtube"] input');
    return input?.checked === false && !input.disabled && !input.closest('.switch').classList.contains('loading');
  }, null, { timeout: 3000 });
  await waitForSwitchTransitions(jobFailure.page);
  assertSwitchVisuals(await readSwitchVisuals(jobFailure.page), allOff, 'откат после ошибки фоновой задачи');
  await jobFailure.page.close();

  const restart = await createPage({ state: allOff });
  await restart.page.route('**/cgi-bin/api/toggle/**', route => route.fulfill({
    status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, job: 'switch-restart-fixture' }),
  }));
  await restart.page.route('**/cgi-bin/api/job*', route => route.fulfill({
    status: 200, contentType: 'application/json', body: JSON.stringify({ done: true, exit: 0, status: 'done', log: 'Тестовый рестарт завершён' }),
  }));
  await restart.page.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(restart.page, 'toggles');
  const statusCallsBeforeRestart = restart.statusCalls;
  restart.setState({ ...allOff, category_youtube: '1' });
  await restart.page.locator('[data-key="category_youtube"] input').check({ force: true });
  await restart.page.waitForFunction(() => {
    const input = document.querySelector('[data-key="category_youtube"] input');
    return input?.checked === true && !input.disabled && !input.closest('.switch').classList.contains('loading');
  }, null, { timeout: 3000 });
  await waitForCondition(() => restart.statusCalls > statusCallsBeforeRestart, 'GET /status после фонового рестарта', 3000);
  await waitForSwitchTransitions(restart.page);
  assertSwitchVisuals(await readSwitchVisuals(restart.page), { ...allOff, category_youtube: '1' },
    'GET /status после завершения рестарта');
  assert.ok(restart.statusCalls > statusCallsBeforeRestart, 'после фонового рестарта перечитан backend status');
  await restart.page.close();

  const unavailable = await createPage({ failStatus: true });
  await unavailable.page.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(unavailable.page, 'toggles');
  await unavailable.page.locator('#toggles-error').waitFor({ state: 'visible' });
  const unavailableVisuals = await readSwitchVisuals(unavailable.page);
  assert.ok(unavailableVisuals.every(item => item.state === 'unknown' && item.busy === 'true' && item.disabled),
    `ошибка API показывает неизвестное состояние вместо выключенных режимов (${JSON.stringify(unavailableVisuals)})`);
  assert.ok(unavailableVisuals.every(item => item.trackImage.includes('repeating-linear-gradient')
    && Math.abs(item.thumbX - 9) < 0.1 && item.unknownMarker === '"?"'),
  `ошибка API визуально отличается от выключенного состояния (${JSON.stringify(unavailableVisuals)})`);
  await unavailable.page.close();

  const unavailableAfterKnownOn = await createPage({ state: mixed });
  await unavailableAfterKnownOn.page.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(unavailableAfterKnownOn.page, 'toggles');
  await unavailableAfterKnownOn.page.waitForFunction(() => {
    const input = document.querySelector('[data-key="category_rkn"] input');
    return input && !input.disabled && !input.closest('.switch').classList.contains('is-unknown');
  }, null, { timeout: 3000 });
  await unavailableAfterKnownOn.page.route('**/cgi-bin/api/status', route => route.fulfill({
    status: 503, contentType: 'application/json', body: JSON.stringify({ ok: false, error: 'Тестовая ошибка повторного /status' }),
  }));
  await unavailableAfterKnownOn.page.route('**/cgi-bin/api/toggle/**', route => route.fulfill({
    status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true }),
  }));
  await unavailableAfterKnownOn.page.locator('[data-key="category_rkn"] input').focus();
  await unavailableAfterKnownOn.page.keyboard.press('Space');
  await unavailableAfterKnownOn.page.waitForFunction(() => {
    const input = document.querySelector('[data-key="category_rkn"] input');
    return input?.checked === true && input.closest('.switch').classList.contains('is-unknown');
  }, null, { timeout: 3000 });
  const staleKnownVisuals = await readSwitchVisuals(unavailableAfterKnownOn.page);
  const staleKnownOn = staleKnownVisuals.find(item => item.key === 'category_rkn');
  assert.equal(staleKnownOn.checked, true, 'неподтверждённый checked остаётся только техническим значением');
  assert.equal(staleKnownOn.state, 'unknown');
  assert.ok(staleKnownOn.trackImage.includes('repeating-linear-gradient') && staleKnownOn.unknownMarker === '"?"',
    `повторная ошибка /status визуально перекрывает устаревшее checked=true (${JSON.stringify(staleKnownOn)})`);
  await unavailableAfterKnownOn.page.close();

  const history = await createPage({ state: mixed });
  await history.page.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(history.page, 'toggles');
  await waitForSwitchTransitions(history.page);
  assertSwitchVisuals(await readSwitchVisuals(history.page), mixed, 'первая загрузка перед навигацией');
  await history.page.locator('a[data-route="dashboard"]').click();
  await waitForRenderedRoute(history.page, 'dashboard');
  for (const route of ['toggles', 'dashboard', 'toggles']) {
    await history.page.evaluate(name => { location.hash = `#/${name}`; }, route);
    await waitForRenderedRoute(history.page, route);
  }
  await waitForSwitchTransitions(history.page);
  assertSwitchVisuals(await readSwitchVisuals(history.page), mixed, 'быстрый возврат на страницу режимов');
  await history.page.reload();
  await waitForRenderedRoute(history.page, 'toggles');
  await waitForSwitchTransitions(history.page);
  assertSwitchVisuals(await readSwitchVisuals(history.page), mixed, 'Reload');
  await history.page.locator('a[data-route="dashboard"]').click();
  await waitForRenderedRoute(history.page, 'dashboard');
  await history.page.goBack();
  await waitForRenderedRoute(history.page, 'toggles');
  await waitForSwitchTransitions(history.page);
  assertSwitchVisuals(await readSwitchVisuals(history.page), mixed, 'Back');
  await history.page.goForward();
  await waitForRenderedRoute(history.page, 'dashboard');
  await history.page.close();

  console.log('PASS: checked, дорожка, кружок и unknown для задержанного/ошибочного /status, dark/light, GSAP/fallback, программного изменения, отката, маршрутов и истории');
}

  const shellOnly = process.env.OPENWRT_SHELL_ONLY === '1';
  const motionOnly = process.env.OPENWRT_MOTION_ONLY === '1' || shellOnly;
const switchOnly = process.env.OPENWRT_SWITCH_ONLY === '1';
let testedRouteCount = 0;
let totalModuleResponses = 0;
  if (motionOnly || switchOnly) {
  holdStatusResponses = false;
  tgRunningFixture = true;
}

try {
  if (switchOnly) {
    await runSwitchVisualTests();
  } else if (!motionOnly) {
  // The old URL is a representative filter-list match. The renamed URL must
  // never be requested as a required bootstrap dependency.
  let oldBootstrapRequests = 0;
  const legacyBlocked = await browser.newPage();
  await legacyBlocked.route('**/js/core/branding.js*', route => {
    oldBootstrapRequests += 1;
    return route.abort('blockedbyclient');
  });
  await legacyBlocked.goto(base + '/#/dashboard');
  await waitForRenderedRoute(legacyBlocked, 'dashboard');
  assert.equal(oldBootstrapRequests, 0, 'the renamed bootstrap never requests branding.js');
  await legacyBlocked.close();

  let blockedGsapRequests = 0;
  const gsapBlocked = await browser.newPage();
  await gsapBlocked.route('**/assets/vendor/gsap.js*', route => {
    blockedGsapRequests += 1;
    return route.abort('blockedbyclient');
  });
  await gsapBlocked.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(gsapBlocked, 'dashboard');
  assert.equal(blockedGsapRequests, 1, 'локальный GSAP необязателен, его запрос блокируется отдельно');
  assert.equal(await gsapBlocked.locator('#app [data-ui-fatal]').count(), 0,
    'панель остаётся рабочей, если локальный GSAP не загрузился');
  await gsapBlocked.close();

  const routes = ['dashboard', 'toggles', 'tiktok', 'strategies', 'warp', 'whitelist', 'exclude', 'extra-domains', 'diag', 'credits', 'state', 'pick', 'autohostlist'];
  testedRouteCount = routes.length;
  const primaryRoutes = ['dashboard', 'toggles', 'tiktok', 'state', 'warp', 'whitelist', 'extra-domains', 'diag', 'credits'];
  const screenshotRoutes = ['dashboard', 'toggles', 'strategies', 'warp', 'whitelist', 'exclude',
    'extra-domains', 'diag', 'tiktok', 'credits', 'state', 'pick', 'autohostlist'];
  const responsiveScreenshotRoutes = ['dashboard', 'state', 'warp'];
  const requiredTokens = ['--ow-canvas', '--ow-surface-1', '--ow-surface-2', '--ow-surface-hover',
    '--ow-surface-selected', '--ow-border-subtle', '--ow-border-strong', '--ow-text-primary',
    '--ow-text-secondary', '--ow-text-tertiary', '--ow-accent', '--ow-accent-hover',
    '--ow-accent-soft', '--ow-brand-violet', '--ow-success', '--ow-warning', '--ow-danger',
    '--ow-info', '--ow-radius-control', '--ow-radius-card', '--ow-radius-panel',
    '--ow-focus-ring', '--ow-shadow-card', '--ow-shadow-popover', '--ow-button-height',
    '--ow-input-height', '--ow-select-height', '--ow-touch-target-height', '--ow-strategy-select-width',
    '--ow-strategy-column-width', '--ow-table-row-height', '--ow-table-header-height',
    '--ow-table-cell-padding-y', '--ow-table-cell-padding-x', '--ow-card-padding', '--ow-card-gap',
    '--ow-motion-button', '--ow-motion-state', '--ow-motion-popover', '--ow-motion-shell',
    '--ow-motion-tab-indicator'];
  const ratio = (foreground, background) => {
    const luminance = hex => {
      const channels = hex.match(/[\da-f]{2}/gi).map(value => parseInt(value, 16) / 255)
        .map(value => value <= 0.04045 ? value / 12.92 : ((value + 0.055) / 1.055) ** 2.4);
      return 0.2126 * channels[0] + 0.7152 * channels[1] + 0.0722 * channels[2];
    };
    const a = luminance(foreground), b = luminance(background);
    return (Math.max(a, b) + 0.05) / (Math.min(a, b) + 0.05);
  };
  const allPageErrors = [];
  const allConsoleErrors = [];

  for (const appearance of ['dark', 'light']) {
    const page = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: appearance });
    const pageErrors = [];
    const consoleErrors = [];
    const moduleResponses = [];
    const requestedOrigins = new Set();
    page.on('pageerror', error => pageErrors.push(error.message));
    page.on('console', message => { if (message.type() === 'error') consoleErrors.push(message.text()); });
    page.on('request', request => requestedOrigins.add(new URL(request.url()).origin));
    page.on('response', response => {
      if (response.request().resourceType() === 'script' && new URL(response.url()).pathname.endsWith('.js')) {
        moduleResponses.push({ url: response.url(), status: response.status(), type: response.headers()['content-type'] || '' });
      }
    });
    await page.addInitScript(mode => {
      localStorage.setItem('z2k-theme', mode);
      localStorage.setItem('z2k-sidebar', 'expanded');
    }, appearance);
    await page.goto(`${base}/#/dashboard`);
    await waitForRenderedRoute(page, 'dashboard');
    await page.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
    assert.equal(await page.evaluate(() => window.gsap?.version || ''), '3.15.0',
      `${appearance}: локальный GSAP загружается до модулей приложения`);
    assert.ok(moduleResponses.some(response => new URL(response.url).pathname.endsWith('/assets/vendor/gsap.js')
      && response.status === 200), `${appearance}: GSAP загружается с адреса локальной панели`);
    assert.equal(await page.evaluate(() => document.documentElement.classList.contains('motion-ready')),
      true, `${appearance}: общий модуль GSAP управляет анимацией интерфейса`);
    const shellTransitions = await page.evaluate(() => Object.fromEntries([
      ['layout', document.documentElement],
      ['nav', document.querySelector('#nav')], ['app', document.querySelector('#app')],
      ['brand', document.querySelector('#panel-brand')], ['theme', document.querySelector('.topbar > .theme-toggle')],
    ].map(([name, element]) => [name, {
      property: getComputedStyle(element).transitionProperty,
      duration: getComputedStyle(element).transitionDuration,
    }])));
    assert.doesNotMatch(shellTransitions.layout.property, /--sidebar-progress/,
      `${appearance}: GSAP владеет общим прогрессом layout`);
    assert.doesNotMatch(shellTransitions.nav.property, /(^|,\s*)(left|width)(,|$)/,
      `${appearance}: у меню нет отдельного CSS-перехода координат`);
    assert.doesNotMatch(shellTransitions.app.property, /(^|,\s*)(margin-left|width)(,|$)/,
      `${appearance}: у контента нет отдельного CSS-перехода геометрии`);
    assert.doesNotMatch(shellTransitions.brand.property, /(^|,\s*)left(,|$)/,
      `${appearance}: логотип не анимирует координаты независимо`);
    assert.doesNotMatch(shellTransitions.theme.property, /(^|,\s*)right(,|$)/,
      `${appearance}: переключатель темы не анимирует координаты независимо`);
    const shellGeometry = await page.evaluate(async () => {
      const nav = document.querySelector('#nav');
      const app = document.querySelector('#app');
      const button = document.querySelector('#sidebar-collapse');
      const brand = document.querySelector('#panel-brand');
      const theme = document.querySelector('.topbar > .theme-toggle');
      const geometry = () => {
        const navBox = nav.getBoundingClientRect();
        const appBox = app.getBoundingClientRect();
        const brandBox = brand.getBoundingClientRect();
        const themeBox = theme.getBoundingClientRect();
        return { navLeft: navBox.left, navWidth: navBox.width, appLeft: appBox.left,
          brandLeft: brandBox.left, themeRight: themeBox.right, gap: appBox.left - navBox.right };
      };
      const start = geometry();
      const gaps = [];
      const sampleFor = async duration => {
        const deadline = performance.now() + duration;
        while (performance.now() < deadline) {
          gaps.push(geometry().gap);
          await new Promise(requestAnimationFrame);
        }
      };
      button.click();
      await sampleFor(120);
      const middle = geometry();
      const layoutTweens = window.gsap.getTweensOf(document.documentElement)
        .filter(tween => tween.isActive()).length;
      button.click();
      await sampleFor(45);
      button.click();
      await sampleFor(360);
      const collapsed = { ...geometry(), state: document.body.getAttribute('data-sidebar'),
        expanded: button.getAttribute('aria-expanded') };
      button.click();
      await sampleFor(360);
      const expanded = { ...geometry(), state: document.body.getAttribute('data-sidebar'),
        expanded: button.getAttribute('aria-expanded') };
      return { start, middle, collapsed, expanded, layoutTweens, minGap: Math.min(...gaps) };
    });
    assert.ok(Math.abs(shellGeometry.middle.navLeft - shellGeometry.start.navLeft) <= 1
      && Math.abs(shellGeometry.collapsed.navLeft - shellGeometry.start.navLeft) <= 1,
    `${appearance}: меню остаётся на месте при изменении ширины (${JSON.stringify(shellGeometry)})`);
    assert.ok(shellGeometry.middle.navWidth < shellGeometry.start.navWidth - 1
      && shellGeometry.middle.navWidth > shellGeometry.collapsed.navWidth + 1,
    `${appearance}: ширина меню проходит промежуточное положение (${JSON.stringify(shellGeometry)})`);
    assert.ok(shellGeometry.middle.appLeft > Math.min(shellGeometry.start.appLeft, shellGeometry.collapsed.appLeft) + 1
      && shellGeometry.middle.appLeft < Math.max(shellGeometry.start.appLeft, shellGeometry.collapsed.appLeft) - 1,
    `${appearance}: контент одновременно с меню проходит промежуточное положение (${JSON.stringify(shellGeometry)})`);
    assert.ok([shellGeometry.middle, shellGeometry.collapsed, shellGeometry.expanded].every(frame =>
      Math.abs(frame.brandLeft - shellGeometry.start.brandLeft) <= 1
      && Math.abs(frame.themeRight - shellGeometry.start.themeRight) <= 1),
    `${appearance}: логотип и переключатель темы неподвижны (${JSON.stringify(shellGeometry)})`);
    assert.ok(shellGeometry.minGap >= -1,
      `${appearance}: при переходе или прерывании контент не перекрывает меню (${JSON.stringify(shellGeometry)})`);
    assert.equal(shellGeometry.layoutTweens, 1,
      `${appearance}: один GSAP tween управляет состоянием layout`);
    assert.deepEqual([shellGeometry.collapsed.state, shellGeometry.collapsed.expanded], ['collapsed', 'false'],
      `${appearance}: последнее прерывающее действие сворачивает боковую панель`);
    assert.deepEqual([shellGeometry.expanded.state, shellGeometry.expanded.expanded], [null, 'true'],
      `${appearance}: меню возвращается в раскрытое состояние`);
    const motionLifecycle = await page.evaluate(async () => {
      const { motion } = await import('/js/motion.js');
      const target = document.createElement('button');
      document.body.appendChild(target);
      const first = motion.to(target, { x: 100, duration: 1 }, 'rapid-toggle');
      const latest = motion.to(target, { x: 12, duration: 0.04 }, 'rapid-toggle');
      const replaced = Boolean(first && !first.isActive());
      await new Promise(resolve => {
        const wait = () => latest && latest.isActive() ? requestAnimationFrame(wait) : resolve();
        requestAnimationFrame(wait);
      });
      const finalX = Number(gsap.getProperty(target, 'x'));
      motion.dispose(target);
      const cleared = gsap.getTweensOf(target).length === 0 && !target.style.transform;
      target.remove();
      return { replaced, finalX, cleared, hasFlip: motion.hasFlip };
    });
    assert.equal(motionLifecycle.replaced, true, `${appearance}: быстрое повторное действие отменяет устаревший tween`);
    assert.ok(Math.abs(motionLifecycle.finalX - 12) < 0.1,
      `${appearance}: последняя анимация достигает заданного состояния (${motionLifecycle.finalX})`);
    assert.equal(motionLifecycle.cleared, true, `${appearance}: очистка удаляет активные tween и временные стили`);
    assert.equal(motionLifecycle.hasFlip, true, `${appearance}: локальная сборка GSAP включает Flip для коротких списков`);
    const motionFeatures = await page.evaluate(async () => {
      const { motion } = await import('/js/motion.js');
      const waitTween = tween => new Promise(resolve => {
        const wait = () => tween && tween.isActive() ? requestAnimationFrame(wait) : resolve();
        requestAnimationFrame(wait);
      });
      const number = document.createElement('strong');
      number.dataset.motionValue = '2';
      number.textContent = '2';
      const numericTween = motion.numberTo(number, 5, value => String(Math.round(value)));
      const progress = document.createElement('div');
      progress.style.width = '20%';
      const progressTween = motion.progressTo(progress, 75);
      const toggle = document.createElement('label');
      toggle.className = 'switch';
      toggle.innerHTML = '<input type="checkbox"><span class="slider"></span>';
      document.body.append(number, progress, toggle);
      const checkbox = toggle.querySelector('input');
      checkbox.checked = true;
      checkbox.dispatchEvent(new Event('change', { bubbles: true }));
      const list = document.createElement('div');
      list.style.cssText = 'position:fixed;top:10px;left:10px;display:flex;width:320px;gap:8px;';
      list.innerHTML = '<span data-flip-id="a" style="width:80px;height:20px"></span><span data-flip-id="b" style="width:80px;height:20px"></span><span data-flip-id="c" style="width:80px;height:20px"></span>';
      document.body.appendChild(list);
      const flipTween = motion.flip(list, () => list.prepend(list.lastElementChild), 24);
      await Promise.all([waitTween(numericTween), waitTween(progressTween), waitTween(flipTween)]);
      await waitTween(gsap.getTweensOf(toggle)[0]);
      const result = {
        number: number.textContent,
        progressWidth: progress.style.width,
        progressValue: progress.getAttribute('aria-valuenow'),
        switchOffset: getComputedStyle(toggle.querySelector('.slider'), '::before').transform,
        flipOrder: [...list.querySelectorAll('[data-flip-id]')].map(item => item.dataset.flipId),
      };
      number.remove(); progress.remove(); toggle.remove(); list.remove();
      return result;
    });
    assert.equal(motionFeatures.number, '5', `${appearance}: числа анимируются через GSAP`);
    assert.equal(motionFeatures.progressWidth, '75%', `${appearance}: прогресс анимируется через GSAP`);
    assert.equal(motionFeatures.progressValue, '75');
    assert.match(motionFeatures.switchOffset, /matrix\(1, 0, 0, 1, 18, 0\)/,
      `${appearance}: GSAP перемещает ручку переключателя в положение «включено»`);
    assert.deepEqual(motionFeatures.flipOrder, ['c', 'a', 'b'], `${appearance}: Flip сохраняет порядок элементов списка`);
    await page.waitForFunction(() => {
      const theme = document.querySelector('#brand-profile-theme');
      return theme && theme.sheet && theme.sheet.cssRules.length > 0;
    }, null, { timeout: 1500 });
    await page.waitForFunction(() => Math.abs(document.querySelector('#nav').getBoundingClientRect().width - 261) < 1,
      null, { timeout: 1200 });
    assert.equal(await page.locator('body').getAttribute('data-sidebar'), null,
      `${appearance}: an expanded sidebar preference starts with the full rail`);
    assert.equal(await page.locator('#sidebar-collapse').count(), 1,
      `${appearance}: the sidebar keeps its bottom collapse control`);
    assert.equal(await page.locator('#nav > #sidebar-collapse').count(), 1,
      `${appearance}: the desktop collapse control is the final row in the sidebar`);
    assert.equal(await page.locator('#sidebar-collapse').isVisible(), true);
    assert.ok(await page.locator('#sidebar-collapse').evaluate(button =>
      button.getBoundingClientRect().bottom <= document.querySelector('#nav').getBoundingClientRect().bottom - 8),
    `${appearance}: the bottom collapse row remains in the visible rail`);
    assert.equal(await page.locator('#sidebar-collapse').getAttribute('aria-expanded'), 'true');
    assert.equal(await page.locator('#nav .nav-external a').first().getAttribute('href'),
      'https://github.com/t0fox/z2kOW', `${appearance}: footer points to our repository`);
    assert.equal(await page.locator('#menu-shell.mm-ocd.mm-ocd--left > .mm-ocd__content > #nav').count(), 1,
      'navigation uses the observed Lolz off-canvas shell/content structure');
    assert.equal(await page.locator('#menu-shell > #menu-backdrop.mm-ocd__backdrop').count(), 1,
      'the dismiss surface belongs to the off-canvas shell');
    if (appearance === 'dark') {
      assert.ok(apiRequests.some(request => request.endpoint === 'status' && request.marker === '1'),
        'status fixture must receive the panel request marker');
      assert.equal(statusResponsesCompleted, 0, 'identity and the initial route are ready before delayed /status completes');
      holdStatusResponses = false;
      for (const response of pendingStatusResponses.splice(0)) {
        statusResponsesCompleted += 1;
        response.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
        response.end(JSON.stringify(statusFixture));
      }
    }

    const lockup = page.locator('#panel-brand');
    const payloadUpdateBanner = page.locator('#update-banner');
    await page.waitForFunction(() => document.querySelector('#update-banner')?.innerText.includes('p-86.1'),
      null, { timeout: 2000 });
    assert.match(await payloadUpdateBanner.innerText(), /z2k p-86\.1 актуален/,
      'the single update banner shows the upstream engine release');
    assert.equal(await page.locator('#product-update-card').count(), 0,
      'the dashboard has no separate z2kOW update card');
    assert.equal(await page.locator('#upd-history-link').innerText(), 'История обновлений');
    assert.equal(await page.locator('#upd-reinstall').innerText(), 'Переустановить p-86.1');
    assert.equal(await page.locator('#upd-recheck').count(), 0,
      'a healthy OpenWrt release has one manual version action instead of a competing check button');
    assert.equal(await page.locator('#upd-apply').count(), 0,
      'current release exposes a check action, not a second update system');
    assert.equal(await page.title(), 'z2kOW · Дашборд');
    assert.equal(await lockup.getAttribute('aria-label'), 'z2kOW — OpenWrt edition');
    assert.equal(await lockup.locator('#brand-composite-logo').count(), 1, 'exactly one composite logo exists');
    assert.equal(await page.locator('#brand-composite-logo').count(), 1, 'the whole document contains one composite logo');
    assert.equal(await lockup.locator('#brand-composite-logo').isVisible(), true, `${appearance}: composite logo is visible`);
    assert.equal(await lockup.locator('#brand-profile-logo').isVisible(), false, `${appearance}: opaque fallback image is hidden`);
    assert.equal(await lockup.locator('.brand-wordmark').isVisible(), false, `${appearance}: duplicate text lockup is hidden`);
    assert.equal(await lockup.locator('.brand-wordmark').textContent(), 'z2kOW', 'generic fallback text remains available');
    assert.doesNotMatch(await lockup.innerText(), /keenetic|antidpi|openwrt edition/i);
    const brandRender = await lockup.evaluate(node => {
      const brand = node.getBoundingClientRect();
      const logo = node.querySelector('#brand-composite-logo').getBoundingClientRect();
      const firstMenuItem = document.querySelector('#nav a[data-route="dashboard"]').getBoundingClientRect();
      const topbar = document.querySelector('.topbar').getBoundingClientRect();
      const style = getComputedStyle(node);
      return {
        x: brand.x, y: brand.y, width: brand.width, height: brand.height,
        background: style.backgroundColor, borderRadius: style.borderRadius,
        logoX: logo.x, logoY: logo.y, logoWidth: logo.width, logoHeight: logo.height,
        firstMenuItemX: firstMenuItem.x, topbarHeight: topbar.height,
      };
    });
    assert.equal(brandRender.background, 'rgba(0, 0, 0, 0)',
      `${appearance}: #panel-brand has a transparent background`);
    assert.equal(brandRender.borderRadius, '0px', `${appearance}: the brand has no card radius`);
    assert.ok(Math.abs(brandRender.logoWidth - 248) < 1 && Math.abs(brandRender.logoHeight - 51.05) < 1,
      `${appearance}: the lockup fills the sidebar at the enlarged artwork size (${JSON.stringify(brandRender)})`);
    assert.ok(brandRender.topbarHeight >= brandRender.logoHeight + 6,
      `${appearance}: the logo has vertical breathing room inside its topbar (${JSON.stringify(brandRender)})`);
    assert.ok(Math.abs(brandRender.logoY - (brandRender.topbarHeight - brandRender.logoHeight) / 2) < 1,
      `${appearance}: the enlarged logo is vertically centered in the topbar (${JSON.stringify(brandRender)})`);
    assert.ok(Math.abs(brandRender.logoWidth / brandRender.logoHeight - (1166 / 240)) < 0.01,
      `${appearance}: the SVG viewport matches the cropped source aspect ratio`);
    assert.ok(Math.abs(brandRender.width - brandRender.logoWidth) <= 1
      && Math.abs(brandRender.height - brandRender.logoHeight) <= 1,
    `${appearance}: the clickable brand box tightly fits the visible SVG (${JSON.stringify(brandRender)})`);
    assert.ok(brandRender.width <= brandRender.logoWidth + 2 && brandRender.height <= brandRender.logoHeight + 2,
      `${appearance}: the brand has no oversized blank area around the SVG (${JSON.stringify(brandRender)})`);
    assert.ok(Math.abs(brandRender.x - brandRender.firstMenuItemX) <= 2,
      `${appearance}: the logo aligns within 2 CSS px of the first sidebar item (${JSON.stringify(brandRender)})`);
    const logoRender = await lockup.locator('#brand-composite-logo').evaluate(node => {
      const box = node.getBoundingClientRect();
      return {
        width: box.width, height: box.height,
        background: getComputedStyle(node).backgroundColor,
        ink: getComputedStyle(node.querySelector('#brand-logo-ink')).fill,
        accent: getComputedStyle(node.querySelector('#brand-logo-accent')).fill,
        sources: [...node.querySelectorAll('[data-brand-source]')].map(source => source.getAttribute('href')),
        preserveAspectRatio: node.getAttribute('preserveAspectRatio'),
        viewBox: [node.viewBox.baseVal.width, node.viewBox.baseVal.height],
      };
    });
    assert.ok(Math.abs(logoRender.width - 248) < 1 && Math.abs(logoRender.height - 51.05) < 1,
      `${appearance}: enlarged logo keeps the cropped source ratio in the topbar`);
    assert.deepEqual(logoRender.viewBox, [1166, 240], `${appearance}: the SVG clips only unused source canvas around the artwork`);
    assert.equal(logoRender.preserveAspectRatio, 'xMidYMid meet',
      `${appearance}: cropped artwork preserves its intrinsic proportions without stretching`);
    assert.equal(logoRender.background, 'rgba(0, 0, 0, 0)', `${appearance}: logo has a transparent background`);
    assert.equal(logoRender.ink, appearance === 'light' ? 'rgb(24, 38, 37)' : 'rgb(214, 214, 214)',
      `${appearance}: z2k lettering follows the theme ink`);
    assert.equal(logoRender.accent, appearance === 'light' ? 'rgb(8, 122, 112)' : 'rgb(0, 186, 120)',
      `${appearance}: OW and the mark follow the green theme accent`);
    const visibleInk = await lockup.locator('#brand-composite-logo').evaluate(async node => {
      const source = new Image();
      source.src = node.querySelector('[data-brand-source]').getAttribute('href');
      await source.decode();
      const canvas = document.createElement('canvas');
      canvas.width = source.naturalWidth;
      canvas.height = source.naturalHeight;
      const context = canvas.getContext('2d', { willReadFrequently: true });
      context.drawImage(source, 0, 0);
      const pixels = context.getImageData(0, 0, canvas.width, canvas.height).data;
      let left = canvas.width, top = canvas.height, right = -1, bottom = -1;
      for (let y = 0; y < canvas.height; y++) {
        for (let x = 0; x < canvas.width; x++) {
          const offset = (y * canvas.width + x) * 4;
          const red = pixels[offset] / 255, green = pixels[offset + 1] / 255;
          const wordAlpha = Math.max(0, 1.085106 * red - 0.085106);
          const accentAlpha = Math.max(0, -1.574803 * red + 1.574803 * green - 0.148235);
          if (Math.max(wordAlpha, accentAlpha) * 255 > 16) {
            left = Math.min(left, x); top = Math.min(top, y);
            right = Math.max(right, x); bottom = Math.max(bottom, y);
          }
        }
      }
      const viewBox = node.viewBox.baseVal;
      const box = node.getBoundingClientRect();
      return {
        width: (right - left + 1) / viewBox.width * box.width,
        height: (bottom - top + 1) / viewBox.height * box.height,
      };
    });
    assert.ok(visibleInk.width >= 237 && visibleInk.height >= 48,
      `${appearance}: the source artwork fills the enlarged lockup at a useful size (${JSON.stringify(visibleInk)})`);
    assert.deepEqual(logoRender.sources, ['/assets/openwrt/logo.png', '/assets/openwrt/logo.png']);
    assert.equal(await page.locator('#brand-favicon').getAttribute('href'), '/assets/openwrt/favicon.svg');
    assert.equal(await page.locator('#brand-profile-theme').getAttribute('href'), '/assets/openwrt/theme.css');
    assert.equal(await page.locator('[data-theme-btn="' + appearance + '"]').getAttribute('aria-pressed'), 'true');
    assert.equal(await page.getByRole('group', { name: 'Тема' }).count(), 1);
    assert.equal(await page.locator('#menu-toggle').isVisible(), false,
      `${appearance}: Full HD desktop keeps the mobile-only menu trigger hidden`);

    const tokens = await page.evaluate(names => {
      const style = getComputedStyle(document.documentElement);
      return Object.fromEntries(names.map(name => [name, style.getPropertyValue(name).trim()]));
    }, requiredTokens);
    for (const name of requiredTokens) assert.ok(tokens[name], `${appearance}: missing ${name}`);
    if (appearance === 'dark') {
      for (const [name, value] of Object.entries({
        '--ow-canvas': '#0C0F0E', '--ow-surface-1': '#111615', '--ow-surface-2': '#181E1C',
        '--ow-border-subtle': '#1E2725', '--ow-text-primary': '#D6D6D6',
        '--ow-text-secondary': '#8CA29A', '--ow-accent': '#00BA78', '--ow-radius-control': '10px',
        '--ow-radius-card': '12px',
      })) assert.equal(tokens[name].toUpperCase(), value.toUpperCase(), `dark reference token: ${name}`);
    } else {
      assert.equal(tokens['--ow-canvas'], '#F4F8F7', 'preserve the light canvas');
      assert.equal(tokens['--ow-accent'], '#087A70', 'preserve the light accent');
    }
    assert.equal(await page.evaluate(() => getComputedStyle(document.body).fontSize), '14px', 'compact body type');
    assert.equal(await page.evaluate(() => getComputedStyle(document.body).lineHeight), '17.92px',
      'body leading matches the measured Lolz 14 px / 17.92 px rhythm');
    assert.equal(await page.locator('.topbar').evaluate(node => node.getBoundingClientRect().height), 58,
      'desktop OpenWrt topbar gives the enlarged logo vertical room');
    const headerStyle = await page.locator('.topbar').evaluate(node => {
      const style = getComputedStyle(node);
      const effect = getComputedStyle(node, '::before');
      return { position: style.position, background: style.backgroundColor,
        effectBackground: effect.backgroundColor, blur: effect.backdropFilter,
        borderBottomWidth: style.borderBottomWidth };
    });
    assert.equal(headerStyle.position, 'fixed', 'the page header follows the fixed Lolz shell geometry');
    assert.equal(headerStyle.background, 'rgba(0, 0, 0, 0)', 'the header itself does not clip fixed drawer descendants');
    assert.equal(headerStyle.effectBackground, appearance === 'dark'
      ? 'rgba(12, 15, 14, 0.62)' : 'rgba(244, 248, 247, 0.82)',
    'the header uses the measured dark surface or a matching frosted light surface');
    assert.equal(headerStyle.blur, 'blur(10px)', 'the header uses the measured 10 px backdrop blur');
    assert.equal(headerStyle.borderBottomWidth, '0px', 'the header has no extra separator line');
    assert.ok(await page.locator('#nav a[data-route="dashboard"]').evaluate(node => {
      const height = node.getBoundingClientRect().height;
      return height >= 36 && height <= 42;
    }), 'desktop navigation stays between 36 and 42 px');
    const desktopSidebarWidth = await page.locator('#nav').evaluate(node => node.getBoundingClientRect().width);
    assert.ok(Math.abs(desktopSidebarWidth - 261) < 1,
      `desktop sidebar matches the compact reference width (${desktopSidebarWidth}px)`);
    const desktopFrame = await page.evaluate(() => ({
      viewport: document.documentElement.clientWidth,
      windowWidth: window.innerWidth,
      navX: document.querySelector('#nav').getBoundingClientRect().x,
      navWidth: document.querySelector('#nav').getBoundingClientRect().width,
      appX: document.querySelector('#app').getBoundingClientRect().x,
      appY: document.querySelector('#app').getBoundingClientRect().y,
      appWidth: document.querySelector('#app').getBoundingClientRect().width,
      brandX: document.querySelector('#panel-brand').getBoundingClientRect().x,
      brandY: document.querySelector('#panel-brand').getBoundingClientRect().y,
      brandWidth: document.querySelector('#panel-brand').getBoundingClientRect().width,
      brandHeight: document.querySelector('#panel-brand').getBoundingClientRect().height,
      firstMenuItemX: document.querySelector('#nav a[data-route="dashboard"]').getBoundingClientRect().x,
      utilityRight: document.querySelector('.theme-toggle').getBoundingClientRect().right,
      appRight: document.querySelector('#app').getBoundingClientRect().right,
    }));
    assert.ok(Math.abs(desktopFrame.navX - (desktopFrame.windowWidth / 2 - 543.3)) < 1,
      `the 261 px rail matches its measured position inside Lolz's centered 1081 px shell (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(desktopFrame.navWidth - 261) < 1,
      `the desktop rail matches Lolz's measured 261 px inner width (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(desktopFrame.appX - (desktopFrame.windowWidth / 2 - 267)) < 1,
      `the main column begins at Lolz's measured centered-shell offset (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(desktopFrame.appWidth - 800) < 1,
      `the main column matches the measured 800 px reference (${desktopFrame.appWidth}px)`);
    assert.ok(Math.abs(desktopFrame.appY - 58) < 1,
      `the main column begins directly below the enlarged 58 px header (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(desktopFrame.brandX - desktopFrame.firstMenuItemX) < 1,
      `the z2kOW lockup aligns with the first sidebar item (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(desktopFrame.brandY - (58 - 51.05) / 2) < 1
      && Math.abs(desktopFrame.brandWidth - 248) < 1 && Math.abs(desktopFrame.brandHeight - 51.05) < 1,
    `the clickable brand box fits the enlarged 248×51 lockup centered in the 58 px topbar (${JSON.stringify(desktopFrame)})`);
    assert.equal(await page.locator('#header-nav, #route-recents').count(), 0,
      'the header has no duplicated route-navigation rows');
    assert.ok(Math.abs(desktopFrame.utilityRight - (desktopFrame.appRight - 98)) < 2,
      `header controls follow Lolz's measured 98 px trailing inset within the shell (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(await page.locator('#nav .nav-ico').first().evaluate(node => node.getBoundingClientRect().width) - 20) < 1,
      'sidebar icons match the reference size');
    const shellMotion = await page.evaluate(async () => {
      const nav = getComputedStyle(document.querySelector('#nav'));
      const app = getComputedStyle(document.querySelector('#app'));
      const root = getComputedStyle(document.documentElement);
      const { motion } = await import('/js/motion.js');
      return { navTransition: nav.transitionProperty, appTransition: app.transitionProperty,
        rootTransition: root.transitionProperty, shellDuration: motion.timing.duration.shell };
    });
    assert.equal(shellMotion.navTransition, 'none', 'sidebar не анимирует геометрию отдельно от состояния оболочки');
    assert.equal(shellMotion.appTransition, 'none', 'контентная колонка следует общей временной шкале');
    assert.equal(shellMotion.rootTransition, 'none', 'при GSAP CSS не конкурирует с timeline shell');
    assert.equal(shellMotion.shellDuration, 0.3, 'timeline оболочки занимает 300 мс');
    assert.ok(await page.locator('#app').evaluate(node => node.getBoundingClientRect().width === 800),
      'all desktop routes use the reference 800 px content column');
    const sidebarCollapse = page.locator('#sidebar-collapse');
    await sidebarCollapse.click();
    await page.waitForFunction(() => document.body.dataset.sidebar === 'collapsed'
      && Math.abs(document.querySelector('#nav').getBoundingClientRect().width - 72) < 0.5
      && Math.abs(document.querySelector('#app').getBoundingClientRect().x - (innerWidth / 2 - 456)) < 1);
    await waitForGsapSettled(page, ['html']);
    const collapsedFrame = await page.evaluate(() => ({
      state: document.body.getAttribute('data-sidebar'),
      windowWidth: window.innerWidth,
      railX: document.querySelector('#nav').getBoundingClientRect().x,
      railWidth: document.querySelector('#nav').getBoundingClientRect().width,
      appX: document.querySelector('#app').getBoundingClientRect().x,
      appWidth: document.querySelector('#app').getBoundingClientRect().width,
      scrollWidth: document.documentElement.scrollWidth,
      clientWidth: document.documentElement.clientWidth,
      labelWidth: document.querySelector('#nav a[data-route="dashboard"] .nav-label').getBoundingClientRect().width,
    }));
    assert.equal(collapsedFrame.state, 'collapsed', `${appearance}: collapse records the icon-only state`);
    assert.ok(Math.abs(collapsedFrame.railWidth - 72) < 1, `${appearance}: collapsed rail is 72 px`);
    assert.ok(Math.abs(collapsedFrame.appX - (collapsedFrame.windowWidth / 2 - 456)) < 1,
      `${appearance}: main column stays 15 px after the fixed compact rail (${JSON.stringify(collapsedFrame)})`);
    assert.equal(collapsedFrame.appWidth, 989, `${appearance}: collapse fills the width released by the rail`);
    assert.ok(collapsedFrame.labelWidth <= 1, `${appearance}: nav text is visually hidden in the compact rail`);
    assert.ok(collapsedFrame.scrollWidth <= collapsedFrame.clientWidth,
      `${appearance}: collapsed shell stays inside the viewport`);
    assert.equal(await page.getByRole('link', { name: 'Дашборд' }).count(), 1,
      `${appearance}: collapsed nav links retain their accessible names`);
    assert.equal(await sidebarCollapse.getAttribute('aria-expanded'), 'false');
    assert.equal(await sidebarCollapse.getAttribute('aria-label'), 'Развернуть боковую панель');
    assert.ok(await sidebarCollapse.locator('.nav-ico').evaluate(node => {
      const matrix = new DOMMatrixReadOnly(getComputedStyle(node).transform);
      return matrix.a < -0.999 && Math.abs(matrix.b) < 0.001
        && Math.abs(matrix.c) < 0.001 && matrix.d < -0.999;
    }), 'collapsed sidebar chevron settles into the expand direction');
    assert.equal(await page.evaluate(() => localStorage.getItem('z2k-sidebar')), 'collapsed');
    if (screenshotDir) {
      await page.mouse.move(1439, 1103);
      await page.screenshot({ path: path.join(screenshotDir, `${appearance}-1440-dashboard-sidebar-collapsed.png`) });
    }
    await sidebarCollapse.click();
    await page.waitForFunction(() => !document.body.hasAttribute('data-sidebar')
      && Math.abs(document.querySelector('#nav').getBoundingClientRect().width - 261) < 0.5);
    await waitForGsapSettled(page, ['html']);
    assert.equal(await page.locator('body').getAttribute('data-sidebar'), null,
      `${appearance}: the collapse control restores the expanded rail`);
    assert.ok(Math.abs(await page.locator('#nav').evaluate(node => node.getBoundingClientRect().width) - 261) < 0.5);
    assert.equal(await sidebarCollapse.getAttribute('aria-expanded'), 'true');
    assert.equal(await page.evaluate(() => localStorage.getItem('z2k-sidebar')), 'expanded');
    const surfaces = await page.evaluate(() => ({
      topbarShadow: getComputedStyle(document.querySelector('.topbar')).boxShadow,
      cardShadow: getComputedStyle(document.querySelector('#app .card')).boxShadow,
      cardRadius: getComputedStyle(document.querySelector('#app .card')).borderRadius,
      successGlowToken: getComputedStyle(document.documentElement).getPropertyValue('--ow-success-glow').trim(),
      successCellShadow: getComputedStyle(document.querySelector('#app .status-cell.good')).boxShadow,
      titleAnimation: getComputedStyle(document.querySelector('#app .page-title')).animationName,
      cardAnimation: getComputedStyle(document.querySelector('#app > .card')).animationName,
    }));
    assert.equal(surfaces.topbarShadow, 'none', 'the reference header has no decorative drop shadow');
    assert.equal(surfaces.cardShadow, 'none', 'cards use a border instead of a floating shadow');
    assert.equal(surfaces.cardRadius, '12px');
    assert.match(surfaces.successGlowToken, /^inset 0 0 0 1px color-mix\(/,
      'success feedback uses a centralized semantic glow token');
    assert.notEqual(surfaces.successCellShadow, 'none', 'successful status cells retain their subtle glow');
    assert.equal(await page.locator('#app .card .desc').first().evaluate(node => getComputedStyle(node).lineHeight), '17.92px',
      'card descriptions use the measured 14 px / 17.92 px Lolz rhythm');
    assert.equal(surfaces.titleAnimation, 'none', 'GSAP заменяет CSS-анимацию заголовка страницы');
    assert.equal(surfaces.cardAnimation, 'none', 'GSAP заменяет CSS-анимацию карточек');
    const buttonStyle = await page.locator('#app .btn').first().evaluate(node => {
      const style = getComputedStyle(node);
      return { height: node.getBoundingClientRect().height, radius: style.borderRadius,
        color: style.color, background: style.backgroundColor,
        transitionDuration: style.transitionDuration, transitionProperty: style.transitionProperty };
    });
    assert.ok(buttonStyle.height >= 34 && buttonStyle.height <= 38, 'desktop buttons stay 34–38 px tall');
    assert.equal(buttonStyle.radius, '10px', 'desktop buttons match the reference control radius');
    assert.equal(buttonStyle.color, appearance === 'dark' ? 'rgb(214, 214, 214)' : 'rgb(24, 38, 37)',
      'button text follows the selected theme');
    assert.equal(buttonStyle.background, appearance === 'dark' ? 'rgb(30, 39, 37)' : 'rgb(234, 241, 239)',
      'button surfaces follow the selected theme');
    assert.equal(buttonStyle.transitionDuration, '0s', 'анимацией кнопки управляет GSAP');
    assert.equal(buttonStyle.transitionProperty, 'none');
    const referenceCard = page.locator('#app > .card').filter({ has: page.locator('h3') }).first();
    const staticCardBefore = await referenceCard.evaluate(node => {
      const style = getComputedStyle(node);
      return { background: style.backgroundColor, border: style.borderColor, boxShadow: style.boxShadow };
    });
    await referenceCard.hover();
    const staticCardAfter = await referenceCard.evaluate(node => {
      const style = getComputedStyle(node);
      return { background: style.backgroundColor, border: style.borderColor, boxShadow: style.boxShadow };
    });
    assert.deepEqual(staticCardAfter, staticCardBefore,
      'non-interactive information cards do not react to hover');
    await page.evaluate(() => {
      const fixture = document.createElement('section');
      fixture.className = 'card is-interactive';
      fixture.dataset.qaCardMotion = 'true';
      fixture.innerHTML = '<h3>Interactive card</h3>';
      fixture.style.cssText = 'position:fixed;top:0;left:80px;width:260px;height:100px;z-index:10000;';
      document.body.appendChild(fixture);
    });
    const interactiveCard = page.locator('[data-qa-card-motion="true"]');
    await interactiveCard.hover();
    const expectedCardHover = appearance === 'dark' ? 'rgb(24, 30, 28)' : 'rgb(225, 236, 233)';
    await page.waitForFunction(expected => getComputedStyle(document.querySelector('[data-qa-card-motion="true"]')).backgroundColor === expected,
      expectedCardHover);
    const cardHover = await interactiveCard.evaluate(node => ({
      background: getComputedStyle(node).backgroundColor,
      border: getComputedStyle(node).borderColor,
      heading: getComputedStyle(node.querySelector('h3')).color,
      duration: getComputedStyle(node).transitionDuration,
    }));
    assert.equal(cardHover.background, appearance === 'dark' ? 'rgb(24, 30, 28)' : 'rgb(225, 236, 233)',
      'hovered cards use the measured Lolz surface or its light-theme equivalent');
    assert.equal(cardHover.border, appearance === 'dark' ? 'rgb(36, 47, 43)' : 'rgb(213, 224, 222)',
      'hovered cards use the measured edge color or its light-theme equivalent');
    assert.ok(ratio(appearance === 'dark' ? '#D6D6D6' : '#182625',
      appearance === 'dark' ? '#181E1C' : '#E1ECE9') >= 4.5, 'hover card headings remain readable');
    assert.equal(cardHover.duration, '0s', 'анимацией интерактивной карточки управляет GSAP');
    await interactiveCard.evaluate(node => node.remove());
    await page.mouse.move(1, 1);
    await page.evaluate(() => { location.hash = '#/state'; });
    await waitForRenderedRoute(page, 'state');
    await page.evaluate(() => {
      const fixture = document.createElement('button');
      fixture.className = 'btn btn-primary';
      fixture.dataset.qaMotion = 'true';
      fixture.type = 'button';
      fixture.textContent = 'QA button';
      fixture.style.cssText = 'position:fixed;top:0;left:0;z-index:10000;';
      document.body.appendChild(fixture);
    });
    const primary = page.locator('button[data-qa-motion="true"]');
    await primary.hover();
    await page.waitForTimeout(250);
    const hoverLayerState = await primary.evaluate(node => ({
      opacity: getComputedStyle(node, '::before').opacity,
      value: node.style.getPropertyValue('--z2k-motion-hover'),
    }));
    assert.deepEqual(hoverLayerState, { opacity: '1', value: '1' },
      'GSAP сохраняет слой наведения после завершения tween');
    const primaryStyle = await primary.evaluate(node => {
      const root = getComputedStyle(document.documentElement);
      const style = getComputedStyle(node);
      const before = getComputedStyle(node, '::before');
      const after = getComputedStyle(node, '::after');
      return { backgroundImage: style.backgroundImage, filter: style.filter,
        hoverLayer: before.backgroundImage, hoverDuration: before.transitionDuration,
        activeLayer: after.backgroundColor, activeDuration: after.transitionDuration,
        text: style.color,
        stops: ['--ow-button-start', '--ow-button-mid', '--ow-button-hover-start',
          '--ow-button-hover-mid', '--ow-button-hover-end'].map(name => root.getPropertyValue(name).trim()) };
    });
    assert.match(primaryStyle.backgroundImage, /linear-gradient\(88deg/,
      `primary gradient follows the source 88 degree angle (${JSON.stringify(primaryStyle)})`);
    assert.match(primaryStyle.backgroundImage, /42, 143, 92/, 'primary gradient uses the source #2A8F5C middle stop');
    assert.match(primaryStyle.hoverLayer, /linear-gradient\(88deg/, 'слой наведения основной кнопки — исходный градиент');
    assert.equal(primaryStyle.hoverDuration, '0s', 'слоем наведения основной кнопки управляет GSAP');
    assert.equal(primaryStyle.filter, 'brightness(1.08)', 'при наведении основная кнопка использует исходную яркость');
    assert.equal(primaryStyle.activeLayer, 'rgba(0, 0, 0, 0.18)', 'нажатие добавляет исходное чёрное наложение');
    assert.equal(primaryStyle.activeDuration, '0s', 'слоем нажатия основной кнопки управляет GSAP');
    assert.deepEqual(primaryStyle.stops.slice(0, 2), ['#20764E', '#2A8F5C']);
    assert.deepEqual(primaryStyle.stops.slice(2), ['#1C6946', '#329C6C', '#1D8254']);
    assert.equal(primaryStyle.text, 'rgb(245, 245, 245)', 'primary button text matches the source #F5F5F5');
    const primaryBox = await primary.boundingBox();
    await page.mouse.move(primaryBox.x + primaryBox.width / 2, primaryBox.y + primaryBox.height / 2);
    await page.mouse.down();
    await page.waitForFunction(() => {
      const node = document.querySelector('button[data-qa-motion="true"]');
      return node && getComputedStyle(node, '::after').opacity === '1';
    });
    const primaryActive = await primary.evaluate(node => ({
      scale: new DOMMatrixReadOnly(getComputedStyle(node).transform).a,
      overlay: getComputedStyle(node, '::after').opacity,
    }));
    assert.ok(Math.abs(primaryActive.scale - 0.97) < 0.002,
      `нажатие основной кнопки использует исходный scale(.97): ${JSON.stringify(primaryActive)}`);
    assert.equal(primaryActive.overlay, '1', 'при нажатии появляется исходное чёрное наложение');
    await page.mouse.up();
    await page.evaluate(() => document.querySelector('button[data-qa-motion="true"]').remove());
    assert.ok(ratio(tokens['--ow-text-primary'], tokens['--ow-surface-1']) >= 4.5);
    assert.ok(ratio(tokens['--ow-text-secondary'], tokens['--ow-surface-2']) >= 4.5);
    assert.ok(ratio(tokens['--ow-text-tertiary'], tokens['--ow-surface-2']) >= 4.5);
    assert.ok(ratio(tokens['--ow-accent'], tokens['--ow-canvas']) >= 4.5);
    assert.ok(ratio(tokens['--ow-border-strong'], tokens['--ow-surface-selected']) >= 3);
    for (const name of ['--ow-success', '--ow-warning', '--ow-danger', '--ow-info']) {
      assert.ok(ratio(tokens[name], tokens['--ow-surface-1']) >= 4.5, `${appearance}: ${name} text contrast`);
      assert.ok(ratio(tokens[name], tokens['--ow-surface-2']) >= 4.5, `${appearance}: ${name} nested text contrast`);
    }
    const localInter = await page.evaluate(() => document.fonts.load('400 14px Inter')
      .then(faces => faces.some(face => face.family === 'Inter' && face.status === 'loaded')));
    assert.equal(localInter, true, 'the locally bundled Lolz reference font is available without a CDN');
    assert.match(await page.evaluate(() => getComputedStyle(document.body).fontFamily), /^Inter, -apple-system, BlinkMacSystemFont/,
      'body typography uses the observed Lolz system/Inter font stack');

    await page.keyboard.press('Tab');
    const focus = await page.evaluate(() => ({
      id: document.activeElement.id,
      width: getComputedStyle(document.activeElement).outlineWidth,
      style: getComputedStyle(document.activeElement).outlineStyle,
    }));
    assert.equal(focus.id, 'panel-brand', 'keyboard focus starts on the single brand link');
    assert.equal(focus.width, '2px');
    assert.equal(focus.style, 'solid');
    await page.evaluate(() => document.activeElement.blur());
    await page.evaluate(() => document.activeElement.blur());

    for (const route of routes) {
      await page.evaluate(name => { location.hash = '#/' + name; }, route);
      await waitForRenderedRoute(page, route);
      await page.mouse.move(1439, 899);
      const expectedNavRoute = ({ state: 'strategies', pick: 'strategies', whitelist: 'exclude', exclude: 'exclude',
        autohostlist: 'extra-domains' })[route] || route;
      const activeNavRoutes = await page.locator('#nav a.active').evaluateAll(nodes => nodes.map(node => node.dataset.route));
      assert.deepEqual(activeNavRoutes, [expectedNavRoute], `${appearance}: /${route} highlights its matching navigation item`);
      if (route === 'toggles') {
        const control = page.locator('#au-hour + .chosen-single');
        assert.equal(await control.evaluate(node => getComputedStyle(node).minHeight), '36px',
          'desktop form controls match the 36 px reference height');
        assert.equal(await control.evaluate(node => getComputedStyle(node).borderRadius), '10px',
          'desktop form controls match the 10 px reference radius');
        assert.equal(await control.getAttribute('role'), 'combobox', 'custom selects expose a combobox control');
        await page.waitForFunction(() => {
          const toggle = document.querySelector('[data-key="auto_update"] input');
          const select = document.querySelector('#au-hour');
          const row = document.querySelector('#au-hour-row');
          return toggle?.checked === true && select?.disabled === false
            && select.options.length === 24 && row?.hidden === false;
        }, null, { timeout: 5000 });
        const listbox = page.locator(`#${await control.getAttribute('aria-controls')}`);
        assert.equal(await listbox.getAttribute('role'), 'listbox', 'custom select options expose a listbox');
        await control.click();
        assert.equal(await control.getAttribute('aria-expanded'), 'true', 'custom select opens from pointer input');
        await listbox.waitFor({ state: 'visible' });
        assert.equal(await listbox.isVisible(), true, 'custom select presents its options while open');
        await waitForGsapSettled(page, ['.chosen-drop-open', '.chosen-arrow']);
        const popupGeometry = await page.evaluate(async () => {
          const trigger = document.querySelector('#au-hour + .chosen-single').getBoundingClientRect();
          const drop = document.querySelector('.chosen-drop-open');
          const rect = drop.getBoundingClientRect();
          const style = getComputedStyle(drop);
          const { motion } = await import('/js/motion.js');
          return { xOffset: Math.round((rect.left - trigger.left) * 100) / 100,
            widthDelta: Math.round((rect.width - trigger.width) * 100) / 100,
            radius: style.borderRadius, animationName: style.animationName,
            animationDuration: style.animationDuration, popupDuration: motion.timing.duration.popup };
        });
        assert.ok(Math.abs(popupGeometry.xOffset) <= 1 && Math.abs(popupGeometry.widthDelta) <= 1,
          `меню Lolz выровнено с триггером с точностью до 1 CSS-пикселя (${JSON.stringify(popupGeometry)})`);
        assert.equal(popupGeometry.radius, '10px', 'the open dropdown uses the shared control radius');
        assert.equal(popupGeometry.animationName, 'none', 'анимацией раскрывающегося списка больше не управляет CSS');
        assert.equal(popupGeometry.animationDuration, '0s');
        assert.equal(popupGeometry.popupDuration, 0.2, 'общая длительность раскрытия списка — 200 мс');
        if (screenshotDir) {
          await control.evaluate(node => window.scrollTo({
            top: Math.max(0, window.scrollY + node.getBoundingClientRect().top - 80), behavior: 'instant',
          }));
          await waitForNavSettled(page);
          await page.screenshot({ path: path.join(screenshotDir, `${appearance}-1440-dropdown-open.png`) });
        }
        await page.keyboard.press('Escape');
        assert.equal(await control.getAttribute('aria-expanded'), 'false', 'Escape closes the custom select');
        assert.equal(await control.evaluate(node => document.activeElement === node), true,
          'closing the custom select returns keyboard focus to its trigger');
        assert.equal(await page.locator('.segmented .seg-btn.seg-on').evaluate(node => getComputedStyle(node).boxShadow), 'none',
          'selected segmented controls use a flat surface');
        const modeSwitches = await page.locator('#app .toggle-row[data-key] .switch').evaluateAll(nodes => nodes
          .filter(node => node.getBoundingClientRect().width > 0)
          .map(node => {
          const track = node.getBoundingClientRect();
          const thumb = getComputedStyle(node.querySelector('.slider'), '::before');
          return { width: track.width, height: track.height, thumbWidth: thumb.width,
            thumbHeight: thumb.height, checked: node.querySelector('input').checked };
          }));
        assert.ok(modeSwitches.length >= 8, 'the modes page exercises its full switch family');
        assert.ok(modeSwitches.every(item => item.width === 40 && item.height === 22
          && item.thumbWidth === '16px' && item.thumbHeight === '16px'),
        `mode switches share one 40×22 track and 16×16 knob (${JSON.stringify(modeSwitches)})`);
        assert.ok(modeSwitches.some(item => item.checked) && modeSwitches.some(item => !item.checked),
          'mode switch geometry is stable in both selected states');
      }
      if (route === 'pick') {
        const pickerGeometry = await page.locator('#app .pick-mode').evaluateAll(nodes => nodes.map(node => {
          const box = node.getBoundingClientRect();
          const radio = node.querySelector('input[type="radio"]').getBoundingClientRect();
          return { left: box.left, top: box.top, width: box.width, height: box.height,
            radius: getComputedStyle(node).borderRadius, radioWidth: radio.width,
            radioHeight: radio.height, checked: node.querySelector('input').checked };
        }));
        assert.equal(pickerGeometry.length, 5, 'the strategy picker exposes five aligned mode cards');
        assert.ok(pickerGeometry.every(card => card.radius === '10px'
          && card.height >= 40 && card.radioWidth === 16 && card.radioHeight === 16),
        `mode cards use the shared corners and radio geometry (${JSON.stringify(pickerGeometry)})`);
        assert.ok(Math.abs(pickerGeometry[0].width - pickerGeometry[1].width) < 0.5
          && Math.abs(pickerGeometry[2].width - pickerGeometry[3].width) < 0.5,
        `paired mode cards share their grid widths (${JSON.stringify(pickerGeometry)})`);
        const domainField = page.locator('#pick-domain');
        const before = await domainField.evaluate(node => [node.offsetWidth, node.offsetHeight]);
        await page.locator('.pick-mode input[value="voice"]').check();
        assert.equal(await domainField.isDisabled(), true, 'voice mode disables the irrelevant domain field');
        const disabled = await domainField.evaluate(node => [node.offsetWidth, node.offsetHeight]);
        assert.deepEqual(disabled, before,
          'the domain field keeps its geometry when disabled');
        await page.locator('.pick-mode input[value="tcp13"]').check();
        assert.equal(await domainField.isDisabled(), false, 'a domain mode restores the field');
      }
      if (route === 'warp') {
        const fieldStyle = await page.locator('#warp-plus-key').evaluate(node => {
          const style = getComputedStyle(node);
          return { height: node.getBoundingClientRect().height, borderWidth: style.borderTopWidth,
            radius: style.borderRadius, background: style.backgroundColor };
        });
        assert.ok(Math.abs(fieldStyle.height - 30) < 0.05,
          'поле сохраняет высоту 30 CSS-пикселей с допуском на дробное округление браузера');
        assert.equal(fieldStyle.borderWidth, '0px', 'Lolz text controls have no visible outline border');
        assert.equal(fieldStyle.radius, '10px', 'Lolz text controls use 10 px corners');
        assert.equal(fieldStyle.background, appearance === 'dark'
          ? 'rgb(24, 30, 28)' : 'rgb(234, 241, 239)',
        'text controls use the measured dark surface or its light-theme surface');
        await page.waitForFunction(() => document.querySelectorAll('#warp-games [data-game]').length >= 5
          && document.querySelectorAll('#warp-neighbors > [data-mac]').length >= 3
          && document.querySelectorAll('#warp-neighbors .warp-offline [data-mac]').length >= 1);
        const offlineDisclosure = page.locator('#warp-neighbors .warp-offline');
        await offlineDisclosure.locator('summary').click();
        const switchGeometry = await page.locator('#app .switch:visible').evaluateAll(nodes => nodes.map(node => {
          const track = node.getBoundingClientRect();
          const thumb = getComputedStyle(node.querySelector('.slider'), '::before');
          return { width: track.width, height: track.height, thumbWidth: thumb.width, thumbHeight: thumb.height,
            checked: node.querySelector('input').checked };
        }));
        assert.ok(switchGeometry.length >= 8, `fixture exposes WARP on/off switches (${switchGeometry.length})`);
        assert.ok(switchGeometry.every(({ width, height, thumbWidth, thumbHeight }) =>
          width === 40 && height === 22 && thumbWidth === '16px' && thumbHeight === '16px'),
        `all visible WARP switches use one 40×22 track and 16×16 knob (${JSON.stringify(switchGeometry)})`);
        assert.ok(switchGeometry.some(item => item.checked) && switchGeometry.some(item => !item.checked),
          'WARP QA includes both switch states without changing track geometry');
        await offlineDisclosure.locator('summary').click();
      }
      if (route === 'diag') {
        assert.equal(await page.locator('#dns-run').count(), 1,
          'Diagnostics exposes the DNS checker once');
        assert.equal(await page.locator('#doh-card').count(), 0,
          'Diagnostics has no duplicate legacy DNS card');
        const logViewport = await page.locator('#diag-output').evaluate(node => ({
          height: node.clientHeight, scrollHeight: node.scrollHeight,
          overflowY: getComputedStyle(node).overflowY,
        }));
        assert.ok(logViewport.scrollHeight > logViewport.height && logViewport.overflowY === 'auto',
          `long diagnostic output stays inside its own scroll container (${JSON.stringify(logViewport)})`);
        await assertDiagDynamicStates(page, appearance);
      }
      if (route === 'tiktok') {
        assert.equal(await page.locator('#tiktok-toggle').count(), 1);
        assert.equal(await page.locator('[data-key="tiktok_feed"]').count(), 0,
          'Modes has no duplicate TikTok switch');
      }
      if (route === 'exclude') {
        await page.waitForFunction(() => document.querySelectorAll('#ex-list li button[data-del]').length >= 4);
        const deleteColumn = await page.locator('#ex-list li button[data-del]').evaluateAll(nodes =>
          nodes.map(node => node.getBoundingClientRect().left));
        assert.ok(Math.max(...deleteColumn) - Math.min(...deleteColumn) < 0.5,
          `address-list delete buttons form one vertical column (${JSON.stringify(deleteColumn)})`);
      }
      if (route === 'extra-domains') {
        await page.waitForFunction(() => document.querySelectorAll('#wl-list .wl-row').length >= 8);
        const listGeometry = await page.locator('#wl-list').evaluate(node => {
          const actions = Array.from(node.querySelectorAll('li button[data-del]'));
          const lefts = actions.map(action => action.getBoundingClientRect().left);
          return { rowCount: actions.length, leftDelta: Math.max(...lefts) - Math.min(...lefts),
            width: node.clientWidth, scrollWidth: node.scrollWidth, height: node.clientHeight,
            scrollHeight: node.scrollHeight, maxHeight: getComputedStyle(node).maxHeight,
            rowFontFamily: getComputedStyle(node.querySelector('li')).fontFamily,
            rowFontSize: getComputedStyle(node.querySelector('li')).fontSize };
        });
        assert.equal(listGeometry.rowCount, 16, `the list fixture exercises sixteen rows (${JSON.stringify(listGeometry)})`);
        assert.ok(listGeometry.leftDelta < 0.5, `domain delete buttons align (${JSON.stringify(listGeometry)})`);
        assert.ok(listGeometry.scrollWidth <= listGeometry.width,
          `long domain names stay inside the list width (${JSON.stringify(listGeometry)})`);
        assert.ok(listGeometry.scrollHeight > listGeometry.height && listGeometry.maxHeight === '400px',
          `long lists scroll inside their own 400 px box (${JSON.stringify(listGeometry)})`);
        assert.match(listGeometry.rowFontFamily, /^Inter, -apple-system, BlinkMacSystemFont/,
          `domain list rows use the shared Lolz Inter typography (${JSON.stringify(listGeometry)})`);
        assert.equal(listGeometry.rowFontSize, '14px',
          `domain list rows use the shared 14 px body scale (${JSON.stringify(listGeometry)})`);
      }
      if (route === 'autohostlist') {
        await page.waitForFunction(() => document.querySelectorAll('#ah-list li button[data-del]').length >= 7);
        const deleteColumn = await page.locator('#ah-list li button[data-del]').evaluateAll(nodes =>
          nodes.map(node => node.getBoundingClientRect().left));
        assert.ok(Math.max(...deleteColumn) - Math.min(...deleteColumn) < 0.5,
          'autohostlist delete buttons form one vertical column');
      }
      if (route === 'whitelist') {
        const emptyMessage = page.locator('#app .wl-list .wl-empty').first();
        await emptyMessage.waitFor({ state: 'visible' });
        const emptyMessageStyle = await emptyMessage.evaluate(node => ({
          text: node.textContent.trim(),
          fontFamily: getComputedStyle(node).fontFamily,
        }));
        assert.equal(emptyMessageStyle.text, 'Список пуст. Добавьте сайт или импортируйте файл.');
        assert.match(emptyMessageStyle.fontFamily, /^Inter, -apple-system, BlinkMacSystemFont/,
          'user-facing empty states use the shared Lolz Inter typography');
      }
      await page.waitForFunction(() => {
        const title = document.querySelector('#app .page-title');
        return title && Number.parseFloat(getComputedStyle(title).opacity) >= 0.99;
      }, null, { timeout: 1500 });
      assert.equal(await page.locator('#app [data-ui-fatal]').count(), 0,
        `${appearance}: #/${route} must not render the fatal-route fallback`);
      assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth),
        `${appearance}/1440: ${route} has no page horizontal overflow`);
      if (route === 'state') {
        await page.locator('.state-table').waitFor({ state: 'visible', timeout: 2000 });
        await page.waitForFunction(() => document.querySelectorAll('.state-table tbody tr').length >= 100, null, { timeout: 2000 });
        await assertStateGroupDisclosure(page, `${appearance}/1440`);
        const tablePanelRadius = await page.locator('.table-scroll').first().evaluate(node => getComputedStyle(node).borderRadius);
        assert.equal(tablePanelRadius, '12px',
          `${appearance}: the table wrapper keeps the measured Lolz 12 px panel radius in both themes`);
        const strategyControl = await page.locator('.state-table .chosen-single:visible').first().evaluate(node => {
          const style = getComputedStyle(node);
          const rect = node.getBoundingClientRect();
          return { width: rect.width, height: rect.height, radius: style.borderRadius };
        });
        assert.deepEqual(strategyControl, { width: 220, height: 36, radius: '10px' },
          'strategy selectors match the measured Lolz 220×36 control geometry');
        const tableGeometry = await page.locator('.state-table').evaluate(table => {
          const header = Array.from(table.tHead.rows[0].cells);
          const rows = Array.from(table.querySelectorAll('tbody tr')).filter(row => row.cells.length === header.length
            && !row.classList.contains('sg-head') && row.getBoundingClientRect().height > 0);
          const first = rows[0];
          const strategyCell = first.cells[3].getBoundingClientRect();
          const strategy = first.cells[3].querySelector('.chosen-single').getBoundingClientRect();
          const boundaries = header.map((cell, index) => {
            const head = cell.getBoundingClientRect();
            const row = first.cells[index].getBoundingClientRect();
            return [Math.abs(head.left - row.left), Math.abs(head.right - row.right)];
          }).flat();
          return { columnBoundaryDelta: Math.max(...boundaries),
            rowHeights: Array.from(new Set(rows.slice(0, 30).map(row => row.getBoundingClientRect().height))),
            strategyCellWidth: strategyCell.width,
            strategyLeftInset: strategy.left - strategyCell.left,
            strategyVerticalCenterDelta: Math.abs((strategy.top + strategy.height / 2)
              - (strategyCell.top + strategyCell.height / 2)),
            sniRows: rows.filter(row => row.querySelector('.state-sni')).length };
        });
        assert.ok(tableGeometry.columnBoundaryDelta < 0.5,
          `table headings and rows share one column grid (${JSON.stringify(tableGeometry)})`);
        assert.deepEqual(tableGeometry.rowHeights, [54],
          `standard and SNI rows keep one desktop row height (${JSON.stringify(tableGeometry)})`);
        assert.equal(tableGeometry.strategyCellWidth, 236);
        assert.equal(tableGeometry.strategyLeftInset, 8);
        assert.ok(tableGeometry.strategyVerticalCenterDelta < 0.5,
          `strategy controls are vertically centered in their cells (${JSON.stringify(tableGeometry)})`);
        assert.ok(tableGeometry.sniRows > 0, 'the populated fixture exercises the optional SNI line');
        const dangerStyle = await page.locator('#app .btn-danger').first().evaluate(node => {
          const style = getComputedStyle(node);
          return { background: style.backgroundColor, color: style.color, radius: style.borderRadius };
        });
        assert.deepEqual(dangerStyle, { background: 'rgb(139, 56, 56)', color: 'rgb(245, 245, 245)', radius: '10px' },
          'destructive controls use the source filled red button treatment');
      }
      if (route === 'state' || route === 'pick') {
        await page.waitForFunction(() => {
          const tabs = document.querySelector('.strat-tabs');
          return tabs && getComputedStyle(tabs, '::after').opacity === '1';
        }, null, { timeout: 1200 });
        const tabIndicator = await page.locator('.strat-tabs').evaluate(node => {
          const style = getComputedStyle(node, '::after');
          return { left: node.style.getPropertyValue('--tab-left'), width: node.style.getPropertyValue('--tab-width'),
            opacity: style.opacity, transition: style.transition };
        });
        assert.notEqual(tabIndicator.width, '', `${appearance}/${route}: active-tab width is measured from the selected link`);
        assert.equal(tabIndicator.opacity, '1', `${appearance}/${route}: source underline is visible`);
        assert.equal(tabIndicator.transition, 'none',
          `${appearance}/${route}: GSAP управляет анимацией индикатора вкладки`);
        assert.ok(tabIndicator.left.endsWith('px'), `${appearance}/${route}: source position variable is applied`);
        await page.locator('.strat-tabs').evaluate(tabs => {
          const spacer = document.createElement('span');
          spacer.dataset.qaTabScrollSpacer = 'true';
          spacer.style.cssText = 'flex:0 0 420px;width:420px';
          tabs.appendChild(spacer);
          tabs.scrollLeft = 40;
          tabs.dispatchEvent(new Event('scroll'));
        });
        await page.waitForFunction(() => {
          const tabs = document.querySelector('.strat-tabs');
          const active = tabs && tabs.querySelector('.strat-tab.active');
          const left = tabs && Number.parseFloat(tabs.style.getPropertyValue('--tab-left'));
          return active && Math.abs(left - (active.offsetLeft - tabs.scrollLeft)) < 0.01;
        }, null, { timeout: 1200 });
        const tabScrollMotion = await page.locator('.strat-tabs').evaluate(tabs => {
          const active = tabs.querySelector('.strat-tab.active');
          const result = { left: Number.parseFloat(tabs.style.getPropertyValue('--tab-left')),
            expectedLeft: active.offsetLeft - tabs.scrollLeft,
            marginLeft: getComputedStyle(tabs, '::after').marginLeft };
          tabs.querySelector('[data-qa-tab-scroll-spacer="true"]')?.remove();
          tabs.scrollLeft = 0;
          tabs.dispatchEvent(new Event('scroll'));
          return result;
        });
        assert.ok(Math.abs(tabScrollMotion.left - tabScrollMotion.expectedLeft) < 0.01,
          `${appearance}/${route}: source tab indicator follows horizontal scroll (${JSON.stringify(tabScrollMotion)})`);
        assert.equal(tabScrollMotion.marginLeft, '5px', `${appearance}/${route}: source underline has its 5 px inset`);
      }
      assert.equal(await lockup.locator('#brand-composite-logo').count(), 1, `${appearance}: single mark on #/${route}`);
      if (screenshotDir && screenshotRoutes.includes(route)) {
        await page.evaluate(() => window.scrollTo(0, 0));
        await page.mouse.move(1439, 899);
        await waitForNavSettled(page);
        await page.screenshot({ path: path.join(screenshotDir, `${appearance}-1440-${route}.png`) });
        if (route === 'warp') {
          const deviceCard = page.locator('#warp-devices-card');
          await deviceCard.evaluate(node => window.scrollTo({
            top: Math.max(0, window.scrollY + node.getBoundingClientRect().top - 60), behavior: 'instant',
          }));
          await waitForNavSettled(page);
          const offlineDisclosure = page.locator('#warp-neighbors .warp-offline');
          await offlineDisclosure.locator('summary').click();
          await page.screenshot({ path: path.join(screenshotDir, `${appearance}-1440-warp-devices.png`) });
        }
        if (route === 'diag') {
          const log = page.locator('#diag-output');
          await log.evaluate(node => {
            const card = node.closest('.card');
            window.scrollTo({
              top: Math.max(0, window.scrollY + card.getBoundingClientRect().top - 60), behavior: 'instant',
            });
          });
          await waitForNavSettled(page);
          await log.evaluate(node => { node.scrollTop = node.scrollHeight; });
          await page.screenshot({ path: path.join(screenshotDir, `${appearance}-1440-diag-log.png`) });
        }
        if (route === 'credits') {
          const disclosure = page.locator('#credits-upstream');
          await disclosure.locator('summary').click();
          assert.equal(await disclosure.getAttribute('open'), '', 'upstream credit details open for screenshot review');
          await page.screenshot({ path: path.join(screenshotDir, `${appearance}-1440-credits-upstream-open.png`) });
          await disclosure.locator('summary').click();
        }
        fs.writeFileSync(path.join(screenshotDir, `${appearance}-${route}.json`), JSON.stringify(await page.evaluate(() => ({
          route: location.hash,
          page: document.body.dataset.page,
          appText: document.querySelector('#app')?.innerText.slice(0, 600) || '',
          tableRows: document.querySelectorAll('.state-table tbody tr').length,
          contentStyle: (() => {
            const element = document.querySelector('.unique-set-card') || document.querySelector('.page-title');
            if (!element) return null;
            const style = getComputedStyle(element);
            const rect = element.getBoundingClientRect();
            return { tag: element.tagName, display: style.display, visibility: style.visibility,
              opacity: style.opacity, color: style.color, background: style.backgroundColor,
              rect: { x: rect.x, y: rect.y, width: rect.width, height: rect.height } };
          })(),
          scrollWidth: document.documentElement.scrollWidth,
          clientWidth: document.documentElement.clientWidth,
        })), null, 2));
      }
    }
    for (const { width, height } of [
      { width: 1920, height: 1080 },
      { width: 1440, height: 900 },
      { width: 1366, height: 768 },
      { width: 1280, height: 720 },
      { width: 1079, height: 900 },
      { width: 1024, height: 900 },
      { width: 800, height: 900 },
      { width: 768, height: 900 },
    ]) {
      await page.setViewportSize({ width, height });
      if (width >= 768 && width <= 1079) {
        await page.waitForFunction(expectedWidth => {
          const nav = document.querySelector('#nav').getBoundingClientRect();
          const app = document.querySelector('#app').getBoundingClientRect();
          return Math.abs(nav.x) < 0.5 && Math.abs(nav.width - 261) < 0.5
            && Math.abs(app.x - 280) < 0.5 && Math.abs(app.width - (expectedWidth - 304)) < 0.5;
        }, width, { timeout: 1500 });
        const tabletFrame = await page.evaluate(() => ({
          viewport: document.documentElement.clientWidth,
          scrollWidth: document.documentElement.scrollWidth,
          navX: document.querySelector('#nav').getBoundingClientRect().x,
          navWidth: document.querySelector('#nav').getBoundingClientRect().width,
          appX: document.querySelector('#app').getBoundingClientRect().x,
          appWidth: document.querySelector('#app').getBoundingClientRect().width,
        }));
        assert.ok(tabletFrame.scrollWidth <= tabletFrame.viewport,
          `${appearance}/${width}: tablet shell has no page horizontal overflow (${JSON.stringify(tabletFrame)})`);
        assert.ok(Math.abs(tabletFrame.navX) < 1 && Math.abs(tabletFrame.navWidth - 261) < 1,
          `${appearance}/${width}: tablet navigation stays fully visible at 261 px (${JSON.stringify(tabletFrame)})`);
        assert.ok(Math.abs(tabletFrame.appX - 280) < 1 && Math.abs(tabletFrame.appWidth - (width - 304)) < 1,
          `${appearance}/${width}: tablet content fits beside the navigation with 20 px gap (${JSON.stringify(tabletFrame)})`);
      }
      for (const route of routes) {
        await page.evaluate(name => { location.hash = '#/' + name; }, route);
        await waitForRenderedRoute(page, route);
        if (route === 'state') {
          await page.locator('.state-table').waitFor({ state: 'visible', timeout: 1500 });
          await page.waitForFunction(() => document.querySelectorAll('.state-table tbody tr').length >= 100, null, { timeout: 2000 });
        }
        assert.equal(await page.locator('#app [data-ui-fatal]').count(), 0, `${appearance}/${width}: ${route}`);
        const responsiveFrame = await page.evaluate(() => ({
          viewport: document.documentElement.clientWidth,
          scrollWidth: document.documentElement.scrollWidth,
          minWidthProbe: (() => {
            const rows = Array.from(document.querySelectorAll('#warp-games > .toggle-row'));
            const originalValues = rows.map(row => row.style.minWidth);
            rows.forEach(row => { row.style.minWidth = '0'; });
            const fittedWidth = document.documentElement.scrollWidth;
            rows.forEach((row, index) => { row.style.minWidth = originalValues[index]; });
            return { rowCount: rows.length, fittedWidth };
          })(),
          overflowCandidates: Array.from(document.querySelectorAll('#app *')).map(node => {
            const rect = node.getBoundingClientRect();
            return { tag: node.tagName, id: node.id, className: String(node.className || ''),
              game: node.closest('[data-game]')?.getAttribute('data-game') || '',
              gridWidth: node.closest('.warp-games')?.getBoundingClientRect().width || 0,
              left: Math.round(rect.left * 10) / 10, right: Math.round(rect.right * 10) / 10,
              width: Math.round(rect.width * 10) / 10, scrollWidth: node.scrollWidth,
              clientWidth: node.clientWidth };
          }).filter(node => node.right > innerWidth + 1 || node.left < -1)
            .sort((left, right) => right.right - left.right).slice(0, 8),
        }));
        assert.ok(responsiveFrame.scrollWidth <= responsiveFrame.viewport,
          `${appearance}/${width}: ${route} has no page horizontal overflow (${JSON.stringify(responsiveFrame)})`);
        if (route === 'dashboard' && [768, 800].includes(width)) {
          const statusGridGeometry = await page.locator('#status-grid').evaluate(grid => {
            const cells = Array.from(grid.querySelectorAll('.status-cell'));
            const columns = getComputedStyle(grid).gridTemplateColumns.trim().split(/\s+/);
            return { count: cells.length, columnCount: columns.length, columns,
              cellWidths: cells.map(cell => Math.round(cell.getBoundingClientRect().width * 10) / 10),
              labels: cells.map(cell => cell.querySelector('.label')?.textContent.trim() || '') };
          });
          assert.equal(statusGridGeometry.count, 6,
            `${appearance}/${width}: dashboard status grid has its six settled cells (${JSON.stringify(statusGridGeometry)})`);
          assert.equal(statusGridGeometry.columnCount, 2,
            `${appearance}/${width}: dashboard status grid retains two tablet columns (${JSON.stringify(statusGridGeometry)})`);
          assert.ok(statusGridGeometry.cellWidths.every(cellWidth => cellWidth >= 160),
            `${appearance}/${width}: dashboard status tiles retain the 160 px minimum at the compact tablet shell (${JSON.stringify(statusGridGeometry)})`);
          if (screenshotDir) fs.writeFileSync(path.join(screenshotDir,
            `${appearance}-${width}-dashboard-status-grid.json`), JSON.stringify(statusGridGeometry, null, 2));
        }
        if (width === 768 && route === 'warp') {
          const warpColumns = await page.locator('#warp-games').evaluate(node => ({
            count: getComputedStyle(node).gridTemplateColumns.trim().split(/\s+/).length,
            names: Array.from(node.querySelectorAll('.t-name')).map(name => ({
              overflow: getComputedStyle(name).textOverflow,
              scrollWidth: name.scrollWidth,
              clientWidth: name.clientWidth,
            })),
          }));
          assert.equal(warpColumns.count, 2, `tablet WARP keeps its measured two-column game grid (${JSON.stringify(warpColumns)})`);
          assert.ok(warpColumns.names.every(name => name.overflow === 'ellipsis' && name.scrollWidth >= name.clientWidth),
            `long WARP labels truncate within their columns (${JSON.stringify(warpColumns)})`);
        }
        if (screenshotDir && responsiveScreenshotRoutes.includes(route)
            && ([1920, 1366, 1280].includes(width) || (appearance === 'dark' && width === 1024 && route === 'dashboard')
              || (width === 1079 && route === 'warp')
              || (width === 1024 && route === 'dashboard')
              || ([768, 800].includes(width) && route === 'dashboard')
              || (width === 768 && route === 'warp'))) {
          await page.evaluate(() => window.scrollTo(0, 0));
          await page.mouse.move(width - 1, height - 1);
          await waitForNavSettled(page);
          await page.waitForFunction(() => {
            const tabs = document.querySelector('.strat-tabs');
            if (!tabs) return true;
            const active = tabs.querySelector('.strat-tab.active, .strat-tab[aria-selected="true"]');
            if (!active) return false;
            const indicator = getComputedStyle(tabs, '::after');
            const close = (actual, expected) => Math.abs(parseFloat(actual) - expected) < 1;
            return window.gsap.getTweensOf(tabs).every(tween => !tween.isActive())
              && close(indicator.left, active.offsetLeft - tabs.scrollLeft)
              && close(indicator.top, active.offsetTop + active.offsetHeight - 2)
              && close(indicator.width, active.offsetWidth);
          }, null, { timeout: 1500 });
          await page.screenshot({ path: path.join(screenshotDir, `${appearance}-${width}-${route}.png`) });
        }
      }
    }
    await page.evaluate(() => { location.hash = '#/toggles'; window.scrollTo(0, 0); });
    await waitForRenderedRoute(page, 'toggles');
    const telegramCard = page.locator('.telegram-tunnel-card');
    await telegramCard.waitFor({ state: 'visible', timeout: 3000 });
    assert.equal(await telegramCard.isVisible(), true, `${appearance}: Telegram card is visible`);
    await page.waitForFunction(() => document.querySelector('#tg-flow')?.dataset.state === 'active');
    const flowDiagram = page.locator('#tg-flow');
    const flowCanvas = flowDiagram.locator('#tg-flow-canvas');
    assert.equal(await flowCanvas.count(), 1,
      `${appearance}: схема потока отрисована одним Canvas`);
    assert.equal(await telegramCard.locator('svg').evaluateAll(nodes => nodes.filter(node => !node.closest('.disclosure-chevron')).length), 0,
      `${appearance}: старая SVG-схема удалена`);
    assert.equal(await flowDiagram.getAttribute('data-state'), 'active',
      `${appearance}: состояние схемы следует телеметрии активной сессии`);
    assert.match(await flowDiagram.locator('#tg-flow-caption').innerText(), /Прямой WSS/,
      `${appearance}: подпись показывает выбранный из Rust-телеметрии транспорт`);
    assert.equal(await page.locator('#tg-active-route').innerText(), 'Прямой WSS',
      `${appearance}: сводка показывает транспорт выбранной сессии`);
    assert.match(await flowCanvas.getAttribute('aria-label'), /Клиент → tg-ws-proxy → Telegram DC/,
      `${appearance}: Canvas имеет доступное описание маршрута`);
    assert.doesNotMatch(await flowDiagram.innerText(), /resPQ.*подтверждён/i,
      `${appearance}: WSS-маршрут не выдаётся за проверку resPQ`);
    assert.equal(await flowDiagram.locator('button, select, input').count(), 0,
      `${appearance}: схема не содержит переключателей сценария`);
    const flowColors = await flowCanvas.evaluate(canvas => {
      const readToken = (parent, token) => {
        const probe = document.createElement('span');
        probe.style.color = `var(${token})`;
        parent.appendChild(probe);
        const color = getComputedStyle(probe).color;
        probe.remove();
        return color;
      };
      return {
        direct: readToken(canvas.parentElement, '--tg-flow-direct'), directTheme: readToken(document.body, '--good'),
        warning: readToken(canvas.parentElement, '--tg-flow-cloudflare'), warningTheme: readToken(document.body, '--warn'),
        text: readToken(canvas.parentElement, '--tg-flow-text'), textTheme: readToken(document.body, '--text'),
        background: readToken(canvas.parentElement, '--tg-flow-background'), backgroundTheme: readToken(document.body, '--bg-card'),
      };
    });
    assert.equal(flowColors.direct, flowColors.directTheme,
      `${appearance}: прямой маршрут использует цветовой токен активной Lolz-темы`);
    assert.equal(flowColors.warning, flowColors.warningTheme,
      `${appearance}: Cloudflare использует цветовой токен активной Lolz-темы`);
    assert.equal(flowColors.text, flowColors.textTheme,
      `${appearance}: подписи Canvas используют текстовый токен активной Lolz-темы`);
    assert.equal(flowColors.background, flowColors.backgroundTheme,
      `${appearance}: фон Canvas совпадает с поверхностью активной Lolz-темы`);
    const flowSize = await flowCanvas.evaluate(node => {
      const rect = node.getBoundingClientRect();
      return { width: rect.width, height: rect.height, ratio: rect.width / rect.height };
    });
    assert.ok(Math.abs(flowSize.ratio - 760 / 340) < 0.02,
      `${appearance}: Canvas сохраняет пропорции референса (${JSON.stringify(flowSize)})`);
    assert.equal(await page.locator('#tg-desc').innerText(),
      'Состояние маршрута берётся из телеметрии Rust-прокси.',
      `${appearance}: карточка указывает реальный источник состояния маршрута`);
    await page.locator('#tg-advanced-settings').waitFor({ state: 'attached' });
    assert.equal(await page.locator('#tg-advanced-settings').getAttribute('open'), null,
      `${appearance}: подробные настройки свёрнуты при открытии карточки`);
    await page.waitForFunction(() => document.querySelector('#tg-runtime-details')?.textContent
      && document.querySelector('#tg-check-results')?.textContent.trim());
    if (await page.locator('body').getAttribute('data-sidebar') === 'collapsed') {
      await page.locator('#sidebar-collapse').click();
      await page.waitForFunction(() => document.body.getAttribute('data-sidebar') === null);
    }
    for (const width of [1440, 1280, 1024, 768, 390, 375, 320]) {
      await page.setViewportSize({ width, height: width < 500 ? 844 : 900 });
      await waitForNavSettled(page);
      await page.evaluate(() => window.scrollTo(0, 0));
      const frame = await page.evaluate(() => ({
        viewport: document.documentElement.clientWidth,
        pageWidth: document.documentElement.scrollWidth,
        cardWidth: document.querySelector('.telegram-tunnel-card').getBoundingClientRect().width,
        cardScrollWidth: document.querySelector('.telegram-tunnel-card').scrollWidth,
        cardClientWidth: document.querySelector('.telegram-tunnel-card').clientWidth,
        cardFont: getComputedStyle(document.querySelector('.telegram-tunnel-card')).fontFamily,
        bodyFont: getComputedStyle(document.body).fontFamily,
        inputColorScheme: getComputedStyle(document.querySelector('#tg-worker-domain')).colorScheme,
        pageName: document.body.getAttribute('data-page'),
        sidebarState: document.body.getAttribute('data-sidebar'),
        narrowBreakpoint: matchMedia('(min-width: 768px) and (max-width: 1091px)').matches,
        appCssWidth: getComputedStyle(document.querySelector('#app')).width,
        overflowingElements: [...document.querySelectorAll('body *')].map(node => ({
          tag: node.tagName, id: node.id, parentId: node.parentElement?.id || '', className: String(node.className || ''),
          right: Math.round(node.getBoundingClientRect().right), width: Math.round(node.getBoundingClientRect().width),
        })).filter(node => node.right > document.documentElement.clientWidth + 1 && node.width > 0
          && (node.id === 'app' || node.parentId === 'app' || node.className.includes('telegram') || node.className.includes('flow-benchmark')))
          .slice(0, 20),
      }));
      if (screenshotDir) {
        await telegramCard.evaluate(node => node.scrollIntoView({ block: 'start', behavior: 'instant' }));
        await waitForNavSettled(page);
        await screenshotComponent(page, telegramCard,
          path.join(screenshotDir, `${screenshotPrefix}${appearance}-${width}-telegram-card.png`));
      }
      if (tgScreenshotOnly) continue;
      assert.ok(frame.pageWidth <= frame.viewport,
        `${appearance}/${width}: Telegram adds no page horizontal scrolling (${JSON.stringify(frame)})`);
      assert.ok(frame.cardScrollWidth <= frame.cardClientWidth + 1,
        `${appearance}/${width}: card content stays within its width (${JSON.stringify(frame)})`);
      assert.equal(frame.cardFont, frame.bodyFont, `${appearance}/${width}: Telegram inherits the panel font`);
      assert.equal(frame.inputColorScheme, appearance, `${appearance}/${width}: Telegram controls follow the active theme`);
      const canvasRatio = await flowCanvas.evaluate(node => {
        const rect = node.getBoundingClientRect();
        return rect.width / rect.height;
      });
      if (width <= 600) {
        const canvasSize = await flowCanvas.evaluate(node => ({
          width: node.getBoundingClientRect().width,
          height: node.getBoundingClientRect().height,
        }));
        assert.ok(canvasSize.height >= 220,
          `${appearance}/${width}: схема сохраняет читаемую высоту на узком экране (${JSON.stringify(canvasSize)})`);
      } else {
        assert.ok(Math.abs(canvasRatio - 760 / 340) < 0.02,
          `${appearance}/${width}: широкая схема сохраняет пропорции референса`);
      }
      const advanced = telegramCard.locator('#tg-advanced-settings');
      await advanced.locator(':scope > summary').click();
      await waitForDisclosureSettled(page, '#tg-advanced-settings');
      await page.locator('#tg-openwrt-tools').waitFor({ state: 'visible' });
      await page.waitForFunction(() => document.querySelector('.tg-summary-grid')
        && document.querySelectorAll('#tg-check-results .tg-dc-row').length === 5, null, { timeout: 1200 });
      assert.equal(await telegramCard.locator('#tg-check').evaluate(node => node.closest('#tg-advanced-settings') === null), true,
        `${appearance}/${width}: кнопка проверки остаётся в основной карточке`);
      assert.equal(await telegramCard.locator('#tg-check').isVisible(), true,
        `${appearance}/${width}: проверка доступна без раскрытия дополнительных настроек`);
      const diagnosticDetails = telegramCard.locator('#tg-diagnostic-details');
      await diagnosticDetails.locator(':scope > summary').click();
      await waitForDisclosureSettled(page, '#tg-diagnostic-details');
      assert.equal(await telegramCard.locator('.tg-dc-row').count(), 5,
        `${appearance}/${width}: the compact list has one row for DC1–DC5`);
      const dc1 = telegramCard.locator('.tg-dc-row').first();
      await dc1.locator('summary').click();
      assert.equal(await dc1.getAttribute('open'), '', `${appearance}/${width}: a DC row expands on activation`);
      const dc1Details = await dc1.innerText();
      for (const field of ['Прямой WSS', '149.154.175.50', 'HTTP 503', 'websocket', 'DNS', 'TCP', 'TLS', 'MTProto']) {
        assert.ok(dc1Details.includes(field), `${appearance}/${width}: expanded DC1 keeps ${field}`);
      }
      const runtimeTechnical = telegramCard.locator('.tg-technical');
      if (await runtimeTechnical.getAttribute('open') !== null) {
        await runtimeTechnical.locator('summary').click();
      }
      const overviewText = await telegramCard.locator('.tg-summary-grid').innerText();
      for (const label of ['Активные соединения', 'Сессии с ответом WSS', 'Память процесса', 'Карта DC']) {
        assert.ok(overviewText.includes(label), `${appearance}/${width}: compact stats expose ${label}`);
      }
      assert.ok(overviewText.includes('не подтверждает resPQ'),
        `${appearance}/${width}: traffic counters are distinct from a resPQ check`);
      assert.doesNotMatch(overviewText, /dc203:cf-proxy|http_503|generation/,
        `${appearance}/${width}: raw technical keys stay in the closed disclosure`);
      await runtimeTechnical.locator('summary').click();
      await waitForDisclosureSettled(page, '#tg-runtime-details .tg-technical');
      assert.equal(await runtimeTechnical.getAttribute('open'), '', `${appearance}/${width}: technical stats expand`);
      const technicalText = await runtimeTechnical.innerText();
      for (const value of ['dc203:cf-proxy', 'http_503', 'generation', 'Счётчики накоплены с момента запуска процесса']) {
        assert.ok(technicalText.includes(value), `${appearance}/${width}: technical details retain ${value}`);
      }
      assert.doesNotMatch(await telegramCard.locator('#tg-runtime-status').innerText(), /проверенный MTProto-ответ/i,
        `${appearance}/${width}: ordinary traffic does not claim to verify an MTProto response`);
      if (screenshotDir && ((appearance === 'dark' && width === 390)
          || (appearance === 'light' && width === 1440))) {
        await screenshotComponent(page, telegramCard,
          path.join(screenshotDir, `${screenshotPrefix}${appearance}-${width}-telegram-card-details.png`));
      }
      await runtimeTechnical.locator('summary').click();
      await dc1.locator('summary').click();
      await diagnosticDetails.locator(':scope > summary').click();
      await waitForDisclosureSettled(page, '#tg-diagnostic-details');
      await advanced.locator(':scope > summary').click();
      await waitForDisclosureSettled(page, '#tg-advanced-settings');
    }

    const savedTgStats = tgStatsResponse;
    tgStatsResponse = { ...tgStatsFixture, active_connections: 0, active_sessions: [] };
    await page.evaluate(() => { location.hash = '#/dashboard'; });
    await waitForRenderedRoute(page, 'dashboard');
    await page.evaluate(() => { location.hash = '#/toggles'; });
    await waitForRenderedRoute(page, 'toggles');
    await page.waitForFunction(() => document.querySelector('#tg-flow')?.dataset.state === 'idle'
      && document.querySelector('#tg-flow-caption')?.textContent.includes('Нет активных соединений'));
    const idleRoute = page.locator('#tg-flow');
    const idleCaption = idleRoute.locator('#tg-flow-caption');
    await idleCaption.waitFor({ state: 'visible' });
    assert.match(await idleCaption.innerText(), /Нет активных соединений/,
      `${appearance}: при отсутствии соединений схема показывает пустое состояние`);
    assert.equal(await idleRoute.locator('#tg-flow-canvas').count(), 1,
      `${appearance}: Canvas сохраняется в состоянии простоя`);
    tgStatsResponse = savedTgStats;

    for (const width of [1080, 1081, 1085, 1090, 1091, 1092]) {
      await page.setViewportSize({ width, height: 900 });
      const edgeFrame = await page.evaluate(() => ({
        viewport: document.documentElement.clientWidth,
        brand: document.querySelector('#panel-brand').getBoundingClientRect().toJSON(),
        nav: document.querySelector('#nav').getBoundingClientRect().toJSON(),
        app: document.querySelector('#app').getBoundingClientRect().toJSON(),
      }));
      assert.ok(edgeFrame.brand.left >= 0 && edgeFrame.nav.left >= 0
        && edgeFrame.app.right <= edgeFrame.viewport,
      `${appearance}/${width}: shell stays inside the viewport at the desktop breakpoint (${JSON.stringify(edgeFrame)})`);
    }
    await page.evaluate(() => { location.hash = '#/state'; });
    await waitForRenderedRoute(page, 'state');
    await page.locator('.state-table').waitFor({ state: 'visible', timeout: 1500 });
    assert.equal(await page.locator('.state-table').evaluate(node => node.tagName), 'TABLE', 'dense desktop data stays a table');
    const frozenRow = await page.locator('.state-table tbody tr').filter({ has: page.locator('.state-strat-sel[data-mode="frozen"]') }).first().evaluate(row => ({
      frozen: row.dataset.frozen,
      inlineBackground: row.style.background,
      background: getComputedStyle(row).backgroundColor,
      selectedSurface: (() => {
        const probe = document.createElement('span');
        probe.style.backgroundColor = 'var(--ow-surface-selected)';
        document.body.appendChild(probe);
        const color = getComputedStyle(probe).backgroundColor;
        probe.remove();
        return color;
      })(),
    }));
    assert.equal(frozenRow.frozen, 'true', `frozen table state is semantic and themeable (${JSON.stringify(frozenRow)})`);
    assert.equal(frozenRow.inlineBackground, '', 'row color comes from the shared Lolz surface token');
    assert.equal(frozenRow.background, frozenRow.selectedSurface, 'frozen rows use the source selected surface');
    assert.equal((await page.locator('.unique-set-badge').innerText()).trim(), 'Экспериментальная функция');
    assert.equal(await page.locator('#unique-set-reset-all').evaluate(node => node.classList.contains('btn-danger')), false,
      'reversible return-to-automatic action is not destructive red');

    assert.ok(moduleResponses.length > 0, 'the browser must load the real ES-module graph');
    for (const response of moduleResponses) {
      assert.equal(response.status, 200, `required module failed: ${response.url}`);
      assert.match(response.type, /javascript/i, `wrong module MIME: ${response.url} (${response.type})`);
    }
    assert.ok([...requestedOrigins].every(origin => origin === base), 'the panel must load every resource locally');
    assert.deepEqual(pageErrors, [], `${appearance}: no uncaught browser exceptions`);
    assert.deepEqual(consoleErrors, [], `${appearance}: no browser console errors`);
    allPageErrors.push(...pageErrors);
    allConsoleErrors.push(...consoleErrors);
    totalModuleResponses += moduleResponses.length;
    await page.close();
  }

  // Hold the OpenWrt profile response to prove the Lolz shell theme is already
  // applied on the first rendered Full-HD dashboard, independent of identity.
  const firstPaintPage = await browser.newPage({ viewport: { width: 1920, height: 1080 }, colorScheme: 'dark' });
  let markProfileRequestStarted;
  const profileRequestStarted = new Promise(resolve => { markProfileRequestStarted = resolve; });
  let profileReleased = false;
  let releaseProfileRequest;
  await firstPaintPage.route('**/assets/openwrt/profile.json', route => {
    markProfileRequestStarted();
    return new Promise(resolve => {
      releaseProfileRequest = async () => {
        await route.continue();
        profileReleased = true;
        resolve();
      };
    });
  });
  await firstPaintPage.goto(`${base}/#/dashboard`, { waitUntil: 'domcontentloaded' });
  await profileRequestStarted;
  await waitForRenderedRoute(firstPaintPage, 'dashboard');
  assert.equal(profileReleased, false, 'first-paint measurements are taken while the OpenWrt profile request is held');
  const firstPaintTheme = await firstPaintPage.evaluate(() => ({
    fontFamily: getComputedStyle(document.body).fontFamily,
    fontSize: getComputedStyle(document.body).fontSize,
    topbarHeight: `${document.querySelector('.topbar').getBoundingClientRect().height}px`,
  }));
  await releaseProfileRequest();
  assert.match(firstPaintTheme.fontFamily, /^Inter, -apple-system, BlinkMacSystemFont/,
    `Full-HD first paint uses the locally bundled Lolz Inter font while profile.json is held (${JSON.stringify(firstPaintTheme)})`);
  assert.equal(firstPaintTheme.fontSize, '14px',
    `Full-HD first paint uses the Lolz 14 px body size while profile.json is held (${JSON.stringify(firstPaintTheme)})`);
  assert.equal(firstPaintTheme.topbarHeight, '58px',
    `Full-HD first paint uses the OpenWrt 58 px topbar while profile.json is held (${JSON.stringify(firstPaintTheme)})`);
  await firstPaintPage.close();

  const motionPage = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'dark' });
  await motionPage.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(motionPage, 'dashboard');
  const modalMotion = await motionPage.evaluate(async () => {
    const { openModalBackdrop, closeModalBackdrop } = await import('/js/core/modal.js');
    const backdrop = document.createElement('div');
    backdrop.className = 'modal-backdrop';
    backdrop.innerHTML = '<div class="modal">Lolz modal state check</div>';
    const modal = backdrop.querySelector('.modal');
    document.body.appendChild(backdrop);
    const start = { backdropOpacity: getComputedStyle(backdrop).opacity,
      modalOpacity: getComputedStyle(modal).opacity,
      modalTransform: getComputedStyle(modal).transform,
      transitionDuration: getComputedStyle(modal).transitionDuration,
      transitionProperty: getComputedStyle(modal).transitionProperty };
    openModalBackdrop(backdrop);
    const openedSettled = await new Promise(resolve => {
      const deadline = performance.now() + 1500;
      const wait = () => {
        const settled = getComputedStyle(backdrop).opacity === '1'
          && getComputedStyle(modal).opacity === '1'
          && !window.gsap.getTweensOf([modal, backdrop]).some(tween => tween.isActive());
        if (settled || performance.now() >= deadline) resolve(settled);
        else requestAnimationFrame(wait);
      };
      wait();
    });
    if (!openedSettled) throw new Error('анимация открытия окна GSAP не достигла конечного состояния');
    const opened = { backdrop: backdrop.classList.contains('in'), modal: modal.classList.contains('in'),
      backdropOpacity: getComputedStyle(backdrop).opacity,
      modalOpacity: getComputedStyle(modal).opacity,
      modalTransform: getComputedStyle(modal).transform };
    closeModalBackdrop(backdrop);
    const closing = { backdrop: backdrop.classList.contains('in'), modal: modal.classList.contains('in'),
      closing: backdrop.dataset.modalClosing };
    await new Promise(resolve => setTimeout(resolve, 220));
    return { start, opened, closing, removed: !backdrop.isConnected };
  });
  assert.equal(modalMotion.start.modalOpacity, '0', 'Lolz modal starts transparent');
  assert.ok(Math.abs(Number(modalMotion.start.modalTransform.match(/^matrix\(([^,]+)/)?.[1]) - 0.9) < 0.002,
    'Lolz modal starts at scale(.9)');
  assert.equal(modalMotion.start.transitionDuration, '0s');
  assert.equal(modalMotion.start.transitionProperty, 'none');
  assert.deepEqual([modalMotion.opened.backdrop, modalMotion.opened.modal,
    modalMotion.opened.backdropOpacity, modalMotion.opened.modalOpacity], [true, true, '1', '1']);
  assert.equal(modalMotion.opened.modalTransform, 'matrix(1, 0, 0, 1, 0, 0)');
  assert.deepEqual([modalMotion.closing.backdrop, modalMotion.closing.modal, modalMotion.closing.closing],
    [true, true, 'true']);
  assert.equal(modalMotion.removed, true, 'modal backdrop is removed after the source close transition');
  if (screenshotDir) {
    await motionPage.evaluate(() => {
      const backdrop = document.createElement('div');
      backdrop.className = 'modal-backdrop in';
      backdrop.dataset.qaModalScreenshot = 'true';
      backdrop.innerHTML = '<div class="modal in"><h3>История обновлений</h3><p>Обновление проверено.</p><button class="btn btn-secondary" type="button">Закрыть</button></div>';
      document.body.appendChild(backdrop);
    });
    await motionPage.screenshot({ path: path.join(screenshotDir, 'dark-1440-modal-open.png') });
    await motionPage.locator('[data-qa-modal-screenshot="true"]').evaluate(node => node.remove());
    await motionPage.evaluate(() => { location.hash = '#/diag'; });
    await waitForRenderedRoute(motionPage, 'diag');
    const visibleButton = motionPage.locator('#app .btn-primary:visible').first();
    if (await visibleButton.count()) {
      await visibleButton.hover();
      await motionPage.waitForFunction(() => {
        const button = document.querySelector('#app .btn-primary:hover');
        return button && getComputedStyle(button, '::before').opacity === '1';
      });
      await motionPage.screenshot({ path: path.join(screenshotDir, 'dark-1440-primary-button-hover.png') });
      await motionPage.mouse.move(1439, 899);
    }
  }
  await motionPage.close();
  if (screenshotDir) {
    const lightMotionPage = await browser.newPage({ viewport: { width: 1440, height: 900 }, colorScheme: 'light' });
    await lightMotionPage.addInitScript(() => localStorage.setItem('z2k-theme', 'light'));
    await lightMotionPage.goto(`${base}/#/diag`);
    await waitForRenderedRoute(lightMotionPage, 'diag');
    await lightMotionPage.waitForFunction(() => document.documentElement.dataset.theme === 'light');
    await lightMotionPage.evaluate(() => {
      const backdrop = document.createElement('div');
      backdrop.className = 'modal-backdrop in';
      backdrop.dataset.qaModalScreenshot = 'true';
      backdrop.innerHTML = '<div class="modal in"><h3>История обновлений</h3><p>Обновление проверено.</p><button class="btn btn-secondary" type="button">Закрыть</button></div>';
      document.body.appendChild(backdrop);
    });
    await lightMotionPage.screenshot({ path: path.join(screenshotDir, 'light-1440-modal-open.png') });
    await lightMotionPage.locator('[data-qa-modal-screenshot="true"]').evaluate(node => node.remove());
    const lightPrimary = lightMotionPage.locator('#app .btn-primary:visible').first();
    if (await lightPrimary.count()) {
      await lightPrimary.hover();
      await lightMotionPage.waitForFunction(() => {
        const button = document.querySelector('#app .btn-primary:hover');
        return button && getComputedStyle(button, '::before').opacity === '1';
      });
      await lightMotionPage.screenshot({ path: path.join(screenshotDir, 'light-1440-primary-button-hover.png') });
    }
    await lightMotionPage.close();
  }

  const loginPage = await browser.newPage({ viewport: { width: 1920, height: 1080 }, colorScheme: 'dark' });
  await loginPage.route('**/cgi-bin/api/status', route => route.fulfill({
    status: 401,
    contentType: 'application/json; charset=utf-8',
    body: JSON.stringify({ ok: false, needauth: true }),
  }));
  await loginPage.goto(`${base}/#/dashboard`);
  await loginPage.locator('.login-box').waitFor({ state: 'visible', timeout: 2000 });
  const loginFrame = await loginPage.evaluate(() => {
    const box = document.querySelector('.login-box').getBoundingClientRect();
    return { viewport: document.documentElement.clientWidth, x: box.x, width: box.width,
      center: box.x + box.width / 2, page: document.body.dataset.page };
  });
  assert.equal(loginFrame.page, 'login', 'an unauthorized status response renders the real login state');
  assert.ok(Math.abs(loginFrame.center - loginFrame.viewport / 2) < 1,
    `desktop login form is centered in the viewport (${JSON.stringify(loginFrame)})`);
  if (screenshotDir) {
    await loginPage.mouse.move(1919, 1079);
    await loginPage.screenshot({ path: path.join(screenshotDir, 'dark-1920-login.png') });
  }
  await loginPage.close();

  const fullHdShort = await browser.newPage({ viewport: { width: 1920, height: 480 } });
  await fullHdShort.goto(base + '/#/dashboard');
  await waitForRenderedRoute(fullHdShort, 'dashboard');
  await fullHdShort.waitForFunction(() => {
    const theme = document.querySelector('#brand-profile-theme');
    return theme && theme.sheet && theme.sheet.cssRules.length > 0;
  }, null, { timeout: 1500 });
  await fullHdShort.waitForFunction(() => Math.abs(document.querySelector('#nav').getBoundingClientRect().width - 261) < 1,
    null, { timeout: 1200 });
  assert.equal(await fullHdShort.locator('#menu-toggle').isVisible(), false,
    'a short Full HD browser window keeps the mobile menu trigger hidden');
  assert.ok(Math.abs(await fullHdShort.locator('#nav').evaluate(node => node.getBoundingClientRect().width) - 261) < 1,
    'a short Full HD browser window retains the desktop sidebar width');
  await fullHdShort.emulateMedia({ reducedMotion: 'reduce' });
  assert.ok(Number.parseFloat(await fullHdShort.locator('html').evaluate(node => getComputedStyle(node).transitionDuration)) <= 0.00001,
    'уменьшение движения почти мгновенно отключает переход единого состояния оболочки');
  await fullHdShort.close();

  const snapshotPage = await browser.newPage({ viewport: { width: 1392, height: 1104 } });
  const snapshotRequests = [];
  await snapshotPage.route('**/cgi-bin/api/product/update/**', async route => {
    snapshotRequests.push(route.request().url());
    await route.fulfill({ status: 599, contentType: 'application/json', body: '{}' });
  });
  await snapshotPage.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(snapshotPage, 'dashboard');
  await snapshotPage.waitForFunction(() => document.querySelector('#update-banner')?.innerText.includes('p-86.1'),
    null, { timeout: 2000 });
  const unifiedBanner = await snapshotPage.locator('#update-banner').innerText();
  assert.match(unifiedBanner, /z2k p-86\.1 актуален/,
    'a CI package still uses the upstream release version in the single banner');
  assert.doesNotMatch(unifiedBanner, /SNAPSHOT|[0-9a-f]{40}|production channel|v0\.1\.[0-9]/i,
    'the production update banner hides CI and product-channel details');
  assert.equal(await snapshotPage.locator('#product-update-card').count(), 0,
    'CI packages have no second production update card');
  assert.deepEqual(snapshotRequests, [],
    'the Dashboard update-check path never queries product release endpoints');
  await snapshotPage.close();

  // The optional identity module can be blocked while the package profile,
  // one-mark lockup, and route graph continue to work.
  const loaderBlocked = await browser.newPage({ viewport: { width: 1392, height: 1104 } });
  const loaderErrors = [];
  loaderBlocked.on('pageerror', error => loaderErrors.push(error.message));
  await loaderBlocked.route('**/js/core/identity.js*', route => route.abort('blockedbyclient'));
  await loaderBlocked.goto(base + '/#/dashboard');
  await waitForRenderedRoute(loaderBlocked, 'dashboard');
  await loaderBlocked.locator('#brand-profile-theme').waitFor({ state: 'attached', timeout: 1200 });
  assert.equal(await loaderBlocked.locator('#brand-composite-logo').isVisible(), true);
  assert.equal(await loaderBlocked.locator('#panel-brand .brand-wordmark').isVisible(), false);
  for (const route of primaryRoutes) {
    await loaderBlocked.evaluate(name => { location.hash = '#/' + name; }, route);
    await waitForRenderedRoute(loaderBlocked, route);
  }
  assert.deepEqual(loaderErrors, []);
  await loaderBlocked.close();

  // Simulate a filter blocking the optional loader and all package assets.
  // The common app still renders routes and never presents a legacy lockup.
  const blocked = await browser.newPage();
  const blockedErrors = [];
  const blockedResourceFailures = [];
  blocked.on('pageerror', error => blockedErrors.push(error.message));
  blocked.on('requestfailed', request => blockedResourceFailures.push({
    path: new URL(request.url()).pathname,
    error: request.failure()?.errorText || '',
  }));
  await blocked.route('**/js/core/identity.js*', route => route.abort('blockedbyclient'));
  await blocked.route('**/assets/openwrt/**', route => route.abort('blockedbyclient'));
  await blocked.goto(base + '/#/dashboard');
  await waitForRenderedRoute(blocked, 'dashboard');
  assert.equal(await blocked.title(), 'z2kOW · Дашборд');
  assert.equal(await blocked.locator('#panel-brand .brand-profile-logo').isVisible(), true);
  assert.equal(await blocked.locator('#panel-brand .brand-wordmark').innerText(), 'z2kOW');
  assert.equal(await blocked.locator('#brand-composite-logo').isVisible(), false);
  assert.doesNotMatch(await blocked.locator('#panel-brand').innerText(), /keenetic|antidpi/i);
  assert.ok(blockedResourceFailures.some(item => item.path.endsWith('/js/core/identity.js')
    && item.error.startsWith('net::ERR_BLOCKED_BY_CLIENT')), 'identity request must be blocked by the browser');
  for (const route of primaryRoutes) {
    await blocked.evaluate(name => { location.hash = '#/' + name; }, route);
    await waitForRenderedRoute(blocked, route);
  }
  assert.deepEqual(blockedErrors, []);
  await blocked.close();

  const themeBlocked = await browser.newPage();
  const themeErrors = [];
  themeBlocked.on('pageerror', error => themeErrors.push(error.message));
  await themeBlocked.addInitScript(() => localStorage.setItem('z2k-theme', 'dark'));
  await themeBlocked.route('**/assets/openwrt/theme.css', route => route.abort('blockedbyclient'));
  await themeBlocked.goto(base + '/#/dashboard');
  await waitForRenderedRoute(themeBlocked, 'dashboard');
  assert.equal(await themeBlocked.locator('#brand-composite-logo').isVisible(), true);
  assert.equal(await themeBlocked.locator('#brand-composite-logo').evaluate(node =>
    getComputedStyle(node.querySelector('#brand-logo-ink')).fill), 'rgb(230, 237, 243)',
  'logo has theme-variable fallback colors if profile CSS is blocked');
  for (const route of primaryRoutes) {
    await themeBlocked.evaluate(name => { location.hash = '#/' + name; }, route);
    await waitForRenderedRoute(themeBlocked, route);
  }
  assert.deepEqual(themeErrors, []);
  await themeBlocked.close();

  const themeSlow = await browser.newPage();
  let markThemeRequestStarted;
  const themeRequestStarted = new Promise(resolve => { markThemeRequestStarted = resolve; });
  let releaseThemeRequest;
  await themeSlow.route('**/assets/openwrt/theme.css', route => {
    markThemeRequestStarted();
    return new Promise(resolve => {
      releaseThemeRequest = async () => {
        await route.continue();
        resolve();
      };
    });
  });
  await themeSlow.goto(base + '/#/dashboard', { waitUntil: 'commit' });
  await themeRequestStarted;
  let routeRenderedBeforeTheme = false;
  try {
    await themeSlow.waitForFunction(() => document.querySelector('#app .page-title')?.textContent === 'Дашборд',
      null, { timeout: 1200 });
    routeRenderedBeforeTheme = true;
  } catch {}
  const beforeSlowTheme = await themeSlow.evaluate(() => ({
    ready: document.documentElement.classList.contains('brand-theme-ready'),
    navTransition: getComputedStyle(document.querySelector('#nav')).transitionProperty,
    boxes: ['#nav', '#app', '#panel-brand', '.topbar', '.theme-toggle'].map(selector => {
      const rect = document.querySelector(selector).getBoundingClientRect();
      return [rect.left, rect.top, rect.width, rect.height];
    }),
  }));
  assert.equal(beforeSlowTheme.ready, false, 'медленная опциональная тема ещё не загружена');
  assert.equal(beforeSlowTheme.navTransition, 'none',
    `задержанная тема не запускает отдельный переход положения меню (${JSON.stringify(beforeSlowTheme)})`);
  await releaseThemeRequest();
  assert.equal(routeRenderedBeforeTheme, true,
    'a slow optional brand theme never blocks the first route render');
  await waitForRenderedRoute(themeSlow, 'dashboard');
  await themeSlow.waitForFunction(() => document.documentElement.classList.contains('brand-theme-ready'));
  const afterSlowTheme = await themeSlow.evaluate(() => ['#nav', '#app', '#panel-brand', '.topbar', '.theme-toggle']
    .map(selector => {
      const rect = document.querySelector(selector).getBoundingClientRect();
      return [rect.left, rect.top, rect.width, rect.height];
    }));
  assert.ok(afterSlowTheme.every((box, index) => {
    const axes = index === 1 ? [0, 1, 2] : [0, 1, 2, 3];
    return axes.every(axis => Math.abs(box[axis] - beforeSlowTheme.boxes[index][axis]) <= 1);
  }),
  `опциональная тема не двигает оболочку после загрузки (${JSON.stringify({ before: beforeSlowTheme.boxes, after: afterSlowTheme })})`);
  await themeSlow.close();

  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, colorScheme: 'dark', isMobile: true, hasTouch: true });
  await mobile.addInitScript(() => localStorage.setItem('z2k-sidebar', 'collapsed'));
  await mobile.goto(base + '/#/dashboard');
  await waitForRenderedRoute(mobile, 'dashboard');
  assert.equal(await mobile.locator('#menu-toggle').isVisible(), true);
  assert.equal(await mobile.locator('#sidebar-collapse').isVisible(), false,
    'mobile keeps the drawer model and hides the desktop collapse control');
  const mobileTriggerBox = await mobile.locator('#menu-toggle').boundingBox();
  const mobileBrandBox = await mobile.locator('#panel-brand').boundingBox();
  const mobileThemeBox = await mobile.locator('.theme-toggle').boundingBox();
  assert.ok(mobileTriggerBox.x < mobileBrandBox.x, 'the mobile menu button sits to the left of the z2kOW mark');
  assert.ok(mobileThemeBox && mobileThemeBox.x >= 0 && mobileThemeBox.x + mobileThemeBox.width <= 390
    && mobileThemeBox.height >= 44,
  `the mobile theme actions stay visible on the right with touch-sized controls (${JSON.stringify(mobileThemeBox)})`);
  assert.equal(await mobile.locator('#header-nav, #route-recents').count(), 0,
    'one route menu remains: the existing navigation drawer');
  assert.ok(await mobile.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth),
    'compact layout must not create page-level horizontal overflow');
  await mobile.locator('#menu-toggle').click();
  assert.equal(await mobile.locator('#menu-toggle').getAttribute('aria-expanded'), 'true');
  assert.equal(await mobile.locator('#menu-shell').evaluate(node => node.classList.contains('mm-ocd--open')), true,
    'opening applies the observed MmenuLight shell state');
  assert.equal(await mobile.locator('body').evaluate(node => node.classList.contains('mm-ocd-opened')), true,
    'opening applies the observed body scroll-state class');
  assert.equal(await mobile.locator('#nav a[data-route="dashboard"] .nav-label').innerText(), 'Дашборд',
    'a persisted desktop collapse preference does not hide mobile drawer labels');
  const drawerMotion = await mobile.evaluate(async () => {
    const { motion } = await import('/js/motion.js');
    return {
    duration: getComputedStyle(document.querySelector('#menu-shell .mm-ocd__content')).transitionDuration,
    easing: getComputedStyle(document.querySelector('#menu-shell .mm-ocd__content')).transitionTimingFunction,
    width: document.querySelector('#menu-shell .mm-ocd__content').getBoundingClientRect().width,
    shellWidth: document.querySelector('#menu-shell').getBoundingClientRect().width,
    shellDuration: getComputedStyle(document.querySelector('#menu-shell')).transitionDuration,
    shellDelay: getComputedStyle(document.querySelector('#menu-shell')).transitionDelay,
    motionDuration: motion.timing.duration.shell,
    };
  });
  assert.equal(drawerMotion.duration, '0s', 'анимацией бокового меню не управляет CSS');
  assert.equal(drawerMotion.shellDuration, '0s');
  assert.equal(drawerMotion.motionDuration, 0.3, 'GSAP использует общую длительность каркаса 300 мс');
  assert.ok(Math.abs(drawerMotion.width / drawerMotion.shellWidth - 0.8) < 0.005,
    `the drawer is 80% of the browser's content viewport (${drawerMotion.width}/${drawerMotion.shellWidth}px)`);
  assert.equal(drawerMotion.shellDelay, '0s');
  await waitForDrawerSettled(mobile, true);
  const openDrawerBox = await mobile.locator('#nav').boundingBox();
  assert.ok(Math.abs(openDrawerBox.x) < 1, 'the mobile drawer opens from the left edge');
  if (screenshotDir) await mobile.screenshot({ path: path.join(screenshotDir, 'dark-390-drawer.png'), fullPage: true });
  await mobile.waitForFunction(() => document.activeElement.closest('#nav') !== null);
  const touchTrigger = await mobile.locator('#menu-toggle').evaluate(node => ({
    height: node.getBoundingClientRect().height, minHeight: getComputedStyle(node).minHeight,
    coarse: matchMedia('(pointer: coarse)').matches, viewport: [innerWidth, innerHeight],
  }));
  assert.ok(touchTrigger.height >= 44, `narrow-screen menu trigger hit area is at least 44 px: ${JSON.stringify(touchTrigger)}`);
  assert.ok(await mobile.locator('#nav a[data-route="dashboard"]').evaluate(node => node.getBoundingClientRect().height >= 44),
    'coarse-pointer navigation links meet the 44 px touch target');
  await mobile.keyboard.press('Escape');
  assert.equal(await mobile.locator('#menu-toggle').getAttribute('aria-expanded'), 'false');
  assert.equal(await mobile.locator('body').evaluate(node => node.classList.contains('mm-ocd-opened')), false);
  await waitForDrawerSettled(mobile, false);
  assert.equal(await mobile.locator('#menu-shell').evaluate(node => node.classList.contains('mm-ocd--open')), false);
  assert.equal(await mobile.locator('#nav').evaluate(node => node.classList.contains('menu-open')), false);
  await mobile.waitForFunction(() => document.querySelector('#menu-backdrop').hidden, null, { timeout: 1000 });
  await mobile.waitForFunction(() => document.activeElement.id === 'menu-toggle', null, { timeout: 1000 });
  assert.equal(await mobile.evaluate(() => document.activeElement.id), 'menu-toggle', 'Escape restores focus to the drawer trigger');
  await mobile.evaluate(() => document.activeElement.blur());
  for (const route of routes) {
    await mobile.evaluate(name => { location.hash = '#/' + name; }, route);
    await waitForRenderedRoute(mobile, route);
    assert.equal(await mobile.locator('#app [data-ui-fatal]').count(), 0, `mobile: ${route}`);
    assert.ok(await mobile.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth),
      `390px: ${route} has no page horizontal overflow`);
    if (route === 'strategies') await assertActiveStrategyTabVisible(mobile, '390px dark');
    if (route === 'diag') await assertDiagDynamicStates(mobile, 'dark', '390');
    if (route === 'extra-domains') await assertMobileSelectedDomainEditor(mobile, 'dark');
    if (route === 'state') {
      await assertStateGroupDisclosure(mobile, 'dark/390');
      const stateLayout = await mobile.locator('.state-table').evaluate(table => {
        const header = table.querySelector('thead');
        const row = table.querySelector('tbody tr');
        const cell = row?.querySelector('td');
        const scroller = table.closest('.table-scroll');
        return {
          table: getComputedStyle(table).display,
          header: getComputedStyle(header).display,
          row: getComputedStyle(row).display,
          cell: getComputedStyle(cell).display,
          scrollClientWidth: scroller.clientWidth,
          scrollWidth: scroller.scrollWidth,
          pageClientWidth: document.documentElement.clientWidth,
          pageScrollWidth: document.documentElement.scrollWidth,
        };
      });
      assert.deepEqual(
        [stateLayout.table, stateLayout.header, stateLayout.row, stateLayout.cell],
        ['table', 'table-header-group', 'table-row', 'table-cell'],
        `390px ${route}: dense state data retains semantic table layout (${JSON.stringify(stateLayout)})`);
      assert.ok(stateLayout.scrollWidth > stateLayout.scrollClientWidth,
        `390px ${route}: columns remain reachable in the local horizontal scroller (${JSON.stringify(stateLayout)})`);
      assert.ok(stateLayout.pageScrollWidth <= stateLayout.pageClientWidth,
        `390px ${route}: table scrolling does not create document overflow (${JSON.stringify(stateLayout)})`);
      const touchTargets = await mobile.locator('.state-table tbody.sg:not(.sg-closed) tr.sg-member:visible').first().evaluate(row => {
        const measure = selector => {
          const rect = row.querySelector(selector).getBoundingClientRect();
          return { width: rect.width, height: rect.height };
        };
        return { rowHeight: row.getBoundingClientRect().height,
          delete: measure('.state-del'), freeze: measure('.state-freeze'),
          selector: measure('.chosen-single') };
      });
      assert.ok(touchTargets.delete.width >= 44 && touchTargets.delete.height >= 44
        && touchTargets.freeze.width >= 44 && touchTargets.freeze.height >= 44,
      `state table actions keep touch hit areas at least 44×44px (${JSON.stringify(touchTargets)})`);
      assert.ok(touchTargets.selector.height >= 44 && touchTargets.rowHeight === 66,
        `coarse-pointer selector and rows share touch geometry (${JSON.stringify(touchTargets)})`);
    }
    if (screenshotDir && ['dashboard', 'strategies', 'warp', 'whitelist', 'exclude',
      'extra-domains', 'autohostlist', 'diag'].includes(route)) {
      await mobile.evaluate(() => window.scrollTo(0, 0));
      await mobile.mouse.move(389, 843);
      await waitForNavSettled(mobile);
      await mobile.screenshot({ path: path.join(screenshotDir, `dark-390-${route}.png`), fullPage: true });
    }
    if (screenshotDir && route === 'state') {
      await mobile.mouse.move(389, 843);
      await waitForNavSettled(mobile);
      await mobile.screenshot({ path: path.join(screenshotDir, 'dark-390-state.png'), fullPage: true });
    }
  }
  await mobile.setViewportSize({ width: 320, height: 844 });
  await mobile.evaluate(() => { location.hash = '#/strategies'; });
  await waitForRenderedRoute(mobile, 'strategies');
  await assertStrategyTabsAllowManualScroll(mobile, '320px dark');
  for (const width of [320, 360, 375, 388, 390]) {
    await mobile.setViewportSize({ width, height: 844 });
    const headerFrame = await mobile.evaluate(() => {
      const rect = selector => document.querySelector(selector).getBoundingClientRect();
      const menu = rect('#menu-toggle');
      const brand = rect('#panel-brand');
      const theme = rect('.theme-toggle');
      return { viewport: document.documentElement.clientWidth, scrollWidth: document.documentElement.scrollWidth,
        menuRight: menu.right, brandLeft: brand.left, brandRight: brand.right, themeLeft: theme.left };
    });
    assert.ok(headerFrame.menuRight <= headerFrame.brandLeft + 0.5
      && headerFrame.brandRight <= headerFrame.themeLeft + 0.5,
    `mobile header controls do not overlap at ${width}px (${JSON.stringify(headerFrame)})`);
    assert.ok(headerFrame.scrollWidth <= headerFrame.viewport,
      `mobile header stays within the viewport at ${width}px (${JSON.stringify(headerFrame)})`);
  }
  await mobile.setViewportSize({ width: 390, height: 844 });
  // Exercise and capture the real mobile light-theme control while the drawer
  // exposes its footer switcher, then check every route in that appearance.
  await mobile.locator('#menu-toggle').click();
  await mobile.locator('[data-theme-btn="light"]').click();
  assert.equal(await mobile.locator('[data-theme-btn="light"]').getAttribute('aria-pressed'), 'true');
  assert.equal(await mobile.locator('#menu-toggle').getAttribute('aria-expanded'), 'true');
  await waitForDrawerSettled(mobile, true);
  if (screenshotDir) await mobile.screenshot({ path: path.join(screenshotDir, 'light-390-drawer.png'), fullPage: true });
  await mobile.keyboard.press('Escape');
  assert.equal(await mobile.locator('#menu-toggle').getAttribute('aria-expanded'), 'false');
  await waitForDrawerSettled(mobile, false);
  await mobile.evaluate(() => document.activeElement.blur());
  for (const route of routes) {
    await mobile.evaluate(name => { location.hash = '#/' + name; }, route);
    await waitForRenderedRoute(mobile, route);
    assert.equal(await mobile.locator('#app [data-ui-fatal]').count(), 0, `mobile light: ${route}`);
    assert.ok(await mobile.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth),
      `390px light: ${route} has no page horizontal overflow`);
    if (route === 'strategies') await assertActiveStrategyTabVisible(mobile, '390px light');
    if (route === 'diag') await assertDiagDynamicStates(mobile, 'light', '390');
    if (route === 'extra-domains') await assertMobileSelectedDomainEditor(mobile, 'light');
    if (route === 'state') {
      await assertStateGroupDisclosure(mobile, 'light/390');
      const stateLayout = await mobile.locator('.state-table').evaluate(table => {
        const header = table.querySelector('thead');
        const row = table.querySelector('tbody tr');
        const cell = row?.querySelector('td');
        const scroller = table.closest('.table-scroll');
        return {
          table: getComputedStyle(table).display,
          header: getComputedStyle(header).display,
          row: getComputedStyle(row).display,
          cell: getComputedStyle(cell).display,
          scrollClientWidth: scroller.clientWidth,
          scrollWidth: scroller.scrollWidth,
          pageClientWidth: document.documentElement.clientWidth,
          pageScrollWidth: document.documentElement.scrollWidth,
        };
      });
      assert.deepEqual(
        [stateLayout.table, stateLayout.header, stateLayout.row, stateLayout.cell],
        ['table', 'table-header-group', 'table-row', 'table-cell'],
        `390px light state: dense state data retains semantic table layout (${JSON.stringify(stateLayout)})`);
      assert.ok(stateLayout.scrollWidth > stateLayout.scrollClientWidth,
        `390px light state: columns remain reachable in the local horizontal scroller (${JSON.stringify(stateLayout)})`);
      assert.ok(stateLayout.pageScrollWidth <= stateLayout.pageClientWidth,
        `390px light state: table scrolling does not create document overflow (${JSON.stringify(stateLayout)})`);
    }
    if (screenshotDir && ['dashboard', 'strategies', 'warp', 'state', 'whitelist', 'exclude',
      'extra-domains', 'autohostlist', 'diag'].includes(route)) {
      await mobile.evaluate(() => window.scrollTo(0, 0));
      await mobile.mouse.move(389, 843);
      await waitForNavSettled(mobile);
      await mobile.screenshot({ path: path.join(screenshotDir, `light-390-${route}.png`), fullPage: true });
    }
  }
  await mobile.emulateMedia({ reducedMotion: 'reduce' });
  assert.equal(await mobile.locator('#menu-shell .mm-ocd__content').evaluate(node => getComputedStyle(node).transitionDuration), '0s',
    'reduced motion disables drawer transitions');
  await mobile.close();

  const coarseTablet = await browser.newPage({ viewport: { width: 1024, height: 900 }, isMobile: true, hasTouch: true });
  await coarseTablet.goto(base + '/#/dashboard');
  await waitForRenderedRoute(coarseTablet, 'dashboard');
  const coarseTabletTargets = await coarseTablet.evaluate(() => ({
    coarse: matchMedia('(pointer: coarse)').matches,
    collapse: document.querySelector('#sidebar-collapse').getBoundingClientRect().height,
    navItem: document.querySelector('#nav a[data-route="dashboard"]').getBoundingClientRect().height,
  }));
  assert.equal(coarseTabletTargets.coarse, true,
    `touch tablet emulation uses a coarse pointer (${JSON.stringify(coarseTabletTargets)})`);
  assert.ok(coarseTabletTargets.collapse >= 44 && coarseTabletTargets.navItem >= 44,
    `tablet collapse and navigation keep 44 px hit areas (${JSON.stringify(coarseTabletTargets)})`);
  await coarseTablet.close();

  // Halving the CSS viewport models a 200% browser zoom on a 1392 px display.
  const zoomed = await browser.newPage({ viewport: { width: 696, height: 552 }, deviceScaleFactor: 2, colorScheme: 'dark' });
  await zoomed.goto(base + '/#/dashboard');
  await waitForRenderedRoute(zoomed, 'dashboard');
  assert.ok(await zoomed.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth),
    '200% zoom equivalent must reflow without page-level horizontal overflow');
  assert.equal(await zoomed.locator('#menu-toggle').isVisible(), true);
  assert.ok((await zoomed.locator('#app').innerText()).trim().length > 0,
    'primary content remains available at the 200% zoom equivalent');
  await zoomed.close();

  const forcedColors = await browser.newPage({ viewport: { width: 1392, height: 1104 } });
  const forcedColorErrors = [];
  forcedColors.on('pageerror', error => forcedColorErrors.push(error.message));
  await forcedColors.emulateMedia({ forcedColors: 'active' });
  await forcedColors.goto(base + '/#/dashboard');
  await waitForRenderedRoute(forcedColors, 'dashboard');
  await forcedColors.keyboard.press('Tab');
  const forcedFocus = await forcedColors.evaluate(() => ({
    width: getComputedStyle(document.activeElement).outlineWidth,
    style: getComputedStyle(document.activeElement).outlineStyle,
  }));
  assert.deepEqual(forcedFocus, { width: '2px', style: 'solid' }, 'forced-colors keeps keyboard focus visible');
  assert.deepEqual(forcedColorErrors, []);
  await forcedColors.close();

  moveOnReinstall = false;
  reinstallFixtureActive = true;
  const reinstallRacePage = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  reinstallRacePage.on('pageerror', error => allPageErrors.push(error.message));
  await reinstallRacePage.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(reinstallRacePage, 'dashboard');
  await reinstallRacePage.locator('#upd-reinstall').waitFor({ state: 'visible' });
  const reinstallCallsBefore = apiRequests.filter(request => request.endpoint === 'update/reinstall').length;
  moveOnReinstall = true;
  await reinstallRacePage.locator('#upd-reinstall').click();
  const reinstallDialog = reinstallRacePage.getByRole('dialog');
  await reinstallDialog.waitFor({ state: 'visible' });
  assert.match(await reinstallDialog.innerText(), /Переустановить p-86\.13\?/,
    'the confirmation names exactly the installed release');
  assert.equal(await reinstallDialog.locator('#confirm-ok').getAttribute('class'), 'btn btn-primary');
  assert.equal(await reinstallDialog.locator('#confirm-cancel').getAttribute('class'), 'btn');
  await reinstallRacePage.keyboard.press('Escape');
  assert.equal(apiRequests.filter(request => request.endpoint === 'update/reinstall').length, reinstallCallsBefore,
    'Escape cancels without calling the backend');
  await reinstallDialog.waitFor({ state: 'detached' });
  await reinstallRacePage.locator('#upd-reinstall').click();
  await reinstallRacePage.getByRole('dialog').getByRole('button', { name: 'Переустановить', exact: true }).click();
  await reinstallRacePage.getByRole('button', { name: 'Обновить до p-86.14' }).waitFor({ state: 'visible' });
  assert.equal(apiRequests.filter(request => request.endpoint === 'update/reinstall').length, reinstallCallsBefore + 1,
    'the accepted action reaches the reinstall preflight exactly once');
  assert.equal(apiRequests.filter(request => request.endpoint === 'update/apply').length, 0,
    'a manifest race never triggers an update to the newer release');
  assert.equal(await reinstallRacePage.locator('#upd-apply').innerText(), 'Обновить до p-86.14');
  await reinstallRacePage.close();
  reinstallFixtureActive = false;

  const makeTikTokPage = async (initialEnabled, tiktokStatus, { width = 390, height = 844, isMobile = true } = {}) => {
    const page = await browser.newPage({ viewport: { width, height }, isMobile, hasTouch: isMobile, colorScheme: 'dark' });
    await page.addInitScript(() => localStorage.setItem('z2k-theme', 'dark'));
    page.on('pageerror', error => allPageErrors.push(error.message));
    let enabled = initialEnabled;
    let currentStatus = tiktokStatus;
    let jobNumber = 0;
    page.route('**/cgi-bin/api/status', route => {
      const fixture = structuredClone(statusFixture);
      fixture.toggles.tiktok_feed = enabled ? '1' : '0';
      fixture.server_now_epoch = Math.floor(Date.now() / 1000);
      if (enabled) fixture.tiktok_feed_status = currentStatus || {
        state: 'healthy', candidate_verified: '1', dns_override_applied: '1',
        selected_ip: '203.0.113.9', latency_ms: '84',
        last_verified_epoch: String(Math.floor(Date.now() / 1000)), reason: 'healthy',
      };
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(fixture) });
    });
    page.route('**/cgi-bin/api/toggle/tiktok-feed', async route => {
      enabled = route.request().postDataJSON().value === '1';
      jobNumber += 1;
      return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, job: `tiktok-status-fixture-${jobNumber}` }) });
    });
    page.route('**/cgi-bin/api/job**', route => route.fulfill({
      status: 200, contentType: 'application/json', body: JSON.stringify({ done: true, exit: 0, status: 'done', log: 'ok' }),
    }));
    await page.goto(`${base}/#/tiktok`);
    await waitForRenderedRoute(page, 'tiktok');
    assert.equal(await page.locator('a[data-route="tiktok"]').getAttribute('class'), 'active');
    return { page, get enabled() { return enabled; }, setStatus(status) { currentStatus = status; } };
  };

  const offCard = await makeTikTokPage(false, null);
  assert.equal(await offCard.page.locator('#tiktok-feed-status-card').isVisible(), false,
    'the TikTok status card stays hidden while its persistent toggle is off');
  await offCard.page.locator('#tiktok-toggle').check({ force: true });
  await offCard.page.locator('#tiktok-feed-status-card').waitFor({ state: 'visible', timeout: 5000 });
  assert.match(await offCard.page.locator('#tiktok-feed-status-card').innerText(), /● CDN доступен/,
    'enabling TikTok shows the verified CDN transport status in the separate card');
  assert.match(await offCard.page.locator('#tiktok-feed-status-card').innerText(), /Передача видео и работа ленты не проверены/,
    'the status does not claim that CDN transport proves video delivery or feed operation');
  await offCard.page.waitForFunction(() => document.querySelector('#tiktok-toggle')?.checked === true);
  assert.equal(offCard.enabled, true);
  await offCard.page.getByRole('button', { name: 'Готово' }).click();
  await offCard.page.locator('.modal-backdrop').waitFor({ state: 'detached' });
  const beforeDisableUrl = offCard.page.url();
  await offCard.page.locator('#tiktok-toggle').uncheck({ force: true });
  await offCard.page.locator('#tiktok-feed-status-card').waitFor({ state: 'hidden', timeout: 5000 });
  assert.equal(offCard.page.url(), beforeDisableUrl, 'toggle off hides the card without navigating or reloading');
  await offCard.page.close();

  const healthy = await makeTikTokPage(true, {
    state: 'healthy', candidate_verified: '1', dns_override_applied: '1',
    selected_ip: '203.0.113.9', latency_ms: '131', last_verified_epoch: String(Math.floor(Date.now() / 1000) - 70),
    mode: 'auto', selected_at_epoch: String(Math.floor(Date.now() / 1000) - 48),
    failure_count: '0', selected_source_domain: 'www.tiktokcdn.com', selected_mode: 'verified',
    selected_provenance: 'resolver+tls', selected_cname: 'edge.example.net', host: 'v77.tiktokcdn.com',
    connect_latency_ms: '9', tls_latency_ms: '117', http_status: '400', x77_pop: 'CLA', x77_cache: 'MISS', server: 'RETN',
    dns_observed: '4', curated_observed: '3', stability_probe_count: '2', health: 'healthy',
    last_failover_epoch: String(Math.floor(Date.now() / 1000) - 3600), last_failover_from: '203.0.113.8',
    last_failover_to: '203.0.113.9', last_failover_reason: 'consecutive-probe-failures', reason: 'healthy',
  });
  const healthyCard = healthy.page.locator('#tiktok-feed-status-card');
  assert.equal(await healthyCard.isVisible(), true);
  assert.equal(await healthy.page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true,
    'TikTok status cards fit the 390 px layout without horizontal overflow');
  assert.match(await healthyCard.innerText(), /203\.0\.113\.9/);
  assert.match(await healthyCard.innerText(), /131 мс/);
  assert.doesNotMatch(await healthyCard.innerText(), /131 мс\s+131/,
    'latency is rendered once instead of repeating the raw number beside the formatted value');
  const healthySummary = await healthyCard.locator('.tiktok-selection-summary').innerText();
  assert.match(healthySummary, /Текущий CDN выбран автоматически/i);
  assert.doesNotMatch(healthySummary, /CDN переключён|203\.0\.113\.8 → 203\.0\.113\.9/);
  if (screenshotDir) {
    await screenshotComponent(healthy.page, healthyCard, path.join(screenshotDir, 'dark-390-tiktok-auto-healthy.png'));
  }
  assert.doesNotMatch(await healthyCard.innerText(), /raw: consecutive-probe-failures/);
  await healthyCard.locator('#tiktok-feed-technical > summary').click();
  assert.equal(await healthyCard.locator('#tiktok-feed-technical').evaluate(node => node.open), true,
    'technical diagnostics disclosure opens');
  assert.match(await healthyCard.innerText(), /www\.tiktokcdn\.com/);
  assert.match(await healthyCard.innerText(), /resolver\+tls/);
  assert.match(await healthyCard.innerText(), /raw: consecutive-probe-failures/);
  assert.match(await healthyCard.innerText(), /Соединение[\s\S]*Выбранный узел[\s\S]*Проверка[\s\S]*Последнее автоматическое переключение/i);
  assert.match(await healthyCard.innerText(), /203\.0\.113\.8 → 203\.0\.113\.9/);
  assert.match(await healthyCard.innerText(), /HTTP-ответ[\s\S]*400/);
  assert.doesNotMatch(await healthyCard.innerText(), /131 мс\s+131/);
  assert.doesNotMatch(await healthyCard.innerText(), /undefined|null|0 мс/);

  await healthy.page.goto(`${base}/#/toggles`);
  await waitForRenderedRoute(healthy.page, 'toggles');
  // FLOWOFFLOAD stays on Modes; reload there while a trial is pending and
  // verify its existing browser-originated sample lifecycle.
  let resumedSample = null;
  let showLastSuccessFallback = false;
  let failBenchmarkPings = false;
  let latestBenchmarkStatus = null;
  const fixtureResult = {
    schema: 2, runtime_evidence_version: 1,
    status: 'completed', timestamp: '2026-10-07T10:00:00Z', recommendation: 'software',
    provider: 'yandex-internetometer', server: 'edge-01.cdn.yandex.net',
    health: {
      none: { accepted: true, reason: 'confirmed' },
      software: { accepted: true, reason: 'confirmed' },
      hardware: { accepted: false, reason: 'hardware-not-observed' },
    },
    validity: { complete: true, unstable: false, accepted: true, warnings: ['Внешний тест зависит от выбранного CDN'] },
    comparisons: {
      software_vs_none: { download_pct: 100, upload_pct: -78, cpu_pct: 17, cpu_peak_pct: 10, idle_ms_delta: 0.05,
        download_loaded_ms_delta: 1.1, upload_loaded_ms_delta: -0.05 },
      hardware_vs_software: { download_pct: null, upload_pct: null, cpu_pct: null },
    },
    system: { router_model: 'Fixture Router', openwrt_version: 'OpenWrt 24.10', z2kow_version: 'p-86.14', wan_interface: 'wan0' },
    modes: Object.fromEntries(['none', 'software', 'hardware'].map(mode => [mode, {
      available: mode !== 'hardware', download_mbps: mode === 'software' ? 120 : 60,
      upload_mbps: 30, cpu_avg: 25, cpu_peak: 41, idle_ms: 9,
      download_loaded_ms: 18, upload_loaded_ms: 21, jitter_ms: 2, loss_pct: 0,
      offload_observed: mode === 'software', run_range_pct: { download: 3.3, upload: 3.3 },
      run_summary: {
        download_mbps: { median: 60, min: 59, max: 61, range_pct: 3.3, outliers: 0 },
        upload_mbps: { median: 30, min: 29, max: 31, range_pct: 3.3, outliers: 0 },
      },
      runs: mode === 'hardware' ? [] : [
        { download_mbps: 59, upload_mbps: 29, cpu_avg: 24.8, cpu_peak: 40.1, idle_ms: 9.05,
          download_loaded_ms: 17, upload_loaded_ms: 20, jitter_ms: 1.2, loss_pct: 0, duration_s: 4.2,
          actual: 'not-observed', health_accepted: true, server: 'very-long-cdn-edge-07.eu-west.example-cdn.net',
          health_before: { expected_health_reason: mode === 'none' ? 'disabled' : 'confirmed', configured_mode: mode,
            flowtable_state: mode === 'none' ? 'absent' : 'present', flowtable_flags: mode === 'none' ? 'none' : 'software',
            flowtable_devices: 'br-lan, wan', actual_dataplane: mode === 'none' ? 'not-applicable' : 'software',
            offloaded_connections: mode === 'none' ? 0 : 3,
            software_offloaded_connections: mode === 'software' ? 3 : 0,
            hw_offloaded_connections: 0, hardware_capability: 'available',
            hardware_requested: 0, hardware_observed: 'not-applicable', hardware_state: 'not-applicable',
            software_capability: 'available', global_fw4_offload: 'disabled', global_fw4_flowtables: 0,
            flow_offload_chain: mode === 'none' ? 'absent' : 'present',
            flow_offload_zapret_chain: mode === 'none' ? 'absent' : 'present',
            flow_offload_always_chain: mode === 'none' ? 'absent' : 'present', flow_add_rules: mode === 'none' ? 0 : 1,
            packet_visibility: 'active', nfqueue_rules: 8, nfqueue_packets: 2450, exemption_rules: 4,
            selective_state: 'complete', circular_state: 'active', owner_state: 'zapret2', owner_conflict: 'none',
            runtime_health: mode === 'none' ? 'disabled' : 'healthy', runtime_health_reason: mode === 'none' ? 'disabled' : 'confirmed' },
          health_after: { expected_health_reason: mode === 'none' ? 'disabled' : 'confirmed', configured_mode: mode,
            flowtable_state: mode === 'none' ? 'absent' : 'present', flowtable_flags: mode === 'none' ? 'none' : 'software',
            flowtable_devices: 'br-lan, wan', actual_dataplane: mode === 'none' ? 'not-applicable' : 'software',
            offloaded_connections: mode === 'none' ? 0 : 3,
            software_offloaded_connections: mode === 'software' ? 3 : 0,
            hw_offloaded_connections: 0, hardware_capability: 'available',
            hardware_requested: 0, hardware_observed: 'not-applicable', hardware_state: 'not-applicable',
            software_capability: 'available', global_fw4_offload: 'disabled', global_fw4_flowtables: 0,
            flow_offload_chain: mode === 'none' ? 'absent' : 'present',
            flow_offload_zapret_chain: mode === 'none' ? 'absent' : 'present',
            flow_offload_always_chain: mode === 'none' ? 'absent' : 'present', flow_add_rules: mode === 'none' ? 0 : 1,
            packet_visibility: 'active', nfqueue_rules: 8, nfqueue_packets: 2470, exemption_rules: 4,
            selective_state: 'complete', circular_state: 'active', owner_state: 'zapret2', owner_conflict: 'none',
            runtime_health: mode === 'none' ? 'disabled' : 'healthy', runtime_health_reason: mode === 'none' ? 'disabled' : 'confirmed' } },
        { download_mbps: 60, upload_mbps: 30, cpu_avg: 25, cpu_peak: 41, idle_ms: 9, download_loaded_ms: 18,
          upload_loaded_ms: 21, jitter_ms: 1.5, loss_pct: 0, duration_s: 4.3, actual: 'not-observed', health_accepted: true,
          server: 'edge-01.cdn.yandex.net', health_before: { flowtable_state: 'present' }, health_after: { flowtable_state: 'present' } },
        { download_mbps: 61, upload_mbps: 31, cpu_avg: 25.2, cpu_peak: 41.4, idle_ms: 9.1,
          download_loaded_ms: 19, upload_loaded_ms: 22, jitter_ms: 1.1, loss_pct: 0, duration_s: 4.4,
          actual: 'not-observed', health_accepted: true, server: 'edge-01.cdn.yandex.net',
          health_before: { flowtable_state: 'present' }, health_after: { flowtable_state: 'present' } },
      ],
    }])),
  };
  const historicalFixtureResult = {
    ...fixtureResult, schema: 1, runtime_evidence_version: undefined, runtime_evidence_state: 'historical',
  };
  await healthy.page.route(/\/cgi-bin\/api\/offload\/benchmark\?view=status$/, route => {
    latestBenchmarkStatus = showLastSuccessFallback
      ? { ok: true, active: false, status: 'failed', result: { ...fixtureResult, status: 'failed', validity: { ...fixtureResult.validity, complete: false, accepted: false }, timestamp: '2026-10-07T11:00:00Z', recommendation: null, message: 'endpoint failed' }, last_success_timestamp: '', last_success_state: 'historical' }
      : resumedSample
        ? { ok: true, active: false, status: 'completed', result: fixtureResult }
        : { ok: true, active: true, session: 'session-fixture', token: 'token-fixture', status: 'awaiting_sample',
            mode: 'software', trial: 2, nonce: 'nonce-after-reload', provider: 'yandex-internetometer', result: null,
            probe_config: {
              provider: 'yandex-internetometer', server: 'edge-01.cdn.yandex.net', mid: 'fixturemid123456789',
              latency_url: 'https://edge-01.cdn.yandex.net/cdnrph/ping?mid=fixturemid123456789&lid=123',
              download_url: 'https://edge-01.cdn.yandex.net/cdnrph/probes/50mb?lid=123&mid=fixturemid123456789',
              upload_url: 'https://edge-01.cdn.yandex.net/cdnrph/upload?mid=fixturemid123456789&size=30720',
            } };
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(latestBenchmarkStatus) });
  });
  await healthy.page.route(/\/cgi-bin\/api\/offload\/benchmark\?view=last-success$/, route => route.fulfill({
    status: 200, contentType: 'application/json', body: JSON.stringify(historicalFixtureResult),
  }));
  await healthy.page.route('**/cgi-bin/api/offload/benchmark', async route => {
    if (route.request().method() !== 'POST') return route.fallback();
    resumedSample = route.request().postDataJSON();
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true }) });
  });
  const benchmarkTransferRequests = [];
  await healthy.page.route('https://**.cdn.yandex.net/**', route => {
    const request = route.request();
    if (request.method() === 'OPTIONS') {
      return route.fulfill({
        status: 204,
        headers: {
          'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET, POST, OPTIONS',
          'access-control-allow-headers': 'content-type',
        },
      });
    }
    const url = new URL(request.url());
    const direction = url.pathname.endsWith('/ping') ? 'latency' : url.pathname.endsWith('/50mb') ? 'download' : 'upload';
    const bytes = direction === 'download' ? 50 * 1024 * 1024 : direction === 'upload' ? request.postDataBuffer()?.byteLength || 0 : 0;
    benchmarkTransferRequests.push({ direction, bytes });
    if (failBenchmarkPings && direction === 'latency') {
      return route.fulfill({
        status: 503,
        headers: { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET, POST, OPTIONS' },
        body: 'temporary latency probe failure',
      });
    }
    return route.fulfill({
      status: 200,
      headers: { 'access-control-allow-origin': '*', 'access-control-allow-methods': 'GET, POST, OPTIONS', 'content-type': direction === 'upload' ? 'text/plain' : 'application/octet-stream' },
      body: direction === 'download' ? Buffer.alloc(bytes) : direction === 'upload' ? 'ok' : '',
    });
  });
  failBenchmarkPings = true;
  await healthy.page.reload();
  await healthy.page.locator('#flowoffload-benchmark-result').waitFor({ state: 'visible', timeout: 10000 });
  assert.equal(resumedSample.session, 'session-fixture');
  assert.equal(resumedSample.nonce, 'nonce-after-reload');
  assert.ok(resumedSample.download_mbps > 0 && resumedSample.upload_mbps > 0,
    'reload resumes the pending browser test and submits measured transfer rates');
  assert.deepEqual(
    [resumedSample.idle_ms, resumedSample.download_loaded_ms, resumedSample.upload_loaded_ms, resumedSample.jitter_ms],
    ['null', 'null', 'null', 'null'],
    'missing CDN ping probes remain null while successful throughput samples are submitted',
  );
  assert.equal(resumedSample.loss_pct, '100', 'failed latency probes are retained as measured loss');
  assert.deepEqual(benchmarkTransferRequests.filter(item => item.direction === 'download').map(item => item.bytes), [50 * 1024 * 1024],
    'each benchmark round downloads the full 50 MiB Yandex CDN probe from the browser');
  const uploadBytes = benchmarkTransferRequests.find(item => item.direction === 'upload')?.bytes || 0;
  assert.ok(uploadBytes >= 8 * 1024 * 1024 && uploadBytes < 8 * 1024 * 1024 + 1024,
    `each benchmark round uploads an 8 MiB Yandex probe from the browser (body ${uploadBytes} bytes)`);
  assert.ok(benchmarkTransferRequests.filter(item => item.direction === 'latency').length >= 4,
    'latency probes use Yandex endpoints');
  assert.ok(Number.isFinite(Number(resumedSample.duration_s)));
  assert.match(await healthy.page.locator('#flowoffload-benchmark-result').innerText(), /Рекомендуется: Программное/);
  assert.match(await healthy.page.locator('#flowoffload-benchmark-result').innerText(), /Программное vs Без ускорения/,
    'accepted benchmark shows its percentage comparison');
  await healthy.page.locator('#flowoffload-benchmark-result > details > summary').click();
  const benchmarkDetails = await healthy.page.locator('#flowoffload-benchmark-result').innerText();
  assert.match(benchmarkDetails, /Run 1\t59 Mbps\t29 Mbps[\s\S]*Run 2\t60 Mbps\t30 Mbps[\s\S]*Run 3\t61 Mbps\t31 Mbps/,
    'benchmark diagnostics show every raw upload trial');
  assert.match(benchmarkDetails, /Run 1[\s\S]*17 ms\t20 ms[\s\S]*Run 2[\s\S]*18 ms\t21 ms[\s\S]*Run 3[\s\S]*19 ms\t22 ms/,
    'benchmark diagnostics show every loaded-latency trial');
  assert.match(benchmarkDetails, /↓ Mbps\t60 Mbps\t59 Mbps\t61 Mbps\t3,3%[\s\S]*↑ Mbps\t30 Mbps\t29 Mbps\t31 Mbps\t3,3%/,
    'benchmark diagnostics show the measured download and upload ranges');
  assert.match(benchmarkDetails, /Провайдер: Яндекс Интернетометр · CDN: edge-01\.cdn\.yandex\.net/,
    'benchmark diagnostics identify the selected Yandex provider and actual CDN host');
  const runTables = healthy.page.locator('#flowoffload-benchmark-result .flow-benchmark-run-table');
  assert.equal(await runTables.count(), 3, 'benchmark details contain one measurement table per mode');
  for (const runTable of await runTables.all()) {
    const runHeaders = await runTable.locator('thead th').allInnerTexts();
    assert.deepEqual(runHeaders, ['Прогон', '↓ Mbps', '↑ Mbps', 'CPU avg', 'CPU peak', 'Ping idle', 'Ping ↓', 'Ping ↑', 'Health'],
      'each mode uses the compact measurement columns and a separate health state');
  }
  const firstRunDetails = healthy.page.locator('#flowoffload-benchmark-result .flow-benchmark-run-details').first();
  await firstRunDetails.locator(':scope > summary').click();
  const runtimeSnapshots = firstRunDetails.locator('.flow-benchmark-snapshots');
  assert.equal(await runtimeSnapshots.evaluate(node => node.open), false,
    'runtime snapshots stay collapsed in the compact per-run view');
  assert.match(await runtimeSnapshots.locator('summary').innerText(), /Runtime до и после · \d+ фактов · изменений: 1/,
    'the compact runtime summary reports evidence and changed-fact counts');
  await runtimeSnapshots.locator('summary').click();
  const firstRunText = await firstRunDetails.innerText();
  assert.match(firstRunText, /Jitter[\s\S]*HTTP loss[\s\S]*Duration[\s\S]*CDN hostname/,
    'per-run details keep sample quality and CDN separate from the measurement table');
  assert.match(firstRunText, /Снимок до прогона[\s\S]*Снимок после прогона[\s\S]*2450[\s\S]*2470/i,
    'per-run details expose before/after snapshots and real NFQUEUE counter changes');
  assert.match(firstRunText, /Пакеты NFQUEUE\s+2450 → 2470/,
    'after snapshot lists only changed facts with before/after values');
  assert.match(firstRunText, /остальные \d+ не изменились и показаны в снимке до прогона/i,
    'unchanged runtime facts stay available in the before snapshot without duplicating the after snapshot');
  assert.match(firstRunText, /Аппаратные соединения[\s\S]*Поддержка hardware[\s\S]*Цепочка zapret2/,
    'runtime snapshots retain connection counts, hardware evidence, and selective rule facts');
  const snapshotHeights = await firstRunDetails.locator('.flow-benchmark-snapshot').evaluateAll(nodes => nodes.map(node => node.getBoundingClientRect().height));
  assert.ok(snapshotHeights[1] < snapshotHeights[0] / 2,
    `the after snapshot keeps its own compact height (${JSON.stringify(snapshotHeights)})`);
  const benchmarkSurfaces = await healthy.page.evaluate(() => ({
    snapshot: getComputedStyle(document.querySelector('.flow-benchmark-snapshot')).backgroundColor,
    recommendation: getComputedStyle(document.querySelector('.flow-benchmark-recommendation')).backgroundColor,
    tableHeader: getComputedStyle(document.querySelector('.flow-benchmark-table thead th')).backgroundColor,
  }));
  assert.deepEqual(benchmarkSurfaces,
    { snapshot: 'rgb(24, 30, 28)', recommendation: 'rgb(24, 30, 28)', tableHeader: 'rgb(24, 30, 28)' },
    `benchmark cards use the neutral Lolz surface color (${JSON.stringify(benchmarkSurfaces)})`);
  const providerSelect = healthy.page.locator('#flowoffload-benchmark-provider');
  await providerSelect.focus();
  await providerSelect.selectOption('cloudflare');
  const runTableWrap = healthy.page.locator('#flowoffload-benchmark-result .flow-benchmark-run-table').first().locator('xpath=..');
  await runTableWrap.evaluate(node => { node.scrollLeft = 80; });
  fixtureResult.modes.none.runs[0].health_after.nfqueue_packets = 2475;
  await healthy.page.waitForFunction(() => document.querySelector('#flowoffload-benchmark-result')?.innerText.includes('2450 → 2475'));
  await healthy.page.waitForTimeout(1400);
  assert.equal(await providerSelect.inputValue(), 'cloudflare', 'status polling preserves the selected benchmark provider');
  assert.equal(await healthy.page.evaluate(() => document.activeElement?.id), 'flowoffload-benchmark-provider',
    'status polling preserves keyboard focus');
  assert.equal(await firstRunDetails.evaluate(node => node.open), true,
    'status polling preserves the open per-run disclosure');
  assert.equal(await firstRunDetails.locator('.flow-benchmark-snapshots').evaluate(node => node.open), true,
    'status polling preserves the open runtime snapshot disclosure');
  assert.equal(await runTableWrap.evaluate(node => node.scrollLeft), 80,
    'status polling preserves the measurement table scroll position');
  if (screenshotDir) {
    await screenshotComponent(healthy.page, healthy.page.locator('#openwrt-offload-card'),
      path.join(screenshotDir, 'dark-1280-flowoffload-benchmark-runtime-evidence.png'));
  }
  await firstRunDetails.locator('.flow-benchmark-snapshots > summary').click();
  await healthy.page.locator('#flowoffload-technical > summary').click();
  for (const width of [1920, 1280, 900, 390]) {
    await healthy.page.setViewportSize({ width, height: 900 });
    await healthy.page.waitForTimeout(400);
    const frame = await healthy.page.evaluate(() => {
      const viewport = document.documentElement.clientWidth;
      const card = document.querySelector('#openwrt-offload-card');
      const run = document.querySelector('#flowoffload-benchmark-result .flow-benchmark-run-main');
      const host = document.querySelector('#flowoffload-benchmark-result .flow-benchmark-run-meta .is-host');
      const fact = document.querySelector('#flowoffload-technical .flow-fact');
      const label = fact?.querySelector('.flow-fact-label');
      const value = fact?.querySelector('.flow-fact-value');
      return {
        viewport, pageWidth: document.documentElement.scrollWidth,
        cardWidth: card?.getBoundingClientRect().width,
        runHeight: run?.getBoundingClientRect().height,
        hostWidth: host?.getBoundingClientRect().width, hostScroll: host?.scrollWidth,
        labelWidth: label?.getBoundingClientRect().width, valueLeft: value?.getBoundingClientRect().left,
        labelRight: label?.getBoundingClientRect().right, labelWordBreak: label && getComputedStyle(label).wordBreak,
        overflowers: [...document.querySelectorAll('#app *')].map(node => {
          const rect = node.getBoundingClientRect();
          return { tag: node.tagName, id: node.id, className: String(node.className || '').slice(0, 80), right: Math.round(rect.right), width: Math.round(rect.width) };
        }).filter(node => node.right > viewport + 1).sort((a, b) => b.right - a.right).slice(0, 8),
      };
    });
    if (screenshotDir) {
      await screenshotComponent(healthy.page, healthy.page.locator('#openwrt-offload-card'),
        path.join(screenshotDir, `dark-${width}-flowoffload-benchmark-diagnostics.png`));
    }
    assert.ok(frame.pageWidth <= frame.viewport, `${width}px FLOWOFFLOAD must not cause page-level horizontal overflow (${JSON.stringify(frame)})`);
    assert.ok(frame.runHeight < 48, `${width}px measurement rows stay compact (${JSON.stringify(frame)})`);
    assert.ok(frame.hostScroll <= frame.hostWidth + 1, `${width}px long CDN hostname wraps inside its details (${JSON.stringify(frame)})`);
    assert.ok(frame.labelWidth >= 88 && frame.valueLeft >= frame.labelRight - 1 && frame.labelWordBreak === 'normal',
      `${width}px diagnostic labels and values use a readable two-column row (${JSON.stringify(frame)})`);
  }
  showLastSuccessFallback = true;
  await healthy.page.reload();
  await waitForCondition(() => latestBenchmarkStatus?.status === 'failed', 'failed benchmark history response');
  await healthy.page.waitForFunction(() => document.querySelector('#flowoffload-benchmark-result')?.dataset.signature?.includes('endpoint failed'));
  assert.doesNotMatch(await healthy.page.locator('#flowoffload-benchmark-result').innerText(), /Программное vs Без ускорения/,
    'incomplete benchmark hides percentage comparisons');
  await healthy.page.waitForFunction(() => document.querySelector('#flowoffload-benchmark-status')?.innerText.includes('Предыдущая сохранённая серия доступна как исторический результат'));
  const lastSuccess = healthy.page.locator('#flowoffload-benchmark-last-success');
  const lastSuccessDebug = await healthy.page.evaluate(() => ({
    status: document.querySelector('#flowoffload-benchmark-status')?.textContent,
    hidden: document.querySelector('#flowoffload-benchmark-last-success')?.hidden,
    timestamp: document.querySelector('#flowoffload-benchmark-last-success')?.dataset.timestamp,
    content: Boolean(document.querySelector('#flowoffload-benchmark-last-success-content')),
  }));
  assert.equal(lastSuccessDebug.hidden, false, `last-success fallback should be visible; fixture=${JSON.stringify(latestBenchmarkStatus)} UI=${JSON.stringify(lastSuccessDebug)}`);
  assert.equal(lastSuccessDebug.timestamp, 'historical', 'legacy history remains visible without a current benchmark timestamp');
  await lastSuccess.locator('summary').first().click();
  await lastSuccess.locator('#flowoffload-benchmark-last-success-content > details > summary').click();
  await lastSuccess.getByText('Модель роутера').waitFor({ state: 'visible' });
  assert.match(await lastSuccess.innerText(), /Fixture Router/);
  assert.match(await lastSuccess.innerText(), /Исторический результат[\s\S]*runtime evidence отсутствует/);
  assert.doesNotMatch(await lastSuccess.innerText(), /Рекомендуется: Аппаратное/);
  await healthy.page.locator('#flowoffload-benchmark-result > details > summary').click();
  assert.match(await healthy.page.locator('#flowoffload-benchmark-result').innerText(), /endpoint failed/);
  await healthy.page.close();

  const visualGoodIps = ['203.0.113.35', '203.0.113.20', '203.0.113.50', '203.0.113.51', '203.0.113.52',
    '203.0.113.53', '203.0.113.54', '203.0.113.55', '203.0.113.56', '203.0.113.57'];
  const visualCandidatePool = [
    ...visualGoodIps.map(ip => `${ip}|v77.tiktokcdn.com,v77.tiktokcdn-eu.com|direct|1.1.1.1|system-wan|edge.example.net|Amsterdam|check-host|1|1|0|8|4|8|ru1,de1|NL,DE|AS1,AS2|Amsterdam|131,117`),
    '203.0.113.8|v77.tiktokcdn.com|direct|1.1.1.1|system-wan||Frankfurt|curated|0|1|0|0|0|0|||||',
  ].join(';');
  const visualProbeObservations = [
    ...visualGoodIps.map((ip, index) => `${ip}|${90 + index * 9}|23|20|400|ams|HIT|edge|ok|ok|verified|${117 + index * 5}|19|27|400|fra|HIT|edge|ok|ok|verified|compatible|23`),
    '203.0.113.8||0|0|||edge|failed|failed|failed||||||||||||incompatible|',
  ].join(';');
  const visualDomainHosts = [
    'v77.tiktokcdn.com', 'v77.tiktokcdn-eu.com', 'v16-cla.tiktokcdn.com',
    'v16-ies-music.tiktokcdn.com', 'sf16-music.tiktokcdn-eu.com',
  ];
  const visualNow = Math.floor(Date.now() / 1000);
  const visualDomainFields = Object.fromEntries(visualDomainHosts.flatMap((host, index) => {
    const slug = host.replace(/[.-]/g, '_');
    const selectedIp = visualGoodIps[index];
    const policy = index === 2 || index === 3 ? 'preferred' : index === 4 ? 'strict' : 'auto';
    const preferredIp = index === 3 ? visualGoodIps[5] : policy === 'preferred' || policy === 'strict' ? selectedIp : '';
    const pool = [
      ...visualGoodIps.map((ip, candidateIndex) => `${ip}|${host}|direct|1.1.1.1|system-wan|edge-${candidateIndex}|Amsterdam|check-host|1|0|0|8|4|8|ru1,de1|NL,DE|AS1,AS2|Amsterdam|300,120`),
      `203.0.113.8|${host}|direct|1.1.1.1|curated-community-fallback||Frankfurt|curated-community-fallback|0|1|0|0|0|0|||||`,
    ].join(';');
    const observation = [
      ...visualGoodIps.map((ip, candidateIndex) => `${ip}|${90 + candidateIndex * 9}|23|20|206|ams|HIT|edge-${candidateIndex}|ok|ok|verified`),
      '203.0.113.8||||||||failed|failed|failed',
    ].join(';');
    const failover = index === 3;
    const fields = {
      cluster: index < 2 ? '77' : '16', policy, preferred_ip: preferredIp, selected_ip: selectedIp,
      health: 'transport-confirmed', failure_count: '0', selected_at_epoch: String(visualNow - 3600 + index * 45),
      preferred_set_at_epoch: preferredIp ? String(visualNow - 7200) : '',
      last_verified_epoch: String(visualNow - 75), last_evaluation_epoch: String(visualNow - 30),
      last_failover_epoch: failover ? String(visualNow - 1800) : '',
      last_failover_from: failover ? visualGoodIps[5] : '', last_failover_to: failover ? selectedIp : '',
      reason: failover ? 'confirmed-failover' : policy === 'preferred' ? 'preferred-selection' : 'healthy',
      dns_override_applied: '1', latency_ms: String(90 + index * 7), http_status: '206',
      candidates_checked_epoch: String(visualNow - 300), candidate_pool: pool,
      candidate_observations: observation,
    };
    return Object.entries(fields).map(([field, value]) => [`domain_${slug}_${field}`, value]);
  }));
  const visualBase = {
    state: 'healthy', candidate_verified: '1', dns_override_applied: '1', selected_ip: visualGoodIps[0],
    manual_ip: '', mode: 'auto', latency_ms: '90', selected_at_epoch: String(Math.floor(Date.now() / 1000) - 48),
    last_verified_epoch: String(Math.floor(Date.now() / 1000) - 48), reason: 'healthy',
    candidate_pool: visualCandidatePool, probe_observations: visualProbeObservations,
    ...visualDomainFields,
    last_failover_epoch: String(Math.floor(Date.now() / 1000) - 3600), last_failover_from: '203.0.113.8',
    last_failover_to: visualGoodIps[0], last_failover_reason: 'consecutive-probe-failures',
  };
  const visualStates = [
    { name: 'auto-healthy', status: visualBase },
    { name: 'manual-selected', status: { ...visualBase, mode: 'manual', manual_ip: visualGoodIps[0] } },
    { name: 'candidates-expanded', status: visualBase, action: 'expand' },
    { name: 'unavailable-candidates', status: visualBase, action: 'unavailable' },
    { name: 'diagnostics-expanded', status: visualBase, action: 'diagnostics' },
  ];
  for (const viewport of [
    { width: 1920, height: 1080 },
    { width: 1440, height: 900 },
    { width: 390, height: 844 },
  ]) {
    const visual = await makeTikTokPage(true, visualStates[0].status,
      { ...viewport, isMobile: viewport.width < 768 });
    for (let stateIndex = 0; stateIndex < visualStates.length; stateIndex += 1) {
      const state = visualStates[stateIndex];
      if (stateIndex > 0) {
        visual.setStatus(state.status);
        await visual.page.reload({ waitUntil: 'domcontentloaded' });
        await waitForRenderedRoute(visual.page, 'tiktok');
      }
      const card = visual.page.locator('#tiktok-feed-status-card');
      await card.waitFor({ state: 'visible' });
      if (stateIndex === 0) {
        const claCard = card.locator('.tiktok-domain-card').filter({ hasText: 'v16-cla.tiktokcdn.com' });
        assert.match(await claCard.innerText(), new RegExp(visualGoodIps[2].replaceAll('.', '\\.')),
          'v16-cla displays its independent selected address');
        assert.match(await claCard.innerText(), /Источник выбранного IP[\s\S]*check-host · system-wan/,
          'per-domain status includes the selected candidate source');
        const selectButton = card.locator('[data-tiktok-action="select"]:not(:disabled)').first();
        const selectStyle = await selectButton.evaluate(node => {
          const style = getComputedStyle(node);
          const rect = node.getBoundingClientRect();
          return { height: rect.height, width: rect.width, radius: style.borderRadius, fontSize: style.fontSize };
        });
        assert.deepEqual(selectStyle, { height: 34, width: 96, radius: '10px', fontSize: '14px' },
          `${viewport.width}px select control follows shared Lolz control geometry (${JSON.stringify(selectStyle)})`);
      }
      if (state.action === 'expand') {
        assert.ok(await card.locator('[data-tiktok-overflow]').count() > 0,
          'candidate list keeps overflow rows collapsed before expansion');
        await card.locator('[data-tiktok-action="show-all"]').click();
        assert.equal(await card.locator('[data-tiktok-overflow]').evaluateAll(items => items.every(item => !item.hidden)), true,
          'show all reveals overflow candidates');
      } else if (state.action === 'unavailable') {
        const filter = card.locator('[data-tiktok-action="filter"][data-tiktok-filter="unavailable"]');
        await filter.focus();
        await visual.page.keyboard.press('Enter');
        assert.equal(await filter.getAttribute('aria-pressed'), 'true',
          'candidate filters can be activated from the keyboard');
        assert.equal(await card.locator('[data-tiktok-candidate-group="unavailable"]').evaluate(node => node.open), true,
          'the unavailable group expands when its filter is selected');
        assert.equal(await card.locator('[data-tiktok-candidate-group="unavailable"] [data-tiktok-action="select"]').count(), 0,
          'unavailable candidates do not show a dead select button');
      } else if (state.action === 'diagnostics') {
        await card.locator('#tiktok-feed-technical > summary').click();
        assert.equal(await card.locator('#tiktok-feed-technical').evaluate(node => node.open), true);
      }
      assert.equal(await visual.page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true,
        `${viewport.width}px ${state.name} layout has no horizontal overflow`);
      if (screenshotDir) {
        await screenshotComponent(visual.page, card, path.join(screenshotDir, `dark-${viewport.width}-tiktok-${state.name}.png`));
      }
    }
    await visual.page.close();
  }

  const desktop = await makeTikTokPage(true, {
    state: 'healthy', candidate_verified: '1', dns_override_applied: '1',
    selected_ip: '203.0.113.9', latency_ms: '131',
    selected_source_domain: 'www.tiktokcdn.com', last_verified_epoch: String(Math.floor(Date.now() / 1000)),
  }, { width: 1280, height: 900, isMobile: false });
  const desktopCard = desktop.page.locator('#tiktok-feed-status-card');
  assert.equal(await desktopCard.isVisible(), true, 'the TikTok status card renders at desktop width');
  assert.equal(await desktopCard.locator('.tiktok-failover').count(), 0,
    'the desktop summary omits a failover block when none has occurred');
  assert.equal(await desktop.page.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true,
    'the desktop card does not introduce horizontal overflow');
  await desktop.page.close();

  const degraded = await makeTikTokPage(true, { state: 'degraded', selected_ip: '203.0.113.10', reason: 'no-verified-alternative' });
  assert.match(await degraded.page.locator('#tiktok-feed-status-card').innerText(), /Нестабильно/);
  await degraded.page.close();

  const failOpen = await makeTikTokPage(true, { state: 'degraded', reason: 'no-verified-cdn-fail-open' });
  const failOpenText = await failOpen.page.locator('#tiktok-feed-status-card').innerText();
  assert.match(failOpenText, /Рабочий CDN не найден/);
  assert.match(failOpenText, /обычный доступ сохранён/);
  assert.doesNotMatch(failOpenText, /● Работает/);
  await failOpen.page.close();

  assert.deepEqual(allPageErrors, []);
  assert.deepEqual(allConsoleErrors, []);
  }

  const videoDir = process.env.OPENWRT_VIDEO_DIR || '';
  if (shellOnly) {
    await runShellMotionTests(videoDir || path.join(repo, '.motion-shell-proof', 'shell-only'));
  } else if (videoDir) {
    fs.mkdirSync(videoDir, { recursive: true });
    const routeEvent = (sequence, transport, state) => ({
      sequence,
      branch: ['direct_wss', 'tcp_passthrough'].includes(transport) ? 'direct' : 'fallback',
      transport,
      state,
    });
    const routeSession = ({ id = 700, dc = 2, direct = { state: 'idle' },
      fallback = { state: 'idle' }, selected = null, events = [] }) => ({
      id, dc, is_media: false, stage: selected ? 'upstream_ready' : 'routing',
      direct_state: direct.state,
      direct_transport: direct.transport || null,
      fallback_state: fallback.state,
      fallback_transport: fallback.transport || null,
      selected_transport: selected,
      telegram_response_seen: false,
      events,
    });
    const routeScenario = ({ direct, fallback, selected, events = [], processStartedAt = tgCheckedAt - 600,
      accepted = 18, active = 1, dc = 2, sessions = null }) => ({
      ...tgStatsFixture,
      process_started_at: processStartedAt,
      accepted_connections: accepted,
      active_connections: active,
      active_sessions: sessions || (active ? Array.from({ length: active }, (_, index) => routeSession({
        id: 700 + index, dc, direct, fallback, selected, events,
      })) : []),
    });
    const directRoute = () => routeScenario({
      direct: { state: 'selected', transport: 'direct_wss' },
      fallback: { state: 'idle' }, selected: 'direct_wss',
      events: [routeEvent(1, 'direct_wss', 'selected')],
    });
    let failStatsApi = false;
    tgRunningFixture = true;
    const motionPage = await browser.newPage({
      viewport: { width: 1280, height: 900 },
      colorScheme: 'dark',
      recordVideo: { dir: videoDir, size: { width: 1280, height: 900 } },
    });
    const telegramVideo = motionPage.video();
    await motionPage.addInitScript(() => {
      localStorage.setItem('z2k-theme', 'dark');
      localStorage.setItem('z2k-sidebar', 'expanded');
      const metrics = window.__tgFlowTestMetrics = {
        mounts: 0, destroys: 0, resizes: 0, processedEvents: 0,
        canvasBackingWrites: [], canvasContextReads: 0, canvasContextChanges: 0, canvasContext: null,
        canvasRemovals: 0,
      };
      for (const name of ['width', 'height']) {
        const descriptor = Object.getOwnPropertyDescriptor(HTMLCanvasElement.prototype, name);
        Object.defineProperty(HTMLCanvasElement.prototype, name, {
          ...descriptor,
          set(value) {
            if (this.id === 'tg-flow-canvas') metrics.canvasBackingWrites.push({ name, value: Number(value) });
            descriptor.set.call(this, value);
          },
        });
      }
      const setterProbe = document.createElement('canvas');
      setterProbe.id = 'tg-flow-canvas';
      setterProbe.width = 1;
      setterProbe.height = 1;
      metrics.canvasSetterProbeWrites = metrics.canvasBackingWrites.length;
      metrics.canvasBackingWrites.length = 0;
      const getContext = HTMLCanvasElement.prototype.getContext;
      HTMLCanvasElement.prototype.getContext = function (...args) {
        const context = getContext.apply(this, args);
        if (this.id === 'tg-flow-canvas') {
          metrics.canvasContextReads += 1;
          if (metrics.canvasContext && metrics.canvasContext !== context) metrics.canvasContextChanges += 1;
          metrics.canvasContext ||= context;
        }
        return context;
      };
      new MutationObserver(records => {
        for (const record of records) {
          for (const node of record.removedNodes) {
            if (node.nodeType === Node.ELEMENT_NODE
              && (node.id === 'tg-flow-canvas' || node.querySelector?.('#tg-flow-canvas'))) {
              metrics.canvasRemovals += 1;
            }
          }
        }
      }).observe(document, { childList: true, subtree: true });
    });
    await motionPage.route('**/cgi-bin/api/tunnel/stats', route =>
      failStatsApi ? route.abort('failed') : route.continue());
    tgStatsResponse = directRoute();
    await motionPage.goto(`${base}/#/dashboard`);
    await waitForRenderedRoute(motionPage, 'dashboard');
    await motionPage.locator('#sidebar-collapse').click();
    await motionPage.waitForTimeout(350);
    await motionPage.locator('#sidebar-collapse').click();
    await motionPage.waitForTimeout(350);
    await motionPage.evaluate(() => { location.hash = '#/toggles'; });
    await waitForRenderedRoute(motionPage, 'toggles');
    const card = motionPage.locator('.telegram-tunnel-card');
    await card.scrollIntoViewIfNeeded();
    const flow = motionPage.locator('#tg-flow');
    const canvas = motionPage.locator('#tg-flow-canvas');
    const caption = motionPage.locator('#tg-flow-caption');
    await motionPage.waitForFunction(() => document.querySelector('#tg-flow')?.dataset.state === 'active');
    assert.match(await caption.innerText(), /Прямой WSS/, 'видео начинается с выбранного прямого WSS');
    assert.equal(await card.locator('#tg-flow svg').count(), 0, 'сама схема Telegram отрисована только в Canvas');
    const firstFrame = await canvas.evaluate(node => node.toDataURL());
    await motionPage.waitForTimeout(280);
    const nextFrame = await canvas.evaluate(node => node.toDataURL());
    assert.notEqual(nextFrame, firstFrame, 'выбранный маршрут непрерывно показывает спокойный цикл соединения');
    if (screenshotDir) {
      await screenshotComponent(motionPage, card,
        path.join(screenshotDir, `${screenshotPrefix}tg-flow-direct-dark-desktop.png`));
    }

    const darkPixel = await canvas.evaluate(node => [...node.getContext('2d').getImageData(1, 1, 1, 1).data]);
    await motionPage.evaluate(() => { document.documentElement.dataset.theme = 'light'; });
    await motionPage.waitForTimeout(120);
    const lightPixel = await canvas.evaluate(node => [...node.getContext('2d').getImageData(1, 1, 1, 1).data]);
    assert.notDeepEqual(lightPixel, darkPixel, 'Canvas перекрашивается при смене темы Lolzteam');
    if (screenshotDir) {
      await screenshotComponent(motionPage, card,
        path.join(screenshotDir, `${screenshotPrefix}tg-flow-direct-light-desktop.png`));
    }
    await motionPage.evaluate(() => { document.documentElement.dataset.theme = 'dark'; });
    await motionPage.emulateMedia({ reducedMotion: 'reduce' });
    await motionPage.waitForTimeout(80);
    const reducedFrame = await canvas.evaluate(node => node.toDataURL());
    await motionPage.waitForTimeout(180);
    assert.equal(await canvas.evaluate(node => node.toDataURL()), reducedFrame,
      'reduced motion останавливает непрерывное движение Canvas');
    await motionPage.emulateMedia({ reducedMotion: 'no-preference' });

    await motionPage.waitForFunction(() => document.querySelectorAll('#tg-check-results .tg-dc-row').length === 5,
      null, { timeout: 3000 });
    await motionPage.locator('#tg-advanced-settings > summary').click();
    await waitForDisclosureSettled(motionPage, '#tg-advanced-settings');
    await motionPage.locator('#tg-stats-refresh').waitFor({ state: 'visible' });
    await motionPage.locator('#tg-diagnostic-details > summary').click();
    await waitForDisclosureSettled(motionPage, '#tg-diagnostic-details');

    const captureTelegramLayout = () => motionPage.evaluate(() => {
      const cardNode = document.querySelector('.telegram-tunnel-card');
      const appRect = document.querySelector('#app').getBoundingClientRect();
      const cardRect = cardNode.getBoundingClientRect();
      const relativeBox = (node, origin) => {
        if (!node) return [];
        const rect = node.getBoundingClientRect();
        return [rect.x - origin.x, rect.y - origin.y, rect.width, rect.height]
          .map(value => Math.round(value * 100) / 100);
      };
      const flowNode = document.querySelector('#tg-flow');
      const flowStyle = getComputedStyle(flowNode);
      const flowParentStyle = getComputedStyle(flowNode.parentElement);
      const box = node => {
        const rect = node.getBoundingClientRect();
        return [rect.x - cardRect.x, rect.y - cardRect.y, rect.width, rect.height]
          .map(value => Math.round(value * 100) / 100);
      };
      return {
        viewport: [window.innerWidth, document.documentElement.clientWidth, window.scrollY],
        app: [appRect.width, appRect.height].map(value => Math.round(value * 100) / 100),
        card: relativeBox(cardNode, appRect),
        flow: box(flowNode),
        flowStyle: {
          display: flowStyle.display, width: flowStyle.width, maxWidth: flowStyle.maxWidth,
          margin: flowStyle.margin, alignSelf: flowStyle.alignSelf,
          transform: flowStyle.transform, transformOrigin: flowStyle.transformOrigin,
          parentDisplay: flowParentStyle.display, parentWidth: flowParentStyle.width,
          parentAlign: flowParentStyle.alignItems, parentJustify: flowParentStyle.justifyContent,
          parentClasses: flowNode.parentElement.className,
        },
        canvasAttributes: [document.querySelector('#tg-flow-canvas').getAttribute('width'),
          document.querySelector('#tg-flow-canvas').getAttribute('height')],
        canvas: box(document.querySelector('#tg-flow-canvas')),
        caption: box(document.querySelector('#tg-flow-caption')),
        buttons: ['#tg-enable', '#tg-disable', '#tg-check'].map(selector => box(document.querySelector(selector))),
        previous: relativeBox(cardNode.previousElementSibling, appRect),
        next: relativeBox(cardNode.nextElementSibling, appRect),
      };
    });
    let baselineTelegramLayout = await captureTelegramLayout();
    const assertStableCardLayout = async description => {
      const current = await captureTelegramLayout();
      const flatten = value => Array.isArray(value) ? value.flatMap(flatten)
        : value && typeof value === 'object' ? Object.values(value).flatMap(flatten) : [value];
      const stableNumbers = value => flatten({
        app: value.app, card: value.card, flow: value.flow, canvas: value.canvas, caption: value.caption,
        buttons: value.buttons,
      });
      const expected = stableNumbers(baselineTelegramLayout);
      const actual = stableNumbers(current);
      assert.equal(actual.length, expected.length, `${description}: компоновка сохраняет состав элементов`);
      assert.ok(actual.every((value, index) => Math.abs(value - expected[index]) <= 1),
        `${description}: высота карточки, Canvas, кнопок и соседних блоков стабильна (до ${JSON.stringify(baselineTelegramLayout)}, после ${JSON.stringify(current)})`);
    };
    const refreshRoute = async (snapshot, expectedText) => {
      tgStatsResponse = snapshot;
      const before = apiRequests.filter(request => request.endpoint === 'tunnel/stats').length;
      await motionPage.evaluate(() => {
        const button = document.querySelector('#tg-stats-refresh');
        button.focus({ preventScroll: true });
        button.click();
      });
      await waitForCondition(() => apiRequests.filter(request => request.endpoint === 'tunnel/stats').length > before,
        'ответ на обновление Telegram statistics');
      await motionPage.waitForFunction(expected => document.querySelector('#tg-flow-caption')?.textContent.includes(expected), expectedText);
      await motionPage.waitForFunction(expected => document.querySelector('[data-tg-row="accepted_connections"] .tg-technical-value span')?.textContent === expected,
        String(snapshot.accepted_connections));
      await assertStableCardLayout(expectedText);
    };

    await refreshRoute(routeScenario({
      direct: { state: 'cooldown', transport: 'direct_wss' },
      fallback: { state: 'selected', transport: 'cloudflare_worker' }, selected: 'cloudflare_worker',
      events: [routeEvent(2, 'direct_wss', 'cooldown'), routeEvent(3, 'cloudflare_worker', 'connecting'),
        routeEvent(4, 'cloudflare_worker', 'connected'), routeEvent(5, 'cloudflare_worker', 'selected')],
    }), 'Cloudflare Worker');
    assert.equal(await motionPage.locator('#tg-active-route').innerText(), 'Cloudflare Worker',
      'после периода паузы прямой линии выбран Cloudflare Worker');
    assert.match(await canvas.getAttribute('aria-label'), /на паузе/,
      'Canvas показывает состояние паузы из события Rust');
    if (screenshotDir) {
      await screenshotComponent(motionPage, card,
        path.join(screenshotDir, `${screenshotPrefix}tg-flow-cooldown-worker-dark-desktop.png`));
    }

    await refreshRoute(routeScenario({
      direct: { state: 'failed', transport: 'direct_wss' },
      fallback: { state: 'selected', transport: 'cloudflare_proxy' }, selected: 'cloudflare_proxy',
      events: [routeEvent(6, 'cloudflare_worker', 'failed'), routeEvent(7, 'cloudflare_proxy', 'connecting'),
        routeEvent(8, 'cloudflare_proxy', 'connected'), routeEvent(9, 'cloudflare_proxy', 'selected')],
    }), 'Прокси Cloudflare');
    assert.equal(await motionPage.locator('#tg-active-route').innerText(), 'Прокси Cloudflare',
      'после отказа Worker выбран Cloudflare proxy');

    await refreshRoute(routeScenario({
      direct: { state: 'selected', transport: 'direct_wss' },
      fallback: { state: 'cancelled', transport: 'cloudflare_worker' }, selected: 'direct_wss',
      events: [routeEvent(10, 'direct_wss', 'connecting'), routeEvent(11, 'cloudflare_worker', 'connecting'),
        routeEvent(12, 'direct_wss', 'selected'), routeEvent(13, 'cloudflare_worker', 'cancelled')],
    }), 'Параллельная гонка');
    assert.match(await caption.innerText(), /победил Прямой WSS.*остальные попытки отменены/,
      'Параллельная гонка показывает победителя и отменённую конкурирующую попытку');
    if (screenshotDir) {
      await screenshotComponent(motionPage, card,
        path.join(screenshotDir, `${screenshotPrefix}tg-flow-hedged-dark-desktop.png`));
    }

    await refreshRoute(routeScenario({
      direct: { state: 'failed', transport: 'direct_wss' },
      fallback: { state: 'selected', transport: 'tcp_fallback' }, selected: 'tcp_fallback',
      events: [routeEvent(14, 'direct_wss', 'failed'), routeEvent(15, 'tcp_fallback', 'connecting'),
        routeEvent(16, 'tcp_fallback', 'connected'), routeEvent(17, 'tcp_fallback', 'selected')],
    }), 'Резервный TCP');
    assert.equal(await motionPage.locator('#tg-active-route').innerText(), 'Резервный TCP',
      'при отказе WSS выбран резервный TCP');
    if (screenshotDir) {
      await screenshotComponent(motionPage, card,
        path.join(screenshotDir, `${screenshotPrefix}tg-flow-tcp-fallback-dark-desktop.png`));
    }

    const mixedSessions = [
      routeSession({ id: 801, dc: 2, direct: { state: 'selected', transport: 'direct_wss' }, selected: 'direct_wss' }),
      routeSession({ id: 802, dc: 4, fallback: { state: 'selected', transport: 'cloudflare_worker' }, selected: 'cloudflare_worker' }),
    ];
    await refreshRoute(routeScenario({ active: 2, sessions: mixedSessions, accepted: 24 }), 'разные маршруты');
    assert.equal(await motionPage.locator('#tg-active-route').innerText(), 'Несколько маршрутов',
      'разные сессии не получают общий вымышленный маршрут');
    assert.match(await canvas.getAttribute('aria-label'), /Прямой WSS.*Cloudflare Worker/,
      'Canvas отдельно перечисляет оба реально выбранных транспорта');
    if (screenshotDir) {
      await screenshotComponent(motionPage, card,
        path.join(screenshotDir, `${screenshotPrefix}tg-flow-mixed-dark-desktop.png`));
    }

    await refreshRoute(routeScenario({
      direct: { state: 'selected', transport: 'direct_wss' }, selected: 'direct_wss',
      events: [routeEvent(18, 'direct_wss', 'selected')], accepted: 25,
    }), 'Прямой WSS');
    await motionPage.locator('#tg-runtime-details .tg-technical > summary').click();
    await waitForDisclosureSettled(motionPage, '#tg-runtime-details .tg-technical');
    baselineTelegramLayout = await captureTelegramLayout();
    await motionPage.evaluate(() => {
      window.__tgPollingRefs = {
        root: document.querySelector('#tg-flow'),
        canvas: document.querySelector('#tg-flow-canvas'),
        caption: document.querySelector('#tg-flow-caption'),
        advanced: document.querySelector('#tg-advanced-settings'),
        tools: document.querySelector('#tg-openwrt-tools'),
        diagnostics: document.querySelector('#tg-diagnostic-details'),
        technical: document.querySelector('#tg-runtime-details .tg-technical'),
        row: document.querySelector('#tg-runtime-details [data-tg-row="accepted_connections"]'),
      };
    });
    await motionPage.locator('#tg-stats-refresh').evaluate(button => button.focus({ preventScroll: true }));
    const persistentRefs = await motionPage.evaluate(() => ({
      focusId: document.activeElement.id,
      scrollY: window.scrollY,
    }));
    await motionPage.evaluate(() => {
      const metrics = window.__tgFlowTestMetrics;
      metrics.canvasBackingWrites.length = 0;
      metrics.canvasContextReads = 0;
      metrics.canvasContextChanges = 0;
      metrics.canvasRemovals = 0;
      metrics.mountsBeforePolling = metrics.mounts;
      metrics.destroysBeforePolling = metrics.destroys;
      metrics.processedEventsBeforePolling = metrics.processedEvents;
      metrics.resizesBeforePolling = metrics.resizes;
    });
    const identicalPollSnapshot = routeScenario({
      direct: { state: 'selected', transport: 'direct_wss' }, selected: 'direct_wss', dc: 5,
      active: 1, accepted: 25,
      events: [routeEvent(18, 'direct_wss', 'selected'), routeEvent(19, 'direct_wss', 'first_binary_response')],
    });
    for (let index = 0; index < 100; index += 1) {
      const snapshot = index < 50 ? identicalPollSnapshot : {
        ...identicalPollSnapshot, accepted_connections: 26 + index - 50,
      };
      await refreshRoute(snapshot, 'Прямой WSS');
      await motionPage.evaluate(() => window.dispatchEvent(new Event('resize')));
      const updateState = await motionPage.evaluate(expected => {
        const selectors = {
          root: '#tg-flow', canvas: '#tg-flow-canvas', caption: '#tg-flow-caption',
          advanced: '#tg-advanced-settings', tools: '#tg-openwrt-tools',
          diagnostics: '#tg-diagnostic-details', technical: '#tg-runtime-details .tg-technical',
          row: '#tg-runtime-details [data-tg-row="accepted_connections"]',
        };
        const sameDom = Object.fromEntries(Object.entries(selectors)
          .map(([key, selector]) => [key, document.querySelector(selector) === window.__tgPollingRefs[key]]));
        return {
          sameDom,
          disclosures: ['#tg-advanced-settings', '#tg-diagnostic-details',
            '#tg-runtime-details .tg-technical'].map(selector => document.querySelector(selector).open),
          focusId: document.activeElement.id,
          scrollY: window.scrollY,
          canvasCount: document.querySelectorAll('#tg-flow-canvas').length,
          svgCount: [...document.querySelectorAll('.telegram-tunnel-card svg')]
            .filter(svg => !svg.closest('.disclosure-chevron')).length,
        };
      }, persistentRefs);
      assert.ok(Object.values(updateState.sameDom).every(Boolean),
        `опрос ${index + 1}: Canvas и детали не пересоздаются (${JSON.stringify(updateState.sameDom)})`);
      assert.deepEqual(updateState.disclosures, [true, true, true], `опрос ${index + 1}: раскрытые подробности остаются открыты`);
      assert.equal(updateState.focusId, persistentRefs.focusId, `опрос ${index + 1}: фокус сохраняется`);
      assert.equal(updateState.scrollY, persistentRefs.scrollY, `опрос ${index + 1}: прокрутка сохраняется`);
      assert.equal(updateState.canvasCount, 1, `опрос ${index + 1}: остаётся один Canvas`);
      assert.equal(updateState.svgCount, 0, `опрос ${index + 1}: SVG-схема не возвращается`);
    }
    const pollingMetrics = await motionPage.evaluate(() => window.__tgFlowTestMetrics);
    assert.equal(pollingMetrics.canvasSetterProbeWrites, 2, 'тестовый перехват видит записи обоих backing dimensions');
    assert.ok(pollingMetrics.resizes - pollingMetrics.resizesBeforePolling >= 100,
      '100 синтетических resize-событий дошли до реального resize()');
    assert.equal(pollingMetrics.canvasBackingWrites.length, 0,
      '100 polling-обновлений без изменения CSS-размера не сбрасывают backing store Canvas');
    assert.equal(pollingMetrics.mounts, pollingMetrics.mountsBeforePolling,
      'polling не повторяет mountTelegramFlow');
    assert.equal(pollingMetrics.destroys, pollingMetrics.destroysBeforePolling,
      'polling не уничтожает поток Telegram');
    assert.equal(pollingMetrics.processedEvents - pollingMetrics.processedEventsBeforePolling, 1,
      'один новый event sequence обрабатывается ровно один раз среди повторных snapshots');
    assert.equal(pollingMetrics.canvasContextChanges, 0, 'polling сохраняет тот же Canvas context');
    assert.equal(pollingMetrics.canvasRemovals, 0, 'polling ни на кадр не удаляет схему Canvas');
    assert.equal(pollingMetrics.canvasContextReads, 0, 'polling не запрашивает новый Canvas context');

    const canvasBeforeResize = await canvas.evaluate(node => ({ width: node.width, height: node.height }));
    await canvas.evaluate(node => {
      node.style.height = `${Math.round(node.getBoundingClientRect().height) - 24}px`;
      window.dispatchEvent(new Event('resize'));
    });
    const cssResize = await canvas.evaluate(node => ({
      width: node.width, height: node.height,
      expectedWidth: Math.round(node.getBoundingClientRect().width * window.devicePixelRatio),
      expectedHeight: Math.round(node.getBoundingClientRect().height * window.devicePixelRatio),
    }));
    assert.deepEqual([cssResize.width, cssResize.height], [cssResize.expectedWidth, cssResize.expectedHeight],
      'CSS resize sets physical Canvas dimensions from CSS size and DPR');
    assert.notDeepEqual([cssResize.width, cssResize.height], [canvasBeforeResize.width, canvasBeforeResize.height],
      'CSS resize changes at least one backing dimension');
    const expectedCssWrites = [
      ...(cssResize.expectedWidth !== canvasBeforeResize.width ? ['width'] : []),
      ...(cssResize.expectedHeight !== canvasBeforeResize.height ? ['height'] : []),
    ];
    const actualCssWrites = await motionPage.evaluate(() => window.__tgFlowTestMetrics.canvasBackingWrites.map(write => write.name));
    assert.deepEqual(actualCssWrites, expectedCssWrites,
      'CSS resize записывает только физические размеры, которые действительно изменились');
    await canvas.evaluate(node => { node.style.height = ''; window.dispatchEvent(new Event('resize')); });
    await motionPage.evaluate(() => { window.__tgFlowTestMetrics.canvasBackingWrites.length = 0; });
    const canvasBeforeDpr = await canvas.evaluate(node => ({ width: node.width, height: node.height }));
    const dprSession = await motionPage.context().newCDPSession(motionPage);
    await dprSession.send('Emulation.setDeviceMetricsOverride', {
      width: 1280, height: 900, deviceScaleFactor: 2, mobile: false,
    });
    await motionPage.evaluate(() => window.dispatchEvent(new Event('resize')));
    const dprResize = await canvas.evaluate(node => ({
      dpr: window.devicePixelRatio, width: node.width, height: node.height,
      expectedWidth: Math.round(node.getBoundingClientRect().width * window.devicePixelRatio),
      expectedHeight: Math.round(node.getBoundingClientRect().height * window.devicePixelRatio),
    }));
    assert.equal(dprResize.dpr, 2, 'тестовое окружение меняет физический DPR');
    assert.deepEqual([dprResize.width, dprResize.height], [dprResize.expectedWidth, dprResize.expectedHeight],
      'изменение DPR пересчитывает обе backing dimensions');
    assert.notDeepEqual([dprResize.width, dprResize.height], [canvasBeforeDpr.width, canvasBeforeDpr.height],
      'изменение DPR меняет физический размер Canvas при прежнем CSS-размере');
    assert.deepEqual(await motionPage.evaluate(() => window.__tgFlowTestMetrics.canvasBackingWrites.map(write => write.name)),
      ['width', 'height'], 'новый DPR обновляет оба изменившихся физических размера');
    assert.equal(await canvas.evaluate(node => node.getContext('2d').getImageData(1, 1, 1, 1).data[3]), 255,
      'после CSS resize и изменения DPR схема снова полностью отрисована');
    await dprSession.send('Emulation.setDeviceMetricsOverride', {
      width: 1280, height: 900, deviceScaleFactor: 1, mobile: false,
    });
    await dprSession.detach();
    await canvas.evaluate(node => { node.style.width = ''; window.dispatchEvent(new Event('resize')); });
    await motionPage.waitForTimeout(50);
    await motionPage.evaluate(() => {
      const metrics = window.__tgFlowTestMetrics;
      metrics.canvasBackingWrites.length = 0;
      metrics.canvasContextReads = 0;
      metrics.canvasContextChanges = 0;
      metrics.canvasRemovals = 0;
    });

    await refreshRoute(routeScenario({
      direct: { state: 'failed', transport: 'direct_wss' },
      fallback: { state: 'failed', transport: 'cloudflare_proxy' }, selected: null,
      events: [routeEvent(51, 'direct_wss', 'failed'), routeEvent(52, 'cloudflare_proxy', 'failed')],
    }), 'маршрут недоступен');
    assert.equal(await flow.getAttribute('data-state'), 'unavailable',
      'отказы всех попыток показываются без вымышленного успеха');

    failStatsApi = true;
    await motionPage.locator('#tg-stats-refresh').click();
    await motionPage.waitForFunction(() => document.querySelector('#tg-flow-caption')?.textContent.includes('Статистика маршрутов недоступна'));
    assert.equal(await motionPage.locator('#tg-active-route').innerText(), 'Недоступно',
      'потеря API помечает транспорт недоступным');
    assert.match(await caption.innerText(), /статистика маршрутов недоступна/i,
      'потеря API немедленно очищает выбранный маршрут');
    failStatsApi = false;

    await refreshRoute(routeScenario({
      direct: { state: 'selected', transport: 'direct_wss' }, selected: 'direct_wss',
      events: [routeEvent(1, 'direct_wss', 'selected')], processStartedAt: tgCheckedAt + 1, accepted: 1,
    }), 'Прямой WSS');
    assert.match(await canvas.getAttribute('aria-label'), /Прямой WSS/,
      'после рестарта процесса читается только новая сессия');

    tgStatsResponse = routeScenario({ active: 0, accepted: 26, events: [] });
    await motionPage.locator('#tg-stats-refresh').click();
    await motionPage.waitForFunction(() => document.querySelector('#tg-flow')?.dataset.state === 'idle');
    assert.match(await caption.innerText(), /Нет активных соединений/,
      'нулевые соединения оставляют схему в простое');

    tgStatsResponse = directRoute();
    await motionPage.locator('#tg-disable').click();
    await motionPage.waitForFunction(() => document.querySelector('#tg-state-badge')?.textContent === 'Остановлен');
    await motionPage.locator('#tg-stats-refresh').click();
    await motionPage.waitForFunction(() => document.querySelector('#tg-flow')?.dataset.state === 'idle');
    assert.equal(await motionPage.locator('#tg-disable').isDisabled(), true,
      'после остановки действие отключения недоступно');
    await motionPage.locator('#tg-enable').click();
    await motionPage.waitForFunction(() => document.querySelector('#tg-state-badge')?.textContent === 'Включён');
    await motionPage.locator('#tg-stats-refresh').click();
    await motionPage.waitForFunction(() => document.querySelector('#tg-flow')?.dataset.state === 'active');
    assert.equal(await motionPage.locator('#tg-enable').isDisabled(), true,
      'после запуска действие включения недоступно');

    await motionPage.evaluate(() => { location.hash = '#/dashboard'; });
    await waitForRenderedRoute(motionPage, 'dashboard');
    await motionPage.evaluate(() => { location.hash = '#/toggles'; });
    await waitForRenderedRoute(motionPage, 'toggles');
    await motionPage.waitForFunction(() => document.querySelectorAll('#tg-flow-canvas').length === 1);
    assert.equal(await motionPage.locator('#tg-flow-canvas').count(), 1,
      'быстрая смена вкладки не оставляет дубликаты схемы');

    const disclosurePage = await browser.newPage({ viewport: { width: 1280, height: 900 }, colorScheme: 'dark' });
    await disclosurePage.addInitScript(() => localStorage.setItem('z2k-theme', 'dark'));
    const disclosureRoutes = ['credits', 'diag', 'state', 'pick', 'tiktok', 'toggles', 'dashboard', 'warp'];
    const disclosureVariants = new Set();
    disclosurePickFixture = true;
    for (const route of disclosureRoutes) {
      await disclosurePage.goto(`${base}/#/${route}`);
      await waitForRenderedRoute(disclosurePage, route);
      if (route === 'diag') {
        await disclosurePage.locator('#probe-domain').fill('example.test');
        await disclosurePage.locator('#probe-run').click();
        await disclosurePage.locator('#probe-result details.probe-raw').waitFor({ state: 'attached' });
      }
      if (route === 'pick') {
        await disclosurePage.locator('#pick-result details.probe-raw').waitFor({ state: 'attached' });
      }
      const report = await disclosurePage.evaluate(() => ({
        page: document.body.dataset.page,
        details: [...document.querySelectorAll('#app details')].map(details => {
          const summary = details.querySelector(':scope > summary');
          const body = [...details.children].find(child => child !== summary);
          const style = summary ? getComputedStyle(summary) : null;
          const variants = ['card', 'compact', 'inline'].filter(name => details.classList.contains(`disclosure-${name}`));
          return {
            variants,
            baseClass: details.classList.contains('disclosure'),
            summary: Boolean(summary),
            label: Boolean(summary?.querySelector(':scope > .disclosure-label')),
            chevron: Boolean(summary?.querySelector(':scope > .disclosure-chevron > svg.icon')),
            marker: style ? style.listStyleType : '',
            userSelect: style?.userSelect || '',
            bodyOverflow: body ? getComputedStyle(body).overflow : '',
            bodyUserSelect: body ? getComputedStyle(body).userSelect : '',
          };
        }),
        overflow: document.documentElement.scrollWidth <= document.documentElement.clientWidth,
      }));
      for (const [index, detail] of report.details.entries()) {
        assert.equal(detail.baseClass, true, `${route}/${index}: общий класс раскрытия назначен`);
        assert.equal(detail.variants.length, 1, `${route}/${index}: ровно один общий вариант (${JSON.stringify(detail.variants)})`);
        assert.equal(detail.summary, true, `${route}/${index}: сохранён прямой summary`);
        assert.equal(detail.label, true, `${route}/${index}: заголовок имеет общий контейнер`);
        assert.equal(detail.chevron, true, `${route}/${index}: используется общий SVG-шеврон`);
        assert.equal(detail.marker, 'none', `${route}/${index}: нативный маркер скрыт`);
        assert.equal(detail.userSelect, 'none', `${route}/${index}: заголовок не выделяется как текст`);
        assert.notEqual(detail.bodyOverflow, 'hidden', `${route}/${index}: содержимое не обрезается`);
        assert.equal(detail.bodyUserSelect, 'text', `${route}/${index}: содержимое остаётся выделяемым`);
        disclosureVariants.add(detail.variants[0]);
      }
      assert.equal(report.overflow, true, `${route}: нет горизонтального переполнения страницы`);
      if (screenshotDir && route === 'credits') {
        await disclosurePage.locator('#credits-upstream').screenshot({ path: path.join(screenshotDir, 'disclosure-inline-closed.png') });
        const summary = disclosurePage.locator('#credits-upstream > summary');
        await summary.click();
        await waitForDisclosureSettled(disclosurePage, '#credits-upstream');
        await disclosurePage.locator('#credits-upstream').screenshot({ path: path.join(screenshotDir, 'disclosure-inline-open.png') });
        await summary.click();
        await waitForDisclosureSettled(disclosurePage, '#credits-upstream');
      }
      if (screenshotDir && route === 'state') {
        const summary = disclosurePage.locator('#app details.state-voice > summary');
        await disclosurePage.locator('#app details.state-voice').screenshot({ path: path.join(screenshotDir, 'disclosure-card-and-inline.png') });
        await disclosurePage.locator('#app details.state-help').screenshot({ path: path.join(screenshotDir, 'disclosure-help-inline.png') });
        await summary.click();
        await waitForDisclosureSettled(disclosurePage, '#app details.state-voice');
        await disclosurePage.locator('#app details.state-voice').screenshot({ path: path.join(screenshotDir, 'disclosure-card-open.png') });
        await summary.click();
        await waitForDisclosureSettled(disclosurePage, '#app details.state-voice');
      }
      if (screenshotDir && route === 'diag') {
        const summary = disclosurePage.locator('#probe-result details.probe-raw > summary');
        await summary.click();
        await waitForDisclosureSettled(disclosurePage, '#probe-result details.probe-raw');
        await disclosurePage.locator('#probe-result details.probe-raw').screenshot({ path: path.join(screenshotDir, 'disclosure-raw-details-open.png') });
      }
    }
    disclosurePickFixture = false;
    assert.ok(disclosureVariants.has('card') && disclosureVariants.has('inline'),
      'remaining disclosure layouts keep the shared card and inline variants');

    await disclosurePage.goto(`${base}/#/toggles`);
    await waitForRenderedRoute(disclosurePage, 'toggles');
    const primaryDisclosure = disclosurePage.locator('#tg-advanced-settings');
    const primarySummary = primaryDisclosure.locator(':scope > summary');
    await primarySummary.click();
    await waitForDisclosureSettled(disclosurePage, '#tg-advanced-settings');
    assert.equal(await primaryDisclosure.evaluate(node => node.open), true, 'Enter/Space сохраняют нативное открытие секции');
    await disclosurePage.keyboard.press('Enter');
    await disclosurePage.waitForFunction(() => !document.querySelector('#tg-advanced-settings')?.open);
    await disclosurePage.keyboard.press('Space');
    await disclosurePage.waitForFunction(() => document.querySelector('#tg-advanced-settings')?.open);
    await disclosurePage.evaluate(() => {
      const summary = document.querySelector('#tg-advanced-settings > summary');
      for (let index = 0; index < 10; index += 1) summary.click();
    });
    await waitForDisclosureSettled(disclosurePage, '#tg-advanced-settings');
    const settledDisclosure = await primaryDisclosure.evaluate(details => ({
      open: details.open,
      expanded: details.querySelector(':scope > summary').getAttribute('aria-expanded'),
      temporaryStyles: [...details.children].filter(child => child.tagName !== 'SUMMARY')
        .some(child => child.style.height || child.style.overflow || child.style.opacity || child.style.transform),
    }));
    assert.deepEqual(settledDisclosure, { open: true, expanded: 'true', temporaryStyles: false },
      '10 быстрых переключений завершаются в согласованном состоянии без inline-остатков');
    await disclosurePage.keyboard.press('Tab');
    await primarySummary.evaluate(summary => summary.focus());
    const focusVisible = await primarySummary.evaluate(summary => ({
      matches: summary.matches(':focus-visible'), outline: getComputedStyle(summary).outlineStyle,
    }));
    assert.deepEqual(focusVisible, { matches: true, outline: 'solid' },
      'клавиатурный фокус виден на строке заголовка');
    await disclosurePage.emulateMedia({ reducedMotion: 'reduce' });
    await primarySummary.click();
    await disclosurePage.waitForFunction(() => !document.querySelector('#tg-advanced-settings')?.open);
    assert.equal(await primaryDisclosure.evaluate(details => details.getAnimations().length), 0,
      'reduced motion отключает переход раскрытия');
    await disclosurePage.close();

    const routeVideoPage = await browser.newPage({
      viewport: { width: 1280, height: 900 }, colorScheme: 'dark',
      recordVideo: { dir: videoDir, size: { width: 1280, height: 900 } },
    });
    const routeVideo = routeVideoPage.video();
    await routeVideoPage.addInitScript(() => {
      localStorage.setItem('z2k-theme', 'dark');
      localStorage.setItem('z2k-sidebar', 'expanded');
    });
    await routeVideoPage.goto(`${base}/#/state`);
    await waitForRenderedRoute(routeVideoPage, 'state');
    await routeVideoPage.waitForTimeout(350);
    await routeVideoPage.evaluate(() => {
      window.__routeExitSamples = [];
      window.__routeEnterSamples = [];
      window.__routeApp = document.querySelector('#app');
      window.__routeOutgoingCard = document.querySelector('#app > .card');
      const sample = () => {
        const app = window.__routeApp;
        const card = window.__routeOutgoingCard;
        if (app) {
          const style = getComputedStyle(app);
          const matrix = new DOMMatrixReadOnly(style.transform);
          const current = { connected: card?.isConnected ?? false,
            opacity: Number(style.opacity), y: matrix.m42 };
          if (card?.isConnected) {
            const cardStyle = getComputedStyle(card);
            current.cardOpacity = Number(cardStyle.opacity);
            current.cardTransform = cardStyle.transform;
            window.__routeExitSamples.push(current);
          } else if (document.body.dataset.page === 'toggles') {
            window.__routeEnterSamples.push(current);
          }
        }
        if (window.__routeExitSamples.length < 60) requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
      document.querySelector('#nav a[data-route="toggles"]').click();
    });
    await routeVideoPage.waitForTimeout(80);
    const routeExit = await routeVideoPage.evaluate(() => ({
      samples: window.__routeExitSamples,
      outgoingConnected: window.__routeOutgoingCard.isConnected,
    }));
    assert.ok(routeExit.samples.some(sample => sample.connected
      && sample.opacity > 0 && sample.opacity < 0.98 && sample.y < 0),
    'старый экран плавно выходит до подмены содержимого вкладки');
    assert.ok(routeExit.samples.every(sample => sample.cardOpacity === 1
      && sample.cardTransform === 'none'),
    'карточки не двигаются отдельно от слоя страницы');
    assert.equal(routeExit.outgoingConnected, true, 'старая вкладка остаётся на месте во время выхода');
    await waitForRenderedRoute(routeVideoPage, 'toggles');
    await routeVideoPage.waitForTimeout(300);
    assert.ok(await routeVideoPage.evaluate(() => window.__routeEnterSamples.some(sample =>
      sample.opacity > 0 && sample.opacity < 0.98 && sample.y > 0)),
    'новая вкладка входит единым слоем');
    assert.equal(await routeVideoPage.evaluate(() => !window.__routeOutgoingCard.isConnected), true,
      'после выхода старая вкладка удаляется');
    assert.equal(await routeVideoPage.locator('#nav a[data-route="toggles"]').getAttribute('class')
      .then(value => value.includes('active')), true, 'индикатор следует за выбранной вкладкой');
    await routeVideoPage.evaluate(() => {
      window.__routeGeometrySamples = [];
      window.__captureRouteGeometry = true;
      const sample = () => {
        if (!window.__captureRouteGeometry) return;
        const box = selector => {
          const element = document.querySelector(selector);
          if (!element) return null;
          const rect = element.getBoundingClientRect();
          return { left: rect.left, top: rect.top, right: rect.right, bottom: rect.bottom,
            width: rect.width, height: rect.height, transform: getComputedStyle(element).transform };
        };
        const tabs = document.querySelector('.strat-tabs');
        const active = tabs?.querySelector('.strat-tab.active, .strat-tab[aria-selected="true"]');
        const targetLeft = tabs && active ? active.offsetLeft - tabs.scrollLeft : null;
        const indicatorLeft = tabs ? Number.parseFloat(tabs.style.getPropertyValue('--tab-left')) : null;
        window.__routeGeometrySamples.push({
          nav: box('#nav'), topbar: box('.topbar'), app: box('#app'),
          indicator: tabs && active ? { targetLeft, indicatorLeft } : null,
          horizontalOverflow: document.documentElement.scrollWidth > document.documentElement.clientWidth,
        });
        requestAnimationFrame(sample);
      };
      requestAnimationFrame(sample);
    });
    for (let cycle = 0; cycle < 30; cycle += 1) {
      for (const route of ['pick', 'dashboard', 'state', 'toggles']) {
        await routeVideoPage.evaluate(name => { location.hash = `#/${name}`; }, route);
        await waitForRenderedRoute(routeVideoPage, route);
      }
    }
    await routeVideoPage.evaluate(() => {
      for (const route of ['dashboard', 'state', 'pick', 'toggles']) {
        history.replaceState(null, '', `#/${route}`);
        window.dispatchEvent(new HashChangeEvent('hashchange'));
      }
    });
    await waitForRenderedRoute(routeVideoPage, 'toggles');
    await waitForGsapSettled(routeVideoPage, ['#app', '#app .page-title', '#app > .card', '.strat-tabs']);
    await routeVideoPage.waitForTimeout(500);
    const routeGeometry = await routeVideoPage.evaluate(() => {
      window.__captureRouteGeometry = false;
      const samples = window.__routeGeometrySamples;
      const shell = key => samples.map(sample => sample[key]).filter(Boolean);
      return {
        sampleCount: samples.length,
        nav: shell('nav'), topbar: shell('topbar'), app: shell('app'),
        indicators: samples.map(sample => sample.indicator).filter(Boolean),
        horizontalOverflow: samples.some(sample => sample.horizontalOverflow),
        finalHash: location.hash,
        finalPage: document.body.dataset.page,
        activeTweens: window.gsap
          ? window.gsap.getTweensOf([document.querySelector('#app'), ...document.querySelectorAll('#app *')])
            .filter(tween => tween.isActive()).length : 0,
      };
    });
    assert.ok(routeGeometry.sampleCount > 250, `30 циклов снимают геометрию по кадрам (${routeGeometry.sampleCount})`);
    for (const [name, boxes] of [['#nav', routeGeometry.nav], ['topbar', routeGeometry.topbar]]) {
      const baseline = boxes[0];
      assert.ok(boxes.every(box => ['left', 'top', 'right', 'bottom', 'width', 'height']
        .every(key => Math.abs(box[key] - baseline[key]) <= 1)),
      `${name}: границы shell стабильны на каждом кадре навигации`);
      assert.ok(boxes.every(box => box.transform === baseline.transform),
        `${name}: маршрут не двигает shell через transform`);
    }
    assert.ok(routeGeometry.app.every(box => Math.abs(box.left - routeGeometry.app[0].left) <= 1
      && Math.abs(box.top - routeGeometry.app[0].top) <= 9),
    '#app перемещается только на короткую дистанцию перехода, без скачков');
    assert.ok(routeGeometry.indicators.every(item => Math.abs(item.targetLeft - item.indicatorLeft) <= 1),
      'индикатор стратегии всегда совпадает с активной вкладкой текущего DOM');
    assert.equal(routeGeometry.horizontalOverflow, false, 'переходы не создают горизонтальное переполнение');
    assert.equal(routeGeometry.finalHash, '#/toggles', 'серия быстрых переходов сохраняет последний hash');
    assert.equal(routeGeometry.finalPage, 'toggles', 'серия быстрых переходов показывает последний маршрут');
    assert.equal(routeGeometry.activeTweens, 0, 'после цикла не остаются активные tween для #app');
    if (screenshotDir) {
      await routeVideoPage.screenshot({ path: path.join(screenshotDir, 'navigation-30-cycles-after.png'), fullPage: true });
    }
    await routeVideoPage.close();
    fs.copyFileSync(await routeVideo.path(), path.join(videoDir, 'navigation-30-cycles.webm'));

    tgRunningFixture = true;
    if (screenshotDir) {
      await motionPage.locator('#tg-flow-canvas').scrollIntoViewIfNeeded();
      await waitForNavSettled(motionPage);
      await screenshotComponent(motionPage, card, path.join(screenshotDir, 'telegram-canvas-stable-after.png'));
    }
    await motionPage.waitForTimeout(30000);
    await motionPage.close();
    fs.copyFileSync(await telegramVideo.path(), path.join(videoDir, 'telegram-polling-30s.webm'));
  }
  if (shellOnly) {
    console.log('PASS: shell layout, navigation, collapse/expand, delayed branding, polling, and disclosure motion');
  } else if (switchOnly) {
    console.log('PASS: изолированная Playwright-матрица переключателей');
  } else if (!motionOnly) {
    // A genuinely broken required module graph receives a visible failure state.
    const broken = await browser.newPage();
    await broken.route('**/js/pages/dashboard.js*', route => route.abort('failed'));
    await broken.goto(`${base}/#/dashboard`);
    await broken.locator('#app [data-ui-fatal]').waitFor({ state: 'visible', timeout: 2000 });
    assert.match(await broken.locator('#app').innerText(), /Не удалось загрузить интерфейс/);

    console.log(`PASS: real browser OpenWrt document root; ${testedRouteCount} routes in dark/light; one-brand, contrast, keyboard, responsive, blocker, and broken-module cases; ${totalModuleResponses} module responses`);
  } else {
    console.log('PASS: focused motion regression block; Telegram, route transitions, and disclosures');
  }
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(root, { recursive: true, force: true });
}
