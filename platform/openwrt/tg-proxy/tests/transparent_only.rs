use clap::Parser;
use z2kow_tg_transparent::config::Config;

#[test]
fn generic_proxy_arguments_are_rejected_by_the_transparent_configuration() {
    for arguments in [
        vec!["tg-ws-proxy", "--transparent"],
        vec!["tg-ws-proxy", "--link-ip", "192.0.2.1"],
        vec![
            "tg-ws-proxy",
            "--secret",
            "11111111111111111111111111111111",
        ],
        vec!["tg-ws-proxy", "--listen-faketls-domain", "example.com"],
        vec!["tg-ws-proxy", "--pool-size", "0"],
        vec!["tg-ws-proxy", "--dc-ip", "2:149.154.167.51"],
        vec!["tg-ws-proxy", "--mtproto-proxy", "proxy.example:443:secret"],
        vec!["tg-ws-proxy", "--no-outbound-proxy"],
    ] {
        let result = Config::try_parse_from(arguments.clone());
        assert!(
            result.is_err(),
            "legacy arguments were accepted: {arguments:?}"
        );
    }
}

#[test]
fn help_exposes_only_the_openwrt_listener_and_connection_controls() {
    let output = std::process::Command::new(env!("CARGO_BIN_EXE_tg-ws-proxy"))
        .arg("--help")
        .output()
        .expect("tg-ws-proxy help should start");
    assert!(output.status.success());
    let help = String::from_utf8_lossy(&output.stdout);
    for option in [
        "--port",
        "--max-connections",
        "--transparent-ports",
        "--transparent-cidrs",
    ] {
        assert!(help.contains(option), "missing OpenWrt option {option}");
    }
    for option in [
        "--transparent ",
        "--link-ip",
        "--secret",
        "--listen-faketls-domain",
        "--pool-size",
        "--mtproto-proxy",
        "--dc-ip",
    ] {
        assert!(
            !help.contains(option),
            "legacy option remains in help: {option}"
        );
    }
}
