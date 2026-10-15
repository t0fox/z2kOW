use serde_json::Value;
use std::{
    collections::{HashMap, HashSet},
    fs, io,
    path::Path,
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Debug, Eq, PartialEq)]
enum Selection {
    Address(String),
    Mac(String),
}

pub fn resolve_selected_devices(
    selected_file: &Path,
    leases_file: &Path,
) -> io::Result<Vec<String>> {
    let selected = match fs::read_to_string(selected_file) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error),
    };
    resolve_selected_devices_from_text(&selected, leases_file)
}

pub fn resolve_selected_devices_from_text(
    selected: &str,
    leases_file: &Path,
) -> io::Result<Vec<String>> {
    let selections = parse_selections(selected);
    let macs = selections
        .iter()
        .filter_map(|selection| match selection {
            Selection::Mac(mac) => Some(mac.clone()),
            Selection::Address(_) => None,
        })
        .collect::<HashSet<_>>();
    if macs.is_empty() {
        return Ok(resolve_selections(
            &selections,
            &HashMap::new(),
            &HashSet::new(),
            &HashMap::new(),
        ));
    }

    let neighbors = discover_neighbors(&macs)?;
    let unresolved_macs = macs
        .iter()
        .filter(|mac| !neighbors.contains_key(*mac))
        .cloned()
        .collect::<HashSet<_>>();
    let active_clients = discover_active_clients(&unresolved_macs)?;
    let leases = if active_clients.is_empty() {
        HashMap::new()
    } else {
        let now = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .map_err(io::Error::other)?
            .as_secs();
        let contents = match fs::read_to_string(leases_file) {
            Ok(contents) => Some(contents),
            Err(error) if error.kind() == io::ErrorKind::NotFound => None,
            Err(error) => return Err(error),
        };
        contents
            .as_deref()
            .map(|text| parse_leases(text, &active_clients, now))
            .unwrap_or_default()
    };
    Ok(resolve_selections(
        &selections,
        &neighbors,
        &active_clients,
        &leases,
    ))
}

fn parse_selections(contents: &str) -> Vec<Selection> {
    contents
        .lines()
        .filter_map(|line| {
            let line = line.trim_matches([' ', '\t', '\r']);
            if line.is_empty() || line.starts_with('#') {
                return None;
            }
            if let Some(mac) = canonical_mac(line) {
                Some(Selection::Mac(mac))
            } else {
                normalize_private_ipv4(line).map(Selection::Address)
            }
        })
        .collect()
}

fn discover_neighbors(selected_macs: &HashSet<String>) -> io::Result<HashMap<String, String>> {
    let output = command_output("ip", &["-4", "-j", "neigh", "show"])?;
    parse_neighbors(&output, selected_macs)
}

fn parse_neighbors(
    output: &[u8],
    selected_macs: &HashSet<String>,
) -> io::Result<HashMap<String, String>> {
    let entries: Value = serde_json::from_slice(output).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("повреждён JSON `ip neigh`: {error}"),
        )
    })?;
    let entries = entries.as_array().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "`ip neigh` вернул не массив JSON",
        )
    })?;
    let mut neighbors = HashMap::new();
    for entry in entries {
        let Some(object) = entry.as_object() else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "объект `ip neigh` имеет неверный тип",
            ));
        };
        let (Some(address), Some(link_address)) = (
            object.get("dst").and_then(Value::as_str),
            object.get("lladdr").and_then(Value::as_str),
        ) else {
            continue;
        };
        let Some(mac) = canonical_mac(link_address) else {
            continue;
        };
        if selected_macs.contains(&mac)
            && let Some(address) = normalize_private_ipv4(address)
        {
            neighbors.entry(mac).or_insert(address);
        }
    }
    Ok(neighbors)
}

fn discover_active_clients(selected_macs: &HashSet<String>) -> io::Result<HashSet<String>> {
    let output = match Command::new("ubus").arg("list").output() {
        Ok(output) => output,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(HashSet::new()),
        Err(error) => return Err(error),
    };
    if !output.status.success() {
        return Err(command_error("ubus list", &output.stderr));
    }
    let objects = String::from_utf8_lossy(&output.stdout);
    let mut active = HashSet::new();
    for object in objects.lines().filter(|line| valid_hostapd_name(line)) {
        let output = Command::new("ubus")
            .args(["call", object, "get_clients"])
            .output()?;
        if !output.status.success() {
            return Err(command_error("ubus call get_clients", &output.stderr));
        }
        active.extend(parse_hostapd_clients(&output.stdout, selected_macs)?);
    }
    Ok(active)
}

fn parse_hostapd_clients(
    output: &[u8],
    selected_macs: &HashSet<String>,
) -> io::Result<HashSet<String>> {
    let clients: Value = serde_json::from_slice(output).map_err(|error| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            format!("повреждён ответ hostapd get_clients: {error}"),
        )
    })?;
    let mut active = HashSet::new();
    let Some(clients) = clients.get("clients").and_then(Value::as_object) else {
        return Ok(active);
    };
    for (raw_mac, client) in clients {
        let Some(mac) = canonical_mac(raw_mac) else {
            continue;
        };
        if selected_macs.contains(&mac)
            && client.get("assoc").and_then(Value::as_bool) == Some(true)
            && client.get("authorized").and_then(Value::as_bool) == Some(true)
        {
            active.insert(mac);
        }
    }
    Ok(active)
}

fn parse_leases(
    contents: &str,
    active_macs: &HashSet<String>,
    now: u64,
) -> HashMap<String, String> {
    let mut selected = HashMap::<String, (u64, String)>::new();
    for line in contents.lines() {
        let fields = line.split_whitespace().collect::<Vec<_>>();
        if fields.len() < 3 {
            continue;
        }
        let Ok(expiry) = fields[0].parse::<u64>() else {
            continue;
        };
        let Some(mac) = canonical_mac(fields[1]) else {
            continue;
        };
        let Some(address) = normalize_private_ipv4(fields[2]) else {
            continue;
        };
        if !active_macs.contains(&mac) || (expiry != 0 && expiry < now) {
            continue;
        }
        let rank = if expiry == 0 { u64::MAX } else { expiry };
        if selected.get(&mac).is_none_or(|(best, _)| rank > *best) {
            selected.insert(mac, (rank, address));
        }
    }
    selected
        .into_iter()
        .map(|(mac, (_, address))| (mac, address))
        .collect()
}

fn resolve_selections(
    selections: &[Selection],
    neighbors: &HashMap<String, String>,
    active_clients: &HashSet<String>,
    leases: &HashMap<String, String>,
) -> Vec<String> {
    let mut result = Vec::new();
    let mut seen = HashSet::new();
    for selection in selections {
        let address = match selection {
            Selection::Address(address) => Some(address.as_str()),
            Selection::Mac(mac) => match neighbors.get(mac) {
                Some(address) => Some(address.as_str()),
                None if active_clients.contains(mac) => leases.get(mac).map(String::as_str),
                None => None,
            },
        };
        if let Some(address) = address
            && private_ipv4(address)
            && seen.insert(address.to_owned())
        {
            result.push(address.to_owned());
        }
    }
    result
}

fn canonical_mac(value: &str) -> Option<String> {
    let value = value.to_ascii_lowercase().replace('-', ":");
    let groups = value.split(':').collect::<Vec<_>>();
    (groups.len() == 6
        && groups
            .iter()
            .all(|group| group.len() == 2 && group.bytes().all(|byte| byte.is_ascii_hexdigit())))
    .then_some(value)
}

fn private_ipv4(value: &str) -> bool {
    normalize_private_ipv4(value).is_some()
}

fn normalize_private_ipv4(value: &str) -> Option<String> {
    let fields = value.split('.').collect::<Vec<_>>();
    if fields.len() != 4
        || fields.iter().any(|field| {
            field.is_empty() || field.len() > 3 || !field.bytes().all(|byte| byte.is_ascii_digit())
        })
    {
        return None;
    }
    let octets = fields
        .iter()
        .map(|field| field.parse::<u8>().ok())
        .collect::<Option<Vec<_>>>()?;
    let [a, b, _, _] = octets.as_slice() else {
        return None;
    };
    if !(*a == 10
        || (*a == 172 && (16..=31).contains(b))
        || (*a == 192 && *b == 168)
        || (*a == 100 && (64..=127).contains(b)))
    {
        return None;
    }
    Some(
        octets
            .iter()
            .map(u8::to_string)
            .collect::<Vec<_>>()
            .join("."),
    )
}

fn valid_hostapd_name(value: &str) -> bool {
    value.strip_prefix("hostapd.").is_some_and(|name| {
        !name.is_empty()
            && name
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
    })
}

fn command_output(program: &str, args: &[&str]) -> io::Result<Vec<u8>> {
    let output = Command::new(program).args(args).output()?;
    if output.status.success() {
        Ok(output.stdout)
    } else {
        Err(command_error(program, &output.stderr))
    }
}

fn command_error(program: &str, stderr: &[u8]) -> io::Error {
    io::Error::other(format!(
        "{} завершилась с ошибкой: {}",
        program,
        String::from_utf8_lossy(stderr).trim()
    ))
}

#[cfg(test)]
mod tests {
    use super::{
        Selection, canonical_mac, parse_hostapd_clients, parse_leases, parse_neighbors,
        parse_selections, private_ipv4, resolve_selections,
    };
    use std::collections::{HashMap, HashSet};

    #[test]
    fn parses_only_private_addresses_and_canonical_macs() {
        assert_eq!(
            parse_selections(
                "192.168.1.8\n100.64.5.6\n8.8.8.8\n172.32.1.2\nAA-BB-CC-DD-EE-FF\n#skip\n"
            ),
            [
                Selection::Address("192.168.1.8".into()),
                Selection::Address("100.64.5.6".into()),
                Selection::Mac("aa:bb:cc:dd:ee:ff".into()),
            ]
        );
        assert!(private_ipv4("192.168.001.8"));
    }

    #[test]
    fn neighbor_addresses_override_active_lease_fallback() {
        let mac = "aa:bb:cc:dd:ee:ff".to_owned();
        let selections = parse_selections("192.168.1.8\nAA-BB-CC-DD-EE-FF\n");
        let neighbors = HashMap::from([(mac.clone(), "10.0.0.4".to_owned())]);
        let active = HashSet::from([mac.clone()]);
        let leases = HashMap::from([(mac, "192.168.1.7".to_owned())]);
        assert_eq!(
            resolve_selections(&selections, &neighbors, &active, &leases),
            ["192.168.1.8", "10.0.0.4"]
        );
    }

    #[test]
    fn leases_require_live_association_and_choose_latest_valid_expiry() {
        let mac = "aa:bb:cc:dd:ee:ff".to_owned();
        let active = HashSet::from([mac.clone()]);
        let leases = parse_leases(
            "900 aa:bb:cc:dd:ee:ff 192.168.1.4 host\n\
             1500 AA-BB-CC-DD-EE-FF 192.168.1.5 host\n\
             1200 00:00:00:00:00:01 192.168.1.9 other\n\
             800 aa:bb:cc:dd:ee:ff 192.168.1.6 old\n",
            &active,
            1000,
        );
        assert_eq!(leases.get(&mac).map(String::as_str), Some("192.168.1.5"));
    }

    #[test]
    fn malformed_mac_is_rejected() {
        assert_eq!(
            canonical_mac("aa:bb:cc:dd:ee:ff"),
            Some("aa:bb:cc:dd:ee:ff".into())
        );
        assert_eq!(canonical_mac("aa:bb:cc:dd:ee"), None);
    }

    #[test]
    fn parses_iproute2_neighbor_json_for_selected_macs() {
        let selected = HashSet::from(["aa:bb:cc:dd:ee:ff".to_owned()]);
        let neighbors = parse_neighbors(
            br#"[{"dst":"192.168.1.9","dev":"br-lan","lladdr":"AA:BB:CC:DD:EE:FF","state":["STALE"]},{"dst":"10.0.0.2","lladdr":"00:11:22:33:44:55"}]"#,
            &selected,
        )
        .unwrap();
        assert_eq!(
            neighbors.get("aa:bb:cc:dd:ee:ff").map(String::as_str),
            Some("192.168.1.9")
        );
        assert_eq!(neighbors.len(), 1);
    }

    #[test]
    fn public_neighbor_does_not_hide_valid_dhcp_fallback() {
        let mac = "aa:bb:cc:dd:ee:ff".to_owned();
        let selected = HashSet::from([mac.clone()]);
        let neighbors = parse_neighbors(
            br#"[{"dst":"8.8.8.8","lladdr":"aa:bb:cc:dd:ee:ff"}]"#,
            &selected,
        )
        .unwrap();
        let leases = HashMap::from([(mac.clone(), "192.168.1.8".to_owned())]);
        assert_eq!(
            resolve_selections(
                &[Selection::Mac(mac)],
                &neighbors,
                &HashSet::from(["aa:bb:cc:dd:ee:ff".to_owned()]),
                &leases,
            ),
            ["192.168.1.8"]
        );
    }

    #[test]
    fn only_associated_and_authorized_hostapd_clients_are_active() {
        let selected = HashSet::from([
            "aa:bb:cc:dd:ee:ff".to_owned(),
            "00:11:22:33:44:55".to_owned(),
        ]);
        let active = parse_hostapd_clients(
            br#"{"clients":{"AA:BB:CC:DD:EE:FF":{"assoc":true,"authorized":true},"00:11:22:33:44:55":{"assoc":true,"authorized":false}}}"#,
            &selected,
        )
        .unwrap();
        assert_eq!(active, HashSet::from(["aa:bb:cc:dd:ee:ff".to_owned()]));
    }
}
