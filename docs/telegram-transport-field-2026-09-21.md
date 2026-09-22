# Telegram transport: router verification, 2026-09-21

## Applied on the test router

- Transparent Telegram TCP interception now includes 80, 443 and 5222. Original destination ports are preserved. Both replacement rules are checked before old 443 rules are removed; existing conntrack sessions are retained.
- IPv6 fallback covers the official `2a0a:f280::/32` prefix. NDM IPv6/filter events and the watchdog now restore IPv6 rules independently of IPv4 NAT. This is TCP fast rejection to allow IPv4 fallback, not an IPv6 tunnel or a UDP solution.
- The voice discovery profile explicitly sends the original UDP datagram after its decoys, then drops the queued original. Each of the six circular arms has its own tagged `send`/`drop` pair. Untagged actions after circular are not executed. Existing first-four-data-packet and discovery/STUN payload limits remain in place; RTP/media traffic is not resent by this change.
- Router helper, NDM hook, watchdog and configuration generator match the working-tree files by SHA-256. Live configuration was patched only in the voice profile. nfqws2 daemons were restarted; the Telegram tunnel process was not restarted.

## Evidence

The local probe is at `../../research/telegram-transport-2026-09-21/probe.go`, built with Go 1.25.13 for the router and VPS. It performs a bounded MTProto req_pq_multi/resPQ exchange with nonce validation, or a STUN exchange with transaction validation. Neither requires a Telegram account or makes a call.

| Probe | Before | After |
|---|---|---|
| Router → Telegram `149.154.167.51:443` | resPQ verified, 177 ms | verified, 180–191 ms |
| Router → same DC `:80` | timeout, 3 s | verified, 178–192 ms |
| Router → same DC `:5222` | timeout, 3 s | verified, 180–387 ms |
| VPS → same DC, all three ports | verified, about 31 ms | control baseline |
| Router → Cloudflare STUN `162.159.207.0:3478` | timeout | verified, 26–28 ms |
| LAN computer → same STUN | timeout | verified, 98 ms |
| Router/LAN → Google STUN `74.125.250.129:19302` | timeout | still timeout in the production profile |

WAN packet capture before the UDP change showed only 1357-byte decoys, with no original 20-byte STUN request. After the change it shows the 20-byte requests to both controls and a matching 32-byte reply from Cloudflare. The exact kernel mechanism losing the queued original was not established; this is an observed local packet-path defect, not proof of a particular ISP filtering rule.

An isolated queue-219 trial sent ten existing dbankcloud decoys followed by an explicit original datagram: both controls replied (27–45 ms). Google success did not reproduce after integration into the full profile, so it must not be advertised as fixed. Plain queue pass-through reached Cloudflare; fake-only and fake+badsum did not; fake+send+drop did. All trial rules and the trial daemon were removed. Only normal queue 200 remains, with zero recorded kernel/user queue drops at final inspection.

The NDM recovery test removed only the owned IPv6 OUTPUT rule, invoked the IPv6/filter hook and verified that both IPv6 rules were present again. The live IPv6 ipset has four members and two references.

## Calls: scope and unresolved coverage

The user cannot make a test call. No authenticated call, TURN allocation with session credentials, audio path, incoming call, group call or IPv6 UDP path was validated. Historical Telegram endpoints `149.154.167.255:596–599` and `149.154.175.211:599` did not answer unauthenticated STUN/Allocate probes from either the router or VPS; those failures cannot identify a router-side block.

Telegram supplies WebRTC connection addresses, ports and credentials during call setup. P2P and reflector/TURN paths differ. A fixed list of MTProto DCs and TCP ports cannot cover every call route. The current voice port filter is unchanged; discovery on other dynamic ports remains outside it. A general call solution may need signature-based STUN interception across ports and, where UDP itself is filtered, a separate UDP-capable tunnel. Neither is claimed implemented here.

Sources checked:

- [Telegram TCP/WebSocket transports](https://core.telegram.org/mtproto/transports).
- [Official Telegram CIDRs](https://core.telegram.org/resources/cidr.txt).
- [Telegram calls and session connection options](https://core.telegram.org/api/calls).
- [Reference manager](https://github.com/StressOzz/tg-ws-proxy-Manager); implementation comparison is in `telegram-reference-comparison-2026-09-21.md`.
- [Upstream signature-based STUN example](https://github.com/bol-van/zapret2/blob/master/init.d/custom.d.examples.linux/50-stun4all).

## Verification and recovery

- Transport migration/IPv6 hook tests pass locally and on BusyBox/router.
- Configuration generator: 121 passed, zero failed, including every circular arm's original-datagram handling. Two existing fixture-directory warnings remain in the unrelated pe-flag cases.
- Telegram diagnostics: 8 passed. Watchdog backoff: 17 passed.
- ShellCheck warning/error level passed for the changed redirect/hook/watchdog/test scripts (dynamic sourcing and existing POSIX-local usage excluded); pre-existing informational SC2012/SC2015 remain in the watchdog. `git diff --check` passed.
- Backups on router: `/opt/z2k-tg-backup-20260921/`, including original config and generator. To roll back voice handling, restore those two files and run `S99zapret2 restart_daemons`. To roll back Telegram interception, first remove the new rules using the current helper, restore the three saved scripts, then ensure rules using the restored helper.
- No commit, push, global release or alert configuration change was made.
