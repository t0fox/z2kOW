const assert = require("node:assert/strict");
const fs = require("node:fs");
const vm = require("node:vm");

const source = fs.readFileSync(process.argv[2], "utf8");
const start = source.indexOf("function warpEdgeStatusCell(d) {");
const end = source.indexOf("\n}\n", start);
assert.notEqual(start, -1, "WARP geography presentation helper exists");
assert.notEqual(end, -1, "WARP geography presentation helper is complete");
const context = vm.createContext({});
vm.runInContext(source.slice(start, end + 2), context);
assert.match(source, /cells\.push\(warpEdgeStatusCell\(d\)\)/,
  "the WARP status renderer uses the tested geography presentation");

const locating = context.warpEdgeStatusCell({ edge_selection: "locating", edge_rtt_ms: 0 });
assert.equal(locating.value, "Определяю географию…");
assert.equal(locating.kind, "", "locating is never shown as healthy");

const unavailable = context.warpEdgeStatusCell({ edge_selection: "unavailable", edge_rtt_ms: "0" });
assert.equal(unavailable.value, "Географию определить не удалось");
assert.equal(unavailable.kind, "", "a failed geo lookup is never shown as healthy");

const partial = context.warpEdgeStatusCell({ edge_colo: "HEL", edge_country: "", edge_rtt_ms: 42 });
assert.equal(partial.kind, "", "partial metadata is not a confirmed location");
assert.equal(partial.value, "География не определена · 42 мс");

const located = context.warpEdgeStatusCell({ edge_colo: " HEL ", edge_country: " FI ", edge_rtt_ms: "42" });
assert.equal(located.value, "HEL · FI · 42 мс");
assert.equal(located.kind, "good");

console.log("PASS: WARP geography status reflects only complete Cloudflare metadata");
