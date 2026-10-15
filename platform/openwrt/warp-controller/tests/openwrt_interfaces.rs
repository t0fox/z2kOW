use warp_controller::openwrt::{InterfaceKind, parse_interface_lists};

const FIREWALL: &str = "firewall.lan=zone\n\
firewall.lan.name='lan'\n\
firewall.lan.device='br-lan'@'br-guest'\n\
firewall.lan.network='lan'@'iot'\n\
firewall.wan=zone\n\
firewall.wan.name='wan'\n\
firewall.wan.device='eth0'\n";

const NETWORK: &str = "network.lan=interface\n\
network.lan.device='br-lan'\n\
network.iot=interface\n\
network.iot.ifname='wlan0'\n\
network.wgserver=interface\n\
network.wgserver.proto='wireguard'\n\
network.wgserver.listen_port='51820'\n\
network.wgserver.device='wgserver0'\n\
network.wgclient=interface\n\
network.wgclient.proto='wireguard'\n\
network.wgclient.device='wgclient0'\n\
network.wgclient.ifname='ignored0'\n\
network.wgfallback=interface\n\
network.wgfallback.proto='wireguard'\n\
network.wginvalid=interface\n\
network.wginvalid.proto='wireguard'\n\
network.wginvalid.listen_port='invalid'\n\
network.wginvalid.device='wginvalid0'\n\
network.wgbadname=interface\n\
network.wgbadname.proto='wireguard'\n\
network.wgbadname.listen_port='51821'\n\
network.wgbadname.device='bad;name'\n";

#[test]
fn discovers_only_valid_lan_and_wireguard_interfaces() {
    assert_eq!(
        parse_interface_lists(InterfaceKind::Lan, FIREWALL, NETWORK).unwrap(),
        ["br-guest", "br-lan", "wlan0"]
    );
    assert_eq!(
        parse_interface_lists(InterfaceKind::WireGuardServers, FIREWALL, NETWORK).unwrap(),
        ["wgserver0"]
    );
    assert_eq!(
        parse_interface_lists(InterfaceKind::WireGuardClients, FIREWALL, NETWORK).unwrap(),
        ["wgclient0", "wgfallback"]
    );
}

#[test]
fn missing_lan_zone_is_an_error() {
    assert!(parse_interface_lists(InterfaceKind::Lan, "", NETWORK).is_err());
}
