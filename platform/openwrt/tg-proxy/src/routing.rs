//! Выбор direct WSS, Cloudflare fallback и TCP по проверенному DC/media маршруту.

use std::net::SocketAddr;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::time::Duration;

use tracing::{debug, info, warn};

use crate::config::{Config, WsRoutingPolicy};
use crate::runtime::Runtime;
use crate::ws_client::{
    CfDialOpts, CooldownMap, ProbeSet, TgWsStream, WsAttempt,
    connect_cf_worker_ws_for_dc_with_outbound_opts, connect_cf_ws_for_dc_with_outbound_ordered,
    connect_ws_for_dc_with_outbound, media_tag,
};
// ─── Failure cooldowns ───────────────────────────────────────────────────────

type DirectRouteKey = (u32, bool, String);
type WorkerRouteKey = (u32, bool, String, String);
type CfProxyRouteKey = (u32, bool, String, String);
const CF_PREFERENCE_TTL: Duration = Duration::from_secs(30);

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
static ACTIVE_CF_PROXY_PROBES: ProbeSet<CfProxyRouteKey> = ProbeSet::new();
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
        if has_fallback
            && let Some(upstream) = route.fallback_chain(target_ip, "ожидание direct IP").await
        {
            return Some(upstream);
        }
        return Some(route.tcp_last_resort(target_ip, "ожидание direct IP"));
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
        return Some(route.tcp_last_resort(target_ip, "ожидание direct WSS"));
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
            PREFERRED_CF.set(route_key.clone(), CF_PREFERENCE_TTL);
            return Some(upstream);
        }
        if let Some(upstream) = route.direct_ws_tier(target_ip).await {
            PREFERRED_CF.clear(&route_key);
            return Some(upstream);
        }
        return Some(route.tcp_last_resort(target_ip, "отказ недавних WSS маршрутов"));
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
                PREFERRED_CF.set(route_key.clone(), CF_PREFERENCE_TTL);
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
            if matches!(
                &upstream,
                Upstream::Ws { route_type, .. }
                    if route_type.starts_with("WSS через Cloudflare")
            ) {
                PREFERRED_CF.set(route_key.clone(), CF_PREFERENCE_TTL);
            } else {
                PREFERRED_CF.clear(&route_key);
            }
            return Some(upstream);
        }
        return Some(route.tcp_last_resort(target_ip, "сбой WSS"));
    }

    if let Some(upstream) = route.direct_ws_tier(target_ip).await {
        return Some(upstream);
    }

    if !cf_first && let Some(upstream) = route.fallback_chain(target_ip, "сбой WSS").await {
        return Some(upstream);
    }
    Some(route.tcp_last_resort(target_ip, "сбой WSS"))
}

impl Route<'_> {
    /// Открыть direct WSS к проверенному IP назначения.
    async fn direct_ws_tier(&self, target_ip: &str) -> Option<Upstream> {
        self.direct_ws(target_ip).await.map(|ws| Upstream::Ws {
            ws: Box::new(ws),
            framing: WsFraming::Packets,
            route_type: "прямой WSS",
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
        if let Some(ws) = self.cf_worker(dst, reason).await {
            return Some(Upstream::Ws {
                ws: Box::new(ws),
                framing: WsFraming::Tunnel,
                route_type: "WSS через Cloudflare Worker",
            });
        }

        self.cf_proxy(dst, reason).await.map(|ws| Upstream::Ws {
            ws: Box::new(ws),
            framing: WsFraming::Packets,
            route_type: "WSS через Cloudflare proxy",
        })
    }

    /// Whether anything other than the direct WebSocket path is configured.
    fn has_fallback(&self) -> bool {
        !self.config.cf_worker_domains().is_empty() || !self.config.cf_domains.is_empty()
    }

    /// Перебрать настроенные Cloudflare Worker по порядку балансировки.
    async fn cf_worker(&self, dst: &str, reason: &str) -> Option<TgWsStream> {
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
                    CF_WORKER_FAIL.clear(&route_key);
                    info!(
                        "[{}] DC{}{}: {} — соединение Cloudflare Worker установлено ({})",
                        self.label, self.dc, self.media, reason, worker_domain
                    );
                    return Some(ws);
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
    async fn cf_proxy(&self, dst: &str, reason: &str) -> Option<TgWsStream> {
        if self.config.cf_domains.is_empty() {
            return None;
        }

        let first_domain = balance_offset(
            &self.config.cf_domains,
            self.config.cf_balance,
            &CF_BALANCE_COUNTER,
        );

        debug!(
            "[{}] DC{}{}: {} — проверка CF-прокси через {:?}",
            self.label, self.dc, self.media, reason, self.config.cf_domains
        );

        for domain in domain_order(&self.config.cf_domains, first_domain).map(str::to_owned) {
            let route_key = (self.dc, self.is_media, dst.to_string(), domain.clone());
            if CF_PROXY_FAIL.active(&route_key) {
                debug!(
                    "[{}] DC{}{}: CF proxy {} на паузе, пропуск",
                    self.label, self.dc, self.media, domain
                );
                continue;
            }
            let _probe = if CF_PROXY_FAIL.contains(&route_key) {
                let Some(permit) = ACTIVE_CF_PROXY_PROBES.try_acquire(route_key.clone()) else {
                    continue;
                };
                Some(permit)
            } else {
                None
            };

            let single_domain = [domain.clone()];
            let (ws, _, _) = connect_cf_ws_for_dc_with_outbound_ordered(
                self.dc,
                &single_domain,
                self.is_media,
                self.timeouts.cf_connect,
                self.runtime.outbound(),
                0,
                CfDialOpts {
                    cf_ips: self.runtime.cf_ips(),
                    fail_cooldown: self.timeouts.cf_fail_cooldown,
                },
            )
            .await;

            if let Some(ws) = ws {
                CF_PROXY_FAIL.clear(&route_key);
                info!(
                    "[{}] DC{}{}: {} — подключение CF-прокси установлено ({})",
                    self.label, self.dc, self.media, reason, domain
                );
                return Some(ws);
            }

            CF_PROXY_FAIL.set(route_key, self.timeouts.cf_fail_cooldown);
            warn!(
                "[{}] DC{}{}: CF proxy {} недоступен, пауза {} с",
                self.label,
                self.dc,
                self.media,
                domain,
                self.timeouts.cf_fail_cooldown.as_secs()
            );
        }

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
            WS_FAIL.clear(&route_key);
            IP_FAIL.clear(&route_key);
            WS_PROBE_WAIT.clear(&route_key);
            PREFERRED_CF.clear(&route_key);
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
    fn tcp_last_resort(&self, target_ip: &str, reason: &str) -> Upstream {
        self.tcp_fallback(target_ip, reason)
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
        ACTIVE_DIRECT_PROBES, CF_PROXY_FAIL, HedgePermit, IP_FAIL, PREFERRED_CF, Route, WS_FAIL,
        first_wss_success,
    };
    use crate::config::Config;
    use crate::outbound::OutboundConnector;
    use crate::runtime::Runtime;
    use std::io::{self, Write};
    use std::net::SocketAddr;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::sync::{Arc, Mutex};
    use std::time::Duration;

    static HEDGE_TEST_LOCK: tokio::sync::Mutex<()> = tokio::sync::Mutex::const_new(());

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
