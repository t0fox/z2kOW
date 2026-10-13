//! Двунаправленная передача transparent MTProto потока через WSS.

use std::future::Future;
use std::net::SocketAddr;
use std::sync::Arc;
use std::sync::atomic::{AtomicU64, AtomicUsize, Ordering};
use std::time::Duration;

use cipher::StreamCipher;
use futures_util::{SinkExt, StreamExt};
use tokio::io::{AsyncReadExt, AsyncWriteExt};
use tokio::net::TcpStream;
use tokio::sync::Mutex as AsyncMutex;
use tracing::{info, warn};
use tungstenite::Message;

use crate::crypto::ProtoTag;
use crate::routing::{RouteFeedback, WsFraming};
use crate::splitter::MsgSplitter;
use crate::transparent;
use crate::ws_client::{TgWsStream, media_tag};

const RELAY_BUF_SIZE: usize = 16 * 1024;
const RELAY_DRAIN_TIMEOUT: Duration = Duration::from_secs(2);
const SESSION_IDLE_TIMEOUT: Duration = Duration::from_secs(600);

enum MtprotoResponseState {
    NotSent,
    Awaiting(tokio::time::Instant),
    Confirmed,
    Failed,
}

async fn send_application_frame<S>(
    ws_write: &Arc<AsyncMutex<S>>,
    response_state: &Arc<AsyncMutex<MtprotoResponseState>>,
    feedback: &RouteFeedback,
    frame: Vec<u8>,
) -> Result<(), String>
where
    S: futures_util::Sink<Message> + Unpin + Send,
    S::Error: std::fmt::Display,
{
    let mut state = response_state.lock().await;
    let first_application_frame = matches!(&*state, MtprotoResponseState::NotSent);
    if first_application_frame {
        *state = MtprotoResponseState::Awaiting(tokio::time::Instant::now());
    }

    if first_application_frame {
        match ws_write.lock().await.send(Message::Binary(frame)).await {
            Ok(()) => Ok(()),
            Err(error) => {
                *state = MtprotoResponseState::Failed;
                crate::routing::record_mtproto_failure(feedback);
                Err(format!("ошибка отправки кадра WSS: {error}"))
            }
        }
    } else {
        drop(state);
        match ws_write.lock().await.send(Message::Binary(frame)).await {
            Ok(()) => Ok(()),
            Err(error) => {
                record_mtproto_failure_if_pending(response_state, feedback).await;
                Err(format!("ошибка отправки кадра WSS: {error}"))
            }
        }
    }
}

async fn record_first_mtproto_response(
    response_state: &Arc<AsyncMutex<MtprotoResponseState>>,
) -> Option<Duration> {
    let mut state = response_state.lock().await;
    if let MtprotoResponseState::Awaiting(started) = &*state {
        let latency = started.elapsed();
        *state = MtprotoResponseState::Confirmed;
        Some(latency)
    } else {
        None
    }
}

async fn record_mtproto_failure_if_pending(
    response_state: &Arc<AsyncMutex<MtprotoResponseState>>,
    feedback: &RouteFeedback,
) {
    let mut state = response_state.lock().await;
    if matches!(&*state, MtprotoResponseState::Awaiting(_)) {
        *state = MtprotoResponseState::Failed;
        crate::routing::record_mtproto_failure(feedback);
    }
}

#[derive(Clone)]
struct PayloadActivity {
    started: tokio::time::Instant,
    last_payload_ms: Arc<AtomicUsize>,
}

impl PayloadActivity {
    fn new() -> Self {
        Self {
            started: tokio::time::Instant::now(),
            last_payload_ms: Arc::new(AtomicUsize::new(0)),
        }
    }

    fn touch(&self) {
        self.last_payload_ms.store(
            self.started.elapsed().as_millis() as usize,
            Ordering::Relaxed,
        );
    }

    async fn idle_reached(&self, idle_timeout: Duration) {
        let idle_ms = idle_timeout.as_millis().min(usize::MAX as u128) as usize;
        loop {
            let elapsed_ms = self.started.elapsed().as_millis() as usize;
            let last_payload_ms = self.last_payload_ms.load(Ordering::Relaxed);
            let idle_for_ms = elapsed_ms.saturating_sub(last_payload_ms);
            if idle_for_ms >= idle_ms {
                return;
            }

            let remaining_ms = (idle_ms - idle_for_ms).clamp(1, 1_000) as u64;
            tokio::time::sleep(Duration::from_millis(remaining_ms)).await;
        }
    }
}

enum RelayDirection<T> {
    Upload(T),
    Download(T),
}

enum RelayCompletion<T> {
    Ended {
        direction: RelayDirection<T>,
        drained: bool,
    },
    Idle,
}

async fn race_directions<U, D>(
    upload: U,
    download: D,
    drain_timeout: Duration,
) -> (RelayDirection<U::Output>, bool)
where
    U: Future<Output = D::Output>,
    D: Future,
{
    tokio::pin!(upload);
    tokio::pin!(download);

    tokio::select! {
        result = &mut upload => {
            let drained = tokio::time::timeout(drain_timeout, &mut download).await.is_ok();
            (RelayDirection::Upload(result), drained)
        },
        result = &mut download => {
            let drained = tokio::time::timeout(drain_timeout, &mut upload).await.is_ok();
            (RelayDirection::Download(result), drained)
        },
    }
}

async fn supervise_directions<U, D>(
    upload: U,
    download: D,
    activity: &PayloadActivity,
    idle_timeout: Duration,
    drain_timeout: Duration,
) -> RelayCompletion<U::Output>
where
    U: Future<Output = D::Output>,
    D: Future,
{
    tokio::select! {
        ended = race_directions(upload, download, drain_timeout) => {
            RelayCompletion::Ended {
                direction: ended.0,
                drained: ended.1,
            }
        },
        _ = activity.idle_reached(idle_timeout) => RelayCompletion::Idle,
    }
}

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
    feedback: RouteFeedback,
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
    let activity = PayloadActivity::new();
    let response_state = Arc::new(AsyncMutex::new(MtprotoResponseState::NotSent));

    let upload = {
        let ws_write = Arc::clone(&ws_write);
        let bytes_up = Arc::clone(&bytes_up);
        let activity = activity.clone();
        let response_state = Arc::clone(&response_state);
        let feedback = feedback.clone();
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
            activity.touch();

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
                    let frames = splitter.split_and_encrypt(&mut buffer[..length], &mut encrypt);
                    if let Some(error) = splitter.error() {
                        return format!("ошибка кадрирования MTProto: {error}");
                    }
                    for frame in frames {
                        let frame_len = frame.len() as u64;
                        if let Err(error) =
                            send_application_frame(&ws_write, &response_state, &feedback, frame)
                                .await
                        {
                            return error;
                        }
                        bytes_up.fetch_add(frame_len, Ordering::Relaxed);
                        activity.touch();
                    }
                } else {
                    if let Err(error) = send_application_frame(
                        &ws_write,
                        &response_state,
                        &feedback,
                        buffer[..length].to_vec(),
                    )
                    .await
                    {
                        return error;
                    }
                    bytes_up.fetch_add(length as u64, Ordering::Relaxed);
                    activity.touch();
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
                    if let Err(error) =
                        send_application_frame(&ws_write, &response_state, &feedback, frame).await
                    {
                        return error;
                    }
                    bytes_up.fetch_add(frame_len, Ordering::Relaxed);
                    activity.touch();
                }
            }

            close_reason
        }
    };

    let download = {
        let ws_write = Arc::clone(&ws_write);
        let bytes_down = Arc::clone(&bytes_down);
        let activity = activity.clone();
        let response_state = Arc::clone(&response_state);
        let feedback = feedback.clone();
        async move {
            while let Some(message) = ws_read.next().await {
                match message {
                    Ok(Message::Binary(data)) => {
                        if !data.is_empty()
                            && let Some(latency) =
                                record_first_mtproto_response(&response_state).await
                        {
                            info!(
                                "[{}] первый MTProto ответ DC{}{} через {} получен за {} мс",
                                label,
                                dc,
                                media_tag(is_media),
                                route_type,
                                latency.as_millis()
                            );
                            crate::routing::record_mtproto_response(&feedback, latency);
                        }
                        let length = data.len() as u64;
                        if let Err(error) = client_write.write_all(&data).await {
                            return format!("ошибка записи в TCP клиента: {error}");
                        }
                        bytes_down.fetch_add(length, Ordering::Relaxed);
                        activity.touch();
                    }
                    Ok(Message::Text(data)) => {
                        let length = data.len() as u64;
                        if let Err(error) = client_write.write_all(data.as_bytes()).await {
                            return format!("ошибка записи текста WSS в TCP клиента: {error}");
                        }
                        bytes_down.fetch_add(length, Ordering::Relaxed);
                        activity.touch();
                    }
                    Ok(Message::Ping(data)) => {
                        if let Err(error) = ws_write.lock().await.send(Message::Pong(data)).await {
                            return format!("ошибка ответа на WSS ping: {error}");
                        }
                    }
                    Ok(Message::Pong(_)) => {}
                    Ok(Message::Close(frame)) => {
                        record_mtproto_failure_if_pending(&response_state, &feedback).await;
                        let _ = client_write.shutdown().await;
                        return match frame {
                            Some(frame) => format!(
                                "upstream закрыл WSS: код={:?}, причина={}",
                                frame.code, frame.reason
                            ),
                            None => "upstream закрыл WSS без кода".to_string(),
                        };
                    }
                    Err(error) => {
                        record_mtproto_failure_if_pending(&response_state, &feedback).await;
                        return format!("ошибка чтения WSS: {error}");
                    }
                    _ => {
                        record_mtproto_failure_if_pending(&response_state, &feedback).await;
                        return "upstream прислал неподдерживаемый кадр WSS".to_string();
                    }
                }
            }
            record_mtproto_failure_if_pending(&response_state, &feedback).await;
            let _ = client_write.shutdown().await;
            "upstream завершил поток WSS".to_string()
        }
    };

    let (closed_by, reason) = match supervise_directions(
        upload,
        download,
        &activity,
        SESSION_IDLE_TIMEOUT,
        RELAY_DRAIN_TIMEOUT,
    )
    .await
    {
        RelayCompletion::Ended {
            direction: RelayDirection::Upload(reason),
            drained,
        } => {
            if !drained {
                warn!(
                    "[{}] вторая сторона не завершилась за {:?}; завершаю WSS",
                    label, RELAY_DRAIN_TIMEOUT
                );
            }
            ("клиент", reason)
        }
        RelayCompletion::Ended {
            direction: RelayDirection::Download(reason),
            drained,
        } => {
            if !drained {
                warn!(
                    "[{}] вторая сторона не завершилась за {:?}; завершаю WSS",
                    label, RELAY_DRAIN_TIMEOUT
                );
            }
            ("upstream", reason)
        }
        RelayCompletion::Idle => (
            "таймер простоя",
            format!("нет MTProto-данных {:?}", SESSION_IDLE_TIMEOUT),
        ),
    };
    if let Err(error) = ws_write.lock().await.close().await {
        warn!("[{}] ошибка закрытия WSS: {}", label, error);
    }
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

#[cfg(test)]
mod tests {
    use super::{
        MtprotoResponseState, PayloadActivity, RelayCompletion, RelayDirection, race_directions,
        record_first_mtproto_response, send_application_frame, supervise_directions,
    };
    use std::future;
    use std::io;
    use std::pin::Pin;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicUsize, Ordering};
    use std::task::{Context, Poll};
    use std::time::Duration;
    use tokio::sync::oneshot;
    use tungstenite::Message;

    use crate::routing::RouteFeedback;

    struct TestSink {
        fail_send: bool,
    }

    impl futures_util::Sink<Message> for TestSink {
        type Error = io::Error;

        fn poll_ready(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }

        fn start_send(self: Pin<&mut Self>, _: Message) -> Result<(), Self::Error> {
            if self.fail_send {
                Err(io::Error::other("ошибка отправки"))
            } else {
                Ok(())
            }
        }

        fn poll_flush(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }

        fn poll_close(self: Pin<&mut Self>, _: &mut Context<'_>) -> Poll<Result<(), Self::Error>> {
            Poll::Ready(Ok(()))
        }
    }

    struct DropCount(Arc<AtomicUsize>);

    impl Drop for DropCount {
        fn drop(&mut self) {
            self.0.fetch_add(1, Ordering::SeqCst);
        }
    }

    #[tokio::test]
    async fn здоровье_маршрута_ждёт_первый_ответ_mtproto_после_запроса() {
        let response_state = Arc::new(tokio::sync::Mutex::new(MtprotoResponseState::NotSent));
        let sink = Arc::new(tokio::sync::Mutex::new(TestSink { fail_send: false }));
        let feedback = RouteFeedback::direct(997, false, "149.154.167.50", Duration::from_secs(1));

        assert!(
            record_first_mtproto_response(&response_state)
                .await
                .is_none()
        );
        send_application_frame(&sink, &response_state, &feedback, vec![1, 2, 3])
            .await
            .unwrap();
        assert!(
            record_first_mtproto_response(&response_state)
                .await
                .is_some()
        );
        assert!(
            record_first_mtproto_response(&response_state)
                .await
                .is_none()
        );
    }

    #[tokio::test]
    async fn ошибка_отправки_не_подтверждает_здоровье_mtproto() {
        let response_state = Arc::new(tokio::sync::Mutex::new(MtprotoResponseState::NotSent));
        let sink = Arc::new(tokio::sync::Mutex::new(TestSink { fail_send: true }));
        let feedback = RouteFeedback::direct(998, false, "149.154.167.51", Duration::from_secs(1));

        assert!(
            send_application_frame(&sink, &response_state, &feedback, vec![1, 2, 3])
                .await
                .is_err()
        );
        assert!(
            record_first_mtproto_response(&response_state)
                .await
                .is_none()
        );
    }

    #[tokio::test]
    async fn cancelling_bridge_drops_both_direction_futures() {
        let dropped = Arc::new(AtomicUsize::new(0));
        let started = Arc::new(AtomicUsize::new(0));
        let upload_drop = Arc::clone(&dropped);
        let download_drop = Arc::clone(&dropped);
        let upload_started = Arc::clone(&started);
        let download_started = Arc::clone(&started);
        let task = tokio::spawn(race_directions(
            async move {
                upload_started.fetch_add(1, Ordering::SeqCst);
                let _drop_count = DropCount(upload_drop);
                future::pending::<()>().await;
            },
            async move {
                download_started.fetch_add(1, Ordering::SeqCst);
                let _drop_count = DropCount(download_drop);
                future::pending::<()>().await;
            },
            Duration::from_millis(10),
        ));

        tokio::time::timeout(std::time::Duration::from_secs(1), async {
            while started.load(Ordering::SeqCst) != 2 {
                tokio::task::yield_now().await;
            }
        })
        .await
        .unwrap();
        task.abort();
        let _ = task.await;

        assert_eq!(dropped.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn completed_direction_drains_its_peer_before_teardown() {
        let activity = PayloadActivity::new();
        let (finish_tx, finish_rx) = oneshot::channel();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            let _ = finish_tx.send("upstream завершён".to_string());
        });

        let result = supervise_directions(
            async { "клиент закрыл TCP".to_string() },
            async move { finish_rx.await.unwrap() },
            &activity,
            Duration::from_secs(1),
            Duration::from_secs(1),
        )
        .await;

        assert!(matches!(
            result,
            RelayCompletion::Ended {
                direction: RelayDirection::Upload(ref reason),
                drained: true,
            } if reason == "клиент закрыл TCP"
        ));
    }

    #[tokio::test]
    async fn idle_session_cancels_both_relay_directions() {
        let activity = PayloadActivity::new();
        let dropped = Arc::new(AtomicUsize::new(0));
        let upload_drop = Arc::clone(&dropped);
        let download_drop = Arc::clone(&dropped);

        let result = supervise_directions(
            async move {
                let _drop_count = DropCount(upload_drop);
                future::pending::<()>().await;
            },
            async move {
                let _drop_count = DropCount(download_drop);
                future::pending::<()>().await;
            },
            &activity,
            Duration::from_millis(10),
            Duration::from_millis(10),
        )
        .await;

        assert!(matches!(result, RelayCompletion::Idle));
        assert_eq!(dropped.load(Ordering::SeqCst), 2);
    }

    #[tokio::test]
    async fn activity_resets_the_idle_deadline() {
        let activity = PayloadActivity::new();
        let touched = activity.clone();
        tokio::spawn(async move {
            tokio::time::sleep(Duration::from_millis(10)).await;
            touched.touch();
        });
        let started = tokio::time::Instant::now();

        activity.idle_reached(Duration::from_millis(30)).await;

        assert!(started.elapsed() >= Duration::from_millis(35));
    }
}
