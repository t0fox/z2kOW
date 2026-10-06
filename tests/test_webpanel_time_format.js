const assert = require("node:assert/strict");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const sourcePath = path.join(__dirname, "..", "webpanel", "www", "js", "core", "time.js");
assert.ok(fs.existsSync(sourcePath), "the WebPanel shared time contract is implemented in core/time.js");
const source = fs.readFileSync(sourcePath, "utf8").replace(/^export /gm, "");
const context = vm.createContext({ Intl, Date, Number, String, Math });
vm.runInContext(`${source}\nglobalThis.time = { formatJobLog, humanAgo };`, context, { filename: sourcePath });

const epoch = Math.floor(Date.UTC(2026, 9, 6, 5, 7, 45) / 1000);
process.env.TZ = "Europe/Moscow";
assert.equal(context.time.formatJobLog(`@z2k-ts:${epoch}|Проверяю CDN`), "[08:07:45] Проверяю CDN",
  "epoch job records are displayed in the browser timezone, independent of router timezone");
process.env.TZ = "UTC";
assert.equal(context.time.formatJobLog(`@z2k-ts:${epoch}|Проверяю CDN`), "[05:07:45] Проверяю CDN",
  "the same epoch is displayed in UTC for a UTC browser");
assert.equal(context.time.formatJobLog("[05:07:45] legacy record"), "[05:07:45] legacy record",
  "legacy wall-clock lines remain unchanged because their timezone is unknown");

process.env.TZ = "Pacific/Honolulu";
assert.equal(context.time.humanAgo(940, 1000), "1 мин назад",
  "relative backend age uses server epoch and is independent of browser timezone");
assert.equal(context.time.humanAgo(1006, 1000), "время не синхронизировано",
  "future backend events are not presented as zero seconds ago");
assert.equal(context.time.humanAgo("invalid", 1000), "время не синхронизировано",
  "invalid backend timestamps are not presented as a valid relative age");

console.log("PASS: browser-local job times and server-relative event ages");
