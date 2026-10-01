# z2kOW WebPanel: Lolz.team visual and interaction port

This pass applies the user's clarified requirement: match Lolz.team's measured page geometry, typography, surfaces and menu motion throughout the WebPanel. Measurements come from the captured live page and preserved public CSS/JS documented in [README.md](README.md); each local route was checked in Chromium at desktop and narrow sizes.

## Shared page shell

- At the source measurement (1440×900, document client width 1425 px), Lolz's centered `#content` is 1081 px wide: 261 px navigation rail, 15 px gap, and 800 px main column. The WebPanel uses a 260 px rail and 800 px column with the same gap and center relationship. Full HD is a tested extrapolation of that centered source geometry.
- The 44 px page header is fixed, uses the measured `rgb(12 15 14 / 62%)` surface and 10 px backdrop blur, and leaves the page shell at the same vertical start.
- The persistent rail and content are positioned from the shared centered shell; at widths below 768 px, the rail becomes the left drawer and the content becomes fluid. Viewport height does not switch the desktop shell into a mobile layout.
- The product keeps its own z2kOW labels, router-specific routes and controls; these occupy Lolz's measured shell and spacing model.

## Type and controls

- Locally bundled Inter 400/500/600 supplies the same font files and weights referenced by Lolz's public stylesheet. `webpanel/www/fonts/README.md` records their source URLs and `Inter-OFL.txt` carries the license.
- Body text is 14 px with 17.92 px line-height. Navigation rows are 36 px; buttons 34 px with 10 px corners and a 100 ms `ease-in-out` response; text fields are 30 px, borderless and 10 px radius; selects are 36 px. Cards use 12 px radius and no floating shadow.
- The light appearance maps the same structure to legible light surfaces and text; it retains z2kOW's existing theme control.

## Menu and motion

- The local menu has the source DOM wrapper shape: `.mm-ocd.mm-ocd--left > .mm-ocd__content > #nav` plus `.mm-ocd__backdrop`.
- Open state adds `.mm-ocd--open` to the wrapper and `.mm-ocd-opened` to `body`. The panel moves from `translate3d(-100%, 0, 0)` to `translate3d(0, 0, 0)` over 300 ms `ease`; the shell fades over 300 ms with the measured 150 ms close delay and 450 ms closed-state delay. The panel width is 80%, clamped to 200–440 px.
- `webpanel/www/js/chrome.js` uses the existing menu trigger event and these state classes while keeping the panel's focus return, Escape key, close button, route selection and scroll lock behavior. The extracted Lolz MmenuLight source files remain unchanged in `reference/lolz-animation/`; the WebPanel uses its local implementation, not the site's application bundle.
- Cards use the observed 150 ms hover-color/inset-edge response. There is no named `@keyframes` for the observed drawer; it is a CSS transition, as detailed in the source capture.

## Verification

The browser test exercises all 12 configured routes in dark and light appearance, then checks Full HD desktop geometry, narrow navigation, focus and keyboard handling, reduced motion, colors, controls and module loading. Selected screenshots are in [reference/webpanel-qa](../webpanel-qa/README.md). The latest captured command and result are recorded there.
