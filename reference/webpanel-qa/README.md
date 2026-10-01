# WebPanel visual QA

Chromium QA for the OpenWrt document root. The browser test renders all 12 routes in dark and light themes and checks the compact header with one route menu, responsive layout, viewport overflow, controls, keyboard/focus behavior, reduced motion, static assets, the mobile drawer, and the unauthorized login state.

## Reviewed captures

| View | Files |
|---|---|
| Full HD, 1920×1080, dark | `screenshots/dark-1920-dashboard.png`, `screenshots/dark-1920-toggles.png`, `screenshots/dark-1920-strategies.png`, `screenshots/dark-1920-warp.png`, `screenshots/dark-1920-exclude.png`, `screenshots/dark-1920-diag.png` |
| Full HD login, 1920×1080, dark | `screenshots/dark-1920-login.png` |
| Full HD state table, 1920×1080 | `screenshots/dark-1920-state.png`, `screenshots/light-1920-state.png` |
| Full HD, 1920×1080, light | `screenshots/light-1920-dashboard.png`, `screenshots/light-1920-strategies.png` |
| Narrow, 390×844, dark | `screenshots/dark-390-dashboard.png`, `screenshots/dark-390-strategies.png`, `screenshots/dark-390-drawer.png` |
| Narrow, 390×844, light | `screenshots/light-390-dashboard.png`, `screenshots/light-390-strategies.png`, `screenshots/light-390-drawer.png` |

The browser suite covers all configured routes in both themes. The checked-in images are selected review points; other generated captures are temporary test output.

## Responsive behavior

- At 1920 px, the desktop side rail is 261 px and the mobile drawer trigger is hidden. The header shows the z2kOW mark and theme control; route links appear once in the side menu.
- The centered desktop shell uses the measured 261 px rail, 15 px gap, and 800 px main column. The main app starts below the 44 px header; there is no extra route-history row.
- The 44 px header is fixed and translucent with a 10 px backdrop blur. Local Inter 400/500/600 renders 14 px / 17.92 px body text; text fields are 30 px.
- At tablet widths from 768 to 1079 px, the rail remains 261 px and content starts at 280 px, with the main column adapting to available width.
- A real 401 `{ "needauth": true }` response opens the login form; at 1920 px its 380 px form column is centered.
- A short 1920×480 browser window keeps the desktop sidebar; viewport height does not switch the panel to its mobile layout.
- At 390 px, the header keeps the drawer trigger, mark, and theme controls. The drawer enters from the left, and the strategy tab labels fit without horizontal clipping.
- The state data grid keeps its native table header, rows, and cells at 390 px. Columns scroll inside the table wrapper without creating page-level overflow.
- Drawer transitions complete before screenshots; the images do not capture an intermediate slide state.

Visual review found duplicate route links in the header and a recent-routes strip above the page. Both were removed because the side menu already lists every route. Review also found clipped strategy-tab labels at 390 px; compact mobile spacing now keeps all three labels visible.

## Test result

Command: `node tests/browser/openwrt-panel.mjs`, with `PLAYWRIGHT_CHROMIUM_EXECUTABLE` set to the installed Microsoft Edge executable. Set `OPENWRT_SCREENSHOT_DIR` to capture review images.

Result: **PASS** — all 12 routes rendered in dark and light themes; responsive layout, single navigation, visible strategy tabs, no-overflow, semantic state-table scrolling, contrast, focus, keyboard, reduced motion, blocked-asset behavior, unauthorized login, and ES-module loading passed. The latest run returned 54 successful module responses.
