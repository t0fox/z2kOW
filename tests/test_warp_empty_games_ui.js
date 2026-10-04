// The empty-state handler must describe the observed empty API response, then
// retry that same read-only API until lists arrive while the WARP page is open.
const fs = require("fs");
const vm = require("vm");
const source = fs.readFileSync(process.argv[2], "utf8");

function extract(start, end) {
  const from = source.indexOf(start);
  if (from < 0) throw new Error(`missing function ${start}`);
  const to = source.indexOf(end, from);
  if (to < 0) throw new Error(`missing boundary ${end}`);
  return source.slice(from, to);
}

const loadGames = extract("async function loadWarpGames() {", "function scheduleWarpGamesRetry() {");
const retryGames = extract("function scheduleWarpGamesRetry() {", "async function warpGameToggle(");
let responses = [
  { ok: true, games: [] },
  { ok: true, games: [{ name: "Steam", entries: 12, enabled: 0 }] },
];
let calls = 0;
let intervalCallback = null;
let intervalCleared = false;
const host = {
  innerHTML: "",
  querySelector(selector) {
    return selector === "[data-game]" && this.innerHTML.includes("data-game=") ? {} : null;
  },
  querySelectorAll() { return []; },
};
const context = {
  document: { getElementById: (id) => id === "warp-games" ? host : null },
  apiGet: async (path) => {
    if (path !== "/warp/games") throw new Error(`unexpected API path ${path}`);
    calls++;
    return responses.shift();
  },
  _newLoad: () => calls,
  _stale: () => false,
  escapeHtml: (value) => String(value),
  warpEntries: (count) => `${count} entries`,
  setInterval: (callback, ms) => {
    if (ms !== 60000) throw new Error(`unexpected retry cadence ${ms}`);
    intervalCallback = callback;
    return 17;
  },
  clearInterval: (id) => {
    if (id === null || id === undefined) return;
    if (id !== 17) throw new Error(`unexpected timer ${id}`);
    intervalCleared = true;
  },
  _warpGamesRetry: null,
  console,
};

(async () => {
  vm.runInNewContext(`${loadGames}\n${retryGames}`, context);
  await context.loadWarpGames();
  if (!host.innerHTML.includes("Панель проверит их снова автоматически")) {
    throw new Error("empty game response does not show an accurate retry state");
  }
  if (host.innerHTML.includes("источник был недоступен")) {
    throw new Error("empty game response is falsely reported as an upstream outage");
  }
  context.scheduleWarpGamesRetry();
  if (typeof intervalCallback !== "function") throw new Error("empty list did not start a retry timer");
  await intervalCallback();
  if (calls !== 2 || !host.innerHTML.includes('data-game="Steam"')) {
    throw new Error("retry did not reload and render the game list once it arrived");
  }
  if (!intervalCleared || context._warpGamesRetry !== null) {
    throw new Error("retry timer was not stopped after game lists arrived");
  }
  console.log("PASS: WARP empty lists are retried and render when available");
})().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
