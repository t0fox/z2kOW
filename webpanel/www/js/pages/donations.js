import { $app } from "../core/dom.js";

const DONATION_URL = "https://donation.streamiverse.io/t0fox";
const WIDGET_URL = "https://donation.streamiverse.io/widget/index.html?widget_id=6b3b146b-b238-434e-a0af-77ee64e53a58";

export function renderDonations() {
  $app.innerHTML = `
    <h1 class="page-title">Поддержать z2kOW</h1>
    <section class="card donation-card">
      <div class="donation-heading">
        <h2>Донаты</h2>
        <p class="desc">
          Если z2kOW оказался полезен, проект можно поддержать через Streamiverse.
          Поддержка добровольная и не открывает платные функции или отдельный доступ.
        </p>
      </div>

      <div class="donation-layout">
        <div class="donation-direct">
          <a class="donation-qr-link" href="${DONATION_URL}" target="_blank" rel="noopener noreferrer"
             aria-label="Открыть страницу поддержки z2kOW в Streamiverse">
            <img class="donation-qr" src="/assets/openwrt/streamiverse-donation.svg"
                 width="280" height="280" alt="QR-код Streamiverse для поддержки z2kOW">
          </a>
          <a class="btn btn-primary donation-open" href="${DONATION_URL}" target="_blank"
             rel="noopener noreferrer">Открыть Streamiverse</a>
          <div class="donation-url">donation.streamiverse.io/t0fox</div>
        </div>

        <div class="donation-widget">
          <iframe
            src="${WIDGET_URL}"
            title="Донаты z2kOW через Streamiverse"
            sandbox="allow-scripts allow-same-origin allow-forms allow-popups"
            loading="lazy"
            referrerpolicy="strict-origin-when-cross-origin"></iframe>
        </div>
      </div>

      <p class="donation-note">
        Внешний виджет загружается с donation.streamiverse.io только после открытия этой вкладки.
        Если он недоступен, используйте QR-код или кнопку выше.
      </p>
    </section>
  `;
}
