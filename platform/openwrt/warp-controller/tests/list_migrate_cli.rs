use std::{fs, os::unix::fs::PermissionsExt, path::PathBuf, process::Command};

#[test]
fn cli_мигрирует_устаревший_агрегат_и_оставляет_пользовательский_список() {
    let root = temp_dir();
    let users = root.join("users");
    let games = root.join("games");
    fs::create_dir_all(&users).unwrap();
    let custom = users.join("custom.txt");
    fs::write(&custom, "8.8.8.8\n").unwrap();
    fs::set_permissions(&custom, fs::Permissions::from_mode(0o600)).unwrap();
    fs::write(users.join("game-warp-ips.txt"), "legacy\n").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args([
            "list-migrate",
            users.to_str().unwrap(),
            games.to_str().unwrap(),
        ])
        .env("Z2K_WARP_LOCK_DIR", root.join("global.lock"))
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(games.is_dir());
    assert!(users.join(".legacy-aggregate-purged").is_file());
    assert!(!users.join("game-warp-ips.txt").exists());
    assert_eq!(fs::read_to_string(custom).unwrap(), "8.8.8.8\n");
    assert!(!root.join("global.lock").exists());
    fs::remove_dir_all(root).unwrap();
}

fn temp_dir() -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "z2k-warp-list-migrate-cli-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}
