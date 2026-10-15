use std::{
    fs,
    path::PathBuf,
    process::Command,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use warp_controller::lock::MutationLock;

fn temp_lock() -> (PathBuf, PathBuf) {
    let root = std::env::temp_dir().join(format!(
        "z2k-warp-lock-cli-{}-{}",
        std::process::id(),
        SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&root).unwrap();
    let lock = root.join("mutate.lock");
    (root, lock)
}

fn run_lock_command(lock: &std::path::Path, args: &[&str]) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args(args)
        .env("Z2K_WARP_LOCK_DIR", lock)
        .output()
        .unwrap()
}

#[test]
fn lock_cli_holds_for_shell_pid_until_explicit_release() {
    let (root, lock) = temp_lock();
    let pid = std::process::id().to_string();

    let acquired = run_lock_command(&lock, &["lock-acquire", &pid, "0"]);
    assert!(
        acquired.status.success(),
        "lock acquire failed: {}",
        String::from_utf8_lossy(&acquired.stderr)
    );
    assert!(lock.is_dir());
    assert_eq!(fs::read_to_string(lock.join("pid")).unwrap().trim(), pid);
    assert!(
        MutationLock::acquire(&lock, Duration::ZERO)
            .unwrap()
            .is_none()
    );

    let foreign_release = run_lock_command(&lock, &["lock-release", "4294967294"]);
    assert!(!foreign_release.status.success());
    assert!(lock.is_dir());

    let released = run_lock_command(&lock, &["lock-release", &pid]);
    assert!(
        released.status.success(),
        "lock release failed: {}",
        String::from_utf8_lossy(&released.stderr)
    );
    assert!(!lock.exists());
    fs::remove_dir_all(root).unwrap();
}
