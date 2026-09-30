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
const screenshotDir = process.env.OPENWRT_SCREENSHOT_DIR || '';
if (screenshotDir) fs.mkdirSync(screenshotDir, { recursive: true });
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'z2k-openwrt-browser-'));
const www = path.join(root, 'www');
fs.cpSync(path.join(repo, 'webpanel/www'), www, { recursive: true });
const profileDir = path.join(www, 'assets/openwrt');
fs.mkdirSync(profileDir, { recursive: true });
for (const name of ['mark.svg', 'favicon.svg', 'theme.css', 'profile.json']) {
  const source = path.join(repo, 'platform/openwrt/webpanel-brand', name);
  if (fs.existsSync(source)) fs.copyFileSync(source, path.join(profileDir, name));
}

const mime = {
  '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.woff2': 'font/woff2',
};
const apiRequests = [];
let statusResponsesCompleted = 0;
let holdStatusResponses = true;
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
const server = http.createServer((req, res) => {
  const url = new URL(req.url || '/', 'http://127.0.0.1');
  if (url.pathname.startsWith('/cgi-bin/api/')) {
    const endpoint = url.pathname.slice('/cgi-bin/api/'.length);
    apiRequests.push({ endpoint, marker: req.headers['x-z2k-panel'] || '' });
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
      ts: Math.floor(Date.now() / 1000) - index * 60,
    }));
    const body = endpoint === 'state'
      ? { ok: true, entries: stateEntries }
      : endpoint === 'pools'
        ? { ok: true, pools: { tcp: 4, quic: 4 } }
        : endpoint === 'strategy/pools'
          ? { ok: true, pools: [{ pool: 'tcp', custom: 0, line: '' }, { pool: 'quic', custom: 0, line: '' }] }
          : endpoint === 'strategy/unique-set'
            ? { ok: true, result: null }
            : endpoint === 'update/status'
              ? { ok: true, installed: 'p-86.1', available: 'p-86.1', behind: 0, last_check: Math.floor(Date.now() / 1000), pending: [] }
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
                    ? { ok: true, enabled: '1', installed: true, ready: true, transport: 'wg', endpoint: '8.6.112.0:2408', iface: 'z2ktun0', addr: '172.16.0.2', entries: 1234, devices: 2, error: '' }
                    : endpoint === 'warp/neighbors'
                      ? { ok: true, devices: [{ mac: 'aa:bb:cc:dd:ee:ff', ip: '192.168.1.77', label: 'PS5', net: 'Home', active: true, on: true }] }
                      : endpoint === 'warp/games'
                        ? { ok: true, games: [{ name: 'ApexLegends', entries: 42, on: 1 }, { name: 'Valorant', entries: 13, on: 0 }] }
                        : endpoint === 'warp/lists'
                          ? { ok: true, lists: [{ name: 'custom', entries: 5, size: 120, mtime: Math.floor(Date.now() / 1000) }] }
                          : endpoint === 'autohostlist-domains'
                            ? { ok: true, domains: [] }
                            : endpoint === 'diag'
                              ? { ok: true, diag: '=== что не так ===\\n  явных проблем не найдено\\n' }
        : endpoint === 'extra-domains' || endpoint === 'whitelist'
          ? { ok: true, text: '', revision: 'fixture-r1', domains: [] }
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
  const requiredTokens = ['--ow-canvas', '--ow-surface-1', '--ow-surface-2', '--ow-surface-hover',
    '--ow-surface-selected', '--ow-border-subtle', '--ow-border-strong', '--ow-text-primary',
    '--ow-text-secondary', '--ow-text-tertiary', '--ow-accent', '--ow-accent-hover',
    '--ow-accent-soft', '--ow-brand-violet', '--ow-success', '--ow-warning', '--ow-danger',
    '--ow-info', '--ow-radius-control', '--ow-radius-card', '--ow-radius-panel',
    '--ow-focus-ring', '--ow-shadow-card', '--ow-shadow-popover'];
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
    const page = await browser.newPage({ viewport: { width: 1392, height: 1104 }, colorScheme: appearance });
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
    await page.addInitScript(mode => localStorage.setItem('z2k-theme', mode), appearance);
    await page.goto(`${base}/#/dashboard`);
    await waitForRenderedRoute(page, 'dashboard');
    await page.waitForFunction(() => {
      const theme = document.querySelector('#brand-profile-theme');
      return theme && theme.sheet && theme.sheet.cssRules.length > 0;
    }, null, { timeout: 1500 });
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
    assert.match(await payloadUpdateBanner.innerText(), /Движок zapret2 p-86\.1 актуален/,
      'the single update banner shows the upstream engine release');
    assert.equal(await page.locator('#product-update-card').count(), 0,
      'the dashboard has no separate z2kOW update card');
    assert.equal(await page.locator('#upd-history-link').innerText(), 'История обновлений');
    assert.equal(await page.locator('#upd-recheck').innerText(), 'Проверить');
    assert.equal(await page.locator('#upd-apply').count(), 0,
      'current release exposes a check action, not a second update system');
    assert.equal(await page.title(), 'Дашборд · z2kOW');
    assert.equal(await lockup.getAttribute('aria-label'), 'z2kOW — OpenWrt edition');
    assert.equal(await lockup.locator('.brand-profile-logo').count(), 1, 'exactly one mark element exists');
    assert.equal(await page.locator('.brand-profile-logo').count(), 1, 'the whole document contains exactly one brand mark');
    assert.equal(await lockup.locator('.brand-wordmark').count(), 1, 'exactly one HTML wordmark exists');
    assert.equal((await lockup.locator('.brand-wordmark').innerText()).replace(/\s+/g, ''), 'z2kOW');
    assert.doesNotMatch(await lockup.innerText(), /keenetic|antidpi|openwrt edition/i);
    assert.equal(await lockup.locator('.brand-profile-logo').evaluate(node => node.naturalWidth > 0), true);
    assert.equal(await page.locator('#brand-favicon').getAttribute('href'), '/assets/openwrt/favicon.svg');
    assert.equal(await page.locator('#brand-profile-theme').getAttribute('href'), '/assets/openwrt/theme.css');
    assert.equal(await page.locator('[data-theme-btn="' + appearance + '"]').getAttribute('aria-pressed'), 'true');
    assert.equal(await page.getByRole('group', { name: 'Тема' }).count(), 1);

    const tokens = await page.evaluate(names => {
      const style = getComputedStyle(document.documentElement);
      return Object.fromEntries(names.map(name => [name, style.getPropertyValue(name).trim()]));
    }, requiredTokens);
    for (const name of requiredTokens) assert.ok(tokens[name], `${appearance}: missing ${name}`);
    assert.ok(ratio(tokens['--ow-text-primary'], tokens['--ow-surface-1']) >= 4.5);
    assert.ok(ratio(tokens['--ow-text-secondary'], tokens['--ow-surface-2']) >= 4.5);
    assert.ok(ratio(tokens['--ow-text-tertiary'], tokens['--ow-surface-2']) >= 4.5);
    assert.ok(ratio(tokens['--ow-accent'], tokens['--ow-canvas']) >= 4.5);
    assert.ok(ratio(tokens['--ow-border-strong'], tokens['--ow-surface-selected']) >= 3);
    for (const name of ['--ow-success', '--ow-warning', '--ow-danger', '--ow-info']) {
      assert.ok(ratio(tokens[name], tokens['--ow-surface-1']) >= 4.5, `${appearance}: ${name} text contrast`);
      assert.ok(ratio(tokens[name], tokens['--ow-surface-2']) >= 4.5, `${appearance}: ${name} nested text contrast`);
    }
    const primaryText = await page.evaluate(() => getComputedStyle(document.documentElement).getPropertyValue('--btn-primary-text').trim());
    assert.ok(ratio(primaryText, tokens['--ow-accent']) >= 4.5, `${appearance}: primary button label contrast`);
    assert.equal(await page.evaluate(() => getComputedStyle(document.body).fontFamily.startsWith('system-ui')), true);

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

    for (const route of routes) {
      await page.evaluate(name => { location.hash = '#/' + name; }, route);
      await waitForRenderedRoute(page, route);
      await page.waitForFunction(() => {
        const title = document.querySelector('#app .page-title');
        return title && Number.parseFloat(getComputedStyle(title).opacity) >= 0.99;
      }, null, { timeout: 1500 });
      assert.equal(await page.locator('#app [data-ui-fatal]').count(), 0,
        `${appearance}: #/${route} must not render the fatal-route fallback`);
      if (route === 'state') {
        await page.locator('.state-table').waitFor({ state: 'visible', timeout: 2000 });
        await page.waitForFunction(() => document.querySelectorAll('.state-table tbody tr').length >= 100, null, { timeout: 2000 });
      }
      assert.equal(await lockup.locator('.brand-profile-logo').count(), 1, `${appearance}: single mark on #/${route}`);
      if (screenshotDir && primaryRoutes.includes(route)) {
        await page.screenshot({ path: path.join(screenshotDir, `${appearance}-${route}.png`) });
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
    await page.evaluate(() => { location.hash = '#/state'; });
    await waitForRenderedRoute(page, 'state');
    await page.locator('.state-table').waitFor({ state: 'visible', timeout: 1500 });
    assert.equal(await page.locator('.state-table').evaluate(node => node.tagName), 'TABLE', 'dense desktop data stays a table');
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
  assert.match(unifiedBanner, /Движок zapret2 p-86\.1 актуален/,
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
  assert.equal(await blocked.title(), 'Дашборд · Z2K');
  assert.equal(await blocked.locator('#panel-brand .brand-profile-logo').count(), 1);
  assert.equal(await blocked.locator('#panel-brand .brand-wordmark').innerText(), 'Z2K');
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

  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, colorScheme: 'dark', hasTouch: true });
  await mobile.goto(base + '/#/dashboard');
  await waitForRenderedRoute(mobile, 'dashboard');
  assert.equal(await mobile.locator('#menu-toggle').isVisible(), true);
  assert.ok(await mobile.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth),
    'compact layout must not create page-level horizontal overflow');
  await mobile.locator('#menu-toggle').click();
  assert.equal(await mobile.locator('#menu-toggle').getAttribute('aria-expanded'), 'true');
  await mobile.waitForFunction(() => document.activeElement.closest('#nav') !== null);
  assert.ok(await mobile.locator('#menu-toggle').evaluate(node => node.getBoundingClientRect().height >= 44));
  assert.ok(await mobile.locator('#nav a[data-route="dashboard"]').evaluate(node => node.getBoundingClientRect().height >= 44),
    'coarse-pointer navigation links meet the 44 px touch target');
  await mobile.keyboard.press('Escape');
  assert.equal(await mobile.locator('#menu-toggle').getAttribute('aria-expanded'), 'false');
  await mobile.waitForFunction(() => document.activeElement.id === 'menu-toggle', null, { timeout: 1000 });
  assert.equal(await mobile.evaluate(() => document.activeElement.id), 'menu-toggle', 'Escape restores focus to the drawer trigger');
  await mobile.close();

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
