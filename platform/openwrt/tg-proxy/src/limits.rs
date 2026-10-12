//! Connection limits derived from the process file-descriptor budget.
//!
//! Each active connection costs 2 file descriptors — the accepted client
//! socket and the outbound connection to Telegram. Accepting past that budget fails
//! with `EMFILE` deep inside the accept loop, so the cap is computed up front
//! from the process's soft `ulimit -n` instead.

/// Conservative fallback for platforms where the soft limit cannot be read.
const DEFAULT_NOFILE_LIMIT: usize = 1024;
/// Cap used when the process has no file-descriptor limit at all.
const UNLIMITED_MAX_CONNECTIONS: usize = 512;
/// File descriptors reserved for the Tokio runtime, stdio and a safety margin.
const RUNTIME_RESERVED_FDS: usize = 32;
/// File descriptors used per active connection: one inbound, one outbound.
const FDS_PER_CONNECTION: usize = 2;
/// Smallest cap worth serving, however tight the budget is.
const MIN_MAX_CONNECTIONS: usize = 4;

/// Read the soft per-process open-file limit from `/proc/self/limits` (Linux).
/// Falls back to 1 024 on other platforms or when the file cannot be parsed.
pub fn soft_nofile_limit() -> usize {
    #[cfg(target_os = "linux")]
    {
        if let Ok(content) = std::fs::read_to_string("/proc/self/limits") {
            for line in content.lines() {
                // Example line:
                //   Max open files            1024                 4096                 files
                if line.starts_with("Max open files")
                    && let Some(soft) = line.split_whitespace().nth(3)
                {
                    if soft == "unlimited" {
                        return usize::MAX;
                    }
                    if let Ok(n) = soft.parse::<usize>() {
                        return n;
                    }
                }
            }
        }
    }

    DEFAULT_NOFILE_LIMIT
}

/// Вычислить лимит клиентских соединений с резервом на одновременные WSS hedge.
///
/// На каждую hedge-попытку резервируется дополнительный исходящий сокет.
pub fn auto_max_connections(fd_limit: usize, hedge_limit: usize) -> usize {
    if fd_limit == usize::MAX {
        // Unlimited FDs: cap at a large but sane value.
        return UNLIMITED_MAX_CONNECTIONS;
    }

    let reserved = 1usize
        .saturating_add(RUNTIME_RESERVED_FDS)
        .saturating_add(hedge_limit);

    (fd_limit.saturating_sub(reserved) / FDS_PER_CONNECTION).max(MIN_MAX_CONNECTIONS)
}
