use std::{
    collections::BTreeSet,
    env,
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::{OpenOptionsExt, PermissionsExt},
    path::{Path, PathBuf},
    process::Command,
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

use crate::{
    config::{self, MatchOrder},
    devices, domain_state,
    health::{self, HealthAction},
    list_ops, lists,
    lock::MutationLock,
    nft::{self, DomainObserverConfig, DomainRemoveConfig, MarkConfig},
    openwrt::{self, InterfaceKind},
    operation::OperationState,
    process,
    routing::{self, RouteConfig},
    state::{
        EngineStatus, Observation, ProcessStatus, RuntimeReadiness, observe_warp_process,
        read_engine_status_snapshot, warp_process_pids,
    },
    status::Paths,
};

struct LifecycleTiming {
    operation_id: String,
    action: &'static str,
    diagnostics: bool,
    started: Instant,
}

impl LifecycleTiming {
    fn new(action: &'static str) -> Self {
        let timestamp = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        Self {
            operation_id: format!("{}-{timestamp}", std::process::id()),
            action,
            diagnostics: env::var("Z2K_WARP_DIAGNOSTICS").as_deref() == Ok("1"),
            started: Instant::now(),
        }
    }

    fn measure<T>(&self, stage: &str, operation: impl FnOnce() -> T) -> T {
        let started = Instant::now();
        let result = operation();
        if self.diagnostics {
            eprintln!(
                "WARP_TIMING operation_id={} action={} stage={} duration_ms={}",
                self.operation_id,
                self.action,
                stage,
                started.elapsed().as_millis()
            );
        }
        result
    }

    fn finish(&self, result: &io::Result<i32>) {
        let status = match result {
            Ok(code) => format!("ok code={code}"),
            Err(_) => "error".to_owned(),
        };
        eprintln!(
            "WARP_TIMING operation_id={} action={} stage=total duration_ms={} result={}",
            self.operation_id,
            self.action,
            self.started.elapsed().as_millis(),
            status
        );
    }
}

fn lifecycle_action(intent: crate::lifecycle::ServiceIntent) -> &'static str {
    match intent {
        crate::lifecycle::ServiceIntent::Enable => "enable",
        crate::lifecycle::ServiceIntent::Disable => "disable",
        crate::lifecycle::ServiceIntent::Remove => "remove",
        crate::lifecycle::ServiceIntent::Restart => "restart",
    }
}

pub fn migrate_lists(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    if args.next().is_some() {
        return Err(invalid("лишние аргументы migrate"));
    }
    let paths = Paths::from_env();
    let _lock = acquire_user_lock()?;
    list_ops::migrate_lists(&paths.user_lists, &paths.games)
}

pub fn install(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    if args.next().is_some() {
        return Err(invalid("лишние аргументы install"));
    }
    let paths = Paths::from_env();
    let _lock = acquire_user_lock()?;
    list_ops::migrate_lists(&paths.user_lists, &paths.games)?;
    if !executable(&paths.warp_bin) {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "движок WARP не установлен или несовместим",
        ));
    }
    let version = process::output(Command::new(&paths.warp_bin).arg("version"))?;
    if !version.status.success() {
        return Err(io::Error::other(
            "движок WARP не установлен или несовместим",
        ));
    }
    register_engine(&paths, false)
}

pub fn register(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let write_stamp = match args.next().as_deref() {
        None => false,
        Some("--stamp") => true,
        Some(_) => return Err(invalid("неверный параметр register")),
    };
    if args.next().is_some() {
        return Err(invalid("лишние аргументы register"));
    }
    let paths = Paths::from_env();
    let _lock = acquire_user_lock()?;
    register_engine(&paths, write_stamp)
}

pub fn license(args: &mut impl Iterator<Item = String>) -> io::Result<i32> {
    if args.next().is_some() {
        return Err(invalid("лишние аргументы license"));
    }
    let paths = Paths::from_env();
    let _lock = acquire_user_lock()?;
    if !executable(&paths.warp_bin) {
        eprintln!("движок WARP не установлен — нажмите «Установить»");
        return Ok(4);
    }
    let mut key = Vec::new();
    io::stdin().read_to_end(&mut key)?;
    let mut command = Command::new(&paths.warp_bin);
    command.args(["license", "--device"]).arg(&paths.device);
    let mut output =
        process::output_with_input_timeout(&mut command, &key, Duration::from_secs(120))?;
    if output.status.code() == Some(1) {
        let proxy = external_proxy(&paths);
        if !proxy.is_empty() {
            let mut command = Command::new(&paths.warp_bin);
            command
                .args(["license", "--device"])
                .arg(&paths.device)
                .arg("--proxy")
                .arg(proxy);
            output =
                process::output_with_input_timeout(&mut command, &key, Duration::from_secs(120))?;
        }
    }
    io::stdout().write_all(&output.stdout)?;
    io::stdout().write_all(&output.stderr)?;
    io::stdout().flush()?;
    Ok(output.status.code().unwrap_or(1))
}

pub fn user_lifecycle(args: &mut impl Iterator<Item = String>) -> io::Result<i32> {
    let intent = match args.next().as_deref() {
        Some("enable") => crate::lifecycle::ServiceIntent::Enable,
        Some("disable") => crate::lifecycle::ServiceIntent::Disable,
        Some("remove") => crate::lifecycle::ServiceIntent::Remove,
        Some("restart") => crate::lifecycle::ServiceIntent::Restart,
        _ => {
            return Err(invalid(
                "ожидается действие enable, disable, remove или restart",
            ));
        }
    };

    let if_idle_env = env::var("Z2K_WARP_IF_IDLE").is_ok_and(|value| value == "1");
    let if_idle = match (intent, args.next().as_deref()) {
        (crate::lifecycle::ServiceIntent::Enable, Some("--if-idle")) => true,
        (crate::lifecycle::ServiceIntent::Enable, None) => if_idle_env,
        (crate::lifecycle::ServiceIntent::Enable, Some(_)) => {
            return Err(invalid("неверный параметр lifecycle enable"));
        }
        (_, None) => false,
        (_, Some(_)) => return Err(invalid("--if-idle доступен только для enable")),
    };
    if args.next().is_some() {
        return Err(invalid("лишние аргументы lifecycle"));
    }

    let timing = LifecycleTiming::new(lifecycle_action(intent));
    let operation = operation_path();
    let pid = std::process::id();
    let prelocked = if if_idle {
        let probe = (|| -> io::Result<Option<MutationLock>> {
            let Some(lock) = timing.measure("mutation_lock", || {
                acquire_user_lock_with_wait(Duration::ZERO)
            })?
            else {
                return Ok(None);
            };
            let paths = Paths::from_env();
            let active = timing.measure("operation_check", || {
                crate::operation::active(&operation, &paths.proc_root)
            })?;
            Ok((!active).then_some(lock))
        })();
        match probe {
            Ok(Some(lock)) => Some(lock),
            Ok(None) => {
                let result = Ok(0);
                timing.finish(&result);
                return result;
            }
            Err(error) if error.kind() == io::ErrorKind::WouldBlock => {
                let result = Ok(0);
                timing.finish(&result);
                return result;
            }
            Err(error) => {
                let result = Err(error);
                timing.finish(&result);
                return result;
            }
        }
    } else {
        None
    };
    let result = match timing.measure("operation_begin", || {
        crate::operation::begin(&operation, pid)
    }) {
        Ok(()) => {
            let result = run_user_lifecycle(intent, pid, &timing, prelocked);
            match timing.measure("operation_clear", || {
                crate::operation::clear_if_owner(&operation, pid)
            }) {
                Ok(_) => result,
                Err(error) if result.is_ok() => Err(error),
                Err(_) => result,
            }
        }
        Err(error) => Err(error),
    };
    timing.finish(&result);
    result
}

pub fn procd_legacy_warp_remove(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    if args.next().is_some() {
        return Err(invalid("лишние аргументы procd-legacy-warp-remove"));
    }

    let paths = Paths::from_env();
    let _lock = acquire_lock()?;
    remove_legacy_procd_instance(&paths)
}

fn remove_legacy_procd_instance(paths: &Paths) -> io::Result<()> {
    let Some(registry) = query_service_registry()? else {
        return Ok(());
    };
    if !legacy_warp_instance_registered(&registry) {
        return Ok(());
    }

    remove_routes(paths)?;
    let all_pids = known_warp_pids(paths)?;
    let pids = match legacy_warp_instance_pid(&registry) {
        Some(pid) => all_pids
            .into_iter()
            .filter(|current| current == &pid)
            .collect(),
        None if new_warp_instance_registered(&registry) && !all_pids.is_empty() => {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "нельзя отличить PID старого WARP от новой службы procd",
            ));
        }
        None => all_pids,
    };
    let mut deleted = false;
    for ubus in ["ubus", "/sbin/ubus", "/usr/sbin/ubus"] {
        let mut command = Command::new(ubus);
        command.args([
            "call",
            "service",
            "delete",
            r#"{"name":"z2k","instance":"z2k-warp"}"#,
        ]);
        match process::output_with_timeout(&mut command, Duration::from_secs(10)) {
            Ok(output) if output.status.success() => {
                deleted = true;
                break;
            }
            Ok(output) => {
                return Err(io::Error::other(format!(
                    "procd не удалил старый z2k/z2k-warp instance: {}",
                    String::from_utf8_lossy(&output.stderr).trim()
                )));
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        }
    }
    if !deleted {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "не найдена команда ubus для удаления старого WARP instance",
        ));
    }

    let registry = query_service_registry()?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::WouldBlock,
            "не удалось проверить удаление старого WARP instance через ubus",
        )
    })?;
    if legacy_warp_instance_registered(&registry) {
        return Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "старый z2k/z2k-warp instance остался в реестре procd",
        ));
    }

    let deadline = std::time::Instant::now()
        + Duration::from_secs(bounded_seconds("WARP_PROC_STOP_WAIT", 5, 60));
    loop {
        let active = known_warp_pids(paths)?;
        if pids
            .iter()
            .all(|pid| !active.iter().any(|current| current == pid))
        {
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "старый z2k-warpd не завершился после удаления procd instance",
            ));
        }
        thread::sleep(Duration::from_millis(100));
    }
}

pub fn startup_reconcile(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    if args.next().is_some() {
        return Err(invalid("лишние аргументы startup-reconcile"));
    }
    crate::status::require_protocol_v1()?;
    let paths = Paths::from_env();
    if config::read_value(&paths.config, "GAME_WARP_ENABLED", "", MatchOrder::First)? != "1" {
        return Ok(());
    }
    let wait = bounded_seconds("WARP_READY_WAIT", 120, 600);
    let started_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if started_at == 0 {
        return Ok(());
    }
    let pid = std::process::id();
    let deadline = std::time::Instant::now() + Duration::from_secs(wait);
    loop {
        if !operation_is_current(pid) {
            return Ok(());
        }
        let Some(lock) = acquire_lock()? else {
            return Ok(());
        };
        if !operation_is_current(pid)
            || config::read_value(&paths.config, "GAME_WARP_ENABLED", "", MatchOrder::First)? != "1"
        {
            drop(lock);
            return Ok(());
        }

        let process = observe_warp_process(&paths.proc_root);
        if process == ProcessStatus::Present {
            install_probe_route(&paths);
        }
        let (engine, modified) = read_engine_status_snapshot(&paths.status);
        let iface_present = match &engine {
            EngineStatus::Ready { iface } if valid_interface(iface) => {
                let mut command = Command::new("ip");
                command.args(["link", "show", "dev", iface]);
                process::output_with_timeout(&mut command, Duration::from_secs(5))
                    .ok()
                    .map(|output| output.status.success())
            }
            EngineStatus::Ready { .. } => Some(false),
            EngineStatus::NotReady | EngineStatus::Unreadable => None,
        };
        if let RuntimeReadiness::Ready { iface } =
            health::ready_since(process, engine, iface_present, modified, started_at)
        {
            if operation_is_current(pid) {
                reconcile_ready(&paths, &iface)?;
            }
            return Ok(());
        }
        drop(lock);

        let now = std::time::Instant::now();
        if now >= deadline {
            return Ok(());
        }
        thread::sleep((deadline - now).min(Duration::from_secs(2)));
    }
}

/// Выполняет updater-hook без Shell-логики: stop освобождает только наши
/// маршруты и завершает проверенные процессы, start ждёт procd-респавн.
pub fn engine_refresh(args: &mut impl Iterator<Item = String>) -> io::Result<i32> {
    let action = match args.next().as_deref() {
        Some("stop") => EngineRefreshAction::Stop,
        Some("start") => EngineRefreshAction::Start,
        _ => return Err(invalid("ожидается действие engine-refresh stop или start")),
    };
    if args.next().is_some() {
        return Err(invalid("лишние аргументы engine-refresh"));
    }
    crate::status::require_protocol_v1()?;
    let paths = Paths::from_env();
    let _lock = acquire_lock()?
        .ok_or_else(|| io::Error::new(io::ErrorKind::WouldBlock, "mutation lock WARP занят"))?;
    let pid = std::process::id();
    match action {
        EngineRefreshAction::Stop => {
            remove_routes(&paths)?;
            let pids = known_warp_pids(&paths)?;
            terminate_warp_pids(&paths, &pids, bounded_seconds("WARP_PROC_STOP_WAIT", 5, 60))?;
            Ok(0)
        }
        EngineRefreshAction::Start => {
            let pids = known_warp_pids(&paths)?;
            terminate_warp_pids(&paths, &pids, bounded_seconds("WARP_PROC_STOP_WAIT", 5, 60))?;
            let wait = bounded_seconds("WARP_PROC_WAIT", 60, 600);
            match wait_ready_and_reconcile_for(&paths, pid, wait, None)? {
                0 => Ok(0),
                _ => {
                    // Обновление остаётся fail-open: отсутствие ready не должно
                    // откатывать уже установленный бинарь или блокировать cron.
                    eprintln!("движок WARP пока не готов; маршрутизацию восстановит health-check");
                    Ok(0)
                }
            }
        }
    }
}

#[derive(Clone, Copy)]
enum EngineRefreshAction {
    Stop,
    Start,
}

fn known_warp_pids(paths: &Paths) -> io::Result<Vec<String>> {
    match warp_process_pids(&paths.proc_root) {
        Observation::Known(pids) => Ok(pids),
        Observation::Unreadable => Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "список процессов WARP временно недоступен",
        )),
    }
}

fn terminate_warp_pids(paths: &Paths, pids: &[String], wait_seconds: u64) -> io::Result<()> {
    for pid in pids {
        let mut command = Command::new("kill");
        command.args(["-TERM", pid]);
        let signal_sent = process::output_with_timeout(&mut command, Duration::from_secs(5))
            .is_ok_and(|output| output.status.success());
        if !signal_sent {
            let still_owned = known_warp_pids(paths)?.iter().any(|current| current == pid);
            if still_owned {
                return Err(io::Error::other(format!(
                    "не удалось отправить SIGTERM процессу z2k-warpd PID {pid}"
                )));
            }
        }
    }
    let deadline = std::time::Instant::now() + Duration::from_secs(wait_seconds);
    loop {
        let active = known_warp_pids(paths)?;
        if pids
            .iter()
            .all(|pid| !active.iter().any(|current| current == pid))
        {
            return Ok(());
        }
        if std::time::Instant::now() >= deadline {
            return Err(io::Error::new(
                io::ErrorKind::TimedOut,
                "z2k-warpd не завершился после SIGTERM; обновление отложено",
            ));
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn run_user_lifecycle(
    intent: crate::lifecycle::ServiceIntent,
    pid: u32,
    timing: &LifecycleTiming,
    prelocked: Option<MutationLock>,
) -> io::Result<i32> {
    timing.measure("protocol_check", crate::status::require_protocol_v1)?;
    let paths = Paths::from_env();
    let lock = match prelocked {
        Some(lock) => Some(lock),
        None => timing.measure("mutation_lock", acquire_user_lock)?,
    };
    let Some(lock) = lock else {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "lifecycle WARP должен владеть mutation lock",
        ));
    };
    let mut lock = Some(lock);
    if !operation_is_current(pid) {
        return Ok(3);
    }

    match intent {
        crate::lifecycle::ServiceIntent::Enable => enable(&paths, &mut lock, pid, timing),
        crate::lifecycle::ServiceIntent::Disable => disable_user(&paths, &mut lock, pid, timing),
        crate::lifecycle::ServiceIntent::Remove => remove_user(&paths, &mut lock, pid, timing),
        crate::lifecycle::ServiceIntent::Restart => restart_user(&paths, &mut lock, pid, timing),
    }
}

fn enable(
    paths: &Paths,
    lock: &mut Option<MutationLock>,
    pid: u32,
    timing: &LifecycleTiming,
) -> io::Result<i32> {
    let was_enabled = timing.measure("configuration", || -> io::Result<bool> {
        let was_enabled =
            config::read_value(&paths.config, "GAME_WARP_ENABLED", "", MatchOrder::First)? == "1";
        if !executable(&paths.warp_bin) {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "движок WARP не установлен",
            ));
        }
        if !was_enabled {
            require_warp_init()?;
        }
        let _ = crate::recovery::clear(&recovery_path());
        config::set_warp_enabled(&paths.config, "1")?;
        unpin_legacy();
        Ok(was_enabled)
    })?;

    let registration_ok = timing.measure("registration", || -> io::Result<bool> {
        match fs::metadata(&paths.device) {
            Ok(metadata) if metadata.is_file() && metadata.len() > 0 => {}
            Ok(_) => {
                if let Err(error) = register_engine(paths, true) {
                    eprintln!(
                        "идентификатор WARP пока не зарегистрирован ({error}); восстановление продолжится в health-check"
                    );
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                if let Err(error) = register_engine(paths, true) {
                    eprintln!(
                        "идентификатор WARP пока не зарегистрирован ({error}); восстановление продолжится в health-check"
                    );
                }
            }
            Err(_) => return Ok(false),
        }
        Ok(true)
    })?;
    if !registration_ok {
        return Ok(2);
    }

    if let Err(error) = timing.measure("nft_list_sync", || sync_sets(paths, true)) {
        config::set_warp_enabled(&paths.config, "0")?;
        return Err(error);
    }
    let _ = timing.measure("domain_policy", || apply_domain_policy(paths));
    if let Err(error) = timing.measure("mark_sync", || sync_mark(paths, true)) {
        config::set_warp_enabled(&paths.config, "0")?;
        return Err(error);
    }

    let process = observe_warp_process(&paths.proc_root);
    if process == ProcessStatus::Unreadable {
        return Ok(2);
    }
    if let Some(code) = timing.measure("procd_transition", || {
        transition_service(
            crate::lifecycle::ServiceIntent::Enable,
            was_enabled,
            lock,
            pid,
        )
    })? {
        return Ok(code);
    }
    wait_ready_and_reconcile(paths, pid, timing)
}

fn require_warp_init() -> io::Result<()> {
    let init = env::var_os("Z2K_WARP_INIT").unwrap_or_else(|| "/etc/init.d/z2k-warp".into());
    let path = Path::new(&init);
    let metadata = fs::metadata(path).map_err(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            io::Error::new(
                io::ErrorKind::NotFound,
                format!("служба procd WARP не найдена: {}", path.display()),
            )
        } else {
            error
        }
    })?;
    if !metadata.is_file() || metadata.permissions().mode() & 0o111 == 0 {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            format!(
                "служба procd WARP не является исполняемым файлом: {}",
                path.display()
            ),
        ));
    }
    Ok(())
}

fn disable_user(
    paths: &Paths,
    lock: &mut Option<MutationLock>,
    pid: u32,
    timing: &LifecycleTiming,
) -> io::Result<i32> {
    let process = observe_warp_process(&paths.proc_root);
    if process == ProcessStatus::Unreadable {
        return Ok(2);
    }
    if let Err(error) = timing.measure("pbr_cleanup", || remove_routes(paths)) {
        return Err(disable_failure(
            paths,
            "warp-disable-pbr-remove-failed",
            error,
        ));
    }
    timing.measure("nft_cleanup", || run_disable_cleanup(paths))?;
    let transition = timing.measure("procd_transition", || {
        transition_service(crate::lifecycle::ServiceIntent::Disable, false, lock, pid)
    });
    match transition {
        Ok(Some(3)) => return Ok(3),
        Ok(Some(_)) => {
            return Err(disable_failure(
                paths,
                "warp-disable-procd-state-unknown",
                io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "состояние службы WARP не подтверждено; выключение отложено",
                ),
            ));
        }
        Err(error) => {
            return Err(disable_failure(
                paths,
                "warp-disable-procd-stop-failed",
                error,
            ));
        }
        Ok(None) => {}
    }

    let process = timing.measure("process_stop_wait", || wait_for_warp_process_stop(paths));
    match process {
        ProcessStatus::Absent => {}
        ProcessStatus::Present => {
            return Err(disable_failure(
                paths,
                "warp-disable-process-still-running",
                io::Error::other("после stop службы WARP процесс z2k-warpd всё ещё работает"),
            ));
        }
        ProcessStatus::Unreadable => {
            return Err(disable_failure(
                paths,
                "warp-disable-process-state-unknown",
                io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "после stop службы WARP состояние процесса z2k-warpd не подтверждено",
                ),
            ));
        }
    }

    if let Err(error) = timing.measure("pbr_finalize", || remove_routes(paths)) {
        return Err(disable_failure(paths, "warp-disable-pbr-remains", error));
    }
    if let Err(error) = timing.measure("runtime_marker_cleanup", || {
        remove_runtime_marker("WARP_PROCD_INSTANCE_FILE", "/tmp/z2k/warp/procd-instance")
    }) {
        return Err(disable_failure(
            paths,
            "warp-disable-marker-remove-failed",
            error,
        ));
    }
    let _ = crate::recovery::clear(&recovery_path());
    if let Err(error) = timing.measure("configuration", || {
        config::set_warp_enabled(&paths.config, "0")
    }) {
        return Err(disable_failure(
            paths,
            "warp-disable-config-commit-failed",
            error,
        ));
    }
    unpin_legacy();
    Ok(0)
}

fn wait_for_warp_process_stop(paths: &Paths) -> ProcessStatus {
    // Реальный QEMU stop занял 46,97 с; ждём до минуты после асинхронного возврата procd.
    let deadline = Instant::now() + Duration::from_secs(60);
    loop {
        let process = observe_warp_process(&paths.proc_root);
        if matches!(process, ProcessStatus::Absent) || Instant::now() >= deadline {
            return process;
        }
        thread::sleep(Duration::from_millis(100));
    }
}

fn disable_failure(paths: &Paths, reason: &str, error: io::Error) -> io::Error {
    match crate::route_error::set(&paths.route_error, reason) {
        Ok(()) => error,
        Err(marker_error) => io::Error::other(format!(
            "{error}; не удалось сохранить причину неполного выключения WARP: {marker_error}"
        )),
    }
}

fn remove_user(
    paths: &Paths,
    lock: &mut Option<MutationLock>,
    pid: u32,
    timing: &LifecycleTiming,
) -> io::Result<i32> {
    let result = disable_user(paths, lock, pid, timing)?;
    if result != 0 || !operation_is_current(pid) {
        return Ok(if result == 0 { 3 } else { result });
    }
    timing.measure("remove_cleanup", || {
        event_stop(paths, true)?;
        remove_custom_engine(paths)
    })?;
    Ok(0)
}

fn remove_custom_engine(paths: &Paths) -> io::Result<()> {
    let runtime = env::var_os("WARP_DOMAIN_RUNTIME_BIN")
        .map(PathBuf::from)
        .unwrap_or_else(|| paths.warp_bin.clone());
    if paths.warp_bin == runtime {
        return Ok(());
    }
    remove_file_if_present(&paths.warp_bin)?;
    let Some(parent) = paths.warp_bin.parent() else {
        return Ok(());
    };
    let Some(name) = paths.warp_bin.file_name().and_then(|name| name.to_str()) else {
        return Ok(());
    };
    let prefix = format!("{name}.new.");
    let entries = match fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    for entry in entries {
        let entry = entry?;
        let file_type = entry.file_type()?;
        if entry.file_name().to_string_lossy().starts_with(&prefix)
            && (file_type.is_file() || file_type.is_symlink())
        {
            remove_file_if_present(&entry.path())?;
        }
    }
    Ok(())
}

fn restart_user(
    paths: &Paths,
    lock: &mut Option<MutationLock>,
    pid: u32,
    timing: &LifecycleTiming,
) -> io::Result<i32> {
    if config::read_value(&paths.config, "GAME_WARP_ENABLED", "", MatchOrder::First)? != "1" {
        return Ok(0);
    }
    let process = observe_warp_process(&paths.proc_root);
    if process == ProcessStatus::Unreadable {
        return Ok(2);
    }
    let _ = crate::recovery::clear(&recovery_path());
    timing.measure("pbr_cleanup", || remove_routes(paths))?;
    if let Some(code) = timing.measure("procd_transition", || {
        transition_service(crate::lifecycle::ServiceIntent::Restart, true, lock, pid)
    })? {
        return Ok(code);
    }
    wait_ready_and_reconcile(paths, pid, timing)
}

fn transition_service(
    intent: crate::lifecycle::ServiceIntent,
    was_enabled: bool,
    lock: &mut Option<MutationLock>,
    pid: u32,
) -> io::Result<Option<i32>> {
    if lock.is_none() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "миграция WARP требует владения mutation lock",
        ));
    }
    let paths = Paths::from_env();
    remove_legacy_procd_instance(&paths)?;
    let process = observe_warp_process(&paths.proc_root);
    let process_running = match process {
        ProcessStatus::Present => true,
        ProcessStatus::Absent => false,
        ProcessStatus::Unreadable => return Ok(Some(2)),
    };
    let active = match service_state() {
        Ok(Some(active)) => crate::state::Observation::Known(active),
        Ok(None) | Err(_) => crate::state::Observation::Unreadable,
    };
    let action = crate::lifecycle::service_action(intent, was_enabled, active, process_running);
    let service_action = match action {
        crate::lifecycle::ServiceAction::Defer => return Ok(Some(2)),
        crate::lifecycle::ServiceAction::None => return Ok(None),
        crate::lifecycle::ServiceAction::Start => "start",
        crate::lifecycle::ServiceAction::Stop => "stop",
        crate::lifecycle::ServiceAction::Reload => "reload",
        crate::lifecycle::ServiceAction::Restart => "restart",
    };
    if lock.take().is_none() {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "нельзя управлять WARP procd instance без владения mutation lock",
        ));
    }

    let recovery = recovery_path();
    let rebuild_marker = env_path(
        "WARP_PROCD_REBUILD_FILE",
        "/tmp/z2k/warp/procd-rebuild-in-progress",
    );
    let mark_rebuild = service_action == "restart" && recovery.exists();
    if mark_rebuild {
        if let Some(parent) = rebuild_marker.parent() {
            fs::create_dir_all(parent)?;
        }
        fs::write(&rebuild_marker, b"")?;
    }
    let init = env::var_os("Z2K_WARP_INIT").unwrap_or_else(|| "/etc/init.d/z2k-warp".into());
    let mut command = Command::new(init);
    command.arg(service_action);
    let action_result = process::output_with_timeout(&mut command, Duration::from_secs(120));
    let clear_result = if mark_rebuild {
        remove_file_if_present(&rebuild_marker)
    } else {
        Ok(())
    };

    let lock_result = acquire_lock()?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::WouldBlock,
            "не удалось повторно захватить mutation lock",
        )
    });
    *lock = Some(lock_result?);
    clear_result?;
    let action_result = action_result?;
    if !action_result.status.success() {
        return Err(io::Error::other(format!(
            "procd не подтвердил действие {service_action} службы WARP"
        )));
    }
    if !operation_is_current(pid) {
        return Ok(Some(3));
    }
    Ok(None)
}

fn wait_ready_and_reconcile(paths: &Paths, pid: u32, timing: &LifecycleTiming) -> io::Result<i32> {
    let wait = env::var("WARP_READY_WAIT")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|seconds| *seconds > 0 && *seconds <= 600)
        .unwrap_or(120);
    timing.measure("go_ready_wait", || {
        wait_ready_and_reconcile_for(paths, pid, wait, Some(timing))
    })
}

fn wait_ready_and_reconcile_for(
    paths: &Paths,
    pid: u32,
    wait: u64,
    timing: Option<&LifecycleTiming>,
) -> io::Result<i32> {
    let started_at = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if started_at == 0 {
        return Ok(2);
    }
    let mut waited = 0;
    while waited < wait {
        if !operation_is_current(pid) {
            return Ok(3);
        }
        let process = observe_warp_process(&paths.proc_root);
        if process == ProcessStatus::Present {
            install_probe_route(paths);
        }
        let (engine, modified) = read_engine_status_snapshot(&paths.status);
        let iface_present = match &engine {
            EngineStatus::Ready { iface } if valid_interface(iface) => {
                let mut command = Command::new("ip");
                command.args(["link", "show", "dev", iface]);
                process::output_with_timeout(&mut command, Duration::from_secs(5))
                    .ok()
                    .map(|output| output.status.success())
            }
            EngineStatus::Ready { .. } => Some(false),
            EngineStatus::NotReady | EngineStatus::Unreadable => None,
        };
        match health::ready_since(process, engine, iface_present, modified, started_at) {
            RuntimeReadiness::Ready { iface } => {
                if let Some(timing) = timing {
                    timing.measure("pbr_reconcile", || reconcile_ready(paths, &iface))?;
                } else {
                    reconcile_ready(paths, &iface)?;
                }
                return Ok(0);
            }
            RuntimeReadiness::NotReady | RuntimeReadiness::Unreadable => {}
        }
        let interval = (wait - waited).min(2);
        thread::sleep(Duration::from_secs(interval));
        waited += interval;
    }
    Ok(2)
}

fn bounded_seconds(name: &str, default: u64, maximum: u64) -> u64 {
    env::var(name)
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .filter(|seconds| *seconds > 0 && *seconds <= maximum)
        .unwrap_or(default)
}

fn install_probe_route(paths: &Paths) {
    let status = read_json(&paths.status);
    let Some(interface) = status.get("iface").and_then(serde_json::Value::as_str) else {
        return;
    };
    let address = status_address(&paths.status);
    if !valid_interface(interface) || address.parse::<std::net::Ipv4Addr>().is_err() {
        return;
    }
    let route = route_config(paths, interface, &address);
    let _ = routing::apply_policy(&route, false);
}

fn run_disable_cleanup(paths: &Paths) -> io::Result<()> {
    let status = read_json(&paths.status);
    let interface = status
        .get("iface")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let address = status_address(&paths.status);
    let mark = parse_mark(&paths.mark);
    let mask = parse_mark(&paths.mark_mask);
    let observer_family = env_string("WARP_DOMAIN_NFT_FAMILY", "inet");
    let observer_table = env_string("WARP_DOMAIN_NFT_TABLE", "z2k_warp_dns");
    let input = format!(
        "version=1\nconfig={}\ninterface={interface}\nprobe_address={address}\ntable={}\nuser_pref={}\nprobe_pref={}\nmark={mark}\nmask={mask}\npbr_owner={}\nprobe_owner={}\nroute_error={}\nfw4_family={}\nfw4_table={}\nfw4_chain={}\nfw4_comment={}\nnft_family={}\nnft_table={}\nmark_chain={}\nmss_chain={}\nforward_chain={}\nnat_chain={}\nobserver_family={observer_family}\nobserver_table={observer_table}\npair_family={}\npair_table={}\npair_set={}\ndomain_error={}\n",
        paths.config.display(),
        paths.route_table,
        paths.rule_pref,
        paths.probe_rule_pref,
        paths.pbr_owner.display(),
        paths.probe_owner.display(),
        paths.route_error.display(),
        paths.fw4_family,
        paths.fw4_table,
        paths.fw4_chain,
        paths.fw4_comment,
        paths.nft_family,
        paths.nft_table,
        paths.mark_chain,
        paths.mss_chain,
        paths.forward_chain,
        paths.nat_chain,
        paths.nft_family,
        paths.nft_table,
        paths.domain_set,
        domain_error_path().display(),
    );
    let executable = env::current_exe()?;
    let mut command = Command::new(executable);
    command
        .arg("disable-cleanup")
        .env("Z2K_WARP_LOCK_HELD", "1");
    let output = process::output_with_input_timeout(
        &mut command,
        input.as_bytes(),
        Duration::from_secs(30),
    )?;
    if output.status.success() {
        Ok(())
    } else {
        Err(io::Error::other(
            String::from_utf8_lossy(&output.stderr).trim().to_owned(),
        ))
    }
}

fn unpin_legacy() {
    let z2k_etc = env_path("Z2K_ETC", "/etc/z2k");
    let z2k_tmp = env_path("Z2K_TMP", "/tmp/z2k");
    let autocircular_state = env::var_os("Z2K_AUTOCIRCULAR_STATE_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| z2k_etc.join("autocircular/state.tsv"));
    let fallback_dir = env::var_os("Z2K_AUTOCIRCULAR_FALLBACK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| z2k_tmp.join("autocircular"));
    let fallback_state = fallback_dir.join("z2k-autocircular-state.tsv");
    let state_dir = env_path("Z2K_STATE", &z2k_etc.join("state").to_string_lossy());
    let files = [
        env::var_os("STATE_FILE")
            .map(PathBuf::from)
            .unwrap_or(autocircular_state),
        env::var_os("STATE_FILE_FALLBACK")
            .map(PathBuf::from)
            .unwrap_or(fallback_state),
        state_dir.join("state.tsv"),
        PathBuf::from("/tmp/z2k-autocircular-state.tsv"),
    ];
    for path in files {
        let Ok(contents) = fs::read_to_string(&path) else {
            continue;
        };
        let mut filtered = String::with_capacity(contents.len());
        let mut removed = false;
        for line in contents.split_inclusive('\n') {
            let fields: Vec<_> = line.trim_end_matches(['\n', '\r']).split('\t').collect();
            if fields.len() >= 5
                && fields[0] == "rkn_tcp"
                && fields[1] == "cloudflareclient.com|4"
                && fields[4] == "manual"
            {
                removed = true;
            } else {
                filtered.push_str(line);
            }
        }
        if !removed {
            continue;
        }
        let Some(parent) = path.parent() else {
            continue;
        };
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos();
        let temporary = parent.join(format!(".z2k-unpin-{}-{nonce}", std::process::id()));
        let result = (|| -> io::Result<()> {
            let mut file = OpenOptions::new()
                .write(true)
                .create_new(true)
                .mode(0o644)
                .open(&temporary)?;
            file.write_all(filtered.as_bytes())?;
            file.sync_all()?;
            drop(file);
            fs::rename(&temporary, &path)?;
            fs::File::open(parent)?.sync_all()
        })();
        if result.is_ok() {
            eprintln!("снято закрепление плеча, оставленное удалённым подборщиком");
        } else {
            let _ = fs::remove_file(temporary);
        }
    }
}

fn operation_path() -> PathBuf {
    env_path("WARP_OP_FILE", "/tmp/z2k/warp/op")
}

fn operation_is_current(pid: u32) -> bool {
    !matches!(
        crate::operation::current(&operation_path(), pid),
        OperationState::Superseded
    )
}

fn install_transaction_active() -> io::Result<bool> {
    let work = env_path("Z2K_OW_INSTALL_WORK", "/usr/lib/.z2k-install");
    match fs::symlink_metadata(work.join("transaction-active")) {
        Ok(_) => Ok(true),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn recovery_path() -> PathBuf {
    env_path(
        "WARP_PROCD_RECOVERY_FILE",
        "/tmp/z2k/warp/procd-recovery-attempt",
    )
}

fn remove_file_if_present(path: &Path) -> io::Result<()> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

pub fn reload_lists(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    if args.next().is_some() {
        return Err(invalid("лишние аргументы reload-lists"));
    }
    let paths = Paths::from_env();
    let _lock = acquire_user_lock()?;
    list_ops::migrate_lists(&paths.user_lists, &paths.games)?;
    sync_sets(&paths, true)?;
    Ok(())
}

pub fn ipset(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let reconcile = match args.next().as_deref() {
        None => false,
        Some("--reconcile-rules") => true,
        Some(_) => return Err(invalid("неверный параметр ipset")),
    };
    if args.next().is_some() {
        return Err(invalid("лишние аргументы ipset"));
    }
    let paths = Paths::from_env();
    let _lock = acquire_user_lock()?;
    if config::read_value(&paths.config, "GAME_WARP_ENABLED", "", MatchOrder::First)? != "1" {
        return Ok(());
    }
    sync_sets(&paths, true)?;
    sync_mark(&paths, true)?;
    let _ = apply_domain_policy(&paths);
    if reconcile
        && crate::status::is_route_ready()
        && (!sync_sets(&paths, false)? || !crate::status::is_route_ready())
    {
        return Err(io::Error::other(
            "после обновления списков WARP-маршрут не подтверждён",
        ));
    }
    Ok(())
}

pub fn mark_rules(args: &mut impl Iterator<Item = String>, apply: bool) -> io::Result<()> {
    if args.next().is_some() {
        return Err(invalid("лишние аргументы nft-mark-sync"));
    }
    let paths = Paths::from_env();
    let _lock = acquire_lock()?;
    if apply {
        let _ = apply_domain_policy(&paths);
        sync_mark(&paths, true)?;
    } else {
        println!("ready={}", u8::from(sync_mark(&paths, false)?));
    }
    Ok(())
}

pub fn health_check(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    if args.next().is_some() {
        return Err(invalid("лишние аргументы health-check"));
    }
    crate::status::require_protocol_v1()?;
    let paths = Paths::from_env();
    let lock = acquire_lock()?;
    let plan = health::observe(&paths);
    let observed_at = std::time::SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    if let Err(error) = crate::health_observation::record(
        &paths.health_observation,
        plan.action,
        plan.defer_reason,
        observed_at,
    ) {
        eprintln!("не удалось сохранить диагностику health-check WARP: {error}");
    }
    match plan.action {
        HealthAction::Defer => Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            format!(
                "состояние WARP временно не подтверждено; проверка отложена без изменений ({})",
                plan.defer_reason.unwrap_or("state-unreadable")
            ),
        )),
        HealthAction::Disabled => converge_off(&paths, true),
        HealthAction::BinaryMissing => {
            set_route_error(&paths, "warp-binary-missing");
            converge_off(&paths, false)
        }
        HealthAction::DeviceMissing => {
            set_route_error(&paths, "device-identity-missing");
            converge_off(&paths, false)?;
            if !registration_due()? {
                return Ok(());
            }
            register_device(&paths)?;
            drop(lock);
            restart_service_if_running()
        }
        HealthAction::ProcessAbsent => {
            note_daemon_death(&paths);
            set_route_error(&paths, "daemon-not-running");
            converge_off(&paths, false)?;
            match service_state()? {
                Some(false) => Ok(()),
                Some(true) => {
                    if procd_warp_instance_registered()? {
                        return Ok(());
                    }
                    if !claim_procd_recovery()? {
                        return Ok(());
                    }
                    drop(lock);
                    restart_service_if_running()
                }
                None => Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "состояние службы procd временно не подтверждено",
                )),
            }
        }
        HealthAction::NotReady => converge_probe_only(&paths),
        HealthAction::Ready => reconcile_ready(&paths, plan.interface.as_deref().unwrap_or("")),
    }
}

pub fn ready_event(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let pid = args
        .next()
        .ok_or_else(|| invalid("ожидается PID процесса z2k-warpd"))?
        .parse::<u32>()
        .map_err(|_| invalid("неверный PID процесса z2k-warpd"))?;
    if pid == 0 || args.next().is_some() {
        return Err(invalid("неверные аргументы ready-event"));
    }
    crate::status::require_protocol_v1()?;
    let paths = Paths::from_env();

    ready_event_operation_clear(&paths)?;
    let Some(_lock) = acquire_user_lock()? else {
        return Err(io::Error::new(
            io::ErrorKind::PermissionDenied,
            "ready-event WARP должен владеть mutation lock",
        ));
    };
    ready_event_operation_clear(&paths)?;
    if !ready_event_process_matches(&paths, pid)? {
        return Ok(());
    }

    let plan = health::observe(&paths);
    match plan.action {
        HealthAction::Defer => Err(ready_event_deferred(
            plan.defer_reason.unwrap_or("state-unreadable"),
        )),
        HealthAction::Ready => {
            ready_event_operation_clear(&paths)?;
            if !ready_event_process_matches(&paths, pid)? {
                return Ok(());
            }
            let confirmed = health::observe(&paths);
            match confirmed.action {
                HealthAction::Defer => Err(ready_event_deferred(
                    confirmed.defer_reason.unwrap_or("state-unreadable"),
                )),
                HealthAction::Ready => {
                    ready_event_operation_clear(&paths)?;
                    if !ready_event_process_matches(&paths, pid)? {
                        return Ok(());
                    }
                    reconcile_ready(&paths, confirmed.interface.as_deref().unwrap_or_default())
                }
                _ => Ok(()),
            }
        }
        _ => Ok(()),
    }
}

fn ready_event_operation_clear(paths: &Paths) -> io::Result<()> {
    match crate::operation::active(&operation_path(), &paths.proc_root) {
        Ok(false) => Ok(()),
        Ok(true) => Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "операция WARP уже выполняется",
        )),
        Err(error) => Err(ready_event_deferred(&format!(
            "operation-owner-unreadable: {error}"
        ))),
    }
}

fn ready_event_process_matches(paths: &Paths, pid: u32) -> io::Result<bool> {
    if !known_warp_pids(paths)?
        .iter()
        .any(|current| current == &pid.to_string())
    {
        return Ok(false);
    }
    let contents = fs::read(&paths.status)
        .map_err(|error| ready_event_deferred(&format!("engine-status-unreadable: {error}")))?;
    let value: serde_json::Value = serde_json::from_slice(&contents)
        .map_err(|error| ready_event_deferred(&format!("engine-status-unreadable: {error}")))?;
    let status_pid = value
        .get("pid")
        .and_then(serde_json::Value::as_u64)
        .ok_or_else(|| ready_event_deferred("engine-status-pid-unreadable"))?;
    Ok(status_pid == u64::from(pid))
}

fn ready_event_deferred(reason: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::WouldBlock,
        format!(
            "состояние WARP временно не подтверждено; событие готовности отложено без изменений ({reason})"
        ),
    )
}

pub fn event(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let event = args.next();
    if args.next().is_some() {
        return Err(invalid("лишние аргументы event"));
    }
    crate::status::require_protocol_v1()?;
    let paths = Paths::from_env();
    let _lock = acquire_lock()?;
    match event.as_deref() {
        Some("rules") => event_rules(&paths),
        Some("stop") => event_stop(&paths, false),
        Some("cleanup") => event_stop(&paths, true),
        Some("proc-bounce") => {
            remove_routes(&paths)?;
            let pids = known_warp_pids(&paths)?;
            terminate_warp_pids(&paths, &pids, bounded_seconds("WARP_PROC_STOP_WAIT", 5, 60))?;
            let _ = wait_ready_and_reconcile_for(
                &paths,
                std::process::id(),
                bounded_seconds("WARP_PROC_WAIT", 60, 600),
                None,
            )?;
            Ok(())
        }
        _ => Err(invalid(
            "ожидается событие rules, stop, cleanup или proc-bounce",
        )),
    }
}

pub fn domain_procd_ready(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let runtime = args
        .next()
        .ok_or_else(|| invalid("не задан runtime WARP"))?;
    let engine = args
        .next()
        .ok_or_else(|| invalid("не задан бинарный файл WARP"))?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы domain-procd-ready"));
    }
    crate::status::require_protocol_v1()?;
    let paths = Paths::from_env();
    let _lock = acquire_lock()?;
    let domains =
        lists::load_active_domains(&paths.user_lists, &paths.games, &paths.enabled_lists)?;
    let active = !domains.is_empty();

    if runtime != engine || !executable(Path::new(&runtime)) || paths.warp_bin != Path::new(&engine)
    {
        if active {
            domain_state::set_error_file(&domain_error_path(), "observer-runtime-unavailable")?;
        }
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "runtime domain observer недоступен",
        ));
    }
    if command_output("nft", &["--version"]).is_err() {
        if active {
            domain_state::set_error_file(&domain_error_path(), "nft-unavailable")?;
        }
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "команда nft недоступна",
        ));
    }
    if !active {
        domain_state::set_error_file(&domain_error_path(), "")?;
        println!("empty");
        return Ok(());
    }

    match fs::read_to_string(domain_error_path()) {
        Ok(error) if !error.is_empty() => {
            return Err(io::Error::other(
                "состояние domain observer требует восстановления",
            ));
        }
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    let observer_family = env_string("WARP_DOMAIN_NFT_FAMILY", "inet");
    let observer_table = env_string("WARP_DOMAIN_NFT_TABLE", "z2k_warp_dns");
    let output_chain = env_string("WARP_DOMAIN_NFT_OUT", "z2k_dns_output");
    let forward_chain = env_string("WARP_DOMAIN_NFT_FWD", "z2k_dns_forward");
    let group = env_string("WARP_DOMAIN_NFLOG_GROUP", "189");
    let verify = nft::DomainVerifyConfig {
        pair_family: &paths.nft_family,
        pair_table: &paths.nft_table,
        pair_set: &paths.domain_set,
        observer_family: &observer_family,
        observer_table: &observer_table,
        output_chain: &output_chain,
        forward_chain: &forward_chain,
        group: &group,
    };
    let ready = nft::verify_domain_observer(&verify).unwrap_or(false);
    if !ready {
        domain_state::set_error_file(&domain_error_path(), "domain-backend-unavailable")?;
        return Err(io::Error::other("nft backend domain observer не готов"));
    }
    domain_state::set_error_file(&domain_error_path(), "")?;
    println!("active");
    Ok(())
}

fn executable(path: &Path) -> bool {
    fs::metadata(path).is_ok_and(|metadata| metadata.permissions().mode() & 0o111 != 0)
}

fn event_rules(paths: &Paths) -> io::Result<()> {
    let plan = health::observe(paths);
    match plan.action {
        HealthAction::Defer => Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "состояние WARP временно не подтверждено; событие rules отложено без изменений",
        )),
        HealthAction::Disabled | HealthAction::BinaryMissing | HealthAction::DeviceMissing => {
            converge_off(paths, true)?;
            remove_domain_state(paths, false)
        }
        HealthAction::ProcessAbsent => {
            sync_sets(paths, true)?;
            let _ = apply_domain_policy(paths);
            sync_mark(paths, true)?;
            converge_off(paths, false)
        }
        HealthAction::NotReady => {
            sync_sets(paths, true)?;
            let _ = apply_domain_policy(paths);
            sync_mark(paths, true)?;
            converge_probe_only(paths)
        }
        HealthAction::Ready => reconcile_ready(paths, plan.interface.as_deref().unwrap_or("")),
    }
}

fn event_stop(paths: &Paths, full: bool) -> io::Result<()> {
    remove_runtime_marker("WARP_PROCD_INSTANCE_FILE", "/tmp/z2k/warp/procd-instance")?;
    let rebuild = env::var_os("WARP_PROCD_REBUILD_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/z2k/warp/procd-rebuild-in-progress"));
    if !rebuild.exists() {
        remove_runtime_marker(
            "WARP_PROCD_RECOVERY_FILE",
            "/tmp/z2k/warp/procd-recovery-attempt",
        )?;
    }
    remove_routes(paths)?;
    remove_fw4(paths)?;
    remove_domain_state(paths, full)?;
    remove_warp_nft(paths, full)
}

fn remove_runtime_marker(name: &str, default: &str) -> io::Result<()> {
    let path = env::var_os(name)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(default));
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn remove_warp_nft(paths: &Paths, full: bool) -> io::Result<()> {
    let tables = command_output("nft", &["list", "tables"])?;
    if !table_exists(&tables, &paths.nft_family, &paths.nft_table) {
        return Ok(());
    }
    let output = command_output(
        "nft",
        &["list", "table", &paths.nft_family, &paths.nft_table],
    )?;
    let batch = nft::render_warp_remove_batch(
        &output,
        &paths.nft_family,
        &paths.nft_table,
        &[
            paths.mark_chain.as_str(),
            paths.mss_chain.as_str(),
            paths.forward_chain.as_str(),
            paths.nat_chain.as_str(),
        ],
        &[paths.dst_set.as_str(), paths.src_set.as_str()],
        full,
    )?;
    if batch.is_empty() {
        Ok(())
    } else {
        nft::apply_transaction(&batch)
    }
}

fn registration_due() -> io::Result<bool> {
    let stamp = env::var_os("WARP_REG_STAMP")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/z2k/warp/register.stamp"));
    let retry = env::var("WARP_REG_RETRY")
        .ok()
        .and_then(|value| value.parse::<u64>().ok())
        .unwrap_or(600);
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    match crate::registration::attempt_due(&stamp, now, retry) {
        crate::state::Observation::Known(due) => Ok(due),
        crate::state::Observation::Unreadable => Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "метка повтора регистрации WARP временно недоступна",
        )),
    }
}

fn register_device(paths: &Paths) -> io::Result<()> {
    register_engine(paths, true)
}

fn register_engine(paths: &Paths, write_retry_stamp: bool) -> io::Result<()> {
    let stamp = env::var_os("WARP_REG_STAMP")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/z2k/warp/register.stamp"));
    if write_retry_stamp {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap_or_default()
            .as_secs();
        write_stamp(&stamp, now)?;
    }
    if let Some(parent) = paths.device.parent() {
        fs::create_dir_all(parent)?;
    }
    let mut command = Command::new(&paths.warp_bin);
    command.args(["register", "--device"]).arg(&paths.device);
    system_ca_environment(&mut command);
    let result = match process::output_with_timeout(&mut command, Duration::from_secs(90)) {
        Ok(result) => result,
        Err(error) => {
            record_registration_error(paths, &format!("регистрация WARP: {error}"));
            return Err(error);
        }
    };
    if !result.status.success() {
        let direct_error = registration_detail(&result.stderr, result.status.code());
        let proxy = external_proxy(paths);
        if proxy.is_empty() {
            record_registration_error(paths, &direct_error);
            return Err(io::Error::other(direct_error));
        }
        let mut command = Command::new(&paths.warp_bin);
        command
            .args(["register", "--device"])
            .arg(&paths.device)
            .arg("--proxy")
            .arg(proxy);
        system_ca_environment(&mut command);
        let proxied = match process::output_with_timeout(&mut command, Duration::from_secs(90)) {
            Ok(result) => result,
            Err(error) => {
                record_registration_error(paths, &format!("регистрация WARP через proxy: {error}"));
                return Err(error);
            }
        };
        if !proxied.status.success() {
            let detail = registration_detail(&proxied.stderr, proxied.status.code());
            record_registration_error(paths, &format!("proxy: {detail}"));
            return Err(io::Error::other(format!(
                "регистрация WARP через proxy: {detail}"
            )));
        }
    }
    clear_registration_error(paths);
    let mut permissions = fs::metadata(&paths.device)?.permissions();
    permissions.set_mode(0o600);
    fs::set_permissions(&paths.device, permissions)
}

fn system_ca_environment(command: &mut Command) {
    let configured_file = env::var_os("SSL_CERT_FILE").filter(|path| Path::new(path).is_file());
    if configured_file.is_none() {
        for candidate in [
            "/etc/ssl/cert.pem",
            "/etc/ssl/certs/ca-certificates.crt",
            "/etc/ssl/certs/ca-bundle.crt",
        ] {
            if Path::new(candidate).is_file() {
                command.env("SSL_CERT_FILE", candidate);
                break;
            }
        }
    }
    let configured_dir = env::var_os("SSL_CERT_DIR")
        .filter(|path| std::env::split_paths(path).any(|directory| directory.is_dir()));
    if configured_dir.is_none() && Path::new("/etc/ssl/certs").is_dir() {
        command.env("SSL_CERT_DIR", "/etc/ssl/certs");
    }
}

fn registration_detail(stderr: &[u8], code: Option<i32>) -> String {
    let detail = String::from_utf8_lossy(stderr)
        .split_whitespace()
        .collect::<Vec<_>>()
        .join(" ");
    if detail.is_empty() {
        format!(
            "регистрация WARP завершилась с кодом {}",
            code.unwrap_or(-1)
        )
    } else {
        detail.chars().take(240).collect()
    }
}

fn record_registration_error(paths: &Paths, detail: &str) {
    let Some(parent) = paths.device.parent() else {
        return;
    };
    if fs::create_dir_all(parent).is_err() {
        return;
    }
    let path = parent.join("registration-error");
    let temporary = parent.join(format!(".registration-error.new.{}", std::process::id()));
    let _ = fs::remove_file(&temporary);
    let Ok(mut file) = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)
    else {
        return;
    };
    if file.write_all(detail.as_bytes()).is_ok() {
        let _ = fs::rename(&temporary, &path);
    } else {
        let _ = fs::remove_file(&temporary);
    }
}

fn clear_registration_error(paths: &Paths) {
    if let Some(parent) = paths.device.parent() {
        let _ = fs::remove_file(parent.join("registration-error"));
    }
}

fn write_stamp(path: &Path, now: u64) -> io::Result<()> {
    let parent = path.parent().unwrap_or(Path::new("."));
    fs::create_dir_all(parent)?;
    let temporary = parent.join(format!(
        ".{}.new.{}",
        path.file_name().unwrap_or_default().to_string_lossy(),
        std::process::id()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create(true)
        .truncate(true)
        .open(&temporary)?;
    file.write_all(format!("{now}\n").as_bytes())?;
    file.sync_all()?;
    drop(file);
    fs::rename(&temporary, path)?;
    fs::File::open(parent)?.sync_all()
}

fn external_proxy(paths: &Paths) -> String {
    let proxy = match config::read_value(&paths.config, "Z2K_WARP_VPS_PROXY", "", MatchOrder::Last)
    {
        Ok(proxy) => proxy,
        Err(_) => return String::new(),
    };
    let Some((_, authority)) = proxy.split_once("://") else {
        return proxy;
    };
    let authority = authority.split('/').next().unwrap_or("");
    let host = authority.rsplit('@').next().unwrap_or("");
    let host = host
        .split(':')
        .next()
        .unwrap_or("")
        .trim_end_matches('.')
        .to_ascii_lowercase();
    if matches!(
        host.as_str(),
        "213.176.74.63" | "213.176.74.63.nip.io" | "79.137.196.7"
    ) {
        String::new()
    } else {
        proxy
    }
}

fn service_state() -> io::Result<Option<bool>> {
    if let Some(value) = query_service_registry()? {
        return Ok(Some(value.get("z2k-warp").is_some()));
    }
    let init = env::var_os("Z2K_WARP_INIT").unwrap_or_else(|| "/etc/init.d/z2k-warp".into());
    let mut command = Command::new(init);
    command.arg("running");
    match process::output(&mut command) {
        Ok(output) if output.status.success() => Ok(Some(true)),
        Ok(output) if output.status.code() == Some(1) => Ok(Some(false)),
        Ok(_) => Ok(None),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(Some(false)),
        Err(error) => Err(error),
    }
}

fn query_service_registry() -> io::Result<Option<serde_json::Value>> {
    for ubus in ["ubus", "/sbin/ubus", "/usr/sbin/ubus"] {
        let mut command = Command::new(ubus);
        command.args(["-S", "call", "service", "list"]);
        match process::output(&mut command) {
            Ok(output) if output.status.success() => {
                let value: serde_json::Value =
                    serde_json::from_slice(&output.stdout).map_err(|_| {
                        io::Error::new(io::ErrorKind::InvalidData, "ответ ubus не JSON")
                    })?;
                return Ok(Some(value));
            }
            Ok(_) => return Err(io::Error::other("ubus не подтвердил состояние z2k")),
            Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
            Err(error) => return Err(error),
        }
    }
    Ok(None)
}

fn procd_warp_instance_registered() -> io::Result<bool> {
    let value = query_service_registry()?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::NotFound,
            "ubus недоступен для проверки WARP instance",
        )
    })?;
    Ok(new_warp_instance_registered(&value))
}

fn new_warp_instance_registered(value: &serde_json::Value) -> bool {
    value
        .get("z2k-warp")
        .and_then(|service| service.get("instances"))
        .and_then(serde_json::Value::as_object)
        .is_some_and(|instances| instances.contains_key("main"))
}

fn legacy_warp_instance_registered(value: &serde_json::Value) -> bool {
    value
        .get("z2k")
        .and_then(|service| service.get("instances"))
        .and_then(|instances| instances.get("z2k-warp"))
        .is_some()
}

fn legacy_warp_instance_pid(value: &serde_json::Value) -> Option<String> {
    let pid = value
        .get("z2k")?
        .get("instances")?
        .get("z2k-warp")?
        .get("pid")?;
    let pid = pid
        .as_u64()
        .map(|pid| pid.to_string())
        .or_else(|| pid.as_str().map(str::to_owned))?;
    pid.parse::<u32>()
        .ok()
        .filter(|pid| *pid > 0)
        .map(|pid| pid.to_string())
}

fn claim_procd_recovery() -> io::Result<bool> {
    let marker = env::var_os("WARP_PROCD_RECOVERY_FILE")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/z2k/warp/procd-recovery-attempt"));
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs()
        .to_string();
    crate::recovery::claim(&marker, &now)
}

fn restart_service_if_running() -> io::Result<()> {
    match service_state()? {
        Some(true) => {}
        Some(false) => return Ok(()),
        None => {
            return Err(io::Error::new(
                io::ErrorKind::WouldBlock,
                "состояние службы WARP временно не подтверждено",
            ));
        }
    }
    let init = env::var_os("Z2K_WARP_INIT").unwrap_or_else(|| "/etc/init.d/z2k-warp".into());
    let mut command = Command::new(init);
    command.arg("restart");
    let output = process::output(&mut command)?;
    if output.status.success() {
        Ok(())
    } else {
        Err(io::Error::other(
            "procd не подтвердил перезапуск службы WARP",
        ))
    }
}

fn note_daemon_death(paths: &Paths) {
    let Ok(log) = fs::read_to_string(&paths.log) else {
        return;
    };
    if log.lines().next_back().is_some_and(|line| {
        line.contains(" stopped")
            || line.contains(" fatal: ")
            || line.contains("исчез без остановки")
    }) {
        return;
    }
    let status = read_json(&paths.status);
    let pid = status.get("pid").and_then(serde_json::Value::as_u64);
    let cause = pid
        .and_then(|pid| {
            let mut command = Command::new("dmesg");
            process::output(&mut command).ok().map(|output| {
                String::from_utf8_lossy(&output.stdout)
                    .lines()
                    .rfind(|line| line.contains(&format!("Killed process {pid} ")))
                    .unwrap_or("")
                    .to_owned()
            })
        })
        .filter(|line| !line.is_empty())
        .unwrap_or_else(|| "причина в логах не записана".into());
    if let Ok(mut file) = OpenOptions::new().append(true).open(&paths.log) {
        let _ = writeln!(
            file,
            "{} движок исчез без остановки (pid {}): {}",
            unix_now_string(),
            pid.map(|pid| pid.to_string()).unwrap_or_else(|| "?".into()),
            cause
        );
    }
}

fn unix_now_string() -> String {
    let seconds = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    seconds.to_string()
}

fn reconcile_ready(paths: &Paths, interface: &str) -> io::Result<()> {
    let address = status_address(&paths.status);
    if !valid_interface(interface) || address.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "готовый WARP status не содержит допустимый интерфейс и IPv4-адрес",
        ));
    }
    if !sync_sets(paths, false)?
        && let Err(error) = sync_sets(paths, true)
    {
        return fail_open(paths, "nft-sets-apply-failed", error);
    }
    let _ = apply_domain_policy(paths);
    if !sync_mark(paths, false)?
        && let Err(error) = sync_mark(paths, true)
    {
        return fail_open(paths, "nft-mark-apply-failed", error);
    }
    if !verify_confirm(|| crate::status::verify_tun(paths))?
        && let Err(error) = apply_tun(paths, interface)
    {
        return fail_open(paths, "tun-apply-failed", error);
    }
    let route = route_config(paths, interface, &address);
    let route_ready = verify_confirm(|| routing::verify_policy(&route).map_err(io::Error::other))?;
    if !route_ready && let Err(error) = routing::reconcile_policy(&route).map_err(io::Error::other)
    {
        return fail_open(paths, "pbr-apply-failed", error);
    }
    if !verify_confirm(|| sync_sets(paths, false))? {
        return fail_open(
            paths,
            "nft-sets-verify-failed",
            invalid("nft-наборы WARP не совпали после синхронизации"),
        );
    }
    if !verify_confirm(|| sync_mark(paths, false))? {
        return fail_open(
            paths,
            "nft-mark-verify-failed",
            invalid("MARK-цепочка WARP не подтверждена после синхронизации"),
        );
    }
    if !verify_confirm(|| crate::status::verify_tun(paths))? {
        return fail_open(
            paths,
            "tun-verify-failed",
            invalid("TUN-цепочки WARP не подтверждены после синхронизации"),
        );
    }
    if !verify_confirm(|| crate::status::verify_pbr(paths))? {
        return fail_open(
            paths,
            "pbr-verify-failed",
            invalid("PBR WARP не подтверждён после синхронизации"),
        );
    }
    crate::route_error::clear(&paths.route_error)
}

fn verify_confirm(mut verify: impl FnMut() -> io::Result<bool>) -> io::Result<bool> {
    match verify() {
        Ok(true) => Ok(true),
        Ok(false) => verify(),
        Err(_) => verify(),
    }
}

fn converge_probe_only(paths: &Paths) -> io::Result<()> {
    remove_routes(paths)?;
    let plan = health::observe(paths);
    let status = read_json(&paths.status);
    let interface = status
        .get("iface")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let address = status_address(&paths.status);
    if plan.action == HealthAction::NotReady
        && valid_interface(interface)
        && address.parse::<std::net::Ipv4Addr>().is_ok()
    {
        let route = route_config(paths, interface, &address);
        routing::apply_policy(&route, false).map_err(io::Error::other)?;
    }
    clear_tun(paths, false)
}

fn converge_off(paths: &Paths, clear_mark: bool) -> io::Result<()> {
    remove_routes(paths)?;
    remove_fw4(paths)?;
    let mut chains = vec![
        paths.mss_chain.as_str(),
        paths.forward_chain.as_str(),
        paths.nat_chain.as_str(),
    ];
    if clear_mark {
        chains.push(paths.mark_chain.as_str());
    }
    clear_chains(paths, &chains)
}

fn clear_tun(paths: &Paths, clear_mark: bool) -> io::Result<()> {
    remove_fw4(paths)?;
    let mut chains = vec![
        paths.mss_chain.as_str(),
        paths.forward_chain.as_str(),
        paths.nat_chain.as_str(),
    ];
    if clear_mark {
        chains.push(paths.mark_chain.as_str());
    }
    clear_chains(paths, &chains)
}

fn clear_chains(paths: &Paths, chains: &[&str]) -> io::Result<()> {
    let tables = command_output("nft", &["list", "tables"])?;
    if !table_exists(&tables, &paths.nft_family, &paths.nft_table) {
        return Ok(());
    }
    let table = command_output(
        "nft",
        &["list", "table", &paths.nft_family, &paths.nft_table],
    )?;
    let batch = nft::render_chain_flush_batch(&table, &paths.nft_family, &paths.nft_table, chains)?;
    if batch.is_empty() {
        Ok(())
    } else {
        nft::apply_transaction(&batch)
    }
}

fn remove_fw4(paths: &Paths) -> io::Result<()> {
    let tables = command_output("nft", &["list", "tables"])?;
    if !table_exists(&tables, &paths.fw4_family, &paths.fw4_table) {
        return Ok(());
    }
    let chain = command_output(
        "nft",
        &[
            "-a",
            "list",
            "chain",
            &paths.fw4_family,
            &paths.fw4_table,
            &paths.fw4_chain,
        ],
    )?;
    let batch = nft::render_fw4_forward_remove_batch(
        &chain,
        &paths.fw4_family,
        &paths.fw4_table,
        &paths.fw4_chain,
        &paths.fw4_comment,
    )?;
    if batch.is_empty() {
        Ok(())
    } else {
        nft::apply_transaction(&batch)
    }
}

fn remove_routes(paths: &Paths) -> io::Result<()> {
    let status = read_json(&paths.status);
    let interface = status
        .get("iface")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("");
    let address = status_address(&paths.status);
    let route = route_config(paths, interface, &address);
    routing::remove_policy_from_owner_files(&route)
        .map(|_| ())
        .map_err(io::Error::other)
}

fn route_config<'a>(paths: &'a Paths, interface: &'a str, address: &'a str) -> RouteConfig<'a> {
    RouteConfig {
        interface,
        probe_address: address,
        table: paths.route_table,
        user_pref: paths.rule_pref,
        probe_pref: paths.probe_rule_pref,
        mark: parse_mark(&paths.mark),
        mask: parse_mark(&paths.mark_mask),
        pbr_owner: &paths.pbr_owner,
        probe_owner: &paths.probe_owner,
    }
}

fn apply_tun(paths: &Paths, interface: &str) -> io::Result<()> {
    let table = command_output(
        "nft",
        &["list", "table", &paths.nft_family, &paths.nft_table],
    )?;
    let mut batch = nft::render_tun_batch(
        &paths.nft_family,
        &paths.nft_table,
        &paths.mss_chain,
        &paths.forward_chain,
        &paths.nat_chain,
        interface,
    )?;
    let fw4 = command_output(
        "nft",
        &[
            "list",
            "chain",
            &paths.fw4_family,
            &paths.fw4_table,
            &paths.fw4_chain,
        ],
    )?;
    let fw4_batch = nft::render_fw4_forward_apply_batch(
        &fw4,
        &paths.fw4_family,
        &paths.fw4_table,
        &paths.fw4_chain,
        interface,
        &paths.mark,
        &paths.mark_mask,
        &paths.fw4_comment,
    )?;
    batch.push_str(&fw4_batch);
    if batch.is_empty() {
        return Ok(());
    }
    let _ = table;
    nft::apply_transaction(&batch)
}

fn fail_open(paths: &Paths, reason: &str, cause: io::Error) -> io::Result<()> {
    set_route_error(paths, reason);
    let cleanup = converge_off(paths, false);
    match cleanup {
        Ok(()) => Err(io::Error::other(format!("{reason}: {cause}"))),
        Err(error) => Err(io::Error::other(format!(
            "{reason}: {cause}; fail-open очистка не завершена: {error}"
        ))),
    }
}

fn set_route_error(paths: &Paths, reason: &str) {
    let _ = crate::route_error::set(&paths.route_error, reason);
}

fn status_address(path: &Path) -> String {
    read_json(path)
        .get("addr")
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_owned()
}

fn read_json(path: &Path) -> serde_json::Value {
    fs::read(path)
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or(serde_json::Value::Null)
}

fn valid_interface(value: &str) -> bool {
    let Some(suffix) = value.strip_prefix("z2ktun") else {
        return false;
    };
    (suffix.len() == 1 || suffix.len() == 2) && suffix.bytes().all(|byte| byte.is_ascii_digit())
}

fn parse_mark(value: &str) -> u32 {
    value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
        .map(|value| u32::from_str_radix(value, 16).unwrap_or(0))
        .unwrap_or_else(|| value.parse().unwrap_or(0))
}

fn acquire_lock() -> io::Result<Option<MutationLock>> {
    acquire_lock_with_wait(Duration::from_secs(30))
}

fn acquire_lock_with_wait(wait: Duration) -> io::Result<Option<MutationLock>> {
    if env::var("Z2K_WARP_LOCK_HELD").as_deref() == Ok("1") {
        return Ok(None);
    }
    let path = env::var_os("Z2K_WARP_LOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/z2k/warp/mutate.lock"));
    match MutationLock::acquire(&path, wait)? {
        Some(lock) => Ok(Some(lock)),
        None if wait.is_zero() => Ok(None),
        None => Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "операция WARP уже выполняется",
        )),
    }
}

fn acquire_user_lock() -> io::Result<Option<MutationLock>> {
    acquire_user_lock_with_wait(Duration::from_secs(30))
}

fn acquire_user_lock_with_wait(wait: Duration) -> io::Result<Option<MutationLock>> {
    let lock = acquire_lock_with_wait(wait)?;
    if install_transaction_active()? {
        return Err(io::Error::new(
            io::ErrorKind::WouldBlock,
            "идёт обновление z2kOW; действие WARP отложено",
        ));
    }
    Ok(lock)
}

fn sync_sets(paths: &Paths, apply: bool) -> io::Result<bool> {
    let snapshot = lists::load_active_lists(
        &paths.user_lists,
        &paths.games,
        &paths.enabled_lists,
        &paths.devices,
    )?;
    let destinations = lists::normalize_destinations(&snapshot.validation.addresses.join("\n"));
    let leases = env::var_os("WARP_DHCP_LEASES")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/dhcp.leases"));
    let mut sources =
        devices::resolve_selected_devices_from_text(&snapshot.device_sources, &leases)?;
    sources.sort();
    sources.dedup();
    if destinations.is_empty()
        && sources.is_empty()
        && snapshot.validation.domains.is_empty()
        && snapshot.has_nonempty_input
    {
        return Err(invalid(
            "непустые источники не содержат допустимых адресов; nft не изменён",
        ));
    }
    let table = command_output(
        "nft",
        &["list", "table", &paths.nft_family, &paths.nft_table],
    )?;
    let inventory = nft::parse_set_inventory(
        &table,
        &paths.nft_family,
        &paths.nft_table,
        &paths.dst_set,
        &paths.src_set,
    )?;
    if nft::sets_match(&inventory, &destinations, &sources) {
        return Ok(true);
    }
    if !apply {
        return Ok(false);
    }
    let batch = nft::render_set_batch_with_create(
        &paths.nft_family,
        &paths.nft_table,
        &paths.dst_set,
        &paths.src_set,
        &inventory,
        &destinations,
        &sources,
    )?;
    nft::apply_transaction(&batch)?;
    Ok(true)
}

fn sync_mark(paths: &Paths, apply: bool) -> io::Result<bool> {
    let inputs = lists::load_mark_policy_inputs(
        &paths.user_lists,
        &paths.games,
        &paths.enabled_lists,
        &paths.devices,
    )?;
    let wdtt = config::read_value(&paths.config, "Z2K_WARP_WDTT", "0", MatchOrder::Last)? == "1";
    let tables = command_output("nft", &["list", "tables"])?;
    if !table_exists(&tables, &paths.nft_family, &paths.nft_table) {
        if apply {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "таблица nft отсутствует для MARK-цепочки",
            ));
        }
        return Ok(false);
    }
    let table = command_output(
        "nft",
        &["list", "table", &paths.nft_family, &paths.nft_table],
    )?;
    let inventory = nft::parse_set_inventory(
        &table,
        &paths.nft_family,
        &paths.nft_table,
        &paths.dst_set,
        &paths.src_set,
    )?;
    let flags = nft::plan_mark_flags(
        inputs.scope.as_str(),
        wdtt,
        !inputs.domains.is_empty(),
        inventory
            .destinations
            .as_ref()
            .is_some_and(|destinations| !destinations.is_empty()),
    )?;
    let domain_rules_active = !inputs.domains.is_empty() && inputs.scope.as_str() != "all";
    if domain_rules_active
        && nft::domain_pair_set_matches(
            &table,
            &paths.nft_family,
            &paths.nft_table,
            &paths.domain_set,
        )?
        .is_none()
    {
        if !apply {
            return Ok(false);
        }
        ensure_domain_pair_set(paths)?;
    }
    let lan = if inputs.scope.as_str() == "all" {
        openwrt::discover_interfaces(InterfaceKind::Lan)?
    } else {
        Vec::new()
    };
    let servers = openwrt::discover_interfaces(InterfaceKind::WireGuardServers)?;
    let clients = openwrt::discover_interfaces(InterfaceKind::WireGuardClients)?;
    let batch = nft::render_mark_batch(&MarkConfig {
        family: &paths.nft_family,
        table: &paths.nft_table,
        chain: &paths.mark_chain,
        destination_set: &paths.dst_set,
        source_set: &paths.src_set,
        domain_set: if domain_rules_active {
            &paths.domain_set
        } else {
            ""
        },
        scope: inputs.scope.as_str(),
        wdtt_active: flags.wdtt_active,
        list_active: flags.list_active,
        lan_ifaces: &lan,
        wireguard_servers: &servers,
        wireguard_clients: &clients,
    })?;
    if nft::mark_chain_matches(
        &table,
        &paths.nft_family,
        &paths.nft_table,
        &paths.mark_chain,
        &batch,
    )? == Some(true)
    {
        return Ok(true);
    }
    if !apply {
        return Ok(false);
    }
    nft::apply_transaction(&batch)?;
    Ok(true)
}

fn apply_domain_policy(paths: &Paths) -> io::Result<()> {
    let domains =
        lists::load_active_domains(&paths.user_lists, &paths.games, &paths.enabled_lists)?;
    let scope = lists::policy_scope(
        &paths.user_lists,
        &paths.games,
        &paths.enabled_lists,
        &paths.devices,
    )?;
    if domains.is_empty() || scope.as_str() == "all" {
        if remove_domain_state(paths, false).is_ok() {
            let _ = domain_state::set_error_file(&domain_error_path(), "");
        } else {
            let _ = domain_state::set_error_file(&domain_error_path(), "nft-domain-remove-failed");
        }
        return Ok(());
    }
    let rules = domain_rules_path();
    let error = domain_error_path();
    let _ = domain_state::sync_rules_file(&rules, &error, &domains);
    ensure_domain_pair_set(paths)?;
    let _ = apply_domain_observer(&error);
    Ok(())
}

fn ensure_domain_pair_set(paths: &Paths) -> io::Result<()> {
    let table = command_output(
        "nft",
        &["list", "table", &paths.nft_family, &paths.nft_table],
    )?;
    if nft::domain_pair_set_matches(
        &table,
        &paths.nft_family,
        &paths.nft_table,
        &paths.domain_set,
    )?
    .is_some()
    {
        return Ok(());
    }
    nft::apply_transaction(&nft::render_domain_pair_set_create_batch(
        &paths.nft_family,
        &paths.nft_table,
        &paths.domain_set,
    )?)
}

fn apply_domain_observer(error: &Path) -> io::Result<()> {
    let family = env_string("WARP_DOMAIN_NFT_FAMILY", "inet");
    let table = env_string("WARP_DOMAIN_NFT_TABLE", "z2k_warp_dns");
    let output_chain = env_string("WARP_DOMAIN_NFT_OUT", "z2k_dns_output");
    let forward_chain = env_string("WARP_DOMAIN_NFT_FWD", "z2k_dns_forward");
    let group = env_string("WARP_DOMAIN_NFLOG_GROUP", "189");
    let interfaces = if let Some(configured) = env::var_os("Z2K_WARP_DOMAIN_LAN_DEVICES") {
        configured
            .to_string_lossy()
            .split_whitespace()
            .map(str::to_owned)
            .collect::<BTreeSet<_>>()
    } else {
        let mut interfaces = openwrt::discover_interfaces(InterfaceKind::Lan)?
            .into_iter()
            .collect::<BTreeSet<_>>();
        interfaces.extend(openwrt::discover_interfaces(
            InterfaceKind::WireGuardServers,
        )?);
        interfaces.extend(openwrt::discover_interfaces(
            InterfaceKind::WireGuardClients,
        )?);
        interfaces
    };
    if interfaces.is_empty() {
        let _ = domain_state::set_error_file(error, "lan-device-unavailable");
        return Err(invalid(
            "не удалось определить LAN-интерфейсы для DNS observer",
        ));
    }
    let interfaces = interfaces.into_iter().collect::<Vec<_>>();
    let tables = command_output("nft", &["list", "tables"])?;
    let mut exists = table_exists(&tables, &family, &table);
    if !exists {
        nft::apply_transaction(&nft::render_domain_observer_table_create_batch(
            &family, &table,
        )?)?;
        exists = table_exists(
            &command_output("nft", &["list", "tables"])?,
            &family,
            &table,
        );
        if !exists {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "таблица nft observer отсутствует после создания",
            ));
        }
    }
    let current = command_output("nft", &["list", "table", &family, &table])?;
    if !nft::domain_observer_table_owned(&current, &family, &table)? {
        let _ = domain_state::set_error_file(error, "nft-observer-table-conflict");
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "таблица nft observer принадлежит другому компоненту",
        ));
    }
    let output_exists =
        nft::domain_observer_chain_owned(&current, &output_chain, "output")?.is_some();
    let forward_exists =
        nft::domain_observer_chain_owned(&current, &forward_chain, "forward")?.is_some();
    let output_matches = if output_exists {
        let chain = command_output("nft", &["list", "chain", &family, &table, &output_chain])?;
        nft::domain_observer_chain_rules_match(&chain, &output_chain, &interfaces, &group)
    } else {
        false
    };
    let forward_matches = if forward_exists {
        let chain = command_output("nft", &["list", "chain", &family, &table, &forward_chain])?;
        nft::domain_observer_chain_rules_match(&chain, &forward_chain, &interfaces, &group)
    } else {
        false
    };
    if exists && output_matches && forward_matches {
        return domain_state::set_error_file(error, "");
    }
    let batch = nft::render_domain_observer_batch(&DomainObserverConfig {
        family: &family,
        table: &table,
        output_chain: &output_chain,
        forward_chain: &forward_chain,
        group: &group,
        devices: &interfaces,
        table_exists: exists,
        output_exists,
        forward_exists,
    })?;
    nft::apply_transaction(&batch)?;
    domain_state::set_error_file(error, "")
}

fn remove_domain_state(paths: &Paths, full: bool) -> io::Result<()> {
    let observer_family = env_string("WARP_DOMAIN_NFT_FAMILY", "inet");
    let observer_table = env_string("WARP_DOMAIN_NFT_TABLE", "z2k_warp_dns");
    let tables = command_output("nft", &["list", "tables"])?;
    let observer_exists = table_exists(&tables, &observer_family, &observer_table);
    if observer_exists {
        let output = command_output("nft", &["list", "table", &observer_family, &observer_table])?;
        if !nft::domain_observer_table_owned(&output, &observer_family, &observer_table)? {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "таблица nft observer принадлежит другому компоненту",
            ));
        }
    }
    let pair_set_exists = if table_exists(&tables, &paths.nft_family, &paths.nft_table) {
        let output = command_output(
            "nft",
            &["list", "table", &paths.nft_family, &paths.nft_table],
        )?;
        nft::domain_pair_set_matches(
            &output,
            &paths.nft_family,
            &paths.nft_table,
            &paths.domain_set,
        )?
        .is_some()
    } else {
        false
    };
    let batch = nft::render_domain_remove_batch(&DomainRemoveConfig {
        family: &observer_family,
        observer_table: &observer_table,
        pair_family: &paths.nft_family,
        pair_table: &paths.nft_table,
        pair_set: &paths.domain_set,
        observer_exists,
        pair_set_exists,
        full,
    })?;
    if !batch.is_empty() {
        nft::apply_transaction(&batch)?;
    }
    Ok(())
}

fn command_output(program: &str, args: &[&str]) -> io::Result<String> {
    let result = process::output(Command::new(program).args(args))?;
    if !result.status.success() {
        return Err(io::Error::other(format!(
            "{program}: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )));
    }
    String::from_utf8(result.stdout)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn table_exists(tables: &str, family: &str, table: &str) -> bool {
    tables.lines().any(|line| {
        let mut fields = line.split_whitespace();
        fields.next() == Some("table")
            && fields.next() == Some(family)
            && fields.next() == Some(table)
    })
}

fn domain_rules_path() -> PathBuf {
    env::var_os("WARP_DOMAIN_RULES")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/z2k-warp/domains.v1"))
}

fn domain_error_path() -> PathBuf {
    env::var_os("WARP_DOMAIN_ERROR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/z2k-warp/domain-setup-error"))
}

fn env_string(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_owned())
}

fn env_path(name: &str, default: &str) -> PathBuf {
    env::var_os(name)
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from(default))
}

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
