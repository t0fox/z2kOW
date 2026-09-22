# Telegram UDP recovery implementation plan

Goal: preserve transparent LAN -> router -> our VPS -> Telegram traffic; prevent stale UDP routing after disconnect and prevent Telegram UDP being modified by generic STUN strategies. No client settings, no global policy/port exclusions, no public release in this task.

Architecture: keep the existing dedicated authenticated UDP WSS transport. Give each connected UDP session a route lifetime, revoke ready state before cleanup, and finish cleanup before reconnect. Keep IPv4/IPv6 policy isolation introduced in p-85.7. Exclude Telegram UDP from NFQUEUE by destination/source match within queue rules (not a broad ACCEPT in router chains).

Execution: native in this session, explicitly authorized by user to analyze, implement and deploy. TDD and live verification; archive installed files before deploying. Existing unrelated work must remain intact.

- [x] Add behavioral client regression: a disconnected authenticated UDP session must withdraw ready state/routes before retry, including setup failure and cancellation. Use real local WebSockets; substitute only privileged route/TUN boundaries.
- [x] Fix client cleanup ownership; verify existing packet/session tests and full Go suite.
- [x] Add shell rule-generation regression covering Telegram UDP exclusion both directions/families, TCP unchanged and unrelated UDP still queued. Fix NFQUEUE builders using the shared Telegram sets.
- [x] Run shell regressions, shell syntax/lint and full affected component suites.
- [x] Build arm64 diagnostic client with existing build credentials kept out of output. Back up client/init/helper on router. Deploy tested changes only; verify checksums and active rules.
- [x] Verify diagnostic UDP egress to Telegram and a controlled local return through router/VPS, plus cleanup/reconnect; separately check ordinary TCP connectivity. A STUN response is not proof of a completed real voice call.

Review focus: disconnected routes; watchdog stale ready state; partial route setup; native Keenetic marks; unrelated UDP/TCP; IPv6; no live call available.

Completed 2026-09-22: two client regression cases first failed, then passed; full Go suite and targeted race checks passed; 224 shell suites, 4150 checks passed, one documented BSD sed skip. Native review and live deployment completed. Real STUN/TURN session credentials and a human voice call are unavailable, so the return-path probe used a controlled packet injected locally on our VPS, not a claimed Telegram response. No public release.
