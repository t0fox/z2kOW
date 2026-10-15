use warp_controller::nft::tun_chains_match;

const TABLE: &str = r#"table inet zapret2 {
 chain z2k_warp_mss {
  oifname "z2ktun0" tcp flags syn tcp option maxseg size set rt mtu
  iifname "z2ktun0" tcp flags syn tcp option maxseg size set 1240
 }
 chain z2k_warp_fwd {
  oifname "z2ktun0" accept
 }
 chain z2k_warp_nat {
  oifname "z2ktun0" masquerade
 }
}"#;

fn verify(table: &str, interface: &str) -> std::io::Result<bool> {
    tun_chains_match(
        table,
        "inet",
        "zapret2",
        "z2k_warp_mss",
        "z2k_warp_fwd",
        "z2k_warp_nat",
        interface,
    )
}

#[test]
fn принимает_только_точные_правила_всех_tun_цепей() {
    assert!(verify(TABLE, "z2ktun0").unwrap());
}

#[test]
fn отсутствие_или_лишнее_правило_не_считается_готовым_состоянием() {
    let missing = TABLE.replace(
        " chain z2k_warp_nat {\n  oifname \"z2ktun0\" masquerade\n }\n",
        "",
    );
    assert!(!verify(&missing, "z2ktun0").unwrap());
    let extra = TABLE.replace(
        "  oifname \"z2ktun0\" accept\n",
        "  oifname \"z2ktun0\" accept\n  counter\n",
    );
    assert!(!verify(&extra, "z2ktun0").unwrap());
}

#[test]
fn отклоняет_невалидный_интерфейс_до_сравнения() {
    assert!(verify(TABLE, "z2ktun0;flush").is_err());
}
