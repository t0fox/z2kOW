use std::io;
use warp_controller::nft::{MarkConfig, mark_chain_matches, plan_mark_flags, render_mark_batch};

#[test]
fn mark_flags_include_domains_or_live_destinations_and_gate_wdtt() -> io::Result<()> {
    let flags = plan_mark_flags("lists", true, false, true)?;
    assert!(flags.list_active);
    assert!(flags.wdtt_active);

    let flags = plan_mark_flags("devices", true, true, false)?;
    assert!(flags.list_active);
    assert!(flags.wdtt_active);

    let flags = plan_mark_flags("lists", true, false, false)?;
    assert!(!flags.list_active);
    assert!(!flags.wdtt_active);

    let flags = plan_mark_flags("lists", false, true, true)?;
    assert!(flags.list_active);
    assert!(!flags.wdtt_active);
    Ok(())
}

#[test]
fn full_device_scope_suppresses_list_and_wdtt_rules() -> io::Result<()> {
    let flags = plan_mark_flags("full", true, true, true)?;
    assert!(!flags.list_active);
    assert!(!flags.wdtt_active);
    Ok(())
}

#[test]
fn all_traffic_scope_uses_wdtt_preference_without_list_data() -> io::Result<()> {
    let enabled = plan_mark_flags("all", true, false, false)?;
    assert!(!enabled.list_active);
    assert!(enabled.wdtt_active);

    let disabled = plan_mark_flags("all", false, false, false)?;
    assert!(!disabled.list_active);
    assert!(!disabled.wdtt_active);
    Ok(())
}

#[test]
fn mark_flag_planner_rejects_unknown_scope() {
    assert!(plan_mark_flags("other", true, true, true).is_err());
}

#[test]
fn list_mode_marks_only_the_destination_set_and_preserves_wireguard_exclusion() -> io::Result<()> {
    let batch = render_mark_batch(&MarkConfig {
        family: "inet",
        table: "zapret2",
        chain: "z2k_warp_mark",
        destination_set: "z2k_warp_dst4",
        source_set: "z2k_warp_src4",
        domain_set: "",
        scope: "lists",
        wdtt_active: false,
        list_active: false,
        lan_ifaces: &[],
        wireguard_servers: &["wgserver0".into()],
        wireguard_clients: &[],
    })?;
    assert!(batch.contains("ip daddr @z2k_warp_dst4 meta mark set mark & 0x7fffffff ^ 0x80000000"));
    assert!(batch.contains("iifname wgserver0 return"));
    assert!(!batch.contains("ip saddr @z2k_warp_src4 ip daddr @z2k_warp_dst4"));
    Ok(())
}

#[test]
fn domain_pairs_join_the_same_atomic_policy_batch() -> io::Result<()> {
    let batch = render_mark_batch(&MarkConfig {
        family: "inet",
        table: "zapret2",
        chain: "z2k_warp_mark",
        destination_set: "z2k_warp_dst4",
        source_set: "z2k_warp_src4",
        domain_set: "z2k_warp_domain4",
        scope: "lists",
        wdtt_active: false,
        list_active: false,
        lan_ifaces: &[],
        wireguard_servers: &[],
        wireguard_clients: &[],
    })?;

    assert!(batch.contains(
        "ip saddr . ip daddr @z2k_warp_domain4 meta mark set mark & 0x7fffffff ^ 0x80000000"
    ));
    Ok(())
}

#[test]
fn selected_devices_and_wireguard_clients_keep_domain_pair_scope() -> io::Result<()> {
    let batch = render_mark_batch(&MarkConfig {
        family: "inet",
        table: "zapret2",
        chain: "z2k_warp_mark",
        destination_set: "z2k_warp_dst4",
        source_set: "z2k_warp_src4",
        domain_set: "z2k_warp_domain4",
        scope: "devices",
        wdtt_active: false,
        list_active: true,
        lan_ifaces: &[],
        wireguard_servers: &[],
        wireguard_clients: &["wgclient0".into()],
    })?;

    assert!(
        batch.contains(
            "ip saddr @z2k_warp_src4 ip saddr . ip daddr @z2k_warp_domain4 meta mark set"
        )
    );
    assert!(batch.contains(
        "iifname wgclient0 ip saddr 192.168.0.0/16 ip saddr . ip daddr @z2k_warp_domain4 meta mark set"
    ));
    Ok(())
}

#[test]
fn all_mode_bypasses_private_networks_and_only_marks_lan_ingress() -> io::Result<()> {
    let batch = render_mark_batch(&MarkConfig {
        family: "inet",
        table: "zapret2",
        chain: "z2k_warp_mark",
        destination_set: "z2k_warp_dst4",
        source_set: "z2k_warp_src4",
        domain_set: "z2k_warp_domain4",
        scope: "all",
        wdtt_active: true,
        list_active: false,
        lan_ifaces: &["br-lan".into(), "wlan0".into()],
        wireguard_servers: &["wgserver0".into()],
        wireguard_clients: &[],
    })?;
    assert!(batch.contains("ip daddr 192.168.0.0/16 return"));
    assert!(batch.contains("iifname wgserver0 meta mark set mark & 0x7fffffff ^ 0x80000000"));
    assert!(batch.contains("iifname br-lan meta mark set mark & 0x7fffffff ^ 0x80000000"));
    assert!(batch.contains("iifname wlan0 meta mark set mark & 0x7fffffff ^ 0x80000000"));
    assert!(!batch.contains("ip daddr @z2k_warp_dst4 meta mark set"));
    Ok(())
}

#[test]
fn invalid_interface_or_scope_is_rejected_before_rendering() {
    let mut config = MarkConfig {
        family: "inet",
        table: "zapret2",
        chain: "z2k_warp_mark",
        destination_set: "z2k_warp_dst4",
        source_set: "z2k_warp_src4",
        domain_set: "",
        scope: "lists",
        wdtt_active: false,
        list_active: false,
        lan_ifaces: &[],
        wireguard_servers: &[],
        wireguard_clients: &[],
    };
    config.scope = "all; flush ruleset";
    assert!(render_mark_batch(&config).is_err());
}

#[test]
fn mark_chain_verification_matches_nft_canonical_rules_in_order() -> io::Result<()> {
    let config = MarkConfig {
        family: "inet",
        table: "zapret2",
        chain: "z2k_warp_mark",
        destination_set: "z2k_warp_dst4",
        source_set: "z2k_warp_src4",
        domain_set: "",
        scope: "lists",
        wdtt_active: false,
        list_active: false,
        lan_ifaces: &[],
        wireguard_servers: &["wgserver0".into()],
        wireguard_clients: &[],
    };
    let batch = render_mark_batch(&config)?;
    let table = r#"table inet zapret2 {
 chain z2k_warp_mark {
  type filter hook prerouting priority mangle; policy accept;
  iifname "wgserver0" return
  ip daddr @z2k_warp_dst4 meta mark set meta mark | 0x80000000
 }
}"#;
    assert_eq!(
        mark_chain_matches(table, "inet", "zapret2", "z2k_warp_mark", &batch)?,
        Some(true)
    );
    let extra = table.replace(" }\n}", "  counter\n }\n}");
    assert_eq!(
        mark_chain_matches(&extra, "inet", "zapret2", "z2k_warp_mark", &batch)?,
        Some(false)
    );
    let foreign_hook = table.replace("hook prerouting", "hook forward");
    assert!(mark_chain_matches(&foreign_hook, "inet", "zapret2", "z2k_warp_mark", &batch).is_err());
    Ok(())
}
