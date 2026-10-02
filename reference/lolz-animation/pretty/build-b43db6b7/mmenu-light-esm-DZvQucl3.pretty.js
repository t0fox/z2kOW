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
    (e._sentryDebugIds[t] = `cd5fa0e6-212a-4a31-b491-4062d57ba242`),
    (e._sentryDebugIdIdentifier = `sentry-dbid-cd5fa0e6-212a-4a31-b491-4062d57ba242`));
} catch (e) {}
import { __esmMin as e } from "./rolldown-runtime-MtAR-uS5.js";
var t,
  n,
  r = e(() => {
    ((t = (function () {
      function e(e) {
        var t = this;
        ((this.listener = function (e) {
          (e.matches ? t.matchFns : t.unmatchFns).forEach(function (e) {
            e();
          });
        }),
          (this.toggler = window.matchMedia(e)),
          this.toggler.addListener(this.listener),
          (this.matchFns = []),
          (this.unmatchFns = []));
      }
      return (
        (e.prototype.add = function (e, t) {
          (this.matchFns.push(e),
            this.unmatchFns.push(t),
            (this.toggler.matches ? e : t)());
        }),
        e
      );
    })()),
      (n = t));
  }),
  i,
  a,
  o = e(() => {
    ((i = function (e) {
      return Array.prototype.slice.call(e);
    }),
      (a = function (e, t) {
        return i((t || document).querySelectorAll(e));
      }));
  }),
  s,
  c,
  l,
  u = e(() => {
    (o(),
      (s = `mm-spn`),
      (c = (function () {
        function e(e, t, n, r, i) {
          ((this.node = e),
            (this.title = t),
            (this.slidingSubmenus = r),
            (this.selectedClass = n),
            this.node.classList.add(s),
            this.node.classList.add(s + `--` + i),
            this.node.classList.add(
              s + `--` + (this.slidingSubmenus ? `navbar` : `vertical`),
            ),
            this._setSelectedl(),
            this._initAnchors());
        }
        return (
          Object.defineProperty(e.prototype, `prefix`, {
            get: function () {
              return s;
            },
            enumerable: !1,
            configurable: !0,
          }),
          (e.prototype.openPanel = function (e) {
            var t = e.parentElement;
            if (this.slidingSubmenus) {
              var n = e.dataset.mmSpnTitle;
              (t === this.node
                ? this.node.classList.add(s + `--main`)
                : (this.node.classList.remove(s + `--main`),
                  n ||
                    i(t.children).forEach(function (e) {
                      e.matches(`a, span`) && (n = e.textContent);
                    })),
                n || (n = this.title),
                (this.node.dataset.mmSpnTitle = n),
                a(`.` + s + `--open`, this.node).forEach(function (e) {
                  (e.classList.remove(s + `--open`),
                    e.classList.remove(s + `--parent`));
                }),
                e.classList.add(s + `--open`),
                e.classList.remove(s + `--parent`));
              for (var r = e.parentElement.closest(`ul`); r; )
                (r.classList.add(s + `--open`),
                  r.classList.add(s + `--parent`),
                  (r = r.parentElement.closest(`ul`)));
            } else {
              var o = e.matches(`.` + s + `--open`);
              (a(`.` + s + `--open`, this.node).forEach(function (e) {
                e.classList.remove(s + `--open`);
              }),
                e.classList[o ? `remove` : `add`](s + `--open`));
              for (var c = e.parentElement.closest(`ul`); c; )
                (c.classList.add(s + `--open`),
                  (c = c.parentElement.closest(`ul`)));
            }
          }),
          (e.prototype._setSelectedl = function () {
            var e = a(`.` + this.selectedClass, this.node),
              t = e[e.length - 1],
              n = null;
            (t && (n = t.closest(`ul`)),
              n || (n = this.node.querySelector(`ul`)),
              this.openPanel(n));
          }),
          (e.prototype._initAnchors = function () {
            var e = this,
              t = function (e) {
                return !!e.matches(`a`);
              },
              n = function (t) {
                var n;
                return (
                  (n = t.closest(`span`)
                    ? t.parentElement
                    : t.closest(`li`)
                      ? t
                      : !1),
                  n
                    ? (i(n.children).forEach(function (t) {
                        t.matches(`ul`) && e.openPanel(t);
                      }),
                      !0)
                    : !1
                );
              },
              r = function (t) {
                var n = a(`.` + s + `--open`, t),
                  r = n[n.length - 1];
                if (r) {
                  var i = r.parentElement.closest(`ul`);
                  if (i) return (e.openPanel(i), !0);
                }
                return !1;
              };
            this.node.addEventListener(`click`, function (e) {
              var i = e.target,
                a = !1;
              ((a = a || t(i)),
                (a = a || n(i)),
                (a = a || r(i)),
                a && e.stopImmediatePropagation());
            });
          }),
          e
        );
      })()),
      (l = c));
  }),
  d,
  f,
  p,
  m = e(() => {
    ((d = `mm-ocd`),
      (f = (function () {
        function e(e, t) {
          var n = this;
          (e === void 0 && (e = null),
            (this.wrapper = document.createElement(`div`)),
            this.wrapper.classList.add(`` + d),
            this.wrapper.classList.add(d + `--` + t),
            (this.content = document.createElement(`div`)),
            this.content.classList.add(d + `__content`),
            this.wrapper.append(this.content),
            (this.backdrop = document.createElement(`div`)),
            this.backdrop.classList.add(d + `__backdrop`),
            this.wrapper.append(this.backdrop),
            document.body.append(this.wrapper),
            e && this.content.append(e));
          var r = function (e) {
            (n.close(), e.stopImmediatePropagation());
          };
          (this.backdrop.addEventListener(`touchstart`, r, { passive: !0 }),
            this.backdrop.addEventListener(`mousedown`, r, { passive: !0 }));
        }
        return (
          Object.defineProperty(e.prototype, `prefix`, {
            get: function () {
              return d;
            },
            enumerable: !1,
            configurable: !0,
          }),
          (e.prototype.open = function () {
            (this.wrapper.classList.add(d + `--open`),
              document.body.classList.add(d + `-opened`));
          }),
          (e.prototype.close = function () {
            (this.wrapper.classList.remove(d + `--open`),
              document.body.classList.remove(d + `-opened`));
          }),
          e
        );
      })()),
      (p = f));
  }),
  h,
  g,
  _ = e(() => {
    (r(),
      u(),
      m(),
      (h = (function () {
        function e(e, t) {
          (t === void 0 && (t = `all`),
            (this.menu = e),
            (this.toggler = new n(t)));
        }
        return (
          (e.prototype.navigation = function (e) {
            var t = this;
            if (!this.navigator) {
              e = e || {};
              var n = e.title,
                r = n === void 0 ? `Menu` : n,
                i = e.selectedClass,
                a = i === void 0 ? `Selected` : i,
                o = e.slidingSubmenus,
                s = o === void 0 ? !0 : o,
                c = e.theme,
                u = c === void 0 ? `light` : c;
              ((this.navigator = new l(this.menu, r, a, s, u)),
                this.toggler.add(
                  function () {
                    return t.menu.classList.add(t.navigator.prefix);
                  },
                  function () {
                    return t.menu.classList.remove(t.navigator.prefix);
                  },
                ));
            }
            return this.navigator;
          }),
          (e.prototype.offcanvas = function (e) {
            var t = this;
            if (!this.drawer) {
              e = e || {};
              var n = e.position,
                r = n === void 0 ? `left` : n;
              this.drawer = new p(null, r);
              var i = document.createComment(`original menu location`);
              (this.menu.after(i),
                this.toggler.add(
                  function () {
                    t.drawer.content.append(t.menu);
                  },
                  function () {
                    (t.drawer.close(), i.after(t.menu));
                  },
                ));
            }
            return this.drawer;
          }),
          e
        );
      })()),
      (g = h));
  });
export { g as core_default, _ as init_core };
