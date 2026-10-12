use std::time::Duration;

use z2kow_tg_transparent::config::Config;
use z2kow_tg_transparent::server;

#[tokio::test]
async fn implicit_transparent_listener_binds_then_stops_cleanly() {
    let config = Config::try_from_cli_line("--host 127.0.0.1 --port 0 --quiet").unwrap();
    let (shutdown_tx, shutdown_rx) = tokio::sync::oneshot::channel();
    let (listen_tx, listen_rx) = tokio::sync::oneshot::channel();

    let task = tokio::spawn(async move {
        server::run_with_listen(
            config,
            async move {
                let _ = shutdown_rx.await;
            },
            move |info| {
                let _ = listen_tx.send(info.addr);
            },
        )
        .await
    });

    let address = tokio::time::timeout(Duration::from_secs(5), listen_rx)
        .await
        .expect("listener не начал принимать подключения")
        .expect("callback прослушивания завершился без адреса");
    assert_ne!(address.port(), 0);
    tokio::net::TcpStream::connect(address)
        .await
        .expect("listener должен принимать TCP подключения");

    shutdown_tx.send(()).unwrap();
    task.await
        .expect("задача сервера завершилась аварийно")
        .expect("сервер вернул ошибку при остановке");

    tokio::net::TcpListener::bind(address)
        .await
        .expect("порт должен освободиться после остановки");
}
