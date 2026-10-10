import { $app } from "../core/dom.js";

const DONATION_URL = "https://pay.cloudtips.ru/p/34db013d";
const WIDGET_URL = "https://pay.cloudtips.ru/p/5e6571c5";
const WIDGET_LAYOUT_ID = "5e6571c5";
const WIDGET_SCRIPT_URL = "https://widget.cloudtips.ru/bundle.js";

// The rest of the router panel does not depend on CloudTips. Only request its
// script after a deliberate click in the donations route.
let widgetLoadPromise;
function loadCloudTipsWidget() {
  if (window.ctips?.CloudTipsSiteWidget) return Promise.resolve();
  if (!widgetLoadPromise) {
    widgetLoadPromise = new Promise((resolve, reject) => {
      const script = document.createElement("script");
      script.src = WIDGET_SCRIPT_URL;
      script.async = true;
      script.onload = () => window.ctips?.CloudTipsSiteWidget
        ? resolve()
        : reject(new Error("CloudTips widget API unavailable"));
      script.onerror = () => reject(new Error("CloudTips widget script unavailable"));
      document.head.appendChild(script);
    }).catch(error => {
      widgetLoadPromise = null; // retry is possible after a temporary network failure
      throw error;
    });
  }
  return widgetLoadPromise;
}

export function renderDonations() {
  $app.innerHTML = `
    <h1 class="page-title">Поддержать z2kOW</h1>
    <section class="card donation-card">
      <div class="donation-heading">
        <h2>Донаты</h2>
        <p class="desc">
          Если z2kOW оказался полезен, проект можно поддержать через CloudTips.
          Поддержка добровольная и не открывает платные функции или отдельный доступ.
        </p>
      </div>

      <div class="donation-layout">
        <div class="donation-direct">
          <a class="donation-qr-link" href="${DONATION_URL}" target="_blank" rel="noopener noreferrer"
             aria-label="Открыть страницу поддержки z2kOW в CloudTips">
            <img class="donation-qr" src="/assets/openwrt/cloudtips-donation.svg"
                 width="280" height="280" alt="QR-код CloudTips для поддержки z2kOW">
          </a>
          <a class="btn btn-primary donation-open" href="${DONATION_URL}" target="_blank"
             rel="noopener noreferrer">Открыть CloudTips</a>
          <div class="donation-url">pay.cloudtips.ru/p/34db013d</div>
        </div>

        <div class="donation-widget">
          <div class="donation-widget-toolbar">
            <div class="donation-widget-caption">
              <strong>CloudTips</strong>
              <span>Форма поддержки z2kOW</span>
            </div>
            <button class="btn btn-primary donation-modal-open" type="button">
              Открыть виджет
            </button>
          </div>
          <p class="donation-widget-status" role="status" aria-live="polite"></p>
          <iframe
            src="${WIDGET_URL}"
            title="Форма пожертвования CloudTips для z2kOW"
            sandbox="allow-scripts allow-same-origin allow-forms allow-popups allow-popups-to-escape-sandbox allow-top-navigation-by-user-activation"
            allow="payment"
            loading="lazy"
            referrerpolicy="strict-origin-when-cross-origin"></iframe>
          <div class="donation-widget-fallback">
            Если форма не отображается, используйте кнопку «Открыть виджет» или
            <a href="${WIDGET_URL}" target="_blank" rel="noopener noreferrer">откройте её в новой вкладке</a>.
          </div>
        </div>
      </div>

      <p class="donation-note">
        CloudTips загружается только на вкладке «Донаты». Оплата проходит на стороне CloudTips.
      </p>
    </section>
  `;

  const button = $app.querySelector(".donation-modal-open");
  const status = $app.querySelector(".donation-widget-status");
  button.addEventListener("click", async () => {
    if (button.disabled) return;
    button.disabled = true;
    status.textContent = "Загружаем виджет CloudTips…";
    try {
      await loadCloudTipsWidget();
      // Do not open the widget over another route after an asynchronous load.
      if (!button.isConnected) return;
      new window.ctips.CloudTipsSiteWidget().open({ layoutid: WIDGET_LAYOUT_ID });
      status.textContent = "";
    } catch {
      if (button.isConnected) {
        status.textContent = "Виджет недоступен. Используйте прямую ссылку ниже.";
      }
    } finally {
      if (button.isConnected) button.disabled = false;
    }
  });
}
