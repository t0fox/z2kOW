use std::{
    fs,
    path::Path,
    process::Command,
    sync::atomic::{AtomicU64, Ordering},
    time::{SystemTime, UNIX_EPOCH},
};

static STATUS_NONCE: AtomicU64 = AtomicU64::new(0);

fn observe(path: &Path) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .arg("state-observe")
        .arg(path)
        .output()
        .expect("запуск CLI-контроллера");
    assert!(
        output.status.success(),
        "CLI завершился с ошибкой: {:?}",
        output
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn temporary_status() -> std::path::PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!(
        "z2k-warp-status-{}-{nonce}-{}.json",
        std::process::id(),
        STATUS_NONCE.fetch_add(1, Ordering::Relaxed)
    ))
}

#[test]
fn готовый_status_возвращает_ready_и_iface_одним_чтением() {
    let path = temporary_status();
    fs::write(
        &path,
        r#"{"ready":true,"transport":"wg","iface":"z2ktun0","addr":"10.0.0.2"}"#,
    )
    .unwrap();

    assert_eq!(observe(&path), "ready z2ktun0");
    fs::remove_file(path).unwrap();
}

#[test]
fn неготовый_status_отличается_от_ошибки_чтения() {
    let path = temporary_status();
    fs::write(&path, r#"{"ready":false,"iface":"z2ktun0"}"#).unwrap();

    assert_eq!(observe(&path), "not-ready");
    fs::remove_file(path).unwrap();
}

#[test]
fn отсутствующий_или_повреждённый_status_откладывает_решение() {
    let path = temporary_status();
    assert_eq!(observe(&path), "unreadable");
    fs::write(&path, "{partial").unwrap();
    assert_eq!(observe(&path), "unreadable");
    fs::remove_file(path).unwrap();
}
