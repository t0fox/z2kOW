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
    (e._sentryDebugIds[t] = `915b5e22-7769-4b92-b10d-d9827c5676e5`),
    (e._sentryDebugIdIdentifier = `sentry-dbid-915b5e22-7769-4b92-b10d-d9827c5676e5`));
} catch (e) {}
import { __esmMin as e } from "./rolldown-runtime-MtAR-uS5.js";
import { init___sentry_release_injection_file as t } from "./_sentry-release-injection-file-DU9EORvB.js";
import { init_client as n, proxy as r } from "./svelte-src-DujwBjvd.js";
function i(e, t, n = {}, r = 0) {
  let i = a.find((t) => t.id === e);
  if (i) {
    ((i.component = t),
      (i.props = n),
      (i.order = r),
      a.sort((e, t) => e.order - t.order));
    return;
  }
  (a.push({ id: e, component: t, props: n, order: r }),
    a.sort((e, t) => e.order - t.order));
}
var a,
  o = e(() => {
    (n(), t(), (a = r([])));
  });
export {
  a as floatingActions,
  o as init_floatingActions_svelte,
  i as registerFloatingAction,
};
