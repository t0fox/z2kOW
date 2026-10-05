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

## WireGuard server clients (WDTT)

`Z2K_WARP_WDTT` defaults to `0` and survives official config regeneration. OpenWrt identifies server-side WireGuard interfaces from UCI (`proto=wireguard` with a valid `listen_port`); client tunnel interfaces are excluded.

With WDTT off, traffic entering through those server interfaces stays direct. With WDTT on and at least one active WARP destination list, all client traffic entering through those interfaces receives the WARP mark, matching upstream WDTT scope. If no destination list is active, clients remain direct, including while selected LAN devices use full-device mode. The WebPanel updates the saved setting and asks the OpenWrt adapter to reconcile nft rules; failed reconciliation restores the previous setting.

## Native WireGuard client tunnels

OpenWrt UCI WireGuard interfaces without a `listen_port` are treated as client tunnels; interfaces with a configured listening port remain server interfaces and follow WDTT. In selected-device list mode, traffic entering a client tunnel is eligible for WARP when its source is in a private IPv4 range and its destination matches an active WARP IP/CIDR or learned domain pair. This path is independent of both the LAN device selection and the WDTT switch, matching upstream native WG/AWG client behavior. Public source traffic and unlisted destinations remain direct. Client tunnels do not receive a special full-device rule; the regular selected-source policy remains in effect there. DNS replies sent to these client interfaces are included in passive domain observation.

## Recovery

Firewall reload, WAN reconnect, reboot, or daemon failure must converge back to the configured state. Recovery must not leave stale policy rules that route traffic to a non-ready tunnel.
