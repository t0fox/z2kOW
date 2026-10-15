use std::{
    fs,
    os::unix::fs::PermissionsExt,
    process::{Command, Output},
    time::{SystemTime, UNIX_EPOCH},
};

fn temp_root() -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "z2k-warp-boot-plan-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ))
}

fn run(config: &std::path::Path, binary: &std::path::Path, device: &std::path::Path) -> Output {
    Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args([
            "boot-plan",
            config.to_str().unwrap(),
            binary.to_str().unwrap(),
            device.to_str().unwrap(),
        ])
        .output()
        .expect("запуск CLI-контроллера")
}

#[test]
fn boot_plan_сохраняет_порядок_конфигурации_и_проверяет_файлы() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let config = root.join("config");
    let binary = root.join("z2k-warpd");
    let device = root.join("device.json");
    fs::write(
        &config,
        "ENABLED=0\nENABLED=1\nGAME_WARP_ENABLED=1\nGAME_WARP_ENABLED=0\n",
    )
    .unwrap();
    fs::write(&binary, "engine").unwrap();
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(&device, "registered\n").unwrap();
    let wanted = run(&config, &binary, &device);
    assert!(wanted.status.success());
    assert_eq!(wanted.stdout, b"wanted\n");

    fs::write(&config, "ENABLED=0\nGAME_WARP_ENABLED=1\n").unwrap();
    assert_eq!(run(&config, &binary, &device).stdout, b"unwanted\n");
    fs::write(&config, "ENABLED=1\nGAME_WARP_ENABLED=0\n").unwrap();
    assert_eq!(run(&config, &binary, &device).stdout, b"unwanted\n");
    fs::write(&config, "ENABLED=1\nGAME_WARP_ENABLED=1\n").unwrap();
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o644)).unwrap();
    assert_eq!(run(&config, &binary, &device).stdout, b"unwanted\n");
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(&device, b"").unwrap();
    assert_eq!(run(&config, &binary, &device).stdout, b"unwanted\n");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn boot_plan_откладывает_нечитаемую_конфигурацию() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let config = root.join("config");
    let binary = root.join("z2k-warpd");
    let device = root.join("device.json");
    fs::create_dir(&config).unwrap();
    fs::write(&binary, "engine").unwrap();
    fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
    fs::write(&device, "registered\n").unwrap();

    let result = run(&config, &binary, &device);
    assert!(result.status.success());
    assert_eq!(result.stdout, b"defer\n");
    fs::remove_dir_all(root).unwrap();
}
