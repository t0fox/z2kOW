use warp_controller::nft::{
    parse_set_inventory, render_chain_flush_batch, render_fw4_forward_apply_batch,
    render_fw4_forward_remove_batch, render_set_batch, render_set_batch_with_create,
    render_warp_remove_batch, sets_match,
};

#[test]
fn set_replacement_is_one_atomic_nft_transaction() {
    assert_eq!(
        render_set_batch(
            "inet",
            "zapret2",
            "z2k_warp_dst4",
            "z2k_warp_src4",
            &["1.2.3.0/24".into(), "8.8.8.8/32".into()],
            &["192.168.1.20".into()],
        )
        .unwrap(),
        "flush set inet zapret2 z2k_warp_dst4\nflush set inet zapret2 z2k_warp_src4\nadd element inet zapret2 z2k_warp_dst4 { 1.2.3.0/24, 8.8.8.8/32 }\nadd element inet zapret2 z2k_warp_src4 { 192.168.1.20 }\n"
    );
}

#[test]
fn empty_lists_flush_both_sets_in_the_same_batch() {
    assert_eq!(
        render_set_batch("inet", "zapret2", "dst", "src", &[], &[]).unwrap(),
        "flush set inet zapret2 dst\nflush set inet zapret2 src\n"
    );
}

#[test]
fn nft_identifiers_and_elements_are_validated_before_rendering() {
    assert!(
        render_set_batch(
            "inet; delete table inet fw4",
            "zapret2",
            "dst",
            "src",
            &[],
            &[]
        )
        .is_err()
    );
    assert!(
        render_set_batch(
            "inet",
            "zapret2",
            "dst",
            "src",
            &["1.2.3.4; delete table inet fw4".into()],
            &[]
        )
        .is_err()
    );
}

#[test]
fn readable_table_inventory_distinguishes_missing_sets_from_empty_sets() {
    let table = "table inet zapret2 {\n    set z2k_warp_dst4 {\n        type ipv4_addr\n        flags interval\n    }\n}\n";
    let inventory =
        parse_set_inventory(table, "inet", "zapret2", "z2k_warp_dst4", "z2k_warp_src4").unwrap();
    assert_eq!(inventory.destinations, Some(Vec::new()));
    assert_eq!(inventory.sources, None);
}

#[test]
fn a_schema_conflict_is_an_error_not_an_empty_set() {
    let table = "table inet zapret2 {\n    set z2k_warp_dst4 {\n        type ipv6_addr\n        flags interval\n    }\n}\n";
    assert!(
        parse_set_inventory(table, "inet", "zapret2", "z2k_warp_dst4", "z2k_warp_src4").is_err()
    );
}

#[test]
fn missing_sets_are_created_in_the_same_transaction_as_their_values() {
    let inventory =
        parse_set_inventory("table inet zapret2 {\n}\n", "inet", "zapret2", "dst", "src").unwrap();
    let batch = render_set_batch_with_create(
        "inet",
        "zapret2",
        "dst",
        "src",
        &inventory,
        &["1.2.3.4/32".into()],
        &[],
    )
    .unwrap();
    assert!(batch.starts_with(
        "add set inet zapret2 dst { type ipv4_addr; flags interval; }\nadd set inet zapret2 src"
    ));
    assert!(batch.contains("flush set inet zapret2 dst\nflush set inet zapret2 src\n"));
}

#[test]
fn unchanged_inventory_needs_no_nft_mutation() {
    let table = "table inet zapret2 {\n set dst {\n  type ipv4_addr\n  flags interval\n  elements = { 1.2.3.0/24, 8.8.8.8 }\n }\n set src {\n  type ipv4_addr\n  flags interval\n  elements = { 192.168.1.20 }\n }\n}";
    let inventory = parse_set_inventory(table, "inet", "zapret2", "dst", "src").unwrap();
    assert!(sets_match(
        &inventory,
        &["1.2.3.0/24".into(), "8.8.8.8/32".into()],
        &["192.168.1.20".into()]
    ));
}

#[test]
fn chain_cleanup_is_atomic_skips_empty_and_unrequested_chains() {
    let table = "table inet z2k_warp {\n chain mark {\n  ip daddr @dst meta mark set 0x80000000\n }\n chain tun {\n }\n chain foreign {\n  counter\n }\n}\n";
    assert_eq!(
        render_chain_flush_batch(table, "inet", "z2k_warp", &["mark", "tun"]).unwrap(),
        "flush chain inet z2k_warp mark\n"
    );
}

#[test]
fn chain_cleanup_rejects_invalid_names_and_wrong_table_output() {
    assert!(
        render_chain_flush_batch(
            "table inet z2k_warp {\n}\n",
            "inet; flush ruleset",
            "z2k_warp",
            &["mark"]
        )
        .is_err()
    );
    assert!(
        render_chain_flush_batch("table inet foreign {\n}\n", "inet", "z2k_warp", &["mark"])
            .is_err()
    );
}

#[test]
fn fw4_forward_apply_inserts_exact_rule_as_one_batch() {
    let chain = "chain forward {\n policy accept\n}\n";
    assert_eq!(
        render_fw4_forward_apply_batch(
            chain,
            "inet",
            "fw4",
            "forward",
            "z2ktun0",
            "0x80000000",
            "0x80000000",
            "!z2k: WARP forwarded traffic",
        )
        .unwrap(),
        "insert rule inet fw4 forward meta mark & 0x80000000 == 0x80000000 oifname \"z2ktun0\" accept comment \"!z2k: WARP forwarded traffic\"\n"
    );
}

#[test]
fn fw4_forward_apply_is_noop_for_exact_or_wildcard_rule() {
    let exact = "chain forward {\n meta mark & 0x80000000 == 0x80000000 oifname \"z2ktun3\" accept comment \"!z2k: WARP forwarded traffic\" # handle 21\n}\n";
    let wildcard = "chain forward {\n meta mark & 0x80000000 == 0x80000000 oifname \"z2ktun*\" accept comment \"!z2k: WARP forwarded traffic\" # handle 22\n}\n";
    for output in [exact, wildcard] {
        assert_eq!(
            render_fw4_forward_apply_batch(
                output,
                "inet",
                "fw4",
                "forward",
                "z2ktun3",
                "0x80000000",
                "0x80000000",
                "!z2k: WARP forwarded traffic",
            )
            .unwrap(),
            ""
        );
    }
}

#[test]
fn fw4_forward_apply_rejects_marker_conflict_and_invalid_input() {
    let conflict = "chain forward {\n oifname \"eth0\" accept comment \"!z2k: WARP forwarded traffic\" # handle 4\n}\n";
    assert!(
        render_fw4_forward_apply_batch(
            conflict,
            "inet",
            "fw4",
            "forward",
            "z2ktun0",
            "0x80000000",
            "0x80000000",
            "!z2k: WARP forwarded traffic",
        )
        .is_err()
    );
    assert!(
        render_fw4_forward_apply_batch(
            "chain input {\n}\n",
            "inet",
            "fw4",
            "forward",
            "z2ktun0",
            "0x80000000",
            "0x80000000",
            "!z2k: WARP forwarded traffic",
        )
        .is_err()
    );
    assert!(
        render_fw4_forward_apply_batch(
            "chain forward {\n}\n",
            "inet",
            "fw4",
            "forward",
            "z2ktun0; add rule inet fw4 forward accept",
            "0x80000000",
            "0x80000000",
            "!z2k: WARP forwarded traffic",
        )
        .is_err()
    );
}

#[test]
fn fw4_forward_remove_deletes_only_owned_runtime_tunnel_rules_atomically() {
    let chain = "chain forward {\n meta mark & 0x80000000 == 0x80000000 oifname \"z2ktun0\" accept comment \"!z2k: WARP forwarded traffic\" # handle 21\n meta mark & 0x80000000 == 0x80000000 oifname \"z2ktun12\" accept comment \"!z2k: WARP forwarded traffic\" # handle 22\n meta mark & 0x80000000 == 0x80000000 oifname \"z2ktun*\" accept comment \"!z2k: WARP forwarded traffic\" # handle 23\n oifname \"z2ktun9\" accept comment \"foreign\" # handle 24\n}\n";
    assert_eq!(
        render_fw4_forward_remove_batch(
            chain,
            "inet",
            "fw4",
            "forward",
            "!z2k: WARP forwarded traffic",
        )
        .unwrap(),
        "delete rule inet fw4 forward handle 21\ndelete rule inet fw4 forward handle 22\n"
    );
}

#[test]
fn warp_cleanup_deletes_owned_chains_and_optional_sets_in_one_batch() {
    let table = "table inet zapret2 {\n set dst {\n  type ipv4_addr\n  flags interval\n }\n set src {\n  type ipv4_addr\n  flags interval\n }\n chain mark {\n  ip daddr @dst meta mark set 0x80000000\n }\n chain mss {\n  counter\n }\n chain fwd {\n }\n chain foreign {\n  counter\n }\n}\n";
    assert_eq!(
        render_warp_remove_batch(
            table,
            "inet",
            "zapret2",
            &["mark", "mss", "fwd", "nat"],
            &["dst", "src"],
            true,
        )
        .unwrap(),
        "flush chain inet zapret2 mark\ndelete chain inet zapret2 mark\nflush chain inet zapret2 mss\ndelete chain inet zapret2 mss\ndelete chain inet zapret2 fwd\ndelete set inet zapret2 dst\ndelete set inet zapret2 src\n"
    );
}

#[test]
fn partial_warp_cleanup_preserves_sets_and_foreign_objects() {
    let table = "table inet zapret2 {\n set dst {\n  type ipv4_addr\n  flags interval\n }\n chain mark {\n }\n chain foreign {\n  counter\n }\n}\n";
    assert_eq!(
        render_warp_remove_batch(table, "inet", "zapret2", &["mark", "mss"], &["dst"], false,)
            .unwrap(),
        "delete chain inet zapret2 mark\n"
    );
    assert_eq!(
        render_warp_remove_batch(table, "inet", "zapret2", &["mss"], &["dst"], true).unwrap(),
        "delete set inet zapret2 dst\n"
    );
}

#[test]
fn warp_cleanup_rejects_wrong_table_and_invalid_object_names() {
    assert!(
        render_warp_remove_batch(
            "table inet foreign {\n}\n",
            "inet",
            "zapret2",
            &["mark"],
            &["dst"],
            true,
        )
        .is_err()
    );
    assert!(
        render_warp_remove_batch(
            "table inet zapret2 {\n}\n",
            "inet",
            "zapret2",
            &["mark; delete table inet fw4"],
            &["dst"],
            true,
        )
        .is_err()
    );
}
