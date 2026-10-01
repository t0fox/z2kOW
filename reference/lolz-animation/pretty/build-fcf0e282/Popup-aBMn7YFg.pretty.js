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
    (e._sentryDebugIds[t] = `e39b4b75-643d-45b9-850e-caecf1a56906`),
    (e._sentryDebugIdIdentifier = `sentry-dbid-e39b4b75-643d-45b9-850e-caecf1a56906`));
} catch (e) {}
import { __esmMin as e, __toESM as t } from "./rolldown-runtime-MtAR-uS5.js";
import { require_jquery as n } from "./jquery-DeI9fuVc.js";
import {
  $document as r,
  action as i,
  append as a,
  append_styles as o,
  bind_this as s,
  child as c,
  create_custom_element as l,
  delegate as u,
  delegated as d,
  event as f,
  flushSync as p,
  from_html as m,
  get$1 as h,
  if_block as g,
  init_client as _,
  init_disclose_version as v,
  noop as y,
  pop as b,
  prop as x,
  proxy as S,
  push as C,
  reset as w,
  set as T,
  set_class as E,
  sibling as D,
  snippet as O,
  state as k,
  template_effect as A,
  user_derived as j,
  user_effect as M,
} from "./svelte-src-DujwBjvd.js";
import {
  createPopperActions as N,
  init_Popper as P,
} from "./Popper-CjyNJtup.js";
import { PopupState as F, init_types as I } from "./types-CJqEXvxE.js";
function L() {
  (0, z.default)(document).trigger(`HideAllMenus`);
}
function R(e, t) {
  (C(t, !0), o(e, H));
  let n = 250,
    l = x(t, `trigger`, 7),
    u = x(t, `content`, 7),
    m = x(t, `popupToggle`, 7),
    _ = x(t, `showOnHover`, 7, !1),
    v = x(t, `offset`, 7, 0),
    [P, I, L] = N({
      placement: `bottom-start`,
      strategy: `fixed`,
      modifiers: v() ? [{ name: `offset`, options: { offset: [0, v()] } }] : [],
    }),
    R = k(S(F.closed)),
    U,
    W = !1,
    G = (e) => {
      W = e.defaultPrevented;
    };
  function K() {
    var e;
    if (!(h(R) === F.closing || h(R) === F.closed)) {
      if (W) {
        W = !1;
        return;
      }
      (clearTimeout(U),
        (e = m()) == null || e(!1),
        T(R, F.closing, !0),
        (U = setTimeout(() => {
          T(R, F.closed, !0);
        }, n)));
    }
  }
  function q() {
    var e;
    if (!(h(R) === F.opening || h(R) === F.opened)) {
      if (
        ((0, z.default)(document).trigger(`HideAllMenus`),
        clearTimeout(U),
        h(R) === F.closing)
      ) {
        var t;
        (t = L()) == null || t.update();
      }
      ((e = m()) == null || e(!0),
        T(R, F.opening, !0),
        (U = setTimeout(() => {
          T(R, F.opened, !0);
        }, n)));
    }
  }
  let J = k(!1);
  function ee(e) {
    (e.preventDefault(),
      e.stopPropagation(),
      !(h(R) === F.opening && h(J)) &&
        (h(R) === F.opening || h(R) === F.opened ? K() : q()));
  }
  function te(e) {
    (e.preventDefault(),
      e.stopPropagation(),
      T(J, !0),
      h(R) !== F.opening &&
        h(R) !== F.opened &&
        setTimeout(() => (h(J) ? q() : K()), 200));
  }
  function Y(e) {
    return (
      (0, z.default)(document).on(`HideAllMenus PopupMenuShow`, K),
      {
        destroy() {
          (0, z.default)(document).off(`HideAllMenus PopupMenuShow`, K);
        },
      }
    );
  }
  let X = k(void 0);
  M(() => {
    h(X) && document.body.appendChild(h(X));
  });
  let ne = j(l),
    re = j(u);
  var ie = {
      get trigger() {
        return l();
      },
      set trigger(e) {
        (l(e), p());
      },
      get content() {
        return u();
      },
      set content(e) {
        (u(e), p());
      },
      get popupToggle() {
        return m();
      },
      set popupToggle(e) {
        (m(e), p());
      },
      get showOnHover() {
        return _();
      },
      set showOnHover(e = !1) {
        (_(e), p());
      },
      get offset() {
        return v();
      },
      set offset(e = 0) {
        (v(e), p());
      },
    },
    Z = V();
  (f(`mousedown`, r, G), f(`click`, r, K));
  var Q = c(Z);
  let $;
  var ae = c(Q);
  (O(ae, () => {
    var e;
    return (e = h(ne)) == null ? y : e;
  }),
    w(Q));
  var oe = D(Q, 2),
    se = (e) => {
      var t = B(),
        n = c(t);
      let r;
      var o = c(n);
      (O(o, () => {
        var e;
        return (e = h(re)) == null ? y : e;
      }),
        w(n),
        w(t),
        i(t, (e) => (I == null ? void 0 : I(e))),
        s(
          t,
          (e) => T(X, e),
          () => h(X),
        ),
        A(
          () =>
            (r = E(n, 1, `Menu lztng-wx1ifo`, null, r, {
              MenuOpened: h(R) === F.opened || h(R) === F.opening,
            })),
        ),
        a(e, t));
    };
  return (
    g(oe, (e) => {
      h(R) !== F.closed && e(se);
    }),
    w(Z),
    i(Z, (e) => (Y == null ? void 0 : Y(e))),
    i(Z, (e) => (P == null ? void 0 : P(e))),
    A(
      () =>
        ($ = E(Q, 1, `PopupControl`, null, $, {
          PopupOpen: h(R) === F.opened || h(R) === F.opening,
          PopupClosed: h(R) === F.closing || h(R) === F.closed,
        })),
    ),
    d(`click`, Q, ee),
    d(`mouseover`, Q, function (...e) {
      var t;
      (t = _() ? te : () => {}) == null || t.apply(this, e);
    }),
    f(`mouseleave`, Q, () => T(J, !1)),
    d(`keydown`, Q, () => {}),
    a(e, Z),
    b(ie)
  );
}
var z,
  B,
  V,
  H,
  U = e(() => {
    (v(),
      (z = t(n())),
      _(),
      I(),
      P(),
      (B = m(`<div class="lztui-Popup lztng-wx1ifo"><div><!></div></div>`)),
      (V = m(
        `<div class="Popup lztng-wx1ifo" data-assume-activated="true"><div role="button" tabindex="0"><!></div> <!></div>`,
      )),
      (H = {
        hash: `lztng-wx1ifo`,
        code: `.lztui-Popup.lztng-wx1ifo {z-index:5699;}.Menu.lztng-wx1ifo {position:static;}.Popup.lztng-wx1ifo {display:flex;}`,
      }),
      u([`click`, `mouseover`, `keydown`]),
      l(
        R,
        {
          trigger: {},
          content: {},
          popupToggle: {},
          showOnHover: {},
          offset: {},
        },
        [],
        [],
        { mode: `open` },
      ));
  });
export { R as Popup, L as hideAllPopups, U as init_Popup };
