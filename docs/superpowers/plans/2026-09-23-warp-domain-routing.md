# WARP Domain Routing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Route traffic for selected domain names from LAN clients through Z2K WARP, using DNS answers observed on the router and Cloudflare One domain-based Split Tunnels as the behavioral reference.

**Architecture:** Keep existing static IP/CIDR and whole-device WARP rules. Normalize selected lists once, pass exact/wildcard names to an observer in the optional WARP engine, and copy ordinary DNS replies through NFLOG. The observer maintains TTL-limited IPv4 destinations in one timeout `hash:ip` set per client; client-specific PREROUTING rules feed the existing ready-gated policy route.

**Tech Stack:** BusyBox ash/awk, iptables/ipset/NFLOG, Go 1.25.12 (`golang.org/x/net/dns/dnsmessage`, `golang.org/x/sys/unix`), existing CGI/JavaScript panel and shell/Go tests.

**Spec:** [2026-09-23-warp-domain-routing-design.md](../specs/2026-09-23-warp-domain-routing-design.md)

## Global Constraints

- The first version covers LAN devices using the router's DNS service or ordinary DNS replies that cross the router; DoH/DoT clients are outside this stage.
- Existing IPv4/CIDR lists and whole-device WARP selection keep their behavior.
- Exact names and `*.example.com` follow Cloudflare One's explicit matching semantics: the wildcard matches subdomains but not the apex.
- Internationalized names are entered in ASCII/Punycode form; IPv6 literals and AAAA-only names are unsupported.
- DNS remains untouched: no replacement DNS server, interception, redirect, queue, or change to Keenetic connection policies.
- At most 4,096 selected domain rules, 128 clients, and 8,192 live client/address pairs; positive TTL capped at one hour, zero TTL skipped.
- Only PREROUTING may set the WARP route mark, and only its existing `0x989` bit; OUTPUT/FORWARD are for passive DNS copies only.
- Missing NFLOG or a failed observer must leave static IP and whole-device routing working and let DNS pass normally.
- No full DNS query log or off-router transmission of query data; no release as part of this work.

## Review Focus

1. A selected name CNAMEs through an unselected alias: only A records reachable through that chain create a pair; pin in Task 2.
2. Two selected names on one client share an IP, then one name is disabled: keep the pair until neither name justifies it; pin in Task 3.
3. A forwarded DNS reply is unrelated to an established LAN DNS flow or has a spoofed source: NFLOG hook/observer must ignore it; pin in Task 4.
4. WARP starts with an old binary that lacks domain observation: static/device routes still work and domain status says unavailable; pin in Task 5.
5. A DNS answer contains an address in a private, documentation, CGNAT, multicast, or router-local range: no dynamic route; pin in Task 2.

## File map and interfaces

- `files/z2k-warp-list-filter.awk`: single canonical classifier/normalizer for address/domain list lines. Invoke as `awk -v mode=save|ipset|domains|count -f ...`; `save` prints accepted lines and comments, `ipset` prints static addresses, `domains` prints lowercase exact/wildcard names, `count` emits machine-readable `ip=N domain=N invalid=N` to stderr. Avoid a shell wrapper in hot paths.
- `files/z2k-warp.sh`: choose enabled lists, build static set and atomic domain snapshot `/tmp/z2k-warp/domains.v1`, create/remove DNS pair set, maintain ready-gated route and NFLOG lifecycle, expose status.
- `webpanel/cgi/actions.sh` and `files/z2k-update-lists.sh`: call the canonical filter for save/import and upstream game refresh; keep atomic replace and failure behavior.
- `z2k-warpd/internal/domainroute/rules.go`, `dns.go`, `cache.go`, `nflog_linux.go`, `ipset.go`, `snapshot.go`, `observer.go`: focused matching/parsing/state/kernel adapters. `Observer.Run(ctx)` owns netlink receive and periodic reconciliation. `Observer.Status()` supplies counts and a concise error state to a separate JSON status file. TCP DNS needs bounded per-flow reassembly because a response can span packets.
- `z2k-warpd/cmd/z2k-warpd/main.go`: start observer beside tunnel engine; observer failure is nonfatal to tunnel.
- `files/ndm/93-z2k-warp.sh`: restore passive DNS capture and pair mark after NDM regeneration.
- `lib/install.sh`, `lib/release_map.sh`: deliver the filter file and hook in full and patch installs.
- `webpanel/www/js/pages/warp.js`, `webpanel/cgi/api.sh`, `README.md`: domain terminology, split counts, visibility/limitations, status.
- `tests/test_warp_lists.sh`, `tests/test_warp_games.sh`, `tests/test_warp_script.sh`, `tests/test_warp_ndm_hook.sh`, `tests/test_panel_warp_ui.sh`, and new Go tests: contract and regression checks.

---

### Task 1: Canonical list grammar and delivery

**Files:** Create `files/z2k-warp-list-filter.awk`; modify `files/z2k-warp.sh`, `webpanel/cgi/actions.sh`, `files/z2k-update-lists.sh`, `lib/install.sh`, `lib/release_map.sh`; test `tests/test_warp_lists.sh`, `tests/test_warp_games.sh`.

**Interfaces:** Consumes selected file paths from `warp_active_lists()`. Produces normalized lowercase domain lines to a versioned snapshot (`v1` header plus one name per line), IPv4/CIDR lines to the existing static set, and save result fields `saved_ip`, `saved_domain`, `skipped_invalid` (keep legacy `saved` as their sum).

- [ ] **Step 1: Write failing shell tests.** Add table cases to `tests/test_warp_lists.sh`: `example.com`, `*.example.com`, `xn--e1afmkfd.xn--p1ai`, `Example.COM`, `1.2.3.4/24`, comment, `*.com`, `a..b`, `https://a.com`, `010.1.2.3`, `::1`. Assert normalized accepted lines, separate counts, and that disabled files are absent from domain snapshot. In `tests/test_warp_games.sh`, use a fixture with a domain and assert the sanitized upstream file retains it.
- [ ] **Step 2: Confirm red.** Run `sh tests/test_warp_lists.sh && sh tests/test_warp_games.sh`; expect the new domain assertions to fail because current three AWK blocks accept only IPv4/CIDR.
- [ ] **Step 3: Implement canonical filter and replace three copies.** Keep current IPv4 exclusions and strict leading-zero behavior. Domain grammar: ASCII labels 1–63 chars, letters/digits/hyphens with no edge hyphen, total DNS name at most 253 chars, at least two labels, alphabetic/Punycode TLD, optional leading `*.` only. Trim CR/outer whitespace; preserve `#` comments on save; lower-case domains; reject embedded whitespace and shell metacharacters. A caller can classify a line by testing `z2k_warp_addr_ok(s)` before `z2k_warp_domain_ok(s)`; emit only the mode's output. Write `domains.v1.new.$$`, validate the count cap, then rename atomically; on cap or write failure retain previous snapshot and report failure. Use the same filter for loader, CGI, updater. Add `files/z2k-warp-list-filter.awk` to install and release mapping (runtime path `/opt/zapret2/z2k-warp-list-filter.awk`).
- [ ] **Step 4: Confirm green and preservation.** Run `sh tests/test_warp_lists.sh && sh tests/test_warp_games.sh && sh -n files/z2k-warp.sh webpanel/cgi/actions.sh files/z2k-update-lists.sh lib/install.sh lib/release_map.sh`; expect pass. Check existing all-IP fixtures produce identical static set contents.
- [ ] **Step 5: Commit.** `git add files/z2k-warp-list-filter.awk files/z2k-warp.sh files/z2k-update-lists.sh webpanel/cgi/actions.sh lib/install.sh lib/release_map.sh tests/test_warp_lists.sh tests/test_warp_games.sh && git commit -m 'feat: accept domains in WARP destination lists'`.

### Task 2: DNS answer parser and name matching

**Files:** Create `z2k-warpd/internal/domainroute/rules.go`, `dns.go`, `rules_test.go`, `dns_test.go`.

**Interfaces:** `ParseRules([]byte) (Rules, error)` reads `domains.v1`; `Rules.Match(string) bool` uses exact/wildcard semantics. `ParseReply(packet []byte, transport Transport) (question string, answers []Answer, err error)` consumes DNS wire bytes (`TransportUDP` or `TransportTCP`) and returns only A answers connected to the question through CNAME edges; `Answer` carries `netip.Addr` and `time.Duration` TTL. `EligibleDestination(netip.Addr) bool` rejects non-public and router-local destinations; use local interface addresses as an additional caller-side exclusion.

- [ ] **Step 1: Write failing Go tests.** In `rules_test.go`, assert `*.example.com` matches `a.example.com` and `a.b.example.com`, but not `example.com`; names are case-insensitive; version mismatch/over 4,096 names fails. In `dns_test.go`, construct DNS messages with `dnsmessage.Builder`: direct A, CNAME→A, unrelated Additional A, malformed compression, truncated/oversized body, TCP two-byte length, duplicate A, zero TTL, and A values `10.0.0.1`, `100.64.0.1`, `192.0.2.1`, `224.0.0.1`, `127.0.0.1`. Assert only connected, eligible A records are returned and each TTL is the minimum along its CNAME chain.
- [ ] **Step 2: Confirm red.** Run `cd z2k-warpd && go test ./internal/domainroute`; expect failure because the package/API does not exist.
- [ ] **Step 3: Implement parser and matcher.** Parse exactly one DNS response with one question, QR=1, RCODE=NOERROR, bounded byte length (4,096-byte observation cap), and no truncated flag. Walk Answer-section CNAME edges with a visited-name set and depth bound 16; ignore Additional-section addresses. Use `dnsmessage.Parser` and `net/netip`; derive TTL with `min(chain TTL, A TTL)`. Reject multicast, unspecified, loopback, link-local, private, CGNAT, documentation, shared/reserved, and local interface IPs. Never resolve a name from Go or change client DNS.
- [ ] **Step 4: Confirm green.** Run `cd z2k-warpd && go test ./internal/domainroute`; expect pass, including Review Focus 1 and 5.
- [ ] **Step 5: Commit.** `git add z2k-warpd/internal/domainroute && git commit -m 'feat: parse selected WARP DNS answers safely'`.

### Task 3: Bounded client-pair cache and persistence

**Files:** Create `z2k-warpd/internal/domainroute/cache.go`, `ipset.go`, `snapshot.go`, `cache_test.go`, `snapshot_test.go`.

**Interfaces:** `Cache.Observe(client netip.Addr, name string, answers []Answer, now time.Time) []Change`; `Cache.ReplaceRules(Rules, now) []Change`; `Cache.Expire(now) []Change`. A `Change` is add/delete of `(client IPv4, destination IPv4, expiry)`. `PairSet.Apply([]Change, now)` writes timeout destinations to `hash:ip` set `z2kd_<client IPv4>` and its source-scoped PREROUTING mark rule. `Snapshot.Save/Load` use `/tmp/z2k-warp/domain-pairs.v1` and restore only unexpired, still-selected names.

- [ ] **Step 1: Write failing tests.** Fake clock and fake `PairSet` verify two clients stay separate, duplicate answer refreshes TTL, zero TTL does nothing, >1-hour TTL caps, 8,192th pair accepted and next pair skipped with counter, expiry deletes, and two matching names sharing `(client,IP)` retain it after one name is removed (Review Focus 2). Snapshot tests verify atomic write, corrupt/old version rejection, and no restore after a rule is disabled.
- [ ] **Step 2: Confirm red.** Run `cd z2k-warpd && go test ./internal/domainroute`; expect missing cache symbols/failing cache assertions.
- [ ] **Step 3: Implement bounded cache and adapter.** Track justifications keyed by `(client,IP,name)` and aggregate pair expiry as the latest still-valid justification. Save bounded state via temp-file/rename with mode 0600. Field probing found the Keenetic kernel rejects `hash:net,net` despite userspace help; use supported timeout `hash:ip` per client, cap at 128 clients, and add exact source-scoped mark rules. On command error retry full reconciliation; remove stale sets/rules at daemon restart and drop invalid/non-routable snapshot pairs.
- [ ] **Step 4: Confirm green.** Run `cd z2k-warpd && go test ./internal/domainroute`; expect pass, including the shared-pair deletion case. Run `go test -race ./internal/domainroute` on the development host.
- [ ] **Step 5: Commit.** `git add z2k-warpd/internal/domainroute && git commit -m 'feat: maintain bounded WARP DNS pair routes'`.

### Task 4: Passive NFLOG capture and observer lifecycle

**Files:** Create `z2k-warpd/internal/domainroute/nflog_linux.go`, `observer.go`, `nflog_test.go`, `observer_test.go`; modify `z2k-warpd/cmd/z2k-warpd/main.go`.

**Interfaces:** `Observer.Run(context.Context) error` loads/periodically reloads `domains.v1`, receives NFLOG group 189, identifies IPv4 destination LAN client and UDP/TCP DNS response, calls `ParseReply` then `Cache.Observe`; `Observer.Status() Status` writes `/tmp/z2k-warp/domain-status.json` with `active`, `pairs`, `rules`, `skipped`, `overflow`, and `error`. Tunnel engine `Run` keeps its existing status file and lifecycle.

- [ ] **Step 1: Write failing tests.** Build IPv4+UDP and IPv4+TCP DNS reply frames for both router OUTPUT and established FORWARD paths; assert client address is IP destination, source port 53 is required, malformed IP lengths/fragmented packets are ignored, and a TCP DNS response split across two segments is reconstructed only for the same flow and valid sequence. Bound TCP flow count, bytes, and idle age in tests. Put the established-connection/spoof rejection in Task 5's hook tests (Review Focus 3). Fake netlink reader verifies EOF/error marks observer unavailable without stopping engine; fake clock verifies periodic expiry and snapshot reload.
- [ ] **Step 2: Confirm red.** Run `cd z2k-warpd && go test ./internal/domainroute ./cmd/z2k-warpd`; expect missing observer/frame parsing behavior.
- [ ] **Step 3: Implement receive loop.** Open `NETLINK_NETFILTER` with `golang.org/x/sys/unix`, bind NFLOG group 189, request packet copy capped at 4,096 bytes, reject truncated netlink messages, decode IPv4/UDP and bounded TCP DNS streams, and feed only complete DNS replies to parser. Key TCP reassembly by source/destination IP and ports plus TCP sequence; cap at 128 flows, 4,096 bytes each and 5 seconds idle, then drop incomplete streams. NFLOG is observation only: never issue netfilter verdicts. On init failure write inactive status and leave `engine.Run` running. Start observer under the same context in `cmdRun`; ensure engine shutdown also ends observer and writes snapshot. Reload rules on mtime/content change and reconcile pairs when disabled names disappear.
- [ ] **Step 4: Confirm green.** Run `cd z2k-warpd && go test ./internal/domainroute ./cmd/z2k-warpd && go vet ./internal/domainroute`; expect pass and no races in observer tests.
- [ ] **Step 5: Commit.** `git add z2k-warpd/internal/domainroute z2k-warpd/cmd/z2k-warpd/main.go && git commit -m 'feat: observe LAN DNS replies for WARP routes'`.

### Task 5: Netfilter, WARP state, and rollback safety

**Files:** Modify `files/z2k-warp.sh`, `files/ndm/93-z2k-warp.sh`; test `tests/test_warp_script.sh`, `tests/test_warp_ndm_hook.sh`, `tests/test_warp_mss_both_ways.sh`.

**Interfaces:** The observer creates per-client `z2kd_<IPv4>` sets and source-scoped PREROUTING marks with `--set-xmark 0x989/0x989`; the shell and NDM hook restore/remove these marks by enumerating validated set names. Filter OUTPUT/FORWARD NFLOG copies use `--nflog-group 189 --nflog-range 4096` only while WARP is enabled (`--nflog-range` is the target router's actual iptables option). `warp_status()` appends observer state from its separate status file without changing existing fields.

- [ ] **Step 1: Write failing shell tests.** Stub iptables/ipset/daemon and assert each client DNS set has a source-scoped PREROUTING mark; OUTPUT/FORWARD NFLOG rules are scoped to IPv4 TCP/UDP `--sport 53` and LAN destinations, FORWARD includes `-m conntrack --ctstate ESTABLISHED` so a spoofed/new inbound reply is not copied (Review Focus 3), and rules appear only while enabled. Assert no route MARK in OUTPUT, mark mask unchanged, disable/remove delete copies and dynamic sets, selfheal and NDM regeneration restore only appropriate rules, and old engine/no status keeps static/device routing with `domain_active=0` (Review Focus 4).
- [ ] **Step 2: Confirm red.** Run `sh tests/test_warp_script.sh && sh tests/test_warp_ndm_hook.sh && sh tests/test_warp_mss_both_ways.sh`; expect new assertions to fail.
- [ ] **Step 3: Implement lifecycle.** Add idempotent create/delete/check helpers for DNS set and both NFLOG rules; use `iptables -w` and same readiness gate for all route marks. Keep observer capture while enabled even if tunnel is reconnecting; remove marks while not ready. NDM hook restores filter OUTPUT/FORWARD copies and mangle PREROUTING pair mark. Verify rule order against existing firewall and source LAN restriction on the router before field test. On old binary or missing NFLOG, leave capture inactive and static/device paths alive. Do not change router DNS settings.
- [ ] **Step 4: Confirm green.** Run the three shell tests plus `sh -n files/z2k-warp.sh files/ndm/93-z2k-warp.sh`; expect pass. Verify real creation/add/test/destroy of `hash:ip` with a dotted client name and `iptables -j NFLOG -h` on target router before deployment.
- [ ] **Step 5: Commit.** `git add files/z2k-warp.sh files/ndm/93-z2k-warp.sh tests/test_warp_script.sh tests/test_warp_ndm_hook.sh tests/test_warp_mss_both_ways.sh && git commit -m 'feat: route observed WARP domain pairs safely'`.

### Task 6: Panel, diagnostics, and acceptance

**Files:** Modify `webpanel/www/js/pages/warp.js`, `webpanel/cgi/actions.sh`, `webpanel/cgi/api.sh`, `README.md`; test `tests/test_panel_warp_ui.sh`, `tests/test_warp_lists.sh`; add `tests/test_warp_domain_status.sh`.

**Interfaces:** `/warp/status` returns existing fields plus `domain_active`, `domain_rules`, `domain_pairs`, `domain_error`. List save/import returns `saved_ip`, `saved_domain`, `skipped_invalid` while retaining `saved` for old clients.

- [ ] **Step 1: Write failing tests.** Assert panel says “Адреса и домены”, exact/wildcard example, ASCII/Punycode input, router/plaintext DNS visibility, IPv4 limitation, shared-IP caveat, and distinct saved counts. API tests assert inactive/error state when observer status is missing or malformed and never expose a client/query log.
- [ ] **Step 2: Confirm red.** Run `sh tests/test_panel_warp_ui.sh && sh tests/test_warp_domain_status.sh`; expect UI/API assertions to fail.
- [ ] **Step 3: Implement copy and status.** Keep existing editor layout; update label/help/toast/import copy. Read `domain-status.json` defensively and surface concise state/counts. Add a README section with enabled-list semantics, wildcard excluding apex, DNS requirements, TTL/limits, same-client shared-IP behavior, and failure behavior. Add CLI help if a relevant status/help line exists.
- [ ] **Step 4: Confirm green and full verification.** Run the two tests, `sh tests/test_warp_lists.sh`, `sh tests/test_warp_games.sh`, `cd z2k-warpd && go test ./...`, plus repository-required shell suites from `.github/workflows/ci.yml`. Run `sh -n` on changed shell files. Check release-map completeness for every added runtime file.
- [ ] **Step 5: Commit.** `git add webpanel/www/js/pages/warp.js webpanel/cgi/actions.sh webpanel/cgi/api.sh README.md tests/test_panel_warp_ui.sh tests/test_warp_lists.sh tests/test_warp_domain_status.sh && git commit -m 'feat: explain and report WARP domain routing'`.

### Task 7: Owner-router field verification without release

**Files:** No source files unless field evidence reveals a defect; record results in `docs/superpowers/plans/2026-09-23-warp-domain-routing.md` as a dated verification note.

**Interfaces:** Use existing SSH access to the owner's Keenetic router. Test only after all prior tasks pass, preserve config/list backup, and do not publish a release.

- [ ] **Step 1: Capture baseline.** Record `ipset list -n`, WARP status, mangle/filter relevant rules, DNS service state, CPU/RSS, and current tunnel readiness. Choose an exact test domain whose A answer is public and note a nonselected control name.
- [ ] **Step 2: Deploy current branch to owner router for evaluation.** Use existing project deployment procedure, verify installed filter and engine checksum/version, and confirm the existing WARP on/off choice and user lists survived.
- [ ] **Step 3: Exercise route lifecycle.** Resolve chosen name from one LAN client through router DNS; confirm only that client's `/32,/32` pair appears, ready-gated PREROUTING mark counters advance on its connection, another client and control name do not create pair, and expiry/list disable removes it. Repeat after NDM regeneration and warpd restart. If a real client lookup cannot be produced, use the project's packet/test fixture injection and clearly mark live-client routing unverified.
- [ ] **Step 4: Check collateral effects.** Confirm DNS replies are unaffected; compare ordinary sites, static WARP addresses, whole-device WARP, and router-originated traffic with baseline. Observe CPU/RSS under representative DNS load. Test missing observer by stopping it/using an older binary only in a controlled rollback window, then restore current binary.
- [ ] **Step 5: Document evidence and final review.** Add measured counters, command outputs (redact client identity/secrets), limitations, and rollback steps to the dated verification note; run `git diff --check` and `git status --short`. Commit only the note or necessary fixes. Do not tag, publish, or release.

### Field verification, 2026-09-23

- Owner Keenetic: KeeneticOS 5.1.5, Linux 4.9, aarch64. Its ipset userspace advertises `hash:net,net`, but the kernel rejects creation. An isolated probe confirmed timeout `hash:ip` sets and source-scoped `PREROUTING` matching; all temporary probe rules/sets were removed.
- Baseline before this deployment: `GAME_WARP_ENABLED=0`, no `/opt/sbin/z2k-warpd`, no WARP ipsets, no WARP mangle marks, no NFLOG group 189 rules. Current WARP choice was preserved.
- Deployed the new shell, filter, NDM hook, CGI actions/API, panel JavaScript and statically linked aarch64 engine to the owner router. All staged sha256 values matched local source/binary. Backup of overwritten files is `/opt/zapret2/.warp-native-backup-20260923/`; the engine and filter did not exist before deployment.
- Router checks: the engine executes (`z2k-warpd dev`), BusyBox awk accepts exact/wildcard domain filtering, `warp_domains_load` creates the v1 snapshot, and `warp_status` reports installed=1, enabled=0, ready=0, domain_active=0. A device record exists, but WARP remains off. There are still zero NFLOG group 189 rules and no WARP mangle rules. A live client DNS-to-route-to-tunnel test, packet counters, restart/NDM lifecycle under an active WARP tunnel, and performance measurements remain **unverified** because no tunnel was started. Do not infer routing success from the static/router checks.
- Rollback: with WARP off, restore the five backed-up files to their original paths, remove `/opt/zapret2/z2k-warp-list-filter.awk` and `/opt/sbin/z2k-warpd` (both absent at baseline), and confirm `GAME_WARP_ENABLED=0`, no `z2kd_` sets and no group 189 rules. No user lists or WARP enable flag were changed.
