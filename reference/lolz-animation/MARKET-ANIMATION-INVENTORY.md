# LZT.Market animation and transition inventory

This is a static inventory of the public resources captured from `https://lzt.market/` in the browser session, with the one market-card hover that was inspected live noted separately. The original files under `original/build-7280435c/lzt-market/` were not edited. Readable copies are under `pretty/build-7280435c/lzt-market/`.

## Evidence and limits

- CDP Network captured the resources listed below from the loaded `lzt.market` page; selected CSS, JS and Google Fonts responses returned HTTP 200.
- Runtime style inspection was limited to geometry/computed styles and a pointer hover on a visible `.marketItemCard`. No listing text, names, balances or screenshots are preserved here.
- Viewport at inspection was 1280×720 (`innerWidth: 1280`, `documentElement.clientWidth: 1265`). The card measured 800 px wide, radius 12 px, base background `#111615`; its computed transform remained `none`, and no card-level shadow was present. Moving the pointer over the card did not produce a measurable card background/transform/shadow change. The loaded stylesheet declares a transition on the card but no `.marketItemCard:hover` rule in that selector section. This is an observed absence of a visible card motion in this pass, not proof that every page state is motionless.
- No market drawer, search, cart, menu popup, reaction, loading state, date picker, or AI-title action was triggered. Their rules and handlers below are source-defined/conditional, not live-confirmed effects.
- The network tree contained more resources than this selected research set. The list below covers the captured CSS/JS used for this inventory; it is not a full archive of every image or account-specific request.

## Resource URLs and local files

| Local original | URL observed in the normal browser request |
|---|---|
| `original/build-7280435c/lzt-market/public-base.css` | [shared CSS](https://lzt.market/css.php?css=public:font,public:xenforo,public:form,public:public&s=52&l=2&d=1790855897) |
| `original/build-7280435c/lzt-market/public-market.css` | [market CSS](https://lzt.market/css.php?css=public%3Amarket%2Cpublic%3Amarket_item_state_badges.scss%2Cpublic%3Amarket_top_sellers%2Cpublic%3Amarket_feedback%2Cpublic%3Amessage_simple%2Cpublic%3Amarket_top_category_queries.scss%2Cpublic%3Amarket_top_queries_icon.scss%2Cpublic%3AmarketItemCard.scss%2Cpublic%3Amarket_new_search_bar%2Cpublic%3Amarket_balance_action%2Cpublic%3Amarket_sidebar.scss%2Cpublic%3Amarket_sidebar_content.scss%2Cpublic%3Alztng_core%2Cpublic%3Alztng_liveAlerts%2Cpublic%3Aunfurl.scss%2Cpublic%3Acounter_icons.scss%2Cpublic%3Ammenu_all_v3%2Cpublic%3Amarket_up_header%2Cpublic%3Alive_header_search_results_user.scss%2Cpublic%3Anav_tab_mobile%2Cpublic%3Anavigation_visitor.scss%2Cpublic%3Alzt_recent_pages.scss%2Cpublic%3Afooter_market%2Cpublic%3Anoticepush.scss&s=52&l=2&d=1790855897&k=8ec4a745a7230996e2c58feed5728c4bfcbd9cff) |
| `original/build-7280435c/lzt-market/inter-fonts.css` | [Inter font CSS](https://fonts.googleapis.com/css2?family=Inter:ital,opsz,wght@0,14..32,100..600;1,14..32,100..600&display=swap) |
| `original/build-7280435c/lzt-market/js/market/core.min.js` | `https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/market/core.min.js?_v=7280435c04428cb2232439a10753600f57a32faa` |
| `original/build-7280435c/lzt-market/js/lolzteam/ng/market/core.js` | `https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/lolzteam/ng/market/core.js?_v=7280435c04428cb2232439a10753600f57a32faa` |
| `original/build-7280435c/lzt-market/js/assets/js/chunks/AnimationFrame-lib-D6ehKyKG.js` | `https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/AnimationFrame-lib-D6ehKyKG.js` |
| `original/build-7280435c/lzt-market/js/assets/js/chunks/core-BLhDKL1T.js` | `https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/core-BLhDKL1T.js` |
| `original/build-7280435c/lzt-market/js/assets/js/chunks/floatingActions.svelte-BVY5S_4Z.js` | `https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/floatingActions.svelte-BVY5S_4Z.js` |
| `original/build-7280435c/lzt-market/js/assets/js/chunks/date-picker-svelte-dist-CgrpS2LH.js` | `https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/date-picker-svelte-dist-CgrpS2LH.js` |
| `original/build-7280435c/lzt-market/js/assets/js/chunks/svelte-src-DujwBjvd.js` | `https://nztcdn.com/js/master/7280435c04428cb2232439a10753600f57a32faa/js/assets/js/chunks/svelte-src-DujwBjvd.js` |

`market/core.min.js` imports the shared `core-BLhDKL1T.js` module. The ESM market entry imports Svelte transition/runtime code and jQuery/XenForo helpers. Shared runtime chunks also appear in the sibling `original/build-7280435c/` capture; those are not recopied into this market subdirectory. SVGs used by the AI-title control, cart, and other small icons are inline in component templates. No separate image is required for the motion rules catalogued here.

## Market stylesheet effects

Line numbers below refer to `pretty/build-7280435c/lzt-market/public-market.pretty.css` unless marked as the shared stylesheet.

| Selector / source | Declaration and effect | Evidence status |
|---|---|---|
| `.marketItemCard` (9015–9021); title (9073–9083) | `transition: all 0.1s ease-in-out`; item title has the same 100 ms transition. Card uses 12 px radius and `#111615`. | Card geometry/styles and hover were inspected live; no visible card transition was detected. Conditional rule only. |
| `.lztui-spinner-bounce.lztng-u62i62` (11209–11214), `.lztui-spinner-bounce1/2` (11225–11230), `@keyframes lztng-u62i62-lztui-spinner-bounce` (11231–11240) | Spinner bounce keyframe scales 0→1 at 40%, back to 0 at 80/100. The class declaration refers to `sk-bouncedelay 1.4s infinite ease-in-out both`; stagger delays are −0.32 s and −0.16 s. The namespaced keyframe is present in the same stylesheet but no matching `animation-name` reference was found in the captured CSS. | Conditional loading component; neither spinner state was triggered. Note the source-name mismatch. |
| `.like-smilie` (11365–11387) | Hover reveals a hidden 12×12 icon; icon is rotated 45 degrees; `.liked` changes visibility/color. No transition or keyframe is declared here. | Conditional control; not triggered. |
| `.unfurlContainer.shorted` and hover/active children (11767–11825) | `all 0.1s ease-in-out`; background and icon color change on hover, opacity 0.72 on active. | Conditional pointer states; not triggered in this capture. |
| `#nav-icon4` / its spans and `.open` states (12213–12292) | Button `transform` transition 0.5 s ease-in-out; bars 0.25 s ease-in-out; `.open` rotates first/third bars ±45°, collapses middle bar to width 0/opacity 0. | CSS state exists; market hamburger was not activated. |
| `.burger__link`, `.burgerFontIcon` (12331–12361) | Background transition 0.1 s linear and icon transition 0.1 s ease-in-out. | Conditional hover; not triggered for this inventory. |
| `.mm-ocd` / `.mm-ocd--open` (12429–12458) | Off-canvas wrapper transitions `bottom` and `background-color`; durations `0s, .3s`, easing `ease`, delays `.45s, .15s`; open state sets delays to zero. | CSS-only menu state; no lzt.market drawer cycle recorded. |
| `.mm-ocd__content`, `.mm-ocd--left/right` (12460–12495) | `transform` / `-webkit-transform` transition `.3s ease`; closed panel is translated ±100%, open panel translates to 0. Root widths are `80%`, min 200 px, max 440 px (12420–12423). | Conditional; static CSS only for lzt.market. The separate Lolz.team browser experiment is documented in `README.md`, not evidence of a market-page runtime cycle. |
| `.mobile-switch-menu` and `.menuBlock` descendants (12925–14171) | Mobile nav/profile/footer rows use 0.3 s transitions for background/color/icon changes and active opacity; desktop `.menuBlock .manageItem` uses 0.2 s with icon color/fill/stroke 0.2–0.3 s; profile/footer rows use 0.3 s. | Conditional hover/active states; not triggered here. |
| `.lztRecentPages-skeletonItem::after` (14197–14231) | Shimmer pseudo-element animates `skeleton-loading 1.5s infinite`; responsive width rules at 1024 px (14233–14240). | Conditional while recent-page data is loading; not observed. The keyframe itself is in shared CSS. |
| `.notice.js-pushCta` / `.notice.notice--bottom` (14395–14495) | Fixed blurred bottom overlay; dismiss control transitions all properties over 0.1 s ease-in-out, hover changes color/background, active opacity 0.72. | A notice was present during the capture; its dismiss/hover transition was not activated. |

Other transition-bearing regions include search/filter controls, search history, payment/wallet controls, review actions, category rows, feedback/like controls, item-state rows, date and payment inputs, and market sidebar panels. Use `rg -n '^\s*(?:-webkit-)?transition' pretty/build-7280435c/lzt-market/public-market.pretty.css` to enumerate the entire CSS surface; many rules are state styling rather than standalone motion effects.

## Keyframes and animation declarations

The market stylesheet has one named `@keyframes` block of its own and two `animation` shorthand declarations (one of those references a shared keyframe):

- `lztng-u62i62-lztui-spinner-bounce`, market CSS 11231–11240: scale(0) at 0/80/100%, scale(1) at 40%. The `.lztui-spinner-bounce` declaration at 11210 instead uses the shared `sk-bouncedelay` name; treat the namespaced keyframe as present-but-unreferenced in this capture.
- `skeleton-loading`, defined in shared CSS `pretty/build-7280435c/lzt-market/public-base.pretty.css` around 22875 and earlier in the source CSS. Its keyframe moves `left` from −150 px to 100% at 50%, holding 100% through the end. Market `.lztRecentPages-skeletonItem::after` uses it at 1.5 s infinite (market CSS 14218–14231).
- `sk-bouncedelay`, shared CSS around 32180–32210: three-dot spinner bounce; base `.spinner > .bounce` uses 1.4 s infinite `ease-in-out both`, with staggered `−.32s` and `−.16s` delays. Market shared spinner class points to this generic name.

The shared CSS bundle also defines framework/global keyframes. They are loaded with the market page but most are only available for conditionally added classes. Complete names present in the captured shared and market CSS are:

```text
animateElement, animateElement2, bounce, bounceIn, bounceInDown, bounceInLeft,
bounceInRight, bounceInUp, bounceOut, bounceOutDown, bounceOutLeft,
bounceOutRight, bounceOutUp, bth-icon-spin360, chosenDropBelow,
chosenDropUpwards, fa-spin, fadeIn, fadeInDown, fadeInDownBig, fadeInLeft,
fadeInLeftBig, fadeInRight, fadeInRightBig, fadeInUp, fadeInUpBig, fadeOut,
fadeOutDown, fadeOutDownBig, fadeOutLeft, fadeOutLeftBig, fadeOutRight,
fadeOutRightBig, fadeOutUp, fadeOutUpBig, flash, flip, flipInX, flipInY,
flipOutX, flipOutY, gradientLolzteamMove, headShake, heartBeat, hinge,
jackInTheBox, jello, lightSpeedIn, lightSpeedOut, likeBurstPop,
lztng-u62i62-lztui-spinner-bounce, move-bg, openConversation, pulse, rainbow,
rollIn, rollOut, rotateIn, rotateInDownLeft, rotateInDownRight, rotateInUpLeft,
rotateInUpRight, rotateOut, rotateOutDownLeft, rotateOutDownRight,
rotateOutUpLeft, rotateOutUpRight, rubberBand, shake, shine, sk-bouncedelay,
skeleton-loading, slideInDown, slideInLeft, slideInRight, slideInUp,
slideOutDown, slideOutLeft, slideOutRight, slideOutUp, swing, tada, UltraFast,
wobble, zoomIn, zoomInDown, zoomInLeft, zoomInRight, zoomInUp, zoomOut,
zoomOutDown, zoomOutLeft, zoomOutRight, zoomOutUp
```

Key market-relevant shared declarations in `pretty/build-7280435c/lzt-market/public-base.pretty.css`:

- `.fa-spin` / `.fa-pulse` (212–217): `fa-spin` rotation, 2 s infinite linear or 1 s infinite `steps(8)`.
- `#ChosenContent > input.loading` (7532): `shine` 1.5 s linear infinite. `.chosen-drop` below/upward states (8090–8107): 0.2 s `cubic-bezier(.5,0,0,1.25)` forwards; keyframes scale/fade/translate dropdown into place.
- `.conversationList…` states (22647–22660): `openConversation` translates X 100%→0 in .25 s ease (reverse for the shown state). Shared support, not activated.
- `.LikeLink.LikeBurstPop .icon` (22939–22959): `likeBurstPop` .4 s `cubic-bezier(.2,.9,.3,1.4)`; reduced-motion media rule suppresses it. Reaction JS is not among this page’s captured market entry resources, and no reaction was triggered.
- `.prefix.lolzteam` and `.prefix.ultra_fast_contest` (about 26845–26913): animated gradient keyframes, 6 s / 3 s ease infinite.
- `.animated` family (about 30930–30985): Animate.css base duration 1 s, `fast` 800 ms, `faster` 400 ms, `slow` 2 s, `slower` 3 s, delay classes 1–5 s. Under `prefers-reduced-motion: reduce` and print, duration is 1 ms and iteration count is 1.
- `.bubbleAnimation` / `.bubbleAnimation2` (31187–31192): `animateElement` / `animateElement2`, .3 s linear once.
- `.button.btn-with-icon .btn-icon.spin-animation.spin-icon` (32704): `bth-icon-spin360` .6 s ease-out; generic loading buttons use `fa-spin` (32715–32727).

The market stylesheet has no independent reduced-motion override for its newer namespaced skeleton/spinner keyframes in the inspected bundle. The shared `Animate.css` and LikeBurst rules do contain reduced-motion handling.

## JS animation entry points

The primary newer market source is `original/build-7280435c/lzt-market/js/lolzteam/ng/market/core.js`; its readable copy includes source lines below. `market/core.min.js` is a short loader that imports and initializes `core-BLhDKL1T.js` (pretty copy lines 1–24). `core.js` imports Svelte transition primitives (`slide`, `transition`, `cubicOut`) and component/runtime helpers from `svelte-src-DujwBjvd.js` near lines 8–70. Svelte’s runtime includes Web Animations API `Element.animate()` paths (`svelte-src...pretty.js` around 4814/4843); source inspection alone does not prove which browser path ran for a given component.

| Effect | JS source and state wiring | CSS/parameters | Status |
|---|---|---|---|
| Responsive “show filters” affordance | `ng/market/core.pretty.js` 1580–1645: listens to scroll/resize; when mobile filter viewport is active and `.ExpandParams` is outside the viewport, renders a control. Click or Enter/Space calls the existing `.ExpandParams` click. | Svelte `slide` transition on X, duration 220 ms, `cubicOut` (1634–1639). | Conditional; no filter scrolling/activation observed. |
| Sticky search header | `ng/market/core.pretty.js` 1691–1755 calculates the search bar/header intersection; 1798–1803 coalesces scroll/resize with `requestAnimationFrame`; 1829–1840 installs/removes listeners; 1892–1899 applies/removes `.is-visible` and `aria-hidden`. | Component styles at 1971–1975: initial `opacity:0`, `visibility:hidden`, `pointer-events:none`, `translateY(-16px)`; visible state changes to opacity 1, visible, interactive, transform none. Opacity/transform `.2s cubic-bezier(.33,1,.68,1)`; visibility delay `.2s`, reset to 0 on show. Hidden at widths ≤800 px. | Source-defined scroll-driven motion; market browser pass did not inspect a listing/search detail state where this component appears. |
| Sticky-header popup | `ng/market/core.pretty.js` 1781–1789: pointer enter/focus sets open; pointer leave/blur closes after 150 ms. `mouseenter`/`mouseleave`/`focus`/`blur` bindings at 1879–1884; component is rendered conditionally at 1935–1938. | Svelte `slide` Y −8 px, 160 ms, `cubicOut` at 1927–1933. | Conditional; not opened. |
| AI-title spinner | `ng/market/core.pretty.js` 1248–1268 guards against a second run, switches `idle→loading`, and POSTs `/market/{itemId}/ai-title`; click wiring and disabled state at 1358–1368. The loading branch renders spinner SVG at 1465–1467. | Dynamic CSS at 1488–1496: `.aiTitleButton--spin` uses `lztng-1q0sljm-aiTitleButtonSpin 0.9s linear infinite`, rotating 0→360°. | Conditional on clicking the AI title control; request/action not performed. |
| Deferred moderator popup content | CSS is injected as a component style in `ng/market/core.pretty.js` 2476–2509; `.MenuOpened` and its inverse select the in/out keyframe. | `lztng-1g3zj8m-deferredModIn/Out` each 100 ms linear forwards; opacity, visibility and Y −4 px → 0 (or reverse), lines 2482–2505. | Conditional menu state; not opened. |
| Cart popup | Component in `ng/market/core.pretty.js` 669–929; cart API updates state and `.ToCartButton.added` (682–710). Injected component CSS at 907–925 gives cart-row hover/active transitions and skeleton placeholder. | `.item`/`.itemTitle` hover `all .2s ease-in-out`; active opacity .72; `lztng-x6d30r-skeleton-loading` 1.5 s infinite at lines 907–920. The latter moves its shimmer pseudo-element from left −150 px to 100%. | Conditional popup/loading rows; not opened or loaded into a visibly loading state. |
| Currency list skeleton | Injected style in `ng/market/core.pretty.js` 1217–1230; loading markup at 1205–1215. | `.skeleton::after` uses `lztng-1p6slds-skeleton-loading 1.5s infinite`, same left −150→100% shimmer; currency row background transition .15 s ease. | Conditional initial/loading state; not observed. |
| Auto-buy summary skeleton | `core-BLhDKL1T.pretty.js` 217–240 has inline component CSS and shimmer keyframe `lztng-10cz8ce-skeleton-loading` 1.5 s infinite. Skeleton child also supports a 4 px blur censor state at line 228. | Left −150→100% shimmer; blur is static when `.censor` applies. | Conditional summary count-loading state; not observed. |
| Search category bar | `core-BLhDKL1T.pretty.js` 1857–1859 `animateSearchBar()` calls `animateCSS(..., ['fadeIn'])`. | Shared `.animated`/`fadeIn` keyframe CSS; default 1 s duration unless `faster` modifier is used. | Source entry point found; not called in this pass. |
| Saved-search icon | `core-BLhDKL1T.pretty.js` 1450–1456 chooses `slideInRight` with `faster` when shown, or `slideOutRight` with `faster` then adds `.hidden`. | Shared `Animate.css`; `faster` is 400 ms. | Conditional on saved-search state changing; not changed. |
| “Always show” market content | `core-BLhDKL1T.pretty.js` 4190–4204 toggles visibility; expansion calls `animateCSS(..., ['animated','fadeIn'])`. | Shared `.animated` with fade keyframe; normal duration 1 s (or `.faster` is not present on this call). | Conditional click; not activated. |
| Floating quick actions / date picker | `floatingActions.svelte...pretty.js` includes scroll/resize positioning, but no `@keyframes`/transition declaration was found in that chunk. `date-picker-svelte-dist...pretty.js` 972 and 1463 embeds `all 80ms cubic-bezier(.4,0,.2,1)` input/picker styling. | Date picker focus/selection changes border, shadow and native control state; picker opens via `.visible` (`display:block`), no CSS animation found. | Conditional and not opened. |
| Tooltip/popover transitions | `core-BLhDKL1T.pretty.js` calls Tippy with `animation:'shift-away'` (2439–2448) and `animation:'shift-toward'` (2860–2869, with manual trigger/delay at 2861–2867). | Tippy animation preset; implementation is in shared Tippy/runtime assets rather than a keyframe in these captured CSS files. | Conditional tooltip; not triggered. |
| Floating UI dropdowns and helper motion | `core-BLhDKL1T.pretty.js` uses jQuery `.animate()` at 1088–1104, 2602, 2696 and fades/slides at 2637, 2678, 3654–3660, 4199. | Shared Animate.css or XenForo/jQuery helpers set the actual easing/duration; those helper calls do not all specify the duration inline. | Various scroll, open/close, and content interactions; not triggered for this inventory. |

`AnimationFrame-lib-D6ehKyKG.js` provides scheduling/polyfill helpers. It is not a standalone UI animation; `requestAnimationFrame` use relevant to sticky positioning is visible in the ESM market entry above. `floatingActions.svelte-BVY5S_4Z.js` contains position watching, not its own CSS keyframes.

## Effect sequence summary

For source-defined market motions, the state changes are:

1. **Sticky header:** initial hidden/−16 px → scroll/resize checks whether search bar bottom is above header bottom → Svelte toggles `.is-visible` → opacity and transform move in over 200 ms; close fades and delays `visibility` until the same 200 ms ends.
2. **Sticky popup:** pointer/focus enters → open state → Svelte slide from Y −8 px to rest over 160 ms; leave/blur schedules close after 150 ms → reverse slide. Source-defined, not observed.
3. **AI title:** click → `idle` to `loading`, request starts, button disabled/spinner SVG shown and rotates continuously at .9 s/turn → response/error settles `idle` and preview/apply UI changes. Source-defined, not invoked.
4. **Loading placeholders:** component renders skeleton shape → diagonal highlight moves left −150 px to 100% every 1.5 s → content replaces it when loading state clears. This is CSS source behavior; no market skeleton was captured mid-cycle.
5. **Mobile menu:** click/open state would apply `.mm-ocd--open` and move panel from ±100% to 0 over 300 ms ease, with background fade; the market page’s drawer was not opened in this pass.

## Portability assessment

The CSS and source behavior are technically portable as isolated patterns, with the exact colors, sizes, easing, and class/state names retained here. The `marketItemCard` transition alone is not a demonstrated standalone effect: the tested card had no visible change while hovered. Several richer effects depend on Lolzteam’s Svelte components, XenForo DOM, route endpoints, or jQuery/Tippy helpers, so copying only their keyframes does not reproduce the trigger/state machine. No market-specific effect from this inventory has been integrated into z2kOW.
