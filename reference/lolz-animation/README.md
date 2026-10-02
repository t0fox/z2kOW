# Lolz.team public UI reference capture

This folder records a browser/CDP inspection of the public pages [https://lolz.team/](https://lolz.team/) and [https://lzt.market/). The primary capture was made on 2026-10-01 in Codex's in-app Chromium browser, with a read-only resource refresh from its already-open `lolz.team` tab on 2026-10-02. Only public frontend resources delivered to those pages were inspected or saved. No post, reaction, favorite, message, purchase, or other account/content action was performed.

The requested target was not narrowed to one named UI effect. This research covers the homepage's observed menu and card-hover motion plus motion code and conditional states in its shared/homepage resources, and the market homepage's measured card styling plus effects defined in its market resources. It does **not** claim to inventory every route or every feature of the whole Lolzteam platform. [ANIMATION-INVENTORY.md](ANIMATION-INVENTORY.md) and [MARKET-ANIMATION-INVENTORY.md](MARKET-ANIMATION-INVENTORY.md) separate live-observed motion from code-defined or conditional effects.

The companion [z2kOW WebPanel design pass](WEBPANEL-DESIGN-PASS.md) records how the measured geometry, typography, surfaces and drawer state transitions were carried into the WebPanel. The original Lolz resources and extracted demo remain unchanged; the panel uses a local implementation with its own focus and route handling.

## Capture identity and viewport

- Page: `https://lolz.team/`
- Additional page: `https://lzt.market/`
- Primary analysis CDN build observed in CDP: `7280435c04428cb2232439a10753600f57a32faa`
- An earlier page load in the same browser session used build `fcf0e282ef396c07d19497c15a3547a2f3d672db`; those original responses are preserved separately because the CDN build changed after reload.
- On 2026-10-02, CDP `Page.getResourceTree` on the active `lolz.team` tab reported 192 resources and build `b43db6b749b4fa1ea4731c842ae75616b0ec0698`. The 22 directly relevant CSS/JS/font responses are saved under `original/build-b43db6b7/`; exact URLs and roles are in [RESOURCE-INDEX.md](RESOURCE-INDEX.md).
- The current homepage CSS's drawer rule block is byte-identical to the 2026-10-01 capture, and the current XenForo chunk still wires `.mobileMenuButton > a` to `MmenuLight.offcanvas().open()` on click. The current shared/homepage styles contain 99 unique keyframe names: none were added, and `lztSkeletonShimmer` is absent from this build. The detailed animation catalogue remains tied to its named 2026-10-01 source snapshot.
- Desktop measurement: requested viewport 1440×900; Chromium `innerWidth` was 1425 because of the vertical scrollbar.
- Narrow measurement: requested viewport 390×844; Chromium `innerWidth` was 390 and `document.documentElement.clientWidth` was 375 with the vertical scrollbar. The off-canvas shell was 375 px wide and the panel measured 300 px, exactly 80% of that content width.
- CDP sources used: `Page.getResourceTree`, `Runtime.evaluate`, `Debugger.scriptParsed` / `Debugger.getScriptSource`, CSS computed styles, and `Animation.getCurrentTime` / `Animation.getKeyframes` observations (via the page's Web Animations API). The opened route and source URLs were checked against the browser's loaded resource tree.

## 2026-10-02 current-tab visual verification

These read-only measurements were taken from the two loaded Codex in-app tabs at the stated viewports. They describe only the named pages; they do not establish access to `lolz.live` or `zelenka.guru`.

### `https://lolz.team/` — 614×672

- The live page used a `#0C0F0E` body, `#D6D6D6` primary text, and the fallback stack `-apple-system, BlinkMacSystemFont, Inter, Helvetica Neue, sans-serif`. Base text was 14 px; thread titles were 15 px / weight 600.
- Accent rules were `#00BA78`; cards used `#111615`, raised surfaces `#181E1C`, and subtle borders `#1E2725`. Card radius was 12 px. The fixed header was 44 px high.
- Buttons were 34 px high, 14 px / weight 500, with 10 px radius; primary buttons used a green gradient.
- Separate component states showed a 100 ms linear opacity/transform/visibility popover transition; primary-button active scale `0.97` with a 0.1 s `ease-in-out` transition; and select-popup scale/fade keyframes `chosenDropBelow` / `chosenDropUpwards` using `cubic-bezier(.5,0,0,1.25)`. The `fa-spin` keyframe rotates from 0° to 360°. These are separate effects; the page also contains unrelated keyframes.
- Stylesheet endpoints observed were `https://fonts.googleapis.com/css2` and two `https://lolz.team/css.php` entries.

### `https://lzt.market/` — 1280×720

- The public page had a 1081 px main layout at x=92, with sidebar and main-content columns; the main content column was 800 px wide.
- The search panel used `#111615`, 12 px radius, and 15 px / 20 px padding. A listing card measured 800×222 px with `#111615` surface, 12 px radius, and a 0.1 s `ease-in-out` transition. Card text used Inter at 14 px; the price was 16 px / weight 700.

## Main observed effect: mobile off-canvas menu

### DOM selectors and relevant markup

- Trigger: `.mobileMenuButton > a#nav-icon4[href="#menu"]`.
- Menu: `#menu.mobileMenu.mm-menu.mm-offcanvas`.
- MmenuLight-generated wrapper: `.mm-ocd.mm-ocd--left`.
- Moving panel: `.mm-ocd__content`.
- Dismiss surface: `.mm-ocd__backdrop`.
- Body state: `body.mm-ocd-opened`.

Sanitized, relevant `outerHTML` (the navigation's dynamic links and user-facing entries are intentionally elided):

```html
<a id="nav-icon4" href="#menu" aria-label="Меню" class="no-scroll">
  <svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none">
    <path d="M3 12H21M3 6H21M3 18H15" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path>
  </svg>
</a>

<div class="mm-ocd mm-ocd--left">
  <div class="mm-ocd__content">
    <nav id="menu" class="mobileMenu mm-menu mm-offcanvas">…</nav>
  </div>
  <div class="mm-ocd__backdrop"></div>
</div>
```

### Original CSS and measured transition

The menu is animated with CSS transitions, not `@keyframes`.

- Variables in the homepage CSS: `--mm-ocd-width: 80%`, `--mm-ocd-min-width: 200px`, `--mm-ocd-max-width: 440px`.
- `.mm-ocd`: fixed full-viewport shell; closed state `bottom: 100%`; opening state `bottom: 0`; background transitions from transparent to `rgb(0 0 0 / .25)`.
- Wrapper transition: `bottom 0s .45s, background-color .3s .15s`; open state overrides delay with `0s`. On close, the shell remains long enough for the panel to slide out before being hidden.
- `.mm-ocd__content`: `transform` transition `.3s ease`; left closed transform `translate3d(-100%, 0, 0)`, open transform `translate3d(0, 0, 0)`.
- The drawer was opened and closed repeatedly through the visible browser control. CDP `Runtime.evaluate` sampled the live `document.getAnimations()` effects during both directions. The panel `CSSTransition` is 300 ms, delay 0 ms, easing `ease`; its interpolated keyframes are `translate3d(-100%, 0, 0)` → `translate3d(0, 0, 0)` on open and the reverse on close. At a 300 px panel width this is −300 px → 0 px. There is no named CSS `@keyframes` rule for this drawer; the browser exposes transition keyframes through Web Animations API.
- The wrapper background is a second 300 ms `ease` transition, transparent → `rgb(0 0 0 / .25)` on open and the reverse on close. Closing applies `.15s` delay to this fade. The wrapper's `bottom` transition has duration 0 and a `.45s` close delay so it stays mounted over the viewport until the panel finishes sliding out; opening removes that delay.
- Effective Lolz dark panel override: `.mm-ocd__content { background: #111615 !important; overflow: scroll; }`.
- Backdrop width is computed from the same width/min/max custom properties with `clamp(...)`; `.mm-ocd--left .mm-ocd__backdrop` is right aligned.
- No external image or SVG asset is needed for the drawer. The hamburger glyph is an inline SVG in the DOM.
- The CSS contains a separate `#nav-icon4.open` hamburger-to-X rule set (`.25s ease-in-out` on bars; `.5s ease-in-out` on the button), but the observed menu handler does not add/remove `.open`. It is therefore recorded as present CSS, not as part of the verified drawer transition.

### JS entry point, event, and classes

- Entry point: `XenForo.MobileMenu` in `xenforo-CkeKFsFe.js`, initialized for `.mobileMenuButton` and activated by the element `.mobileMenuButton > a`.
- Initialization creates MmenuLight around `#menu`, using the `left` off-canvas mode. MmenuLight creates the wrapper/content/backdrop, inserts an `original menu location` comment, and moves the menu into the panel. `XenForo.MobileMenu` also adds `.no-scroll` to the trigger during initialization; it is not toggled by open/close.
- Trigger event: `click`. The handler calls the off-canvas `open()`, then prevents the anchor's default action and stops propagation.
- Open adds `.mm-ocd--open` to the wrapper and `.mm-ocd-opened` to `body`. The trigger keeps `.no-scroll`; the click handler does not add `.open`.
- Close event: `touchstart` or `mousedown` on `.mm-ocd__backdrop`. MmenuLight removes both state classes and stops immediate propagation. CDP confirmed `#menu` remains a child of `.mm-ocd__content` after close; the original-location comment is used to restore it only when the MmenuLight media-query toggler unmatches, not on ordinary close.
- A separate `window` click handler in `XenForo.MobileMenu` clears the trigger's inline padding and shows it when the click target is outside `#menu`; this is trigger housekeeping and does not drive the drawer transition.
- No JS animation library, `requestAnimationFrame`, or Web Animations API drives this effect; the JS changes state and CSS transitions interpolate it.

### State sequence

1. Initial: wrapper has `.mm-ocd mm-ocd--left`, body has no `.mm-ocd-opened`; panel is translated left by 100%; wrapper is below the viewport (`bottom: 100%`).
2. Trigger click: `open()` adds `.mm-ocd--open` and body `.mm-ocd-opened`.
3. Open transition: wrapper moves to `bottom: 0` and dims the backdrop; panel translates from −100% to 0 over 300 ms with `ease`.
4. Stable open state: `#menu` stays inside `.mm-ocd__content`; body overscroll chaining is disabled.
5. Backdrop press: `close()` removes the two open classes. `#menu` remains inside `.mm-ocd__content`.
6. Close transition: panel returns to −100% over 300 ms. The wrapper background fades with its `.15s` close delay; wrapper bottom hides after `.45s`.

## Page dimensions and visual references

These are measured values from the inspected homepage, useful as references rather than universal tokens for all Lolzteam routes:

| Element | Desktop measurement / computed style | Narrow measurement / computed style |
|---|---|---|
| Page body | `#0c0f0e`; `14px / 17.92px`; `-apple-system, BlinkMacSystemFont, Inter, "Helvetica Neue", sans-serif` | same |
| Header `#header` | 44 px high; dark translucent background (`rgba` alpha .62) | 44 px high |
| Content `#content` | x=172, width=1081 px | responsive full-width layout |
| Sidebar | x≈177, width=261 px | responsive/collapsed layout |
| Main content | x=453, width=800 px; 15 px sidebar gap | responsive |
| Discussion card | 800 px wide, radius 12 px; background `rgb(17,22,21)` | responsive |
| Card hover | background `rgb(17,22,21)` → `rgb(24,30,28)`; inset border `rgb(30,39,37)` → `rgb(36,47,43)`; `background .15s, transform .15s` | not separately measured |
| Menu panel | max width 440 px; effective content width reported 425 px at 1425 px document client width (scrollbar/content sizing applies) | width 300 px = 80% of 375 px document client width |
| `#nav-icon4` | 36×36 px when visible; radius 10 px; bg `rgb(24,30,28)` | same size/style |
| `.chosen-container` | 220×36 px; radius 10 px; horizontal padding 13 px | not separately measured |
| `.CreateThreadButton` | 160.5×34 px in the observed narrow layout; radius 10 px; horizontal padding 15 px | measured at x=21, y=119 |

## lzt.market reference and loaded effects

CDP `Network.enable` / `Network.responseReceived` recorded 133 responses during the normal public page load. The three CSS/font responses and seven market-specific JS files saved here returned HTTP 200. The resource tree also referenced shared chunks captured with the forum build; those are reused from the same build folder rather than duplicated. No listing or account text was copied into this reference.

Style measurements at a 1280×720 requested viewport (Chromium inner width 1280, document client width 1265):

| Element | Measured style |
|---|---|
| Body | 14 px, `-apple-system, BlinkMacSystemFont, Inter, "Helvetica Neue", sans-serif`; canvas `#0C0F0E`; text `#D6D6D6` |
| `#content` | width 1081 px, x≈92 px |
| `.marketSidebar` | width 261 px |
| `.marketMainContainer` / `.marketItemCard` | width 800 px |
| `.marketItemCard` | base `#111615`, 12 px radius, `transition: 0.1s ease-in-out`; no base transform or shadow |
| Card inner head/footer blocks | `#181E1C` |

The first two inspected card instances had different heights (222 px and 260 px) due to their content. CDP pointer movement reached a visible card after scrolling past a bottom notice; the card and its inner blocks stayed on the same measured surfaces with no transform or shadow change. The card declares a short `0.1s ease-in-out` transition, but the sampled hover did not expose an animated property change. The temporary market tab was closed after measurement; user-owned forum tabs were left open.

See [MARKET-ANIMATION-INVENTORY.md](MARKET-ANIMATION-INVENTORY.md) for selectors, keyframes, transitions, conditional market components, bundle locations, and the limits of runtime observation. Public market-specific resources are saved under `original/build-7280435c/lzt-market/`:

- CSS: `public-base.css`, `public-market.css`, `inter-fonts.css`.
- Page modules: `js/market/core.min.js`, `js/lolzteam/ng/market/core.js`.
- Chunks: `AnimationFrame-lib-D6ehKyKG.js`, `core-BLhDKL1T.js`, `date-picker-svelte-dist-CgrpS2LH.js`, `floatingActions.svelte-BVY5S_4Z.js`, and `svelte-src-DujwBjvd.js`.

The complete source URL for every saved resource is recorded in [RESOURCE-INDEX.md](RESOURCE-INDEX.md), including the exact market stylesheet query and CDN URLs.

Homepage custom properties captured from the loaded CSS/DOM include `--lzt-recent-pages-radius: 10px`, press scale X `1.03`, Y `.94`, easing `cubic-bezier(.42, 1.67, .21, .9)`, duration `.18s`, and pin icon scale `.95`.

## Other animation findings

See [ANIMATION-INVENTORY.md](ANIMATION-INVENTORY.md) and [MARKET-ANIMATION-INVENTORY.md](MARKET-ANIMATION-INVENTORY.md) for the observed/conditional/code-only catalogues. The captured forum base and homepage CSS contain 100 unique keyframe names after deduplication (156 base and 239 homepage transition selector/value pairs); the separate market stylesheet inventory is scoped to the market resources. Important evidence distinctions:

- The discussion-card hover and menu drawer were activated and measured in the browser without making a content change.
- Like burst and confetti require interacting with reaction controls; those actions were not triggered. Their implementation was inspected statically in resources the page loaded.
- Skeletons, spinners, rotating images, tabs, recent-pages press states, copy-success heartbeat, and swipe sheets are conditional on their component/state. Their code is documented as source-defined, not as live-observed during this capture.

## Saved resources and provenance

Original downloaded bytes are under `original/`; `.pretty.*` files under `pretty/` are separate readable copies and do not replace the originals. [RESOURCE-SHA256SUMS.txt](RESOURCE-SHA256SUMS.txt) records a digest for each of the 66 originals. The detailed animation measurements use build `7280435c...`; `build-fcf0e282/` preserves the earlier CDN snapshot and `build-b43db6b7/` preserves the 2026-10-02 resource refresh.

See [RESOURCE-INDEX.md](RESOURCE-INDEX.md) for a file-by-file inventory of all 66 downloaded originals, their URL provenance, build hash and role. In the 2026-10-01 XenForo bundle, `XenForo.MobileMenu` begins around byte 115,931 and its registration for `.mobileMenuButton` around byte 188,639. In the refreshed build it is readable in `pretty/build-b43db6b7/xenforo-iTePVTI1.pretty.js` near line 5,728. MmenuLight's backdrop/open/close implementation is in `mmenu-light-esm-DZvQucl3.js`; the current original is saved under `original/build-b43db6b7/`. Readable copies are under `pretty/`; the `original/` bytes remain unchanged. Five delivered CSS responses contain syntax errors that Prettier rejects; their separate whitespace-formatted copies and parser notes are identified in the resource index.

The animation's direct source files are:

| Local original file | Source URL / use |
|---|---|
| `original/build-7280435c/public-homepage.css` and `capture-1790855897/public-homepage.css` | [2026-10-01 homepage CSS capture](https://lolz.team/css.php?css=public%3Abb_code%2Cpublic%3Alzt_unfurl_telegram.scss%2Cpublic%3AEWRporta2_Global%2Cpublic%3Anode_list%2Cpublic%3Anode_list.scss%2Cpublic%3Anode_category%2Cpublic%3Atitle_prefix_edit%2Cpublic%3Adiscussion_list%2Cpublic%3Alzt_text_ads.scss%2Cpublic%3Ahot_threads.scss%2Cpublic%3Anewmainpage%2Cpublic%3Adiscussion_list_icon%2Cpublic%3Aquick_reply%2Cpublic%3Alzt_fe_editor%2Cpublic%3Alzt_fe_editor_simple%2Cpublic%3Alzt_fe_editor_smilies%2Cpublic%3Alztng_photoshop%2Cpublic%3Alzt_fe_conversation_templates%2Cpublic%3Anode_notify.scss%2Cpublic%3Alztng_core%2Cpublic%3Alztng_liveAlerts%2Cpublic%3Aunfurl.scss%2Cpublic%3Acounter_icons.scss%2Cpublic%3Ammenu_all_v3%2Cpublic%3Alive_header_search_results_user.scss%2Cpublic%3Anav_tab_mobile%2Cpublic%3Anavigation_visitor.scss%2Cpublic%3Alzt_recent_pages.scss%2Cpublic%3Anoticepush.scss&s=52&l=2&d=1790855897&k=c3c486fd1989e62e2e0fa2d3a8f12b9aed2c64aa); drawer, menu sizing, page-specific transitions, Recent Pages styles. The `public-homepage.css` file in the parent build folder is the earlier response (`d=1790855470`); both are preserved.
| `original/build-7280435c/public-base.css` and `capture-1790855897/public-base.css` | [2026-10-01 shared CSS capture](https://lolz.team/css.php?css=public:font,public:xenforo,public:form,public:public&s=52&l=2&d=1790855897); shared keyframes, LikeBurst, tabs, skeletons and controls. |
| `original/build-7280435c/xenforo-CkeKFsFe.js` | [CDN JS bundle](https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/xenforo-CkeKFsFe.js); `XenForo.MobileMenu`, changeable images, animated tabs and component event wiring. |
| `original/build-7280435c/mmenu-light-esm-DZvQucl3.js` | [MmenuLight ESM chunk](https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/mmenu-light-esm-DZvQucl3.js); off-canvas wrapper, backdrop close handlers, `open()`/`close()`. |
| `original/build-7280435c/mmenu-light-src-BfP3NJC5.js` | [MmenuLight source wrapper](https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/mmenu-light-src-BfP3NJC5.js); exports `window.MmenuLight`. |
| `original/build-7280435c/rolldown-runtime-MtAR-uS5.js` | [CDN runtime chunk](https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/rolldown-runtime-MtAR-uS5.js); ESM runtime dependency of the downloaded MmenuLight chunk. |
| `original/build-7280435c/core.js` | [Core bundle](https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/lolzteam/ng/core.js?_v=7280435c04428cb2232439a10753600f57a32faa); registers feature modules and loads motion helpers. |
| `original/build-7280435c/like_burst-BQ4lbENK.js` | [LikeBurst chunk](https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/like_burst-BQ4lbENK.js); reaction-triggered burst. |
| `original/build-7280435c/confetti-CY7pp9a5.js` | [Confetti chunk](https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/confetti-CY7pp9a5.js); conditional celebration handlers. |
| `original/build-7280435c/canvas-confetti-dist-BhZaCPDF.js` | [canvas-confetti dependency](https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/canvas-confetti-dist-BhZaCPDF.js). |
| `original/build-b43db6b7/public-base.css` | [current shared CSS](https://lolz.team/css.php?css=public:font,public:xenforo,public:form,public:public&s=52&l=2&d=1790891290); current shared animation and component rules. |
| `original/build-b43db6b7/public-homepage.css` | [current homepage CSS](https://lolz.team/css.php?css=public%3Abb_code%2Cpublic%3AEWRporta2_Global%2Cpublic%3Anode_list%2Cpublic%3Anode_list.scss%2Cpublic%3Anode_category%2Cpublic%3Atitle_prefix_edit%2Cpublic%3Adiscussion_list%2Cpublic%3Alzt_text_ads.scss%2Cpublic%3Ahot_threads.scss%2Cpublic%3Anewmainpage%2Cpublic%3Adiscussion_list_icon%2Cpublic%3Aquick_reply%2Cpublic%3Alzt_fe_editor%2Cpublic%3Alzt_fe_editor_simple%2Cpublic%3Alzt_fe_editor_smilies%2Cpublic%3Alztng_photoshop%2Cpublic%3Alzt_fe_conversation_templates%2Cpublic%3Anode_notify.scss%2Cpublic%3Alztng_core%2Cpublic%3Alztng_liveAlerts%2Cpublic%3Aunfurl.scss%2Cpublic%3Acounter_icons.scss%2Cpublic%3Ammenu_all_v3%2Cpublic%3Alive_header_search_results_user.scss%2Cpublic%3Anav_tab_mobile%2Cpublic%3Anavigation_visitor.scss%2Cpublic%3Alzt_recent_pages.scss%2Cpublic%3Anoticepush.scss&s=52&l=2&d=1790891290&k=60023f54592b50730d1d16c9a156d0e1f0d3c18b); drawer rule region is byte-identical to the 2026-10-01 capture. |
| `original/build-b43db6b7/xenforo-iTePVTI1.js` | [current XenForo chunk](https://nztcdn.com/js/master/b43db6b749b4fa1ea4731c842ae75616b0ec0698/js/assets/js/chunks/xenforo-iTePVTI1.js); contains the current `XenForo.MobileMenu` event handler. |
| `original/build-b43db6b7/mmenu-light-esm-DZvQucl3.js` | [current MmenuLight ESM chunk](https://nztcdn.com/js/master/b43db6b749b4fa1ea4731c842ae75616b0ec0698/js/assets/js/chunks/mmenu-light-esm-DZvQucl3.js); same hashed implementation used for the drawer. |
| `original/build-b43db6b7/mmenu-light-src-BfP3NJC5.js` | [current MmenuLight wrapper](https://nztcdn.com/js/master/b43db6b749b4fa1ea4731c842ae75616b0ec0698/js/assets/js/chunks/mmenu-light-src-BfP3NJC5.js). |
| `original/build-b43db6b7/rolldown-runtime-MtAR-uS5.js` | [current runtime chunk](https://nztcdn.com/js/master/b43db6b749b4fa1ea4731c842ae75616b0ec0698/js/assets/js/chunks/rolldown-runtime-MtAR-uS5.js); current MmenuLight ESM dependency. |
| `original/build-b43db6b7/like_burst-BGiZfc0n.js` | [current LikeBurst chunk](https://nztcdn.com/js/master/b43db6b749b4fa1ea4731c842ae75616b0ec0698/js/assets/js/chunks/like_burst-BGiZfc0n.js); reaction-triggered effect. |
| `original/build-b43db6b7/confetti-D6GvLetH.js` | [current confetti chunk](https://nztcdn.com/js/master/b43db6b749b4fa1ea4731c842ae75616b0ec0698/js/assets/js/chunks/confetti-D6GvLetH.js); conditional celebration effect. |

Supporting raw resources from the same public builds are retained in the folders, including `script.js`, `forum.min.js`, `jquery`, `Popup`, `PopupMenu`, `Tooltip`, `Spinner`, and earlier build chunks. Their exact CDN paths follow the filenames/build hashes in those folders; page-level animation dependencies are listed above. No external raster, SVG, or font file is needed for the extracted drawer.

## Extracted files and portability

- `extracted/animation.css` contains only the drawer shell, panel, backdrop and the source-derived size/easing values.
- `extracted/animation.js` contains the minimal MmenuLight DOM setup/open/close behavior and the observed click binding. It adds `.no-scroll` during setup, matching the source initialization; the click handler does not toggle that class. The separate trigger-housekeeping window listener and other application behavior are omitted.
- This drawer can be moved 1:1 at the CSS/state-machine level if z2kOW keeps the same `.mm-ocd` DOM shape and state classes. The observed panel/backdrop transitions need no image/font assets. The exact source bundles are preserved for checking any future port.
- LikeBurst's visual CSS/keyframes can be ported separately, but the original JS depends on Lolzteam reaction controls, rate-limiting and confetti hooks; it is not the menu extraction and was not activated in this study.
- The preserved source bundles and extracted reference demo remain unmodified research artifacts. The measured page shell, Inter font files, and menu dimensions/states/timing are implemented in the WebPanel theme and chrome layer; the original Lolz application bundles are not shipped with the panel.
