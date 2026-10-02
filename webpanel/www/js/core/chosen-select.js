// Shared Chosen-style presentation for every single-value select in the panel.
// Keep the native <select> as the value and event source so route code keeps
// its existing selectors, values, and change handlers.
const states = new WeakMap();
const valueProperty = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value");
const indexProperty = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "selectedIndex");

let activeState = null;
let nextId = 0;
let initialized = false;

function cleanText(value) {
  return String(value || "").replace(/\s+/g, " ").trim();
}

function selectedOption(select) {
  return select.selectedIndex >= 0 ? select.options[select.selectedIndex] : null;
}

function getLabel(select) {
  const explicit = cleanText(select.getAttribute("aria-label"));
  if (explicit) return explicit;

  const label = select.labels && select.labels[0];
  if (label) {
    const visibleLabel = label.querySelector(".field-label, .t-sub-label");
    const text = cleanText(visibleLabel ? visibleLabel.textContent : label.textContent);
    if (text) return text;
  }

  if (select.closest(".state-table")) return "Стратегия";
  if (select.id === "dv-strat") return "Стратегия Discord Voice";
  return cleanText(select.id.replace(/[-_]+/g, " ")) || "Выбор";
}

function optionDisabled(option) {
  return option.disabled || Boolean(option.parentElement && option.parentElement.disabled);
}

function setActiveOption(state, optionIndex, scrollIntoView = false) {
  const options = Array.from(state.select.options);
  if (!options.length) {
    state.activeIndex = -1;
    state.trigger.removeAttribute("aria-activedescendant");
    return;
  }

  let next = optionIndex;
  while (next >= 0 && next < options.length && optionDisabled(options[next])) {
    next += optionIndex >= state.activeIndex ? 1 : -1;
  }
  if (next < 0 || next >= options.length || optionDisabled(options[next])) return;

  state.activeIndex = next;
  const rows = state.list.querySelectorAll("[data-option-index]");
  rows.forEach(row => {
    const active = Number(row.dataset.optionIndex) === next;
    row.classList.toggle("highlighted", active);
    if (active) state.trigger.setAttribute("aria-activedescendant", row.id);
  });

  if (scrollIntoView) {
    const row = state.list.querySelector(`[data-option-index="${next}"]`);
    if (row) {
      const rowRect = row.getBoundingClientRect();
      const listRect = state.list.getBoundingClientRect();
      if (rowRect.top < listRect.top) state.list.scrollTop -= listRect.top - rowRect.top;
      else if (rowRect.bottom > listRect.bottom) state.list.scrollTop += rowRect.bottom - listRect.bottom;
    }
  }
}

function syncValue(state) {
  const { select, trigger, label, wrapper } = state;
  const option = selectedOption(select);
  const value = cleanText(option ? option.textContent : "");
  label.textContent = value || "Выберите…";
  trigger.setAttribute("aria-valuetext", value || "Выберите значение");
  trigger.setAttribute("aria-disabled", String(select.disabled));
  trigger.tabIndex = select.disabled ? -1 : 0;
  wrapper.classList.toggle("chosen-disabled", select.disabled);

  for (const row of state.rows) {
    const selected = Number(row.dataset.optionIndex) === select.selectedIndex;
    row.classList.toggle("result-selected", selected);
    row.setAttribute("aria-selected", String(selected));
  }

  if (state.open) {
    const index = select.selectedIndex;
    setActiveOption(state, index >= 0 && !optionDisabled(select.options[index]) ? index : 0);
    positionPopup(state);
  }
}

function renderOptions(state) {
  const { select, list, drop } = state;
  const options = Array.from(select.options);
  state.rows = [];
  list.replaceChildren();

  for (const child of Array.from(select.children)) {
    if (child instanceof HTMLOptGroupElement) {
      const group = document.createElement("li");
      group.className = "group-result";
      group.setAttribute("role", "presentation");
      group.textContent = child.label;
      list.appendChild(group);
      for (const option of Array.from(child.children)) {
        if (option instanceof HTMLOptionElement && !option.hidden) appendOption(state, option, options);
      }
    } else if (child instanceof HTMLOptionElement && !child.hidden) {
      appendOption(state, child, options);
    }
  }

  if (!state.rows.length) {
    const empty = document.createElement("li");
    empty.className = "no-results";
    empty.setAttribute("role", "presentation");
    empty.textContent = "Нет доступных вариантов";
    list.appendChild(empty);
  }

  syncValue(state);
  if (state.open) setActiveOption(state, select.selectedIndex >= 0 ? select.selectedIndex : 0);
  list.setAttribute("aria-label", getLabel(select));
}

function appendOption(state, option, allOptions) {
  const index = allOptions.indexOf(option);
  const row = document.createElement("li");
  const disabled = optionDisabled(option);
  const selected = option.selected;
  row.id = `${state.id}-option-${index}`;
  row.className = `active-result${disabled ? " disabled-result" : ""}${selected ? " result-selected" : ""}`;
  row.dataset.optionIndex = String(index);
  row.setAttribute("role", "option");
  row.setAttribute("aria-selected", String(selected));
  row.setAttribute("aria-disabled", String(disabled));
  row.textContent = cleanText(option.textContent);

  row.addEventListener("pointerenter", () => {
    if (!disabled) setActiveOption(state, index);
  });
  row.addEventListener("click", event => {
    event.preventDefault();
    event.stopPropagation();
    if (!disabled) chooseOption(state, index);
  });

  state.rows.push(row);
  state.list.appendChild(row);
}

function positionPopup(state) {
  if (!state.open || !state.select.isConnected) return;
  const rect = state.trigger.getBoundingClientRect();
  const viewportWidth = document.documentElement.clientWidth || window.innerWidth;
  const viewportHeight = window.innerHeight;
  const margin = 8;

  state.drop.style.setProperty("--chosen-min-width", `${rect.width}px`);
  state.drop.style.setProperty("--chosen-anchor-top", `${rect.top}px`);
  state.drop.style.maxHeight = `${Math.min(300, Math.max(96, viewportHeight - margin * 2))}px`;
  state.drop.style.left = "-10000px";
  state.drop.style.top = "-10000px";

  const box = state.drop.getBoundingClientRect();
  const width = Math.min(box.width, 340, viewportWidth - margin * 2);
  const height = Math.min(box.height, 300, viewportHeight - margin * 2);
  const roomBelow = viewportHeight - rect.bottom - margin;
  const roomAbove = rect.top - margin;
  const upwards = height > roomBelow && roomAbove > roomBelow;
  const left = Math.max(margin, Math.min(rect.left + 10, viewportWidth - width - margin));
  const top = upwards ? rect.top - 12 : rect.bottom;

  state.drop.style.width = `${Math.max(rect.width, width)}px`;
  state.drop.style.left = `${left}px`;
  state.drop.style.top = `${Math.max(margin, Math.min(top, viewportHeight - height - margin))}px`;
  state.drop.classList.toggle("chosen-drop-upwards", upwards);
}

function openSelect(state) {
  if (state.select.disabled || !state.select.options.length) return;
  if (activeState && activeState !== state) closeSelect(activeState);
  if (state.closeTimer) window.clearTimeout(state.closeTimer);

  state.open = true;
  activeState = state;
  state.wrapper.classList.add("chosen-container-active", "chosen-with-drop");
  state.trigger.setAttribute("aria-expanded", "true");
  state.drop.hidden = false;
  state.drop.classList.remove("chosen-drop-closing", "chosen-drop-open");
  state.drop.classList.add("chosen-drop-measuring");
  renderOptions(state);
  positionPopup(state);
  state.drop.classList.remove("chosen-drop-measuring");

  const selected = state.select.selectedIndex;
  const firstEnabled = Array.from(state.select.options).findIndex(option => !optionDisabled(option));
  setActiveOption(state, selected >= 0 && !optionDisabled(state.select.options[selected]) ? selected : firstEnabled);
  state.trigger.focus({ preventScroll: true });
  requestAnimationFrame(() => {
    if (state.open) state.drop.classList.add("chosen-drop-open");
  });
}

function closeSelect(state, restoreFocus = false) {
  if (!state || !state.open) return;
  state.open = false;
  if (activeState === state) activeState = null;
  state.wrapper.classList.remove("chosen-with-drop");
  state.trigger.setAttribute("aria-expanded", "false");
  state.trigger.removeAttribute("aria-activedescendant");
  state.drop.classList.remove("chosen-drop-open", "chosen-drop-measuring");
  state.drop.classList.add("chosen-drop-closing");
  if (state.closeTimer) window.clearTimeout(state.closeTimer);
  state.closeTimer = window.setTimeout(() => {
    state.drop.hidden = true;
    state.drop.classList.remove("chosen-drop-closing", "chosen-drop-upwards");
  }, 200);
  if (restoreFocus && !state.select.disabled) state.trigger.focus({ preventScroll: true });
}

function chooseOption(state, index) {
  const option = state.select.options[index];
  if (!option || optionDisabled(option) || state.select.disabled) return;
  const changed = state.select.selectedIndex !== index;
  if (changed) {
    state.select.value = option.value;
    state.select.dispatchEvent(new Event("change", { bubbles: true }));
  }
  closeSelect(state, true);
}

function moveActive(state, direction, toEdge = false) {
  const options = Array.from(state.select.options);
  const enabled = options.map((option, index) => optionDisabled(option) ? -1 : index).filter(index => index >= 0);
  if (!enabled.length) return;
  if (toEdge) {
    setActiveOption(state, direction > 0 ? enabled[enabled.length - 1] : enabled[0], true);
    return;
  }
  const current = enabled.indexOf(state.activeIndex);
  const nextPosition = Math.max(0, Math.min(enabled.length - 1, (current < 0 ? 0 : current) + direction));
  setActiveOption(state, enabled[nextPosition], true);
}

function handleKeydown(state, event) {
  const { key } = event;
  if (key === "Tab") {
    closeSelect(state);
    return;
  }
  if (key === "Escape" && state.open) {
    event.preventDefault();
    closeSelect(state, true);
    return;
  }
  if (key === "ArrowDown" || key === "ArrowUp") {
    event.preventDefault();
    if (!state.open) openSelect(state);
    else moveActive(state, key === "ArrowDown" ? 1 : -1);
    return;
  }
  if ((key === "Home" || key === "End") && state.open) {
    event.preventDefault();
    moveActive(state, key === "End" ? 1 : -1, true);
    return;
  }
  if ((key === "PageDown" || key === "PageUp") && state.open) {
    event.preventDefault();
    for (let step = 0; step < 8; step += 1) moveActive(state, key === "PageDown" ? 1 : -1);
    return;
  }
  if (key === "Enter" || key === " ") {
    event.preventDefault();
    if (state.open) chooseOption(state, state.activeIndex);
    else openSelect(state);
    return;
  }
  if (key.length === 1 && !event.ctrlKey && !event.metaKey && !event.altKey) {
    state.searchText += key.toLocaleLowerCase();
    window.clearTimeout(state.searchTimer);
    state.searchTimer = window.setTimeout(() => { state.searchText = ""; }, 700);
    const options = Array.from(state.select.options);
    const start = Math.max(0, state.activeIndex + 1);
    const ordered = options.slice(start).concat(options.slice(0, start));
    const match = ordered.find(option => !optionDisabled(option)
      && cleanText(option.textContent).toLocaleLowerCase().startsWith(state.searchText));
    if (match) {
      event.preventDefault();
      const index = options.indexOf(match);
      if (state.open) setActiveOption(state, index, true);
      else chooseOption(state, index);
    }
  }
}

function patchNativeSetter(select, property, descriptor, state) {
  if (!descriptor || typeof descriptor.get !== "function" || typeof descriptor.set !== "function") return;
  Object.defineProperty(select, property, {
    configurable: true,
    enumerable: descriptor.enumerable,
    get() { return descriptor.get.call(this); },
    set(value) {
      descriptor.set.call(this, value);
      syncValue(state);
    },
  });
}

function enhanceSelect(select) {
  if (states.has(select) || select.multiple || select.size > 1) return;
  const id = `z2k-chosen-${++nextId}`;
  const wrapper = document.createElement("span");
  wrapper.className = "chosen-container chosen-container-single";
  for (const name of select.classList) wrapper.classList.add(name);
  wrapper.dataset.chosenSelect = "true";

  const trigger = document.createElement("span");
  trigger.className = "chosen-single";
  trigger.id = `${id}-trigger`;
  trigger.tabIndex = select.disabled ? -1 : 0;
  trigger.setAttribute("role", "combobox");
  trigger.setAttribute("aria-haspopup", "listbox");
  trigger.setAttribute("aria-autocomplete", "none");
  trigger.setAttribute("aria-expanded", "false");
  trigger.setAttribute("aria-controls", `${id}-listbox`);
  trigger.setAttribute("aria-label", getLabel(select));

  const label = document.createElement("span");
  label.className = "chosen-single-label";
  label.setAttribute("aria-hidden", "true");
  const arrow = document.createElement("span");
  arrow.className = "chosen-arrow";
  arrow.setAttribute("aria-hidden", "true");
  trigger.append(label, arrow);

  const drop = document.createElement("div");
  drop.className = "chosen-drop";
  drop.id = `${id}-drop`;
  drop.hidden = true;
  const list = document.createElement("ul");
  list.className = "chosen-results";
  list.id = `${id}-listbox`;
  list.setAttribute("role", "listbox");
  list.setAttribute("aria-label", getLabel(select));
  drop.appendChild(list);

  const state = {
    id, select, wrapper, trigger, label, arrow, drop, list,
    open: false, activeIndex: -1, rows: [], closeTimer: 0,
    searchText: "", searchTimer: 0,
    sync() { syncValue(state); },
    refreshOptions() { renderOptions(state); },
  };
  states.set(select, state);
  select.dataset.chosenSelect = "true";
  select.classList.add("chosen-native");
  select.tabIndex = -1;
  select.setAttribute("aria-hidden", "true");

  select.before(wrapper);
  wrapper.append(select, trigger);
  document.body.appendChild(drop);

  select.addEventListener("change", () => syncValue(state));
  select.addEventListener("input", () => syncValue(state));
  select.addEventListener("reset", () => requestAnimationFrame(() => syncValue(state)));
  patchNativeSetter(select, "value", valueProperty, state);
  patchNativeSetter(select, "selectedIndex", indexProperty, state);

  trigger.addEventListener("focus", () => wrapper.classList.add("chosen-container-active"));
  trigger.addEventListener("blur", () => {
    if (!state.open) wrapper.classList.remove("chosen-container-active");
  });
  trigger.addEventListener("click", event => {
    event.preventDefault();
    event.stopPropagation();
    if (select.disabled) return;
    if (state.open) closeSelect(state);
    else openSelect(state);
  });
  trigger.addEventListener("keydown", event => handleKeydown(state, event));
  renderOptions(state);
}

export function initChosenSelects() {
  if (initialized) return;
  const app = document.getElementById("app");
  if (!app) return;
  initialized = true;

  const enhanceAll = () => {
    for (const select of app.querySelectorAll("select")) enhanceSelect(select);
  };
  enhanceAll();

  const observer = new MutationObserver(records => {
    if (activeState && !activeState.select.isConnected) closeSelect(activeState);
    const changed = new Set();
    for (const record of records) {
      const target = record.target instanceof HTMLSelectElement
        ? record.target : record.target.closest && record.target.closest("select");
      if (target) changed.add(target);
    }
    enhanceAll();
    for (const select of changed) {
      const state = states.get(select);
      if (state) renderOptions(state);
    }
  });
  observer.observe(app, {
    childList: true,
    subtree: true,
    attributes: true,
    attributeFilter: ["disabled", "selected", "label", "hidden"],
  });

  document.addEventListener("pointerdown", event => {
    if (!activeState) return;
    if (activeState.wrapper.contains(event.target) || activeState.drop.contains(event.target)) return;
    closeSelect(activeState);
  });
  const reposition = () => { if (activeState) positionPopup(activeState); };
  window.addEventListener("resize", reposition, { passive: true });
  window.addEventListener("scroll", reposition, { passive: true, capture: true });
}
