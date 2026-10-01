const MODAL_EXIT_MS = 200;

export function openModalBackdrop(backdrop) {
  requestAnimationFrame(() => {
    if (!backdrop.isConnected || backdrop.dataset.modalClosing === "true") return;
    backdrop.classList.add("in");
    const modal = backdrop.querySelector(".modal");
    if (modal) modal.classList.add("in");
  });
}

export function closeModalBackdrop(backdrop, afterClose) {
  if (!backdrop.isConnected) {
    if (afterClose) afterClose();
    return;
  }
  if (backdrop.dataset.modalClosing === "true") return;
  backdrop.dataset.modalClosing = "true";
  backdrop.classList.remove("in");
  const modal = backdrop.querySelector(".modal");
  if (modal) modal.classList.remove("in");

  const delay = window.matchMedia("(prefers-reduced-motion: reduce)").matches
    ? 0 : MODAL_EXIT_MS;
  window.setTimeout(() => {
    backdrop.remove();
    if (afterClose) afterClose();
  }, delay);
}
