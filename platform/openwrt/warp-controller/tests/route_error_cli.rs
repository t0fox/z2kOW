use std::{
    fs,
    os::unix::fs::{MetadataExt, PermissionsExt},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

fn temp_root() -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "z2k-route-error-{}-{}",
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
fn cli_сохраняет_первую_ошибку_и_очищает_маркер_и_временные_файлы() {
    let root = temp_root();
    let marker = root.join("route-error");
    let first = controller()
        .args([
            "route-error-set",
            marker.to_str().unwrap(),
            "pbr-apply-failed",
        ])
        .status()
        .unwrap();
    assert!(first.success());
    let contents = fs::read_to_string(&marker).unwrap();
    assert!(
        contents
            .trim_end()
            .split_once(' ')
            .is_some_and(|(reason, timestamp)| {
                reason == "pbr-apply-failed" && timestamp.parse::<u64>().is_ok()
            })
    );
    assert_eq!(
        fs::metadata(&marker).unwrap().permissions().mode() & 0o777,
        0o600
    );
    let inode = fs::metadata(&marker).unwrap().ino();

    let second = controller()
        .args([
            "route-error-set",
            marker.to_str().unwrap(),
            "tun-apply-failed",
        ])
        .status()
        .unwrap();
    assert!(second.success());
    assert_eq!(fs::metadata(&marker).unwrap().ino(), inode);
    assert_eq!(fs::read_to_string(&marker).unwrap(), contents);

    let stale = root.join("route-error.new.stale");
    fs::write(&stale, "unfinished\n").unwrap();
    let clear = controller()
        .args(["route-error-clear", marker.to_str().unwrap()])
        .status()
        .unwrap();
    assert!(clear.success());
    assert!(!marker.exists());
    assert!(!stale.exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cli_отклоняет_недопустимый_код_без_записи() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let marker = root.join("route-error");
    let result = controller()
        .args(["route-error-set", marker.to_str().unwrap(), "bad reason"])
        .output()
        .unwrap();
    assert!(!result.status.success());
    assert!(String::from_utf8_lossy(&result.stderr).contains("неверный код ошибки маршрутизации"));
    assert!(!marker.exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn cli_повторная_очистка_успешна_при_отсутствующем_каталоге() {
    let root = temp_root();
    let marker = root.join("route-error");
    let result = controller()
        .args(["route-error-clear", marker.to_str().unwrap()])
        .status()
        .unwrap();
    assert!(result.success());
    assert!(!root.exists());
}
