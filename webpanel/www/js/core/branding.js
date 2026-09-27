// Common brand profile projection. Platform-specific values arrive through
// /status; this module only accepts local, typed assets and never branches on
// a platform name.
let _brandName = "Z2K";

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
  if (!value.startsWith("/brand/") || value.includes("..") || value.includes("\\")
      || /[\s?#]/.test(value)) return "";
  return new RegExp(`^/brand/[A-Za-z0-9/_-]+\\.${extension}$`).test(value) ? value : "";
}

export function currentBrandName() { return _brandName; }

export function applyBranding(status) {
  const profile = status && status.brand;
  if (!profile || typeof profile !== "object" || Array.isArray(profile)) return false;

  const name = _label(profile.name);
  const subtitle = _label(profile.subtitle);
  const logo = _asset(profile.logo, "svg");
  const favicon = _asset(profile.favicon, "svg");
  const theme = _asset(profile.theme, "css");
  if (!name || !subtitle || !logo || !favicon || !theme) return false;

  const brand = document.getElementById("panel-brand");
  const fallback = document.getElementById("brand-default-logo");
  const image = document.getElementById("brand-profile-logo");
  const icon = document.getElementById("brand-favicon");
  const mask = document.getElementById("brand-mask-icon");
  if (!brand || !fallback || !image || !icon || !mask) return false;

  image.setAttribute("src", logo);
  image.hidden = false;
  fallback.hidden = true;
  brand.setAttribute("aria-label", `${name} — ${subtitle}`);
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
  return true;
}
