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
    (e._sentryDebugIds[t] = `6c096c44-d7ca-4183-96e1-8779d5e0b06f`),
    (e._sentryDebugIdIdentifier = `sentry-dbid-6c096c44-d7ca-4183-96e1-8779d5e0b06f`));
} catch (e) {}
import { __esmMin as e } from "./rolldown-runtime-MtAR-uS5.js";
import {
  append as t,
  append_styles as n,
  child as r,
  clsx as i,
  create_custom_element as a,
  flushSync as o,
  from_html as s,
  if_block as c,
  init_client as l,
  init_disclose_version as u,
  only_child as d,
  pop as f,
  prop as p,
  push as m,
  reset as h,
  set_class as g,
  template_effect as _,
} from "./svelte-src-KVj-O-HW.js";
function v(e, a) {
  (m(a, !0), n(e, C));
  let s = p(a, `variant`, 7),
    l = p(a, `type`, 7),
    u = p(a, `inline`, 7, !1);
  var v = {
      get variant() {
        return s();
      },
      set variant(e) {
        (s(e), o());
      },
      get type() {
        return l();
      },
      set type(e) {
        (l(e), o());
      },
      get inline() {
        return u();
      },
      set inline(e = !1) {
        (u(e), o());
      },
    },
    w = S();
  let T;
  var E = r(w),
    D = (e) => {
      var n = y(),
        r = d(n);
      (_(() => g(r, 0, i(l()), `lztng-1f69oee`)), t(e, n));
    },
    O = (e) => {
      var n = b(),
        r = d(n);
      (_(() => g(r, 0, i(l()), `lztng-1f69oee`)), t(e, n));
    },
    k = (e) => {
      var n = x();
      let r;
      (_(() => {
        var e;
        return (r = g(
          n,
          1,
          `lztui-spinner lztui-spinner-${(e = l()) == null ? `` : e}`,
          `lztng-1f69oee`,
          r,
          { "lztui-spinner-full": !u() },
        ));
      }),
        t(e, n));
    };
  return (
    c(E, (e) => {
      s() === `logoForum` ? e(D) : s() === `logoMarket` ? e(O, 1) : e(k, -1);
    }),
    h(w),
    _(
      () =>
        (T = g(w, 1, `lztui-spinner-wrapper lztng-1f69oee`, null, T, {
          "lztui-spinner-full": !u(),
        })),
    ),
    t(e, w),
    f(v)
  );
}
var y,
  b,
  x,
  S,
  C,
  w = e(() => {
    (u(),
      l(),
      (y = s(
        `<div class="lztui-spinner-logo lztng-1f69oee"><svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256" fill="none"><defs class="lztng-1f69oee"><linearGradient id="shimmer" class="lztng-1f69oee"><stop offset="0%" stop-color="#393939" class="lztng-1f69oee"><animate attributeName="offset" values="-2;-1;1;2" dur="1.5s" repeatCount="indefinite" class="lztng-1f69oee"></animate></stop><stop offset="50%" stop-color="#505050" class="lztng-1f69oee"><animate attributeName="offset" values="-1;0;2;3" dur="1.5s" repeatCount="indefinite" class="lztng-1f69oee"></animate></stop><stop offset="100%" stop-color="#393939" class="lztng-1f69oee"><animate attributeName="offset" values="0;1;3;4" dur="1.5s" repeatCount="indefinite" class="lztng-1f69oee"></animate></stop></linearGradient><clipPath id="clip0_123_378" class="lztng-1f69oee"><rect width="236.512" height="214.598" fill="white" transform="translate(9.4707 20.4229)" class="lztng-1f69oee"></rect></clipPath></defs><g clip-path="url(#clip0_123_378)" class="lztng-1f69oee"><path fill-rule="evenodd" clip-rule="evenodd" d="M70.1504 207.392C91.8146 224.992 116.842 235.022 143.533 235.022C183.225 235.022 219.257 212.775 245.995 176.542C234.706 161.247 221.764 148.436 207.575 138.751L184.794 150.124C189.69 157.741 192.542 166.809 192.542 176.542C192.542 203.577 170.604 225.491 143.533 225.491C122.499 225.491 104.566 212.252 97.6139 193.666L70.1504 207.38V207.392ZM126.67 179.168C127.216 182.721 128.88 186.025 131.459 188.604C134.656 191.8 139.005 193.595 143.533 193.583C152.957 193.583 160.598 185.953 160.598 176.542C160.598 171.919 158.756 167.724 155.761 164.646L126.682 179.168H126.67Z" fill="url(#shimmer)" class="lztng-1f69oee"></path><path d="M76.3528 176.16L242.405 96.3367L205.91 20.4229L187.062 87.507L164.412 40.3758L145.552 107.46L122.902 60.3287L104.042 127.413L81.3916 80.2816L62.5319 147.366L39.8814 100.235L9.4707 208.318L50.9809 188.365L76.3528 176.172V176.16Z" fill="url(#shimmer)" class="lztng-1f69oee"></path></g></svg></div>`,
      )),
      (b = s(
        `<div class="lztui-spinner-logo lztng-1f69oee"><svg xmlns="http://www.w3.org/2000/svg" width="256" height="256" viewBox="0 0 256 256" fill="none"><defs class="lztng-1f69oee"><linearGradient id="shimmer" class="lztng-1f69oee"><stop offset="0%" stop-color="#393939" class="lztng-1f69oee"><animate attributeName="offset" values="-2;-1;1;2" dur="1.5s" repeatCount="indefinite" class="lztng-1f69oee"></animate></stop><stop offset="50%" stop-color="#505050" class="lztng-1f69oee"><animate attributeName="offset" values="-1;0;2;3" dur="1.5s" repeatCount="indefinite" class="lztng-1f69oee"></animate></stop><stop offset="100%" stop-color="#393939" class="lztng-1f69oee"><animate attributeName="offset" values="0;1;3;4" dur="1.5s" repeatCount="indefinite" class="lztng-1f69oee"></animate></stop></linearGradient></defs><path d="M4 40C28.2591 85.11 70.8437 98.4849 122.833 99.5138C153.51 100.147 210.666 97.6539 210.666 113.759C210.666 125.867 176.438 157.286 176.438 165.042C176.438 165.042 207.479 139.4 224.876 124.206C242.271 109.011 252 99.949 252 90.9665C252 72.6851 179.828 76.0881 121.542 76.0881C63.2552 76.0881 31.4076 65.1666 4 40ZM66 174.539C54.5769 174.539 45.3334 183.601 45.3334 194.799C45.3334 205.997 54.5769 215.059 66 215.059C77.4231 215.059 86.6666 205.997 86.6666 194.799C86.6666 183.601 77.4231 174.539 66 174.539ZM148.667 174.539C137.243 174.539 128 183.601 128 194.799C128 205.997 137.243 215.059 148.667 215.059C160.09 215.059 169.333 205.997 169.333 194.799C169.333 183.601 160.09 174.539 148.667 174.539Z" fill="url(#shimmer)" class="lztng-1f69oee"></path></svg></div>`,
      )),
      (x = s(
        `<div><div class="lztui-spinner-bounce lztui-spinner-bounce1 lztng-1f69oee"></div> <div class="lztui-spinner-bounce lztui-spinner-bounce2 lztng-1f69oee"></div> <div class="lztui-spinner-bounce lztui-spinner-bounce3 lztng-1f69oee"></div></div>`,
      )),
      (S = s(`<div><!></div>`)),
      (C = {
        hash: `lztng-1f69oee`,
        code: `.lztui-spinner.lztng-1f69oee {display:flex;align-items:center;justify-content:center;}.lztui-spinner-logo.lztng-1f69oee .small:where(.lztng-1f69oee) {width:28px;height:28px;}.lztui-spinner-logo.lztng-1f69oee .medium:where(.lztng-1f69oee) {width:40px;height:40px;}.lztui-spinner-bounce.lztng-1f69oee {
		animation: sk-bouncedelay 1.4s infinite ease-in-out both;background-color:#454545;border-radius:100%;display:inline-block;transform-origin:center bottom;}.lztui-spinner-small.lztng-1f69oee .lztui-spinner-bounce:where(.lztng-1f69oee) {width:6px;height:6px;margin:0 2px;}.lztui-spinner-medium.lztng-1f69oee .lztui-spinner-bounce:where(.lztng-1f69oee) {width:16px;height:16px;}.lztui-spinner-bounce1.lztng-1f69oee {animation-delay:-0.32s;}.lztui-spinner-bounce2.lztng-1f69oee {animation-delay:-0.16s;}

	@keyframes lztng-1f69oee-lztui-spinner-bounce {
		0%,
		80%,
		100% {
			transform: scale(0);
		}
		40% {
			transform: scale(1);
		}
	}.lztui-spinner-full.lztng-1f69oee {height:100%;}.lztui-spinner-wrapper.lztng-1f69oee {display:inline-block;}.lztui-spinner-full.lztui-spinner-wrapper.lztng-1f69oee {display:flex;align-items:center;}`,
      }),
      a(v, { variant: {}, type: {}, inline: {} }, [], [], { mode: `open` }));
  });
export { v as Spinner, w as init_Spinner };
