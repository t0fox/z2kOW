use std::{path::PathBuf, process::Command};
use warp_controller::routing::{RouteConfig, apply_policy, remove_policy};

#[test]
fn actual_iproute2_policy_is_idempotent_and_owned() {
    if std::env::var_os("Z2K_WARP_REAL_IPROUTE2").is_none() {
        return;
    }
    let root = std::env::var_os("Z2K_WARP_REAL_STATE")
        .map(PathBuf::from)
        .expect("задайте каталог временного состояния для реального теста");
    let pbr_owner = root.join("pbr.owner");
    let probe_owner = root.join("probe.owner");
    let config = RouteConfig {
        interface: "z2ktun0",
        probe_address: "192.0.2.1",
        table: 989,
        user_pref: 500,
        probe_pref: 499,
        mark: 0x8000_0000,
        mask: 0x8000_0000,
        pbr_owner: &pbr_owner,
        probe_owner: &probe_owner,
    };

    assert!(apply_policy(&config, true).expect("установка маршрутов через iproute2"));
    assert!(!apply_policy(&config, true).expect("повторная установка должна быть пустой"));
    let cli = env!("CARGO_BIN_EXE_z2k-warp-controller");
    let applied = Command::new(cli)
        .args([
            "route-apply",
            "z2ktun0",
            "192.0.2.1",
            "989",
            "500",
            "499",
            "0x80000000",
            "0x80000000",
            pbr_owner.to_str().unwrap(),
            probe_owner.to_str().unwrap(),
            "1",
        ])
        .status()
        .expect("запуск Rust CLI для сверки живого состояния");
    assert!(
        applied.success(),
        "CLI должен принять уже установленный принадлежащий маршрут"
    );
    let verified = Command::new(cli)
        .args([
            "route-verify",
            "z2ktun0",
            "192.0.2.1",
            "989",
            "500",
            "499",
            "0x80000000",
            "0x80000000",
            pbr_owner.to_str().unwrap(),
            probe_owner.to_str().unwrap(),
        ])
        .output()
        .expect("запуск read-only route-verify через реальный iproute2");
    assert!(
        verified.status.success(),
        "CLI должен подтвердить принадлежащий PBR: {}",
        String::from_utf8_lossy(&verified.stderr)
    );
    assert_eq!(String::from_utf8(verified.stdout).unwrap(), "ready=1\n");
    let removed = Command::new(cli)
        .args([
            "route-remove",
            "z2ktun0",
            "192.0.2.1",
            "989",
            "500",
            "499",
            "0x80000000",
            "0x80000000",
            pbr_owner.to_str().unwrap(),
            probe_owner.to_str().unwrap(),
        ])
        .status()
        .expect("запуск Rust CLI для снятия маршрутов");
    assert!(removed.success(), "CLI должен снять принадлежащие маршруты");
    let absent = Command::new(cli)
        .args([
            "route-verify",
            "z2ktun0",
            "192.0.2.1",
            "989",
            "500",
            "499",
            "0x80000000",
            "0x80000000",
            pbr_owner.to_str().unwrap(),
            probe_owner.to_str().unwrap(),
        ])
        .output()
        .expect("проверка снятого PBR");
    assert!(absent.status.success());
    assert_eq!(String::from_utf8(absent.stdout).unwrap(), "ready=0\n");
    assert!(!remove_policy(&config).expect("повторное снятие должно быть пустым"));

    let rules = Command::new("ip").args(["rule", "show"]).output().unwrap();
    let rules = String::from_utf8(rules.stdout).unwrap();
    assert!(
        !rules
            .lines()
            .any(|line| line.starts_with("499:") || line.starts_with("500:"))
    );
    let routes = Command::new("ip")
        .args(["route", "show", "table", "989"])
        .output()
        .unwrap();
    assert!(routes.stdout.is_empty());
}
