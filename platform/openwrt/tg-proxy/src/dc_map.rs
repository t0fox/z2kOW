use std::collections::BTreeSet;
use std::fmt;
use std::fs::{self, File, OpenOptions};
use std::io::{self, Read, Write};
use std::net::IpAddr;
use std::path::{Path, PathBuf};
use std::sync::Arc;
use std::sync::RwLock;
use std::sync::atomic::{AtomicU64, Ordering};

use serde::{Deserialize, Serialize};

const CACHE_SCHEMA_VERSION: u32 = 1;
const CACHE_MAX_BYTES: u64 = 1024 * 1024;
const CACHE_MAX_OPTIONS: usize = 512;
const CACHE_MAX_AGE_SECS: i64 = 90 * 24 * 60 * 60;
const RETAIN_OLD_OPTION_SECS: i64 = 90 * 24 * 60 * 60;
const FUTURE_CLOCK_TOLERANCE_SECS: i64 = 5 * 60;

static TEMP_FILE_SEQUENCE: AtomicU64 = AtomicU64::new(0);

/// Одна запись `dcOption`, полученная из официального `help.getConfig`.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DcEndpoint {
    pub id: u32,
    pub address: IpAddr,
    pub port: u16,
    pub ipv6: bool,
    pub media_only: bool,
    pub tcpo_only: bool,
    pub cdn: bool,
    pub is_static: bool,
    pub this_port_only: bool,
    pub secret: Option<String>,
    pub last_seen: i64,
}

impl fmt::Debug for DcEndpoint {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DcEndpoint")
            .field("id", &self.id)
            .field("address", &self.address)
            .field("port", &self.port)
            .field("ipv6", &self.ipv6)
            .field("media_only", &self.media_only)
            .field("tcpo_only", &self.tcpo_only)
            .field("cdn", &self.cdn)
            .field("is_static", &self.is_static)
            .field("this_port_only", &self.this_port_only)
            .field("secret_present", &self.secret.is_some())
            .field("last_seen", &self.last_seen)
            .finish()
    }
}

/// Проверенная копия конфигурации DC с датой получения и исходным сроком действия.
#[derive(Clone, Eq, PartialEq, Serialize, Deserialize)]
#[serde(deny_unknown_fields)]
pub struct DcSnapshot {
    pub schema_version: u32,
    pub fetched_at: i64,
    pub config_date: i64,
    pub config_expires: i64,
    pub this_dc: u32,
    pub endpoints: Vec<DcEndpoint>,
}

impl fmt::Debug for DcSnapshot {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter
            .debug_struct("DcSnapshot")
            .field("schema_version", &self.schema_version)
            .field("fetched_at", &self.fetched_at)
            .field("config_date", &self.config_date)
            .field("config_expires", &self.config_expires)
            .field("this_dc", &self.this_dc)
            .field("endpoint_count", &self.endpoints.len())
            .finish()
    }
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RouteLookupError {
    AddressNotListed,
    PortNotAllowed,
    MediaFlagMismatch,
    DcMismatch,
    CdnEndpoint,
    Ambiguous,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum RouteMapSource {
    OfficialCache,
    BuiltInFallback,
}

impl RouteMapSource {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::OfficialCache => "официальный кэш help.getConfig",
            Self::BuiltInFallback => "встроенная точная резервная карта",
        }
    }
}

impl fmt::Display for RouteLookupError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        formatter.write_str(match self {
            Self::AddressNotListed => "адрес отсутствует в проверенной карте Telegram DC",
            Self::PortNotAllowed => "адрес разрешён только на другом порту",
            Self::MediaFlagMismatch => "признак media не совпадает с dcOption",
            Self::DcMismatch => "DC из рукопожатия не совпадает с dcOption",
            Self::CdnEndpoint => "адрес относится к CDN DC и не подходит для обычного MTProto",
            Self::Ambiguous => "для адреса найдено несколько несовместимых dcOption",
        })
    }
}

impl std::error::Error for RouteLookupError {}

/// Кэш с резервной точной картой для первого запуска и offline-режима.
pub struct DcMapStore {
    path: PathBuf,
    snapshot: RwLock<Option<Arc<DcSnapshot>>>,
}

/// Получить точные пары адрес/порт из проверенной карты для набора nft.
/// CDN включаются: Rust пропустит их только прямым TCP к исходному адресу.
pub fn endpoint_pairs(snapshot: &DcSnapshot, allowed_ports: &[u16]) -> Vec<(IpAddr, u16)> {
    let mut pairs = BTreeSet::new();
    for endpoint in &snapshot.endpoints {
        let ports = if endpoint.this_port_only {
            vec![endpoint.port]
        } else {
            allowed_ports.to_vec()
        };
        for port in ports {
            if port == 0
                || port == 80
                || !allowed_ports.contains(&port)
                || (endpoint.this_port_only && port != endpoint.port)
            {
                continue;
            }
            pairs.insert((endpoint.address, port));
        }
    }
    pairs.into_iter().collect()
}

/// Атомарно опубликовать проверенные пары для OpenWrt. Ошибка не меняет старый файл.
pub fn write_endpoint_manifest(
    path: &Path,
    snapshot: &DcSnapshot,
    allowed_ports: &[u16],
) -> Result<usize, String> {
    validate_snapshot(snapshot, unix_time())?;
    let pairs = endpoint_pairs(snapshot, allowed_ports);
    if pairs.is_empty() {
        return Err("в проверенной карте DC нет допустимых пар IP и TCP-порта".to_string());
    }
    let mut contents = format!(
        "z2k-tg-dc-options-v1 {} {}\n",
        snapshot.config_date, snapshot.fetched_at
    );
    for (address, port) in &pairs {
        contents.push_str(&format!("{address} {port}\n"));
    }
    atomic_write(path, contents.as_bytes())
        .map_err(|error| format!("не удалось атомарно сохранить пары для nft: {error}"))?;
    Ok(pairs.len())
}

impl DcMapStore {
    pub fn load(path: impl Into<PathBuf>) -> Self {
        let path = path.into();
        let now = unix_time();
        let snapshot = read_valid_snapshot(&path, now)
            .or_else(|| read_valid_snapshot(&last_good_path(&path), now))
            .map(Arc::new);
        Self {
            path,
            snapshot: RwLock::new(snapshot),
        }
    }

    pub fn without_cache(path: impl Into<PathBuf>) -> Self {
        Self {
            path: path.into(),
            snapshot: RwLock::new(None),
        }
    }

    pub fn current(&self) -> Option<Arc<DcSnapshot>> {
        self.snapshot
            .read()
            .ok()
            .and_then(|snapshot| snapshot.as_ref().map(Arc::clone))
    }

    /// Вернуть уникальные секреты точных TCP-only опций для разбора рукопожатия.
    pub fn handshake_secrets_for(&self, address: IpAddr, original_port: u16) -> Vec<Vec<u8>> {
        let Some(snapshot) = self.current() else {
            return Vec::new();
        };
        if unix_time().saturating_sub(snapshot.fetched_at) > CACHE_MAX_AGE_SECS {
            return Vec::new();
        }

        let mut secrets = Vec::new();
        for endpoint in snapshot.endpoints.iter().filter(|endpoint| {
            endpoint.address == address
                && endpoint.tcpo_only
                && (!endpoint.this_port_only || endpoint.port == original_port)
        }) {
            let Some(secret) = &endpoint.secret else {
                continue;
            };
            let Ok(secret) = hex::decode(secret) else {
                continue;
            };
            if !secrets.contains(&secret) {
                secrets.push(secret);
            }
        }
        secrets
    }

    pub fn refresh_due(&self, now: i64, refresh_secs: u64) -> bool {
        let Ok(snapshot) = self.snapshot.read() else {
            return true;
        };
        snapshot.as_ref().is_none_or(|cached| {
            now.saturating_sub(cached.fetched_at) >= refresh_secs.min(i64::MAX as u64) as i64
                || now >= cached.config_expires
        })
    }

    /// Точный поиск сначала использует последнюю проверенную конфигурацию,
    /// затем компактную встроенную карту. CIDR для назначения DC не применяется.
    pub fn resolve(
        &self,
        address: IpAddr,
        original_port: u16,
        media_hint: bool,
        dc_hint: Option<u32>,
    ) -> Result<DcEndpoint, RouteLookupError> {
        self.resolve_with_source(address, original_port, media_hint, dc_hint)
            .map(|(endpoint, _)| endpoint)
    }

    pub fn resolve_with_source(
        &self,
        address: IpAddr,
        original_port: u16,
        media_hint: bool,
        dc_hint: Option<u32>,
    ) -> Result<(DcEndpoint, RouteMapSource), RouteLookupError> {
        self.resolve_with_source_policy(address, original_port, media_hint, dc_hint, false)
    }

    /// Разрешает официальный CDN endpoint только для прозрачного TCP-маршрута.
    /// Обычный resolver остаётся закрытым для CDN, чтобы не направлять его через WSS.
    pub fn resolve_for_transparent_with_source(
        &self,
        address: IpAddr,
        original_port: u16,
        media_hint: bool,
        dc_hint: Option<u32>,
    ) -> Result<(DcEndpoint, RouteMapSource), RouteLookupError> {
        self.resolve_with_source_policy(address, original_port, media_hint, dc_hint, true)
    }

    fn resolve_with_source_policy(
        &self,
        address: IpAddr,
        original_port: u16,
        media_hint: bool,
        dc_hint: Option<u32>,
        allow_cdn: bool,
    ) -> Result<(DcEndpoint, RouteMapSource), RouteLookupError> {
        if let Some(snapshot) = self.current()
            && unix_time().saturating_sub(snapshot.fetched_at) <= CACHE_MAX_AGE_SECS
        {
            match lookup_endpoint_with_policy(
                &snapshot,
                address,
                original_port,
                media_hint,
                dc_hint,
                allow_cdn,
            ) {
                Ok(endpoint) => return Ok((endpoint, RouteMapSource::OfficialCache)),
                Err(RouteLookupError::AddressNotListed) => {}
                Err(error) => return Err(error),
            }
        }

        let (id, media_only) = crate::config::default_dc_route_for_ip(address)
            .ok_or(RouteLookupError::AddressNotListed)?;
        if media_only && !media_hint {
            return Err(RouteLookupError::MediaFlagMismatch);
        }
        if dc_hint.is_some_and(|hint| hint != id) {
            return Err(RouteLookupError::DcMismatch);
        }
        Ok((
            DcEndpoint {
                id,
                address,
                port: original_port,
                ipv6: address.is_ipv6(),
                media_only,
                tcpo_only: false,
                cdn: false,
                is_static: true,
                this_port_only: false,
                secret: None,
                last_seen: 0,
            },
            RouteMapSource::BuiltInFallback,
        ))
    }

    /// Принимает только полную, структурно корректную конфигурацию.
    /// Ошибка проверки или записи оставляет активную last-known-good карту нетронутой.
    pub fn install(&self, incoming: DcSnapshot, now: i64) -> Result<DcSnapshot, String> {
        validate_snapshot(&incoming, now)?;
        let previous = self.current();
        let merged = match previous.as_deref() {
            Some(previous) => merge_snapshots(previous, &incoming, now)?,
            None => incoming,
        };
        persist_snapshot(&self.path, previous.as_deref(), &merged)?;
        let mut current = self
            .snapshot
            .write()
            .map_err(|_| "не удалось заблокировать карту DC".to_string())?;
        *current = Some(Arc::new(merged.clone()));
        Ok(merged)
    }
}

pub fn lookup_endpoint(
    snapshot: &DcSnapshot,
    address: IpAddr,
    original_port: u16,
    media_hint: bool,
    dc_hint: Option<u32>,
) -> Result<DcEndpoint, RouteLookupError> {
    lookup_endpoint_with_policy(snapshot, address, original_port, media_hint, dc_hint, false)
}

fn lookup_endpoint_with_policy(
    snapshot: &DcSnapshot,
    address: IpAddr,
    original_port: u16,
    media_hint: bool,
    dc_hint: Option<u32>,
    allow_cdn: bool,
) -> Result<DcEndpoint, RouteLookupError> {
    let for_address: Vec<&DcEndpoint> = snapshot
        .endpoints
        .iter()
        .filter(|endpoint| endpoint.address == address)
        .collect();
    if for_address.is_empty() {
        return Err(RouteLookupError::AddressNotListed);
    }

    let for_port: Vec<&DcEndpoint> = for_address
        .iter()
        .copied()
        .filter(|endpoint| !endpoint.this_port_only || endpoint.port == original_port)
        .collect();
    if for_port.is_empty() {
        return Err(RouteLookupError::PortNotAllowed);
    }

    let for_media: Vec<&DcEndpoint> = for_port
        .iter()
        .copied()
        .filter(|endpoint| !endpoint.media_only || media_hint)
        .collect();
    if for_media.is_empty() {
        return Err(RouteLookupError::MediaFlagMismatch);
    }

    let for_dc: Vec<&DcEndpoint> = for_media
        .iter()
        .copied()
        .filter(|endpoint| dc_hint.is_none_or(|hint| endpoint.id == hint))
        .collect();
    if for_dc.is_empty() {
        return Err(RouteLookupError::DcMismatch);
    }

    let first = for_dc[0];
    if !allow_cdn && for_dc.iter().all(|endpoint| endpoint.cdn) {
        return Err(RouteLookupError::CdnEndpoint);
    }
    if for_dc.iter().any(|endpoint| {
        endpoint.id != first.id
            || endpoint.media_only != first.media_only
            || endpoint.cdn != first.cdn
    }) {
        return Err(RouteLookupError::Ambiguous);
    }

    let selected = for_dc
        .iter()
        .copied()
        .find(|endpoint| endpoint.this_port_only && endpoint.port == original_port)
        .unwrap_or(first);
    Ok(selected.clone())
}

pub fn validate_snapshot(snapshot: &DcSnapshot, now: i64) -> Result<(), String> {
    if snapshot.schema_version != CACHE_SCHEMA_VERSION {
        return Err("версия схемы кэша DC не поддерживается".to_string());
    }
    if snapshot.fetched_at <= 0 || snapshot.fetched_at > now + FUTURE_CLOCK_TOLERANCE_SECS {
        return Err("дата получения карты DC некорректна".to_string());
    }
    if snapshot.config_date <= 0 || snapshot.config_date > now + FUTURE_CLOCK_TOLERANCE_SECS {
        return Err("дата конфигурации Telegram некорректна".to_string());
    }
    if snapshot.config_expires <= snapshot.config_date || !(1..=999).contains(&snapshot.this_dc) {
        return Err("срок или текущий DC в конфигурации Telegram некорректны".to_string());
    }
    if snapshot.endpoints.is_empty() || snapshot.endpoints.len() > CACHE_MAX_OPTIONS {
        return Err("число адресов DC вне допустимого диапазона".to_string());
    }

    for endpoint in &snapshot.endpoints {
        if !(1..=999).contains(&endpoint.id) || endpoint.port == 0 {
            return Err("идентификатор DC или порт некорректен".to_string());
        }
        if endpoint.ipv6 != endpoint.address.is_ipv6() || !is_public_address(endpoint.address) {
            return Err("IP-адрес dcOption некорректен".to_string());
        }
        if endpoint.last_seen <= 0 || endpoint.last_seen > now + FUTURE_CLOCK_TOLERANCE_SECS {
            return Err("дата подтверждения адреса DC некорректна".to_string());
        }
        if endpoint.secret.as_ref().is_some_and(|secret| {
            secret.len() > 512 || secret.len() % 2 != 0 || hex::decode(secret).is_err()
        }) {
            return Err("секрет dcOption имеет неверный формат".to_string());
        }
    }

    if !has_primary_coverage(&snapshot.endpoints) {
        return Err("ответ help.getConfig неполный: отсутствует основной IPv4 DC".to_string());
    }
    Ok(())
}

pub fn merge_snapshots(
    previous: &DcSnapshot,
    incoming: &DcSnapshot,
    now: i64,
) -> Result<DcSnapshot, String> {
    validate_snapshot(incoming, now)?;
    if incoming.config_date < previous.config_date {
        return Err("ответ help.getConfig старше уже сохранённой конфигурации".to_string());
    }
    let mut merged = incoming.clone();

    for old in &previous.endpoints {
        let replaced_by_new_option = incoming.endpoints.iter().any(|new| {
            new.address == old.address
                && new.port == old.port
                && (new.id != old.id || new.media_only != old.media_only || new.cdn != old.cdn)
        });
        if replaced_by_new_option || now.saturating_sub(old.last_seen) > RETAIN_OLD_OPTION_SECS {
            continue;
        }
        if !merged
            .endpoints
            .iter()
            .any(|new| same_option_identity(new, old))
        {
            merged.endpoints.push(old.clone());
        }
    }

    merged.endpoints.sort_by_key(|endpoint| {
        (
            endpoint.id,
            endpoint.address,
            endpoint.port,
            endpoint.media_only,
            endpoint.cdn,
            endpoint.this_port_only,
        )
    });
    if merged.endpoints.len() > CACHE_MAX_OPTIONS {
        return Err("объединённая карта DC превышает допустимый размер".to_string());
    }
    Ok(merged)
}

fn has_primary_coverage(endpoints: &[DcEndpoint]) -> bool {
    (1..=5).all(|dc| {
        endpoints
            .iter()
            .any(|endpoint| endpoint.id == dc && !endpoint.media_only && !endpoint.cdn)
    })
}

fn same_option_identity(left: &DcEndpoint, right: &DcEndpoint) -> bool {
    left.id == right.id
        && left.address == right.address
        && left.port == right.port
        && left.ipv6 == right.ipv6
        && left.media_only == right.media_only
        && left.tcpo_only == right.tcpo_only
        && left.cdn == right.cdn
        && left.is_static == right.is_static
        && left.this_port_only == right.this_port_only
        && left.secret == right.secret
}

fn is_public_address(address: IpAddr) -> bool {
    match address {
        IpAddr::V4(ip) => {
            !ip.is_unspecified()
                && !ip.is_loopback()
                && !ip.is_private()
                && !ip.is_link_local()
                && !ip.is_multicast()
                && !ip.is_broadcast()
        }
        IpAddr::V6(ip) => {
            !ip.is_unspecified()
                && !ip.is_loopback()
                && !ip.is_unique_local()
                && !ip.is_unicast_link_local()
                && !ip.is_multicast()
        }
    }
}

fn read_valid_snapshot(path: &Path, now: i64) -> Option<DcSnapshot> {
    let metadata = fs::metadata(path).ok()?;
    if metadata.len() > CACHE_MAX_BYTES {
        return None;
    }
    let file = File::open(path).ok()?;
    let mut bytes = Vec::with_capacity(metadata.len() as usize);
    file.take(CACHE_MAX_BYTES + 1)
        .read_to_end(&mut bytes)
        .ok()?;
    if bytes.len() as u64 > CACHE_MAX_BYTES {
        return None;
    }
    let snapshot: DcSnapshot = serde_json::from_slice(&bytes).ok()?;
    validate_snapshot(&snapshot, now).ok()?;
    Some(snapshot)
}

fn persist_snapshot(
    path: &Path,
    previous: Option<&DcSnapshot>,
    incoming: &DcSnapshot,
) -> Result<(), String> {
    let encoded = serde_json::to_vec_pretty(incoming)
        .map_err(|error| format!("не удалось подготовить кэш DC: {error}"))?;
    let backup = last_good_path(path);
    if let Some(previous) = previous {
        let previous_bytes = serde_json::to_vec_pretty(previous)
            .map_err(|error| format!("не удалось подготовить last-known-good кэш DC: {error}"))?;
        atomic_write(&backup, &previous_bytes)
            .map_err(|error| format!("не удалось сохранить last-known-good кэш DC: {error}"))?;
    }
    atomic_write(path, &encoded)
        .map_err(|error| format!("не удалось атомарно сохранить кэш DC: {error}"))
}

fn last_good_path(path: &Path) -> PathBuf {
    PathBuf::from(format!("{}.last-good", path.display()))
}

fn atomic_write(path: &Path, bytes: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent)?;
    let name = path
        .file_name()
        .unwrap_or_else(|| std::ffi::OsStr::new("telegram-dc-map"))
        .to_string_lossy();
    let sequence = TEMP_FILE_SEQUENCE.fetch_add(1, Ordering::Relaxed);
    let temporary = parent.join(format!(".{name}.{}.{}.tmp", std::process::id(), sequence));
    let mut options = OpenOptions::new();
    options.write(true).create_new(true);
    #[cfg(unix)]
    {
        use std::os::unix::fs::OpenOptionsExt;
        options.mode(0o600);
    }
    let mut file = options.open(&temporary)?;
    let write_result = (|| {
        file.write_all(bytes)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)?;
        File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    write_result
}

fn unix_time() -> i64 {
    std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .map(|duration| duration.as_secs().min(i64::MAX as u64) as i64)
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use std::fs;
    use std::net::IpAddr;
    use std::path::PathBuf;
    use std::sync::Arc;
    use std::sync::atomic::{AtomicU64, Ordering};

    use super::{
        DcEndpoint, DcMapStore, DcSnapshot, RouteLookupError, endpoint_pairs, lookup_endpoint,
        merge_snapshots, unix_time, validate_snapshot, write_endpoint_manifest,
    };

    fn endpoint(
        id: u32,
        ip: &str,
        media_only: bool,
        cdn: bool,
        this_port_only: bool,
    ) -> DcEndpoint {
        DcEndpoint {
            id,
            address: ip.parse().unwrap(),
            port: 443,
            ipv6: ip.contains(':'),
            media_only,
            tcpo_only: true,
            cdn,
            is_static: true,
            this_port_only,
            secret: Some("aabbccdd".to_string()),
            last_seen: 1_797_000_000,
        }
    }

    fn complete(endpoints: Vec<DcEndpoint>) -> DcSnapshot {
        DcSnapshot {
            schema_version: 1,
            fetched_at: 1_797_000_000,
            config_date: 1_797_000_000,
            config_expires: 1_797_086_400,
            this_dc: 2,
            endpoints,
        }
    }

    fn primary_endpoints() -> Vec<DcEndpoint> {
        (1..=5)
            .map(|id| endpoint(id, &format!("149.154.160.{id}"), false, false, false))
            .collect()
    }

    fn endpoint_at(
        id: u32,
        ip: &str,
        media_only: bool,
        cdn: bool,
        this_port_only: bool,
        last_seen: i64,
    ) -> DcEndpoint {
        let mut endpoint = endpoint(id, ip, media_only, cdn, this_port_only);
        endpoint.last_seen = last_seen;
        endpoint
    }

    fn primary_endpoints_at(now: i64) -> Vec<DcEndpoint> {
        (1..=5)
            .map(|id| endpoint_at(id, &format!("149.154.160.{id}"), false, false, false, now))
            .collect()
    }

    fn current_complete(endpoints: Vec<DcEndpoint>) -> DcSnapshot {
        let now = unix_time();
        DcSnapshot {
            schema_version: 1,
            fetched_at: now,
            config_date: now,
            config_expires: now + 86_400,
            this_dc: 2,
            endpoints,
        }
    }

    #[test]
    fn nft_pairs_respect_endpoint_transport_and_port_flags() {
        let mut endpoints = primary_endpoints();
        let mut media = endpoint(2, "149.154.175.52", true, false, false);
        media.port = 443;
        endpoints.push(media);
        let mut exact_port = endpoint(2, "149.154.167.151", true, false, true);
        exact_port.port = 5222;
        endpoints.push(exact_port);
        endpoints.push(endpoint(2, "149.154.167.152", false, true, false));
        let mut tcp_only_without_secret = endpoint(3, "149.154.167.153", false, false, false);
        tcp_only_without_secret.secret = None;
        endpoints.push(tcp_only_without_secret);
        let mut ipv6 = endpoint(4, "2001:db8::4", false, false, false);
        ipv6.tcpo_only = false;
        ipv6.secret = None;
        endpoints.push(ipv6);
        let mut http = endpoint(5, "149.154.167.155", false, false, true);
        http.port = 80;
        endpoints.push(http);

        let pairs = endpoint_pairs(&complete(endpoints), &[80, 443, 5222]);
        assert!(pairs.contains(&("149.154.175.52".parse().unwrap(), 443)));
        assert!(pairs.contains(&("149.154.175.52".parse().unwrap(), 5222)));
        assert!(pairs.contains(&("149.154.167.151".parse().unwrap(), 5222)));
        assert!(!pairs.contains(&("149.154.167.151".parse().unwrap(), 443)));
        assert!(pairs.contains(&("149.154.167.152".parse().unwrap(), 443)));
        assert!(pairs.contains(&("149.154.167.152".parse().unwrap(), 5222)));
        assert!(pairs.contains(&("149.154.167.153".parse().unwrap(), 443)));
        assert!(pairs.contains(&("2001:db8::4".parse().unwrap(), 443)));
        assert!(!pairs.iter().any(|(_, port)| *port == 80));
    }

    #[test]
    fn endpoint_manifest_is_atomic_and_keeps_last_good_on_invalid_policy() {
        let directory = test_directory("endpoint-manifest");
        let path = directory.join("telegram-dc-endpoints.tsv");
        let snapshot = current_complete(primary_endpoints_at(unix_time()));
        let count = write_endpoint_manifest(&path, &snapshot, &[443, 5222]).unwrap();
        let previous = fs::read_to_string(&path).unwrap();
        assert_eq!(count, 10);
        assert!(previous.starts_with("z2k-tg-dc-options-v1 "));
        assert!(previous.contains("149.154.160.1 443\n"));
        assert!(write_endpoint_manifest(&path, &snapshot, &[80]).is_err());
        assert_eq!(fs::read_to_string(&path).unwrap(), previous);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn unlisted_observed_endpoints_stay_fail_closed() {
        let directory = test_directory("unlisted-observed");
        let store = DcMapStore::without_cache(directory.join("map.json"));
        let now = unix_time();
        store
            .install(current_complete(primary_endpoints_at(now)), now)
            .unwrap();

        for address in ["149.154.167.43", "91.108.56.137"] {
            for media_hint in [false, true] {
                assert_eq!(
                    store.resolve(address.parse().unwrap(), 5222, media_hint, None),
                    Err(RouteLookupError::AddressNotListed),
                    "адрес {address} вне проверенной карты не должен получать назначение DC"
                );
            }
        }

        fs::remove_dir_all(directory).unwrap();
    }

    fn test_directory(label: &str) -> PathBuf {
        static NEXT: AtomicU64 = AtomicU64::new(0);
        let directory = std::env::temp_dir().join(format!(
            "tg-dc-map-{label}-{}-{}",
            std::process::id(),
            NEXT.fetch_add(1, Ordering::Relaxed)
        ));
        fs::create_dir_all(&directory).unwrap();
        directory
    }

    #[test]
    fn current_reads_share_the_immutable_snapshot_generation() {
        let directory = test_directory("shared-snapshot");
        let store = DcMapStore::without_cache(directory.join("map.json"));
        let now = unix_time();
        let first_snapshot = current_complete(primary_endpoints_at(now));
        store.install(first_snapshot.clone(), now).unwrap();

        let first = store.current().unwrap();
        let second = store.current().unwrap();
        assert!(Arc::ptr_eq(&first, &second));

        let mut next_snapshot = first_snapshot;
        next_snapshot.fetched_at = now + 1;
        next_snapshot.config_date = now + 1;
        store.install(next_snapshot, now + 1).unwrap();
        let next = store.current().unwrap();

        assert!(!Arc::ptr_eq(&first, &next));
        assert_eq!(first.config_date, now);
        assert_eq!(next.config_date, now + 1);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn corrupted_primary_cache_loads_last_known_good_copy() {
        let directory = test_directory("lkg");
        let path = directory.join("map.json");
        let backup = PathBuf::from(format!("{}.last-good", path.display()));
        let now = unix_time();
        let mut endpoints = primary_endpoints_at(now);
        endpoints.push(endpoint_at(2, "149.154.167.43", false, false, false, now));
        let snapshot = current_complete(endpoints);
        fs::write(&path, b"{").unwrap();
        fs::write(&backup, serde_json::to_vec(&snapshot).unwrap()).unwrap();

        let store = DcMapStore::load(&path);
        assert_eq!(store.current().as_deref(), Some(&snapshot));
        assert_eq!(
            store
                .resolve("149.154.167.43".parse().unwrap(), 5222, false, Some(2))
                .unwrap()
                .id,
            2
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn refresh_persists_new_map_and_keeps_previous_verified_copy() {
        let directory = test_directory("persist");
        let path = directory.join("map.json");
        let store = DcMapStore::without_cache(&path);
        let now = unix_time();
        let first = current_complete(primary_endpoints_at(now));
        store.install(first.clone(), now).unwrap();

        let mut changed = first.clone();
        changed.fetched_at = now + 1;
        changed.config_date = now + 1;
        changed.config_expires = now + 86_401;
        changed.endpoints.push(endpoint_at(
            2,
            "149.154.167.43",
            false,
            false,
            false,
            now + 1,
        ));
        let installed = store.install(changed, now + 1).unwrap();
        let primary: DcSnapshot = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let last_good: DcSnapshot = serde_json::from_slice(
            &fs::read(PathBuf::from(format!("{}.last-good", path.display()))).unwrap(),
        )
        .unwrap();
        assert_eq!(primary, installed);
        assert_eq!(last_good, first);
        #[cfg(unix)]
        {
            use std::os::unix::fs::PermissionsExt;
            assert_eq!(
                fs::metadata(&path).unwrap().permissions().mode() & 0o777,
                0o600
            );
        }
        assert!(fs::read_dir(&directory).unwrap().all(|entry| {
            !entry
                .unwrap()
                .file_name()
                .to_string_lossy()
                .ends_with(".tmp")
        }));
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn dynamic_lookup_uses_the_official_dc_and_preserves_non_fixed_port() {
        let mut endpoints = primary_endpoints();
        endpoints.push(endpoint(2, "149.154.167.43", false, false, false));
        let snapshot = complete(endpoints);

        let route = lookup_endpoint(
            &snapshot,
            "149.154.167.43".parse().unwrap(),
            5222,
            false,
            None,
        )
        .unwrap();

        assert_eq!(route.id, 2);
        assert_eq!(route.port, 443);
        assert_eq!(route.address, "149.154.167.43".parse::<IpAddr>().unwrap());
    }

    #[test]
    fn media_route_can_use_a_regular_dc_option() {
        let mut endpoints = primary_endpoints();
        endpoints.push(endpoint(2, "149.154.167.51", false, false, false));
        let snapshot = complete(endpoints);

        let route = lookup_endpoint(
            &snapshot,
            "149.154.167.51".parse().unwrap(),
            443,
            true,
            Some(2),
        )
        .unwrap();

        assert_eq!(route.id, 2);
        assert!(!route.media_only);
        assert!(!route.cdn);
    }

    #[test]
    fn media_route_can_use_a_regular_builtin_fallback() {
        let directory = test_directory("media-fallback");
        let store = DcMapStore::without_cache(directory.join("map.json"));

        let route = store
            .resolve("149.154.167.51".parse().unwrap(), 443, true, Some(2))
            .unwrap();

        assert_eq!(route.id, 2);
        assert!(!route.media_only);
        assert!(!route.cdn);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn resolution_reports_official_or_exact_fallback_source() {
        let directory = test_directory("source");
        let path = directory.join("map.json");
        let store = DcMapStore::without_cache(&path);

        let (fallback, source) = store
            .resolve_with_source("149.154.167.51".parse().unwrap(), 443, false, Some(2))
            .unwrap();
        assert_eq!(fallback.id, 2);
        assert_eq!(source, super::RouteMapSource::BuiltInFallback);

        let now = unix_time();
        let mut endpoints = primary_endpoints_at(now);
        endpoints.push(endpoint_at(2, "149.154.167.43", false, false, false, now));
        store.install(current_complete(endpoints), now).unwrap();
        let (official, source) = store
            .resolve_with_source("149.154.167.43".parse().unwrap(), 5222, false, Some(2))
            .unwrap();
        assert_eq!(official.id, 2);
        assert_eq!(source, super::RouteMapSource::OfficialCache);

        assert!(
            store
                .resolve_with_source("149.154.167.44".parse().unwrap(), 443, false, Some(2))
                .is_err()
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn handshake_secrets_are_scoped_to_exact_address_port_and_tcpo_only() {
        let directory = test_directory("handshake-secret");
        let store = DcMapStore::without_cache(directory.join("map.json"));
        let now = unix_time();
        let mut endpoints = primary_endpoints_at(now);
        let mut secret_endpoint = endpoint_at(2, "149.154.167.151", true, false, true, now);
        secret_endpoint.port = 5222;
        secret_endpoint.secret = Some("aabbccdd".to_string());
        endpoints.push(secret_endpoint.clone());
        endpoints.push(secret_endpoint);
        let mut non_tcp_option = endpoint_at(1, "149.154.175.52", true, false, true, now);
        non_tcp_option.port = 5222;
        non_tcp_option.tcpo_only = false;
        endpoints.push(non_tcp_option);
        let mut cdn_option = endpoint_at(3, "149.154.175.102", false, true, true, now);
        cdn_option.port = 5222;
        endpoints.push(cdn_option);
        store.install(current_complete(endpoints), now).unwrap();

        assert_eq!(
            store.handshake_secrets_for("149.154.167.151".parse().unwrap(), 5222),
            [vec![0xaa, 0xbb, 0xcc, 0xdd]],
            "секрет берётся из точной TCP-only опции и дубликат удаляется"
        );
        assert!(
            store
                .handshake_secrets_for("149.154.167.151".parse().unwrap(), 443)
                .is_empty(),
            "опция только для порта 5222 не применяется к порту 443"
        );
        assert!(
            store
                .handshake_secrets_for("149.154.175.52".parse().unwrap(), 5222)
                .is_empty(),
            "секрет без признака TCP-only не применяется к обфускации"
        );
        assert_eq!(
            store.handshake_secrets_for("149.154.175.102".parse().unwrap(), 5222),
            [vec![0xaa, 0xbb, 0xcc, 0xdd]],
            "секрет TCP-only CDN применяется только к точному официальному адресу и порту"
        );

        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn this_port_only_rejects_another_original_port() {
        let mut endpoints = primary_endpoints();
        endpoints.push(endpoint(2, "149.154.167.43", false, false, true));
        let snapshot = complete(endpoints);

        assert!(
            lookup_endpoint(
                &snapshot,
                "149.154.167.43".parse().unwrap(),
                5222,
                false,
                None,
            )
            .is_err()
        );
    }

    #[test]
    fn media_only_and_cdn_remain_separate_flags() {
        let mut endpoints = primary_endpoints();
        endpoints.push(endpoint(2, "149.154.167.43", true, false, false));
        endpoints.push(endpoint(203, "91.105.192.203", false, true, false));
        let snapshot = complete(endpoints);

        let media = lookup_endpoint(
            &snapshot,
            "149.154.167.43".parse().unwrap(),
            443,
            true,
            Some(2),
        )
        .unwrap();
        let cdn = snapshot
            .endpoints
            .iter()
            .find(|endpoint| endpoint.cdn)
            .unwrap();

        assert!(media.media_only);
        assert!(!media.cdn);
        assert!(!cdn.media_only);
        assert!(cdn.cdn);
    }

    #[test]
    fn cdn_only_option_is_rejected_for_transparent_mtproto() {
        let mut endpoints = primary_endpoints();
        endpoints.push(endpoint(203, "91.105.192.203", false, true, false));
        let snapshot = complete(endpoints);

        let result = lookup_endpoint(
            &snapshot,
            "91.105.192.203".parse().unwrap(),
            443,
            false,
            Some(203),
        );

        assert!(
            result.is_err(),
            "CDN-only dcOption нельзя направлять в обычный MTProto DC"
        );
    }

    #[test]
    fn transparent_cdn_lookup_requires_an_exact_official_option() {
        let directory = test_directory("transparent-cdn");
        let now = unix_time();
        let mut endpoints = primary_endpoints_at(now);
        let mut cdn = endpoint_at(203, "91.105.192.203", false, true, true, now);
        cdn.port = 443;
        endpoints.push(cdn);
        let store = DcMapStore::without_cache(directory.join("map.json"));
        store.install(current_complete(endpoints), now).unwrap();

        assert_eq!(
            store.resolve_with_source("91.105.192.203".parse().unwrap(), 443, true, Some(203)),
            Err(RouteLookupError::CdnEndpoint),
            "обычный resolver сохраняет запрет CDN для WSS"
        );
        let (route, source) = store
            .resolve_for_transparent_with_source(
                "91.105.192.203".parse().unwrap(),
                443,
                true,
                Some(203),
            )
            .unwrap();
        assert!(route.cdn);
        assert_eq!(route.id, 203);
        assert_eq!(source, super::RouteMapSource::OfficialCache);
        assert_eq!(
            store.resolve_for_transparent_with_source(
                "91.105.192.203".parse().unwrap(),
                443,
                true,
                Some(2),
            ),
            Err(RouteLookupError::DcMismatch)
        );
        assert_eq!(
            store.resolve_for_transparent_with_source(
                "91.105.192.203".parse().unwrap(),
                5222,
                true,
                Some(203),
            ),
            Err(RouteLookupError::PortNotAllowed)
        );
        assert_eq!(
            store.resolve_for_transparent_with_source(
                "91.105.192.204".parse().unwrap(),
                443,
                true,
                Some(203),
            ),
            Err(RouteLookupError::AddressNotListed)
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn an_explicit_dc_hint_must_match_the_exact_endpoint() {
        let mut endpoints = primary_endpoints();
        endpoints.push(endpoint(2, "149.154.167.43", false, false, false));
        let snapshot = complete(endpoints);

        assert!(
            lookup_endpoint(
                &snapshot,
                "149.154.167.43".parse().unwrap(),
                443,
                false,
                Some(4),
            )
            .is_err()
        );
    }

    #[test]
    fn incomplete_refresh_keeps_the_last_known_good_entries() {
        let old = complete(primary_endpoints());
        let partial = complete(vec![endpoint(2, "149.154.167.43", false, false, false)]);

        let result = merge_snapshots(&old, &partial, old.fetched_at + 60);

        assert!(result.is_err());
        assert_eq!(old.endpoints.len(), 5);
        validate_snapshot(&old, old.fetched_at).unwrap();
    }

    #[test]
    fn older_config_date_preserves_last_known_good() {
        let directory = test_directory("stale-config");
        let path = directory.join("map.json");
        let backup = PathBuf::from(format!("{}.last-good", path.display()));
        let store = DcMapStore::without_cache(&path);
        let now = unix_time();

        let first = current_complete(primary_endpoints_at(now));
        store.install(first.clone(), now).unwrap();

        let mut newer = first.clone();
        newer.fetched_at = now + 1;
        newer.config_date = now + 1;
        newer.config_expires = now + 86_401;
        newer.endpoints.push(endpoint_at(
            2,
            "149.154.167.43",
            false,
            false,
            false,
            now + 1,
        ));
        let newer = store.install(newer, now + 1).unwrap();
        let previous_last_good: DcSnapshot =
            serde_json::from_slice(&fs::read(&backup).unwrap()).unwrap();

        let mut stale = current_complete(primary_endpoints_at(now + 2));
        stale.config_date = now;
        let result = store.install(stale, now + 2);

        assert!(
            result.is_err(),
            "устаревшая конфигурация должна быть отклонена"
        );
        assert_eq!(store.current().as_deref(), Some(&newer));
        let cached: DcSnapshot = serde_json::from_slice(&fs::read(&path).unwrap()).unwrap();
        let last_good: DcSnapshot = serde_json::from_slice(&fs::read(&backup).unwrap()).unwrap();
        assert_eq!(cached, newer);
        assert_eq!(last_good, previous_last_good);
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn valid_refresh_merges_region_specific_addresses_without_dropping_old_ones() {
        let old = complete(primary_endpoints());
        let mut endpoints = primary_endpoints();
        endpoints.push(endpoint(2, "149.154.167.43", false, false, false));
        let new = complete(endpoints);

        let merged = merge_snapshots(&old, &new, old.fetched_at + 60).unwrap();

        assert!(
            merged
                .endpoints
                .iter()
                .any(|entry| { entry.address == "149.154.167.43".parse::<IpAddr>().unwrap() })
        );
        assert_eq!(merged.endpoints.len(), 6);
    }
}
