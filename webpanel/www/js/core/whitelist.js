// Row IDs refer to the loaded text snapshot, never to filtered display positions.
export function whitelistRows(text) {
  return text.split("\n").flatMap((line, id) => {
    const domain = line.trim();
    return domain && !domain.startsWith("#") ? [{ id, domain }] : [];
  });
}

export function replaceWhitelistSelection(text, selected, replacement) {
  let inserted = false;
  const lines = text.split("\n");
  const out = [];
  for (let id = 0; id < lines.length; id++) {
    if (!selected.has(id)) { out.push(lines[id]); continue; }
    if (!inserted && replacement.trim()) out.push(replacement.replace(/\n+$/, ""));
    inserted = true;
  }
  return out.join("\n");
}

export function selectWhitelistRange(selected, visible, anchor, id, checked) {
  const next = new Set(selected);
  const end = visible.indexOf(id);
  const start = visible.includes(anchor) ? visible.indexOf(anchor) : end;
  for (const key of visible.slice(Math.min(start, end), Math.max(start, end) + 1)) {
    if (checked) next.add(key); else next.delete(key);
  }
  return next;
}
