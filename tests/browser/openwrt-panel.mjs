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
const root = fs.mkdtempSync(path.join(os.tmpdir(), 'z2k-openwrt-browser-'));
const www = path.join(root, 'www');
fs.cpSync(path.join(repo, 'webpanel/www'), www, { recursive: true });
const profileDir = path.join(www, 'assets/openwrt');
fs.mkdirSync(profileDir, { recursive: true });
for (const name of ['wordmark.svg', 'favicon.svg', 'theme.css', 'profile.json']) {
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
      // Keep backend status unavailable long enough to prove boot identity and
      // route rendering do not wait on the CGI endpoint.
      setTimeout(() => {
        statusResponsesCompleted += 1;
        res.writeHead(503, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ ok: false, error: 'fixture status unavailable' }));
      }, 3000);
      return;
    }
    const body = endpoint === 'extra-domains' || endpoint === 'whitelist'
      ? { ok: true, text: '', revision: 'fixture-r1', domains: [] }
      : endpoint === 'autohostlist-domains'
        ? { ok: true, domains: [] }
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

  const page = await browser.newPage({ viewport: { width: 1280, height: 900 } });
  const pageErrors = [];
  const moduleResponses = [];
  page.on('pageerror', error => pageErrors.push(error.message));
  page.on('response', response => {
    if (response.request().resourceType() === 'script' && new URL(response.url()).pathname.endsWith('.js')) {
      moduleResponses.push({ url: response.url(), status: response.status(), type: response.headers()['content-type'] || '' });
    }
  });

  await page.goto(`${base}/#/dashboard`);
  await waitForRenderedRoute(page, 'dashboard');
  await page.locator('#brand-profile-logo[src]').waitFor({ state: 'visible', timeout: 1200 });
  assert.equal(await page.title(), 'Дашборд · z2kOW');
  assert.equal(await page.locator('#panel-brand').getAttribute('aria-label'), 'z2kOW — OpenWrt edition');
  assert.equal(await page.locator('#brand-default-logo').evaluate(node => node.hidden), true);
  assert.equal(await page.locator('#brand-profile-logo').evaluate(node => node.naturalWidth > 0), true);
  assert.equal(await page.locator('#brand-profile-theme').getAttribute('href'), '/assets/openwrt/theme.css');
  assert.equal(await page.locator('#brand-profile-theme').evaluate(node => !!node.sheet && node.sheet.cssRules.length > 0), true);
  assert.equal(await page.locator('#brand-favicon').getAttribute('href'), '/assets/openwrt/favicon.svg');
  assert.equal(statusResponsesCompleted, 0, 'static OpenWrt identity is ready before /status completes');

  const routes = ['dashboard', 'toggles', 'strategies', 'warp', 'whitelist', 'exclude', 'extra-domains', 'diag', 'credits', 'state', 'pick', 'autohostlist'];
  for (const route of routes) {
    await page.goto(base + '/#/' + route);
    await waitForRenderedRoute(page, route);
  }
  assert.ok(apiRequests.some(request => request.endpoint === 'status' && request.marker === '1'), 'status fixture must receive the panel request marker');
  assert.ok(moduleResponses.length > 0, 'Chromium must load the real ES-module graph');
  for (const response of moduleResponses) {
    assert.equal(response.status, 200, `required module failed: ${response.url}`);
    assert.match(response.type, /javascript/i, `wrong module MIME: ${response.url} (${response.type})`);
  }
  assert.deepEqual(pageErrors, [], 'no uncaught browser exceptions across OpenWrt routes');

  // Simulate blocker behavior in Chromium itself: abort optional identity and
  // package-asset requests as ERR_BLOCKED_BY_CLIENT while checking every route.
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
  assert.doesNotMatch(await blocked.locator('#panel-brand').innerText(), /keenetic/i);
  assert.ok(blockedResourceFailures.some(item => item.path.endsWith('/js/core/identity.js')
    && item.error.startsWith('net::ERR_BLOCKED_BY_CLIENT')), 'identity request must be blocked by the browser: ' + JSON.stringify(blockedResourceFailures));
  for (const route of routes) {
    await blocked.evaluate(name => { location.hash = '#/' + name; }, route);
    await waitForRenderedRoute(blocked, route);
  }
  assert.deepEqual(blockedErrors, []);

  // Block only the optional stylesheet while leaving the static identity
  // profile available. The OpenWrt name survives and every route still renders.
  const themeBlocked = await browser.newPage();
  const themeErrors = [];
  themeBlocked.on('pageerror', error => themeErrors.push(error.message));
  await themeBlocked.route('**/assets/openwrt/theme.css', route => route.abort('blockedbyclient'));
  await themeBlocked.goto(base + '/#/dashboard');
  await waitForRenderedRoute(themeBlocked, 'dashboard');
  assert.equal(await themeBlocked.locator('#panel-brand').getAttribute('aria-label'), 'z2kOW — OpenWrt edition');
  for (const route of routes) {
    await themeBlocked.evaluate(name => { location.hash = '#/' + name; }, route);
    await waitForRenderedRoute(themeBlocked, route);
  }
  assert.deepEqual(themeErrors, []);

  // A genuinely broken required module graph receives a visible failure state.
  const broken = await browser.newPage();
  await broken.route('**/js/pages/dashboard.js*', route => route.abort('failed'));
  await broken.goto(`${base}/#/dashboard`);
  await broken.locator('#app [data-ui-fatal]').waitFor({ state: 'visible', timeout: 2000 });
  assert.match(await broken.locator('#app').innerText(), /Не удалось загрузить интерфейс/);

  console.log(`PASS: real Chromium OpenWrt document root; ${routes.length} routes; identity and theme blocker cases; broken-module error screen`);
} finally {
  await browser.close();
  await new Promise(resolve => server.close(resolve));
  fs.rmSync(root, { recursive: true, force: true });
}
