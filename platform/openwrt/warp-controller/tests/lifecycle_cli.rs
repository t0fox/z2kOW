use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Command, Stdio},
    time::{SystemTime, UNIX_EPOCH},
};

struct Fixture {
    root: PathBuf,
    engine: PathBuf,
    trace: PathBuf,
    config: PathBuf,
    device: PathBuf,
    user_lists: PathBuf,
    games: PathBuf,
}

impl Fixture {
    fn new() -> Self {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let root = std::env::temp_dir().join(format!(
            "z2k-warp-lifecycle-cli-{}-{nonce}",
            std::process::id()
        ));
        let user_lists = root.join("user-lists");
        let games = root.join("games");
        fs::create_dir_all(&user_lists).unwrap();
        fs::create_dir_all(&games).unwrap();
        let engine = root.join("z2k-warpd");
        fs::write(
            &engine,
            r##"#!/bin/sh
printf '%s\n' "$*" >> "$TRACE"
case "$1" in
  version) echo fixture-engine; exit 0 ;;
  register)
    shift
    [ "$1" = --device ] || exit 20
    printf '{"registered":true}\n' > "$2"
    exit "${REGISTER_RC:-0}"
    ;;
  license)
    cat > "$LICENSE_INPUT"
    printf 'license-result\n'
    exit "${LICENSE_RC:-0}"
    ;;
esac
exit 21
"##,
        )
        .unwrap();
        let mut permissions = fs::metadata(&engine).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(&engine, permissions).unwrap();
        Self {
            trace: root.join("engine.trace"),
            config: root.join("config"),
            device: root.join("state/warp/device.json"),
            user_lists,
            games,
            root,
            engine,
        }
    }

    fn controller(&self, command_name: &str) -> Command {
        let mut command = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"));
        command
            .arg(command_name)
            .env("WARP_BIN", &self.engine)
            .env("WARP_DEVICE", &self.device)
            .env("CONFIG_FILE", &self.config)
            .env("WARP_LISTS_DIR", &self.user_lists)
            .env("WARP_GAMES_DIR", &self.games)
            .env("WARP_ENABLED_FILE", self.user_lists.join(".enabled"))
            .env("WARP_DEVICES_FILE", self.user_lists.join("devices.txt"))
            .env("Z2K_WARP_LOCK_DIR", self.root.join("warp/mutate.lock"))
            .env("Z2K_WARP_PROTOCOL_VERSION", "1")
            .env("TRACE", &self.trace)
            .env("LICENSE_INPUT", self.root.join("license.input"));
        command
    }

    fn system_commands(&self) -> PathBuf {
        let bin = self.root.join("bin");
        fs::create_dir_all(&bin).unwrap();
        for (name, body) in [
            ("ip", "#!/bin/sh\nexit 0\n"),
            ("nft", "#!/bin/sh\nexit 0\n"),
            ("ubus", "#!/bin/sh\nprintf '{}\\n'\n"),
        ] {
            let path = bin.join(name);
            fs::write(&path, body).unwrap();
            let mut permissions = fs::metadata(&path).unwrap().permissions();
            permissions.set_mode(0o755);
            fs::set_permissions(path, permissions).unwrap();
        }
        bin
    }
}

impl Drop for Fixture {
    fn drop(&mut self) {
        let _ = fs::remove_dir_all(&self.root);
    }
}

#[test]
fn install_проверяет_версию_регистрирует_движок_и_закрывает_права_ключа() {
    let fixture = Fixture::new();
    let output = fixture.controller("install").output().unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(&fixture.trace).unwrap(),
        format!("version\nregister --device {}\n", fixture.device.display())
    );
    assert_eq!(
        fs::metadata(&fixture.device).unwrap().permissions().mode() & 0o777,
        0o600
    );
    assert!(fixture.user_lists.join(".legacy-aggregate-purged").exists());
}

#[test]
fn license_передаёт_ключ_только_через_stdin_и_сохраняет_вывод() {
    let fixture = Fixture::new();
    let mut command = fixture.controller("license");
    command
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn().unwrap();
    use std::io::Write;
    child
        .stdin
        .take()
        .unwrap()
        .write_all(b"secret-license-key\n")
        .unwrap();
    let output = child.wait_with_output().unwrap();

    assert!(output.status.success());
    assert_eq!(output.stdout, b"license-result\n");
    assert_eq!(
        fs::read(fixture.root.join("license.input")).unwrap(),
        b"secret-license-key\n"
    );
    assert_eq!(
        fs::read_to_string(&fixture.trace).unwrap(),
        format!("license --device {}\n", fixture.device.display())
    );
}

#[test]
fn restart_выключенного_warp_идемпотентен_и_не_трогает_конфигурацию() {
    let fixture = Fixture::new();
    fs::write(&fixture.config, "GAME_WARP_ENABLED=0\nother=value\n").unwrap();
    let output = fixture
        .controller("lifecycle")
        .arg("restart")
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(&fixture.config).unwrap(),
        "GAME_WARP_ENABLED=0\nother=value\n"
    );
    assert!(!fixture.trace.exists());
}

#[test]
fn enable_при_отсутствующем_движке_откатывает_флаг_и_снимает_lock() {
    let fixture = Fixture::new();
    fs::write(&fixture.config, "GAME_WARP_ENABLED=0\nother=value\n").unwrap();
    let output = fixture
        .controller("lifecycle")
        .arg("enable")
        .env("WARP_BIN", fixture.root.join("missing-engine"))
        .env("WARP_OP_FILE", fixture.root.join("warp/op"))
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("движок WARP не установлен"));
    assert_eq!(
        fs::read_to_string(&fixture.config).unwrap(),
        "GAME_WARP_ENABLED=0\nother=value\n"
    );
    assert!(!fixture.root.join("warp/mutate.lock").exists());
    assert!(!fixture.root.join("warp/op").exists());
}

#[test]
fn remove_очищает_состояние_и_сохраняет_регистрацию_лицензию_и_списки() {
    let fixture = Fixture::new();
    let account = fixture.device.parent().unwrap().join("account.json");
    let license = fixture.device.parent().unwrap().join("license");
    fs::create_dir_all(fixture.device.parent().unwrap()).unwrap();
    fs::create_dir_all(fixture.root.join("proc")).unwrap();
    fs::write(&fixture.device, "device sentinel\n").unwrap();
    fs::write(&account, "account sentinel\n").unwrap();
    fs::write(&license, "license sentinel\n").unwrap();
    fs::write(fixture.user_lists.join("custom.txt"), "192.0.2.4\n").unwrap();
    fs::write(&fixture.config, "GAME_WARP_ENABLED=1\nother=value\n").unwrap();
    let bin = fixture.system_commands();
    let output = fixture
        .controller("lifecycle")
        .arg("remove")
        .env("WARP_BIN", &fixture.engine)
        .env("WARP_DOMAIN_RUNTIME_BIN", "/usr/bin/z2k-warpd")
        .env("WARP_STATUS", fixture.root.join("status.json"))
        .env("WARP_PBR_OWNER", fixture.root.join("pbr.owner"))
        .env("WARP_PROBE_OWNER", fixture.root.join("probe.owner"))
        .env("WARP_ROUTE_ERROR_FILE", fixture.root.join("route-error"))
        .env(
            "WARP_PROCD_INSTANCE_FILE",
            fixture.root.join("procd-instance"),
        )
        .env("WARP_PROCD_RECOVERY_FILE", fixture.root.join("recovery"))
        .env("WARP_PROCD_REBUILD_FILE", fixture.root.join("rebuild"))
        .env("WARP_OP_FILE", fixture.root.join("warp/op"))
        .env("Z2K_INIT", fixture.root.join("missing-init"))
        .env("Z2K_PROC_ROOT", fixture.root.join("proc"))
        .env(
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        )
        .output()
        .unwrap();

    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(!fixture.engine.exists());
    assert_eq!(
        fs::read_to_string(&fixture.config).unwrap(),
        "GAME_WARP_ENABLED=0\nother=value\n"
    );
    assert_eq!(
        fs::read_to_string(&fixture.device).unwrap(),
        "device sentinel\n"
    );
    assert_eq!(fs::read_to_string(account).unwrap(), "account sentinel\n");
    assert_eq!(fs::read_to_string(license).unwrap(), "license sentinel\n");
    assert_eq!(
        fs::read_to_string(fixture.user_lists.join("custom.txt")).unwrap(),
        "192.0.2.4\n"
    );

    fs::write(&fixture.engine, "Go runtime sentinel\n").unwrap();
    let output = fixture
        .controller("lifecycle")
        .arg("remove")
        .env("WARP_DOMAIN_RUNTIME_BIN", &fixture.engine)
        .env("WARP_STATUS", fixture.root.join("status.json"))
        .env("WARP_PBR_OWNER", fixture.root.join("pbr.owner"))
        .env("WARP_PROBE_OWNER", fixture.root.join("probe.owner"))
        .env("WARP_ROUTE_ERROR_FILE", fixture.root.join("route-error"))
        .env(
            "WARP_PROCD_INSTANCE_FILE",
            fixture.root.join("procd-instance"),
        )
        .env("WARP_PROCD_RECOVERY_FILE", fixture.root.join("recovery"))
        .env("WARP_PROCD_REBUILD_FILE", fixture.root.join("rebuild"))
        .env("WARP_OP_FILE", fixture.root.join("warp/op"))
        .env("Z2K_INIT", fixture.root.join("missing-init"))
        .env("Z2K_PROC_ROOT", fixture.root.join("proc"))
        .env(
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        )
        .output()
        .unwrap();
    assert!(
        output.status.success(),
        "{}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(&fixture.engine).unwrap(),
        "Go runtime sentinel\n"
    );
}

#[test]
fn user_lifecycle_откладывается_во_время_обновления_без_изменений() {
    let fixture = Fixture::new();
    let work = fixture.root.join("install-work");
    fs::create_dir_all(&work).unwrap();
    fs::write(work.join("transaction-active"), "active\n").unwrap();
    fs::write(&fixture.config, "GAME_WARP_ENABLED=1\nother=value\n").unwrap();
    let output = fixture
        .controller("lifecycle")
        .arg("disable")
        .env("Z2K_OW_INSTALL_WORK", &work)
        .env("WARP_OP_FILE", fixture.root.join("warp/op"))
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("идёт обновление z2kOW"));
    assert_eq!(
        fs::read_to_string(&fixture.config).unwrap(),
        "GAME_WARP_ENABLED=1\nother=value\n"
    );
    assert!(!fixture.root.join("warp/mutate.lock").exists());
    assert!(!fixture.root.join("warp/op").exists());

    let output = fixture
        .controller("install")
        .env("Z2K_OW_INSTALL_WORK", &work)
        .output()
        .unwrap();
    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("идёт обновление z2kOW"));
    assert!(!fixture.trace.exists());
}
