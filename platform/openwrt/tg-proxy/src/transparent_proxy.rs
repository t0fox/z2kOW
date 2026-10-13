//! Прозрачный MTProto перехват, выбор WSS fallback и передача потока.

use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;
use std::time::Duration;

use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tracing::{debug, info, warn};

use crate::config::Config;
use crate::dc_map::RouteLookupError;
use crate::routing::{self, Upstream};
use crate::runtime::Runtime;
use crate::transparent;
use crate::ws_client::media_tag;

const MAX_HTTP_HEADER_BYTES: usize = 16 * 1024;
const MAX_HTTP_HEADERS: usize = 32;
const MAX_HTTP_BODY_BYTES: usize = 16 * 1024 * 1024 + 4;
const INITIAL_PREFIX_LEN: usize = 8;

async fn read_initial_prefix(stream: &mut TcpStream) -> std::io::Result<[u8; INITIAL_PREFIX_LEN]> {
    let mut prefix = [0u8; INITIAL_PREFIX_LEN];
    stream.read_exact(&mut prefix).await?;
    Ok(prefix)
}

fn effective_media_route(client_is_media: bool, endpoint_media_only: bool) -> bool {
    client_is_media || endpoint_media_only
}

fn should_forward_unmapped_direct(error: &RouteLookupError, dc_hint: Option<u32>) -> bool {
    *error == RouteLookupError::AddressNotListed && dc_hint.is_none()
}

fn trim_http_ows(mut value: &[u8]) -> &[u8] {
    while value
        .first()
        .is_some_and(|byte| matches!(byte, b' ' | b'\t'))
    {
        value = &value[1..];
    }
    while value
        .last()
        .is_some_and(|byte| matches!(byte, b' ' | b'\t'))
    {
        value = &value[..value.len() - 1];
    }
    value
}

fn http_host_matches_dc(value: &[u8], destination: SocketAddr, dc: u32) -> bool {
    let value = trim_http_ows(value);
    let Ok(host) = std::str::from_utf8(value) else {
        return false;
    };
    if !host.is_ascii() || host.bytes().any(|byte| byte.is_ascii_whitespace()) {
        return false;
    }
    if let Ok(address) = host.parse::<SocketAddr>() {
        return address.ip() == destination.ip() && address.port() == 80;
    }
    if let Ok(address) = host.parse::<std::net::IpAddr>() {
        return address == destination.ip();
    }
    if host.starts_with('[') && host.ends_with(']') {
        return host[1..host.len() - 1]
            .parse::<std::net::IpAddr>()
            .is_ok_and(|address| address == destination.ip());
    }

    let domain = host.strip_suffix(":80").unwrap_or(host);
    let name = match dc {
        1 => "pluto",
        2 => "venus",
        3 => "aurora",
        4 => "vesta",
        5 => "flora",
        _ => return false,
    };
    domain.eq_ignore_ascii_case(&format!("{name}.web.telegram.org"))
        || domain.eq_ignore_ascii_case(&format!("{name}-1.web.telegram.org"))
}

fn validate_http_request_head(
    bytes: &[u8],
    destination: SocketAddr,
    dc: u32,
) -> Result<usize, &'static str> {
    let mut headers = [httparse::EMPTY_HEADER; MAX_HTTP_HEADERS];
    let mut request = httparse::Request::new(&mut headers);
    let header_len = match request.parse(bytes) {
        Ok(httparse::Status::Complete(length)) => length,
        Ok(httparse::Status::Partial) => return Err("HTTP-заголовок неполный"),
        Err(_) => return Err("некорректный HTTP-запрос"),
    };
    if request.method != Some("POST") || request.path != Some("/api") || request.version != Some(1)
    {
        return Err("разрешён только POST /api HTTP/1.1");
    }

    let mut host = None;
    let mut content_length = None;
    for header in request.headers.iter() {
        if header.name.eq_ignore_ascii_case("host") {
            if host.replace(header.value).is_some() {
                return Err("повторный HTTP Host");
            }
        } else if header.name.eq_ignore_ascii_case("content-length") {
            if content_length.is_some() {
                return Err("повторный HTTP Content-Length");
            }
            let value = trim_http_ows(header.value);
            if value.is_empty() || !value.iter().all(u8::is_ascii_digit) {
                return Err("некорректный HTTP Content-Length");
            }
            let text =
                std::str::from_utf8(value).map_err(|_| "некорректный HTTP Content-Length")?;
            let length = text
                .parse::<usize>()
                .map_err(|_| "некорректный HTTP Content-Length")?;
            if length == 0 || length > MAX_HTTP_BODY_BYTES {
                return Err("размер MTProto HTTP-тела вне допустимого диапазона");
            }
            content_length = Some(length);
        } else if header.name.eq_ignore_ascii_case("transfer-encoding")
            || header.name.eq_ignore_ascii_case("expect")
            || header.name.eq_ignore_ascii_case("upgrade")
            || header.name.to_ascii_lowercase().starts_with("proxy-")
        {
            return Err("HTTP-заголовок не поддерживается для MTProto");
        }
    }

    let host = host.ok_or("в HTTP-запросе отсутствует Host")?;
    if !http_host_matches_dc(host, destination, dc) {
        return Err("HTTP Host не совпадает с проверенным DC");
    }
    if content_length.is_none() {
        return Err("в HTTP-запросе отсутствует Content-Length");
    }
    Ok(header_len)
}

async fn read_http_transport_request(
    stream: &mut TcpStream,
    first_bytes: [u8; INITIAL_PREFIX_LEN],
    destination: SocketAddr,
    dc: u32,
) -> Result<Vec<u8>, String> {
    let mut request = first_bytes.to_vec();
    loop {
        if let Some(header_end) = request
            .windows(4)
            .position(|window| window == b"\r\n\r\n")
            .map(|index| index + 4)
        {
            if header_end > MAX_HTTP_HEADER_BYTES {
                return Err("HTTP-заголовок превышает допустимый размер".to_string());
            }
            validate_http_request_head(&request[..header_end], destination, dc)
                .map_err(str::to_string)?;
            return Ok(request);
        }
        if request.len() >= MAX_HTTP_HEADER_BYTES {
            return Err("HTTP-заголовок превышает допустимый размер".to_string());
        }
        let mut chunk = [0u8; 1024];
        let read_len = chunk.len().min(MAX_HTTP_HEADER_BYTES - request.len());
        let count = stream
            .read(&mut chunk[..read_len])
            .await
            .map_err(|error| format!("не удалось прочитать HTTP-заголовок: {error}"))?;
        if count == 0 {
            return Err("клиент закрыл соединение до конца HTTP-заголовка".to_string());
        }
        request.extend_from_slice(&chunk[..count]);
    }
}

async fn wait_for_client_reset(client: &TcpStream) {
    let mut byte = [0u8; 1];
    loop {
        match client.peek(&mut byte).await {
            Ok(_) => tokio::time::sleep(Duration::from_millis(25)).await,
            Err(error)
                if matches!(
                    error.kind(),
                    std::io::ErrorKind::Interrupted | std::io::ErrorKind::WouldBlock
                ) => {}
            Err(_) => return,
        }
    }
}

async fn complete_unless_client_resets<F: Future>(
    client: &TcpStream,
    operation: F,
) -> Option<F::Output> {
    tokio::select! {
        result = operation => Some(result),
        _ = wait_for_client_reset(client) => None,
    }
}

async fn bridge_direct_tcp(
    client: TcpStream,
    init: [u8; crate::crypto::HANDSHAKE_LEN],
    destination: SocketAddr,
    peer: SocketAddr,
    is_media: bool,
    config: Arc<Config>,
    runtime: Arc<Runtime>,
) {
    bridge_direct_payload(
        client,
        DirectPayload {
            initial: &init,
            destination,
            peer,
            is_media,
            transport: "прямой TCP",
        },
        config,
        runtime,
    )
    .await;
}

async fn bridge_direct_http(
    client: TcpStream,
    initial_request: Vec<u8>,
    destination: SocketAddr,
    peer: SocketAddr,
    is_media: bool,
    config: Arc<Config>,
    runtime: Arc<Runtime>,
) {
    bridge_direct_payload(
        client,
        DirectPayload {
            initial: &initial_request,
            destination,
            peer,
            is_media,
            transport: "MTProto HTTP",
        },
        config,
        runtime,
    )
    .await;
}

struct DirectPayload<'a> {
    initial: &'a [u8],
    destination: SocketAddr,
    peer: SocketAddr,
    is_media: bool,
    transport: &'static str,
}

async fn bridge_direct_payload(
    mut client: TcpStream,
    payload: DirectPayload<'_>,
    config: Arc<Config>,
    runtime: Arc<Runtime>,
) {
    let host = payload.destination.ip().to_string();
    let timeout = Duration::from_secs(config.tcp_fallback_timeout);
    let connect = runtime
        .outbound()
        .connect(&host, payload.destination.port(), timeout);
    let Some(result) = complete_unless_client_resets(&client, connect).await else {
        debug!(
            "[{}] клиент сбросил соединение во время выбора прямого TCP-маршрута",
            payload.peer
        );
        return;
    };
    match result {
        Ok(mut remote) => {
            if let Err(error) = remote.write_all(payload.initial).await {
                warn!(
                    "[{}] не удалось передать начальные данные по маршруту {} к {}: {}",
                    payload.peer, payload.transport, payload.destination, error
                );
                return;
            }
            match tokio::io::copy_bidirectional(&mut client, &mut remote).await {
                Ok((bytes_up, bytes_down)) => info!(
                    "[{}] маршрут {} к исходному назначению {}{} завершён: вверх {} байт, вниз {} байт",
                    payload.peer,
                    payload.transport,
                    payload.destination,
                    media_tag(payload.is_media),
                    bytes_up + payload.initial.len() as u64,
                    bytes_down
                ),
                Err(error) => debug!(
                    "[{}] поток маршрута {} к {}{} завершился с ошибкой: {}",
                    payload.peer,
                    payload.transport,
                    payload.destination,
                    media_tag(payload.is_media),
                    error
                ),
            }
        }
        Err(error) => warn!(
            "[{}] не удалось открыть маршрут {} к исходному назначению {}: {}",
            payload.peer, payload.transport, payload.destination, error
        ),
    }
}

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

    let handshake_deadline =
        tokio::time::Instant::now() + Duration::from_secs(config.handshake_timeout);
    let first_bytes =
        match tokio::time::timeout_at(handshake_deadline, read_initial_prefix(&mut stream)).await {
            Ok(Ok(prefix)) => prefix,
            Ok(Err(error)) => {
                debug!(
                    "[{}] не удалось прочитать начало MTProto-потока: {}",
                    peer, error
                );
                return;
            }
            Err(_) => {
                debug!("[{}] истекло время ожидания начала MTProto-потока", peer);
                return;
            }
        };

    if destination.port() == 80 && transparent::is_http_request(&first_bytes) {
        let (route, map_source) = match runtime
            .dc_map()
            .resolve_http_for_transparent_with_source(destination.ip())
        {
            Ok(route) => route,
            Err(error) => {
                warn!(
                    "[{}] MTProto HTTP отклонён для {}: адрес не прошёл проверку DC-карты ({})",
                    peer, destination, error
                );
                return;
            }
        };
        if route.tcpo_only {
            warn!(
                "[{}] MTProto HTTP отклонён для {}: dcOption требует транспортную обфускацию",
                peer, destination
            );
            return;
        }
        let initial_request = match tokio::time::timeout_at(
            handshake_deadline,
            read_http_transport_request(&mut stream, first_bytes, destination, route.id),
        )
        .await
        {
            Ok(Ok(request)) => request,
            Ok(Err(reason)) => {
                debug!(
                    "[{}] MTProto HTTP отклонён для {}: {}",
                    peer, destination, reason
                );
                return;
            }
            Err(_) => {
                debug!(
                    "[{}] истекло время ожидания HTTP-заголовка от {}",
                    peer, destination
                );
                return;
            }
        };
        let is_media = route.media_only;
        info!(
            "[{}] MTProto HTTP POST /api: точный DC{}{} из {}, прямой TCP к {}",
            peer,
            route.id,
            media_tag(is_media),
            map_source.as_str(),
            destination
        );
        bridge_direct_http(
            stream,
            initial_request,
            destination,
            peer,
            is_media,
            Arc::clone(&config),
            Arc::clone(&runtime),
        )
        .await;
        return;
    }

    if transparent::is_http_request(&first_bytes) {
        debug!(
            "[{}] HTTP MTProto-транспорт разрешён только на TCP/80, получено назначение {}",
            peer, destination
        );
        return;
    }

    let mut init = [0u8; crate::crypto::HANDSHAKE_LEN];
    init[..INITIAL_PREFIX_LEN].copy_from_slice(&first_bytes);
    match tokio::time::timeout_at(
        handshake_deadline,
        stream.read_exact(&mut init[INITIAL_PREFIX_LEN..]),
    )
    .await
    {
        Ok(Ok(_)) => {}
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
    let (destination_route, map_source) = match runtime
        .dc_map()
        .resolve_for_transparent_with_source(
            destination.ip(),
            destination.port(),
            init_info.is_media,
            init_info.dc,
        ) {
        Ok(route) => route,
        Err(error) if should_forward_unmapped_direct(&error, init_info.dc) => {
            warn!(
                "[{}] адрес {} отсутствует в проверенной DC-карте; WSS relay не выбирается, поток направляется только к тому же исходному IP:port",
                peer, destination
            );
            bridge_direct_tcp(
                stream,
                init,
                destination,
                peer,
                init_info.is_media,
                Arc::clone(&config),
                Arc::clone(&runtime),
            )
            .await;
            return;
        }
        Err(error) => {
            warn!(
                "[{}] прозрачный маршрут отклонён для {}: {} (DC из рукопожатия: {:?}, media: {})",
                peer, destination, error, init_info.dc, init_info.is_media
            );
            return;
        }
    };
    let dc = destination_route.id;
    let is_media = effective_media_route(init_info.is_media, destination_route.media_only);
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
    if destination_route.cdn {
        info!(
            "[{}] официальный CDN DC{} направляется только прямым TCP к исходному назначению {}",
            peer, destination_route.id, destination
        );
        bridge_direct_tcp(
            stream,
            init,
            destination,
            peer,
            effective_media_route(init_info.is_media, destination_route.media_only),
            Arc::clone(&config),
            Arc::clone(&runtime),
        )
        .await;
        return;
    }
    let label = peer;
    let target_ip = destination.ip().to_string();
    let route = routing::Route::new(label, &config, &runtime, dc, is_media);
    let tcp_fallback_timeout = route.tcp_fallback_timeout();
    let tcp_failure_cooldown = route.tcp_fallback_failure_cooldown();
    let Some(upstream) =
        complete_unless_client_resets(&stream, routing::select_upstream(&route, &target_ip))
            .await
            .flatten()
    else {
        return;
    };
    match upstream {
        Upstream::Ws {
            ws,
            framing,
            route_type,
            feedback,
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
                feedback,
            )
            .await;
        }
        Upstream::Tcp(host) => {
            let (fallback_host, fallback_port) =
                transparent::tcp_fallback_target(&host, destination);
            let connect =
                runtime
                    .outbound()
                    .connect(&fallback_host, fallback_port, tcp_fallback_timeout);
            let Some(result) = complete_unless_client_resets(&stream, connect).await else {
                debug!(
                    "[{}] клиент сбросил соединение во время выбора резервного TCP",
                    peer
                );
                return;
            };
            match result {
                Ok(mut remote) => {
                    routing::record_tcp_connect_success(dc, is_media, &target_ip);
                    if let Err(error) = remote.write_all(&init).await {
                        routing::record_tcp_connect_failure(
                            dc,
                            is_media,
                            &target_ip,
                            tcp_failure_cooldown,
                        );
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
                Err(error) => {
                    routing::record_tcp_connect_failure(
                        dc,
                        is_media,
                        &target_ip,
                        tcp_failure_cooldown,
                    );
                    warn!(
                        "[{}] не удалось открыть резервное TCP-соединение с {}: {}; маршрут приостановлен на {} с",
                        peer,
                        host,
                        error,
                        tcp_failure_cooldown.as_secs()
                    );
                }
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{
        bridge_direct_tcp, complete_unless_client_resets, effective_media_route,
        read_initial_prefix, should_forward_unmapped_direct, validate_http_request_head,
    };
    use crate::config::Config;
    use crate::dc_map::{DcEndpoint, DcMapStore, DcSnapshot, RouteLookupError, lookup_endpoint};
    use crate::outbound::OutboundConnector;
    use crate::runtime::Runtime;
    use std::net::IpAddr;
    use std::net::Ipv4Addr;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicBool, Ordering};
    use std::time::Duration;
    use tokio::io::{AsyncReadExt, AsyncWriteExt};
    use tokio::net::{TcpListener, TcpStream};

    #[tokio::test]
    async fn initial_prefix_contains_enough_bytes_to_recognize_http_method() {
        let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
        let address = listener.local_addr().unwrap();
        let mut client = TcpStream::connect(address).await.unwrap();
        client.write_all(b"POST /api HTTP/1.1\r\n").await.unwrap();
        let (mut server, _) = listener.accept().await.unwrap();

        let prefix = read_initial_prefix(&mut server).await.unwrap();

        assert_eq!(&prefix[..8], b"POST /ap");
        assert!(crate::transparent::is_http_request(&prefix));
    }

    #[test]
    fn ordinary_dc_option_preserves_the_clients_media_session_hint() {
        assert!(effective_media_route(true, false));
        assert!(effective_media_route(true, true));
        assert!(!effective_media_route(false, false));
    }

    #[test]
    fn mtproto_http_accepts_only_bounded_post_api_for_the_selected_dc() {
        let destination = "149.154.167.151:80".parse().unwrap();
        let valid =
            b"POST /api HTTP/1.1\r\nHost: venus.web.telegram.org:80\r\nContent-Length: 4\r\n\r\n";
        assert_eq!(
            validate_http_request_head(valid, destination, 2),
            Ok(valid.len()),
            "официальное имя DC2 и полный HTTP-заголовок принимаются"
        );

        let invalid_requests: &[&[u8]] = &[
            b"GET /api HTTP/1.1\r\nHost: 149.154.167.151:80\r\nContent-Length: 4\r\n\r\n",
            b"POST /other HTTP/1.1\r\nHost: 149.154.167.151:80\r\nContent-Length: 4\r\n\r\n",
            b"POST /api HTTP/1.0\r\nHost: 149.154.167.151:80\r\nContent-Length: 4\r\n\r\n",
            b"POST /api HTTP/1.1\r\nHost: 149.154.175.50:80\r\nContent-Length: 4\r\n\r\n",
            b"POST /api HTTP/1.1\r\nHost: 149.154.167.151:80\r\nContent-Length: 0\r\n\r\n",
            b"POST /api HTTP/1.1\r\nHost: 149.154.167.151:80\r\nTransfer-Encoding: chunked\r\nContent-Length: 4\r\n\r\n",
            b"POST /api HTTP/1.1\r\nHost: 149.154.167.151:80\r\nContent-Length: 4\r\nContent-Length: 4\r\n\r\n",
            b"POST /api HTTP/1.1\r\nHost: 149.154.167.151:80\r\nProxy-Authorization: token\r\nContent-Length: 4\r\n\r\n",
        ];
        for request in invalid_requests {
            assert!(
                validate_http_request_head(request, destination, 2).is_err(),
                "недопустимый HTTP-заголовок принят: {}",
                String::from_utf8_lossy(request)
            );
        }

        let oversized = format!(
            "POST /api HTTP/1.1\r\nHost: 149.154.167.151:80\r\nContent-Length: {}\r\n\r\n",
            super::MAX_HTTP_BODY_BYTES + 1
        );
        assert!(validate_http_request_head(oversized.as_bytes(), destination, 2).is_err());
    }

    #[test]
    fn unmapped_tcp_passthrough_does_not_guess_a_dc_or_bypass_other_validation_errors() {
        assert!(should_forward_unmapped_direct(
            &RouteLookupError::AddressNotListed,
            None
        ));
        assert!(!should_forward_unmapped_direct(
            &RouteLookupError::AddressNotListed,
            Some(2)
        ));
        assert!(!should_forward_unmapped_direct(
            &RouteLookupError::MediaFlagMismatch,
            None
        ));
        assert!(!should_forward_unmapped_direct(
            &RouteLookupError::DcMismatch,
            None
        ));
    }

    #[test]
    fn observed_unmapped_addresses_use_exact_direct_fallback_only_without_dc_hint() {
        let store = DcMapStore::without_cache("/tmp/tg-transparent-unmapped-test.json");
        for address in ["149.154.167.43", "91.108.56.137"] {
            let error = store
                .resolve_with_source(address.parse().unwrap(), 443, true, None)
                .unwrap_err();
            assert_eq!(error, RouteLookupError::AddressNotListed, "{address}");
            assert!(should_forward_unmapped_direct(&error, None), "{address}");
            assert!(
                !should_forward_unmapped_direct(&error, Some(2)),
                "DC hint must not let an unknown IP select a WSS route: {address}"
            );
        }
    }

    #[test]
    fn official_regular_dc_option_keeps_media_session_and_media_only_validation() {
        let now = 1_800_000_000;
        let regular = DcEndpoint {
            id: 2,
            address: "149.154.167.151".parse::<IpAddr>().unwrap(),
            port: 443,
            ipv6: false,
            media_only: false,
            tcpo_only: false,
            cdn: false,
            is_static: false,
            this_port_only: false,
            secret: None,
            last_seen: now,
        };
        let snapshot = DcSnapshot {
            schema_version: 1,
            fetched_at: now,
            config_date: now,
            config_expires: now + 86_400,
            this_dc: 2,
            endpoints: vec![regular],
        };
        let route = lookup_endpoint(
            &snapshot,
            "149.154.167.151".parse().unwrap(),
            443,
            true,
            Some(2),
        )
        .unwrap();
        assert!(!route.media_only);
        assert!(effective_media_route(true, route.media_only));

        let mut media_only_snapshot = snapshot;
        media_only_snapshot.endpoints[0].media_only = true;
        assert_eq!(
            lookup_endpoint(
                &media_only_snapshot,
                "149.154.167.151".parse().unwrap(),
                443,
                false,
                Some(2),
            ),
            Err(RouteLookupError::MediaFlagMismatch)
        );
    }

    #[tokio::test]
    async fn unmapped_connection_passes_the_same_destination_and_mtproto_bytes_directly() {
        let target = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let destination = target.local_addr().unwrap();
        let client_listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let mut client = TcpStream::connect(client_listener.local_addr().unwrap())
            .await
            .unwrap();
        let (proxy_side, peer) = client_listener.accept().await.unwrap();
        let config = Arc::new(Config::try_from_cli_line("--tcp-fallback-timeout=1").unwrap());
        let runtime = Arc::new(Runtime::new(OutboundConnector::direct()));
        let init = [0x5a; 64];
        let forward = tokio::spawn(bridge_direct_tcp(
            proxy_side,
            init,
            destination,
            peer,
            true,
            config,
            runtime,
        ));

        client.write_all(b"data").await.unwrap();
        client.shutdown().await.unwrap();
        let (mut upstream, _) = target.accept().await.unwrap();
        let mut received_init = [0; 64];
        upstream.read_exact(&mut received_init).await.unwrap();
        let mut received_payload = [0; 4];
        upstream.read_exact(&mut received_payload).await.unwrap();
        assert_eq!(received_init, init);
        assert_eq!(&received_payload, b"data");
        upstream.write_all(b"resPQ").await.unwrap();
        upstream.shutdown().await.unwrap();

        let mut response = [0; 5];
        client.read_exact(&mut response).await.unwrap();
        assert_eq!(&response, b"resPQ");
        forward.await.unwrap();
    }

    #[tokio::test]
    async fn reset_client_cancels_pending_route_selection() {
        struct DropFlag(Arc<AtomicBool>);
        impl Drop for DropFlag {
            fn drop(&mut self) {
                self.0.store(true, Ordering::SeqCst);
            }
        }

        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let client = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (proxy_side, _) = listener.accept().await.unwrap();
        socket2::SockRef::from(&client)
            .set_linger(Some(Duration::ZERO))
            .unwrap();

        let dropped = Arc::new(AtomicBool::new(false));
        let dropped_for_operation = Arc::clone(&dropped);
        let operation = async move {
            let _drop_flag = DropFlag(dropped_for_operation);
            std::future::pending::<()>().await;
        };
        let task =
            tokio::spawn(
                async move { complete_unless_client_resets(&proxy_side, operation).await },
            );
        drop(client);

        assert_eq!(
            tokio::time::timeout(Duration::from_secs(1), task)
                .await
                .unwrap()
                .unwrap(),
            None
        );
        assert!(dropped.load(Ordering::SeqCst));
    }

    #[tokio::test]
    async fn tcp_half_close_does_not_cancel_pending_route_selection() {
        let listener = TcpListener::bind((Ipv4Addr::LOCALHOST, 0)).await.unwrap();
        let mut client = TcpStream::connect(listener.local_addr().unwrap())
            .await
            .unwrap();
        let (proxy_side, _) = listener.accept().await.unwrap();
        client.shutdown().await.unwrap();

        let result = complete_unless_client_resets(&proxy_side, async {
            tokio::time::sleep(Duration::from_millis(10)).await;
            7
        })
        .await;

        assert_eq!(result, Some(7));
    }
}
