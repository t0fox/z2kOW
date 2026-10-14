const WIDTH = 760;
const HEIGHT = 340;
const LANE_Y = [50, 125, 215, 290];
const MAX_PARTICLES = 64;
const MAX_SPARKS = 24;
const MAX_RIPPLES = 12;

const ROUTES = [
  { transport: "direct_wss", label: "Прямой WSS" },
  { transport: "cloudflare_worker", label: "Cloudflare Worker" },
  { transport: "cloudflare_proxy", label: "Прокси Cloudflare" },
  { transport: "tcp_fallback", label: "Резервный TCP" },
];

const TRANSPORT_TO_LANE = new Map([
  ["direct_wss", 0],
  ["cloudflare_worker", 1],
  ["cloudflare_proxy", 2],
  ["tcp_fallback", 3],
  ["tcp_passthrough", 0],
]);

const STATE_LABELS = {
  idle: "резерв",
  connecting: "подключение",
  connected: "upstream готов",
  selected: "активен",
  race: "гонка",
  cooldown: "на паузе",
  failed: "отказ",
  cancelled: "отменён",
  skipped: "пропуск",
};

const STATUS_ORDER = ["selected", "race", "connecting", "connected", "cooldown", "failed", "cancelled", "skipped"];

function bezier(start, control1, control2, end, progress) {
  const inverse = 1 - progress;
  const weights = [inverse ** 3, 3 * inverse ** 2 * progress, 3 * inverse * progress ** 2, progress ** 3];
  return [0, 1].map(axis => start[axis] * weights[0] + control1[axis] * weights[1]
    + control2[axis] * weights[2] + end[axis] * weights[3]);
}

function makeLanePath(y) {
  const points = [];
  for (let index = 0; index <= 30; index += 1) {
    points.push(bezier([230, 170], [290, 170], [280, y], [340, y], index / 30));
  }
  for (let index = 1; index <= 20; index += 1) points.push([340 + 230 * index / 20, y]);
  for (let index = 1; index <= 30; index += 1) {
    points.push(bezier([570, y], [630, y], [620, 170], [700, 170], index / 30));
  }
  return makePath(points);
}

function makePath(points) {
  const cumulative = [0];
  for (let index = 1; index < points.length; index += 1) {
    cumulative.push(cumulative[index - 1]
      + Math.hypot(points[index][0] - points[index - 1][0], points[index][1] - points[index - 1][1]));
  }
  return { points, cumulative, length: cumulative[cumulative.length - 1] };
}

function pointAt(path, fraction) {
  const distance = Math.max(0, Math.min(1, fraction)) * path.length;
  let low = 0;
  let high = path.cumulative.length - 1;
  while (high - low > 1) {
    const middle = (low + high) >> 1;
    if (path.cumulative[middle] < distance) low = middle;
    else high = middle;
  }
  const segmentLength = path.cumulative[high] - path.cumulative[low] || 1;
  const progress = (distance - path.cumulative[low]) / segmentLength;
  return [0, 1].map(axis => path.points[low][axis]
    + (path.points[high][axis] - path.points[low][axis]) * progress);
}

function ease(progress) {
  return progress < 0.5 ? 4 * progress ** 3 : 1 - ((-2 * progress + 2) ** 3) / 2;
}

function cssColorToRgb(color, fallback) {
  const probe = document.createElement("span");
  probe.style.color = color;
  probe.setAttribute("aria-hidden", "true");
  probe.style.position = "absolute";
  probe.style.visibility = "hidden";
  document.body.appendChild(probe);
  const normalized = window.getComputedStyle(probe).color;
  probe.remove();
  const channels = normalized.match(/[\d.]+/g);
  if (!channels || channels.length < 3) return fallback;
  return channels.slice(0, 3).map(value => Number(value));
}

function transportLane(transport) {
  return TRANSPORT_TO_LANE.has(transport) ? TRANSPORT_TO_LANE.get(transport) : -1;
}

function routeState(value) {
  return Object.hasOwn(STATE_LABELS, value) ? value : "idle";
}

function eventState(value) {
  if (value === "first_binary_response") return "selected";
  return routeState(value);
}

function routeDescription(transport, lane) {
  if (transport === "tcp_passthrough") return "Прямой TCP passthrough";
  return ROUTES[lane]?.label || "WSS-транспорт не определён";
}

function selectedLaneFor(session) {
  return session?.selected_transport ? transportLane(session.selected_transport) : -1;
}

function laneStatesForSession(session) {
  const states = ROUTES.map(() => "idle");
  const transports = ROUTES.map(route => route.transport);
  let directLane = transportLane(session.direct_transport);
  let fallbackLane = transportLane(session.fallback_transport);
  if (directLane >= 0) {
    transports[directLane] = session.direct_transport;
    states[directLane] = routeState(session.direct_state);
  }
  if (fallbackLane >= 0) {
    transports[fallbackLane] = session.fallback_transport;
    states[fallbackLane] = routeState(session.fallback_state);
  }
  (session.events || []).forEach(event => {
    const lane = transportLane(event.transport);
    if (lane >= 0) {
      transports[lane] = event.transport;
      states[lane] = eventState(event.state);
    }
  });
  const selectedLane = selectedLaneFor(session);
  if (selectedLane >= 0) {
    transports[selectedLane] = session.selected_transport;
    states[selectedLane] = "selected";
  }
  const connecting = states.map((state, lane) => state === "connecting" ? lane : -1).filter(lane => lane >= 0);
  if (connecting.length > 1) connecting.forEach(lane => { states[lane] = "race"; });
  return { states, transports, connecting: connecting.length > 1, selectedLane };
}

function summarize(snapshot, error) {
  if (error) {
    return {
      state: "unavailable", caption: "Статистика маршрутов недоступна", transportLabel: "Недоступно",
      dcLabel: "DC неизвестен", lanes: ROUTES.map(route => ({ ...route, status: "idle", counts: {} })),
      sessions: [], truncated: false, hedged: [], activeConnections: 0,
    };
  }

  const activeConnections = Math.max(0, Number(snapshot?.active_connections) || 0);
  const sessions = Array.isArray(snapshot?.active_sessions) ? snapshot.active_sessions.slice(0, 64) : [];
  const emptyLanes = ROUTES.map(route => ({ ...route, status: "idle", counts: {} }));
  if (activeConnections === 0) {
    return {
      state: "idle", caption: "Нет активных соединений", transportLabel: "Нет подключений",
      dcLabel: "DC неизвестен", lanes: emptyLanes, sessions: [],
      truncated: Boolean(snapshot?.route_sessions_truncated), hedged: [], activeConnections,
    };
  }
  if (!Array.isArray(snapshot?.active_sessions) || !sessions.length) {
    return {
      state: "unavailable", caption: "Активные соединения есть, маршрут пока не определён", transportLabel: "Определяется",
      dcLabel: "DC неизвестен", lanes: emptyLanes, sessions: [],
      truncated: Boolean(snapshot?.route_sessions_truncated), hedged: [], activeConnections,
    };
  }

  const counts = ROUTES.map(() => Object.create(null));
  const sessionViews = sessions.map(session => {
    const view = laneStatesForSession(session);
    view.states.forEach((state, lane) => {
      if (state !== "idle") counts[lane][state] = (counts[lane][state] || 0) + 1;
    });
    return { session, ...view };
  });
  const lanes = ROUTES.map((route, index) => {
    const laneCounts = counts[index];
    const status = STATUS_ORDER.find(value => laneCounts[value]) || "idle";
    const transports = [...new Set(sessionViews
      .filter(session => session.states[index] !== "idle")
      .map(session => session.transports[index]).filter(Boolean))];
    const label = transports.length === 1 ? routeDescription(transports[0], index) : route.label;
    return { ...route, label, status, counts: laneCounts };
  });
  const selectedLanes = lanes.filter(lane => lane.counts.selected);
  const connectingLanes = lanes.filter(lane => lane.counts.connecting || lane.counts.race);
  const failedLanes = lanes.filter(lane => lane.counts.failed || lane.counts.cooldown);
  const dcValues = new Set(sessions.map(({ dc }) => Number(dc)).filter(Number.isInteger));
  const dcLabel = dcValues.size === 1 ? `DC${[...dcValues][0]}`
    : dcValues.size > 1 ? "Несколько DC" : "DC неизвестен";
  const transportLabel = selectedLanes.length > 1 ? "Несколько маршрутов"
    : selectedLanes.length === 1 ? selectedLanes[0].label
      : connectingLanes.length === 1 ? connectingLanes[0].label
        : connectingLanes.length > 1 ? "Несколько попыток" : failedLanes.length ? "Недоступно" : "Определяется";
  const selectedTransportKeys = new Set(sessionViews.map(({ session }) => session.selected_transport).filter(Boolean));
  const mixedRoutes = selectedTransportKeys.size > 1;
  const hedged = sessionViews.flatMap(view => {
    if (!view.connecting && view.selectedLane < 0) return [];
    const hadTwoAttempts = (view.session.events || []).some((event, eventIndex, events) => event.state === "connecting"
      && events.slice(eventIndex + 1).some(next => next.state === "connecting"
        && transportLane(next.transport) >= 0 && transportLane(next.transport) !== transportLane(event.transport)));
    const cancelled = view.states.map((state, lane) => state === "cancelled" ? lane : -1).filter(lane => lane >= 0);
    return hadTwoAttempts && view.selectedLane >= 0 && cancelled.length
      ? [{ winner: routeDescription(view.session.selected_transport, view.selectedLane),
        losers: cancelled.map(lane => ROUTES[lane].label) }]
      : [];
  });
  const anyConnecting = sessionViews.some(view => view.states.some(state => state === "connecting" || state === "race"));
  const anySelected = selectedLanes.length > 0;
  const allFailed = !anySelected && !anyConnecting && failedLanes.length > 0
    && lanes.every(lane => ["idle", "failed", "cooldown", "cancelled", "skipped"].includes(lane.status));
  const state = anySelected ? (mixedRoutes ? "mixed" : "active")
    : anyConnecting ? (sessionViews.some(view => view.connecting) ? "race" : "searching")
      : allFailed ? "unavailable" : "searching";
  const caption = hedged.length
    ? `Параллельная гонка: победил ${hedged[0].winner}, остальные попытки отменены · ${dcLabel}`
    : mixedRoutes ? `Сессии используют разные маршруты · ${dcLabel}`
      : selectedLanes.length > 1 ? `Активны несколько маршрутов · ${dcLabel}`
        : anySelected ? `Выбран маршрут ${selectedLanes[0].label} · ${dcLabel}`
          : anyConnecting ? (sessionViews.some(view => view.connecting)
            ? `Идёт параллельная гонка маршрутов · ${dcLabel}` : `Прокси устанавливает соединение · ${dcLabel}`)
            : allFailed ? `Для активных соединений маршрут недоступен · ${dcLabel}`
              : `Маршрут определяется · ${dcLabel}`;

  return {
    state, caption, transportLabel, dcLabel, lanes, sessions,
    truncated: Boolean(snapshot.route_sessions_truncated), hedged, activeConnections,
  };
}

export function mountTelegramFlow(canvas) {
  const context = canvas.getContext("2d", { alpha: false });
  if (!context) throw new Error("Canvas 2D недоступен для схемы Telegram");
  const root = canvas.closest(".tg-flow");
  const incomingPath = makePath([[60, 170], [230, 170]]);
  const lanes = ROUTES.map((route, index) => ({
    ...route, index, path: makeLanePath(LANE_Y[index]), color: [100, 125, 128], targetColor: [100, 125, 128],
    alpha: 0.22, targetAlpha: 0.22, glow: 0, targetGlow: 0, status: "idle", markerPulse: 0,
  }));
  const hub = { angle: 0, pulse: 0, spin: 0 };
  const destination = { pulse: 0 };
  const particles = [];
  const sparks = [];
  const ripples = [];
  const cursors = new Map();
  const attemptedSessions = new Set();
  const activeParticles = new Map();
  const lastSteadyFlowAt = new Map();
  let currentView = summarize(null, "");
  let processStartedAt = 0;
  let acceptedConnections = null;
  let pixelRatio = 1;
  let scaleX = 1;
  let scaleY = 1;
  let inView = true;
  let destroyed = false;
  let frameId = 0;
  let lastFrame = 0;
  let lastRippleAt = 0;
  let paletteInitialized = false;
  const motionPreference = window.matchMedia?.("(prefers-reduced-motion: reduce)") || null;

  const fallbackColors = {
    line: [100, 125, 128],
    text: [230, 237, 240],
    muted: [127, 146, 150],
    accent: [45, 212, 160],
    failure: [239, 91, 91],
    background: [13, 20, 22],
  };
  const palette = { ...fallbackColors, direct: fallbackColors.accent, cloudflare: fallbackColors.muted, tcp: fallbackColors.muted };

  function readColor(name, fallback) {
    const value = window.getComputedStyle(canvas).getPropertyValue(name).trim();
    return cssColorToRgb(value || `rgb(${fallback.join(",")})`, fallback);
  }

  function refreshPalette() {
    palette.line = readColor("--tg-flow-line", fallbackColors.line);
    palette.text = readColor("--tg-flow-text", fallbackColors.text);
    palette.muted = readColor("--tg-flow-muted", fallbackColors.muted);
    palette.accent = readColor("--tg-flow-accent", fallbackColors.accent);
    palette.failure = readColor("--tg-flow-failure", fallbackColors.failure);
    palette.background = readColor("--tg-flow-background", fallbackColors.background);
    palette.direct = readColor("--tg-flow-direct", fallbackColors.accent);
    palette.cloudflare = readColor("--tg-flow-cloudflare", fallbackColors.cloudflare);
    palette.tcp = readColor("--tg-flow-tcp", fallbackColors.tcp);
    lanes.forEach(lane => {
      lane.targetColor = laneColor(lane);
      if (!paletteInitialized || motionPreference?.matches) lane.color = [...lane.targetColor];
    });
    paletteInitialized = true;
  }

  function laneColor(lane) {
    if (lane.status === "failed") return palette.failure;
    if (lane.status === "idle") return palette.line;
    if (lane.status === "cooldown" || lane.status === "cancelled" || lane.status === "skipped") return palette.muted;
    if (lane.transport === "tcp_passthrough") return palette.direct;
    if (lane.transport === "tcp_fallback") return palette.tcp;
    if (lane.index === 0) return palette.direct;
    return palette.cloudflare;
  }

  function configureLane(lane, view) {
    const next = view.lanes[lane.index];
    const nextStatus = next?.status || "idle";
    const nextTransport = next?.transport || lane.transport;
    if (lane.status === nextStatus && lane.transport === nextTransport) return;
    lane.status = nextStatus;
    lane.transport = nextTransport;
    lane.targetColor = laneColor(lane);
    lane.targetAlpha = nextStatus === "idle" ? 0.22
      : nextStatus === "cancelled" || nextStatus === "skipped" ? 0.3 : 0.62;
    lane.targetGlow = ["selected", "connected", "connecting", "race"].includes(nextStatus) ? 0.9 : 0;
    if (nextStatus === "failed") lane.markerPulse = 1;
    if (motionPreference?.matches) {
      lane.color = [...lane.targetColor];
      lane.alpha = lane.targetAlpha;
      lane.glow = lane.targetGlow;
      lane.markerPulse = 0;
    }
  }

  function combinedPath(laneIndex, startsAtHub) {
    const route = lanes[laneIndex].path.points;
    return makePath(startsAtHub ? route : [...incomingPath.points, ...route.slice(1)]);
  }

  function addParticle(sessionId, laneIndex, now, options = {}) {
    if (motionPreference?.matches || laneIndex < 0 || particles.length >= MAX_PARTICLES) return null;
    const path = combinedPath(laneIndex, options.startsAtHub !== false);
    const particle = {
      sessionId,
      laneIndex,
      path,
      startedAt: now,
      duration: options.duration || 1250,
      stopAt: options.stopAt ?? null,
      kind: options.kind || "attempt",
      fadeAt: 0,
      x: path.points[0][0],
      y: path.points[0][1],
      opacity: 1,
      radius: 2.5,
      trail: [],
      color: options.kind === "failure" ? palette.failure : lanes[laneIndex].targetColor,
    };
    particles.push(particle);
    if (options.track !== false) activeParticles.set(`${sessionId}:${laneIndex}`, particle);
    return particle;
  }

  function launchFailure(sessionId, laneIndex, now) {
    const key = `${sessionId}:${laneIndex}`;
    const existing = activeParticles.get(key);
    if (existing && existing.startedAt + existing.duration > now && !existing.fadeAt) {
      existing.kind = "failure";
      existing.stopAt = 0.58;
      existing.color = palette.failure;
      return;
    }
    addParticle(sessionId, laneIndex, now, { startsAtHub: true, duration: 760, stopAt: 0.58, kind: "failure" });
  }

  function fadeAttempt(sessionId, laneIndex, now) {
    const particle = activeParticles.get(`${sessionId}:${laneIndex}`);
    if (particle && !particle.fadeAt) particle.fadeAt = now;
  }

  function processEvent(session, event, now) {
    const laneIndex = transportLane(event.transport);
    if (laneIndex < 0) return;
    const state = event.state;
    if (state === "connecting") {
      const startsAtHub = attemptedSessions.has(session.id);
      attemptedSessions.add(session.id);
      addParticle(session.id, laneIndex, now, { startsAtHub });
      hub.pulse = 0.8;
      hub.spin = 0.6;
    } else if (state === "connected" || state === "selected") {
      const key = `${session.id}:${laneIndex}`;
      const existing = activeParticles.get(key);
      if (!existing || existing.startedAt + existing.duration <= now) {
        addParticle(session.id, laneIndex, now, { startsAtHub: true, kind: "success" });
      }
      if (state === "selected") destination.pulse = 1;
    } else if (state === "failed") {
      launchFailure(session.id, laneIndex, now);
    } else if (state === "cancelled") {
      fadeAttempt(session.id, laneIndex, now);
    } else if (state === "first_binary_response") {
      destination.pulse = 1;
    }
  }

  function readEvents(snapshot, view, now) {
    const processTime = Number(snapshot?.process_started_at || 0);
    const accepted = Number(snapshot?.accepted_connections || 0);
    const restarted = processTime && (processStartedAt !== processTime
      || (acceptedConnections != null && accepted < acceptedConnections));
    if (restarted) {
      cursors.clear();
      attemptedSessions.clear();
      activeParticles.clear();
      lastSteadyFlowAt.clear();
      particles.length = 0;
      ripples.length = 0;
      sparks.length = 0;
    }
    if (processTime) processStartedAt = processTime;
    if (snapshot) acceptedConnections = accepted;
    const liveIds = new Set(view.sessions.map(session => session.id));
    for (const id of cursors.keys()) {
      if (!liveIds.has(id)) {
        cursors.delete(id);
        attemptedSessions.delete(id);
        for (const key of lastSteadyFlowAt.keys()) {
          if (key.startsWith(`${id}:`)) lastSteadyFlowAt.delete(key);
        }
        for (const [key, particle] of activeParticles) {
          if (particle.sessionId === id) {
            particle.fadeAt ||= now;
            activeParticles.delete(key);
          }
        }
      }
    }
    view.sessions.forEach(session => {
      const events = Array.isArray(session.events) ? session.events : [];
      const newest = events.length ? Number(events[events.length - 1].sequence) || 0 : 0;
      const previous = cursors.get(session.id);
      if (previous == null || restarted) {
        cursors.set(session.id, newest);
        return;
      }
      const oldest = events.length ? Number(events[0].sequence) || newest : newest;
      if (previous < oldest - 1) {
        cursors.set(session.id, newest);
        return;
      }
      events.filter(event => Number(event.sequence) > previous)
        .sort((left, right) => left.sequence - right.sequence)
        .forEach(event => processEvent(session, event, now));
      cursors.set(session.id, newest);
    });
  }

  function setLaneTargets(view) {
    lanes.forEach(lane => configureLane(lane, view));
  }

  function resize() {
    if (destroyed) return;
    const rect = canvas.getBoundingClientRect();
    const width = Math.max(1, rect.width);
    const height = Math.max(1, rect.height);
    pixelRatio = Math.min(2.5, Math.max(1, window.devicePixelRatio || 1));
    canvas.width = Math.round(width * pixelRatio);
    canvas.height = Math.round(height * pixelRatio);
    scaleX = canvas.width / WIDTH;
    scaleY = canvas.height / HEIGHT;
    if (motionPreference?.matches || !inView || document.hidden) draw();
    else startLoop();
  }

  function strokePath(path, color, alpha, width, dash = [], glow = 0) {
    context.beginPath();
    context.moveTo(path.points[0][0], path.points[0][1]);
    for (let index = 1; index < path.points.length; index += 1) {
      context.lineTo(path.points[index][0], path.points[index][1]);
    }
    context.setLineDash(dash);
    context.lineWidth = width;
    context.lineCap = "round";
    context.lineJoin = "round";
    context.globalAlpha = alpha;
    context.strokeStyle = color;
    context.shadowColor = color;
    context.shadowBlur = glow * 6;
    context.stroke();
    context.shadowBlur = 0;
    context.globalAlpha = 1;
    context.setLineDash([]);
  }

  function rgb(color, alpha = 1) {
    return `rgba(${color[0] | 0},${color[1] | 0},${color[2] | 0},${alpha})`;
  }

  function drawHexagon(x, y, radius, rotation) {
    context.beginPath();
    for (let index = 0; index < 6; index += 1) {
      const angle = rotation + index * Math.PI / 3;
      context[index ? "lineTo" : "moveTo"](x + radius * Math.cos(angle), y + radius * Math.sin(angle));
    }
    context.closePath();
  }

  function drawNode(x, y, radius, glow) {
    context.save();
    context.translate(x, y);
    context.scale(1, scaleX / scaleY);
    context.beginPath();
    context.arc(0, 0, radius, 0, Math.PI * 2);
    context.fillStyle = rgb(palette.background);
    context.fill();
    context.lineWidth = 2.5;
    context.strokeStyle = rgb(palette.accent, 0.35 + 0.65 * glow);
    context.shadowColor = rgb(palette.accent, 0.9);
    context.shadowBlur = 8 * glow;
    context.stroke();
    context.shadowBlur = 0;
    context.restore();
  }

  function drawText(text, x, y, cssFont, color, cssWidth, cssHeight, align = "center") {
    context.save();
    context.setTransform(pixelRatio, 0, 0, pixelRatio, 0, 0);
    context.textAlign = align;
    context.font = cssFont;
    context.fillStyle = color;
    context.fillText(text, x * cssWidth / WIDTH, y * cssHeight / HEIGHT);
    context.restore();
  }

  function draw() {
    if (destroyed || !context || !canvas.width || !canvas.height) return;
    const cssWidth = canvas.width / pixelRatio;
    const cssHeight = canvas.height / pixelRatio;
    context.setTransform(scaleX, 0, 0, scaleY, 0, 0);
    context.globalCompositeOperation = "source-over";
    context.globalAlpha = 1;
    context.fillStyle = rgb(palette.background);
    context.fillRect(0, 0, WIDTH, HEIGHT);

    strokePath(incomingPath, rgb(palette.accent), 0.35, 3);
    lanes.forEach((lane, index) => {
      const dashed = ["cooldown", "failed", "cancelled", "skipped"].includes(lane.status) ? [3, 9] : [];
      strokePath(lane.path, rgb(lane.color), lane.alpha, 3, dashed, lane.glow * 0.5);
      const routeLabel = lane.transport === "tcp_passthrough" ? "Прямой TCP passthrough" : lane.label;
      drawText(routeLabel, 455, LANE_Y[index] - 18, "600 14px system-ui, sans-serif", rgb(palette.text, 0.9), cssWidth, cssHeight);
      if (cssWidth >= 620) {
        const stateColor = lane.status === "failed" ? palette.failure
          : lane.status === "idle" ? palette.muted : lane.color;
        drawText(STATE_LABELS[lane.status] || STATE_LABELS.idle, 455, LANE_Y[index] - 3,
          "12px system-ui, sans-serif", rgb(stateColor, 0.95), cssWidth, cssHeight);
      }
      const marker = pointAt(lane.path, 0.5);
      context.save();
      context.translate(marker[0], marker[1]);
      context.lineCap = "round";
      context.lineWidth = 3;
      if (lane.status === "failed") {
        const markerScale = 1 + 0.3 * lane.markerPulse;
        context.scale(markerScale, markerScale);
        context.strokeStyle = rgb(palette.failure, Math.max(0.2, lane.alpha));
        context.beginPath();
        context.moveTo(-6, -6); context.lineTo(6, 6);
        context.moveTo(6, -6); context.lineTo(-6, 6);
        context.stroke();
      }
      if (lane.status === "cooldown") {
        context.strokeStyle = rgb(palette.muted, Math.max(0.4, lane.alpha));
        context.beginPath();
        context.moveTo(-3.5, -6); context.lineTo(-3.5, 6);
        context.moveTo(3.5, -6); context.lineTo(3.5, 6);
        context.stroke();
      }
      context.restore();
    });

    drawNode(60, 170, 28, 0);
    drawNode(700, 170, 28, Math.min(1, destination.pulse));
    context.strokeStyle = rgb(palette.text, 0.8);
    context.lineWidth = 2;
    context.lineCap = "round";
    context.lineJoin = "round";
    context.strokeRect(52, 157, 16, 26);
    context.beginPath(); context.moveTo(57, 178); context.lineTo(63, 178); context.stroke();
    context.strokeRect(687, 157, 26, 10);
    context.strokeRect(687, 173, 26, 10);

    const hubScale = 1 + 0.06 * hub.pulse;
    context.save();
    context.translate(230, 170);
    context.scale(hubScale, hubScale * scaleX / scaleY);
    drawHexagon(0, 0, 28, hub.angle);
    context.fillStyle = rgb(palette.background);
    context.fill();
    context.lineWidth = 2.5;
    context.strokeStyle = rgb(palette.accent, 0.95);
    context.shadowColor = rgb(palette.accent, 0.9);
    context.shadowBlur = 6 + 6 * hub.pulse;
    context.stroke();
    context.shadowBlur = 0;
    for (let index = 0; index < 3; index += 1) {
      const angle = -hub.angle * 1.6 + index * 2.094;
      context.beginPath();
      context.arc(38 * Math.cos(angle), 38 * Math.sin(angle), 2.5, 0, Math.PI * 2);
      context.fillStyle = rgb(palette.accent, 0.55);
      context.fill();
    }
    context.beginPath(); context.arc(0, 0, 5, 0, Math.PI * 2);
    context.fillStyle = rgb(palette.text); context.fill();
    context.restore();

    const compact = cssWidth < 620;
    drawText("Клиент", compact ? 74 : 60, 218, "600 13px system-ui, sans-serif", rgb(palette.text, 0.72), cssWidth, cssHeight);
    drawText("tg-ws-proxy", 230, 235, "13px system-ui, sans-serif", rgb(palette.text, 0.72), cssWidth, cssHeight);
    drawText("Telegram DC", compact ? 635 : 700, 220, "600 13px system-ui, sans-serif", rgb(palette.text, 0.72), cssWidth, cssHeight);

    ripples.forEach(ripple => {
      const progress = ripple.elapsed / 0.7;
      const eased = 1 - (1 - progress) ** 3;
      context.beginPath();
      context.arc(ripple.x, ripple.y, 28 + 40 * eased, 0, Math.PI * 2);
      context.strokeStyle = rgb(ripple.color, 0.3 * (1 - progress));
      context.lineWidth = 2;
      context.stroke();
    });
    context.globalCompositeOperation = "lighter";
    particles.forEach(particle => {
      const count = particle.trail.length;
      for (let index = 1; index < count; index += 1) {
        const weight = index / count;
        context.beginPath();
        context.moveTo(particle.trail[index - 1][0], particle.trail[index - 1][1]);
        context.lineTo(particle.trail[index][0], particle.trail[index][1]);
        context.strokeStyle = rgb(particle.color, 0.3 * weight * particle.opacity);
        context.lineWidth = 0.6 + 1.4 * weight;
        context.lineCap = "round";
        context.stroke();
      }
      context.beginPath();
      context.arc(particle.x, particle.y, particle.radius, 0, Math.PI * 2);
      context.fillStyle = rgb(particle.color, 0.9 * particle.opacity);
      context.shadowColor = rgb(particle.color);
      context.shadowBlur = 5;
      context.fill();
      context.shadowBlur = 0;
    });
    sparks.forEach(spark => {
      context.beginPath();
      context.arc(spark.x, spark.y, 1.6, 0, Math.PI * 2);
      context.fillStyle = rgb(palette.failure, 0.7 * (1 - spark.elapsed / 0.45));
      context.fill();
    });
    context.globalCompositeOperation = "source-over";
    context.globalAlpha = 1;
  }

  function burst(x, y) {
    for (let index = 0; index < 4 && sparks.length < MAX_SPARKS; index += 1) {
      const angle = Math.random() * Math.PI * 2;
      const speed = 25 + Math.random() * 50;
      sparks.push({ x, y, vx: Math.cos(angle) * speed, vy: Math.sin(angle) * speed, elapsed: 0 });
    }
  }

  function updateFrame(now) {
    frameId = 0;
    if (destroyed || !inView || document.hidden || motionPreference?.matches) return;
    const delta = Math.min(0.05, Math.max(0, (now - lastFrame) / 1000));
    lastFrame = now;
    const smoothing = 1 - Math.exp(-delta * 7);
    lanes.forEach(lane => {
      for (let channel = 0; channel < 3; channel += 1) {
        lane.color[channel] += (lane.targetColor[channel] - lane.color[channel]) * smoothing;
      }
      lane.alpha += (lane.targetAlpha - lane.alpha) * smoothing;
      lane.glow += (lane.targetGlow - lane.glow) * smoothing;
      lane.markerPulse *= Math.exp(-delta * 6);
    });
    currentView.sessions.forEach(session => {
      const laneIndex = selectedLaneFor(session);
      if (laneIndex < 0) return;
      const key = `${session.id}:${laneIndex}`;
      const last = lastSteadyFlowAt.get(key) ?? -Infinity;
      const alreadyVisible = particles.some(particle => particle.sessionId === session.id
        && particle.laneIndex === laneIndex && particle.kind === "flow");
      if (now - last >= 1650 && !alreadyVisible) {
        addParticle(session.id, laneIndex, now, { startsAtHub: true, duration: 2200, kind: "flow", track: false });
        lastSteadyFlowAt.set(key, now);
      }
    });
    hub.pulse *= Math.exp(-delta * 5);
    hub.spin *= Math.exp(-delta * 3);
    hub.angle += delta * (0.3 + 1.5 * hub.spin);
    destination.pulse *= Math.exp(-delta * 4);
    for (let index = particles.length - 1; index >= 0; index -= 1) {
      const particle = particles[index];
      if (particle.fadeAt) {
        const fade = (now - particle.fadeAt) / 300;
        if (fade >= 1) {
          particles.splice(index, 1);
          continue;
        }
        particle.opacity = 1 - fade;
        particle.radius = 2.5 * (1 - 0.5 * fade);
      } else {
        const progress = Math.min((now - particle.startedAt) / particle.duration, 1);
        const fraction = particle.stopAt == null ? ease(progress) : Math.min(ease(progress), particle.stopAt);
        const point = pointAt(particle.path, fraction);
        particle.x = point[0];
        particle.y = point[1];
        particle.opacity = 1;
        particle.trail.push(point);
        if (particle.trail.length > 5) particle.trail.shift();
        if (progress >= 1) {
          if (particle.kind === "failure") {
            burst(particle.x, particle.y);
            lanes[particle.laneIndex].markerPulse = 1;
          } else if (now - lastRippleAt > 400) {
            ripples.push({ x: 700, y: 170, elapsed: 0, color: lanes[particle.laneIndex].targetColor });
            if (ripples.length > MAX_RIPPLES) ripples.shift();
            lastRippleAt = now;
          }
          if (activeParticles.get(`${particle.sessionId}:${particle.laneIndex}`) === particle) {
            activeParticles.delete(`${particle.sessionId}:${particle.laneIndex}`);
          }
          particles.splice(index, 1);
        }
      }
    }
    for (let index = sparks.length - 1; index >= 0; index -= 1) {
      const spark = sparks[index];
      spark.elapsed += delta;
      spark.x += spark.vx * delta;
      spark.y += spark.vy * delta;
      spark.vx *= 0.94;
      spark.vy *= 0.94;
      if (spark.elapsed >= 0.45) sparks.splice(index, 1);
    }
    for (let index = ripples.length - 1; index >= 0; index -= 1) {
      ripples[index].elapsed += delta;
      if (ripples[index].elapsed >= 0.7) ripples.splice(index, 1);
    }
    draw();
    startLoop();
  }

  function startLoop() {
    if (destroyed || frameId || !inView || document.hidden || motionPreference?.matches) return;
    lastFrame = performance.now();
    frameId = window.requestAnimationFrame(updateFrame);
  }

  function stopLoop() {
    if (frameId) window.cancelAnimationFrame(frameId);
    frameId = 0;
  }

  function updateAccessibility(view) {
    const routeText = view.lanes.map(lane => {
      const details = Object.entries(lane.counts).map(([state, count]) => `${STATE_LABELS[state] || state}: ${count}`).join(", ");
      return `${lane.label} — ${details || STATE_LABELS.idle}`;
    }).join("; ");
    const raceText = view.hedged.length
      ? ` Параллельная гонка: победитель ${view.hedged[0].winner}; отменены ${view.hedged[0].losers.join(", ")}.` : "";
    const truncationText = view.truncated ? " Показана ограниченная выборка активных сессий." : "";
    canvas.setAttribute("aria-label", `Поток соединений: Клиент → tg-ws-proxy → Telegram DC. ${routeText}. ${view.caption}.${raceText}${truncationText}`);
    canvas.dataset.state = view.state;
    if (root) root.dataset.state = view.state;
    const caption = root?.querySelector("#tg-flow-caption");
    if (caption && caption.textContent !== view.caption) caption.textContent = view.caption;
  }

  function update(snapshot, error = "") {
    if (destroyed) return null;
    const view = summarize(snapshot, error);
    const now = performance.now();
    readEvents(snapshot, view, now);
    setLaneTargets(view);
    currentView = view;
    updateAccessibility(view);
    if (motionPreference?.matches || !inView || document.hidden) draw();
    else startLoop();
    return view;
  }

  function onMotionPreferenceChange() {
    stopLoop();
    if (motionPreference?.matches) {
      particles.length = 0;
      sparks.length = 0;
      ripples.length = 0;
      activeParticles.clear();
      lastSteadyFlowAt.clear();
      lanes.forEach(lane => {
        lane.color = [...lane.targetColor];
        lane.alpha = lane.targetAlpha;
        lane.glow = lane.targetGlow;
        lane.markerPulse = 0;
      });
      draw();
    } else {
      startLoop();
    }
  }

  function onVisibilityChange() {
    if (document.hidden) stopLoop();
    else startLoop();
  }

  function onIntersection(entries) {
    inView = Boolean(entries[0]?.isIntersecting);
    if (inView) startLoop();
    else stopLoop();
  }

  const resizeObserver = typeof window.ResizeObserver === "function"
    ? new window.ResizeObserver(resize) : null;
  const intersectionObserver = typeof window.IntersectionObserver === "function"
    ? new window.IntersectionObserver(onIntersection, { rootMargin: "80px" }) : null;
  const themeObserver = typeof window.MutationObserver === "function"
    ? new window.MutationObserver(() => { refreshPalette(); draw(); }) : null;
  const motionListener = onMotionPreferenceChange;

  refreshPalette();
  resize();
  resizeObserver?.observe(canvas);
  intersectionObserver?.observe(canvas);
  themeObserver?.observe(document.documentElement, { attributes: true, attributeFilter: ["data-theme"] });
  window.addEventListener("resize", resize, { passive: true });
  document.addEventListener("visibilitychange", onVisibilityChange);
  motionPreference?.addEventListener("change", motionListener);
  if (!intersectionObserver) startLoop();

  return {
    update,
    destroy() {
      if (destroyed) return;
      destroyed = true;
      stopLoop();
      resizeObserver?.disconnect();
      intersectionObserver?.disconnect();
      themeObserver?.disconnect();
      window.removeEventListener("resize", resize);
      document.removeEventListener("visibilitychange", onVisibilityChange);
      motionPreference?.removeEventListener("change", motionListener);
      cursors.clear();
      attemptedSessions.clear();
      activeParticles.clear();
      lastSteadyFlowAt.clear();
      particles.length = 0;
      sparks.length = 0;
      ripples.length = 0;
    },
  };
}
