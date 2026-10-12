//! Прозрачный TCP listener и ограниченный accept loop для OpenWrt.

use std::future::Future;
use std::net::{Ipv6Addr, SocketAddr};
use std::sync::Arc;
use std::time::Duration;

use socket2::{Domain, Protocol, Socket, Type};
use tokio::net::TcpListener;
use tokio::sync::Semaphore;
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

#[derive(Debug)]
pub enum RunError {
    InvalidListenAddress(String),
    Bind {
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
        }
    }
}

impl std::error::Error for RunError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        match self {
            Self::Bind { source, .. } => Some(source),
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
    mut config: Config,
    shutdown: impl Future<Output = ()> + Send,
    on_listen: impl FnOnce(ListenInfo) + Send,
) -> Result<(), RunError> {
    install_crypto_provider();

    let outbound = config.outbound_connector();
    let runtime = Arc::new(
        Runtime::new(outbound)
            .with_dc_map_path(config.dc_map_path.clone())
            .with_cf_ips(config.cf_ips.clone())
            .with_cf_fail_cooldown(Duration::from_secs(config.cf_fail_cooldown)),
    );

    tokio::pin!(shutdown);

    if config.default_domains {
        info!("Загрузка списка доменов CF-прокси…");
        let fetched = tokio::select! {
            _ = &mut shutdown => {
                info!("прокси остановлен");
                return Ok(());
            }
            fetched = crate::default_domains::fetch_default_domains_with_outbound(runtime.outbound()) => fetched,
        };
        info!("Загружено доменов CF: {}", fetched.len());
        config.cf_domains.extend(fetched);
    }

    let bind_host = config.bind_host();
    let address = listen_address(&bind_host, config.port);
    let addr: SocketAddr = address
        .parse()
        .map_err(|_| RunError::InvalidListenAddress(address.clone()))?;
    let listener = bind_server_listener(addr, true)
        .await
        .map_err(|source| RunError::Bind { addr, source })?;
    let bound_addr = listener.local_addr().unwrap_or(addr);

    let fd_limit = soft_nofile_limit();
    let safe_max_connections = auto_max_connections(fd_limit, config.ws_hedge_limit);
    let max_connections = config.max_connections.unwrap_or(safe_max_connections);
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

    let refresh_task = {
        let runtime = Arc::clone(&runtime);
        let interval = config.dc_map_refresh_secs;
        let endpoints_path = config.dc_map_endpoints_path.clone();
        let transparent_ports = config.transparent_ports.clone();
        let cf_domains = config.cf_domains.clone();
        tokio::spawn(async move {
            crate::dc_discovery::refresh_loop(
                runtime,
                interval,
                endpoints_path,
                transparent_ports,
                cf_domains,
            )
            .await;
        })
    };

    let semaphore = Arc::new(Semaphore::new(max_connections));
    const EMFILE: i32 = 24;
    const ENFILE: i32 = 23;

    loop {
        let permit = tokio::select! {
            _ = &mut shutdown => break,
            permit = Arc::clone(&semaphore).acquire_owned() => {
                permit.expect("semaphore закрыт неожиданно")
            }
        };

        tokio::select! {
            _ = &mut shutdown => break,
            accepted = listener.accept() => match accepted {
                Ok((stream, peer_addr)) => {
                    let cfg = Arc::clone(&config);
                    let runtime = Arc::clone(&runtime);
                    tokio::spawn(async move {
                        let _permit = permit;
                        transparent_proxy::handle_transparent_client_with_runtime(
                            stream, peer_addr, cfg, runtime,
                        ).await;
                    });
                }
                Err(error) => {
                    if matches!(error.raw_os_error(), Some(EMFILE) | Some(ENFILE)) {
                        warn!("ошибка приёма: {}; ожидание освобождения дескрипторов", error);
                        tokio::time::sleep(Duration::from_millis(500)).await;
                    } else {
                        error!("ошибка приёма: {}", error);
                        tokio::time::sleep(Duration::from_millis(50)).await;
                    }
                }
            }
        }
    }

    refresh_task.abort();
    info!("прокси остановлен");
    Ok(())
}

#[cfg(all(test, target_os = "linux"))]
mod transparent_listener_tests {
    use super::{bind_server_listener, run_with_listen};
    use crate::config::Config;
    use std::net::{Ipv6Addr, SocketAddr};
    use std::time::Duration;
    use tokio::net::TcpStream;
    use tokio::sync::oneshot;

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
        let config = Config::try_from_cli_line("--host :: --port 0").unwrap();
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
    }
}
