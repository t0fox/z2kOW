use std::{
    collections::{BTreeMap, BTreeSet},
    io,
    process::Command,
};

use crate::process;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum InterfaceKind {
    Lan,
    WireGuardServers,
    WireGuardClients,
}

pub fn discover_interfaces(kind: InterfaceKind) -> io::Result<Vec<String>> {
    let network = command_output("uci", &["-d", "@", "show", "network"])?;
    match kind {
        InterfaceKind::Lan => {
            let firewall = command_output("uci", &["-d", "@", "show", "firewall"])?;
            parse_lan_interfaces_with_runtime(&firewall, &network, ubus_interface_device)
        }
        InterfaceKind::WireGuardServers => parse_wireguard_interfaces(&network, true),
        InterfaceKind::WireGuardClients => parse_wireguard_interfaces(&network, false),
    }
}

pub fn parse_interface_lists(
    kind: InterfaceKind,
    firewall: &str,
    network: &str,
) -> io::Result<Vec<String>> {
    match kind {
        InterfaceKind::Lan => parse_lan_interfaces(firewall, network),
        InterfaceKind::WireGuardServers => parse_wireguard_interfaces(network, true),
        InterfaceKind::WireGuardClients => parse_wireguard_interfaces(network, false),
    }
}

fn parse_lan_interfaces(firewall: &str, network: &str) -> io::Result<Vec<String>> {
    parse_lan_interfaces_with_runtime(firewall, network, |_| Ok(None))
}

fn parse_lan_interfaces_with_runtime(
    firewall: &str,
    network: &str,
    mut runtime_device: impl FnMut(&str) -> io::Result<Option<String>>,
) -> io::Result<Vec<String>> {
    let firewall = UciConfig::parse(firewall, "firewall")?;
    let network = UciConfig::parse(network, "network")?;
    let mut found_lan = false;
    let mut devices = BTreeSet::new();

    for (section, kind) in &firewall.sections {
        if kind != "zone" || firewall.scalar(section, "name") != Some("lan") {
            continue;
        }
        found_lan = true;
        add_interfaces(
            &mut devices,
            firewall
                .joined(section, "device")
                .as_deref()
                .unwrap_or_default(),
            true,
        );
        for network_name in firewall.tokens(section, "network") {
            let network_device =
                runtime_device(&network_name)?.or_else(|| network.joined(&network_name, "device"));
            let network_device = match network_device {
                Some(device) if !device.is_empty() => Some(device),
                _ => network.joined(&network_name, "ifname"),
            };
            if let Some(network_device) = network_device {
                add_interfaces(&mut devices, &network_device, true);
            }
        }
    }

    if !found_lan {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "в UCI не найдена firewall-зона lan",
        ));
    }
    Ok(devices.into_iter().collect())
}

fn ubus_interface_device(network: &str) -> io::Result<Option<String>> {
    let object = format!("network.interface.{network}");
    let output = process::output(Command::new("ubus").args(["call", &object, "status"]))?;
    if !output.status.success() {
        if String::from_utf8_lossy(&output.stderr).trim() == "Command failed: Not found" {
            return Ok(None);
        }
        return Err(io::Error::other(format!(
            "ubus call {object} status завершился с ошибкой: {}",
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    let status = serde_json::from_slice::<serde_json::Value>(&output.stdout).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("ubus call {object} status вернул некорректный JSON: {error}"),
        )
    })?;
    Ok(status
        .get("device")
        .and_then(serde_json::Value::as_str)
        .map(str::to_owned))
}

fn parse_wireguard_interfaces(network: &str, server: bool) -> io::Result<Vec<String>> {
    let network = UciConfig::parse(network, "network")?;
    let mut devices = BTreeSet::new();
    for section in network.sections.keys() {
        if network.scalar(section, "proto") != Some("wireguard") {
            continue;
        }
        let listen_port = network.joined(section, "listen_port").unwrap_or_default();
        if (server && !valid_listen_port(&listen_port)) || (!server && !listen_port.is_empty()) {
            continue;
        }

        let device = network
            .joined(section, "device")
            .filter(|value| !value.is_empty())
            .or_else(|| {
                network
                    .joined(section, "ifname")
                    .filter(|value| !value.is_empty())
            })
            .unwrap_or_else(|| section.clone());
        add_interfaces(&mut devices, &device, false);
    }
    Ok(devices.into_iter().collect())
}

fn valid_listen_port(value: &str) -> bool {
    value
        .parse::<u32>()
        .is_ok_and(|port| (1..=65_535).contains(&port))
}

fn add_interfaces(into: &mut BTreeSet<String>, values: &str, lan: bool) {
    for value in values.split_whitespace() {
        let valid = if lan {
            valid_lan_interface(value)
        } else {
            valid_wireguard_interface(value)
        };
        if valid {
            into.insert(value.to_owned());
        }
    }
}

fn valid_lan_interface(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 15
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b':' | b'-'))
}

fn valid_wireguard_interface(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 15
        && !value.starts_with('.')
        && value
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
}

#[derive(Default)]
struct UciConfig {
    sections: BTreeMap<String, String>,
    values: BTreeMap<(String, String), Vec<String>>,
}

impl UciConfig {
    fn parse(input: &str, package: &str) -> io::Result<Self> {
        let mut config = Self::default();
        let prefix = format!("{package}.");
        for line in input.lines() {
            let Some(line) = line.strip_prefix(&prefix) else {
                continue;
            };
            let (path, raw_value) = line.split_once('=').ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "повреждён вывод uci show")
            })?;
            let values = parse_uci_values(raw_value)?;
            if !raw_value.starts_with('\'') {
                config.sections.insert(
                    path.to_owned(),
                    values.into_iter().next().unwrap_or_default(),
                );
                continue;
            }
            let (section, option) = path.rsplit_once('.').ok_or_else(|| {
                io::Error::new(io::ErrorKind::InvalidData, "повреждён параметр uci show")
            })?;
            config
                .values
                .entry((section.to_owned(), option.to_owned()))
                .or_default()
                .extend(values);
        }
        Ok(config)
    }

    fn scalar(&self, section: &str, option: &str) -> Option<&str> {
        self.values
            .get(&(section.to_owned(), option.to_owned()))
            .and_then(|values| (values.len() == 1).then(|| values[0].as_str()))
    }

    fn joined(&self, section: &str, option: &str) -> Option<String> {
        self.values
            .get(&(section.to_owned(), option.to_owned()))
            .map(|values| values.join(" "))
    }

    fn tokens(&self, section: &str, option: &str) -> Vec<String> {
        self.joined(section, option)
            .unwrap_or_default()
            .split_whitespace()
            .map(str::to_owned)
            .collect()
    }
}

fn parse_uci_values(raw: &str) -> io::Result<Vec<String>> {
    if let Some(value) = raw
        .strip_prefix('\'')
        .and_then(|value| value.strip_suffix('\''))
    {
        return Ok(value.split("'@'").map(str::to_owned).collect());
    }
    if raw.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "пустое значение uci show",
        ));
    }
    Ok(vec![raw.to_owned()])
}

fn command_output(program: &str, args: &[&str]) -> io::Result<String> {
    let output = process::output(Command::new(program).args(args))?;
    if !output.status.success() {
        return Err(io::Error::other(format!(
            "{} завершилась с ошибкой: {}",
            program,
            String::from_utf8_lossy(&output.stderr).trim()
        )));
    }
    String::from_utf8(output.stdout)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

#[cfg(test)]
mod tests {
    use super::parse_lan_interfaces_with_runtime;

    #[test]
    fn активное_устройство_lan_предпочитается_конфигурации_uci() {
        let firewall = concat!(
            "firewall.@zone[0]=zone\n",
            "firewall.@zone[0].name='lan'\n",
            "firewall.@zone[0].network='lan'@'guest'\n",
            "firewall.@zone[0].device='br-extra'\n",
        );
        let network = concat!(
            "network.lan=interface\n",
            "network.lan.device='br-config'\n",
            "network.guest=interface\n",
            "network.guest.ifname='wlan-guest'\n",
        );

        let interfaces = parse_lan_interfaces_with_runtime(firewall, network, |name| {
            Ok((name == "lan").then(|| "br-runtime".to_owned()))
        })
        .unwrap();

        assert_eq!(
            interfaces,
            vec![
                "br-extra".to_owned(),
                "br-runtime".to_owned(),
                "wlan-guest".to_owned(),
            ]
        );
    }
}
