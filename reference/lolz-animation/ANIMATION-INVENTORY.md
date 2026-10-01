# Animation inventory for the captured public homepage

## Scope and evidence labels

This catalogue covers the standard and homepage CSS responses loaded by `https://lolz.team/` in the current CDP capture (`7280435c04428cb2232439a10753600f57a32faa`). It also records motion components found in the corresponding loaded JavaScript chunks. It is not a claim that every route or all code on Lolzteam has been inspected.

- **Observed** means the state was activated on the page and measured in Chromium.
- **Wired / conditional** means the loaded CSS/JS defines a trigger, but it depends on a component or state that was not activated in this inspection.
- **Code-only** means a declaration exists, but no matching trigger/state was confirmed in the inspected route and captured bundle.

The full current CSS match catalogue, source offsets, resource URLs, and captured SHA-256 hashes are in [effects-catalog.json](effects-catalog.json). Original bytes are under `original/`; readable whitespace-formatted copies are under `pretty/`.

## Live-observed motion

| Effect | Element/state | Implementation | Timing and values | Result |
|---|---|---|---|---|
| Mobile drawer | `.mm-ocd__content` on menu open/close | CSS transition; state toggled by MmenuLight | `transform .3s ease`; `translate3d(-100%,0,0)` ↔ `translate3d(0,0,0)`; shell background `.3s` | Opened and closed repeatedly at narrow widths. No `@keyframes`. |
| Discussion-card hover | `.discussionListItem:hover` | CSS color/shadow transition | `background .15s, transform .15s`; easing `ease`; no transform change occurred | Background `rgb(17,22,21)` → `rgb(24,30,28)`; inset border `rgb(30,39,37)` → `rgb(36,47,43)`. |

The menu's exact markup, event handler, classes, transition delays, close sequence, dimensions, and portability assessment are in the root [README](README.md). The animation itself was run more than once; no posts, reactions, or other account content were changed.

## CSS `@keyframes` coverage

The current shared CSS has **94 unique keyframe names** (175 standard/vendor-prefixed definitions). The current homepage CSS has **9 names** (24 definitions), three of which repeat shared names. That gives **100 unique CSS keyframe names** across the two CSS responses. Vendor-prefixed duplicates are counted as one name. The JSON catalogue retains each definition's source offset.

### Animate.css family (78 names)

```text
bounce, bounceIn, bounceInDown, bounceInLeft, bounceInRight, bounceInUp,
bounceOut, bounceOutDown, bounceOutLeft, bounceOutRight, bounceOutUp,
flash, pulse, rubberBand, shake, headShake, swing, tada, wobble, jello,
heartBeat,
fadeIn, fadeInDown, fadeInDownBig, fadeInLeft, fadeInLeftBig, fadeInRight,
fadeInRightBig, fadeInUp, fadeInUpBig, fadeOut, fadeOutDown, fadeOutDownBig,
fadeOutLeft, fadeOutLeftBig, fadeOutRight, fadeOutRightBig, fadeOutUp,
fadeOutUpBig,
flip, flipInX, flipInY, flipOutX, flipOutY,
lightSpeedIn, lightSpeedOut,
rotateIn, rotateInDownLeft, rotateInDownRight, rotateInUpLeft, rotateInUpRight,
rotateOut, rotateOutDownLeft, rotateOutDownRight, rotateOutUpLeft,
rotateOutUpRight,
hinge, jackInTheBox, rollIn, rollOut,
zoomIn, zoomInDown, zoomInLeft, zoomInRight, zoomInUp,
zoomOut, zoomOutDown, zoomOutLeft, zoomOutRight, zoomOutUp,
slideInDown, slideInLeft, slideInRight, slideInUp,
slideOutDown, slideOutLeft, slideOutRight, slideOutUp
```

Shared timing: `.animated` uses 1 s and `both`; `.fast` 800 ms, `.faster` 400 ms, `.slow` 2 s, `.slower` 3 s; delay utility classes cover 1–5 s; `.infinite` repeats. The shared print/reduced-motion rule reduces animation and transition durations to 1 ms and iteration count to one. `heartBeat` overrides the general duration with 1.3 s `ease-in-out`.

### Other shared CSS keyframes (16 names)

| Name | Selector / state | Source timing or behavior | Evidence |
|---|---|---|---|
| `fa-spin` | `.fa-spin`, `.fa-pulse`, loading controls and status markers | 2 s infinite linear; pulse variant 1 s, `steps(8)` | Conditional controls |
| `shine` | `#ChosenContent > input.loading` | 1.5 s linear infinite; background position moves to −200% | Loading state |
| `chosenDropBelow` | `.chosen-with-drop.chosen-container-active .chosen-drop:not(.chosen-drop-upwards)` | .2 s `cubic-bezier(.5,0,0,1.25)` forwards | Chosen dropdown state |
| `chosenDropUpwards` | matching `.chosen-drop-upwards` | .2 s `cubic-bezier(.5,0,0,1.25)` forwards | Chosen dropdown state |
| `openConversation` | `.conversationList` / `.conversationViewContainer` | .25 s ease; reverse for shown state | Conversation view |
| `move-bg` | `.petushBanner` | 5000 s linear infinite | Special banner |
| `rainbow` | `.petushBanner` | 2.5 s linear infinite | Special banner |
| `likeBurstPop` | `.LikeLink.LikeBurstPop .icon` | .4 s `cubic-bezier(.2,.9,.3,1.4)`; scale 1 → 1.45 at 35% → .9 at 60% → 1 | Wired to reaction; not triggered |
| `skeleton-loading` | `.messageText.SkeletonText .SkeletonTextBlock::after` | 1.5 s infinite; shimmer traverses left −150 px to 100% | Loading state |
| `gradientLolzteamMove` | `.prefix.lolzteam` | 6 s ease infinite | Special badge |
| `UltraFast` | `.prefix.ultra_fast_contest` | 3 s ease infinite | Special badge |
| `animateElement` | `.bubbleAnimation` | .3 s linear, one iteration | Conditional bubble UI |
| `animateElement2` | `.bubbleAnimation2` | .3 s linear, one iteration | Conditional bubble UI |
| `masked-animation` | enumerated `.userText em.statusNNN` selectors | 40 s infinite linear | Specific status text |
| `sk-bouncedelay` | `.spinner > .bounce, .spinner > div` | 1.4 s infinite ease-in-out, `both`; stagger delays −.32 s and −.16 s | Loading state |
| `bth-icon-spin360` | `.button.btn-with-icon .btn-icon.spin-animation.spin-icon` | .6 s ease-out | Button loading state |

### Homepage-only keyframes (6 names)

| Name | Selector / state | Source timing or behavior | Evidence |
|---|---|---|---|
| `lztSkeletonShimmer` | `.lztTgPost-skeleton span::after` | 1.4 s infinite; child shimmer delays .12 s and .24 s | Conditional Telegram-post skeleton; reduced-motion disables it |
| `comefromtop` | `.comefromtop` | .5 s, opacity 0→1 and translateY −100%→0 | Code-only; no assignment found in loaded JS |
| `pushdown` | `.pushdown` | .5 s, translateY −10%→0 | Code-only; no assignment found in loaded JS |
| `loading` | Froala indeterminate file/files/image/video progress spans | 2 s linear infinite | Editor upload state |
| `spin` | `.fr-file-loader` | 2 s linear infinite | Editor upload state |
| `lztng-u62i62-lztui-spinner-bounce` | no animation-name reference | no trigger found | Orphan keyframe in this capture |

`shine`, `chosenDropBelow`, and `chosenDropUpwards` also exist in the shared CSS and are counted once in the 100-name union.

## CSS transitions and state effects

The captured CSS declares a large set of transitions for hover, active, expanded, selected, loading, editor, popup, and modal states. Current full declarations and source offsets are searchable in `effects-catalog.json`; repeated vendor-prefixed forms are retained there. High-signal non-menu values include:

| Selector / component | Transition | Effect/state |
|---|---|---|
| `.Tabs::after` | `opacity .2s`; left/width `.35s cubic-bezier(.4,0,.2,1)`; top `.35s` | Active-tab underline follows JS-updated CSS variables |
| `.modal` | `transform .2s ease-out, opacity .15s` | Modal open/close |
| `.Menu` | opacity, transform and visibility 100 ms linear | Popup/menu state |
| `.chosen-container-active .chosen-drop` | opacity .2 s ease-out | Chosen popup |
| `.messageText .SkeletonTextBlock` | all .2 s ease-in-out | Skeleton/non-skeleton state |
| `.InfiniteScrollSpinner` | all .2 s `cubic-bezier(.25,0,.25,1)` | Scroll loading container |
| `.mm-spn ul` | left .3 s ease | Sliding submenu, distinct from the outer drawer |
| `.burger__link` | background-color .1 s linear | Menu-link interaction |
| `.discussionListItem` | background .15 s, transform .15 s | The hover state observed live |
| `.discussionListItem.newLoaded` | background 1 s | New-item appearance |

## JavaScript motion found in loaded bundles

| Component | Entry / trigger | Motion behavior | Capture status |
|---|---|---|---|
| Mobile menu | `XenForo.MobileMenu`; click `.mobileMenuButton > a` | Calls MmenuLight `open()`, which adds `.mm-ocd--open` and `body.mm-ocd-opened`; backdrop `touchstart`/`mousedown` closes | Live observed; detailed in README |
| `window.animateCSS` helper | Called with a class; copy-success path calls `heartBeat` | Adds `.animated` and requested class, removes them on `animationend` | Code inspected; copy action not invoked |
| LikeBurst | Reaction click on `.like` | Adds `.LikeBurstPop`, removes after 400 ms; preloads on pointerdown; rate limit 250 ms; confetti hook follows | Code inspected; no reaction action |
| Confetti | Button/seasonal text handlers | Loads canvas-confetti and emits celebration particles | Code inspected; no action |
| `Y.ChangeableImages` | Component `.ChangeableImages` with at least 2 images | Sets inline positions/opacities; cross-fades over 1 s ease-in-out and advances each 3 s | Conditional component |
| `Y.AnimatedTabs` | `.Tabs`; click/resize/load/scroll and MutationObserver | `requestAnimationFrame` updates `--tab-left`, `--tab-top`, `--tab-width`, `--tab-height`; CSS underline supplies easing | Component source inspected; no tab click |
| LZT Recent Pages | `.LztRecentPages` registration | Background/opacity/shadow .1 s; press scale x=1.03/y=.94 over .18 s `cubic-bezier(.42,1.67,.21,.9)`; pin icon scale .95; reduced-motion disables transition/press scaling | Component source inspected; skeleton is state-dependent |
| BottomSheet/member-card sheet | Component pointer/touch gesture | `requestAnimationFrame` follows drag; release uses transform 200 ms ease-out; 100 px threshold closes | Conditional component |

Some JS chunks were requested by the homepage shell and contain site-wide components. Their code being present does not prove the component appears on this route. The two live-observed effects are explicitly separated above from those conditional modules.

## Assets directly required by the observed drawer

The drawer needs no remote bitmap, SVG, or font. Its only icon is the inline hamburger SVG. It uses:

1. `public-homepage.css` for drawer geometry, dark panel override, and transition declarations;
2. `xenforo-CkeKFsFe.js` for the `XenForo.MobileMenu` event binding;
3. `mmenu-light-esm-DZvQucl3.js`, `mmenu-light-src-BfP3NJC5.js`, and `rolldown-runtime-MtAR-uS5.js` for the original MmenuLight setup in that bundle.

LikeBurst additionally uses `public-base.css`, `like_burst-BQ4lbENK.js`, `confetti-CY7pp9a5.js`, and `canvas-confetti-dist-BhZaCPDF.js`; these assets are preserved but the external reaction was not fired.
