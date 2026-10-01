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
    (e._sentryDebugIds[t] = `3ac939f4-9b1f-4eda-972e-5393c62cb8e1`),
    (e._sentryDebugIdIdentifier = `sentry-dbid-3ac939f4-9b1f-4eda-972e-5393c62cb8e1`));
} catch (e) {}
import { __esmMin as e } from "../../../assets/js/chunks/rolldown-runtime-MtAR-uS5.js";
import {
  init_jquery_xenforo_rollup as t,
  jquery_xenforo_rollup_default as n,
} from "../../../assets/js/chunks/jquery-Csqho11y.js";
import { init___sentry_release_injection_file as r } from "../../../assets/js/chunks/_sentry-release-injection-file-DU9EORvB.js";
import {
  formatFloat as i,
  init_xenforo as a,
  init_xf as o,
  phrase as s,
  visitor as c,
  xenforo_default as l,
} from "../../../assets/js/chunks/xenforo-CkeKFsFe.js";
import {
  $window as u,
  action as d,
  append as f,
  append_styles as p,
  bind_checked as m,
  bind_this as h,
  child as g,
  clsx as _,
  comment as v,
  create_custom_element as y,
  cubicOut as b,
  delegate as x,
  delegated as S,
  each as C,
  event as w,
  first_child as T,
  flushSync as E,
  fly as D,
  from_html as O,
  from_svg as k,
  get$1 as A,
  html as j,
  if_block as M,
  index as N,
  init as ee,
  init_client as P,
  init_disclose_version as F,
  init_easing as I,
  init_index_client$2 as L,
  init_legacy as te,
  init_transition as ne,
  mount as re,
  next as R,
  onMount as ie,
  only_child as z,
  pop as B,
  prop as V,
  proxy as ae,
  push as H,
  remove_input_defaults as oe,
  reset as U,
  set as W,
  set_attribute as G,
  set_checked as se,
  set_class as K,
  set_style as ce,
  set_text as q,
  set_value as le,
  sibling as J,
  slide as ue,
  state as Y,
  template_effect as X,
  text as de,
  to_array as fe,
  transition as pe,
  user_derived as Z,
  user_effect as me,
} from "../../../assets/js/chunks/svelte-src-DujwBjvd.js";
import {
  flip as he,
  init_floating_ui_dom as ge,
  offset as _e,
  shift as ve,
} from "../../../assets/js/chunks/@floating-ui-dom-BbfNPIpv.js";
import {
  createFloatingActions as ye,
  init_floating as be,
} from "../../../assets/js/chunks/floating-B20kKcsO.js";
import {
  Scrollable as xe,
  init_Scrollable as Se,
} from "../../../assets/js/chunks/Scrollable-Bta5dahV.js";
import {
  Select as Ce,
  init_Select as we,
} from "../../../assets/js/chunks/Select-BE5szm7a.js";
import {
  bindFilterCount as Te,
  core_default as Q,
  filterCountState as Ee,
  init_core as De,
  init_deferredMod as Oe,
  init_filterCount_svelte as ke,
  runDeferredModActions as Ae,
} from "../../../assets/js/chunks/core-BLhDKL1T.js";
import {
  init_api as je,
  xenApiFetch as Me,
} from "../../../assets/js/chunks/api-DL24p_US.js";
import {
  init_Tooltip as Ne,
  simpleTooltip as Pe,
} from "../../../assets/js/chunks/Tooltip-Cr6IwMoT.js";
import {
  init_mountOnce as Fe,
  mountOnce as Ie,
} from "../../../assets/js/chunks/mountOnce-V4ehP90m.js";
import {
  Spinner as Le,
  init_Spinner as Re,
} from "../../../assets/js/chunks/Spinner-DWPFGXTE.js";
import {
  Popup as ze,
  init_Popup as Be,
} from "../../../assets/js/chunks/Popup-PH-PQZ6v.js";
import {
  init_Overlay as Ve,
  openSvelteOverlay as He,
} from "../../../assets/js/chunks/Overlay-DalX65x7.js";
import {
  init_floatingActions_svelte as Ue,
  registerFloatingAction as We,
} from "../../../assets/js/chunks/floatingActions.svelte-BVY5S_4Z.js";
import {
  dist_default as Ge,
  init_dist as Ke,
} from "../../../assets/js/chunks/@castlenine-svelte-qrcode-BT8T4dcj.js";
import {
  html2canvas_esm_default as qe,
  init_html2canvas_esm as Je,
} from "../../../assets/js/chunks/html2canvas-dist--MXe4sTW.js";
import {
  init_tippy_esm as Ye,
  tippy_esm_default as Xe,
} from "../../../assets/js/chunks/tippy.js-dist-DJnX1fEs.js";
function Ze(e) {
  let t = [];
  for (let n = 0, r = e.length; n < r; n++) t.push(e[n]);
  return t;
}
function Qe(e = {}) {
  return (
    lt ||
    (e.includeStyleProperties
      ? ((lt = e.includeStyleProperties), lt)
      : ((lt = Ze(window.getComputedStyle(document.documentElement))), lt))
  );
}
function $e(e, t) {
  var n;
  let r =
      (e == null || (n = e.ownerDocument) == null ? void 0 : n.defaultView) ||
      window,
    i = r.getComputedStyle(e).getPropertyValue(t);
  return i ? parseFloat(i.replace(`px`, ``)) : 0;
}
function et(e) {
  let t = $e(e, `border-left-width`),
    n = $e(e, `border-right-width`);
  return e.clientWidth + t + n;
}
function tt(e) {
  let t = $e(e, `border-top-width`),
    n = $e(e, `border-bottom-width`);
  return e.clientHeight + t + n;
}
function nt(e, t = {}) {
  let n = t.width || et(e),
    r = t.height || tt(e);
  return { width: n, height: r };
}
function rt() {
  return window.devicePixelRatio || 1;
}
function it(e) {
  (e.width > $ || e.height > $) &&
    (e.width > $ && e.height > $
      ? e.width > e.height
        ? ((e.height *= $ / e.width), (e.width = $))
        : ((e.width *= $ / e.height), (e.height = $))
      : e.width > $
        ? ((e.height *= $ / e.width), (e.width = $))
        : ((e.width *= $ / e.height), (e.height = $)));
}
function at(e) {
  return new Promise((t, n) => {
    let r = new Image();
    ((r.onload = () => {
      r.decode().then(() => {
        requestAnimationFrame(() => t(r));
      });
    }),
      (r.onerror = n),
      (r.crossOrigin = `anonymous`),
      (r.decoding = `async`),
      (r.src = e));
  });
}
async function ot(e) {
  return Promise.resolve()
    .then(() => new XMLSerializer().serializeToString(e))
    .then(encodeURIComponent)
    .then((e) => `data:image/svg+xml;charset=utf-8,${e}`);
}
async function st(e, t, n) {
  let r = `http://www.w3.org/2000/svg`,
    i = document.createElementNS(r, `svg`),
    a = document.createElementNS(r, `foreignObject`);
  return (
    i.setAttribute(`width`, `${t}`),
    i.setAttribute(`height`, `${n}`),
    i.setAttribute(`viewBox`, `0 0 ${t} ${n}`),
    a.setAttribute(`width`, `100%`),
    a.setAttribute(`height`, `100%`),
    a.setAttribute(`x`, `0`),
    a.setAttribute(`y`, `0`),
    a.setAttribute(`externalResourcesRequired`, `true`),
    i.appendChild(a),
    a.appendChild(e),
    ot(i)
  );
}
var ct,
  lt,
  $,
  ut,
  dt = e(() => {
    (r(),
      (ct = (() => {
        let e = 0,
          t = () =>
            `0000${((Math.random() * 36 ** 4) << 0).toString(36)}`.slice(-4);
        return () => ((e += 1), `u${t()}${e}`);
      })()),
      (lt = null),
      ($ = 16384),
      (ut = (e, t) => {
        if (e instanceof t) return !0;
        let n = Object.getPrototypeOf(e);
        return n === null ? !1 : n.constructor.name === t.name || ut(n, t);
      }));
  });
function ft(e) {
  let t = e.getPropertyValue(`content`);
  return `${e.cssText} content: '${t.replace(/'|"/g, ``)}';`;
}
function pt(e, t) {
  return Qe(t)
    .map((t) => {
      let n = e.getPropertyValue(t),
        r = e.getPropertyPriority(t);
      return `${t}: ${n}${r ? ` !important` : ``};`;
    })
    .join(` `);
}
function mt(e, t, n, r) {
  let i = `.${e}:${t}`,
    a = n.cssText ? ft(n) : pt(n, r);
  return document.createTextNode(`${i}{${a}}`);
}
function ht(e, t, n, r) {
  let i = window.getComputedStyle(e, n),
    a = i.getPropertyValue(`content`);
  if (a === `` || a === `none`) return;
  let o = ct();
  try {
    t.className = `${t.className} ${o}`;
  } catch (e) {
    return;
  }
  let s = document.createElement(`style`);
  (s.appendChild(mt(o, n, i, r)), t.appendChild(s));
}
function gt(e, t, n) {
  (ht(e, t, `:before`, n), ht(e, t, `:after`, n));
}
var _t = e(() => {
  (dt(), r());
});
async function vt(e) {
  return e.cloneNode(Tt(e));
}
async function yt(e, t, n) {
  var r;
  if (Tt(t)) return t;
  let i = [];
  if (wt(e) && e.assignedNodes) i = Ze(e.assignedNodes());
  else if (
    ut(e, HTMLIFrameElement) &&
    (r = e.contentDocument) != null &&
    r.body
  )
    i = Ze(e.contentDocument.body.childNodes);
  else {
    var a;
    i = Ze(((a = e.shadowRoot) == null ? e : a).childNodes);
  }
  return (
    i.length === 0 ||
      ut(e, HTMLVideoElement) ||
      (await i.reduce(
        (e, r) =>
          e
            .then(() => Ct(r, n))
            .then((e) => {
              e && t.appendChild(e);
            }),
        Promise.resolve(),
      )),
    t
  );
}
function bt(e, t, n) {
  let r = t.style;
  if (!r) return;
  let i = window.getComputedStyle(e);
  i.cssText
    ? ((r.cssText = i.cssText), (r.transformOrigin = i.transformOrigin))
    : Qe(n).forEach((n) => {
        let a = i.getPropertyValue(n);
        if (n === `font-size` && a.endsWith(`px`)) {
          let e = Math.floor(parseFloat(a.substring(0, a.length - 2))) - 0.1;
          a = `${e}px`;
        }
        (ut(e, HTMLIFrameElement) &&
          n === `display` &&
          a === `inline` &&
          (a = `block`),
          n === `d` &&
            t.getAttribute(`d`) &&
            (a = `path(${t.getAttribute(`d`)})`),
          r.setProperty(n, a, i.getPropertyPriority(n)));
      });
}
function xt(e, t, n) {
  return (ut(t, Element) && (bt(e, t, n), gt(e, t, n)), t);
}
async function St(e, t) {
  let n = e.querySelectorAll ? e.querySelectorAll(`use`) : [];
  if (n.length === 0) return e;
  let r = {};
  for (let i = 0; i < n.length; i++) {
    let a = n[i],
      o = a.getAttribute(`xlink:href`);
    if (o) {
      let n = e.querySelector(o),
        i = document.querySelector(o);
      !n && i && !r[o] && (r[o] = await Ct(i, t, !0));
    }
  }
  let i = Object.values(r);
  if (i.length) {
    let t = `http://www.w3.org/1999/xhtml`,
      n = document.createElementNS(t, `svg`);
    (n.setAttribute(`xmlns`, t),
      (n.style.position = `absolute`),
      (n.style.width = `0`),
      (n.style.height = `0`),
      (n.style.overflow = `hidden`),
      (n.style.display = `none`));
    let r = document.createElementNS(t, `defs`);
    n.appendChild(r);
    for (let e = 0; e < i.length; e++) r.appendChild(i[e]);
    e.appendChild(n);
  }
  return e;
}
async function Ct(e, t, n) {
  return !n && t.filter && !t.filter(e)
    ? null
    : Promise.resolve(e)
        .then((e) => vt(e))
        .then((n) => yt(e, n, t))
        .then((n) => xt(e, n, t))
        .then((e) => St(e, t));
}
var wt,
  Tt,
  Et = e(() => {
    (_t(),
      dt(),
      r(),
      (wt = (e) => e.tagName != null && e.tagName.toUpperCase() === `SLOT`),
      (Tt = (e) => e.tagName != null && e.tagName.toUpperCase() === `SVG`));
  });
async function Dt(e, t) {
  let n = t.fontEmbedCSS == null ? (t.skipFonts, null) : t.fontEmbedCSS;
  if (n) {
    let t = document.createElement(`style`),
      r = document.createTextNode(n);
    (t.appendChild(r),
      e.firstChild ? e.insertBefore(t, e.firstChild) : e.appendChild(t));
  }
}
var Ot = e(() => {
  r();
});
async function kt(e, t = {}) {
  let { width: n, height: r } = nt(e, t),
    i = await At(e, t),
    a = await at(i),
    o = document.createElement(`canvas`),
    s = o.getContext(`2d`),
    c = t.pixelRatio || rt(),
    l = t.canvasWidth || n,
    u = t.canvasHeight || r;
  return (
    (o.width = l * c),
    (o.height = u * c),
    t.skipAutoScale || it(o),
    (o.style.width = `${l}`),
    (o.style.height = `${u}`),
    t.backgroundColor &&
      ((s.fillStyle = t.backgroundColor), s.fillRect(0, 0, o.width, o.height)),
    s.drawImage(a, 0, 0, o.width, o.height),
    o
  );
}
async function At(e, t = {}) {
  let { width: n, height: r } = nt(e, t),
    i = await Ct(e, t, !0);
  return (await Dt(i, t), await st(i, n, r));
}
var jt = e(() => {
  (dt(), Et(), Ot(), r());
});
function Mt(e, t) {
  (H(t, !0), p(e, Ft));
  let n = V(t, `sellerNickname`, 7),
    r = V(t, `marketTitle`, 7),
    i = V(t, `price`, 7),
    a = V(t, `list`, 7),
    o = V(t, `bannerGoodsText`, 7),
    c = V(t, `bannerType`, 7),
    l = Y(``);
  me(() => {
    A(l) !== `` && A(m) && _();
  });
  let u = Y(null),
    m = Y(null);
  ie(() => {
    n() &&
      kt(n(), { pixelRatio: 3 })
        .then((e) => {
          W(m, e, !0);
        })
        .catch((e) =>
          console.error(
            `DownloadGoodsBanner: failed to render seller nickname to canvas`,
            e,
          ),
        );
  });
  let _ = async () => {
      var e;
      A(m) && ((e = A(u)) == null || e.appendChild(A(m)));
      let t = document.getElementById(`banner_${c()}`);
      t &&
        qe(t, { useCORS: !0 }).then((e) => {
          let t = e.toDataURL(`image/png`),
            n = document.createElement(`a`);
          ((n.download = `banner.png`), (n.href = t), n.click(), W(l, ``));
        });
    },
    v = Y(void 0);
  function y(e) {
    me(() => {
      let t = Xe(e, {
        arrow: !1,
        content: A(v),
        interactive: !0,
        placement: `left`,
      });
      return t.destroy;
    });
  }
  var b = {
      get sellerNickname() {
        return n();
      },
      set sellerNickname(e) {
        (n(e), E());
      },
      get marketTitle() {
        return r();
      },
      set marketTitle(e) {
        (r(e), E());
      },
      get price() {
        return i();
      },
      set price(e) {
        (i(e), E());
      },
      get list() {
        return a();
      },
      set list(e) {
        (a(e), E());
      },
      get bannerGoodsText() {
        return o();
      },
      set bannerGoodsText(e) {
        (o(e), E());
      },
      get bannerType() {
        return c();
      },
      set bannerType(e) {
        (c(e), E());
      },
    },
    x = Pt(),
    C = T(x),
    w = g(C);
  (d(w, (e) => (y == null ? void 0 : y(e))), U(C));
  var D = J(C, 2),
    O = g(D),
    k = J(O, 2);
  (U(D),
    h(
      D,
      (e) => W(v, e),
      () => A(v),
    ));
  var N = J(D, 2),
    ee = (e) => {
      var t = Nt(),
        n = g(t),
        d = z(n, !0),
        p = J(n, 2);
      (j(p, () => a().innerHTML, !0), U(p));
      var m = J(p, 2),
        _ = g(m),
        v = g(_),
        y = J(v);
      (j(y, r), U(_));
      var b = J(_, 2),
        x = g(b),
        S = g(x),
        C = g(S),
        w = J(C);
      (j(w, i), R(), U(S));
      var T = J(S, 2),
        E = g(T),
        D = z(E, !0),
        O = J(E, 2);
      (h(
        O,
        (e) => W(u, e),
        () => A(u),
      ),
        U(T),
        R(2),
        U(x));
      var k = J(x, 2),
        M = g(k);
      Ge(M, { data: window.location.href, size: 140 });
      var N = J(M, 2),
        ee = z(N);
      (U(k),
        U(b),
        U(m),
        U(t),
        X(
          (e, n, r, i, a) => {
            (G(t, `id`, `banner_${c()}`),
              G(t, `data-type`, c()),
              q(d, o()),
              q(v, `${e == null ? `` : e} `),
              q(C, `${n == null ? `` : n} `),
              q(D, r),
              q(ee, `${i == null ? `` : i} ${a == null ? `` : a}`));
          },
          [
            () => s(`banner_name_${A(l)}`),
            () => s(`banner_priceTitle_${A(l)}`),
            () => s(`banner_seller_${A(l)}`),
            () => s(`banner_actual_${A(l)}`),
            () => new Date().toLocaleDateString(),
          ],
        ),
        f(e, t));
    };
  return (
    M(N, (e) => {
      A(l) !== `` && e(ee);
    }),
    S(`click`, O, () => {
      W(l, `RU`);
    }),
    S(`click`, k, () => {
      W(l, `EN`);
    }),
    f(e, x),
    B(b)
  );
}
var Nt,
  Pt,
  Ft,
  It = e(() => {
    (F(),
      P(),
      Ke(),
      Je(),
      L(),
      Ye(),
      o(),
      jt(),
      (Nt = O(
        `<div class="banner lztng-1vys5jr"><div class="bannerInfo--goodsCount lztng-1vys5jr"> </div> <div class="bannerList marketItemView--gamesContainer fortniteItems valorantItems lztng-1vys5jr"></div> <div class="bannerInfo--container lztng-1vys5jr"><span class="bannerInfo--title lztng-1vys5jr"> <!></span> <div class="bannerInfo--description lztng-1vys5jr"><div class="bannerInfo--text lztng-1vys5jr"><span> <!> &#x20BD;</span> <div class="bannerInfo--text-seller lztng-1vys5jr"><span> </span> <div class="lztng-1vys5jr"></div></div> <div id="lzt-market-logo"></div></div> <div class="bannerInfo--qrcode lztng-1vys5jr"><!> <span class="bannerInfo--actualDate lztng-1vys5jr"> </span></div></div></div></div>`,
      )),
      (Pt = O(
        `<div class="downloadButton--wrapper lztng-1vys5jr"><button aria-label="download banner" class="fl_r outfitsImageDownloadSvg downloadButton lztng-1vys5jr"></button></div> <div class="tooltip lztng-1vys5jr"><button class="lztng-1vys5jr">RU</button> <button class="lztng-1vys5jr">EN</button></div> <!>`,
        1,
      )),
      (Ft = {
        hash: `lztng-1vys5jr`,
        code: `.bannerInfo--text-seller.lztng-1vys5jr {display:flex;align-items:center;justify-content:start;}.bannerInfo--text-seller.lztng-1vys5jr div:where(.lztng-1vys5jr) {display:inline;position:relative;height:41px;width:100px;}.bannerInfo--text-seller.lztng-1vys5jr canvas {transform:scale(0.8) !important;position:absolute;top:-4px;left:-25%;}.banner.lztng-1vys5jr {position:fixed;
		/* top: 0px;
		left: 0px; */top:-9999px;right:-9999px;z-index:1000;width:730px;padding:20px;background:rgb(39, 39, 39);}.tooltip.lztng-1vys5jr {display:flex;align-items:center;gap:10px;}.tooltip.lztng-1vys5jr button:where(.lztng-1vys5jr) {color:var(--textCtrlBackground);transition:0.2s ease-in-out;}.tooltip.lztng-1vys5jr button:where(.lztng-1vys5jr):hover {cursor:pointer;color:var(--primaryMedium);}.downloadButton--wrapper.lztng-1vys5jr {display:inline;}.downloadButton.lztng-1vys5jr {margin:0;}.bannerList.lztng-1vys5jr {display:grid;grid-template-columns:repeat(5, 1fr);gap:20px;}.banner[data-type='weapons'].lztng-1vys5jr,
	.banner[data-type='buddies'].lztng-1vys5jr,
	.banner[data-type='agents'].lztng-1vys5jr {max-width:800px;}.banner[data-type='weapons'].lztng-1vys5jr .bannerList:where(.lztng-1vys5jr),
	.banner[data-type='buddies'].lztng-1vys5jr .bannerList:where(.lztng-1vys5jr),
	.banner[data-type='agents'].lztng-1vys5jr .bannerList:where(.lztng-1vys5jr) {grid-template-columns:repeat(3, 1fr);gap:5px;}.banner[data-type='agents'].lztng-1vys5jr .bannerList:where(.lztng-1vys5jr) .item {background:transparent !important;}.bannerInfo--goodsCount.lztng-1vys5jr {font-size:28px;margin-bottom:20px;}.bannerInfo--container.lztng-1vys5jr #lzt-market-logo {margin-top:40px;width:300px !important;padding-bottom:10px;}.bannerInfo--title.lztng-1vys5jr .marketIndexItem--helpfulIcons {display:inline-flex;align-items:center;}.bannerInfo--container.lztng-1vys5jr .uniqUsernameIcon--custom,
	.bannerInfo--container.lztng-1vys5jr .uniqUsernameIcon--custom > svg {width:20px;height:20px;}.bannerInfo--container.lztng-1vys5jr {margin-top:25px;display:flex;align-items:start;flex-direction:column;justify-content:space-between;font-weight:normal;font-size:32px;}.bannerInfo--description.lztng-1vys5jr {width:100%;margin-top:5px;display:flex;align-items:start;justify-content:space-between;}.bannerInfo--text.lztng-1vys5jr {display:flex;flex-direction:column;align-items:start;}.bannerInfo--qrcode.lztng-1vys5jr {display:flex;flex-direction:column;align-items:end;}.bannerInfo--actualDate.lztng-1vys5jr {margin-top:10px;font-size:14px;}button.lztng-1vys5jr {background-color:transparent;border:none;}button.lztng-1vys5jr:hover {cursor:pointer;}`,
      }),
      x([`click`]),
      y(
        Mt,
        {
          sellerNickname: {},
          marketTitle: {},
          price: {},
          list: {},
          bannerGoodsText: {},
          bannerType: {},
        },
        [],
        [],
        { mode: `open` },
      ));
  });
function Lt(e, t) {
  (H(t, !0), p(e, Ut));
  let n = Y(ae([])),
    r = Z(() => A(n).length),
    a = Y(!1),
    o = Y(``),
    l = Z(() => A(n).reduce((e, t) => e + t.price, 0)),
    u;
  async function d() {
    W(a, !0);
    let e = await Me(`/market/cart`, { scopes: [`basic`, `read`] });
    (W(n, e.items, !0), W(o, e.searchUrl, !0), W(a, !1));
  }
  async function m(e) {
    await Me(`/market/cart`, {
      method: `DELETE`,
      data: { item_id: e },
      scopes: [`basic`, `read`],
    });
    let t = document.querySelector(`.ToCartButton[data-item-id="${e}"]`);
    (t && t.classList.remove(`added`),
      W(
        n,
        A(n).filter((t) => t.item_id !== e),
        !0,
      ),
      u &&
        u.dispatchEvent(
          new CustomEvent(`CartUpdated`, { detail: { itemId: e } }),
        ));
  }
  async function _() {
    (W(a, !0),
      await Me(`/market/cart`, { method: `DELETE`, scopes: [`basic`, `read`] }),
      W(n, [], !0),
      document.querySelectorAll(`.ToCartButton.added`).forEach((e) => {
        e.classList.remove(`added`);
      }),
      u &&
        u.dispatchEvent(
          new CustomEvent(`CartUpdated`, { detail: { itemId: null } }),
        ),
      W(a, !1));
  }
  ie(() => {
    u &&
      u.addEventListener(`FetchCart`, () => {
        d();
      });
  });
  var y = Ht(),
    b = g(y),
    x = g(b),
    w = g(x);
  let E;
  var D = g(w),
    O = (e) => {
      var t = de();
      (X(
        (e) => q(t, e),
        [() => s(`market_items_in_cart_count`, { count: A(r) })],
      ),
        f(e, t));
    };
  (M(D, (e) => {
    A(a) || e(O);
  }),
    U(w));
  var k = J(w, 2),
    j = g(k),
    ee = z(j, !0);
  (U(k), U(x));
  var P = J(x, 2),
    F = (e) => {
      var t = Rt(),
        n = g(t);
      (Le(n, { variant: `logoMarket`, type: `medium` }), U(t), f(e, t));
    },
    I = (e) => {
      var t = Bt(),
        r = T(t),
        a = g(r);
      (xe(a, {
        mode: `vertical`,
        innerStyle: `max-height: 300px;`,
        scrollbarYStyle: `z-index: 2;`,
        children: (e, t) => {
          var r = v(),
            a = T(r);
          (C(
            a,
            17,
            () => A(n),
            N,
            (e, t) => {
              var n = zt(),
                r = g(n),
                a = J(r, 2),
                o = g(a),
                s = g(o),
                l = (e) => {
                  var n = de();
                  (X(() => q(n, A(t).title)), f(e, n));
                },
                u = (e) => {
                  var n = de();
                  (X(() => q(n, A(t).title_en)), f(e, n));
                };
              (M(s, (e) => {
                c.languageId === 2 ? e(l) : e(u, -1);
              }),
                U(o));
              var d = J(o, 2),
                p = g(d),
                h = J(p);
              (U(d), U(a));
              var _ = J(a, 2);
              (U(n),
                X(
                  (e) => {
                    var n, i, a;
                    (G(r, `href`, `/${(n = A(t).item_id) == null ? `` : n}`),
                      G(r, `aria-label`, A(t).title),
                      K(
                        o,
                        1,
                        `itemTitle categoryIcon ${(i = A(t).category.category_url) == null ? `` : i}`,
                        `lztng-x6d30r`,
                      ),
                      q(p, `${e == null ? `` : e} `),
                      K(
                        h,
                        1,
                        `svgIcon--${(a = c.currency) == null ? `` : a}`,
                        `lztng-x6d30r`,
                      ));
                  },
                  [() => i(A(t).price)],
                ),
                S(`click`, _, () => m(A(t).item_id)),
                f(e, n));
            },
          ),
            f(e, r));
        },
        $$slots: { default: !0 },
      }),
        U(r));
      var u = J(r, 2),
        d = g(u),
        p = g(d),
        h = g(p),
        _ = z(h, !0),
        y = J(h, 2),
        b = g(y),
        x = g(b),
        w = J(x);
      (U(b), U(y), U(p));
      var E = J(p, 2),
        D = z(E, !0);
      (U(d),
        U(u),
        X(
          (e, t, n) => {
            var r;
            (q(_, e),
              q(x, `${t == null ? `` : t} `),
              K(
                w,
                1,
                `svgIcon--${(r = c.currency) == null ? `` : r}`,
                `lztng-x6d30r`,
              ),
              G(E, `href`, A(o)),
              q(D, n));
          },
          [
            () => s(`market_cart_total_price`),
            () => i(A(l)),
            () => s(`market_cart_checkout`),
          ],
        ),
        f(e, t));
    },
    L = (e) => {
      var t = Vt(),
        n = z(t, !0);
      (X((e) => q(n, e), [() => s(`market_cart_empty`)]), f(e, t));
    };
  (M(P, (e) => {
    A(a) ? e(F) : A(n).length ? e(I, 1) : e(L, -1);
  }),
    U(b),
    U(y),
    h(
      y,
      (e) => (u = e),
      () => u,
    ),
    X(
      (e) => {
        ((E = K(w, 1, `title lztng-x6d30r`, null, E, { loading: A(a) })),
          q(ee, e));
      },
      [() => s(`market_cart_clear`)],
    ),
    S(`click`, j, () => _()),
    f(e, y),
    B());
}
var Rt,
  zt,
  Bt,
  Vt,
  Ht,
  Ut,
  Wt = e(() => {
    (F(),
      P(),
      je(),
      o(),
      Se(),
      Re(),
      L(),
      (Rt = O(`<div class="loading lztng-x6d30r"><!></div>`)),
      (zt = O(
        `<div class="item lztng-x6d30r"><a class="itemClicker IgnoreMenuHide lztng-x6d30r" target="_blank"></a> <div class="title lztng-x6d30r"><span><!></span> <div class="price lztng-x6d30r"> <span></span></div></div> <button class="deleteButton lztng-x6d30r"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none" class="lztng-x6d30r"><path opacity="0.12" d="M18.2987 16.5193L19 6H5L5.70129 16.5193C5.8065 18.0975 5.85911 18.8867 6.19998 19.485C6.50009 20.0118 6.95276 20.4353 7.49834 20.6997C8.11803 21 8.90891 21 10.4907 21H13.5093C15.0911 21 15.882 21 16.5017 20.6997C17.0472 20.4353 17.4999 20.0118 17.8 19.485C18.1409 18.8867 18.1935 18.0975 18.2987 16.5193Z" fill="CurrentColor" class="lztng-x6d30r"></path><path d="M9 3H15M3 6H21M19 6L18.2987 16.5193C18.1935 18.0975 18.1409 18.8867 17.8 19.485C17.4999 20.0118 17.0472 20.4353 16.5017 20.6997C15.882 21 15.0911 21 13.5093 21H10.4907C8.90891 21 8.11803 21 7.49834 20.6997C6.95276 20.4353 6.50009 20.0118 6.19998 19.485C5.85911 18.8867 5.8065 18.0975 5.70129 16.5193L5 6M10 10.5V15.5M14 10.5V15.5" stroke="CurrentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round" class="lztng-x6d30r"></path></svg></button></div>`,
      )),
      (Bt = O(
        `<div class="itemsList lztng-x6d30r"><!></div> <div class="footer lztng-x6d30r"><div class="infoBlock lztng-x6d30r"><div class="price-info lztng-x6d30r"><span class="description lztng-x6d30r"> </span> <span class="title lztng-x6d30r"><div class="price lztng-x6d30r"> <span></span></div></span></div> <a class="button primary toCart lztng-x6d30r"> </a></div></div>`,
        1,
      )),
      (Vt = O(`<div class="empty lztng-x6d30r"> </div>`)),
      (Ht = O(
        `<div class="cartPopupWrapper lztng-x6d30r"><div class="cartPopup lztng-x6d30r"><div class="header lztng-x6d30r"><span><!></span> <span class="clearCart lztng-x6d30r"><button class="clean lztng-x6d30r"> </button></span></div> <!></div></div>`,
      )),
      (Ut = {
        hash: `lztng-x6d30r`,
        code: `.itemCount.empty.lztng-x6d30r {display:none;}.header.lztng-x6d30r {font-size:15px;font-weight:bold;line-height:24px;padding:10px 20px;border-bottom:1px solid var(--primary);background-color:var(--primaryDarker);border-radius:10px 10px 0 0;display:flex;flex-direction:row;justify-content:space-between;align-items:center;}.cartPopup.lztng-x6d30r {background:var(--contentBackground);border-radius:12px;border:1px solid var(--primary);box-shadow:0 5px 26px 0 rgb(0 0 0 / 0.32);line-height:normal;}.loading.lztng-x6d30r {display:flex;justify-content:center;align-items:center;padding:4px;}.itemsList.lztng-x6d30r {display:flex;flex-direction:column;flex-wrap:wrap;padding:4px;width:calc(100% - 8px);}.empty.lztng-x6d30r {padding:20px;text-align:center;color:var(--mutedTextColor);}.item.lztng-x6d30r {display:flex;padding:12px 12px 12px 16px;gap:10px;cursor:pointer;justify-content:space-between;transition:all 0.2s ease-in-out;border-radius:10px;width:calc(100% - 28px);position:relative;}.itemClicker.lztng-x6d30r {position:absolute;top:0;left:0;width:100%;height:100%;z-index:1;text-decoration:none;}.item.lztng-x6d30r:hover {background-color:var(--primaryDarker);transition:all 0.2s ease-in-out;}.item.lztng-x6d30r:hover .itemTitle:where(.lztng-x6d30r) {color:var(--primaryMedium);transition:all 0.2s ease-in-out;}.item.lztng-x6d30r:active {opacity:0.72;transition:all 0.2s ease-in-out;}.itemTitle.lztng-x6d30r {line-height:20px;font-weight:bold;font-size:14px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;transition:all 0.2s ease-in-out;text-decoration:none;}.categoryIcon.lztng-x6d30r::before {width:20px;height:20px;background-size:20px 20px;}.price.lztng-x6d30r {line-height:20px;font-weight:bold;font-size:16px;}.title.lztng-x6d30r {display:flex;flex-direction:column;justify-content:space-between;gap:8px;white-space:nowrap;overflow:hidden;text-overflow:ellipsis;max-width:calc(100% - 40px);}.title.loading.lztng-x6d30r {position:relative;overflow:hidden;background:linear-gradient(90deg, #ffffff16 0%, #ffffff0d 100%);content:'';cursor:default;height:25px;width:75px;border-radius:8px;}.title.loading.lztng-x6d30r::after {content:'';position:absolute;top:0;width:150px;height:50px;background:linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.1), transparent);
		animation: lztng-x6d30r-skeleton-loading 1.5s infinite;z-index:2;}

	@keyframes lztng-x6d30r-skeleton-loading {
		0% {
			left: -150px;
		}
		50% {
			left: 100%;
		}
		100% {
			left: 100%;
		}
	}.clean.lztng-x6d30r {padding:6px;background:none;color:var(--textCtrlTextColor);border-radius:8px;transition:color 0.18s ease;border:none;cursor:pointer;z-index:2;}.clean.lztng-x6d30r:hover,
	.clean.lztng-x6d30r:focus-visible {color:var(--primaryMedium);}.deleteButton.lztng-x6d30r {padding:6px;background-color:var(--primaryDarker);border-radius:8px;transition:all 0.2s ease-in-out;height:fit-content;border:none;cursor:pointer;z-index:2;}.deleteButton.lztng-x6d30r:hover {background-color:var(--primary);transition:all 0.2s ease-in-out;}.deleteButton.lztng-x6d30r svg:where(.lztng-x6d30r) {width:20px;height:20px;display:flex;color:var(--mutedTextColor);transition:all 0.2s ease-in-out;}.deleteButton.lztng-x6d30r:hover svg:where(.lztng-x6d30r) {color:var(--contentText);transition:all 0.2s ease-in-out;}.footer.lztng-x6d30r {padding:10px 20px;border-top:1px solid var(--primary);background-color:var(--primaryDarker);border-radius:0 0 10px 10px;display:flex;flex-direction:column;gap:10px;}.infoBlock.lztng-x6d30r {display:flex;flex-direction:row;justify-content:space-between;align-items:center;}.price-info.lztng-x6d30r {display:flex;flex-direction:column;gap:4px;text-align:left;}.infoBlock.lztng-x6d30r .description:where(.lztng-x6d30r) {font-size:14px;color:var(--mutedTextColor);line-height:20px;}.infoBlock.lztng-x6d30r .title:where(.lztng-x6d30r),
	.infoBlock.lztng-x6d30r .price:where(.lztng-x6d30r) {font-size:15px;font-weight:bold;line-height:24px;}

	@media (max-width: 520px) {.cartPopup.lztng-x6d30r {width:100%;}.footer.lztng-x6d30r {flex-direction:column;gap:10px;}.price-info.lztng-x6d30r {text-align:left;align-items:flex-start;}
	}`,
      }),
      x([`click`]),
      y(Lt, {}, [], [], { mode: `open` }));
  });
function Gt(e, t) {
  (H(t, !0), p(e, Zt));
  let n = Y(void 0),
    r = Y(!0),
    a = Y(`RUB`),
    o = Y(`USD`),
    l = Y(``),
    u = Z(() =>
      A(n)
        ? Object.entries(A(n).currencyList).map(([e, t]) => ({
            key: e,
            label: `${t.title} (${e})`,
            selectedLabel: e,
            value: e,
          }))
        : [],
    ),
    m = Z(() => (A(n) ? Object.entries(A(n).currencyList) : [])),
    h = Z(() => {
      var e, t;
      if (!A(n) || !A(l)) return ``;
      let r = parseFloat(A(l).replace(`,`, `.`));
      if (isNaN(r) || r <= 0) return ``;
      let s = (e = A(n).currencyList[A(a)]) == null ? void 0 : e.rate,
        c = (t = A(n).currencyList[A(o)]) == null ? void 0 : t.rate;
      if (!s || !c) return ``;
      let u = (r * s) / c;
      if (!Number.isFinite(u)) return ``;
      let d = y(u);
      return i(u.toFixed(d), d);
    }),
    _ = Z(() => {
      var e, t;
      if (!A(n)) return ``;
      let r = (e = A(n).currencyList[A(a)]) == null ? void 0 : e.rate,
        s = (t = A(n).currencyList[A(o)]) == null ? void 0 : t.rate;
      if (!r || !s) return ``;
      let c = r / s;
      if (!Number.isFinite(c)) return ``;
      let l = y(c);
      return i(c.toFixed(l), l);
    });
  function y(e) {
    let t = Math.abs(e);
    return t >= 100 ? 2 : t >= 1 ? 4 : t >= 0.01 ? 6 : 8;
  }
  ie(b);
  async function b() {
    (W(r, !0),
      W(
        n,
        await Me(`/currency`, { scopes: [`basic`, `read`], target: `market` }),
        !0,
      ),
      A(n).visitorCurrency &&
        A(n).visitorCurrency in A(n).currencyList &&
        W(o, A(n).visitorCurrency === `RUB` ? `USD` : A(n).visitorCurrency, !0),
      W(r, !1));
  }
  function x(e) {
    return new Intl.DateTimeFormat(c.languageCode, {
      dateStyle: `long`,
      timeStyle: `short`,
      timeZone: c.timezone,
    }).format(new Date(e * 1e3));
  }
  function E() {
    ((e) => {
      var t = fe(e, 2);
      (W(a, t[0], !0), W(o, t[1], !0));
    })([A(o), A(a)]);
  }
  function D(e) {
    let t = e.currentTarget,
      n = t.value
        .replace(/,/g, `.`)
        .replace(/[^\d.]/g, ``)
        .replace(/(\..*)\./g, `$1`),
      [r, i] = n.split(`.`);
    ((n = r.slice(0, 15)),
      i !== void 0 && (n += `.${i.slice(0, 8)}`),
      (t.value = n),
      W(l, n, !0));
  }
  var O = v(),
    k = T(O),
    j = (e) => {
      var t = qt(),
        n = J(g(t), 4);
      (C(
        n,
        16,
        () => ({ length: 8 }),
        N,
        (e, t) => {
          var n = Kt();
          f(e, n);
        },
      ),
        U(t),
        f(e, t));
    },
    ee = (e) => {
      var t = Xt(),
        r = g(t),
        i = g(r),
        c = g(i),
        p = g(c),
        y = z(p, !0),
        b = J(p, 2),
        O = g(b);
      Ce(O, {
        get options() {
          return A(u);
        },
        class: `calc-currency-select`,
        searchable: !0,
        portal: !0,
        get value() {
          return A(a);
        },
        set value(e) {
          W(a, e, !0);
        },
      });
      var k = J(O, 2);
      (oe(k), U(b), U(c));
      var j = J(c, 2),
        ee = z(j),
        P = J(j, 2),
        F = g(P),
        I = z(F, !0),
        L = J(F, 2),
        te = g(L);
      Ce(te, {
        get options() {
          return A(u);
        },
        class: `calc-currency-select`,
        searchable: !0,
        portal: !0,
        get value() {
          return A(o);
        },
        set value(e) {
          W(o, e, !0);
        },
      });
      var ne = J(te, 2);
      (oe(ne), U(L), U(P), U(i));
      var re = J(i, 2),
        R = g(re),
        ie = g(R),
        B = z(ie),
        V = J(ie, 2),
        ae = (e) => {
          var t = Jt();
          (d(
            t,
            (e, t) => (Pe == null ? void 0 : Pe(e, t)),
            () => ({ content: x(A(n).lastUpdate), placementStrategy: `fixed` }),
          ),
            f(e, t));
        };
      (M(V, (e) => {
        A(n).lastUpdate && e(ae);
      }),
        U(R));
      var H = J(R, 2),
        G = z(H, !0);
      (U(re), U(r));
      var se = J(r, 2),
        ce = g(se),
        ue = z(ce, !0),
        Y = J(ce, 2),
        de = z(Y, !0),
        pe = J(Y, 2),
        me = z(pe, !0);
      U(se);
      var he = J(se, 2);
      (xe(he, {
        mode: `vertical`,
        style: `height: auto;`,
        innerStyle: `max-height: min(380px, calc(100dvh - 28rem - 15px - env(safe-area-inset-bottom, 0px)));`,
        children: (e, t) => {
          var r = v(),
            i = T(r);
          (C(
            i,
            17,
            () => A(m),
            N,
            (e, t) => {
              var r = Z(() => fe(A(t), 2));
              let i = () => A(r)[0],
                a = () => A(r)[1];
              var o = Yt();
              let s;
              var c = g(o),
                l = g(c),
                u = z(l, !0);
              U(c);
              var d = J(c, 2),
                p = z(d, !0),
                m = J(d, 2),
                h = z(m, !0);
              (U(o),
                X(() => {
                  ((s = K(o, 1, `currency-row lztng-1p6slds`, null, s, {
                    highlighted: i() === A(n).visitorCurrency,
                  })),
                    q(u, i()),
                    q(p, a().title),
                    q(h, a().formattedRate));
                }),
                f(e, o));
            },
          ),
            f(e, r));
        },
        $$slots: { default: !0 },
      }),
        U(t),
        X(
          (e, t, n, r, i, s) => {
            var c, u, d;
            (q(y, e),
              le(k, A(l)),
              q(I, t),
              le(ne, A(h) || `0`),
              q(
                B,
                `1 ${(c = A(a)) == null ? `` : c} = ${(u = A(_)) == null ? `` : u} ${(d = A(o)) == null ? `` : d}`,
              ),
              q(G, n),
              q(ue, r),
              q(de, i),
              q(me, s));
          },
          [
            () => s(`market_currency_from`),
            () => s(`market_currency_to`),
            () => s(`market_currency_actual_rate`),
            () => s(`market_currency_code`),
            () => s(`market_currency_name`),
            () => s(`market_currency_rate`),
          ],
        ),
        S(`input`, k, D),
        S(`click`, ee, E),
        w(`focus`, ne, (e) => e.currentTarget.select()),
        f(e, t));
    };
  (M(k, (e) => {
    A(r) ? e(j) : A(n) && e(ee, 1);
  }),
    f(e, O),
    B());
}
var Kt,
  qt,
  Jt,
  Yt,
  Xt,
  Zt,
  Qt = e(() => {
    (F(),
      P(),
      o(),
      L(),
      je(),
      we(),
      Se(),
      Ne(),
      (Kt = O(
        `<div class="currency-row skeleton-row lztng-1p6slds"><div class="currencyCodeBlock lztng-1p6slds"><div class="skeleton code-sk lztng-1p6slds"></div></div> <div class="skeleton title-sk lztng-1p6slds"></div> <div class="skeleton rate-sk lztng-1p6slds"></div></div>`,
      )),
      (qt = O(
        `<div class="currency-list lztng-1p6slds"><div class="section calc-section lztng-1p6slds"><div class="calc-fields lztng-1p6slds"><div class="calc-row lztng-1p6slds"><div class="skeleton label-sk lztng-1p6slds"></div> <div class="skeleton controls-sk lztng-1p6slds"></div></div> <div class="swap-wrap lztng-1p6slds"><div class="skeleton swap-sk lztng-1p6slds"></div></div> <div class="calc-row lztng-1p6slds"><div class="skeleton label-sk lztng-1p6slds"></div> <div class="skeleton controls-sk lztng-1p6slds"></div></div></div> <div class="rate-block lztng-1p6slds"><div class="skeleton rate-line-sk lztng-1p6slds"></div> <div class="skeleton rate-meta-sk lztng-1p6slds"></div></div></div> <div class="section list-header lztng-1p6slds"><div class="skeleton th-sk lztng-1p6slds"></div> <div class="skeleton th-sk wide lztng-1p6slds"></div> <div class="skeleton th-sk th-rate lztng-1p6slds"></div></div> <!></div>`,
      )),
      (Jt = O(`<i class="far fa-info-circle rate-info lztng-1p6slds"></i>`)),
      (Yt = O(
        `<div><div class="currencyCodeBlock lztng-1p6slds"><span class="currency-code lztng-1p6slds"> </span></div> <span class="currency-title lztng-1p6slds"> </span> <span class="currency-rate lztng-1p6slds"> </span></div>`,
      )),
      (Xt = O(
        `<div class="currency-list lztng-1p6slds"><div class="section calc-section lztng-1p6slds"><div class="calc-fields lztng-1p6slds"><div class="calc-row lztng-1p6slds"><span class="label lztng-1p6slds"> </span> <div class="calc-controls lztng-1p6slds"><!> <input class="calc-amount lztng-1p6slds" type="text" inputmode="decimal" placeholder="0"/></div></div> <div class="swap-wrap lztng-1p6slds"><button class="swap-btn lztng-1p6slds"><svg xmlns="http://www.w3.org/2000/svg" width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" class="lztng-1p6slds"><path d="M7 16V4m0 0L3 8m4-4l4 4" class="lztng-1p6slds"></path><path d="M17 8v12m0 0l4-4m-4 4l-4-4" class="lztng-1p6slds"></path></svg></button></div> <div class="calc-row lztng-1p6slds"><span class="label lztng-1p6slds"> </span> <div class="calc-controls lztng-1p6slds"><!> <input class="calc-amount lztng-1p6slds" type="text" readonly="" tabindex="0"/></div></div></div> <div class="rate-block lztng-1p6slds"><div class="rate-top lztng-1p6slds"><span class="rate-value lztng-1p6slds"> </span> <!></div> <div class="rate-meta lztng-1p6slds"> </div></div></div> <div class="section list-header lztng-1p6slds"><span class="col col-code lztng-1p6slds"> </span> <span class="col col-title lztng-1p6slds"> </span> <span class="col col-rate lztng-1p6slds"> </span></div> <!></div>`,
      )),
      (Zt = {
        hash: `lztng-1p6slds`,
        code: `.currency-list.lztng-1p6slds {background:var(--contentBackground);border-radius:10px;min-width:420px;overflow:hidden;}.section.lztng-1p6slds {padding:16px 20px;border-top:1px solid var(--primaryDark);}.section.lztng-1p6slds:first-child {border-top:none;}

	/* ── Calculator ── */.calc-section.lztng-1p6slds {display:flex;flex-direction:column;gap:15px;margin:0;}.calc-fields.lztng-1p6slds {display:flex;flex-direction:row;align-items:stretch;gap:10px;}.calc-fields.lztng-1p6slds > .calc-row:where(.lztng-1p6slds) {flex:1;min-width:0;}.swap-wrap.lztng-1p6slds {display:flex;align-items:center;flex-shrink:0;}.label.lztng-1p6slds {font-weight:700;line-height:18px;color:var(--mutedTextColor);}.calc-row.lztng-1p6slds {display:flex;flex-direction:column;gap:8px;padding:10px 14px 10px 10px;background:var(--primaryDarker);border-radius:12px;}.calc-controls.lztng-1p6slds {display:flex;align-items:stretch;gap:0;box-sizing:border-box;border:1px solid #2e3b38;border-radius:10px;overflow:hidden;background:var(--contentBackground);box-shadow:none;}.calc-row.lztng-1p6slds .select-container.calc-currency-select {flex:0 0 92px;box-sizing:border-box;width:92px;min-width:92px;max-width:92px;min-height:44px;background:#181e1c;border-radius:0;border-right:1px solid #2e3b38;box-shadow:none;}.calc-row.lztng-1p6slds .select-container.calc-currency-select .select-trigger {padding:0 28px 0 15px;min-height:44px;line-height:44px;}.calc-row.lztng-1p6slds .select-container.calc-currency-select .select-value,
	.calc-row.lztng-1p6slds .select-container.calc-currency-select .select-search-input {width:100%;min-width:0;max-width:100%;margin-right:0;font-weight:600;}.calc-row.lztng-1p6slds .select-container.calc-currency-select .select-search-input {flex:none;height:44px;line-height:44px;}.calc-amount.lztng-1p6slds {flex:1;min-width:0;height:44px;padding:0 10px;border:none;outline:none;box-shadow:none;border-radius:0;background:transparent;color:var(--textColor);font-family:inherit;font-size:20px;font-weight:600;line-height:44px;text-align:right;}.calc-amount.lztng-1p6slds::placeholder {color:var(--mutedTextColor);}.calc-amount[readonly].lztng-1p6slds {cursor:text;}.swap-btn.lztng-1p6slds {flex-shrink:0;display:flex;align-items:center;justify-content:center;width:36px;height:36px;border:none;border-radius:50%;background:var(--primaryDark);color:var(--mutedTextColor);cursor:pointer;transition:background 0.15s ease,
			color 0.15s ease;}.swap-btn.lztng-1p6slds svg:where(.lztng-1p6slds) {transform:rotate(90deg);}.swap-btn.lztng-1p6slds:hover {background:var(--primaryDarker);color:var(--textColor);}.rate-block.lztng-1p6slds {padding:12px 14px;background:var(--primaryDarker);border-radius:12px;}.rate-top.lztng-1p6slds {display:flex;align-items:center;justify-content:space-between;gap:8px;}.rate-value.lztng-1p6slds {font-size:15px;font-weight:600;line-height:20px;color:var(--textColor);}.rate-info.lztng-1p6slds {flex-shrink:0;font-size:16px;color:var(--mutedTextColor);}.rate-meta.lztng-1p6slds {margin-top:4px;font-size:14px;line-height:16px;color:var(--mutedTextColor);}.list-header.lztng-1p6slds {display:flex;gap:8px;padding:8px 20px;margin:0;background-color:var(--primaryDark);}.col.lztng-1p6slds {font-size:14px;font-weight:700;line-height:16px;color:var(--mutedTextColor);text-transform:uppercase;letter-spacing:0.4px;}.col-code.lztng-1p6slds {width:52px;flex-shrink:0;}.col-title.lztng-1p6slds {flex:1;}.col-rate.lztng-1p6slds {width:100px;flex-shrink:0;text-align:right;}.currency-row.lztng-1p6slds {display:flex;align-items:center;gap:8px;padding:10px 20px;transition:background 0.15s ease;}.currency-row.lztng-1p6slds:not(:last-child) {border-bottom:1px solid var(--primaryDark);}.currency-row.lztng-1p6slds:hover {background:var(--primaryDarker);}.currency-row.highlighted.lztng-1p6slds {background:rgba(34, 142, 93, 0.08);}.currency-row.highlighted.lztng-1p6slds:hover {background:rgba(34, 142, 93, 0.14);}.currencyCodeBlock.lztng-1p6slds {min-width:60px;}.currency-code.lztng-1p6slds {flex-shrink:0;font-weight:700;font-size:14px;line-height:20px;padding:2px 6px;background:var(--primaryDark);border-radius:5px;text-align:center;letter-spacing:0.3px;}.currency-title.lztng-1p6slds {flex:1;font-size:14px;line-height:20px;color:var(--textCtrlTextColor);white-space:nowrap;overflow:hidden;text-overflow:ellipsis;}.currency-rate.lztng-1p6slds {width:100px;flex-shrink:0;text-align:right;font-size:14px;font-weight:600;line-height:20px;text-wrap-mode:nowrap;display:flex;justify-content:flex-end;}.skeleton.lztng-1p6slds {position:relative;overflow:hidden;background:linear-gradient(90deg, #ffffff16 0%, #ffffff0d 100%);border-radius:4px;}.skeleton.lztng-1p6slds::after {content:'';position:absolute;top:0;left:-150px;width:150px;height:100%;background:linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.1), transparent);
		animation: lztng-1p6slds-skeleton-loading 1.5s infinite;}.label-sk.lztng-1p6slds {width:72px;height:18px;}.controls-sk.lztng-1p6slds {width:100%;height:44px;border-radius:10px;}.swap-sk.lztng-1p6slds {flex-shrink:0;width:36px;height:36px;border-radius:50%;}.rate-line-sk.lztng-1p6slds {width:58%;height:20px;}.rate-meta-sk.lztng-1p6slds {width:72%;height:16px;margin-top:4px;}.th-sk.lztng-1p6slds {height:16px;border-radius:3px;width:52px;}.th-sk.wide.lztng-1p6slds {flex:1;}.th-sk.th-rate.lztng-1p6slds {width:100px;}.skeleton-row.lztng-1p6slds {padding:10px 20px;display:flex;align-items:center;gap:8px;background:none;}.code-sk.lztng-1p6slds {width:52px;height:22px;flex-shrink:0;border-radius:5px;}.title-sk.lztng-1p6slds {flex:1;height:20px;}.rate-sk.lztng-1p6slds {width:100px;height:20px;flex-shrink:0;}

	@keyframes lztng-1p6slds-skeleton-loading {
		0% {
			left: -150px;
		}
		50% {
			left: 100%;
		}
		100% {
			left: 100%;
		}
	}

	@media (max-width: 610px) {.Responsive .xenOverlay.currencyListOverlay .sectionMain {border-radius:10px;}.Responsive .xenOverlay.currencyListOverlay .section {border-radius:0;}
	}

	@media (max-width: 520px) {.currency-list.lztng-1p6slds {min-width:unset;}.calc-fields.lztng-1p6slds {flex-direction:column;gap:0;}.swap-wrap.lztng-1p6slds {width:100%;gap:10px;padding:8px 0;}.swap-wrap.lztng-1p6slds::before,
		.swap-wrap.lztng-1p6slds::after {content:'';flex:1;border-top:1px solid var(--primary);}.swap-btn.lztng-1p6slds svg:where(.lztng-1p6slds) {transform:none;}
	}`,
      }),
      x([`input`, `click`]),
      y(Gt, {}, [], [], { mode: `open` }));
  });
function $t(e, t) {
  (H(t, !0), p(e, fn));
  let n = V(t, `itemId`, 7),
    r = V(
      t,
      `titleSelector`,
      7,
      `.marketItemView--titleStyle .EditableValue[data-key="title"]`,
    ),
    i = Y(`idle`),
    a = Y(``),
    o = Y(!1);
  async function c() {
    if (A(i) !== `loading`) {
      W(i, `loading`);
      try {
        let e = await Me(`/market/${n()}/ai-title`, {
          method: `POST`,
          scopes: [`basic`],
          ignoreError: !0,
        });
        if (l.hasResponseError(e)) {
          W(i, `idle`);
          return;
        }
        let t =
          (e == null ? void 0 : e.title) ||
          (e == null ? void 0 : e._message) ||
          ``;
        if (!t) {
          W(i, `idle`);
          return;
        }
        (W(a, t, !0), W(i, `preview`));
      } catch (e) {
        W(i, `idle`);
      }
    }
  }
  async function m() {
    if (!A(o)) {
      W(o, !0);
      try {
        let e = await Me(`/market/${n()}/edit`, {
            method: `PUT`,
            scopes: [`basic`],
            data: { key: `title`, value: A(a) },
            ignoreError: !0,
          }),
          t = e && (e.status === `ok` || (!e.error && !e.errors));
        if (!t) {
          l.hasResponseError(e);
          return;
        }
        let o = A(a),
          s = document.querySelector(r());
        if (s) {
          s.textContent = o;
          let e = window.jQuery || window.$;
          e && e(s).data(`value`, o);
        }
        (e != null &&
          e.message &&
          typeof l.alert == `function` &&
          l.alert(e.message, ``, 4e3, null, `success`),
          W(i, `idle`),
          W(a, ``));
      } catch (e) {
      } finally {
        W(o, !1);
      }
    }
  }
  function h() {
    (W(i, `idle`), W(a, ``));
  }
  function _(e) {
    A(i) === `preview` &&
      (e.key === `Enter`
        ? (e.preventDefault(), m())
        : e.key === `Escape` && (e.preventDefault(), h()));
  }
  var v = {
      get itemId() {
        return n();
      },
      set itemId(e) {
        (n(e), E());
      },
      get titleSelector() {
        return r();
      },
      set titleSelector(
        e = `.marketItemView--titleStyle .EditableValue[data-key="title"]`,
      ) {
        (r(e), E());
      },
    },
    y = dn();
  w(`keydown`, u, _);
  var b = g(y),
    x = (e) => {
      var t = ln(),
        n = g(t),
        r = (e) => {
          tn(e);
        },
        a = (e) => {
          en(e);
        };
      (M(n, (e) => {
        A(i) === `loading` ? e(r) : e(a, -1);
      }),
        U(t),
        d(
          t,
          (e, t) => (Pe == null ? void 0 : Pe(e, t)),
          () => ({ content: s(`market_change_title_with_use_ai`) }),
        ),
        X(() => (t.disabled = A(i) === `loading`)),
        S(`click`, t, c),
        f(e, t));
    },
    C = (e) => {
      var t = un(),
        n = g(t),
        r = z(n, !0),
        i = J(n, 2),
        c = g(i),
        l = g(c),
        u = (e) => {
          tn(e);
        },
        p = (e) => {
          nn(e);
        };
      (M(l, (e) => {
        A(o) ? e(u) : e(p, -1);
      }),
        U(c),
        d(
          c,
          (e, t) => (Pe == null ? void 0 : Pe(e, t)),
          () => ({
            content: `${s(`apply`)}<div class="aiTitleButton--shortcut">Enter</div>`,
            html: !0,
          }),
        ));
      var _ = J(c, 2),
        v = g(_);
      (rn(v),
        U(_),
        d(
          _,
          (e, t) => (Pe == null ? void 0 : Pe(e, t)),
          () => ({
            content: `${s(`cancel`)}<div class="aiTitleButton--shortcut">Esc</div>`,
            html: !0,
          }),
        ),
        U(i),
        U(t),
        X(() => {
          (q(r, A(a)), (c.disabled = A(o)), (_.disabled = A(o)));
        }),
        S(`click`, c, m),
        S(`click`, _, h),
        f(e, t));
    };
  return (
    M(b, (e) => {
      A(i) === `preview` ? e(C, -1) : e(x);
    }),
    U(y),
    X(() => G(y, `data-item-id`, n())),
    f(e, y),
    B(v)
  );
}
var en,
  tn,
  nn,
  rn,
  an,
  on,
  sn,
  cn,
  ln,
  un,
  dn,
  fn,
  pn = e(() => {
    (F(),
      P(),
      je(),
      Ne(),
      a(),
      o(),
      (en = (e) => {
        var t = an();
        f(e, t);
      }),
      (tn = (e) => {
        var t = on();
        f(e, t);
      }),
      (nn = (e) => {
        var t = sn();
        f(e, t);
      }),
      (rn = (e) => {
        var t = cn();
        f(e, t);
      }),
      (an = k(
        `<svg class="aiTitleButton--icon aiIcon lztng-1q0sljm" xmlns="http://www.w3.org/2000/svg" width="12" height="12" viewBox="0 0 12 12" fill="none"><path d="M1.92567 10H0L2.93416 2H5.24995L8.17997 10H6.25429L4.12526 3.82812H4.05886L1.92567 10ZM1.80532 6.85547H6.3539V8.17578H1.80532V6.85547Z" fill="#00BA78"></path><path d="M11 2V10H9.20298V2H11Z" fill="#00BA78"></path></svg>`,
      )),
      (on = k(
        `<svg class="aiTitleButton--icon aiTitleButton--spin lztng-1q0sljm" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2" stroke-linecap="round" aria-hidden="true"><path d="M21 12a9 9 0 1 1-6.219-8.56" opacity="1"></path></svg>`,
      )),
      (sn = k(
        `<svg class="aiTitleButton--icon lztng-1q0sljm" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M20 6L9 17l-5-5"></path></svg>`,
      )),
      (cn = k(
        `<svg class="aiTitleButton--icon lztng-1q0sljm" viewBox="0 0 24 24" width="16" height="16" fill="none" stroke="currentColor" stroke-width="2.5" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true"><path d="M18 6L6 18"></path><path d="M6 6l12 12"></path></svg>`,
      )),
      (ln = O(
        `<button type="button" class="aiTitleButton--trigger lztng-1q0sljm"><!></button>`,
      )),
      (un = O(
        `<div class="aiTitleButton--preview lztng-1q0sljm"><span class="aiTitleButton--previewText lztng-1q0sljm"> </span> <div class="aiTitleButton--buttonGroup lztng-1q0sljm"><button type="button" class="aiTitleButton--apply lztng-1q0sljm"><!></button> <button type="button" class="aiTitleButton--cancel lztng-1q0sljm"><!></button></div></div>`,
      )),
      (dn = O(`<span class="aiTitleButton lztng-1q0sljm"><!></span>`)),
      (fn = {
        hash: `lztng-1q0sljm`,
        code: `.aiTitleButton.lztng-1q0sljm {display:inline-flex;align-items:center;gap:4px;vertical-align:middle;font-size:14px;.aiTitleButton--trigger:where(.lztng-1q0sljm),
		.aiTitleButton--apply:where(.lztng-1q0sljm),
		.aiTitleButton--cancel:where(.lztng-1q0sljm) {display:inline-flex;align-items:center;justify-content:center;width:26px;height:26px;padding:0;border:1px solid #d6d6d632;border-radius:6px;background:#d6d6d624;cursor:pointer;transition:all 0.1s ease-in-out;flex-shrink:0;&:hover:not(:disabled) {background:var(--xf-paletteAccent1, rgba(255, 255, 255, 0.08));}&:disabled {opacity:0.6;cursor:progress;}}.aiTitleButton--trigger:where(.lztng-1q0sljm) {color:#00ba78;margin-left:4px;&:hover:not(:disabled) {color:#00ba78;border-color:#00ba78;background-color:#00ba7856;}

			@media (max-width: 480px) {margin-left:0;margin-top:8px;
			}}.aiTitleButton--apply:where(.lztng-1q0sljm) {color:#00ba78;&:hover:not(:disabled) {background-color:#00ba7832;border-color:#00ba78;}}.aiTitleButton--cancel:where(.lztng-1q0sljm) {color:#ef5350;&:hover:not(:disabled) {border-color:#ef5350;background-color:#ef535032;}}.aiTitleButton--preview:where(.lztng-1q0sljm) {display:inline-flex;align-items:center;gap:12px;padding:8px 12px;border:1px solid var(--primaryDark);border-radius:10px;background:var(--primaryDarker);margin:8px 0;.aiTitleButton--previewText:where(.lztng-1q0sljm) {line-height:20px;}.aiTitleButton--buttonGroup:where(.lztng-1q0sljm) {display:flex;gap:8px;}}.aiTitleButton--icon:where(.lztng-1q0sljm) {display:block;width:16px;height:16px;&.aiTitleButton--spin {
				animation: lztng-1q0sljm-aiTitleButtonSpin 0.9s linear infinite;}}}.AiTitleButton {display:inline-flex;vertical-align:middle;}.aiTitleButton--shortcut {display:inline-block;margin-left:6px;padding:2px 6px;border-radius:4px;background:#ffffff20;font-size:12px;line-height:16px;vertical-align:middle;}
	@keyframes lztng-1q0sljm-aiTitleButtonSpin {
		from {
			transform: rotate(0deg);
		}
		to {
			transform: rotate(360deg);
		}
	}`,
      }),
      x([`click`]),
      y($t, { itemId: {}, titleSelector: {} }, [], [], { mode: `open` }));
  });
function mn(e, t) {
  (H(t, !1), p(e, gn), ee());
  var n = v(),
    r = T(n),
    i = (e) => {
      var t = hn(),
        n = z(t, !0);
      (X(() => q(n, Ee.count)), f(e, t));
    };
  (M(r, (e) => {
    Ee.count > 0 && e(i);
  }),
    f(e, n),
    B());
}
var hn,
  gn,
  _n = e(() => {
    (F(),
      te(),
      P(),
      ke(),
      (hn = O(
        `<span class="notificationCount filterNotificationCount lztng-il0iqr"> </span>`,
      )),
      (gn = {
        hash: `lztng-il0iqr`,
        code: `.filterNotificationCount.lztng-il0iqr {display:inline-flex;align-items:center;justify-content:center;box-sizing:border-box;min-width:20px;height:20px;padding:0 5px;border-radius:99px;font-size:11px;font-weight:700;line-height:18px;color:#fff;background:var(--primaryLight);}`,
      }),
      y(mn, {}, [], [], { mode: `open` }));
  });
function vn(e, t) {
  H(t, !1);
  let n = `data:image/svg+xml;base64,PHN2ZyB3aWR0aD0iMTQiIGhlaWdodD0iMTQiIHZpZXdCb3g9IjAgMCAxNCAxNCIgZmlsbD0ibm9uZSIgeG1sbnM9Imh0dHA6Ly93d3cudzMub3JnLzIwMDAvc3ZnIj4KPHBhdGggZmlsbC1ydWxlPSJldmVub2RkIiBjbGlwLXJ1bGU9ImV2ZW5vZGQiIGQ9Ik0wLjI5Mjg5MyAzLjI5Mjg5QzAuNjgzNDE3IDIuOTAyMzcgMS4zMTY1OCAyLjkwMjM3IDEuNzA3MTEgMy4yOTI4OUw3IDguNTg1NzlMMTIuMjkyOSAzLjI5Mjg5QzEyLjY4MzQgMi45MDIzNyAxMy4zMTY2IDIuOTAyMzcgMTMuNzA3MSAzLjI5Mjg5QzE0LjA5NzYgMy42ODM0MiAxNC4wOTc2IDQuMzE2NTggMTMuNzA3MSA0LjcwNzExTDcuNzA3MTEgMTAuNzA3MUM3LjMxNjU4IDExLjA5NzYgNi42ODM0MiAxMS4wOTc2IDYuMjkyODkgMTAuNzA3MUwwLjI5Mjg5MyA0LjcwNzExQy0wLjA5NzYzMTEgNC4zMTY1OCAtMC4wOTc2MzExIDMuNjgzNDIgMC4yOTI4OTMgMy4yOTI4OVoiIGZpbGw9IiM5NDk0OTQiLz4KPC9zdmc+Cg==`;
  (Te(), ee());
  var r = yn(),
    i = T(r),
    a = g(i),
    o = J(a);
  mn(o, {});
  var c = J(o, 2);
  (G(c, `src`, n), U(i));
  var l = J(i, 2),
    u = g(l),
    d = J(u);
  (G(d, `src`, n),
    U(l),
    X(
      (e, t, n, r) => {
        (q(a, `${e == null ? `` : e} `),
          G(c, `alt`, t),
          q(u, `${n == null ? `` : n} `),
          G(d, `alt`, r));
      },
      [
        () => s(`market_all_parameters`),
        () => s(`market_click_to_expand_all_search_options`),
        () => s(`market_collapse`),
        () => s(`hide`),
      ],
    ),
    f(e, r),
    B());
}
var yn,
  bn = e(() => {
    (F(),
      te(),
      P(),
      o(),
      ke(),
      _n(),
      (yn = O(
        `<span class="expand"> <!> <img class="fa-filter-chevron-down"/></span> <span class="hide hidden"> <img class="fa-filter-chevron-down ch_transform"/></span>`,
        1,
      )),
      y(vn, {}, [], [], { mode: `open` }));
  });
function xn(e, t) {
  (H(t, !0), p(e, Cn));
  let n = Y(!1);
  Te();
  let r = () =>
      document.querySelector(`#CategorySearchBar .ExpandParams`) ||
      document.querySelector(`.ExpandParams`),
    i = () =>
      typeof Q.isMobileFiltersViewport == `function` &&
      Q.isMobileFiltersViewport(),
    a = () =>
      Q.FiltersOverlay &&
      typeof Q.FiltersOverlay.isOpen == `function` &&
      Q.FiltersOverlay.isOpen(),
    o = (e) => e.getClientRects().length > 0;
  function c() {
    let e = r();
    if (!i() || a() || !e || !o(e)) {
      W(n, !1);
      return;
    }
    let t = e.getBoundingClientRect(),
      s = window.innerHeight || document.documentElement.clientHeight;
    W(n, t.bottom < 0 || t.top > s, !0);
  }
  function l() {
    let e = r();
    e instanceof HTMLElement && e.click();
  }
  ie(
    () => (
      window.addEventListener(`scroll`, c, { passive: !0 }),
      window.addEventListener(`resize`, c),
      c(),
      () => {
        (window.removeEventListener(`scroll`, c),
          window.removeEventListener(`resize`, c));
      }
    ),
  );
  var u = v(),
    d = T(u),
    m = (e) => {
      var t = Sn(),
        n = g(t),
        r = g(n),
        i = z(r, !0),
        a = J(r, 2);
      (mn(a, {}),
        U(n),
        U(t),
        X((e) => q(i, e), [() => s(`market_all_parameters`)]),
        S(`click`, n, l),
        S(`keydown`, n, (e) => (e.key === `Enter` || e.key === ` `) && l()),
        pe(
          3,
          t,
          () => ue,
          () => ({ axis: `x`, duration: 220, easing: b }),
        ),
        f(e, t));
    };
  (M(d, (e) => {
    A(n) && e(m);
  }),
    f(e, u),
    B());
}
var Sn,
  Cn,
  wn = e(() => {
    (F(),
      P(),
      L(),
      I(),
      ne(),
      De(),
      o(),
      ke(),
      _n(),
      (Sn = O(
        `<span class="MarketExpandParams--stickySlot lztng-hc4y5s"><span class="MarketExpandParams--sticky lztng-hc4y5s" role="button" tabindex="0"><span class="MarketExpandParams--sticky--text"> </span> <!></span></span>`,
      )),
      (Cn = {
        hash: `lztng-hc4y5s`,
        code: `.MarketExpandParams--stickySlot.lztng-hc4y5s {display:flex;flex:0 0 auto;}.MarketExpandParams--sticky.lztng-hc4y5s {display:inline-flex;align-items:center;flex:0 0 auto;gap:12px;box-sizing:border-box;padding:10px 18px;border-radius:24px;color:#fff;background:var(--contentBackground, #15171a);border:1px solid var(--primaryDark);box-shadow:0 4px 18px rgba(0, 0, 0, 0.35);cursor:pointer;font-size:14px;line-height:1;user-select:none;white-space:nowrap;}`,
      }),
      x([`click`, `keydown`]),
      y(xn, {}, [], [], { mode: `open` }));
  });
function Tn(e, t) {
  (H(t, !0), p(e, jn));
  let r = Y(!1),
    i = Y(!1),
    a = Y(0),
    o = Y(0),
    s = Y(0),
    c = Y(!1),
    l = Y(!1),
    u = Y(!1),
    h = Y(!1),
    _ = Y(``),
    v = Y(!1),
    [y, x] = ye({
      strategy: `fixed`,
      placement: `bottom-end`,
      middleware: [_e(8), he(), ve({ padding: 8 })],
    }),
    C = Y(``),
    E = Y(``),
    O = Y(``),
    k = () => document.querySelector(`.searchBarContainer`),
    N = () => document.getElementById(`header`),
    ee = () => document.querySelector(`#MarketSearchBar .SaveSearch`),
    P = () => document.querySelector(`.SaveSearchMenu`),
    F = () =>
      document.querySelector(`.SaveSearchMenu .SaveSearchNotifyCheckbox`);
  function I() {
    var e;
    let t = ee();
    (W(c, !!t && !t.classList.contains(`hidden`), !0),
      W(l, !!t && t.classList.contains(`Saved`), !0),
      W(
        C,
        (t == null || (e = t.querySelector(`.text`)) == null
          ? void 0
          : e.textContent.trim()) ||
          (t == null ? void 0 : t.textContent.trim()) ||
          ``,
        !0,
      ));
    let n = P(),
      r = F(),
      i = parseInt(
        (r == null ? void 0 : r.getAttribute(`data-search-id`)) || `0`,
        10,
      );
    if (
      (W(u, !!n && !n.classList.contains(`hidden`) && !!r && i > 0, !0),
      W(h, !!r && r.checked, !0),
      n)
    ) {
      var a;
      W(
        _,
        ((a = n.textContent) == null
          ? void 0
          : a.replace(/\s+/g, ` `).trim()) || A(_),
        !0,
      );
    }
  }
  function L() {
    var e, t;
    let n = k();
    if (!n) {
      (W(r, !1), W(i, !1));
      return;
    }
    W(r, !0);
    let c = n.getBoundingClientRect();
    (W(
      a,
      Math.max(
        0,
        (e = (t = N()) == null ? void 0 : t.getBoundingClientRect().bottom) ==
          null
          ? 0
          : e,
      ),
      !0,
    ),
      W(o, c.left, !0),
      W(s, c.width, !0),
      W(i, c.bottom <= A(a)),
      A(i) && I());
  }
  function te() {
    var e, t;
    let r = k();
    r &&
      n(`html,body`).animate(
        {
          scrollTop:
            n(r).offset().top -
            ((e = (t = N()) == null ? void 0 : t.offsetHeight) == null
              ? 0
              : e) -
            10,
        },
        200,
      );
  }
  function ne() {
    var e;
    (e = ee()) == null || e.click();
  }
  function re() {
    let e = F();
    !e || e.disabled || (e.click(), W(h, e.checked, !0));
  }
  let R = null;
  function V() {
    A(u) && (R && (clearTimeout(R), (R = null)), W(v, !0));
  }
  function ae() {
    (R && clearTimeout(R),
      (R = setTimeout(() => {
        (W(v, !1), (R = null));
      }, 150)));
  }
  me(() => {
    (!A(i) || !A(u)) && W(v, !1);
  });
  function se(e) {
    (W(E, e.title, !0), W(O, e.count, !0), I());
  }
  let le = !1;
  function ue() {
    le ||
      ((le = !0),
      requestAnimationFrame(() => {
        (L(), (le = !1));
      }));
  }
  ie(() => {
    var e, t, r, i;
    return (
      W(
        E,
        (e =
          (t = document.querySelector(`.marketIndex--titleContainer h1`)) ==
          null
            ? void 0
            : t.innerHTML.trim()) == null
          ? ``
          : e,
        !0,
      ),
      W(
        O,
        (r =
          (i = document.getElementById(`SubmitSearchButton`)) == null
            ? void 0
            : i.textContent.trim()) == null
          ? ``
          : r,
        !0,
      ),
      window.addEventListener(`scroll`, ue, { passive: !0 }),
      window.addEventListener(`resize`, ue),
      n(document).on(`market:pageUrlUpdated.stickyTop`, I),
      n(document).on(`market:searchSaved.stickyTop`, I),
      L(),
      I(),
      () => {
        (window.removeEventListener(`scroll`, ue),
          window.removeEventListener(`resize`, ue),
          n(document).off(`market:pageUrlUpdated.stickyTop`),
          n(document).off(`market:searchSaved.stickyTop`),
          R && clearTimeout(R));
      }
    );
  });
  var de = { updateSearch: se },
    fe = An(),
    Z = T(fe),
    ge = (e) => {
      var t = On();
      let n;
      var r = g(t),
        u = g(r),
        p = J(g(u), 2);
      (j(p, () => A(E), !0), U(p), U(u));
      var m = J(u, 2),
        h = (e) => {
          var t = En(),
            n = z(t, !0);
          (X(() => q(n, A(O))), f(e, t));
        };
      (M(m, (e) => {
        A(O) && e(h);
      }),
        U(r));
      var _ = J(r, 2),
        b = (e) => {
          var t = Dn();
          let n;
          var r = J(g(t), 2),
            i = z(r, !0);
          (U(t),
            d(t, (e) => (y == null ? void 0 : y(e))),
            X(() => {
              ((n = K(t, 1, `MarketStickyTop--save lztng-12iogik`, null, n, {
                "is-saved": A(l),
                "is-open": A(v),
              })),
                q(i, A(C)));
            }),
            S(`click`, t, ne),
            w(`mouseenter`, t, V),
            w(`mouseleave`, t, ae),
            w(`focus`, t, V),
            w(`blur`, t, ae),
            f(e, t));
        };
      (M(_, (e) => {
        A(c) && e(b);
      }),
        U(t),
        X(() => {
          var e, r, c;
          ((n = K(t, 1, `MarketStickyTop lztng-12iogik`, null, n, {
            "is-visible": A(i),
          })),
            G(t, `aria-hidden`, !A(i)),
            ce(
              t,
              `top: ${(e = A(a)) == null ? `` : e}px; left: ${(r = A(o)) == null ? `` : r}px; width: ${(c = A(s)) == null ? `` : c}px;`,
            ));
        }),
        S(`click`, u, te),
        f(e, t));
    };
  M(Z, (e) => {
    A(r) && e(ge);
  });
  var be = J(Z, 2),
    xe = (e) => {
      var t = kn(),
        n = g(t),
        r = g(n);
      oe(r);
      var i = J(r, 2),
        a = z(i, !0);
      (U(n),
        U(t),
        d(t, (e) => (x == null ? void 0 : x(e))),
        X(() => q(a, A(_))),
        w(`mouseenter`, t, V),
        w(`mouseleave`, t, ae),
        S(`change`, r, re),
        m(
          r,
          () => A(h),
          (e) => W(h, e),
        ),
        pe(
          3,
          t,
          () => D,
          () => ({ y: -8, duration: 160, easing: b }),
        ),
        f(e, t));
    };
  return (
    M(be, (e) => {
      A(u) && A(v) && A(i) && e(xe);
    }),
    f(e, fe),
    B(de)
  );
}
var En,
  Dn,
  On,
  kn,
  An,
  jn,
  Mn = e(() => {
    (F(),
      P(),
      L(),
      ne(),
      I(),
      t(),
      be(),
      ge(),
      (En = O(`<span class="MarketStickyTop--count lztng-12iogik"> </span>`)),
      (Dn = O(
        `<button type="button"><svg width="24" height="24" viewBox="0 0 24 24" fill="none" xmlns="http://www.w3.org/2000/svg" class="lztng-12iogik"><path opacity="0.12" d="M5 7.8C5 6.11984 5 5.27976 5.32698 4.63803C5.6146 4.07354 6.07354 3.6146 6.63803 3.32698C7.27976 3 8.11984 3 9.8 3H14.2C15.8802 3 16.7202 3 17.362 3.32698C17.9265 3.6146 18.3854 4.07354 18.673 4.63803C19 5.27976 19 6.11984 19 7.8V21L12 17L5 21V7.8Z" fill="#8C8C8C"></path><path d="M5 7.8C5 6.11984 5 5.27976 5.32698 4.63803C5.6146 4.07354 6.07354 3.6146 6.63803 3.32698C7.27976 3 8.11984 3 9.8 3H14.2C15.8802 3 16.7202 3 17.362 3.32698C17.9265 3.6146 18.3854 4.07354 18.673 4.63803C19 5.27976 19 6.11984 19 7.8V21L12 17L5 21V7.8Z" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path></svg> <span> </span></button>`,
      )),
      (On = O(
        `<div><div class="MarketStickyInfo lztng-12iogik"><button type="button" class="MarketStickyTop--nav lztng-12iogik"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" fill="none" viewBox="0 0 24 24" class="lztng-12iogik"><path fill="currentColor" d="M13 21V6.828l4.586 4.586L19 10l-7-7-7 7 1.414 1.414L11 6.828V21z"></path></svg> <span class="MarketStickyTop--name lztng-12iogik"></span></button> <!></div> <!></div>`,
      )),
      (kn = O(
        `<div class="MarketStickyTop--popup lztng-12iogik"><label class="MarketStickyTop--popupOption lztng-12iogik"><input type="checkbox" class="lztng-12iogik"/> <span class="lztng-12iogik"> </span></label></div>`,
      )),
      (An = O(`<!> <!>`, 1)),
      (jn = {
        hash: `lztng-12iogik`,
        code: `.MarketStickyTop.lztng-12iogik {position:fixed;z-index:99;display:flex;align-items:center;justify-content:space-between;gap:12px;box-sizing:border-box;padding:10px 18px;border-radius:0 0 24px 24px;color:#fff;background:color-mix(in srgb, var(--contentBackground) 85%, transparent);backdrop-filter:blur(10px);box-shadow:0 4px 12px rgba(0, 0, 0, 0.35);opacity:0;visibility:hidden;pointer-events:none;transform:translateY(-16px);transition:opacity 0.2s cubic-bezier(0.33, 1, 0.68, 1),
			transform 0.2s cubic-bezier(0.33, 1, 0.68, 1),
			visibility 0s linear 0.2s;&.is-visible {opacity:1;visibility:visible;pointer-events:auto;transform:none;transition-delay:0s;}}

	@media (max-width: 800px) {.MarketStickyTop.lztng-12iogik {display:none;}
	}.MarketStickyInfo.lztng-12iogik {display:flex;align-items:center;gap:16px;max-width:75%;}.MarketStickyTop--nav.lztng-12iogik,
	.MarketStickyTop--save.lztng-12iogik {display:inline-flex;align-items:center;gap:4px;margin:0;padding:0;border:0;background:none;color:inherit;font:inherit;line-height:1;cursor:pointer;}.MarketStickyTop--nav.lztng-12iogik {min-width:0;
		/* высота строки не зависит от наличия кнопки «Сохранить» (30px) — иначе
		   измеренная до показа высота разойдётся с реальной */min-height:30px;transition:color 0.2s ease;&:hover {color:var(--primaryMedium);}svg:where(.lztng-12iogik) {width:24px;height:24px;fill:currentColor;flex-shrink:0;}}.MarketStickyTop--name.lztng-12iogik {overflow:hidden;padding-right:1px;font-size:13px;line-height:20px;font-weight:600;white-space:nowrap;text-overflow:ellipsis;span {color:inherit !important;}.svgCurIcon::before {font-size:11px;}}.MarketStickyTop--count.lztng-12iogik {flex:0 0 auto;color:var(--mutedTextColor, #8b9199);font-size:14px;}.MarketStickyTop--save.lztng-12iogik {flex:0 0 auto;padding:6px 10px;border-radius:8px;font-size:13px;font-weight:600;white-space:nowrap;transition:background 0.15s ease,
			color 0.15s ease;&:hover,
		&.is-open {background:rgba(255, 255, 255, 0.06);color:var(--primaryMedium);}svg:where(.lztng-12iogik) {flex-shrink:0;width:18px;height:18px;stroke:currentColor;transition:fill 0.15s ease,
				stroke 0.15s ease;}&.is-saved {color:var(--primaryMedium);}}.MarketStickyTop--popup.lztng-12iogik {position:fixed;z-index:100;display:flex;flex-direction:column;gap:6px;min-width:220px;padding:8px;border-radius:12px;color:#fff;background:rgb(28, 28, 28, 0.95);backdrop-filter:blur(10px);box-shadow:0 8px 24px rgba(0, 0, 0, 0.45);}.MarketStickyTop--popupOption.lztng-12iogik {display:flex;align-items:center;gap:10px;padding:8px 10px;border-radius:8px;cursor:pointer;font-size:13px;font-weight:500;line-height:1.4;user-select:none;transition:background 0.15s ease;&:hover {background:rgba(255, 255, 255, 0.06);}input:where(.lztng-12iogik) {flex:0 0 auto;width:16px;height:16px;margin:0;accent-color:var(--primaryMedium);cursor:pointer;}span:where(.lztng-12iogik) {flex:1 1 auto;}}`,
      }),
      x([`click`, `change`]),
      y(Tn, {}, [], [`updateSearch`], { mode: `open` }));
  });
function Nn(e, t) {
  (H(t, !0), p(e, In));
  let n = V(t, `containerSelector`, 7),
    r = V(t, `totalCount`, 7, 0),
    i = V(t, `paidCount`, 7, 0),
    a = V(t, `freeCount`, 7, 0),
    o = Y(`all`),
    c = null,
    l = Y(void 0),
    u = ``;
  function d() {
    return (
      c ||
      (A(l) && (c = A(l).closest(n())),
      c || (c = document.querySelector(n())),
      c)
    );
  }
  function m() {
    var e, t;
    return (e =
      (t = d()) == null ? void 0 : t.querySelector(`.scroll-content`)) == null
      ? null
      : e;
  }
  function y() {
    if (u) return;
    let e = m();
    if (!e) return;
    let t = getComputedStyle(e).maxHeight;
    t && t !== `none` && (u = t);
  }
  function b() {
    let e = d();
    if (e)
      try {
        let t = e.querySelector(`.MarketScrollBar`);
        if (!t) return;
        let n = window.jQuery || window.$;
        if (!n) return;
        let r = n(t),
          i = r.data(`scrollbar`);
        i && typeof i.update == `function` ? i.update() : r.trigger(`update`);
      } catch (e) {}
  }
  function x() {
    let e = m();
    !e ||
      !u ||
      ((e.style.height || e.style.maxHeight === `none`) &&
        ((e.style.height = ``), (e.style.maxHeight = u)));
  }
  function C(e) {
    let t = d();
    if (!t) return;
    let n = t.querySelectorAll(`li.item`);
    n.forEach((t) => {
      let n = t,
        r = n.getAttribute(`is-paid`);
      e === `all`
        ? (n.style.display = ``)
        : e === `paid`
          ? (n.style.display = r === `1` ? `` : `none`)
          : e === `free` && (n.style.display = r === `0` ? `` : `none`);
    });
  }
  function w(e) {
    let t = d();
    if (!t) {
      W(o, e, !0);
      return;
    }
    (y(), W(o, e, !0), C(e), b(), x());
  }
  function D() {
    if (!A(l)) return;
    let e = A(l).querySelector(`ul.tabs`),
      t = e == null ? void 0 : e.querySelector(`li.active`);
    if (!e || !t) return;
    let n = e.getBoundingClientRect(),
      r = t.getBoundingClientRect(),
      i = getComputedStyle(e),
      a = getComputedStyle(t),
      o =
        r.left -
        n.left -
        parseFloat(i.borderLeftWidth || `0`) -
        parseFloat(a.marginLeft || `0`) +
        e.scrollLeft,
      s =
        r.top -
        n.top -
        parseFloat(i.borderTopWidth || `0`) -
        parseFloat(a.marginTop || `0`);
    (e.style.setProperty(`--tab-left`, `${o}px`),
      e.style.setProperty(`--tab-top`, `${s}px`),
      e.style.setProperty(`--tab-width`, `${t.offsetWidth}px`),
      e.style.setProperty(`--tab-height`, `${t.offsetHeight}px`));
  }
  (me(() => {
    (A(o), requestAnimationFrame(D));
  }),
    ie(() => {
      requestAnimationFrame(() => {
        (d(), y(), D());
      });
      let e = () => D();
      return (
        window.addEventListener(`resize`, e),
        () => window.removeEventListener(`resize`, e)
      );
    }));
  var O = {
      get containerSelector() {
        return n();
      },
      set containerSelector(e) {
        (n(e), E());
      },
      get totalCount() {
        return r();
      },
      set totalCount(e = 0) {
        (r(e), E());
      },
      get paidCount() {
        return i();
      },
      set paidCount(e = 0) {
        (i(e), E());
      },
      get freeCount() {
        return a();
      },
      set freeCount(e = 0) {
        (a(e), E());
      },
    },
    k = v(),
    j = T(k),
    N = (e) => {
      var t = Fn(),
        n = g(t),
        c = g(n),
        u = g(c),
        d = g(u),
        p = J(d),
        m = z(p, !0);
      (U(u), U(c));
      var v = J(c, 2),
        y = (e) => {
          var t = Pn(),
            n = g(t),
            r = g(n),
            a = J(r),
            c = z(a, !0);
          (U(n),
            U(t),
            X(
              (e) => {
                (K(t, 1, _(A(o) === `paid` ? `active` : ``), `lztng-t6kosq`),
                  K(n, 1, _(A(o) === `paid` ? `active` : ``)),
                  q(r, `${e == null ? `` : e} `),
                  q(c, i()));
              },
              [() => s(`market_paid_games`)],
            ),
            S(`click`, t, (e) => {
              (e.preventDefault(), w(`paid`));
            }),
            S(`click`, n, (e) => e.preventDefault()),
            f(e, t));
        };
      M(v, (e) => {
        i() > 0 && e(y);
      });
      var b = J(v, 2),
        x = (e) => {
          var t = Pn(),
            n = g(t),
            r = g(n),
            i = J(r),
            c = z(i, !0);
          (U(n),
            U(t),
            X(
              (e) => {
                (K(t, 1, _(A(o) === `free` ? `active` : ``), `lztng-t6kosq`),
                  K(n, 1, _(A(o) === `free` ? `active` : ``)),
                  q(r, `${e == null ? `` : e} `),
                  q(c, a()));
              },
              [() => s(`market_free_games`)],
            ),
            S(`click`, t, (e) => {
              (e.preventDefault(), w(`free`));
            }),
            S(`click`, n, (e) => e.preventDefault()),
            f(e, t));
        };
      (M(b, (e) => {
        a() > 0 && e(x);
      }),
        U(n),
        U(t),
        h(
          t,
          (e) => W(l, e),
          () => A(l),
        ),
        X(
          (e) => {
            (K(c, 1, _(A(o) === `all` ? `active` : ``), `lztng-t6kosq`),
              K(u, 1, _(A(o) === `all` ? `active` : ``)),
              q(d, `${e == null ? `` : e} `),
              q(m, r()));
          },
          [() => s(`market_all_games`)],
        ),
        S(`click`, c, (e) => {
          (e.preventDefault(), w(`all`));
        }),
        S(`click`, u, (e) => e.preventDefault()),
        f(e, t));
    };
  return (
    M(j, (e) => {
      (i() > 0 || a() > 0) && e(N);
    }),
    f(e, k),
    B(O)
  );
}
var Pn,
  Fn,
  In,
  Ln = e(() => {
    (F(),
      P(),
      o(),
      L(),
      (Pn = O(`<li><a href="#"> <span class="muted"> </span></a></li>`)),
      (Fn = O(
        `<div class="steamGamesFilter lztng-t6kosq"><ul class="tabs mainTabs Tabs lztng-t6kosq"><li><a href="#"> <span class="muted"> </span></a></li> <!> <!></ul></div>`,
      )),
      (In = {
        hash: `lztng-t6kosq`,
        code: `.steamGamesFilter.lztng-t6kosq {margin-bottom:12px;}.steamGamesFilter.lztng-t6kosq .tabs:where(.lztng-t6kosq) li:where(.lztng-t6kosq) {cursor:pointer;}`,
      }),
      x([`click`]),
      y(
        Nn,
        { containerSelector: {}, totalCount: {}, paidCount: {}, freeCount: {} },
        [],
        [],
        { mode: `open` },
      ));
  });
function Rn(e, t) {
  (H(t, !0), p(e, Wn));
  let n = V(t, `groups`, 7),
    r = V(t, `onApply`, 7),
    i = Y(ae([])),
    a = Z(() => A(i).length);
  function o(e) {
    return A(i).indexOf(e);
  }
  function c(e) {
    let t = A(i).indexOf(e);
    t === -1
      ? W(i, [...A(i), e], !0)
      : W(
          i,
          A(i).filter((t) => t !== e),
          !0,
        );
  }
  function l() {
    A(a) && r()([...A(i)]);
  }
  var u = {
      get groups() {
        return n();
      },
      set groups(e) {
        (n(e), E());
      },
      get onApply() {
        return r();
      },
      set onApply(e) {
        (r(e), E());
      },
    },
    d = Un(),
    m = g(d);
  xe(m, {
    mode: `vertical`,
    children: (e, t) => {
      var r = v(),
        i = T(r);
      (C(i, 17, n, N, (e, t, n) => {
        var r = v(),
          i = T(r),
          a = (e) => {
            var r = Hn(),
              i = T(r),
              a = (e) => {
                var t = zn();
                f(e, t);
              };
            M(i, (e) => {
              n > 0 && e(a);
            });
            var s = J(i, 2),
              l = (e) => {
                var n = Bn(),
                  r = z(n, !0);
                (X(() => q(r, A(t).title)), f(e, n));
              };
            M(s, (e) => {
              A(t).title && e(l);
            });
            var u = J(s, 2);
            (C(
              u,
              17,
              () => A(t).items,
              (e) => e.value,
              (e, t) => {
                let n = Z(() => o(A(t).value));
                var r = Vn(),
                  i = g(r);
                oe(i);
                var a = J(i, 2),
                  s = z(a, !0),
                  l = J(a, 2),
                  u = z(l, !0);
                (U(r),
                  X(() => {
                    (se(i, A(n) !== -1),
                      q(s, A(t).label),
                      q(u, A(n) === -1 ? `` : A(n) + 1));
                  }),
                  S(`click`, r, () => c(A(t).value)),
                  S(`click`, i, (e) => e.stopPropagation()),
                  S(`change`, i, () => c(A(t).value)),
                  f(e, r));
              },
            ),
              f(e, r));
          };
        (M(i, (e) => {
          A(t).items.length && e(a);
        }),
          f(e, r));
      }),
        f(e, r));
    },
    $$slots: { default: !0 },
  });
  var h = J(m, 2),
    _ = g(h),
    y = z(_, !0),
    b = J(_, 2),
    x = z(b, !0);
  return (
    U(h),
    U(d),
    X(
      (e, t) => {
        (q(y, e), (b.disabled = A(a) === 0), q(x, t));
      },
      [
        () =>
          A(a)
            ? s(`market_deferred_mod_selected_count`, { count: A(a) })
            : s(`market_deferred_mod_nothing_selected`),
        () =>
          A(a)
            ? `${s(`market_deferred_mod_execute`)} (${A(a)})`
            : s(`market_deferred_mod_execute`),
      ],
    ),
    S(`mousedown`, d, (e) => e.preventDefault()),
    S(`click`, b, l),
    f(e, d),
    B(u)
  );
}
var zn,
  Bn,
  Vn,
  Hn,
  Un,
  Wn,
  Gn = e(() => {
    (F(),
      P(),
      o(),
      Se(),
      (zn = O(`<div class="account-menu-sep"></div>`)),
      (Bn = O(`<label class="menuGroupTitle lztng-1e74msx"> </label>`)),
      (Vn = O(
        `<div class="deferredModRow lztng-1e74msx"><input type="checkbox" class="deferredModCheck lztng-1e74msx"/> <label class="menuItemLabel lztng-1e74msx"> </label> <span class="deferredModOrder lztng-1e74msx"> </span></div>`,
      )),
      (Hn = O(`<!> <!> <!>`, 1)),
      (Un = O(
        `<div class="deferredMod lztng-1e74msx"><!> <div class="deferredModFooter lztng-1e74msx"><span class="deferredModCount lztng-1e74msx"> </span> <button type="button" class="button smallButton primary deferredModApply lztng-1e74msx"> </button></div></div>`,
      )),
      (Wn = {
        hash: `lztng-1e74msx`,
        code: `.menuGroupTitle.lztng-1e74msx {display:block;margin:0;padding:10px 13px 6px !important;font-size:12px;font-weight:600;color:var(--mutedTextColor);text-transform:none;cursor:default;pointer-events:none;background:none !important;}.deferredModRow.lztng-1e74msx {display:flex;align-items:center;gap:11px;margin:0 15px 0 5px;padding:0 10px;cursor:pointer;}.deferredModRow.lztng-1e74msx:hover {background:var(--primaryDarker);border-radius:10px;}.deferredModRow.lztng-1e74msx:last-child {margin-bottom:5px;}.deferredModCheck.lztng-1e74msx {width:14px;height:14px;flex-shrink:0;cursor:pointer;margin:0;}.menuItemLabel.lztng-1e74msx {flex:1;cursor:pointer;margin:0;padding-left:0 !important;font-weight:normal;color:var(--contentText);}.deferredModOrder.lztng-1e74msx {font-size:11px;opacity:0.55;min-width:14px;}.deferredModFooter.lztng-1e74msx {display:flex;align-items:center;justify-content:space-between;gap:10px;padding:8px 12px;border-top:1px solid var(--primary);background:var(--contentBackground);}.deferredModCount.lztng-1e74msx {color:var(--mutedTextColor);}.deferredModApply.lztng-1e74msx {flex-shrink:0;}.deferredMod.lztng-1e74msx .scrollable-x {display:none;}`,
      }),
      x([`mousedown`, `click`, `change`]),
      y(Rn, { groups: {}, onApply: {} }, [], [], { mode: `open` }));
  });
function Kn(e, t) {
  (H(t, !0), p(e, Yn));
  let n = V(t, `heading`, 7),
    r = V(t, `groups`, 7),
    i = V(t, `onApply`, 7);
  var a = {
    get heading() {
      return n();
    },
    set heading(e) {
      (n(e), E());
    },
    get groups() {
      return r();
    },
    set groups(e) {
      (r(e), E());
    },
    get onApply() {
      return i();
    },
    set onApply(e) {
      (i(e), E());
    },
  };
  {
    let t = (e) => {
        var t = qn(),
          r = J(g(t), 2),
          i = z(r, !0);
        (R(2), U(t), X(() => q(i, n())), f(e, t));
      },
      a = (e) => {
        var t = Jn(),
          n = g(t);
        (Rn(n, {
          get groups() {
            return r();
          },
          get onApply() {
            return i();
          },
        }),
          U(t),
          f(e, t));
      };
    ze(e, {
      offset: 10,
      showOnHover: !0,
      trigger: t,
      content: a,
      $$slots: { trigger: !0, content: !0 },
    });
  }
  return B(a);
}
var qn,
  Jn,
  Yn,
  Xn = e(() => {
    (F(),
      P(),
      Be(),
      Gn(),
      (qn = O(
        `<span class="button btn-with-icon-text deferredModTrigger lztng-1g3zj8m"><span class="btn-icon"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none"><path d="M16 10H3M20 6H3M20 14H3M16 18H3" stroke="currentColor" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path></svg></span> <span class="deferredModTriggerText"> </span> <span class="arrowWidget"></span></span>`,
      )),
      (Jn = O(
        `<div class="secondaryContent blockLinksList deferredModContent lztng-1g3zj8m"><!></div>`,
      )),
      (Yn = {
        hash: `lztng-1g3zj8m`,
        code: `.deferredModTrigger.lztng-1g3zj8m {display:inline-flex;align-items:center;gap:6px;}.Popup .PopupControl:not(.dottesStyle) .arrowWidget,
	.Popup .NoPopupGadget .arrowWidget {color:#8ca29a;margin-left:6px;display:inline-flex;transition:0.2s;vertical-align:middle;align-items:center;}.Popup .PopupControl:not(.dottesStyle) .arrowWidget::before,
	.Popup .NoPopupGadget .arrowWidget::before {font-size:20px;font-family:'Font Awesome 5 Pro';font-weight:400;content:'\\f107';}.Popup .PopupControl .arrowWidget::before {transition:all 0.2s ease-in-out;}.Popup .PopupControl.PopupOpen .arrowWidget::before {transform:rotate(180deg);}.deferredModContent.lztng-1g3zj8m {padding:0;overflow:hidden;}.MenuOpened .deferredModContent.lztng-1g3zj8m {
		animation: lztng-1g3zj8m-deferredModIn 100ms linear forwards;}.Menu:not(.MenuOpened) .deferredModContent.lztng-1g3zj8m {
		animation: lztng-1g3zj8m-deferredModOut 100ms linear forwards;}

	@keyframes lztng-1g3zj8m-deferredModIn {
		from {
			opacity: 0;
			visibility: hidden;
			transform: translateY(-4px);
		}
		to {
			opacity: 1;
			visibility: visible;
			transform: translateY(0);
		}
	}

	@keyframes lztng-1g3zj8m-deferredModOut {
		from {
			opacity: 1;
			visibility: visible;
			transform: translateY(0);
		}
		to {
			opacity: 0;
			visibility: hidden;
			transform: translateY(-4px);
		}
	}.deferredModContent.lztng-1g3zj8m .scrollable-content {max-height:320px;}

	@media (max-width: 520px) {.deferredModContent.lztng-1g3zj8m .scrollable-content {max-height:80vh;}
	}`,
      }),
      y(Kn, { heading: {}, groups: {}, onApply: {} }, [], [], {
        mode: `open`,
      }));
  }),
  Zn = e(() => {
    (L(),
      It(),
      a(),
      De(),
      Wt(),
      t(),
      Ve(),
      Qt(),
      pn(),
      bn(),
      wn(),
      Mn(),
      Ln(),
      Xn(),
      o(),
      Ue(),
      Oe(),
      Fe(),
      r(),
      (Q.DownloadGoodsBanner = function (e) {
        this.__construct(e);
      }),
      (Q.DownloadGoodsBanner.prototype = {
        __construct: function (e) {
          ((this.$button = e),
            this.$button.ready(n.context(this, `DownloadGoodsBannerInit`)));
        },
        DownloadGoodsBannerInit: function () {
          var e, t;
          let r = this.$button[0].parentNode,
            i = this.$button[0].href.split(`=`)[1],
            a = n(`.price.currentPrice .value`).attr(`data-value`),
            o = n(`.h1Style.marketItemView--titleStyle span`).text(),
            s =
              (e = n(`.username.fl_l`)[0]) == null
                ? n(`.sellerUsernameBlock .username`)[0]
                : e,
            c = n(r).text().split(`·`)[0] || n(r).parent().text().split(`·`)[0],
            l =
              (t = n(`ul[data-key*=${i.slice(0, -2)} i]`)[0]) == null
                ? n(`ul[data-save-url].body`)[0]
                : t;
          if (!s || !l) {
            this.$button.remove();
            return;
          }
          if (i === `games`) {
            let e = l.cloneNode(!0);
            (n(e)
              .find(`img`)
              .map(function () {
                this.src = `https://api.codetabs.com/v1/proxy/?quest=${this.src}`;
              }),
              (l = e),
              (n(
                `.marketItemView--gamesContainer .title`,
              )[0].style.flexDirection = `row`));
          }
          (re(Mt, {
            target: r,
            props: {
              list: l,
              price: a,
              marketTitle: o,
              sellerNickname: s,
              bannerGoodsText: c,
              bannerType: i,
            },
          }),
            this.$button.remove());
        },
      }),
      l.register(
        `html.DEBUG a.outfitsImageDownloadSvg`,
        `Market.DownloadGoodsBanner`,
      ),
      (Q.CartPopup = function (e) {
        re(Lt, { target: e[0] });
        let t = e.find(`.cartPopupWrapper`);
        n(document).on(`PopupMenuShow`, (e) => {
          e.$menu.is(`#CartPopup`) &&
            t[0].dispatchEvent(new CustomEvent(`FetchCart`));
        });
        let r = n(`#MarketCart_Counter`);
        t.on(`CartUpdated`, function (e) {
          let t = parseInt(r.text()) || 0;
          (t--, l.balloonCounterUpdate(r, e.detail.itemId === null ? 0 : t));
        });
      }),
      l.register(`.CartPopupContent`, `Market.CartPopup`),
      (Q.CurrencyList = function (e) {
        e.off(`click`).on(`click`, function (e) {
          (e.preventDefault(),
            He(
              Gt,
              s(`market_currency_list_title`),
              {},
              !1,
              `currencyListOverlay`,
            ));
        });
      }),
      l.register(`a.CurrencyList`, `Market.CurrencyList`),
      (Q.AiTitleButton = function (e) {
        let t = e[0];
        if (!t || t.getAttribute(`data-svelte-mounted`) === `1`) return;
        let n = parseInt(t.getAttribute(`data-item-id`) || `0`, 10);
        n && Ie(t, $t, { itemId: n });
      }),
      l.register(`.AiTitleButton`, `Market.AiTitleButton`),
      (Q.SteamGamesFilter = function (e) {
        let t = e[0];
        if (!t || t.getAttribute(`data-svelte-mounted`) === `1`) return;
        let n =
            t.getAttribute(`data-container`) ||
            `.marketItemView--gamesContainer`,
          r = parseInt(t.getAttribute(`data-total`) || `0`, 10),
          i = parseInt(t.getAttribute(`data-paid`) || `0`, 10),
          a = parseInt(t.getAttribute(`data-free`) || `0`, 10);
        Ie(t, Nn, {
          containerSelector: n,
          totalCount: r,
          paidCount: i,
          freeCount: a,
        });
      }),
      l.register(`.SteamGamesFilter`, `Market.SteamGamesFilter`),
      (Q.ExpandParamsSvelte = function (e) {
        let t = e[0];
        if (!t || t.getAttribute(`data-svelte-expand`) === `1`) return;
        t.setAttribute(`data-svelte-expand`, `1`);
        let n = t.querySelector(`.hide:not(.hidden)`) !== null;
        ((t.innerHTML = ``),
          re(vn, { target: t }),
          n &&
            (e.find(`.expand`).addClass(`hidden`),
            e.find(`.hide`).removeClass(`hidden`)),
          We(`market-expand-params`, xn));
      }),
      l.register(`.ExpandParams`, `Market.ExpandParamsSvelte`),
      (Q.StickyTopBar = function () {
        if (Q.StickyTopBarComponent) return;
        let e = document.createElement(`div`);
        (document.body.appendChild(e),
          (Q.StickyTopBarComponent = re(Tn, { target: e })));
      }),
      l.register(`#MarketSearchBar`, `Market.StickyTopBar`),
      (Q.DeferredMod = function (e) {
        let t = e[0];
        if (
          !t ||
          t.getAttribute(`data-svelte-mounted`) === `1` ||
          !t.dataset.groups
        )
          return;
        let n;
        try {
          n = JSON.parse(t.dataset.groups);
        } catch (e) {
          return;
        }
        if (!Array.isArray(n) || !n.some((e) => e.items.length > 0)) return;
        let r = t.querySelector(`.deferredModHeading`),
          i = r ? r.textContent.trim() : t.dataset.heading || ``;
        ((t.innerHTML = ``),
          Ie(
            t,
            Kn,
            {
              heading: i,
              groups: n,
              onApply: (e) => Ae(document.getElementById(`MarketSearchBar`), e),
            },
            { revealClass: `hidden`, unmountOnRemove: !0 },
          ));
      }),
      l.register(`.MarketDeferredModPopup`, `Market.DeferredMod`));
  });
Zn();
