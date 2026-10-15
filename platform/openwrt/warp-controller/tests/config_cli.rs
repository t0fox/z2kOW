use std::{fs, path::PathBuf, process::Command, time::SystemTime};

fn temp_root() -> PathBuf {
    let root = std::env::temp_dir().join(format!(
        "z2k-warp-config-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&root).unwrap();
    root
}

fn read_config(
    path: &std::path::Path,
    key: &str,
    default: &str,
    order: &str,
) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args(["config-read", path.to_str().unwrap(), key, default, order])
        .output()
        .unwrap()
}

#[test]
fn config_cli_preserves_first_last_and_default_contracts() {
    let root = temp_root();
    let config = root.join("config");
    fs::write(
        &config,
        "GAME_WARP_ENABLED=1\nGAME_WARP_ENABLED=0\nZ2K_WARP_TRANSPORT=\" h2 \"\nENABLED=\n",
    )
    .unwrap();

    let first = read_config(&config, "GAME_WARP_ENABLED", "", "first");
    assert!(first.status.success());
    assert_eq!(String::from_utf8(first.stdout).unwrap(), "1\n");

    let last = read_config(&config, "GAME_WARP_ENABLED", "", "last");
    assert!(last.status.success());
    assert_eq!(String::from_utf8(last.stdout).unwrap(), "0\n");

    let transport = read_config(&config, "Z2K_WARP_TRANSPORT", "auto", "last");
    assert!(transport.status.success());
    assert_eq!(String::from_utf8(transport.stdout).unwrap(), "h2\n");

    let enabled = read_config(&config, "ENABLED", "1", "last");
    assert!(enabled.status.success());
    assert_eq!(String::from_utf8(enabled.stdout).unwrap(), "1\n");

    let absent = read_config(&root.join("missing"), "ENABLED", "1", "last");
    assert!(absent.status.success());
    assert_eq!(String::from_utf8(absent.stdout).unwrap(), "1\n");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn config_cli_reports_read_errors() {
    let root = temp_root();
    let output = read_config(&root, "ENABLED", "1", "last");
    let _ = fs::remove_dir_all(&root);
    assert!(!output.status.success());
}
