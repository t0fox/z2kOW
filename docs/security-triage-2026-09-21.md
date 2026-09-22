# GitHub Security and quality review — 2026-09-21

Reviewed all ten open CodeQL alerts against fca1ed5, the revision reported by
GitHub, and SECURITY.md. An independent read-only review reached the same
boundary conclusions. No vulnerable runtime path was established within the
supported security model, and no runtime code was changed to silence CodeQL.

| Alert | Location | Disposition and reason |
|---|---|---|
| #18 | WARP H2 tlsConfig | False positive: mandatory VerifyConnection authenticates the registered ECDSA peer key, including resumed sessions. Missing or malformed pins fail closed before dialing. Web PKI is intentionally replaced, not authentication. |
| #16 | detect tcp16 | Accepted diagnostic behavior: substituted-SNI reachability measurement, not identity verification. |
| #15 | detect prober TLS | Accepted diagnostic behavior: synthetic handshake and HTTP availability tests, no authenticated service claim. |
| #14 | detect prober H2 | Accepted diagnostic behavior: synthetic HTTP/2 measurement, no user credentials. |
| #13 | detect classify transfer | Accepted diagnostic behavior: counts response bytes; does not install downloaded code or carry user secrets. |
| #12 | detect classify response | Accepted diagnostic behavior: compares trigger and random control SNI; normal hostname validation would defeat this comparison. |
| #11 | rt-proxy outer TLS | Accepted carrier boundary: original client TLS is replayed through CONNECT and authenticated by browser/curl. Carrier authenticity and metadata protection are not guaranteed. |
| #10 | rt-proxy health TLS | Accepted availability limitation: empty health-spki-pin does not authenticate the probe; a configured pin rejects mismatches. An attacker can influence pool health, not authenticate user HTTPS. |
| #9 | vendored WireGuard IPv6 SetMark | False positive: uint32→int→int32 preserves the four-byte socket mark. The syscall uses a four-byte value, not a buffer length or index. |
| #8 | vendored WireGuard IPv4 SetMark | Same independently inspected ABI path for IPv4. UAPI parses the full uint32 range with ParseUint(...,32); rejecting marks above MaxInt32 would break valid 32-bit configurations. |

The seven intentional TLS findings are recorded as `won't fix`, not as fixes or
as authenticated connections. The other three are recorded as `false positive`.
CodeQL remains enabled. Each GitHub alert receives its own scoped explanation.

Focused verification on Go 1.25.13:

- WARP H2 tests with race detector and vet passed. Existing real TLS handshake
  tests reject an impostor key and accept a matching registered key even for
  self-signed/wrong-host certificates; missing and invalid pins are rejected.
- rt-proxy tests with race detector and vet passed, including matching,
  mismatching and empty health pins and functioning/stalling proxy nodes.
- detect prober and classify tests with race detector passed. tcp16 has no test
  files; it was compiled by the package test command.
- Linux socket-mark readback was not performed on this macOS host. The ABI
  conclusion follows from x/sys SetsockoptInt's int32 storage and four-byte
  setsockopt argument. TLS session resumption was inspected structurally, not
  separately exercised by a resumed-handshake test.

PR #66 updates pinned zizmor and CodeQL actions, passed its GitHub CI and was
squash-merged as 63921fb. Dependabot alert and secret-scanning endpoints report
that those features are disabled; this is not a clean scan result for them.

Release scope: add Altaec to the panel credits and deliver the workflow update
through the normal signed patch release process. Earlier uncommitted Telegram
and VPS maintenance work remains in the original checkout and is not included.
