use z2kow_tg_transparent::default_domains::deobfuscate;

#[test]
fn deobfuscate_restores_the_real_suffix_and_shift() {
    assert_eq!(deobfuscate("virkgj.com").as_deref(), Some("pclead.co.uk"));
}

#[test]
fn deobfuscate_rejects_anything_that_is_not_a_com_domain() {
    assert!(deobfuscate("example.org").is_none());
    assert!(deobfuscate("nocomhere").is_none());
    assert!(deobfuscate("").is_none());
}
