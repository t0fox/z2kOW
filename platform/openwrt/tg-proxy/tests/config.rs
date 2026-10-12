use z2kow_tg_transparent::config::{Config, WsRoutingPolicy};

#[test]
fn openwrt_options_configure_the_single_transparent_listener() {
    let config = Config::try_from_cli_line(
        "--host :: --port 1443 --transparent-ports 443,5222 --transparent-cidrs 149.154.160.0/20 --max-connections 48 --ws-routing hedged --ws-hedge-delay-ms 100 --ws-hedge-limit 4 --cf-domain cf.example --cf-worker-domain https://worker.example/path",
    )
    .unwrap();

    assert_eq!(config.host.as_deref(), Some("::"));
    assert_eq!(config.port, 1443);
    assert_eq!(config.transparent_ports, [443, 5222]);
    assert_eq!(config.transparent_cidrs, ["149.154.160.0/20"]);
    assert_eq!(config.max_connections, Some(48));
    assert_eq!(config.ws_routing, WsRoutingPolicy::Hedged);
    assert_eq!(config.ws_hedge_delay_ms, 100);
    assert_eq!(config.ws_hedge_limit, 4);
    assert_eq!(config.cf_domains, ["cf.example"]);
    assert_eq!(config.cf_worker_domains(), ["worker.example"]);
}

#[test]
fn transparent_mode_is_implicit_and_legacy_switch_is_rejected() {
    let config = Config::try_from_cli_line("--host :: --port 1443").unwrap();
    assert_eq!(config.port, 1443);
    assert!(Config::try_from_cli_line("--transparent").is_err());
}

#[test]
fn websocket_hedge_limit_has_a_fixed_upper_bound() {
    assert!(Config::try_from_cli_line("--ws-hedge-limit 32").is_ok());
    assert!(Config::try_from_cli_line("--ws-hedge-limit 33").is_err());
}
