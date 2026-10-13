//! Параметры единственного режима OpenWrt: прозрачного перехвата MTProto.

use std::collections::HashMap;
use std::net::IpAddr;
use std::path::PathBuf;

use clap::{Parser, ValueEnum};

use crate::outbound::OutboundConnector;

const MAX_CF_WORKER_DOMAINS: usize = 8;

fn validate_cf_worker_domain_count(count: usize) -> Result<(), String> {
    if count > MAX_CF_WORKER_DOMAINS {
        Err(format!(
            "число доменов Telegram Cloudflare Worker не должно превышать {MAX_CF_WORKER_DOMAINS}"
        ))
    } else {
        Ok(())
    }
}

const DEFAULT_DC_IPS: &[(u32, &str)] = &[
    (1, "149.154.175.50"),
    (2, "149.154.167.51"),
    (3, "149.154.175.100"),
    (4, "149.154.167.91"),
    (5, "149.154.171.5"),
    (203, "91.105.192.100"),
];

const DEFAULT_DC_IPV6S: &[(u32, &str)] = &[
    (1, "2001:b28:f23d:f001::a"),
    (2, "2001:67c:4e8:f002::a"),
    (3, "2001:b28:f23d:f003::a"),
    (4, "2001:67c:4e8:f004::a"),
    (5, "2001:b28:f23f:f005::a"),
];

/// Резервные точные адреса для тестов и первоначального bootstrap карты DC.
const DEFAULT_DC_ROUTES: &[(u32, &str, bool)] = &[
    (1, "149.154.175.50", false),
    (1, "149.154.175.51", false),
    (1, "149.154.175.52", true),
    (1, "149.154.175.53", false),
    (1, "149.154.175.54", false),
    (2, "149.154.167.41", false),
    (2, "149.154.167.50", false),
    (2, "149.154.167.51", false),
    (2, "149.154.167.220", false),
    (2, "95.161.76.100", false),
    (2, "149.154.167.151", true),
    (2, "149.154.167.222", true),
    (2, "149.154.167.223", true),
    (2, "149.154.162.123", true),
    (3, "149.154.175.100", false),
    (3, "149.154.175.101", false),
    (3, "149.154.175.102", true),
    (4, "149.154.167.91", false),
    (4, "149.154.167.92", false),
    (4, "149.154.164.250", true),
    (4, "149.154.166.120", true),
    (4, "149.154.166.121", true),
    (4, "149.154.167.118", true),
    (4, "149.154.165.111", true),
    (5, "91.108.56.100", false),
    (5, "91.108.56.101", false),
    (5, "91.108.56.116", false),
    (5, "91.108.56.126", false),
    (5, "149.154.171.5", false),
    (5, "91.108.56.102", true),
    (5, "91.108.56.128", true),
    (5, "91.108.56.151", true),
    (203, "91.105.192.100", false),
];

const DC_OVERRIDES: &[(u32, u32)] = &[(203, 2)];

pub fn default_dc_ips() -> HashMap<u32, String> {
    DEFAULT_DC_IPS
        .iter()
        .map(|(dc, ip)| (*dc, ip.to_string()))
        .collect()
}

/// Проверенные встроенные IPv4/IPv6 адреса для bootstrap запроса `help.getConfig`.
pub fn default_dc_bootstrap_ips() -> Vec<(u32, &'static str)> {
    let mut targets = Vec::with_capacity(DEFAULT_DC_IPS.len() + DEFAULT_DC_IPV6S.len());
    for (dc, ipv4) in DEFAULT_DC_IPS {
        targets.push((*dc, *ipv4));
        if let Some((_, ipv6)) = DEFAULT_DC_IPV6S.iter().find(|(ipv6_dc, _)| ipv6_dc == dc) {
            targets.push((*dc, *ipv6));
        }
    }
    targets
}

pub fn default_dc_route_for_ip(ip: IpAddr) -> Option<(u32, bool)> {
    DEFAULT_DC_ROUTES
        .iter()
        .find_map(|(dc, address, is_media)| {
            (address.parse::<IpAddr>().ok() == Some(ip)).then_some((*dc, *is_media))
        })
        .or_else(|| {
            DEFAULT_DC_IPV6S.iter().find_map(|(dc, address)| {
                (address.parse::<IpAddr>().ok() == Some(ip)).then_some((*dc, false))
            })
        })
}

pub fn default_dc_overrides() -> HashMap<u32, u32> {
    DC_OVERRIDES.iter().copied().collect()
}

pub fn websocket_dc(dc: u32) -> u32 {
    DC_OVERRIDES
        .iter()
        .find_map(|(from, to)| (*from == dc).then_some(*to))
        .unwrap_or(dc)
}

/// Политика выбора между direct WSS и Cloudflare WSS.
#[derive(Copy, Clone, PartialEq, Eq, Debug, ValueEnum)]
pub enum WsRoutingPolicy {
    Sequential,
    CfFirst,
    Hedged,
    Adaptive,
}

fn parse_ws_hedge_limit(value: &str) -> Result<usize, String> {
    let limit = value
        .parse::<usize>()
        .map_err(|_| format!("неверный лимит WSS-попыток: {value}"))?;
    if limit <= 32 {
        Ok(limit)
    } else {
        Err("лимит WSS-попыток не может превышать 32".to_string())
    }
}

#[derive(Parser, Clone, Debug)]
#[command(
    name = "tg-ws-proxy",
    version,
    about = "Прозрачный Telegram MTProto → WSS-прокси для OpenWrt"
)]
pub struct Config {
    /// TCP-порты перехвата, заданные политикой OpenWrt.
    #[arg(long = "transparent-ports", value_delimiter = ',')]
    pub transparent_ports: Vec<u16>,

    /// CIDR диапазоны Telegram, заданные политикой OpenWrt.
    #[arg(long = "transparent-cidrs", value_delimiter = ',')]
    pub transparent_cidrs: Vec<String>,

    /// Проверенный кэш официальных dcOption.
    #[arg(
        long,
        env = "TG_DC_MAP_PATH",
        default_value = "/etc/z2k/telegram-dc-map.json"
    )]
    pub dc_map_path: PathBuf,

    /// Путь атомарного списка адресов DC для адаптера OpenWrt.
    #[arg(
        long,
        env = "TG_DC_MAP_ENDPOINTS_PATH",
        default_value = "/etc/z2k/telegram-dc-endpoints.tsv"
    )]
    pub dc_map_endpoints_path: PathBuf,

    /// Интервал обновления официальной карты DC в секундах.
    #[arg(long, env = "TG_DC_MAP_REFRESH_SECS", default_value_t = 21_600)]
    pub dc_map_refresh_secs: u64,

    /// Порт transparent listener.
    #[arg(long, default_value_t = 1443, env = "TG_PORT")]
    pub port: u16,

    /// Адрес прослушивания. OpenWrt задаёт `::` для IPv4 и IPv6.
    #[arg(long, env = "TG_HOST")]
    pub host: Option<String>,

    /// Максимум одновременных клиентских подключений.
    #[arg(long = "max-connections", env = "TG_MAX_CONNECTIONS")]
    pub max_connections: Option<usize>,

    /// Включить подробное журналирование.
    #[arg(short, long, env = "TG_VERBOSE")]
    pub verbose: bool,

    /// Отключить журналирование.
    #[arg(short = 'q', long, env = "TG_QUIET")]
    pub quiet: bool,

    /// Путь к файлу журнала.
    #[arg(long = "log-file", value_name = "PATH", env = "TG_LOG_FILE")]
    pub log_file: Option<String>,

    /// Домены Cloudflare proxy для резервного WSS маршрута.
    #[arg(long = "cf-domain", value_delimiter = ',', env = "TG_CF_DOMAIN")]
    pub cf_domains: Vec<String>,

    /// Домены Cloudflare Worker для TCP туннеля до DC.
    #[arg(
        long = "cf-worker-domain",
        alias = "cfproxy-worker-domain",
        value_delimiter = ',',
        num_args = 1..=8,
        value_parser = parse_cf_worker_domain,
        env = "TG_CF_WORKER_DOMAIN"
    )]
    pub cf_worker_domains: Vec<String>,

    /// Балансировать подключения между доменами Cloudflare.
    #[arg(long = "cf-balance", env = "TG_CF_BALANCE")]
    pub cf_balance: bool,

    /// Предпочтительные IP адреса Cloudflare edge.
    #[arg(long = "cf-ip", value_delimiter = ',', env = "TG_CF_IP")]
    pub cf_ips: Vec<IpAddr>,

    /// Порядок выбора direct WSS и Cloudflare WSS.
    #[arg(
        long = "ws-routing",
        value_enum,
        default_value = "adaptive",
        env = "TG_WS_ROUTING"
    )]
    pub ws_routing: WsRoutingPolicy,

    /// Задержка перед началом резервной WSS попытки в миллисекундах.
    #[arg(
        long = "ws-hedge-delay-ms",
        default_value_t = 125,
        env = "TG_WS_HEDGE_DELAY_MS"
    )]
    pub ws_hedge_delay_ms: u64,

    /// Максимум одновременно hedged подключений; 0 отключает hedge.
    #[arg(
        long = "ws-hedge-limit",
        default_value_t = 8,
        value_parser = parse_ws_hedge_limit,
        env = "TG_WS_HEDGE_LIMIT"
    )]
    pub ws_hedge_limit: usize,

    /// Тайм-аут подключения direct WSS в секундах.
    #[arg(
        long = "ws-connect-timeout",
        default_value_t = 10,
        env = "TG_WS_CONNECT_TIMEOUT"
    )]
    pub ws_connect_timeout: u64,

    /// Короткий повторный WSS probe во время cooldown, в секундах.
    #[arg(
        long = "ws-fail-probe-timeout",
        default_value_t = 2,
        env = "TG_WS_FAIL_PROBE_TIMEOUT"
    )]
    pub ws_fail_probe_timeout: u64,

    /// Пауза после сетевого отказа WSS, в секундах.
    #[arg(
        long = "ws-fail-cooldown",
        default_value_t = 30,
        env = "TG_WS_FAIL_COOLDOWN"
    )]
    pub ws_fail_cooldown: u64,

    /// Пауза после отказа Telegram redirect, в секундах.
    #[arg(
        long = "ws-redirect-cooldown",
        default_value_t = 300,
        env = "TG_WS_REDIRECT_COOLDOWN"
    )]
    pub ws_redirect_cooldown: u64,

    /// Пауза после истечения TCP connect timeout к IP назначения.
    #[arg(
        long = "ip-fail-cooldown",
        default_value_t = 3600,
        env = "TG_IP_FAIL_COOLDOWN"
    )]
    pub ip_fail_cooldown: u64,

    /// Тайм-аут чтения начального obfuscated2 пакета.
    #[arg(
        long = "handshake-timeout",
        default_value_t = 10,
        env = "TG_HANDSHAKE_TIMEOUT"
    )]
    pub handshake_timeout: u64,

    /// Тайм-аут прямого TCP fallback в секундах.
    #[arg(
        long = "tcp-fallback-timeout",
        default_value_t = 10,
        env = "TG_TCP_FALLBACK_TIMEOUT"
    )]
    pub tcp_fallback_timeout: u64,

    /// Тайм-аут Cloudflare WSS подключения.
    #[arg(
        long = "cf-connect-timeout",
        default_value_t = 10,
        env = "TG_CF_CONNECT_TIMEOUT"
    )]
    pub cf_connect_timeout: u64,

    /// Пауза перед повтором Cloudflare Worker после отказа.
    #[arg(
        long = "cf-fail-cooldown",
        default_value_t = 60,
        env = "TG_CF_FAIL_COOLDOWN"
    )]
    pub cf_fail_cooldown: u64,

    /// Использовать встроенный список доменов Cloudflare.
    #[arg(long = "default-domains", env = "TG_DEFAULT_DOMAINS")]
    pub default_domains: bool,
}

/// Разобрать shell-подобную строку аргументов для конфигурационного теста.
pub fn split_cli_args(line: &str) -> Result<Vec<String>, String> {
    let mut args = Vec::new();
    let mut current = String::new();
    let mut started = false;
    let mut chars = line.chars().peekable();
    let mut in_single = false;
    let mut in_double = false;

    while let Some(character) = chars.next() {
        match character {
            '\'' if !in_double => {
                in_single = !in_single;
                started = true;
            }
            '"' if !in_single => {
                in_double = !in_double;
                started = true;
            }
            character if character.is_whitespace() && !in_single && !in_double => {
                if started {
                    args.push(std::mem::take(&mut current));
                    started = false;
                }
            }
            '\\' if !in_single => {
                if let Some(next) = chars.next() {
                    current.push(next);
                    started = true;
                } else {
                    return Err("обратная косая черта в конце строки аргументов".into());
                }
            }
            other => {
                current.push(other);
                started = true;
            }
        }
    }

    if in_single || in_double {
        return Err("незакрытая кавычка в строке аргументов".into());
    }
    if started {
        args.push(current);
    }
    Ok(args)
}

impl Config {
    pub fn from_args() -> Self {
        let config = Self::try_parse().unwrap_or_else(|error| error.exit());
        validate_cf_worker_domain_count(config.cf_worker_domains.len()).unwrap_or_else(|error| {
            clap::Error::raw(clap::error::ErrorKind::ValueValidation, error).exit()
        });
        config.with_defaults()
    }

    pub fn try_from_cli_line(line: &str) -> Result<Self, String> {
        let tokens = split_cli_args(line.trim())?;
        let args = match tokens.first() {
            Some(first) if !first.starts_with('-') => tokens,
            _ => {
                let mut args = vec!["tg-ws-proxy".to_string()];
                args.extend(tokens);
                args
            }
        };
        Self::try_parse_from(args)
            .map_err(|error| error.render().to_string())
            .and_then(|config| {
                validate_cf_worker_domain_count(config.cf_worker_domains.len())?;
                Ok(config.with_defaults())
            })
    }

    pub fn with_defaults(mut self) -> Self {
        let mut worker_domains = Vec::with_capacity(MAX_CF_WORKER_DOMAINS);
        for domain in std::mem::take(&mut self.cf_worker_domains) {
            let Some(domain) = Self::normalize_cf_worker_domain(&domain) else {
                continue;
            };
            if !worker_domains.contains(&domain) && worker_domains.len() < MAX_CF_WORKER_DOMAINS {
                worker_domains.push(domain);
            }
        }
        self.cf_worker_domains = worker_domains;
        self
    }

    pub fn cf_worker_domains(&self) -> &[String] {
        &self.cf_worker_domains
    }

    fn normalize_cf_worker_domain(domain: &str) -> Option<String> {
        let normalized = domain.trim().to_ascii_lowercase();
        let domain = normalized.as_str();
        if domain.is_empty() {
            return None;
        }
        let domain = domain
            .strip_prefix("https://")
            .or_else(|| domain.strip_prefix("http://"))
            .unwrap_or(domain);
        let domain = domain.split_once('/').map_or(domain, |(host, _)| host);
        let domain = domain.trim_end_matches('.');
        if domain.len() > 253 || domain.parse::<std::net::IpAddr>().is_ok() {
            return None;
        }
        let labels: Vec<_> = domain.split('.').collect();
        if labels.len() < 2
            || labels.iter().any(|label| {
                label.is_empty()
                    || label.len() > 63
                    || label.starts_with('-')
                    || label.ends_with('-')
                    || !label
                        .bytes()
                        .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
            })
        {
            return None;
        }
        Some(domain.to_string())
    }

    pub fn outbound_connector(&self) -> OutboundConnector {
        OutboundConnector::direct().with_socket_mark(Some(0x4000_0000))
    }

    pub fn bind_host(&self) -> String {
        self.host.clone().unwrap_or_else(|| "::".to_string())
    }
}

fn parse_cf_worker_domain(domain: &str) -> Result<String, String> {
    Config::normalize_cf_worker_domain(domain)
        .ok_or_else(|| format!("неверный домен Telegram Cloudflare Worker: {domain}"))
}
