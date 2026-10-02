// Verify the z2kOW credits wrapper in the real WebPanel document and Chromium.
// Run with PLAYWRIGHT_CHROMIUM_EXECUTABLE=/path/to/chromium node tests/browser/credits-page.mjs
import assert from 'node:assert/strict';
import fs from 'node:fs';
import http from 'node:http';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const { chromium } = await import(process.env.PLAYWRIGHT_MODULE || 'playwright');
const repo = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const www = path.join(repo, 'webpanel/www');
const brandAssets = path.join(repo, 'platform/openwrt/webpanel-brand');
const upstreamSource = fs.readFileSync(path.join(www, 'js/pages/credits.js'), 'utf8');
const upstreamNames = [...upstreamSource.matchAll(/<div class="credits-name">([\s\S]*?)<\/div>/g)]
  .map(([, name]) => name.replaceAll('&lt;', '<').replaceAll('&gt;', '>').replaceAll('&amp;', '&').trim());

const contentType = {
  '.css': 'text/css; charset=utf-8', '.html': 'text/html; charset=utf-8',
  '.js': 'application/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
  '.svg': 'image/svg+xml', '.png': 'image/png', '.woff2': 'font/woff2', '.ttf': 'font/ttf',
};
const server = http.createServer((req, res) => {
  const pathname = decodeURIComponent(new URL(req.url || '/', 'http://127.0.0.1').pathname);
  if (pathname.startsWith('/cgi-bin/api/')) {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({ ok: true, installed: 'p-86.1', running: true, platform: 'openwrt',
      capabilities: { policy: false, ppe: false, tcp16: false, diag: true, warp: true,
        telegram: true, uninstall: false, offload: true } }));
    return;
  }
  const assetPath = pathname.startsWith('/assets/openwrt/')
    ? path.resolve(brandAssets, `.${pathname.slice('/assets/openwrt'.length)}`)
    : path.resolve(www, `.${pathname === '/' ? '/index.html' : pathname}`);
  const allowedRoot = pathname.startsWith('/assets/openwrt/') ? brandAssets : www;
  if (assetPath !== allowedRoot && !assetPath.startsWith(allowedRoot + path.sep)) {
    res.writeHead(400); res.end('bad path'); return;
  }
  if (!fs.existsSync(assetPath) || !fs.statSync(assetPath).isFile()) {
    res.writeHead(404); res.end('not found'); return;
  }
  res.writeHead(200, { 'Content-Type': contentType[path.extname(assetPath)] || 'application/octet-stream' });
  fs.createReadStream(assetPath).pipe(res);
});
await new Promise(resolve => server.listen(0, '127.0.0.1', resolve));
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({
  headless: true,
  ...(process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE
    ? { executablePath: process.env.PLAYWRIGHT_CHROMIUM_EXECUTABLE } : {}),
});

try {
  for (const appearance of ['dark', 'light']) {
    const page = await browser.newPage({ viewport: { width: 1440, height: 1000 }, colorScheme: appearance });
    const errors = [];
    page.on('pageerror', error => errors.push(error.message));
    await page.addInitScript(mode => localStorage.setItem('z2k-theme', mode), appearance);
    await page.goto(`${base}/#/credits`);
    await page.waitForFunction(() => document.body.dataset.page === 'credits'
      && document.querySelector('#app .page-title')?.textContent.trim() === 'Благодарности');
    await page.waitForFunction(() => {
      const theme = document.querySelector('#brand-profile-theme');
      return theme?.sheet?.cssRules.length > 0;
    });

    const localSection = page.locator('#credits-openwrt');
    assert.equal(await localSection.count(), 1, `${appearance}: one primary z2kOW/OpenWrt section`);
    assert.equal((await localSection.locator('h2').innerText()).trim(), 'z2kOW / OpenWrt');
    assert.match((await localSection.locator('.credits-intro').innerText()).trim(),
      /Люди, которые помогают тестировать и поддерживать z2kOW на OpenWrt/);
    assert.equal(await localSection.locator('.credits-card').count(), 0,
      'upstream people are not promoted into local OpenWrt credits');
    assert.equal((await localSection.locator('[data-credit-empty]').innerText()).trim(),
      'Участники появятся здесь после подтверждённого вклада в z2kOW на OpenWrt.');
    const emptyStyle = await localSection.locator('[data-credit-empty]').evaluate(node => ({
      background: getComputedStyle(node).backgroundColor, radius: getComputedStyle(node).borderRadius,
    }));
    assert.equal(emptyStyle.background, appearance === 'dark' ? 'rgb(24, 30, 28)' : 'rgb(234, 241, 239)',
      'the empty state uses the measured Lolz secondary surface');
    assert.equal(emptyStyle.radius, '10px', 'the empty state uses the shared Lolz control radius');

    const upstream = page.locator('#credits-upstream');
    assert.equal(await upstream.count(), 1, `${appearance}: separate upstream disclosure`);
    assert.equal(await upstream.getAttribute('open'), null, 'upstream list starts collapsed');
    assert.equal((await upstream.locator('summary').innerText()).trim(), 'Upstream z2k / Keenetic');
    assert.match((await upstream.locator('.credits-upstream__description').textContent()).trim(),
      /Благодарности оригинального проекта z2k\. Указанные здесь тестирование и вклад относятся к upstream\/Keenetic и не означают тестирование z2kOW на OpenWrt\./);

    const disclosure = await upstream.evaluate(node => {
      const summary = node.querySelector('summary');
      const arrow = summary.querySelector('.credits-upstream__arrow');
      return { background: getComputedStyle(node).backgroundColor, radius: getComputedStyle(node).borderRadius,
        triggerHeight: summary.getBoundingClientRect().height, triggerRadius: getComputedStyle(summary).borderRadius,
        triggerBackground: getComputedStyle(summary).backgroundColor,
        arrowTransition: getComputedStyle(arrow).transition };
    });
    assert.equal(disclosure.background, appearance === 'dark' ? 'rgb(24, 30, 28)' : 'rgb(234, 241, 239)',
      'secondary container uses the measured Lolz surface 2 token');
    assert.equal(disclosure.radius, '12px', 'Lolz spoiler container radius');
    assert.equal(disclosure.triggerHeight, 34, 'Lolz spoiler button height');
    assert.equal(disclosure.triggerRadius, '10px', 'Lolz button radius');
    assert.equal(disclosure.triggerBackground, appearance === 'dark' ? 'rgb(24, 30, 28)' : 'rgb(234, 241, 239)',
      'Lolz spoiler button surface');
    assert.match(disclosure.arrowTransition, /0\.2s/, 'Lolz spoiler arrow timing');
    const summary = upstream.locator('summary');
    await summary.hover();
    assert.equal(await summary.evaluate(node => getComputedStyle(node).backgroundImage), 'none',
      'Lolz spoiler hover keeps its flat inherited surface');
    await page.mouse.down();
    await page.waitForTimeout(150);
    const activeStyle = await summary.evaluate(node => {
      const style = getComputedStyle(node);
      return { transform: style.transform, background: style.backgroundColor,
        image: style.backgroundImage, size: style.backgroundSize };
    });
    await page.mouse.up();
    assert.equal(activeStyle.transform, 'none', 'Lolz spoiler activation does not scale the button');
    assert.equal(activeStyle.background, appearance === 'dark' ? 'rgb(24, 30, 28)' : 'rgb(234, 241, 239)',
      'Lolz spoiler activation keeps its inherited surface');
    assert.equal(activeStyle.image, 'none', 'Lolz spoiler activation adds no button effect layer');
    assert.equal(activeStyle.size, 'auto', 'Lolz spoiler activation has no generic button scaling background');
    assert.equal(await upstream.getAttribute('open'), '', 'one click opens upstream credits');
    await page.waitForFunction(() => getComputedStyle(document.querySelector('#credits-upstream .credits-upstream__arrow')).transform !== 'none');
    const gridLayout = await upstream.locator('[data-upstream-grid] .credits-grid').evaluate(node => ({
      width: node.getBoundingClientRect().width,
      columns: getComputedStyle(node).gridTemplateColumns.split(' ').length,
    }));
    assert.ok(gridLayout.width >= 740, `upstream grid fills the content column (${JSON.stringify(gridLayout)})`);
    assert.equal(gridLayout.columns, 2, `desktop credits retain the source two-column density (${JSON.stringify(gridLayout)})`);
    const actualNames = (await upstream.locator('[data-upstream-grid] .credits-name').allTextContents())
      .map(name => name.trim());
    assert.deepEqual(actualNames, upstreamNames, 'the complete upstream list renders from its original module');
    await upstream.locator('summary').focus();
    await page.keyboard.press('Space');
    assert.equal(await upstream.getAttribute('open'), null, 'keyboard activation closes the upstream list');

    await page.setViewportSize({ width: 390, height: 844 });
    const mobileFrame = await page.evaluate(() => ({
      viewport: document.documentElement.clientWidth,
      scrollWidth: document.documentElement.scrollWidth,
      summary: document.querySelector('#credits-upstream summary').getBoundingClientRect().toJSON(),
    }));
    assert.ok(mobileFrame.scrollWidth <= mobileFrame.viewport,
      `${appearance}: credits page has no horizontal overflow at 390 px (${JSON.stringify(mobileFrame)})`);
    assert.ok(mobileFrame.summary.left >= 0 && mobileFrame.summary.right <= mobileFrame.viewport,
      `${appearance}: the disclosure trigger fits on mobile (${JSON.stringify(mobileFrame)})`);
    await upstream.locator('summary').click();
    assert.equal(await upstream.getAttribute('open'), '', 'upstream list remains one-tap on mobile');
    const mobileGridColumns = await upstream.locator('[data-upstream-grid] .credits-grid')
      .evaluate(node => getComputedStyle(node).gridTemplateColumns.split(' ').length);
    assert.equal(mobileGridColumns, 1, `${appearance}: upstream credits flow into one mobile column`);
    assert.deepEqual(errors, [], `${appearance}: no browser exceptions`);
    await page.close();
  }
  const touchPage = await browser.newPage({ viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true });
  await touchPage.goto(`${base}/#/credits`);
  await touchPage.waitForFunction(() => document.body.dataset.page === 'credits'
    && document.querySelector('#credits-upstream summary'));
  const touchTrigger = await touchPage.locator('#credits-upstream summary').evaluate(node => ({
    height: node.getBoundingClientRect().height,
    minHeight: getComputedStyle(node).minHeight,
    lineHeight: getComputedStyle(node).lineHeight,
  }));
  assert.deepEqual(touchTrigger, { height: 34, minHeight: '34px', lineHeight: '34px' },
    'touch devices keep the Lolz spoiler trigger at 34 px');
  await touchPage.locator('#credits-upstream summary').click();
  assert.equal(await touchPage.locator('#credits-upstream').getAttribute('open'), '',
    'the touch disclosure opens with one tap');
  await touchPage.close();
  console.log(`Credits page passed: dark + light; ${upstreamNames.length} upstream names preserved.`);
} finally {
  await browser.close();
  await new Promise((resolve, reject) => server.close(error => error ? reject(error) : resolve()));
}
