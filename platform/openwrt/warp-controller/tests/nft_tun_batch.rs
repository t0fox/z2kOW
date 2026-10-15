use std::io;
use warp_controller::nft::render_tun_batch;

#[test]
fn tun_batch_replaces_all_three_owned_chains_atomically() -> io::Result<()> {
    let batch = render_tun_batch(
        "inet", "zapret2", "warp_mss", "warp_fwd", "warp_nat", "z2ktun0",
    )?;
    assert_eq!(
        batch,
        concat!(
            "add chain inet zapret2 warp_mss\n",
            "add chain inet zapret2 warp_fwd\n",
            "add chain inet zapret2 warp_nat\n",
            "flush chain inet zapret2 warp_mss\n",
            "flush chain inet zapret2 warp_fwd\n",
            "flush chain inet zapret2 warp_nat\n",
            "add rule inet zapret2 warp_mss oifname z2ktun0 tcp flags syn tcp option maxseg size set rt mtu\n",
            "add rule inet zapret2 warp_mss iifname z2ktun0 tcp flags syn tcp option maxseg size set 1240\n",
            "add rule inet zapret2 warp_fwd oifname z2ktun0 accept\n",
            "add rule inet zapret2 warp_nat oifname z2ktun0 masquerade\n",
        )
    );
    Ok(())
}

#[test]
fn tun_batch_rejects_shell_metacharacters_in_interface() {
    assert!(
        render_tun_batch(
            "inet",
            "zapret2",
            "warp_mss",
            "warp_fwd",
            "warp_nat",
            "tun0; flush ruleset"
        )
        .is_err()
    );
}
