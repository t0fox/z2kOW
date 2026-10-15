use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

struct Fixture {
    root: PathBuf,
    config: PathBuf,
    binary: PathBuf,
    device: PathBuf,
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
            "z2k-warp-health-plan-{}-{nonce}",
            std::process::id()
        ));
        let proc_root = root.join("proc");
        fs::create_dir_all(&proc_root).unwrap();
        let config = root.join("config");
        fs::write(&config, "ENABLED=1\nGAME_WARP_ENABLED=1\n").unwrap();
        let binary = root.join("z2k-warpd");
        fs::write(&binary, "engine placeholder").unwrap();
        fs::set_permissions(&binary, fs::Permissions::from_mode(0o755)).unwrap();
        let device = root.join("device.json");
        fs::write(&device, "{}\n").unwrap();
        Self {
            status: root.join("status.json"),
            root,
            config,
            binary,
            device,
            proc_root,
        }
    }

    fn process(&self) {
        let process = self.proc_root.join("101");
        fs::create_dir_all(&process).unwrap();
        fs::write(process.join("comm"), "z2k-warpd\n").unwrap();
        fs::write(process.join("cmdline"), b"/usr/bin/z2k-warpd\0run\0").unwrap();
    }

    fn run(&self) -> String {
        let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
            .args([
                "health-plan",
                self.config.to_str().unwrap(),
                self.binary.to_str().unwrap(),
                self.device.to_str().unwrap(),
                self.status.to_str().unwrap(),
                self.proc_root.to_str().unwrap(),
            ])
            .output()
            .expect("запуск CLI-контроллера");
        assert!(
            output.status.success(),
            "CLI завершился с ошибкой: {output:?}"
        );
        String::from_utf8(output.stdout).unwrap().trim().to_owned()
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn health_plan_отключает_явно_выключенную_функцию() {
    let fixture = Fixture::new();
    fs::write(&fixture.config, "ENABLED=0\nGAME_WARP_ENABLED=1\n").unwrap();

    assert_eq!(fixture.run(), "disabled");
}

#[test]
fn health_plan_откладывает_временную_ошибку_чтения_конфига() {
    let fixture = Fixture::new();
    fs::remove_file(&fixture.config).unwrap();
    fs::create_dir(&fixture.config).unwrap();

    assert_eq!(fixture.run(), "defer");
}

#[test]
fn health_plan_не_перепутывает_отсутствующий_движок_и_отключение() {
    let fixture = Fixture::new();
    fs::remove_file(&fixture.binary).unwrap();

    assert_eq!(fixture.run(), "binary-missing");
}

#[test]
fn health_plan_различает_отсутствующую_регистрацию_и_живой_движок() {
    let fixture = Fixture::new();
    fs::remove_file(&fixture.device).unwrap();

    assert_eq!(fixture.run(), "device-missing");
}

#[test]
fn health_plan_возвращает_process_absent_для_проверенного_пустого_procfs() {
    let fixture = Fixture::new();
    fs::write(&fixture.device, "{\"id\":\"registered\"}\n").unwrap();

    assert_eq!(fixture.run(), "process-absent");
}

#[test]
fn health_plan_не_отключает_живой_но_неготовый_туннель_как_ошибку_чтения() {
    let fixture = Fixture::new();
    fs::write(&fixture.device, "{\"id\":\"registered\"}\n").unwrap();
    fs::write(&fixture.status, r#"{"ready":false}"#).unwrap();
    fixture.process();

    assert_eq!(fixture.run(), "not-ready");
}

#[test]
fn health_plan_откладывает_ошибку_status_живого_процесса() {
    let fixture = Fixture::new();
    fs::write(&fixture.device, "{\"id\":\"registered\"}\n").unwrap();
    fixture.process();

    assert_eq!(fixture.run(), "defer");
}
