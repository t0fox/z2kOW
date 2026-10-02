import { $app, _icons, escapeHtml } from "../core/dom.js";
import { openwrtCredits } from "../data/openwrt-credits.js";
import { renderCredits } from "./credits.js";

function renderLocalCredits() {
  if (!Array.isArray(openwrtCredits) || openwrtCredits.length === 0) {
    return '<p class="credits-openwrt__empty" data-credit-empty>Участники появятся здесь после подтверждённого вклада в z2kOW на OpenWrt.</p>';
  }

  const cards = openwrtCredits.map(credit => {
    if (!credit || typeof credit.name !== "string" || !credit.name.trim()
        || typeof credit.role !== "string" || !credit.role.trim()) return "";
    const description = typeof credit.description === "string" && credit.description.trim()
      ? `<p class="desc">${escapeHtml(credit.description.trim())}</p>` : "";
    return `<article class="card credits-card openwrt-credit-card">
      <div class="credits-badge openwrt-credit-badge">${escapeHtml(credit.role.trim())}</div>
      <div class="credits-name">${escapeHtml(credit.name.trim())}</div>
      ${description}
    </article>`;
  }).filter(Boolean).join("");

  return cards
    ? `<div class="credits-grid openwrt-credits-grid">${cards}</div>`
    : '<p class="credits-openwrt__empty" data-credit-empty>Участники появятся здесь после подтверждённого вклада в z2kOW на OpenWrt.</p>';
}

export function renderCreditsPage() {
  // Let upstream own the contributor data and cards. Move its rendered grid
  // intact into a platform-owned presentation wrapper.
  renderCredits();
  const upstreamGrid = $app.querySelector(".credits-grid");

  $app.innerHTML = `
    <h1 class="page-title">Благодарности</h1>
    <section class="card credits-openwrt" id="credits-openwrt" aria-labelledby="credits-openwrt-title">
      <h2 class="credits-openwrt__title" id="credits-openwrt-title">z2kOW / OpenWrt</h2>
      <p class="credits-intro">Люди, которые помогают тестировать и поддерживать z2kOW на OpenWrt.</p>
      ${renderLocalCredits()}
    </section>
    <details class="credits-upstream" id="credits-upstream">
      <summary class="btn btn-secondary">
        <span>Upstream z2k / Keenetic</span>
        <span class="credits-upstream__arrow">${_icons.chevronDown}</span>
      </summary>
      <div class="credits-upstream__body">
        <p class="credits-upstream__description">Благодарности оригинального проекта z2k. Указанные здесь тестирование и вклад относятся к upstream/Keenetic и не означают тестирование z2kOW на OpenWrt.</p>
        <div data-upstream-grid></div>
      </div>
    </details>
  `;

  const upstreamHost = $app.querySelector("[data-upstream-grid]");
  if (upstreamGrid && upstreamHost) upstreamHost.appendChild(upstreamGrid);
}
