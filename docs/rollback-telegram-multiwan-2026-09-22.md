# Retire Telegram UDP experiment; keep multi-WAN without native VPN capture

Requested after p-85.6–85.8 caused broad connectivity complaints. No release
manifest/version changes are part of this work.

## Rollback scope

Restore the Telegram client source and all shipped client binaries to p-85.5
(4192519), restore TCP/443 redirect and the old IPv6 fallback paths, and remove
UDP TUN startup, transport and periodic repair. Restore the pre-experiment
Discord/STUN strategy (remove the added send+drop in every circular arm).
Remove the Telegram-UDP-specific NFQUEUE exemption. Existing UDP helper names
are cleanup-only compatibility entry points for hooks/supervisors running
while an update replaces their files. Startup, stop and watchdog remove both
85.6 bit-mask and 85.7/85.8 exact-mask policy rules, table 988 routes and only
the experiment's netfilter rules. Other policy selectors at priority 89 survive.

Server UDP transport is removed from source too. Keep unrelated maintenance:
queue memory accounting, nginx fixes, instance switching, recycling and disk
maintenance. The VPS firewall helper now retires its exact tagged exceptions,
retaining the normal QUIC block and all unrelated live/persistent rules.
Deploying this server change is separate from previewing it on the owner's
router: the public fleet is still on p-85.8 until a release is authorized.

## Multi-WAN correction (superseded)

The all-table/blacklist approach below was an intermediate preview. The current
correction restores main-table discovery; see [WAN discovery](multiwan-2026-09-22.md).
The Telegram retirement and its recorded verification remain unchanged.

### Earlier implementation

The introduced regression was automatic discovery of all-table defaults with
no exclusion for native VPN interfaces. A fixture with main ppp0 and policy
usb0, nwg0, tun0 produced four outputs and therefore NFQUEUE on user VPNs.

Keep all-table/ECMP detection, deduplication, per-WAN repair, IPv4/IPv6 and
explicit WAN_IFACE. Automatic discovery filters native WireGuard/AmneziaWG,
TUN/TAP and known IP tunnels using names plus sysfs type/tun_flags. No netlink
link query is added (known hangs on unhealthy native WG). A hardware-backed
raw-IP USB modem with ARPHRD_NONE remains eligible; PPPoE/PPP remains eligible.
PPP-based ISP and user PPTP/L2TP connections cannot be distinguished by this
kernel type alone; this change does not invent an unreliable classification.
An explicit WAN_IFACE list remains the way to restrict those ambiguous cases.

Additive start_fw removes already-installed NFQUEUE rules for automatically
excluded devices, by exact z2k queue number. It leaves other queues, ISP rules,
explicitly selected VPNs and Keenetic routing/policies alone. The self-healer
uses the same discovery and cannot keep re-adding the excluded VPNs.

## Verification

Regression fixture failed before the change on native and renamed VPNs, while
explicit override already passed. A second fixture caught accidental exclusion
of a raw-IP USB modem. Both now pass. Stateful retirement checks cover both
families, duplicate old/new selectors, repeated cleanup, preservation of
another priority-89 policy/table and TCP redirect. Firewall cleanup checks
preserve another queue and explicit override. Self-healer covers a missing
secondary ISP and complete dual-ISP rules alongside VPN defaults.

No live dual-provider + VPN router or Aqara client is available in this session.
A successful local fixture/owner-router health check is not proof of every
reported user's calls or Aqara operation. Historical UDP design/field notes
remain as incident records, not descriptions of the current runtime.

## Owner-router preview and final validation

Full local CI passed (`/tmp/z2k-network-ci-final.log`): 4,131 assertions,
0 failures; 6 explicit environment skips (BSD-sed toggle + 5 absent rt-proxy
build-output comparisons). Go tests/race, vet, cross-build, reproducible shipped
binaries, mutation tests, linters and manifest gate passed. Subsequent exact-queue
and legacy TCP cleanup regressions were separately tested and linted after the
full run. The first CI run caught an intermediate empty shell clause in the VPS
deployer; fixed before the green final run.

Applied only to owner's router, with backup and failure rollback under
`/opt/z2k-network-preview-20260922/`. Config validator: 16 OK, 0 WARN, 0 FAIL.
Saved user WAN/policy/enable flags and native IPv4/IPv6 policy rule lists compare
unchanged after subtracting only the retired table-988 selector. The client
binary matches p-85.5 byte-for-byte (arm64 SHA256
bf2038e6a74922824421d6ba9ebcb929e6255b8fe847828a59ee118fd9d1d64b).

WAN detection on this router remains ppp0 for both families; six NFQUEUE rules
per family, all on ppp0. Generated Discord/STUN has no added send/drop. No
z2ktg0, ready marker, table-988 selector, Z2K_TG_UDP chain, expanded TCP selector
or expanded 2a0a:f280::/32 ipset entry remains. Running the installed watchdog
and NFQUEUE self-healer did not resurrect any of them. Telegram core and YouTube
HTTPS probes returned 200. GitHub API TLS still times out, as before this rollback;
this is not claimed fixed. No actual Telegram voice/Aqara test was performed.

Main service shutdown cleanup was also corrected to match queue 200 exactly,
not queue 2000 by prefix; fixture demonstrates another application's queue
survives while z2k's own rules are removed.

No public release, publication of the network branch or live VPS deployment.
A later release must regenerate config and restart both main and TG services,
so the retired client and STUN profile are actually replaced, not just copied.
