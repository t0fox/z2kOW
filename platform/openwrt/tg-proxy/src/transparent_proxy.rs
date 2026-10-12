//! Прозрачный MTProto перехват, выбор WSS fallback и передача потока.

use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{debug, info, warn};

use crate::config::Config;
use crate::routing::{self, Upstream};
use crate::runtime::Runtime;
use crate::transparent;
use crate::ws_client::media_tag;

/// Путь для прозрачного перехвата правилами REDIRECT на роутере. Начальный
/// пакет obfuscated2 содержит DC и признак media, а SO_ORIGINAL_DST — точный IP DC.
/// Начальный пакет и все последующие байты передаются выбранному узлу без изменений.
pub async fn handle_transparent_client_with_runtime(
    mut stream: TcpStream,
    peer: SocketAddr,
    config: Arc<Config>,
    runtime: Arc<Runtime>,
) {
    let destination = match transparent::original_destination(&stream) {
        Ok(destination) => destination,
        Err(error) => {
            warn!(
                "[{}] прозрачное перенаправление: SO_ORIGINAL_DST недоступен: {}",
                peer, error
            );
            return;
        }
    };
    debug!(
        "[{}] исходное назначение прозрачного потока: {}",
        peer, destination
    );
    if !transparent::supports_destination_port(destination.port(), &config.transparent_ports) {
        debug!(
            "[{}] прозрачное перенаправление отклонено: порт {} отсутствует в политике",
            peer,
            destination.port()
        );
        return;
    }
    if !transparent::is_telegram_destination(destination.ip(), &config.transparent_cidrs) {
        debug!(
            "[{}] прозрачное перенаправление отклонено: IP назначения {} не входит в CIDR Telegram",
            peer,
            destination.ip()
        );
        return;
    }
    let _ = stream.set_nodelay(true);

    let mut init = [0u8; crate::crypto::HANDSHAKE_LEN];
    let read_init = tokio::time::timeout(Duration::from_secs(config.handshake_timeout), async {
        stream.read_exact(&mut init[..4]).await?;
        if transparent::is_http_request(&init[..4]) {
            return Ok::<bool, std::io::Error>(false);
        }
        stream.read_exact(&mut init[4..]).await?;
        Ok(true)
    })
    .await;
    match read_init {
        Ok(Ok(true)) => {}
        Ok(Ok(false)) => {
            debug!(
                "[{}] HTTP на TCP/{} не является прозрачным MTProto-потоком",
                peer,
                destination.port()
            );
            return;
        }
        Ok(Err(error)) => {
            debug!(
                "[{}] не удалось прочитать начальный пакет obfuscated2: {}",
                peer, error
            );
            return;
        }
        Err(_) => {
            debug!(
                "[{}] истекло время ожидания начального пакета obfuscated2",
                peer
            );
            return;
        }
    }
    let secret_candidates = runtime
        .dc_map()
        .handshake_secrets_for(destination.ip(), destination.port());
    let Some(init_info) = transparent::parse_client_init_with_secrets(&init, &secret_candidates)
    else {
        debug!(
            "[{}] неизвестное или повреждённое рукопожатие MTProto для назначения {}",
            peer, destination
        );
        return;
    };
    let (destination_route, map_source) = match runtime.dc_map().resolve_with_source(
        destination.ip(),
        destination.port(),
        init_info.is_media,
        init_info.dc,
    ) {
        Ok(route) => route,
        Err(error) => {
            warn!(
                "[{}] прозрачный маршрут отклонён для {}: {} (DC из рукопожатия: {:?}, media: {})",
                peer, destination, error, init_info.dc, init_info.is_media
            );
            return;
        }
    };
    let dc = destination_route.id;
    let is_media = destination_route.media_only;
    info!(
        "[{}] dcOption для {}: DC{}{}, карта={}, CDN={}, TCP-only={}, this-port-only={}, порт опции={}, порт клиента={}",
        peer,
        destination,
        dc,
        media_tag(is_media),
        map_source.as_str(),
        destination_route.cdn,
        destination_route.tcpo_only,
        destination_route.this_port_only,
        destination_route.port,
        destination.port()
    );
    let label = peer;
    let target_ip = destination.ip().to_string();
    let route = routing::Route::new(label, &config, &runtime, dc, is_media);
    let tcp_fallback_timeout = route.tcp_fallback_timeout();
    let Some(upstream) = routing::select_upstream(&route, &target_ip).await else {
        return;
    };
    match upstream {
        Upstream::Ws {
            ws,
            framing,
            route_type,
        } => {
            crate::bridge::bridge_transparent_ws(
                stream,
                *ws,
                init,
                label,
                destination,
                dc,
                is_media,
                init_info.proto,
                framing,
                route_type,
            )
            .await;
        }
        Upstream::Tcp(host) => {
            let (fallback_host, fallback_port) =
                transparent::tcp_fallback_target(&host, destination);
            match runtime
                .outbound()
                .connect(&fallback_host, fallback_port, tcp_fallback_timeout)
                .await
            {
                Ok(mut remote) => {
                    if let Err(error) = remote.write_all(&init).await {
                        warn!(
                            "[{}] не удалось передать начальный пакет по резервному TCP: {}",
                            peer, error
                        );
                        return;
                    }
                    let mut client = stream;
                    match tokio::io::copy_bidirectional(&mut client, &mut remote).await {
                        Ok((bytes_up, bytes_down)) => info!(
                            "[{}] прозрачный маршрут=резервный TCP DC{}{} закрыт клиентом: вверх {} байт, вниз {} байт",
                            peer,
                            dc,
                            media_tag(is_media),
                            bytes_up,
                            bytes_down
                        ),
                        Err(error) => debug!(
                            "[{}] прозрачный маршрут=резервный TCP DC{}{} закрыт с ошибкой: {}",
                            peer,
                            dc,
                            media_tag(is_media),
                            error
                        ),
                    }
                }
                Err(error) => warn!(
                    "[{}] не удалось открыть резервное TCP-соединение с {}: {}",
                    peer, host, error
                ),
            }
        }
    }
}
