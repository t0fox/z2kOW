import { apiGet, apiPost, toastErr } from "../core/api.js";
import { $app, escapeHtml, skeletonBlocks } from "../core/dom.js";
import { refreshStatus } from "../core/loadorder.js";
import { toast } from "../core/toast.js";
import { JOB_FAIL, _updateGlobalUILock, awaitPanelBack, confirmTypedModal, jobOutcome, jobUnresolved, openJobModal, unresolvedMsg } from "../job.js";
import { renderStatsNotice } from "./telemetry.js";
import { refreshUpdateBanner } from "./update.js";

export async function renderDashboard() {
  $app.innerHTML = `
    <div id="update-banner" hidden></div>
    <div id="stats-notice" hidden></div>
    <h1 class="page-title">Дашборд</h1>
    <div class="card" id="status-card">
      <h3>Состояние</h3>
      <div class="status-grid" id="status-grid">${skeletonBlocks(7)}</div>
    </div>
    <div class="card" id="product-update-card">
      <h3>Обновление z2kOW</h3>
      <div id="product-update-state" class="desc">Проверяю подписанный выпуск…</div>
      <div id="product-update-release"></div>
      <div class="btn-row">
        <button class="btn" id="product-update-check">Проверить</button>
        <button class="btn btn-primary" id="product-update-start" disabled>Обновить z2kOW</button>
      </div>
    </div>
    <div class="card">
      <h3>Управление сервисом</h3>
      <p class="desc">Запуск, остановка и перезапуск nfqws2.</p>
      <div class="btn-row">
        <button class="btn btn-primary" data-svc="start" data-target="active">Запустить</button>
        <button class="btn" data-svc="restart" data-target="active">Перезапустить</button>
        <button class="btn btn-danger" data-svc="stop" data-target="stopped">Остановить</button>
      </div>
    </div>
    <!-- Обрыв на 16 КБ живёт отдельной системой: проба линии по опорным
         адресам, карта «сеть → имя», подстановка имени. В ротацию стратегий
         он не входит, поэтому и карточка своя, а не строка в состоянии.
         Строка состояния и под ней кнопка слева, как во всех карточках:
         плитки на всю ширину под три слова — пустое место, кнопка справа —
         единственная в панели; владелец снял и то и другое 11.09.2026. -->
    <div class="card" id="tcp16-card">
      <h3>Обрыв на 16 КБ</h3>
      <p class="desc">
        Сайт открывается, а страница обрывается на первых 16 КБ. Перебор
        стратегий это не лечит: z2k проверяет линию каждую ночь и подбирает
        сетям с обрывом другое имя.
      </p>
      <div class="tcp16-state" id="tcp16-state"><span class="tcp16-dot"></span><span class="tcp16-text">проверяю…</span></div>
      <div class="btn-row">
        <button class="btn btn-primary" id="tcp16-probe-btn">Пробить 16 КБ</button>
      </div>
    </div>
    <!-- ОТДЕЛЬНАЯ КАРТОЧКА, А НЕ ЧЕТВЁРТАЯ КНОПКА В РЯДУ ВЫШЕ.
         «Остановить» обратимо и делается каждый день; удаление необратимо и
         делается один раз. В одном ряду они получили бы одинаковый вес и
         отличались бы только подписью — так и промахиваются. -->
    <div class="card card-danger" id="uninstall-card">
      <h3>Удаление z2k</h3>
      <p class="desc">
        Снимает z2k с роутера полностью: сервис, правила обхода, настройки,
        подобранные стратегии и саму эту панель. Отмены нет — вернуть можно
        только установкой заново, с нуля.
      </p>
      <div class="btn-row">
        <button class="btn btn-danger" id="uninstall-btn">Удалить z2k</button>
      </div>
    </div>
  `;

  // querySelectorAll().forEach, а не querySelector().addEventListener — тем же
  // приёмом, что и обработчик [data-svc] выше. Пустая выборка просто ничего не
  // делает, а обращение к .addEventListener у null роняет весь рендер
  // страницы: дашборд собирается одной строкой innerHTML, и любой сторонний
  // рендер этой же разметки (тестовый харнесс, будущая подстраница) уронил бы
  // не кнопку, а экран целиком.
  $app.querySelectorAll("#uninstall-btn").forEach(btn => btn.addEventListener("click", async () => {
    const ok = await confirmTypedModal(
      "Удалить z2k с роутера",
      [
        "Будут удалены: служба обхода и её автозапуск, все правила iptables, " +
          "настройки, списки доменов и подобранные для них стратегии.",
        "Вместе с ними исчезнет и эта панель — страница перестанет отвечать " +
          "примерно на середине, и это нормальный конец, а не сбой.",
        "Интернет продолжит работать, но уже без обхода блокировок.",
      ],
      "УДАЛИТЬ",
      "Удалить z2k"
    );
    if (!ok) return;
    let resp;
    try {
      resp = await apiPost("/uninstall", { confirm: "УДАЛИТЬ" });
    } catch (e) {
      toastErr("Не удалось запустить удаление: ", e);
      return;
    }
    openJobModal("Удаление z2k", resp.job, {
      tolerateOutage: true,
      // Панель входит в удаляемое и обратно не поднимется. Без этого флага
      // опрос честно ждал бы её возвращения десять минут и всё это время
      // писал «ждём…» — про сервер, которого больше нет.
      expectGone: true,
    });
  }));

  refreshTcp16();
  $app.querySelectorAll("#tcp16-probe-btn").forEach(btn => btn.addEventListener("click", async () => {
    if (btn.disabled) return;
    btn.disabled = true;
    let resp;
    try {
      resp = await apiPost("/tcp16/probe");
    } catch (e) {
      btn.disabled = false;
      toastErr("Не удалось запустить пробу: ", e);
      return;
    }
    btn.disabled = false;
    openJobModal("Проба линии на обрыв 16 КБ", resp.job, {
      // Если ответ пробы сменил картину, она пересобирает конфиг и
      // перезапускает сервис — короткий обрыв панели тут штатный.
      tolerateOutage: true,
      onDone: (d) => {
        const outcome = jobOutcome(d);
        if (outcome === JOB_FAIL) toast("Проба не завершилась — подробности в журнале выше", "bad");
        // Проба могла перезапустить сервис; дождаться панели, потом читать.
        if (jobUnresolved(outcome)) awaitPanelBack().then(() => { refreshTcp16(); refreshStatus(); });
        else setTimeout(() => { refreshTcp16(); refreshStatus(); }, 500);
      },
    });
  }));

  $app.querySelectorAll("[data-svc]").forEach(btn => {
    btn.addEventListener("click", async () => {
      if (btn.disabled) return;
      const action = btn.dataset.svc;
      const titleByAction = { start: "Запуск сервиса", stop: "Остановка сервиса", restart: "Перезапуск сервиса" };
      const title = titleByAction[action] || ("Действие: " + action);
      // Глобальный лок включается только когда придёт id задачи, а до тех
      // пор кнопка кликабельна: второй клик по «Перезапустить» запускал
      // второй конкурентный S99zapret2 restart.
      btn.disabled = true;
      let resp;
      try {
        resp = await apiPost("/service/" + action);
      } catch (e) {
        btn.disabled = false;
        toastErr("Ошибка запуска: ", e);
        return;
      }
      // Кнопку возвращаем в исходное состояние ДО openJobModal: лок
      // запоминает текущее disabled как «правильное» и после задачи вернул
      // бы её навсегда выключенной.
      btn.disabled = false;
      // Backend теперь async — возвращает {ok, job:<id>}. Открываем
      // модалку с live-логом точно как при auto-update apply. После
      // завершения refreshStatus подтянет grid вверху.
      openJobModal(title, resp.job, {
        // Старт/стоп/рестарт бьют по тому же iptables, через который открыта
        // панель — короткий обрыв здесь штатный, а не отказ команды.
        tolerateOutage: true,
        onDone: (d) => {
          const outcome = jobOutcome(d);
          if (outcome === JOB_FAIL) {
            toast("Команда завершилась с кодом " + d.exit, "bad");
          } else {
            const m = unresolvedMsg(outcome);
            if (m) toast(m, "bad");
          }
          if (jobUnresolved(outcome)) awaitPanelBack().then(() => refreshStatus());
          else setTimeout(refreshStatus, 500);
        },
      });
    });
  });

  refreshStatus();
  refreshUpdateBanner();
  refreshProductUpdate();
  renderStatsNotice();
  _updateGlobalUILock();
}

const productStateText = {
  snapshot: "Production channel is not activated for CI snapshots",
  "snapshot-inconsistent": "Snapshot package build IDs do not match; product update is disabled",
  checking: "Проверяю подпись выпуска…",
  "update-available": "Доступен подписанный выпуск",
  "up-to-date": "Установлен последний выпуск",
  updating: "APK обновляет пакеты z2kOW…",
  "health-check": "Проверяю core и webpanel…",
  rollback: "Проверка не прошла, возвращаю предыдущий выпуск…",
  "rolled-back": "Обновление отменено: восстановлен предыдущий выпуск",
  updated: "Обновление установлено и проверено",
  failed: "Обновление завершилось ошибкой",
};

function productReleaseSummary(manifest, installedTag) {
  const history = Array.isArray(manifest?.history) ? manifest.history : [];
  if (!history.length) return "История выпусков пока недоступна.";
  const installedIndex = history.findIndex(release => release.tag === installedTag);
  const releases = installedIndex < 0
    ? history
    : installedIndex > 0 ? history.slice(0, installedIndex) : [history[0]];
  const categories = [["new", "Новое"], ["fixed", "Исправлено"], ["changed", "Изменено"]];
  return releases.map(release => {
    const changelog = release.changelog || {};
    const notes = categories.map(([key, title]) => {
      const values = Array.isArray(changelog[key]) ? changelog[key] : [];
      if (!values.length) return "";
      return `<p><strong>${title}</strong></p><ul>${values.map(item => `<li>${escapeHtml(item)}</li>`).join("")}</ul>`;
    }).join("");
    return `<section class="product-release-notes"><p><strong>${escapeHtml(release.tag || "")}</strong></p>${notes}</section>`;
  }).join("");
}

async function refreshProductUpdate() {
  const stateEl = document.getElementById("product-update-state");
  const releaseEl = document.getElementById("product-update-release");
  const updateBtn = document.getElementById("product-update-start");
  const checkBtn = document.getElementById("product-update-check");
  if (!stateEl || !releaseEl || !updateBtn) return;

  const load = async () => {
    stateEl.textContent = "Проверяю подписанный выпуск…";
    updateBtn.disabled = true;
    try {
      const status = await apiGet("/product/update/status");
      if (["snapshot", "snapshot-inconsistent"].includes(status.state)) {
        const build = typeof status.build === "string" && status.build ? status.build.slice(0, 8) : "";
        const product = build ? `SNAPSHOT ${build}` : "SNAPSHOT";
        const engine = status.engine || "unknown";
        const label = productStateText[status.state];
        stateEl.textContent = `z2kOW ${product} · engine ${engine}. ${label}`;
        releaseEl.textContent = "Канал production-обновлений недоступен для CI snapshot; наличие стабильного выпуска не проверено.";
        updateBtn.disabled = true;
        return;
      }
      const [check, manifest] = await Promise.all([
        apiGet("/product/update/check"),
        apiGet("/product/update/info"),
      ]);
      const state = !status.state || ["unknown", "checking"].includes(status.state)
        ? (check.update_available ? "update-available" : "up-to-date")
        : status.state;
      const label = productStateText[state] || status.message || "Состояние выпуска проверено";
      const current = check.installed || status.installed || "не записан";
      const latest = check.latest || status.latest || "неизвестен";
      const skipped = Number.isInteger(check.skipped_releases) ? check.skipped_releases : null;
      const tail = skipped == null ? "" : ` · пропущено выпусков: ${skipped}`;
      const reason = state === "failed" || state === "rolled-back" ? (status.message || "") : "";
      stateEl.textContent = `Установлен ${current} → доступен ${latest}. ${label}${tail}${reason ? ` — ${reason}` : ""}`;
      releaseEl.innerHTML = productReleaseSummary(manifest, current);
      updateBtn.disabled = !check.update_available || ["updating", "health-check", "rollback"].includes(state);
    } catch (error) {
      stateEl.textContent = `Состояние выпуска недоступно: ${error?.message || error}`;
      releaseEl.textContent = "Подписанный release manifest не удалось проверить.";
    }
  };

  checkBtn?.addEventListener("click", () => load());
  updateBtn.addEventListener("click", async () => {
    if (updateBtn.disabled) return;
    updateBtn.disabled = true;
    let response;
    try {
      response = await apiPost("/product/update/start");
    } catch (error) {
      updateBtn.disabled = false;
      toastErr("Не удалось запустить обновление z2kOW: ", error);
      return;
    }
    openJobModal("Обновление z2kOW", response.job, {
      tolerateOutage: true,
      onDone: (details) => {
        if (jobOutcome(details) === JOB_FAIL) toast("Обновление z2kOW не прошло; смотрите причину в журнале", "bad");
        const refresh = () => { refreshStatus(); load(); };
        if (jobUnresolved(jobOutcome(details))) awaitPanelBack().then(refresh);
        else setTimeout(refresh, 500);
      },
    });
  });
  await load();
}

// Карточка «Обрыв на 16 КБ»: одна строка состояния из файлов пробы, а не
// из конфига. Вердикт с давностью, при найденном блоке — сколько сетей и
// имён и доехал ли обход до конфига: расхождение флага и конфига — самая
// частая болезнь механизма, человеку его надо видеть, и красным.
export function tcp16Line(t) {
  const ago = (s) => {
    if (s == null) return "";
    if (s < 3600) return `${Math.max(1, Math.floor(s / 60))} мин назад`;
    if (s < 86400) return `${Math.floor(s / 3600)} ч назад`;
    return `${Math.floor(s / 86400)} дн назад`;
  };
  if (t.running) return { text: "проба идёт…", kind: "" };
  if (t.measured === "1") {
    const head = `Блок есть, проверено ${ago(t.age)}: сетей с обрывом ${t.nets_blocked}, имён подобрано ${t.names}`;
    return t.in_config
      ? { text: `${head}, обход включён`, kind: "warn" }
      : { text: `${head}, но обход в конфиг не попал`, kind: "bad" };
  }
  if (t.measured === "0") return { text: `Блока нет, проверено ${ago(t.age)}`, kind: "good" };
  return { text: "Линия ещё не проверялась", kind: "" };
}

async function refreshTcp16() {
  const el = document.getElementById("tcp16-state");
  if (!el) return;
  let t;
  try {
    t = await apiGet("/tcp16");
  } catch (e) {
    el.className = "tcp16-state bad";
    el.innerHTML = `<span class="tcp16-dot"></span><span class="tcp16-text">Состояние недоступно</span>`;
    return;
  }
  const line = tcp16Line(t);
  el.className = "tcp16-state" + (line.kind ? " " + line.kind : "");
  el.innerHTML = `<span class="tcp16-dot"></span><span class="tcp16-text">${escapeHtml(line.text)}</span>`;
  const btn = document.getElementById("tcp16-probe-btn");
  if (btn) btn.disabled = !!t.running;
}
