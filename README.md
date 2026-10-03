# z2kOW

z2kOW adapts [z2k](https://github.com/necronicle/z2k) for OpenWrt routers. It uses OpenWrt services and firewall integration while sharing z2k's strategy engine and WebPanel.

## Features

- Manage traffic filtering strategies and persistent strategy state.
- Manage user lists and custom strategies.
- Use the WebPanel to control the service, edit settings and lists, and view diagnostics.
- Optional Telegram transport, RT proxy, and WARP routing integrations.
- Install and update from a signed, complete release payload.

The available controls depend on the router and the installed release. The WebPanel hides controls that the installed platform does not provide.

## Requirements

- An OpenWrt router with `apk` package management.
- Root access and an internet connection during installation and updates.
- A router architecture supported by the published release.

## Install

Run as root on the router:

```sh
wget -qO- https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh
```

Alternatively, if `curl` is already installed, run `curl -fsSL https://raw.githubusercontent.com/t0fox/z2kOW/main/scripts/openwrt/install.sh | sh`. The installer obtains required system tools with `apk`, verifies the signed release manifest and the complete payload, then installs the selected release.

## WebPanel

Open `http://<router-address>:8088` from the local network. The panel uses HTTP and is intended for local-network access. Keep it off public interfaces.

## Commands

Check for an available release and apply an update:

```sh
z2kow check
z2kow update
```

Show release and service status or restart the service:

```sh
z2kow status
z2kow restart
```

The service can also be managed through OpenWrt init:

```sh
/etc/init.d/z2k start
/etc/init.d/z2k stop
/etc/init.d/z2k restart
```

## Update

Use `z2kow check` to inspect the available release and `z2kow update` to apply it. Updates preserve configuration, state, and user lists.

## Remove

The current complete-payload installation does not expose a supported uninstall command in `z2kow` or the WebPanel. Do not use `apk del` to remove it; `apk` installs system dependencies and does not own the z2kOW payload. See the [release operations guide](docs/openwrt-release-operations.md) for current removal limitations and ownership details.

## Documentation

See the [documentation index](docs/README.md) for architecture, upstream parity, release, security, and platform contracts.

## License

MIT. See [LICENSE](LICENSE).
