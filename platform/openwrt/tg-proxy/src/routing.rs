//! Выбор direct WSS, Cloudflare fallback и TCP по проверенному DC/media маршруту.

use std::collections::HashMap;
use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::Duration;

use tracing::{debug, info, warn};

use crate::cf_domain_pool::CfDomainPool;
use crate::config::{Config, WsRoutingPolicy};
use crate::runtime::Runtime;
use crate::ws_client::{
    CfDialOpts, CooldownMap, ProbeSet, TgWsStream, WsAttempt, WsConnectResult,
    connect_cf_domain_with_outbound_opts, connect_cf_worker_ws_for_dc_with_outbound_opts,
    connect_ws_for_dc_with_outbound, media_tag, race_ws_candidates as race_candidates,
};
// ─── Failure cooldowns ───────────────────────────────────────────────────────

type DirectRouteKey = (u32, bool, String);
type WorkerRouteKey = (u32, bool, String, String);
type CfProxyRouteKey = (u32, bool, String, String);
const CF_PREFERENCE_TTL: Duration = Duration::from_secs(30);
const ROUTE_LATENCY_TTL: Duration = Duration::from_secs(120);

#[derive(Clone, Copy)]
enum RouteClass {
    Direct,
    Cloudflare,
}

#[derive(Clone, Copy)]
struct RouteLatencySample {
    micros: u64,
    measured_at: std::time::Instant,
}

#[derive(Default)]
struct RouteLatencyState {
    direct: Option<RouteLatencySample>,
    cloudflare: Option<RouteLatencySample>,
}

impl RouteLatencyState {
    fn is_recent(&self, now: std::time::Instant) -> bool {
        self.direct
            .is_some_and(|sample| now.duration_since(sample.measured_at) <= ROUTE_LATENCY_TTL)
            || self
                .cloudflare
                .is_some_and(|sample| now.duration_since(sample.measured_at) <= ROUTE_LATENCY_TTL)
    }
}

static ROUTE_LATENCIES: LazyLock<Mutex<HashMap<DirectRouteKey, RouteLatencyState>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

fn update_route_latency(
    route_key: &DirectRouteKey,
    route_class: RouteClass,
    latency: Duration,
) -> Option<bool> {
    let now = std::time::Instant::now();
    let mut measurements = ROUTE_LATENCIES.lock().expect("route latency lock poisoned");
    measurements.retain(|_, state| state.is_recent(now));
    let state = measurements.entry(route_key.clone()).or_default();
    if state
        .direct
        .is_some_and(|sample| now.duration_since(sample.measured_at) > ROUTE_LATENCY_TTL)
    {
        state.direct = None;
    }
    if state
        .cloudflare
        .is_some_and(|sample| now.duration_since(sample.measured_at) > ROUTE_LATENCY_TTL)
    {
        state.cloudflare = None;
    }
    let slot = match route_class {
        RouteClass::Direct => &mut state.direct,
        RouteClass::Cloudflare => &mut state.cloudflare,
    };
    let measured_micros = latency.as_micros().min(u128::from(u64::MAX)) as u64;
    let smoothed_micros = slot
        .filter(|sample| now.duration_since(sample.measured_at) <= ROUTE_LATENCY_TTL)
        .map_or(measured_micros, |previous| {
            ((u128::from(previous.micros) * 3 + u128::from(measured_micros)) / 4) as u64
        });
    *slot = Some(RouteLatencySample {
        micros: smoothed_micros,
        measured_at: now,
    });

    match (state.direct, state.cloudflare) {
        (Some(direct), Some(cloudflare)) => Some(cloudflare.micros < direct.micros),
        _ => None,
    }
}

#[derive(Clone)]
pub(crate) struct RouteFeedback {
    direct_key: DirectRouteKey,
    kind: RouteFeedbackKind,
}

#[derive(Clone)]
enum RouteFeedbackKind {
    Direct {
        cooldown: Duration,
    },
    CfWorker {
        route_key: WorkerRouteKey,
        cooldown: Duration,
    },
    CfProxy {
        route_key: CfProxyRouteKey,
        dc: u32,
        domain: String,
        pool: Arc<CfDomainPool>,
        cooldown: Duration,
    },
}

impl RouteFeedback {
    pub(crate) fn direct(dc: u32, is_media: bool, target_ip: &str, cooldown: Duration) -> Self {
        Self {
            direct_key: direct_route_key(dc, is_media, target_ip),
            kind: RouteFeedbackKind::Direct { cooldown },
        }
    }

    fn cf_worker(
        dc: u32,
        is_media: bool,
        target_ip: &str,
        worker_domain: &str,
        cooldown: Duration,
    ) -> Self {
        Self {
            direct_key: direct_route_key(dc, is_media, target_ip),
            kind: RouteFeedbackKind::CfWorker {
                route_key: (
                    dc,
                    is_media,
                    target_ip.to_string(),
                    worker_domain.to_string(),
                ),
                cooldown,
            },
        }
    }

    fn cf_proxy(
        dc: u32,
        is_media: bool,
        target_ip: String,
        domain: String,
        pool: Arc<CfDomainPool>,
        cooldown: Duration,
    ) -> Self {
        Self {
            direct_key: direct_route_key(dc, is_media, &target_ip),
            kind: RouteFeedbackKind::CfProxy {
                route_key: (dc, is_media, target_ip, domain.clone()),
                dc,
                domain,
                pool,
                cooldown,
            },
        }
    }
}

pub(crate) fn record_mtproto_response(feedback: &RouteFeedback, latency: Duration) {
    let route_class = match &feedback.kind {
        RouteFeedbackKind::Direct { .. } => RouteClass::Direct,
        RouteFeedbackKind::CfWorker { .. } | RouteFeedbackKind::CfProxy { .. } => {
            RouteClass::Cloudflare
        }
    };
    let cf_is_faster = update_route_latency(&feedback.direct_key, route_class, latency);

    match &feedback.kind {
        RouteFeedbackKind::Direct { .. } => {
            WS_FAIL.clear(&feedback.direct_key);
            IP_FAIL.clear(&feedback.direct_key);
        }
        RouteFeedbackKind::CfWorker { route_key, .. } => {
            CF_WORKER_FAIL.clear(route_key);
        }
        RouteFeedbackKind::CfProxy {
            route_key,
            dc,
            domain,
            pool,
            ..
        } => {
            CF_PROXY_FAIL.clear(route_key);
            CF_PROXY_503_FAIL.clear(route_key);
            pool.mark_available(domain);
            let domains = pool.snapshot();
            remember_cf_proxy_success(*dc, &domains.domains, domain);
        }
    }

    if matches!(route_class, RouteClass::Cloudflare) && cf_is_faster != Some(false) {
        PREFERRED_CF.set(feedback.direct_key.clone(), CF_PREFERENCE_TTL);
    } else {
        PREFERRED_CF.clear(&feedback.direct_key);
    }
}

pub(crate) fn record_mtproto_failure(feedback: &RouteFeedback) {
    match &feedback.kind {
        RouteFeedbackKind::Direct { cooldown } => {
            WS_FAIL.set(feedback.direct_key.clone(), *cooldown);
        }
        RouteFeedbackKind::CfWorker {
            route_key,
            cooldown,
        } => {
            CF_WORKER_FAIL.set(route_key.clone(), *cooldown);
        }
        RouteFeedbackKind::CfProxy {
            route_key,
            cooldown,
            ..
        } => {
            CF_PROXY_FAIL.set(route_key.clone(), *cooldown);
        }
    }
    PREFERRED_CF.clear(&feedback.direct_key);
}

pub(crate) fn record_tcp_connect_success(dc: u32, is_media: bool, target_ip: &str) {
    IP_FAIL.clear(&direct_route_key(dc, is_media, target_ip));
}

pub(crate) fn record_tcp_connect_failure(
    dc: u32,
    is_media: bool,
    target_ip: &str,
    cooldown: Duration,
) {
    IP_FAIL.set(direct_route_key(dc, is_media, target_ip), cooldown);
}

/// Состояние direct WSS хранится отдельно для DC, media hint и точного IP.
static WS_FAIL: CooldownMap<DirectRouteKey> = CooldownMap::new();
static IP_FAIL: CooldownMap<DirectRouteKey> = CooldownMap::new();
static WS_PROBE_WAIT: CooldownMap<DirectRouteKey> = CooldownMap::new();
static ACTIVE_DIRECT_PROBES: ProbeSet<DirectRouteKey> = ProbeSet::new();
/// Ошибка Worker относится к конкретному DC, media hint, IP и домену Worker.
static CF_WORKER_FAIL: CooldownMap<WorkerRouteKey> = CooldownMap::new();
static ACTIVE_CF_WORKER_PROBES: ProbeSet<WorkerRouteKey> = ProbeSet::new();
/// Ошибка CF proxy относится к конкретному DC, media hint, IP и домену.
static CF_PROXY_FAIL: CooldownMap<CfProxyRouteKey> = CooldownMap::new();
static CF_PROXY_503_FAIL: CooldownMap<CfProxyRouteKey> = CooldownMap::new();
static ACTIVE_CF_PROXY_PROBES: ProbeSet<CfProxyRouteKey> = ProbeSet::new();
static CF_PROXY_ROUTE_FAIL: CooldownMap<DirectRouteKey> = CooldownMap::new();
static ACTIVE_CF_PROXY_ROUTE_PROBES: ProbeSet<DirectRouteKey> = ProbeSet::new();
const CF_PROXY_503_COOLDOWN: Duration = Duration::from_secs(15);
/// Недавно победивший в hedge CF маршрут временно выбирается первым.
static PREFERRED_CF: CooldownMap<DirectRouteKey> = CooldownMap::new();
static ACTIVE_HEDGES: AtomicUsize = AtomicUsize::new(0);
static HEDGE_AVAILABLE: tokio::sync::Notify = tokio::sync::Notify::const_new();

fn direct_route_key(dc: u32, is_media: bool, ip: &str) -> DirectRouteKey {
    (dc, is_media, ip.to_string())
}

struct HedgePermit;

impl HedgePermit {
    fn try_acquire(limit: usize) -> Option<Self> {
        if limit == 0 {
            return None;
        }
        ACTIVE_HEDGES
            .fetch_update(Ordering::AcqRel, Ordering::Acquire, |active| {
                (active < limit).then_some(active + 1)
            })
            .ok()
            .map(|_| Self)
    }

    async fn acquire(limit: usize) -> Self {
        loop {
            let notified = HEDGE_AVAILABLE.notified();
            tokio::pin!(notified);
            notified.as_mut().enable();
            if let Some(permit) = Self::try_acquire(limit) {
                return permit;
            }
            notified.await;
        }
    }
}

fn should_hedge_direct_recovery(
    policy: WsRoutingPolicy,
    has_fallback: bool,
    hedge_limit: usize,
) -> bool {
    has_fallback
        && hedge_limit > 0
        && matches!(policy, WsRoutingPolicy::Hedged | WsRoutingPolicy::Adaptive)
}

impl Drop for HedgePermit {
    fn drop(&mut self) {
        ACTIVE_HEDGES.fetch_sub(1, Ordering::AcqRel);
        HEDGE_AVAILABLE.notify_one();
    }
}

// ─── Cloudflare domain balancing ─────────────────────────────────────────────

/// Round-robin counter for CF domain balancing (`--cf-balance`).
static CF_BALANCE_COUNTER: AtomicUsize = AtomicUsize::new(0);
/// Round-robin counter for CF Worker domain balancing (`--cf-balance`).
static CF_WORKER_BALANCE_COUNTER: AtomicUsize = AtomicUsize::new(0);
static CF_PROXY_STICKY: LazyLock<Mutex<HashMap<u32, String>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static CF_PROXY_OFFSET: LazyLock<Mutex<HashMap<u32, usize>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static CF_PROXY_DIALS: tokio::sync::Semaphore = tokio::sync::Semaphore::const_new(8);
const CF_PROXY_HEDGE_DELAY: Duration = Duration::from_millis(125);

#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum CfFailureAction {
    RateLimited,
    ServiceUnavailable,
    RouteCooldown,
    Rotate,
}

#[derive(Debug)]
enum CfCandidateFailure {
    ProbeBusy,
    Connect(Box<WsConnectResult>),
}

fn cf_failure_action(result: &WsConnectResult) -> CfFailureAction {
    match result {
        WsConnectResult::HttpStatus(429) => CfFailureAction::RateLimited,
        WsConnectResult::HttpStatus(503) => CfFailureAction::ServiceUnavailable,
        WsConnectResult::HttpStatus(_) | WsConnectResult::Redirect(_) => CfFailureAction::Rotate,
        WsConnectResult::Connected(_) => CfFailureAction::Rotate,
        WsConnectResult::Failed(_)
        | WsConnectResult::DnsFailed(_)
        | WsConnectResult::ConnectTimedOut(_)
        | WsConnectResult::TimedOut => CfFailureAction::RouteCooldown,
    }
}

fn should_stop_cf_proxy_race(failures: &[(String, CfCandidateFailure)]) -> bool {
    failures
        .iter()
        .filter(|(_, failure)| {
            matches!(
                failure,
                CfCandidateFailure::Connect(result)
                    if cf_failure_action(result) == CfFailureAction::RouteCooldown
            )
        })
        .take(2)
        .count()
        == 2
}

fn cf_proxy_domain_order(domains: &[String], dc: u32, balance: bool) -> Vec<String> {
    if domains.is_empty() {
        return Vec::new();
    }
    let sticky = CF_PROXY_STICKY
        .lock()
        .expect("CF sticky lock poisoned")
        .get(&dc)
        .cloned();
    let first = if let Some(sticky) = sticky.as_ref()
        && let Some(index) = domains.iter().position(|domain| domain == sticky)
    {
        index
    } else if balance {
        balance_offset(domains, true, &CF_BALANCE_COUNTER)
    } else {
        *CF_PROXY_OFFSET
            .lock()
            .expect("CF offset lock poisoned")
            .entry(dc)
            .or_insert(0)
            % domains.len()
    };
    domain_order(domains, first).map(str::to_owned).collect()
}

fn remember_cf_proxy_success(dc: u32, domains: &[String], domain: &str) {
    CF_PROXY_STICKY
        .lock()
        .expect("CF sticky lock poisoned")
        .insert(dc, domain.to_string());
    if let Some(index) = domains.iter().position(|candidate| candidate == domain) {
        CF_PROXY_OFFSET
            .lock()
            .expect("CF offset lock poisoned")
            .insert(dc, index);
    }
}

fn advance_cf_proxy_domain(dc: u32, domains: &[String], failed: usize) {
    if domains.is_empty() {
        return;
    }
    CF_PROXY_STICKY
        .lock()
        .expect("CF sticky lock poisoned")
        .remove(&dc);
    let mut offsets = CF_PROXY_OFFSET.lock().expect("CF offset lock poisoned");
    let offset = offsets.entry(dc).or_insert(0);
    let step = if failed >= domains.len() {
        1
    } else {
        failed.max(1)
    };
    *offset = (*offset + step) % domains.len();
}

fn balance_offset(domains: &[String], enabled: bool, counter: &AtomicUsize) -> usize {
    let n = domains.len();
    if !enabled || n <= 1 {
        return 0;
    }

    counter.fetch_add(1, Ordering::Relaxed) % n
}

fn domain_order(domains: &[String], first: usize) -> impl Iterator<Item = &str> {
    (0..domains.len()).map(move |offset| domains[(first + offset) % domains.len()].as_str())
}

struct Timeouts {
    ws_connect: Duration,
    ws_fail_probe: Duration,
    ws_fail_cooldown: Duration,
    ws_redirect_cooldown: Duration,
    ip_fail_cooldown: Duration,
    tcp_fallback: Duration,
    cf_connect: Duration,
    cf_fail_cooldown: Duration,
}

impl Timeouts {
    fn from_config(config: &Config) -> Self {
        Self {
            ws_connect: Duration::from_secs(config.ws_connect_timeout),
            ws_fail_probe: Duration::from_secs(config.ws_fail_probe_timeout),
            ws_fail_cooldown: Duration::from_secs(config.ws_fail_cooldown),
            ws_redirect_cooldown: Duration::from_secs(config.ws_redirect_cooldown),
            ip_fail_cooldown: Duration::from_secs(config.ip_fail_cooldown),
            tcp_fallback: Duration::from_secs(config.tcp_fallback_timeout),
            cf_connect: Duration::from_secs(config.cf_connect_timeout),
            cf_fail_cooldown: Duration::from_secs(config.cf_fail_cooldown),
        }
    }
}
// ─── Routing ─────────────────────────────────────────────────────────────────

/// How the client's byte stream has to be cut into WebSocket messages.
///
/// The two upstream kinds want opposite things, and getting it wrong only
/// shows up under load:
///
/// * Telegram's own `/apiws` endpoint (direct or fronted by the Cloudflare
///   proxy) treats every WebSocket message as exactly one MTProto packet, so
///   the stream must go through [`MsgSplitter`].
/// * A Cloudflare Worker is a raw TCP tunnel — it writes each message's
///   payload straight into the socket, so boundaries carry no meaning there.
///   Packet-aligning for it is not just pointless but harmful: Cloudflare
///   caps a WebSocket message at 1 MiB, and a media upload produces MTProto
///   packets well past that, which killed the connection mid-transfer
///   (Flowseal/tg-ws-proxy#1161, fixed upstream in v1.9.1).
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub(crate) enum WsFraming {
    /// One WebSocket message per MTProto packet.
    Packets,
    /// Opaque byte stream, chunked at whatever size reads off the client.
    Tunnel,
}

impl WsFraming {
    pub(crate) fn as_str(self) -> &'static str {
        match self {
            Self::Packets => "пакетное",
            Self::Tunnel => "потоковое",
        }
    }
}

pub(crate) enum Upstream {
    Ws {
        ws: Box<TgWsStream>,
        framing: WsFraming,
        route_type: &'static str,
        feedback: RouteFeedback,
    },
    Tcp(String),
}

/// Everything the fallback ladder needs to route one client connection.
pub(crate) struct Route<'a> {
    label: SocketAddr,
    config: &'a Config,
    runtime: &'a Runtime,
    timeouts: Timeouts,
    dc: u32,
    is_media: bool,
    /// Cached [`media_tag`] for this DC, used in every log line.
    media: &'static str,
}

impl<'a> Route<'a> {
    pub(crate) fn new(
        label: SocketAddr,
        config: &'a Config,
        runtime: &'a Runtime,
        dc: u32,
        is_media: bool,
    ) -> Self {
        Self {
            label,
            config,
            runtime,
            timeouts: Timeouts::from_config(config),
            dc,
            is_media,
            media: media_tag(is_media),
        }
    }

    pub(crate) fn tcp_fallback_timeout(&self) -> Duration {
        self.timeouts.tcp_fallback
    }

    pub(crate) fn tcp_fallback_failure_cooldown(&self) -> Duration {
        self.timeouts.ip_fail_cooldown
    }
}

async fn first_wss_success<D, C, T>(direct: D, cf: C, hedge_delay: Duration) -> Option<T>
where
    D: std::future::Future<Output = Option<T>>,
    C: std::future::Future<Output = Option<T>>,
{
    tokio::pin!(direct);
    tokio::pin!(cf);
    let delay = tokio::time::sleep(hedge_delay);
    tokio::pin!(delay);

    let mut direct_done = false;
    let mut cf_done = false;

    tokio::select! {
        result = &mut direct => match result {
            Some(value) => return Some(value),
            None => direct_done = true,
        },
        _ = &mut delay => {}
    }

    if direct_done {
        return cf.await;
    }

    loop {
        tokio::select! {
            result = &mut direct, if !direct_done => match result {
                Some(value) => return Some(value),
                None => direct_done = true,
            },
            result = &mut cf, if !cf_done => match result {
                Some(value) => return Some(value),
                None => cf_done = true,
            }
        }

        if direct_done {
            return cf.await;
        }
        if cf_done {
            return direct.await;
        }
    }
}

/// Walk the fallback ladder and return the upstream to bridge, or `None` when
/// the connection cannot be routed at all.
///
/// `target_ip` берётся только из проверенного SO_ORIGINAL_DST и dcOption.
pub(crate) async fn select_upstream(route: &Route<'_>, target_ip: &str) -> Option<Upstream> {
    let has_fallback = route.has_fallback();
    let route_key = direct_route_key(route.dc, route.is_media, target_ip);
    let ip_cooling = IP_FAIL.active(&route_key);

    if ip_cooling {
        info!(
            "[{}] DC{}{}: прямой WSS для {} на паузе; пробую CF-маршрут",
            route.label, route.dc, route.media, target_ip
        );
        if should_hedge_direct_recovery(
            route.config.ws_routing,
            has_fallback,
            route.config.ws_hedge_limit,
        ) {
            if let Some(_permit) = HedgePermit::try_acquire(route.config.ws_hedge_limit) {
                let delay = Duration::from_millis(route.config.ws_hedge_delay_ms);
                if let Some(upstream) = first_wss_success(
                    route.direct_ws_tier(target_ip),
                    route.fallback_chain(target_ip, "проверка восстановления direct WSS"),
                    delay,
                )
                .await
                {
                    return Some(upstream);
                }
            } else if let Some(upstream) =
                route.fallback_chain(target_ip, "ожидание direct IP").await
            {
                return Some(upstream);
            }
        } else if has_fallback
            && let Some(upstream) = route.fallback_chain(target_ip, "ожидание direct IP").await
        {
            return Some(upstream);
        }
        return route.tcp_last_resort(target_ip, "ожидание direct IP");
    }

    let direct_cooling = WS_FAIL.active(&route_key);
    if direct_cooling {
        info!(
            "[{}] DC{}{}: прямой WSS для {} на паузе; пропускаю его до следующей проверки",
            route.label, route.dc, route.media, target_ip
        );
        if has_fallback
            && let Some(upstream) = route.fallback_chain(target_ip, "ожидание direct WSS").await
        {
            return Some(upstream);
        }
        return route.tcp_last_resort(target_ip, "ожидание direct WSS");
    }

    if has_fallback
        && PREFERRED_CF.active(&route_key)
        && matches!(
            route.config.ws_routing,
            WsRoutingPolicy::Hedged | WsRoutingPolicy::Adaptive
        )
    {
        if let Some(upstream) = route
            .fallback_chain(target_ip, "недавно победивший CF маршрут")
            .await
        {
            return Some(upstream);
        }
        if let Some(upstream) = route.direct_ws_tier(target_ip).await {
            PREFERRED_CF.clear(&route_key);
            return Some(upstream);
        }
        return route.tcp_last_resort(target_ip, "отказ недавних WSS маршрутов");
    }

    let cf_first = route.config.ws_routing == WsRoutingPolicy::CfFirst;
    if cf_first
        && has_fallback
        && let Some(upstream) = route.fallback_chain(target_ip, "CF-first").await
    {
        return Some(upstream);
    }

    if matches!(
        route.config.ws_routing,
        WsRoutingPolicy::Hedged | WsRoutingPolicy::Adaptive
    ) && has_fallback
        && route.config.ws_hedge_limit > 0
    {
        let _permit = HedgePermit::acquire(route.config.ws_hedge_limit).await;

        if route.config.ws_routing == WsRoutingPolicy::Adaptive && PREFERRED_CF.active(&route_key) {
            if let Some(upstream) = route
                .fallback_chain(
                    target_ip,
                    "недавно победивший CF маршрут после ожидания hedge",
                )
                .await
            {
                return Some(upstream);
            }
            PREFERRED_CF.clear(&route_key);
        }

        let delay = Duration::from_millis(route.config.ws_hedge_delay_ms);
        if let Some(upstream) = first_wss_success(
            route.direct_ws_tier(target_ip),
            route.fallback_chain(target_ip, "hedged WSS"),
            delay,
        )
        .await
        {
            return Some(upstream);
        }
        return route.tcp_last_resort(target_ip, "сбой WSS");
    }

    if let Some(upstream) = route.direct_ws_tier(target_ip).await {
        return Some(upstream);
    }

    if !cf_first && let Some(upstream) = route.fallback_chain(target_ip, "сбой WSS").await {
        return Some(upstream);
    }
    route.tcp_last_resort(target_ip, "сбой WSS")
}

impl Route<'_> {
    /// Открыть direct WSS к проверенному IP назначения.
    async fn direct_ws_tier(&self, target_ip: &str) -> Option<Upstream> {
        self.direct_ws(target_ip).await.map(|ws| Upstream::Ws {
            ws: Box::new(ws),
            framing: WsFraming::Packets,
            route_type: "прямой WSS",
            feedback: RouteFeedback::direct(
                self.dc,
                self.is_media,
                target_ip,
                self.timeouts.ws_fail_cooldown,
            ),
        })
    }

    /// Перебрать Cloudflare Worker и Cloudflare proxy.
    async fn fallback_chain(&self, dst: &str, reason: &str) -> Option<Upstream> {
        self.cf_tiers(dst, reason).await
    }

    /// Both Cloudflare tiers in upstream's order: Worker tunnel first, then
    /// the Cloudflare proxy.
    ///
    /// Kept as one step so `--cf-priority` and the post-failure fallback walk
    /// the identical ladder — a Worker-only setup used to sit out
    /// `--cf-priority` entirely and pay the full direct-WS timeout on every
    /// connection before reaching its only working path.
    async fn cf_tiers(&self, dst: &str, reason: &str) -> Option<Upstream> {
        if let Some((ws, worker_domain)) = self.cf_worker(dst, reason).await {
            return Some(Upstream::Ws {
                ws: Box::new(ws),
                framing: WsFraming::Tunnel,
                route_type: "WSS через Cloudflare Worker",
                feedback: RouteFeedback::cf_worker(
                    self.dc,
                    self.is_media,
                    dst,
                    &worker_domain,
                    self.timeouts.cf_fail_cooldown,
                ),
            });
        }

        self.cf_proxy(dst, reason)
            .await
            .map(|(ws, domain)| Upstream::Ws {
                ws: Box::new(ws),
                framing: WsFraming::Packets,
                route_type: "WSS через Cloudflare proxy",
                feedback: RouteFeedback::cf_proxy(
                    self.dc,
                    self.is_media,
                    dst.to_string(),
                    domain,
                    Arc::clone(self.runtime.cf_domain_pool()),
                    self.timeouts.cf_fail_cooldown,
                ),
            })
    }

    /// Whether anything other than the direct WebSocket path is configured.
    fn has_fallback(&self) -> bool {
        !self.config.cf_worker_domains().is_empty() || !self.runtime.cf_domains().domains.is_empty()
    }

    /// Перебрать настроенные Cloudflare Worker по порядку балансировки.
    async fn cf_worker(&self, dst: &str, reason: &str) -> Option<(TgWsStream, String)> {
        let worker_domains = self.config.cf_worker_domains();
        if worker_domains.is_empty() {
            return None;
        }

        // Worker туннелирует на проверенный SO_ORIGINAL_DST из DC-карты.
        let first_worker = balance_offset(
            worker_domains,
            self.config.cf_balance,
            &CF_WORKER_BALANCE_COUNTER,
        );

        for worker_domain in domain_order(worker_domains, first_worker) {
            let route_key = (
                self.dc,
                self.is_media,
                dst.to_string(),
                worker_domain.to_string(),
            );
            if CF_WORKER_FAIL.active(&route_key) {
                debug!(
                    "[{}] DC{}{}: Cloudflare Worker {} на паузе, пропуск",
                    self.label, self.dc, self.media, worker_domain
                );
                continue;
            }
            let _probe = if CF_WORKER_FAIL.contains(&route_key) {
                let Some(permit) = ACTIVE_CF_WORKER_PROBES.try_acquire(route_key.clone()) else {
                    continue;
                };
                Some(permit)
            } else {
                None
            };

            debug!(
                "[{}] DC{}{}: {} — проверка Cloudflare Worker {} для {}",
                self.label, self.dc, self.media, reason, worker_domain, dst
            );

            let ws = connect_cf_worker_ws_for_dc_with_outbound_opts(
                worker_domain,
                dst,
                self.dc,
                self.is_media,
                self.timeouts.cf_connect,
                self.runtime.outbound(),
                CfDialOpts {
                    cf_ips: self.runtime.cf_ips(),
                    fail_cooldown: self.timeouts.cf_fail_cooldown,
                },
            )
            .await;

            match ws {
                Some(ws) => {
                    info!(
                        "[{}] DC{}{}: {} — соединение Cloudflare Worker установлено ({})",
                        self.label, self.dc, self.media, reason, worker_domain
                    );
                    return Some((ws, worker_domain.to_string()));
                }
                None => {
                    CF_WORKER_FAIL.set(route_key, self.timeouts.cf_fail_cooldown);
                    warn!(
                        "[{}] DC{}{}: Cloudflare Worker {} недоступен, пауза {} с",
                        self.label,
                        self.dc,
                        self.media,
                        worker_domain,
                        self.timeouts.cf_fail_cooldown.as_secs()
                    );
                }
            }
        }

        None
    }

    /// Перебрать CF proxy-домены в порядке `--cf-balance`, помня сбой отдельно
    /// для DC, media hint, проверенного адреса и домена.
    async fn cf_proxy(&self, dst: &str, reason: &str) -> Option<(TgWsStream, String)> {
        let route_key = direct_route_key(self.dc, self.is_media, dst);
        if CF_PROXY_ROUTE_FAIL.active(&route_key) {
            debug!(
                "[{}] DC{}{}: CF proxy для {} на паузе после сетевых отказов",
                self.label, self.dc, self.media, dst
            );
            return None;
        }
        let _route_probe = if CF_PROXY_ROUTE_FAIL.contains(&route_key) {
            Some(ACTIVE_CF_PROXY_ROUTE_PROBES.try_acquire(route_key.clone())?)
        } else {
            None
        };

        let pool = self.runtime.cf_domains();
        if pool.domains.is_empty() {
            if _route_probe.is_some() {
                CF_PROXY_ROUTE_FAIL.set(route_key, self.timeouts.cf_fail_cooldown);
            }
            return None;
        }

        let ordered = cf_proxy_domain_order(&pool.domains, self.dc, self.config.cf_balance);

        debug!(
            "[{}] DC{}{}: {} — проверка CF-прокси через {:?}",
            self.label, self.dc, self.media, reason, ordered
        );

        let mut candidates = Vec::with_capacity(ordered.len());
        for domain in ordered {
            if self.runtime.cf_domain_pool().is_rate_limited(&domain) {
                debug!(
                    "[{}] DC{}{}: CF-домен {} пропущен после HTTP 429",
                    self.label, self.dc, self.media, domain
                );
                continue;
            }
            let route_key = (self.dc, self.is_media, dst.to_string(), domain.clone());
            if CF_PROXY_FAIL.active(&route_key) || CF_PROXY_503_FAIL.active(&route_key) {
                debug!(
                    "[{}] DC{}{}: CF proxy {} на паузе после ошибки маршрута, пропуск",
                    self.label, self.dc, self.media, domain
                );
                continue;
            }
            candidates.push(domain);
        }

        if candidates.is_empty() {
            if _route_probe.is_some() {
                CF_PROXY_ROUTE_FAIL.set(route_key, self.timeouts.cf_fail_cooldown);
            }
            return None;
        }

        let domains = candidates.clone();
        let dc = self.dc;
        let is_media = self.is_media;
        let destination = dst.to_string();
        let timeout = self.timeouts.cf_connect;
        let (winner, failures) = race_candidates(
            candidates,
            CF_PROXY_HEDGE_DELAY,
            move |domain| {
                let route = self;
                let destination = destination.clone();
                async move {
                    let candidate_route_key = (dc, is_media, destination, domain.clone());
                    let _probe = if CF_PROXY_FAIL.contains(&candidate_route_key)
                        || CF_PROXY_503_FAIL.contains(&candidate_route_key)
                    {
                        let Some(permit) =
                            ACTIVE_CF_PROXY_PROBES.try_acquire(candidate_route_key.clone())
                        else {
                            return Err(CfCandidateFailure::ProbeBusy);
                        };
                        Some(permit)
                    } else {
                        None
                    };
                    let _dial = CF_PROXY_DIALS
                        .acquire()
                        .await
                        .expect("семафор подключений CF-прокси неожиданно закрыт");
                    match connect_cf_domain_with_outbound_opts(
                        dc,
                        &domain,
                        is_media,
                        timeout,
                        route.runtime.outbound(),
                        CfDialOpts {
                            cf_ips: route.runtime.cf_ips(),
                            fail_cooldown: route.timeouts.cf_fail_cooldown,
                        },
                    )
                    .await
                    {
                        WsConnectResult::Connected(ws) => Ok(ws),
                        result => Err(CfCandidateFailure::Connect(Box::new(result))),
                    }
                }
            },
            should_stop_cf_proxy_race,
        )
        .await;

        let route_unavailable = should_stop_cf_proxy_race(&failures);
        for (domain, failure) in failures {
            match failure {
                CfCandidateFailure::ProbeBusy => debug!(
                    "[{}] DC{}{}: параллельная проверка CF-домена {} уже выполняется",
                    self.label, self.dc, self.media, domain
                ),
                CfCandidateFailure::Connect(result) => match cf_failure_action(&result) {
                    CfFailureAction::RateLimited => {
                        self.runtime.cf_domain_pool().mark_rate_limited(&domain);
                        warn!(
                            "[{}] DC{}{}: CF-домен {} ограничил частоту (HTTP 429); включён cooldown",
                            self.label, self.dc, self.media, domain
                        );
                    }
                    CfFailureAction::ServiceUnavailable => {
                        let route_key = (self.dc, self.is_media, dst.to_string(), domain.clone());
                        CF_PROXY_503_FAIL.set(route_key, CF_PROXY_503_COOLDOWN);
                        warn!(
                            "[{}] DC{}{}: CF-домен {} ответил HTTP 503; маршрут приостановлен на {} с",
                            self.label,
                            self.dc,
                            self.media,
                            domain,
                            CF_PROXY_503_COOLDOWN.as_secs()
                        );
                    }
                    CfFailureAction::RouteCooldown => {
                        let route_key = (self.dc, self.is_media, dst.to_string(), domain.clone());
                        CF_PROXY_FAIL.set(route_key, self.timeouts.cf_fail_cooldown);
                        warn!(
                            "[{}] DC{}{}: CF-домен {}: {:?}; маршрут приостановлен на {} с",
                            self.label,
                            self.dc,
                            self.media,
                            domain,
                            result,
                            self.timeouts.cf_fail_cooldown.as_secs()
                        );
                    }
                    CfFailureAction::Rotate => warn!(
                        "[{}] DC{}{}: CF-домен {} ответил {:?}; пробую следующий без сетевого cooldown",
                        self.label, self.dc, self.media, domain, result
                    ),
                },
            }
        }

        if let Some((domain, ws)) = winner {
            CF_PROXY_ROUTE_FAIL.clear(&route_key);
            info!(
                "[{}] DC{}{}: {} — подключение CF-прокси установлено ({})",
                self.label, self.dc, self.media, reason, domain
            );
            return Some((ws, domain));
        }

        if route_unavailable {
            CF_PROXY_ROUTE_FAIL.set(route_key, self.timeouts.cf_fail_cooldown);
            warn!(
                "[{}] DC{}{}: CF proxy для {} получил два сетевых отказа; повторная проверка через {} с",
                self.label,
                self.dc,
                self.media,
                dst,
                self.timeouts.cf_fail_cooldown.as_secs()
            );
        }

        advance_cf_proxy_domain(self.dc, &pool.domains, domains.len());
        None
    }

    /// Open a fresh direct WebSocket to `target_ip`, always fronted when
    /// `--fronting-domain` is set, and applying the per-route cooldown on
    /// failure.
    async fn direct_ws(&self, target_ip: &str) -> Option<TgWsStream> {
        // `--fronting-domain` means the very first ClientHello carries the
        // fronted SNI. A reactive "front only after the direct SNI times out"
        // switch sends the real `telegram.org` SNI first, which networks that
        // RST it on sight never let through (#111) — so there is nothing left
        // to decide here: front when configured, otherwise don't.
        // Повторная проверка известного маршрута выполняется коротко и не
        // чаще одного раза за интервал; параллельные подключения используют CF.
        let route_key = direct_route_key(self.dc, self.is_media, target_ip);
        let was_ip_failure = IP_FAIL.contains(&route_key);
        let probing = WS_FAIL.contains(&route_key) || was_ip_failure;
        let _probe = if probing {
            if WS_PROBE_WAIT.active(&route_key) {
                return None;
            }
            let permit = ACTIVE_DIRECT_PROBES.try_acquire(route_key.clone())?;
            WS_PROBE_WAIT.set(route_key.clone(), self.timeouts.ws_fail_probe);
            Some(permit)
        } else {
            None
        };
        let attempt = self.connect_ws(target_ip, probing).await;

        if let Some(ws) = attempt.ws {
            IP_FAIL.clear(&route_key);
            WS_PROBE_WAIT.clear(&route_key);
            info!(
                "[{}] DC{}{}: WSS подключение установлено через {}",
                self.label, self.dc, self.media, target_ip
            );

            return Some(ws);
        }

        self.cool_down_ws(&route_key, attempt.all_redirects);

        // Only a TCP connect that ran out the clock says the address itself is
        // unreachable.  A redirect, a refusal, or a handshake that stalled all
        // came from a host that is very much there, and taking it out of the
        // rotation for an hour on that basis would be wrong.
        if attempt.connect_timed_out && (!probing || was_ip_failure) {
            self.cool_down_ip(&route_key, target_ip);
        } else if !attempt.connect_timed_out {
            IP_FAIL.clear(&route_key);
        }

        None
    }

    async fn connect_ws(&self, target_ip: &str, probing: bool) -> WsAttempt {
        let timeout = if probing {
            self.timeouts.ws_fail_probe
        } else {
            self.timeouts.ws_connect
        };

        connect_ws_for_dc_with_outbound(
            target_ip,
            self.runtime.websocket_dc(self.dc),
            self.is_media,
            timeout,
            self.runtime.outbound(),
        )
        .await
    }

    /// Back off from this DC's WebSocket path after a failed attempt.
    ///
    /// A cooldown rather than a permanent blacklist, so the proxy recovers
    /// automatically if WS becomes available again (e.g. after a network
    /// change or a Telegram-side redirect policy change).
    fn cool_down_ws(&self, route_key: &DirectRouteKey, all_redirects: bool) {
        let cooldown = if all_redirects {
            self.timeouts.ws_redirect_cooldown
        } else {
            self.timeouts.ws_fail_cooldown
        };
        WS_FAIL.set(route_key.clone(), cooldown);

        if all_redirects {
            warn!(
                "[{}] DC{}{}: пауза WS {} с (все домены перенаправили запрос)",
                self.label,
                self.dc,
                self.media,
                cooldown.as_secs()
            );
        } else {
            info!(
                "[{}] DC{}{}: пауза WS {} с",
                self.label,
                self.dc,
                self.media,
                cooldown.as_secs()
            );
        }
    }

    /// Back off from a target IP whose TCP connect timed out.
    ///
    fn cool_down_ip(&self, route_key: &DirectRouteKey, target_ip: &str) {
        IP_FAIL.set(route_key.clone(), self.timeouts.ip_fail_cooldown);
        info!(
            "[{}] DC{}{}: истекло время TCP-подключения к {}, пауза {} с",
            self.label,
            self.dc,
            self.media,
            target_ip,
            self.timeouts.ip_fail_cooldown.as_secs()
        );
    }

    /// Последний direct TCP путь к проверенному адресу назначения.
    fn tcp_last_resort(&self, target_ip: &str, reason: &str) -> Option<Upstream> {
        let route_key = direct_route_key(self.dc, self.is_media, target_ip);
        if self.timeouts.tcp_fallback.is_zero() {
            info!(
                "[{}] DC{}{}: прямой TCP fallback отключён настройкой",
                self.label, self.dc, self.media
            );
            return None;
        }
        if IP_FAIL.active(&route_key) {
            info!(
                "[{}] DC{}{}: прямой TCP к {} пропущен до истечения cooldown",
                self.label, self.dc, self.media, target_ip
            );
            return None;
        }
        Some(self.tcp_fallback(target_ip, reason))
    }

    fn tcp_fallback(&self, dst: &str, reason: &str) -> Upstream {
        info!(
            "[{}] DC{}{}: {} — резервное TCP-подключение к {}:443",
            self.label, self.dc, self.media, reason, dst
        );

        Upstream::Tcp(dst.to_string())
    }
}

#[cfg(test)]
mod tests {
    use super::{
        ACTIVE_CF_PROXY_ROUTE_PROBES, ACTIVE_DIRECT_PROBES, CF_PROXY_503_COOLDOWN,
        CF_PROXY_503_FAIL, CF_PROXY_DIALS, CF_PROXY_FAIL, CF_PROXY_OFFSET, CF_PROXY_ROUTE_FAIL,
        CF_PROXY_STICKY, CfCandidateFailure, CfFailureAction, HedgePermit, IP_FAIL, PREFERRED_CF,
        ROUTE_LATENCIES, Route, RouteFeedback, WS_FAIL, WsConnectResult, advance_cf_proxy_domain,
        cf_failure_action, cf_proxy_domain_order, first_wss_success, race_candidates,
        record_mtproto_failure, record_mtproto_response, remember_cf_proxy_success,
        should_hedge_direct_recovery, should_stop_cf_proxy_race,
    };
    use crate::config::{Config, WsRoutingPolicy};
    use crate::outbound::OutboundConnector;
    use crate::runtime::Runtime;
    use std::io::{self, Write};
    use std::net::SocketAddr;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    static HEDGE_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

    #[test]
    fn повторная_проверка_direct_при_ip_cooldown_требует_adaptive_hedge() {
        assert!(should_hedge_direct_recovery(
            WsRoutingPolicy::Adaptive,
            true,
            1
        ));
        assert!(should_hedge_direct_recovery(
            WsRoutingPolicy::Hedged,
            true,
            1
        ));
        assert!(!should_hedge_direct_recovery(
            WsRoutingPolicy::Sequential,
            true,
            1
        ));
        assert!(!should_hedge_direct_recovery(
            WsRoutingPolicy::CfFirst,
            true,
            1
        ));
        assert!(!should_hedge_direct_recovery(
            WsRoutingPolicy::Adaptive,
            false,
            1
        ));
        assert!(!should_hedge_direct_recovery(
            WsRoutingPolicy::Adaptive,
            true,
            0
        ));
    }

    #[test]
    fn cf_proxy_dial_budget_allows_eight_parallel_connections() {
        let permits = CF_PROXY_DIALS
            .try_acquire_many(8)
            .expect("CF fallback must allow eight simultaneous WSS dials");
        assert_eq!(CF_PROXY_DIALS.available_permits(), 0);
        drop(permits);
    }

    #[tokio::test]
    async fn cf_route_cooldown_skips_retries_and_releases_single_flight_probe() {
        let dc = 995;
        let ip = "149.154.167.55";
        let key = (dc, false, ip.to_string());
        let config = Config::try_from_cli_line("--tcp-fallback-timeout=1").unwrap();
        let runtime = Runtime::new(OutboundConnector::direct());
        let route = Route::new(
            "127.0.0.1:12345".parse().unwrap(),
            &config,
            &runtime,
            dc,
            false,
        );

        CF_PROXY_ROUTE_FAIL.set(key.clone(), Duration::from_secs(30));
        assert!(route.cf_proxy(ip, "test").await.is_none());
        assert!(CF_PROXY_ROUTE_FAIL.active(&key));

        CF_PROXY_ROUTE_FAIL.set(key.clone(), Duration::ZERO);
        assert!(!CF_PROXY_ROUTE_FAIL.active(&key));
        assert!(CF_PROXY_ROUTE_FAIL.contains(&key));
        assert!(route.cf_proxy(ip, "test").await.is_none());
        assert!(CF_PROXY_ROUTE_FAIL.active(&key));
        let probe = ACTIVE_CF_PROXY_ROUTE_PROBES
            .try_acquire(key.clone())
            .expect("probe permit is released after an empty candidate pool");

        drop(probe);
        CF_PROXY_ROUTE_FAIL.clear(&key);
    }

    #[derive(Clone)]
    struct LogBuffer(Arc<Mutex<Vec<u8>>>);

    impl Write for LogBuffer {
        fn write(&mut self, bytes: &[u8]) -> io::Result<usize> {
            self.0.lock().unwrap().extend_from_slice(bytes);
            Ok(bytes.len())
        }

        fn flush(&mut self) -> io::Result<()> {
            Ok(())
        }
    }

    impl<'a> tracing_subscriber::fmt::MakeWriter<'a> for LogBuffer {
        type Writer = Self;

        fn make_writer(&'a self) -> Self::Writer {
            self.clone()
        }
    }

    struct DropFlag(Arc<AtomicBool>);

    impl Drop for DropFlag {
        fn drop(&mut self) {
            self.0.store(true, Ordering::SeqCst);
        }
    }

    #[tokio::test]
    async fn first_success_cancels_the_losing_attempt() {
        let direct_cancelled = Arc::new(AtomicBool::new(false));
        let cf_started = Arc::new(AtomicBool::new(false));
        let direct_flag = Arc::clone(&direct_cancelled);
        let cf_flag = Arc::clone(&cf_started);

        let result = first_wss_success(
            async move {
                let _drop_flag = DropFlag(direct_flag);
                tokio::time::sleep(Duration::from_secs(1)).await;
                Some("direct")
            },
            async move {
                cf_flag.store(true, Ordering::SeqCst);
                tokio::time::sleep(Duration::from_millis(1)).await;
                Some("cf")
            },
            Duration::from_millis(5),
        )
        .await;

        assert_eq!(result, Some("cf"));
        assert!(cf_started.load(Ordering::SeqCst));
        assert!(direct_cancelled.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn гонка_доменов_отменяет_проигравшее_подключение() {
        let slow_cancelled = Arc::new(AtomicBool::new(false));
        let fast_started = Arc::new(AtomicBool::new(false));
        let slow_flag = Arc::clone(&slow_cancelled);
        let fast_flag = Arc::clone(&fast_started);

        let (winner, failures) = race_candidates(
            vec!["slow.example".to_string(), "fast.example".to_string()],
            Duration::from_millis(5),
            move |domain| {
                let slow_flag = Arc::clone(&slow_flag);
                let fast_flag = Arc::clone(&fast_flag);
                async move {
                    if domain == "slow.example" {
                        let _drop_flag = DropFlag(slow_flag);
                        std::future::pending::<Result<&'static str, &'static str>>().await
                    } else {
                        fast_flag.store(true, Ordering::SeqCst);
                        Ok("fast")
                    }
                }
            },
            |_| false,
        )
        .await;

        assert_eq!(winner, Some(("fast.example".to_string(), "fast")));
        assert!(failures.is_empty());
        assert!(fast_started.load(Ordering::SeqCst));
        assert!(slow_cancelled.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn гонка_доменов_ограничивает_число_попыток_двумя() {
        use std::sync::atomic::AtomicUsize;

        struct Active(Arc<AtomicUsize>);
        impl Drop for Active {
            fn drop(&mut self) {
                self.0.fetch_sub(1, Ordering::SeqCst);
            }
        }

        let active = Arc::new(AtomicUsize::new(0));
        let maximum = Arc::new(AtomicUsize::new(0));
        let active_for_dial = Arc::clone(&active);
        let maximum_for_dial = Arc::clone(&maximum);
        let domains = (0..8).map(|i| format!("d{i}.example")).collect();

        let (winner, _) = race_candidates(
            domains,
            Duration::from_millis(5),
            move |domain| {
                let active = Arc::clone(&active_for_dial);
                let maximum = Arc::clone(&maximum_for_dial);
                async move {
                    let now = active.fetch_add(1, Ordering::SeqCst) + 1;
                    maximum.fetch_max(now, Ordering::SeqCst);
                    let _active = Active(active);
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    if domain == "d5.example" {
                        Ok(domain)
                    } else {
                        Err(domain)
                    }
                }
            },
            |_| false,
        )
        .await;

        assert!(winner.is_some());
        assert_eq!(maximum.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn гонка_cf_останавливается_после_двух_сетевых_ошибок() {
        use std::sync::atomic::AtomicUsize;

        let attempts = Arc::new(AtomicUsize::new(0));
        let attempts_for_connect = Arc::clone(&attempts);
        let domains = (0..20).map(|i| format!("d{i}.example")).collect();
        let (winner, failures) = race_candidates(
            domains,
            Duration::from_millis(1),
            move |domain| {
                let attempts = Arc::clone(&attempts_for_connect);
                async move {
                    attempts.fetch_add(1, Ordering::SeqCst);
                    Err::<(), CfCandidateFailure>(CfCandidateFailure::Connect(Box::new(
                        WsConnectResult::ConnectTimedOut(domain),
                    )))
                }
            },
            should_stop_cf_proxy_race,
        )
        .await;

        assert!(winner.is_none());
        assert!(attempts.load(Ordering::SeqCst) <= 3);
        assert_eq!(failures.len(), 2);
    }

    #[tokio::test]
    async fn cf_гонка_продолжается_после_http_ответа_и_принимает_следующий_домен() {
        let (winner, failures) = race_candidates(
            vec![
                "a.example".to_string(),
                "b.example".to_string(),
                "c.example".to_string(),
            ],
            Duration::from_millis(1),
            |domain| async move {
                match domain.as_str() {
                    "a.example" => Err(CfCandidateFailure::Connect(Box::new(
                        WsConnectResult::ConnectTimedOut("a unreachable".to_string()),
                    ))),
                    "b.example" => Err(CfCandidateFailure::Connect(Box::new(
                        WsConnectResult::HttpStatus(503),
                    ))),
                    _ => Ok::<String, CfCandidateFailure>(domain),
                }
            },
            should_stop_cf_proxy_race,
        )
        .await;

        assert_eq!(
            winner,
            Some(("c.example".to_string(), "c.example".to_string()))
        );
        assert_eq!(failures.len(), 2);
    }

    #[test]
    fn cf_proxy_различает_429_503_и_тайм_аут() {
        assert_eq!(
            cf_failure_action(&WsConnectResult::HttpStatus(429)),
            CfFailureAction::RateLimited
        );
        assert_eq!(
            cf_failure_action(&WsConnectResult::HttpStatus(503)),
            CfFailureAction::ServiceUnavailable
        );
        assert_eq!(
            cf_failure_action(&WsConnectResult::TimedOut),
            CfFailureAction::RouteCooldown
        );
    }

    #[test]
    fn короткий_503_cooldown_ограничен_конкретным_dc_и_назначением() {
        let route = (
            1995,
            false,
            "149.154.167.50".to_string(),
            "alpha.example".to_string(),
        );
        let other_dc = (1996, false, route.2.clone(), route.3.clone());
        let other_destination = (1995, false, "149.154.167.51".to_string(), route.3.clone());

        CF_PROXY_503_FAIL.set(route.clone(), CF_PROXY_503_COOLDOWN);

        assert!(CF_PROXY_503_FAIL.active(&route));
        assert!(!CF_PROXY_503_FAIL.active(&other_dc));
        assert!(!CF_PROXY_503_FAIL.active(&other_destination));
        CF_PROXY_503_FAIL.clear(&route);
    }

    #[test]
    fn cf_proxy_сохраняет_маршрут_dc_и_вращает_его_после_сбоя() {
        let dc = 997;
        let domains = [
            "alpha.example".to_string(),
            "beta.example".to_string(),
            "gamma.example".to_string(),
        ];
        remember_cf_proxy_success(dc, &domains, "beta.example");
        assert_eq!(
            cf_proxy_domain_order(&domains, dc, false)[0],
            "beta.example"
        );

        let refreshed = [
            "beta.example".to_string(),
            "gamma.example".to_string(),
            "delta.example".to_string(),
        ];
        assert_eq!(
            cf_proxy_domain_order(&refreshed, dc, false)[0],
            "beta.example"
        );
        advance_cf_proxy_domain(dc, &refreshed, 1);
        assert_eq!(
            cf_proxy_domain_order(&refreshed, dc, false)[0],
            "delta.example"
        );

        CF_PROXY_STICKY.lock().unwrap().remove(&dc);
        CF_PROXY_OFFSET.lock().unwrap().remove(&dc);
    }

    #[test]
    fn полный_отказ_cf_пула_сдвигает_следующий_стартовый_домен() {
        let dc = 996;
        let domains = [
            "alpha.example".to_string(),
            "beta.example".to_string(),
            "gamma.example".to_string(),
        ];
        remember_cf_proxy_success(dc, &domains, "beta.example");

        advance_cf_proxy_domain(dc, &domains, domains.len());

        assert_eq!(
            cf_proxy_domain_order(&domains, dc, false)[0],
            "gamma.example"
        );
        CF_PROXY_STICKY.lock().unwrap().remove(&dc);
        CF_PROXY_OFFSET.lock().unwrap().remove(&dc);
    }

    #[test]
    fn direct_cooldowns_are_scoped_by_dc_media_and_ip() {
        let route = (2, true, "149.154.167.151".to_string());
        let other_ip = (2, true, "149.154.167.152".to_string());
        let non_media = (2, false, "149.154.167.151".to_string());
        let other_dc = (4, true, "149.154.167.151".to_string());

        WS_FAIL.set(route.clone(), Duration::from_secs(60));
        IP_FAIL.set(route.clone(), Duration::from_secs(60));
        assert!(WS_FAIL.active(&route));
        assert!(IP_FAIL.active(&route));
        for other in [&other_ip, &non_media, &other_dc] {
            assert!(!WS_FAIL.active(other));
            assert!(!IP_FAIL.active(other));
        }
        WS_FAIL.clear(&route);
        IP_FAIL.clear(&route);
    }

    #[test]
    fn прямой_tcp_fallback_пропускается_пока_ip_на_паузе() {
        let config = Config::try_from_cli_line("--tcp-fallback-timeout=1").unwrap();
        let runtime = Runtime::new(OutboundConnector::direct());
        let route = Route::new(
            "127.0.0.1:12345".parse().unwrap(),
            &config,
            &runtime,
            2,
            false,
        );
        let target_ip = "149.154.167.51";
        let route_key = (2, false, target_ip.to_string());
        super::record_tcp_connect_failure(2, false, target_ip, Duration::from_secs(60));
        assert!(IP_FAIL.active(&route_key));

        assert!(
            route
                .tcp_last_resort(target_ip, "регрессионный тест")
                .is_none()
        );

        super::record_tcp_connect_success(2, false, target_ip);
        assert!(!IP_FAIL.active(&route_key));
        assert!(route.tcp_last_resort(target_ip, "после cooldown").is_some());

        let disabled_config = Config::try_from_cli_line("--tcp-fallback-timeout=0").unwrap();
        let disabled_route = Route::new(
            "127.0.0.1:12345".parse().unwrap(),
            &disabled_config,
            &runtime,
            2,
            false,
        );
        assert!(
            disabled_route
                .tcp_last_resort(target_ip, "резерв отключён")
                .is_none()
        );
    }

    #[test]
    fn direct_route_probe_is_single_flight_and_released_on_drop() {
        let route = (2, true, "149.154.167.151".to_string());
        let first = ACTIVE_DIRECT_PROBES
            .try_acquire(route.clone())
            .expect("первая проверка маршрута должна получить слот");
        assert!(ACTIVE_DIRECT_PROBES.try_acquire(route.clone()).is_none());
        drop(first);
        assert!(ACTIVE_DIRECT_PROBES.try_acquire(route).is_some());
    }

    #[test]
    fn cloudflare_proxy_cooldowns_are_scoped_by_dc_media_ip_and_domain() {
        let route = (
            2,
            true,
            "149.154.167.151".to_string(),
            "edge.example".to_string(),
        );
        let other_ip = (
            2,
            true,
            "149.154.167.152".to_string(),
            "edge.example".to_string(),
        );
        let non_media = (
            2,
            false,
            "149.154.167.151".to_string(),
            "edge.example".to_string(),
        );
        let other_dc = (
            4,
            true,
            "149.154.167.151".to_string(),
            "edge.example".to_string(),
        );
        let other_domain = (
            2,
            true,
            "149.154.167.151".to_string(),
            "other.example".to_string(),
        );

        CF_PROXY_FAIL.set(route.clone(), Duration::from_secs(60));
        assert!(CF_PROXY_FAIL.active(&route));
        for other in [&other_ip, &non_media, &other_dc, &other_domain] {
            assert!(!CF_PROXY_FAIL.active(other));
        }
        CF_PROXY_FAIL.clear(&route);
    }

    #[test]
    fn recent_cf_route_preference_is_scoped_by_dc_media_and_ip() {
        let route = (2, true, "149.154.167.151".to_string());
        let other_ip = (2, true, "149.154.167.152".to_string());
        let non_media = (2, false, "149.154.167.151".to_string());

        PREFERRED_CF.set(route.clone(), Duration::from_secs(60));
        assert!(PREFERRED_CF.active(&route));
        assert!(!PREFERRED_CF.active(&other_ip));
        assert!(!PREFERRED_CF.active(&non_media));
        PREFERRED_CF.clear(&route);
    }

    #[test]
    fn cf_маршрут_становится_предпочтительным_после_ответа_mtproto() {
        let dc = 987;
        let ip = "149.154.167.151".to_string();
        let domain = "alpha.example.co.uk".to_string();
        let route = (dc, true, ip.clone());
        let cf_route = (dc, true, ip.clone(), domain.clone());
        let direct_feedback = RouteFeedback::direct(dc, true, &ip, Duration::from_secs(30));
        let pool = Arc::new(crate::cf_domain_pool::CfDomainPool::new(
            Vec::new(),
            false,
            std::env::temp_dir().join(format!("tg-cf-feedback-{}.json", std::process::id())),
        ));
        let feedback = RouteFeedback::cf_proxy(
            dc,
            true,
            ip,
            domain.clone(),
            Arc::clone(&pool),
            Duration::from_secs(30),
        );

        assert!(
            !PREFERRED_CF.active(&route),
            "HTTP 101 сам по себе не выбирает CF первым"
        );
        record_mtproto_response(&direct_feedback, Duration::from_millis(250));
        assert!(
            !PREFERRED_CF.active(&route),
            "одного измеренного маршрута недостаточно"
        );
        CF_PROXY_FAIL.set(cf_route.clone(), Duration::from_secs(30));
        pool.mark_rate_limited(&domain);
        record_mtproto_response(&feedback, Duration::from_millis(80));

        assert!(PREFERRED_CF.active(&route));
        assert!(!CF_PROXY_FAIL.active(&cf_route));
        assert!(!pool.is_rate_limited(&domain));
        assert_eq!(CF_PROXY_STICKY.lock().unwrap().get(&dc), Some(&domain));
        PREFERRED_CF.clear(&route);
        CF_PROXY_FAIL.clear(&cf_route);
        CF_PROXY_STICKY.lock().unwrap().remove(&dc);
        ROUTE_LATENCIES.lock().unwrap().remove(&route);
    }

    #[test]
    fn успешный_cf_маршрут_предпочитается_пока_direct_не_доказан_быстрее() {
        let dc = 989;
        let ip = "149.154.167.153".to_string();
        let domain = "known-fast.example.co.uk".to_string();
        let route = (dc, true, ip.clone());
        let pool = Arc::new(crate::cf_domain_pool::CfDomainPool::new(
            Vec::new(),
            false,
            std::env::temp_dir().join(format!("tg-cf-unknown-direct-{}.json", std::process::id())),
        ));
        let feedback = RouteFeedback::cf_proxy(dc, true, ip, domain, pool, Duration::from_secs(30));

        record_mtproto_response(&feedback, Duration::from_millis(80));

        assert!(PREFERRED_CF.active(&route));
        CF_PROXY_STICKY.lock().unwrap().remove(&dc);
        PREFERRED_CF.clear(&route);
        ROUTE_LATENCIES.lock().unwrap().remove(&route);
    }

    #[test]
    fn быстрый_direct_wss_остаётся_предпочтительным() {
        let dc = 986;
        let ip = "149.154.167.151";
        let route = (dc, true, ip.to_string());
        let direct = RouteFeedback::direct(dc, true, ip, Duration::from_secs(30));
        let pool = Arc::new(crate::cf_domain_pool::CfDomainPool::new(
            Vec::new(),
            false,
            std::env::temp_dir().join(format!("tg-cf-latency-{}.json", std::process::id())),
        ));
        let cf = RouteFeedback::cf_proxy(
            dc,
            true,
            ip.to_string(),
            "edge.example.co.uk".to_string(),
            pool,
            Duration::from_secs(30),
        );

        record_mtproto_response(&direct, Duration::from_millis(40));
        record_mtproto_response(&cf, Duration::from_millis(160));

        assert!(!PREFERRED_CF.active(&route));
        ROUTE_LATENCIES.lock().unwrap().remove(&route);
        CF_PROXY_STICKY.lock().unwrap().remove(&dc);
    }

    #[test]
    fn cf_маршрут_без_ответа_mtproto_получает_паузы() {
        let dc = 988;
        let ip = "149.154.167.151".to_string();
        let domain = "beta.example.co.uk".to_string();
        let route = (dc, true, ip.clone());
        let cf_route = (dc, true, ip.clone(), domain.clone());
        let pool = Arc::new(crate::cf_domain_pool::CfDomainPool::new(
            Vec::new(),
            false,
            std::env::temp_dir().join(format!("tg-cf-feedback-{}.json", std::process::id())),
        ));
        let feedback = RouteFeedback::cf_proxy(dc, true, ip, domain, pool, Duration::from_secs(30));

        record_mtproto_failure(&feedback);

        assert!(CF_PROXY_FAIL.active(&cf_route));
        assert!(!PREFERRED_CF.active(&route));
        CF_PROXY_FAIL.clear(&cf_route);
    }

    #[tokio::test(flavor = "current_thread")]
    async fn cloudflare_worker_uses_the_validated_dynamic_dc_address() {
        let output = Arc::new(Mutex::new(Vec::new()));
        let subscriber = tracing_subscriber::fmt()
            .with_ansi(false)
            .with_max_level(tracing::Level::DEBUG)
            .with_writer(LogBuffer(Arc::clone(&output)))
            .finish();
        let dispatch = tracing::Dispatch::new(subscriber);
        let _guard = tracing::dispatcher::set_default(&dispatch);

        let config =
            Config::try_from_cli_line("--cf-worker-domain=127.0.0.1 --cf-connect-timeout=1")
                .unwrap();
        let runtime = Runtime::new(OutboundConnector::direct());
        let route = Route::new(
            SocketAddr::from(([127, 0, 0, 1], 1443)),
            &config,
            &runtime,
            2,
            true,
        );

        let _ = route
            .cf_worker("149.154.167.151", "тест динамического media DC")
            .await;

        let logs = String::from_utf8(output.lock().unwrap().clone()).unwrap();
        assert!(
            logs.contains("для 149.154.167.151"),
            "Worker должен получить проверенный адрес media DC, логи: {logs}"
        );
    }

    #[tokio::test]
    async fn hedge_limit_is_bounded_and_released_by_drop() {
        let _guard = HEDGE_TEST_LOCK.lock().await;
        let first = HedgePermit::try_acquire(1).expect("первый hedge должен получить слот");
        assert!(HedgePermit::try_acquire(1).is_none());
        drop(first);
        assert!(HedgePermit::try_acquire(1).is_some());
        assert!(HedgePermit::try_acquire(0).is_none());
    }

    #[tokio::test]
    async fn hedge_waiter_gets_a_slot_after_an_active_probe_finishes() {
        let _guard = HEDGE_TEST_LOCK.lock().await;
        let active = HedgePermit::try_acquire(1).expect("первый hedge должен получить слот");
        let waiter = tokio::spawn(async { HedgePermit::acquire(1).await });
        tokio::task::yield_now().await;
        assert!(
            !waiter.is_finished(),
            "ожидающий hedge не должен обойти лимит"
        );

        drop(active);
        let permit = tokio::time::timeout(Duration::from_secs(1), waiter)
            .await
            .expect("освобождённый hedge-слот должен разбудить ожидающий запрос")
            .expect("задача hedge не должна паниковать");
        drop(permit);
    }
}
