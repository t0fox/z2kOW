> Historical experiment, retired by the 2026-09-22 rollback. See [rollback scope](rollback-telegram-multiwan-2026-09-22.md).

# Telegram UDP recovery, 2026-09-22

## Scope and findings
User explicitly requested analysis, implementation and deployment while preserving transparent clients and our VPS path. No client proxy settings and no fleet release.

The p-85.6 client intentionally retained TUN routes across a WSS failure. This leaves selected LAN UDP going to a dead session. The same readiness file lets the watchdog retain that state. Changed recovery policy: revoke readiness before removing routes, clean partial setup, reconnect and install only after authentication. Native router policy is the temporary fallback while disconnected; this does not make blocked direct Telegram reachable.

Live NFQUEUE rules had no Telegram UDP exclusion, and the active generic discord,stun profile includes ports 3478–3481. Add a negative Telegram IP-set match to UDP queue rules only, source for incoming, destination for outgoing, IPv4 and IPv6. Preserve all other filters, NDM chains, policy marks and TCP. Explicit Telegram disable omits the exclusion. If shared sets cannot be created, omit the additional predicate rather than installing a rule referencing a nonexistent set.

This fixes confirmed recovery behavior and removes an identified processing overlap. It does not explain or claim to fix loss of TCP SYNs between home WAN and VPS noted earlier today.

## Verification
- TestUDPDisconnectWithdrawsRoutes failed on the old transport loop for disconnect and partial setup: stale routes and ready marker visible during cleanup. Both pass after the fix.
- Full mtproxy-client go test ./... passed (38.566 s); UDP race tests passed.
- test_tg_nfq_exclusion.sh first failed because Telegram UDP still entered NFQUEUE. Passed after fix, including both families/directions, add/remove symmetry, TCP, disabled feature and unavailable sets.
- Existing UDP policy collision/migration, transport coverage and self-heal tests passed.
- Full shell suite: 224 suites, 4150 checks passed, 0 failures, one BSD sed skip in test_auto_update_toggle.
- Shell syntax, repository ShellCheck policy and git diff --check passed.

## Router deployment and live evidence
Backup: /opt/z2k-incident-20260922/udp-recovery-before (client, S99, config, rules, list checksums). Only diagnostic arm64 client and S99 replaced. Diagnostic build p-85.7-udpfix1; official version stays p-85.7. Existing credential retained without logging it. UDP enabled.

Installed client SHA256: 8e5b4027e2ff7cd798f6933136bd058004908e98065f9cd4cca7e94a52daf63e.
Installed S99 SHA256: c9a6a657f7e7bda7be91ea8b3e1823c89b1e15bbe346515874b4a8dc7c7edc78.

At 13:15 MSK, closed only home UDP WSS socket (source port 49800) on VPS. Router observation: 13:15:18 ready absent; 13:15:19–20 policy rule 988 absent; 13:15:21 authenticated reconnect and rule restored. TCP tunnel stayed connected. Full-mask policy selector and Telegram-only routes/throw default retained.

At 13:16:08, a bounded diagnostic datagram sent by Mac 192.168.1.117 through en0 to 149.154.167.50:45999 was captured on VPS ens3 with source 213.176.74.63 and exact payload z2k-udp-recovery-20260922-proof.

Return-path test: Mac sent a distinct probe to port 45998. A diagnostic script observed its exact VPS UDP source port 43457 and injected a checksummed reply locally to that socket on the VPS (never spoofed onto the Internet). Mac received exact expected payload and original endpoint through WSS/TUN in 128 ms. This verifies controlled transport in both directions, NOT a Telegram-server response or successful voice call. No listener, broad firewall rule or allowlist expansion was needed.

Telegram HTTPS through production TCP tunnel returned 200, TLS 188 ms. Whitelist and extra-domains checksums remained identical. IPv4/IPv6 UDP NFQUEUE exclusions verified live. No production VPS service was restarted or changed.

## Limitations
No human call, TURN credentials or IPv6 LAN endpoint was available. Network-path outages to VPS remain a separate unresolved issue. Wider rollout must not be described as proven real-world voice reliability on this evidence alone.
