use cipher::StreamCipher;
use z2kow_tg_transparent::crypto::{
    ProtoTag, build_connection_ciphers, generate_client_handshake, generate_relay_init,
    make_cipher, parse_handshake,
};

#[test]
fn secret_obfuscated2_handshake_roundtrips_for_supported_transports() {
    let secret = test_secret();

    for proto in [
        ProtoTag::Abridged,
        ProtoTag::Intermediate,
        ProtoTag::PaddedIntermediate,
    ] {
        let (handshake, _, _) = generate_client_handshake(&secret, 2, proto);
        let parsed = parse_handshake(&handshake, &secret).expect("generated handshake parses");

        assert_eq!(parsed.dc_id, 2);
        assert!(!parsed.is_media);
        assert_eq!(parsed.proto, proto);
    }
}

#[test]
fn generated_client_handshake_preserves_media_dc_sign() {
    // Negative DC indexes are Telegram's media-DC marker; keep that behavior
    // independent from FakeTLS listener changes.
    let secret = test_secret();
    let (handshake, _, _) = generate_client_handshake(&secret, -4, ProtoTag::PaddedIntermediate);
    let parsed = parse_handshake(&handshake, &secret).expect("generated media handshake parses");

    assert_eq!(parsed.dc_id, 4);
    assert!(parsed.is_media);
    assert_eq!(parsed.proto, ProtoTag::PaddedIntermediate);
}

#[test]
fn generated_client_handshake_rejects_wrong_secret() {
    // A valid-looking init packet must not parse when the shared proxy secret
    // is different.
    let secret = test_secret();
    let wrong_secret = hex::decode("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").unwrap();
    let (handshake, _, _) = generate_client_handshake(&secret, 2, ProtoTag::PaddedIntermediate);

    assert!(parse_handshake(&handshake, &wrong_secret).is_none());
}

#[test]
fn connection_ciphers_match_client_handshake_ciphers() {
    // After the handshake bytes, both sides must derive matching stream
    // ciphers for client -> proxy and proxy -> client traffic.
    let secret = test_secret();
    let (handshake, mut client_enc, mut client_dec) =
        generate_client_handshake(&secret, 2, ProtoTag::PaddedIntermediate);
    let parsed = parse_handshake(&handshake, &secret).expect("generated handshake parses");
    let relay_init = generate_relay_init(parsed.proto, parsed.dc_id as i16);
    let mut ciphers = build_connection_ciphers(&parsed.prekey_and_iv, &secret, &relay_init);

    let original_to_proxy = b"client payload after handshake".to_vec();
    let mut encrypted_to_proxy = original_to_proxy.clone();
    client_enc.apply_keystream(&mut encrypted_to_proxy);
    ciphers.clt_dec.apply_keystream(&mut encrypted_to_proxy);
    assert_eq!(encrypted_to_proxy, original_to_proxy);

    let original_to_client = b"proxy response after handshake".to_vec();
    let mut encrypted_to_client = original_to_client.clone();
    ciphers.clt_enc.apply_keystream(&mut encrypted_to_client);
    client_dec.apply_keystream(&mut encrypted_to_client);
    assert_eq!(encrypted_to_client, original_to_client);
}

// ─── Protocol tags ───────────────────────────────────────────────────────────

#[test]
fn proto_tag_bytes_round_trip() {
    for proto in [
        ProtoTag::Abridged,
        ProtoTag::Intermediate,
        ProtoTag::PaddedIntermediate,
    ] {
        assert_eq!(ProtoTag::from_bytes(&proto.as_bytes()), Some(proto));
    }

    assert_eq!(ProtoTag::from_bytes(&[0x00, 0x01, 0x02, 0x03]), None);
    assert_eq!(ProtoTag::from_bytes(&[]), None);
}

// ─── Relay init ──────────────────────────────────────────────────────────────

#[test]
fn relay_init_never_starts_with_a_reserved_prefix() {
    // Telegram (and any DPI in between) rejects an init packet that looks like
    // HTTP or TLS, so the generator has to reroll those.
    const RESERVED_STARTS: &[&[u8]] = &[
        b"HEAD",
        b"POST",
        b"GET ",
        &[0xee, 0xee, 0xee, 0xee],
        &[0xdd, 0xdd, 0xdd, 0xdd],
        &[0x16, 0x03, 0x01, 0x02],
    ];

    for _ in 0..256 {
        let init = generate_relay_init(ProtoTag::PaddedIntermediate, 2);

        assert_ne!(init[0], 0xef);
        assert!(!RESERVED_STARTS.contains(&&init[..4]));
        assert_ne!(&init[4..8], &[0, 0, 0, 0]);
    }
}

#[test]
fn relay_init_embeds_the_protocol_tag_and_signed_dc_index() {
    // Decode the init the way Telegram's backend does: the key and IV are
    // embedded raw in the packet (no secret hashing), and decrypting the whole
    // 64 bytes with them reveals the protocol tag and signed DC index.
    for (proto, dc_idx) in [
        (ProtoTag::Abridged, 1i16),
        (ProtoTag::Intermediate, 5),
        (ProtoTag::PaddedIntermediate, -2),
    ] {
        let init = generate_relay_init(proto, dc_idx);

        let mut decrypted = init;
        make_cipher(&init[8..40], &init[40..56]).apply_keystream(&mut decrypted);

        assert_eq!(&decrypted[56..60], &proto.as_bytes());
        assert_eq!(i16::from_le_bytes([decrypted[60], decrypted[61]]), dc_idx);
    }
}

#[test]
fn relay_init_is_unique_per_call() {
    let first = generate_relay_init(ProtoTag::PaddedIntermediate, 2);
    let second = generate_relay_init(ProtoTag::PaddedIntermediate, 2);

    assert_ne!(first, second, "init packets must not be replayable");
}

// ─── Telegram-facing ciphers ─────────────────────────────────────────────────

#[test]
fn relay_ciphers_are_forwarded_past_the_init_packet() {
    // tg_enc must start where the 64-byte relay init left off, otherwise the
    // very first forwarded packet is encrypted with a reused keystream.
    let secret = test_secret();
    let (handshake, _, _) = generate_client_handshake(&secret, 2, ProtoTag::PaddedIntermediate);
    let parsed = parse_handshake(&handshake, &secret).unwrap();
    let relay_init = generate_relay_init(parsed.proto, 2);
    let mut ciphers = build_connection_ciphers(&parsed.prekey_and_iv, &secret, &relay_init);

    // Telegram's view: the same raw key/IV, fast-forwarded the same way.
    let mut telegram_view = make_cipher(&relay_init[8..40], &relay_init[40..56]);
    let mut skip = [0u8; 64];
    telegram_view.apply_keystream(&mut skip);

    let payload = b"first packet after the relay init".to_vec();
    let mut wire = payload.clone();
    ciphers.tg_enc.apply_keystream(&mut wire);
    assert_ne!(wire, payload);

    telegram_view.apply_keystream(&mut wire);
    assert_eq!(wire, payload);
}

fn test_secret() -> Vec<u8> {
    hex::decode("2a519e5be6c3219c69879e5fa2a0eab8").unwrap()
}
