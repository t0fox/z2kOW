#!/bin/sh
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
export ROOT
node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import fs from 'node:fs';
const path = process.env.ROOT + '/webpanel/www/js/core/whitelist.js';
assert.ok(fs.existsSync(path), 'whitelist editor model is missing');
const {whitelistRows, replaceWhitelistSelection, selectWhitelistRange} = await import('data:text/javascript;base64,' + fs.readFileSync(path).toString('base64'));
const text = '# keep\na.example\n\nb.example\nc.example\n';
assert.deepEqual(whitelistRows(text), [{id:1,domain:'a.example'},{id:3,domain:'b.example'},{id:4,domain:'c.example'}]);
assert.equal(replaceWhitelistSelection(text,new Set([1,4]),'new.example\n'), '# keep\nnew.example\n\nb.example\n');
assert.equal(replaceWhitelistSelection(text,new Set([3]),''), '# keep\na.example\n\nc.example\n');
assert.equal(replaceWhitelistSelection(text,new Set(), 'ignored.example'), text);
assert.deepEqual([...selectWhitelistRange(new Set(),[1,3,4],1,4,true)], [1,3,4]);
assert.deepEqual([...selectWhitelistRange(new Set([1,3,4]),[1,3,4],4,3,false)], [1]);
assert.deepEqual([...selectWhitelistRange(new Set(),[3,4],1,4,true)], [4], 'hidden anchor cannot select hidden rows');
const large=Array.from({length:10000},(_,i)=>`host${i}.example`).join('\n');
assert.equal(whitelistRows(large).length,10000);
assert.ok(replaceWhitelistSelection(large,new Set([0,9999]),'').startsWith('host1.example\n'));
console.log('PASS: selection replacement preserves unselected rows/comments, range selection, hidden anchor, 10,000 domains');
JS
