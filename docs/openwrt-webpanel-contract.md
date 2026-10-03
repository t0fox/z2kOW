# OpenWrt WebPanel contract

The shared z2k WebPanel runs on OpenWrt through a small platform adapter. The common API and frontend remain shared; OpenWrt-specific filesystem, service, firewall, and network operations belong to `webpanel/cgi/platform.sh` and `platform/openwrt/webpanel.sh`.

## Ownership and paths

- `webpanel/cgi/` and `webpanel/www/` are part of the complete release payload.
- `/etc/z2k/webpanel/` stores operator-selected panel settings.
- `/tmp/z2k/` stores generated configuration, logs, jobs, and other transient files.
- `/etc/init.d/z2k-webpanel` owns the panel's procd service. The core service and WebPanel have separate lifecycles.
- LuCI and uhttpd remain OpenWrt-owned. The panel must not modify `/www/cgi-bin/luci`, `/www/luci-static`, `/etc/config/uhttpd`, or their ports 80 and 443.

The default panel bind is the detected LAN address on port `8088`. It uses HTTP. The panel is intended for local-network access; it must not bind automatically to WAN or a public interface.

## Platform capabilities

The API reports capabilities through `/status`; the frontend uses them to hide controls without an OpenWrt implementation.

| Capability | OpenWrt behavior |
|---|---|
| Core service, strategies, config, lists, and diagnostics | Shared WebPanel backed by OpenWrt paths and procd; diagnostics delegate to the OpenWrt adapter. |
| Telegram and WARP controls | Routed through the existing OpenWrt service adapters. |
| TCP16 | Advertised only when the probe, detector, Lua module, and required data files are present in the installed payload. |
| Custom DNS and flow offload controls | Advertised only when their OpenWrt prerequisites are available. |
| Keenetic policy routing, PPE, fast route, uninstall | Not advertised as OpenWrt capabilities. |

The capability response in `webpanel/cgi/platform.sh` is the source of truth for current exposure. Do not infer support from dormant common frontend routes or files present in the repository.

## Security and lifecycle

The panel uses the common request-origin checks. Optional password authentication is disabled by default. A password does not make WAN exposure safe; see the project [security model](../SECURITY.md).

WebPanel updates use the same controlled release manifest and complete rootfs installation as the rest of z2kOW. Panel template refreshes and service operations must not restart or reconfigure LuCI/uhttpd. Installing or updating the core and stopping the core service must preserve the panel's independent lifecycle.

The current CLI and WebPanel do not expose uninstall. Internal cleanup functions are not operator-facing commands.
