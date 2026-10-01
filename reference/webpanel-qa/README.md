# WebPanel visual QA

Chromium browser QA for the OpenWrt document root, captured from the 2026-10-01 branch state. The test renders every configured route in dark and light themes and checks viewport overflow, control metrics, keyboard/focus, reduced motion, static asset loading, and the mobile drawer.

## Captures

The checked-in screenshots are representative review points. Dark/light coverage for all configured routes is exercised by the browser test; these selected files show the Dashboard and Strategies page at the requested desktop Full HD size and the narrow layout, plus each mobile drawer state.

| View | Files |
|---|---|
| Full HD, 1920×1080, dark | `screenshots/dark-1920-dashboard.png`, `screenshots/dark-1920-strategies.png` |
| Full HD card hover, dark | `screenshots/dark-1920-card-hover.png` |
| Full HD strategy table, 1920×1080 | `screenshots/dark-1920-state.png`, `screenshots/light-1920-state.png` |
| Full HD, 1920×1080, light | `screenshots/light-1920-dashboard.png`, `screenshots/light-1920-strategies.png` |
| Narrow, 390×844, dark | `screenshots/dark-390-dashboard.png`, `screenshots/dark-390-strategies.png`, `screenshots/dark-390-drawer.png` |
| Narrow, 390×844, light | `screenshots/light-390-dashboard.png`, `screenshots/light-390-strategies.png`, `screenshots/light-390-drawer.png` |

## Responsive behavior checked

- At 1920 px CSS width the persistent desktop sidebar is 260 px and the mobile menu button is hidden.
- The centered shell follows the measured Lolz relationship: 260 px rail, 15 px gap and 800 px main column (the 1081 px source wrapper was measured at 1440×900; Full HD positioning is locally verified).
- The 44 px header is fixed, translucent and blurred by 10 px. Local Inter renders 14 px / 17.92 px body text; text fields are 30 px and navigation/menu geometry is measured in the browser.
- A short 1920×480 browser window also keeps the desktop sidebar; viewport height no longer switches the whole panel to its mobile navigation layout.
- At 390 px CSS width the menu trigger appears to the left of the z2kOW wordmark and the navigation drawer enters from the left.
- Mobile drawer open/close transitions complete before screenshots are taken; the images do not capture an intermediate slide state.
- Review of the first light-theme capture found dark button surfaces with dark text; theme-aware button surfaces were added and the full visual suite was rerun.

## Test result

Command: `node tests/browser/openwrt-panel.mjs`, with `PLAYWRIGHT_CHROMIUM_EXECUTABLE` set to the installed Microsoft Edge executable and `OPENWRT_SCREENSHOT_DIR` pointed at a temporary capture directory because Playwright's bundled Chromium was not installed.

Result: **PASS** — all 12 routes rendered in dark and light themes; layout, no-overflow, contrast, focus, keyboard, reduced-motion, blocked-asset and ES-module checks passed; 52 module responses returned successfully.
