use std::{
    collections::BTreeMap,
    fs, io,
    net::Ipv4Addr,
    os::unix::fs::PermissionsExt,
    path::Path,
    process::{Command, Output},
};

use crate::process;
use serde_json::{Map, Number, Value};

#[derive(Debug)]
pub struct RouteObservation {
    pub rules: String,
    pub table: String,
    pub interface: String,
    pub probe_address: String,
}

#[derive(Debug, Default, Eq, PartialEq)]
pub struct RouteInventory {
    pub probe_rule: bool,
    pub user_rule: bool,
    pub default_route: bool,
}

pub struct RouteConfig<'a> {
    pub interface: &'a str,
    pub probe_address: &'a str,
    pub table: u32,
    pub user_pref: u32,
    pub probe_pref: u32,
    pub mark: u32,
    pub mask: u32,
    pub pbr_owner: &'a Path,
    pub probe_owner: &'a Path,
}

pub fn verify_policy(config: &RouteConfig<'_>) -> Result<bool, String> {
    if !valid_tun(config.interface)
        || config.probe_address.parse::<Ipv4Addr>().is_err()
        || config.mask == 0
        || config.mark & !config.mask != 0
    {
        return Err("неверные параметры WARP route policy".into());
    }
    if !command_ok("ip", &["link", "show", "dev", config.interface])? {
        return Ok(false);
    }

    let inventory = snapshot(config)?;
    let pbr_owner = read_owner(config.pbr_owner)?;
    let probe_owner = read_owner(config.probe_owner)?;
    Ok(inventory.user_rule
        && inventory.probe_rule
        && inventory.default_route
        && pbr_owner
            .as_ref()
            .is_some_and(|owner| owner_matches(owner, config))
        && probe_owner
            .as_ref()
            .is_some_and(|owner| probe_owner_matches(owner, config)))
}

pub fn reconcile_policy(config: &RouteConfig<'_>) -> Result<bool, String> {
    if verify_policy(config)? {
        return Ok(false);
    }
    apply_policy(config, true)?;
    if !verify_policy(config)? {
        return Err("iproute2 не подтвердил согласованное WARP-состояние".into());
    }
    Ok(true)
}

pub fn apply_policy(config: &RouteConfig<'_>, include_user_rule: bool) -> Result<bool, String> {
    if !valid_tun(config.interface)
        || config.probe_address.parse::<Ipv4Addr>().is_err()
        || config.mask == 0
        || config.mark & !config.mask != 0
    {
        return Err("неверные параметры WARP route policy".into());
    }
    if !command_ok("ip", &["link", "show", "dev", config.interface])? {
        return Err(format!("TUN-интерфейс {} не найден", config.interface));
    }

    let mut inventory = snapshot(config)?;
    let pbr_owner = read_owner(config.pbr_owner)?;
    let probe_owner = read_owner(config.probe_owner)?;
    let pbr_owned = pbr_owner
        .as_ref()
        .is_some_and(|owner| owner_matches(owner, config));
    let probe_owner_matches = probe_owner
        .as_ref()
        .is_some_and(|owner| probe_owner_matches(owner, config));
    if probe_owner.is_some() && !probe_owner_matches {
        return Err("запись владельца probe не совпадает с WARP-состоянием".into());
    }
    let probe_owned = probe_owner_matches || (probe_owner.is_none() && pbr_owned);
    if inventory.user_rule && !pbr_owned {
        return Err("найдено точное WARP правило без записи владельца".into());
    }
    if inventory.probe_rule && !probe_owned && !pbr_owned {
        return Err("найдено точное probe правило без записи владельца".into());
    }
    if inventory.default_route && !probe_owned && !pbr_owned {
        return Err("таблица WARP содержит маршрут без записи владельца".into());
    }

    let mut changed = false;
    let mut added_route = false;
    let mut added_probe = false;
    let mut added_user = false;
    let mutation = (|| {
        if !inventory.default_route {
            run_ip(&[
                "route",
                "replace",
                "default",
                "dev",
                config.interface,
                "table",
                &config.table.to_string(),
            ])?;
            changed = true;
            added_route = true;
        }
        if !inventory.probe_rule {
            run_ip(&[
                "rule",
                "add",
                "pref",
                &config.probe_pref.to_string(),
                "from",
                &format!("{}/32", config.probe_address),
                "table",
                &config.table.to_string(),
            ])?;
            changed = true;
            added_probe = true;
        }
        if include_user_rule && !inventory.user_rule {
            run_ip(&[
                "rule",
                "add",
                "pref",
                &config.user_pref.to_string(),
                "fwmark",
                &format!("{:#x}/{:#x}", config.mark, config.mask),
                "table",
                &config.table.to_string(),
            ])?;
            changed = true;
            added_user = true;
        }
        Ok::<(), String>(())
    })();
    if let Err(error) = mutation {
        rollback_added(config, added_user, added_probe, added_route);
        return Err(error);
    }

    inventory = match snapshot(config) {
        Ok(inventory) => inventory,
        Err(error) => {
            rollback_added(config, added_user, added_probe, added_route);
            return Err(error);
        }
    };
    if !inventory.default_route
        || !inventory.probe_rule
        || (include_user_rule && !inventory.user_rule)
    {
        rollback_added(config, added_user, added_probe, added_route);
        return Err("iproute2 не подтвердил установленное WARP-состояние".into());
    }

    if !probe_owner_matches
        && let Err(error) = write_owner(config.probe_owner, &probe_owner_text(config))
    {
        rollback_added(config, added_user, added_probe, added_route);
        return Err(format!(
            "не удалось записать владельца probe route: {error}"
        ));
    }
    if include_user_rule
        && !pbr_owned
        && let Err(error) = write_owner(config.pbr_owner, &pbr_owner_text(config))
    {
        rollback_added(config, added_user, added_probe, added_route);
        if !probe_owned {
            let _ = fs::remove_file(config.probe_owner);
        }
        return Err(format!("не удалось записать владельца PBR: {error}"));
    }
    Ok(changed)
}

pub fn remove_policy(config: &RouteConfig<'_>) -> Result<bool, String> {
    let inventory = snapshot(config)?;
    let pbr_owner = read_owner(config.pbr_owner)?;
    let probe_owner = read_owner(config.probe_owner)?;
    let pbr_owned = pbr_owner
        .as_ref()
        .is_some_and(|owner| owner_matches(owner, config));
    let probe_owner_matches = probe_owner
        .as_ref()
        .is_some_and(|owner| probe_owner_matches(owner, config));
    let probe_owned = probe_owner_matches || (probe_owner.is_none() && pbr_owned);
    let route_owned = probe_owned || pbr_owned;
    if inventory.user_rule && !pbr_owned {
        return Err("не удаляю WARP правило без совпадающей записи владельца".into());
    }
    if inventory.default_route && !route_owned {
        return Err("не удаляю маршрут таблицы WARP без совпадающей записи владельца".into());
    }

    let mut changed = false;
    if inventory.user_rule {
        run_ip(&[
            "rule",
            "del",
            "pref",
            &config.user_pref.to_string(),
            "fwmark",
            &format!("{:#x}/{:#x}", config.mark, config.mask),
            "table",
            &config.table.to_string(),
        ])?;
        changed = true;
    }
    if inventory.probe_rule && probe_owned {
        run_ip(&[
            "rule",
            "del",
            "pref",
            &config.probe_pref.to_string(),
            "from",
            &format!("{}/32", config.probe_address),
            "table",
            &config.table.to_string(),
        ])?;
        changed = true;
    }
    if inventory.default_route && route_owned {
        run_ip(&[
            "route",
            "del",
            "default",
            "dev",
            config.interface,
            "table",
            &config.table.to_string(),
        ])?;
        changed = true;
    }

    let after = snapshot(config)?;
    if (pbr_owned && after.user_rule)
        || (probe_owned && after.probe_rule)
        || (route_owned && after.default_route)
    {
        return Err("iproute2 не подтвердил снятие принадлежащих WARP-маршрутов".into());
    }
    if pbr_owned {
        remove_owner(config.pbr_owner)?;
    }
    if probe_owner_matches {
        remove_owner(config.probe_owner)?;
    }
    Ok(changed)
}

pub fn remove_policy_from_owner_files(fallback: &RouteConfig<'_>) -> Result<bool, String> {
    let pbr_record = read_owner_file(fallback.pbr_owner)?;
    let probe_record = read_owner_file(fallback.probe_owner)?;
    let pbr_interface = pbr_record
        .as_ref()
        .map(|owner| required_owner_field(owner, "iface", fallback.pbr_owner))
        .transpose()?;
    let probe_interface = probe_record
        .as_ref()
        .map(|owner| required_owner_field(owner, "iface", fallback.probe_owner))
        .transpose()?;
    let owner_probe_address = probe_record
        .as_ref()
        .map(|owner| required_owner_field(owner, "addr", fallback.probe_owner))
        .transpose()?;
    let interface = pbr_interface
        .or(probe_interface)
        .unwrap_or(fallback.interface);
    let probe_address = if fallback.probe_address.is_empty() {
        owner_probe_address.unwrap_or("")
    } else {
        fallback.probe_address
    };
    if interface.is_empty() || probe_address.is_empty() {
        if pbr_record.is_none() && probe_record.is_none() {
            return Ok(false);
        }
        return Err("записи владельца WARP не содержат адрес для безопасного удаления".into());
    }

    let config = RouteConfig {
        interface,
        probe_address,
        table: fallback.table,
        user_pref: fallback.user_pref,
        probe_pref: fallback.probe_pref,
        mark: fallback.mark,
        mask: fallback.mask,
        pbr_owner: fallback.pbr_owner,
        probe_owner: fallback.probe_owner,
    };
    remove_policy(&config)
}

fn snapshot(config: &RouteConfig<'_>) -> Result<RouteInventory, String> {
    let rule_args = ["-4", "-j", "rule", "show"];
    let rules_output = run_ip_command(&rule_args)?;
    let json_rules = if rules_output.status.success() {
        Some(ip_output_text(rules_output, &rule_args)?)
    } else if json_output_unsupported(&rules_output) {
        None
    } else {
        return Err(format!(
            "не удалось прочитать состояние iproute2: {}",
            rule_args.join(" ")
        ));
    };

    let route_args = ["-4", "-j", "route", "show", "table", "all"];
    let json_table = if json_rules.is_some() {
        let table_output = run_ip_command(&route_args)?;
        if table_output.status.success() {
            Some(ip_output_text(table_output, &route_args)?)
        } else if json_output_unsupported(&table_output) {
            None
        } else {
            return Err(format!(
                "не удалось прочитать состояние iproute2: {}",
                route_args.join(" ")
            ));
        }
    } else {
        None
    };

    let (rules, table) = match (json_rules, json_table) {
        (Some(rules), Some(table)) => (rules, table),
        _ => {
            let rules = run_ip_output(&["-4", "rule", "show"])?;
            let table_id = config.table.to_string();
            let table = run_ip_output(&["-4", "route", "show", "table", &table_id])?;
            (rules, table)
        }
    };
    inspect_routes(
        &RouteObservation {
            rules,
            table,
            interface: config.interface.to_owned(),
            probe_address: config.probe_address.to_owned(),
        },
        config.user_pref,
        config.probe_pref,
        config.mark,
        config.mask,
        config.table,
    )
}

fn run_ip(arguments: &[&str]) -> Result<(), String> {
    if command_ok("ip", arguments)? {
        Ok(())
    } else {
        Err(format!(
            "iproute2 отклонил операцию: {}",
            arguments.join(" ")
        ))
    }
}

fn run_ip_output(arguments: &[&str]) -> Result<String, String> {
    let output = run_ip_command(arguments)?;
    ip_output_text(output, arguments)
}

fn run_ip_command(arguments: &[&str]) -> Result<Output, String> {
    process::output(Command::new("ip").args(arguments))
        .map_err(|error| format!("не удалось запустить iproute2: {error}"))
}

fn ip_output_text(output: Output, arguments: &[&str]) -> Result<String, String> {
    if !output.status.success() {
        let route_table_query = (arguments.len() == 4
            && arguments[0..3] == ["route", "show", "table"])
            || (arguments.len() == 5 && arguments[0..4] == ["-4", "route", "show", "table"]);
        if route_table_query
            && output.stdout.is_empty()
            && String::from_utf8_lossy(&output.stderr).contains("FIB table does not exist")
        {
            return Ok(String::new());
        }
        return Err(format!(
            "не удалось прочитать состояние iproute2: {}",
            arguments.join(" ")
        ));
    }
    String::from_utf8(output.stdout).map_err(|error| format!("iproute2 вернул не-UTF8: {error}"))
}

fn json_output_unsupported(output: &Output) -> bool {
    let text = format!(
        "{}\n{}",
        String::from_utf8_lossy(&output.stdout),
        String::from_utf8_lossy(&output.stderr)
    )
    .to_ascii_lowercase();
    text.contains("busybox")
        || text.contains("usage: ip")
        || text.contains("invalid option")
        || text.contains("unrecognized option")
}

fn command_ok(program: &str, arguments: &[&str]) -> Result<bool, String> {
    let output = process::output(Command::new(program).args(arguments))
        .map_err(|error| format!("не удалось запустить {program}: {error}"))?;
    Ok(output.status.success())
}

fn rollback_added(config: &RouteConfig<'_>, user: bool, probe: bool, route: bool) {
    if user {
        let _ = run_ip(&[
            "rule",
            "del",
            "pref",
            &config.user_pref.to_string(),
            "fwmark",
            &format!("{:#x}/{:#x}", config.mark, config.mask),
            "table",
            &config.table.to_string(),
        ]);
    }
    if probe {
        let _ = run_ip(&[
            "rule",
            "del",
            "pref",
            &config.probe_pref.to_string(),
            "from",
            &format!("{}/32", config.probe_address),
            "table",
            &config.table.to_string(),
        ]);
    }
    if route {
        let _ = run_ip(&[
            "route",
            "del",
            "default",
            "dev",
            config.interface,
            "table",
            &config.table.to_string(),
        ]);
    }
}

fn owner_matches(owner: &BTreeMap<String, String>, config: &RouteConfig<'_>) -> bool {
    owner
        .get("mark")
        .is_some_and(|value| value == &format!("{:#x}", config.mark))
        && owner
            .get("mask")
            .is_some_and(|value| value == &format!("{:#x}", config.mask))
        && owner
            .get("pref")
            .is_some_and(|value| value == &config.user_pref.to_string())
        && owner
            .get("table")
            .is_some_and(|value| value == &config.table.to_string())
        && owner
            .get("iface")
            .is_some_and(|value| value == config.interface)
}

fn probe_owner_matches(owner: &BTreeMap<String, String>, config: &RouteConfig<'_>) -> bool {
    owner
        .get("iface")
        .is_some_and(|value| value == config.interface)
        && owner
            .get("addr")
            .is_some_and(|value| value == config.probe_address)
}

fn read_owner(path: &Path) -> Result<Option<BTreeMap<String, String>>, String> {
    let content = match fs::read_to_string(path) {
        Ok(content) => content,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "не удалось прочитать запись владельца {}: {error}",
                path.display()
            ));
        }
    };
    let mut owner = BTreeMap::new();
    for line in content.lines() {
        let Some((key, value)) = line.split_once('=') else {
            return Err(format!(
                "неверная строка в записи владельца {}",
                path.display()
            ));
        };
        if owner.insert(key.to_owned(), value.to_owned()).is_some() {
            return Err(format!(
                "повторяющееся поле в записи владельца {}",
                path.display()
            ));
        }
    }
    Ok(Some(owner))
}

fn read_owner_file(path: &Path) -> Result<Option<BTreeMap<String, String>>, String> {
    match fs::metadata(path) {
        Ok(metadata) if metadata.is_file() => {}
        Ok(_) => {
            return Err(format!(
                "запись владельца {} не является файлом",
                path.display()
            ));
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(None),
        Err(error) => {
            return Err(format!(
                "не удалось проверить запись владельца {}: {error}",
                path.display()
            ));
        }
    }
    read_owner(path)?
        .map(Some)
        .ok_or_else(|| format!("запись владельца {} имеет неверный формат", path.display()))
}

fn required_owner_field<'a>(
    owner: &'a BTreeMap<String, String>,
    key: &str,
    path: &Path,
) -> Result<&'a str, String> {
    owner
        .get(key)
        .map(String::as_str)
        .filter(|value| !value.is_empty())
        .ok_or_else(|| format!("запись владельца {} не содержит поле {key}", path.display()))
}

fn pbr_owner_text(config: &RouteConfig<'_>) -> String {
    format!(
        "mark={:#x}\nmask={:#x}\npref={}\ntable={}\niface={}\n",
        config.mark, config.mask, config.user_pref, config.table, config.interface
    )
}

fn probe_owner_text(config: &RouteConfig<'_>) -> String {
    format!(
        "iface={}\naddr={}\n",
        config.interface, config.probe_address
    )
}

fn write_owner(path: &Path, contents: &str) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| io::Error::other("путь owner не имеет каталога"))?;
    fs::create_dir_all(parent)?;
    let temporary = path.with_extension(format!("new.{}", std::process::id()));
    fs::write(&temporary, contents)?;
    fs::set_permissions(&temporary, fs::Permissions::from_mode(0o600))?;
    fs::rename(temporary, path)
}

fn remove_owner(path: &Path) -> Result<(), String> {
    match fs::remove_file(path) {
        Ok(()) => Ok(()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
        Err(error) => Err(format!(
            "не удалось удалить запись владельца {}: {error}",
            path.display()
        )),
    }
}

pub fn inspect_routes(
    observed: &RouteObservation,
    user_pref: u32,
    probe_pref: u32,
    mark: u32,
    mask: u32,
    table: u32,
) -> Result<RouteInventory, String> {
    if mask == 0 || mark & !mask != 0 || !valid_tun(&observed.interface) {
        return Err("неверные параметры WARP route policy".into());
    }
    observed
        .probe_address
        .parse::<Ipv4Addr>()
        .map_err(|_| "неверный IPv4-адрес probe".to_owned())?;

    let rules = parse_rule_observation(&observed.rules)?;

    let mut inventory = RouteInventory::default();
    let mut user_count = 0;
    let mut probe_count = 0;
    for rule in &rules {
        let pref = json_u32(rule, "priority")
            .ok_or_else(|| format!("ip rule без допустимого priority: {rule}"))?;
        let rule_table = json_table(rule.get("table"));
        let source = rule_source(rule)?;
        let found_mark = json_mark(rule)?;
        let has_extra_selector = rule.get("_z2k_extra_selector").is_some();
        let exact_user = !has_extra_selector
            && pref == user_pref
            && source == "all"
            && found_mark == Some((mark, mask))
            && rule_table == Some(table);
        let exact_probe = !has_extra_selector
            && pref == probe_pref
            && source_matches_probe(source, &observed.probe_address)
            && found_mark.is_none()
            && rule_table == Some(table);

        if pref == user_pref {
            user_count += 1;
            if !exact_user {
                return Err(format!("приоритет WARP занят чужим ip rule: {rule}"));
            }
        }
        if pref == probe_pref {
            probe_count += 1;
            if !exact_probe {
                return Err(format!("приоритет probe занят чужим ip rule: {rule}"));
            }
        }
        if !exact_user && let Some((other_mark, other_mask)) = found_mark {
            let overlap = (other_mark ^ mark) & other_mask & mask == 0;
            if overlap {
                return Err(format!("чужой fwmark пересекается с WARP: {rule}"));
            }
        }
        inventory.user_rule |= exact_user;
        inventory.probe_rule |= exact_probe;
    }
    if user_count > 1 || probe_count > 1 {
        return Err("приоритет WARP продублирован".into());
    }

    let routes = parse_route_observation(&observed.table, table)?;
    let mut route_count = 0;
    for route in &routes {
        let route_table = match route.get("table") {
            Some(value) => json_table(Some(value))
                .ok_or_else(|| format!("ip route содержит неверную table: {route}"))?,
            None => 254,
        };
        if route_table != table {
            continue;
        }
        if !exact_default_route_json(route, &observed.interface, table) {
            return Err(format!("таблица WARP содержит чужой маршрут: {route}"));
        }
        route_count += 1;
        if route_count > 1 {
            return Err("default WARP route продублирован".into());
        }
    }
    inventory.default_route = route_count == 1;
    Ok(inventory)
}

fn parse_rule_observation(contents: &str) -> Result<Vec<Value>, String> {
    if contents.trim_start().starts_with('[') {
        let rules: Value = serde_json::from_str(contents)
            .map_err(|error| format!("не удалось разобрать JSON ip rule: {error}"))?;
        return rules
            .as_array()
            .cloned()
            .ok_or_else(|| "iproute2 вернул не-массив JSON для правил".to_owned());
    }
    if contents.trim().is_empty() {
        return Err("ip rule вернул пустой вывод".into());
    }

    let mut rules = Vec::new();
    for line in contents
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        let (priority, body) = line
            .split_once(':')
            .ok_or_else(|| format!("не удалось разобрать правило BusyBox ip: {line}"))?;
        let priority = priority
            .trim()
            .parse::<u32>()
            .map_err(|_| format!("не удалось разобрать приоритет BusyBox ip: {line}"))?;
        let tokens: Vec<_> = body.split_whitespace().collect();
        let mut source = None;
        let mut fwmark = None;
        let mut fwmask = None;
        let mut table = None;
        let mut extra_selector = false;
        let mut index = 0;

        while index < tokens.len() {
            let token = tokens[index];
            index += 1;
            match token {
                "from" => {
                    let value = next_rule_value(&tokens, &mut index, line)?;
                    if source.replace(value).is_some() {
                        return Err(format!(
                            "правило BusyBox ip содержит повторный from: {line}"
                        ));
                    }
                }
                "fwmark" => {
                    let value = next_rule_value(&tokens, &mut index, line)?;
                    if fwmark.replace(value).is_some() {
                        return Err(format!(
                            "правило BusyBox ip содержит повторный fwmark: {line}"
                        ));
                    }
                }
                "fwmask" => {
                    let value = next_rule_value(&tokens, &mut index, line)?;
                    if fwmask.replace(value).is_some() {
                        return Err(format!(
                            "правило BusyBox ip содержит повторный fwmask: {line}"
                        ));
                    }
                }
                "lookup" | "table" => {
                    let value = next_rule_value(&tokens, &mut index, line);
                    let value = value?;
                    if table.replace(value).is_some() {
                        return Err(format!(
                            "правило BusyBox ip содержит повторную таблицу: {line}"
                        ));
                    }
                }
                "to"
                | "iif"
                | "oif"
                | "tos"
                | "uidrange"
                | "ipproto"
                | "sport"
                | "dport"
                | "realms"
                | "suppress_prefixlength"
                | "suppress_ifgroup"
                | "goto" => {
                    extra_selector = true;
                    let _ = next_rule_value(&tokens, &mut index, line)?;
                }
                "not" | "l3mdev" | "blackhole" | "unreachable" | "prohibit" | "throw" | "nat" => {
                    extra_selector = true
                }
                _ => extra_selector = true,
            }
        }

        let mut rule = Map::new();
        rule.insert("priority".into(), Value::Number(Number::from(priority)));
        rule.insert(
            "src".into(),
            Value::String(source.unwrap_or_else(|| "all".into())),
        );
        if let Some(fwmark) = fwmark {
            rule.insert("fwmark".into(), Value::String(fwmark));
        }
        if let Some(fwmask) = fwmask {
            rule.insert("fwmask".into(), Value::String(fwmask));
        }
        if let Some(table) = table {
            rule.insert("table".into(), Value::String(table));
        }
        if extra_selector {
            rule.insert("_z2k_extra_selector".into(), Value::Bool(true));
        }
        rules.push(Value::Object(rule));
    }
    Ok(rules)
}

fn next_rule_value(tokens: &[&str], index: &mut usize, line: &str) -> Result<String, String> {
    let value = tokens
        .get(*index)
        .ok_or_else(|| format!("у правила BusyBox ip отсутствует значение: {line}"))?;
    *index += 1;
    Ok((*value).to_owned())
}

fn parse_route_observation(contents: &str, table: u32) -> Result<Vec<Value>, String> {
    if contents.trim_start().starts_with('[') {
        let routes: Value = serde_json::from_str(contents)
            .map_err(|error| format!("не удалось разобрать JSON ip route: {error}"))?;
        return routes
            .as_array()
            .cloned()
            .ok_or_else(|| "iproute2 вернул не-массив JSON для маршрутов".to_owned());
    }

    let mut routes = Vec::new();
    for line in contents
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        let tokens: Vec<_> = line.split_whitespace().collect();
        let mut index = 0;
        let mut route = Map::new();
        if matches!(
            tokens.first(),
            Some(
                &"unicast"
                    | &"local"
                    | &"broadcast"
                    | &"blackhole"
                    | &"unreachable"
                    | &"prohibit"
                    | &"throw"
                    | &"nat"
            )
        ) {
            route.insert("type".into(), Value::String(tokens[0].to_owned()));
            index += 1;
        }
        let destination = tokens
            .get(index)
            .ok_or_else(|| format!("не удалось разобрать маршрут BusyBox ip: {line}"))?;
        route.insert("dst".into(), Value::String((*destination).to_owned()));
        route.insert("table".into(), Value::Number(Number::from(table)));
        index += 1;
        let mut unexpected_attribute = false;

        while index < tokens.len() {
            let token = tokens[index];
            index += 1;
            match token {
                "dev" | "scope" | "metric" | "table" => {
                    let value = tokens.get(index).ok_or_else(|| {
                        format!("у маршрута BusyBox ip отсутствует значение: {line}")
                    })?;
                    index += 1;
                    if token == "table" {
                        let value = json_table(Some(&Value::String((*value).to_owned())))
                            .ok_or_else(|| {
                                format!("маршрут BusyBox ip содержит неверную таблицу: {line}")
                            })?;
                        if value != table {
                            return Err(format!(
                                "маршрут BusyBox ip вышел за запрошенную таблицу: {line}"
                            ));
                        }
                    }
                    let key = if token == "metric" { "metric" } else { token };
                    if route
                        .insert(key.into(), Value::String((*value).to_owned()))
                        .is_some()
                    {
                        unexpected_attribute = true;
                    }
                }
                "via" => {
                    let mut value = tokens.get(index).ok_or_else(|| {
                        format!("у маршрута BusyBox ip отсутствует gateway: {line}")
                    })?;
                    index += 1;
                    if matches!(*value, "inet" | "inet6") {
                        value = tokens.get(index).ok_or_else(|| {
                            format!("у маршрута BusyBox ip отсутствует gateway: {line}")
                        })?;
                        index += 1;
                    }
                    if route
                        .insert("gateway".into(), Value::String((*value).to_owned()))
                        .is_some()
                    {
                        unexpected_attribute = true;
                    }
                }
                "proto" | "src" | "prefsrc" => {
                    unexpected_attribute = true;
                    let _ = tokens.get(index).ok_or_else(|| {
                        format!("у маршрута BusyBox ip отсутствует значение: {line}")
                    })?;
                    index += 1;
                }
                _ => unexpected_attribute = true,
            }
        }
        if unexpected_attribute {
            route.insert("_z2k_unexpected_attribute".into(), Value::Bool(true));
        }
        routes.push(Value::Object(route));
    }
    Ok(routes)
}

fn json_u32(object: &Value, key: &str) -> Option<u32> {
    json_u32_value(object.get(key)?)
}

fn json_u32_value(value: &Value) -> Option<u32> {
    value
        .as_u64()
        .and_then(|number| u32::try_from(number).ok())
        .or_else(|| parse_u32(value.as_str()?))
}

fn json_string(value: Option<&Value>) -> Option<&str> {
    value?.as_str()
}

fn json_table(value: Option<&Value>) -> Option<u32> {
    let value = value?;
    if let Some(number) = value.as_u64() {
        return u32::try_from(number).ok();
    }
    match value.as_str()? {
        "local" => Some(255),
        "main" => Some(254),
        "default" => Some(253),
        number => number.parse().ok(),
    }
}

fn json_mark(rule: &Value) -> Result<Option<(u32, u32)>, String> {
    let Some(value) = rule.get("fwmark") else {
        if rule.get("fwmask").is_some() {
            return Err(format!("ip rule содержит fwmask без fwmark: {rule}"));
        }
        return Ok(None);
    };
    let text = match value {
        Value::String(value) => value.clone(),
        Value::Number(value) => value.to_string(),
        _ => return Err(format!("ip rule содержит неверный fwmark: {rule}")),
    };
    let (mark, embedded_mask) =
        parse_mark(&text).ok_or_else(|| format!("не удалось разобрать fwmark: {rule}"))?;
    let mask = match rule.get("fwmask") {
        Some(value) => {
            let mask = json_u32_value(value)
                .ok_or_else(|| format!("ip rule содержит неверный fwmask: {rule}"))?;
            if text.contains('/') && mask != embedded_mask {
                return Err(format!(
                    "ip rule содержит несогласованные fwmark/fwmask: {rule}"
                ));
            }
            mask
        }
        None => embedded_mask,
    };
    Ok(Some((mark, mask)))
}

fn rule_source(rule: &Value) -> Result<&str, String> {
    let source = rule.get("src");
    let from = rule.get("from");
    match (source, from) {
        (None, None) => Ok("all"),
        (Some(Value::String(source)), None) | (None, Some(Value::String(source))) => Ok(source),
        (Some(Value::String(source)), Some(Value::String(from))) if source == from => Ok(source),
        _ => Err(format!("ip rule содержит неверный src/from: {rule}")),
    }
}

fn source_matches_probe(source: &str, address: &str) -> bool {
    source.strip_suffix("/32").unwrap_or(source) == address
}

fn parse_mark(value: &str) -> Option<(u32, u32)> {
    let (mark, mask) = value.split_once('/').unwrap_or((value, "0xffffffff"));
    Some((parse_u32(mark)?, parse_u32(mask)?))
}

fn parse_u32(value: &str) -> Option<u32> {
    if let Some(hex) = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
    {
        u32::from_str_radix(hex, 16).ok()
    } else {
        value.parse().ok()
    }
}

fn exact_default_route_json(route: &Value, interface: &str, table: u32) -> bool {
    let route_type = match route.get("type") {
        None => true,
        Some(Value::String(value)) => value == "unicast",
        Some(_) => false,
    };
    route_type
        && matches!(json_string(route.get("dst")), Some("default" | "0.0.0.0/0"))
        && json_string(route.get("dev")) == Some(interface)
        && json_table(route.get("table")).unwrap_or(254) == table
        && route.get("_z2k_unexpected_attribute").is_none()
        && route.get("gateway").is_none()
        && route.get("via").is_none()
        && route.get("metric").is_none()
        && matches!(json_string(route.get("scope")), None | Some("link"))
}

fn valid_tun(interface: &str) -> bool {
    let Some(suffix) = interface.strip_prefix("z2ktun") else {
        return false;
    };
    (suffix.len() == 1 || suffix.len() == 2) && suffix.bytes().all(|byte| byte.is_ascii_digit())
}

#[cfg(test)]
mod tests {
    use super::{RouteConfig, RouteInventory, snapshot};
    use std::path::Path;

    #[test]
    #[ignore = "ручной smoke в WSL с BusyBox ip и реальным состоянием таблицы маршрутов"]
    fn снимок_маршрутов_читает_реальный_busybox_ip() {
        let config = RouteConfig {
            interface: "z2ktun0",
            probe_address: "172.16.9.9",
            table: 989,
            user_pref: 500,
            probe_pref: 499,
            mark: 0x8000_0000,
            mask: 0x8000_0000,
            pbr_owner: Path::new("/tmp/z2k-warp-unused-pbr-owner"),
            probe_owner: Path::new("/tmp/z2k-warp-unused-probe-owner"),
        };

        assert_eq!(snapshot(&config).unwrap(), RouteInventory::default());
    }
}
