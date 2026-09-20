# OpenWrt webpanel contract (Stage 6)

Upstream webpanel + tiny OpenWrt platform adapter. No LuCI rewrite, no new
API/frontend, no second TG/RT/WARP/firewall/updater/config implementation.
Panel thinks it calls ordinary z2k operations; the adapter translates them
into existing OpenWrt primitives (Stages 1-5).

## 1. Capability matrix (обязательный результат §36)

CLASS: COMMON (тот же код), PLATFORM_IO (тонкий перевод), KEENETIC_ONLY
(capability=false), ABSENT (в UI нет).

| Capability | Class | OpenWrt owner / adaptation |
|---|---|---|
| service start/stop/restart/status | PLATFORM_IO | `INIT_SCRIPT=/etc/init.d/z2k`; `is_running` → init running (procd); `is_installed` → payload marker |
| strategy editor/pools/custom/validate/save/reset | COMMON | env paths only; common generator |
| whitelist add/delete/import/list | COMMON | `WHITELIST_FILE=/etc/z2k/user-lists/whitelist.txt` |
| extra-domains add/delete/list | COMMON | `EXTRA_DOMAINS_FILE` → user-lists |
| autohostlist view/delete | COMMON | `AUTOHOSTLIST_DOMAINS_FILE` → `/etc/z2k/state/autohostlist-domains.txt`; live `Z2K_AUTOHOSTLIST_FILE` is a separate nfqws2 working file |
| exclusions add/delete/list | COMMON (file) | `EXCLUDE_FILE` → user-lists/exclude.txt; live nft apply unavailable (no ipset impl; graceful no-op precedent) |
| rotator state view/edit/clear | COMMON | `STATE_FILE` → /etc/z2k/state/state.tsv |
| config flags (все тумблеры кроме PPE) | COMMON | `CONFIG_FILE` → /etc/z2k/config + common generator + init restart |
| debug flag | COMMON | `DEBUG_FLAG_FILE` (new seam, transient default) |
| game-warp toggle | PLATFORM_IO | `WARP_SCRIPT` → platform warp.sh (rc 0/1/2 contract compatible) |
| warp install/remove/status | PLATFORM_IO | same verbs |
| warp reregister | PLATFORM_IO | `WARP_DEVICE` env + `WARP_INIT=/etc/init.d/z2k` (documented full-restart side effect) |
| warp neighbors | PLATFORM_IO | `warp_neighbors` override: `ip -4 neigh` + DHCP leases + `/proc/net/arp` fallback; empty hostname allowed |
| warp devices toggle/save/read | COMMON | `WARP_LISTS_DIR` env + reload via new `ipset` verb (sets_load, no duplication) |
| warp games/lists read/toggle/save/delete | COMMON | `WARP_GAMES_DIR` → shipped tree, `WARP_LISTS_DIR` → user tree |
| TG enable/disable | PLATFORM_IO | same `TG_PROXY_USER_DISABLED` flag + `/etc/init.d/z2k reload` (override, no daemon mgmt in CGI) |
| TG status pid | COMMON | same :1443 cmdline match (portable, no /opt) |
| RT toggle | ABSENT | no UI toggle upstream; don't invent; restart/update/uninstall must not break RT |
| update status/check | PLATFORM_IO | manifest URL → `Z2K_AU_REPO_RAW`/`Z2K_AU_BRANCH` seam; `AU_TAG_FILE` → install-meta |
| update apply | PLATFORM_IO | `AU_SCRIPT` → platform update.sh (`Z2K_AU_MANUAL/NO_JITTER` honored) |
| full uninstall | KEENETIC_ONLY | capability false (message: package manager) |
| Keenetic policy | KEENETIC_ONLY | capability false (no mwan3/PBR substitute) |
| PPE toggle | KEENETIC_ONLY | capability false (HFO owned by zapret2 runtime) |
| diagnostics /diag | KEENETIC_ONLY | capability false (diag.sh Keenetic-path-bound; don't deliver) |
| tcp16 card/probe | KEENETIC_ONLY | capability false (probe not delivered; card hidden) |
| domain probe/pick | COMMON* | works iff z2k-detect present (manifest delivers); else existing graceful error |
| dns check | PLATFORM_IO | deliver z2k-dns-check.sh via release_map; `DNS_CHECK_OWN` → user-lists |
| logs/jobs | COMMON | /tmp paths fine as-is |
| strategy picker deps | COMMON* | `Z2K_DETECT_BIN` env |
| auth state/challenge/login/logout | COMMON* | NDM capability false (`Z2K_PANEL_AUTH` stays 0 → required:false); origin/Host guards keep (platform-neutral) |
| lighttpd/pkg/install | PLATFORM_IO | package-owned init + Makefile subpackage; no opkg from panel |
| settings port/bind/hosts | COMMON | `WEBPANEL_KEEP_DIR` → /etc/z2k/webpanel |
| template render | PLATFORM_IO | same template + `@PLATFORM_ENV@`; OpenWrt renderer, OpenWrt values |

`*` = works when the underlying artifact is present, graceful error otherwise
(existing behavior, no new code).

## 2. Platform seam (exact)

- `webpanel/cgi/platform.sh` — NEW small common file. Keenetic: no-op.
  OpenWrt (`Z2K_PLATFORM=openwrt`): frozen-ownership env map (§4) + source
  `$Z2K_ROOT/platform/openwrt/webpanel.sh` (function overrides). Sourced by
  `api.sh` between auth.sh and actions.sh (one added line).
- `platform/openwrt/webpanel.sh` — PACKAGE-owned OS-effect helpers:
  `wp_lan_ip`, `wp_panel_render`, `wp_panel_validate`, `wp_panel_running`,
  `wp_neighbors`, `wp_service_running`.
- No `actions-openwrt.sh` / `api-openwrt.sh` / `app-openwrt.js` forks.
- `api.sh` additions: source platform.sh; append `platform` +
  `capabilities{policy,ppe,tcp16,diag,warp,telegram,uninstall}` to /status
  on openwrt only (Keenetic bytes identical). GET stays GET, shapes preserved.
- Frontend: only capability visibility (hide policy card/PPE toggle/tcp16
  card/diag nav/uninstall button on openwrt). No redesign, no new pages.

## 3. CGI must not know (frozen Stages 1-5 own it)

nft chains, procd internals, table 989, WARP mark, TG ports, RT DNS,
hotplug, fw4. No `nft/ip rule/ubus/uci` in actions.sh for lifecycle —
CGI calls adapter primitives. Static test pins this on the openwrt path
(reachability-aware, not whole-file grep: Keenetic source keeps its lines).

## 4. OpenWrt path map (no /opt symlink hack)

```text
ZAPRET2_DIR=/usr/lib/z2k   Z2K_BIN=/usr/lib/z2k/bin
Z2K_ETC=/etc/z2k           Z2K_STATE=/etc/z2k/state
Z2K_USER_LISTS=/etc/z2k/user-lists
Z2K_TMP=/tmp/z2k           Z2K_LOG=/tmp/z2k/logs   Z2K_RUN=/tmp/z2k/runtime
INIT_SCRIPT=/etc/init.d/z2k
CONFIG_FILE=/etc/z2k/config
WHITELIST_FILE=/etc/z2k/user-lists/whitelist.txt
EXTRA_DOMAINS_FILE=/etc/z2k/user-lists/extra-domains.txt
EXCLUDE_FILE=/etc/z2k/user-lists/exclude.txt
CUSTOM_STRAT_DIR=/etc/z2k/user-lists/custom-strategies
WARP_SCRIPT=/usr/lib/z2k/platform/openwrt/warp.sh
WARP_LISTS_DIR=/etc/z2k/user-lists/warp
WARP_GAMES_DIR=/usr/lib/z2k/lists/warp/games   (UPDATER wholesale refresh)
STATE_FILE=/etc/z2k/state/state.tsv
AUTOHOSTLIST_DOMAINS_FILE=/etc/z2k/state/autohostlist-domains.txt
Z2K_AUTOHOSTLIST_FILE=/etc/z2k/state/zapret-hosts-auto.txt (nfqws2 live file)
DNS_CHECK_SCRIPT=/usr/lib/z2k/z2k-dns-check.sh
DNS_CHECK_OWN=/etc/z2k/user-lists/dns-check.txt
Z2K_DETECT_BIN=/usr/lib/z2k/bin/z2k-detect
AU_TAG_FILE=/etc/z2k/state/installed-tag
AU_SCRIPT=/usr/lib/z2k/platform/openwrt/update.sh
DEBUG_FLAG_FILE=/tmp/z2k/debug.flag (new seam, transient)
WEBPANEL_KEEP_DIR=/etc/z2k/webpanel (port/bind/hosts, USER)
```

Updater-owned vs user-owned lists never remix (§5): shipped game lists stay
under `/usr/lib/z2k/lists`, user lists under `/etc/z2k/user-lists`.

OpenWrt сохраняет найденные `--hostlist-auto` домены при штатном stop и
восстанавливает их перед следующей генерацией/запуском через
`platform/openwrt/autohostlist.sh`. Слив выполняется атомарным rename live-файла
в drain, поэтому панельный ledger не зависит от payload
`/usr/lib/z2k/lists/autohostlist-domains.txt`, а рабочий файл движка не является
источником duplicate-check в WebUI. При выключенном `Z2K_AUTOHOSTLIST` ledger
сохраняется, но новый engine-файл не создаётся.

## 5. Ownership (→ ownership.map, tests)

```text
webpanel/cgi/*, webpanel/www/*, lighttpd.conf template → UPDATER
platform/openwrt/webpanel.sh, package init/glue      → PACKAGE
/etc/z2k/webpanel/* (port/bind/hosts)                → USER
generated lighttpd.conf, logs, pidfiles              → TRANSIENT
```

Upstream UI changes → signed updater; adapter changes → package upgrade.
Dormant assets on disk ≠ panel enabled (no updater special-casing).

## 6. Panel service (independent lifecycle)

- `/etc/init.d/z2k-webpanel` (procd, PACKAGE): renders transient
  `/tmp/z2k/runtime/webpanel/lighttpd.conf` from template + settings,
  validates (`lighttpd -tt`), opens instance `lighttpd -D -f`, bounded
  respawn (no shell supervisor). Never touches stock lighttpd/service.
- Stopping core MUST NOT kill panel and vice versa (separate services).
- Port conflict: foreign listener → FAIL LOUDLY (no kill, no reconfig).
- Bind default: canonical LAN via `z2k_ow_lan` (no second detector);
  one LAN IPv4 socket; IPv6 off unless configured; never 0.0.0.0/WAN auto.
- Settings created only if absent; update preserves port/bind/hosts.
- Template update → render + panel-only reload/restart; core PID unchanged.

## 7. Updater integration (same step names)

- `rebuild-panel` keeps its name. OpenWrt branch: template
  `/usr/lib/z2k/webpanel/lighttpd.conf.in` + `/etc/z2k/webpanel/*` →
  render via platform adapter → validate → restart `z2k-webpanel` ONLY if
  installed+running. Panel package absent ⇒ safe no-op.
- restart-set `webpanel/*` on openwrt → `z2k-webpanel` (not core restart).
- Update button: check → manifest from `Z2K_AU_REPO_RAW`/`Z2K_AU_BRANCH`
  (one updater truth); apply → `Z2K_AU_MANUAL=1 update.sh apply`
  (no jitter for manual). No second manifest/verify/branch logic in CGI.
- release_map openwrt adds: `webpanel/cgi/*`, `webpanel/www/*`,
  `webpanel/lighttpd.conf` (→.in), `files/z2k-dns-check.sh`.
  install/uninstall/init scripts stay package-owned (no updater mapping).
- Template keeps ONE file + `@PLATFORM_ENV@` (empty on Keenetic):
  OpenWrt renderer substitutes the `setenv Z2K_PLATFORM=openwrt` line.

## 8. Security (no weakening)

auth.sh, Host validation, same-origin, request limits, CGI restrictions
unchanged. Panel binds LAN only (never WAN auto). NDM-auth unsupported on
OpenWrt (stays off, fail-closed). No directory listing, api-only executable.

## 9. Test layers

A contract/static (matrix doc, ownership, no-forbidden-on-path, no fork,
diff budget). B platform unit (webpanel.sh). C real CGI sysroot
(api.sh+actions.sh, WP-scenarios). D panel lifecycle (render/start/stop).
E regression (Foundation+TG+RT+WARP+Keenetic panel suites).

## 10. Non-goals / stop conditions

No LuCI/uhttpd/Node/Python rewrites. No new subsystems for
Keenetic-only features (capability=false is a finished decision).
RUNTIME PARTIAL without live router is not a blocker. Go CI debt stays
out of Stage 6.
