use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use cipher::StreamCipher;
use futures_util::{SinkExt, StreamExt};
use grammers_crypto::DequeBuffer;
use grammers_mtproto::authentication;
use grammers_mtproto::mtp::{Deserialization, Encrypted, Mtp, Plain};
use grammers_mtproto::transport::{Error as TransportError, Intermediate, Obfuscated, Transport};
use grammers_tl_types::{Deserializable, RemoteCall, Serializable};
use tokio::io::{AsyncRead, AsyncReadExt, AsyncWrite, AsyncWriteExt, DuplexStream};
use tokio::sync::Mutex;
use tracing::{info, warn};
use tungstenite::Message;

use crate::config::default_dc_bootstrap_ips;
use crate::crypto::ProtoTag;
use crate::dc_map::{DcEndpoint, DcSnapshot, write_endpoint_manifest};
use crate::runtime::Runtime;
use crate::splitter::MsgSplitter;
use crate::transparent::direct_stream_ciphers;
use crate::ws_client::{CfDialOpts, TgWsStream, connect_cf_ws_for_dc_with_outbound_opts};

const TELEGRAM_TCP_PORT: u16 = 443;
const CONNECT_TIMEOUT: Duration = Duration::from_secs(6);
const EXCHANGE_TIMEOUT: Duration = Duration::from_secs(12);
const MAX_PACKET_BYTES: usize = 1024 * 1024;
const MAX_BOOTSTRAP_ATTEMPTS: usize = 3;
const MIN_REFRESH_SECS: u64 = 60 * 60;
const MAX_REFRESH_SECS: u64 = 7 * 24 * 60 * 60;
// Идентификатор официального Telegram Android; для help.getConfig api_hash и вход в аккаунт не нужны.
const TELEGRAM_CONFIG_API_ID: i32 = 4;

type TelegramTransport = Obfuscated<Intermediate>;

/// Получить `help.getConfig` на одном из проверенных встроенных DC без входа пользователя.
pub async fn fetch_config(runtime: &Runtime, cf_domains: &[String]) -> Result<DcSnapshot, String> {
    let mut failures = Vec::new();
    let bootstrap = default_dc_bootstrap_ips();
    for (dc, address) in bootstrap.iter().take(MAX_BOOTSTRAP_ATTEMPTS) {
        match fetch_from_dc(runtime, address).await {
            Ok(snapshot) => return Ok(snapshot),
            Err(error) => failures.push(format!("DC{dc} {address}: {error}")),
        }
    }

    let mut tried_dcs = Vec::new();
    for dc in bootstrap.iter().map(|(dc, _)| *dc) {
        if tried_dcs.contains(&dc) {
            continue;
        }
        tried_dcs.push(dc);
        match fetch_from_cf_dc(runtime, dc, cf_domains).await {
            Ok(snapshot) => return Ok(snapshot),
            Err(error) => failures.push(format!("DC{dc} через WSS: {error}")),
        }
    }

    Err(format!(
        "не удалось получить конфигурацию ни с одного bootstrap DC: {}",
        failures.join("; ")
    ))
}

async fn fetch_from_dc(runtime: &Runtime, address: &str) -> Result<DcSnapshot, String> {
    let mut stream = runtime
        .outbound()
        .connect(address, TELEGRAM_TCP_PORT, CONNECT_TIMEOUT)
        .await
        .map_err(|error| format!("TCP-соединение: {error}"))?;
    stream
        .set_nodelay(true)
        .map_err(|error| format!("TCP_NODELAY: {error}"))?;

    fetch_over_stream(&mut stream).await
}

async fn fetch_from_cf_dc(
    runtime: &Runtime,
    dc: u32,
    cf_domains: &[String],
) -> Result<DcSnapshot, String> {
    if cf_domains.is_empty() {
        return Err("домены Cloudflare для WSS не настроены".to_string());
    }

    let (ws, domain, _) = connect_cf_ws_for_dc_with_outbound_opts(
        dc,
        cf_domains,
        false,
        CONNECT_TIMEOUT,
        runtime.outbound(),
        CfDialOpts {
            cf_ips: runtime.cf_ips(),
            fail_cooldown: runtime.cf_fail_cooldown(),
        },
    )
    .await;
    let ws = ws.ok_or_else(|| "Cloudflare WSS-соединение не установлено".to_string())?;
    info!(
        "Получение help.getConfig через проверенный WSS-маршрут DC{} ({})",
        dc,
        domain.as_deref().unwrap_or("домен неизвестен")
    );

    let mut stream = start_ws_byte_stream(ws);
    fetch_over_stream(&mut stream).await
}

fn start_ws_byte_stream(ws: TgWsStream) -> DuplexStream {
    let (client, relay) = tokio::io::duplex(64 * 1024);
    tokio::spawn(bridge_ws_byte_stream(relay, ws));
    client
}

async fn bridge_ws_byte_stream(stream: DuplexStream, ws: TgWsStream) {
    let (mut reader, mut writer) = tokio::io::split(stream);
    let (sink, mut source) = ws.split();
    let sink = Arc::new(Mutex::new(sink));

    let upload_sink = Arc::clone(&sink);
    let mut upload = tokio::spawn(async move {
        let mut init = [0u8; crate::crypto::HANDSHAKE_LEN];
        reader
            .read_exact(&mut init)
            .await
            .map_err(|error| format!("не удалось прочитать obfuscated2 bootstrap: {error}"))?;
        upload_sink
            .lock()
            .await
            .send(Message::Binary(init.to_vec()))
            .await
            .map_err(|error| format!("не удалось передать bootstrap по WSS: {error}"))?;

        let (mut decrypt, mut encrypt) = direct_stream_ciphers(&init);
        let mut splitter = MsgSplitter::new(ProtoTag::Intermediate);
        let mut buffer = vec![0u8; 16 * 1024];
        loop {
            let length = reader
                .read(&mut buffer)
                .await
                .map_err(|error| format!("ошибка чтения bootstrap-запроса: {error}"))?;
            if length == 0 {
                break;
            }
            decrypt.apply_keystream(&mut buffer[..length]);
            for packet in splitter.split_and_encrypt(&mut buffer[..length], &mut encrypt) {
                upload_sink
                    .lock()
                    .await
                    .send(Message::Binary(packet))
                    .await
                    .map_err(|error| {
                        format!("не удалось передать пакет help.getConfig по WSS: {error}")
                    })?;
            }
        }
        for packet in splitter.flush() {
            upload_sink
                .lock()
                .await
                .send(Message::Binary(packet))
                .await
                .map_err(|error| format!("не удалось передать остаток пакета по WSS: {error}"))?;
        }
        upload_sink
            .lock()
            .await
            .close()
            .await
            .map_err(|error| format!("не удалось закрыть исходящий WSS-поток: {error}"))?;
        Ok::<(), String>(())
    });

    let download_sink = Arc::clone(&sink);
    let mut download: tokio::task::JoinHandle<Result<(), String>> = tokio::spawn(async move {
        loop {
            let message = source
                .next()
                .await
                .ok_or_else(|| "Cloudflare закрыл WSS-поток".to_string())?
                .map_err(|error| format!("ошибка чтения ответа WSS: {error}"))?;
            match message {
                Message::Binary(data) if data.len() <= MAX_PACKET_BYTES => writer
                    .write_all(&data)
                    .await
                    .map_err(|error| format!("не удалось передать ответ WSS в MTProto: {error}"))?,
                Message::Binary(_) => return Err("пакет ответа WSS превышает 1 MiB".to_string()),
                Message::Text(data) => writer
                    .write_all(data.as_bytes())
                    .await
                    .map_err(|error| format!("не удалось передать текстовый ответ WSS: {error}"))?,
                Message::Ping(data) => {
                    download_sink
                        .lock()
                        .await
                        .send(Message::Pong(data))
                        .await
                        .map_err(|error| format!("не удалось ответить на WSS ping: {error}"))?
                }
                Message::Pong(_) => {}
                Message::Close(_) => return Err("Telegram закрыл WSS-поток".to_string()),
                _ => return Err("WSS прислал неподдерживаемый тип кадра".to_string()),
            }
        }
    });

    tokio::select! {
        result = &mut upload => {
            if let Err(error) = result.unwrap_or_else(|error| Err(error.to_string())) {
                warn!("Ошибка отправки bootstrap через WSS: {error}");
            }
            download.abort();
        }
        result = &mut download => {
            if let Err(error) = result.unwrap_or_else(|error| Err(error.to_string())) {
                warn!("Ошибка получения bootstrap через WSS: {error}");
            }
            upload.abort();
        }
    }
}

async fn fetch_over_stream<S>(stream: &mut S) -> Result<DcSnapshot, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
{
    let mut transport = Obfuscated::new(Intermediate::new());
    let mut wire = Vec::with_capacity(16 * 1024);

    let (request, state) =
        authentication::step1().map_err(|error| format!("начало авторизации MTProto: {error}"))?;
    let response = exchange_plain(stream, &mut transport, &mut wire, &request)
        .await
        .map_err(|error| format!("этап req_pq_multi: {error}"))?;
    let response = grammers_tl_types::enums::ResPq::from_bytes(&response)
        .map_err(|error| format!("разбор resPQ: {error}"))?;

    let (request, state) = authentication::step2(state, response)
        .map_err(|error| format!("обработка resPQ: {error}"))?;
    let response = exchange_plain(stream, &mut transport, &mut wire, &request)
        .await
        .map_err(|error| format!("этап req_DH_params: {error}"))?;
    let response = grammers_tl_types::enums::ServerDhParams::from_bytes(&response)
        .map_err(|error| format!("разбор server_DH_params: {error}"))?;

    let (request, state) = authentication::step3(state, response)
        .map_err(|error| format!("обработка server_DH_params: {error}"))?;
    let response = exchange_plain(stream, &mut transport, &mut wire, &request)
        .await
        .map_err(|error| format!("этап set_client_DH_params: {error}"))?;
    let response = grammers_tl_types::enums::SetClientDhParamsAnswer::from_bytes(&response)
        .map_err(|error| format!("разбор set_client_DH_params_answer: {error}"))?;

    let auth = authentication::create_key(state, response)
        .map_err(|error| format!("завершение авторизации MTProto: {error}"))?;
    let mut encrypted = Encrypted::build()
        .time_offset(auth.time_offset)
        .first_salt(auth.first_salt)
        .finish(auth.auth_key);
    let request = config_request();
    let response = exchange_encrypted(stream, &mut transport, &mut wire, &mut encrypted, &request)
        .await
        .map_err(|error| format!("этап help.getConfig: {error}"))?;
    let response = grammers_tl_types::enums::Config::from_bytes(&response)
        .map_err(|error| format!("разбор help.getConfig: {error}"))?;
    let grammers_tl_types::enums::Config::Config(config) = response;
    config_to_snapshot(config)
}

fn config_request() -> grammers_tl_types::functions::InvokeWithLayer<
    grammers_tl_types::functions::InitConnection<grammers_tl_types::functions::help::GetConfig>,
> {
    grammers_tl_types::functions::InvokeWithLayer {
        layer: grammers_tl_types::LAYER,
        query: grammers_tl_types::functions::InitConnection {
            api_id: TELEGRAM_CONFIG_API_ID,
            device_model: "OpenWrt".to_string(),
            system_version: "OpenWrt".to_string(),
            app_version: env!("CARGO_PKG_VERSION").to_string(),
            system_lang_code: "ru".to_string(),
            lang_pack: String::new(),
            lang_code: "ru".to_string(),
            proxy: None,
            params: None,
            query: grammers_tl_types::functions::help::GetConfig {},
        },
    }
}

async fn exchange_plain<S, R>(
    stream: &mut S,
    transport: &mut TelegramTransport,
    wire: &mut Vec<u8>,
    request: &R,
) -> Result<Vec<u8>, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
    R: Serializable,
{
    let mut mtp = Plain::new();
    exchange(stream, transport, wire, &mut mtp, request).await
}

async fn exchange_encrypted<S, R>(
    stream: &mut S,
    transport: &mut TelegramTransport,
    wire: &mut Vec<u8>,
    mtp: &mut Encrypted,
    request: &R,
) -> Result<Vec<u8>, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
    R: RemoteCall,
{
    exchange(stream, transport, wire, mtp, request).await
}

async fn exchange<S, M, R>(
    stream: &mut S,
    transport: &mut TelegramTransport,
    wire: &mut Vec<u8>,
    mtp: &mut M,
    request: &R,
) -> Result<Vec<u8>, String>
where
    S: AsyncRead + AsyncWrite + Unpin,
    M: Mtp,
    R: Serializable,
{
    let request = request.to_bytes();
    let deadline = tokio::time::Instant::now() + EXCHANGE_TIMEOUT;
    loop {
        let mut packet = DequeBuffer::with_capacity(request.len() + 64, 0);
        let request_queued = mtp.push(&mut packet, &request).is_some();
        let packet_finalized = mtp.finalize(&mut packet).is_some();
        if request_queued && !packet_finalized {
            return Err("MTProto не сформировал исходящий пакет".to_string());
        }
        if !packet.is_empty() {
            transport.pack(&mut packet);
            tokio::time::timeout_at(deadline, stream.write_all(packet.as_ref()))
                .await
                .map_err(|_| "истекло время передачи запроса Telegram".to_string())?
                .map_err(|error| format!("передача запроса Telegram: {error}"))?;
        }

        loop {
            let payload =
                tokio::time::timeout_at(deadline, read_transport_packet(stream, transport, wire))
                    .await
                    .map_err(|_| "истекло время ожидания ответа Telegram".to_string())??;
            let mut payload = payload;
            let responses = mtp
                .deserialize(&mut payload)
                .map_err(|error| format!("разбор пакета MTProto: {error}"))?;
            for response in responses {
                match response {
                    Deserialization::RpcResult(result) => return Ok(result.body),
                    Deserialization::RpcError(result) => {
                        return Err(format!(
                            "Telegram вернул RPC-ошибку {}: {}",
                            result.error.error_code, result.error.error_message
                        ));
                    }
                    Deserialization::Failure(failure) => {
                        return Err(format!("ответ MTProto не прошёл разбор: {}", failure.error));
                    }
                    Deserialization::BadMessage(message) => {
                        return Err(format!(
                            "Telegram отклонил сообщение MTProto, код {}",
                            message.code
                        ));
                    }
                    Deserialization::Update(_) | Deserialization::OwnUpdate { .. } => {}
                }
            }
            if !request_queued {
                break;
            }
        }
    }
}

async fn read_transport_packet<S>(
    stream: &mut S,
    transport: &mut TelegramTransport,
    wire: &mut Vec<u8>,
) -> Result<Vec<u8>, String>
where
    S: AsyncRead + Unpin,
{
    let mut read_buffer = [0u8; 16 * 1024];
    loop {
        if !wire.is_empty() {
            match transport.unpack(wire) {
                Ok(offset) => {
                    let payload = wire[offset.data_range].to_vec();
                    wire.drain(..offset.next_offset);
                    return Ok(payload);
                }
                Err(TransportError::MissingBytes) => {}
                Err(error) => return Err(format!("кадрирование MTProto: {error}")),
            }
        }
        if wire.len() >= MAX_PACKET_BYTES {
            return Err("пакет Telegram превысил допустимый размер".to_string());
        }
        let read_limit = read_buffer.len().min(MAX_PACKET_BYTES - wire.len());
        let read = stream
            .read(&mut read_buffer[..read_limit])
            .await
            .map_err(|error| format!("чтение ответа Telegram: {error}"))?;
        if read == 0 {
            return Err("Telegram закрыл соединение во время запроса конфигурации".to_string());
        }
        wire.extend_from_slice(&read_buffer[..read]);
    }
}

fn config_to_snapshot(config: grammers_tl_types::types::Config) -> Result<DcSnapshot, String> {
    let now = unix_time();
    let mut endpoints = Vec::with_capacity(config.dc_options.len());
    for option in config.dc_options {
        let grammers_tl_types::enums::DcOption::Option(option) = option;
        let id = u32::try_from(option.id)
            .map_err(|_| format!("dcOption содержит недопустимый DC ID {}", option.id))?;
        let address: IpAddr = option
            .ip_address
            .parse()
            .map_err(|_| format!("dcOption DC{id} содержит неверный IP-адрес"))?;
        let port = u16::try_from(option.port)
            .map_err(|_| format!("dcOption DC{id} содержит неверный TCP-порт"))?;
        endpoints.push(DcEndpoint {
            id,
            address,
            port,
            ipv6: option.ipv6,
            media_only: option.media_only,
            tcpo_only: option.tcpo_only,
            cdn: option.cdn,
            is_static: option.r#static,
            this_port_only: option.this_port_only,
            secret: option.secret.map(hex::encode),
            last_seen: now,
        });
    }
    Ok(DcSnapshot {
        schema_version: 1,
        fetched_at: now,
        config_date: i64::from(config.date),
        config_expires: i64::from(config.expires),
        this_dc: u32::try_from(config.this_dc)
            .map_err(|_| "help.getConfig вернул неверный текущий DC".to_string())?,
        endpoints,
    })
}

/// Загружать официальную карту не чаще заданного интервала и не терять кэш при ошибке сети.
pub async fn refresh_loop(
    runtime: Arc<Runtime>,
    requested_interval: u64,
    endpoint_pairs_path: PathBuf,
    transparent_ports: Vec<u16>,
    cf_domains: Vec<String>,
) {
    let interval = requested_interval.clamp(MIN_REFRESH_SECS, MAX_REFRESH_SECS);
    let store = Arc::clone(runtime.dc_map());
    if !transparent_ports.is_empty()
        && let Some(snapshot) = store.current()
    {
        match write_endpoint_manifest(&endpoint_pairs_path, &snapshot, &transparent_ports) {
            Ok(count) => info!(
                "В nft подготовлены пары из последнего проверенного кэша Telegram DC: {count}"
            ),
            Err(error) => warn!(
                "Не удалось обновить файл пар Telegram DC из кэша; сохранено предыдущее состояние: {error}"
            ),
        }
    }
    loop {
        if store.refresh_due(unix_time(), interval) {
            match fetch_config(&runtime, &cf_domains).await {
                Ok(snapshot) => match store.install(snapshot, unix_time()) {
                    Ok(installed) => {
                        info!(
                            "Официальная карта Telegram DC обновлена: {} адресов, конфигурация от {}, кэш проверен и сохранён атомарно",
                            installed.endpoints.len(),
                            installed.config_date
                        );
                        if !transparent_ports.is_empty() {
                            match write_endpoint_manifest(
                                &endpoint_pairs_path,
                                &installed,
                                &transparent_ports,
                            ) {
                                Ok(count) => info!(
                                    "Для OpenWrt атомарно сохранены проверенные пары Telegram IP+порт: {count}"
                                ),
                                Err(error) => warn!(
                                    "Обновлена карта DC, но не её nft-пары; прошлый файл сохранён, listener продолжает работу: {error}"
                                ),
                            }
                        }
                    }
                    Err(error) => {
                        warn!("Не удалось сохранить официальную карту Telegram DC: {error}");
                        tokio::time::sleep(Duration::from_secs(MIN_REFRESH_SECS)).await;
                        continue;
                    }
                },
                Err(error) => {
                    warn!(
                        "Не удалось обновить карту Telegram DC; используются кэш и встроенная резервная карта: {error}"
                    );
                    tokio::time::sleep(Duration::from_secs(MIN_REFRESH_SECS)).await;
                    continue;
                }
            }
        }
        tokio::time::sleep(Duration::from_secs(interval)).await;
    }
}

fn unix_time() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs().min(i64::MAX as u64) as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::{TELEGRAM_CONFIG_API_ID, config_request, config_to_snapshot, exchange_encrypted};
    use grammers_mtproto::mtp::Encrypted;
    use grammers_mtproto::transport::{Intermediate, Obfuscated};
    use grammers_tl_types::{self as tl, Serializable};
    use tokio::io::AsyncReadExt;

    #[test]
    fn converts_all_official_dc_option_flags_without_merging_cdn_and_media() {
        let option = tl::types::DcOption {
            ipv6: true,
            media_only: true,
            tcpo_only: true,
            cdn: false,
            r#static: true,
            this_port_only: true,
            id: 2,
            ip_address: "2001:db8::2".to_string(),
            port: 5222,
            secret: Some(vec![0xaa, 0xbb]),
        };
        let config = test_config(vec![option.into()]);
        let snapshot = config_to_snapshot(config).unwrap();
        let endpoint = &snapshot.endpoints[0];
        assert_eq!(endpoint.id, 2);
        assert!(endpoint.ipv6);
        assert!(endpoint.media_only);
        assert!(endpoint.tcpo_only);
        assert!(!endpoint.cdn);
        assert!(endpoint.is_static);
        assert!(endpoint.this_port_only);
        assert_eq!(endpoint.port, 5222);
        assert_eq!(endpoint.secret.as_deref(), Some("aabb"));
    }

    #[test]
    fn rejects_invalid_official_address_instead_of_guessing_a_dc() {
        let option = tl::types::DcOption {
            ipv6: false,
            media_only: false,
            tcpo_only: false,
            cdn: false,
            r#static: false,
            this_port_only: false,
            id: 2,
            ip_address: "not-an-ip".to_string(),
            port: 443,
            secret: None,
        };
        assert!(config_to_snapshot(test_config(vec![option.into()])).is_err());
    }

    #[test]
    fn config_request_initializes_api_layer_without_user_auth() {
        let request = config_request();

        assert_eq!(request.layer, tl::LAYER);
        assert_eq!(request.query.api_id, TELEGRAM_CONFIG_API_ID);
        assert_eq!(request.query.device_model, "OpenWrt");
        assert_eq!(request.query.system_version, "OpenWrt");
        assert_eq!(request.query.app_version, env!("CARGO_PKG_VERSION"));
        assert_eq!(request.query.system_lang_code, "ru");
        assert_eq!(request.query.lang_code, "ru");
        assert!(request.query.proxy.is_none());
        assert!(request.query.params.is_none());
        assert_eq!(
            request.query.query.to_bytes(),
            tl::functions::help::GetConfig {}.to_bytes()
        );
    }

    #[tokio::test]
    async fn encrypted_exchange_sends_internal_request_when_push_returns_none() {
        let (mut client, mut peer) = tokio::io::duplex(16 * 1024);
        let peer_task = tokio::spawn(async move {
            let mut bytes = vec![0; 16 * 1024];
            let length = peer.read(&mut bytes).await.unwrap();
            bytes.truncate(length);
            bytes
        });
        let mut transport = Obfuscated::new(Intermediate::new());
        let mut wire = Vec::new();
        let mut encrypted = Encrypted::build()
            .time_offset(0)
            .first_salt(1)
            .finish([0; 256]);

        let result = exchange_encrypted(
            &mut client,
            &mut transport,
            &mut wire,
            &mut encrypted,
            &tl::functions::help::GetConfig {},
        )
        .await;
        drop(client);
        let sent = peer_task.await.unwrap();

        assert!(sent.len() > crate::crypto::HANDSHAKE_LEN);
        assert!(
            !result
                .unwrap_err()
                .contains("MTProto не принял запрос в исходящий пакет")
        );
    }

    fn test_config(dc_options: Vec<tl::enums::DcOption>) -> tl::types::Config {
        tl::types::Config {
            default_p2p_contacts: false,
            preload_featured_stickers: false,
            revoke_pm_inbox: false,
            blocked_mode: false,
            force_try_ipv6: false,
            date: 1_797_000_000,
            expires: 1_797_086_400,
            test_mode: false,
            this_dc: 2,
            dc_options,
            dc_txt_domain_name: String::new(),
            chat_size_max: 0,
            megagroup_size_max: 0,
            forwarded_count_max: 0,
            online_update_period_ms: 0,
            offline_blur_timeout_ms: 0,
            offline_idle_timeout_ms: 0,
            online_cloud_timeout_ms: 0,
            notify_cloud_delay_ms: 0,
            notify_default_delay_ms: 0,
            push_chat_period_ms: 0,
            push_chat_limit: 0,
            edit_time_limit: 0,
            revoke_time_limit: 0,
            revoke_pm_time_limit: 0,
            rating_e_decay: 0,
            stickers_recent_limit: 0,
            channels_read_media_period: 0,
            tmp_sessions: None,
            call_receive_timeout_ms: 0,
            call_ring_timeout_ms: 0,
            call_connect_timeout_ms: 0,
            call_packet_timeout_ms: 0,
            me_url_prefix: String::new(),
            autoupdate_url_prefix: None,
            gif_search_username: None,
            venue_search_username: None,
            img_search_username: None,
            static_maps_provider: None,
            caption_length_max: 0,
            message_length_max: 0,
            webfile_dc_id: 2,
            suggested_lang_code: None,
            lang_pack_version: None,
            base_lang_pack_version: None,
            reactions_default: None,
            autologin_token: None,
        }
    }
}
