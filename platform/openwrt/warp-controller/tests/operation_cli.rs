use std::{
    fs,
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

fn temp_root() -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "z2k-warp-operation-{}-{}",
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
fn команды_публикуют_проверяют_и_условно_снимают_намерение() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let marker = root.join("op");

    assert!(
        controller()
            .args(["op-begin", marker.to_str().unwrap(), "101"])
            .status()
            .unwrap()
            .success()
    );
    assert_eq!(fs::read_to_string(&marker).unwrap(), "101\n");
    assert_eq!(
        controller()
            .args(["op-current", marker.to_str().unwrap(), "101"])
            .output()
            .unwrap()
            .stdout,
        b"current\n"
    );
    assert_eq!(
        controller()
            .args(["op-current", marker.to_str().unwrap(), "202"])
            .output()
            .unwrap()
            .stdout,
        b"superseded\n"
    );
    assert!(
        controller()
            .args(["op-clear", marker.to_str().unwrap(), "202"])
            .status()
            .unwrap()
            .success()
    );
    assert_eq!(fs::read_to_string(&marker).unwrap(), "101\n");
    assert!(
        controller()
            .args(["op-clear", marker.to_str().unwrap(), "101"])
            .status()
            .unwrap()
            .success()
    );
    assert!(!marker.exists());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn ошибка_чтения_маркера_не_выдаётся_за_новое_действие() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let marker = root.join("op");
    fs::create_dir(&marker).unwrap();
    let result = controller()
        .args(["op-current", marker.to_str().unwrap(), "101"])
        .output()
        .unwrap();
    assert!(result.status.success());
    assert_eq!(result.stdout, b"unreadable\n");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn одновременные_действия_публикуют_целый_pid_последнего_писателя() {
    let root = temp_root();
    fs::create_dir_all(&root).unwrap();
    let marker = root.join("op");
    let marker_path = marker.to_str().unwrap();
    let mut first = controller()
        .args(["op-begin", marker_path, "101"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    let second = controller()
        .args(["op-begin", marker_path, "202"])
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .unwrap();
    assert!(first.wait().unwrap().success());
    assert!(second.wait_with_output().unwrap().status.success());
    assert!(matches!(
        fs::read_to_string(&marker).unwrap().as_str(),
        "101\n" | "202\n"
    ));
    fs::remove_dir_all(root).unwrap();
}
