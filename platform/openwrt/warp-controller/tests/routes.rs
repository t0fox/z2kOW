use warp_controller::routing::{RouteObservation, inspect_routes};

#[test]
fn structured_iproute2_snapshot_recognizes_only_owned_rules_and_route() {
    let observed = RouteObservation {
        rules: r#"[{"priority":0,"src":"all","table":"local"},{"priority":499,"src":"172.16.9.9","table":"989"},{"priority":500,"src":"all","fwmark":"0x80000000","fwmask":"0x80000000","table":"989"}]"#.into(),
        table: r#"[{"dst":"default","dev":"z2ktun0","table":"989","scope":"link"},{"dst":"default","gateway":"10.0.2.2","dev":"eth0","table":"main"}]"#.into(),
        interface: "z2ktun0".into(),
        probe_address: "172.16.9.9".into(),
    };

    let result = inspect_routes(&observed, 500, 499, 0x8000_0000, 0x8000_0000, 989).unwrap();
    assert!(result.probe_rule);
    assert!(result.user_rule);
    assert!(result.default_route);
}

#[test]
fn exact_owned_rules_and_route_are_recognized() {
    let observed = RouteObservation {
        rules: r#"[{"priority":0,"src":"all","table":"local"},{"priority":499,"src":"172.16.0.2","table":"989"},{"priority":500,"src":"all","fwmark":"0x80000000","fwmask":"0x80000000","table":"989"}]"#.into(),
        table: r#"[{"dst":"default","dev":"z2ktun0","table":"989","scope":"link"}]"#.into(),
        interface: "z2ktun0".into(),
        probe_address: "172.16.0.2".into(),
    };
    let result = inspect_routes(&observed, 500, 499, 0x8000_0000, 0x8000_0000, 989).unwrap();
    assert!(result.probe_rule);
    assert!(result.user_rule);
    assert!(result.default_route);
}

#[test]
fn foreign_route_and_overlapping_mark_fail_closed() {
    let mut observed = RouteObservation {
        rules: "[]".into(),
        table: r#"[{"dst":"default","dev":"eth9","table":"989"}]"#.into(),
        interface: "z2ktun0".into(),
        probe_address: "172.16.0.2".into(),
    };
    assert!(inspect_routes(&observed, 500, 499, 0x8000_0000, 0x8000_0000, 989).is_err());
    observed.rules = r#"[{"priority":501,"src":"all","fwmark":"0x80000000","table":"100"}]"#.into();
    observed.table = "[]".into();
    assert!(inspect_routes(&observed, 500, 499, 0x8000_0000, 0x8000_0000, 989).is_err());
}

#[test]
fn unrelated_main_routes_are_ignored() {
    let observed = RouteObservation {
        rules: "[]".into(),
        table: r#"[{"dst":"default","gateway":"192.0.2.1","dev":"eth0","table":"main"}]"#.into(),
        interface: "z2ktun0".into(),
        probe_address: "172.16.0.2".into(),
    };
    let result = inspect_routes(&observed, 500, 499, 0x8000_0000, 0x8000_0000, 989).unwrap();
    assert!(!result.default_route);
}

#[test]
fn malformed_mark_metadata_fails_closed() {
    for rules in [
        r#"[{"priority":501,"src":"all","fwmark":"0x80000000","fwmask":"invalid","table":"100"}]"#,
        r#"[{"priority":501,"src":"all","fwmask":"0x80000000","table":"100"}]"#,
    ] {
        let observed = RouteObservation {
            rules: rules.into(),
            table: "[]".into(),
            interface: "z2ktun0".into(),
            probe_address: "172.16.0.2".into(),
        };
        assert!(inspect_routes(&observed, 500, 499, 0x8000_0000, 0x8000_0000, 989).is_err());
    }
}

#[test]
fn missing_or_unreadable_inventory_is_not_treated_as_empty() {
    let observed = RouteObservation {
        rules: "[]".into(),
        table: "[]".into(),
        interface: "bad iface".into(),
        probe_address: "172.16.0.2".into(),
    };
    assert!(inspect_routes(&observed, 500, 499, 0x8000_0000, 0x8000_0000, 989).is_err());
}

#[test]
fn clean_snapshot_without_rules_is_not_ready_but_is_safe() {
    let observed = RouteObservation {
        rules: r#"[{"priority":0,"src":"all","table":"local"}]"#.into(),
        table: "[]".into(),
        interface: "z2ktun0".into(),
        probe_address: "172.16.0.2".into(),
    };
    let result = inspect_routes(&observed, 500, 499, 0x8000_0000, 0x8000_0000, 989).unwrap();
    assert!(!result.probe_rule);
    assert!(!result.user_rule);
    assert!(!result.default_route);
}
