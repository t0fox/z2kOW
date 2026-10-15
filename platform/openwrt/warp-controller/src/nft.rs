use std::{
    io::{self, Write},
    process::{Command, Stdio},
};

#[derive(Debug, Eq, PartialEq)]
pub struct SetInventory {
    pub destinations: Option<Vec<String>>,
    pub sources: Option<Vec<String>>,
}

pub struct MarkConfig<'a> {
    pub family: &'a str,
    pub table: &'a str,
    pub chain: &'a str,
    pub destination_set: &'a str,
    pub source_set: &'a str,
    pub domain_set: &'a str,
    pub scope: &'a str,
    pub wdtt_active: bool,
    pub list_active: bool,
    pub lan_ifaces: &'a [String],
    pub wireguard_servers: &'a [String],
    pub wireguard_clients: &'a [String],
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct MarkPolicyFlags {
    pub wdtt_active: bool,
    pub list_active: bool,
}

pub struct DomainObserverConfig<'a> {
    pub family: &'a str,
    pub table: &'a str,
    pub output_chain: &'a str,
    pub forward_chain: &'a str,
    pub group: &'a str,
    pub devices: &'a [String],
    pub table_exists: bool,
    pub output_exists: bool,
    pub forward_exists: bool,
}

pub struct DomainRemoveConfig<'a> {
    pub family: &'a str,
    pub observer_table: &'a str,
    pub pair_family: &'a str,
    pub pair_table: &'a str,
    pub pair_set: &'a str,
    pub observer_exists: bool,
    pub pair_set_exists: bool,
    pub full: bool,
}

const DOMAIN_PAIR_SET_COMMENT: &str = "z2k WARP DNS pairs";

pub fn domain_pair_set_matches(
    table_output: &str,
    family: &str,
    table: &str,
    set: &str,
) -> io::Result<Option<bool>> {
    for identifier in [family, table, set] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft-объекта содержит недопустимые символы",
            ));
        }
    }
    let header = format!("table {family} {table} {{");
    if !table_output.lines().any(|line| line.trim() == header) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "ответ nft не содержит ожидаемую таблицу",
        ));
    }
    let Some(block) = extract_nft_block(table_output, "set", set) else {
        return Ok(None);
    };
    let normalized = block.split_whitespace().collect::<Vec<_>>().join(" ");
    let owned = normalized.contains("type ipv4_addr . ipv4_addr")
        && normalized.contains("timeout 1h")
        && normalized.contains("size 8192")
        && normalized.contains(&format!("comment \"{DOMAIN_PAIR_SET_COMMENT}\""));
    if owned {
        Ok(Some(true))
    } else {
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "набор доменных пар nft занят или несовместим",
        ))
    }
}

pub fn render_domain_pair_set_create_batch(
    family: &str,
    table: &str,
    set: &str,
) -> io::Result<String> {
    for identifier in [family, table, set] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft-объекта содержит недопустимые символы",
            ));
        }
    }
    Ok(format!(
        "add set {family} {table} {set} {{ type ipv4_addr . ipv4_addr; flags timeout; timeout 1h; size 8192; comment \"{DOMAIN_PAIR_SET_COMMENT}\"; }}\n"
    ))
}

pub fn render_domain_observer_table_create_batch(family: &str, table: &str) -> io::Result<String> {
    for identifier in [family, table] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft observer-таблицы содержит недопустимые символы",
            ));
        }
    }
    Ok(format!(
        "add table {family} {table} {{ comment \"z2k WARP passive DNS observer\"; }}\n"
    ))
}

pub fn domain_observer_table_owned(
    table_output: &str,
    family: &str,
    table: &str,
) -> io::Result<bool> {
    for identifier in [family, table] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft-таблицы содержит недопустимые символы",
            ));
        }
    }
    let header = format!("table {family} {table} {{");
    if !table_output.lines().any(|line| line.trim() == header) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "ответ nft не содержит ожидаемую таблицу observer",
        ));
    }
    let mut table_comment = false;
    for line in table_output.lines().skip(1) {
        let line = line.trim();
        if line.starts_with("chain ") || line.starts_with("set ") {
            break;
        }
        if line == "comment \"z2k WARP passive DNS observer\"" {
            table_comment = true;
            break;
        }
    }
    Ok(table_comment)
}

pub fn domain_observer_chain_owned(
    table_output: &str,
    name: &str,
    hook: &str,
) -> io::Result<Option<bool>> {
    if !valid_identifier(name) || !matches!(hook, "output" | "forward") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "недопустимый nft observer chain или hook",
        ));
    }
    let Some(block) = extract_nft_block(table_output, "chain", name) else {
        return Ok(None);
    };
    let comment = format!("comment \"z2k WARP passive DNS observer chain {name}\"");
    let has_comment = block.lines().any(|line| line.trim() == comment);
    let owned = has_comment
        && block.contains(&format!("type filter hook {hook}"))
        && block.contains("policy accept");
    if owned {
        Ok(Some(true))
    } else {
        Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            format!("nft observer chain {name} занят или несовместим"),
        ))
    }
}

pub fn domain_observer_chain_rules_match(
    chain_output: &str,
    name: &str,
    devices: &[String],
    group: &str,
) -> bool {
    let Some(block) = extract_nft_block(chain_output, "chain", name) else {
        return false;
    };
    let group = match group.parse::<u16>() {
        Ok(group) => group,
        _ => return false,
    };
    let mut expected = unique_interfaces(devices)
        .map(|device| {
            format!(
                "oifname \"{device}\" ip protocol {{ tcp, udp }} th sport 53 counter log group {group} snaplen 4096 queue-threshold 1"
            )
        })
        .collect::<Vec<_>>();
    if expected.is_empty() {
        return false;
    }
    let mut actual = Vec::new();
    for line in block.lines() {
        let line = line.trim();
        if line.is_empty()
            || line.starts_with("chain ")
            || line.starts_with("type ")
            || line.starts_with("policy ")
            || line.starts_with("comment ")
            || line == "}"
        {
            continue;
        }
        actual.push(normalize_observer_rule(line));
    }
    expected.sort();
    actual.sort();
    actual == expected
}

pub fn domain_observer_chain_has_group(chain_output: &str, name: &str, group: &str) -> bool {
    let Some(block) = extract_nft_block(chain_output, "chain", name) else {
        return false;
    };
    if group.parse::<u16>().is_err()
        || group.is_empty()
        || !group.bytes().all(|byte| byte.is_ascii_digit())
    {
        return false;
    }
    block.lines().any(|line| {
        line.split_whitespace()
            .collect::<Vec<_>>()
            .windows(3)
            .any(|tokens| tokens == ["log", "group", group])
    })
}

pub fn render_domain_observer_batch(config: &DomainObserverConfig<'_>) -> io::Result<String> {
    let DomainObserverConfig {
        family,
        table,
        output_chain,
        forward_chain,
        group,
        devices,
        table_exists,
        output_exists,
        forward_exists,
    } = config;
    for identifier in [*family, *table, *output_chain, *forward_chain] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft observer-объекта содержит недопустимые символы",
            ));
        }
    }
    if group.parse::<u16>().is_err()
        || group.is_empty()
        || !group.bytes().all(|b| b.is_ascii_digit())
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "номер NFLOG group должен быть числом от 0 до 65535",
        ));
    }
    if devices.is_empty() || devices.iter().any(|device| !valid_interface(device)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "не найдены допустимые LAN-устройства для nft observer",
        ));
    }
    let group = group.parse::<u16>().expect("NFLOG group validated above");
    let mut batch = String::new();
    if !table_exists {
        batch.push_str(&format!(
            "add table {family} {table} {{ comment \"z2k WARP passive DNS observer\"; }}\n"
        ));
    }
    if !output_exists {
        batch.push_str(&format!(
            "add chain {family} {table} {output_chain} {{ type filter hook output priority -150; policy accept; comment \"z2k WARP passive DNS observer chain {output_chain}\"; }}\n"
        ));
    }
    if !forward_exists {
        batch.push_str(&format!(
            "add chain {family} {table} {forward_chain} {{ type filter hook forward priority -150; policy accept; comment \"z2k WARP passive DNS observer chain {forward_chain}\"; }}\n"
        ));
    }
    batch.push_str(&format!(
        "flush chain {family} {table} {output_chain}\nflush chain {family} {table} {forward_chain}\n"
    ));
    for device in unique_interfaces(devices) {
        for chain in [output_chain, forward_chain] {
            batch.push_str(&format!(
                "add rule {family} {table} {chain} oifname \"{device}\" ip protocol {{ tcp, udp }} th sport 53 counter log group {group} snaplen 4096 queue-threshold 1\n"
            ));
        }
    }
    Ok(batch)
}

pub fn render_domain_remove_batch(config: &DomainRemoveConfig<'_>) -> io::Result<String> {
    let DomainRemoveConfig {
        family,
        observer_table,
        pair_family,
        pair_table,
        pair_set,
        observer_exists,
        pair_set_exists,
        full,
    } = config;
    for identifier in [
        *family,
        *observer_table,
        *pair_family,
        *pair_table,
        *pair_set,
    ] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft observer-объекта содержит недопустимые символы",
            ));
        }
    }
    let mut batch = String::new();
    if *observer_exists {
        batch.push_str(&format!("delete table {family} {observer_table}\n"));
    }
    if *pair_set_exists {
        let operation = if *full { "delete" } else { "flush" };
        batch.push_str(&format!(
            "{operation} set {pair_family} {pair_table} {pair_set}\n"
        ));
    }
    Ok(batch)
}

fn normalize_observer_rule(line: &str) -> String {
    let fields = line.split_whitespace().collect::<Vec<_>>();
    let mut normalized = Vec::with_capacity(fields.len());
    let mut index = 0;
    while index < fields.len() {
        if fields[index] == "counter"
            && fields.get(index + 1) == Some(&"packets")
            && fields.get(index + 3) == Some(&"bytes")
            && fields
                .get(index + 2)
                .is_some_and(|value| value.bytes().all(|b| b.is_ascii_digit()))
            && fields
                .get(index + 4)
                .is_some_and(|value| value.bytes().all(|b| b.is_ascii_digit()))
        {
            normalized.push("counter");
            index += 5;
        } else {
            normalized.push(fields[index]);
            index += 1;
        }
    }
    normalized.join(" ")
}

fn extract_nft_block(table_output: &str, kind: &str, name: &str) -> Option<String> {
    let start = format!("{kind} {name} {{");
    let mut block = String::new();
    let mut depth = 0_i32;
    let mut found = false;
    for line in table_output.lines() {
        if !found {
            if line.trim() != start {
                continue;
            }
            found = true;
        }
        block.push_str(line);
        block.push('\n');
        for byte in line.bytes() {
            match byte {
                b'{' => depth += 1,
                b'}' => depth -= 1,
                _ => {}
            }
        }
        if depth == 0 {
            return Some(block);
        }
    }
    None
}

pub fn plan_mark_flags(
    scope: &str,
    wdtt_enabled: bool,
    has_domains: bool,
    destination_set_nonempty: bool,
) -> io::Result<MarkPolicyFlags> {
    if !matches!(scope, "all" | "full" | "devices" | "lists") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "неизвестный режим WARP policy",
        ));
    }
    let list_active = scope != "full" && (has_domains || destination_set_nonempty);
    let wdtt_active = scope != "full" && wdtt_enabled && (scope == "all" || list_active);
    Ok(MarkPolicyFlags {
        wdtt_active,
        list_active,
    })
}

pub fn render_mark_batch(config: &MarkConfig<'_>) -> io::Result<String> {
    for identifier in [
        config.family,
        config.table,
        config.chain,
        config.destination_set,
        config.source_set,
    ] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft-объекта содержит недопустимые символы",
            ));
        }
    }
    if !config.domain_set.is_empty() && !valid_identifier(config.domain_set) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "имя доменного набора nft содержит недопустимые символы",
        ));
    }
    if !matches!(config.scope, "all" | "full" | "devices" | "lists") {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "неизвестный режим WARP policy",
        ));
    }
    if config
        .lan_ifaces
        .iter()
        .chain(config.wireguard_servers)
        .chain(config.wireguard_clients)
        .any(|interface| !valid_interface(interface))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "недопустимое имя сетевого интерфейса",
        ));
    }
    if config.scope == "all" && config.lan_ifaces.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "для режима all требуется хотя бы один LAN-интерфейс",
        ));
    }

    let mut batch = format!(
        "add chain {} {} {} {{ type filter hook prerouting priority -150; }}\nflush chain {} {} {}\n",
        config.family, config.table, config.chain, config.family, config.table, config.chain
    );
    if config.scope == "all" {
        for subnet in PRIVATE_AND_NON_UNICAST {
            append_mark_rule(&mut batch, config, &format!("ip daddr {subnet} return"));
        }
    }
    for interface in unique_interfaces(config.wireguard_servers) {
        if config.wdtt_active {
            append_mark_rule(
                &mut batch,
                config,
                &format!("iifname {interface} {MARK_EXPRESSION}"),
            );
        }
        append_mark_rule(&mut batch, config, &format!("iifname {interface} return"));
    }
    if config.scope == "devices" && config.list_active {
        for interface in unique_interfaces(config.wireguard_clients) {
            for subnet in PRIVATE_UNICAST {
                append_mark_rule(
                    &mut batch,
                    config,
                    &format!(
                        "iifname {interface} ip saddr {subnet} ip daddr @{} {MARK_EXPRESSION}",
                        config.destination_set
                    ),
                );
            }
        }
    }
    if config.scope == "all" {
        for interface in unique_interfaces(config.lan_ifaces) {
            append_mark_rule(
                &mut batch,
                config,
                &format!("iifname {interface} {MARK_EXPRESSION}"),
            );
        }
        return Ok(batch);
    }
    match config.scope {
        "full" => append_mark_rule(
            &mut batch,
            config,
            &format!(
                "ip saddr @{} {} {MARK_EXPRESSION}",
                config.source_set,
                PRIVATE_AND_NON_UNICAST
                    .iter()
                    .map(|subnet| format!("ip daddr != {subnet}"))
                    .collect::<Vec<_>>()
                    .join(" ")
            ),
        ),
        "devices" => append_mark_rule(
            &mut batch,
            config,
            &format!(
                "ip saddr @{} ip daddr @{} {MARK_EXPRESSION}",
                config.source_set, config.destination_set
            ),
        ),
        "lists" => append_mark_rule(
            &mut batch,
            config,
            &format!("ip daddr @{} {MARK_EXPRESSION}", config.destination_set),
        ),
        "all" => unreachable!(),
        _ => unreachable!(),
    }
    if !config.domain_set.is_empty() && config.scope != "all" {
        let source = if matches!(config.scope, "devices" | "full") {
            format!("ip saddr @{} ", config.source_set)
        } else {
            String::new()
        };
        append_mark_rule(
            &mut batch,
            config,
            &format!(
                "{source}ip saddr . ip daddr @{} {MARK_EXPRESSION}",
                config.domain_set
            ),
        );
        if config.scope == "devices" && config.list_active {
            for interface in unique_interfaces(config.wireguard_clients) {
                for subnet in PRIVATE_UNICAST {
                    append_mark_rule(
                        &mut batch,
                        config,
                        &format!(
                            "iifname {interface} ip saddr {subnet} ip saddr . ip daddr @{} {MARK_EXPRESSION}",
                            config.domain_set
                        ),
                    );
                }
            }
        }
    }
    Ok(batch)
}

pub fn mark_chain_matches(
    table_output: &str,
    family: &str,
    table: &str,
    chain: &str,
    batch: &str,
) -> io::Result<Option<bool>> {
    for identifier in [family, table, chain] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя MARK-цепочки nft содержит недопустимые символы",
            ));
        }
    }
    let table_header = format!("table {family} {table} {{");
    if !table_output.lines().any(|line| line.trim() == table_header) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "ответ nft не содержит ожидаемую MARK-таблицу",
        ));
    }
    let Some(block) = extract_nft_block(table_output, "chain", chain) else {
        return Ok(None);
    };
    let owned_hook = block.lines().any(|line| {
        let line = line.trim();
        line.starts_with("type filter hook prerouting priority mangle")
            || line.starts_with("type filter hook prerouting priority -150")
    });
    if !owned_hook {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "MARK-цепочка nft принадлежит другому hook или priority",
        ));
    }

    let expected = batch
        .lines()
        .filter_map(|line| {
            let mut fields = line.split_whitespace();
            if fields.next() != Some("add")
                || fields.next() != Some("rule")
                || fields.next() != Some(family)
                || fields.next() != Some(table)
                || fields.next() != Some(chain)
            {
                return None;
            }
            Some(normalize_mark_rule(&fields.collect::<Vec<_>>().join(" ")))
        })
        .collect::<Vec<_>>();
    if expected.is_empty() {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "MARK batch не содержит правил для проверки",
        ));
    }

    let actual = block
        .lines()
        .map(str::trim)
        .filter(|line| {
            !line.is_empty()
                && !line.starts_with("chain ")
                && !line.starts_with("type ")
                && !line.starts_with("policy ")
                && !line.starts_with("comment ")
                && *line != "}"
        })
        .map(normalize_mark_rule)
        .collect::<Vec<_>>();
    Ok(Some(actual == expected))
}

fn normalize_mark_rule(line: &str) -> String {
    let fields = normalize_observer_rule(line);
    let tokens = fields.split_whitespace().collect::<Vec<_>>();
    let mut normalized = Vec::with_capacity(tokens.len());
    let mut interface_name = false;
    for token in tokens {
        if interface_name {
            normalized.push(token.trim_matches('"'));
        } else {
            normalized.push(token);
        }
        interface_name = matches!(token, "iifname" | "oifname");
    }
    normalized
        .join(" ")
        .replace(
            "set mark & 0x7fffffff ^ 0x80000000",
            "set meta mark | 0x80000000",
        )
        .replace("set mark | 0x80000000", "set meta mark | 0x80000000")
}

const MARK_EXPRESSION: &str = "meta mark set mark & 0x7fffffff ^ 0x80000000";
const PRIVATE_AND_NON_UNICAST: &[&str] = &[
    "0.0.0.0/8",
    "10.0.0.0/8",
    "100.64.0.0/10",
    "127.0.0.0/8",
    "169.254.0.0/16",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "224.0.0.0/3",
];
const PRIVATE_UNICAST: &[&str] = &[
    "10.0.0.0/8",
    "172.16.0.0/12",
    "192.168.0.0/16",
    "100.64.0.0/10",
];

fn append_mark_rule(batch: &mut String, config: &MarkConfig<'_>, expression: &str) {
    batch.push_str(&format!(
        "add rule {} {} {} {expression}\n",
        config.family, config.table, config.chain
    ));
}

fn unique_interfaces(interfaces: &[String]) -> impl Iterator<Item = &str> {
    let mut unique = std::collections::BTreeSet::new();
    interfaces
        .iter()
        .map(String::as_str)
        .filter(move |interface| unique.insert(*interface))
}

fn valid_interface(interface: &str) -> bool {
    !interface.is_empty()
        && interface.len() <= 15
        && interface
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'_' | b'.' | b'-'))
}

pub fn parse_set_inventory(
    table_output: &str,
    family: &str,
    table: &str,
    destination_set: &str,
    source_set: &str,
) -> io::Result<SetInventory> {
    let header = format!("table {family} {table} {{");
    if !table_output.lines().any(|line| line.trim() == header) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "ответ nft не содержит ожидаемую таблицу",
        ));
    }
    Ok(SetInventory {
        destinations: parse_one_set(table_output, destination_set)?,
        sources: parse_one_set(table_output, source_set)?,
    })
}

pub fn sets_match(inventory: &SetInventory, destinations: &[String], sources: &[String]) -> bool {
    set_matches(&inventory.destinations, destinations) && set_matches(&inventory.sources, sources)
}

pub fn render_set_batch(
    family: &str,
    table: &str,
    destination_set: &str,
    source_set: &str,
    destinations: &[String],
    sources: &[String],
) -> io::Result<String> {
    for identifier in [family, table, destination_set, source_set] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft-объекта содержит недопустимые символы",
            ));
        }
    }
    if destinations
        .iter()
        .any(|entry| !valid_ipv4_entry(entry, true))
        || sources.iter().any(|entry| !valid_ipv4_entry(entry, false))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "nft-набор содержит недопустимый IPv4-элемент",
        ));
    }

    let mut batch = format!(
        "flush set {family} {table} {destination_set}\nflush set {family} {table} {source_set}\n"
    );
    append_elements(&mut batch, family, table, destination_set, destinations);
    append_elements(&mut batch, family, table, source_set, sources);
    Ok(batch)
}

pub fn render_tun_batch(
    family: &str,
    table: &str,
    mss_chain: &str,
    forward_chain: &str,
    nat_chain: &str,
    interface: &str,
) -> io::Result<String> {
    for identifier in [family, table, mss_chain, forward_chain, nat_chain] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft-объекта содержит недопустимые символы",
            ));
        }
    }
    if !valid_interface(interface) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "недопустимое имя TUN-интерфейса",
        ));
    }

    Ok(format!(
        "add chain {family} {table} {mss_chain}\n\
         add chain {family} {table} {forward_chain}\n\
         add chain {family} {table} {nat_chain}\n\
         flush chain {family} {table} {mss_chain}\n\
         flush chain {family} {table} {forward_chain}\n\
         flush chain {family} {table} {nat_chain}\n\
         add rule {family} {table} {mss_chain} oifname {interface} tcp flags syn tcp option maxseg size set rt mtu\n\
         add rule {family} {table} {mss_chain} iifname {interface} tcp flags syn tcp option maxseg size set 1240\n\
         add rule {family} {table} {forward_chain} oifname {interface} accept\n\
         add rule {family} {table} {nat_chain} oifname {interface} masquerade\n"
    ))
}

pub fn render_chain_flush_batch(
    table_output: &str,
    family: &str,
    table: &str,
    chains: &[&str],
) -> io::Result<String> {
    for identifier in [family, table].into_iter().chain(chains.iter().copied()) {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft-объекта содержит недопустимые символы",
            ));
        }
    }
    let header = format!("table {family} {table} {{");
    if !table_output.lines().any(|line| line.trim() == header) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "ответ nft не содержит ожидаемую таблицу",
        ));
    }

    let mut batch = String::new();
    for chain in chains {
        let Some(block) = extract_nft_block(table_output, "chain", chain) else {
            continue;
        };
        let has_rules = block
            .lines()
            .skip(1)
            .any(|line| !line.trim().is_empty() && line.trim() != "}");
        if has_rules {
            batch.push_str(&format!("flush chain {family} {table} {chain}\n"));
        }
    }
    Ok(batch)
}

pub fn render_warp_remove_batch(
    table_output: &str,
    family: &str,
    table: &str,
    chains: &[&str],
    sets: &[&str],
    full: bool,
) -> io::Result<String> {
    for identifier in [family, table]
        .into_iter()
        .chain(chains.iter().copied())
        .chain(if full {
            sets.iter().copied()
        } else {
            [].iter().copied()
        })
    {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft-объекта содержит недопустимые символы",
            ));
        }
    }
    let header = format!("table {family} {table} {{");
    if !table_output.lines().any(|line| line.trim() == header) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "ответ nft не содержит ожидаемую таблицу WARP",
        ));
    }

    let mut batch = String::new();
    let mut seen_chains = std::collections::BTreeSet::new();
    for chain in chains {
        if !seen_chains.insert(*chain) {
            continue;
        }
        let Some(block) = extract_nft_block(table_output, "chain", chain) else {
            continue;
        };
        let has_rules = block
            .lines()
            .skip(1)
            .any(|line| !line.trim().is_empty() && line.trim() != "}");
        if has_rules {
            batch.push_str(&format!("flush chain {family} {table} {chain}\n"));
        }
        batch.push_str(&format!("delete chain {family} {table} {chain}\n"));
    }

    if full {
        let mut seen_sets = std::collections::BTreeSet::new();
        for set in sets {
            if seen_sets.insert(*set) && extract_nft_block(table_output, "set", set).is_some() {
                batch.push_str(&format!("delete set {family} {table} {set}\n"));
            }
        }
    }
    Ok(batch)
}

#[allow(clippy::too_many_arguments)]
pub fn render_fw4_forward_apply_batch(
    chain_output: &str,
    family: &str,
    table: &str,
    chain: &str,
    interface: &str,
    mark: &str,
    mask: &str,
    comment: &str,
) -> io::Result<String> {
    validate_fw4_arguments(family, table, chain, interface, comment)?;
    for value in [mark, mask] {
        if !valid_mark(value) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "метка nft содержит недопустимое значение",
            ));
        }
    }
    let rules = fw4_chain_rules(chain_output, chain)?;
    let escaped_comment = nft_quote(comment)?;
    let exact = format!(
        "meta mark & {mask} == {mark} oifname \"{interface}\" accept comment {escaped_comment}"
    );
    let wildcard = format!(
        "meta mark & {mask} == {mark} oifname \"z2ktun*\" accept comment {escaped_comment}"
    );
    if rules
        .iter()
        .any(|rule| rule.contains(&exact) || rule.contains(&wildcard))
    {
        return Ok(String::new());
    }
    let marker = format!("comment {escaped_comment}");
    if rules.iter().any(|rule| rule.contains(&marker)) {
        return Err(io::Error::new(
            io::ErrorKind::AlreadyExists,
            "правило fw4 WARP занято другим выражением",
        ));
    }
    Ok(format!("insert rule {family} {table} {chain} {exact}\n"))
}

pub fn fw4_forward_matches(
    chain_output: &str,
    chain: &str,
    interface: &str,
    mask: &str,
    mark: &str,
    comment: &str,
) -> io::Result<bool> {
    if !valid_identifier(chain)
        || !valid_interface(interface)
        || !valid_mark(mark)
        || !valid_mark(mask)
        || comment.is_empty()
        || comment.len() > 256
        || comment.chars().any(char::is_control)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "недопустимые параметры проверки fw4 WARP",
        ));
    }
    let rules = fw4_chain_rules(chain_output, chain)?;
    let escaped_comment = nft_quote(comment)?;
    let exact = format!(
        "meta mark & {mask} == {mark} oifname \"{interface}\" accept comment {escaped_comment}"
    );
    let wildcard = format!(
        "meta mark & {mask} == {mark} oifname \"z2ktun*\" accept comment {escaped_comment}"
    );
    let mut expected = vec![exact, wildcard];
    for mark_expression in nft_mark_prefix_expressions(mark, mask) {
        expected.push(format!(
            "{mark_expression} oifname \"{interface}\" accept comment {escaped_comment}"
        ));
        expected.push(format!(
            "{mark_expression} oifname \"z2ktun*\" accept comment {escaped_comment}"
        ));
    }
    Ok(rules
        .iter()
        .any(|rule| expected.iter().any(|expression| rule.contains(expression))))
}

pub fn render_fw4_forward_remove_batch(
    chain_output: &str,
    family: &str,
    table: &str,
    chain: &str,
    comment: &str,
) -> io::Result<String> {
    for value in [family, table, chain] {
        if !valid_identifier(value) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft-объекта содержит недопустимые символы",
            ));
        }
    }
    let rules = fw4_chain_rules(chain_output, chain)?;
    let marker = format!("comment {}", nft_quote(comment)?);
    let mut handles = std::collections::BTreeSet::new();
    for rule in rules {
        if !rule.contains(&marker) {
            continue;
        }
        let Some(interface) = nft_rule_interface(rule) else {
            continue;
        };
        if interface == "z2ktun*" || !is_runtime_tunnel_interface(interface) {
            continue;
        }
        let Some(handle) = nft_rule_handle(rule) else {
            return Err(io::Error::new(
                io::ErrorKind::InvalidData,
                "для принадлежащего WARP правила fw4 отсутствует handle",
            ));
        };
        handles.insert(handle.to_owned());
    }
    Ok(handles
        .into_iter()
        .map(|handle| format!("delete rule {family} {table} {chain} handle {handle}\n"))
        .collect())
}

fn validate_fw4_arguments(
    family: &str,
    table: &str,
    chain: &str,
    interface: &str,
    comment: &str,
) -> io::Result<()> {
    if [family, table, chain]
        .into_iter()
        .any(|value| !valid_identifier(value))
        || !valid_interface(interface)
        || comment.is_empty()
        || comment.len() > 256
        || comment.chars().any(char::is_control)
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "недопустимые параметры правила fw4 WARP",
        ));
    }
    Ok(())
}

fn valid_mark(value: &str) -> bool {
    let Some(hex) = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
    else {
        return false;
    };
    !hex.is_empty() && hex.len() <= 8 && hex.bytes().all(|byte| byte.is_ascii_hexdigit())
}

fn nft_mark_prefix_expressions(mark: &str, mask: &str) -> Vec<String> {
    let Some(mark) = mark
        .strip_prefix("0x")
        .or_else(|| mark.strip_prefix("0X"))
        .and_then(|value| u32::from_str_radix(value, 16).ok())
    else {
        return Vec::new();
    };
    let Some(mask) = mask
        .strip_prefix("0x")
        .or_else(|| mask.strip_prefix("0X"))
        .and_then(|value| u32::from_str_radix(value, 16).ok())
    else {
        return Vec::new();
    };
    if mark & !mask != 0 {
        return Vec::new();
    }
    let prefix = mask.leading_ones();
    if prefix == 0 || mask != u32::MAX << (32 - prefix) {
        return Vec::new();
    }

    let value = format!("0x{mark:x}");
    let mut expressions = vec![format!("meta mark {value}/{prefix}")];
    if prefix == 32 {
        expressions.push(format!("meta mark {value}"));
    }
    expressions
}

fn nft_quote(value: &str) -> io::Result<String> {
    if value.is_empty() || value.len() > 256 || value.chars().any(char::is_control) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "недопустимый nft comment",
        ));
    }
    let mut quoted = String::with_capacity(value.len() + 2);
    quoted.push('"');
    for character in value.chars() {
        if matches!(character, '"' | '\\') {
            quoted.push('\\');
        }
        quoted.push(character);
    }
    quoted.push('"');
    Ok(quoted)
}

fn fw4_chain_rules<'a>(output: &'a str, chain: &str) -> io::Result<Vec<&'a str>> {
    let header = format!("chain {chain} {{");
    if !output.lines().any(|line| line.trim().starts_with(&header)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "ответ nft не содержит ожидаемую fw4 цепочку",
        ));
    }
    Ok(output
        .lines()
        .map(str::trim)
        .filter(|line| {
            !line.is_empty()
                && !line.starts_with("chain ")
                && !line.starts_with("type ")
                && !line.starts_with("policy ")
                && *line != "}"
        })
        .collect())
}

fn nft_rule_interface(rule: &str) -> Option<&str> {
    let start = rule.find("oifname \"")? + "oifname \"".len();
    let rest = &rule[start..];
    let end = rest.find('"')?;
    Some(&rest[..end])
}

fn is_runtime_tunnel_interface(interface: &str) -> bool {
    interface.strip_prefix("z2ktun").is_some_and(|suffix| {
        !suffix.is_empty() && suffix.bytes().all(|byte| byte.is_ascii_digit())
    })
}

fn nft_rule_handle(rule: &str) -> Option<&str> {
    let (_, handle) = rule.rsplit_once(" # handle ")?;
    (!handle.is_empty() && handle.bytes().all(|byte| byte.is_ascii_digit())).then_some(handle)
}

pub fn tun_chains_match(
    table_output: &str,
    family: &str,
    table: &str,
    mss_chain: &str,
    forward_chain: &str,
    nat_chain: &str,
    interface: &str,
) -> io::Result<bool> {
    for identifier in [family, table, mss_chain, forward_chain, nat_chain] {
        if !valid_identifier(identifier) {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "имя nft TUN-цепочки содержит недопустимые символы",
            ));
        }
    }
    if !valid_interface(interface) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "недопустимое имя TUN-интерфейса",
        ));
    }

    Ok(tun_chain_rules_match(
        table_output,
        family,
        table,
        mss_chain,
        &[
            format!("oifname {interface} tcp flags syn tcp option maxseg size set rt mtu"),
            format!("iifname {interface} tcp flags syn tcp option maxseg size set 1240"),
        ],
    ) && tun_chain_rules_match(
        table_output,
        family,
        table,
        forward_chain,
        &[format!("oifname {interface} accept")],
    ) && tun_chain_rules_match(
        table_output,
        family,
        table,
        nat_chain,
        &[format!("oifname {interface} masquerade")],
    ))
}

fn tun_chain_rules_match(
    output: &str,
    family: &str,
    table: &str,
    chain: &str,
    expected: &[String],
) -> bool {
    let table_header = format!("table {family} {table} {{");
    if !output.lines().any(|line| line.trim() == table_header) {
        return false;
    }
    let Some(block) = extract_nft_block(output, "chain", chain) else {
        return false;
    };
    let actual = block
        .lines()
        .map(str::trim)
        .filter(|line| {
            !line.is_empty()
                && !line.starts_with("chain ")
                && !line.starts_with("comment ")
                && *line != "}"
        })
        .map(normalize_tun_rule)
        .collect::<Vec<_>>();
    actual == expected
}

fn normalize_tun_rule(line: &str) -> String {
    let mut interface_name = false;
    let normalized = line
        .split_whitespace()
        .map(|token| {
            if interface_name {
                interface_name = false;
                token.trim_matches('"')
            } else {
                interface_name = matches!(token, "iifname" | "oifname");
                token
            }
        })
        .collect::<Vec<_>>();
    normalized.join(" ")
}

pub fn render_set_batch_with_create(
    family: &str,
    table: &str,
    destination_set: &str,
    source_set: &str,
    inventory: &SetInventory,
    destinations: &[String],
    sources: &[String],
) -> io::Result<String> {
    let mut batch = String::new();
    if inventory.destinations.is_none() {
        batch.push_str(&format!(
            "add set {family} {table} {destination_set} {{ type ipv4_addr; flags interval; }}\n"
        ));
    }
    if inventory.sources.is_none() {
        batch.push_str(&format!(
            "add set {family} {table} {source_set} {{ type ipv4_addr; flags interval; }}\n"
        ));
    }
    batch.push_str(&render_set_batch(
        family,
        table,
        destination_set,
        source_set,
        destinations,
        sources,
    )?);
    Ok(batch)
}

pub fn apply_transaction(batch: &str) -> io::Result<()> {
    let mut child = Command::new("nft")
        .args(["-f", "-"])
        .stdin(Stdio::piped())
        .stdout(Stdio::null())
        .stderr(Stdio::piped())
        .spawn()?;
    child
        .stdin
        .take()
        .ok_or_else(|| io::Error::other("не удалось открыть stdin nft"))?
        .write_all(batch.as_bytes())?;
    let output = child.wait_with_output()?;
    if output.status.success() {
        return Ok(());
    }
    let details = String::from_utf8_lossy(&output.stderr);
    Err(io::Error::other(format!(
        "nft отклонил атомарную транзакцию: {}",
        details.trim()
    )))
}

fn append_elements(batch: &mut String, family: &str, table: &str, set: &str, entries: &[String]) {
    if entries.is_empty() {
        return;
    }
    batch.push_str(&format!(
        "add element {family} {table} {set} {{ {} }}\n",
        entries.join(", ")
    ));
}

fn valid_identifier(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 64
        && value.as_bytes()[0].is_ascii_lowercase()
        && value
            .bytes()
            .all(|byte| byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'_')
}

fn parse_one_set(table_output: &str, name: &str) -> io::Result<Option<Vec<String>>> {
    let start = format!("set {name} {{");
    let Some(start_index) = table_output.lines().position(|line| line.trim() == start) else {
        return Ok(None);
    };
    let lines: Vec<&str> = table_output.lines().collect();
    let mut block = String::new();
    let mut depth = 0_i32;
    let mut opened = false;
    for line in lines.iter().skip(start_index) {
        for character in line.chars() {
            match character {
                '{' => {
                    depth += 1;
                    opened = true;
                }
                '}' => depth -= 1,
                _ => {}
            }
        }
        block.push_str(line);
        block.push('\n');
        if opened && depth == 0 {
            break;
        }
    }
    if depth != 0 || !opened {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "неполное описание nft set",
        ));
    }
    if !block
        .lines()
        .any(|line| line.trim_start().starts_with("type ipv4_addr"))
        || !block
            .lines()
            .any(|line| line.trim_start().starts_with("flags interval"))
    {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            format!("nft set {name} имеет чужую схему"),
        ));
    }
    parse_elements(&block).map(Some)
}

fn parse_elements(block: &str) -> io::Result<Vec<String>> {
    let Some(line_index) = block.lines().position(|line| line.contains("elements")) else {
        return Ok(Vec::new());
    };
    let lines: Vec<&str> = block.lines().collect();
    let mut raw = String::new();
    let mut opened = false;
    let mut closed = false;
    for line in lines.iter().skip(line_index) {
        for character in line.chars() {
            if character == '{' {
                opened = true;
                continue;
            }
            if character == '}' && opened {
                closed = true;
                break;
            }
            if opened {
                raw.push(character);
            }
        }
        if closed {
            break;
        }
    }
    if !opened || !closed {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "не удалось прочитать элементы nft set",
        ));
    }
    let entries: Vec<String> = raw
        .split(',')
        .map(str::trim)
        .filter(|entry| !entry.is_empty())
        .map(str::to_owned)
        .collect();
    if entries.iter().any(|entry| !valid_ipv4_entry(entry, true)) {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "nft set содержит неизвестную форму IPv4-элемента",
        ));
    }
    Ok(entries)
}

fn set_matches(actual: &Option<Vec<String>>, expected: &[String]) -> bool {
    let Some(actual) = actual else { return false };
    let mut actual: Vec<String> = actual.iter().map(|entry| strip_host_mask(entry)).collect();
    let mut expected: Vec<String> = expected
        .iter()
        .map(|entry| strip_host_mask(entry))
        .collect();
    actual.sort();
    expected.sort();
    actual == expected
}

fn strip_host_mask(entry: &str) -> String {
    entry.strip_suffix("/32").unwrap_or(entry).to_owned()
}

fn valid_ipv4_entry(entry: &str, allow_cidr: bool) -> bool {
    let (address, prefix) = match entry.split_once('/') {
        Some((address, prefix)) if allow_cidr => {
            if prefix.is_empty()
                || !prefix.bytes().all(|byte| byte.is_ascii_digit())
                || prefix.starts_with('0')
            {
                return false;
            }
            let Ok(prefix) = prefix.parse::<u8>() else {
                return false;
            };
            if !(1..=32).contains(&prefix) {
                return false;
            }
            (address, Some(prefix))
        }
        Some(_) => return false,
        None => (entry, None),
    };
    let octets: Vec<&str> = address.split('.').collect();
    if octets.len() != 4
        || octets.iter().any(|octet| {
            octet.is_empty()
                || octet.len() > 3
                || !octet.bytes().all(|byte| byte.is_ascii_digit())
                || (octet.len() > 1 && octet.starts_with('0'))
        })
    {
        return false;
    }
    address.parse::<std::net::Ipv4Addr>().is_ok() && (allow_cidr || prefix.is_none())
}

#[cfg(test)]
mod tests {
    use super::fw4_forward_matches;

    #[test]
    fn verifies_nft_1_0_9_canonical_fw4_mark_rule() {
        let output = "table inet fw4 {\n\tchain forward { # handle 1\n\t\ttype filter hook forward priority filter; policy accept;\n\t\tmeta mark 0x80000000/1 oifname \"z2ktun0\" accept comment \"!z2k: WARP forwarded traffic\" # handle 2\n\t}\n}\n";

        assert!(
            fw4_forward_matches(
                output,
                "forward",
                "z2ktun0",
                "0x80000000",
                "0x80000000",
                "!z2k: WARP forwarded traffic",
            )
            .unwrap()
        );

        let foreign = output.replace("0x80000000/1", "0x40000000/1");
        assert!(
            !fw4_forward_matches(
                &foreign,
                "forward",
                "z2ktun0",
                "0x80000000",
                "0x80000000",
                "!z2k: WARP forwarded traffic",
            )
            .unwrap()
        );
    }
}
