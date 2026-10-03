# OpenWrt WARP contract

WARP keeps upstream z2k user-visible semantics while OpenWrt owns process, firewall, routing, and filesystem integration.

## State model

WARP is optional.

- `install` installs a verified engine and registers device identity; it does not enable routing.
- `enable` starts the engine, waits for ready state, then enables policy routing.
- `disable` removes policy routing first, stops the active engine, and disables the feature.
- binary removal must not silently destroy persistent device identity unless the corresponding upstream action does so.
- self-heal is fail-open: if WARP is not ready, selected traffic must not be blackholed behind broken policy routing.

## Ownership

Persistent device identity and user selections live under `/etc/z2k`. Runtime status/logs live under `/tmp/z2k`. Release-owned game/list data lives under `/usr/lib/z2k`.

User-maintained WARP lists and release-maintained lists are separate ownership domains.

## OpenWrt network backend

The WARP engine uses the external-network backend on OpenWrt. OpenWrt, not the engine's Keenetic/iptables path, owns:

- nftables destination/source sets and packet marks;
- policy-routing rules and routing table;
- tunnel-interface convergence;
- cleanup and fail-open behavior.

Do not run the upstream iptables network backend in parallel with the OpenWrt nftables backend.

## Process lifecycle

procd owns the WARP process. The feature is started only when configuration, binary, and persistent device identity satisfy the enabled-state contract.

WebPanel, CLI/actions, scheduler self-heal, diagnostics, and service startup must all use the same WARP backend and the same persistent state.

## Lists and selected clients

Keep upstream filtering/validation semantics for destination lists and selected clients. OpenWrt adapters may change storage paths and nftables representation, not the meaning of accepted entries.

## Recovery

Firewall reload, WAN reconnect, reboot, or daemon failure must converge back to the configured state. Recovery must not leave stale policy rules that route traffic to a non-ready tunnel.
