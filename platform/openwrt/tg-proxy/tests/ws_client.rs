use z2kow_tg_transparent::ws_client::{cf_worker_path, cf_ws_domains, ws_domains};

#[test]
fn telegram_ws_domains_prefer_dc_record_and_media_variant() {
    assert_eq!(
        ws_domains(2, false),
        ["kws2.web.telegram.org", "kws2-1.web.telegram.org"]
    );
    assert_eq!(
        ws_domains(2, true),
        ["kws2-1.web.telegram.org", "kws2.web.telegram.org"]
    );
    assert_eq!(
        ws_domains(203, false),
        ["kws2.web.telegram.org", "kws2-1.web.telegram.org"]
    );
}

#[test]
fn cloudflare_ws_domains_keep_dc_and_configured_domain_order() {
    assert_eq!(
        cf_ws_domains(203, &["a.example".to_string()], false),
        ["kws203.a.example"]
    );
    assert_eq!(
        cf_ws_domains(2, &["a.example".to_string(), "b.example".to_string()], true),
        ["kws2.a.example", "kws2.b.example"]
    );
    assert!(cf_ws_domains(2, &[], false).is_empty());
}

#[test]
fn cloudflare_worker_path_preserves_dc_and_media_hint() {
    assert_eq!(
        cf_worker_path("149.154.167.51", 2, true),
        "/apiws?dst=149.154.167.51&dc=2&media=1"
    );
    assert_eq!(
        cf_worker_path("149.154.167.51", 2, false),
        "/apiws?dst=149.154.167.51&dc=2&media=0"
    );
}
