use z2kow_tg_transparent::outbound::OutboundConnector;
use z2kow_tg_transparent::runtime::Runtime;

#[test]
fn websocket_dc_remaps_only_the_non_canonical_dcs() {
    let runtime = Runtime::new(OutboundConnector::direct());

    assert_eq!(runtime.websocket_dc(203), 2);
    for dc in 1..=5 {
        assert_eq!(runtime.websocket_dc(dc), dc);
    }
    assert_eq!(runtime.websocket_dc(42), 42);
}
