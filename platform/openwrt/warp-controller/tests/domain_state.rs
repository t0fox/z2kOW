use std::{fs, os::unix::fs::MetadataExt};
use warp_controller::domain_state::{render_rules, set_error_file, sync_rules_file};

#[test]
fn domains_file_is_sorted_deduplicated_and_keeps_the_v1_header() {
    let domains = [
        "z.example.com".to_owned(),
        "a.example.com".to_owned(),
        "a.example.com".to_owned(),
    ];

    let rendered = render_rules(&domains);

    assert_eq!(rendered.contents, "v1\na.example.com\nz.example.com\n");
    assert_eq!(rendered.error, None);
}

#[test]
fn oversized_domain_lists_publish_an_empty_v1_file_and_error() {
    let domains = (0..=4096)
        .map(|index| format!("d{index}.example.com"))
        .collect::<Vec<_>>();

    let rendered = render_rules(&domains);

    assert_eq!(rendered.contents, "v1\n");
    assert_eq!(rendered.error, Some("domain-rule-limit-exceeded"));
}

#[test]
fn syncing_domain_rules_is_atomic_idempotent_and_clears_stale_errors() {
    let root = std::env::temp_dir().join(format!(
        "z2k-domain-state-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let rules_path = root.join("domains.v1");
    let error_path = root.join("domain-setup-error");
    let oversized = (0..=4096)
        .map(|index| format!("d{index}.example.com"))
        .collect::<Vec<_>>();
    sync_rules_file(&rules_path, &error_path, &oversized).unwrap();
    assert_eq!(fs::read_to_string(&rules_path).unwrap(), "v1\n");
    assert_eq!(
        fs::read_to_string(&error_path).unwrap(),
        "domain-rule-limit-exceeded\n"
    );

    let domains = ["a.example.com".to_owned(), "z.example.com".to_owned()];
    sync_rules_file(&rules_path, &error_path, &domains).unwrap();
    let first_inode = fs::metadata(&rules_path).unwrap().ino();
    sync_rules_file(&rules_path, &error_path, &domains).unwrap();
    assert_eq!(fs::metadata(&rules_path).unwrap().ino(), first_inode);
    assert_eq!(
        fs::read_to_string(&rules_path).unwrap(),
        "v1\na.example.com\nz.example.com\n"
    );
    assert!(!error_path.exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn ошибки_domain_записываются_атомарно_и_одной_строкой() {
    let root = std::env::temp_dir().join(format!(
        "z2k-domain-error-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    let error_path = root.join("domain-setup-error");
    set_error_file(&error_path, "nft-observer-unavailable").unwrap();
    let inode = fs::metadata(&error_path).unwrap().ino();
    set_error_file(&error_path, "nft-observer-unavailable").unwrap();
    assert_eq!(fs::metadata(&error_path).unwrap().ino(), inode);
    assert_eq!(
        fs::read_to_string(&error_path).unwrap(),
        "nft-observer-unavailable\n"
    );
    assert!(set_error_file(&error_path, "bad\ncode").is_err());
    set_error_file(&error_path, "").unwrap();
    assert!(!error_path.exists());
    fs::remove_dir_all(root).unwrap();
}
