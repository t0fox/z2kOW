use std::process::Command;

#[test]
fn lifecycle_plan_preserves_procd_transition_contract() {
    let cases = [
        ("enable", "0", "1", "1", "rebuild"),
        ("enable", "1", "1", "1", "reload"),
        ("enable", "1", "1", "0", "rebuild"),
        ("enable", "0", "0", "1", "none"),
        ("disable", "1", "1", "1", "rebuild"),
        ("disable", "1", "1", "0", "reload"),
        ("disable", "1", "0", "1", "none"),
        ("restart", "0", "1", "1", "none"),
        ("restart", "1", "1", "1", "rebuild"),
        ("restart", "1", "0", "1", "none"),
        ("enable", "1", "unreadable", "0", "defer"),
        ("disable", "0", "unreadable", "1", "defer"),
        ("restart", "1", "unreadable", "1", "defer"),
    ];

    for (intent, was_enabled, service_active, process_running, expected) in cases {
        let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
            .args([
                "service-plan",
                intent,
                was_enabled,
                service_active,
                process_running,
            ])
            .output()
            .expect("запуск CLI-контроллера");

        assert!(
            output.status.success(),
            "service-plan {intent} завершился с ошибкой: {}",
            String::from_utf8_lossy(&output.stderr)
        );
        assert_eq!(
            output.stdout,
            format!("{expected}\n").as_bytes(),
            "неверное решение для {intent}/{was_enabled}/{service_active}/{process_running}"
        );
    }
}

#[test]
fn lifecycle_plan_rejects_unknown_intent_and_unreadable_booleans() {
    let binary = env!("CARGO_BIN_EXE_z2k-warp-controller");
    for arguments in [
        vec!["service-plan", "register", "1", "1", "1"],
        vec!["service-plan", "enable", "maybe", "1", "1"],
        vec!["service-plan", "enable", "1", "maybe", "1"],
        vec!["service-plan", "enable", "1", "1", "1", "extra"],
    ] {
        let output = Command::new(binary)
            .args(arguments)
            .output()
            .expect("запуск CLI-контроллера");
        assert!(!output.status.success(), "аргументы должны быть отклонены");
    }
}
