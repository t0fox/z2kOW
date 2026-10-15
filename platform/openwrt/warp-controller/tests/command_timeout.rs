#![cfg(unix)]

use std::{
    env, fs,
    os::unix::fs::PermissionsExt,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

#[test]
fn зависшая_системная_команда_завершается_по_дедлайну() {
    let id = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    let dir = env::temp_dir().join(format!(
        "z2k-warp-command-timeout-{}-{id}",
        std::process::id()
    ));
    fs::create_dir_all(&dir).unwrap();
    let uci = dir.join("uci");
    fs::write(&uci, "#!/bin/sh\nexec /bin/sleep 6\n").unwrap();
    fs::set_permissions(&uci, fs::Permissions::from_mode(0o755)).unwrap();

    let mut paths = vec![dir.clone()];
    paths.extend(env::split_paths(&env::var_os("PATH").unwrap_or_default()));
    let path = env::join_paths(paths).unwrap();
    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args(["interfaces", "wireguard-clients"])
        .env("PATH", path)
        .output()
        .unwrap();
    let stderr = String::from_utf8_lossy(&output.stderr);
    fs::remove_dir_all(dir).unwrap();

    assert!(
        !output.status.success(),
        "зависшая команда неожиданно прошла"
    );
    assert!(
        stderr.contains("тайм-аут"),
        "нет причины тайм-аута: {stderr}"
    );
}
