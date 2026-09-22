# p-85.6: Telegram UDP routing captures native Keenetic policies

User reports after p-85.6: Telegram connectivity failures, loss/jitter in other
messengers, broken Fortnite matchmaking and inter-router WireGuard, and a work
VPN failing on a device excluded from zapret processing. Disabling the Telegram
tunnel restores connectivity. Reinstallation only temporarily helps some users.

## Confirmed mechanism

The Telegram UDP helper installs a priority-89 routing rule matching one bit:
`fwmark 0x8000000/0x8000000 lookup 988`. Table 988 has an unrestricted default
route through `z2ktg0`. Native Keenetic policy marks, including the live router's
`0xffffaaa`, also match that bit. The Telegram rule precedes Keenetic's priority
100/101 rules and captures policy traffic regardless of destination, protocol,
or whether the packet passed the Telegram iptables selector. The TUN consumer
accepts only Telegram UDP; unrelated traffic is lost.

A read-only RTM_GETROUTE diagnostic on the actual router confirmed that
`1.1.1.1`, `198.51.100.123`, and `2606:4700:4700::1111` with mark `0xffffaaa`
all selected `z2ktg0`. Unmarked `1.1.1.1` selected `ppp0`. No test packet was
sent to these destinations. This is a confirmed routing regression, not proof
of every reported client symptom or of a separate web-updater defect.

The minute watchdog and NDM hook call the same ensure helper. Reinstalling or
rebuilding firewall rules does not permanently remove the problem while the
old helper continues restoring it. The reported exact five-minute delay has
not been independently reproduced.

## Correction

- Match the entire routing mark, not a shared bit.
- Replace the tunnel table's forwarding default with a `throw` default, which
  continues normal policy lookup; add only the Telegram IPv4/IPv6 prefixes.
- Return marked traffic from the Telegram chain before MARK/ACCEPT, preserving
  native policies and other tools' routing decisions. Telegram UDP relaying
  therefore covers unmarked LAN traffic; explicitly policy-routed devices keep
  their own route, including their VPN, for Telegram UDP too.
- Remove all duplicate copies of the old selector by complete identity. Do not
  delete rules merely by priority. Stop cleans both old and new selectors.
- Keep the existing authenticated-ready gate, LAN/UDP/destination restrictions,
  and rollback on partial setup failure. No relay/client binary change needed.

The table fallback is installed before selector migration so the unrestricted
catch-all disappears first. TCP Telegram REDIRECT behavior is unchanged.
The fix addresses collateral routing; it does not establish success of every
Telegram call topology or client version. No real Telegram call was available.

## Verification

`sh tests/test_tg_udp.sh` initially failed with
`native Keenetic policy captured by Telegram route` on the old implementation.
The updated test records actual helper-generated netfilter/routing operations
and checks native-mark isolation, marked-traffic RETURN order, destination
scope, repeat repair, duplicate legacy migration, preservation of another
service at the same priority, stop cleanup, and IPv6 failure rollback.

Live before/after kernel route lookup, watchdog repair, and full local CI
results are recorded below after deployment.

The full local CI passed: 4,150 integration assertions, zero failures; the
existing macOS/BSD-sed skip remains. Additional deliberate mutations of the
forwarding default, policy RETURN guard, and legacy cleanup were each caught
by the routing regression tests.

Router preview deployed only `z2k-tg-redirect.sh`, atomically, with backup in
`/opt/z2k-tg-isolation-backup-20260922/`. No service restart, user config edit,
client/VPS binary replacement, or public release was performed. BusyBox accepts
both IPv4 and IPv6 throw routes (checked first in an unused isolated table).

After deployment, all three non-Telegram native-policy lookups stopped selecting
`z2ktg0`. This router's Policy0 currently has no internet default and has an
existing priority-101 blackhole, so the native-policy internet lookups correctly
return its blackhole/error rather than inventing a VPN route. That native policy
was not changed. Unmarked traffic and even a non-Telegram destination carrying
the exact Telegram tag both select `ppp0`. Tagged Telegram IPv4 and IPv6
lookups still select `z2ktg0`. Telegram HTTPS over the existing tunnel returned
200. The routing selectors each appeared exactly once after watchdog repair.

At 328 seconds after applying the fix, the scheduler's `tg-watchdog-epoch`
had advanced through normal minute-cadence runs. The seven kernel lookup
results matched the immediate post-fix results byte-for-byte, each family
still had exactly one exact-match selector, the UDP ready file remained
present, and Telegram HTTPS again returned 200. Explicit IPv4/IPv6 mangle
NDM-hook invocations and the installed watchdog also preserved the fix.
