use std::io;
use warp_controller::nft::{
    domain_observer_chain_has_group, domain_pair_set_matches,
    render_domain_observer_table_create_batch, render_domain_pair_set_create_batch,
};

const OWNED_TABLE: &str = r#"table inet zapret2 {
	set z2k_domain {
		type ipv4_addr . ipv4_addr
		flags timeout
		timeout 1h
		size 8192
		comment "z2k WARP DNS pairs"
	}
}"#;

#[test]
fn recognizes_only_the_exact_warp_owned_pair_set() -> io::Result<()> {
    assert_eq!(
        domain_pair_set_matches(OWNED_TABLE, "inet", "zapret2", "z2k_domain")?,
        Some(true)
    );
    let foreign = OWNED_TABLE.replace("z2k WARP DNS pairs", "foreign");
    assert!(domain_pair_set_matches(&foreign, "inet", "zapret2", "z2k_domain").is_err());
    let absent = OWNED_TABLE.replace("set z2k_domain", "set other");
    assert_eq!(
        domain_pair_set_matches(&absent, "inet", "zapret2", "z2k_domain")?,
        None
    );
    Ok(())
}

#[test]
fn create_batch_uses_the_compatible_pair_timeout_contract() -> io::Result<()> {
    assert_eq!(
        render_domain_pair_set_create_batch("inet", "zapret2", "z2k_domain")?,
        "add set inet zapret2 z2k_domain { type ipv4_addr . ipv4_addr; flags timeout; timeout 1h; size 8192; comment \"z2k WARP DNS pairs\"; }\n"
    );
    Ok(())
}

#[test]
fn observer_table_creation_is_one_atomic_owned_operation() -> io::Result<()> {
    assert_eq!(
        render_domain_observer_table_create_batch("inet", "z2k_warp_dns")?,
        "add table inet z2k_warp_dns { comment \"z2k WARP passive DNS observer\"; }\n"
    );
    Ok(())
}

#[test]
fn observer_group_check_requires_the_exact_nflog_group() {
    let chain = r#"table inet z2k_warp_dns {
 chain z2k_dns_output {
  type filter hook output priority mangle; policy accept;
  oifname "br-lan" ip protocol { tcp, udp } th sport 53 counter packets 0 bytes 0 log group 189 snaplen 4096 queue-threshold 1
 }
}"#;
    assert!(domain_observer_chain_has_group(
        chain,
        "z2k_dns_output",
        "189"
    ));
    assert!(!domain_observer_chain_has_group(
        chain,
        "z2k_dns_output",
        "18"
    ));
    assert!(!domain_observer_chain_has_group(
        chain,
        "z2k_dns_forward",
        "189"
    ));
    assert!(!domain_observer_chain_has_group(
        chain,
        "z2k_dns_output",
        "189x"
    ));
}
