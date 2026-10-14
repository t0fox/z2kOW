//! Ограниченная внутрипроцессная статистика и локальный Unix-сокет чтения.

use std::collections::{BTreeMap, VecDeque};
use std::fs;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, AtomicUsize, Ordering};
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use serde::Serialize;
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::UnixListener;
use tracing::info;

const MAX_COUNTER_KEYS: usize = 96;
const MAX_TTFB_SAMPLES: usize = 128;
const MAX_ACTIVE_ROUTE_SESSIONS: usize = 64;
const MAX_ROUTE_EVENTS: usize = 6;

static GLOBAL: LazyLock<Arc<RuntimeStats>> = LazyLock::new(|| Arc::new(RuntimeStats::new()));

#[cfg(target_has_atomic = "64")]
type AtomicCounterU64 = std::sync::atomic::AtomicU64;
#[cfg(target_has_atomic = "64")]
type AtomicCounterI64 = std::sync::atomic::AtomicI64;

#[cfg(not(target_has_atomic = "64"))]
#[derive(Default)]
struct AtomicCounterU64(Mutex<u64>);

#[cfg(not(target_has_atomic = "64"))]
impl AtomicCounterU64 {
    fn new(value: u64) -> Self {
        Self(Mutex::new(value))
    }

    fn load(&self, _ordering: Ordering) -> u64 {
        *self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn store(&self, value: u64, _ordering: Ordering) {
        *self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = value;
    }

    fn fetch_add(&self, value: u64, _ordering: Ordering) -> u64 {
        let mut current = self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner());
        let previous = *current;
        *current = current.wrapping_add(value);
        previous
    }
}

#[cfg(not(target_has_atomic = "64"))]
#[derive(Default)]
struct AtomicCounterI64(Mutex<i64>);

#[cfg(not(target_has_atomic = "64"))]
impl AtomicCounterI64 {
    fn load(&self, _ordering: Ordering) -> i64 {
        *self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner())
    }

    fn store(&self, value: i64, _ordering: Ordering) {
        *self
            .0
            .lock()
            .unwrap_or_else(|poisoned| poisoned.into_inner()) = value;
    }
}

pub fn global() -> Arc<RuntimeStats> {
    Arc::clone(&GLOBAL)
}

#[derive(Default)]
pub struct RuntimeStats {
    started_at: AtomicCounterU64,
    listener_ready: AtomicBool,
    active_connections: AtomicUsize,
    max_connections: AtomicUsize,
    accepted_connections: AtomicCounterU64,
    wss_established: AtomicCounterU64,
    mtproto_success: AtomicCounterU64,
    mtproto_failure: AtomicCounterU64,
    last_mtproto_response_at: AtomicCounterU64,
    dc_generation: AtomicCounterU64,
    dc_fetched_at: AtomicCounterI64,
    counters: Mutex<BTreeMap<String, u64>>,
    ttfb_samples: Mutex<BTreeMap<String, VecDeque<u64>>>,
    sessions_by_route: Mutex<BTreeMap<String, u64>>,
    workers: Mutex<BTreeMap<String, WorkerState>>,
    cf_domains: Mutex<Vec<String>>,
    cf_fetched_at: AtomicCounterU64,
    next_route_session_id: AtomicCounterU64,
    route_sessions: Mutex<BTreeMap<u64, RouteSession>>,
}

#[derive(Clone, Debug, Default, Serialize)]
pub struct WorkerState {
    pub state: &'static str,
    pub last_success_at: u64,
    pub last_failure_at: u64,
    pub last_failure: Option<String>,
}

#[derive(Clone, Debug, Serialize)]
pub struct LatencyPercentiles {
    pub count: usize,
    pub p50_ms: u64,
    pub p95_ms: u64,
    pub p99_ms: u64,
}

#[derive(Clone, Debug, Serialize)]
pub struct StatsSnapshot {
    pub process_started_at: u64,
    pub listener_ready: bool,
    pub active_connections: usize,
    pub active_sessions: Vec<ActiveRouteSession>,
    pub route_sessions_truncated: bool,
    pub max_connections: usize,
    pub accepted_connections: u64,
    pub wss_established: u64,
    pub mtproto_success: u64,
    pub mtproto_failure: u64,
    pub last_mtproto_response_at: u64,
    pub dc_map: DcMapStats,
    pub cf_domain_pool: CfPoolStats,
    pub workers: BTreeMap<String, WorkerState>,
    pub sessions_by_dc_transport: BTreeMap<String, u64>,
    pub failures: BTreeMap<String, u64>,
    pub ttfb: BTreeMap<String, LatencyPercentiles>,
    pub rss_kib: Option<u64>,
    pub rss_hwm_kib: Option<u64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ActiveRouteSession {
    pub id: u64,
    pub dc: Option<u32>,
    pub is_media: Option<bool>,
    pub stage: &'static str,
    pub direct_state: &'static str,
    pub direct_transport: Option<&'static str>,
    pub fallback_state: &'static str,
    pub fallback_transport: Option<&'static str>,
    pub selected_transport: Option<&'static str>,
    pub telegram_response_seen: bool,
    pub events: VecDeque<ActiveRouteEvent>,
}

#[derive(Clone, Debug, Serialize)]
pub struct ActiveRouteEvent {
    pub sequence: u64,
    pub branch: &'static str,
    pub transport: &'static str,
    pub state: &'static str,
}

struct RouteSession {
    snapshot: ActiveRouteSession,
    next_event_sequence: u64,
}

impl RouteSession {
    fn new(id: u64) -> Self {
        Self {
            snapshot: ActiveRouteSession {
                id,
                dc: None,
                is_media: None,
                stage: "accepted",
                direct_state: "idle",
                direct_transport: None,
                fallback_state: "idle",
                fallback_transport: None,
                selected_transport: None,
                telegram_response_seen: false,
                events: VecDeque::with_capacity(MAX_ROUTE_EVENTS),
            },
            next_event_sequence: 1,
        }
    }

    fn event(&mut self, branch: &'static str, transport: &'static str, state: &'static str) {
        if self.snapshot.events.len() == MAX_ROUTE_EVENTS {
            self.snapshot.events.pop_front();
        }
        self.snapshot.events.push_back(ActiveRouteEvent {
            sequence: self.next_event_sequence,
            branch,
            transport,
            state,
        });
        self.next_event_sequence = self.next_event_sequence.saturating_add(1);
    }
}

#[derive(Clone, Debug, Serialize)]
pub struct DcMapStats {
    pub generation: u64,
    pub fetched_at: i64,
    pub freshness_seconds: Option<u64>,
}

#[derive(Clone, Debug, Serialize)]
pub struct CfPoolStats {
    pub domains: Vec<String>,
    pub fetched_at: u64,
    pub freshness_seconds: Option<u64>,
}

impl RuntimeStats {
    pub fn new() -> Self {
        Self {
            started_at: AtomicCounterU64::new(unix_time()),
            next_route_session_id: AtomicCounterU64::new(0),
            ..Self::default()
        }
    }

    pub fn set_listener_ready(&self, ready: bool) {
        self.listener_ready.store(ready, Ordering::Release);
    }

    pub fn set_max_connections(&self, max: usize) {
        self.max_connections.store(max, Ordering::Release);
    }

    pub fn connection_started(self: &Arc<Self>) -> ConnectionGuard {
        self.accepted_connections.fetch_add(1, Ordering::Relaxed);
        self.active_connections.fetch_add(1, Ordering::AcqRel);
        let id = self.next_route_session_id.fetch_add(1, Ordering::Relaxed) + 1;
        let tracked = {
            let mut sessions = self.route_sessions.lock().expect("маршруты заняты");
            if sessions.len() >= MAX_ACTIVE_ROUTE_SESSIONS {
                false
            } else {
                sessions.insert(id, RouteSession::new(id));
                true
            }
        };
        ConnectionGuard {
            stats: Arc::clone(self),
            telemetry: ConnectionTelemetry {
                stats: Arc::clone(self),
                id,
                tracked,
            },
        }
    }

    pub fn record_wss_established(&self) {
        self.wss_established.fetch_add(1, Ordering::Relaxed);
    }

    pub fn record_failure(&self, stage: &str) {
        let key = bounded_failure_key(stage);
        let mut counters = self.counters.lock().expect("счётчики статистики заняты");
        if counters.len() < MAX_COUNTER_KEYS || counters.contains_key(&key) {
            *counters.entry(key).or_default() += 1;
        }
    }

    pub fn record_mtproto_response(&self, dc: u32, transport: &str, ttfb: Duration) {
        self.mtproto_success.fetch_add(1, Ordering::Relaxed);
        self.last_mtproto_response_at
            .store(unix_time(), Ordering::Release);
        let key = format!("dc{dc}:{transport}");
        {
            let mut sessions = self
                .sessions_by_route
                .lock()
                .expect("счётчики маршрутов заняты");
            if sessions.len() < MAX_COUNTER_KEYS || sessions.contains_key(&key) {
                *sessions.entry(key.clone()).or_default() += 1;
            }
        }
        let millis = ttfb.as_millis().min(u128::from(u64::MAX)) as u64;
        let mut samples = self.ttfb_samples.lock().expect("выборка TTFB занята");
        if samples.len() < MAX_COUNTER_KEYS || samples.contains_key(&key) {
            let values = samples.entry(key).or_default();
            if values.len() == MAX_TTFB_SAMPLES {
                values.pop_front();
            }
            values.push_back(millis);
        }
    }

    pub fn record_mtproto_failure(&self, stage: &str) {
        self.mtproto_failure.fetch_add(1, Ordering::Relaxed);
        self.record_failure(stage);
    }

    pub fn record_worker_success(&self, domain: &str) {
        let mut workers = self.workers.lock().expect("состояние Worker занято");
        if workers.len() < 8 || workers.contains_key(domain) {
            workers.insert(
                domain.to_string(),
                WorkerState {
                    state: "healthy",
                    last_success_at: unix_time(),
                    last_failure_at: 0,
                    last_failure: None,
                },
            );
        }
    }

    pub fn record_worker_failure(&self, domain: &str, reason: &str) {
        let mut workers = self.workers.lock().expect("состояние Worker занято");
        if workers.len() < 8 || workers.contains_key(domain) {
            let last_success_at = workers.get(domain).map_or(0, |state| state.last_success_at);
            workers.insert(
                domain.to_string(),
                WorkerState {
                    state: "unavailable",
                    last_success_at,
                    last_failure_at: unix_time(),
                    last_failure: Some(reason.chars().take(160).collect()),
                },
            );
        }
    }

    pub fn set_dc_map(&self, generation: u64, fetched_at: i64) {
        self.dc_generation.store(generation, Ordering::Release);
        self.dc_fetched_at.store(fetched_at, Ordering::Release);
    }

    pub fn set_cf_pool(&self, domains: &[String], fetched_at: u64) {
        let mut current = self.cf_domains.lock().expect("снимок CF pool занят");
        *current = domains.iter().take(256).cloned().collect();
        self.cf_fetched_at.store(fetched_at, Ordering::Release);
    }

    pub fn snapshot(&self) -> StatsSnapshot {
        let now = unix_time();
        let dc_fetched_at = self.dc_fetched_at.load(Ordering::Acquire);
        let cf_fetched_at = self.cf_fetched_at.load(Ordering::Acquire);
        let ttfb = self
            .ttfb_samples
            .lock()
            .expect("выборка TTFB занята")
            .iter()
            .filter_map(|(key, samples)| {
                percentile_stats(samples).map(|stats| (key.clone(), stats))
            })
            .collect();
        let active_sessions = {
            let sessions = self.route_sessions.lock().expect("маршруты заняты");
            sessions
                .values()
                .map(|session| session.snapshot.clone())
                .collect::<Vec<_>>()
        };
        let active_connections = self.active_connections.load(Ordering::Acquire);
        let route_sessions_truncated = active_connections > active_sessions.len();
        StatsSnapshot {
            process_started_at: self.started_at.load(Ordering::Acquire),
            listener_ready: self.listener_ready.load(Ordering::Acquire),
            active_connections,
            route_sessions_truncated,
            active_sessions,
            max_connections: self.max_connections.load(Ordering::Acquire),
            accepted_connections: self.accepted_connections.load(Ordering::Acquire),
            wss_established: self.wss_established.load(Ordering::Acquire),
            mtproto_success: self.mtproto_success.load(Ordering::Acquire),
            mtproto_failure: self.mtproto_failure.load(Ordering::Acquire),
            last_mtproto_response_at: self.last_mtproto_response_at.load(Ordering::Acquire),
            dc_map: DcMapStats {
                generation: self.dc_generation.load(Ordering::Acquire),
                fetched_at: dc_fetched_at,
                freshness_seconds: (dc_fetched_at > 0)
                    .then_some(now.saturating_sub(dc_fetched_at as u64)),
            },
            cf_domain_pool: CfPoolStats {
                domains: self
                    .cf_domains
                    .lock()
                    .expect("снимок CF pool занят")
                    .clone(),
                fetched_at: cf_fetched_at,
                freshness_seconds: (cf_fetched_at > 0).then_some(now.saturating_sub(cf_fetched_at)),
            },
            workers: self
                .workers
                .lock()
                .expect("состояние Worker занято")
                .clone(),
            sessions_by_dc_transport: self
                .sessions_by_route
                .lock()
                .expect("счётчики маршрутов заняты")
                .clone(),
            failures: self
                .counters
                .lock()
                .expect("счётчики статистики заняты")
                .clone(),
            ttfb,
            rss_kib: read_proc_kib("VmRSS"),
            rss_hwm_kib: read_proc_kib("VmHWM"),
        }
    }
}

pub struct ConnectionGuard {
    stats: Arc<RuntimeStats>,
    telemetry: ConnectionTelemetry,
}

impl ConnectionGuard {
    pub fn telemetry(&self) -> ConnectionTelemetry {
        self.telemetry.clone()
    }
}

#[derive(Clone)]
pub struct ConnectionTelemetry {
    stats: Arc<RuntimeStats>,
    id: u64,
    tracked: bool,
}

impl ConnectionTelemetry {
    pub fn set_stage(&self, stage: &'static str) {
        if !self.tracked {
            return;
        }
        if let Some(session) = self
            .stats
            .route_sessions
            .lock()
            .expect("маршруты заняты")
            .get_mut(&self.id)
        {
            session.snapshot.stage = stage;
        }
    }

    pub fn set_dc(&self, dc: u32, is_media: bool) {
        if !self.tracked {
            return;
        }
        if let Some(session) = self
            .stats
            .route_sessions
            .lock()
            .expect("маршруты заняты")
            .get_mut(&self.id)
        {
            session.snapshot.dc = Some(dc);
            session.snapshot.is_media = Some(is_media);
        }
    }

    pub fn begin_attempt(
        &self,
        branch: &'static str,
        transport: &'static str,
    ) -> RouteAttemptGuard {
        self.set_attempt_state(branch, transport, "connecting");
        RouteAttemptGuard {
            telemetry: self.clone(),
            branch,
            transport,
            complete: false,
        }
    }

    pub fn select_transport(&self, branch: &'static str, transport: &'static str) {
        if !self.tracked {
            return;
        }
        if let Some(session) = self
            .stats
            .route_sessions
            .lock()
            .expect("маршруты заняты")
            .get_mut(&self.id)
        {
            let losing_branch = if branch == "direct" {
                "fallback"
            } else {
                "direct"
            };
            let (losing_state, losing_transport) = if losing_branch == "direct" {
                (
                    session.snapshot.direct_state,
                    session.snapshot.direct_transport,
                )
            } else {
                (
                    session.snapshot.fallback_state,
                    session.snapshot.fallback_transport,
                )
            };
            if losing_state == "connected" {
                if losing_branch == "direct" {
                    session.snapshot.direct_state = "cancelled";
                } else {
                    session.snapshot.fallback_state = "cancelled";
                }
                if let Some(losing_transport) = losing_transport {
                    session.event(losing_branch, losing_transport, "cancelled");
                }
            }
            session.snapshot.stage = "upstream_ready";
            session.snapshot.selected_transport = Some(transport);
            session.snapshot.telegram_response_seen = false;
            if branch == "direct" {
                session.snapshot.direct_state = "selected";
                session.snapshot.direct_transport = Some(transport);
            } else {
                session.snapshot.fallback_state = "selected";
                session.snapshot.fallback_transport = Some(transport);
            }
            session.event(branch, transport, "selected");
        }
    }

    pub fn mark_first_wss_binary(&self) {
        if !self.tracked {
            return;
        }
        if let Some(session) = self
            .stats
            .route_sessions
            .lock()
            .expect("маршруты заняты")
            .get_mut(&self.id)
        {
            let transport = session.snapshot.selected_transport.unwrap_or("unknown");
            let branch = if transport == "direct_wss" {
                "direct"
            } else {
                "fallback"
            };
            session.snapshot.stage = "first_wss_binary_response";
            session.snapshot.telegram_response_seen = true;
            session.event(branch, transport, "first_binary_response");
        }
    }

    fn set_attempt_state(
        &self,
        branch: &'static str,
        transport: &'static str,
        state: &'static str,
    ) {
        if !self.tracked {
            return;
        }
        if let Some(session) = self
            .stats
            .route_sessions
            .lock()
            .expect("маршруты заняты")
            .get_mut(&self.id)
        {
            session.snapshot.stage = "routing";
            if branch == "direct" {
                session.snapshot.direct_state = state;
                session.snapshot.direct_transport = Some(transport);
            } else {
                session.snapshot.fallback_state = state;
                session.snapshot.fallback_transport = Some(transport);
            }
            session.event(branch, transport, state);
        }
    }
}

pub struct RouteAttemptGuard {
    telemetry: ConnectionTelemetry,
    branch: &'static str,
    transport: &'static str,
    complete: bool,
}

impl RouteAttemptGuard {
    pub fn finish(mut self, state: &'static str) {
        self.telemetry
            .set_attempt_state(self.branch, self.transport, state);
        self.complete = true;
    }
}

impl Drop for RouteAttemptGuard {
    fn drop(&mut self) {
        if !self.complete {
            self.telemetry
                .set_attempt_state(self.branch, self.transport, "cancelled");
        }
    }
}

impl Drop for ConnectionGuard {
    fn drop(&mut self) {
        if self.telemetry.tracked {
            self.stats
                .route_sessions
                .lock()
                .expect("маршруты заняты")
                .remove(&self.telemetry.id);
        }
        self.stats.active_connections.fetch_sub(1, Ordering::AcqRel);
    }
}

#[cfg(unix)]
pub async fn serve_unix(path: PathBuf, stats: Arc<RuntimeStats>) -> Result<(), String> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|error| format!("создание каталога сокета: {error}"))?;
    }
    remove_stale_socket(&path).await?;
    let listener =
        UnixListener::bind(&path).map_err(|error| format!("создание Unix-сокета: {error}"))?;
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&path, fs::Permissions::from_mode(0o600))
        .map_err(|error| format!("ограничение доступа к Unix-сокету: {error}"))?;
    info!("Статистика Telegram доступна через локальный защищённый Unix-сокет");
    loop {
        let (mut stream, _) = listener.accept().await.map_err(|error| error.to_string())?;
        let mut request = Vec::with_capacity(9);
        let mut read_failed = false;
        while request.len() < 32 {
            let mut byte = [0u8; 1];
            let length = match stream.read(&mut byte).await {
                Ok(length) => length,
                Err(error) => {
                    tracing::debug!(%error, "клиент статистики закрыл чтение с ошибкой");
                    read_failed = true;
                    break;
                }
            };
            if length == 0 {
                break;
            }
            request.push(byte[0]);
            if byte[0] == b'\n' {
                break;
            }
        }
        if read_failed || request.is_empty() {
            continue;
        }
        if request != b"snapshot\n" {
            if let Err(error) = stream
                .write_all(b"{\"error\":\"unsupported request\"}\n")
                .await
            {
                tracing::debug!(%error, "не удалось ответить клиенту статистики");
            }
            continue;
        }
        let response = serde_json::to_vec(&stats.snapshot())
            .map_err(|error| format!("сериализация статистики: {error}"))?;
        if let Err(error) = stream.write_all(&response).await {
            tracing::debug!(%error, "не удалось передать статистику клиенту");
            continue;
        }
        if let Err(error) = stream.write_all(b"\n").await {
            tracing::debug!(%error, "не удалось завершить ответ статистики");
        }
    }
}

#[cfg(not(unix))]
pub async fn serve_unix(_path: PathBuf, _stats: Arc<RuntimeStats>) -> Result<(), String> {
    Err("локальный сокет статистики поддерживается только в Unix".into())
}

#[cfg(unix)]
async fn remove_stale_socket(path: &Path) -> Result<(), String> {
    use std::os::unix::fs::FileTypeExt;
    match fs::symlink_metadata(path) {
        Ok(metadata) if metadata.file_type().is_socket() => {
            match tokio::time::timeout(
                Duration::from_millis(200),
                tokio::net::UnixStream::connect(path),
            )
            .await
            {
                Ok(Ok(_)) => {
                    return Err("сокет статистики уже обслуживается другим процессом".into());
                }
                Err(_) => return Err("не удалось проверить владельца сокета статистики".into()),
                Ok(Err(_)) => {}
            }
            fs::remove_file(path).map_err(|error| format!("удаление старого сокета: {error}"))
        }
        Ok(_) => Err("путь статистики занят файлом, не являющимся сокетом".into()),
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!("проверка пути сокета: {error}")),
    }
}

pub async fn read_socket(path: &Path) -> Result<Vec<u8>, String> {
    #[cfg(unix)]
    {
        let mut stream = tokio::time::timeout(
            Duration::from_secs(1),
            tokio::net::UnixStream::connect(path),
        )
        .await
        .map_err(|_| "истёк тайм-аут соединения со статистикой".to_string())?
        .map_err(|error| format!("не удалось подключиться к статистике: {error}"))?;
        stream
            .write_all(b"snapshot\n")
            .await
            .map_err(|error| error.to_string())?;
        let mut response = Vec::new();
        tokio::time::timeout(Duration::from_secs(1), stream.read_to_end(&mut response))
            .await
            .map_err(|_| "истёк тайм-аут чтения статистики".to_string())?
            .map_err(|error| error.to_string())?;
        if response.len() > 64 * 1024 {
            return Err("ответ статистики превышает допустимый размер".into());
        }
        Ok(response)
    }
    #[cfg(not(unix))]
    {
        let _ = path;
        Err("локальный сокет статистики поддерживается только в Unix".into())
    }
}

fn percentile_stats(samples: &VecDeque<u64>) -> Option<LatencyPercentiles> {
    if samples.is_empty() {
        return None;
    }
    let mut sorted = samples.iter().copied().collect::<Vec<_>>();
    sorted.sort_unstable();
    let percentile = |p: usize| {
        let index = ((sorted.len() - 1) * p).div_ceil(100);
        sorted[index]
    };
    Some(LatencyPercentiles {
        count: sorted.len(),
        p50_ms: percentile(50),
        p95_ms: percentile(95),
        p99_ms: percentile(99),
    })
}

fn bounded_failure_key(stage: &str) -> String {
    match stage {
        "dns" | "tcp" | "tls" | "websocket" | "http_429" | "http_503" | "mtproto" | "timeout"
        | "fd_exhaustion" => stage.to_string(),
        _ => "other".to_string(),
    }
}

fn unix_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

fn read_proc_kib(field: &str) -> Option<u64> {
    let contents = fs::read_to_string("/proc/self/status").ok()?;
    contents.lines().find_map(|line| {
        let (name, value) = line.split_once(':')?;
        if name != field {
            return None;
        }
        value.split_whitespace().next()?.parse().ok()
    })
}

#[cfg(test)]
mod tests {
    use super::{AtomicCounterI64, AtomicCounterU64, RuntimeStats};
    use std::sync::Arc;
    use std::time::Duration;

    #[test]
    fn counters_keep_atomic_api_semantics_on_every_target() {
        let counter = AtomicCounterU64::new(4);
        assert_eq!(
            counter.fetch_add(3, std::sync::atomic::Ordering::Relaxed),
            4
        );
        assert_eq!(counter.load(std::sync::atomic::Ordering::Relaxed), 7);

        let timestamp = AtomicCounterI64::default();
        timestamp.store(-9, std::sync::atomic::Ordering::Release);
        assert_eq!(timestamp.load(std::sync::atomic::Ordering::Acquire), -9);
    }

    #[test]
    fn соединение_освобождает_активный_слот_после_отмены() {
        let stats = Arc::new(RuntimeStats::new());
        let guard = stats.connection_started();
        assert_eq!(stats.snapshot().active_connections, 1);
        assert_eq!(stats.snapshot().active_sessions.len(), 1);
        drop(guard);
        assert_eq!(stats.snapshot().active_connections, 0);
        assert!(stats.snapshot().active_sessions.is_empty());
        assert_eq!(stats.snapshot().accepted_connections, 1);
    }

    #[test]
    fn попытка_маршрута_сохраняет_фактические_состояния_и_ограниченный_журнал() {
        let stats = Arc::new(RuntimeStats::new());
        let guard = stats.connection_started();
        let telemetry = guard.telemetry();
        telemetry.set_dc(2, false);

        for _ in 0..4 {
            telemetry
                .begin_attempt("direct", "direct_wss")
                .finish("failed");
        }

        let snapshot = stats.snapshot();
        let session = &snapshot.active_sessions[0];
        assert_eq!(session.dc, Some(2));
        assert_eq!(session.direct_state, "failed");
        assert_eq!(session.direct_transport, Some("direct_wss"));
        assert_eq!(session.events.len(), super::MAX_ROUTE_EVENTS);
        assert_eq!(session.events.front().unwrap().sequence, 3);
        assert_eq!(session.events.back().unwrap().sequence, 8);
        drop(guard);
        assert!(stats.snapshot().active_sessions.is_empty());
    }

    #[test]
    fn отменённая_параллельная_попытка_не_остаётся_подключающейся() {
        let stats = Arc::new(RuntimeStats::new());
        let guard = stats.connection_started();
        let telemetry = guard.telemetry();
        let attempt = telemetry.begin_attempt("fallback", "cloudflare_proxy");
        drop(attempt);

        let session = &stats.snapshot().active_sessions[0];
        assert_eq!(session.fallback_state, "cancelled");
        assert!(
            session
                .events
                .iter()
                .any(|event| { event.branch == "fallback" && event.state == "cancelled" })
        );
    }

    #[test]
    fn проигравшая_подключённая_ветка_отменяется_при_выборе_победителя() {
        let stats = Arc::new(RuntimeStats::new());
        let guard = stats.connection_started();
        let telemetry = guard.telemetry();
        telemetry
            .begin_attempt("direct", "direct_wss")
            .finish("connected");
        telemetry
            .begin_attempt("fallback", "cloudflare_proxy")
            .finish("connected");

        telemetry.select_transport("direct", "direct_wss");

        let snapshot = stats.snapshot();
        let session = &snapshot.active_sessions[0];
        assert_eq!(session.direct_state, "selected");
        assert_eq!(session.selected_transport, Some("direct_wss"));
        assert_eq!(session.fallback_state, "cancelled");
        assert!(
            session
                .events
                .iter()
                .any(|event| { event.branch == "fallback" && event.state == "cancelled" })
        );
    }

    #[test]
    fn переполнение_активных_снимков_помечается_без_роста_памяти() {
        let stats = Arc::new(RuntimeStats::new());
        let connections = (0..=super::MAX_ACTIVE_ROUTE_SESSIONS)
            .map(|_| {
                let guard = stats.connection_started();
                let telemetry = guard.telemetry();
                telemetry.set_dc(2, false);
                for _ in 0..3 {
                    telemetry
                        .begin_attempt("fallback", "cloudflare_proxy")
                        .finish("failed");
                }
                guard
            })
            .collect::<Vec<_>>();
        let snapshot = stats.snapshot();
        assert_eq!(
            snapshot.active_connections,
            super::MAX_ACTIVE_ROUTE_SESSIONS + 1
        );
        assert_eq!(
            snapshot.active_sessions.len(),
            super::MAX_ACTIVE_ROUTE_SESSIONS
        );
        assert!(snapshot.route_sessions_truncated);
        assert!(
            serde_json::to_vec(&snapshot).unwrap().len() < 64 * 1024,
            "активная телеметрия не должна переполнять ограниченный stats API"
        );
        drop(connections);
        assert!(stats.snapshot().active_sessions.is_empty());
    }

    #[test]
    fn ответ_mtproto_обновляет_счётчик_маршрута_и_ttfb() {
        let stats = RuntimeStats::new();
        stats.record_mtproto_response(2, "cf-worker", Duration::from_millis(37));
        let snapshot = stats.snapshot();
        assert_eq!(snapshot.mtproto_success, 1);
        assert_eq!(
            snapshot.sessions_by_dc_transport.get("dc2:cf-worker"),
            Some(&1)
        );
        assert_eq!(snapshot.ttfb["dc2:cf-worker"].p50_ms, 37);
        assert!(snapshot.last_mtproto_response_at > 0);
    }

    #[test]
    fn причины_отказа_ограничены_известным_набором() {
        let stats = RuntimeStats::new();
        stats.record_failure("dns");
        stats.record_failure("произвольный текст с адресами");
        assert_eq!(stats.snapshot().failures.get("dns"), Some(&1));
        assert_eq!(stats.snapshot().failures.get("other"), Some(&1));
    }

    #[test]
    fn состояние_worker_содержит_время_последнего_отказа() {
        let stats = RuntimeStats::new();
        stats.record_worker_failure("worker.example", "TLS timeout");
        let snapshot = stats.snapshot();
        let state = &snapshot.workers["worker.example"];
        assert_eq!(state.state, "unavailable");
        assert!(state.last_failure_at > 0);
        assert_eq!(state.last_failure.as_deref(), Some("TLS timeout"));
    }

    #[cfg(unix)]
    #[tokio::test]
    async fn локальный_сокет_статистики_доступен_только_владельцу() {
        use std::os::unix::fs::PermissionsExt;

        let directory = std::env::temp_dir().join(format!("z2k-tg-stats-{}", std::process::id()));
        let path = directory.join("stats.sock");
        let stats = Arc::new(RuntimeStats::new());
        stats.set_listener_ready(true);
        let server = tokio::spawn(super::serve_unix(path.clone(), Arc::clone(&stats)));
        for _ in 0..100 {
            if path.exists() {
                break;
            }
            tokio::time::sleep(Duration::from_millis(2)).await;
        }
        let mode = std::fs::metadata(&path).unwrap().permissions().mode() & 0o777;
        assert_eq!(mode, 0o600);
        let snapshot = super::read_socket(&path).await.unwrap();
        let snapshot: serde_json::Value = serde_json::from_slice(&snapshot).unwrap();
        assert_eq!(snapshot["listener_ready"], true);
        assert!(
            super::serve_unix(path.clone(), Arc::clone(&stats))
                .await
                .unwrap_err()
                .contains("уже обслуживается")
        );
        assert!(super::read_socket(&path).await.is_ok());
        server.abort();
        let _ = server.await;
        std::fs::remove_file(&path).unwrap();
        std::fs::remove_dir_all(directory).unwrap();
    }
}
