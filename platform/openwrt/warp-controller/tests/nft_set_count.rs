use warp_controller::nft::count_ipv4_set_elements;

#[test]
fn counts_only_ipv4_elements_from_an_nft_set_listing() {
    let output = "table inet zapret2 {\n set z2k_warp_dst4 {\n  type ipv4_addr\n  elements = { 1.1.1.1, 8.8.8.8 }\n }\n}";
    assert_eq!(count_ipv4_set_elements(output), 2);
}

#[test]
fn accepts_an_empty_or_multiline_set() {
    assert_eq!(count_ipv4_set_elements("elements = { }"), 0);
    assert_eq!(
        count_ipv4_set_elements("elements = {\n 1.1.1.1,\n 8.8.8.8\n}"),
        2
    );
}

#[test]
fn ignores_ipv4_literals_outside_the_elements_block() {
    let output = "type ipv4_addr\n comment \"example 10.0.0.1\"\n elements = { 1.1.1.1 }";
    assert_eq!(count_ipv4_set_elements(output), 1);
}
