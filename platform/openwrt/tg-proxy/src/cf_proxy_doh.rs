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
const DOH_CACHE_TTL: Duration = Duration::from_secs(300);
const CF_DNS_TIMEOUT: Duration = Duration::from_millis(500);
const CF_DNS_CACHE_TTL: Duration = Duration::from_secs(60);

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

static DOH_CACHE: LazyLock<Mutex<HashMap<String, (String, Instant)>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static DOH_LOCKS: LazyLock<Mutex<HashMap<String, Arc<AsyncMutex<()>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static CF_IP_CACHE: LazyLock<Mutex<HashMap<String, (String, Instant)>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));
static CF_IP_LOCKS: LazyLock<Mutex<HashMap<String, Arc<AsyncMutex<()>>>>> =
    LazyLock::new(|| Mutex::new(HashMap::new()));

pub(crate) fn cached_cf_ip(domain: &str) -> Option<String> {
    CF_IP_CACHE
        .lock()
        .expect("CF DNS cache lock poisoned")
        .get(domain)
        .filter(|(_, expires_at)| Instant::now() < *expires_at)
        .map(|(ip, _)| ip.clone())
}

fn cache_cf_ip(domain: &str, ip: &str, ttl: Duration) {
    let mut cache = CF_IP_CACHE.lock().expect("CF DNS cache lock poisoned");
    cache.retain(|_, (_, expires_at)| Instant::now() < *expires_at);
    cache.insert(domain.to_string(), (ip.to_string(), Instant::now() + ttl));
}

#[cfg(test)]
fn clear_cf_ip(domain: &str) {
    CF_IP_CACHE
        .lock()
        .expect("CF DNS cache lock poisoned")
        .remove(domain);
    DOH_CACHE
        .lock()
        .expect("DoH cache lock poisoned")
        .remove(domain);
}

async fn resolve_cf_ip_with<S, SFut, D, DFut>(
    domain: &str,
    system_lookup: S,
    doh_lookup: D,
) -> Option<String>
where
    S: FnOnce() -> SFut,
    SFut: Future<Output = Option<String>>,
    D: FnOnce() -> DFut,
    DFut: Future<Output = Option<String>>,
{
    if !valid_domain(domain) {
        return None;
    }
    if let Some(ip) = cached_cf_ip(domain) {
        return Some(ip);
    }

    let domain_lock = {
        let mut locks = CF_IP_LOCKS.lock().expect("CF DNS lock map poisoned");
        Arc::clone(
            locks
                .entry(domain.to_string())
                .or_insert_with(|| Arc::new(AsyncMutex::new(()))),
        )
    };
    let _single_flight = domain_lock.lock().await;
    if let Some(ip) = cached_cf_ip(domain) {
        return Some(ip);
    }

    let ip = if let Some(ip) = system_lookup().await {
        Some(ip)
    } else {
        doh_lookup().await
    }?;
    cache_cf_ip(domain, &ip, CF_DNS_CACHE_TTL);
    Some(ip)
}

pub(crate) async fn resolve_cf_ip(
    domain: &str,
    outbound: &OutboundConnector,
) -> Result<String, String> {
    let system_domain = domain.to_string();
    let doh_domain = domain.to_string();
    resolve_cf_ip_with(
        domain,
        move || async move {
            let addresses = tokio::time::timeout(
                CF_DNS_TIMEOUT,
                tokio::net::lookup_host((system_domain.as_str(), 443)),
            )
            .await
            .ok()?
            .ok()?;
            let mut ipv6 = None;
            for address in addresses {
                match address.ip() {
                    IpAddr::V4(ip) => return Some(ip.to_string()),
                    IpAddr::V6(ip) if ipv6.is_none() => ipv6 = Some(ip.to_string()),
                    IpAddr::V6(_) => {}
                }
            }
            ipv6
        },
        || async move { resolve_doh(&doh_domain, outbound).await },
    )
    .await
    .ok_or_else(|| format!("не удалось разрешить CF-хост {domain} через системный DNS и DoH"))
}

fn preferred_doh_answer(body: &[u8]) -> Option<IpAddr> {
    let response: serde_json::Value = serde_json::from_slice(body).ok()?;
    if response.get("Status").and_then(serde_json::Value::as_u64) != Some(0) {
        return None;
    }
    let answers = response.get("Answer")?.as_array()?;
    let mut ipv6 = None;
    for answer in answers {
        let record_type = answer.get("type").and_then(serde_json::Value::as_u64);
        let address = answer
            .get("data")
            .and_then(serde_json::Value::as_str)
            .and_then(|value| value.parse::<IpAddr>().ok());
        match (record_type, address) {
            (Some(1), Some(ip @ IpAddr::V4(_))) => return Some(ip),
            (Some(28), Some(ip @ IpAddr::V6(_))) if ipv6.is_none() => ipv6 = Some(ip),
            _ => {}
        }
    }
    ipv6
}

async fn query_endpoint(
    endpoint: &'static DohEndpoint,
    domain: &str,
    outbound: &OutboundConnector,
) -> Option<String> {
    let path = format!("/dns-query?name={domain}&type=A");
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
    preferred_doh_answer(body.as_bytes()).map(|ip| ip.to_string())
}

pub(crate) async fn resolve_doh(domain: &str, outbound: &OutboundConnector) -> Option<String> {
    let domain = domain.trim();
    if !valid_domain(domain) {
        return None;
    }
    if let Some((ip, _)) = DOH_CACHE
        .lock()
        .expect("DoH cache lock poisoned")
        .get(domain)
        .filter(|(_, expires_at)| Instant::now() < *expires_at)
    {
        return Some(ip.clone());
    }

    let domain_lock = {
        let mut locks = DOH_LOCKS.lock().expect("DoH lock map poisoned");
        Arc::clone(
            locks
                .entry(domain.to_string())
                .or_insert_with(|| Arc::new(AsyncMutex::new(()))),
        )
    };
    let _single_flight = domain_lock.lock().await;
    if let Some((ip, _)) = DOH_CACHE
        .lock()
        .expect("DoH cache lock poisoned")
        .get(domain)
        .filter(|(_, expires_at)| Instant::now() < *expires_at)
    {
        return Some(ip.clone());
    }

    let mut queries = FuturesUnordered::new();
    for endpoint in DOH_ENDPOINTS {
        queries.push(query_endpoint(endpoint, domain, outbound));
    }
    let ip = tokio::time::timeout(DOH_TIMEOUT, async {
        while let Some(answer) = queries.next().await {
            if answer.is_some() {
                return answer;
            }
        }
        None
    })
    .await
    .ok()??;

    let mut cache = DOH_CACHE.lock().expect("DoH cache lock poisoned");
    cache.retain(|_, (_, expires_at)| Instant::now() < *expires_at);
    cache.insert(
        domain.to_string(),
        (ip.clone(), Instant::now() + DOH_CACHE_TTL),
    );
    Some(ip)
}

#[cfg(test)]
mod tests {
    use std::sync::{
        Arc,
        atomic::{AtomicUsize, Ordering},
    };
    use std::time::Duration;

    use super::{
        cache_cf_ip, cached_cf_ip, clear_cf_ip, preferred_doh_answer, resolve_cf_ip_with,
        resolve_doh,
    };
    use crate::outbound::OutboundConnector;

    #[test]
    fn doh_выбирает_валидный_a_ответ_и_проверяет_status() {
        let body = br#"{"Status":0,"Answer":[{"name":"edge.example","type":28,"TTL":120,"data":"2606:4700:4700::1111"},{"name":"edge.example","type":1,"TTL":120,"data":"104.21.75.42"},{"name":"edge.example","type":16,"TTL":120,"data":"text"}]}"#;
        assert_eq!(
            preferred_doh_answer(body).unwrap().to_string(),
            "104.21.75.42"
        );
        assert!(preferred_doh_answer(br#"{"Status":2,"Answer":[]}"#).is_none());
    }

    #[tokio::test]
    async fn doh_отклоняет_некорректное_имя_до_сетевого_запроса() {
        assert!(
            resolve_doh("edge.example?name=evil", &OutboundConnector::direct())
                .await
                .is_none()
        );
    }

    #[test]
    fn cf_dns_cache_можно_прочитать_и_сбросить() {
        let domain = "kws2.cache-check.example";
        cache_cf_ip(domain, "188.114.97.1", Duration::from_secs(60));

        assert_eq!(cached_cf_ip(domain).as_deref(), Some("188.114.97.1"));

        clear_cf_ip(domain);
        assert!(cached_cf_ip(domain).is_none());
    }

    #[tokio::test]
    async fn cf_dns_не_вызывает_doh_если_системный_dns_ответил() {
        let domain = "kws2.system-dns.example";
        let doh_calls = Arc::new(AtomicUsize::new(0));
        let doh_calls_for_lookup = Arc::clone(&doh_calls);

        let result = resolve_cf_ip_with(
            domain,
            || async { Some("104.21.75.42".to_string()) },
            move || async move {
                doh_calls_for_lookup.fetch_add(1, Ordering::Relaxed);
                Some("188.114.97.1".to_string())
            },
        )
        .await;

        assert_eq!(result.as_deref(), Some("104.21.75.42"));
        assert_eq!(doh_calls.load(Ordering::Relaxed), 0);
    }

    #[tokio::test]
    async fn cf_dns_переходит_на_doh_при_сбое_системного_resolver() {
        let domain = "kws2.doh-fallback.example";
        clear_cf_ip(domain);
        let system_calls = Arc::new(AtomicUsize::new(0));
        let doh_calls = Arc::new(AtomicUsize::new(0));
        let system_calls_for_lookup = Arc::clone(&system_calls);
        let doh_calls_for_lookup = Arc::clone(&doh_calls);

        let result = resolve_cf_ip_with(
            domain,
            move || async move {
                system_calls_for_lookup.fetch_add(1, Ordering::Relaxed);
                None
            },
            move || async move {
                doh_calls_for_lookup.fetch_add(1, Ordering::Relaxed);
                Some("188.114.97.1".to_string())
            },
        )
        .await;

        assert_eq!(result.as_deref(), Some("188.114.97.1"));
        assert_eq!(system_calls.load(Ordering::Relaxed), 1);
        assert_eq!(doh_calls.load(Ordering::Relaxed), 1);
        clear_cf_ip(domain);
    }

    #[tokio::test]
    async fn cf_dns_single_flight_разрешает_имя_один_раз_для_параллельных_сессий() {
        let domain = "kws2.single-flight.example";
        let system_calls = Arc::new(AtomicUsize::new(0));

        let resolve = || {
            let system_calls = Arc::clone(&system_calls);
            resolve_cf_ip_with(
                domain,
                move || async move {
                    system_calls.fetch_add(1, Ordering::Relaxed);
                    tokio::time::sleep(Duration::from_millis(20)).await;
                    Some("188.114.97.1".to_string())
                },
                || async { None },
            )
        };

        let (first, second) = tokio::join!(resolve(), resolve());

        assert_eq!(first.as_deref(), Some("188.114.97.1"));
        assert_eq!(second.as_deref(), Some("188.114.97.1"));
        assert_eq!(system_calls.load(Ordering::Relaxed), 1);
    }
}
