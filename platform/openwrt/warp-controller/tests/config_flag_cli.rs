use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

fn temp_root() -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "z2k-warp-config-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn controller() -> Command {
    Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
}

#[test]
fn команда_заменяет_только_warp_flag_и_сохраняет_формат_конфига() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let config = root.join("config");
    fs::write(
        &config,
        "# настройка\nGAME_WARP_ENABLED=1\nOTHER_FEATURE=keep\nGAME_WARP_ENABLED=0",
    )
    .unwrap();
    fs::set_permissions(&config, fs::Permissions::from_mode(0o640)).unwrap();

    let result = controller()
        .args(["warp-flag-set", config.to_str().unwrap(), "0"])
        .status()
        .unwrap();
    assert!(result.success());
    assert_eq!(
        fs::read_to_string(&config).unwrap(),
        "# настройка\nGAME_WARP_ENABLED=0\nOTHER_FEATURE=keep\nGAME_WARP_ENABLED=0\n"
    );
    assert_eq!(
        fs::metadata(&config).unwrap().permissions().mode() & 0o777,
        0o640
    );
    let inode = fs::metadata(&config).unwrap().ino();
    assert!(
        controller()
            .args(["warp-flag-set", config.to_str().unwrap(), "0"])
            .status()
            .unwrap()
            .success()
    );
    assert_eq!(fs::metadata(&config).unwrap().ino(), inode);
    assert!(!root.join("config.z2k-flaglock").exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn команда_добавляет_отсутствующий_flag_и_отклоняет_неверное_значение() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let config = root.join("config");
    fs::write(&config, "OTHER_FEATURE=keep").unwrap();
    assert!(
        controller()
            .args(["warp-flag-set", config.to_str().unwrap(), "1"])
            .status()
            .unwrap()
            .success()
    );
    assert_eq!(
        fs::read_to_string(&config).unwrap(),
        "OTHER_FEATURE=keep\nGAME_WARP_ENABLED=1\n"
    );
    let before = fs::read(&config).unwrap();
    let invalid = controller()
        .args(["warp-flag-set", config.to_str().unwrap(), "true"])
        .output()
        .unwrap();
    assert!(!invalid.status.success());
    assert_eq!(fs::read(&config).unwrap(), before);
    assert!(String::from_utf8_lossy(&invalid.stderr).contains("неверный флаг WARP"));
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn занятый_канонический_lock_не_меняет_конфиг() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let config = root.join("config");
    fs::write(&config, "GAME_WARP_ENABLED=1\nOTHER_FEATURE=keep\n").unwrap();
    let before = fs::read(&config).unwrap();
    fs::create_dir(config.with_file_name("config.z2k-flaglock")).unwrap();
    let result = controller()
        .args(["warp-flag-set", config.to_str().unwrap(), "0"])
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert_eq!(fs::read(&config).unwrap(), before);
    assert!(config.with_file_name("config.z2k-flaglock").is_dir());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn конкурентные_установки_flag_оставляют_целый_конфиг() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let config = root.join("config");
    fs::write(&config, "OTHER_FEATURE=keep\nGAME_WARP_ENABLED=1\n").unwrap();
    let path = config.to_str().unwrap();
    let mut first = controller()
        .args(["warp-flag-set", path, "0"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let second = controller()
        .args(["warp-flag-set", path, "1"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert!(first.wait().unwrap().success());
    assert!(second.wait_with_output().unwrap().status.success());
    let contents = fs::read_to_string(&config).unwrap();
    assert!(contents.starts_with("OTHER_FEATURE=keep\n"));
    assert!(contents.ends_with("\n"));
    assert!(
        contents.contains("GAME_WARP_ENABLED=0\n") || contents.contains("GAME_WARP_ENABLED=1\n")
    );
    assert!(!config.with_file_name("config.z2k-flaglock").exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cli_записывает_wdtt_тем_же_атомарным_контрактом() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let config = root.join("config");
    fs::write(
        &config,
        "GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT=0\nOTHER_FEATURE=keep\n",
    )
    .unwrap();

    let result = controller()
        .args([
            "config-flag-set",
            config.to_str().unwrap(),
            "Z2K_WARP_WDTT",
            "1",
        ])
        .status()
        .unwrap();
    assert!(result.success());
    assert_eq!(
        fs::read_to_string(&config).unwrap(),
        "GAME_WARP_ENABLED=1\nZ2K_WARP_WDTT=1\nOTHER_FEATURE=keep\n"
    );

    let before = fs::read(&config).unwrap();
    let invalid = controller()
        .args([
            "config-flag-set",
            config.to_str().unwrap(),
            "OTHER_FEATURE",
            "0",
        ])
        .output()
        .unwrap();
    assert!(!invalid.status.success());
    assert_eq!(fs::read(&config).unwrap(), before);
    assert!(!config.with_file_name("config.z2k-flaglock").exists());
    fs::remove_dir_all(root).unwrap();
}
