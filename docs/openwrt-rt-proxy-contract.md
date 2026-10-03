# OpenWrt RT proxy contract

The RT proxy keeps upstream z2k proxy semantics. OpenWrt replaces Keenetic DNS, service, and firewall operations with native adapters.

## Runtime

- procd owns the RT proxy process.
- The proxy listens on the z2k RT local listener and uses the upstream proxy engine.
- The proxy's outbound sockets use upstream's exact `--so-mark` desync-bypass option, resolved from the shared runtime config, so the proxy does not feed itself back into nfqws2.

## DNS

OpenWrt uses owned UCI/dnsmasq host records for the exact RT hostnames required by upstream behavior. It must not use broad suffix overrides when upstream semantics are exact-host.

Only z2kOW-owned DNS records may be created or removed. Conflicting foreign records fail closed instead of being overwritten.

DNS updates are transactional: write owned records, commit, reload dnsmasq, then verify the effective result. A partial DNS state is not considered ready.

## Firewall

OpenWrt uses nftables for the RT redirect/fallback path. Rules are scoped to the RT feature and must not mutate unrelated fw4 state.

IPv4 and IPv6 handling should preserve the upstream client-fallback intent rather than blindly copying Keenetic iptables commands.

## Lifecycle

Preserve the upstream distinction between a process bounce and full teardown. A normal proxy restart should not unnecessarily remove DNS/firewall state and cause clients to cache a bypass path.

## Recovery

Health checks converge the feature toward ready state without restart storms. Disabled RT behavior is a valid state, not an error.
