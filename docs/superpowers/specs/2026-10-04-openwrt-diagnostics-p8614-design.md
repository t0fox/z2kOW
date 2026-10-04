# OpenWrt Diagnostics Parity with p-86.14

## Goal

Bring z2kOW's OpenWrt diagnostics to the same diagnostic meaning and usefulness as upstream `necronicle/z2k` `p-86.14` (`5e058c1c3944e0f0362cf9665b84108fc6e9b3dc`), while retaining OpenWrt-native evidence and the existing working runtime probes.

## Current Context

- z2kOW `main` already selects product release `p-86.14`, sequence `137`.
- The OpenWrt adapter already proves procd/runtime readiness, live `nfqws2` process details, strategy and circular-pool counts, detected autocircular state paths, WARP `route_ready`, nftables state, and offload state. These probes are the baseline to preserve.
- The current OpenWrt health path prints DNS and Insta details before the main diagnostic sections. Its firewall summary counts eight matching queue rules and all ruleset counters, without proving the owned incoming/outgoing paths or their traffic.
- The source-of-truth firewall contract is `z2k_ow_fw_verify()` in `platform/openwrt/firewall.sh`: the configured zapret2 table, `nozapret`/`nozapret6`, WAN sets, `postnat_hook -> postnat`, `prenat_hook -> prenat`, and the configured queue number.
- The specified upstream source is present in the task scratch checkout at the exact commit above. It is the behavior contract; its complete diagnostic file must not be copied over the OpenWrt implementation.

## Design

### Common diagnostics

Keep portable behavior in `files/z2k-diag.sh`. Reuse or restore upstream semantics there for relay ping, relay-relative clock skew, DNS snapshot parsing and age, common log filtering/masking, and rendering autocircular rows where the existing adapter boundary permits it. Common probes should not be duplicated in `platform/openwrt/diag.sh`.

The OpenWrt health section must render only `=== что не так ===` and its verdict. DNS snapshots, Insta/WhatsApp pins, DNS backend/AdGuard details, and OpenWrt panel/network facts belong after `=== network path ===`. A diagnostic probe must have one truth consumed by both the health verdict and detailed output. Preserve `unknown`, `unavailable`, `not-observed`, zero, and broken as distinct states.

### OpenWrt adapter and runtime evidence

Retain procd/ubus PID detection and live `/proc/<pid>/cmdline` and `/proc/<pid>/environ` interpretation, including all state-directory overrides. Do not replace current runtime strategy or autocircular detection with `ps w` or generated-config-only evidence.

For autocircular, render entries from the path selected by `_ow_autocircular_detect()` (`OW_AUTOCIRCULAR_STATE_FILE`), excluding blank/comment/header rows. Show 10 data rows in full mode and 40 in report mode, plus the detected persistent, runtime-primary, and fallback paths. Missing state while enabled is not by itself proof of failure.

For Telegram, identify the tunnel PID only when the command line has `tg-mtproxy-client` with `--listen=:1443`. Add the upstream three-packet VPS ping and HTTPS relay `Date` skew probe with the ±120 second threshold. Read recent meaningful log lines from the actual OpenWrt log path. Keep ordinary output compact; report output may include longer tails and must mask addresses wherever the common upstream report does.

For nftables, use only `${Z2K_ZAPRET_NFT_TABLE:-zapret2}` and z2kOW-owned chains. Report reachable outgoing (`postnat_hook -> postnat`) and incoming (`prenat_hook -> prenat`) queue paths separately, checking the configured queue number and hook jumps. Keep the queue consumer PID as a separate live-process proof. Report actual packet and byte counters for owned NFQUEUE paths (and owned offload-exemption paths only when they can be identified reliably); never count fw4 or unrelated queue rules. A zero counter is informational and must not alone make health fail.

WARP detail must expose the concrete OpenWrt routing proofs behind the existing `route_ready` state, such as the applicable tunnel device, policy rule/route, nft mark/forward path, selected address sets, and device selections. Reuse the current WARP status/verifier state so health and detailed output cannot disagree; do not create a second verifier.

Preserve the existing OpenWrt Insta/dnsmasq registration, runtime config, managed-hostname and refresh checks. Present how many managed hosts have records and whether the live dnsmasq configuration loads those records. DNS, pins and backend/AdGuard detail must answer whether clients can receive the managed pins; a missing rewrite count alone is not a failure.

The all-logs report must retain the upstream algorithm: z2kOW-owned current log paths, last 4,000 lines, seven-day window, both supported date formats, the specified error/failure terms, noise exclusions, 200-character line cap, repeat aggregation, compact/full versus longer/report tails, and report-mode address masking. Include current OpenWrt subsystem logs and exclude Keenetic-only paths.

### Non-goals

- Do not rewrite working OpenWrt probes or replace the adapter with a new diagnostic implementation.
- Do not copy Keenetic-only commands, paths, firewall layout, offload controls, panel architecture, or Entware assumptions.
- Do not use iptables for the OpenWrt firewall proof.
- Do not treat configuration as proof of live process state, a daemon as proof of dataplane health, a rule count as proof of path reachability, or counter presence as proof of traffic.
- Do not add a new product version/revision for this downstream fix.

## Regression Coverage

Add semantic regression cases to the existing OpenWrt shell fixture suite. The tests must verify behavior and verdicts, not merely snapshots of new labels.

1. Health contains no DNS/Insta detail; DNS and Insta detail appears in/after network path; health and detailed output agree.
2. Telegram exact `:1443` PID selection, rejection of `:1444`-only, three-packet ping/packet-loss parsing, clock skew at and beyond ±120 seconds, and meaningful log-tail output/masking.
3. Autocircular active persistent state, row count/render limits of 10/40, fallback and runtime-primary override paths, comments/headers excluded, and enabled-but-unobserved state not classified as broken.
4. Firewall outgoing/incoming present or missing independently, foreign table/rule exclusion, wrong queue exclusion, unreachable hook-jump detection, consumer PID separation, owned packet/byte counter parsing, foreign fw4 counter exclusion, and zero counters without a false health alarm.
5. WARP daemon-ready with broken route, missing tunnel device/route/nft path, all-ready state, and matching health/detail verdict.
6. DNS works/spoof/silent parsing, stale (>48-hour) snapshot, and missing snapshot.
7. Insta registered-and-active, runtime dnsmasq missing `addn-hosts`, user-disabled state, and refresh enabled/disabled.
8. Report-mode address masking and preservation of all existing diagnostic tests.

## Acceptance and Release

Before changes, compare the common diagnostic file with upstream `p-86.14` and record the portable-versus-OpenWrt dispositions. Run focused diagnostic tests, the OpenWrt test suite, and the applicable full CI gates on the exact candidate SHA.

On the current healthy OpenWrt runtime, capture a new `z2k-diag --report` and compare sections with upstream `p-86.14`. Verify service/runtime/strategy proofs, incoming and outgoing firewall paths, live queue consumer, owned counters, Telegram ping/clock/log, real autocircular rows, network-path placement, offload, WARP route proofs, and agreement between the issue summary and detailed sections. Record unavailable device evidence as not run; do not infer it from fixtures.

The repository already selects `p-86.14` / seq `137`. If that product release is already published, publish this downstream fix through the normal hotfix workflow: keep the product version and sequence, publish an immutable technical release named `openwrt-<exact source SHA>`, and update the production payload without creating a new Product Release. If it is not published, include the fix in the existing upstream-release workflow. In either case, completion requires green CI, successful publication, public `UPDATES.json` verification, signature verification, artifact SHA-256/size verification, and proof the public artifact corresponds to the exact source SHA.

## Questions to Resolve During Execution

- Identify the currently healthy OpenWrt device and available read-only access for live report capture; do not install, update, or otherwise alter the device during acceptance.
- Verify the production release state and publication credentials through the repository's existing release workflow before attempting publication.
- Derive exact expected queue-rule counts from the current firewall construction; do not hard-code a count until the owned chain structure establishes it.
