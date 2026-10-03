# z2kOW

z2kOW is an OpenWrt adaptation of [z2k](https://github.com/necronicle/z2k). The project keeps upstream z2k behavior and features as close as practical while replacing Keenetic/Entware-specific integration with native OpenWrt mechanisms.

## Project model

- Upstream z2k is the source of truth for product behavior, configuration semantics, strategies, WebPanel logic, update semantics, and user-facing features.
- OpenWrt-specific work belongs in the platform layer: procd, fw4/nftables, netifd/ubus/UCI, hotplug, filesystem paths, architecture selection, and release delivery.
- Existing upstream behavior is not redesigned just because the platform is different.
- z2kOW keeps its own signed release pipeline and OpenWrt-native install lifecycle.

See [UPSTREAM.md](UPSTREAM.md) for the parity policy and [ARCHITECTURE.md](ARCHITECTURE.md) for the platform boundary.

## Features

- z2k strategy engine, strategy rotation, custom strategies, and persistent state.
- RKN, YouTube, Discord, whitelist, exclusions, extra domains, and scheduled list maintenance.
- WebPanel for service control, configuration, lists, diagnostics, and release management.
- TCP16 line probing and related runtime integration.
- Optional Telegram transport, RT proxy, and WARP routing.
- OpenWrt service, firewall, network-event, and scheduler integration.
- Signed release metadata and complete OpenWrt release payloads with rollback-aware installation.

Some controls are exposed only when the installed OpenWrt platform provides the required capability.

## Requirements

- OpenWrt with `apk` package management.
- Root access.
- Network access during installation and updates.
- A target architecture supported by the published release.

## Install

Run as root:

```sh
wget -qO- https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh
```

If `curl` is already installed:

```sh
curl -fsSL https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh
```

The bootstrap installs only required OpenWrt system dependencies, verifies the signed z2kOW manifest and release artifact, then converges the selected release through `install_release`.

## WebPanel

Open:

```text
http://<router-address>:8088
```

The panel is intended for the local network. Do not expose it directly to WAN.

## CLI

```sh
z2kow status
z2kow check
z2kow update
z2kow restart
z2kow blocked-monitor status
```

The core service can also be controlled through OpenWrt init:

```sh
/etc/init.d/z2k start
/etc/init.d/z2k stop
/etc/init.d/z2k restart
```

## Updates and persistent data

Routers read only the controlled repository-root `UPDATES.json`. Upstream discovery by itself never publishes a device update.

Release-owned files live under `/usr/lib/z2k` and OpenWrt integration paths. Operator configuration, user lists, and persistent state live under `/etc/z2k` and are kept outside the replaceable release payload.

## Documentation

- [Documentation index](docs/README.md)
- [Architecture](ARCHITECTURE.md)
- [Upstream parity policy](UPSTREAM.md)
- [Upstream parity matrix](docs/UPSTREAM-PARITY-MATRIX.md)
- [Release policy](RELEASING.md)
- [Security model](SECURITY.md)

## License

MIT. See [LICENSE](LICENSE).
