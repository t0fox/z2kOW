// Единый владелец движения интерфейса. Без GSAP панель остаётся на CSS-fallback.
const gsap = typeof window !== "undefined" ? window.gsap : null;
const Flip = typeof window !== "undefined" ? window.Flip : null;
const reduceQuery = typeof window !== "undefined"
  ? window.matchMedia("(prefers-reduced-motion: reduce)") : null;

const duration = Object.freeze({ micro: 0.1, state: 0.16, popup: 0.2, base: 0.28, shell: 0.3, tab: 0.35 });
const ease = Object.freeze({ standard: "power2.out", enter: "power3.out", spring: "back.out(1.15)" });
const keyed = new WeakMap();
const activities = new Map();
const detailsStyles = new WeakMap();
const detailsTargets = new WeakMap();
const interactionStyles = new WeakMap();
const flipAnimations = new WeakMap();
let routeContext = null;
let activityObserver = null;
let domObserver = null;
let intersections = null;
let initialized = false;
let reduced = Boolean(reduceQuery && reduceQuery.matches);

function targetMap(target) {
  if (!target || (typeof target !== "object" && typeof target !== "function")) return null;
  let entries = keyed.get(target);
  if (!entries) {
    entries = new Map();
    keyed.set(target, entries);
  }
  return entries;
}

function killKey(target, key) {
  const entries = targetMap(target);
  const previous = entries && entries.get(key);
  if (previous) {
    previous.kill();
    entries.delete(key);
  }
}

function track(target, key, animation, onComplete) {
  if (!animation) return animation;
  const entries = targetMap(target);
  if (!entries) return animation;
  entries.set(key, animation);
  const finish = () => {
    if (entries.get(key) === animation) entries.delete(key);
    if (typeof onComplete === "function") onComplete();
  };
  animation.eventCallback("onComplete", finish);
  animation.eventCallback("onInterrupt", () => {
    if (entries.get(key) === animation) entries.delete(key);
  });
  return animation;
}

function immediate(target, vars, onComplete) {
  if (gsap && target) gsap.set(target, vars);
  if (typeof onComplete === "function") onComplete();
  return null;
}

function saveStyles(elements) {
  return elements.map(element => ({
    element,
    style: {
      display: element.style.display,
      height: element.style.height,
      overflow: element.style.overflow,
      opacity: element.style.opacity,
      visibility: element.style.visibility,
      transform: element.style.transform,
    },
  }));
}

function restoreStyles(saved) {
  for (const item of saved || []) {
    if (!item.element.isConnected) continue;
    for (const [name, value] of Object.entries(item.style)) item.element.style[name] = value;
  }
}

function disclosureElements(details) {
  const summary = details && details.querySelector(":scope > summary");
  return details ? Array.from(details.children).filter(child => child !== summary) : [];
}

function animateDisclosure(details, open) {
  if (!details || !gsap || !hasGsap) return;
  const children = disclosureElements(details);
  const saved = detailsStyles.get(details) || saveStyles(children);
  detailsTargets.set(details, open);
  const current = detailsStyles.get(details);
  if (current) {
    for (const item of current) gsap.killTweensOf(item.element);
    restoreStyles(current);
  }
  detailsStyles.set(details, saved);

  if (open) {
    details.open = true;
    details.querySelector(":scope > summary")?.setAttribute("aria-expanded", "true");
    if (reduced) {
      restoreStyles(saved);
      return;
    }
    for (const child of children) {
      child.style.overflow = "hidden";
      child.style.height = "0px";
      child.style.opacity = "0";
      child.style.visibility = "visible";
    }
    const animation = to(children, {
      height: "auto", opacity: 1, y: 0, duration: duration.base, ease: ease.standard,
      onComplete: () => restoreStyles(saved),
    }, "disclosure");
    if (!animation) restoreStyles(saved);
    return;
  }

  const displays = children.map(child => getComputedStyle(child).display);
  details.querySelector(":scope > summary")?.setAttribute("aria-expanded", "false");
  if (reduced) {
    details.open = false;
    restoreStyles(saved);
    return;
  }
  children.forEach((child, index) => {
    child.style.display = displays[index] === "none" ? "block" : displays[index];
    child.style.overflow = "hidden";
  });
  const animation = to(children, {
    height: 0, opacity: 0, y: -3, duration: duration.base, ease: ease.standard,
    onComplete: () => {
      if (detailsTargets.get(details) !== false) return;
      details.open = false;
      restoreStyles(saved);
    },
  }, "disclosure");
  if (!animation) restoreStyles(saved);
}

function detailsClick(event) {
  if (event.defaultPrevented || event.button > 0 || !hasGsap) return;
  const summary = event.target instanceof Element && event.target.closest("summary");
  const details = summary && summary.parentElement;
  if (!details || details.tagName !== "DETAILS" || summary.parentElement !== details) return;
  if (event.target.closest("a,button,input,select,textarea")) return;
  event.preventDefault();
  animateDisclosure(details, !(detailsTargets.has(details) ? detailsTargets.get(details) : details.open));
}

function isVisible(element) {
  if (!element.isConnected || document.hidden) return false;
  if (intersections) return Boolean(element.__z2kMotionVisible);
  const rect = element.getBoundingClientRect();
  return rect.bottom > 0 && rect.right > 0 && rect.top < innerHeight && rect.left < innerWidth;
}

function stopActivity(element, settle = false) {
  intersections?.unobserve(element);
  const timeline = activities.get(element);
  if (timeline) {
    timeline.kill();
    activities.delete(element);
  }
  if (settle && gsap) {
    gsap.set(element, { clearProps: "opacity,backgroundPosition,transform" });
    element.style.removeProperty("--z2k-motion-skeleton-left");
    if (element.classList.contains("job-badge-dot")) gsap.set(element, { opacity: 1 });
  }
}

function syncActivity(element) {
  if (!element || !element.isConnected) {
    stopActivity(element);
    return;
  }
  if (!gsap || reduced) {
    stopActivity(element, true);
    return;
  }
  if (!isVisible(element)) {
    const existing = activities.get(element);
    if (existing) existing.pause();
    return;
  }
  if (activities.has(element)) {
    activities.get(element).play();
    return;
  }
  const timeline = gsap.timeline({ repeat: -1, paused: true });
  if (element.classList.contains("job-badge-dot")) {
    timeline.to(element, { opacity: 0.35, duration: 0.6, ease: "sine.inOut", yoyo: true, repeat: 1 });
  } else {
    const sweep = { progress: 0 };
    timeline.fromTo(sweep, { progress: 0 }, {
      progress: 1, duration: 1.5, ease: "none",
      onUpdate: () => element.style.setProperty("--z2k-motion-skeleton-left",
        `${-150 + (element.clientWidth + 150) * sweep.progress}px`),
    });
  }
  activities.set(element, timeline);
  timeline.play();
}

function scanActivities(root) {
  if (!root) return;
  const selector = ".job-badge-dot, .skel-line, .skel-block";
  if (root instanceof Element && root.matches(selector)) observeActivity(root);
  if (root.querySelectorAll) root.querySelectorAll(selector).forEach(observeActivity);
}

function observeActivity(element) {
  if (intersections) intersections.observe(element);
  else syncActivity(element);
}

function visibilityChanged() {
  for (const [element, timeline] of activities) {
    if (isVisible(element)) timeline.play();
    else timeline.pause();
  }
}

function activityMutation(records) {
  for (const record of records) {
    for (const node of record.addedNodes || []) if (node.nodeType === 1) scanActivities(node);
    for (const node of record.removedNodes || []) {
      if (node.nodeType !== 1) continue;
      if (activities.has(node)) stopActivity(node);
      node.querySelectorAll?.(".job-badge-dot, .skel-line, .skel-block").forEach(stopActivity);
    }
  }
}

function interactiveTarget(target) {
  if (!(target instanceof Element)) return null;
  const control = target.closest(".switch") || target.closest("a[href],button,input:not([type=hidden]),textarea,select,summary,[role=option],.seg-btn,.chosen-single,.sort-trigger,.sheet-option,.card.is-interactive");
  if (!control || control.matches(":disabled,[aria-disabled='true']")) return null;
  if (control.matches(".switch") && control.querySelector("input:disabled")) return null;
  return control;
}

function readInteractionStyle(element) {
  const style = getComputedStyle(element);
  return {
    backgroundColor: style.backgroundColor,
    color: style.color,
    borderColor: style.borderColor,
    boxShadow: style.boxShadow,
    filter: style.filter,
    outlineColor: style.outlineColor,
  };
}

function rememberInteractions(root) {
  const selector = "a[href],button,input:not([type=hidden]),textarea,select,summary,[role=option],.switch,.seg-btn,.chosen-single,.sort-trigger,.sheet-option,.card.is-interactive,.status-cell,.policy-status,.job-modal-status,[role=status],[aria-live],.tcp16-state";
  if (root instanceof Element && root.matches(selector) && !interactionStyles.has(root)) {
    interactionStyles.set(root, readInteractionStyle(root));
  }
  root.querySelectorAll?.(selector).forEach(element => {
    if (!interactionStyles.has(element)) interactionStyles.set(element, readInteractionStyle(element));
  });
}

function animateInteractionStyle(element, targetStyle, key = "interaction-style", fromStyle = interactionStyles.get(element), remember = true) {
  if (remember) interactionStyles.set(element, targetStyle);
  if (!fromStyle || reduced || !hasGsap) return;
  if (Object.keys(fromStyle).every(property => fromStyle[property] === targetStyle[property])) return;
  const properties = Object.keys(targetStyle);
  const inline = properties.map(property => {
    const cssProperty = property.replace(/[A-Z]/g, match => `-${match.toLowerCase()}`);
    return [cssProperty, element.style.getPropertyValue(cssProperty), element.style.getPropertyPriority(cssProperty)];
  });
  const restore = () => inline.forEach(([property, value, priority]) => {
    if (value) element.style.setProperty(property, value, priority);
    else element.style.removeProperty(property);
  });
  gsap.set(element, fromStyle);
  to(element, { ...targetStyle, duration: duration.state, ease: ease.standard, onComplete: restore }, key);
}

function animateButtonLayer(element, variable, value) {
  if (!element.matches(".btn-primary")) return;
  to(element, { [variable]: value, duration: duration.popup, ease: ease.standard }, `button-${variable}`);
}

function hoverIn(event) {
  const control = interactiveTarget(event.target);
  if (!control || (event.relatedTarget instanceof Node && control.contains(event.relatedTarget))) return;
  const base = interactionStyles.get(control);
  animateInteractionStyle(control, readInteractionStyle(control), "interaction-style", base, false);
  to(control, { scale: 1.025, y: -1, duration: duration.micro, ease: ease.standard }, "interaction");
  animateButtonLayer(control, "--z2k-motion-hover", 1);
}

function hoverOut(event) {
  const control = interactiveTarget(event.target);
  if (!control || (event.relatedTarget instanceof Node && control.contains(event.relatedTarget))) return;
  const focused = control.matches(":focus-visible");
  const targetStyle = focused ? readInteractionStyle(control) : interactionStyles.get(control);
  animateInteractionStyle(control, targetStyle, "interaction-style", readInteractionStyle(control), false);
  to(control, { scale: focused ? 1.015 : 1, y: focused ? -0.5 : 0,
    duration: duration.micro, ease: ease.standard, clearProps: "transform" }, "interaction");
  animateButtonLayer(control, "--z2k-motion-hover", 0);
}

function focusIn(event) {
  const control = interactiveTarget(event.target);
  if (control && !control.matches(":active")) {
    const base = interactionStyles.get(control);
    animateInteractionStyle(control, readInteractionStyle(control), "interaction-style", base, false);
    to(control, { scale: 1.015, y: -0.5, duration: duration.micro, ease: ease.standard }, "interaction");
  }
}

function focusOut(event) {
  const control = interactiveTarget(event.target);
  if (control && !control.matches(":hover")) {
    const targetStyle = control.matches(":hover") ? readInteractionStyle(control) : interactionStyles.get(control);
    animateInteractionStyle(control, targetStyle, "interaction-style", readInteractionStyle(control), false);
    to(control, { scale: 1, y: 0, duration: duration.micro, ease: ease.standard, clearProps: "transform" }, "interaction");
    animateButtonLayer(control, "--z2k-motion-hover", 0);
  }
}

function pressIn(event) {
  if (event.button !== 0) return;
  const control = interactiveTarget(event.target);
  if (control) {
    to(control, { scale: 0.97, y: 0, duration: 0.07, ease: "power1.out" }, "interaction");
    animateButtonLayer(control, "--z2k-motion-press", 1);
  }
}

function pressOut(event) {
  const control = interactiveTarget(event.target);
  if (!control) return;
  const active = control.matches(":hover,:focus-visible") ? 1.015 : 1;
  to(control, { scale: active, y: active > 1 ? -0.5 : 0,
    duration: duration.micro, ease: ease.standard, clearProps: "transform" }, "interaction");
  animateButtonLayer(control, "--z2k-motion-press", 0);
}

function animateStateMutation(element) {
  if (!(element instanceof Element) || !element.isConnected || !hasGsap) return;
  animateInteractionStyle(element, readInteractionStyle(element), "state-style", interactionStyles.get(element));
  if (reduced) return;
  const closedGroup = element.matches("tbody.sg") && element.classList.contains("sg-closed");
  const groupIcon = element.matches("tbody.sg") ? element.querySelector(".sg-toggle .icon") : null;
  const disclosureIcon = element.matches(".btn-disclosure") ? element.querySelector(".icon") : null;
  if (groupIcon) fromTo(groupIcon, { rotation: closedGroup ? 0 : -90 }, {
    rotation: closedGroup ? -90 : 0, duration: duration.base, ease: ease.standard, clearProps: "transform",
  }, "disclosure-icon");
  if (disclosureIcon) fromTo(disclosureIcon, { rotation: element.classList.contains("is-open") ? 0 : 180 }, {
    rotation: element.classList.contains("is-open") ? 180 : 0, duration: duration.base, ease: ease.standard, clearProps: "transform",
  }, "disclosure-icon");
  if (element.matches(".nav-active-indicator,.strat-tabs,.chosen-drop")) return;
  const stateful = element.matches("[aria-pressed],[aria-selected],[aria-expanded],[data-kind],[data-state],[role=status],[aria-live],.active,.status-cell,.job-modal-status")
    || /(?:^|\s)(?:is-(?:on|off|running|success|error|active|enabled|healthy|unavailable)|status-(?:ok|bad|good|warn))(?:\s|$)/.test(element.className || "");
  if (stateful) status(element);
}

function initStateObserver() {
  if (!document.body || !window.MutationObserver) return;
  rememberInteractions(document.body);
  domObserver = new MutationObserver(records => {
    for (const record of records) {
      if (record.type === "attributes") animateStateMutation(record.target);
      if (record.type === "childList") {
        for (const node of record.addedNodes) {
          if (node.nodeType !== 1) continue;
          scanActivities(node);
          rememberInteractions(node);
          syncSwitches(node);
        }
        const target = record.target instanceof Element ? record.target : record.target.parentElement;
        if (target && (target.matches("[role=status],[aria-live],.tcp16-state,.policy-status,.job-modal-status")
          || target.closest("[role=status],[aria-live]"))) animateStateMutation(target);
      }
    }
  });
  domObserver.observe(document.body, { subtree: true, childList: true, attributes: true,
    attributeFilter: ["class", "aria-pressed", "aria-selected", "aria-expanded", "data-kind", "data-state", "checked"] });
}

function initActivityObserver() {
  if (!document.body || !window.MutationObserver) return;
  activityObserver = new MutationObserver(activityMutation);
  activityObserver.observe(document.body, { childList: true, subtree: true });
  if (window.IntersectionObserver) {
    intersections = new IntersectionObserver(entries => {
      for (const entry of entries) {
        entry.target.__z2kMotionVisible = entry.isIntersecting;
        if (entry.isIntersecting) syncActivity(entry.target);
        else activities.get(entry.target)?.pause();
      }
    }, { rootMargin: "24px" });
  }
  scanActivities(document.body);
  document.addEventListener("visibilitychange", visibilityChanged);
}

function switchColors(checked) {
  const root = getComputedStyle(document.documentElement);
  return {
    "--z2k-switch-offset": checked ? "18px" : "0px",
    "--z2k-switch-track": root.getPropertyValue(checked ? "--accent" : "--switch-track").trim(),
  };
}

function switchState(input) {
  const control = input instanceof HTMLInputElement && input.closest(".switch");
  if (!control) return;
  if (reduced || !hasGsap) {
    control.style.removeProperty("--z2k-switch-offset");
    control.style.removeProperty("--z2k-switch-track");
    return;
  }
  gsap.set(control, switchColors(!input.checked));
  to(control, { ...switchColors(input.checked), duration: duration.base, ease: ease.standard,
    onComplete: () => {
      control.style.removeProperty("--z2k-switch-offset");
      control.style.removeProperty("--z2k-switch-track");
    } }, "switch-state");
}

function switchChanged(event) {
  if (event.target instanceof HTMLInputElement && event.target.matches(".switch input[type=checkbox]")) switchState(event.target);
}

function syncSwitches(root) {
  const controls = root instanceof Element && root.matches(".switch") ? [root] : [];
  root.querySelectorAll?.(".switch").forEach(control => controls.push(control));
  controls.forEach(control => {
    const input = control.querySelector("input[type=checkbox]");
    if (input) gsap.set(control, switchColors(input.checked));
  });
}

function setReduced(value) {
  reduced = Boolean(value);
  if (!gsap) return;
  if (reduced) {
    for (const element of Array.from(activities.keys())) stopActivity(element, true);
    for (const element of document.querySelectorAll("[data-z2k-motion-active]")) {
      gsap.killTweensOf(element);
      gsap.set(element, { clearProps: "transform,opacity,visibility" });
      element.removeAttribute("data-z2k-motion-active");
    }
    const children = gsap.globalTimeline.getChildren(true, true, true);
    for (const animation of children) animation.progress(1).kill();
  } else {
    scanActivities(document.body);
    visibilityChanged();
  }
}

function ensureNavIndicator(nav) {
  let indicator = nav.querySelector(":scope > .nav-active-indicator");
  if (indicator) return indicator;
  indicator = document.createElement("span");
  indicator.className = "nav-active-indicator";
  indicator.setAttribute("aria-hidden", "true");
  nav.insertBefore(indicator, nav.firstChild);
  return indicator;
}

function moveNavIndicator(nav, active) {
  if (!nav || !active || !hasGsap) return;
  const indicator = ensureNavIndicator(nav);
  const navRect = nav.getBoundingClientRect();
  const activeRect = active.getBoundingClientRect();
  const target = { x: activeRect.left - navRect.left, y: activeRect.top - navRect.top + nav.scrollTop,
    width: activeRect.width, height: activeRect.height };
  if (!indicator.dataset.ready || reduced) {
    gsap.set(indicator, target);
    indicator.dataset.ready = "true";
  } else {
    to(indicator, { ...target, duration: duration.base, ease: ease.standard }, "position");
  }
}

function moveTabIndicator(tabs, position, first = false, previous = null) {
  const vars = { "--tab-left": `${position.left}px`, "--tab-top": `${position.top}px`,
    "--tab-width": `${position.width}px`, "--tab-height": `${position.height}px` };
  if (!hasGsap || first && !previous || reduced) {
    if (gsap) gsap.set(tabs, vars);
    else for (const [key, value] of Object.entries(vars)) tabs.style.setProperty(key, value);
    return null;
  }
  if (first && previous) {
    return fromTo(tabs, { "--tab-left": `${previous.left}px`, "--tab-top": `${previous.top}px`,
      "--tab-width": `${previous.width}px`, "--tab-height": `${previous.height}px` },
    { ...vars, duration: duration.tab, ease: "power2.inOut" }, "tab-indicator");
  }
  return to(tabs, { ...vars, duration: duration.tab, ease: "power2.inOut" }, "tab-indicator");
}

function animateActivityOnReducedChange() {
  if (reduceQuery && reduceQuery.addEventListener) reduceQuery.addEventListener("change", event => setReduced(event.matches));
}

function init() {
  if (initialized || !gsap || !document.documentElement) return;
  initialized = true;
  try { if (Flip && gsap.registerPlugin) gsap.registerPlugin(Flip); } catch (_) {}
  document.documentElement.classList.add("motion-ready");
  document.addEventListener("click", detailsClick, true);
  document.addEventListener("pointerover", hoverIn, true);
  document.addEventListener("pointerout", hoverOut, true);
  document.addEventListener("focusin", focusIn, true);
  document.addEventListener("focusout", focusOut, true);
  document.addEventListener("pointerdown", pressIn, true);
  document.addEventListener("pointerup", pressOut, true);
  document.addEventListener("pointercancel", pressOut, true);
  document.addEventListener("change", switchChanged, true);
  initStateObserver();
  initActivityObserver();
  syncSwitches(document.body);
  animateActivityOnReducedChange();
}

function to(target, vars, key = "default") {
  if (!gsap || !target) return null;
  killKey(target, key);
  const onComplete = vars.onComplete;
  const options = { duration: duration.base, ease: ease.standard, overwrite: "auto", ...vars };
  delete options.onComplete;
  if (reduced) return immediate(target, options, onComplete);
  const animation = gsap.to(target, options);
  return track(target, key, animation, onComplete);
}

function fromTo(target, fromVars, toVars, key = "default") {
  if (!gsap || !target) return null;
  killKey(target, key);
  const onComplete = toVars.onComplete;
  const options = { duration: duration.base, ease: ease.standard, overwrite: "auto", ...toVars };
  delete options.onComplete;
  if (reduced) return immediate(target, options, onComplete);
  const animation = gsap.fromTo(target, fromVars, options);
  return track(target, key, animation, onComplete);
}

function dispose(target, clear = true) {
  if (!target || !gsap) return;
  gsap.killTweensOf(target);
  const entries = targetMap(target);
  if (entries) entries.clear();
  if (clear) gsap.set(target, { clearProps: "transform,opacity,visibility,backgroundPosition" });
}

function enterRoute(root) {
  if (!hasGsap || !root) return;
  if (routeContext) routeContext.revert();
  if (reduced) return;
  const title = root.querySelector(".page-title");
  const cards = Array.from(root.querySelectorAll(":scope > .card")).slice(0, 5);
  const targets = [title, ...cards].filter(Boolean);
  if (!targets.length) return;
  routeContext = gsap.context(() => {
    gsap.fromTo(targets, { autoAlpha: 0, y: 8 }, {
      autoAlpha: 1, y: 0, duration: duration.base, ease: ease.enter,
      stagger: 0.035, clearProps: "opacity,visibility,transform",
    });
  }, root);
}

function disclosure(details, open) { animateDisclosure(details, Boolean(open)); }

function overlay(panel, backdrop, open, options = {}) {
  const panelDuration = options.duration || duration.base;
  const complete = options.onComplete;
  if (!hasGsap) return null;
  if (open) {
    if (backdrop) fromTo(backdrop, { autoAlpha: 0 }, { autoAlpha: 1, duration: panelDuration }, "overlay-backdrop");
    return fromTo(panel, { autoAlpha: 0, y: options.fromY ?? 8, scale: options.fromScale ?? 0.985 }, {
      autoAlpha: 1, y: 0, scale: 1, duration: panelDuration, ease: ease.enter,
      clearProps: "transform,opacity,visibility",
    }, "overlay-panel");
  }
  if (backdrop) to(backdrop, { autoAlpha: 0, duration: panelDuration, ease: ease.standard }, "overlay-backdrop");
  return to(panel, { autoAlpha: 0, y: options.toY ?? -4, scale: options.toScale ?? 0.99,
    duration: panelDuration, ease: ease.standard, clearProps: "transform,opacity,visibility", onComplete: complete }, "overlay-panel");
}

function drawer(nav, theme, backdrop, open, onComplete) {
  if (!hasGsap) return null;
  const navOffset = (nav?.getBoundingClientRect().width || 240) + 32;
  const themeOffset = (theme?.getBoundingClientRect().width || 160) + 32;
  if (open) {
    if (nav) fromTo(nav, { x: -navOffset }, { x: 0, duration: duration.shell, ease: ease.standard, clearProps: "transform" }, "drawer-nav");
    if (theme) fromTo(theme, { x: themeOffset }, { x: 0, duration: duration.shell, ease: ease.standard, clearProps: "transform" }, "drawer-theme");
    if (backdrop) fromTo(backdrop, { autoAlpha: 0 }, { autoAlpha: 1, duration: duration.shell, ease: ease.standard, clearProps: "opacity,visibility" }, "drawer-backdrop");
    return null;
  }
  if (nav) to(nav, { x: -navOffset, duration: duration.shell, ease: ease.standard, clearProps: "transform" }, "drawer-nav");
  if (theme) to(theme, { x: themeOffset, duration: duration.shell, ease: ease.standard, clearProps: "transform" }, "drawer-theme");
  if (backdrop) return to(backdrop, { autoAlpha: 0, duration: duration.shell, ease: ease.standard,
    clearProps: "opacity,visibility", onComplete }, "drawer-backdrop");
  if (onComplete) onComplete();
  return null;
}

function sidebar(nav, body, before) {
  if (!hasGsap || reduced || !before) return;
  const navWidth = getComputedStyle(nav).width;
  const bodyPadding = getComputedStyle(body).paddingLeft;
  const brand = document.getElementById("panel-brand");
  const theme = document.querySelector(".topbar > .theme-toggle");
  const navBefore = before.navWidth;
  const bodyBefore = before.bodyPadding;
  if (navBefore !== navWidth) fromTo(nav, { width: navBefore }, { width: navWidth, duration: duration.shell,
    ease: ease.standard, clearProps: "width", onComplete: () => {
      const active = nav.querySelector("a.active");
      if (active) moveNavIndicator(nav, active);
    } }, "sidebar-width");
  if (bodyBefore !== bodyPadding) fromTo(body, { paddingLeft: bodyBefore }, { paddingLeft: bodyPadding,
    duration: duration.shell, ease: ease.standard, clearProps: "paddingLeft" }, "sidebar-body");
  if (brand && before.brandLeft != null && before.brandLeft !== getComputedStyle(brand).left) {
    fromTo(brand, { left: before.brandLeft }, { left: getComputedStyle(brand).left,
      duration: duration.shell, ease: ease.standard, clearProps: "left" }, "sidebar-brand");
  }
  if (theme && before.themeRight != null && before.themeRight !== getComputedStyle(theme).right) {
    fromTo(theme, { right: before.themeRight }, { right: getComputedStyle(theme).right,
      duration: duration.shell, ease: ease.standard, clearProps: "right" }, "sidebar-theme");
  }
}

function flip(container, mutate, maxItems = 24) {
  if (typeof mutate !== "function") return null;
  const items = container && container.querySelectorAll ? Array.from(container.querySelectorAll("[data-flip-id]")) : [];
  if (!hasGsap || !Flip || reduced || items.length > maxItems || items.length < 2) {
    mutate();
    return null;
  }
  flipAnimations.get(container)?.kill();
  const state = Flip.getState(items);
  mutate();
  const animation = Flip.from(state, { duration: duration.base, ease: ease.standard, absolute: false,
    nested: true, prune: true, stagger: 0.015 });
  if (animation) {
    flipAnimations.set(container, animation);
    const finish = () => { if (flipAnimations.get(container) === animation) flipAnimations.delete(container); };
    animation.eventCallback("onComplete", finish);
    animation.eventCallback("onInterrupt", finish);
  }
  return animation;
}

function numberTo(element, value, format = value => Math.round(value).toLocaleString("ru-RU")) {
  const target = Number(value);
  const start = Number(element?.dataset.motionValue ?? element?.textContent?.trim());
  if (!element || !Number.isFinite(target) || !Number.isFinite(start) || !hasGsap || reduced) {
    if (element) element.textContent = format(Number.isFinite(target) ? target : 0);
    if (element && Number.isFinite(target)) element.dataset.motionValue = String(target);
    return null;
  }
  element.dataset.motionValue = String(target);
  const state = { value: start };
  return to(state, { value: target, duration: duration.base, ease: ease.standard,
    onUpdate: () => { element.textContent = format(state.value); } }, "number");
}

function progressTo(element, value) {
  if (!element) return null;
  const target = Math.max(0, Math.min(100, Number(value) || 0));
  element.setAttribute("aria-valuenow", String(target));
  return to(element, { width: `${target}%`, duration: duration.base, ease: ease.standard }, "progress");
}

function status(element) {
  if (!element) return null;
  if (!hasGsap || reduced) return null;
  return to(element, { keyframes: [{ scale: 0.96, opacity: 0.78 }, { scale: 1, opacity: 1 }],
    duration: duration.state, ease: ease.enter, clearProps: "transform,opacity" }, "status");
}

export const hasGsap = Boolean(gsap && typeof gsap.to === "function");

export const motion = Object.freeze({
  available: hasGsap,
  hasFlip: Boolean(Flip),
  timing: Object.freeze({ duration, ease }),
  init,
  to,
  fromTo,
  dispose,
  enterRoute,
  disclosure,
  overlay,
  drawer,
  sidebar,
  moveNavIndicator,
  moveTabIndicator,
  flip,
  numberTo,
  progressTo,
  status,
  switchState,
  refreshActivity: scanActivities,
  snapshot: target => ({
    activeTweens: gsap && target ? gsap.getTweensOf(target).length : 0,
    activities: activities.size,
    reducedMotion: reduced,
  }),
});

if (hasGsap && document.readyState !== "loading") init();
