use cipher::StreamCipher;
use clap::Parser;
use std::net::{IpAddr, SocketAddr};
use z2kow_tg_transparent::crypto::{
    ProtoTag, generate_client_handshake, generate_relay_init, make_cipher,
};
use z2kow_tg_transparent::dc_map::{DcEndpoint, DcMapStore, DcSnapshot};
use z2kow_tg_transparent::splitter::MsgSplitter;
use z2kow_tg_transparent::transparent::{
    direct_stream_ciphers, parse_client_init, parse_client_init_with_secrets,
};

#[test]
fn transparent_mode_is_implicit_and_legacy_switch_is_rejected() {
    let config =
        z2kow_tg_transparent::config::Config::try_from_cli_line("--host :: --port 1443").unwrap();
    assert_eq!(config.port, 1443);
    assert!(
        z2kow_tg_transparent::config::Config::try_from_cli_line("--transparent").is_err(),
        "единственный режим не должен требовать переключателя"
    );
}

#[test]
fn transparent_init_accepts_dc_and_media_marker_without_a_proxy_secret() {
    let init = generate_relay_init(ProtoTag::Intermediate, -4);
    let parsed = parse_client_init(&init).expect("корректный obfuscated2-пакет без секрета");
    assert_eq!(parsed.dc, Some(4));
    assert!(parsed.is_media);
    assert_eq!(parsed.proto, ProtoTag::Intermediate);
}

#[test]
fn transparent_init_accepts_direct_connection_without_dc_metadata() {
    let init = generate_relay_init(ProtoTag::Intermediate, 0);
    let parsed = parse_client_init(&init).expect("корректный прямой obfuscated2-пакет");
    assert_eq!(parsed.dc, None);
    assert!(!parsed.is_media);
    assert_eq!(parsed.proto, ProtoTag::Intermediate);
}

#[test]
fn transparent_init_decodes_secret_obfuscated2_using_official_dc_and_cdn_secrets() {
    let secret = [0x12, 0x34, 0x56, 0x78];
    let (init, _, _) = generate_client_handshake(&secret, -2, ProtoTag::Intermediate);
    let cdn_secret = [0x87, 0x65, 0x43, 0x21];
    let (cdn_init, _, _) = generate_client_handshake(&cdn_secret, -203, ProtoTag::Intermediate);
    let now = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_secs() as i64;
    let directory =
        std::env::temp_dir().join(format!("tg-secret-map-{}-{}", std::process::id(), now));
    std::fs::create_dir_all(&directory).unwrap();
    let mut endpoints = (1..=5)
        .map(|id| DcEndpoint {
            id,
            address: format!("149.154.160.{id}").parse().unwrap(),
            port: 443,
            ipv6: false,
            media_only: false,
            tcpo_only: false,
            cdn: false,
            is_static: true,
            this_port_only: false,
            secret: None,
            last_seen: now,
        })
        .collect::<Vec<_>>();
    endpoints.push(DcEndpoint {
        id: 2,
        address: "149.154.167.151".parse().unwrap(),
        port: 5222,
        ipv6: false,
        media_only: true,
        tcpo_only: true,
        cdn: false,
        is_static: true,
        this_port_only: true,
        secret: Some(hex::encode(secret)),
        last_seen: now,
    });
    endpoints.push(DcEndpoint {
        id: 203,
        address: "91.105.192.203".parse().unwrap(),
        port: 443,
        ipv6: false,
        media_only: false,
        tcpo_only: true,
        cdn: true,
        is_static: true,
        this_port_only: true,
        secret: Some(hex::encode(cdn_secret)),
        last_seen: now,
    });
    let store = DcMapStore::without_cache(directory.join("map.json"));
    store
        .install(
            DcSnapshot {
                schema_version: 1,
                fetched_at: now,
                config_date: now,
                config_expires: now + 86_400,
                this_dc: 2,
                endpoints,
            },
            now,
        )
        .unwrap();
    let secrets = store.handshake_secrets_for("149.154.167.151".parse().unwrap(), 5222);
    let parsed = parse_client_init_with_secrets(&init, &secrets)
        .expect("официальный секрет должен позволить разобрать рукопожатие");

    assert_eq!(parsed.dc, Some(2));
    assert!(parsed.is_media);
    assert_eq!(parsed.proto, ProtoTag::Intermediate);

    let cdn_secrets = store.handshake_secrets_for("91.105.192.203".parse().unwrap(), 443);
    let parsed_cdn = parse_client_init_with_secrets(&cdn_init, &cdn_secrets)
        .expect("точный секрет официального CDN должен разобрать отрицательный DC index");
    assert_eq!(parsed_cdn.dc, Some(203));
    assert!(parsed_cdn.is_media);
    assert_eq!(parsed_cdn.proto, ProtoTag::Intermediate);
    std::fs::remove_dir_all(directory).unwrap();
}

#[test]
fn transparent_init_rejects_wrong_secret_obfuscated2() {
    let (init, _, _) = generate_client_handshake(&[0x12, 0x34], 2, ProtoTag::Intermediate);

    assert!(
        parse_client_init_with_secrets(&init, &[vec![0xab, 0xcd]]).is_none(),
        "рукопожатие с неизвестным секретом должно закрываться"
    );
}

#[test]
fn transparent_mode_maps_destination_to_one_of_the_known_dc_fallbacks() {
    assert_eq!(
        z2kow_tg_transparent::transparent::dc_route_for_destination(
            "149.154.175.52".parse().unwrap()
        ),
        Some((1, true))
    );
    assert_eq!(
        z2kow_tg_transparent::transparent::dc_route_for_destination(
            "149.154.167.151".parse().unwrap()
        ),
        Some((2, true))
    );
    assert_eq!(
        z2kow_tg_transparent::transparent::dc_route_for_destination(
            "149.154.167.51".parse().unwrap()
        ),
        Some((2, false))
    );
    assert_eq!(
        z2kow_tg_transparent::transparent::dc_route_for_destination(
            "149.154.175.102".parse().unwrap()
        ),
        Some((3, true))
    );
    assert_eq!(
        z2kow_tg_transparent::transparent::dc_route_for_destination(
            "149.154.164.250".parse().unwrap()
        ),
        Some((4, true))
    );
    assert_eq!(
        z2kow_tg_transparent::transparent::dc_route_for_destination(
            "91.108.56.102".parse().unwrap()
        ),
        Some((5, true))
    );
    assert_eq!(
        z2kow_tg_transparent::transparent::dc_route_for_destination(
            "91.105.192.100".parse().unwrap()
        ),
        Some((203, false))
    );
    assert_eq!(
        z2kow_tg_transparent::transparent::dc_route_for_destination(
            "2001:67c:4e8:f002::a".parse().unwrap()
        ),
        Some((2, false))
    );
    assert_eq!(
        z2kow_tg_transparent::transparent::dc_route_for_destination(
            "198.51.100.25".parse().unwrap()
        ),
        None
    );
}

#[test]
fn transparent_packet_framing_survives_partial_tcp_reads_without_changing_ciphertext() {
    let init = generate_relay_init(ProtoTag::Intermediate, 0);
    let plaintext = [
        4, 0, 0, 0, 1, 2, 3, 4, 8, 0, 0, 0, 5, 6, 7, 8, 9, 10, 11, 12,
    ];
    let mut client_encrypt = make_cipher(&init[8..40], &init[40..56]);
    let mut skipped = [0u8; 64];
    client_encrypt.apply_keystream(&mut skipped);
    let mut wire = plaintext;
    client_encrypt.apply_keystream(&mut wire);

    let (mut client_decrypt, mut passthrough_encrypt) = direct_stream_ciphers(&init);
    let mut splitter = MsgSplitter::new(ProtoTag::Intermediate);
    let mut frames = Vec::new();
    for part in wire.chunks(3) {
        let mut plaintext = part.to_vec();
        client_decrypt.apply_keystream(&mut plaintext);
        frames.extend(splitter.split_and_encrypt(&mut plaintext, &mut passthrough_encrypt));
    }
    frames.extend(splitter.flush());

    assert_eq!(frames.iter().map(Vec::len).collect::<Vec<_>>(), [8, 12]);
    assert_eq!(frames.concat(), wire);
}

#[test]
fn transparent_init_accepts_cdn_dc_203() {
    let init = generate_relay_init(ProtoTag::PaddedIntermediate, 203);
    let parsed = parse_client_init(&init).expect("начальный пакет DC203");
    assert_eq!(parsed.dc, Some(203));
    assert!(!parsed.is_media);
}

#[test]
fn transparent_init_preserves_dynamic_dc_and_rejects_random_data() {
    let parsed = parse_client_init(&generate_relay_init(ProtoTag::Intermediate, 6)).unwrap();
    assert_eq!(parsed.dc, Some(6));
    let parsed = parse_client_init(&generate_relay_init(ProtoTag::Intermediate, -301)).unwrap();
    assert_eq!(parsed.dc, Some(301));
    assert!(parsed.is_media);
    assert!(parse_client_init(&[0; 64]).is_none());
}

#[test]
fn transparent_mode_uses_the_configured_port_policy() {
    let configured = [58321, 60001];
    assert!(z2kow_tg_transparent::transparent::supports_destination_port(58321, &configured));
    assert!(!z2kow_tg_transparent::transparent::supports_destination_port(80, &configured));
    assert!(!z2kow_tg_transparent::transparent::supports_destination_port(60002, &configured));
}

#[test]
fn transparent_mode_checks_telegram_cidrs_for_both_address_families() {
    let cidrs = vec!["192.0.2.0/24".to_string(), "2001:db8::/32".to_string()];
    assert!(z2kow_tg_transparent::transparent::is_telegram_destination(
        "192.0.2.15".parse::<IpAddr>().unwrap(),
        &cidrs
    ));
    assert!(z2kow_tg_transparent::transparent::is_telegram_destination(
        "2001:db8:1::15".parse::<IpAddr>().unwrap(),
        &cidrs
    ));
    assert!(!z2kow_tg_transparent::transparent::is_telegram_destination(
        "198.51.100.15".parse::<IpAddr>().unwrap(),
        &cidrs
    ));
    assert!(!z2kow_tg_transparent::transparent::is_telegram_destination(
        "2001:db9::15".parse::<IpAddr>().unwrap(),
        &cidrs
    ));
}

#[test]
fn прозрачный_режим_отличает_tls_и_неизвестные_рукопожатия_от_obfuscated2() {
    let unknown = [0x45; 64];
    assert!(parse_client_init(&unknown).is_none());

    let mut tls_client_hello = [0u8; 64];
    tls_client_hello[..5].copy_from_slice(&[0x16, 0x03, 0x01, 0x00, 0x10]);
    assert!(parse_client_init(&tls_client_hello).is_none());
}

#[test]
fn transparent_mode_preserves_original_port_for_tcp_fallback() {
    let original: SocketAddr = "192.0.2.10:58321".parse().unwrap();
    assert_eq!(
        z2kow_tg_transparent::transparent::tcp_fallback_target("fallback.example", original),
        ("fallback.example".to_string(), 58321)
    );
}

#[test]
fn transparent_policy_never_accepts_tcp_80_even_if_legacy_cli_configures_it() {
    assert!(!z2kow_tg_transparent::transparent::supports_destination_port(80, &[80, 443, 5222]));
    assert!(z2kow_tg_transparent::transparent::supports_destination_port(443, &[80, 443, 5222]));
    assert!(z2kow_tg_transparent::transparent::supports_destination_port(5222, &[80, 443, 5222]));
}

#[test]
fn transparent_mode_reads_policy_arguments_from_openwrt() {
    let config = z2kow_tg_transparent::config::Config::try_parse_from([
        "tg-ws-proxy",
        "--transparent-ports=58321,60001",
        "--transparent-cidrs=192.0.2.0/24,2001:db8::/32",
        "--dc-map-endpoints-path=/tmp/telegram-dc-endpoints.tsv",
    ])
    .unwrap()
    .with_defaults();
    assert_eq!(config.transparent_ports, [58321, 60001]);
    assert_eq!(config.transparent_cidrs, ["192.0.2.0/24", "2001:db8::/32"]);
    assert_eq!(
        config.dc_map_endpoints_path,
        std::path::PathBuf::from("/tmp/telegram-dc-endpoints.tsv")
    );
}
