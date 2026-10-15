use std::{
    fs::{self, FileTimes},
    path::PathBuf,
    process::Command,
    time::{Duration, SystemTime, UNIX_EPOCH},
};
use warp_controller::{
    health::ready_since,
    state::{EngineStatus, ProcessStatus, RuntimeReadiness, read_engine_status_file},
};

struct Fixture {
    root: PathBuf,
    status: PathBuf,
    proc_root: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "z2k-warp-ready-wait-{}-{nonce}",
            std::process::id()
        ));
        let proc_root = root.join("proc");
        fs::create_dir_all(&proc_root).unwrap();
        let process = proc_root.join("101");
        fs::create_dir_all(&process).unwrap();
        fs::write(process.join("comm"), "z2k-warpd\n").unwrap();
        fs::write(process.join("cmdline"), b"/usr/bin/z2k-warpd\0run\0").unwrap();
        Self {
            status: root.join("status.json"),
            root,
            proc_root,
        }
    }

    fn observe_since(&self, started_at: u64) -> (bool, String) {
        let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
            .args([
                "ready-observe-since",
                self.status.to_str().unwrap(),
                self.proc_root.to_str().unwrap(),
                &started_at.to_string(),
            ])
            .output()
            .expect("запуск CLI-контроллера");
        (
            output.status.success(),
            String::from_utf8(output.stdout).unwrap().trim().to_owned(),
        )
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn устаревший_ready_остаётся_not_ready_при_живом_процессе() {
    let fixture = Fixture::new();
    fs::write(&fixture.status, r#"{"ready":true,"iface":"z2ktun0"}"#).unwrap();
    let started_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs()
        + 60;

    assert_eq!(
        fixture.observe_since(started_at),
        (true, "not-ready".into())
    );
}

#[test]
fn повреждённый_status_остаётся_unreadable() {
    let fixture = Fixture::new();
    fs::write(&fixture.status, "{partial").unwrap();

    assert_eq!(fixture.observe_since(1), (true, "unreadable".into()));
}

#[test]
fn нулевое_время_начала_не_подтверждает_ready() {
    let fixture = Fixture::new();
    fs::write(&fixture.status, r#"{"ready":true,"iface":"z2ktun0"}"#).unwrap();

    assert!(!fixture.observe_since(0).0);
}

#[test]
fn чтение_сохраняет_mtime_того_же_inode_что_и_json() {
    let fixture = Fixture::new();
    fs::write(&fixture.status, r#"{"ready":true,"iface":"z2ktun0"}"#).unwrap();
    let opened = fs::File::open(&fixture.status).unwrap();
    let old_mtime = fs::metadata(&fixture.status)
        .unwrap()
        .modified()
        .unwrap()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_secs();

    let replacement_path = fixture.root.join("replacement.json");
    let replacement = fs::File::create(&replacement_path).unwrap();
    fs::write(&replacement_path, r#"{"ready":false}"#).unwrap();
    replacement
        .set_times(FileTimes::new().set_modified(UNIX_EPOCH + Duration::from_secs(old_mtime + 2)))
        .unwrap();
    fs::rename(replacement_path, &fixture.status).unwrap();

    let (engine, modified) = read_engine_status_file(opened);
    assert_eq!(
        engine,
        EngineStatus::Ready {
            iface: "z2ktun0".into()
        }
    );
    assert_eq!(modified, Some(old_mtime));
    assert_eq!(
        ready_since(
            ProcessStatus::Present,
            engine,
            Some(true),
            modified,
            old_mtime + 1,
        ),
        RuntimeReadiness::NotReady
    );
}
