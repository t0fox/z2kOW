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
const screenshotPrefix = process.env.OPENWRT_SCREENSHOT_PREFIX
  ? `${process.env.OPENWRT_SCREENSHOT_PREFIX}-` : '';
const tgScreenshotOnly = process.env.OPENWRT_TG_SCREENSHOT_ONLY === '1';
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'z2k-openwrt-browser-'));
const www = path.join(root, 'www');
fs.cpSync(path.join(repo, 'webpanel/www'), www, { recursive: true });
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
const pendingStatusResponses = [];
const statusFixture = {
  ok: true, installed: 'p-86.1', running: true, service: 'active', platform: 'openwrt',
  toggles: {
    game_warp: '0', customd: '0', dynamic_ttl: '1',
    ppe: '1', auto_update: '1', autohostlist: '0', fastroute: '0',
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
const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', 'http://127.0.0.1');
  if (url.pathname.startsWith('/cgi-bin/api/')) {
    const endpoint = url.pathname.slice('/cgi-bin/api/'.length);
    const apiRequest = { endpoint, method: req.method, marker: req.headers['x-z2k-panel'] || '',
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
        res.end(JSON.stringify(statusFixture));
      }
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
      : endpoint === 'tunnel/stats' ? tgStatsResponse
      : endpoint === 'state'
      ? { ok: true, entries: stateEntries }
      : endpoint === 'pools'
        ? { ok: true, pools: { tcp: 4, quic: 4 } }
        : endpoint === 'strategy/pools'
          ? { ok: true, pools: [{ pool: 'tcp', custom: 0, line: '' }, { pool: 'quic', custom: 0, line: '' }] }
          : endpoint === 'strategy/unique-set'
            ? { ok: true, result: null }
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
        : endpoint === 'dns/check' && req.method === 'GET'
          ? { ok: true, own: '1.1.1.1\nhttps://dns.example.test/dns-query', result: {
            intercept: true, intercept_by: 'router', stub: '198.18.0.1', servers: [
              { name: 'Resolver A', udp: 'works', udp_ms: 18, doh: 'spoof', doh_ms: 74,
                dot: 'silent', dot_ms: null, current: true, yt: 'empty' },
              { name: 'Resolver B', udp: 'silent', udp_ms: null, doh: 'works', doh_ms: 25,
                dot: 'spoof', dot_ms: 97, current: false, yt: '' },
            ],
          } }
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
      && getComputedStyle(node).visibility !== "hidden"), null, { timeout: 2000 });
  await page.waitForFunction(name => {
    const app = document.querySelector("#app");
    const content = app ? app.innerText.trim() : "";
    return document.body.getAttribute("data-page") === name
      && content.length > 0 && content !== "Загрузка…";
  }, route, { timeout: 2000 });
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
  await waitForGsapSettled(page, ['#nav a', '#nav .nav-active-indicator']);
}

async function waitForGsapSettled(page, selectors) {
  await page.waitForFunction(targetSelectors => {
    if (!window.gsap) return true;
    const targets = targetSelectors.flatMap(selector => [...document.querySelectorAll(selector)]);
    return targets.every(target => window.gsap.getTweensOf(target).every(tween => !tween.isActive()));
  }, selectors, { timeout: 1500 });
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

async function assertDiagDynamicStates(page, label, viewport = '1440') {
  if (await page.locator('#dns-result').count()) {
  await page.locator('#dns-result details.dns-group').first().waitFor({ state: 'attached' });
  const groups = page.locator('#dns-result details.dns-group');
  assert.equal(await groups.count(), 3, `${label}: previous DNS result renders all three paths`);
  assert.deepEqual(await page.locator('#dns-result .dns-path').allTextContents(),
    ['Обычный DNS', 'Шифрованный DoH', 'Шифрованный DoT'],
    `${label}: DNS paths remain separately discoverable`);
  assert.ok(await groups.evaluateAll(nodes => nodes.every(node => !node.open)),
    `${label}: DNS result groups start collapsed`);
  await groups.nth(0).locator('summary').click();
  await groups.nth(1).locator('summary').click();
  await groups.nth(2).locator('summary').click();
  const dnsState = await groups.evaluateAll(nodes => nodes.map(node => ({
    path: node.querySelector('.dns-path')?.textContent.trim(),
    open: node.open,
    note: node.querySelector('.dns-count')?.textContent.trim(),
    tally: node.querySelector('.dns-tally')?.textContent.trim(),
    tallyClass: node.querySelector('.dns-tally')?.className,
    rows: Array.from(node.querySelectorAll('li')).map(row => ({
      name: row.querySelector('span')?.textContent.trim(),
      state: row.querySelector('.dns-state')?.textContent.trim(),
      stateClass: row.querySelector('.dns-state')?.className,
      current: row.querySelector('.dns-cur')?.textContent.trim() || '',
      youtube: row.querySelector('.dns-yt')?.textContent.trim() || '',
    })),
  })));
  assert.ok(dnsState.every(group => group.open && group.rows.length === 2),
    `${label}: each expanded DNS path shows both fixture servers (${JSON.stringify(dnsState)})`);
  assert.deepEqual(dnsState.map(group => group.tally), [
    '1 целых · 1 без ответа', '1 целых · 1 подменено', '1 подменено · 1 без ответа',
  ], `${label}: path summaries count working, substituted and silent responses (${JSON.stringify(dnsState)})`);
  assert.deepEqual(dnsState.map(group => group.tallyClass), [
    'dns-tally dns-good', 'dns-tally dns-bad', 'dns-tally dns-bad',
  ]);
  assert.match(dnsState[0].note, /порт 53 завёрнут роутером.*заглушка 198\.18\.0\.1/);
  assert.ok(dnsState.every(group => group.rows.some(row => row.name.includes('Resolver A')
    && row.current === 'используется сейчас' && row.youtube === 'нет адреса для youtube.com')),
  `${label}: current resolver and missing YouTube address tags appear on each path`);
  assert.match(dnsState[0].rows[0].state, /честно 18 мс/);
  assert.match(dnsState[1].rows[0].state, /ответ подменён 74 мс/);
  assert.match(dnsState[2].rows[1].state, /ответ подменён 97 мс/);
  assert.equal(await page.locator('#dns-own-text').inputValue(),
    '1.1.1.1\nhttps://dns.example.test/dns-query', `${label}: custom resolver text is restored`);

  }
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
    if (viewport !== '390' && await page.locator('#dns-result').count()) {
      await page.locator('#dns-result').screenshot({
        path: path.join(screenshotDir, `${screenshotBase}-dns-results.png`),
      });
    }
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

try {
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

  const routes = ['dashboard', 'toggles', 'tiktok', 'dns', 'strategies', 'warp', 'whitelist', 'exclude', 'extra-domains', 'diag', 'credits', 'state', 'pick', 'autohostlist'];
  const primaryRoutes = ['dashboard', 'toggles', 'tiktok', 'dns', 'state', 'warp', 'whitelist', 'extra-domains', 'diag', 'credits'];
  const screenshotRoutes = ['dashboard', 'toggles', 'strategies', 'warp', 'whitelist', 'exclude',
    'extra-domains', 'diag', 'tiktok', 'dns', 'credits', 'state', 'pick', 'autohostlist'];
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
  let totalModuleResponses = 0;

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
    assert.equal(await page.evaluate(() => window.gsap?.version || ''), '3.15.0',
      `${appearance}: локальный GSAP загружается до модулей приложения`);
    assert.ok(moduleResponses.some(response => new URL(response.url).pathname.endsWith('/assets/vendor/gsap.js')
      && response.status === 200), `${appearance}: GSAP загружается с адреса локальной панели`);
    assert.equal(await page.evaluate(() => document.documentElement.classList.contains('motion-ready')),
      true, `${appearance}: общий модуль GSAP управляет анимацией интерфейса`);
    assert.equal(await page.locator('#sidebar-collapse').evaluate(button =>
      getComputedStyle(button).transitionDuration.split(',').every(value => parseFloat(value) === 0)),
    true, `${appearance}: CSS-переходы выключены, когда анимацией управляет GSAP`);
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
      const { motion } = await import('/js/motion.js');
      return { navDuration: nav.transitionDuration, appDuration: app.transitionDuration,
        appTransition: app.transitionProperty, shellDuration: motion.timing.duration.shell };
    });
    assert.equal(shellMotion.navDuration, '0s', 'анимацией боковой панели управляет GSAP');
    assert.equal(shellMotion.appDuration, '0s', 'анимацией содержимого управляет GSAP');
    assert.equal(shellMotion.appTransition, 'none');
    assert.equal(shellMotion.shellDuration, 0.3, 'общая длительность анимации каркаса — 300 мс');
    assert.ok(await page.locator('#app').evaluate(node => node.getBoundingClientRect().width === 800),
      'all desktop routes use the reference 800 px content column');
    const sidebarCollapse = page.locator('#sidebar-collapse');
    await sidebarCollapse.click();
    await page.waitForFunction(() => document.body.dataset.sidebar === 'collapsed'
      && Math.abs(document.querySelector('#nav').getBoundingClientRect().width - 72) < 0.5
      && Math.abs(document.querySelector('#app').getBoundingClientRect().x - (innerWidth / 2 - 356.5)) < 1);
    await waitForGsapSettled(page, ['#nav', 'body', '#sidebar-collapse .nav-ico']);
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
    assert.ok(Math.abs(collapsedFrame.appX - (collapsedFrame.windowWidth / 2 - 356.5)) < 1,
      `${appearance}: main column recenters with the compact rail (${JSON.stringify(collapsedFrame)})`);
    assert.equal(collapsedFrame.appWidth, 800, `${appearance}: collapse preserves the desktop content width`);
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
    await waitForGsapSettled(page, ['#nav', 'body', '#sidebar-collapse .nav-ico']);
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
        assert.deepEqual([popupGeometry.xOffset, popupGeometry.widthDelta], [0, 0],
          `the Lolz dropdown aligns to its trigger on the same x-axis and width (${JSON.stringify(popupGeometry)})`);
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
        assert.equal(fieldStyle.height, 30, 'Lolz text controls use a compact 30 px field height');
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
      if (route === 'dns') {
        const editorStyle = await page.locator('#dns-own-text').evaluate(node => {
          const style = getComputedStyle(node);
          return { borderWidth: style.borderTopWidth, radius: style.borderRadius,
            background: style.backgroundColor, minHeight: style.minHeight };
        });
        assert.equal(editorStyle.borderWidth, '0px', 'specialized text editors keep Lolz borderless controls');
        assert.equal(editorStyle.radius, '10px', 'specialized text editors use the reference radius');
        assert.equal(editorStyle.background, appearance === 'dark'
          ? 'rgb(24, 30, 28)' : 'rgb(234, 241, 239)', 'specialized text editors use the theme control surface');
        assert.equal(editorStyle.minHeight, '76px', 'the diagnostics editor retains its task-specific working area');
      }
      if (route === 'diag') {
        assert.equal(await page.locator('#dns-run, #doh-card').count(), 0,
          'Diagnostics has no duplicate DNS controls');
        const logViewport = await page.locator('#diag-output').evaluate(node => ({
          height: node.clientHeight, scrollHeight: node.scrollHeight,
          overflowY: getComputedStyle(node).overflowY,
        }));
        assert.ok(logViewport.scrollHeight > logViewport.height && logViewport.overflowY === 'auto',
          `long diagnostic output stays inside its own scroll container (${JSON.stringify(logViewport)})`);
        await assertDiagDynamicStates(page, appearance);
      }
      if (route === 'dns') {
        assert.deepEqual(await page.locator('#dns-protocol option').evaluateAll(options => options.map(option => option.value)),
          ['doh', 'doh3', 'dot', 'doq', 'dnscrypt']);
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
    assert.equal(await telegramCard.isVisible(), true, `${appearance}: Telegram card is visible`);
    await page.waitForFunction(() => document.querySelector('#tg-route-scheme')?.dataset.state === 'active');
    const routeScheme = page.locator('#tg-route-scheme');
    assert.equal(await routeScheme.locator('[data-route-branch="direct"]').first().getAttribute('data-active'), 'true',
      `${appearance}: the active direct WSS path follows live session telemetry`);
    assert.equal(await routeScheme.locator('[data-route-branch="fallback"]').first().getAttribute('data-active'), 'false',
      `${appearance}: the unused fallback path remains quiet`);
    assert.match(await routeScheme.locator('#tg-route-caption').innerText(), /Прямой WSS.*5 активных соединений/,
      `${appearance}: the diagram describes the live transport and connection count`);
    assert.doesNotMatch(await routeScheme.innerText(), /resPQ.*подтверждён/i,
      `${appearance}: a live WSS path does not claim Telegram resPQ confirmation`);
    assert.doesNotMatch(await routeScheme.innerText(), /transparent redirect|DC map\s*·\s*route selection/i,
      `${appearance}: diagram annotations follow the Russian panel language`);
    assert.equal(await routeScheme.locator('button, select, input').count(), 0,
      `${appearance}: the route diagram has no scenario controls`);
    const routePulse = await routeScheme.evaluate(node => {
      const ring = node.querySelector('.tg-route-svg--desktop [data-route-branch="direct"] .tg-route-live-ring');
      const ringBox = ring.getBoundingClientRect();
      const branchBox = ring.parentElement.querySelector('.tg-route-branch-node').getBoundingClientRect();
      return {
        looping: window.gsap.getTweensOf(ring).some(tween => tween.repeat() === -1),
        visible: ringBox.right <= branchBox.left || ringBox.left >= branchBox.right
          || ringBox.bottom <= branchBox.top || ringBox.top >= branchBox.bottom,
      };
    });
    assert.equal(routePulse.looping, true, `${appearance}: an active route keeps a continuous loop`);
    assert.equal(routePulse.visible, true, `${appearance}: the route pulse is visible beyond the branch node`);
    const routeColors = await routeScheme.evaluate(node => {
      const probe = document.createElement('span');
      probe.style.borderColor = 'var(--ow-border-subtle, var(--border))';
      document.body.appendChild(probe);
      const result = { diagram: getComputedStyle(node).borderColor, lolzTheme: getComputedStyle(probe).borderColor };
      probe.remove();
      return result;
    });
    assert.equal(routeColors.diagram, routeColors.lolzTheme,
      `${appearance}: route scheme uses the active Lolzteam theme border token`);
    await page.locator('#tg-openwrt-tools').waitFor({ state: 'visible' });
    await page.waitForFunction(() => document.querySelector('#tg-runtime-details')?.textContent
      && document.querySelector('#tg-check-results')?.textContent.trim());
    if (await page.locator('body').getAttribute('data-sidebar') === 'collapsed') {
      await page.locator('#sidebar-collapse').click();
      await page.waitForFunction(() => document.body.getAttribute('data-sidebar') === null);
    }
    for (const width of [1440, 1280, 768, 390, 375, 320]) {
      await page.setViewportSize({ width, height: width < 500 ? 844 : 900 });
      await waitForGsapSettled(page, ['#app > .card', '.page-title']);
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
      assert.equal(await routeScheme.locator('.tg-route-svg--mobile').first().evaluate(node => getComputedStyle(node).display !== 'none'),
        width <= 900, `${appearance}/${width}: compact schematic switches layout at the panel breakpoint`);
      await page.waitForFunction(() => document.querySelector('.tg-summary-grid')
        && document.querySelectorAll('#tg-check-results .tg-dc-row').length === 5, null, { timeout: 1200 });
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
      for (const label of ['Активные соединения', 'Сессии с ответом', 'Память процесса', 'Карта DC']) {
        assert.ok(overviewText.includes(label), `${appearance}/${width}: compact stats expose ${label}`);
      }
      assert.ok(overviewText.includes('не подтверждает resPQ'),
        `${appearance}/${width}: traffic counters are distinct from a resPQ check`);
      assert.doesNotMatch(overviewText, /dc203:cf-proxy|http_503|generation/,
        `${appearance}/${width}: raw technical keys stay in the closed disclosure`);
      await runtimeTechnical.locator('summary').click();
      assert.equal(await runtimeTechnical.getAttribute('open'), '', `${appearance}/${width}: technical stats expand`);
      const technicalText = await runtimeTechnical.innerText();
      for (const value of ['dc203:cf-proxy', 'http_503', 'generation', 'Накопленная статистика процесса']) {
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
    }

    const savedTgStats = tgStatsResponse;
    tgStatsResponse = { ...tgStatsFixture, active_connections: 0, active_sessions: [] };
    await page.evaluate(() => { location.hash = '#/dashboard'; });
    await waitForRenderedRoute(page, 'dashboard');
    await page.evaluate(() => { location.hash = '#/toggles'; });
    await waitForRenderedRoute(page, 'toggles');
    await page.waitForFunction(() => document.querySelector('#tg-route-scheme')?.dataset.state === 'idle');
    const idleRoute = page.locator('#tg-route-scheme');
    assert.match(await idleRoute.locator('#tg-route-caption').innerText(), /Нет активных соединений/,
      `${appearance}: no connections keep the diagram static and explicit`);
    assert.equal(await idleRoute.locator('[data-route-branch][data-active="true"]').count(), 0,
      `${appearance}: idle telemetry lights no route branch`);
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
  assert.equal(await fullHdShort.locator('#nav').evaluate(node => getComputedStyle(node).transitionDuration), '0s',
    'reduced motion disables desktop rail geometry transitions');
  assert.equal(await fullHdShort.locator('#app').evaluate(node => getComputedStyle(node).transitionDuration), '0s',
    'reduced motion disables desktop content geometry transitions');
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
  await releaseThemeRequest();
  assert.equal(routeRenderedBeforeTheme, true,
    'a slow optional brand theme never blocks the first route render');
  await waitForRenderedRoute(themeSlow, 'dashboard');
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

  const dohPage = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true, colorScheme: 'dark' });
  await dohPage.addInitScript(() => localStorage.setItem('z2k-theme', 'dark'));
  dohPage.on('pageerror', error => allPageErrors.push(error.message));
  let dohStatus = { state: 'not-installed', installed: '0', enabled: '0', provider: 'unknown', protocol: 'doh', actual_protocol: '', local_dns_state: 'unknown', upstream_state: 'unconfirmed', external_config: '0' };
  let dohJobNumber = 0;
  let acceptNextDohConfirm = false;
  let holdNextDohJobResult = false;
  let releaseHeldDohJob = null;
  let dohStatusCalls = 0;
  let autohostlistFixture = '0';
  let tiktokRefreshVersion = 0;
  let failNextDohUninstall = true;
  const failedDohJobIds = new Set();
  let tgRunningFixture = true;
  let tgJobNumber = 0;
  const dohConfirmMessages = [];
  const dohActions = [];
  dohPage.on('dialog', async dialog => {
    dohConfirmMessages.push(dialog.message());
    if (acceptNextDohConfirm) {
      acceptNextDohConfirm = false;
      await dialog.accept();
    } else {
      await dialog.dismiss();
    }
  });
  dohPage.route('**/cgi-bin/api/status', route => {
    dohStatusCalls += 1;
    const fixture = structuredClone(statusFixture);
    fixture.doh = structuredClone(dohStatus);
    fixture.tunnel = { running: tgRunningFixture };
    fixture.toggles.autohostlist = autohostlistFixture;
    fixture.toggles.tiktok_feed = '1';
    fixture.tiktok_feed_status = {
      state: 'healthy', selected_ip: '203.0.113.9', mode: 'auto', candidate_verified: '1',
      dns_override_applied: '1', selected_source_domain: 'www.tiktokcdn.com', candidates: [],
      failure_count: String(tiktokRefreshVersion),
    };
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify(fixture) });
  });
  dohPage.route('**/cgi-bin/api/doh/**', async route => {
    const endpoint = new URL(route.request().url()).pathname.split('/').pop();
    const body = route.request().postDataJSON() || {};
    dohActions.push({ endpoint, body });
    if (endpoint === 'profile') {
      const encodeList = value => Buffer.from(value || '').toString('base64');
      dohStatus = {
        ...dohStatus, state: 'working', installed: '1', enabled: '1', running: '1', provider: 'profile',
        protocol: 'doh', actual_protocol: 'doh', upstream_state: 'confirmed', local_dns_state: 'working',
        endpoint: body.upstreams.split('\n')[0], bootstrap: body.bootstrap, external_config: '0', confirm_remove: '1', reason: '',
        profile_upstreams_b64: encodeList(body.upstreams), profile_fallbacks_b64: encodeList(body.fallbacks),
        profile_routes_b64: encodeList(body.routes), profile_bootstrap_b64: encodeList(body.bootstrap), profile_mode: body.mode,
      };
    }
    if (endpoint === 'install') dohStatus = { ...dohStatus, state: 'disabled', installed: '1', enabled: '0', running: '0', external_config: '0' };
    if (endpoint === 'enable') dohStatus = { ...dohStatus, state: 'working', installed: '1', enabled: '1', running: '1', reason: '' };
    if (endpoint === 'disable') dohStatus = { ...dohStatus, state: 'disabled', installed: '1', enabled: '0', running: '0', reason: '' };
    if (endpoint === 'uninstall') {
      if (failNextDohUninstall) {
        failNextDohUninstall = false;
        failedDohJobIds.add(`doh-fixture-${dohJobNumber + 1}`);
      } else {
        dohStatus = { state: 'not-installed', installed: '0', enabled: '0', provider: 'unknown', external_config: '0', confirm_remove: '0' };
      }
    }
    dohJobNumber += 1;
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, job: `doh-fixture-${dohJobNumber}` }) });
  });
  dohPage.route('**/cgi-bin/api/tunnel/**', route => {
    tgJobNumber += 1;
    return route.fulfill({ status: 200, contentType: 'application/json', body: JSON.stringify({ ok: true, job: `tg-fixture-${tgJobNumber}` }) });
  });
  dohPage.route('**/cgi-bin/api/job**', async route => {
    if (holdNextDohJobResult) {
      holdNextDohJobResult = false;
      await new Promise(resolve => { releaseHeldDohJob = resolve; });
    }
    const jobId = new URL(route.request().url()).searchParams.get('id');
    return route.fulfill({
      status: 200, contentType: 'application/json', body: JSON.stringify({ done: true,
        exit: failedDohJobIds.has(jobId) ? 1 : 0, status: failedDohJobIds.has(jobId) ? 'failed' : 'done',
        log: failedDohJobIds.has(jobId) ? 'DoH: apk del https-dns-proxy завершился ошибкой' : 'ok' }),
    });
  });
  await dohPage.goto(`${base}/#/dns`);
  await waitForRenderedRoute(dohPage, 'dns');
  assert.equal(await dohPage.locator('a[data-route="dns"]').getAttribute('class'), 'active');
  const dohCard = dohPage.locator('#doh-card');
  assert.equal(await dohCard.isVisible(), true, 'DoH controls are shown on OpenWrt');
  try {
    await dohPage.waitForFunction(() => document.querySelector('#doh-status')?.innerText.includes('Статус: Не установлен'));
  } catch (error) {
    throw new Error(`${error.message}; /status calls=${dohStatusCalls}; page errors=${allPageErrors.slice(-5).join(' | ')}`);
  }
  assert.match(await dohCard.innerText(), /Статус: Не установлен/);
  assert.equal(await dohCard.locator('#dns-protocol').inputValue(), 'doh');
  const catalogGroups = await dohCard.locator('#doh-provider optgroup').evaluateAll(groups => groups.map(group => ({
    label: group.label, providers: [...group.querySelectorAll('option')].map(option => option.value),
  })));
  assert.deepEqual(catalogGroups.map(group => group.label), ['Универсальные', 'С фильтрацией', 'Региональные и Smart DNS', 'Персональные'],
    'the catalog groups providers by category');
  assert.ok(catalogGroups.flatMap(group => group.providers).includes('quad9'), 'catalog includes Quad9');
  assert.ok(catalogGroups.flatMap(group => group.providers).includes('google'), 'catalog includes Google Public DNS');
  assert.equal(await dohCard.locator('#doh-provider option[value="custom"]').count(), 1,
    'the custom endpoint remains available outside catalog categories');
  assert.deepEqual(await dohPage.locator('#app h2').allInnerTexts(), ['Настройка', 'Дополнительно', 'Проверка'],
    'DNS is organized into setup, additional controls, and checks');
  await dohCard.locator('#doh-provider').selectOption('quad9');
  assert.equal(await dohCard.locator('#dns-protocol option[value="doq"]').evaluate(option => option.hidden), false,
    'Quad9 exposes its supported DoQ endpoint');
  await dohCard.locator('#doh-provider').selectOption('google');
  assert.equal(await dohPage.locator('#doh-custom-fields').isVisible(), false,
    'catalog entries use their confirmed endpoint without custom fields');
  assert.equal(await dohCard.locator('[data-doh-action]').count(), 1,
    'not-installed state offers only Install');
  assert.equal(await dohCard.locator('#doh-provider-panel').count(), 0,
    'provider controls do not sit in a nested card');
  await dohCard.locator('#doh-provider').selectOption('google');
  await dohCard.locator('#doh-add-upstream').click();
  assert.match(await dohCard.locator('#dns-profile-queue').innerText(), /https:\/\/dns\.google\/dns-query/,
    'adding a catalog choice queues its original domain endpoint');
  assert.equal(dohActions.length, 0, 'choosing or queueing a catalog endpoint does not apply it automatically');

  await dohCard.getByRole('button', { name: 'Установить' }).click();
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-1"] #job-close').waitFor({ state: 'visible' });
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-1"] #job-close').click();
  await dohPage.waitForFunction(() => document.querySelector('#doh-status')?.innerText.includes('Статус: Выключен'));
  assert.deepEqual(await dohCard.locator('[data-doh-action]').evaluateAll(buttons => buttons.map(button => button.dataset.dohAction)),
    ['apply', 'check', 'uninstall'], 'freshly installed DoH offers Apply, Check and Remove until a resolver is configured');
  assert.equal(await dohCard.locator('#doh-force-dns').count(), 0,
    'force DNS is not exposed as an unrelated extra stage');

  dohStatus = {
    ...dohStatus, state: 'disabled', enabled: '0', running: '0', external_config: '1', confirm_remove: '1', package_owner: 'external',
    provider: 'unknown', endpoint: '', profile_upstreams_b64: '', profile_fallbacks_b64: '', profile_routes_b64: '', profile_bootstrap_b64: '', profile_mode: '',
  };
  await dohPage.reload();
  await waitForRenderedRoute(dohPage, 'dns');
  await dohPage.waitForFunction(() => document.querySelector('#doh-ownership-warning')?.hidden === false);
  await dohCard.locator('#doh-provider').selectOption('google');
  await dohCard.locator('#doh-add-upstream').click();
  await dohCard.locator('#doh-provider').selectOption('quad9');
  await dohCard.locator('#dns-protocol').selectOption('doq');
  await dohCard.locator('#doh-upstream-role').selectOption('fallback');
  await dohCard.locator('#doh-add-upstream').click();
  assert.match(await dohCard.locator('#dns-profile-queue').innerText(), /Основные upstream[\s\S]*dns\.google[\s\S]*Аварийный fallback[\s\S]*dns\.quad9/,
    'the profile supports multiple role groups with unchanged domain endpoints');
  await dohPage.locator('#dns-profile-bootstrap').fill('1.1.1.1\n2001:4860:4860::8888');
  await dohPage.locator('#dns-upstream-mode').selectOption('parallel');
  await dohPage.locator('#dns-route-domain').fill('video.example');
  await dohPage.locator('#dns-route-upstream').selectOption('fallbacks:0');
  await dohPage.locator('#dns-route-add').click();
  assert.match(await dohPage.locator('#dns-profile-rules-list').innerText(), /video\.example\s*→\s*quic:\/\/dns\.quad9\.net:853/,
    'доменное правило направляется на выбранный upstream или fallback');
  const profileBody = {
    upstreams: 'https://dns.google/dns-query', fallbacks: 'quic://dns.quad9.net:853',
    routes: 'video.example=quic://dns.quad9.net:853', protocol: 'doq', mode: 'parallel', bootstrap: '1.1.1.1\n2001:4860:4860::8888', replace: '1',
  };
  assert.match(await dohCard.locator('#dns-profile-warning').innerText(), /Незашифрованный fallback отключён/,
    'the profile explicitly states that there is no plain DNS fallback');
  assert.equal(await dohCard.locator('#dns-profile-ack').count(), 1,
    'mixing universal and filtering catalog categories requires acknowledgement');
  await dohCard.locator('#dns-profile-ack').check();
  await dohCard.getByRole('button', { name: 'Применить' }).click();
  assert.match(dohConfirmMessages.at(-1), /конфигурация dnsproxy/i,
    'replacing external dnsproxy configuration requires explicit confirmation');
  assert.equal(dohActions.length, 1, 'dismissing the ownership warning does not submit a profile');
  acceptNextDohConfirm = true;
  await dohCard.getByRole('button', { name: 'Применить' }).click();
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-2"] #job-close').waitFor({ state: 'visible' });
  assert.deepEqual(dohActions[1], { endpoint: 'profile', body: profileBody },
    'Отправка профиля передаёт выбранный DoQ и точные параметры DNS');
  assert.equal(Object.hasOwn(dohActions[1].body, 'plain_fallback'), false,
    'the profile request contains no plain fallback setting');
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-2"] #job-close').click();
  await dohPage.waitForFunction(() => document.querySelector('#doh-status')?.innerText.includes('Статус: Работает'));
  assert.match(await dohCard.innerText(), /DNS роутера: ответы DNS подтверждены/);
  assert.match(await dohCard.innerText(), /Защищённый upstream: подтверждён · фактически: DoH/);
  assert.equal(await dohCard.locator('#doh-ownership-warning').isVisible(), false,
    'a successful profile apply no longer reports its own resolver as external');
  assert.deepEqual(await dohCard.locator('[data-doh-action]').evaluateAll(buttons => buttons.map(button => button.dataset.dohAction)),
    ['apply', 'check', 'disable', 'uninstall'], 'configured working DoH offers Stop');
  await dohCard.getByRole('button', { name: 'Остановить' }).click();
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-3"] #job-close').waitFor({ state: 'visible' });
  assert.deepEqual(dohActions[2], { endpoint: 'disable', body: {} }, 'Stop calls the existing DoH disable action');
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-3"] #job-close').click();
  await dohPage.waitForFunction(() => document.querySelector('#doh-status')?.innerText.includes('Статус: Выключен'));
  assert.deepEqual(await dohCard.locator('[data-doh-action]').evaluateAll(buttons => buttons.map(button => button.dataset.dohAction)),
    ['apply', 'check', 'enable', 'uninstall'], 'stopping DoH retains its config and offers Start');
  await dohCard.getByRole('button', { name: 'Запустить' }).click();
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-4"] #job-close').waitFor({ state: 'visible' });
  assert.deepEqual(dohActions[3], { endpoint: 'enable', body: {} }, 'Start calls the existing DoH enable action');
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-4"] #job-close').click();
  await dohPage.waitForFunction(() => document.querySelector('#doh-status')?.innerText.includes('Статус: Работает'));

  dohStatus = { ...dohStatus, state: 'error', enabled: '1', running: '0', reason: 'proxy-not-running' };
  await dohPage.reload();
  await waitForRenderedRoute(dohPage, 'dns');
  await dohPage.waitForFunction(() => document.querySelector('#doh-status')?.innerText.includes('Статус: Ошибка'));
  assert.match(await dohCard.innerText(), /сервис dnsproxy не запущен/i);
  assert.deepEqual(await dohCard.locator('[data-doh-action]').evaluateAll(buttons => buttons.map(button => button.dataset.dohAction)),
    ['apply', 'check', 'disable', 'uninstall'], 'error state keeps Stop available while the service remains enabled');
  assert.match(await dohPage.locator('#dns-profile-queue').innerText(),
    /Основные upstream[\s\S]*Google Public DNS[\s\S]*https:\/\/dns\.google[\s\S]*Аварийный fallback[\s\S]*Quad9[\s\S]*quic:\/\/dns\.quad9/,
    'после перезагрузки профиль восстанавливает DoH upstream и DoQ fallback');
  assert.equal(await dohPage.locator('#dns-profile-bootstrap').inputValue(), '1.1.1.1\n2001:4860:4860::8888',
    'both IPv4 and IPv6 bootstrap resolvers are restored from profile status');
  assert.equal(await dohPage.locator('#dns-upstream-mode').inputValue(), 'parallel',
    'saved upstream mode is restored from profile status');
  assert.match(await dohPage.locator('#dns-profile-rules-list').innerText(), /video\.example\s*→\s*quic:\/\/dns\.quad9\.net:853/,
    'после перезагрузки доменное правило восстанавливается из состояния DNS');
  assert.equal(dohStatus.profile_upstreams_b64, Buffer.from(profileBody.upstreams).toString('base64'));
  assert.equal(dohStatus.profile_fallbacks_b64, Buffer.from(profileBody.fallbacks).toString('base64'));
  assert.equal(dohStatus.profile_routes_b64, Buffer.from(profileBody.routes).toString('base64'));
  assert.equal(dohStatus.profile_bootstrap_b64, Buffer.from(profileBody.bootstrap).toString('base64'));

  await dohPage.evaluate(() => { window.__dnsPageRoot = document.querySelector('#app').firstElementChild; });
  holdNextDohJobResult = true;
  const dohStatusCallsBeforeCheck = dohStatusCalls;
  await dohCard.getByRole('button', { name: 'Проверить' }).click();
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-5"] #job-close').waitFor({ state: 'visible' });
  assert.equal(dohActions[4].endpoint, 'check', 'diagnostics use a separate Check action');
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-5"] #job-close').click();
  await dohPage.evaluate(() => {
    window.scrollTo(0, 650);
    const input = document.querySelector('#dns-profile-bootstrap');
    input.focus({ preventScroll: true });
    input.setSelectionRange(8, 19);
    window.__dnsExpectedScroll = window.scrollY;
    window.__dnsExpectedSelection = [input.selectionStart, input.selectionEnd];
  });
  await dohPage.waitForFunction(() => new Promise(resolve => {
    const y = window.scrollY;
    requestAnimationFrame(() => requestAnimationFrame(() => resolve(y === window.scrollY)));
  }));
  await dohPage.evaluate(() => { window.__dnsExpectedScroll = window.scrollY; });
  assert.equal(typeof releaseHeldDohJob, 'function');
  releaseHeldDohJob();
  releaseHeldDohJob = null;
  await waitForCondition(() => dohStatusCalls > dohStatusCallsBeforeCheck, 'DNS /status refresh');
  await dohPage.waitForTimeout(50);
  const dnsRefreshDomState = await dohPage.evaluate(() => ({
    expectedScroll: window.__dnsExpectedScroll, scroll: window.scrollY,
    rootSame: document.querySelector('#app').firstElementChild === window.__dnsPageRoot,
    focusedId: document.activeElement?.id,
    expectedSelection: window.__dnsExpectedSelection,
    selection: [document.activeElement?.selectionStart, document.activeElement?.selectionEnd],
  }));
  assert.equal(dnsRefreshDomState.scroll, dnsRefreshDomState.expectedScroll, 'DNS status refresh preserves window.scrollY');
  assert.equal(dnsRefreshDomState.rootSame, true, 'DNS status refresh keeps the original page root');
  assert.equal(dnsRefreshDomState.focusedId, 'dns-profile-bootstrap', 'DNS status refresh preserves focused input');
  assert.deepEqual(dnsRefreshDomState.selection, dnsRefreshDomState.expectedSelection, 'DNS status refresh preserves the input cursor');

  acceptNextDohConfirm = true;
  await dohCard.getByRole('button', { name: 'Удалить', exact: true }).click();
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-6"] #job-close').waitFor({ state: 'visible' });
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-6"] #job-close').filter({ hasText: 'Закрыть' }).waitFor({ state: 'visible' });
  assert.equal(await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-6"] #job-close').innerText(), 'Закрыть',
    'a failed uninstall never presents the success action Готово');
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-6"] #job-close').click();
  await dohPage.waitForFunction(() => document.querySelector('#doh-status')?.innerText.includes('Статус: Ошибка'));
  acceptNextDohConfirm = true;
  await dohCard.getByRole('button', { name: 'Удалить', exact: true }).click();
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-7"] #job-close').waitFor({ state: 'visible' });
  await dohPage.locator('.modal-backdrop[data-job-id="doh-fixture-7"] #job-close').click();
  await dohPage.waitForFunction(() => document.querySelector('#doh-status')?.innerText.includes('Статус: Не установлен'));
  assert.deepEqual(dohActions[5], { endpoint: 'uninstall', body: { confirm: '1' } },
    'confirmed Remove submits the server-required external package confirmation');
  assert.deepEqual(dohActions[6], { endpoint: 'uninstall', body: { confirm: '1' } },
    'a failed Remove remains retryable after state is refreshed');
  assert.deepEqual(await dohCard.locator('[data-doh-action]').evaluateAll(buttons => buttons.map(button => button.dataset.dohAction)),
    ['install'], 'Remove immediately returns the card to Install-only state');
  assert.equal(await dohCard.locator('#doh-ownership-warning').isVisible(), false,
    'the external ownership warning disappears after package removal');
  assert.deepEqual(dohActions.map(action => action.endpoint), ['install', 'profile', 'disable', 'enable', 'check', 'uninstall', 'uninstall']);
  assert.equal(await dohPage.evaluate(() => document.documentElement.scrollWidth <= window.innerWidth), true,
    'compact DoH controls do not introduce mobile horizontal overflow');
  await dohPage.close();

  assert.deepEqual(allPageErrors, []);
  assert.deepEqual(allConsoleErrors, []);

  const videoDir = process.env.OPENWRT_VIDEO_DIR || '';
  if (videoDir) {
    fs.mkdirSync(videoDir, { recursive: true });
    const transitionEvents = (events) => events.map(([sequence, branch, transport, state]) => ({
      sequence, branch, transport, state,
    }));
    const routeScenario = ({ direct, fallback, selected, events, processStartedAt = tgCheckedAt - 600, accepted = 18, active = 1 }) => ({
      ...tgStatsFixture,
      process_started_at: processStartedAt,
      accepted_connections: accepted,
      active_connections: active,
      active_sessions: active ? [{
        id: 700,
        dc: 2,
        is_media: false,
        stage: selected ? 'upstream_ready' : 'routing',
        direct_state: direct.state,
        direct_transport: direct.transport || null,
        fallback_state: fallback.state,
        fallback_transport: fallback.transport || null,
        selected_transport: selected,
        telegram_response_seen: false,
        events: transitionEvents(events),
      }] : [],
    });
    const directRoute = () => routeScenario({
      direct: { state: 'selected', transport: 'direct_wss' },
      fallback: { state: 'idle' }, selected: 'direct_wss',
      events: [[1, 'direct', 'direct_wss', 'selected']],
    });
    let failStatsApi = false;
    const motionPage = await browser.newPage({
      viewport: { width: 1280, height: 900 },
      colorScheme: 'dark',
      recordVideo: { dir: videoDir, size: { width: 1280, height: 900 } },
    });
    await motionPage.addInitScript(() => {
      localStorage.setItem('z2k-theme', 'dark');
      localStorage.setItem('z2k-sidebar', 'expanded');
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
    await motionPage.locator('.telegram-tunnel-card').scrollIntoViewIfNeeded();
    const routeCaption = motionPage.locator('#tg-route-caption');
    await motionPage.waitForFunction(() => document.querySelector('#tg-route-scheme')?.dataset.state === 'active');
    assert.match(await routeCaption.innerText(), /Прямой WSS/, 'video starts on a direct WSS fixture');
    await motionPage.waitForFunction(() => {
      const ring = document.querySelector('.tg-route-svg--desktop [data-route-branch="direct"] .tg-route-live-ring');
      return window.gsap.getTweensOf(ring).some(tween => tween.repeat() === -1);
    });
    await motionPage.emulateMedia({ reducedMotion: 'reduce' });
    await motionPage.waitForFunction(() => {
      const ring = document.querySelector('.tg-route-svg--desktop [data-route-branch="direct"] .tg-route-live-ring');
      return window.gsap.getTweensOf(ring).every(tween => tween.repeat() !== -1);
    }, null, { timeout: 1000 });
    await motionPage.emulateMedia({ reducedMotion: 'no-preference' });
    await motionPage.waitForFunction(() => {
      const ring = document.querySelector('.tg-route-svg--desktop [data-route-branch="direct"] .tg-route-live-ring');
      return window.gsap.getTweensOf(ring).some(tween => tween.repeat() === -1);
    });
    const refreshRoute = async (snapshot, expectedText) => {
      tgStatsResponse = snapshot;
      await motionPage.locator('#tg-stats-refresh').click();
      await motionPage.waitForFunction(expected => document.querySelector('#tg-route-caption')?.textContent.includes(expected), expectedText);
    };
    await refreshRoute(routeScenario({
      direct: { state: 'failed', transport: 'direct_wss' },
      fallback: { state: 'selected', transport: 'cloudflare_proxy' }, selected: 'cloudflare_proxy',
      events: [[2, 'direct', 'direct_wss', 'failed'], [3, 'fallback', 'cloudflare_proxy', 'connecting'],
        [4, 'fallback', 'cloudflare_proxy', 'connected'], [5, 'fallback', 'cloudflare_proxy', 'selected']],
    }), 'Cloudflare Proxy');
    await waitForGsapSettled(motionPage, ['.tg-route-path']);
    assert.match(await routeCaption.innerText(), /не подтверждает ответ Telegram|не подтверждение resPQ/,
      'a selected WSS upstream is not presented as Telegram confirmation');
    if (screenshotDir) {
      await screenshotComponent(motionPage, motionPage.locator('.telegram-tunnel-card'),
        path.join(screenshotDir, `${screenshotPrefix}tg-route-fallback-desktop.png`));
    }
    await refreshRoute(routeScenario({
      direct: { state: 'selected', transport: 'direct_wss' },
      fallback: { state: 'failed', transport: 'cloudflare_proxy' }, selected: 'direct_wss',
      events: [[6, 'fallback', 'cloudflare_proxy', 'failed'], [7, 'direct', 'direct_wss', 'connecting'],
        [8, 'direct', 'direct_wss', 'connected'], [9, 'direct', 'direct_wss', 'selected']],
    }), 'Прямой WSS');
    await waitForGsapSettled(motionPage, ['.tg-route-path']);

    await refreshRoute(routeScenario({
      direct: { state: 'failed', transport: 'direct_wss' },
      fallback: { state: 'failed', transport: 'cloudflare_proxy' }, selected: null,
      events: [[10, 'direct', 'direct_wss', 'failed'], [11, 'fallback', 'cloudflare_proxy', 'failed']],
    }), 'Выбор маршрута');
    assert.equal(await motionPage.locator('.tg-route-svg--desktop [data-route-branch][data-status="failed"]').count(), 2,
      'all unavailable routes remain visibly failed without a synthetic success');

    // Несколько быстрых снимков не должны оставлять старую ветку или tween.
    await refreshRoute(routeScenario({
      direct: { state: 'selected', transport: 'direct_wss' }, fallback: { state: 'failed', transport: 'cloudflare_proxy' },
      selected: 'direct_wss', events: [[12, 'direct', 'direct_wss', 'selected']],
    }), 'Прямой WSS');
    await refreshRoute(routeScenario({
      direct: { state: 'failed', transport: 'direct_wss' }, fallback: { state: 'selected', transport: 'cloudflare_proxy' },
      selected: 'cloudflare_proxy', events: [[13, 'direct', 'direct_wss', 'failed'], [14, 'fallback', 'cloudflare_proxy', 'selected']],
    }), 'Cloudflare Proxy');
    assert.equal(await motionPage.locator('#tg-route-scheme [data-route-branch="fallback"]').first().getAttribute('data-status'), 'selected',
      'rapid route changes end on the latest real transport');

    failStatsApi = true;
    await motionPage.locator('#tg-stats-refresh').click();
    await motionPage.waitForFunction(() => document.querySelector('#tg-route-scheme')?.dataset.state === 'unavailable');
    assert.equal(await motionPage.locator('#tg-route-scheme [data-route-branch][data-active="true"]').count(), 0,
      'API loss immediately clears the previously selected route');
    failStatsApi = false;

    await refreshRoute(routeScenario({
      direct: { state: 'selected', transport: 'direct_wss' }, fallback: { state: 'idle' }, selected: 'direct_wss',
      events: [[1, 'direct', 'direct_wss', 'selected']], processStartedAt: tgCheckedAt + 1, accepted: 1,
    }), 'Прямой WSS');
    assert.equal(await motionPage.locator('#tg-route-scheme [data-route-branch="direct"]').first().getAttribute('data-status'), 'selected',
      'proxy restart uses only the new process snapshot');

    await refreshRoute(routeScenario({
      direct: { state: 'idle' }, fallback: { state: 'idle' }, selected: null, events: [], active: 0,
    }), 'Нет активных соединений');
    assert.equal(await motionPage.locator('#tg-route-scheme [data-route-branch][data-active="true"]').count(), 0,
      'no active connections leave both branches static');
    if (screenshotDir) {
      await screenshotComponent(motionPage, motionPage.locator('.telegram-tunnel-card'),
        path.join(screenshotDir, `${screenshotPrefix}tg-route-idle-desktop.png`));
    }
    await motionPage.close();
  }

  // A genuinely broken required module graph receives a visible failure state.
  const broken = await browser.newPage();
  await broken.route('**/js/pages/dashboard.js*', route => route.abort('failed'));
  await broken.goto(`${base}/#/dashboard`);
  await broken.locator('#app [data-ui-fatal]').waitFor({ state: 'visible', timeout: 2000 });
  assert.match(await broken.locator('#app').innerText(), /Не удалось загрузить интерфейс/);

  console.log(`PASS: real browser OpenWrt document root; ${routes.length} routes in dark/light; one-brand, contrast, keyboard, responsive, blocker, and broken-module cases; ${totalModuleResponses} module responses`);
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(root, { recursive: true, force: true });
}
