use z2kow_tg_transparent::limits::{auto_max_connections, soft_nofile_limit};

/// Минимум подключений при очень низком лимите файловых дескрипторов.
const MIN_MAX_CONNECTIONS: usize = 4;

#[test]
fn default_connection_limit_reserves_listener_and_runtime_descriptors() {
    assert_eq!(auto_max_connections(1024, 0), 495);
    assert_eq!(auto_max_connections(1024, 8), 491);
}

#[test]
fn connection_limit_grows_with_the_fd_limit() {
    assert!(auto_max_connections(65_536, 8) > auto_max_connections(1024, 8));
}

#[test]
fn unlimited_fd_budget_has_a_sane_connection_cap() {
    assert_eq!(auto_max_connections(usize::MAX, 8), 512);
}

#[test]
fn tiny_fd_budget_keeps_the_minimum_serviceable_limit() {
    assert_eq!(auto_max_connections(64, 8), 11);
    assert_eq!(auto_max_connections(0, 8), MIN_MAX_CONNECTIONS);
}

#[test]
fn soft_nofile_limit_reports_a_usable_budget() {
    let limit = soft_nofile_limit();

    assert!(limit > 0);
    assert!(auto_max_connections(limit, 8) >= MIN_MAX_CONNECTIONS);
}
