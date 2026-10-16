use std::{fs, process::Command, time::SystemTime};

#[test]
fn событие_готовности_откладывает_reconcile_при_активной_операции() {
    let nonce = SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "z2k-warp-readiness-event-{}-{nonce}",
        std::process::id()
    ));
    let proc_root = root.join("proc");
    let owner = proc_root.join("424242");
    fs::create_dir_all(&owner).expect("каталог активной операции");
    fs::write(owner.join("comm"), "z2k-warp-controller\n").expect("процесс операции");
    let engine = proc_root.join("98765");
    fs::create_dir_all(&engine).expect("каталог Go-движка");
    fs::write(engine.join("comm"), "z2k-warpd\n").expect("процесс Go-движка");
    fs::write(engine.join("cmdline"), b"/usr/bin/z2k-warpd\0run\0").expect("аргументы Go-движка");
    let operation = root.join("tmp/warp/op");
    fs::create_dir_all(operation.parent().unwrap()).expect("каталог операции");
    fs::write(&operation, "424242\n").expect("владелец операции");
    let config = root.join("etc/config");
    fs::create_dir_all(config.parent().unwrap()).expect("каталог конфигурации");
    fs::write(&config, "ENABLED=1\nGAME_WARP_ENABLED=1\n").expect("конфигурация");
    let status = root.join("tmp/warp/status.json");
    fs::create_dir_all(status.parent().unwrap()).expect("каталог статуса");
    fs::write(
        &status,
        r#"{"ready":true,"iface":"z2ktun0","addr":"172.16.9.9","pid":98765}"#,
    )
    .expect("готовый статус Go-движка");
    let lock = root.join("tmp/warp/mutate.lock");

    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args(["ready-event", "424242"])
        .env("Z2K_WARP_PROTOCOL_VERSION", "1")
        .env("Z2K_PROC_ROOT", &proc_root)
        .env("WARP_OP_FILE", &operation)
        .env("Z2K_WARP_LOCK_DIR", &lock)
        .env("CONFIG_FILE", &config)
        .env("WARP_STATUS", &status)
        .output()
        .expect("запуск события готовности WARP");

    assert!(
        !output.status.success(),
        "активная операция должна отложить восстановление маршрутов"
    );
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("операция WARP уже выполняется"),
        "ожидалась причина DEFER, получено: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(&config).expect("конфигурация после события"),
        "ENABLED=1\nGAME_WARP_ENABLED=1\n"
    );
    assert!(!root.join("tmp/warp/pbr.owner").exists());
    assert!(!root.join("tmp/warp/route-error").exists());
    assert!(!lock.exists(), "событие освободило mutation lock");

    fs::remove_dir_all(root).expect("очистка временного каталога");
}

#[test]
fn событие_готовности_не_меняет_маршруты_при_нечитаемом_статусе() {
    let nonce = SystemTime::now()
        .duration_since(std::time::UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let root = std::env::temp_dir().join(format!(
        "z2k-warp-readiness-unknown-{}-{nonce}",
        std::process::id()
    ));
    let proc_root = root.join("proc");
    let engine = proc_root.join("98765");
    fs::create_dir_all(&engine).expect("каталог Go-движка");
    fs::write(engine.join("comm"), "z2k-warpd\n").expect("процесс Go-движка");
    fs::write(engine.join("cmdline"), b"/usr/bin/z2k-warpd\0run\0").expect("аргументы Go-движка");

    let config = root.join("etc/config");
    fs::create_dir_all(config.parent().unwrap()).expect("каталог конфигурации");
    fs::write(&config, "ENABLED=1\nGAME_WARP_ENABLED=1\n").expect("конфигурация");
    let status = root.join("tmp/warp/status.json");
    fs::create_dir_all(status.parent().unwrap()).expect("каталог статуса");
    fs::write(&status, b"{\"ready\":").expect("частично записанный статус");
    let device = root.join("etc/state/warp/device.json");
    fs::create_dir_all(device.parent().unwrap()).expect("каталог устройства");
    fs::write(&device, "{}\n").expect("файл устройства");
    let warp_bin = root.join("bin/z2k-warpd");
    fs::create_dir_all(warp_bin.parent().unwrap()).expect("каталог Go-бинарника");
    fs::write(&warp_bin, "#!/bin/sh\nexit 0\n").expect("Go-бинарник");
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&warp_bin, fs::Permissions::from_mode(0o755)).expect("права Go-бинарника");
    let lock = root.join("tmp/warp/mutate.lock");
    let pbr_owner = root.join("tmp/warp/pbr.owner");
    let route_error = root.join("tmp/warp/route-error");

    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args(["ready-event", "98765"])
        .env("Z2K_WARP_PROTOCOL_VERSION", "1")
        .env("Z2K_PROC_ROOT", &proc_root)
        .env("WARP_OP_FILE", root.join("tmp/warp/op"))
        .env("Z2K_WARP_LOCK_DIR", &lock)
        .env("CONFIG_FILE", &config)
        .env("WARP_DEVICE", &device)
        .env("WARP_BIN", &warp_bin)
        .env("WARP_STATUS", &status)
        .env("WARP_PBR_OWNER", &pbr_owner)
        .env("WARP_ROUTE_ERROR_FILE", &route_error)
        .output()
        .expect("запуск события готовности WARP");

    assert!(
        !output.status.success(),
        "нечитаемый статус должен отложить событие готовности"
    );
    assert!(
        String::from_utf8_lossy(&output.stderr).contains("состояние WARP временно не подтверждено"),
        "ожидался DEFER по неизвестному статусу, получено: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        fs::read_to_string(&config).expect("конфигурация после события"),
        "ENABLED=1\nGAME_WARP_ENABLED=1\n"
    );
    assert!(!pbr_owner.exists(), "UNKNOWN readiness создал PBR owner");
    assert!(
        !route_error.exists(),
        "UNKNOWN readiness записал route error"
    );
    assert!(!lock.exists(), "событие освободило mutation lock");

    fs::remove_dir_all(root).expect("очистка временного каталога");
}
