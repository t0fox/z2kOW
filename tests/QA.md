# Test suite guide

Use the suite closest to the code you changed:

```sh
sh tests/openwrt/run.sh       # OpenWrt adapter and release contracts
sh tests/run_all.sh           # shared shell and application suites
sh scripts/ci_local.sh       # project CI checks available in the local environment
```

Run individual suites directly when narrowing a failure. OpenWrt fixtures exercise platform behavior with temporary files and command stubs; they do not replace checks on a router with the target architecture, network, packages, and firewall configuration.

The release workflow runs the configured CI gate before trusted publication. Release policy and device operations are documented in [RELEASING.md](../RELEASING.md) and [the OpenWrt operations guide](../docs/openwrt-release-operations.md).
