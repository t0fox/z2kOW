# Design review: OpenWrt webpanel

**Status:** Visual implementation is on `codex/openwrt-visual-redesign`; exact-HEAD CI and package installation/live verification are pending. **Source baseline:** `origin/main` at `39c554510d8551bcd16ab2de88556321ec8501db`. **Live baseline:** Cudy WBR3000UAX v1, OpenWrt 25.12.5, adapter `0.1.0-r79`; the Strategies screen showed 140 rows at 1392 × 1104.

### Summary

**Rating: Good, pending live verification.** The panel now reads as a calm router control surface whose signature is one open route-ribbon mark beside the HTML wordmark `z2kOW`. The source and local Chromium review cover every primary route in both appearances; router installation and a fresh live visual review remain open.

### Critical

No active accessibility or navigation blocker was found in the local Chromium review. The same-origin profile/theme blockers leave the route shell usable, and all eight primary routes render in light and dark appearances.

### Improvements

No unresolved source-level High or Medium design finding remains from the first-pass audit. Before calling the delivery accepted, run exact-HEAD CI, install package `r80` through the supported package path, and repeat the visual review from fresh live responses.

### Craft notes

The single open route ribbon is the memorable element; aqua identifies interactive emphasis, violet stays in the mark, and the surrounding interface remains quiet. This follows `branding.md › Best practices`: “instantly recognizable while feeling at home on the platform.” The design avoids the default “navy dashboard + teal accent” template by tying its one signature element to routing rather than adding decorative network diagrams.

### What works

- One local SVG mark and one HTML wordmark replace the two competing identities; the accessible name and page title use the same `z2kOW` identity.
- The 140-row Strategies view remains a sortable table. `lists-and-tables.md › Best practices`: “Prefer displaying text in a list or table.”
- The reversible return-to-automatic action is neutral; destructive deletion remains red and confirmation-protected. `buttons.md › Role`: “The button performs an action that can result in data destruction.”
- Light and dark palettes preserve distinct surfaces and meet the recorded contrast targets. `accessibility.md › Vision`: “Strive to meet color contrast minimum standards” and “Convey information with more than color alone.”
- The mobile drawer moves focus inside, traps keyboard navigation, closes with Escape, and restores focus to its trigger. Coarse-pointer navigation and controls use 44 px targets.

### Platform notes

This is an offline-first web panel, not a native macOS or iOS app. Desktop keeps the existing sidebar and compact theme control; narrow and touch layouts use the existing drawer. Browser zoom is covered with a 696 × 552 CSS viewport (the 200% equivalent of 1392 × 1104), and reduced-motion and forced-colors styles remain available. Real Cudy screenshots after package installation will close the remaining visual acceptance gap.

## Design thesis

The panel is a compact, dependable instrument for reading router and service state and operating network controls safely; its visual signature is one continuous, softly routed line that turns once like a path through a small network.

The audience is an OpenWrt router owner or operator, often working on a laptop or tablet and sometimes using a constrained local connection. Prioritize legible state, clear consequences, rapid scanning, keyboard operation, and offline reliability. The design borrows familiar web controls without imitating macOS chrome or introducing decorative network maps.

## Design direction and template check

The first proposal of “navy canvas + teal accent + left sidebar + rounded cards” was too generic: it could describe a router, analytics dashboard, or developer tool. The implementation keeps the interface quiet and content-led, with the open route-ribbon as its only branded gesture. Do not add glowing gradients, circuit traces, decorative topology, or repeated logo stamps.

This translates Apple guidance into a web panel rather than imitating an Apple application: `layout.md › Visual hierarchy` says “Order content by relative importance”; `color.md › Best practices` says “Avoid using the same color to mean different things”; and `branding.md › Best practices` calls for a brand that feels “at home on the platform.”

## Identity

- Render exactly one brand lockup in the shell: a single local vector mark followed by the HTML text `z2kOW`.
- Draw the mark as an open, smooth route ribbon with rounded caps and joins, one broad turn, and a small branch/terminal cue. Its silhouette may suggest a soft Z through the route, but it must not be a square enclosure, sharp lightning bolt, or literal “OW” monogram.
- Use restrained aqua for the route and a small violet detail only where it helps identify the mark. Violet is decorative brand color; it never carries status or action meaning.
- Build the wordmark from HTML text so its color follows both appearances. Use lowercase `z`, digit `2`, lowercase `k`, uppercase `OW` exactly as `z2kOW`; do not insert a visual space or separate the OpenWrt suffix into another logo.
- Do not include a tagline in the lockup. The page title and route context already explain where the user is. The favicon contains the mark only, with no text.
- Start from one neutral `Z2K` fallback lockup in static HTML. The local OpenWrt profile applies the `z2kOW` mark and wordmark; if profile or identity loading fails, keep the single local fallback rather than revealing a competing legacy identity.
- Keep identity enhancement optional: a failed or blocked profile, theme, SVG, or identity module must not prevent the route shell and primary content from booting. Use local assets only; no remote font, image, or stylesheet requests.

## Color tokens

The package-owned theme defines the same semantic token set in both appearances. These values match `platform/openwrt/webpanel-brand/theme.css`; ratios below use WCAG relative luminance against the listed solid surfaces.

| Token role | Dark | Light | Use |
| --- | --- | --- | --- |
| `--ow-canvas` | `#0B1113` | `#F4F8F7` | Application background |
| `--ow-surface-1` | `#111A1D` | `#FFFFFF` | Primary cards and menus |
| `--ow-surface-2` | `#172326` | `#EAF1EF` | Nested regions, table header, grouped form sections |
| `--ow-surface-hover` | `#202F32` | `#E1ECE9` | Hover only; do not use hover as the selected state |
| `--ow-surface-selected` | `#243A39` | `#D8EAE5` | Persistent selected row/navigation item |
| `--ow-border-subtle` | `#29383A` | `#D5E0DE` | Low-emphasis separators |
| `--ow-border-strong` | `#728589` | `#718885` | Control boundaries and non-text structure |
| `--ow-text-primary` | `#F2F7F6` | `#182625` | Main labels and values |
| `--ow-text-secondary` | `#A4B7B5` | `#4C625F` | Supporting labels and descriptions |
| `--ow-text-tertiary` | `#829795` | `#5A6F6C` | Metadata and low-priority timestamps; preserve readable contrast |
| `--ow-accent` | `#72D8C7` | `#087A70` | Links and primary control accent |
| `--ow-accent-hover` | `#9AE8DB` | `#06655F` | Hover/focus accent on canvas and surfaces |
| `--ow-accent-soft` | `#193B38` | `#DDF1EC` | Quiet accent surface; pair with primary text |
| `--ow-brand-violet` | `#A99BFF` | `#6554CE` | Mark detail only |
| `--ow-success` | `#71D6A5` | `#176B4D` | Positive state icon and text |
| `--ow-warning` | `#F4C46A` | `#855400` | Caution state icon and text |
| `--ow-danger` | `#F08084` | `#B6384B` | Destructive action and error state |
| `--ow-info` | `#83BFFD` | `#17658C` | Informational state icon and text |
| `--ow-focus-ring` | `#72D8C7` | `#087A70` | Keyboard focus ring |
| `--ow-radius-control` | `8px` | `8px` | Buttons, inputs, and segmented controls |
| `--ow-radius-card` | `12px` | `12px` | Cards |
| `--ow-radius-panel` | `14px` | `14px` | Larger panels and scroll surfaces |
| `--ow-shadow-card` | `0 8px 24px rgba(0,0,0,.24)` | `0 8px 24px rgba(24,38,37,.08)` | Subtle card depth |
| `--ow-shadow-popover` | `0 16px 40px rgba(0,0,0,.36)` | `0 16px 40px rgba(24,38,37,.14)` | Dialogs and floating sheets |

Semantic colors are always accompanied by a word, icon, or shape. Never use color alone to identify state. Hover, selected, disabled, and focus must remain distinguishable. A selected item uses `--ow-surface-selected`, not the hover fill. Danger is reserved for destructive actions/errors, not routine or reversible operations.

Shared frontend variables map to these `--ow-*` tokens, so route and API code keep their existing component ownership while OpenWrt owns the visual layer. Shadows are subtle depth cues, not substitutes for surface hierarchy or boundaries.

### Contrast check for the proposed values

| Foreground / boundary | Dark target | Ratio | Light target | Ratio |
| --- | --- | ---: | --- | ---: |
| Primary text | surface 1 | 16.32:1 | surface 1 | 15.64:1 |
| Primary text | surface 2 | 14.88:1 | surface 2 | 13.65:1 |
| Secondary text | surface 1 | 8.42:1 | surface 1 | 6.52:1 |
| Secondary text | surface 2 | 7.68:1 | surface 2 | 5.69:1 |
| Accent | canvas | 11.20:1 | canvas | 4.87:1 |
| Accent foreground for filled primary button | accent fill | button text `#05201C`: 10.05:1 | accent fill | white: 5.21:1 |
| Strong boundary | surface 1 | 4.57:1 | surface 1 | 3.78:1 |
| Strong boundary | surface 2 | 4.16:1 | surface 2 | 3.29:1 |
| Strong boundary | selected surface | 3.12:1 | selected surface | 3.02:1 |
| Tertiary text | surface 1 | 5.73:1 | surface 1 | 5.35:1 |
| Tertiary text | surface 2 | 5.22:1 | surface 2 | 4.67:1 |

Semantic state text/icon contrast against surface 1 / surface 2: dark success 9.98 / 9.09, warning 10.89 / 9.93, danger 6.83 / 6.23, info 9.11 / 8.30; light success 6.47 / 5.64, warning 6.43 / 5.61, danger 5.74 / 5.01, info 6.41 / 5.59. Text stays above 4.5:1; strong boundaries stay above 3:1 against the listed surfaces, including selected. Recheck final rendered states, including focus and selected controls, in both themes.

## Type, spacing, and component geometry

- Use a system UI stack for interface text (`system-ui`, `-apple-system`, `BlinkMacSystemFont`, `Segoe UI`, sans-serif). Use the existing local monospace stack only for IP addresses, commands, logs, and other technical identifiers.
- Type roles: page title 24/32 px semibold; section title 18/24 px semibold; body and controls 16/22 px; secondary text 14/20 px; metadata 13.5/18 px; technical values 14/20 px monospace. Do not use thin weights. Keep long descriptive text at a comfortable measure; do not scale the table's primary values below 14 px.
- Use a 4 px base spacing scale, with frequent steps of 8, 12, 16, 24, and 32 px. Align fields, labels, and table columns consistently. Reserve 24–32 px between major content groups; use 8–12 px within related control groups.
- Use 8 px control radius, 12 px card radius, and 14 px panel radius. Avoid pill-shaped controls except compact state chips where existing interaction already uses them.
- Target a 58 px top bar and preserve the established 240 px desktop sidebar. Sidebar items have a generous pointer target, a quiet selected surface, and a 3 px accent indicator. On narrow widths, retain the existing drawer behavior and move focus into the open drawer; Escape closes it and returns focus to its trigger.
- Keep the sidebar information architecture and order: Дашборд, Режимы, Стратегии, WARP, Исключения, Доп. домены, Диагностика, Благодарности. Selected items use a tinted surface, readable text, and one accent cue; hover does not move layout. Use a consistent 18 px outline icon family with rounded caps/joins and similar optical weight. Keep external links visually secondary at the bottom.
- Keep the top bar quiet: one logo at the left, breathing space, and theme controls at the right. Do not repeat the product name elsewhere in the top bar. Keep theme selection as a compact segmented `light / auto / dark` control, preserving the current choice and all three options. Icon-only controls need accessible names and visible hover, active, and focus-visible states.
- Cards use a clear surface edge and restrained shadow. Do not layer several bordered cards around the same content. Inputs use their own surface and quiet boundary at rest, explicit non-glowing focus, hover, and disabled states, a practical control height, and persistent labels. Keep placeholder text secondary, never as the sole label.
- Buttons use four clear roles: teal primary (for example, “Создать уникальный набор”), neutral secondary, genuinely destructive, and quiet. “Вернуть все категории к автоматике” must not look destructive when it is safely reversible. Keep destructive wording and confirmation behavior intact.
- Tables keep a stable header, improved row height and hover, clear column/group hierarchy, readable metadata, and aligned numeric/status columns. Show selected/frozen state distinctly from hover. Preserve existing sorting/filtering and horizontal overflow behavior. On small screens, keep columns accessible through the established responsive table behavior; do not silently drop data or turn the desktop table into cards.
- Keep loading, empty, success, warning, and error messages close to the content they explain. Do not let badges replace their accompanying state text.
- Restyle “ЭКСПЕРИМЕНТАЛЬНО!!!” as “Экспериментальная функция” with semantic warning treatment; retain the fact that the feature is experimental.
- Support keyboard navigation and screen-reader labels; use a visible `:focus-visible` ring; keep status understandable without color; maintain usable layout at 200% browser zoom and enlarged text; and provide at least 44 × 44 px targets for touch-oriented controls without inflating dense desktop controls.

### Desktop content wireframe

```text
┌──────────────────────────────────────────────────────────────────────────────┐
│ [route mark] z2kOW                                      Theme  User/connection│
├───────────────────┬──────────────────────────────────────────────────────────┤
│ Overview          │ Page title                                    Main action│
│ Network           │ Short context or connection state                         │
│ Strategies        │ ┌──────────────────────┐  ┌────────────────────────────┐ │
│ Services          │ │ Key state / summary  │  │ Related state / summary   │ │
│ Settings          │ └──────────────────────┘  └────────────────────────────┘ │
│                   │ Section title                                      Filter│
│                   │ ┌──────────────────────────────────────────────────────┐ │
│                   │ │ Table header                                         │ │
│                   │ │ Data row, aligned state and action                   │ │
│                   │ │ Data row                                             │ │
│                   │ └──────────────────────────────────────────────────────┘ │
└───────────────────┴──────────────────────────────────────────────────────────┘
```

### Compact wireframe (narrow viewport)

```text
┌───────────────────────────────────┐
│ ☰  [route mark] z2kOW        Theme│
├───────────────────────────────────┤
│ Page title                         │
│ Short context                      │
│ ┌───────────────────────────────┐  │
│ │ Priority state                │  │
│ └───────────────────────────────┘  │
│ Section title       Filter / action│
│ ┌───────────────────────────────┐  │
│ │ Table stays legible and can   │  │
│ │ scroll horizontally as before│  │
│ └───────────────────────────────┘  │
└───────────────────────────────────┘
```

These are hierarchy sketches, not permission to reorder routes or remove controls. Retain all current route, API, RPC, state, persistence, and interaction ownership.

## Motion and feedback

Use no ambient or looping motion. Limit any transition to direct state changes (150–250 ms) for hover, selection, sidebar collapse, modal/sheet, and theme changes. Honor `prefers-reduced-motion: reduce` by removing nonessential transition and animation. Focus movement, confirmation, loading, and errors must remain understandable without animation.

## Implementation boundaries

- Keep the OpenWrt visual system and assets under `platform/openwrt/webpanel-brand/`; continue the existing package-owned exception and installed local path `/usr/lib/z2k/www/assets/openwrt/`.
- Keep shared route, view, API, RPC, backend, and state behavior intact. Do not fork the shared webpanel or add branding-only requests to its critical boot path.
- Keep the route shell usable when optional branding enhancement fails or a browser blocks an identity module. The static first-paint lockup is a single neutral fallback; the local OpenWrt profile enhances it without depending on `/status`.
- Keep all font, logo, favicon, theme, and supporting UI assets local so the panel works offline.
- Add regression coverage for one lockup, exact HTML wordmark, curved/local SVG identity, favicon without text, no raster/remote references, no competing legacy identity, and fallback when identity assets or their optional loader are blocked.
- Browser coverage must render Дашборд, Режимы, Стратегии, WARP, Исключения, Доп. домены, Диагностика, and Благодарности in both dark and light appearance; assert the theme and single identity; check visible keyboard focus and usable zoom/text scaling; capture console errors; and prove a failed branding asset does not blank route content. Verify visual density and responsive behavior on representative narrow and desktop widths.
- Run the requested CI on the exact implementation HEAD and record its run/result separately from browser evidence. Only after CI is green, deploy through the whole package/update path to the Cudy WBR3000UAX v1 running OpenWrt 25.12.5 at `192.168.1.1:8088`; do not manually copy CSS/SVG. Leave LuCI untouched.
- Capture before and after screenshots from the same live route and viewport when practical, and inspect all eight routes in both appearances. Separate source tests, browser checks, CI, package deployment, live browser, traffic, and soak evidence; report gaps explicitly.
- Do not publish a release solely for the theme. Record the implementation under `[Unreleased]` in `CHANGELOG.md`.

## Acceptance checklist

- [x] One neutral first-paint lockup; OpenWrt profile applies one `z2kOW` identity with no duplicate or competing legacy brand.
- [x] OpenWrt-owned component system for light and dark appearances; not only root color overrides.
- [x] Full token roles, recorded contrast, and clear semantic status/action use.
- [x] Smooth route-ribbon vector mark, HTML wordmark, mark-only favicon, no external assets.
- [x] Typography, spacing, surfaces, navigation, cards, controls, tables, badges, and focus treated consistently.
- [x] Sidebar route order and 18 px icon language preserved; topbar contains one left lockup and compact light/auto/dark control at right.
- [x] Reversible and destructive buttons have distinct roles; experimental state keeps semantic warning copy.
- [x] Zoom-equivalent viewport, accessible names, visible keyboard focus, and mobile targets verified in Chromium.
- [x] Route/API/RPC/backend/persistence source remains unchanged; local route and branding-blocker regression coverage passes.
- [x] Browser and asset regression coverage renders all primary routes in both appearances and covers focus, console, responsive, and blocker cases.
- [ ] Exact HEAD CI is green; package is installed through the supported path on the specified Cudy router; LuCI is unchanged.
- [ ] Comparable live before/after screenshots captured; traffic and soak status stated separately.
- [x] `[Unreleased]` updated; no theme-only release published.

Local verification on 2026-09-28: branding 26/26, ownership 11/11, panel pages 15/15, webpanel static 152/152, webpanel package 18/18, and Chromium passed 12 routes in dark/light plus responsive, keyboard, contrast, forced-colors, and blocked-asset cases. This is local evidence, not exact-HEAD CI or live-router evidence.

## Skill installation record

Apple Design Skill is installed project-locally at `.agents/skills/apple-design` and pinned in `skills-lock.json` from `dickwu/apple-design-skill`. The repository `HEAD` resolved during this review is `39ea3fbab3011e0798c076dbeabf4917001499da`; the lock's `computedHash` (`1d50548823a11269581e27242f9cdad2e01be9097680e861cca45abbc2ce6ca5`) identifies installed contents and is distinct from that Git commit SHA.
