// Real Chromium acceptance for the OpenWrt document root and its ES-module graph.
// Run with PLAYWRIGHT_MODULE=/path/to/playwright/index.mjs node tests/browser/openwrt-panel.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import os from 'node:os';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const webpanelInit = fs.readFileSync(path.join(repo, 'platform/openwrt/files/etc/init.d/z2k-webpanel'), 'utf8');
const webpanelAdapter = fs.readFileSync(path.join(repo, 'platform/openwrt/webpanel.sh'), 'utf8');
assert.equal(/wp_panel_reconcile_http_listener/.test(webpanelInit), false,
  'the panel instance does not stop or restart stock listeners');
assert.equal(/webpanel-lifecycle\.sh/.test(webpanelAdapter), false,
  'panel helpers do not load stock HTTP service mutations');
const screenshotDir = process.env.OPENWRT_SCREENSHOT_DIR || '';
if (screenshotDir) fs.mkdirSync(screenshotDir, { recursive: true });
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
    game_warp: '0', customd: '0', dynamic_ttl: '1', stats: '1', stats_ack: '0',
    ppe: '1', auto_update: '1', autohostlist: '0', fastroute: '0',
    fastroute_available: '0', flowoffload: 'hardware', flowoffload_status: 'enabled', au_hour: '3',
  },
  tunnel: { running: true },
  capabilities: { policy: false, ppe: false, tcp16: false, diag: true, warp: true, telegram: true, uninstall: false, offload: true },
};
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
    const body = endpoint === 'state'
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
  ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {}),
});

async function waitForRenderedRoute(page, route) {
  await page.waitForFunction(name => {
    const app = document.querySelector("#app");
    const content = app ? app.innerText.trim() : "";
    return document.body.getAttribute("data-page") === name
      && content.length > 0 && content !== "Загрузка…";
  }, route, { timeout: 2000 });
  const content = (await page.locator("#app").innerText()).trim();
  assert.ok(content, route + " must render visible content");
  assert.notEqual(content, "Загрузка…", route + " must leave the initial loading state");
  await page.waitForFunction(() => [...document.querySelectorAll('#app .page-title, #app > .card')]
    .every(node => Number.parseFloat(getComputedStyle(node).opacity) >= 0.99), null, { timeout: 2000 });
}

async function waitForNavSettled(page) {
  await page.waitForFunction(() => [...document.querySelectorAll('#nav a')]
    .every(link => link.getAnimations().every(animation => animation.playState !== 'running')),
  null, { timeout: 1200 });
}

async function waitForDrawerSettled(page, open) {
  await page.waitForFunction(expectedOpen => {
    const nav = document.querySelector('#nav');
    const shell = document.querySelector('#menu-shell');
    return nav.classList.contains('menu-open') === expectedOpen
      && shell.classList.contains('mm-ocd--open') === expectedOpen
      && shell.getAnimations({ subtree: true }).every(animation => animation.playState !== 'running');
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
    if (viewport !== '390') {
      await page.locator('#dns-result').screenshot({
        path: path.join(screenshotDir, `${screenshotBase}-dns-results.png`),
      });
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

  const routes = ['dashboard', 'toggles', 'strategies', 'warp', 'whitelist', 'exclude', 'extra-domains', 'diag', 'credits', 'state', 'pick', 'autohostlist'];
  const primaryRoutes = ['dashboard', 'toggles', 'state', 'warp', 'whitelist', 'extra-domains', 'diag', 'credits'];
  const screenshotRoutes = ['dashboard', 'toggles', 'strategies', 'warp', 'whitelist', 'exclude',
    'extra-domains', 'diag', 'credits', 'state', 'pick', 'autohostlist'];
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
    assert.equal(await lockup.locator('.brand-profile-logo').count(), 1, 'exactly one mark element exists');
    assert.equal(await page.locator('.brand-profile-logo').count(), 1, 'the whole document contains exactly one brand mark');
    assert.equal(await lockup.locator('.brand-wordmark').count(), 1, 'exactly one HTML wordmark exists');
    assert.equal((await lockup.locator('.brand-wordmark').innerText()).replace(/\s+/g, ''), 'z2kOW');
    assert.doesNotMatch(await lockup.innerText(), /keenetic|antidpi|openwrt edition/i);
    assert.equal(await lockup.locator('.brand-profile-logo').evaluate(node => node.naturalWidth > 0), true);
    assert.equal(await lockup.locator('.brand-profile-logo').getAttribute('src'), '/assets/openwrt/logo.png');
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
    assert.equal(await page.locator('.topbar').evaluate(node => node.getBoundingClientRect().height), 44,
      'desktop topbar uses the compact reference height');
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
    assert.ok(Math.abs(desktopFrame.appY - 44) < 1,
      `the main column begins directly below the single 44 px header (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(desktopFrame.brandX - (desktopFrame.windowWidth / 2 - 545.5)) < 1,
      `the z2kOW lockup starts at Lolz's measured brand position (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(desktopFrame.brandY - 3) < 1 && Math.abs(desktopFrame.brandWidth - 200) < 1,
      `the full z2kOW logo lockup occupies the measured 200×38 header slot at y=3 (${JSON.stringify(desktopFrame)})`);
    assert.equal(await page.locator('#header-nav, #route-recents').count(), 0,
      'the header has no duplicated route-navigation rows');
    assert.ok(Math.abs(desktopFrame.utilityRight - (desktopFrame.appRight - 98)) < 2,
      `header controls follow Lolz's measured 98 px trailing inset within the shell (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(await page.locator('#nav .nav-ico').first().evaluate(node => node.getBoundingClientRect().width) - 20) < 1,
      'sidebar icons match the reference size');
    const shellMotion = await page.evaluate(() => {
      const nav = getComputedStyle(document.querySelector('#nav'));
      const app = getComputedStyle(document.querySelector('#app'));
      return { navDuration: nav.transitionDuration, navEasing: nav.transitionTimingFunction,
        appDuration: app.transitionDuration, appEasing: app.transitionTimingFunction };
    });
    assert.deepEqual(shellMotion.navDuration.split(',').map(value => value.trim()), ['0.3s', '0.3s'],
      'desktop sidebar left and width transition for 300 ms');
    assert.ok(shellMotion.navEasing.split(',').every(value => value.trim() === 'ease'),
      'desktop sidebar uses the observed ease curve');
    assert.deepEqual(shellMotion.appDuration.split(',').map(value => value.trim()), ['0.3s', '0.3s'],
      'desktop content margin and width follow the rail over 300 ms');
    assert.ok(shellMotion.appEasing.split(',').every(value => value.trim() === 'ease'),
      'desktop content follows the observed ease curve');
    assert.ok(await page.locator('#app').evaluate(node => node.getBoundingClientRect().width === 800),
      'all desktop routes use the reference 800 px content column');
    const sidebarCollapse = page.locator('#sidebar-collapse');
    await sidebarCollapse.click();
    await page.waitForFunction(() => document.body.dataset.sidebar === 'collapsed'
      && Math.abs(document.querySelector('#nav').getBoundingClientRect().width - 72) < 0.5
      && Math.abs(document.querySelector('#app').getBoundingClientRect().x - (innerWidth / 2 - 356.5)) < 1);
    await page.waitForFunction(() => document.getAnimations()
      .every(animation => animation.playState !== 'running'));
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
    await page.waitForFunction(() => document.getAnimations()
      .every(animation => animation.playState !== 'running'));
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
    assert.equal(surfaces.titleAnimation, 'page-enter', 'the reference route transition is applied to page titles');
    assert.equal(surfaces.cardAnimation, 'page-enter', 'the reference route transition is applied to cards');
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
    assert.ok(buttonStyle.transitionDuration.split(',').every(value => value.trim() === '0.1s'),
      'buttons use the measured 100 ms Lolz transition');
    assert.ok(buttonStyle.transitionProperty.includes('all'), 'buttons retain the source transition shorthand');
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
    assert.ok(cardHover.duration.split(',').includes('0.15s'), 'cards ease their hover state over 150 ms');
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
    await page.waitForFunction(() => {
      const node = document.querySelector('button[data-qa-motion="true"]');
      return node && getComputedStyle(node, '::before').opacity === '1';
    });
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
    assert.match(primaryStyle.hoverLayer, /linear-gradient\(88deg/, 'primary hover is the source pseudo-element overlay');
    assert.equal(primaryStyle.hoverDuration, '0.3s', 'primary hover overlay fades over the source 300 ms');
    assert.equal(primaryStyle.filter, 'brightness(1.08)', 'primary hover uses the source brightness response');
    assert.equal(primaryStyle.activeLayer, 'rgba(0, 0, 0, 0.18)', 'primary press overlays the source black tint');
    assert.equal(primaryStyle.activeDuration, '0.15s', 'primary press overlay uses the source 150 ms fade');
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
    assert.ok(Math.abs(primaryActive.scale - 0.97) < 0.002, 'primary press uses the source scale(.97)');
    assert.equal(primaryActive.overlay, '1', 'primary press reaches the source black-overlay state');
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
        await page.waitForFunction(() => {
          const drop = document.querySelector('.chosen-drop-open');
          return drop && drop.getAnimations().every(animation => animation.playState !== 'running');
        });
        const popupGeometry = await page.evaluate(() => {
          const trigger = document.querySelector('#au-hour + .chosen-single').getBoundingClientRect();
          const drop = document.querySelector('.chosen-drop-open');
          const rect = drop.getBoundingClientRect();
          const style = getComputedStyle(drop);
          return { xOffset: Math.round((rect.left - trigger.left) * 100) / 100,
            widthDelta: Math.round((rect.width - trigger.width) * 100) / 100,
            radius: style.borderRadius, animationName: style.animationName,
            animationDuration: style.animationDuration, animationEasing: style.animationTimingFunction };
        });
        assert.deepEqual([popupGeometry.xOffset, popupGeometry.widthDelta], [0, 0],
          `the Lolz dropdown aligns to its trigger on the same x-axis and width (${JSON.stringify(popupGeometry)})`);
        assert.equal(popupGeometry.radius, '10px', 'the open dropdown uses the shared control radius');
        assert.equal(popupGeometry.animationName, 'chosenDropBelow', 'the dropdown uses its Lolz open keyframe');
        assert.equal(popupGeometry.animationDuration, '0.2s', 'the dropdown opens over the source 200 ms');
        assert.match(popupGeometry.animationEasing, /cubic-bezier\(0\.5, 0, 0, 1\.25\)/,
          'the dropdown uses the source spring-like easing');
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
        const before = await domainField.boundingBox();
        await page.locator('.pick-mode input[value="voice"]').check();
        assert.equal(await domainField.isDisabled(), true, 'voice mode disables the irrelevant domain field');
        const disabled = await domainField.boundingBox();
        assert.deepEqual([disabled.width, disabled.height], [before.width, before.height],
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
        const switchGeometry = await page.locator('#app .switch').evaluateAll(nodes => nodes.map(node => {
          const track = node.getBoundingClientRect();
          const thumb = getComputedStyle(node.querySelector('.slider'), '::before');
          return { width: track.width, height: track.height, thumbWidth: thumb.width, thumbHeight: thumb.height,
            checked: node.querySelector('input').checked };
        }));
        assert.ok(switchGeometry.length >= 8, `fixture exposes WARP on/off switches (${switchGeometry.length})`);
        assert.ok(switchGeometry.every(({ width, height, thumbWidth, thumbHeight }) =>
          width === 40 && height === 22 && thumbWidth === '16px' && thumbHeight === '16px'),
        `all WARP switches use one 40×22 track and 16×16 knob (${JSON.stringify(switchGeometry)})`);
        assert.ok(switchGeometry.some(item => item.checked) && switchGeometry.some(item => !item.checked),
          'WARP QA includes both switch states without changing track geometry');
        await offlineDisclosure.locator('summary').click();
      }
      if (route === 'diag') {
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
        const logViewport = await page.locator('#diag-output').evaluate(node => ({
          height: node.clientHeight, scrollHeight: node.scrollHeight,
          overflowY: getComputedStyle(node).overflowY,
        }));
        assert.ok(logViewport.scrollHeight > logViewport.height && logViewport.overflowY === 'auto',
          `long diagnostic output stays inside its own scroll container (${JSON.stringify(logViewport)})`);
        await assertDiagDynamicStates(page, appearance);
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
        assert.match(tabIndicator.transition, /0\.35s cubic-bezier\(0\.4, 0, 0\.2, 1\)/,
          `${appearance}/${route}: underline position follows Lolz easing`);
        assert.ok(tabIndicator.left.endsWith('px'), `${appearance}/${route}: source position variable is applied`);
        const tabScrollMotion = await page.locator('.strat-tabs').evaluate(async tabs => {
          const active = tabs.querySelector('.strat-tab.active');
          const spacer = document.createElement('span');
          spacer.style.cssText = 'flex:0 0 420px;width:420px';
          tabs.appendChild(spacer);
          tabs.scrollLeft = 40;
          tabs.dispatchEvent(new Event('scroll'));
          await new Promise(requestAnimationFrame);
          const result = { left: Number.parseFloat(tabs.style.getPropertyValue('--tab-left')),
            expectedLeft: active.offsetLeft - tabs.scrollLeft,
            marginLeft: getComputedStyle(tabs, '::after').marginLeft };
          spacer.remove();
          tabs.scrollLeft = 0;
          tabs.dispatchEvent(new Event('scroll'));
          return result;
        });
        assert.equal(tabScrollMotion.left, tabScrollMotion.expectedLeft,
          `${appearance}/${route}: source tab indicator follows horizontal scroll (${JSON.stringify(tabScrollMotion)})`);
        assert.equal(tabScrollMotion.marginLeft, '5px', `${appearance}/${route}: source underline has its 5 px inset`);
      }
      assert.equal(await lockup.locator('.brand-profile-logo').count(), 1, `${appearance}: single mark on #/${route}`);
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
            return tabs.getAnimations({ subtree: true })
              .filter(animation => animation.effect?.pseudoElement === '::after')
              .every(animation => animation.playState !== 'running')
              && close(indicator.left, active.offsetLeft - tabs.scrollLeft)
              && close(indicator.top, active.offsetTop + active.offsetHeight - 2)
              && close(indicator.width, active.offsetWidth);
          }, null, { timeout: 1500 });
          await page.screenshot({ path: path.join(screenshotDir, `${appearance}-${width}-${route}.png`) });
        }
      }
    }
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
      selectedSurface: getComputedStyle(document.querySelector('#nav a.active')).backgroundColor,
    }));
    assert.equal(frozenRow.frozen, 'true', `frozen table state is semantic and themeable (${JSON.stringify(frozenRow)})`);
    assert.equal(frozenRow.inlineBackground, '', 'row color comes from the shared Lolz surface token');
    assert.equal(frozenRow.background, frozenRow.selectedSurface, 'frozen rows use the source selected surface');
    assert.equal((await page.locator('.unique-set-badge').innerText()).trim(), 'Экспериментальная функция');
    assert.equal(await page.locator('#unique-set-reset-all').evaluate(node => node.classList.contains('btn-danger')), false,
      'reversible return-to-automatic action is not destructive red');

    assert.ok(moduleResponses.length > 0, 'Chromium must load the real ES-module graph');
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
  assert.equal(firstPaintTheme.topbarHeight, '44px',
    `Full-HD first paint uses the Lolz 44 px topbar while profile.json is held (${JSON.stringify(firstPaintTheme)})`);
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
    const transformFinished = new Promise(resolve => {
      const timeout = window.setTimeout(() => finish(), 1000);
      function finish(event) {
        if (event && event.propertyName !== 'transform') return;
        window.clearTimeout(timeout);
        modal.removeEventListener('transitionend', finish);
        resolve();
      }
      modal.addEventListener('transitionend', finish);
    });
    openModalBackdrop(backdrop);
    await new Promise(requestAnimationFrame);
    await transformFinished;
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
  assert.equal(modalMotion.start.transitionDuration, '0.2s, 0.15s');
  assert.equal(modalMotion.start.transitionProperty, 'transform, opacity');
  assert.deepEqual([modalMotion.opened.backdrop, modalMotion.opened.modal,
    modalMotion.opened.backdropOpacity, modalMotion.opened.modalOpacity], [true, true, '1', '1']);
  assert.equal(modalMotion.opened.modalTransform, 'matrix(1, 0, 0, 1, 0, 0)');
  assert.deepEqual([modalMotion.closing.backdrop, modalMotion.closing.modal, modalMotion.closing.closing],
    [false, false, 'true']);
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
  assert.equal(await loaderBlocked.locator('#brand-wordmark').innerText(), 'z2kOW');
  assert.equal(await loaderBlocked.locator('#panel-brand .brand-profile-logo').count(), 1);
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
  assert.equal(await blocked.locator('#panel-brand .brand-profile-logo').count(), 1);
  assert.equal(await blocked.locator('#panel-brand .brand-wordmark').innerText(), 'z2kOW');
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
  await themeBlocked.route('**/assets/openwrt/theme.css', route => route.abort('blockedbyclient'));
  await themeBlocked.goto(base + '/#/dashboard');
  await waitForRenderedRoute(themeBlocked, 'dashboard');
  assert.equal(await themeBlocked.locator('#brand-wordmark').innerText(), 'z2kOW');
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
  const drawerMotion = await mobile.evaluate(() => ({
    duration: getComputedStyle(document.querySelector('#menu-shell .mm-ocd__content')).transitionDuration,
    easing: getComputedStyle(document.querySelector('#menu-shell .mm-ocd__content')).transitionTimingFunction,
    width: document.querySelector('#menu-shell .mm-ocd__content').getBoundingClientRect().width,
    shellWidth: document.querySelector('#menu-shell').getBoundingClientRect().width,
    shellDuration: getComputedStyle(document.querySelector('#menu-shell')).transitionDuration,
    shellDelay: getComputedStyle(document.querySelector('#menu-shell')).transitionDelay,
  }));
  assert.equal(drawerMotion.duration, '0.3s', 'the Lolz drawer slides for 300 ms');
  assert.equal(drawerMotion.easing, 'ease', 'the drawer uses the measured ease curve');
  assert.ok(Math.abs(drawerMotion.width / drawerMotion.shellWidth - 0.8) < 0.005,
    `the drawer is 80% of the browser's content viewport (${drawerMotion.width}/${drawerMotion.shellWidth}px)`);
  assert.ok(drawerMotion.shellDuration.split(',').some(value => value.trim() === '0.3s' || value.trim() === '300ms'),
    `the shell fades for 300 ms (${drawerMotion.shellDuration})`);
  assert.ok(drawerMotion.shellDelay.split(',').every(value => value.trim() === '0s'),
    'opening removes both shell transition delays');
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
  assert.equal(await mobile.locator('#menu-shell').evaluate(node => node.classList.contains('mm-ocd--open')), false);
  assert.equal(await mobile.locator('body').evaluate(node => node.classList.contains('mm-ocd-opened')), false);
  const closingDelay = await mobile.locator('#menu-shell').evaluate(node => getComputedStyle(node).transitionDelay);
  assert.ok(closingDelay.split(',').some(value => value.trim() === '0.15s'),
    'closing delays the shell fade by the measured 150 ms');
  await waitForDrawerSettled(mobile, false);
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
  await reinstallRacePage.locator('#upd-reinstall').click();
  await reinstallRacePage.locator('#confirm-ok').click();
  await reinstallRacePage.getByRole('button', { name: 'Обновить до p-86.14' }).waitFor({ state: 'visible' });
  assert.equal(apiRequests.filter(request => request.endpoint === 'update/reinstall').length, reinstallCallsBefore + 1,
    'the accepted action reaches the reinstall preflight exactly once');
  assert.equal(apiRequests.filter(request => request.endpoint === 'update/apply').length, 0,
    'a manifest race never triggers an update to the newer release');
  assert.equal(await reinstallRacePage.locator('#upd-apply').innerText(), 'Обновить до p-86.14');
  await reinstallRacePage.close();
  reinstallFixtureActive = false;

  assert.deepEqual(allPageErrors, []);
  assert.deepEqual(allConsoleErrors, []);

  // A genuinely broken required module graph receives a visible failure state.
  const broken = await browser.newPage();
  await broken.route('**/js/pages/dashboard.js*', route => route.abort('failed'));
  await broken.goto(`${base}/#/dashboard`);
  await broken.locator('#app [data-ui-fatal]').waitFor({ state: 'visible', timeout: 2000 });
  assert.match(await broken.locator('#app').innerText(), /Не удалось загрузить интерфейс/);

  console.log(`PASS: real Chromium OpenWrt document root; ${routes.length} routes in dark/light; one-brand, contrast, keyboard, responsive, blocker, and broken-module cases; ${totalModuleResponses} module responses`);
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(root, { recursive: true, force: true });
}
