//! WebSocket client for Telegram DC connections.
//!
//! Telegram exposes WebSocket endpoints at `wss://kwsN.web.telegram.org/apiws`
//! (where N is the DC id).  The proxy connects TCP to the configured **IP**
//! while using the **domain** as the TLS SNI / HTTP Host, matching the Python
//! reference implementation.
//!
//! DC numbers that don't have dedicated WebSocket hostnames (e.g. DC 203, the
//! test DC) are remapped to their canonical counterpart via
//! `config::websocket_dc()` before the domain is constructed, so the TLS
//! certificate presented by Telegram's servers remains valid.
//!
//! Сертификаты TLS всегда проверяются по встроенному хранилищу WebPKI.

use std::borrow::Borrow;
use std::collections::{HashMap, HashSet};
use std::hash::Hash;
use std::net::IpAddr;
use std::sync::atomic::{AtomicUsize, Ordering as AtomicOrdering};
use std::sync::{Arc, Mutex as StdMutex, OnceLock};
use std::time::{Duration, Instant};

use crate::config::websocket_dc;
use crate::outbound::OutboundConnector;

use futures_util::{SinkExt, StreamExt};
use tokio::net::TcpStream;
use tokio_tungstenite::{
    Connector, MaybeTlsStream, WebSocketStream, client_async_tls_with_config,
    tungstenite::{client::IntoClientRequest, http::HeaderValue},
};
use tracing::{debug, warn};
use tungstenite::Error as WsError;
use tungstenite::Message;
use tungstenite::protocol::WebSocketConfig;

/// A live WebSocket connection to a Telegram DC.
pub type TgWsStream = WebSocketStream<MaybeTlsStream<TcpStream>>;

/// Suffix that marks a media DC in log lines (`DC2` vs `DC2m`).
///
/// Every DC is logged together with its media flag, so this keeps the format
/// arguments readable at the ~30 call sites across the proxy.
pub(crate) fn media_tag(is_media: bool) -> &'static str {
    if is_media { "m" } else { "" }
}

// ─── Preferred Cloudflare edge IPs (--cf-ip) ─────────────────────────────────

/// Round-robin counter for `--cf-ip`, shared by every dial site so the load
/// spreads across the preferred edges instead of hammering the first one.
static CF_IP_ROTATION: AtomicUsize = AtomicUsize::new(0);

pub(crate) struct CooldownMap<K> {
    entries: StdMutex<Option<HashMap<K, Instant>>>,
}

impl<K: Eq + Hash> CooldownMap<K> {
    pub(crate) const fn new() -> Self {
        Self {
            entries: StdMutex::new(None),
        }
    }

    pub(crate) fn set(&self, key: K, cooldown: Duration) {
        self.entries
            .lock()
            .unwrap()
            .get_or_insert_with(HashMap::new)
            .insert(key, Instant::now() + cooldown);
    }

    pub(crate) fn clear<Q>(&self, key: &Q)
    where
        K: Borrow<Q>,
        Q: Hash + Eq + ?Sized,
    {
        if let Some(entries) = self.entries.lock().unwrap().as_mut() {
            entries.remove(key);
        }
    }

    pub(crate) fn active<Q>(&self, key: &Q) -> bool
    where
        K: Borrow<Q>,
        Q: Hash + Eq + ?Sized,
    {
        let entries = self.entries.lock().unwrap();
        match entries.as_ref().and_then(|entries| entries.get(key)) {
            Some(&until) => Instant::now() < until,
            None => false,
        }
    }

    pub(crate) fn contains<Q>(&self, key: &Q) -> bool
    where
        K: Borrow<Q>,
        Q: Hash + Eq + ?Sized,
    {
        self.entries
            .lock()
            .unwrap()
            .as_ref()
            .is_some_and(|entries| entries.contains_key(key))
    }
}

/// Один сетевой probe на маршрут одновременно.
pub(crate) struct ProbeSet<K> {
    entries: StdMutex<Option<HashSet<K>>>,
}

impl<K> ProbeSet<K> {
    pub(crate) const fn new() -> Self {
        Self {
            entries: StdMutex::new(None),
        }
    }
}

impl<K: Eq + Hash + Clone> ProbeSet<K> {
    pub(crate) fn try_acquire(&self, key: K) -> Option<ProbeGuard<'_, K>> {
        let mut entries = self.entries.lock().unwrap();
        if !entries.get_or_insert_with(HashSet::new).insert(key.clone()) {
            return None;
        }
        Some(ProbeGuard { set: self, key })
    }
}

pub(crate) struct ProbeGuard<'a, K: Eq + Hash> {
    set: &'a ProbeSet<K>,
    key: K,
}

impl<K: Eq + Hash> Drop for ProbeGuard<'_, K> {
    fn drop(&mut self) {
        if let Some(entries) = self.set.entries.lock().unwrap().as_mut() {
            entries.remove(&self.key);
        }
    }
}

type CfEdgeRouteKey = (IpAddr, String, String);

static CF_EDGE_TLS_FAIL: CooldownMap<CfEdgeRouteKey> = CooldownMap::new();

/// Cloudflare-specific dial settings shared by proxy, Worker, and pool paths.
#[derive(Clone, Copy)]
pub struct CfDialOpts<'a> {
    pub cf_ips: &'a [IpAddr],
    pub fail_cooldown: Duration,
}

/// Starting index for one logical Cloudflare connection. Every configured IP
/// is still tried before failure; rotating only spreads which one gets first
/// chance.
fn cf_ip_start(ips: &[IpAddr]) -> usize {
    if ips.len() <= 1 {
        return 0;
    }
    CF_IP_ROTATION.fetch_add(1, AtomicOrdering::Relaxed) % ips.len()
}

fn cf_ip_attempts(
    ips: &[IpAddr],
    first: usize,
    domain: &str,
    route_scope: &str,
    cooldowns: &CooldownMap<CfEdgeRouteKey>,
) -> Vec<IpAddr> {
    let entries = cooldowns.entries.lock().unwrap();
    let now = Instant::now();
    let is_cooling = |ip: &IpAddr| {
        entries
            .as_ref()
            .and_then(|entries| entries.get(&(*ip, domain.to_string(), route_scope.to_string())))
            .is_some_and(|&until| now < until)
    };
    let all_cooling = ips.iter().all(is_cooling);
    let limit = if all_cooling { 1 } else { ips.len() };
    (0..ips.len())
        .map(move |offset| ips[(first + offset) % ips.len()])
        .filter(|ip| all_cooling || !is_cooling(ip))
        .take(limit)
        .collect()
}

/// WebSocket domains for a given DC.
///
/// Telegram provides two hostnames per DC; trying both increases resilience.
/// Media DCs prefer the `kwsN-1` variant first.
///
/// Non-standard DC numbers (e.g. DC 203, the test/alternate DC) are remapped
/// to their canonical WebSocket DC via `config::websocket_dc()` so that TLS
/// certificate validation succeeds — Telegram's wildcard cert only covers the
/// real DC numbers (1-5).
pub fn ws_domains(dc: u32, is_media: bool) -> Vec<String> {
    let effective_dc = websocket_dc(dc);

    ordered_records(
        format!("kws{}.web.telegram.org", effective_dc),
        format!("kws{}-1.web.telegram.org", effective_dc),
        is_media,
    )
}

/// Order a `kws{N}` / `kws{N}-1` record pair by preference: media DCs prefer
/// the `-1` variant, everything else prefers the base record.
fn ordered_records(base: String, dash_one: String, is_media: bool) -> Vec<String> {
    if is_media {
        vec![dash_one, base]
    } else {
        vec![base, dash_one]
    }
}

/// Outcome of a WebSocket connection attempt.
#[derive(Debug)]
#[allow(clippy::large_enum_variant)]
pub(crate) enum WsConnectResult {
    /// Successful WebSocket upgrade.
    Connected(TgWsStream),
    /// The server returned a redirect (301/302/303/307/308).
    /// Telegram sometimes does this when WS is unavailable — the caller
    /// should fall back to direct TCP.
    Redirect(u16),
    /// Any other non-101 status code or transport error.
    Failed(String),
    /// The TCP connect ran out the clock: nothing at `ip:443` answered.
    ///
    /// Distinct from [`Self::TimedOut`]: the TCP destination did not answer.
    ConnectTimedOut(String),
    /// TCP answered, but TLS or the WebSocket upgrade timed out.
    TimedOut,
}

/// Результат перебора WSS-доменов одного DC.
pub(crate) struct WsAttempt {
    pub ws: Option<TgWsStream>,
    /// Every hostname answered with a redirect — Telegram has taken the
    /// WebSocket path away for this DC rather than the network blocking it.
    pub all_redirects: bool,
    /// A TCP connect stalled: nothing at the address answered at all.
    pub connect_timed_out: bool,
}

impl WsAttempt {
    fn connected(ws: TgWsStream) -> Self {
        Self {
            ws: Some(ws),
            all_redirects: false,
            connect_timed_out: false,
        }
    }
}

/// Открыть TLS/WSS-соединение к заданному DC IP и домену.
async fn connect_ws_with_path(
    ip: &str,
    domain: &str,
    path: &str,
    request_binary_subprotocol: bool,
    timeout: Duration,
    outbound: &OutboundConnector,
) -> WsConnectResult {
    let tcp = match outbound.connect(ip, 443, timeout).await {
        Ok(stream) => stream,
        Err(error) if error.timed_out => return WsConnectResult::ConnectTimedOut(error.reason),
        Err(error) => return WsConnectResult::Failed(error.reason),
    };
    let _ = tcp.set_nodelay(true);

    let url = format!("wss://{domain}{path}");
    let mut request = match url.into_client_request() {
        Ok(request) => request,
        Err(error) => return WsConnectResult::Failed(format!("bad URL: {error}")),
    };
    let headers = request.headers_mut();
    if request_binary_subprotocol {
        headers.insert("Sec-WebSocket-Protocol", HeaderValue::from_static("binary"));
    }
    headers.insert(
        "Origin",
        HeaderValue::from_static("https://web.telegram.org"),
    );
    headers.insert(
        "User-Agent",
        HeaderValue::from_static(
            "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
        ),
    );

    match tokio::time::timeout(timeout, tls_handshake_and_upgrade(tcp, request)).await {
        Ok(Ok((ws, response))) if response.status().as_u16() == 101 => {
            WsConnectResult::Connected(ws)
        }
        Ok(Ok((_, response)))
            if matches!(response.status().as_u16(), 301 | 302 | 303 | 307 | 308) =>
        {
            WsConnectResult::Redirect(response.status().as_u16())
        }
        Ok(Ok((_, response))) => {
            WsConnectResult::Failed(format!("unexpected HTTP status {}", response.status()))
        }
        Ok(Err(WsError::Http(response)))
            if matches!(response.status().as_u16(), 301 | 302 | 303 | 307 | 308) =>
        {
            WsConnectResult::Redirect(response.status().as_u16())
        }
        Ok(Err(WsError::Http(response))) => {
            WsConnectResult::Failed(format!("HTTP {} from server", response.status()))
        }
        Ok(Err(error)) => WsConnectResult::Failed(error.to_string()),
        Err(_) => WsConnectResult::TimedOut,
    }
}
/// Connect to a Cloudflare hostname through the configured preferred edges.
///
/// With no preferred IPs, the hostname is dialled normally and DNS chooses
/// Cloudflare's anycast edge. With `--cf-ip`, DNS is never used for the TCP
/// destination: every configured address is attempted, starting at a rotating
/// offset. `domain` remains the TLS SNI and HTTP `Host` on every attempt.
#[allow(clippy::too_many_arguments)]
async fn connect_cf_with_path(
    domain: &str,
    path: &str,
    route_scope: &str,
    request_binary_subprotocol: bool,
    timeout: Duration,
    outbound: &OutboundConnector,
    opts: CfDialOpts<'_>,
) -> WsConnectResult {
    if opts.cf_ips.is_empty() {
        return connect_ws_with_path(
            domain,
            domain,
            path,
            request_binary_subprotocol,
            timeout,
            outbound,
        )
        .await;
    }

    let first = cf_ip_start(opts.cf_ips);
    let cooldowns = &CF_EDGE_TLS_FAIL;
    let mut last_non_redirect = None;
    let mut last_redirect = None;

    for ip in cf_ip_attempts(opts.cf_ips, first, domain, route_scope, cooldowns) {
        let route_key = (ip, domain.to_string(), route_scope.to_string());
        let target = ip.to_string();
        debug!("проверка узла CF {} для домена {}", ip, domain);
        match connect_ws_with_path(
            &target,
            domain,
            path,
            request_binary_subprotocol,
            timeout,
            outbound,
        )
        .await
        {
            WsConnectResult::Connected(ws) => {
                cooldowns.clear(&route_key);
                return WsConnectResult::Connected(ws);
            }
            WsConnectResult::Redirect(code) => {
                cooldowns.clear(&route_key);
                last_redirect = Some(code);
            }
            WsConnectResult::Failed(reason) => {
                cooldowns.clear(&route_key);
                last_non_redirect = Some(WsConnectResult::Failed(reason));
            }
            WsConnectResult::TimedOut => {
                cooldowns.clear(&route_key);
                last_non_redirect = Some(WsConnectResult::TimedOut);
            }
            WsConnectResult::ConnectTimedOut(reason) => {
                cooldowns.set(route_key, opts.fail_cooldown);
                last_non_redirect = Some(WsConnectResult::ConnectTimedOut(reason));
            }
        }
    }

    last_non_redirect.unwrap_or_else(|| {
        WsConnectResult::Redirect(last_redirect.expect("non-empty CF IP list attempted"))
    })
}

#[allow(clippy::result_large_err)]
async fn tls_handshake_and_upgrade<R>(
    tcp: TcpStream,
    request: R,
) -> Result<(TgWsStream, tungstenite::handshake::client::Response), WsError>
where
    R: IntoClientRequest + Unpin,
{
    let connector = Connector::Rustls(verifying_rustls_config());
    client_async_tls_with_config(request, tcp, Some(ws_config()), Some(connector)).await
}
/// Ceiling for one incoming WebSocket frame and its reassembled message.
///
/// Tungstenite otherwise permits 16 MiB frames and 64 MiB messages, while its
/// input buffer retains the largest capacity reached by a connection. Telegram
/// media parts are at most 1 MiB, so 4 MiB leaves protocol headroom without
/// letting one unusual frame park tens of megabytes for the session lifetime.
const WS_MAX_FRAME: usize = 4 * 1024 * 1024;

/// Target size of tungstenite's per-connection write buffer.
///
/// Every send in the bridge is awaited and flushed before the next message, so
/// the default 128 KiB batching target only increases the retained footprint.
const WS_WRITE_BUFFER: usize = 16 * 1024;

fn ws_config() -> WebSocketConfig {
    WebSocketConfig {
        write_buffer_size: WS_WRITE_BUFFER,
        max_frame_size: Some(WS_MAX_FRAME),
        max_message_size: Some(WS_MAX_FRAME),
        ..WebSocketConfig::default()
    }
}

/// Path used by the Cloudflare Worker TCP-tunnel mode.
///
/// The Worker accepts a WebSocket at `/apiws`, opens a raw TCP connection to
/// `dst:443`, and forwards every WebSocket message payload as TCP bytes.
pub fn cf_worker_path(dst: &str, dc: u32, is_media: bool) -> String {
    format!(
        "/apiws?dst={}&dc={}&media={}",
        dst,
        dc,
        if is_media { 1 } else { 0 }
    )
}

pub(crate) async fn connect_ws_for_dc_with_outbound(
    ip: &str,
    dc: u32,
    is_media: bool,
    timeout: Duration,
    outbound: &OutboundConnector,
) -> WsAttempt {
    let domains = ws_domains(dc, is_media);
    let media = media_tag(is_media);
    let mut all_redirects = true;
    let mut connect_timed_out = false;

    for domain in &domains {
        debug!(
            "DC{}{}: проверка WS-домена {} через {}",
            dc, media, domain, ip
        );
        let result = connect_ws_with_path(ip, domain, "/apiws", true, timeout, outbound).await;
        let try_next_domain = should_try_next_ws_domain(&result);
        match result {
            WsConnectResult::Connected(ws) => return WsAttempt::connected(ws),
            WsConnectResult::Redirect(code) => {
                warn!(
                    "DC{}{}: домен {} ответил кодом HTTP {} (перенаправление)",
                    dc, media, domain, code
                );
            }
            WsConnectResult::Failed(reason) => {
                warn!(
                    "DC{}{}: ошибка WS-подключения к {}: {}",
                    dc, media, domain, reason
                );
                all_redirects = false;
            }
            WsConnectResult::TimedOut => {
                warn!(
                    "DC{}{}: истекло время ожидания WS-подключения к {}",
                    dc, media, domain
                );
                all_redirects = false;
            }
            WsConnectResult::ConnectTimedOut(reason) => {
                warn!(
                    "DC{}{}: ошибка WS-подключения к {}: {}",
                    dc, media, domain, reason
                );
                connect_timed_out = true;
                all_redirects = false;
            }
        }
        if !try_next_domain {
            break;
        }
    }

    WsAttempt {
        ws: None,
        all_redirects,
        connect_timed_out,
    }
}

fn should_try_next_ws_domain(result: &WsConnectResult) -> bool {
    !matches!(result, WsConnectResult::ConnectTimedOut(_))
}

/// Each DNS record `kws{N}.{cf_domain}` should be an **orange-cloud** (proxied)
/// A record in Cloudflare pointing at the corresponding Telegram DC IP, with
/// the zone's SSL/TLS mode set to **Flexible**.  Cloudflare then terminates TLS
/// from our side and forwards the WebSocket traffic as plain HTTP to Telegram.
///
/// Unlike `ws_domains()`, the raw DC number is used **without** applying
/// the `config::websocket_dc()` remap.  The user controls the Cloudflare DNS zone and
/// creates explicit records for every DC — including non-canonical ones like
/// DC 203 (`kws203.{cf_domain}`).  Remapping 203 → 2 would incorrectly route
/// traffic to DC 2 instead of DC 203 (they have different IPs/servers).
///
/// Only the base `kws{N}` record is used, never a `kws{N}-1` one.  Through
/// Cloudflare the hostname only selects the origin IP, and both records point
/// at the same DC, so a `-1` record buys nothing — while the shared
/// `--default-domains` zones do not define it at all, which made every lookup
/// a guaranteed NXDOMAIN.  `is_media` is accepted for API compatibility only.
///
/// When multiple CF domains are given, they are returned in order — the first
/// domain has highest priority.
pub fn cf_ws_domains(dc: u32, cf_domains: &[String], _is_media: bool) -> Vec<String> {
    cf_domains
        .iter()
        .map(|cf_domain| format!("kws{}.{}", dc, cf_domain))
        .collect()
}

/// Ordering policy for the Cloudflare connect loop.
///
/// Each configured domain's `kws{N}` record is attempted twice in a row, and
/// duplicate domains are skipped.  The second attempt is skipped when the
/// first ran out the clock — retrying it just buys another full connect
/// timeout before the fallback chain can move on.
///
/// That second attempt is load-bearing, not an accident.  It used to happen
/// implicitly, as the fallback for a missing `kws{N}-1` record, and
/// deduplicating it away measurably pushed connections into the (often
/// blocked) TCP fallback: on one tester's network the fallback share nearly
/// doubled, 5.9% -> 11.4%, each costing a full `--tcp-fallback-timeout`.
struct CfAttempts<'a> {
    dc: u32,
    domains: &'a [String],
    first_domain: usize,
    next_ordinal: usize,
    /// The domain just attempted for the first time, until its retry is due.
    pending_retry: Option<usize>,
}

impl<'a> CfAttempts<'a> {
    #[cfg(test)]
    fn new(dc: u32, domains: &'a [String]) -> Self {
        Self::with_offset(dc, domains, 0)
    }

    fn with_offset(dc: u32, domains: &'a [String], first_domain: usize) -> Self {
        Self {
            dc,
            domains,
            first_domain: if domains.is_empty() {
                0
            } else {
                first_domain % domains.len()
            },
            next_ordinal: 0,
            pending_retry: None,
        }
    }

    /// The next record to attempt.
    fn next_domain(&mut self) -> Option<String> {
        if let Some(domain_index) = self.pending_retry.take() {
            return Some(self.hostname(domain_index));
        }

        while self.next_ordinal < self.domains.len() {
            let ordinal = self.next_ordinal;
            self.next_ordinal += 1;
            let domain_index = (self.first_domain + ordinal) % self.domains.len();
            if (0..ordinal).any(|prior| {
                self.domains[(self.first_domain + prior) % self.domains.len()]
                    == self.domains[domain_index]
            }) {
                continue;
            }

            self.pending_retry = Some(domain_index);
            return Some(self.hostname(domain_index));
        }

        None
    }

    /// Record that the attempt just returned by `next_domain` hit the connect
    /// timeout, so it is not retried.
    fn note_timed_out(&mut self) {
        self.pending_retry = None;
    }

    fn hostname(&self, domain_index: usize) -> String {
        format!("kws{}.{}", self.dc, self.domains[domain_index])
    }
}

pub(crate) async fn connect_cf_ws_for_dc_with_outbound_opts(
    dc: u32,
    cf_domains: &[String],
    is_media: bool,
    timeout: Duration,
    outbound: &OutboundConnector,
    opts: CfDialOpts<'_>,
) -> (Option<TgWsStream>, Option<String>, bool) {
    connect_cf_ws_for_dc_with_outbound_ordered(dc, cf_domains, is_media, timeout, outbound, 0, opts)
        .await
}

pub(crate) async fn connect_cf_ws_for_dc_with_outbound_ordered(
    dc: u32,
    cf_domains: &[String],
    is_media: bool,
    timeout: Duration,
    outbound: &OutboundConnector,
    first_domain: usize,
    opts: CfDialOpts<'_>,
) -> (Option<TgWsStream>, Option<String>, bool) {
    let media = media_tag(is_media);
    let mut all_redirects = true;
    let mut attempts = CfAttempts::with_offset(dc, cf_domains, first_domain);

    while let Some(domain) = attempts.next_domain() {
        debug!("DC{}{}: проверка WS через CF-домен {}", dc, media, domain);
        let route_scope = format!("dc={dc};media={is_media};transport=cf-proxy");
        match connect_cf_with_path(
            &domain,
            "/apiws",
            &route_scope,
            true,
            timeout,
            outbound,
            opts,
        )
        .await
        {
            WsConnectResult::Connected(ws) => return (Some(ws), Some(domain), false),
            WsConnectResult::Redirect(code) => {
                warn!(
                    "DC{}{}: CF-домен {} ответил кодом HTTP {} (перенаправление)",
                    dc, media, domain, code
                );
            }
            WsConnectResult::Failed(reason) => {
                warn!(
                    "DC{}{}: ошибка CF WS-подключения к {}: {}",
                    dc, media, domain, reason
                );
                all_redirects = false;
            }
            WsConnectResult::TimedOut | WsConnectResult::ConnectTimedOut(_) => {
                warn!(
                    "DC{}{}: истекло время ожидания CF WS-подключения к {}",
                    dc, media, domain
                );
                attempts.note_timed_out();
                all_redirects = false;
            }
        }
    }

    (None, None, all_redirects)
}
pub(crate) async fn connect_cf_worker_ws_for_dc_with_outbound_opts(
    worker_domain: &str,
    dst: &str,
    dc: u32,
    is_media: bool,
    timeout: Duration,
    outbound: &OutboundConnector,
    opts: CfDialOpts<'_>,
) -> Option<TgWsStream> {
    let path = cf_worker_path(dst, dc, is_media);
    let media = media_tag(is_media);
    let route_scope = format!("dc={dc};media={is_media};dst={dst};transport=cf-worker");
    debug!(
        "DC{}{}: проверка CF Worker {} через {}",
        dc, media, dst, worker_domain
    );

    match connect_cf_with_path(
        worker_domain,
        &path,
        &route_scope,
        false,
        timeout,
        outbound,
        opts,
    )
    .await
    {
        WsConnectResult::Connected(ws) => Some(ws),
        WsConnectResult::Redirect(code) => {
            warn!(
                "DC{}{}: CF Worker {} ответил кодом HTTP {} (перенаправление)",
                dc, media, worker_domain, code
            );
            None
        }
        WsConnectResult::Failed(reason) => {
            warn!(
                "DC{}{}: ошибка CF Worker-подключения к {}: {}",
                dc, media, worker_domain, reason
            );
            None
        }
        WsConnectResult::TimedOut | WsConnectResult::ConnectTimedOut(_) => {
            warn!(
                "DC{}{}: истекло время ожидания CF Worker {}",
                dc, media, worker_domain
            );
            None
        }
    }
}
/// Send a binary WebSocket message and flush.
pub async fn ws_send(ws: &mut TgWsStream, data: Vec<u8>) -> Result<(), String> {
    ws.send(Message::Binary(data))
        .await
        .map_err(|e| e.to_string())
}

/// Receive the next binary message from the WebSocket.
/// Returns `None` when the connection is closed gracefully.
#[allow(dead_code)]
pub async fn ws_recv(ws: &mut TgWsStream) -> Option<Vec<u8>> {
    loop {
        match ws.next().await {
            Some(Ok(Message::Binary(b))) => return Some(b),
            Some(Ok(Message::Text(t))) => return Some(t.into_bytes()),
            Some(Ok(Message::Ping(_))) | Some(Ok(Message::Pong(_))) => continue,
            Some(Ok(Message::Close(_))) | None => return None,
            Some(Err(_)) => return None,
            Some(Ok(_)) => continue,
        }
    }
}

// ─── TLS connector helpers ───────────────────────────────────────────────────

// Both client configs are built once and shared by every connection.
//
// Rebuilding them per connection — as this used to — cost a fresh copy of the
// ~150-entry WebPKI root store each time, and, far worse, a fresh TLS session
// cache: `rustls` keeps resumption tickets in the `ClientConfig`, so a config
// that lives for one connection can never resume anything. Every single
// connection therefore paid a full TLS 1.3 handshake. Sharing the config lets
// repeat connections to the same DC or CF domain resume instead, which is the
// difference between a key exchange plus certificate verification and almost
// nothing — the dominant CPU cost on the routers and phones this runs on.
//
// `ClientConfig` is `Sync` and its session store is internally locked, so
// sharing one across connections is the intended usage.
static VERIFYING_CONFIG: OnceLock<Arc<rustls::ClientConfig>> = OnceLock::new();

/// How many TLS sessions to keep for resumption — `rustls`'s own default,
/// stated explicitly because it is easy to assume it is oversized and shrink
/// it. It is not: it leaves headroom over the largest realistic config.
///
/// The cache holds one entry per *hostname*, and this proxy dials a lot of
/// them. Each CF domain contributes `kws{N}` for every DC in play (media and
/// non-media share that name), plus `kws{1..5}[-1].web.telegram.org` for the
/// direct path and one name per Worker. With `--default-domains` that is
/// roughly:
///
/// ```text
///   21 domains x 3 DCs + 10 + 1  ~=  75 names
///   21 domains x 6 DCs + 10 + 1  ~= 140 names
/// ```
///
/// and `--cf-balance` deliberately keeps every one of them hot. Undersizing
/// the cache is the worst outcome available: the memory is still spent, and
/// entries get evicted before they can be reused, so the handshakes come back.
const TLS_SESSION_CACHE_SIZE: usize = 256;

/// Общая конфигурация TLS-клиента со встроенными корнями WebPKI.
fn verifying_rustls_config() -> Arc<rustls::ClientConfig> {
    VERIFYING_CONFIG
        .get_or_init(|| {
            let mut root_store = rustls::RootCertStore::empty();
            root_store.extend(webpki_roots::TLS_SERVER_ROOTS.iter().cloned());

            let mut config = rustls::ClientConfig::builder()
                .with_root_certificates(root_store)
                .with_no_client_auth();
            config.resumption =
                rustls::client::Resumption::in_memory_sessions(TLS_SESSION_CACHE_SIZE);

            Arc::new(config)
        })
        .clone()
}

#[cfg(test)]
mod tests;
