import { closeNavMore } from "./chrome.js";
import { $app, $nav, escapeHtml } from "./core/dom.js";
import { renderCredits, renderStrategies } from "./pages/credits.js";
import { renderDashboard } from "./pages/dashboard.js";
import { renderDiag } from "./pages/diag.js";
import { renderExcludeAddresses, renderExcludeDomains } from "./pages/exclude.js";
import { renderAutohostlistDomains, renderExtraDomains } from "./pages/extra-domains.js";
import { renderState } from "./pages/strategies.js";
import { renderStrategyPick } from "./pages/strategy-pick.js";
import { renderToggles } from "./pages/toggles.js";
import { renderWarp } from "./pages/warp.js";

const routes = {
  dashboard: renderDashboard,
  toggles: renderToggles,
  warp: renderWarp,
  // «Исключения» — одна страница с двумя подвкладками. Два маршрута, потому
  // что подвкладка обязана быть адресом: её можно дать ссылкой и она
  // переживает перезагрузку страницы. Имена маршрутов оставлены прежними,
  // чтобы старая закладка открывала ровно то, что на ней лежало: #/whitelist
  // — «Домены», #/exclude — «Адреса».
  whitelist: renderExcludeDomains,
  exclude: renderExcludeAddresses,
  "extra-domains": renderExtraDomains,
  // Подвкладка «Автохостлист» — отдельным маршрутом по той же причине, что и
  // у «Исключений»: на неё можно дать ссылку и она переживает перезагрузку.
  autohostlist: renderAutohostlistDomains,
  state: renderState,
  pick: renderStrategyPick,
  strategies: renderStrategies,
  diag: renderDiag,
  credits: renderCredits,
};

// Active route highlight для всех `<a>` в #nav (primary + overflow).
// Highlight «...» кнопки делается через CSS :has() — не нужен JS sync.
// Page title — per-route, формат "PageName · Z2K" (GitHub/Linear style).
const ROUTE_TITLES = {
  dashboard:       "Дашборд",
  toggles:         "Режимы",
  warp:            "WARP",
  // Обе подвкладки «Исключений» — один раздел, значит и один заголовок.
  whitelist:       "Исключения",
  exclude:         "Исключения",
  "extra-domains": "Доп. домены",
  // Подвкладка «Автохостлист» использует заголовок того же раздела.
  autohostlist:   "Доп. домены",
  // «Стратегии» — одна дверь, два вида внутри. Маршрут `state` остался жив
  // ради старых ссылок и закладок: он открывает ту же страницу на вкладке
  // «Автоподбор». Поэтому и заголовок у него тот же — раньше здесь
  // стояло «Rotator», из-за чего один раздел назывался четырьмя разными
  // именами (меню, маршрут, заголовок страницы, README).
  state:           "Стратегии",
  pick:            "Стратегии",
  strategies:      "Стратегии",
  diag:            "Диагностика",
  credits:         "Благодарности",
};

// Маршрут → пункт меню, который он подсвечивает. Только для маршрутов,
// которые являются подвкладками чужого раздела.
const NAV_OF_ROUTE = {
  state: "strategies",
  pick: "strategies",
  whitelist: "exclude",
};

let _activeRoute = "dashboard";
let _navigationToken = 0;

// Route titles have one owner; the suffix follows the active common brand
// profile and defaults to the upstream Z2K identity.
export function refreshRouteTitle() {
  const pageTitle = ROUTE_TITLES[_activeRoute] || "Z2K";
  const brandName = window.__z2kBrandName || "Z2K";
  document.title = pageTitle + " · " + brandName;
}

export function setRouteBrandName(name) {
  const value = typeof name === "string" ? name.trim() : "";
  const hasControlCharacter = Array.from(value).some(character => {
    const code = character.charCodeAt(0);
    return code <= 31 || code === 127;
  });
  if (value && value.length <= 64 && !hasControlCharacter) {
    window.__z2kBrandName = value;
  } else {
    window.__z2kBrandName = "Z2K";
  }
  refreshRouteTitle();
}

function showRouteFailure(error, token) {
  if (token !== _navigationToken) return;
  const detail = error && error.message ? error.message : String(error || "unknown error");
  $app.innerHTML = '<section class="card" data-ui-fatal role="alert">' +
    '<h1 class="page-title">Не удалось загрузить страницу</h1>' +
    '<p class="desc">Обновите страницу. Подробность: ' + escapeHtml(detail) + '</p></section>';
}

export function navigate() {
  const hash = location.hash.replace(/^#\//, "") || "dashboard";
  const name = routes[hash] ? hash : "dashboard";
  _activeRoute = name;
  const token = ++_navigationToken;
  // Маршрутов больше, чем пунктов меню: подвкладка — тоже адрес, но своего
  // пункта у неё нет. Без подмены переход на такой адрес не подсвечивал бы
  // в меню ничего.
  const navName = NAV_OF_ROUTE[name] || name;
  for (const a of $nav.querySelectorAll("a")) {
    a.classList.toggle("active", a.dataset.route === navName);
  }
  // Имя экрана в DOM: по нему стилям видно, где мы находимся. Нужно
  // ровно одному правилу — экран стратегий снимает кап ширины, потому что
  // это таблица на сотни строк, а не текст.
  document.body.setAttribute("data-page", name);
  refreshRouteTitle();
  closeNavMore();
  $app.innerHTML = '<section class="card" aria-live="polite">Загрузка…</section>';
  try {
    const result = routes[name]();
    if (result && typeof result.catch === "function") {
      result.catch(error => showRouteFailure(error, token));
    }
  } catch (error) {
    showRouteFailure(error, token);
  }
}

window.addEventListener("hashchange", navigate);
