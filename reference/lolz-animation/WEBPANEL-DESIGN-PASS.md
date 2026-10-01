# z2kOW WebPanel: Lolz visual and interaction pass

This pass applies source-backed Lolz geometry, typography, surfaces, and interaction timings to z2kOW's own routes and controls. The panel keeps its z2kOW brand, data, and route behavior.

## Shared shell

- The captured Lolz page measured a centered 1081 px content wrapper with a 261 px inner rail, 15 px gap, and 800 px main column. The WebPanel uses those same desktop dimensions. At 1920 px, the main column starts at x=693.
- The source logo box is 36×36 px at y=3. The local header is 44 px high and contains the z2kOW mark and theme control.
- Lolz also has header route links and a recent-pages strip. The WebPanel already has a complete side menu for its routes, so these duplicated local route lists were removed to keep navigation in one place. The main content and side rail start below the 44 px header.
- At 390 px, the side menu becomes the existing left drawer; the compact header keeps the menu trigger, mark, and theme control. Strategy tabs use tighter horizontal spacing at this width so all labels fit without clipping.

## Typography and controls

- The browser rendered the source page with the system-first Inter stack, 14 px body text, and 17.92 px line-height. The WebPanel uses locally served Inter weights 400/500/600 with that body scale.
- Cards use a 12 px radius and a flat bordered surface. Standard inputs are 30 px, selects are 36 px, and the strategy selector is 220×36 px.
- Primary buttons use the observed 88° three-stop gradient, a 300 ms hover overlay, brightness adjustment, and the 100 ms `scale(.97)` press. Destructive buttons keep a distinct red surface.
- Strategy tabs use the measured 2 px underline, 5 px inset, and 350 ms `cubic-bezier(.4,0,.2,1)` motion. The active indicator follows horizontal scrolling and recalculates after resize and async DOM insertion.
- Modals use the observed `.in` state: scale `.9` to `1` over 200 ms `ease-out`, with 150 ms opacity. Skeletons use the captured 350 px shimmer and 1.5 s `skeleton-loading` keyframes. Reduced motion is respected.
- Frozen strategy rows expose semantic `data-frozen` state and use the selected surface rather than an inline blue color.

## Product behavior and limits

The pass does not replace the router, backend APIs, WARP operations, strategy semantics, or other z2kOW actions. It applies shared visual tokens to all 12 routes; route-specific forms and tables remain shaped around the router panel's data. Forum-only content and navigation patterns are not added.

The source measurements come from the public Lolz capture documented in [the capture report](README.md). They support the shared shell and component timings; they do not establish pixel-perfect equivalence for router-specific pages.

## Verification

The Chromium suite renders all 12 routes in dark and light modes across desktop, tablet, and 390 px layouts. It checks the single side navigation, compact header, full visibility of strategy tabs, measured shell and controls, modal and drawer lifecycles, frozen rows, no-overflow, contrast, keyboard behavior, reduced motion, and local asset/module loading. Reviewed captures are listed in [the WebPanel QA report](../webpanel-qa/README.md).
