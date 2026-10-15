use std::{
    fs,
    path::PathBuf,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
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
        let root =
            std::env::temp_dir().join(format!("z2k-warp-runtime-{}-{nonce}", std::process::id()));
        let proc_root = root.join("proc");
        fs::create_dir_all(&proc_root).unwrap();
        let status = root.join("status.json");
        Self {
            root,
            status,
            proc_root,
        }
    }

    fn ready_status(&self) {
        fs::write(&self.status, r#"{"ready":true,"iface":"z2ktun0"}"#).unwrap();
    }

    fn process(&self) {
        let process = self.proc_root.join("101");
        fs::create_dir_all(&process).unwrap();
        fs::write(process.join("comm"), "z2k-warpd\n").unwrap();
        fs::write(process.join("cmdline"), b"/usr/bin/z2k-warpd\0run\0").unwrap();
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

fn observe(fixture: &Fixture) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .arg("runtime-observe")
        .arg(&fixture.status)
        .arg(&fixture.proc_root)
        .output()
        .expect("запуск CLI-контроллера");
    assert!(
        output.status.success(),
        "CLI завершился с ошибкой: {:?}",
        output
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

#[test]
fn отсутствующий_процесс_отличается_от_готового_status() {
    let fixture = Fixture::new();
    fixture.ready_status();

    assert_eq!(observe(&fixture), "not-ready absent -");
}

#[test]
fn ошибка_чтения_proc_не_превращается_в_отсутствие_процесса() {
    let fixture = Fixture::new();
    fixture.ready_status();
    fs::remove_dir(&fixture.proc_root).unwrap();
    fs::write(&fixture.proc_root, "это файл, а не proc root").unwrap();

    assert_eq!(observe(&fixture), "unreadable unreadable -");
}

#[test]
fn статус_не_ready_при_живом_движке_не_считается_ошибкой_чтения() {
    let fixture = Fixture::new();
    fixture.process();
    fs::write(&fixture.status, r#"{"ready":false}"#).unwrap();

    assert_eq!(observe(&fixture), "not-ready present -");
}

#[test]
fn ошибка_чтения_status_при_живом_движке_откладывает_решение() {
    let fixture = Fixture::new();
    fixture.process();

    assert_eq!(observe(&fixture), "unreadable present -");
}
