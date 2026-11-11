// Проверяем боевую модель сортировки без копии её компаратора.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

(async () => {
  global.localStorage = { getItem: () => null };
  const source = fs.readFileSync(path.join(__dirname, '../webpanel/www/js/state-model.js'), 'utf8');
  const model = await import('data:text/javascript;base64,' + Buffer.from(source).toString('base64'));
  const now = 2000000000;
  const row = (host, age, key = 'tcp') => ({ host, key, ts: age === null ? 0 : now - age });
  const entries = [
    row('pair.net|4', 1440), row('pair.net|6', 86400),
    row('solo.org|4', 1560), row('hours.org|4', 7200), row('days.org|4', 172800),
    row('a.group.com|4', 120), row('b.group.com|6', 259200), row('c.group.com|4', null),
    row('a.group.com|4', 3600, 'quic'), row('b.group.com|6', 345600, 'quic'),
    row('missing.org|4', null), row('a.empty.com|4', null), row('b.empty.com|6', null),
  ];
  const snapshot = JSON.stringify(entries);
  const meta = new Map(entries.map(entry => {
    const name = entry.host.replace(/\|[46]$/, '');
    const group = model.groupDomain(name);
    return [entry, { name, group, gkey: entry.key + '|' + group, age: model.stateAge(entry.ts, now) }];
  }));
  for (const bad of [undefined, null, '', 0, '0', 'bad', NaN, Infinity, -1]) {
    assert.equal(model.stateAge(bad, now), null);
  }
  assert.equal(model.stateAge(String(now - 120), now), 120);
  assert.equal(model.stateAge(now + 1, now), 0);
  for (const dir of ['asc', 'desc']) {
    Object.assign(model.stateSort, { key: 'age', dir });
    const blocks = model.buildStateBlocks(entries, meta);
    const expected = dir === 'asc'
      ? [120, 1440, 1560, 3600, 7200, 86400, 172800, null, null]
      : [172800, 86400, 7200, 3600, 1560, 1440, 120, null, null];
    assert.deepEqual(blocks.map(block => block.age), expected, `${dir}: порядок видимых возрастов`);
    for (const block of blocks) {
      const ages = block.rows.map(entry => meta.get(entry).age);
      const known = ages.filter(age => age !== null);
      assert.equal(block.age, known.length ? Math.min(...known) : null);
      assert.deepEqual(ages, [...known].sort((a, b) => dir === 'asc' ? a - b : b - a)
        .concat(ages.filter(age => age === null)), `${dir}: порядок строк внутри группы`);
    }
    assert.equal(blocks.flatMap(block => block.rows).length, entries.length);
    assert.equal(JSON.stringify(entries), snapshot, 'ответ кэша не меняется');
  }
  console.log('[PASS] модель панели: возраст, группы, IPv4/IPv6, пустые отметки, оба направления');
})().catch(error => { console.error(error); process.exitCode = 1; });
