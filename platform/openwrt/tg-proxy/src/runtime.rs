//! Shared per-process runtime state.
//!
//! Holds process-wide state shared by the transparent listener and DC routes.

use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use crate::cf_domain_pool::{CfDomainPool, CfDomainSnapshot};
use crate::config::websocket_dc;
use crate::dc_map::DcMapStore;
use crate::outbound::OutboundConnector;
use crate::stats::RuntimeStats;

pub struct Runtime {
    outbound: OutboundConnector,
    dc_map: Arc<DcMapStore>,
    cf_domain_pool: Arc<CfDomainPool>,
    /// Preferred Cloudflare edges from `--cf-ip`. Empty means DNS picks the
    /// anycast edge as usual.
    cf_ips: Vec<IpAddr>,
    /// Пользовательские Worker общие для маршрутизации и DC discovery.
    cf_worker_domains: Vec<String>,
    cf_fail_cooldown: Duration,
    stats: Arc<RuntimeStats>,
}

impl Runtime {
    pub fn new(outbound: OutboundConnector) -> Self {
        Self {
            outbound,
            dc_map: Arc::new(DcMapStore::without_cache("/etc/z2k/telegram-dc-map.json")),
            cf_domain_pool: Arc::new(CfDomainPool::new(
                Vec::new(),
                false,
                PathBuf::from("/etc/z2k/telegram-cf-domains.json"),
            )),
            cf_ips: Vec::new(),
            cf_worker_domains: Vec::new(),
            cf_fail_cooldown: Duration::from_secs(60),
            stats: crate::stats::global(),
        }
    }

    /// Загрузить проверенный кэш карты DC из заданного файла.
    pub fn with_dc_map_path(mut self, path: PathBuf) -> Self {
        self.dc_map = Arc::new(DcMapStore::load(path));
        self
    }

    /// Настроить общий пул доменов Flowseal для маршрутизации и discovery.
    pub fn with_cf_domain_pool(
        mut self,
        manual_domains: Vec<String>,
        enabled: bool,
        path: PathBuf,
    ) -> Self {
        self.cf_domain_pool = Arc::new(CfDomainPool::new(manual_domains, enabled, path));
        self
    }

    /// Configure preferred Cloudflare edges (`--cf-ip`).
    pub fn with_cf_ips(mut self, ips: Vec<IpAddr>) -> Self {
        self.cf_ips = ips;
        self
    }

    pub fn with_cf_worker_domains(mut self, domains: Vec<String>) -> Self {
        self.cf_worker_domains = domains;
        self
    }

    pub fn with_cf_fail_cooldown(mut self, cooldown: Duration) -> Self {
        self.cf_fail_cooldown = cooldown;
        self
    }

    pub fn outbound(&self) -> &OutboundConnector {
        &self.outbound
    }

    pub fn dc_map(&self) -> &Arc<DcMapStore> {
        &self.dc_map
    }

    pub fn cf_domain_pool(&self) -> &Arc<CfDomainPool> {
        &self.cf_domain_pool
    }

    pub fn cf_domains(&self) -> Arc<CfDomainSnapshot> {
        self.cf_domain_pool.snapshot()
    }

    pub fn cf_ips(&self) -> &[IpAddr] {
        &self.cf_ips
    }

    pub fn cf_worker_domains(&self) -> &[String] {
        &self.cf_worker_domains
    }

    pub fn cf_fail_cooldown(&self) -> Duration {
        self.cf_fail_cooldown
    }

    pub fn stats(&self) -> &Arc<RuntimeStats> {
        &self.stats
    }

    pub fn websocket_dc(&self, dc: u32) -> u32 {
        websocket_dc(dc)
    }
}
