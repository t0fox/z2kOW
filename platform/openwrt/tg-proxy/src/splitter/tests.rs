use super::*;
use crate::crypto::{HANDSHAKE_LEN, SKIP_LEN, generate_relay_init, make_cipher};

const PREKEY_LEN: usize = 32;
const IV_LEN: usize = 16;

fn splitter_and_encryptor(proto: ProtoTag) -> (MsgSplitter, AesCtr256) {
    let relay_init = generate_relay_init(proto, 2);
    let mut enc = make_cipher(
        &relay_init[SKIP_LEN..SKIP_LEN + PREKEY_LEN],
        &relay_init[SKIP_LEN + PREKEY_LEN..SKIP_LEN + PREKEY_LEN + IV_LEN],
    );
    enc.apply_keystream(&mut [0u8; HANDSHAKE_LEN]);
    (MsgSplitter::new(proto), enc)
}

fn intermediate_packet(payload_len: usize) -> Vec<u8> {
    let mut packet = (payload_len as u32).to_le_bytes().to_vec();
    packet.resize(4 + payload_len, 0x5a);
    packet
}

fn feed(splitter: &mut MsgSplitter, enc: &mut AesCtr256, packet: &[u8]) -> Vec<Vec<u8>> {
    let mut plaintext = packet.to_vec();
    splitter.split_and_encrypt(&mut plaintext, enc)
}

#[test]
fn a_completed_packet_moves_out_the_only_large_buffer() {
    let (mut splitter, mut enc) = splitter_and_encryptor(ProtoTag::PaddedIntermediate);
    let big = intermediate_packet(1024 * 1024);

    let parts = feed(&mut splitter, &mut enc, &big);

    assert_eq!(parts.len(), 1);
    assert_eq!(parts[0].len(), big.len());
    assert_eq!(splitter.packet.capacity(), 0);
    assert_eq!(splitter.header_len, 0);
    assert_eq!(splitter.packet_len, None);
}

#[test]
fn a_fragmented_packet_uses_one_assembly_buffer() {
    let (mut splitter, mut enc) = splitter_and_encryptor(ProtoTag::PaddedIntermediate);
    let packet = intermediate_packet(128 * 1024);
    let split_at = packet.len() / 2;

    assert!(feed(&mut splitter, &mut enc, &packet[..split_at]).is_empty());
    assert_eq!(splitter.packet.len(), split_at);

    let parts = feed(&mut splitter, &mut enc, &packet[split_at..]);
    assert_eq!(parts.len(), 1);
    assert_eq!(splitter.packet.capacity(), 0);
}

#[test]
fn disabling_the_splitter_releases_assembly_state() {
    let (mut splitter, mut enc) = splitter_and_encryptor(ProtoTag::PaddedIntermediate);
    let big = intermediate_packet(128 * 1024);
    assert_eq!(feed(&mut splitter, &mut enc, &big).len(), 1);

    let zero = intermediate_packet(0);
    assert_eq!(feed(&mut splitter, &mut enc, &zero).len(), 1);

    assert!(splitter.disabled);
    assert_eq!(splitter.packet.capacity(), 0);
    assert_eq!(splitter.header_len, 0);
    assert_eq!(splitter.packet_len, None);
}

#[test]
fn rejects_packet_larger_than_the_websocket_frame_limit() {
    const MAX_PACKET_BYTES: usize = 4 * 1024 * 1024;
    let (mut splitter, mut enc) = splitter_and_encryptor(ProtoTag::PaddedIntermediate);
    let mut header = (MAX_PACKET_BYTES as u32).to_le_bytes();

    assert!(splitter.split_and_encrypt(&mut header, &mut enc).is_empty());

    let mut payload = vec![0x5a; MAX_PACKET_BYTES];
    let emitted = splitter.split_and_encrypt(&mut payload, &mut enc);

    assert!(
        emitted.is_empty(),
        "переполненный MTProto-пакет не должен уходить в WSS"
    );
    assert!(
        splitter.packet.is_empty(),
        "пакет сверх лимита не должен оставаться в памяти"
    );
    assert!(
        splitter.error().is_some(),
        "отказ должен быть виден bridge и DC discovery"
    );
}
