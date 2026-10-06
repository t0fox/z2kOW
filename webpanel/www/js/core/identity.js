// Optional visual identity projection. The app loads this as a separate
// module script so a content blocker cannot stop the core ES-module graph.
let _brandName = "z2kOW";

function _label(value) {
  if (typeof value !== "string") return "";
  const text = value.trim();
  if (!text || text.length > 64) return "";
  for (let i = 0; i < text.length; i++) {
    const code = text.charCodeAt(i);
    if (code < 32 || code === 127) return "";
  }
  return text;
}

function _asset(value, extension) {
  if (typeof value !== "string" || value.length > 160) return "";
  if (!value.startsWith("/assets/") || value.includes("..") || value.includes("\\")
      || /[\s?#]/.test(value)) return "";
  return new RegExp("^/assets/[A-Za-z0-9/_-]+\\." + extension + "$").test(value) ? value : "";
}

export function currentBrandName() { return _brandName; }

export function applyBranding(status) {
  const profile = status && status.brand;
  if (!profile || typeof profile !== "object" || Array.isArray(profile)) return false;

  const name = _label(profile.name);
  const subtitle = _label(profile.subtitle);
  const logo = _asset(profile.logo, "png");
  const favicon = _asset(profile.favicon, "svg");
  const theme = _asset(profile.theme, "css");
  if (!name || !subtitle || !logo || !favicon || !theme) return false;

  const brand = document.getElementById("panel-brand");
  const image = document.getElementById("brand-profile-logo");
  const wordmark = document.getElementById("brand-wordmark");
  const logoSvg = document.getElementById("brand-composite-logo");
  const icon = document.getElementById("brand-favicon");
  const mask = document.getElementById("brand-mask-icon");
  if (!brand || !image || !wordmark || !logoSvg || !icon || !mask) return false;

  logoSvg.querySelectorAll("[data-brand-source]").forEach(source => source.setAttribute("href", logo));
  brand.classList.add("brand-composite");
  wordmark.textContent = name;
  brand.setAttribute("aria-label", name + " — " + subtitle);
  icon.setAttribute("href", favicon);
  mask.setAttribute("href", favicon);

  let themeLink = document.getElementById("brand-profile-theme");
  if (!themeLink) {
    themeLink = document.createElement("link");
    themeLink.id = "brand-profile-theme";
    themeLink.rel = "stylesheet";
    document.head.appendChild(themeLink);
  }
  themeLink.setAttribute("href", theme);
  _brandName = name;
  if (typeof window !== "undefined" && typeof window.__z2kSetRouteBrandName === "function") {
    window.__z2kSetRouteBrandName(name);
  }
  return true;
}

// The optional module may arrive before or after /status. Neither branch owns
// first paint: index.html loads the package profile independently.
if (typeof window !== "undefined") {
  window.__z2kApplyBranding = applyBranding;
  if (window.__z2kBrandStatus) {
    try { applyBranding(window.__z2kBrandStatus); } catch (_) { /* optional */ }
  }
}
