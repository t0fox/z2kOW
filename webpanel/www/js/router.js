import { closeNavMore } from "./chrome.js";
import { $app, $nav, escapeHtml } from "./core/dom.js";
import { renderStrategies } from "./pages/credits.js";
import { renderCreditsPage } from "./pages/credits-openwrt.js";
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
  credits: renderCreditsPage,
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
  autohostlist: "extra-domains",
};

let _activeRoute = routes[location.hash.replace(/^#\//, "")] ? location.hash.replace(/^#\//, "") : "dashboard";
let _navigationToken = 0;
let _previousTabPosition = null;
const _scrollWatchedTabs = new WeakSet();


function currentTabPosition() {
  const tabs = $app.querySelector(".strat-tabs");
  const active = tabs && tabs.querySelector('.strat-tab[aria-selected="true"], .strat-tab.active');
  if (!active) return null;
  return {
    left: active.offsetLeft - tabs.scrollLeft,
    top: active.offsetTop,
    width: active.offsetWidth,
    height: active.offsetHeight,
  };
}

function writeTabPosition(tabs, position) {
  tabs.style.setProperty("--tab-left", position.left + "px");
  tabs.style.setProperty("--tab-top", position.top + "px");
  tabs.style.setProperty("--tab-width", position.width + "px");
  tabs.style.setProperty("--tab-height", position.height + "px");
}

function syncTabIndicator(previous, revealActive = true) {
  const tabs = $app.querySelector(".strat-tabs");
  const active = tabs && tabs.querySelector('.strat-tab[aria-selected="true"], .strat-tab.active');
  if (!tabs || !active) {
    _previousTabPosition = null;
    return;
  }
  if (revealActive) {
    const activeLeft = active.offsetLeft - tabs.scrollLeft;
    const activeRight = activeLeft + active.offsetWidth;
    if (activeLeft < 0) tabs.scrollLeft = active.offsetLeft;
    else if (activeRight > tabs.clientWidth) tabs.scrollLeft = active.offsetLeft + active.offsetWidth - tabs.clientWidth;
  }
  if (!_scrollWatchedTabs.has(tabs)) {
    _scrollWatchedTabs.add(tabs);
    tabs.addEventListener("scroll", () => requestAnimationFrame(() => {
      if (tabs.isConnected) syncTabIndicator(null, false);
    }), { passive: true });
  }
  const target = {
    left: active.offsetLeft - tabs.scrollLeft,
    top: active.offsetTop,
    width: active.offsetWidth,
    height: active.offsetHeight,
  };
  const targetKey = Object.values(target).join(":");
  if (tabs.dataset.tabIndicatorTarget === targetKey) return;
  tabs.dataset.tabIndicatorTarget = targetKey;
  if (previous && Object.values(previous).some((value, index) => value !== Object.values(target)[index])) {
    writeTabPosition(tabs, previous);
    requestAnimationFrame(() => {
      if (tabs.isConnected) writeTabPosition(tabs, target);
    });
  } else {
    writeTabPosition(tabs, target);
  }
  _previousTabPosition = target;
}

// Tabs can be rendered after an async feature-status response (for example,
// the optional Autohostlist tab). Follow DOM insertion as the source component
// does with a MutationObserver, and recalculate on resize.
const _tabObserver = new MutationObserver(() => {
  const tabs = $app.querySelector(".strat-tabs");
  if (tabs && !tabs.dataset.tabIndicatorTarget) syncTabIndicator(_previousTabPosition);
});
_tabObserver.observe($app, { childList: true, subtree: true });
window.addEventListener("resize", () => requestAnimationFrame(() => syncTabIndicator(null)));

// Route titles have one owner; the tab starts with the active brand so it stays
// visible when the browser shortens the title.
export function refreshRouteTitle() {
  const pageTitle = ROUTE_TITLES[_activeRoute] || "z2kOW";
  const brandName = window.__z2kBrandName || "z2kOW";
  document.title = brandName + " · " + pageTitle;
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
    window.__z2kBrandName = "z2kOW";
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
  const previousTabPosition = currentTabPosition();
  _previousTabPosition = previousTabPosition;
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
    syncTabIndicator(previousTabPosition);
    if (result && typeof result.catch === "function") {
      result.then(() => {
        if (token === _navigationToken) syncTabIndicator(previousTabPosition);
      }).catch(error => showRouteFailure(error, token));
    }
  } catch (error) {
    showRouteFailure(error, token);
  }
}

window.addEventListener("hashchange", navigate);
