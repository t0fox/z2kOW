use std::{fs, path::PathBuf, process::Command, time::Duration};
use warp_controller::lock::MutationLock;

fn temp_dir(label: &str) -> PathBuf {
    let dir = std::env::temp_dir().join(format!(
        "z2k-warp-lock-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&dir).unwrap();
    dir
}

#[test]
fn lock_is_exclusive_and_released_by_owner() {
    let dir = temp_dir("exclusive");
    let path = dir.join("mutate.lock");
    let first = MutationLock::acquire(&path, Duration::ZERO)
        .unwrap()
        .unwrap();
    assert!(
        MutationLock::acquire(&path, Duration::ZERO)
            .unwrap()
            .is_none()
    );
    drop(first);
    assert!(
        MutationLock::acquire(&path, Duration::ZERO)
            .unwrap()
            .is_some()
    );
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn dead_owner_lock_is_reaped() {
    let dir = temp_dir("stale");
    let path = dir.join("mutate.lock");
    fs::create_dir(&path).unwrap();
    fs::write(path.join("owner"), "4294967294 1\n").unwrap();
    let lock = MutationLock::acquire(&path, Duration::ZERO)
        .unwrap()
        .unwrap();
    assert!(path.join("owner").is_file());
    drop(lock);
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn unreadable_owner_is_not_treated_as_stale() {
    let dir = temp_dir("unknown");
    let path = dir.join("mutate.lock");
    fs::create_dir(&path).unwrap();
    assert!(
        MutationLock::acquire(&path, Duration::ZERO)
            .unwrap()
            .is_none()
    );
    assert!(path.is_dir());
    fs::remove_dir_all(dir).unwrap();
}

#[test]
fn shell_process_lock_is_reaped_after_sigkill() {
    let dir = temp_dir("shell-owner-kill");
    let path = dir.join("mutate.lock");
    let mut owner = Command::new("sleep").arg("30").spawn().unwrap();
    assert!(MutationLock::acquire_for_process(&path, owner.id(), Duration::ZERO).unwrap());
    assert!(
        MutationLock::acquire(&path, Duration::ZERO)
            .unwrap()
            .is_none()
    );

    owner.kill().unwrap();
    owner.wait().unwrap();
    let recovered = MutationLock::acquire(&path, Duration::ZERO)
        .unwrap()
        .expect("dead shell owner lock should be recovered");
    drop(recovered);
    assert!(!path.exists());
    fs::remove_dir_all(dir).unwrap();
}
