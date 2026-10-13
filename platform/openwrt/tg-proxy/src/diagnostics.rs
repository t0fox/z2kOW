//! Активная проверка доступности маршрутов Telegram без запуска listener.

use std::net::IpAddr;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

use futures_util::future::join_all;
use serde::Serialize;
use tokio::sync::Semaphore;

use crate::config::{Config, default_dc_ips};
use crate::dc_discovery::{probe_res_pq, start_ws_byte_stream};
use crate::runtime::Runtime;
use crate::ws_client::{
    WsProbeError, WsProbeTiming, cf_ws_domains, connect_probe_ws, race_ws_candidates, ws_domains,
};

const ROUTE_TIMEOUT: Duration = Duration::from_secs(8);
const TCP_TIMEOUT: Duration = Duration::from_secs(3);
const MTPROTO_TIMEOUT: Duration = Duration::from_secs(3);
const MAX_PARALLEL_ROUTES: usize = 3;
const EDGE_HEDGE_DELAY: Duration = Duration::from_millis(125);
const MAX_EDGE_ATTEMPTS: usize = 3;

#[derive(Clone, Debug, Serialize)]
pub struct DiagnosticReport {
    pub checked_at: u64,
    pub state: &'static str,
    pub data_centers: Vec<DcDiagnostic>,
}

#[derive(Clone, Debug, Serialize)]
pub struct DcDiagnostic {
    pub dc: u32,
    pub state: &'static str,
    pub routes: Vec<RouteDiagnostic>,
}

#[derive(Clone, Debug, Serialize)]
pub struct RouteDiagnostic {
    pub transport: &'static str,
    pub domain: Option<String>,
    pub selected_ip: Option<IpAddr>,
    pub state: &'static str,
    pub failed_stage: Option<&'static str>,
    pub http_status: Option<u16>,
    pub reason: Option<String>,
    pub dns_ms: Option<u64>,
    pub tcp_ms: Option<u64>,
    pub tls_ms: Option<u64>,
    pub websocket_ms: Option<u64>,
    pub mtproto_ms: Option<u64>,
}

impl DiagnosticReport {
    pub fn has_healthy_route(&self) -> bool {
        self.data_centers.iter().all(|dc| dc.state == "healthy")
    }
}

#[derive(Clone)]
struct RouteSpec {
    transport: &'static str,
    domain: Option<String>,
    target_ip: Option<IpAddr>,
    path: String,
    binary_subprotocol: bool,
}

/// Проверить DC1–DC5 по активным маршрутам из текущей конфигурации.
/// Успех засчитывается только после получения и разбора `resPQ`.
pub async fn run(config: &Config) -> Result<DiagnosticReport, String> {
    let runtime = Runtime::new(config.outbound_connector())
        .with_dc_map_path(config.dc_map_path.clone())
        .with_cf_domain_pool(
            config.cf_domains.clone(),
            config.default_domains,
            config
                .dc_map_path
                .with_file_name("telegram-cf-domains.json"),
        )
        .with_cf_ips(config.cf_ips.clone())
        .with_cf_worker_domains(config.cf_worker_domains.clone())
        .with_cf_fail_cooldown(Duration::from_secs(config.cf_fail_cooldown));

    let specs = route_specs(config, &runtime);
    let semaphore = std::sync::Arc::new(Semaphore::new(MAX_PARALLEL_ROUTES));
    let futures = specs.into_iter().map(|(dc, sequence, spec)| {
        let semaphore = std::sync::Arc::clone(&semaphore);
        let runtime = &runtime;
        async move {
            let _permit = semaphore
                .acquire_owned()
                .await
                .map_err(|_| "диагностический лимит параллелизма закрыт".to_string())?;
            Ok::<_, String>((dc, sequence, probe_route(runtime, spec).await))
        }
    });
    let mut routes = join_all(futures)
        .await
        .into_iter()
        .collect::<Result<Vec<_>, _>>()?;
    routes.sort_by_key(|route| (route.0, route.1));

    let mut data_centers = Vec::with_capacity(5);
    for dc in 1..=5 {
        let dc_routes = routes
            .iter()
            .filter(|route| route.0 == dc)
            .map(|route| route.2.clone())
            .collect::<Vec<_>>();
        data_centers.push(DcDiagnostic {
            dc,
            state: dc_state(&dc_routes),
            routes: dc_routes,
        });
    }

    let report = DiagnosticReport {
        checked_at: unix_time(),
        state: if data_centers.iter().all(|dc| dc.state == "healthy") {
            "healthy"
        } else if data_centers.iter().any(|dc| dc.state == "healthy") {
            "partial"
        } else if data_centers.iter().all(|dc| dc.state == "unverified") {
            "unverified"
        } else {
            "unavailable"
        },
        data_centers,
    };
    Ok(report)
}

fn route_specs(config: &Config, runtime: &Runtime) -> Vec<(u32, usize, RouteSpec)> {
    let fallback = default_dc_ips();
    let map = runtime.dc_map().current();
    let cf_domains = runtime.cf_domains();
    let mut routes = Vec::new();

    for dc in 1..=5 {
        let target_ip = map
            .as_ref()
            .and_then(|snapshot| {
                snapshot
                    .endpoints
                    .iter()
                    .find(|endpoint| {
                        endpoint.id == dc
                            && endpoint.port == 443
                            && !endpoint.media_only
                            && !endpoint.tcpo_only
                            && !endpoint.cdn
                    })
                    .map(|endpoint| endpoint.address)
            })
            .or_else(|| fallback.get(&dc)?.parse::<IpAddr>().ok());

        let mut add = |transport, domain, ip, path, binary_subprotocol| {
            let sequence = routes
                .iter()
                .filter(|route: &&(u32, usize, RouteSpec)| route.0 == dc)
                .count();
            routes.push((
                dc,
                sequence,
                RouteSpec {
                    transport,
                    domain,
                    target_ip: ip,
                    path,
                    binary_subprotocol,
                },
            ));
        };

        if let Some(ip) = target_ip {
            add("tcp-fallback", None, Some(ip), String::new(), false);
            add(
                "direct-wss",
                Some(ws_domains(dc, false)[0].clone()),
                Some(ip),
                "/apiws".into(),
                true,
            );

            for domain in &config.cf_worker_domains {
                add(
                    "cf-worker",
                    Some(domain.clone()),
                    Some(ip),
                    crate::ws_client::cf_worker_path(&ip.to_string(), dc, false),
                    false,
                );
            }
            for domain in cf_ws_domains(dc, &cf_domains.domains, false) {
                add("cf-proxy", Some(domain), None, "/apiws".into(), true);
            }
        }

        if config.cf_worker_domains.is_empty() {
            add("cf-worker", None, None, String::new(), false);
        }
        if cf_domains.domains.is_empty() {
            add("cf-proxy", None, None, String::new(), false);
        }
    }
    routes
}

async fn probe_route(runtime: &Runtime, spec: RouteSpec) -> RouteDiagnostic {
    if spec.transport == "tcp-fallback" {
        return match spec.target_ip {
            Some(target_ip) => probe_tcp(runtime, spec, target_ip).await,
            None => RouteDiagnostic::unverified(spec.transport),
        };
    }
    let Some(domain) = spec.domain.clone() else {
        return RouteDiagnostic::unverified(spec.transport);
    };
    if route_requires_target_ip(&spec) && spec.target_ip.is_none() {
        return RouteDiagnostic::unverified(spec.transport);
    }
    probe_wss(runtime, spec.clone(), spec.target_ip, &domain).await
}

fn route_requires_target_ip(spec: &RouteSpec) -> bool {
    spec.transport != "cf-proxy"
}

async fn probe_tcp(runtime: &Runtime, spec: RouteSpec, ip: IpAddr) -> RouteDiagnostic {
    let mut result = RouteDiagnostic::empty(spec.transport, spec.domain, Some(ip));
    let started = std::time::Instant::now();
    let stream = match tokio::time::timeout(
        TCP_TIMEOUT,
        runtime
            .outbound()
            .connect(&ip.to_string(), 443, TCP_TIMEOUT),
    )
    .await
    {
        Ok(Ok(stream)) => stream,
        Ok(Err(error)) => {
            result.fail("tcp", error.to_string());
            return result;
        }
        Err(_) => {
            result.fail("tcp", "истёк тайм-аут TCP connect".into());
            return result;
        }
    };
    result.tcp_ms = Some(elapsed_ms(started));
    let mut stream = stream;
    let started = std::time::Instant::now();
    match tokio::time::timeout(MTPROTO_TIMEOUT, probe_res_pq(&mut stream)).await {
        Ok(Ok(_)) => {
            result.mtproto_ms = Some(elapsed_ms(started));
            result.state = "healthy";
        }
        Ok(Err(error)) => result.fail("mtproto", error),
        Err(_) => result.fail("mtproto", "истёк тайм-аут req_pq_multi/resPQ".into()),
    }
    result
}

async fn probe_wss(
    runtime: &Runtime,
    spec: RouteSpec,
    target_ip: Option<IpAddr>,
    domain: &str,
) -> RouteDiagnostic {
    let mut result = RouteDiagnostic::empty(spec.transport, spec.domain.clone(), target_ip);
    let (ips, dns_ms) = if spec.transport == "direct-wss" {
        match target_ip {
            Some(target_ip) => (vec![target_ip], None),
            None => {
                result.fail("dns", "неизвестен IP Telegram DC для direct WSS".into());
                return result;
            }
        }
    } else {
        let started = std::time::Instant::now();
        match tokio::time::timeout(
            Duration::from_secs(3),
            crate::cf_proxy_doh::resolve_cf_ips(domain, runtime.outbound()),
        )
        .await
        {
            Ok(Ok(ips)) => (ips, Some(elapsed_ms(started))),
            Ok(Err(error)) => {
                result.fail("dns", error);
                return result;
            }
            Err(_) => {
                result.fail("dns", "истёк тайм-аут DNS".into());
                return result;
            }
        }
    };
    result.dns_ms = dns_ms;
    let candidates = ips
        .into_iter()
        .take(if spec.transport == "direct-wss" {
            1
        } else {
            MAX_EDGE_ATTEMPTS
        })
        .map(|ip| ip.to_string())
        .collect::<Vec<_>>();
    if candidates.is_empty() {
        result.fail("dns", "DNS не вернул пригодных IP-адресов".into());
        return result;
    }

    let domain_owned = domain.to_string();
    let path = spec.path.clone();
    let binary_subprotocol = spec.binary_subprotocol;
    let outbound = runtime.outbound();
    let (winner, failures) =
        race_ws_candidates(
            candidates,
            EDGE_HEDGE_DELAY,
            move |target| {
                let domain = domain_owned.clone();
                let path = path.clone();
                async move {
                    probe_wss_edge(outbound, &target, &domain, &path, binary_subprotocol).await
                }
            },
            |_| false,
        )
        .await;
    if let Some((selected_ip, (timing, mtproto_ms))) = winner {
        result.selected_ip = selected_ip.parse().ok();
        result.tcp_ms = timing.tcp_ms;
        result.tls_ms = timing.tls_ms;
        result.websocket_ms = timing.websocket_ms;
        result.mtproto_ms = Some(mtproto_ms);
        result.state = "healthy";
        return result;
    }
    if let Some((selected_ip, error)) = failures.into_iter().last() {
        result.selected_ip = selected_ip.parse().ok();
        result.apply_ws_error(error);
    } else {
        result.fail("websocket", "все попытки WSS отменены".into());
    }
    result
}

async fn probe_wss_edge(
    outbound: &crate::outbound::OutboundConnector,
    ip: &str,
    domain: &str,
    path: &str,
    binary_subprotocol: bool,
) -> Result<(WsProbeTiming, u64), WsProbeError> {
    let (ws, timing) = connect_probe_ws(
        ip,
        domain,
        path,
        binary_subprotocol,
        ROUTE_TIMEOUT,
        outbound,
    )
    .await?;
    let mut stream = start_ws_byte_stream(ws);
    let started = std::time::Instant::now();
    match tokio::time::timeout(MTPROTO_TIMEOUT, probe_res_pq(&mut stream)).await {
        Ok(Ok(_)) => Ok((timing, elapsed_ms(started))),
        Ok(Err(reason)) => Err(WsProbeError {
            phase: "mtproto",
            reason,
            http_status: None,
            timing,
        }),
        Err(_) => Err(WsProbeError {
            phase: "mtproto",
            reason: "истёк тайм-аут req_pq_multi/resPQ".into(),
            http_status: None,
            timing,
        }),
    }
}

impl RouteDiagnostic {
    fn empty(transport: &'static str, domain: Option<String>, ip: Option<IpAddr>) -> Self {
        Self {
            transport,
            domain,
            selected_ip: ip,
            state: "unavailable",
            failed_stage: None,
            http_status: None,
            reason: None,
            dns_ms: None,
            tcp_ms: None,
            tls_ms: None,
            websocket_ms: None,
            mtproto_ms: None,
        }
    }

    fn unverified(transport: &'static str) -> Self {
        let mut result = Self::empty(transport, None, None);
        result.state = "unverified";
        result
    }

    fn fail(&mut self, stage: &'static str, reason: String) {
        self.failed_stage = Some(stage);
        self.state = route_failure_state(stage, &reason);
        self.reason = Some(reason);
    }

    fn apply_ws_error(&mut self, error: WsProbeError) {
        self.dns_ms = error.timing.dns_ms;
        self.tcp_ms = error.timing.tcp_ms;
        self.tls_ms = error.timing.tls_ms;
        self.websocket_ms = error.timing.websocket_ms;
        self.http_status = error.http_status;
        self.fail(error.phase, error.reason);
    }
}

fn route_failure_state(stage: &str, reason: &str) -> &'static str {
    if stage == "dns" {
        return "unavailable";
    }
    if stage == "websocket" && (reason.contains("HTTP 403") || reason.contains("HTTP 451")) {
        return "blocked";
    }
    "unavailable"
}

fn dc_state(routes: &[RouteDiagnostic]) -> &'static str {
    if routes.iter().any(|route| route.state == "healthy") {
        "healthy"
    } else if routes.iter().all(|route| route.state == "unverified") {
        "unverified"
    } else if routes.iter().any(|route| route.state == "blocked") {
        "blocked"
    } else {
        "unavailable"
    }
}

fn elapsed_ms(started: std::time::Instant) -> u64 {
    started.elapsed().as_millis().min(u128::from(u64::MAX)) as u64
}

fn unix_time() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or_default()
}

#[cfg(test)]
mod tests {
    use super::{
        RouteDiagnostic, RouteSpec, dc_state, route_failure_state, route_requires_target_ip,
    };

    #[test]
    fn только_res_pq_может_пометить_dc_работающим() {
        let mut route =
            RouteDiagnostic::empty("direct-wss", Some("kws1.web.telegram.org".into()), None);
        assert_eq!(route.state, "unavailable");
        route.state = "healthy";
        assert_eq!(dc_state(&[route]), "healthy");
    }

    #[test]
    fn различает_непроверенный_недоступный_и_явно_заблокированный_маршрут() {
        assert_eq!(route_failure_state("dns", "NXDOMAIN"), "unavailable");
        assert_eq!(
            route_failure_state("websocket", "сервер ответил HTTP 403"),
            "blocked"
        );
        assert_eq!(
            dc_state(&[RouteDiagnostic::unverified("cf-worker")]),
            "unverified"
        );
    }

    #[test]
    fn cf_proxy_route_resolves_its_own_edge_without_a_dc_ip_hint() {
        let route = RouteSpec {
            transport: "cf-proxy",
            domain: Some("kws1.cf.example".into()),
            target_ip: None,
            path: "/apiws".into(),
            binary_subprotocol: true,
        };
        assert!(!route_requires_target_ip(&route));
        let worker = RouteSpec {
            transport: "cf-worker",
            domain: Some("worker.example".into()),
            target_ip: None,
            path: "/telegram".into(),
            binary_subprotocol: false,
        };
        assert!(route_requires_target_ip(&worker));
    }
}
