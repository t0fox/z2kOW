use std::{fs, process::Command};

#[test]
fn device_ips_filters_direct_addresses_without_mac_lookup() {
    let temp = std::env::temp_dir().join(format!(
        "z2k-warp-device-ips-{}-{}",
        std::process::id(),
        std::thread::current().name().unwrap_or("test")
    ));
    fs::create_dir_all(&temp).unwrap();
    let selected = temp.join("devices.txt");
    let leases = temp.join("dhcp.leases");
    fs::write(
        &selected,
        "192.168.1.8\n100.64.5.6\n8.8.8.8\n172.32.1.2\n# comment\n192.168.1.8\n",
    )
    .unwrap();
    fs::write(&leases, "").unwrap();

    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .args([
            "device-ips",
            selected.to_str().unwrap(),
            leases.to_str().unwrap(),
        ])
        .output()
        .unwrap();
    let _ = fs::remove_dir_all(&temp);

    assert!(
        output.status.success(),
        "controller failed: {}",
        String::from_utf8_lossy(&output.stderr)
    );
    assert_eq!(
        String::from_utf8(output.stdout).unwrap(),
        "192.168.1.8\n100.64.5.6\n"
    );
}
