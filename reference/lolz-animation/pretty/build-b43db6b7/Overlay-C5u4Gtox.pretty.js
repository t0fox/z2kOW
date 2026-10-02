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
    (e._sentryDebugIds[t] = `ebeb03af-e2ab-4bb9-a9dd-88f122a5324a`),
    (e._sentryDebugIdIdentifier = `sentry-dbid-ebeb03af-e2ab-4bb9-a9dd-88f122a5324a`));
} catch (e) {}
import { __esmMin as e } from "./rolldown-runtime-MtAR-uS5.js";
import {
  init_jquery_xenforo_rollup as t,
  jquery_xenforo_rollup_default as n,
} from "./jquery-nYWvo6DM.js";
import { init___sentry_release_injection_file as r } from "./_sentry-release-injection-file-oX-AVkR8.js";
import { init_xenforo as i, xenforo_default as a } from "./xenforo-iTePVTI1.js";
import {
  init_index_client$2 as o,
  mount as s,
  unmount as c,
} from "./svelte-src-KVj-O-HW.js";
function l(e, t, r = {}, i, o, l = !0) {
  let u = n(`<div class="sectionMain"><div class="helper"></div></div>`);
  (t && n(`<h2 class="heading h1" />`).html(t).insertBefore(u.find(`.helper`)),
    i && n(`.xenOverlay`).data(`overlay`).close());
  let d = {
      onClose: () => {
        (c(f), u.closest(`.xenOverlay`).data(`overlay`).destroy());
      },
      severalModals: !0,
      closeOnSwipe: l,
      className: o,
    },
    f = s(e, {
      target: u.find(`.helper`)[0],
      props: {
        ...r,
        header: u.find(`.heading`)[0],
        closeOverlay: () => u.closest(`.xenOverlay`).data(`overlay`).close(),
      },
    }),
    p = a.createOverlay(null, u, d);
  p.load();
}
var u = e(() => {
  (t(), i(), o(), r());
});
export { u as init_Overlay, l as openSvelteOverlay };
