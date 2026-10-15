use std::process::Command;

fn plan(enabled: &str, engine: &str, policy: &str) -> std::process::Output {
    Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args(["policy-plan", enabled, engine, policy])
        .output()
        .expect("запуск CLI-контроллера")
}

#[test]
fn исправное_состояние_не_меняет_политику() {
    let output = plan("enabled", "ready", "present");
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap().trim(), "noop");
}

#[test]
fn готовый_движок_создаёт_отсутствующую_политику() {
    let output = plan("enabled", "ready", "absent");
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap().trim(), "apply");
}

#[test]
fn неготовый_движок_снимает_существующую_политику() {
    let output = plan("enabled", "not-ready", "present");
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap().trim(), "remove");
}

#[test]
fn ошибка_чтения_откладывает_изменения() {
    for observations in [
        ("enabled", "unreadable", "present"),
        ("enabled", "ready", "unreadable"),
        ("unreadable", "ready", "absent"),
    ] {
        let output = plan(observations.0, observations.1, observations.2);
        assert!(output.status.success());
        assert_eq!(String::from_utf8(output.stdout).unwrap().trim(), "defer");
    }
}

#[test]
fn выключенный_флаг_снимает_политику_без_статуса_движка() {
    let output = plan("disabled", "unreadable", "present");
    assert!(output.status.success());
    assert_eq!(String::from_utf8(output.stdout).unwrap().trim(), "remove");
}

#[test]
fn неизвестное_наблюдение_отклоняется() {
    let output = plan("enabled", "unknown", "present");
    assert!(!output.status.success());
}
