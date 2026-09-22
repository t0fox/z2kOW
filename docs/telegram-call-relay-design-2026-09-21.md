# Telegram calls through our VPS: research and implementation boundary

Initial research. The follow-up implementation and measured limitations are
documented in [telegram-udp-relay.md](telegram-udp-relay.md).

## Findings

1. `mtproxy-client/listener.go` accepts transparently redirected IPv4 TCP.
   `vps-relay/wire.go` defines CONNECT/DATA/CLOSE byte-stream frames;
   `vps-relay/main.go` dials TCP. There is no UDP association/datagram protocol.
   Passing MTProto does not pass WebRTC media.
2. The earlier STUN discovery fix is local, uncommitted test-router work. It
   was not included in published p-85.5. Even deployed everywhere, it would
   not provide UDP transport through the VPS.
3. Telegram supports both ordinary STUN/TURN and custom reflectors. At
   tgcalls revision `efd330ca04f74706024a5abdfb5b41f4e4dd1065`,
   `tgcalls/v2/ReflectorPort.cpp::SendReflectorHello` uses a call-specific
   peer tag and custom framing. Plain unauthenticated STUN/Allocate probes
   are not a valid health oracle for these reflectors.
4. Desktop `calls_call.cpp::AppendServer` consumes per-call IP, IPv6, port,
   peer tag and TCP flag; the WebRTC variant supplies STUN/TURN credentials.
   TCP reflectors exist, but a transparent router cannot make every client
   choose one. Adding static ports 596–599 is not complete coverage.
5. Calls can use P2P to another subscriber's IP, outside Telegram's subnets.
   A Telegram-only destination allowlist cannot cover every direct call.
   Disabling call P2P in the application makes relay-only testing more
   deterministic; it cannot be silently forced via encrypted MTProto traffic
   by our router. Reflector addresses still need evidence-based coverage.
6. A generic coturn server on our VPS is not automatically discovered by
   Telegram. The application obtains call connection options from Telegram;
   a packet tunnel should preserve those options and their authentication.

## Recommended first implementation

Transparent, opt-in **Telegram relay UDP** forwarding through an independent
TLS/WSS connection to the existing VPS. This targets reflector/TURN calls,
not arbitrary P2P endpoints. It forwards opaque datagrams and does not
implement Telegram codecs, decrypt calls or fabricate TURN credentials.

Path: LAN client → router packet interception → authenticated voice transport
→ VPS UDP socket → original Telegram reflector/TURN → reverse path.

- Router: use a dedicated TUN and policy route for the approved destination
  ranges. `/dev/net/tun` exists on the test Keenetic. TPROXY is not currently
  registered in `/proc/net/ip_tables_targets`; availability of a loadable
  module was not established. Do not assume an existing TCP REDIRECT plus
  SO_ORIGINAL_DST implementation works unchanged for UDP.
- Preserve a flow mapping from LAN source IP:port, destination IP:port and
  address family to a VPS UDP socket. Return packets must reach the original
  LAN tuple with the expected source endpoint. Do not migrate an established
  ICE flow midway to a different egress mapping.
- Authenticate with the existing per-install identity model, but negotiate a
  new explicit capability/version or separate endpoint. Old relays/clients
  must reject unsupported UDP modes cleanly, not reinterpret datagrams as
  stream bytes. Proposed logical messages: associate(destination), datagram,
  association-close/error. Preserve packet boundaries and validate lengths.
- Voice must have a separate underlying TCP connection from files/messages.
  A separate logical stream in the existing shared WebSocket does not remove
  TCP head-of-line blocking. UDP-over-TLS can still stall on retransmission;
  it is a bypass fallback, not a latency guarantee. A usable authenticated
  QUIC/UDP transport would avoid TCP-wide ordering, but its reachability must
  be measured rather than assumed.
- Bound packet size, per-install association count, aggregate queued bytes,
  idle lifetime and send rate. Prefer dropping stale queued media over
  accumulating seconds of audio. Apply destination allowlists and reject
  private/local/multicast/broadcast targets on the server. This must not
  silently turn the restricted Telegram relay into a general UDP proxy.
- Route whole selected UDP flows, not merely STUN-looking packets: TURN
  ChannelData, custom reflector packets and encrypted media follow discovery.
  Handle IPv6 explicitly; current Telegram TCP IPv6 fast-reject is irrelevant
  to IPv6 UDP.
- Existing `z2k-warpd` contains TUN lifecycle/NAT and capsule framing patterns
  worth reusing. Its current H2 transport is Cloudflare-specific CONNECT-IP
  with a documented nonstandard payload; it is not a ready-made generic
  CONNECT-UDP server for our VPS.

## Lower-effort alternatives and limits

- Native SOCKS5 inside Telegram: Desktop supports a “use proxy for calls”
  branch, but behavior depends on client and reflector transport. Merely
  adding UDP ASSOCIATE to a SOCKS server is not proof it will be used.
- Native TCP reflector interception: could reuse our byte-stream relay for
  connections that already choose TCP and target an allowed address. Useful
  as additional coverage, not a complete call fix.
- A maintained TUN-capable proxy with UDP-over-TCP support on router and VPS
  is a useful reference/isolated baseline before extending our own protocol.
  It still needs routing scope, identity integration and device resource
  checks. No third-party service or daemon was installed in this investigation.

## Verification without asking the user to call

Build a bounded lab first: two synthetic UDP endpoints through the router/VPS
path, plus an authenticated STUN/TURN test service controlled by us. Check
bidirectional datagram boundaries, source mapping, simultaneous LAN clients,
idle expiry, reconnect cleanup, mixed voice/file load, MTU and loss/jitter.
Measure sustained small-packet delivery, not just one STUN response. Test
malformed frames, forbidden destinations, quotas and compatibility separately.

These checks can demonstrate the packet transport without a personal call.
They cannot establish all Telegram client/reflector behavior. A full automatic
Telegram call test needs controlled accounts/devices and call-specific
credentials; neither is available or assumed authorized in this investigation.

## Primary sources

- [Telegram call connection options](https://core.telegram.org/api/calls)
- [Telegram signaling vs WebRTC transport](https://core.telegram.org/api/end-to-end/video-calls)
- [Pinned custom reflector implementation](https://github.com/TelegramMessenger/tgcalls/blob/efd330ca04f74706024a5abdfb5b41f4e4dd1065/tgcalls/v2/ReflectorPort.cpp)
- [NativeNetworkingImpl](https://github.com/TelegramMessenger/tgcalls/blob/efd330ca04f74706024a5abdfb5b41f4e4dd1065/tgcalls/v2/NativeNetworkingImpl.cpp)
- [Desktop call setup and proxy selection](https://github.com/telegramdesktop/tdesktop/blob/dev/Telegram/SourceFiles/calls/calls_call.cpp)
- [Linux transparent proxy requirements](https://docs.kernel.org/networking/tproxy.html)
- [CONNECT-UDP, RFC 9298](https://www.rfc-editor.org/rfc/rfc9298.html)
- [SagerNet UDP-over-TCP framing](https://sing-box.sagernet.org/configuration/shared/udp-over-tcp/)
