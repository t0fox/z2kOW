try {
  let e =
      typeof window < `u`
        ? window
        : typeof global < `u`
          ? global
          : typeof globalThis < `u`
            ? globalThis
            : typeof self < `u`
              ? self
              : {},
    t = new e.Error().stack;
  t &&
    ((e._sentryDebugIds = e._sentryDebugIds || {}),
    (e._sentryDebugIds[t] = `75bd2bba-8f4a-497a-9f80-d624860bcf38`),
    (e._sentryDebugIdIdentifier = `sentry-dbid-75bd2bba-8f4a-497a-9f80-d624860bcf38`));
} catch (e) {}
import { __esmMin as e } from "./rolldown-runtime-MtAR-uS5.js";
import {
  core_default as t,
  init_core as n,
} from "./mmenu-light-esm-DZvQucl3.js";
var r,
  i = e(() => {
    (n(), (r = t), (window.MmenuLight = t));
  });
export { i as init_mmenu_light, r as mmenu_light_default };
