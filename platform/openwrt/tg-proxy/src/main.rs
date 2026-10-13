//! tg-ws-proxy-rs — Telegram MTProto WebSocket Bridge Proxy
//!
//! Listens for Telegram Desktop MTProto connections and forwards them through
//! WebSocket tunnels to Telegram's DC servers, bypassing networks that block
//! direct Telegram TCP traffic.
//!
//! # Architecture
//!
//! ```
//! Telegram Desktop → MTProto (TCP 1443) → tg-ws-proxy-rs → WS (TLS 443) → Telegram DC
//! ```
//!
//! See [`z2kow_tg_transparent::transparent_proxy`] for the connection handling logic and
//! [`z2kow_tg_transparent::crypto`] for the MTProto obfuscation details.

use std::io::IsTerminal as _;

use z2kow_tg_transparent::config::Config;
use z2kow_tg_transparent::server;

#[tokio::main]
async fn main() {
    rustls::crypto::ring::default_provider()
        .install_default()
        .expect("failed to install rustls ring CryptoProvider");

    let config = Config::from_args();
    init_logging(&config);

    if config.stats {
        match z2kow_tg_transparent::stats::read_socket(&config.stats_socket_path).await {
            Ok(snapshot) => print!("{}", String::from_utf8_lossy(&snapshot)),
            Err(error) => {
                eprintln!("не удалось получить статистику Telegram: {error}");
                std::process::exit(1);
            }
        }
        return;
    }

    if config.check {
        match z2kow_tg_transparent::diagnostics::run(&config).await {
            Ok(report) => {
                println!(
                    "{}",
                    serde_json::to_string(&report).expect("JSON диагностики")
                );
                if !report.has_healthy_route() {
                    std::process::exit(2);
                }
            }
            Err(error) => {
                eprintln!("ошибка диагностики Telegram: {error}");
                std::process::exit(1);
            }
        }
        return;
    }

    match server::run(config, shutdown_signal()).await {
        Ok(()) => {}
        // Bind and InvalidListenAddress are ordinary user mistakes -- "port
        // already in use" must not reach the user as a panic with a
        // RUST_BACKTRACE suggestion attached.
        Err(e) => {
            eprintln!("{e}");
            std::process::exit(1);
        }
    }
}

async fn shutdown_signal() {
    #[cfg(unix)]
    {
        use tokio::signal::unix::{SignalKind, signal};

        let mut terminate =
            signal(SignalKind::terminate()).expect("не удалось подписаться на SIGTERM");
        tokio::select! {
            _ = tokio::signal::ctrl_c() => {}
            _ = terminate.recv() => {}
        }
    }

    #[cfg(not(unix))]
    {
        let _ = tokio::signal::ctrl_c().await;
    }
}

fn init_logging(config: &Config) {
    let log_level = if config.quiet {
        "off"
    } else if config.verbose {
        "debug"
    } else {
        "info"
    };

    let env_filter =
        tracing_subscriber::EnvFilter::try_from_default_env().unwrap_or_else(|_| log_level.into());

    if let Some(ref path) = config.log_file {
        // File output: always disable ANSI color codes in log files.
        let file = std::fs::OpenOptions::new()
            .create(true)
            .append(true)
            .open(path)
            .unwrap_or_else(|e| panic!("cannot open log file '{}': {}", path, e));
        tracing_subscriber::fmt()
            .with_env_filter(env_filter)
            .with_ansi(false)
            .with_writer(file)
            .init();
    } else {
        // Console output: ANSI color codes are not rendered correctly on
        // Windows consoles that lack Virtual Terminal Processing support, so
        // disable them there.  Also disable when stderr is not a terminal
        // (e.g. output is piped or redirected).
        let use_ansi = std::io::stderr().is_terminal() && !cfg!(windows);
        tracing_subscriber::fmt()
            .with_env_filter(env_filter)
            .with_ansi(use_ansi)
            .init();
    }
}
