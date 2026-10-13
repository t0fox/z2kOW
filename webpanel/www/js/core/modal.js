import { motion } from "../motion.js";

const MODAL_EXIT_MS = 200;

export function openModalBackdrop(backdrop) {
  requestAnimationFrame(() => {
    if (!backdrop.isConnected || backdrop.dataset.modalClosing === "true") return;
    backdrop.classList.add("in");
    const modal = backdrop.querySelector(".modal");
    if (modal) {
      modal.classList.add("in");
      if (motion.available) motion.overlay(modal, backdrop, true, {
        duration: motion.timing.duration.popup, fromY: 10, fromScale: 0.96,
      });
    } else if (motion.available) motion.overlay(backdrop, null, true, {
      duration: motion.timing.duration.popup, fromY: 0, fromScale: 1,
    });
  });
}

export function closeModalBackdrop(backdrop, afterClose) {
  if (!backdrop.isConnected) {
    if (afterClose) afterClose();
    return;
  }
  if (backdrop.dataset.modalClosing === "true") return;
  backdrop.dataset.modalClosing = "true";
  const modal = backdrop.querySelector(".modal");
  if (motion.available) {
    const finish = () => {
      backdrop.classList.remove("in");
      if (modal) modal.classList.remove("in");
      backdrop.remove();
      if (afterClose) afterClose();
    };
    if (modal) motion.overlay(modal, backdrop, false, {
      duration: motion.timing.duration.popup, toY: 4, toScale: 0.98, onComplete: finish,
    });
    else motion.overlay(backdrop, null, false, {
      duration: motion.timing.duration.popup, toY: 0, toScale: 1, onComplete: finish,
    });
    return;
  }
  backdrop.classList.remove("in");
  if (modal) modal.classList.remove("in");

  const delay = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ? 0 : MODAL_EXIT_MS;
  window.setTimeout(() => {
    backdrop.remove();
    if (afterClose) afterClose();
  }, delay);
}
