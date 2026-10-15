use std::{
    fs,
    os::unix::fs::MetadataExt,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

fn temp_root() -> std::path::PathBuf {
    std::env::temp_dir().join(format!(
        "z2k-warp-recovery-{}-{}",
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
fn claim_is_one_shot_and_clear_is_idempotent() {
    let root = temp_root();
    let marker = root.join("procd-recovery-attempt");
    let first = controller()
        .args(["procd-recovery-claim", marker.to_str().unwrap(), "12345"])
        .output()
        .unwrap();
    assert!(first.status.success());
    assert_eq!(first.stdout, b"claimed\n");
    let contents = fs::read(&marker).unwrap();
    assert_eq!(contents, b"attempted 12345\n");
    let inode = fs::metadata(&marker).unwrap().ino();

    let second = controller()
        .args(["procd-recovery-claim", marker.to_str().unwrap(), "67890"])
        .output()
        .unwrap();
    assert!(second.status.success());
    assert_eq!(second.stdout, b"exists\n");
    assert_eq!(fs::metadata(&marker).unwrap().ino(), inode);
    assert_eq!(fs::read(&marker).unwrap(), contents);

    let clear = controller()
        .args(["procd-recovery-clear", marker.to_str().unwrap()])
        .status()
        .unwrap();
    assert!(clear.success());
    assert!(!marker.exists());
    assert!(
        controller()
            .args(["procd-recovery-clear", marker.to_str().unwrap()])
            .status()
            .unwrap()
            .success()
    );
    assert!(
        !marker
            .with_file_name(".procd-recovery-attempt.mutate.lock")
            .exists()
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn concurrent_recovery_claims_publish_only_one_attempt() {
    let root = temp_root();
    let marker = root.join("procd-recovery-attempt");
    let path = marker.to_str().unwrap();
    let first = controller()
        .args(["procd-recovery-claim", path, "1"])
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let second = controller()
        .args(["procd-recovery-claim", path, "2"])
        .stdout(std::process::Stdio::piped())
        .spawn()
        .unwrap();
    let first = first.wait_with_output().unwrap();
    let second = second.wait_with_output().unwrap();
    assert!(first.status.success());
    assert!(second.status.success());
    let outputs = [first.stdout, second.stdout];
    assert!(outputs.contains(&b"claimed\n".to_vec()));
    assert!(outputs.contains(&b"exists\n".to_vec()));
    assert!(matches!(
        fs::read(&marker).unwrap().as_slice(),
        b"attempted 1\n" | b"attempted 2\n"
    ));
    assert!(
        !marker
            .with_file_name("procd-recovery-attempt.lock")
            .exists()
    );
    fs::remove_dir_all(root).unwrap();
}
