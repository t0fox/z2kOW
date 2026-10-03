# OpenWrt WebPanel contract

The WebPanel remains the shared z2k panel. OpenWrt adapts platform effects; it does not maintain a separate frontend fork.

## Ownership

- Shared panel code: `webpanel/`.
- OpenWrt panel adapter: `platform/openwrt/webpanel.sh` and the small platform seam in `webpanel/cgi/platform.sh`.
- Persistent panel settings: `/etc/z2k/webpanel/` and the canonical z2k config/state paths.
- Transient jobs/logs: `/tmp/z2k/`.
- Service owner: procd through `/etc/init.d/z2k-webpanel`.

LuCI/uhttpd are outside z2kOW ownership. The panel must not replace LuCI files or change OpenWrt ports 80/443.

Default z2kOW panel endpoint:

```text
http://<LAN-address>:8088
```

## Capability contract

The backend advertises a control only when the required OpenWrt implementation is present. Repository files that are not reachable in the installed payload are not sufficient evidence of a capability.

Platform-gated examples include TCP16, flow offload, custom.d, Telegram, WARP, and future operator actions. Keenetic-only controls must not be exposed through fake success paths.

CLI, WebPanel, updater, and diagnostics use the same canonical installed-release state.

## Mutations

Service actions go through procd-aware helpers. Firewall/network changes go through OpenWrt adapters. Release actions go through the controlled updater/install lifecycle.

List editing keeps the shared optimistic-concurrency behavior: the client saves against a content revision, stale writes are rejected, and accepted writes are validated and atomically replaced.

## Security

The panel is intended for the local network. Optional authentication must use an OpenWrt-compatible local backend and must not silently fall back to Keenetic `ndmc`/NDM behavior.

## Removal

When removal is exposed in the panel, it must call the same canonical OpenWrt uninstall backend as the CLI and preserve the same user-visible semantics as upstream z2k.
