use std::{fs, os::unix::fs::PermissionsExt, process::Command};

#[test]
fn controller_defers_on_unreadable_proc_without_touching_route_state() {
    let root = std::env::temp_dir().join(format!("z2k-warp-health-defer-{}", std::process::id()));
    let _ = fs::remove_dir_all(&root);
    let etc = root.join("etc");
    let state = root.join("state");
    let temp = root.join("tmp");
    let lists = root.join("lists");
    fs::create_dir_all(&etc).expect("каталог конфигурации");
    fs::create_dir_all(&state).expect("каталог состояния");
    fs::create_dir_all(&temp).expect("каталог временных файлов");
    fs::create_dir_all(&lists).expect("каталог списков");

    let config = etc.join("config");
    fs::write(&config, "ENABLED=1\nGAME_WARP_ENABLED=1\n").expect("конфигурация");
    let binary = root.join("z2k-warpd");
    fs::write(&binary, "fixture\n").expect("файл движка");
    let mut permissions = fs::metadata(&binary).expect("права движка").permissions();
    permissions.set_mode(0o755);
    fs::set_permissions(&binary, permissions).expect("исполняемые права");
    let device = state.join("device.json");
    fs::write(&device, "{}\n").expect("регистрация устройства");
    let proc_root = root.join("proc-not-readable");
    let route_error = temp.join("warp/route-error");
    let health_observation = temp.join("warp/health-observation.json");
    fs::create_dir_all(health_observation.parent().expect("каталог наблюдения"))
        .expect("каталог health observation");
    fs::write(
        &health_observation,
        r#"{"version":1,"state":"ready","observed_at":100,"last_success_at":100,"source":"health-check","reason":"ready"}"#,
    )
    .expect("предыдущая успешная проверка");

    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .arg("health-check")
        .env("Z2K_WARP_PROTOCOL_VERSION", "1")
        .env("CONFIG_FILE", &config)
        .env("WARP_BIN", &binary)
        .env("WARP_DEVICE", &device)
        .env("WARP_STATUS", root.join("status.json"))
        .env("Z2K_PROC_ROOT", &proc_root)
        .env("Z2K_ETC", &etc)
        .env("Z2K_ROOT", &root)
        .env("Z2K_STATE", &state)
        .env("Z2K_TMP", &temp)
        .env("Z2K_LISTS_DIR", &lists)
        .env("WARP_ROUTE_ERROR_FILE", &route_error)
        .env("WARP_HEALTH_OBSERVATION", &health_observation)
        .env("WARP_LOCK_DIR", temp.join("warp/mutate.lock"))
        .output()
        .expect("запуск контроллера health-check");

    assert!(
        !output.status.success(),
        "нечитаемый procfs не должен выглядеть как успешная проверка"
    );
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("проверка отложена без изменений"),
        "контроллер должен явно сообщить об отложенной проверке"
    );
    assert_eq!(
        fs::read_to_string(&config).expect("конфигурация после проверки"),
        "ENABLED=1\nGAME_WARP_ENABLED=1\n"
    );
    assert!(
        !route_error.exists(),
        "нечитаемое состояние не должно снимать маршрут"
    );
    let observation: serde_json::Value = serde_json::from_slice(
        &fs::read(&health_observation).expect("снимок проверки health-check"),
    )
    .expect("валидный JSON наблюдения");
    assert_eq!(observation["state"], "unknown");
    assert_eq!(observation["source"], "health-check");
    assert_eq!(observation["reason"], "proc-unreadable");
    assert_eq!(observation["last_success_at"], 100);
    assert!(
        !temp.join("warp/mutate.lock").exists(),
        "lock должен освобождаться"
    );
    fs::remove_dir_all(root).expect("очистка временного каталога");
}
