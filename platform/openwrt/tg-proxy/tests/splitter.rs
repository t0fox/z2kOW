use cipher::StreamCipher;
use z2kow_tg_transparent::{
    crypto::{
        AesCtr256, ProtoTag, build_connection_ciphers, generate_client_handshake,
        generate_relay_init, parse_handshake,
    },
    splitter::MsgSplitter,
};

#[test]
fn splitter_buffers_partial_intermediate_packet_until_complete() {
    let payload = b"0123456789abcdef";
    let mut plain_packet = (payload.len() as u32).to_le_bytes().to_vec();
    plain_packet.extend_from_slice(payload);
    let (mut splitter, mut enc, mut expected_enc) = harness(ProtoTag::PaddedIntermediate);
    let expected = encrypt(&mut expected_enc, &plain_packet);

    assert!(feed(&mut splitter, &mut enc, &plain_packet[..5]).is_empty());
    assert_eq!(
        feed(&mut splitter, &mut enc, &plain_packet[5..]),
        vec![expected]
    );
    assert!(splitter.flush().is_empty());
}

#[test]
fn splitter_returns_each_complete_abridged_packet_separately() {
    let first_payload = b"abcdefgh";
    let second_payload = b"ijklmnop";
    let mut plain_stream = vec![(first_payload.len() / 4) as u8];
    plain_stream.extend_from_slice(first_payload);
    plain_stream.push((second_payload.len() / 4) as u8);
    plain_stream.extend_from_slice(second_payload);
    let (mut splitter, mut enc, mut expected_enc) = harness(ProtoTag::Abridged);
    let expected = encrypt(&mut expected_enc, &plain_stream);

    let parts = feed(&mut splitter, &mut enc, &plain_stream);

    assert_eq!(parts.len(), 2);
    assert_eq!(parts[0], expected[..1 + first_payload.len()]);
    assert_eq!(parts[1], expected[1 + first_payload.len()..]);
}

#[test]
fn splitter_disables_after_zero_length_abridged_packet() {
    let first_payload = b"abcdefgh";
    let mut plain_stream = vec![(first_payload.len() / 4) as u8];
    plain_stream.extend_from_slice(first_payload);
    plain_stream.push(0);
    plain_stream.extend_from_slice(b"tail");
    let (mut splitter, mut enc, mut expected_enc) = harness(ProtoTag::Abridged);
    let expected = encrypt(&mut expected_enc, &plain_stream);

    let parts = feed(&mut splitter, &mut enc, &plain_stream);
    assert_eq!(parts.len(), 2);
    assert_eq!(parts[0], expected[..1 + first_payload.len()]);
    assert_eq!(parts[1], expected[1 + first_payload.len()..]);

    let trailing = b"raw bytes";
    let expected_trailing = encrypt(&mut expected_enc, trailing);
    assert_eq!(
        feed(&mut splitter, &mut enc, trailing),
        vec![expected_trailing]
    );
}

#[test]
fn splitter_reassembles_a_packet_spread_across_many_reads() {
    let payload = vec![0xa5u8; 40_000];
    let mut plain_packet = (payload.len() as u32).to_le_bytes().to_vec();
    plain_packet.extend_from_slice(&payload);
    let (mut splitter, mut enc, mut expected_enc) = harness(ProtoTag::PaddedIntermediate);
    let expected = encrypt(&mut expected_enc, &plain_packet);

    let mut parts = Vec::new();
    for chunk in plain_packet.chunks(16 * 1024) {
        parts.extend(feed(&mut splitter, &mut enc, chunk));
    }

    assert_eq!(parts, vec![expected]);
    assert!(splitter.flush().is_empty());
}

#[test]
fn splitter_keeps_emitting_after_a_large_packet() {
    let big_payload = vec![7u8; 32_000];
    let mut plain_stream = (big_payload.len() as u32).to_le_bytes().to_vec();
    plain_stream.extend_from_slice(&big_payload);

    let small_payload = b"still working";
    let mut small_packet = (small_payload.len() as u32).to_le_bytes().to_vec();
    small_packet.extend_from_slice(small_payload);
    let small_packet_count = 200;
    for _ in 0..small_packet_count {
        plain_stream.extend_from_slice(&small_packet);
    }

    let (mut splitter, mut enc, mut expected_enc) = harness(ProtoTag::PaddedIntermediate);
    let expected = encrypt(&mut expected_enc, &plain_stream);
    let mut parts = Vec::new();
    for chunk in plain_stream.chunks(4096) {
        parts.extend(feed(&mut splitter, &mut enc, chunk));
    }

    assert_eq!(parts.len(), 1 + small_packet_count);
    let big_len = 4 + big_payload.len();
    assert_eq!(parts[0], expected[..big_len]);
    for (index, part) in parts[1..].iter().enumerate() {
        let start = big_len + index * small_packet.len();
        assert_eq!(part, &expected[start..start + small_packet.len()]);
    }
}

#[test]
fn splitter_flush_returns_an_incomplete_encrypted_packet() {
    let payload = b"0123456789abcdef";
    let mut plain_packet = (payload.len() as u32).to_le_bytes().to_vec();
    plain_packet.extend_from_slice(payload);
    let (mut splitter, mut enc, mut expected_enc) = harness(ProtoTag::PaddedIntermediate);
    let expected = encrypt(&mut expected_enc, &plain_packet[..10]);

    assert!(feed(&mut splitter, &mut enc, &plain_packet[..10]).is_empty());
    assert_eq!(splitter.flush(), vec![expected]);
    assert!(splitter.flush().is_empty());
}

#[test]
fn splitter_ignores_empty_reads() {
    let (mut splitter, mut enc, _) = harness(ProtoTag::Abridged);

    assert!(splitter.split_and_encrypt(&mut [], &mut enc).is_empty());
    assert!(splitter.flush().is_empty());
}

#[test]
fn splitter_handles_the_four_byte_abridged_header() {
    let payload = vec![3u8; 4 * 0x80];
    let mut plain_packet = vec![0x7f];
    plain_packet.extend_from_slice(&((payload.len() / 4) as u32).to_le_bytes()[..3]);
    plain_packet.extend_from_slice(&payload);
    let (mut splitter, mut enc, mut expected_enc) = harness(ProtoTag::Abridged);
    let expected = encrypt(&mut expected_enc, &plain_packet);

    assert_eq!(feed(&mut splitter, &mut enc, &plain_packet), vec![expected]);
    assert!(splitter.flush().is_empty());
}

fn harness(proto: ProtoTag) -> (MsgSplitter, AesCtr256, AesCtr256) {
    let secret = hex::decode("2a519e5be6c3219c69879e5fa2a0eab8").unwrap();
    let (handshake, _, _) = generate_client_handshake(&secret, 2, proto);
    let parsed = parse_handshake(&handshake, &secret).expect("generated handshake parses");
    let relay_init = generate_relay_init(parsed.proto, parsed.dc_id as i16);
    let first = build_connection_ciphers(&parsed.prekey_and_iv, &secret, &relay_init).tg_enc;
    let second = build_connection_ciphers(&parsed.prekey_and_iv, &secret, &relay_init).tg_enc;
    (MsgSplitter::new(proto), first, second)
}

fn feed(splitter: &mut MsgSplitter, enc: &mut AesCtr256, plain: &[u8]) -> Vec<Vec<u8>> {
    let mut input = plain.to_vec();
    splitter.split_and_encrypt(&mut input, enc)
}

fn encrypt(enc: &mut AesCtr256, plain: &[u8]) -> Vec<u8> {
    let mut encrypted = plain.to_vec();
    enc.apply_keystream(&mut encrypted);
    encrypted
}
