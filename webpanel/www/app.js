// z2k webpanel — точка входа. Вся работа живёт в js/, здесь только запуск.
//
// ПОЧЕМУ ES-МОДУЛИ, А НЕ НЕСКОЛЬКО <script>. Панель отдаётся lighttpd с
// заголовком `Cache-Control: no-cache, must-revalidate` и ETag (см.
// webpanel/lighttpd.conf), поэтому каждый файл перед использованием
// перепроверяется — устаревший подмодуль подсунуться не может, и версионировать
// импорты не нужно. А главное: при обычных <script> все объявления попадают в
// одну общую область видимости, и `no-undef` в линтере пришлось бы кормить
// списком из 65 имён руками — то есть своими руками сломать ту страховку, ради
// которой линтер и заводился. С модулями область видимости пофайловая, и
// правило работает в полную силу, ловя ещё и неиспользуемые импорты.
//
// СБОРКИ ПО-ПРЕЖНЕМУ НЕТ. Файлы отдаются как есть: панель обязана открываться
// на роутере без интернета и без тулчейна.
//
// Порядок разрезания задан не на глаз: связность измерена по AST (378
// обращений в ядро против 92 между фичами), слои идут только вниз, граф
// ациклический. Точка входа зависит от оболочки и маршрутизатора — и всё.
import { initDrawer, initSidebar, initTheme } from "./js/chrome.js";
import { navigate, refreshRouteTitle, setRouteBrandName } from "./js/router.js";
import { apiGet } from "./js/core/api.js";
import { applyCapabilities } from "./js/core/loadorder.js";
import { initChosenSelects } from "./js/core/chosen-select.js";

initTheme();
initSidebar();
initDrawer();
initChosenSelects();

window.__z2kRefreshRouteTitle = refreshRouteTitle;
window.__z2kSetRouteBrandName = setRouteBrandName;
if (!location.hash) location.hash = "#/dashboard";
navigate();

// Visual identity is optional. A content blocker may reject this separate
// module script; the static profile bootstrap in index.html and route graph
// continue independently.
const identityScript = document.createElement("script");
identityScript.type = "module";
identityScript.src = "/js/core/identity.js?v=p-86.1";
identityScript.dataset.optionalPanelModule = "true";
identityScript.onerror = () => {};
document.head.appendChild(identityScript);

// Platform capabilities для nav (Stage 6): status is an enhancement, never a
// prerequisite for the first route or OpenWrt identity.
apiGet("/status").then((s) => {
  applyCapabilities(s);
  window.__z2kBrandStatus = s;
  try {
    if (typeof window.__z2kApplyBranding === "function") window.__z2kApplyBranding(s);
  } catch (_) { /* optional visual identity must not affect route rendering */ }
}).catch(() => {});
