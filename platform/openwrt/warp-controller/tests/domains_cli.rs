use std::{
    fs,
    os::unix::fs::PermissionsExt,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

fn temporary_root() -> std::path::PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root =
        std::env::temp_dir().join(format!("z2k-warp-domains-{}-{nonce}", std::process::id()));
    fs::create_dir_all(&root).unwrap();
    root
}

#[test]
fn domains_cli_preserves_go_file_contract_and_keeps_last_good_state_on_read_error() {
    let root = temporary_root();
    let users = root.join("users");
    let games = root.join("games");
    let enabled = users.join(".enabled");
    let rules = root.join("domains.v1");
    let error = root.join("domain-setup-error");
    let lock = root.join("mutate.lock");
    fs::create_dir_all(&users).unwrap();
    fs::create_dir_all(&games).unwrap();
    fs::write(users.join("mine.txt"), "Z.example.com\nA.example.com\n").unwrap();
    fs::write(users.join("disabled.txt"), "disabled.example\n").unwrap();
    fs::write(users.join(".disabled"), "disabled\n").unwrap();
    fs::write(&enabled, "game\n").unwrap();
    fs::write(games.join("game.txt"), "Game.example\n").unwrap();

    let list = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args([
            "domains-list",
            users.to_str().unwrap(),
            games.to_str().unwrap(),
            enabled.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        list.status.success(),
        "{}",
        String::from_utf8_lossy(&list.stderr)
    );
    assert_eq!(
        String::from_utf8(list.stdout).unwrap(),
        "a.example.com\ngame.example\nz.example.com\n"
    );

    let sync = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .env("Z2K_WARP_LOCK_DIR", &lock)
        .args([
            "domains-sync",
            users.to_str().unwrap(),
            games.to_str().unwrap(),
            enabled.to_str().unwrap(),
            rules.to_str().unwrap(),
            error.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(
        sync.status.success(),
        "{}",
        String::from_utf8_lossy(&sync.stderr)
    );
    assert_eq!(
        fs::read_to_string(&rules).unwrap(),
        "v1\na.example.com\ngame.example\nz.example.com\n"
    );
    assert_eq!(
        fs::metadata(&rules).unwrap().permissions().mode() & 0o777,
        0o600
    );

    fs::write(users.join("mine.txt"), [0xff]).unwrap();
    let unreadable = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .env("Z2K_WARP_LOCK_DIR", &lock)
        .args([
            "domains-sync",
            users.to_str().unwrap(),
            games.to_str().unwrap(),
            enabled.to_str().unwrap(),
            rules.to_str().unwrap(),
            error.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    assert!(!unreadable.status.success());
    assert_eq!(
        fs::read_to_string(&rules).unwrap(),
        "v1\na.example.com\ngame.example\nz.example.com\n"
    );
    fs::remove_dir_all(root).unwrap();
}
