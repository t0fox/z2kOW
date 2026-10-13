use z2kow_tg_transparent::outbound::OutboundConnector;
use z2kow_tg_transparent::runtime::Runtime;

#[test]
fn websocket_dc_remaps_only_the_non_canonical_dcs() {
    let runtime = Runtime::new(OutboundConnector::direct());

    assert_eq!(runtime.websocket_dc(203), 2);
    for dc in 1..=5 {
        assert_eq!(runtime.websocket_dc(dc), dc);
    }
    assert_eq!(runtime.websocket_dc(42), 42);
}

#[test]
fn маршрутизация_и_dc_discovery_читают_один_актуальный_snapshot() {
    let path = std::env::temp_dir().join(format!(
        "z2kow-runtime-cf-domain-pool-{}.json",
        std::process::id()
    ));
    let runtime = Runtime::new(OutboundConnector::direct()).with_cf_domain_pool(
        vec!["manual.example.org".to_string()],
        true,
        path.clone(),
    );
    let domains = vec![
        "alpha.example.co.uk".to_string(),
        "beta.example.co.uk".to_string(),
        "gamma.example.co.uk".to_string(),
    ];
    runtime
        .cf_domain_pool()
        .replace_remote(domains.clone(), 123)
        .unwrap();

    let routing_view = runtime.cf_domains();
    let discovery_view = runtime.cf_domain_pool().snapshot();
    assert!(std::sync::Arc::ptr_eq(&routing_view, &discovery_view));
    assert_eq!(routing_view.domains[0], "manual.example.org");
    assert!(
        domains
            .iter()
            .all(|domain| routing_view.domains.contains(domain))
    );
    assert_eq!(routing_view.fetched_at, 123);

    let _ = std::fs::remove_file(path);
}
