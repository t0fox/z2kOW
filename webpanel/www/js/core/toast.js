import { $toastStack } from "./dom.js";
import { motion } from "../motion.js";

// Skill rule toast-dismiss: 3-5s. New toasts push old ones up; if more
// than MAX_TOASTS are visible the oldest is evicted immediately. Each
// toast has its own dismiss timer so a fast burst doesn't double-fire.
const MAX_TOASTS = 3;

const TOAST_TTL_MS = 3500;
const toastTimers = new WeakMap();

function removeToast(element) {
  const timers = toastTimers.get(element);
  if (timers) {
    clearTimeout(timers.enter);
    clearTimeout(timers.exit);
  }
  motion.dispose(element);
  element.remove();
}

export function toast(msg, kind = "ok") {
  if (!$toastStack) return;
  // Пустой текст — это осознанное молчание, а не недосмотр вызывающего.
  // Так гасятся временные ответы во время переустановки: дерево переезжает,
  // каждый фоновый загрузчик об него спотыкается, и без этого человек
  // получает очередь красных плашек про то, что ничего не сломалось.
  // Единственная точка, где такой текст рождается пустым, — httpError.
  if (!msg || !String(msg).trim()) return;
  const el = document.createElement("div");
  el.className = "toast-item toast-" + kind;
  el.setAttribute("role", "status");
  el.textContent = msg;
  $toastStack.appendChild(el);
  // FIFO eviction: keep at most MAX_TOASTS visible.
  while ($toastStack.children.length > MAX_TOASTS) {
    removeToast($toastStack.firstElementChild);
  }
  const timers = { enter: 0, exit: 0 };
  toastTimers.set(el, timers);
  if (motion.available) {
    el.classList.add("is-visible");
    motion.fromTo(el, { autoAlpha: 0, y: 8 }, { autoAlpha: 1, y: 0,
      duration: motion.timing.duration.popup, ease: motion.timing.ease.standard }, "toast");
  } else requestAnimationFrame(() => el.classList.add("is-visible"));
  timers.enter = setTimeout(() => {
    el.classList.remove("is-visible");
    el.classList.add("is-leaving");
    if (motion.available) {
      motion.fromTo(el, { autoAlpha: 1, y: 0 }, { autoAlpha: 0, y: -4,
        duration: motion.timing.duration.popup, ease: motion.timing.ease.standard,
        onComplete: () => removeToast(el) }, "toast");
    } else timers.exit = setTimeout(() => removeToast(el), 250);
  }, TOAST_TTL_MS);
}
