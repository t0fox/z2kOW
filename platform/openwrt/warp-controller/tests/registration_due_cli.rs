use std::{
    fs,
    path::{Path, PathBuf},
    process::{Command, Output},
};

struct TempDir(PathBuf);

impl TempDir {
    fn new(label: &str) -> Self {
        let path = std::env::temp_dir().join(format!(
            "z2k-warp-registration-due-{}-{label}",
            std::process::id()
        ));
        let _ = fs::remove_dir_all(&path);
        fs::create_dir_all(&path).expect("временный каталог");
        Self(path)
    }

    fn path(&self) -> &Path {
        &self.0
    }
}

impl Drop for TempDir {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.0);
    }
}

fn run(path: &Path, now: &str, retry: &str) -> Output {
    Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args(["register-due", path.to_str().unwrap(), now, retry])
        .output()
        .expect("запуск CLI-контроллера")
}

#[test]
fn missing_or_stale_registration_stamp_is_due() {
    let temp = TempDir::new("stale");
    let stamp = temp.path().join("register-attempt");
    let missing = run(&stamp, "1000", "300");
    assert!(missing.status.success());
    assert_eq!(missing.stdout, b"due\n");

    fs::write(&stamp, "100\n").expect("устаревшая метка");
    let stale = run(&stamp, "1000", "300");
    assert!(stale.status.success());
    assert_eq!(stale.stdout, b"due\n");
}

#[test]
fn recent_or_future_registration_stamp_waits() {
    let temp = TempDir::new("recent");
    let stamp = temp.path().join("register-attempt");
    fs::write(&stamp, "900\n").expect("актуальная метка");
    let recent = run(&stamp, "1000", "300");
    assert!(recent.status.success());
    assert_eq!(recent.stdout, b"wait\n");

    fs::write(&stamp, "1100\n").expect("метка из будущего");
    let future = run(&stamp, "1000", "300");
    assert!(future.status.success());
    assert_eq!(future.stdout, b"wait\n");
}

#[test]
fn malformed_registration_stamp_preserves_stale_fallback() {
    let temp = TempDir::new("malformed");
    let stamp = temp.path().join("register-attempt");
    fs::write(&stamp, "not-an-epoch\n").expect("повреждённая метка");
    let output = run(&stamp, "1000", "300");
    assert!(output.status.success());
    assert_eq!(output.stdout, b"due\n");
}

#[test]
fn unreadable_registration_stamp_defers_without_retrying_registration() {
    let temp = TempDir::new("unreadable");
    let output = run(temp.path(), "1000", "300");
    assert!(output.status.success());
    assert_eq!(output.stdout, b"defer\n");
}

#[test]
fn registration_due_rejects_invalid_arguments() {
    let binary = env!("CARGO_BIN_EXE_z2k-warp-controller");
    for arguments in [
        vec!["register-due", "/tmp/stamp", "invalid", "300"],
        vec!["register-due", "/tmp/stamp", "1000", "invalid"],
        vec!["register-due", "/tmp/stamp", "1000", "300", "extra"],
    ] {
        let output = Command::new(binary)
            .args(arguments)
            .output()
            .expect("запуск CLI-контроллера");
        assert!(!output.status.success(), "аргументы должны быть отклонены");
    }
}
