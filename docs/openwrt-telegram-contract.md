# OpenWrt Telegram transport contract

The Telegram feature keeps upstream z2k transport behavior while replacing Keenetic service and firewall mechanics with OpenWrt owners.

## Runtime

- One Telegram client process serves the transparent Telegram path and CDN path.
- procd owns the process lifecycle.
- Persistent relay identity/config lives under `/etc/z2k`; transient logs/state live under `/tmp/z2k`.
- Architecture-specific binaries come from the signed OpenWrt release payload.

User disable/enable semantics follow upstream. Disabling the feature removes its active routing/firewall effect and stops the owned runtime without touching unrelated services.

## Firewall

OpenWrt uses nftables inside the z2k runtime firewall ownership model. It does not reproduce raw iptables/ipset commands.

The adapter owns only Telegram-specific sets/chains/rules:

- IPv4 Telegram DC traffic is redirected to the local Telegram listener.
- Telegram CDN traffic is redirected to the CDN listener.
- IPv6 Telegram DC handling preserves the upstream fast-fallback intent.
- Router-local and forwarded traffic are handled deliberately; direct WAN access to local listener ports is not opened.

Rules must be idempotent and recoverable after fw4/network events.

## Health and recovery

OpenWrt keeps the upstream health intent with platform-native actions:

- procd handles dead-process respawn;
- the health path verifies required nftables state and listener readiness;
- active probe failure uses bounded recovery rather than restart loops;
- a disabled feature is not treated as unhealthy.

## Boundaries

Do not add a second Telegram implementation in WebPanel or scheduler code. WebPanel, diagnostics, cron health checks, and service startup must all delegate to the same OpenWrt Telegram backend.
