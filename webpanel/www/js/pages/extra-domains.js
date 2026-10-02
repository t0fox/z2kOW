import { renderDomainList } from "../core/domain-list-editor.js";
import { apiGet, apiPost, errHtml, toastErr } from "../core/api.js";
import { $app, _icons, escapeHtml, skeletonLines } from "../core/dom.js";
import { _newLoad, _stale } from "../core/loadorder.js";
import { toast } from "../core/toast.js";

// «Дополнительные домены» — одна страница, две подвкладки. Вторая появляется
// только при включённом автохостлисте: пока он выключен, показывать там
// нечего, а пустая вкладка читается как «функция сломана».
//
// Состояние тумблера берём из /status, а не из адреса: страницу открывают по
// прямой ссылке, и вкладка обязана быть честной сразу, без промежуточного
// «есть/нет».
function extraTabs(activeId) {
  return '<div class="strat-tabs" role="tablist" aria-label="Виды доменов">' +
    '<a href="#/extra-domains" class="strat-tab' + (activeId === "own" ? " active" : "") +
      '" role="tab" aria-selected="' + (activeId === "own") + '" title="Домены, которые вы добавили вручную">Свои</a>' +
    '<a href="#/autohostlist" class="strat-tab' + (activeId === "auto" ? " active" : "") +
      '" role="tab" aria-selected="' + (activeId === "auto") +
      '" title="Домены, которые автохостлист определил как заблокированные сам">Автохостлист</a>' +
    '</div>';
}

function extraShell(activeId, bodyHtml, autoOn) {
  const showTabs = Boolean(autoOn || activeId === "auto");
  return '<h1 class="page-title">Дополнительные домены</h1>' +
    '<div id="extra-domain-tabs-slot">' + (showTabs ? extraTabs(activeId) : "") + '</div>' +
    '<p class="desc strat-tabhint" id="extra-domain-tab-hint"' + (showTabs ? "" : " hidden") + '>' +
      (activeId === "auto"
        ? "Домены, которые автохостлист определил как заблокированные сам"
        : "Домены, которые вы добавили вручную") + '</p>' +
    bodyHtml;
}

function showExtraDomainTabs(activeId) {
  const slot = document.getElementById("extra-domain-tabs-slot");
  const hint = document.getElementById("extra-domain-tab-hint");
  if (!slot || !hint) return;
  slot.innerHTML = extraTabs(activeId);
  hint.hidden = false;
}

export async function renderAutohostlistDomains() {
  $app.innerHTML = await extraShell("auto", `
    <div class="card">
      <h3>Найдено автохостлистом</h3>
      <p class="desc">
        Автохостлист сам определяет, какие сайты у вас блокируются, и добавляет их
        в обработку. Здесь видно, что он набрал. Список сохраняется и переживает
        обновление основного списка блокировок.
        Если сюда попал сайт, которому обход не нужен — удалите его,
        и он больше не вернётся.
      </p>
      <ul class="wl-list" id="ah-list">${skeletonLines(5)}</ul>
    </div>
  `);
  loadAutohostlistDomains();
}

async function loadAutohostlistDomains() {
  const list = document.getElementById("ah-list");
  if (!list) return;
  const seq = _newLoad("autohostDomains");
  try {
    const d = await apiGet("/autohostlist-domains");
    if (_stale("autohostDomains", seq)) return;
    if (!d.domains.length) {
      list.innerHTML = `<li class="wl-empty">(пока ничего не найдено)</li>`;
      return;
    }
    list.innerHTML = d.domains.map(dom => `
      <li><span>${escapeHtml(dom)}</span><button class="btn-icon" title="Удалить" aria-label="Удалить ${escapeHtml(dom)}" data-del="${escapeHtml(dom)}">${_icons.close}</button></li>
    `).join("");
    list.querySelectorAll("button[data-del]").forEach(btn => {
      btn.addEventListener("click", () => ahDelete(btn.dataset.del));
    });
  } catch (e) {
    if (_stale("autohostDomains", seq)) return;
    list.innerHTML = `<li style="color:var(--bad)">${errHtml(e)}</li>`;
  }
}

async function ahDelete(domain) {
  try {
    await apiPost("/autohostlist-domains/delete", { domain });
    toast("Удалено");
    loadAutohostlistDomains();
  } catch (e) {
    toastErr("Ошибка: ", e);
  }
}

export function renderExtraDomains() {
  const render = renderDomainList({
    endpoint: "/extra-domains",
    shell: html => extraShell("own", html, false),
    title: "Обрабатывать эти сайты",
    description: 'Добавьте сайты, которым нужен обход блокировок в дополнение к основным спискам. <code>example.com</code> включает все поддомены. Домены, уже покрытые другими списками, повторно добавлять не нужно.',
    deleteHint: "Эти сайты будут удалены из дополнительного списка. Обработка по другим спискам сохранится.",
  });
  apiGet("/status").then(status => {
    if (String(status?.toggles?.autohostlist || "0") === "1") showExtraDomainTabs("own");
  }).catch(() => {});
  return render;
}
