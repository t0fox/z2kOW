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
    (e._sentryDebugIds[t] = `fceb1b18-17a8-4c43-9802-5fa0c47ffb82`),
    (e._sentryDebugIdIdentifier = `sentry-dbid-fceb1b18-17a8-4c43-9802-5fa0c47ffb82`));
} catch (e) {}
import { __esmMin as e } from "../assets/js/chunks/rolldown-runtime-MtAR-uS5.js";
import {
  import_jquery as t,
  init_jquery_xenforo_rollup as n,
  jquery_xenforo_rollup_default as r,
} from "../assets/js/chunks/jquery-nYWvo6DM.js";
import { init___sentry_release_injection_file as i } from "../assets/js/chunks/_sentry-release-injection-file-oX-AVkR8.js";
import {
  init_xenforo as a,
  xenforo_default as o,
} from "../assets/js/chunks/xenforo-iTePVTI1.js";
import {
  editor_default as s,
  init_editor as c,
} from "../assets/js/chunks/froala-Cv-iWpGU.js";
var l = e(() => {
  (a(),
    n(),
    c(),
    i(),
    (o.QuickReplyTrigger = function (e) {
      e.on(`click`, function () {
        console.info(`Quick Reply Trigger Click`);
        var t = null,
          n = null,
          i = {},
          a = null,
          c;
        if (
          (e.is(`.MultiQuote`)
            ? (t = r(e.data(`form`)))
            : ((t = r(`#QuickReply`)), t.data(`QuickReply`).scrollAndFocus()),
          (a = new r.Event(`QuickReplyDataPrepare`)),
          (a.$trigger = e),
          (a.queryData = i),
          r(document).trigger(a),
          e.attr(`data-quote`).includes(`comment`)
            ? (c = `posts/comments/${e.attr(`data-quote`).split(`-`)[2]}/quote`)
            : e.attr(`data-quote`).includes(`post`)
              ? (c = `posts/${e.attr(`data-quote`).split(`-`)[1]}/quote`)
              : e.attr(`data-quote`).includes(`message`) &&
                (c = `support-tickets/messages/${e.attr(`data-quote`).split(`-`)[1]}/quote`),
          c)
        )
          return (
            c.length || (c = e.data(`posturl`) || e.attr(`href`)),
            n ||
              (n = o.ajax(c, i, function (n) {
                if (o.hasResponseError(n)) return !1;
                var i = o.getEditorInForm(t);
                if (!i) return !1;
                if (i.$box) {
                  var a = r(`#QuickReply`),
                    c = r(`#` + e.attr(`data-quote`)),
                    l = n.quote.match(
                      /\[QUOTE="([^,]+), ([A-z]+): (\d+)(?:, member: (\d+))?"]/i,
                    ),
                    u = c.find(`.username`).clone();
                  u = u.wrapInner(`<span class="username"></span>`).html();
                  let t = r(i.html.get()).text();
                  (c.find(`.tagComment`).length
                    ? c.find(`.tagComment`).data(`wipe`, `no`)
                    : (c.append(
                        r(
                          `<a class="XITag tagComment PostCommentButton" data-username="${l[1]}" data-wipe="no"></a>`,
                        ),
                      ),
                      c.xfActivate()),
                    e.attr(`data-quote`).indexOf(`comment`) > -1 &&
                      !a.data(`commentingmessage`) &&
                      !t &&
                      c.find(`.tagComment`).trigger(`click`));
                  var d = n.quoteHtml,
                    f = r(`#` + c.attr(`id`)),
                    p = c.find(`.hashPermalink`).attr(`href`),
                    m = a.find(`.MessageReplyBox`);
                  if (!t && !c.hasClass(`firstPost`)) {
                    let e;
                    ((e =
                      c.attr(`id`).split(`-`).length > 2
                        ? c.parents(`.message`).attr(`id`).split(`-`)[1]
                        : c.attr(`id`).split(`-`)[1]),
                      c.attr(`id`).split(`-`).length > 2
                        ? a.data(`commentingmessage`, c.parents(`.message`))
                        : a.data(`commentingmessage`, c),
                      a.attr(`action`, `posts/${e}/comment`));
                  }
                  (!t &&
                    a.data(`commentingmessage`) &&
                    (m
                      .find(`.Content`)
                      .html(
                        m
                          .find(`.Content`)
                          .data(`content`)
                          .replace(`{{username}}`, u),
                      )
                      .attr(`href`, p)
                      .unbind(`click`)
                      .on(`click`, function (e) {
                        (e.preventDefault(),
                          isScrolledIntoView(f) ||
                            r(`html, body`).animate(
                              { scrollTop: f.offset().top - 44 },
                              0,
                            ),
                          o.animateBackgroundColor(f));
                      }),
                    m.show()),
                    m
                      .find(`.Cancel`)
                      .off(`click`)
                      .on(
                        `click`,
                        function (e) {
                          (m.hide(),
                            a.data(`commentingmessage`, ``),
                            a.attr(`action`, a.data(`def-action`)),
                            e.screenX || i.html.set(``));
                        }.bind(this),
                      ),
                    i.$el.on(`keydown`, function () {}.bind(this)));
                  try {
                    (i.html.insert(d + `<p>${s.MARKERS}</p>`),
                      i.selection.restore());
                  } catch (e) {}
                  console.info(`QuoteHTML: %s`, n.quoteHtml);
                } else i.val(i.val() + n.quote);
                e.is(`.MultiQuote`) && t.trigger(`MultiQuoteComplete`);
              })),
            !1
          );
      });
    }),
    (o.InlineMessageEditor = function (e) {
      (new o.MultiSubmitFix(e),
        e.on({
          AutoValidationBeforeSubmit: function (e) {
            r(e.clickedSubmitButton).is(`input[name="more_options"]`) &&
              (e.preventDefault(), (e.returnValue = !0));
          },
          AutoValidationComplete: function (t) {
            var n = e.closest(`div.xenOverlay`).data(`overlay`);
            o.hasTemplateHtml(t.ajaxData, `messagesTemplateHtml`) ||
            o.hasTemplateHtml(t.ajaxData)
              ? (t.preventDefault(),
                n.close().getTrigger().data(`XenForo.OverlayTrigger`).deCache(),
                o.showMessages(t.ajaxData, n.getTrigger(), `instant`))
              : console.warn(`No template HTML!`);
          },
        }));
    }),
    (o.NewMessageLoader = function (e) {
      var t = !1;
      e.on(`click`, function (n) {
        (n.preventDefault(),
          !t &&
            ((t = !0),
            o
              .ajax(e.data(`href`) || e.attr(`href`), {}, function (e) {
                if (o.hasResponseError(e)) return !1;
                var t = r(`#QuickReply`),
                  n = r(`#messageList`);
                (r(`input[name="last_date"]`, t).val(e.lastDate),
                  new o.ExtLoader(e, function () {
                    (n.find(`.messagesSinceReplyingNotice`).remove(),
                      r(e.templateHtml).each(function () {
                        this.tagName &&
                          r(this).xfInsert(`appendTo`, n, `xfFadeIn`, 0);
                      }));
                  }));
              })
              .always(function () {
                t = !1;
              })));
      });
    }),
    (o.MessageLoader = function (e) {
      e.on(`click`, function (t) {
        t.preventDefault();
        var n = [];
        (r(e.data(`messageselector`)).each(function (e, t) {
          n.push(t.id);
        }),
          n.length
            ? o.ajax(e.attr(`href`), { messageIds: n }, function (t) {
                o.showMessages(t, e, `fadeDown`);
              })
            : console.warn(`No messages found to load.`));
      });
    }),
    (o.showMessages = function (e, t, n) {
      let i = function (e, t) {
        switch ((e.charAt(0) === `#` && (e = `[id="${e.substring(1)}"]`), n)) {
          case `instant`:
            n = { show: `xfShow`, hide: `xfHide`, speed: 0 };
            break;
          case `fadeIn`:
            n = { show: `xfFadeIn`, hide: `xfFadeOut`, speed: o.speed.fast };
            break;
          case `fadeDown`:
          default:
            n = { show: `xfFadeDown`, hide: `xfFadeUp`, speed: o.speed.normal };
        }
        r(e)[n.hide](n.speed / 2, function () {
          r(t).xfInsert(`replaceAll`, e, n.show, n.speed);
        });
      };
      if (o.hasResponseError(e)) return !1;
      o.hasTemplateHtml(e, `messagesTemplateHtml`)
        ? new o.ExtLoader(e, function () {
            r.each(e.messagesTemplateHtml, i);
          })
        : o.hasTemplateHtml(e) &&
          new o.ExtLoader(e, function () {
            i(t.data(`messageselector`), e.templateHtml);
          });
    }),
    (o.PollVoteForm = function (e) {
      var t = function (t) {
        new o.ExtLoader(t, function () {
          var n = e.closest(`.PollContainer`);
          e.xfFadeUp(
            o.speed.normal,
            function () {
              e.empty().remove();
              var i = r(t.templateHtml);
              (i.is(`.PollContainer`)
                ? (i = i.children())
                : i.find(`.PollContainer`).length &&
                  (i = i.find(`.PollContainer`).children()),
                i.xfInsert(`appendTo`, n),
                n.xfActivate());
            },
            o.speed.normal,
            `swing`,
          );
        });
      };
      (e.on(`AutoValidationComplete`, function (e) {
        (e.preventDefault(), o.hasTemplateHtml(e.ajaxData) && t(e.ajaxData));
      }),
        e.on(`click`, `.PollChangeVote`, function (e) {
          e.preventDefault();
          let n = r(e.target),
            i = n.attr(`href`);
          i &&
            (n.removeAttr(`href`),
            o.ajax(
              i,
              {},
              function (e) {
                o.hasTemplateHtml(e) && t(e);
              },
              { method: `get` },
            ));
        }));
      var n = e.data(`max-votes`) || 0;
      n > 1 &&
        e.on(`click`, `.PollResponse`, function () {
          var t = e.find(`.PollResponse`),
            r = t.filter(`:not(:checked)`);
          t.length - r.length >= n
            ? r.prop(`disabled`, !0)
            : r.prop(`disabled`, !1);
        });
    }),
    (o.MultiQuote = function (e) {
      this.__construct(e);
    }),
    (o.MultiQuote.prototype = {
      __construct: function (e) {
        ((this.$button = e.on(`click`, r.context(this, `prepareOverlay`))),
          (this.$form = e.closest(`form`)),
          (this.cookieName = e.data(`mq-cookie`) || `MultiQuote`),
          (this.cookieValue = []),
          (this.submitUrl = e.data(`submiturl`)),
          (this.$controls = new t.default()),
          this.getCookieValue(),
          this.setButtonState());
        var n = this;
        (this.$form.on(`MultiQuoteComplete`, r.context(this, `reset`)),
          this.$form.on(`MultiQuoteRemove MultiQuoteAdd`, function (e, t) {
            t &&
              t.messageId &&
              n.toggleControl(t.messageId, e.type == `MultiQuoteAdd`);
          }),
          r(document).on(
            `QuickReplyDataPrepare`,
            r.context(this, `quickReplyDataPrepare`),
          ));
      },
      getCookieValue: function () {
        var e = r.getCookie(this.cookieName);
        this.cookieValue = e == null ? [] : e.split(`,`);
      },
      setButtonState: function () {
        (this.getCookieValue(),
          this.cookieValue.length ? this.$button.show() : this.$button.hide());
      },
      addControl: function (e) {
        (e.on(`click`, r.context(this, `clickControl`)),
          this.getCookieValue(),
          this.setControlState(
            e,
            r.inArray(e.data(`messageid`) + ``, this.cookieValue) >= 0,
            !0,
          ),
          (this.$controls = this.$controls.add(e)));
      },
      setControls: function () {
        var e = this;
        (e.getCookieValue(),
          this.$controls.each(function () {
            e.setControlState(
              r(this),
              r.inArray(r(this).data(`messageid`) + ``, e.cookieValue) >= 0,
            );
          }));
      },
      setControlState: function (e, t, n) {
        var r,
          i = this.$button,
          a;
        (t
          ? ((r = i.data(`remove`) || `-`), (a = !0))
          : ((r = i.data(`add`) || `+`), (a = !1)),
          (!n || e.hasClass(`active`) !== a) &&
            e.toggleClass(`active`, t).find(`span.symbol`).text(r));
      },
      clickControl: function (e) {
        e.preventDefault();
        var t, n, i, a, s;
        ((t = r(e.target).closest(`a.MultiQuoteControl`)),
          t.is(`.QuoteSelected`)
            ? ((n = !0),
              (i = r(`#QuoteSelected`).data(`quote-html`)),
              t.trigger(`QuoteSelectedClicked`))
            : ((n = !t.is(`.active`)), (i = null)),
          (a = t.data(`messageid`)),
          this.toggleControl(a, n, i),
          (s = this.$button.data(n ? `add-message` : `remove-message`)) &&
            o.alert(s, ``, 2e3, null, `success`));
      },
      toggleControl: function (e, t, n) {
        this.getCookieValue();
        var i = null;
        if (((e += ``), e.indexOf(`-`) > 0)) {
          var a = e.split(`-`);
          ((e = a[0]), (i = a[1]));
        }
        var o,
          s = r.inArray(e, this.cookieValue);
        ((o = this.$controls
          .filter(function () {
            return r(this).data(`messageid`) == e;
          })
          .first()),
          t
            ? (o.length && this.setControlState(o, !0),
              n === null
                ? this.removeQuotesFromStorage(e)
                : this.storeSelectedQuote(e, n),
              s < 0 && this.cookieValue.push(e))
            : (this.removeQuotesFromStorage(e, i),
              this.getStorageForId(e) ||
                (o.length && this.setControlState(o, !1),
                s >= 0 && this.cookieValue.splice(s, 1))),
          this.cookieValue.length > 0
            ? r.setCookie(this.cookieName, this.cookieValue.join(`,`))
            : r.deleteCookie(this.cookieName),
          this.setButtonState());
      },
      storeSelectedQuote: function (e, t) {
        var n = this.getStorageObject(),
          i = 0;
        ((!n[e] || typeof n[e] != `object`) && (n[e] = {}),
          r.each(n[e], function (e) {
            i = e;
          }),
          (i = parseInt(i, 10) + 1),
          (n[e][i] = t),
          this.saveStorageObject(n));
      },
      removeQuotesFromStorage: function (e, t) {
        var n = this.getStorageObject();
        if (((e += ``), !t && e.indexOf(`-`) > 0)) {
          var i = e.split(`-`);
          ((e = i[0]), (t = i[1]));
        }
        (t
          ? (delete n[e][t], r.isEmptyObject(n[e]) && delete n[e])
          : delete n[e],
          this.saveStorageObject(n));
      },
      getStorageObject: function () {
        if (!window.localStorage) return {};
        var e = null;
        try {
          e = JSON.parse(localStorage.getItem(this.cookieName));
        } catch (e) {}
        return ((typeof e != `object` || !e) && (e = {}), e);
      },
      getStorageForId: function (e) {
        var t = this.getStorageObject();
        return t[e] && typeof t[e] == `object` && !r.isEmptyObject(t[e])
          ? t[e]
          : null;
      },
      getStorageObjectFlat: function () {
        var e = {};
        return (
          r.each(this.getStorageObject(), function (t, n) {
            typeof n == `object` &&
              r.each(n, function (n, r) {
                e[t + `-` + n] = r;
              });
          }),
          e
        );
      },
      saveStorageObject: function (e) {
        window.localStorage &&
          localStorage.setItem(this.cookieName, JSON.stringify(e));
      },
      prepareOverlay: function () {
        var e = this.getStorageObjectFlat();
        (r.each(e, function (t, n) {
          e[t] = o.unparseBbCode(n);
        }),
          o.ajax(
            this.$button.data(`href`),
            { quoteSelections: e },
            function (e) {
              o.hasTemplateHtml(e) &&
                new o.ExtLoader(e, function (e) {
                  ((e.noCache = !0),
                    o.createOverlay(null, e.templateHtml, e).load());
                });
            },
          ));
      },
      quickReplyDataPrepare: function (e) {
        if (e.$trigger.is(`.MultiQuote`)) {
          var t = this.getStorageObjectFlat();
          (r.each(t, function (e, n) {
            t[e] = o.unparseBbCode(n);
          }),
            (e.queryData.quoteSelections = t),
            (e.queryData.postIds = r(e.$trigger.data(`inputs`))
              .map(function () {
                return this.value;
              })
              .get()));
        }
      },
      reset: function () {
        (r.deleteCookie(this.cookieName),
          (this.cookieValue = []),
          window.localStorage && localStorage.removeItem(this.cookieName),
          this.setControls(),
          this.setButtonState());
      },
    }),
    (o.MultiQuoteControl = function (e) {
      var t = e.data(`mq-target`) || `#MultiQuote`,
        n = r(t).data(`XenForo.MultiQuote`);
      n && n.addControl(e);
    }),
    (o.MultiQuoteRemove = function (e) {
      e.on(`click`, function () {
        var t = e.closest(`.MultiQuoteItem`),
          n = t.find(`.MultiQuoteId`).val(),
          i = r(r(`#MultiQuoteForm`).data(`form`)),
          a = e.closest(`.xenOverlay`);
        (n && i.trigger(`MultiQuoteRemove`, { messageId: n }),
          t.remove(),
          a.length && !a.find(`.MultiQuoteItem`).length && a.overlay().close());
      });
    }),
    (o.Sortable = function (e) {
      e.on({
        sortupdate: function () {},
        dragstart: function (e) {
          console.log(`drag start, %o`, e.target);
        },
        dragend: function () {
          console.log(`drag end`);
        },
      });
    }),
    (o.SelectQuotable = function (e) {
      this.__construct(e);
    }),
    (o.SelectQuotable.prototype = {
      __construct: function (e) {
        if (window.getSelection && r(`#QuickReply`).length) {
          ((this.$container = e),
            (this.$messageTextContainer = null),
            (this.triggerEvent = void 0));
          var t = this,
            n = !1,
            i,
            a = function () {
              !i &&
                !t.processing &&
                (i = setTimeout(function () {
                  ((i = null), t._handleSelection());
                }, 100));
            };
          (e.on(`mousedown`, function () {
            n = !0;
          }),
            e.on(`mouseup`, function () {
              ((n = !1), a());
            }),
            e.on(`pointerdown pointerup`, (e) => {
              this.triggerEvent = e;
            }),
            r(document).on(`selectionchange`, function () {
              n || a();
            }),
            r(document).on(`QuickReplyDataPrepare`, function (e) {
              var t = e.$trigger.closest(`#QuoteSelected`);
              t.length &&
                ((e.queryData.quoteHtml = o.unparseBbCode(
                  t.data(`quote-html`),
                )),
                e.$trigger.trigger(`QuoteSelectedClicked`));
            }));
        }
      },
      buttonClicked: function () {
        var e = window.getSelection();
        e.isCollapsed ||
          (e.collapse(e.getRangeAt(0).commonAncestorContainer, 0),
          this.hideQuoteButton());
      },
      _handleSelection: function () {
        this.processing = !0;
        var e = window.getSelection();
        this._isValidSelection(e)
          ? this.showQuoteButton(e)
          : !this.translating &&
            !this.translationShown &&
            !this._isSelectionInTooltip(e) &&
            this.hideQuoteButton();
        var t = this;
        setTimeout(function () {
          t.processing = !1;
        }, 0);
      },
      _isValidSelection: function (e) {
        if (
          ((this.$messageTextContainer = null), e.isCollapsed || !e.rangeCount)
        )
          return !1;
        var t = e.getRangeAt(0);
        if (
          (this._adjustRange(t),
          !t.toString().trim().length &&
            !t.cloneContents().querySelectorAll(`img`).length)
        )
          return !1;
        var n = r(t.commonAncestorContainer).closest(`.SelectQuoteContainer`);
        if (!n.length) return !1;
        var i = n.closest(`.message`);
        return !i.find(`a.MultiQuoteControl, a.ReplyQuote`).length ||
          r(t.startContainer).closest(`.bbCodeQuote, .NoSelectToQuote`)
            .length ||
          r(t.endContainer).closest(`.bbCodeQuote, .NoSelectToQuote`).length ||
          (this.$container &&
            n.closest(`.SelectQuotable`)[0] !== this.$container[0])
          ? !1
          : ((this.$messageTextContainer = n), !0);
      },
      _isSelectionInTooltip: function (e) {
        return e.rangeCount
          ? r(e.getRangeAt(0).commonAncestorContainer).closest(
              `[data-tippy-root]`,
            ).length > 0
          : !1;
      },
      _adjustRange: function (e) {
        var t = !1,
          n = !1;
        if (e.endOffset == 0) {
          var i = r(e.endContainer);
          (e.endContainer.nodeType == 3 &&
            !e.endContainer.previousSibling &&
            (i = i.parent()),
            (n = i.is(`.quote, .attribution, .bbCodeQuote`)));
        }
        if (n) {
          var a = r(e.endContainer).closest(`.bbCodeQuote`);
          a.length && (e.setEndBefore(a[0]), (t = !0));
        }
        if (t) {
          var o = window.getSelection();
          (o.removeAllRanges(), o.addRange(e));
        }
      },
      _getPointerXY: function (e) {
        return e
          ? e.touches && e.touches[0]
            ? { x: e.touches[0].clientX, y: e.touches[0].clientY }
            : e.changedTouches && e.changedTouches[0]
              ? {
                  x: e.changedTouches[0].clientX,
                  y: e.changedTouches[0].clientY,
                }
              : typeof e.clientX == `number` && typeof e.clientY == `number`
                ? { x: e.clientX, y: e.clientY }
                : null
          : null;
      },
      previousOffset: { top: 0, left: 0 },
      showQuoteButton: function (e) {
        var t,
          n = this.$messageTextContainer.closest(`[id]`).attr(`id`);
        (this.tippyInstance === void 0 || this.lastMessageId !== n
          ? (this.hideQuoteButton(),
            this.createButton(),
            (this.lastMessageId = n))
          : this.translationShown && this.restoreButtons(),
          this.$button.data(`quote-html`, this.getSelectionHtml(e)),
          this.$button.data(`quote-text`, e.toString()),
          this.$translateWrap &&
            this.$translateWrap.toggle(
              this._isTranslatableSelection(e.toString()),
            ));
        let r = 6;
        if (
          (((t = this.triggerEvent) == null ? void 0 : t.pointerType) ===
            `touch` &&
            (r = document.documentElement.classList.contains(`iOS`) ? 10 : 20),
          this.tippyInstance)
        ) {
          let t = e.getRangeAt(0);
          (this.tippyInstance.setProps({
            getReferenceClientRect: () => {
              let e = Array.from(t.getClientRects()),
                n = e.length ? e[e.length - 1] : t.getBoundingClientRect(),
                r = this._getPointerXY(this.triggerEvent);
              if (!r || !e.length) return n;
              let i = e[0],
                a = 1 / 0;
              for (let t of e) {
                let e =
                  r.y < t.top
                    ? t.top - r.y
                    : r.y > t.bottom
                      ? r.y - t.bottom
                      : 0;
                e < a && ((a = e), (i = t));
              }
              let o = t.getBoundingClientRect(),
                s = Math.min(Math.max(r.x, o.left), o.right);
              return {
                width: 0,
                height: 0,
                top: i.bottom,
                bottom: i.bottom,
                left: s,
                right: s,
              };
            },
            offset: [0, r],
          }),
            this.tippyInstance.show());
        }
      },
      createButton: function () {
        if (!this.$messageTextContainer.length) return !1;
        var e = this.$messageTextContainer.closest(`.message`);
        ((this.$button = r(`<div id="QuoteSelected"></div>`).attr(
          `data-quote`,
          this.$messageTextContainer.closest(`li`).attr(`id`),
        )),
          this.$button.data(`XenForo.SelectQuotable`, this));
        var t = e.find(`a.MultiQuoteControl`).first().clone();
        t.length &&
          (t
            .addClass(`QuoteSelected`)
            .attr(`title`, ``)
            .on(`QuoteSelectedClicked`, r.context(this, `buttonClicked`)),
          t.find(`span.symbol`).text(r(`.MultiQuoteWatcher`).data(`add`)),
          new o.MultiQuoteControl(t),
          this.$button.append(t),
          this.$button.append(document.createTextNode(` | `)));
        var n = e.find(`a.ReplyQuote`).clone();
        (n
          .addClass(`QuoteSelected`)
          .attr(`title`, ``)
          .attr(
            `data-quote`,
            this.$messageTextContainer.closest(`li`).attr(`id`),
          )
          .on(`QuoteSelectedClicked`, r.context(this, `buttonClicked`)),
          new o.QuickReplyTrigger(n),
          this.$button.append(n));
        var i = r(
          `<a href="javascript:" class="QuoteSelected SelectTranslate"></a>`,
        )
          .text(
            (o.phrases &&
              (o.phrases.translate_selected_text ||
                o.phrases.translate_to_x)) ||
              `Translate`,
          )
          .on(`click`, r.context(this, `translateButtonClicked`));
        ((this.$translateWrap = r(`<span></span>`)
          .append(document.createTextNode(` | `))
          .append(i)),
          this.$button.append(this.$translateWrap));
        var a = this;
        this.tippyInstance = tippy(document.body, {
          content: this.$button[0],
          placement: `bottom`,
          interactive: !0,
          trigger: `manual`,
          hideOnClick: !1,
          theme: `quote-selected`,
          allowHTML: !0,
          arrow: !0,
          zIndex: 5560,
          offset: [0, 5],
          animation: `shift-toward`,
          appendTo: document.body,
          getReferenceClientRect: () => new DOMRect(),
          onClickOutside: function () {
            a.hideQuoteButton();
          },
        });
        var s = r(window).width();
        (r(window).on(`resize.SelectQuotable`, function () {
          var e = r(window).width();
          e != s && ((s = e), a._handleSelection());
        }),
          r(document).on(`XFOverlay.SelectQuotable`, function () {
            (a.hideQuoteButton(), window.getSelection().collapseToEnd());
          }));
      },
      hideQuoteButton: function () {
        (this.tippyInstance !== void 0 &&
          (this.tippyInstance.hide(),
          this.tippyInstance.destroy(),
          delete this.tippyInstance),
          this.$button !== void 0 &&
            (this.$button.remove(), delete this.$button),
          delete this.$translateWrap,
          (this.translating = !1),
          (this.translationShown = !1),
          clearTimeout(this.translateTimer),
          r(window).off(`resize.SelectQuotable`),
          r(document).off(`XFOverlay.SelectQuotable`));
      },
      _isTranslatableSelection: function (e) {
        if (((e = (e || ``).trim()), !e)) return !1;
        var t = (e.match(/\p{sc=Cyrillic}/gu) || []).length,
          n = (
            e.match(
              /[\p{sc=Han}\p{sc=Hiragana}\p{sc=Katakana}\p{sc=Hangul}\p{sc=Thai}\p{sc=Arabic}]/gu,
            ) || []
          ).length;
        if (o.visitor.language_id == 1) return t > 0 || n > 0;
        if (n > 0) return !0;
        if (t === 0) return /[\p{L}_]/u.test(e);
        var r = (e.match(/\p{sc=Latin}/gu) || []).length;
        return r > t && r > 10;
      },
      translateButtonClicked: function (e) {
        if (
          (e.preventDefault(), !(this.translating || this.$button === void 0))
        ) {
          var t = (this.$button.data(`quote-text`) || ``).trim();
          if (t) {
            var n = o.visitor.language_id == 1,
              r = this,
              i = function () {
                ((r.translating = !1), clearTimeout(r.translateTimer));
              };
            ((this.translating = !0),
              this.showTranslateSkeleton(t),
              clearTimeout(this.translateTimer),
              (this.translateTimer = setTimeout(function () {
                r.translating && ((r.translating = !1), r.restoreButtons());
              }, 32e3)),
              o.ajax(
                `/misc/translate`,
                { source: n ? `ru` : `en`, target: n ? `en` : `ru`, text: t },
                function (e) {
                  if ((i(), e.success !== void 0 && !e.success)) {
                    (e.error && o.alert(e.error), r.restoreButtons());
                    return;
                  }
                  if (o.hasResponseError(e)) {
                    r.restoreButtons();
                    return;
                  }
                  r.showTranslation(e.result);
                },
                {
                  onError: function () {
                    (i(), r.restoreButtons());
                  },
                },
              ));
          }
        }
      },
      showTranslateSkeleton: function (e) {
        if (this.tippyInstance !== void 0) {
          var t = Math.min(6, Math.max(1, Math.ceil(e.length / 45))),
            n = r(`<div class="selectTranslateSkeleton"></div>`).css({
              position: `relative`,
              overflow: `hidden`,
              width: `260px`,
              maxWidth: `80vw`,
              height: t * 14 + `px`,
              background: `linear-gradient(90deg, #404040 0%, #393939 100%)`,
              borderRadius: `6px`,
              cursor: `default`,
            });
          (r(`<div></div>`)
            .css({
              position: `absolute`,
              top: 0,
              left: `-150px`,
              width: `350px`,
              height: `100%`,
              background: `linear-gradient(90deg, transparent, rgba(255, 255, 255, 0.1), transparent)`,
              animation: `skeleton-loading 1.5s infinite`,
            })
            .appendTo(n),
            this.tippyInstance.setContent(n[0]));
        }
      },
      restoreButtons: function () {
        (this.tippyInstance !== void 0 &&
          this.$button !== void 0 &&
          this.tippyInstance.setContent(this.$button[0]),
          (this.translationShown = !1));
      },
      showTranslation: function (e) {
        if (!(this.tippyInstance === void 0 || !e)) {
          var t = r(`<div class="selectTranslateResult"></div>`)
            .text(e)
            .css({
              maxWidth: `350px`,
              whiteSpace: `pre-wrap`,
              overflowWrap: `break-word`,
              textAlign: `left`,
            });
          (this.tippyInstance.setContent(t[0]), (this.translationShown = !0));
        }
      },
      getSelectionHtml: function (e) {
        var t = document.createElement(`div`),
          n,
          r;
        for (n = 0, r = e.rangeCount; n < r; n++)
          t.appendChild(e.getRangeAt(n).cloneContents());
        return this.prepareSelectionHtml(t.innerHTML);
      },
      prepareSelectionHtml: function (e) {
        return e;
      },
    }),
    (o.unparseBbCode = function (e) {
      var t = r(document.createElement(`div`));
      return (
        t.html(e),
        console.log(t.find(`.bbCodeQuote`).length),
        t.find(`.NoSelectToQuote`).each(function () {
          r(this).remove();
        }),
        r.each([`B`, `I`, `U`], function (e, n) {
          t.find(n).each(function () {
            r(this).replaceWith(
              `[` + n + `]` + r(this).html() + `[/` + n + `]`,
            );
          });
        }),
        t.find(`.bbCodeQuote`).each(function () {
          var e = r(this),
            t = e.find(`.quote`);
          t.length
            ? e.replaceWith(`<div>[QUOTE]` + t.html() + `[/QUOTE]</div>`)
            : t.find(`.quoteExpand`).remove();
        }),
        t.find(`.bbCodeCode, .bbCodeHtml, .bbCodePHP`).each(function () {
          var e = r(this),
            t = r(this).find(`div.type`).first().text(),
            n = `pre`;
          (t !== `` && (t = t.replace(/^(.+):$/, `$1`)),
            e.is(`.bbCodePHP`) && (n = `code`),
            e.replaceWith(e.find(n).first().attr(`data-type`, t)));
        }),
        t.find(`div[style*="text-align"]`).each(function () {
          var e = r(this).css(`text-align`).toUpperCase();
          r(this).replaceWith(`[` + e + `]` + r(this).html() + `[/` + e + `]`);
        }),
        t.find(`.bbCodeSpoilerContainer`).each(function () {
          var e, t, n, i;
          if (
            ((e = r(this).find(`.bbCodeSpoilerButton`)),
            e.length && ((t = e.data(`target`)), t))
          ) {
            i = r(this).find(t).html();
            var a = r(this).find(`.SpoilerTitle`);
            ((n = a.length ? `="` + a.text() + `"` : ``),
              r(this).replaceWith(`[SPOILER` + n + `]` + i + `[/SPOILER]`));
          }
        }),
        console.info(`HTML to be sent: %s`, t.html()),
        t.html()
      );
    }),
    (o.Timer = function (e) {
      let t = e.data(`end-date`),
        n = e.data(`end-phrase`),
        r = e.data(`insert-icon`) ? !!e.data(`insert-icon`) : !0,
        i = e.get(0);
      if (!i) return;
      let a = new Intl.RelativeTimeFormat(o.visitor.language_code),
        s = `<span class="Svg-Icon"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none"><path d="M20.4532 12.8928C20.1754 15.5027 18.6967 17.9484 16.2497 19.3612C12.1842 21.7084 6.98566 20.3155 4.63845 16.25L4.38845 15.817M3.54617 11.1071C3.82397 8.49723 5.30276 6.05151 7.74974 4.63874C11.8152 2.29153 17.0138 3.68447 19.361 7.74995L19.611 8.18297M3.49316 18.0659L4.22522 15.3339L6.95727 16.0659M17.0422 7.93398L19.7743 8.66603L20.5063 5.93398M11.9997 7.49995V12L14.4997 13.5" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path></svg></span>`;
      !e.find(`.Svg-Icon`).length &&
        (e.hasClass(`HasTimerIcon`) || e.hasClass(`HasTimerDisabledIcon`)) &&
        e.prepend(s);
      let c = 1e3,
        l = performance.timeOrigin / c - o.serverTimeInfo.now,
        u = () => {
          let i = Math.ceil(t - Date.now() / c + l);
          if (i <= 0) {
            if (e.hasClass(`TimerRemoveOnEnd`)) e.parent().xfRemove();
            else {
              let t = e.find(`.Svg-Icon`).first();
              t.length
                ? e
                    .html(``)
                    .append(t)
                    .append(` ` + n)
                : e.html(
                    `${r ? `<span class="Svg-Icon"><svg xmlns="http://www.w3.org/2000/svg" width="24" height="24" viewBox="0 0 24 24" fill="none"><path d="M20.4532 12.8928C20.1754 15.5027 18.6967 17.9484 16.2497 19.3612C12.1842 21.7084 6.98566 20.3155 4.63845 16.25L4.38845 15.817M3.54617 11.1071C3.82397 8.49723 5.30276 6.05151 7.74974 4.63874C11.8152 2.29153 17.0138 3.68447 19.361 7.74995L19.611 8.18297M3.49316 18.0659L4.22522 15.3339L6.95727 16.0659M17.0422 7.93398L19.7743 8.66603L20.5063 5.93398M11.9997 7.49995V12L14.4997 13.5" stroke-width="2" stroke-linecap="round" stroke-linejoin="round"></path></svg></span>` : ``}${n}`,
                  );
            }
            return;
          }
          let o = Math.floor(i / (24 * 60 * 60)),
            s = Math.floor((i % (24 * 60 * 60)) / (60 * 60)),
            d = Math.floor((i % (60 * 60)) / 60),
            f = Math.floor(i % 60),
            p = ``;
          (o && (p += o + a.formatToParts(o, `day`)[2].value + ` `),
            s && (p += s + a.formatToParts(s, `hour`)[2].value + ` `),
            d && (p += d + a.formatToParts(d, `minute`)[2].value + ` `),
            !o && f && (p += f + a.formatToParts(f, `second`)[2].value));
          let m = e.find(`.Svg-Icon`).first();
          (e.html(``),
            e.append(m),
            e.append(` ` + p.trim()),
            setTimeout(u, Math.max(100, c - (Date.now() % c))));
        };
      u();
    }),
    o.register(`#QuickReply`, `XenForo.QuickReply`),
    o.register(
      `a.ReplyQuote, a.MultiQuote, a.QuoteSelected`,
      `XenForo.QuickReplyTrigger`,
    ),
    o.register(`form.InlineMessageEditor`, `XenForo.InlineMessageEditor`),
    o.register(`a.MessageLoader`, `XenForo.MessageLoader`),
    o.register(`a.NewMessageLoader`, `XenForo.NewMessageLoader`),
    o.register(`form.PollVoteForm`, `XenForo.PollVoteForm`),
    o.register(`.MultiQuoteWatcher`, `XenForo.MultiQuote`),
    o.register(`a.MultiQuoteControl`, `XenForo.MultiQuoteControl`),
    o.register(`a.MultiQuoteRemove`, `XenForo.MultiQuoteRemove`),
    o.register(`.Sortable`, `XenForo.Sortable`),
    o.register(`.SelectQuotable`, `XenForo.SelectQuotable`),
    o.register(`.Timer`, `XenForo.Timer`));
});
l();
