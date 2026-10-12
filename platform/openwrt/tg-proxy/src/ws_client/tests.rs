use std::sync::Arc;
use std::time::Duration;

use rustls::pki_types::{CertificateDer, PrivateKeyDer, PrivatePkcs8KeyDer};
use tokio::net::{TcpListener, TcpStream};

use super::*;

fn install_rustls_provider() {
    let _ = rustls::crypto::ring::default_provider().install_default();
}

fn test_certificate(domain: &str) -> (CertificateDer<'static>, PrivateKeyDer<'static>) {
    let cert = rcgen::generate_simple_self_signed(vec![domain.to_string()]).unwrap();
    let cert_der = CertificateDer::from(cert.serialize_der().unwrap());
    let key_der = PrivateKeyDer::Pkcs8(PrivatePkcs8KeyDer::from(cert.serialize_private_key_der()));
    (cert_der, key_der)
}

#[test]
fn media_tag_marks_only_media_dcs() {
    assert_eq!(media_tag(true), "m");
    assert_eq!(media_tag(false), "");
}

#[test]
fn ordered_records_put_the_preferred_variant_first() {
    let base = || "kws2.example".to_string();
    let dash_one = || "kws2-1.example".to_string();

    assert_eq!(
        ordered_records(base(), dash_one(), false),
        ["kws2.example", "kws2-1.example"]
    );
    assert_eq!(
        ordered_records(base(), dash_one(), true),
        ["kws2-1.example", "kws2.example"]
    );
}

#[test]
fn cf_ip_attempts_skip_edges_in_cooldown() {
    let cooldowns = CooldownMap::new();
    let ips = ["192.0.2.1".parse().unwrap(), "192.0.2.2".parse().unwrap()];
    cooldowns.set(
        (
            ips[0],
            "kws2.edge.example".to_string(),
            "dc2-media-proxy".to_string(),
        ),
        Duration::from_secs(60),
    );

    assert_eq!(
        cf_ip_attempts(&ips, 0, "kws2.edge.example", "dc2-media-proxy", &cooldowns),
        [ips[1]]
    );
}

#[test]
fn cf_ip_cooldowns_are_scoped_by_domain_and_transport_route() {
    let cooldowns = CooldownMap::new();
    let ips = ["192.0.2.1".parse().unwrap(), "192.0.2.2".parse().unwrap()];
    cooldowns.set(
        (
            ips[0],
            "kws2.edge.example".to_string(),
            "dc2-media-proxy".to_string(),
        ),
        Duration::from_secs(60),
    );

    assert_eq!(
        cf_ip_attempts(&ips, 0, "kws4.edge.example", "dc4-proxy", &cooldowns),
        ips
    );
}

#[test]
fn cf_ip_attempts_try_one_edge_when_every_edge_is_cooling() {
    let cooldowns = CooldownMap::new();
    let ips = ["192.0.2.1".parse().unwrap(), "192.0.2.2".parse().unwrap()];
    for ip in ips {
        cooldowns.set(
            (ip, "kws2.edge.example".to_string(), "dc2-proxy".to_string()),
            Duration::from_secs(60),
        );
    }

    assert_eq!(
        cf_ip_attempts(&ips, 1, "kws2.edge.example", "dc2-proxy", &cooldowns),
        [ips[1]]
    );
}

#[tokio::test]
async fn tls_verification_rejects_self_signed_certificates() {
    install_rustls_provider();

    let real_domain = "real.example.test";
    let (cert, key) = test_certificate(real_domain);

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();

    let server_task = tokio::spawn(async move {
        let (stream, _) = listener.accept().await.unwrap();
        let config = rustls::ServerConfig::builder()
            .with_no_client_auth()
            .with_single_cert(vec![cert], key)
            .unwrap();
        let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(config));
        // The client is expected to abort during the TLS handshake because
        // it doesn't trust this self-signed cert, so the accept here may
        // legitimately fail — that's the point of the assertion below.
        let _ = acceptor.accept(stream).await;
    });

    let tcp = TcpStream::connect(addr).await.unwrap();
    let request = format!("wss://{real_domain}/apiws")
        .into_client_request()
        .unwrap();

    let result = tls_handshake_and_upgrade(tcp, request).await;
    assert!(
        result.is_err(),
        "expected certificate verification to reject the self-signed cert"
    );

    tokio::time::timeout(Duration::from_secs(2), server_task)
        .await
        .expect("server task timed out")
        .ok();
}

#[test]
fn tls_client_configs_are_built_once_and_shared() {
    install_rustls_provider();

    // Rebuilding the config per connection re-copied the ~150-entry root store
    // and, worse, threw away the TLS session cache — so no connection could
    // ever resume. Both configs must be the same allocation every time.
    let first = verifying_rustls_config();
    let second = verifying_rustls_config();
    assert!(Arc::ptr_eq(&first, &second));
}

#[test]
fn websocket_buffers_are_bounded_for_many_connections() {
    let config = ws_config();

    assert_eq!(config.write_buffer_size, 16 * 1024);
    assert_eq!(config.max_frame_size, Some(4 * 1024 * 1024));
    assert_eq!(config.max_message_size, Some(4 * 1024 * 1024));
}

/// Regression test for TLS session resumption.
///
/// The shared `ClientConfig` owns the session cache, so a config rebuilt per
/// connection — as this used to be — could never resume: every handshake was a
/// full one. Two connections through one config must produce a full handshake
/// then a resumed one.
#[tokio::test]
async fn a_second_connection_to_the_same_host_resumes_its_tls_session() {
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    install_rustls_provider();

    let domain = "resumption.example.test";
    let (cert, key) = test_certificate(domain);

    let mut server_config = rustls::ServerConfig::builder()
        .with_no_client_auth()
        .with_single_cert(vec![cert.clone()], key)
        .unwrap();
    // Hand out a ticket so the client has something to resume with.
    server_config.send_tls13_tickets = 1;
    let acceptor = tokio_rustls::TlsAcceptor::from(Arc::new(server_config));

    let listener = TcpListener::bind("127.0.0.1:0").await.unwrap();
    let addr = listener.local_addr().unwrap();
    let server = tokio::spawn(async move {
        for _ in 0..2 {
            let (stream, _) = listener.accept().await.unwrap();
            let mut tls = acceptor.accept(stream).await.unwrap();
            tls.write_all(b"hi").await.unwrap();
            tls.flush().await.unwrap();
            let mut sink = Vec::new();
            let _ = tls.read_to_end(&mut sink).await;
        }
    });

    // Trust the test certificate, but otherwise the same resumption defaults
    // the shared config uses.
    let mut roots = rustls::RootCertStore::empty();
    roots.add(cert).unwrap();
    let config = Arc::new(
        rustls::ClientConfig::builder()
            .with_root_certificates(roots)
            .with_no_client_auth(),
    );
    let connector = tokio_rustls::TlsConnector::from(Arc::clone(&config));
    let name = rustls::pki_types::ServerName::try_from(domain).unwrap();

    let mut kinds = Vec::new();
    for _ in 0..2 {
        let tcp = TcpStream::connect(addr).await.unwrap();
        let mut tls = connector.connect(name.clone(), tcp).await.unwrap();
        // Read the server's greeting; the session ticket arrives with it and
        // has to be processed before it can be reused.
        let mut buf = [0u8; 2];
        tls.read_exact(&mut buf).await.unwrap();
        kinds.push(tls.get_ref().1.handshake_kind());
        tls.shutdown().await.unwrap();
    }

    assert_eq!(
        kinds,
        vec![
            Some(rustls::HandshakeKind::Full),
            Some(rustls::HandshakeKind::Resumed),
        ],
        "the shared config must let the second handshake resume"
    );
    let _ = tokio::time::timeout(Duration::from_secs(5), server).await;
}

// ─── Cloudflare attempt ordering ─────────────────────────────────────────────

fn drain(attempts: &mut CfAttempts) -> Vec<String> {
    std::iter::from_fn(|| attempts.next_domain()).collect()
}

#[test]
fn every_base_record_gets_a_second_attempt() {
    // Regression test: deduplicating this retry away measurably pushed
    // connections into the TCP fallback (see CfAttempts' docs).
    let domains = ["a.example".to_string(), "b.example".to_string()];
    let mut attempts = CfAttempts::new(2, &domains);

    assert_eq!(
        drain(&mut attempts),
        [
            "kws2.a.example",
            "kws2.a.example",
            "kws2.b.example",
            "kws2.b.example",
        ]
    );
}

#[test]
fn no_dash_one_record_is_ever_attempted() {
    // Through Cloudflare a `-1` record reaches the same origin as the base
    // one, and the shared default domains do not define it, so every lookup
    // was a wasted NXDOMAIN (issue #139).
    let domains = ["a.example".to_string(), "b.example".to_string()];
    let mut attempts = CfAttempts::new(203, &domains);

    assert!(drain(&mut attempts).iter().all(|d| !d.contains("-1.")));
}

#[test]
fn a_record_that_timed_out_is_not_retried() {
    // Retrying a record that ran out the clock just buys another full connect
    // timeout before the fallback chain can move on.
    let domains = ["a.example".to_string(), "b.example".to_string()];
    let mut attempts = CfAttempts::new(2, &domains);

    assert_eq!(attempts.next_domain().as_deref(), Some("kws2.a.example"));
    attempts.note_timed_out();
    assert_eq!(attempts.next_domain().as_deref(), Some("kws2.b.example"));
    assert_eq!(attempts.next_domain().as_deref(), Some("kws2.b.example"));
    assert_eq!(attempts.next_domain(), None);
}

#[test]
fn lazy_attempts_rotate_domains_without_rebuilding_the_list() {
    let domains = [
        "a.example".to_string(),
        "b.example".to_string(),
        "c.example".to_string(),
    ];
    let mut attempts = CfAttempts::with_offset(2, &domains, 1);

    assert_eq!(
        drain(&mut attempts),
        [
            "kws2.b.example",
            "kws2.b.example",
            "kws2.c.example",
            "kws2.c.example",
            "kws2.a.example",
            "kws2.a.example",
        ]
    );
}

#[test]
fn lazy_attempts_preserve_duplicate_domain_deduplication() {
    let domains = ["a.example".to_string(), "a.example".to_string()];
    let mut attempts = CfAttempts::new(2, &domains);

    assert_eq!(drain(&mut attempts), ["kws2.a.example", "kws2.a.example"]);
}

#[test]
fn no_domains_means_no_attempts() {
    let mut attempts = CfAttempts::new(2, &[]);

    assert_eq!(attempts.next_domain(), None);
}

#[test]
fn tcp_connect_timeout_skips_sibling_ws_domains() {
    let timed_out = WsConnectResult::ConnectTimedOut("TCP connect timed out".into());
    assert!(!should_try_next_ws_domain(&timed_out));
    assert!(should_try_next_ws_domain(&WsConnectResult::TimedOut));
}
