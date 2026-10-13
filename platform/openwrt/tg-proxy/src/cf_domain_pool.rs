use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::{Arc, Mutex, RwLock};
use std::time::{Duration, Instant, SystemTime, UNIX_EPOCH};

use serde::{Deserialize, Serialize};
use tracing::{info, warn};

use crate::default_domains::{MIN_VALID_DOMAINS, fallback_domains, normalize_domain_pool};

const CACHE_SCHEMA_VERSION: u32 = 1;

#[derive(Clone, Debug)]
pub struct CfDomainSnapshot {
    pub domains: Vec<String>,
    pub fetched_at: u64,
    pub generation: u64,
}

#[derive(Deserialize, Serialize)]
struct CachedDomainPool {
    schema_version: u32,
    fetched_at: u64,
    domains: Vec<String>,
}

pub struct CfDomainPool {
    manual_domains: Vec<String>,
    enabled: bool,
    path: PathBuf,
    current: RwLock<Arc<CfDomainSnapshot>>,
    update_lock: Mutex<()>,
    rate_limits: Mutex<HashMap<String, RateLimitState>>,
}

struct RateLimitState {
    failures: u8,
    until: Instant,
}

impl CfDomainPool {
    pub fn new(manual_domains: Vec<String>, enabled: bool, path: PathBuf) -> Self {
        let manual_domains = normalize_domain_pool(&manual_domains);
        let (remote_domains, fetched_at) = if enabled {
            load_cached(&path).unwrap_or_else(|| (fallback_domains(), 0))
        } else {
            (Vec::new(), 0)
        };
        let domains = merge_domains(&manual_domains, &remote_domains);
        Self {
            manual_domains,
            enabled,
            path,
            current: RwLock::new(Arc::new(CfDomainSnapshot {
                domains,
                fetched_at,
                generation: 0,
            })),
            update_lock: Mutex::new(()),
            rate_limits: Mutex::new(HashMap::new()),
        }
    }

    pub fn snapshot(&self) -> Arc<CfDomainSnapshot> {
        Arc::clone(
            &self
                .current
                .read()
                .expect("CF domain snapshot lock poisoned"),
        )
    }

    pub fn enabled(&self) -> bool {
        self.enabled
    }

    pub fn is_rate_limited(&self, domain: &str) -> bool {
        self.rate_limits
            .lock()
            .expect("CF rate limit lock poisoned")
            .get(domain)
            .is_some_and(|state| Instant::now() < state.until)
    }

    pub fn mark_rate_limited(&self, domain: &str) {
        let mut rate_limits = self
            .rate_limits
            .lock()
            .expect("CF rate limit lock poisoned");
        let state = rate_limits
            .entry(domain.to_string())
            .or_insert_with(|| RateLimitState {
                failures: 0,
                until: Instant::now(),
            });
        state.failures = state.failures.saturating_add(1);
        let exponent = u32::from(state.failures.saturating_sub(1).min(3));
        let seconds = (45_u64.saturating_mul(1 << exponent)).min(300);
        state.until = Instant::now() + Duration::from_secs(seconds);
    }

    pub fn mark_available(&self, domain: &str) {
        self.rate_limits
            .lock()
            .expect("CF rate limit lock poisoned")
            .remove(domain);
    }

    pub fn replace_remote(&self, domains: Vec<String>, fetched_at: u64) -> Result<(), String> {
        if !self.enabled {
            return Err("автообновление доменов CF выключено".to_string());
        }
        let domains = normalize_domain_pool(&domains);
        if domains.len() < MIN_VALID_DOMAINS {
            return Err(format!(
                "список Flowseal содержит только {} корректных доменов; требуется не меньше {MIN_VALID_DOMAINS}",
                domains.len()
            ));
        }

        let _update = self
            .update_lock
            .lock()
            .expect("CF domain update lock poisoned");
        let cache = CachedDomainPool {
            schema_version: CACHE_SCHEMA_VERSION,
            fetched_at,
            domains: domains.clone(),
        };
        write_cache_atomically(&self.path, &cache)?;

        let previous_generation = self.snapshot().generation;
        *self
            .current
            .write()
            .expect("CF domain snapshot lock poisoned") = Arc::new(CfDomainSnapshot {
            domains: merge_domains(&self.manual_domains, &domains),
            fetched_at,
            generation: previous_generation.saturating_add(1),
        });
        Ok(())
    }

    pub async fn refresh_once(
        &self,
        outbound: &crate::outbound::OutboundConnector,
    ) -> Result<(), String> {
        if !self.enabled {
            return Ok(());
        }
        let domains =
            crate::default_domains::fetch_flowseal_domains_with_outbound(outbound).await?;
        let fetched_at = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        self.replace_remote(domains, fetched_at)
    }
}

pub async fn refresh_loop(runtime: Arc<crate::runtime::Runtime>) {
    let pool = Arc::clone(runtime.cf_domain_pool());
    loop {
        let next_refresh = match pool.refresh_once(runtime.outbound()).await {
            Ok(()) => {
                let snapshot = pool.snapshot();
                info!(
                    "Список доменов CF обновлён: {} адресов, поколение {}",
                    snapshot.domains.len(),
                    snapshot.generation
                );
                Duration::from_secs(60 * 60)
            }
            Err(error) => {
                warn!(
                    "Не удалось обновить список доменов CF; используется последний проверенный набор: {error}"
                );
                Duration::from_secs(5 * 60)
            }
        };
        tokio::time::sleep(next_refresh).await;
    }
}

fn load_cached(path: &Path) -> Option<(Vec<String>, u64)> {
    let data = fs::read(path).ok()?;
    let cache: CachedDomainPool = serde_json::from_slice(&data).ok()?;
    if cache.schema_version != CACHE_SCHEMA_VERSION {
        return None;
    }
    let domains = normalize_domain_pool(&cache.domains);
    (domains.len() >= MIN_VALID_DOMAINS).then_some((domains, cache.fetched_at))
}

fn merge_domains(manual: &[String], remote: &[String]) -> Vec<String> {
    normalize_domain_pool(&manual.iter().chain(remote).cloned().collect::<Vec<_>>())
}

fn write_cache_atomically(path: &Path, cache: &CachedDomainPool) -> Result<(), String> {
    if let Some(parent) = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
    {
        fs::create_dir_all(parent)
            .map_err(|error| format!("не удалось создать каталог кэша CF: {error}"))?;
    }
    let file_name = path
        .file_name()
        .ok_or_else(|| "у файла кэша CF отсутствует имя".to_string())?
        .to_string_lossy();
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary = path.with_file_name(format!(".{file_name}.tmp-{}-{nonce}", std::process::id()));
    let bytes = serde_json::to_vec(cache)
        .map_err(|error| format!("не удалось сериализовать кэш CF: {error}"))?;
    let result = (|| {
        let mut file = OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&temporary)
            .map_err(|error| format!("не удалось создать временный кэш CF: {error}"))?;
        file.write_all(&bytes)
            .and_then(|()| file.sync_all())
            .map_err(|error| format!("не удалось записать временный кэш CF: {error}"))?;
        fs::rename(&temporary, path)
            .map_err(|error| format!("не удалось атомарно заменить кэш CF: {error}"))
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::CfDomainPool;
    use std::path::PathBuf;
    use std::sync::atomic::{AtomicUsize, Ordering};

    static NEXT_TEST_PATH: AtomicUsize = AtomicUsize::new(0);

    fn cache_path() -> PathBuf {
        std::env::temp_dir().join(format!(
            "z2kow-cf-domain-pool-{}-{}.json",
            std::process::id(),
            NEXT_TEST_PATH.fetch_add(1, Ordering::Relaxed)
        ))
    }

    #[test]
    fn проверенный_список_переживает_перезапуск() {
        let path = cache_path();
        let domains = vec![
            "alpha.example.co.uk".to_string(),
            "beta.example.co.uk".to_string(),
            "gamma.example.co.uk".to_string(),
        ];
        {
            let pool = CfDomainPool::new(Vec::new(), true, path.clone());
            pool.replace_remote(domains.clone(), 123).unwrap();
        }

        let restored = CfDomainPool::new(Vec::new(), true, path.clone());
        assert_eq!(restored.snapshot().domains, domains);
        assert_eq!(restored.snapshot().fetched_at, 123);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn обновление_не_меняет_снимок_уже_начатого_соединения() {
        let path = cache_path();
        let pool = CfDomainPool::new(Vec::new(), true, path.clone());
        let previous_domains = vec![
            "alpha.example.co.uk".to_string(),
            "beta.example.co.uk".to_string(),
            "gamma.example.co.uk".to_string(),
        ];
        pool.replace_remote(previous_domains.clone(), 123).unwrap();
        let active_connection_snapshot = pool.snapshot();

        let refreshed_domains = vec![
            "delta.example.co.uk".to_string(),
            "epsilon.example.co.uk".to_string(),
            "zeta.example.co.uk".to_string(),
        ];
        pool.replace_remote(refreshed_domains.clone(), 456).unwrap();

        let current_snapshot = pool.snapshot();
        assert_eq!(active_connection_snapshot.domains, previous_domains);
        assert_eq!(active_connection_snapshot.fetched_at, 123);
        assert_eq!(current_snapshot.domains, refreshed_domains);
        assert_eq!(current_snapshot.fetched_at, 456);
        assert_eq!(
            current_snapshot.generation,
            active_connection_snapshot.generation + 1
        );
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn повреждённый_файл_кэша_не_мешает_встроенному_резерву() {
        let path = cache_path();
        std::fs::write(&path, b"{broken json").unwrap();

        let pool = CfDomainPool::new(Vec::new(), true, path.clone());
        assert_eq!(pool.snapshot().domains.len(), 20);
        assert_eq!(pool.snapshot().fetched_at, 0);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn повреждённое_обновление_не_заменяет_последний_рабочий_список() {
        let path = cache_path();
        let pool = CfDomainPool::new(Vec::new(), true, path.clone());
        let domains = vec![
            "alpha.example.co.uk".to_string(),
            "beta.example.co.uk".to_string(),
            "gamma.example.co.uk".to_string(),
        ];
        pool.replace_remote(domains.clone(), 123).unwrap();

        assert!(
            pool.replace_remote(vec!["not a domain".to_string()], 456)
                .is_err()
        );
        assert_eq!(pool.snapshot().domains, domains);
        assert_eq!(pool.snapshot().fetched_at, 123);
        let _ = std::fs::remove_file(path);
    }

    #[test]
    fn ошибка_атомарной_записи_не_публикует_новый_список() {
        let obstruction = cache_path();
        std::fs::write(&obstruction, "это файл, а не каталог").unwrap();
        let path = obstruction.join("telegram-cf-domains.json");
        let pool = CfDomainPool::new(Vec::new(), true, path);
        let before = pool.snapshot();
        let update = vec![
            "alpha.example.co.uk".to_string(),
            "beta.example.co.uk".to_string(),
            "gamma.example.co.uk".to_string(),
        ];

        assert!(pool.replace_remote(update, 123).is_err());
        assert_eq!(pool.snapshot().domains, before.domains);
        assert_eq!(pool.snapshot().fetched_at, before.fetched_at);
        let _ = std::fs::remove_file(obstruction);
    }

    #[test]
    fn ограничение_429_привязано_к_домену_и_снимается_после_успеха() {
        let path = cache_path();
        let pool = CfDomainPool::new(Vec::new(), true, path.clone());
        pool.mark_rate_limited("alpha.example.co.uk");

        assert!(pool.is_rate_limited("alpha.example.co.uk"));
        assert!(!pool.is_rate_limited("beta.example.co.uk"));
        pool.mark_available("alpha.example.co.uk");
        assert!(!pool.is_rate_limited("alpha.example.co.uk"));
        let _ = std::fs::remove_file(path);
    }
}
