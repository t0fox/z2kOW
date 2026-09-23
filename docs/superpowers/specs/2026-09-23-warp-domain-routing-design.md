# Domain-based routing for Z2K WARP

Date: 2026-09-23
Status: design approved in conversation; implementation pending spec review

## Outcome and boundary

People can put a domain in an existing WARP destination list and have traffic to
its DNS-resolved IPv4 addresses use the Z2K WARP tunnel. The first version covers
LAN devices using the router's DNS service or ordinary DNS replies that cross the
router. The owner explicitly accepted that devices resolving through their own
DoH/DoT are outside this stage. Existing IPv4/CIDR lists and whole-device WARP
selection keep their behavior. This change does not release or deploy itself.

The product distinction matters. Consumer Cloudflare WARP normally tunnels all
device traffic and handles DNS; it does not need a domain list to select what
enters the tunnel. **Cloudflare One Client** domain-based Split Tunnels are the
behavioral reference for selective routing: its local DNS proxy handles each
device's lookup and dynamically supplies route addresses. Z2K instead observes
DNS replies at the router. It is an adaptation of the name-to-address routing
principle, not an implementation of Cloudflare's client-side DNS proxy, and
cannot claim identical coverage where DNS never traverses the router in
readable form. Exact names and `*.example.com` follow Cloudflare One's explicit
matching semantics: the wildcard matches subdomains but not the apex. A user
who wants both enters both lines.

## Existing system

`webpanel/cgi/actions.sh::warp_list_save` currently accepts only IPv4/CIDR.
`files/z2k-update-lists.sh::update_warp_game_list` strips non-IP upstream lines.
`files/z2k-warp.sh::warp_ipset_load` builds `z2k_warp` from selected destination
lists. `z2k_warp_src` selects complete LAN devices. The `S51z2k-warp` process
owns the tunnel; `files/z2k-warp.sh` and `files/ndm/93-z2k-warp.sh` install or
restore PREROUTING marks and policy routing. There is no Entware dnsmasq on the
owner's KeeneticOS 5.1.5 router, and Z2K must not replace its DNS service.

## Choices considered

1. Periodically resolve names from the router. Smallest change, but misses
   wildcard subdomains and can diverge from the answer the client received.
2. Replace or chain Keenetic DNS through dnsmasq with `ipset=` rules. Familiar
   implementation, but changes the DNS path for the entire household and can
   conflict with existing DNS policies and AdGuard Home configurations.
3. **Selected:** observe copies of DNS replies with NFLOG and translate their
   A records into temporary, client-scoped WARP destinations. DNS remains
   untouched and observation cannot hold DNS packets awaiting a userspace
   verdict. The owner's router has the `nfnetlink_log` module and NFLOG target.

## Data and routing flow

1. The same enabled WARP user/game lists may contain IPv4, CIDR, exact domain,
   or `*.domain`. Comments and blank lines remain supported. Save, import,
   upstream refresh, and runtime load share one validation contract. Invalid
   lines are counted and reported rather than silently treated as routes.
   Internationalized names are entered in ASCII/Punycode form. IPv6 literals
   and AAAA-only names are explicitly unsupported because today's WARP policy
   route has no IPv6 leg.
2. Static IPv4/CIDR entries keep loading into `z2k_warp` atomically. Selected
   domain entries are supplied to the WARP DNS observer as a versioned snapshot;
   a list change reloads the snapshot without restarting the tunnel. Disabled
   lists contribute neither static nor domain destinations.
3. While WARP is enabled, the netfilter hook observes DNS replies from the
   router to LAN clients in OUTPUT and forwarded plaintext DNS replies in
   FORWARD. It uses a dedicated NFLOG group, restricted to TCP/UDP replies from
   port 53. NFLOG copies packets; it does not queue or redirect them. The hook
   is restored after NDM firewall regeneration and removed on disable/remove.
4. The observer accepts only valid DNS responses. It associates a matching
   question name with A answers along a valid CNAME chain, then records
   `(client IPv4, destination IPv4, expiry)` using the minimum applicable TTL.
   It ignores malformed responses, unrelated additional records, private,
   loopback, multicast, documentation, and other non-routable destinations.
   Zero-TTL answers are not cached; positive TTLs are capped at one hour.
   At most 4,096 selected domain rules, 128 clients, and 8,192 live client/address pairs
   are retained. Packets larger than the observation cap are skipped and an
   overflow counter is exposed, so memory and CPU cannot grow without limit.
5. A separate timeout-capable `hash:ip` set named `z2kd_<client IPv4>` stores
   destinations for each LAN client. A PREROUTING rule for that client's source
   address matches its destination set and sets only the existing WARP mark bit.
   Static destinations remain global in `z2k_warp`; domain-derived destinations
   affect only the client that got the DNS reply. The existing ready-gated policy
   route applies both paths. No WARP routing rule is placed in OUTPUT. This
   replaces the initially planned `hash:net,net` pair set: the owner's router's
   ipset 7.24 userspace advertises it, but its Keenetic 4.9 kernel returns
   `set type not supported` on creation. A real `hash:ip` set with timeout and
   dotted client name was created and exercised successfully on 2026-09-23.
6. The observer persists a small, bounded snapshot of unexpired pairs under
   `/tmp/z2k-warp`, so a daemon reconnect or restart does not discard a DNS
   answer still cached by a client. A snapshot is restored only after checking
   expiry, current enabled domains, and local-address exclusions. Removing or
   disabling a domain withdraws its pairs immediately; shared pairs remain
   while at least one selected name still justifies them. Reboot clears the
   snapshot; a LAN client's own DNS cache may survive that reboot, so its
   traffic can go direct until the next lookup.

## Failures and limits

- Missing NFLOG support or an observer startup failure leaves static IP and
  whole-device WARP working. The UI and diagnostics report domain routing as
  unavailable. DNS responses themselves continue normally.
- DNS capture is limited to replies addressed to LAN clients; forwarded replies
  must belong to an established connection. Invalid or oversized answers do
  not alter routes. Reaching a domain/pair cap leaves existing routes intact
  and reports the skipped addition.
- If the tunnel is not ready, existing fail-open behavior removes WARP policy
  routing. Client DNS sets may still learn answers for when the tunnel returns.
- A client with cached DNS from before the observer starts may initially use
  the direct route until it resolves again. The same applies after reboot and
  to unseen wildcard subdomains. Exact names may be prewarmed through the
  router resolver, but prewarming must not create a route for a LAN client
  whose DNS answer was never observed; it is only a diagnostic or cache aid.
- DoH/DoT, application-bundled encrypted DNS, hard-coded IPs, and IPv6 do not
  generate domain routes in this stage. The UI states this beside the editor.
- A shared CDN IP can carry unrelated hostnames. Client scoping limits the
  effect to the client that resolved the selected domain, but cannot separate
  other hostnames that the *same client* reaches at that IP. The UI explains
  this before broad domain or wildcard use.
- DNS observation records no full query log and does not transmit query data
  off-router. Status exposes counts and selected-name resolution state, not a
  history of every client DNS request.

## UI, lifecycle, and installation

The WARP section calls the lists "Адреса и домены" and documents exact names,
wildcards, IPv4 support, and the DNS visibility requirement. Save/import results
count accepted IP and domain lines separately plus invalid lines. The section
shows whether the DNS observer is active and how many live client/address pairs
exist; an on-demand detail view may show selected names and resulting IPs with
expiry, without showing LAN client identities by default. README and CLI help
use the same semantics.

Installation and update deliver the observer as part of the existing optional
WARP engine and add the NFLOG hook only when WARP is enabled. Disabling or
removing WARP removes hooks and dynamic sets. Restart/reinstall preserve user
lists and the WARP on/off choice. NDM hook regeneration, self-heal, and rollback
to an older engine must leave DNS packets unaffected and must not strand a
route to a dead tunnel. The feature must not change the router's DNS servers,
DNS interception settings, or other Keenetic connection policies.

## Acceptance and verification

- Test parser and list CRUD/import/refresh with exact domains, wildcard,
  Punycode, malformed entries, comments, IPv4/CIDR, and disabled lists.
- Test DNS response parsing with A, CNAME chains, unrelated additional A,
  truncated/malformed packets, TCP DNS framing, TTL expiration, duplicate
  answers, and multiple clients. A domain deletion must remove only pairs no
  longer justified by any enabled domain.
- Test policy rules and lifecycle with stubs: existing mark mask, PREROUTING
  only for WARP routing, OUTPUT/FORWARD only for passive NFLOG copies, NDM
  regeneration, enable/disable/remove, engine failure, and tunnel fail-open.
- On the owner's router, verify that an ordinary LAN DNS lookup for an exact
  test name creates only that client's pair, a later connection takes the
  tunnel when ready, TTL expiry removes the pair, and unrelated DNS/site traffic
  is unaffected. Check memory and CPU during representative DNS traffic.
- Run existing WARP, panel, update, and router-recovery suites; do not publish
  a release as part of this work.

## Reference behavior

- [Consumer WARP modes](https://developers.cloudflare.com/warp-client/warp-modes/):
  Traffic and DNS tunnels all device traffic; DNS may use UDP, DoT, or DoH.
- [Cloudflare One Client architecture](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/client-architecture/):
  the per-device client installs a local DNS proxy.
- [Cloudflare One Split Tunnels](https://developers.cloudflare.com/cloudflare-one/team-and-resources/devices/cloudflare-one-client/configure/route-traffic/split-tunnels/):
  domain answers dynamically produce IP routes and shared IPs can affect other
  hostnames. Domain-based rules require the client to handle the lookup.
