//! Shared per-process runtime state.
//!
//! Holds process-wide state shared by the transparent listener and DC routes.

use std::net::IpAddr;
use std::path::PathBuf;
use std::sync::Arc;
use std::time::Duration;

use crate::config::websocket_dc;
use crate::dc_map::DcMapStore;
use crate::outbound::OutboundConnector;

pub struct Runtime {
    outbound: OutboundConnector,
    dc_map: Arc<DcMapStore>,
    /// Preferred Cloudflare edges from `--cf-ip`. Empty means DNS picks the
    /// anycast edge as usual.
    cf_ips: Vec<IpAddr>,
    cf_fail_cooldown: Duration,
}

impl Runtime {
    pub fn new(outbound: OutboundConnector) -> Self {
        Self {
            outbound,
            dc_map: Arc::new(DcMapStore::without_cache("/etc/z2k/telegram-dc-map.json")),
            cf_ips: Vec::new(),
            cf_fail_cooldown: Duration::from_secs(60),
        }
    }

    /// Загрузить проверенный кэш карты DC из заданного файла.
    pub fn with_dc_map_path(mut self, path: PathBuf) -> Self {
        self.dc_map = Arc::new(DcMapStore::load(path));
        self
    }

    /// Configure preferred Cloudflare edges (`--cf-ip`).
    pub fn with_cf_ips(mut self, ips: Vec<IpAddr>) -> Self {
        self.cf_ips = ips;
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

    pub fn cf_ips(&self) -> &[IpAddr] {
        &self.cf_ips
    }

    pub fn cf_fail_cooldown(&self) -> Duration {
        self.cf_fail_cooldown
    }

    pub fn websocket_dc(&self, dc: u32) -> u32 {
        websocket_dc(dc)
    }
}
