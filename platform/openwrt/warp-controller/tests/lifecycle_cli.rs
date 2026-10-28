use std::{
    fs,
    os::unix::fs::PermissionsExt,
    path::PathBuf,
    process::{Command, Stdio},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use warp_controller::lock::MutationLock;

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
            .env("WARP_OP_FILE", self.root.join("warp/op"))
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
fn enable_if_idle_с_флагом_или_переменной_не_трогает_активную_операцию() {
    for use_flag in [true, false] {
        let fixture = Fixture::new();
        let proc_root = fixture.root.join("proc");
        let active_pid = 424242;
        let operation = fixture.root.join("warp/op");
        fs::create_dir_all(proc_root.join(active_pid.to_string())).unwrap();
        fs::create_dir_all(operation.parent().unwrap()).unwrap();
        fs::write(&operation, format!("{active_pid}\n")).unwrap();
        fs::write(&fixture.config, "GAME_WARP_ENABLED=0\nother=value\n").unwrap();

        let mut command = fixture.controller("lifecycle");
        command
            .arg("enable")
            .env("WARP_BIN", fixture.root.join("missing-engine"))
            .env("Z2K_PROC_ROOT", &proc_root);
        if use_flag {
            command.arg("--if-idle");
        } else {
            command.env("Z2K_WARP_IF_IDLE", "1");
        }
        let output = command.output().unwrap();

        assert!(
            output.status.success(),
            "{}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            fs::read_to_string(&fixture.config).unwrap(),
            "GAME_WARP_ENABLED=0\nother=value\n"
        );
        assert_eq!(
            fs::read_to_string(&operation).unwrap(),
            format!("{active_pid}\n")
        );
        assert!(!fixture.root.join("warp/mutate.lock").exists());
        assert!(!fixture.trace.exists());
    }
}

#[test]
fn enable_if_idle_не_перебивает_активный_mutation_lock() {
    let fixture = Fixture::new();
    let lock = MutationLock::acquire(&fixture.root.join("warp/mutate.lock"), Duration::ZERO)
        .unwrap()
        .expect("фикстура должна владеть mutation lock");
    fs::write(&fixture.config, "GAME_WARP_ENABLED=0\nother=value\n").unwrap();
    let output = fixture
        .controller("lifecycle")
        .args(["enable", "--if-idle"])
        .env("WARP_BIN", fixture.root.join("missing-engine"))
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
    assert!(!fixture.root.join("warp/op").exists());
    assert!(!fixture.trace.exists());
    drop(lock);
}

#[test]
fn enable_if_idle_игнорирует_устаревший_маркер() {
    let fixture = Fixture::new();
    let proc_root = fixture.root.join("proc");
    fs::create_dir_all(&proc_root).unwrap();
    let operation = fixture.root.join("warp/op");
    fs::create_dir_all(operation.parent().unwrap()).unwrap();
    fs::write(&operation, "424242\n").unwrap();
    fs::write(&fixture.config, "GAME_WARP_ENABLED=0\nother=value\n").unwrap();
    let output = fixture
        .controller("lifecycle")
        .args(["enable", "--if-idle"])
        .env("WARP_BIN", fixture.root.join("missing-engine"))
        .env("Z2K_PROC_ROOT", &proc_root)
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("движок WARP не установлен"));
    assert!(!operation.exists());
    assert!(!fixture.root.join("warp/mutate.lock").exists());
}

#[test]
fn lifecycle_always_reports_total_and_only_reports_stages_in_diagnostic_mode() {
    let fixture = Fixture::new();
    fs::write(&fixture.config, "GAME_WARP_ENABLED=0\nother=value\n").unwrap();

    let diagnostic = fixture
        .controller("lifecycle")
        .arg("restart")
        .env("Z2K_WARP_DIAGNOSTICS", "1")
        .output()
        .unwrap();
    assert!(
        diagnostic.status.success(),
        "{}",
        String::from_utf8_lossy(&diagnostic.stderr)
    );
    assert!(diagnostic.stdout.is_empty());
    let diagnostic_stderr = String::from_utf8_lossy(&diagnostic.stderr);
    let diagnostic_lines: Vec<_> = diagnostic_stderr
        .lines()
        .filter(|line| line.starts_with("WARP_TIMING "))
        .collect();
    let total = diagnostic_lines
        .iter()
        .find(|line| line.contains("stage=total"))
        .expect("должна быть итоговая длительность lifecycle");
    let operation_id = total
        .split_whitespace()
        .find_map(|field| field.strip_prefix("operation_id="))
        .expect("итог должен содержать operation ID");
    assert!(total.contains("action=restart"));
    assert!(total.contains("duration_ms="));
    assert!(diagnostic_lines.iter().any(|line| {
        line.contains(&format!("operation_id={operation_id}"))
            && line.contains("stage=mutation_lock")
    }));

    let quiet = fixture
        .controller("lifecycle")
        .arg("restart")
        .output()
        .unwrap();
    assert!(quiet.status.success());
    let quiet_stderr = String::from_utf8_lossy(&quiet.stderr);
    let quiet_lines: Vec<_> = quiet_stderr
        .lines()
        .filter(|line| line.starts_with("WARP_TIMING "))
        .collect();
    assert_eq!(quiet_lines.len(), 1);
    assert!(quiet_lines[0].contains("stage=total"));
    assert!(!quiet_lines[0].contains("stage=mutation_lock"));
    let quiet_operation_id = quiet_lines[0]
        .split_whitespace()
        .find_map(|field| field.strip_prefix("operation_id="))
        .expect("итог должен содержать operation ID");
    assert_ne!(operation_id, quiet_operation_id);
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

#[test]
fn engine_refresh_stop_не_разрешает_замену_пока_pid_движка_жив() {
    let fixture = Fixture::new();
    let proc_root = fixture.root.join("proc");
    let pid_dir = proc_root.join("424242");
    fs::create_dir_all(&pid_dir).unwrap();
    fs::write(pid_dir.join("comm"), "z2k-warpd\n").unwrap();
    fs::write(
        pid_dir.join("cmdline"),
        b"z2k-warpd\0run\0--device\0/tmp/device.json\0",
    )
    .unwrap();

    let bin = fixture.system_commands();
    let kill = bin.join("kill");
    fs::write(
        &kill,
        "#!/bin/sh\nprintf '%s\\n' \"$*\" >> \"$WARP_TEST_KILL_TRACE\"\nexit 0\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(&kill).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&kill, permissions).unwrap();

    let kill_trace = fixture.root.join("kill.trace");
    let output = fixture
        .controller("engine-refresh")
        .arg("stop")
        .env("Z2K_PROC_ROOT", &proc_root)
        .env("Z2K_TMP", fixture.root.join("tmp"))
        .env("Z2K_ETC", fixture.root.join("etc"))
        .env("WARP_STATUS", fixture.root.join("status.json"))
        .env("WARP_PBR_OWNER", fixture.root.join("pbr.owner"))
        .env("WARP_PROBE_OWNER", fixture.root.join("probe.owner"))
        .env("WARP_PROC_STOP_WAIT", "1")
        .env("WARP_TEST_KILL_TRACE", &kill_trace)
        .env(
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        )
        .output()
        .unwrap();

    assert!(!output.status.success());
    assert!(String::from_utf8_lossy(&output.stderr).contains("не завершился после SIGTERM"));
    assert_eq!(fs::read_to_string(kill_trace).unwrap(), "-TERM 424242\n");
    assert!(!fixture.root.join("warp/mutate.lock").exists());
}

#[test]
fn restart_warp_не_перезапускает_z2k_и_сохраняет_pid_основных_служб() {
    let fixture = Fixture::new();
    fs::write(&fixture.config, "GAME_WARP_ENABLED=1\nother=value\n").unwrap();

    let core_pids = [
        (fixture.root.join("nfqws2.pid"), "101"),
        (fixture.root.join("rt-proxy.pid"), "202"),
        (fixture.root.join("tg-proxy.pid"), "303"),
    ];
    for (path, pid) in &core_pids {
        fs::write(path, format!("{pid}\n")).unwrap();
    }

    let z2k_init = fixture.root.join("etc/init.d/z2k");
    let warp_init = fixture.root.join("etc/init.d/z2k-warp");
    fs::create_dir_all(z2k_init.parent().unwrap()).unwrap();
    fs::write(
        &z2k_init,
        r##"#!/bin/sh
case "$1" in
  running) exit 0 ;;
  restart)
    printf 'restart\n' >> "$Z2K_MAIN_INIT_TRACE"
    printf '901\n' > "$Z2K_NFQWS2_PID_FILE"
    printf '902\n' > "$Z2K_RT_PID_FILE"
    printf '903\n' > "$Z2K_TG_PID_FILE"
    exit 0
    ;;
esac
exit 1
"##,
    )
    .unwrap();
    fs::write(
        &warp_init,
        r##"#!/bin/sh
case "$1" in
  running) exit 0 ;;
  restart|reload|start) printf '%s enabled=%s\n' "$1" "$(sed -n 's/^GAME_WARP_ENABLED=//p' "$CONFIG_FILE" | head -n 1)" >> "$WARP_INIT_TRACE"; exit 0 ;;
  stop)
    printf 'stop enabled=%s\n' "$(sed -n 's/^GAME_WARP_ENABLED=//p' "$CONFIG_FILE" | head -n 1)" >> "$WARP_INIT_TRACE"
    rm -rf "$Z2K_PROC_ROOT/424242"
    exit 0
    ;;
esac
exit 1
"##,
    )
    .unwrap();
    for path in [&z2k_init, &warp_init] {
        let mut permissions = fs::metadata(path).unwrap().permissions();
        permissions.set_mode(0o755);
        fs::set_permissions(path, permissions).unwrap();
    }

    let bin = fixture.system_commands();
    let ubus = bin.join("ubus");
    fs::write(
        &ubus,
        "#!/bin/sh\nprintf '%s\\n' '{\"z2k\":{\"instances\":{\"z2k\":{\"running\":true}}},\"z2k-warp\":{\"instances\":{\"main\":{\"running\":true}}}}'\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(&ubus).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&ubus, permissions).unwrap();

    let proc_root = fixture.root.join("proc");
    let warp_pid = proc_root.join("424242");
    fs::create_dir_all(&warp_pid).unwrap();
    fs::write(warp_pid.join("comm"), "z2k-warpd\n").unwrap();
    fs::write(
        warp_pid.join("cmdline"),
        b"z2k-warpd\0run\0--device\0/tmp/device.json\0",
    )
    .unwrap();

    let main_trace = fixture.root.join("z2k-init.trace");
    let warp_trace = fixture.root.join("z2k-warp-init.trace");
    let output = fixture
        .controller("lifecycle")
        .arg("restart")
        .env("Z2K_INIT", &z2k_init)
        .env("Z2K_WARP_INIT", &warp_init)
        .env("Z2K_MAIN_INIT_TRACE", &main_trace)
        .env("WARP_INIT_TRACE", &warp_trace)
        .env("Z2K_NFQWS2_PID_FILE", &core_pids[0].0)
        .env("Z2K_RT_PID_FILE", &core_pids[1].0)
        .env("Z2K_TG_PID_FILE", &core_pids[2].0)
        .env("Z2K_PROC_ROOT", &proc_root)
        .env("WARP_STATUS", fixture.root.join("status.json"))
        .env("WARP_PBR_OWNER", fixture.root.join("pbr.owner"))
        .env("WARP_PROBE_OWNER", fixture.root.join("probe.owner"))
        .env("WARP_ROUTE_ERROR_FILE", fixture.root.join("route-error"))
        .env("WARP_OP_FILE", fixture.root.join("warp/op"))
        .env("WARP_PROCD_RECOVERY_FILE", fixture.root.join("recovery"))
        .env("WARP_PROCD_REBUILD_FILE", fixture.root.join("rebuild"))
        .env("WARP_READY_WAIT", "1")
        .env(
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        )
        .output()
        .unwrap();

    assert_eq!(output.status.code(), Some(2));
    assert!(
        !main_trace.exists(),
        "WARP lifecycle перезапустил основной z2k: {}",
        fs::read_to_string(&main_trace).unwrap_or_default()
    );
    assert_eq!(
        fs::read_to_string(&warp_trace).unwrap(),
        "restart enabled=1\n"
    );
    for (path, pid) in &core_pids {
        assert_eq!(fs::read_to_string(path).unwrap(), format!("{pid}\n"));
    }

    fs::create_dir_all(&warp_pid).unwrap();
    fs::write(warp_pid.join("comm"), "z2k-warpd\n").unwrap();
    fs::write(
        warp_pid.join("cmdline"),
        b"z2k-warpd\0run\0--device\0/tmp/device.json\0",
    )
    .unwrap();
    let output = fixture
        .controller("lifecycle")
        .arg("disable")
        .env("Z2K_INIT", &z2k_init)
        .env("Z2K_WARP_INIT", &warp_init)
        .env("Z2K_MAIN_INIT_TRACE", &main_trace)
        .env("WARP_INIT_TRACE", &warp_trace)
        .env("Z2K_NFQWS2_PID_FILE", &core_pids[0].0)
        .env("Z2K_RT_PID_FILE", &core_pids[1].0)
        .env("Z2K_TG_PID_FILE", &core_pids[2].0)
        .env("Z2K_PROC_ROOT", &proc_root)
        .env("WARP_STATUS", fixture.root.join("status.json"))
        .env("WARP_PBR_OWNER", fixture.root.join("pbr.owner"))
        .env("WARP_PROBE_OWNER", fixture.root.join("probe.owner"))
        .env("WARP_ROUTE_ERROR_FILE", fixture.root.join("route-error"))
        .env("WARP_OP_FILE", fixture.root.join("warp/op"))
        .env(
            "WARP_PROCD_INSTANCE_FILE",
            fixture.root.join("procd-instance"),
        )
        .env("WARP_PROCD_RECOVERY_FILE", fixture.root.join("recovery"))
        .env("WARP_PROCD_REBUILD_FILE", fixture.root.join("rebuild"))
        .env("WARP_READY_WAIT", "1")
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
        fs::read_to_string(&fixture.config).unwrap(),
        "GAME_WARP_ENABLED=0\nother=value\n"
    );
    assert_eq!(
        fs::read_to_string(&warp_trace).unwrap(),
        "restart enabled=1\nstop enabled=1\n"
    );
    assert!(!warp_pid.exists(), "procd stop оставил z2k-warpd");
    assert!(!main_trace.exists(), "disable перезапустил основной z2k");
    for (path, pid) in &core_pids {
        assert_eq!(fs::read_to_string(path).unwrap(), format!("{pid}\n"));
    }
}

#[test]
fn миграция_procd_удаляет_старый_warp_instance_до_запуска_новой_службы() {
    let fixture = Fixture::new();
    let bin = fixture.system_commands();
    let proc_root = fixture.root.join("proc");
    let old_warp = proc_root.join("424242");
    fs::create_dir_all(&old_warp).unwrap();
    fs::write(old_warp.join("comm"), "z2k-warpd\n").unwrap();
    fs::write(
        old_warp.join("cmdline"),
        b"z2k-warpd\0run\0--device\0/tmp/device.json\0",
    )
    .unwrap();

    let ubus = bin.join("ubus");
    fs::write(
        &ubus,
        r##"#!/bin/sh
printf '%s\n' "$*" >> "$WARP_TEST_UBUS_TRACE"
if [ "$1" = -S ] && [ "$2" = call ] && [ "$3" = service ] && [ "$4" = list ]; then
    if [ -f "$WARP_TEST_LEGACY_REMOVED" ]; then
        printf '%s\n' '{"z2k":{"instances":{"z2k":{"running":true}}}}'
    else
        printf '%s\n' '{"z2k":{"instances":{"z2k":{"running":true},"z2k-warp":{"running":true}}}}'
    fi
    exit 0
fi
if [ "$1" = call ] && [ "$2" = service ] && [ "$3" = delete ] \
    && [ "$4" = '{"name":"z2k","instance":"z2k-warp"}' ]; then
    : > "$WARP_TEST_LEGACY_REMOVED"
    rm -rf "$Z2K_PROC_ROOT/424242"
    exit 0
fi
exit 1
"##,
    )
    .unwrap();
    let mut permissions = fs::metadata(&ubus).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&ubus, permissions).unwrap();

    let removed = fixture.root.join("legacy-removed");
    let trace = fixture.root.join("ubus.trace");
    let output = fixture
        .controller("procd-legacy-warp-remove")
        .env("Z2K_PROC_ROOT", &proc_root)
        .env("WARP_TEST_LEGACY_REMOVED", &removed)
        .env("WARP_TEST_UBUS_TRACE", &trace)
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
    assert!(removed.exists());
    assert!(
        !old_warp.exists(),
        "старый Go-процесс должен быть удалён procd"
    );
    let trace = fs::read_to_string(trace).unwrap();
    assert!(trace.contains("call service delete {\"name\":\"z2k\",\"instance\":\"z2k-warp\"}"));
}

#[test]
fn startup_reconcile_не_держит_mutation_lock_во_время_ожидания_ready() {
    let fixture = Fixture::new();
    fs::write(&fixture.config, "GAME_WARP_ENABLED=1\n").unwrap();
    let proc_root = fixture.root.join("proc");
    fs::create_dir_all(&proc_root).unwrap();
    let status = fixture.root.join("status.json");
    fs::write(&status, "{\"ready\":false}\n").unwrap();
    let lock_path = fixture.root.join("warp/mutate.lock");

    let mut child = fixture
        .controller("startup-reconcile")
        .env("Z2K_PROC_ROOT", &proc_root)
        .env("WARP_STATUS", &status)
        .env("WARP_READY_WAIT", "4")
        .env("Z2K_WARP_LOCK_DIR", &lock_path)
        .spawn()
        .unwrap();
    thread::sleep(Duration::from_millis(250));
    assert!(
        child.try_wait().unwrap().is_none(),
        "ожидание ready должно продолжаться"
    );

    let deadline = Instant::now() + Duration::from_secs(1);
    let mut acquired = false;
    while Instant::now() < deadline {
        if let Some(lock) = MutationLock::acquire(&lock_path, Duration::ZERO).unwrap() {
            drop(lock);
            acquired = true;
            break;
        }
        thread::sleep(Duration::from_millis(20));
    }
    assert!(
        acquired,
        "boot-reconcile удержал общий mutation lock во время ожидания"
    );
    assert!(child.wait().unwrap().success());
}

#[test]
fn disable_ждёт_завершения_go_после_возврата_procd_stop() {
    let fixture = Fixture::new();
    fs::write(&fixture.config, "GAME_WARP_ENABLED=1\nother=value\n").unwrap();

    let proc_root = fixture.root.join("proc");
    let warp_pid = proc_root.join("424242");
    fs::create_dir_all(&warp_pid).unwrap();
    fs::write(warp_pid.join("comm"), "z2k-warpd\n").unwrap();
    fs::write(
        warp_pid.join("cmdline"),
        b"z2k-warpd\0run\0--device\0/tmp/device.json\0",
    )
    .unwrap();

    let bin = fixture.system_commands();
    let ubus = bin.join("ubus");
    fs::write(
        &ubus,
        "#!/bin/sh\nprintf '%s\\n' '{\"z2k-warp\":{\"instances\":{\"main\":{\"running\":true}}}}'\n",
    )
    .unwrap();
    let mut permissions = fs::metadata(&ubus).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&ubus, permissions).unwrap();

    let warp_init = fixture.root.join("etc/init.d/z2k-warp");
    fs::create_dir_all(warp_init.parent().unwrap()).unwrap();
    fs::write(
        &warp_init,
        [
            "#!/bin/sh\n",
            "case \"$1\" in\n",
            "  stop)\n",
            "    (sleep 1; rm -rf \"$Z2K_PROC_ROOT/424242\") ",
            "</dev/null >/dev/null 2>&1 &\n",
            "    exit 0\n",
            "    ;;\n",
            "esac\n",
            "exit 1\n",
        ]
        .concat(),
    )
    .unwrap();
    let mut permissions = fs::metadata(&warp_init).unwrap().permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&warp_init, permissions).unwrap();

    let output = fixture
        .controller("lifecycle")
        .arg("disable")
        .env("Z2K_WARP_INIT", &warp_init)
        .env("Z2K_PROC_ROOT", &proc_root)
        .env("WARP_STATUS", fixture.root.join("status.json"))
        .env("WARP_PBR_OWNER", fixture.root.join("pbr.owner"))
        .env("WARP_PROBE_OWNER", fixture.root.join("probe.owner"))
        .env("WARP_ROUTE_ERROR_FILE", fixture.root.join("route-error"))
        .env("WARP_DOMAIN_ERROR", fixture.root.join("domain-error"))
        .env(
            "WARP_PROCD_INSTANCE_FILE",
            fixture.root.join("procd-instance"),
        )
        .env("WARP_PROCD_RECOVERY_FILE", fixture.root.join("recovery"))
        .env("Z2K_WARP_DIAGNOSTICS", "1")
        .env(
            "PATH",
            format!("{}:{}", bin.display(), std::env::var("PATH").unwrap()),
        )
        .output()
        .unwrap();

    let deadline = Instant::now() + Duration::from_secs(3);
    while warp_pid.exists() && Instant::now() < deadline {
        thread::sleep(Duration::from_millis(20));
    }
    assert!(
        !warp_pid.exists(),
        "тестовый процесс не завершился по таймеру"
    );
    assert!(
        output.status.success(),
        "disable должен дождаться завершения после возврата procd stop: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("stage=process_stop_wait"),
        "этап ожидания Go должен попадать в диагностику"
    );
    let diagnostics = String::from_utf8_lossy(&output.stderr);
    let pbr_cleanup = diagnostics
        .find("stage=pbr_cleanup")
        .expect("очистка PBR должна попадать в диагностику");
    let procd_transition = diagnostics
        .find("stage=procd_transition")
        .expect("переход procd должен попадать в диагностику");
    assert!(
        pbr_cleanup < procd_transition,
        "фактическая очистка PBR должна быть измерена до остановки Go: {diagnostics}"
    );
    assert_eq!(
        fs::read_to_string(&fixture.config).unwrap(),
        "GAME_WARP_ENABLED=0\nother=value\n"
    );
}
