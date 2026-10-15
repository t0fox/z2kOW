#![cfg(unix)]

use std::{
    env, fs,
    os::unix::fs::PermissionsExt,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

fn write_executable(path: &std::path::Path, contents: &str) {
    fs::write(path, contents).unwrap();
    fs::set_permissions(path, fs::Permissions::from_mode(0o755)).unwrap();
}

fn run_with_ubus(script: &str) -> std::process::Output {
    let id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = env::temp_dir().join(format!("z2k-warp-ubus-error-{}-{id}", std::process::id()));
    fs::create_dir_all(&dir).unwrap();
    write_executable(
        &dir.join("uci"),
        "#!/bin/sh\ncase \"$*\" in\n  *firewall*) printf \"firewall.lan=zone\\nfirewall.lan.name='lan'\\nfirewall.lan.network='lan'\\n\" ;;\n  *network*) printf \"network.lan=interface\\nnetwork.lan.device='br-lan'\\n\" ;;\nesac\n",
    );
    write_executable(&dir.join("ubus"), script);

    let mut paths = vec![dir.clone()];
    paths.extend(env::split_paths(&env::var_os("PATH").unwrap_or_default()));
    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args(["interfaces", "lan"])
        .env("PATH", env::join_paths(paths).unwrap())
        .output()
        .unwrap();
    fs::remove_dir_all(dir).unwrap();
    output
}

#[test]
fn сбой_ubus_не_подменяется_устаревшим_устройством_из_uci() {
    let output = run_with_ubus("#!/bin/sh\nprintf 'temporary ubus failure\\n' >&2\nexit 1\n");
    let stderr = String::from_utf8_lossy(&output.stderr);

    assert!(
        !output.status.success(),
        "сбой ubus принят за отсутствие устройства"
    );
    assert!(stderr.contains("ubus"), "ошибка ubus потеряна: {stderr}");
}

#[test]
fn отсутствие_ubus_объекта_позволяет_использовать_настройку_uci() {
    let output = run_with_ubus("#!/bin/sh\nprintf 'Command failed: Not found\\n' >&2\nexit 1\n");

    assert!(output.status.success());
    assert_eq!(String::from_utf8_lossy(&output.stdout), "br-lan\n");
}
