# SDD ledger — plan: docs/superpowers/plans/2026-10-06-openwrt-doh.md

## Pre-flight
- Base: f3fa28af9499377c16c6832fe50528f603a8c0d4 (main).
- Workspace: `/mnt/e/z2kow`, branch `main`; user explicitly required main-only work and E: as the only work drive.
- Existing DoH WIP in the shared working tree was retained and continued in place; no worktree or branch was created.
- Graphify: repository `t0fox/z2kOW`, indexed at f3fa28a; `tiktok.sh` owns two hosts via independent dnsmasq UCI list entries.
- Ruling: the OpenWrt runner already discovers `tests/openwrt/test_ow_*.sh` by glob, so no runner registration edit is needed — avoids a redundant change — cost if wrong: new test could be skipped.
- Ruling: packaged `config main 'config'` is exposed by UCI as `https-dns-proxy.config='main'`; the adapter uses that official section type.
- Ruling: the adapter selects a free per-resolver UDP listener port, and records its dnsmasq route port so cleanup can remove the exact route if UCI is later edited.
- Logo: retained `logo.png` byte-for-byte and extracted its white and green artwork into transparent SVG masks; CSS variables recolor the masks with the active theme.

## Verification
- `sh -n platform/openwrt/doh.sh` — pass.
- `sh tests/openwrt/run.sh` — pass=3889, fail=0; optional `ow-rt-somark` skipped without `Z2K_RT_TARBALL`.
- `sh tests/test_panel_pages.sh` — pass=15, fail=0.
- `sh tests/openwrt/test_ow_webpanel_branding.sh` — pass=28, fail=0.
- `node --check tests/browser/openwrt-panel.mjs` and `node --check tests/panel_harness.js` — pass.
- Browser execution was unavailable because this E: environment has neither a Playwright package nor a browser executable; browser assertions were updated but not executed.
- `git diff --check` — pass.
