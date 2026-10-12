//! Двунаправленная передача transparent MTProto потока через WSS.

use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, Ordering};

use cipher::StreamCipher;
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::Mutex as AsyncMutex;
use tracing::{info, warn};
use tungstenite::Message;

use crate::crypto::ProtoTag;
use crate::routing::WsFraming;
use crate::splitter::MsgSplitter;
use crate::transparent;
use crate::ws_client::{TgWsStream, media_tag};

const RELAY_BUF_SIZE: usize = 16 * 1024;
#[allow(clippy::too_many_arguments)]
pub(crate) async fn bridge_transparent_ws(
    stream: TcpStream,
    ws: TgWsStream,
    init: [u8; crate::crypto::HANDSHAKE_LEN],
    label: SocketAddr,
    destination: SocketAddr,
    dc: u32,
    is_media: bool,
    proto: ProtoTag,
    framing: WsFraming,
    route_type: &'static str,
) {
    info!(
        "[{}] прозрачный маршрут: {} → DC{}{} через {} (кадрирование: {})",
        label,
        destination,
        dc,
        media_tag(is_media),
        route_type,
        framing.as_str()
    );
    let (mut client_read, mut client_write) = stream.into_split();
    let (ws_write, mut ws_read) = ws.split();
    let ws_write = Arc::new(AsyncMutex::new(ws_write));
    let bytes_up = Arc::new(AtomicU64::new(0));
    let bytes_down = Arc::new(AtomicU64::new(0));

    let mut upload = tokio::spawn({
        let ws_write = Arc::clone(&ws_write);
        let bytes_up = Arc::clone(&bytes_up);
        async move {
            if ws_write
                .lock()
                .await
                .send(Message::Binary(init.to_vec()))
                .await
                .is_err()
            {
                return "не удалось отправить init по WSS".to_string();
            }
            bytes_up.fetch_add(init.len() as u64, Ordering::Relaxed);

            let (mut decrypt, mut encrypt) = transparent::direct_stream_ciphers(&init);
            let mut splitter = (framing == WsFraming::Packets).then(|| MsgSplitter::new(proto));
            let mut buffer = vec![0u8; RELAY_BUF_SIZE];
            let close_reason = loop {
                let length = match client_read.read(&mut buffer).await {
                    Ok(0) => break "клиент закрыл TCP".to_string(),
                    Err(error) => break format!("ошибка чтения TCP клиента: {error}"),
                    Ok(length) => length,
                };

                if let Some(splitter) = splitter.as_mut() {
                    decrypt.apply_keystream(&mut buffer[..length]);
                    for frame in splitter.split_and_encrypt(&mut buffer[..length], &mut encrypt) {
                        let frame_len = frame.len() as u64;
                        if let Err(error) = ws_write.lock().await.send(Message::Binary(frame)).await
                        {
                            return format!("ошибка отправки кадра WSS: {error}");
                        }
                        bytes_up.fetch_add(frame_len, Ordering::Relaxed);
                    }
                } else {
                    if let Err(error) = ws_write
                        .lock()
                        .await
                        .send(Message::Binary(buffer[..length].to_vec()))
                        .await
                    {
                        return format!("ошибка отправки потока WSS: {error}");
                    }
                    bytes_up.fetch_add(length as u64, Ordering::Relaxed);
                }
            };

            if let Some(splitter) = splitter.as_mut() {
                let pending = splitter.pending_len();
                if pending > 0 {
                    warn!(
                        "[{}] ошибка кадрирования MTProto: при закрытии осталось {} байт неполного пакета",
                        label, pending
                    );
                }
                for frame in splitter.flush() {
                    let frame_len = frame.len() as u64;
                    if let Err(error) = ws_write.lock().await.send(Message::Binary(frame)).await {
                        return format!("ошибка отправки неполного кадра WSS: {error}");
                    }
                    bytes_up.fetch_add(frame_len, Ordering::Relaxed);
                }
            }

            match ws_write.lock().await.close().await {
                Ok(()) => close_reason,
                Err(error) => format!("{close_reason}; ошибка закрытия WSS: {error}"),
            }
        }
    });

    let mut download = tokio::spawn({
        let ws_write = Arc::clone(&ws_write);
        let bytes_down = Arc::clone(&bytes_down);
        async move {
            while let Some(message) = ws_read.next().await {
                match message {
                    Ok(Message::Binary(data)) => {
                        let length = data.len() as u64;
                        if let Err(error) = client_write.write_all(&data).await {
                            return format!("ошибка записи в TCP клиента: {error}");
                        }
                        bytes_down.fetch_add(length, Ordering::Relaxed);
                    }
                    Ok(Message::Text(data)) => {
                        let length = data.len() as u64;
                        if let Err(error) = client_write.write_all(data.as_bytes()).await {
                            return format!("ошибка записи текста WSS в TCP клиента: {error}");
                        }
                        bytes_down.fetch_add(length, Ordering::Relaxed);
                    }
                    Ok(Message::Ping(data)) => {
                        if let Err(error) = ws_write.lock().await.send(Message::Pong(data)).await {
                            return format!("ошибка ответа на WSS ping: {error}");
                        }
                    }
                    Ok(Message::Pong(_)) => {}
                    Ok(Message::Close(frame)) => {
                        return match frame {
                            Some(frame) => format!(
                                "upstream закрыл WSS: код={:?}, причина={}",
                                frame.code, frame.reason
                            ),
                            None => "upstream закрыл WSS без кода".to_string(),
                        };
                    }
                    Err(error) => return format!("ошибка чтения WSS: {error}"),
                    _ => return "upstream прислал неподдерживаемый кадр WSS".to_string(),
                }
            }
            let _ = client_write.shutdown().await;
            "upstream завершил поток WSS".to_string()
        }
    });

    let (closed_by, reason) = tokio::select! {
        result = &mut upload => {
            download.abort();
            ("клиент", result.unwrap_or_else(|error| format!("задача отправки завершилась: {error}")))
        }
        result = &mut download => {
            upload.abort();
            ("upstream", result.unwrap_or_else(|error| format!("задача получения завершилась: {error}")))
        }
    };
    info!(
        "[{}] сессия DC{}{} через {} закрыта стороной {}: причина={}, вверх {} байт, вниз {} байт",
        label,
        dc,
        media_tag(is_media),
        route_type,
        closed_by,
        reason,
        bytes_up.load(Ordering::Relaxed),
        bytes_down.load(Ordering::Relaxed)
    );
}
