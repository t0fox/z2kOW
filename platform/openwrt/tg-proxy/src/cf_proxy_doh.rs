use std::collections::HashMap;
use std::future::Future;
use std::net::IpAddr;
use std::sync::{Arc, LazyLock, Mutex};
use std::time::{Duration, Instant};

use futures_util::stream::{FuturesUnordered, StreamExt};
use tokio::sync::Mutex as AsyncMutex;

use crate::default_domains::http::https_get_to_ip;
use crate::default_domains::valid_domain;
use crate::outbound::OutboundConnector;

const DOH_TIMEOUT: Duration = Duration::from_secs(2);
const CF_DNS_TIMEOUT: Duration = Duration::from_millis(500);
const CF_DNS_CACHE_TTL: Duration = Duration::from_secs(60);
const MAX_CF_DNS_CACHE_ENTRIES: usize = 256;
type CachedCfIpLists = HashMap<String, (Vec<IpAddr>, Instant)>;
type CfDomainLocks = HashMap<String, Arc<AsyncMutex<()>>>;

struct DohEndpoint {
    host: &'static str,
    ip: &'static str,
}

const DOH_ENDPOINTS: &[DohEndpoint] = &[
    DohEndpoint {
        host: "cloudflare-dns.com",
        ip: "1.1.1.1",
    },
    DohEndpoint {
        host: "dns.google",
        ip: "8.8.8.8",
    },
];

static CF_IP_LIST_CACHE: LazyLock<Mutex<CachedCfIpLists>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static CF_IP_LOCKS: LazyLock<Mutex<CfDomainLocks>> = LazyLock::new(|| Mutex::new(HashMap::new()));

#[cfg(test)]
fn clear_cf_ip(domain: &str) {
    CF_IP_LIST_CACHE
        .lock()
        .expect("CF DNS list cache lock poisoned")
        .remove(domain);
}

/// Получить ограниченный набор IPv4/IPv6 адресов CF/Worker домена.
/// Системный DNS пробуется первым, DoH используется только как резерв.
pub(crate) async fn resolve_cf_ips(
    domain: &str,
    outbound: &OutboundConnector,
) -> Result<Vec<IpAddr>, String> {
    let system_domain = domain.to_string();
    let doh_domain = domain.to_string();
    resolve_cf_ips_with(
        domain,
        move || async move {
            let addresses = tokio::net::lookup_host((system_domain.as_str(), 443))
                .await
                .ok()?;
            let values = addresses.map(|address| address.ip()).collect::<Vec<_>>();
            (!values.is_empty()).then_some(values)
        },
        || async move { resolve_doh_ips(&doh_domain, outbound).await },
    )
    .await
    .ok_or_else(|| format!("не удалось разрешить CF-хост {domain} через системный DNS и DoH"))
}

async fn resolve_cf_ips_with<S, SFut, D, DFut>(
    domain: &str,
    system_lookup: S,
    doh_lookup: D,
) -> Option<Vec<IpAddr>>
where
    S: FnOnce() -> SFut,
    SFut: Future<Output = Option<Vec<IpAddr>>>,
    D: FnOnce() -> DFut,
    DFut: Future<Output = Option<Vec<IpAddr>>>,
{
    resolve_cf_ips_with_timeouts(
        domain,
        system_lookup,
        doh_lookup,
        CF_DNS_TIMEOUT,
        DOH_TIMEOUT,
    )
    .await
}

async fn resolve_cf_ips_with_timeouts<S, SFut, D, DFut>(
    domain: &str,
    system_lookup: S,
    doh_lookup: D,
    system_timeout: Duration,
    doh_timeout: Duration,
) -> Option<Vec<IpAddr>>
where
    S: FnOnce() -> SFut,
    SFut: Future<Output = Option<Vec<IpAddr>>>,
    D: FnOnce() -> DFut,
    DFut: Future<Output = Option<Vec<IpAddr>>>,
{
    if !valid_domain(domain) {
        return None;
    }
    if let Some(ips) = cached_cf_ips(domain) {
        return Some(ips);
    }
    let domain_lock = domain_resolution_lock(domain);
    let _single_flight = domain_lock.lock().await;
    if let Some(ips) = cached_cf_ips(domain) {
        return Some(ips);
    }

    let mut ips = tokio::time::timeout(system_timeout, system_lookup())
        .await
        .ok()
        .flatten()
        .unwrap_or_default();
    ips.retain(is_usable_edge_ip);
    if ips.is_empty() {
        ips = tokio::time::timeout(doh_timeout, doh_lookup())
            .await
            .ok()
            .flatten()
            .unwrap_or_default();
        ips.retain(is_usable_edge_ip);
    }
    ips.sort_by_key(|ip| match ip {
        IpAddr::V4(_) => 0,
        IpAddr::V6(_) => 1,
    });
    ips.dedup();
    ips.truncate(8);
    if ips.is_empty() {
        return None;
    }
    cache_cf_ips(domain, ips.clone(), CF_DNS_CACHE_TTL);
    Some(ips)
}

fn domain_resolution_lock(domain: &str) -> Arc<AsyncMutex<()>> {
    let mut locks = CF_IP_LOCKS.lock().expect("CF DNS lock map poisoned");
    retain_active_domain_locks(&mut locks);
    if let Some(lock) = locks.get(domain) {
        return Arc::clone(lock);
    }
    let lock = Arc::new(AsyncMutex::new(()));
    if locks.len() < MAX_CF_DNS_CACHE_ENTRIES {
        locks.insert(domain.to_string(), Arc::clone(&lock));
    }
    lock
}

fn retain_active_domain_locks(locks: &mut CfDomainLocks) {
    locks.retain(|_, lock| Arc::strong_count(lock) > 1);
}

fn cached_cf_ips(domain: &str) -> Option<Vec<IpAddr>> {
    let mut cache = CF_IP_LIST_CACHE
        .lock()
        .expect("CF DNS list cache lock poisoned");
    cache.retain(|_, (_, expires_at)| Instant::now() < *expires_at);
    cache.get(domain).map(|(ips, _)| ips.clone())
}

fn cache_cf_ips(domain: &str, ips: Vec<IpAddr>, ttl: Duration) {
    let mut cache = CF_IP_LIST_CACHE
        .lock()
        .expect("CF DNS list cache lock poisoned");
    cache.retain(|_, (_, expires_at)| Instant::now() < *expires_at);
    while cache.len() >= MAX_CF_DNS_CACHE_ENTRIES && !cache.contains_key(domain) {
        let Some(oldest) = cache
            .iter()
            .min_by_key(|(_, (_, expires_at))| *expires_at)
            .map(|(key, _)| key.clone())
        else {
            break;
        };
        cache.remove(&oldest);
    }
    cache.insert(domain.to_string(), (ips, Instant::now() + ttl));
}

fn is_usable_edge_ip(ip: &IpAddr) -> bool {
    match ip {
        IpAddr::V4(ip) => {
            !ip.is_private()
                && !ip.is_loopback()
                && !ip.is_link_local()
                && !ip.is_broadcast()
                && !ip.is_unspecified()
                && !ip.is_multicast()
                && !((ip.octets()[0] == 100) && (64..=127).contains(&ip.octets()[1]))
        }
        IpAddr::V6(ip) => {
            !ip.is_loopback()
                && !ip.is_unspecified()
                && !ip.is_multicast()
                && !ip.is_unicast_link_local()
                && !((ip.segments()[0] & 0xfe00) == 0xfc00)
        }
    }
}

fn doh_answers(body: &[u8]) -> Vec<IpAddr> {
    let Ok(response) = serde_json::from_slice::<serde_json::Value>(body) else {
        return Vec::new();
    };
    if response.get("Status").and_then(serde_json::Value::as_u64) != Some(0) {
        return Vec::new();
    }
    let Some(answers) = response.get("Answer").and_then(serde_json::Value::as_array) else {
        return Vec::new();
    };
    let mut result = Vec::new();
    for answer in answers {
        let record_type = answer.get("type").and_then(serde_json::Value::as_u64);
        let address = answer
            .get("data")
            .and_then(serde_json::Value::as_str)
            .and_then(|value| value.parse::<IpAddr>().ok());
        match (record_type, address) {
            (Some(1), Some(ip @ IpAddr::V4(_))) | (Some(28), Some(ip @ IpAddr::V6(_))) => {
                if is_usable_edge_ip(&ip) && !result.contains(&ip) {
                    result.push(ip);
                }
            }
            _ => continue,
        }
    }
    result
}

async fn query_endpoint(
    endpoint: &'static DohEndpoint,
    domain: &str,
    record_type: &'static str,
    outbound: &OutboundConnector,
) -> Option<Vec<IpAddr>> {
    let path = format!("/dns-query?name={domain}&type={record_type}");
    let body = tokio::time::timeout(
        DOH_TIMEOUT,
        https_get_to_ip(
            endpoint.ip,
            endpoint.host,
            &path,
            &[("Accept", "application/dns-json")],
            outbound,
        ),
    )
    .await
    .ok()?
    .ok()?;
    Some(doh_answers(body.as_bytes()))
}

async fn resolve_doh_ips(domain: &str, outbound: &OutboundConnector) -> Option<Vec<IpAddr>> {
    let domain = domain.trim();
    if !valid_domain(domain) {
        return None;
    }
    let mut queries = FuturesUnordered::new();
    for endpoint in DOH_ENDPOINTS {
        queries.push(query_endpoint(endpoint, domain, "A", outbound));
        queries.push(query_endpoint(endpoint, domain, "AAAA", outbound));
    }
    let ips = tokio::time::timeout(DOH_TIMEOUT, async {
        let mut ips = Vec::new();
        while let Some(answer) = queries.next().await {
            if let Some(answer) = answer {
                for ip in answer {
                    if is_usable_edge_ip(&ip) && !ips.contains(&ip) {
                        ips.push(ip);
                    }
                }
            }
        }
        (!ips.is_empty()).then_some(ips)
    })
    .await
    .ok()??;

    Some(ips)
}

#[cfg(test)]
mod tests {
    use std::net::IpAddr;
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use std::time::Duration;

    use super::{
        CfDomainLocks, cache_cf_ips, cached_cf_ips, clear_cf_ip, doh_answers, resolve_cf_ips_with,
        resolve_cf_ips_with_timeouts, retain_active_domain_locks,
    };

    #[test]
    fn doh_собирает_ipv4_и_ipv6_и_отвергает_ошибочный_status() {
        let body = br#"{"Status":0,"Answer":[{"name":"edge.example","type":28,"TTL":120,"data":"2606:4700:4700::1111"},{"name":"edge.example","type":1,"TTL":120,"data":"104.21.75.42"},{"name":"edge.example","type":16,"TTL":120,"data":"text"}]}"#;
        assert_eq!(
            doh_answers(body)
                .iter()
                .map(ToString::to_string)
                .collect::<Vec<_>>(),
            ["2606:4700:4700::1111", "104.21.75.42"]
        );
        assert!(doh_answers(br#"{"Status":2,"Answer":[]}"#).is_empty());
    }

    #[tokio::test]
    async fn doh_отклоняет_некорректное_имя_до_сетевого_запроса() {
        let result = resolve_cf_ips_with(
            "edge.example?name=evil",
            || async {
                panic!("некорректное имя не должно вызывать системный DNS")
            },
            || async {
                panic!("некорректное имя не должно вызывать DoH")
            },
        )
        .await;
        assert!(result.is_none());
    }

    #[test]
    fn cf_dns_cache_хранит_список_адресов_и_очищается() {
        let domain = "kws2.cache-check.example";
        let addresses = [
            "188.114.97.1".parse().unwrap(),
            "2606:4700::1".parse().unwrap(),
        ];
        cache_cf_ips(domain, addresses.to_vec(), Duration::from_secs(60));

        assert_eq!(cached_cf_ips(domain), Some(addresses.to_vec()));

        clear_cf_ip(domain);
        assert!(cached_cf_ips(domain).is_none());
    }

    #[tokio::test]
    async fn cf_dns_сохраняет_несколько_системных_адресов_и_не_вызывает_doh() {
        let domain = "kws2.system-dns.example";
        let doh_calls = Arc::new(AtomicUsize::new(0));
        let doh_calls_for_lookup = Arc::clone(&doh_calls);

        let result = resolve_cf_ips_with(
            domain,
            || async {
                Some(vec![
                    "2606:4700:4700::1111".parse().unwrap(),
                    "104.21.75.42".parse().unwrap(),
                    "127.0.0.1".parse().unwrap(),
                    "104.21.75.42".parse().unwrap(),
                ])
            },
            move || async move {
                doh_calls_for_lookup.fetch_add(1, Ordering::Relaxed);
                Some(vec!["188.114.97.1".parse().unwrap()])
            },
        )
        .await;

        assert_eq!(
            result.unwrap(),
            [
                "104.21.75.42".parse::<IpAddr>().unwrap(),
                "2606:4700:4700::1111".parse::<IpAddr>().unwrap()
            ]
        );
        assert_eq!(doh_calls.load(Ordering::Relaxed), 0);
        clear_cf_ip(domain);
    }

    #[tokio::test]
    async fn cf_dns_переходит_на_doh_если_системные_адреса_непригодны() {
        let domain = "kws2.doh-fallback.example";
        clear_cf_ip(domain);
        let system_calls = Arc::new(AtomicUsize::new(0));
        let doh_calls = Arc::new(AtomicUsize::new(0));
        let system_calls_for_lookup = Arc::clone(&system_calls);
        let doh_calls_for_lookup = Arc::clone(&doh_calls);

        let result = resolve_cf_ips_with(
            domain,
            move || async move {
                system_calls_for_lookup.fetch_add(1, Ordering::Relaxed);
                Some(vec!["10.0.0.8".parse().unwrap()])
            },
            move || async move {
                doh_calls_for_lookup.fetch_add(1, Ordering::Relaxed);
                Some(vec!["188.114.97.1".parse().unwrap()])
            },
        )
        .await;

        assert_eq!(result.unwrap(), ["188.114.97.1".parse::<IpAddr>().unwrap()]);
        assert_eq!(system_calls.load(Ordering::Relaxed), 1);
        assert_eq!(doh_calls.load(Ordering::Relaxed), 1);
        clear_cf_ip(domain);
    }

    #[tokio::test]
    async fn cf_dns_timeout_системного_resolver_переходит_на_doh() {
        let domain = "kws2.timeout-fallback.example";
        clear_cf_ip(domain);
        let result = tokio::time::timeout(
            Duration::from_millis(200),
            resolve_cf_ips_with_timeouts(
                domain,
                || async { std::future::pending::<Option<Vec<IpAddr>>>().await },
                || async { Some(vec!["188.114.97.1".parse().unwrap()]) },
                Duration::from_millis(10),
                Duration::from_millis(50),
            ),
        )
        .await
        .expect("тайм-аут DNS не должен блокировать резервный DoH");

        assert_eq!(result, Some(vec!["188.114.97.1".parse().unwrap()]));
        clear_cf_ip(domain);
    }

    #[tokio::test]
    async fn cf_dns_после_истечения_ttl_заменяет_устаревший_ip() {
        let domain = "kws2.changed-edge.example";
        clear_cf_ip(domain);
        let old_ip = "188.114.97.1".parse().unwrap();
        let new_ip = "188.114.97.2".parse().unwrap();
        cache_cf_ips(domain, vec![old_ip], Duration::from_millis(1));
        tokio::time::sleep(Duration::from_millis(5)).await;

        let result = resolve_cf_ips_with(
            domain,
            || async { Some(vec![new_ip]) },
            || async {
                panic!("пригодный системный DNS не должен вызывать DoH")
            },
        )
        .await;

        assert_eq!(result, Some(vec![new_ip]));
        assert_eq!(cached_cf_ips(domain), Some(vec![new_ip]));
        clear_cf_ip(domain);
    }

    #[test]
    fn cf_dns_lock_cache_retains_only_active_requests() {
        let idle = Arc::new(tokio::sync::Mutex::new(()));
        let active = Arc::new(tokio::sync::Mutex::new(()));
        let active_request = Arc::clone(&active);
        let mut locks = CfDomainLocks::from([
            ("idle.example".into(), idle),
            ("active.example".into(), active),
        ]);

        retain_active_domain_locks(&mut locks);

        assert!(!locks.contains_key("idle.example"));
        assert!(locks.contains_key("active.example"));
        drop(active_request);
    }

    #[tokio::test]
    async fn cf_dns_single_flight_разрешает_имя_один_раз_для_параллельных_сессий() {
        let domain = "kws2.single-flight.example";
        let system_calls = Arc::new(AtomicUsize::new(0));

        let resolve = || {
            let system_calls = Arc::clone(&system_calls);
            resolve_cf_ips_with(
                domain,
                move || async move {
                    system_calls.fetch_add(1, Ordering::Relaxed);
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    Some(vec!["188.114.97.1".parse().unwrap()])
                },
                || async { Some(vec!["188.114.97.2".parse().unwrap()]) },
            )
        };

        let (first, second) = tokio::join!(resolve(), resolve());

        assert_eq!(first, Some(vec!["188.114.97.1".parse().unwrap()]));
        assert_eq!(second, Some(vec!["188.114.97.1".parse().unwrap()]));
        assert_eq!(system_calls.load(Ordering::Relaxed), 1);
    }
}
