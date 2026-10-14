//! Прозрачный TCP listener и ограниченный accept loop для OpenWrt.

use std::future::Future;
use std::io;
use std::net::{Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use socket2::{Domain, Protocol, Socket, Type};
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
use tokio::task::{JoinError, JoinSet};
use tracing::{error, info, warn};

use crate::config::Config;
use crate::limits::{auto_max_connections, soft_nofile_limit};
use crate::runtime::Runtime;
use crate::transparent_proxy;

fn listen_address(host: &str, port: u16) -> String {
    let host = if host.parse::<Ipv6Addr>().is_ok() {
        format!("[{host}]")
    } else {
        host.to_string()
    };
    format!("{host}:{port}")
}

async fn cancel_and_join_clients(clients: &mut JoinSet<()>) {
    clients.shutdown().await;
}

fn log_client_task_result(result: Result<(), JoinError>) {
    if let Err(error) = result
        && error.is_panic()
    {
        warn!("задача Telegram-соединения завершилась аварийно: {error}");
    }
}

async fn bind_server_listener(addr: SocketAddr, dual_stack: bool) -> std::io::Result<TcpListener> {
    if dual_stack && addr.is_ipv6() {
        let socket = Socket::new(Domain::IPV6, Type::STREAM, Some(Protocol::TCP))?;
        socket.set_reuse_address(true)?;
        socket.set_only_v6(false)?;
        socket.bind(&addr.into())?;
        socket.listen(1024)?;
        socket.set_nonblocking(true)?;
        let listener: std::net::TcpListener = socket.into();
        TcpListener::from_std(listener)
    } else {
        TcpListener::bind(addr).await
    }
}

const ACCEPT_REBIND_THRESHOLD: u8 = 5;
const ACCEPT_REBIND_ATTEMPTS: u8 = 5;
const MAX_CONSECUTIVE_REBINDS: u8 = 3;

fn is_fd_exhaustion(error: &io::Error) -> bool {
    error
        .raw_os_error()
        .is_some_and(|code| code == libc::EMFILE || code == libc::ENFILE)
}

fn accept_error_requires_rebind(error: &io::Error, consecutive: u8) -> bool {
    !is_fd_exhaustion(error) && consecutive >= ACCEPT_REBIND_THRESHOLD
}

fn listener_rebind_backoff(attempt: u8) -> Duration {
    Duration::from_millis(100u64.saturating_mul(1u64 << attempt.min(4)))
}

fn rebind_limit_reached(consecutive_rebinds: u8) -> bool {
    consecutive_rebinds >= MAX_CONSECUTIVE_REBINDS
}

async fn rebind_listener(
    previous: TcpListener,
    addr: SocketAddr,
    dual_stack: bool,
) -> io::Result<TcpListener> {
    drop(previous);
    let mut last_error = None;
    for attempt in 0..ACCEPT_REBIND_ATTEMPTS {
        if attempt > 0 {
            tokio::time::sleep(listener_rebind_backoff(attempt - 1)).await;
        }
        match bind_server_listener(addr, dual_stack).await {
            Ok(listener) => return Ok(listener),
            Err(error)
                if matches!(
                    error.kind(),
                    io::ErrorKind::AddrInUse
                        | io::ErrorKind::WouldBlock
                        | io::ErrorKind::Interrupted
                ) || is_fd_exhaustion(&error) =>
            {
                last_error = Some(error);
            }
            Err(error) => return Err(error),
        }
    }
    Err(last_error.unwrap_or_else(|| io::Error::other("listener rebind исчерпал попытки")))
}

#[derive(Debug)]
pub enum RunError {
    InvalidListenAddress(String),
    Bind {
        addr: SocketAddr,
        source: std::io::Error,
    },
    AcceptRecovery {
        addr: SocketAddr,
        source: std::io::Error,
    },
}

impl std::fmt::Display for RunError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::InvalidListenAddress(address) => {
                write!(f, "неверный адрес прослушивания: {address}")
            }
            Self::Bind { addr, source } => {
                write!(f, "не удалось начать прослушивание {addr}: {source}")
            }
            Self::AcceptRecovery { addr, source } => {
                write!(f, "не удалось восстановить accept() на {addr}: {source}")
            }
        }
    }
}

impl std::error::Error for RunError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Bind { source, .. } | Self::AcceptRecovery { source, .. } => Some(source),
            _ => None,
        }
    }
}

#[derive(Clone, Debug)]
pub struct ListenInfo {
    pub addr: SocketAddr,
}

pub fn install_crypto_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

pub async fn run(
    config: Config,
    shutdown: impl Future<Output = ()> + Send,
) -> Result<(), RunError> {
    run_with_listen(config, shutdown, |_| {}).await
}

pub async fn run_with_listen(
    config: Config,
    shutdown: impl Future<Output = ()> + Send,
    on_listen: impl FnOnce(ListenInfo) + Send,
) -> Result<(), RunError> {
    install_crypto_provider();

    let outbound = config.outbound_connector();
    let runtime = Arc::new(
        Runtime::new(outbound)
            .with_dc_map_path(config.dc_map_path.clone())
            .with_cf_domain_pool(
                config.cf_domains.clone(),
                config.default_domains,
                config
                    .dc_map_path
                    .with_file_name("telegram-cf-domains.json"),
            )
            .with_cf_ips(config.cf_ips.clone())
            .with_cf_worker_domains(config.cf_worker_domains.clone())
            .with_cf_fail_cooldown(Duration::from_secs(config.cf_fail_cooldown)),
    );

    tokio::pin!(shutdown);
    let cf_snapshot = runtime.cf_domains();
    info!(
        "Пул CF-прокси готов: {} доменов, поколение {}, время последнего обновления {}",
        cf_snapshot.domains.len(),
        cf_snapshot.generation,
        cf_snapshot.fetched_at
    );
    if let Some(snapshot) = runtime.dc_map().current() {
        runtime
            .stats()
            .set_dc_map(snapshot.config_date as u64, snapshot.fetched_at);
    }
    runtime
        .stats()
        .set_cf_pool(&cf_snapshot.domains, cf_snapshot.fetched_at);

    let bind_host = config.bind_host();
    let address = listen_address(&bind_host, config.port);
    let addr: SocketAddr = address
        .parse()
        .map_err(|_| RunError::InvalidListenAddress(address.clone()))?;
    let mut listener = bind_server_listener(addr, true)
        .await
        .map_err(|source| RunError::Bind { addr, source })?;
    let bound_addr = listener.local_addr().unwrap_or(addr);
    runtime.stats().set_listener_ready(true);

    let fd_limit = soft_nofile_limit();
    let safe_max_connections = auto_max_connections(fd_limit, config.ws_hedge_limit);
    let max_connections = config.max_connections.unwrap_or(safe_max_connections);
    runtime.stats().set_max_connections(max_connections);
    if max_connections > safe_max_connections {
        warn!(
            "max-connections={} выше безопасного лимита {} для {} дескрипторов",
            max_connections, safe_max_connections, fd_limit
        );
    }

    info!("Telegram transparent MTProto → WSS слушает {}", bound_addr);
    info!("Вход: nft REDIRECT → SO_ORIGINAL_DST → obfuscated2");
    info!("Лимит соединений: {} (FD: {})", max_connections, fd_limit);
    on_listen(ListenInfo { addr: bound_addr });

    let config = Arc::new(config);
    let mut background_tasks = JoinSet::new();
    {
        let stats = Arc::clone(runtime.stats());
        let path = config.stats_socket_path.clone();
        background_tasks.spawn(async move {
            if let Err(error) = crate::stats::serve_unix(path, stats).await {
                warn!("Локальный сокет статистики TG не запущен: {error}");
            }
        });
    }
    if runtime.cf_domain_pool().enabled() {
        background_tasks.spawn(crate::cf_domain_pool::refresh_loop(Arc::clone(&runtime)));
    }
    background_tasks.spawn(crate::dc_discovery::refresh_loop(
        Arc::clone(&runtime),
        config.dc_map_refresh_secs,
        config.dc_map_endpoints_path.clone(),
        config.transparent_ports.clone(),
    ));

    let semaphore = Arc::new(Semaphore::new(max_connections));
    let mut clients = JoinSet::new();
    let mut consecutive_accept_errors = 0u8;
    let mut consecutive_rebinds = 0u8;

    loop {
        let permit = tokio::select! {
            _ = &mut shutdown => break,
            Some(result) = clients.join_next(), if !clients.is_empty() => {
                log_client_task_result(result);
                continue;
            }
            permit = Arc::clone(&semaphore).acquire_owned() => {
                permit.expect("semaphore закрыт неожиданно")
            }
        };

        tokio::select! {
            _ = &mut shutdown => break,
            Some(result) = clients.join_next(), if !clients.is_empty() => {
                log_client_task_result(result);
            }
            accepted = listener.accept() => match accepted {
                Ok((stream, peer_addr)) => {
                    consecutive_accept_errors = 0;
                    consecutive_rebinds = 0;
                    let cfg = Arc::clone(&config);
                    let runtime = Arc::clone(&runtime);
                    let connection = runtime.stats().connection_started();
                    let telemetry = connection.telemetry();
                    clients.spawn(async move {
                        let _connection = connection;
                        let _permit = permit;
                        transparent_proxy::handle_transparent_client_with_runtime(
                            stream, peer_addr, cfg, runtime, telemetry,
                        ).await;
                    });
                }
                Err(error) => {
                    if is_fd_exhaustion(&error) {
                        runtime.stats().record_failure("fd_exhaustion");
                        warn!("ошибка приёма: {}; ожидание освобождения дескрипторов", error);
                        tokio::time::sleep(Duration::from_millis(500)).await;
                    } else {
                        consecutive_accept_errors = consecutive_accept_errors.saturating_add(1);
                        runtime.stats().record_failure("tcp");
                        if accept_error_requires_rebind(&error, consecutive_accept_errors) {
                            if rebind_limit_reached(consecutive_rebinds) {
                                error!("accept() продолжает завершаться ошибкой после ограниченного восстановления listener");
                                return Err(RunError::AcceptRecovery {
                                    addr,
                                    source: error,
                                });
                            }
                            warn!("{} последовательных ошибок accept(); безопасно пересоздаю listener", consecutive_accept_errors);
                            tokio::time::sleep(listener_rebind_backoff(consecutive_rebinds)).await;
                            runtime.stats().set_listener_ready(false);
                            match rebind_listener(listener, addr, true).await {
                                Ok(replacement) => {
                                    listener = replacement;
                                    consecutive_accept_errors = 0;
                                    consecutive_rebinds = consecutive_rebinds.saturating_add(1);
                                    runtime.stats().set_listener_ready(true);
                                    info!("listener Telegram восстановлен на {}", bound_addr);
                                }
                                Err(source) => {
                                    error!("не удалось восстановить listener Telegram: {}", source);
                                    return Err(RunError::Bind { addr, source });
                                }
                            }
                        } else {
                            error!("ошибка приёма: {}", error);
                            tokio::time::sleep(Duration::from_millis(50)).await;
                        }
                    }
                }
            }
        }
    }

    background_tasks.shutdown().await;
    runtime.stats().set_listener_ready(false);
    cancel_and_join_clients(&mut clients).await;
    info!("прокси остановлен");
    Ok(())
}

#[cfg(all(test, target_os = "linux"))]
mod transparent_listener_tests {
    use super::{
        ACCEPT_REBIND_THRESHOLD, accept_error_requires_rebind, bind_server_listener,
        cancel_and_join_clients, is_fd_exhaustion, listener_rebind_backoff, rebind_limit_reached,
        rebind_listener, run_with_listen,
    };
    use crate::config::Config;
    use std::net::{Ipv6Addr, SocketAddr};
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;
    use tokio::net::TcpStream;
    use tokio::sync::oneshot;
    use tokio::task::JoinSet;

    #[test]
    fn fd_exhaustion_is_waited_out_and_rebind_uses_a_bounded_backoff() {
        let emfile = std::io::Error::from_raw_os_error(24);
        let transient = std::io::Error::from(std::io::ErrorKind::ConnectionReset);
        assert!(is_fd_exhaustion(&emfile));
        assert!(!accept_error_requires_rebind(
            &emfile,
            ACCEPT_REBIND_THRESHOLD
        ));
        assert!(!accept_error_requires_rebind(
            &transient,
            ACCEPT_REBIND_THRESHOLD - 1
        ));
        assert!(accept_error_requires_rebind(
            &transient,
            ACCEPT_REBIND_THRESHOLD
        ));
        assert_eq!(listener_rebind_backoff(0), Duration::from_millis(100));
        assert_eq!(listener_rebind_backoff(8), Duration::from_millis(1_600));
        assert!(!rebind_limit_reached(2));
        assert!(rebind_limit_reached(3));
    }

    #[tokio::test]
    async fn rebind_does_not_drop_established_client_streams_or_open_two_listeners() {
        let original = bind_server_listener("127.0.0.1:0".parse().unwrap(), false)
            .await
            .unwrap();
        let address = original.local_addr().unwrap();
        let first_client = tokio::net::TcpStream::connect(address).await.unwrap();
        let (first_server, _) = original.accept().await.unwrap();
        let replacement = rebind_listener(original, address, false).await.unwrap();
        let second_client = tokio::net::TcpStream::connect(address).await.unwrap();
        let (second_server, _) = replacement.accept().await.unwrap();

        first_client.writable().await.unwrap();
        first_client.try_write(b"a").unwrap();
        second_client.writable().await.unwrap();
        second_client.try_write(b"b").unwrap();
        let mut bytes = [0u8; 1];
        first_server.readable().await.unwrap();
        first_server.try_read(&mut bytes).unwrap();
        assert_eq!(bytes, [b'a']);
        second_server.readable().await.unwrap();
        second_server.try_read(&mut bytes).unwrap();
        assert_eq!(bytes, [b'b']);
    }

    #[tokio::test]
    async fn listener_accepts_ipv4_and_ipv6() {
        let listener = bind_server_listener("[::]:0".parse().unwrap(), true)
            .await
            .unwrap();
        let port = listener.local_addr().unwrap().port();
        let v4 = TcpStream::connect(SocketAddr::from(([127, 0, 0, 1], port)));
        let v6 = TcpStream::connect(SocketAddr::from((Ipv6Addr::LOCALHOST, port)));
        let (v4, v6) = tokio::join!(v4, v6);
        assert!(v4.is_ok(), "не удалось подключиться через IPv4: {v4:?}");
        assert!(v6.is_ok(), "не удалось подключиться через IPv6: {v6:?}");
    }

    #[tokio::test]
    async fn server_implicitly_starts_in_transparent_mode_and_stops() {
        let state_dir =
            std::env::temp_dir().join(format!("z2kow-server-cf-domains-{}", std::process::id()));
        let cache_path = state_dir.join("telegram-cf-domains.json");
        let dc_map_path = state_dir.join("telegram-dc-map.json");
        let config = Config::try_from_cli_line(&format!(
            "--host :: --port 0 --default-domains --dc-map-path {}",
            dc_map_path.display()
        ))
        .unwrap();
        let (bound_tx, bound_rx) = oneshot::channel();
        let (shutdown_tx, shutdown_rx) = oneshot::channel();
        let server = tokio::spawn(run_with_listen(
            config,
            async move {
                let _ = shutdown_rx.await;
            },
            move |info| {
                let _ = bound_tx.send(info.addr);
            },
        ));

        let bound_result = tokio::time::timeout(Duration::from_secs(2), bound_rx)
            .await
            .expect("сервер не начал слушать");
        let bound = match bound_result {
            Ok(bound) => bound,
            Err(_) => panic!("сервер завершился до bind: {:?}", server.await.unwrap()),
        };
        assert_eq!(bound.ip(), Ipv6Addr::UNSPECIFIED);
        let _ = shutdown_tx.send(());
        assert!(
            tokio::time::timeout(Duration::from_secs(2), server)
                .await
                .expect("сервер не остановился")
                .unwrap()
                .is_ok()
        );
        let _ = std::fs::remove_file(cache_path);
    }

    #[tokio::test]
    async fn client_shutdown_aborts_and_joins_active_sessions_idempotently() {
        let cleaned = Arc::new(AtomicBool::new(false));
        let mut clients = JoinSet::new();
        let task_cleaned = Arc::clone(&cleaned);
        clients.spawn(async move {
            struct MarkCleaned(Arc<AtomicBool>);
            impl Drop for MarkCleaned {
                fn drop(&mut self) {
                    self.0.store(true, Ordering::SeqCst);
                }
            }
            let _mark_cleaned = MarkCleaned(task_cleaned);
            std::future::pending::<()>().await;
        });
        tokio::task::yield_now().await;

        cancel_and_join_clients(&mut clients).await;
        cancel_and_join_clients(&mut clients).await;

        assert!(cleaned.load(Ordering::SeqCst));
        assert!(clients.is_empty());
    }
}
