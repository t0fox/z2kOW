//! Средства Linux для прозрачного проксирования. После чтения 64-байтового
//! заголовка obfuscated2 поток остаётся непрозрачным: Telegram WSS передаёт
//! MTProto как единый поток байтов, поэтому границы WebSocket-кадров не должны
//! менять или повторно шифровать данные.

use std::io;
use std::net::{IpAddr, Ipv4Addr, Ipv6Addr, SocketAddr, SocketAddrV4, SocketAddrV6};
use std::os::fd::AsRawFd;

use tokio::net::TcpStream;

use cipher::StreamCipher;

use crate::crypto::{AesCtr256, DC_IDX_POS, HANDSHAKE_LEN, PROTO_TAG_POS, ProtoTag, make_cipher};

/// Метаданные obfuscated2: DC может отсутствовать в прямом подключении.
pub struct ClientInit {
    pub dc: Option<u32>,
    pub is_media: bool,
    pub proto: crate::crypto::ProtoTag,
}

/// Проверить исходный порт по списку общей политики OpenWrt.
pub fn supports_destination_port(port: u16, configured_ports: &[u16]) -> bool {
    port != 80 && configured_ports.contains(&port)
}

/// Проверить исходный IP по CIDR общей политики OpenWrt.
pub fn is_telegram_destination(ip: IpAddr, cidrs: &[String]) -> bool {
    cidrs.iter().any(|cidr| cidr_contains(cidr, ip))
}

fn cidr_contains(cidr: &str, ip: IpAddr) -> bool {
    let (network_text, prefix_text) = cidr.split_once('/').unwrap_or((cidr, ""));
    let Ok(network) = network_text.parse::<IpAddr>() else {
        return false;
    };
    let prefix = if prefix_text.is_empty() {
        match network {
            IpAddr::V4(_) => 32,
            IpAddr::V6(_) => 128,
        }
    } else if let Ok(prefix) = prefix_text.parse::<u8>() {
        prefix
    } else {
        return false;
    };

    match (network, ip) {
        (IpAddr::V4(network), IpAddr::V4(ip)) if prefix <= 32 => {
            prefix_matches(&ip.octets(), &network.octets(), prefix)
        }
        (IpAddr::V6(network), IpAddr::V6(ip)) if prefix <= 128 => {
            prefix_matches(&ip.octets(), &network.octets(), prefix)
        }
        _ => false,
    }
}

fn prefix_matches(address: &[u8], network: &[u8], prefix: u8) -> bool {
    let full_bytes = usize::from(prefix / 8);
    let remaining_bits = prefix % 8;
    if address[..full_bytes] != network[..full_bytes] {
        return false;
    }
    if remaining_bits == 0 {
        return true;
    }
    let mask = u8::MAX << (8 - remaining_bits);
    address[full_bytes] & mask == network[full_bytes] & mask
}

/// Сохранить исходный порт при выборе TCP fallback-хоста.
pub fn tcp_fallback_target(host: &str, original: SocketAddr) -> (String, u16) {
    (host.to_string(), original.port())
}

pub fn dc_route_for_destination(ip: IpAddr) -> Option<(u32, bool)> {
    crate::config::default_dc_route_for_ip(ip)
}

/// Создать парные потоковые шифры прямого obfuscated2-соединения.
pub fn direct_stream_ciphers(init: &[u8; HANDSHAKE_LEN]) -> (AesCtr256, AesCtr256) {
    let key = &init[8..40];
    let iv = &init[40..56];
    let mut decrypt = make_cipher(key, iv);
    let mut encrypt = make_cipher(key, iv);
    let mut handshake = [0u8; HANDSHAKE_LEN];
    decrypt.apply_keystream(&mut handshake);
    encrypt.apply_keystream(&mut handshake);
    (decrypt, encrypt)
}

/// Получить исходный адрес назначения, сохранённый nftables REDIRECT.
pub fn original_destination(stream: &TcpStream) -> io::Result<SocketAddr> {
    #[cfg(target_os = "linux")]
    {
        let peer = stream.peer_addr()?;
        let mapped_v4 =
            matches!(peer, SocketAddr::V6(addr) if addr.ip().to_ipv4_mapped().is_some());
        if peer.is_ipv4() || mapped_v4 {
            match original_destination_v4(stream) {
                Ok(addr) => Ok(addr.into()),
                Err(v4_error) => original_destination_v6(stream).map_err(|_| v4_error),
            }
        } else {
            original_destination_v6(stream)
                .or_else(|_| original_destination_v4(stream).map(Into::into))
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = stream;
        Err(io::Error::new(
            io::ErrorKind::Unsupported,
            "для прозрачного режима в Linux требуется SO_ORIGINAL_DST",
        ))
    }
}

#[cfg(target_os = "linux")]
fn original_destination_v4(stream: &TcpStream) -> io::Result<SocketAddrV4> {
    let mut addr: libc::sockaddr_in = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::sockaddr_in>() as libc::socklen_t;
    // Значение SO_ORIGINAL_DST из linux/netfilter_ipv4.h.
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::SOL_IP,
            80,
            &mut addr as *mut _ as *mut libc::c_void,
            &mut len,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    if (addr.sin_family as libc::c_int) != libc::AF_INET {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "исходный адрес назначения не является IPv4",
        ));
    }
    Ok(SocketAddrV4::new(
        Ipv4Addr::from(u32::from_be(addr.sin_addr.s_addr)),
        u16::from_be(addr.sin_port),
    ))
}

#[cfg(target_os = "linux")]
fn original_destination_v6(stream: &TcpStream) -> io::Result<SocketAddr> {
    let mut addr: libc::sockaddr_in6 = unsafe { std::mem::zeroed() };
    let mut len = std::mem::size_of::<libc::sockaddr_in6>() as libc::socklen_t;
    // IP6T_SO_ORIGINAL_DST из linux/netfilter_ipv6/ip6_tables.h.
    let rc = unsafe {
        libc::getsockopt(
            stream.as_raw_fd(),
            libc::IPPROTO_IPV6,
            80,
            &mut addr as *mut _ as *mut libc::c_void,
            &mut len,
        )
    };
    if rc != 0 {
        return Err(io::Error::last_os_error());
    }
    if (addr.sin6_family as libc::c_int) != libc::AF_INET6 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "исходный адрес назначения не является IPv6",
        ));
    }
    Ok(SocketAddr::V6(SocketAddrV6::new(
        Ipv6Addr::from(addr.sin6_addr.s6_addr),
        u16::from_be(addr.sin6_port),
        addr.sin6_flowinfo,
        addr.sin6_scope_id,
    )))
}

/// Распознать obfuscated2; DC ID присутствует только в MTProxy-рукопожатии.
pub fn parse_client_init(init: &[u8; HANDSHAKE_LEN]) -> Option<ClientInit> {
    let mut decoded = *init;
    make_cipher(&init[8..40], &init[40..56]).apply_keystream(&mut decoded);
    let proto = ProtoTag::from_bytes(&decoded[PROTO_TAG_POS..PROTO_TAG_POS + 4])?;
    let dc_idx = i16::from_le_bytes([decoded[DC_IDX_POS], decoded[DC_IDX_POS + 1]]);
    let raw_dc = dc_idx.unsigned_abs() as u32;
    Some(ClientInit {
        dc: (1..=999).contains(&raw_dc).then_some(raw_dc),
        is_media: dc_idx < 0,
        proto,
    })
}

/// Разобрать рукопожатие, используя только секреты точных официальных DC-опций.
pub fn parse_client_init_with_secrets(
    init: &[u8; HANDSHAKE_LEN],
    secrets: &[Vec<u8>],
) -> Option<ClientInit> {
    if let Some(parsed) = parse_client_init(init) {
        return Some(parsed);
    }

    let mut parsed: Option<ClientInit> = None;
    for secret in secrets {
        let Some(handshake) = crate::crypto::parse_handshake(init, secret) else {
            continue;
        };
        let candidate = ClientInit {
            dc: (1..=999)
                .contains(&handshake.dc_id)
                .then_some(handshake.dc_id),
            is_media: handshake.is_media,
            proto: handshake.proto,
        };
        if let Some(previous) = &parsed {
            if previous.dc != candidate.dc
                || previous.is_media != candidate.is_media
                || previous.proto != candidate.proto
            {
                return None;
            }
        } else {
            parsed = Some(candidate);
        }
    }
    parsed
}
