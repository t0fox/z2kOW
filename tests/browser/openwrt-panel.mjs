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
  '.svg': 'image/svg+xml', '.woff2': 'font/woff2', '.ttf': 'font/ttf',
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
  await page.waitForFunction(() => [...document.querySelectorAll('#app .page-title, #app > .card')]
    .every(node => Number.parseFloat(getComputedStyle(node).opacity) >= 0.99), null, { timeout: 2000 });
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
  const screenshotRoutes = ['dashboard', 'toggles', 'strategies', 'warp', 'exclude', 'diag', 'state'];
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
    const page = await browser.newPage({ viewport: { width: 1440, height: 1104 }, colorScheme: appearance });
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
    await page.waitForFunction(() => Math.abs(document.querySelector('#nav').getBoundingClientRect().width - 260) < 1,
      null, { timeout: 1200 });
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
    assert.equal(await page.locator('#menu-toggle').isVisible(), false,
      `${appearance}: Full HD desktop uses the persistent sidebar, not the mobile menu button`);

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
    assert.ok(Math.abs(desktopSidebarWidth - 260) < 1,
      `desktop sidebar matches the compact reference width (${desktopSidebarWidth}px)`);
    const desktopFrame = await page.evaluate(() => ({
      viewport: document.documentElement.clientWidth,
      navX: document.querySelector('#nav').getBoundingClientRect().x,
      appX: document.querySelector('#app').getBoundingClientRect().x,
      appY: document.querySelector('#app').getBoundingClientRect().y,
      appWidth: document.querySelector('#app').getBoundingClientRect().width,
      brandX: document.querySelector('#panel-brand').getBoundingClientRect().x,
    }));
    assert.ok(Math.abs(desktopFrame.navX - (desktopFrame.viewport / 2 - 535)) < 1,
      `Lolz measured 1081 px shell places the 261 px rail 5 px inside the wrapper (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(desktopFrame.appX - (desktopFrame.viewport / 2 - 260)) < 1,
      `the main column begins after the 260 px rail and 20 px gap (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(desktopFrame.appWidth - 800) < 1,
      `the main column matches the measured 800 px reference (${desktopFrame.appWidth}px)`);
    assert.ok(Math.abs(desktopFrame.appY - 44) < 1,
      `the main column starts below the fixed 44 px header (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(desktopFrame.brandX - desktopFrame.navX) < 1,
      `the z2kOW wordmark aligns with the left edge of the centered page shell (${JSON.stringify(desktopFrame)})`);
    assert.ok(Math.abs(await page.locator('#nav .nav-ico').first().evaluate(node => node.getBoundingClientRect().width) - 20) < 1,
      'sidebar icons match the reference size');
    assert.ok(await page.locator('#app').evaluate(node => node.getBoundingClientRect().width === 800),
      'all desktop routes use the reference 800 px content column');
    const surfaces = await page.evaluate(() => ({
      topbarShadow: getComputedStyle(document.querySelector('.topbar')).boxShadow,
      cardShadow: getComputedStyle(document.querySelector('#app .card')).boxShadow,
      cardRadius: getComputedStyle(document.querySelector('#app .card')).borderRadius,
      titleAnimation: getComputedStyle(document.querySelector('#app .page-title')).animationName,
      cardAnimation: getComputedStyle(document.querySelector('#app > .card')).animationName,
    }));
    assert.equal(surfaces.topbarShadow, 'none', 'the reference header has no decorative drop shadow');
    assert.equal(surfaces.cardShadow, 'none', 'cards use a border instead of a floating shadow');
    assert.equal(surfaces.cardRadius, '12px');
    assert.equal(await page.locator('#app .card .desc').first().evaluate(node => getComputedStyle(node).lineHeight), '17.92px',
      'card descriptions use the measured 14 px / 17.92 px Lolz rhythm');
    assert.equal(surfaces.titleAnimation, 'none', 'route changes do not add an unverified fade-slide effect');
    assert.equal(surfaces.cardAnimation, 'none', 'route changes do not stagger cards');
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
    assert.doesNotMatch(buttonStyle.transitionProperty, /transform/, 'buttons do not scale on press');
    const referenceCard = page.locator('#app > .card').filter({ has: page.locator('h3') }).first();
    await referenceCard.hover();
    const expectedCardHover = appearance === 'dark' ? 'rgb(24, 30, 28)' : 'rgb(225, 236, 233)';
    await page.waitForFunction(expected => getComputedStyle(document.querySelector('#app > .card h3')?.closest('.card')).backgroundColor === expected,
      expectedCardHover);
    const cardHover = await referenceCard.evaluate(node => ({
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
    await page.mouse.move(1, 1);
    const primaryStyle = await page.locator('#app .btn-primary').first().evaluate(node => ({
      backgroundImage: getComputedStyle(node).backgroundImage,
      text: getComputedStyle(document.documentElement).getPropertyValue('--btn-primary-text').trim(),
      stops: ['--ow-button-start', '--ow-button-mid'].map(name =>
        getComputedStyle(document.documentElement).getPropertyValue(name).trim()),
    }));
    assert.match(primaryStyle.backgroundImage, /linear-gradient/, 'primary actions use the reference green gradient');
    for (const stop of primaryStyle.stops) assert.ok(ratio(primaryStyle.text, stop) >= 4.5,
      `primary button text has readable contrast over ${stop}`);
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
    assert.match(await page.evaluate(() => getComputedStyle(document.body).fontFamily), /^Inter,/,
      'body typography uses the observed Inter-first font stack');

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
    const button = page.locator('#app .btn').first();
    const buttonBox = await button.boundingBox();
    await page.mouse.move(buttonBox.x + buttonBox.width / 2, buttonBox.y + buttonBox.height / 2);
    await page.mouse.down();
    assert.equal(await button.evaluate(node => getComputedStyle(node).transform), 'none',
      'press feedback does not scale controls');
    await page.mouse.move(1, 1);
    await page.mouse.up();
    await page.evaluate(() => document.activeElement.blur());

    for (const route of routes) {
      await page.evaluate(name => { location.hash = '#/' + name; }, route);
      await waitForRenderedRoute(page, route);
      const expectedNavRoute = ({ state: 'strategies', pick: 'strategies', whitelist: 'exclude', exclude: 'exclude',
        autohostlist: 'extra-domains' })[route] || route;
      const activeNavRoutes = await page.locator('#nav a.active').evaluateAll(nodes => nodes.map(node => node.dataset.route));
      assert.deepEqual(activeNavRoutes, [expectedNavRoute], `${appearance}: /${route} highlights its matching navigation item`);
      if (route === 'toggles') {
        const control = page.locator('#au-hour');
        assert.equal(await control.evaluate(node => getComputedStyle(node).minHeight), '36px',
          'desktop form controls match the 36 px reference height');
        assert.equal(await control.evaluate(node => getComputedStyle(node).borderRadius), '10px',
          'desktop form controls match the 10 px reference radius');
        assert.equal(await page.locator('.segmented .seg-btn.seg-on').evaluate(node => getComputedStyle(node).boxShadow), 'none',
          'selected segmented controls use a flat surface');
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
        const strategyControl = await page.locator('.state-table select').first().evaluate(node => {
          const style = getComputedStyle(node);
          const rect = node.getBoundingClientRect();
          return { width: rect.width, height: rect.height, radius: style.borderRadius };
        });
        assert.deepEqual(strategyControl, { width: 220, height: 36, radius: '10px' },
          'strategy selectors match the measured Lolz 220×36 control geometry');
      }
      assert.equal(await lockup.locator('.brand-profile-logo').count(), 1, `${appearance}: single mark on #/${route}`);
      if (screenshotDir && screenshotRoutes.includes(route)) {
        await page.screenshot({ path: path.join(screenshotDir, `${appearance}-1440-${route}.png`) });
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
    for (const width of [1920, 1366, 1280]) {
      await page.setViewportSize({ width, height: width === 1920 ? 1080 : 1104 });
      for (const route of routes) {
        await page.evaluate(name => { location.hash = '#/' + name; }, route);
        await waitForRenderedRoute(page, route);
        if (route === 'state') {
          await page.locator('.state-table').waitFor({ state: 'visible', timeout: 1500 });
          await page.waitForFunction(() => document.querySelectorAll('.state-table tbody tr').length >= 100, null, { timeout: 2000 });
        }
        assert.equal(await page.locator('#app [data-ui-fatal]').count(), 0, `${appearance}/${width}: ${route}`);
        assert.ok(await page.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth),
          `${appearance}/${width}: ${route} has no page horizontal overflow`);
        if (screenshotDir && screenshotRoutes.includes(route)) {
          await page.screenshot({ path: path.join(screenshotDir, `${appearance}-${width}-${route}.png`) });
        }
        if (screenshotDir && appearance === 'dark' && width === 1920 && route === 'dashboard') {
          const hoverCard = page.locator('#app > .card').filter({ has: page.locator('h3') }).first();
          await hoverCard.hover();
          await page.waitForFunction(() => getComputedStyle(document.querySelector('#app > .card h3')?.closest('.card')).backgroundColor === 'rgb(24, 30, 28)');
          await page.screenshot({ path: path.join(screenshotDir, 'dark-1920-card-hover.png') });
          await page.mouse.move(1, 1);
        }
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

  const fullHdShort = await browser.newPage({ viewport: { width: 1920, height: 480 } });
  await fullHdShort.goto(base + '/#/dashboard');
  await waitForRenderedRoute(fullHdShort, 'dashboard');
  await fullHdShort.waitForFunction(() => {
    const theme = document.querySelector('#brand-profile-theme');
    return theme && theme.sheet && theme.sheet.cssRules.length > 0;
  }, null, { timeout: 1500 });
  await fullHdShort.waitForFunction(() => Math.abs(document.querySelector('#nav').getBoundingClientRect().width - 260) < 1,
    null, { timeout: 1200 });
  assert.equal(await fullHdShort.locator('#menu-toggle').isVisible(), false,
    'a short Full HD browser window keeps the desktop sidebar');
  assert.ok(Math.abs(await fullHdShort.locator('#nav').evaluate(node => node.getBoundingClientRect().width) - 260) < 1,
    'a short Full HD browser window retains the desktop sidebar width');
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

  const mobile = await browser.newPage({ viewport: { width: 390, height: 844 }, colorScheme: 'dark', isMobile: true, hasTouch: true });
  await mobile.goto(base + '/#/dashboard');
  await waitForRenderedRoute(mobile, 'dashboard');
  assert.equal(await mobile.locator('#menu-toggle').isVisible(), true);
  const mobileTriggerBox = await mobile.locator('#menu-toggle').boundingBox();
  const mobileBrandBox = await mobile.locator('#panel-brand').boundingBox();
  assert.ok(mobileTriggerBox.x < mobileBrandBox.x, 'the mobile menu button sits to the left of the z2kOW wordmark');
  assert.ok(await mobile.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth),
    'compact layout must not create page-level horizontal overflow');
  await mobile.locator('#menu-toggle').click();
  assert.equal(await mobile.locator('#menu-toggle').getAttribute('aria-expanded'), 'true');
  assert.equal(await mobile.locator('#menu-shell').evaluate(node => node.classList.contains('mm-ocd--open')), true,
    'opening applies the observed MmenuLight shell state');
  assert.equal(await mobile.locator('body').evaluate(node => node.classList.contains('mm-ocd-opened')), true,
    'opening applies the observed body scroll-state class');
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
  for (const route of routes) {
    await mobile.evaluate(name => { location.hash = '#/' + name; }, route);
    await waitForRenderedRoute(mobile, route);
    assert.equal(await mobile.locator('#app [data-ui-fatal]').count(), 0, `mobile: ${route}`);
    assert.ok(await mobile.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth),
      `390px: ${route} has no page horizontal overflow`);
    if (screenshotDir && ['dashboard', 'strategies'].includes(route)) {
      await mobile.screenshot({ path: path.join(screenshotDir, `dark-390-${route}.png`), fullPage: true });
    }
  }
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
  for (const route of routes) {
    await mobile.evaluate(name => { location.hash = '#/' + name; }, route);
    await waitForRenderedRoute(mobile, route);
    assert.equal(await mobile.locator('#app [data-ui-fatal]').count(), 0, `mobile light: ${route}`);
    assert.ok(await mobile.evaluate(() => document.documentElement.scrollWidth <= document.documentElement.clientWidth),
      `390px light: ${route} has no page horizontal overflow`);
    if (screenshotDir) await mobile.screenshot({ path: path.join(screenshotDir, `light-390-${route}.png`), fullPage: true });
  }
  await mobile.emulateMedia({ reducedMotion: 'reduce' });
  assert.equal(await mobile.locator('#menu-shell .mm-ocd__content').evaluate(node => getComputedStyle(node).transitionDuration), '0s',
    'reduced motion disables drawer transitions');
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
