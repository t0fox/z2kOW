# Telegram server UDP relay

Release p-85.6 enables Telegram server UDP forwarding by default through
`--telegram-udp` in S98tg-tunnel. Both fresh installs and configurations from
older releases without the setting enable it. An explicit `Z2K_TG_UDP_RELAY=0`
is preserved and disables the feature. `TG_PROXY_USER_DISABLED=1` still
stops the complete Telegram tunnel. The updated VPS was deployed first.

This is a public test of call transport. Synthetic packet transport is
verified; an authenticated Telegram voice call has not been verified.

## Scope and routing

LAN bridge traffic (`br+`), UDP, and the Telegram IPv4/IPv6 destination sets
are the complete interception condition. Every destination port is eligible;
this includes authenticated TURN, TURN ChannelData and Telegram's opaque
custom reflector messages. P2P addresses outside these sets, third-party
STUN servers and router-originated UDP keep their existing routes.

On the VPS, `vps/bin/telegram-udp-firewall.sh --apply` adds only
Telegram IPv4 UDP/443 exceptions for the relay UID (nobody) ahead of the
existing general QUIC drop. It updates `/etc/iptables/rules.v4` atomically
after validation and preserves other rules; IPv6 had no such egress block.
The CIDR fixture is checked against both the router and server by a Go test.

The daemon owns `z2ktg0` (TUN, MTU 1500). After a successful UDP-capable relay
handshake, the helper installs policy table 988, preference 89, mark
`0x8000000/0x8000000`. Other mark bits are preserved. The selected packets skip
NDM acceleration/mark rewriting and masquerading; replies preserve the LAN
source tuple and must match an established conntrack entry. The helper,
NDM hook and watchdog restore the same rules under a shared directory lock. Setup failure rolls back both
families. Stop removes only this feature's rules/table. Existing TCP recovery
flushes TCP conntrack entries only.

After a detected WSS outage, the client revokes the ready marker and removes
UDP routing before reconnecting. The normal router policy handles traffic
until an authenticated UDP session is ready again; no stale TUN route owns it.
A new WSS session creates new UDP associations. ICE recovery across that change
is a Telegram client responsibility. Process exit removes the nonpersistent
TUN; the supervisor/stop path also cleans the rules. No keepalive daemon or
second identity is introduced.

When the Telegram feature is enabled, Telegram-subnet UDP is excluded from
NFQUEUE in both directions and address families. This is a negative IP-set
predicate on the existing queue rules, not an ACCEPT that bypasses NDM policy.
TCP and non-Telegram UDP retain existing zapret behavior. An explicit
TG_PROXY_USER_DISABLED=1 restores the original queue selection on rebuild.

IPv4 fragments and IPv6 extension/fragment headers are not reassembled.
Supported UDP payloads are at most 1472 bytes for IPv4 and 1452 for IPv6;
ordinary voice/reflector packets fit. Jumbo datagrams are not supported.
IPv6 support was exercised through router-originated **temporary test-only**
routing; the test laptop had no IPv6 LAN address. IPv6 LAN bridge forwarding
has the same installed rule shape but was not tested with an IPv6 LAN device.

## Wire contract

- Separate WSS connection to `/ws?transport=udp-v1`.
- WebSocket subprotocol `z2k-udp-v1` must be negotiated. An old relay cannot
  accidentally interpret the connection as TCP. No downgrade to v1.
- Existing v2 HELLO / HELLO_ACK / signed per-install AUTHID / INFO AUTH_OK.
- Binary message: `uint16_be association_id | 0x20 | endpoint | datagram`.
  IDs are nonzero. Endpoint is `0x01 | IPv4[4] | port_be[2]`, or
  `0x04 | IPv6[16] | port_be[2]`. Empty UDP datagrams are valid.
- Each message carries one datagram, including its endpoint. First use of an
  ID opens a connected UDP socket. Subsequent packets must use that same
  endpoint. Replies carry the same ID/endpoint. Only that socket's peer can
  supply reply packets. The client checks the endpoint against its flow map
  and reconstructs IP/UDP headers and checksums for the original LAN tuple.
- Malformed frames, forbidden addresses, a changed live endpoint and TCP
  message types terminate the UDP session. Unknown or expired reply IDs are
  discarded. UDP has no byte-stream window or CONNECT retry semantics.

## Bounds

One authenticated UDP WSS session per install, 64 associations per session,
2048 UDP sessions and 4096 UDP sockets per VPS process. The server accepts
only the explicit Telegram ranges, independently of TCP `--extra-cidrs`.
Private/local/multicast, IPv4 network/broadcast and IPv4-mapped IPv6 targets
are rejected. DNS names are not accepted.

Each direction is limited to 500 packets/s and 512 KiB/s per install, with
bursts of 200 packets / 256 KiB. Each outbound WSS queue holds at most 64
packets; media older than 200 ms in that queue is discarded. A blocked WSS
write expires after one second. UDP socket writes expire after 200 ms, and
associations expire after 90 seconds without outbound traffic. UDP counters
are exposed as `relay_udp_datagrams_total` and `relay_udp_drop_total` in the
existing metrics endpoint. Alerts remain disabled.

The voice connection is separate from file/message TCP multiplexing. WSS is
still TCP underneath: loss can delay following voice packets. This is an
accessibility fallback, not a guarantee of low jitter.

## Verification, 2026-09-21

- Go tests and race detector: opaque datagram sizes (including zero), four
  concurrent source flows, endpoint matching, malformed lengths/checksums,
  forbidden destinations, per-install quota, rate refill, stale queue drop.
- Routing tests: capability gate, both families, repeated repair without
  duplicate policy rules, LAN-only selectors, full cleanup and rollback if
  IPv6 setup fails.
- Real Keenetic → isolated VPS relay → controlled UDP echo: 2000/2000 packets,
  four simultaneous flows, payloads 20/160/1200/1472, no corrupt or crossed
  replies. Direct WSS median RTT approximately 105 ms, p95 143–149 ms.
- Same direct WSS path with concurrent TCP echo traffic (5.18 MB in 14 s):
  2000/2000 UDP packets; median RTT 107–108 ms, p95 184–194 ms. This modest
  synthetic load does not establish performance under link saturation.
- IPv6 through TUN/WSS/VPS: successful echo for 0/20/1200/1452-byte payloads.

The echo server was controlled by us; temporary VPS DNAT rules applied only
to the isolated root-owned test relay's synthetic destinations/ports. The
production relay runs as nobody. No external UDP destinations were added to
the production allowlist. Lab services, temporary port exposure and packet rewrites were removed
after validation.

A real Telegram call was not made. Custom reflector authentication remains
end-to-end in the Telegram application. These tests establish transparent
packet transport, not success of every client version or call topology.

## Live rollout

VPS instance a runs `p-85.5-udp1` after the normal a/b switch; instance b is
stopped. The test router runs the matching client with `Z2K_TG_UDP_RELAY=1`.
The flag is preserved by config regeneration and the installer's existing
`Z2K_*` preservation path. Both WSS channels authenticated against the
production endpoint; a TCP HTTPS check returned 200. An external-interface
capture confirmed a diagnostic UDP packet left the production VPS for its
original Telegram endpoint, including UDP/443 after the firewall exception.
The full CI passed; later config/routing/firewall adjustments were checked
with targeted tests, repeated live application and concurrent router repair.
The initial deployment was local and opt-in. Release p-85.6 distributes the
client and enables the feature by default for public testing.

Rollback binary backups: VPS `/root/z2k-udp-deploy-20260921/relay.before`,
router `/opt/z2k-udp-backup-20260921/`. Disable the router feature with
`set_flag Z2K_TG_UDP_RELAY 0 /opt/zapret2/config` (source `lib/utils.sh` first),
then restart S98tg-tunnel. The TCP service remains enabled. Persistent
firewall backup: `/etc/iptables/rules.v4.z2k-udp.bak`.
