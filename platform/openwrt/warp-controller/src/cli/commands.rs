use std::fs;
use std::os::unix::fs::PermissionsExt;
use std::path::PathBuf;
use std::time::Duration;
use std::{env, io, process};
use warp_controller::{
    config::{self, MatchOrder},
    devices,
    disable::{self, CleanupFailure, Config as DisableConfig, DisableOperations},
    domain_state, health, lifecycle, lists,
    lock::MutationLock,
    nft,
    openwrt::InterfaceKind,
    registration, route_error,
    routing::{
        RouteConfig, apply_policy, reconcile_policy, remove_policy, remove_policy_from_owner_files,
        verify_policy,
    },
    state::{
        EngineStatus, Observation, ProcessStatus, RuntimeReadiness, observe_warp_process,
        read_engine_status, read_engine_status_snapshot, runtime_readiness,
    },
};

pub(super) fn required(
    args: &mut impl Iterator<Item = String>,
    description: &str,
) -> io::Result<String> {
    args.next()
        .ok_or_else(|| invalid(&format!("не задан {description}")))
}

pub(super) fn run_interface_list(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let kind = match required(args, "тип интерфейсов")?.as_str() {
        "lan" => InterfaceKind::Lan,
        "wireguard-servers" => InterfaceKind::WireGuardServers,
        "wireguard-clients" => InterfaceKind::WireGuardClients,
        _ => return Err(invalid("неизвестный тип интерфейсов")),
    };
    if args.next().is_some() {
        return Err(invalid("лишние аргументы interfaces"));
    }
    for interface in warp_controller::openwrt::discover_interfaces(kind)? {
        println!("{interface}");
    }
    Ok(())
}

pub(super) fn run_nft_sets_command(
    args: &mut impl Iterator<Item = String>,
    apply: bool,
) -> io::Result<()> {
    let _lock = acquire_global_lock()?;
    let user_dir = required(args, "каталог пользовательских списков")?;
    let games_dir = required(args, "каталог игровых списков")?;
    let enabled = required(args, "файл включённых игр")?;
    let devices = required(args, "файл устройств")?;
    let family = required(args, "семейство nft")?;
    let table = required(args, "таблица nft")?;
    let dst_set = required(args, "набор адресов назначения")?;
    let src_set = required(args, "набор адресов источника")?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы nft sets command"));
    }

    let snapshot = lists::load_active_lists(
        user_dir.as_ref(),
        games_dir.as_ref(),
        enabled.as_ref(),
        devices.as_ref(),
    )?;
    let destinations = lists::normalize_destinations(&snapshot.validation.addresses.join("\n"));
    let leases_file = env::var_os("WARP_DHCP_LEASES")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/dhcp.leases"));
    let mut sources =
        devices::resolve_selected_devices_from_text(&snapshot.device_sources, &leases_file)?;
    sources.sort();
    sources.dedup();
    if destinations.is_empty()
        && sources.is_empty()
        && snapshot.validation.domains.is_empty()
        && snapshot.has_nonempty_input
    {
        return Err(invalid(
            "непустые источники не содержат допустимых адресов; nft не изменён",
        ));
    }

    let table_output = command_output("nft", &["list", "table", &family, &table])?;
    let inventory = nft::parse_set_inventory(&table_output, &family, &table, &dst_set, &src_set)?;
    if nft::sets_match(&inventory, &destinations, &sources) {
        if !apply {
            println!("ready=1");
        }
        return Ok(());
    }
    if !apply {
        println!("ready=0");
        return Ok(());
    }
    let batch = nft::render_set_batch_with_create(
        &family,
        &table,
        &dst_set,
        &src_set,
        &inventory,
        &destinations,
        &sources,
    )?;
    nft::apply_transaction(&batch)
}

pub(super) fn run_nft_set_count(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let family = required(args, "семейство nft")?;
    let table = required(args, "таблица nft")?;
    let set = required(args, "набор nft")?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы nft-set-count"));
    }
    let output = command_output("nft", &["list", "set", &family, &table, &set])?;
    println!("{}", nft::count_ipv4_set_elements(&output));
    Ok(())
}

pub(super) fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

pub(super) fn parse_bool(value: &str) -> io::Result<bool> {
    match value {
        "0" => Ok(false),
        "1" => Ok(true),
        _ => Err(invalid("ожидается 0 или 1")),
    }
}

pub(super) fn run_service_plan(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let intent = match required(args, "действие жизненного цикла WARP")?.as_str()
    {
        "enable" => lifecycle::ServiceIntent::Enable,
        "disable" => lifecycle::ServiceIntent::Disable,
        "restart" => lifecycle::ServiceIntent::Restart,
        _ => return Err(invalid("неверное действие service-plan")),
    };
    let was_enabled = parse_bool(&required(args, "прежний флаг WARP")?)?;
    let service_active = match required(args, "состояние службы procd")?.as_str() {
        "1" => Observation::Known(true),
        "0" => Observation::Known(false),
        "unreadable" => Observation::Unreadable,
        _ => return Err(invalid("ожидается 0, 1 или unreadable для службы procd")),
    };
    let process_running = parse_bool(&required(args, "состояние процесса WARP")?)?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы service-plan"));
    }

    let action = lifecycle::service_action(intent, was_enabled, service_active, process_running);
    println!(
        "{}",
        match action {
            lifecycle::ServiceAction::Defer => "defer",
            lifecycle::ServiceAction::None => "none",
            lifecycle::ServiceAction::Start => "start",
            lifecycle::ServiceAction::Stop => "stop",
            lifecycle::ServiceAction::Reload => "reload",
            lifecycle::ServiceAction::Restart => "restart",
        }
    );
    Ok(())
}

pub(super) fn run_register_due(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let stamp_path = PathBuf::from(required(args, "файл попытки регистрации")?);
    let now = required(args, "текущее время")?
        .parse::<u64>()
        .map_err(|_| invalid("неверное текущее время регистрации"))?;
    let retry_seconds = required(args, "интервал повторной регистрации")?
        .parse::<u64>()
        .map_err(|_| invalid("неверный интервал повторной регистрации"))?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы register-due"));
    }

    let result = match registration::attempt_due(&stamp_path, now, retry_seconds) {
        Observation::Known(true) => "due",
        Observation::Known(false) => "wait",
        Observation::Unreadable => "defer",
    };
    println!("{result}");
    Ok(())
}

pub(super) fn parse_policy_observation(
    value: &str,
    true_value: &str,
    false_value: &str,
) -> io::Result<Observation<bool>> {
    match value {
        value if value == true_value => Ok(Observation::Known(true)),
        value if value == false_value => Ok(Observation::Known(false)),
        "unreadable" => Ok(Observation::Unreadable),
        _ => Err(invalid("неверное наблюдение policy-plan")),
    }
}

pub(super) fn run_health_plan(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let config_path = PathBuf::from(required(args, "файл конфигурации WARP")?);
    let binary_path = PathBuf::from(required(args, "бинарник движка WARP")?);
    let device_path = PathBuf::from(required(args, "файл регистрации WARP")?);
    let status_path = PathBuf::from(required(args, "файл состояния WARP")?);
    let proc_root = PathBuf::from(required(args, "корень procfs")?);
    if args.next().is_some() {
        return Err(invalid("лишние аргументы health-plan"));
    }

    let engine = read_engine_status(&status_path);
    let iface_present = observe_interface(&engine);
    let ready_iface = match &engine {
        EngineStatus::Ready { iface } => Some(iface.clone()),
        EngineStatus::NotReady | EngineStatus::Unreadable => None,
    };
    let action = health::plan(health::HealthObservations {
        config_enabled: read_config_flag(&config_path, "ENABLED", "1", MatchOrder::Last),
        feature_enabled: read_config_flag(&config_path, "GAME_WARP_ENABLED", "", MatchOrder::First),
        binary_present: file_observation(&binary_path, |metadata| {
            metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
        }),
        device_present: file_observation(&device_path, |metadata| {
            metadata.is_file() && metadata.len() > 0
        }),
        process: observe_warp_process(&proc_root),
        engine,
        iface_present,
    });
    let action_name = match action {
        health::HealthAction::Defer => "defer",
        health::HealthAction::Disabled => "disabled",
        health::HealthAction::BinaryMissing => "binary-missing",
        health::HealthAction::DeviceMissing => "device-missing",
        health::HealthAction::ProcessAbsent => "process-absent",
        health::HealthAction::NotReady => "not-ready",
        health::HealthAction::Ready => "ready",
    };
    if action == health::HealthAction::Ready {
        println!("{action_name} {}", ready_iface.as_deref().unwrap_or(""));
    } else {
        println!("{action_name}");
    }
    Ok(())
}

pub(super) fn run_boot_plan(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let config_path = PathBuf::from(required(args, "файл конфигурации WARP")?);
    let binary_path = PathBuf::from(required(args, "бинарник движка WARP")?);
    let device_path = PathBuf::from(required(args, "файл регистрации WARP")?);
    if args.next().is_some() {
        return Err(invalid("лишние аргументы boot-plan"));
    }

    let action = health::plan_boot(
        read_config_flag(&config_path, "ENABLED", "1", MatchOrder::Last),
        read_config_flag(&config_path, "GAME_WARP_ENABLED", "", MatchOrder::First),
        file_observation(&binary_path, |metadata| {
            metadata.is_file() && metadata.permissions().mode() & 0o111 != 0
        }),
        file_observation(&device_path, |metadata| {
            metadata.is_file() && metadata.len() > 0
        }),
    );
    println!(
        "{}",
        match action {
            health::BootAction::Defer => "defer",
            health::BootAction::Skip => "unwanted",
            health::BootAction::Start => "wanted",
        }
    );
    Ok(())
}

pub(super) fn read_config_flag(
    path: &std::path::Path,
    key: &str,
    default: &str,
    order: MatchOrder,
) -> Observation<bool> {
    match config::read_value(path, key, default, order) {
        Ok(value) => Observation::Known(value == "1"),
        Err(_) => Observation::Unreadable,
    }
}

pub(super) fn file_observation(
    path: &std::path::Path,
    is_present: impl FnOnce(&fs::Metadata) -> bool,
) -> Observation<bool> {
    match fs::metadata(path) {
        Ok(metadata) => Observation::Known(is_present(&metadata)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Observation::Known(false),
        Err(_) => Observation::Unreadable,
    }
}

pub(super) fn observe_interface(engine: &EngineStatus) -> Option<bool> {
    match engine {
        EngineStatus::Ready { iface } if valid_warp_interface(iface) => {
            live_link_exists(iface).ok()
        }
        EngineStatus::Ready { .. } => Some(false),
        EngineStatus::NotReady | EngineStatus::Unreadable => None,
    }
}

pub(super) fn run_runtime_observe(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let status_path = required(args, "файл состояния WARP")?;
    let proc_root = required(args, "корень procfs")?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы runtime-observe"));
    }

    let process = observe_warp_process(proc_root.as_ref());
    match process {
        ProcessStatus::Absent => {
            println!("not-ready absent -");
            return Ok(());
        }
        ProcessStatus::Unreadable => {
            println!("unreadable unreadable -");
            return Ok(());
        }
        ProcessStatus::Present => {}
    }

    let engine = read_engine_status(status_path.as_ref());
    let iface_present = match &engine {
        EngineStatus::Ready { iface } if valid_warp_interface(iface) => {
            live_link_exists(iface).ok()
        }
        EngineStatus::Ready { .. } => Some(false),
        EngineStatus::NotReady | EngineStatus::Unreadable => None,
    };
    match runtime_readiness(process, engine, iface_present) {
        RuntimeReadiness::Ready { iface } => println!("ready present {iface}"),
        RuntimeReadiness::NotReady => println!("not-ready present -"),
        RuntimeReadiness::Unreadable => println!("unreadable present -"),
    }
    Ok(())
}

pub(super) fn run_ready_observe_since(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let status_path = PathBuf::from(required(args, "файл состояния WARP")?);
    let proc_root = PathBuf::from(required(args, "корень procfs")?);
    let started_at = required(args, "время начала ожидания")?
        .parse::<u64>()
        .map_err(|_| invalid("время начала ожидания должно быть epoch в секундах"))?;
    if started_at == 0 {
        return Err(invalid("неизвестное время начала ожидания"));
    }
    if args.next().is_some() {
        return Err(invalid("лишние аргументы ready-observe-since"));
    }

    let process = observe_warp_process(proc_root.as_ref());
    let (engine, status_modified) = read_engine_status_snapshot(&status_path);
    let iface_present = observe_interface(&engine);
    match health::ready_since(process, engine, iface_present, status_modified, started_at) {
        RuntimeReadiness::Ready { iface } => println!("ready {iface}"),
        RuntimeReadiness::NotReady => println!("not-ready"),
        RuntimeReadiness::Unreadable => println!("unreadable"),
    }
    Ok(())
}

pub(super) fn valid_warp_interface(iface: &str) -> bool {
    let Some(suffix) = iface.strip_prefix("z2ktun") else {
        return false;
    };
    (1..=2).contains(&suffix.len()) && suffix.bytes().all(|byte| byte.is_ascii_digit())
}

pub(super) fn link_exists(output: &str, iface: &str) -> io::Result<bool> {
    if !output.trim_start().starts_with('[') {
        return link_exists_text(output, iface);
    }
    let links: Vec<serde_json::Value> = serde_json::from_str(output)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    for link in links {
        let name = link
            .get("ifname")
            .and_then(serde_json::Value::as_str)
            .ok_or_else(|| invalid("ip link JSON не содержит имя интерфейса"))?;
        if name == iface {
            return Ok(true);
        }
    }
    Ok(false)
}

pub(super) fn link_exists_text(output: &str, iface: &str) -> io::Result<bool> {
    let mut found_link = false;
    for line in output
        .lines()
        .map(str::trim)
        .filter(|line| !line.is_empty())
    {
        let Some((index, link)) = line.split_once(':') else {
            continue;
        };
        if index.trim().parse::<u32>().is_err() {
            continue;
        }
        let (name, _) = link.trim_start().split_once(':').ok_or_else(|| {
            io::Error::new(
                io::ErrorKind::InvalidData,
                "ip link не содержит имя интерфейса",
            )
        })?;
        found_link = true;
        let name = name.split('@').next().unwrap_or(name);
        if name == iface {
            return Ok(true);
        }
    }
    if !found_link {
        return Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "ip link вернул некорректный текстовый список интерфейсов",
        ));
    }
    Ok(false)
}

pub(super) fn live_link_exists(iface: &str) -> io::Result<bool> {
    let json =
        warp_controller::process::output(process::Command::new("ip").args(["-j", "link", "show"]))?;
    if json.status.success() {
        let output = String::from_utf8(json.stdout)
            .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
        return link_exists(&output, iface);
    }
    if !json_output_unsupported(&json) {
        return Err(command_error("ip -j link show", &json.stderr));
    }
    let text =
        warp_controller::process::output(process::Command::new("ip").args(["link", "show"]))?;
    if !text.status.success() {
        return Err(command_error("ip link show", &text.stderr));
    }
    let output = String::from_utf8(text.stdout)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))?;
    link_exists(&output, iface)
}

pub(super) fn json_output_unsupported(output: &process::Output) -> bool {
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

pub(super) fn parse_interface_csv(value: &str) -> io::Result<Vec<String>> {
    if value.is_empty() {
        return Ok(Vec::new());
    }
    let interfaces: Vec<String> = value.split(',').map(str::to_owned).collect();
    if interfaces.iter().any(String::is_empty) {
        return Err(invalid(
            "список сетевых интерфейсов содержит пустой элемент",
        ));
    }
    Ok(interfaces)
}

pub(super) fn nft_table_exists(tables: &str, family: &str, table: &str) -> bool {
    let expected = format!("table {family} {table}");
    tables.lines().any(|line| line.trim() == expected)
}

pub(super) fn run_nft_mark(
    args: &mut impl Iterator<Item = String>,
    apply: bool,
) -> io::Result<bool> {
    let _lock = acquire_global_lock()?;
    let family = required(args, "семейство nft")?;
    let table = required(args, "таблица nft")?;
    let chain = required(args, "MARK-цепочка")?;
    let destination_set = required(args, "набор назначения")?;
    let source_set = required(args, "набор источника")?;
    let domain_set = required(args, "доменный набор")?;
    let user_dir = required(args, "каталог пользовательских списков")?;
    let games_dir = required(args, "каталог игровых списков")?;
    let enabled_file = required(args, "файл включённых игр")?;
    let devices_file = required(args, "файл выбранных устройств")?;
    let config_file = required(args, "файл настроек")?;
    let lan_ifaces = parse_interface_csv(&required(args, "LAN-интерфейсы")?)?;
    let wireguard_servers = parse_interface_csv(&required(args, "WG server-интерфейсы")?)?;
    let wireguard_clients = parse_interface_csv(&required(args, "WG client-интерфейсы")?)?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы nft-mark command"));
    }
    let policy_inputs = lists::load_mark_policy_inputs(
        user_dir.as_ref(),
        games_dir.as_ref(),
        enabled_file.as_ref(),
        devices_file.as_ref(),
    )?;
    let wdtt_enabled =
        config::read_value(config_file.as_ref(), "Z2K_WARP_WDTT", "0", MatchOrder::Last)? == "1";
    let tables = command_output("nft", &["list", "tables"])?;
    if !nft_table_exists(&tables, &family, &table) {
        if apply {
            return Err(io::Error::new(
                io::ErrorKind::NotFound,
                "таблица nft отсутствует для MARK-цепочки",
            ));
        }
        return Ok(false);
    }
    let table_output = command_output("nft", &["list", "table", &family, &table])?;
    let inventory = nft::parse_set_inventory(
        &table_output,
        &family,
        &table,
        &destination_set,
        &source_set,
    )?;
    let flags = nft::plan_mark_flags(
        policy_inputs.scope.as_str(),
        wdtt_enabled,
        !policy_inputs.domains.is_empty(),
        inventory
            .destinations
            .as_ref()
            .is_some_and(|destinations| !destinations.is_empty()),
    )?;
    let domain_rules_active =
        !policy_inputs.domains.is_empty() && policy_inputs.scope.as_str() != "all";
    let domain_set_for_rules = if domain_rules_active {
        domain_set.as_str()
    } else {
        ""
    };
    let batch = nft::render_mark_batch(&nft::MarkConfig {
        family: &family,
        table: &table,
        chain: &chain,
        destination_set: &destination_set,
        source_set: &source_set,
        domain_set: domain_set_for_rules,
        scope: policy_inputs.scope.as_str(),
        wdtt_active: flags.wdtt_active,
        list_active: flags.list_active,
        lan_ifaces: &lan_ifaces,
        wireguard_servers: &wireguard_servers,
        wireguard_clients: &wireguard_clients,
    })?;
    if domain_rules_active {
        let pair_set = nft::domain_pair_set_matches(&table_output, &family, &table, &domain_set)?;
        if pair_set.is_none() {
            if apply {
                return Err(io::Error::new(
                    io::ErrorKind::NotFound,
                    "доменный nft-набор отсутствует для MARK-цепочки",
                ));
            }
            return Ok(false);
        }
    }
    if nft::mark_chain_matches(&table_output, &family, &table, &chain, &batch)? == Some(true) {
        return Ok(true);
    }
    if apply {
        nft::apply_transaction(&batch)?;
        return Ok(true);
    }
    Ok(false)
}

pub(super) fn run_nft_tun_verify(args: &mut impl Iterator<Item = String>) -> io::Result<bool> {
    let _lock = acquire_global_lock()?;
    let family = required(args, "семейство nft")?;
    let table = required(args, "таблица nft")?;
    let mss_chain = required(args, "MSS-цепочка")?;
    let forward_chain = required(args, "forward-цепочка")?;
    let nat_chain = required(args, "NAT-цепочка")?;
    let interface = required(args, "TUN-интерфейс")?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы nft-tun-verify"));
    }

    let tables = command_output("nft", &["list", "tables"])?;
    if !nft_table_exists(&tables, &family, &table) {
        return Ok(false);
    }
    let output = command_output("nft", &["list", "table", &family, &table])?;
    nft::tun_chains_match(
        &output,
        &family,
        &table,
        &mss_chain,
        &forward_chain,
        &nat_chain,
        &interface,
    )
}

pub(super) fn run_nft_chain_clear(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let _lock = acquire_global_lock()?;
    let family = required(args, "семейство nft")?;
    let table = required(args, "таблица nft")?;
    let chains = args.collect::<Vec<_>>();
    if chains.is_empty() {
        return Err(invalid("не заданы nft-цепочки для очистки"));
    }
    clear_nft_chains(&family, &table, &chains)
}

pub(super) fn clear_nft_chains(family: &str, table: &str, chains: &[String]) -> io::Result<()> {
    let tables = command_output("nft", &["list", "tables"])?;
    if !nft_table_exists(&tables, family, table) {
        return Ok(());
    }
    let output = command_output("nft", &["list", "table", family, table])?;
    let chains = chains.iter().map(String::as_str).collect::<Vec<_>>();
    let batch = nft::render_chain_flush_batch(&output, family, table, &chains)?;
    if batch.is_empty() {
        Ok(())
    } else {
        nft::apply_transaction(&batch)
    }
}

pub(super) fn run_nft_fw4_forward_apply(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let _lock = acquire_global_lock()?;
    let family = required(args, "семейство fw4")?;
    let table = required(args, "таблица fw4")?;
    let chain = required(args, "цепочка fw4")?;
    let interface = required(args, "TUN-интерфейс")?;
    let mark = required(args, "метка WARP")?;
    let mask = required(args, "маска WARP")?;
    let comment = required(args, "комментарий fw4")?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы nft-fw4-forward-apply"));
    }
    let output = command_output("nft", &["list", "chain", &family, &table, &chain])?;
    let batch = nft::render_fw4_forward_apply_batch(
        &output, &family, &table, &chain, &interface, &mark, &mask, &comment,
    )?;
    if batch.is_empty() {
        Ok(())
    } else {
        nft::apply_transaction(&batch)
    }
}

pub(super) fn run_nft_fw4_forward_verify(
    args: &mut impl Iterator<Item = String>,
) -> io::Result<()> {
    let family = required(args, "семейство fw4")?;
    let table = required(args, "таблица fw4")?;
    let chain = required(args, "цепочка fw4")?;
    let interface = required(args, "TUN-интерфейс")?;
    let mark = required(args, "метка WARP")?;
    let mask = required(args, "маска WARP")?;
    let comment = required(args, "комментарий fw4")?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы nft-fw4-forward-verify"));
    }
    let tables = command_output("nft", &["list", "tables"])?;
    if !nft_table_exists(&tables, &family, &table) {
        println!("ready=0");
        return Ok(());
    }
    let output = command_output("nft", &["list", "chain", &family, &table, &chain])?;
    let ready = nft::fw4_forward_matches(&output, &chain, &interface, &mask, &mark, &comment)?;
    println!("ready={}", u8::from(ready));
    Ok(())
}

pub(super) fn run_nft_fw4_forward_remove(
    args: &mut impl Iterator<Item = String>,
) -> io::Result<()> {
    let _lock = acquire_global_lock()?;
    let family = required(args, "семейство fw4")?;
    let table = required(args, "таблица fw4")?;
    let chain = required(args, "цепочка fw4")?;
    let comment = required(args, "комментарий fw4")?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы nft-fw4-forward-remove"));
    }
    remove_fw4_forward_rule(&family, &table, &chain, &comment)
}

pub(super) fn remove_fw4_forward_rule(
    family: &str,
    table: &str,
    chain: &str,
    comment: &str,
) -> io::Result<()> {
    let tables = command_output("nft", &["list", "tables"])?;
    if !nft_table_exists(&tables, family, table) {
        return Ok(());
    }
    let output = command_output("nft", &["-a", "list", "chain", family, table, chain])?;
    let batch = nft::render_fw4_forward_remove_batch(&output, family, table, chain, comment)?;
    if batch.is_empty() {
        Ok(())
    } else {
        nft::apply_transaction(&batch)
    }
}

pub(super) fn run_nft_warp_remove(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let _lock = acquire_global_lock()?;
    let family = required(args, "семейство nft WARP")?;
    let table = required(args, "таблица nft WARP")?;
    let full = parse_bool(&required(args, "полное удаление nft WARP")?)?;
    let chains = (0..4)
        .map(|_| required(args, "WARP-цепочка"))
        .collect::<io::Result<Vec<_>>>()?;
    let sets = (0..2)
        .map(|_| required(args, "WARP-набор"))
        .collect::<io::Result<Vec<_>>>()?;
    if args.next().is_some() {
        return Err(invalid("лишние аргументы nft-warp-remove"));
    }
    let tables = command_output("nft", &["list", "tables"])?;
    if !nft_table_exists(&tables, &family, &table) {
        return Ok(());
    }
    let output = command_output("nft", &["list", "table", &family, &table])?;
    let chains = chains.iter().map(String::as_str).collect::<Vec<_>>();
    let sets = sets.iter().map(String::as_str).collect::<Vec<_>>();
    let batch = nft::render_warp_remove_batch(&output, &family, &table, &chains, &sets, full)?;
    if batch.is_empty() {
        Ok(())
    } else {
        nft::apply_transaction(&batch)
    }
}

pub(super) fn remove_domain_nft_state(
    observer_family: &str,
    observer_table: &str,
    pair_family: &str,
    pair_table: &str,
    pair_set: &str,
    full: bool,
) -> io::Result<()> {
    let tables_output = command_output("nft", &["list", "tables"])?;
    let observer_exists = nft_table_exists(&tables_output, observer_family, observer_table);
    if observer_exists {
        let output = command_output("nft", &["list", "table", observer_family, observer_table])?;
        if !nft::domain_observer_table_owned(&output, observer_family, observer_table)? {
            return Err(io::Error::new(
                io::ErrorKind::AlreadyExists,
                "nft observer table занят другим владельцем",
            ));
        }
    }
    let pair_set_exists = if nft_table_exists(&tables_output, pair_family, pair_table) {
        let output = command_output("nft", &["list", "table", pair_family, pair_table])?;
        nft::domain_pair_set_matches(&output, pair_family, pair_table, pair_set)?.is_some()
    } else {
        false
    };
    let batch = nft::render_domain_remove_batch(&nft::DomainRemoveConfig {
        family: observer_family,
        observer_table,
        pair_family,
        pair_table,
        pair_set,
        observer_exists,
        pair_set_exists,
        full,
    })?;
    if batch.is_empty() {
        Ok(())
    } else {
        nft::apply_transaction(&batch)
    }
}

pub(super) fn run_disable_state(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    if args.next().is_some() {
        return Err(invalid(
            "disable-state получает конфигурацию только через stdin",
        ));
    }
    let config = DisableConfig::read(io::stdin().lock())?;
    let _lock = acquire_global_lock()?;
    let route = RouteConfig {
        interface: &config.interface,
        probe_address: &config.probe_address,
        table: config.table,
        user_pref: config.user_pref,
        probe_pref: config.probe_pref,
        mark: config.mark,
        mask: config.mask,
        pbr_owner: &config.pbr_owner,
        probe_owner: &config.probe_owner,
    };
    let mut operations = RuntimeDisableOperations {
        config: &config,
        route,
    };
    disable::prepare(&mut operations)
}

struct RuntimeDisableOperations<'a> {
    config: &'a DisableConfig,
    route: RouteConfig<'a>,
}

impl DisableOperations for RuntimeDisableOperations<'_> {
    fn remove_routes(&mut self) -> io::Result<()> {
        remove_policy_from_owner_files(&self.route)
            .map(|_| ())
            .map_err(io::Error::other)
    }

    fn remove_remaining_state(&mut self) -> Vec<CleanupFailure> {
        let mut errors = Vec::new();
        if let Err(error) = remove_fw4_forward_rule(
            &self.config.fw4_family,
            &self.config.fw4_table,
            &self.config.fw4_chain,
            &self.config.fw4_comment,
        ) {
            errors.push(CleanupFailure {
                reason: "warp-disable-fw4-remove-failed",
                message: format!("fw4: {error}"),
            });
        }
        let chains = [
            self.config.mark_chain.clone(),
            self.config.mss_chain.clone(),
            self.config.forward_chain.clone(),
            self.config.nat_chain.clone(),
        ];
        if let Err(error) =
            clear_nft_chains(&self.config.nft_family, &self.config.nft_table, &chains)
        {
            errors.push(CleanupFailure {
                reason: "warp-disable-nft-remove-failed",
                message: format!("nft WARP: {error}"),
            });
        }
        match remove_domain_nft_state(
            &self.config.observer_family,
            &self.config.observer_table,
            &self.config.pair_family,
            &self.config.pair_table,
            &self.config.pair_set,
            false,
        ) {
            Ok(()) => {
                if let Err(error) = domain_state::set_error_file(&self.config.domain_error_file, "")
                {
                    errors.push(CleanupFailure {
                        reason: "warp-disable-domain-marker-failed",
                        message: format!("marker domain observer: {error}"),
                    });
                }
            }
            Err(error) => {
                errors.push(CleanupFailure {
                    reason: "warp-disable-domain-remove-failed",
                    message: format!("domain observer: {error}"),
                });
                if let Err(marker_error) = domain_state::set_error_file(
                    &self.config.domain_error_file,
                    "nft-domain-remove-failed",
                ) {
                    errors.push(CleanupFailure {
                        reason: "warp-disable-domain-marker-failed",
                        message: format!("marker domain observer: {marker_error}"),
                    });
                }
            }
        }
        errors
    }

    fn clear_failure_marker(&mut self) -> io::Result<()> {
        route_error::clear(&self.config.route_error_file)
    }

    fn commit_disabled(&mut self) -> io::Result<()> {
        config::set_config_flag(&self.config.config_file, "GAME_WARP_ENABLED", "0")
    }

    fn record_failure(&mut self, reason: &str) -> io::Result<()> {
        route_error::set(&self.config.route_error_file, reason)
    }
}

pub(super) fn run_route_command(
    args: &mut impl Iterator<Item = String>,
    apply: bool,
) -> io::Result<()> {
    let _lock = acquire_global_lock()?;
    let interface = required(args, "TUN-интерфейс")?;
    let probe_address = required(args, "IPv4-адрес probe")?;
    let table = parse_u32(&required(args, "номер таблицы")?)?;
    let user_pref = parse_u32(&required(args, "приоритет пользовательского правила")?)?;
    let probe_pref = parse_u32(&required(args, "приоритет probe-правила")?)?;
    let mark = parse_u32(&required(args, "метка fwmark")?)?;
    let mask = parse_u32(&required(args, "маска fwmark")?)?;
    let pbr_owner = PathBuf::from(required(args, "файл владельца PBR")?);
    let probe_owner = PathBuf::from(required(args, "файл владельца probe")?);
    let include_user = if apply {
        Some(parse_bool(&required(args, "признак PBR")?)?)
    } else {
        None
    };
    if args.next().is_some() {
        return Err(invalid("лишние аргументы route command"));
    }
    let config = RouteConfig {
        interface: &interface,
        probe_address: &probe_address,
        table,
        user_pref,
        probe_pref,
        mark,
        mask,
        pbr_owner: &pbr_owner,
        probe_owner: &probe_owner,
    };
    if let Some(include_user) = include_user {
        apply_policy(&config, include_user).map_err(io::Error::other)?;
    } else {
        remove_policy(&config).map_err(io::Error::other)?;
    }
    Ok(())
}

pub(super) fn run_route_remove_owned_command(
    args: &mut impl Iterator<Item = String>,
) -> io::Result<()> {
    let _lock = acquire_global_lock()?;
    let fallback_interface = required(args, "резервный TUN-интерфейс")?;
    let fallback_probe_address = required(args, "резервный IPv4-адрес probe")?;
    let table = parse_u32(&required(args, "номер таблицы")?)?;
    let user_pref = parse_u32(&required(args, "приоритет пользовательского правила")?)?;
    let probe_pref = parse_u32(&required(args, "приоритет probe-правила")?)?;
    let mark = parse_u32(&required(args, "метка fwmark")?)?;
    let mask = parse_u32(&required(args, "маска fwmark")?)?;
    let pbr_owner = PathBuf::from(required(args, "файл владельца PBR")?);
    let probe_owner = PathBuf::from(required(args, "файл владельца probe")?);
    if args.next().is_some() {
        return Err(invalid("лишние аргументы route-remove-owned"));
    }
    let fallback = RouteConfig {
        interface: &fallback_interface,
        probe_address: &fallback_probe_address,
        table,
        user_pref,
        probe_pref,
        mark,
        mask,
        pbr_owner: &pbr_owner,
        probe_owner: &probe_owner,
    };
    remove_policy_from_owner_files(&fallback).map_err(io::Error::other)?;
    Ok(())
}

pub(super) fn run_route_reconcile_command(
    args: &mut impl Iterator<Item = String>,
) -> io::Result<()> {
    let _lock = acquire_global_lock()?;
    let interface = required(args, "TUN-интерфейс")?;
    let probe_address = required(args, "IPv4-адрес probe")?;
    let table = parse_u32(&required(args, "номер таблицы")?)?;
    let user_pref = parse_u32(&required(args, "приоритет пользовательского правила")?)?;
    let probe_pref = parse_u32(&required(args, "приоритет probe-правила")?)?;
    let mark = parse_u32(&required(args, "метка fwmark")?)?;
    let mask = parse_u32(&required(args, "маска fwmark")?)?;
    let pbr_owner = PathBuf::from(required(args, "файл владельца PBR")?);
    let probe_owner = PathBuf::from(required(args, "файл владельца probe")?);
    if args.next().is_some() {
        return Err(invalid("лишние аргументы route-reconcile"));
    }
    let config = RouteConfig {
        interface: &interface,
        probe_address: &probe_address,
        table,
        user_pref,
        probe_pref,
        mark,
        mask,
        pbr_owner: &pbr_owner,
        probe_owner: &probe_owner,
    };
    let changed = reconcile_policy(&config).map_err(io::Error::other)?;
    println!("changed={}", u8::from(changed));
    Ok(())
}

pub(super) fn run_route_verify_command(args: &mut impl Iterator<Item = String>) -> io::Result<()> {
    let interface = required(args, "TUN-интерфейс")?;
    let probe_address = required(args, "IPv4-адрес probe")?;
    let table = parse_u32(&required(args, "номер таблицы")?)?;
    let user_pref = parse_u32(&required(args, "приоритет пользовательского правила")?)?;
    let probe_pref = parse_u32(&required(args, "приоритет probe-правила")?)?;
    let mark = parse_u32(&required(args, "метка fwmark")?)?;
    let mask = parse_u32(&required(args, "маска fwmark")?)?;
    let pbr_owner = PathBuf::from(required(args, "файл владельца PBR")?);
    let probe_owner = PathBuf::from(required(args, "файл владельца probe")?);
    if args.next().is_some() {
        return Err(invalid("лишние аргументы route-verify"));
    }
    let config = RouteConfig {
        interface: &interface,
        probe_address: &probe_address,
        table,
        user_pref,
        probe_pref,
        mark,
        mask,
        pbr_owner: &pbr_owner,
        probe_owner: &probe_owner,
    };
    println!(
        "ready={}",
        if verify_policy(&config).map_err(io::Error::other)? {
            1
        } else {
            0
        }
    );
    Ok(())
}

pub(super) fn acquire_global_lock() -> io::Result<Option<MutationLock>> {
    if env::var("Z2K_WARP_LOCK_HELD").as_deref() == Ok("1") {
        return Ok(None);
    }
    let path = env::var_os("Z2K_WARP_LOCK_DIR")
        .map(PathBuf::from)
        .unwrap_or_else(|| PathBuf::from("/tmp/z2k/warp/mutate.lock"));
    MutationLock::acquire(&path, Duration::from_secs(30))?
        .map(Some)
        .ok_or_else(|| io::Error::new(io::ErrorKind::WouldBlock, "операция WARP уже выполняется"))
}

pub(super) fn acquire_operation_lock(path: &std::path::Path) -> io::Result<MutationLock> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "путь действия WARP не содержит каталог",
        )
    })?;
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(io::ErrorKind::InvalidInput, "неверный путь действия WARP")
    })?;
    let lock_path = parent.join(format!(".{}.mutate.lock", name.to_string_lossy()));
    MutationLock::acquire(&lock_path, Duration::from_secs(5))?.ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::WouldBlock,
            "изменение намерения WARP уже выполняется",
        )
    })
}

pub(super) fn parse_pid(value: &str) -> io::Result<u32> {
    let pid = value
        .parse::<u32>()
        .map_err(|_| invalid("неверный PID действия WARP"))?;
    if pid == 0 {
        return Err(invalid("PID действия WARP должен быть положительным"));
    }
    Ok(pid)
}

pub(super) fn parse_u32(value: &str) -> io::Result<u32> {
    let parsed = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
        .map(|hex| u32::from_str_radix(hex, 16))
        .unwrap_or_else(|| value.parse::<u32>());
    parsed.map_err(|_| invalid("неверное целое число"))
}

pub(super) fn command_output(program: &str, args: &[&str]) -> io::Result<String> {
    let output = warp_controller::process::output(process::Command::new(program).args(args))?;
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

pub(super) fn command_error(program: &str, stderr: &[u8]) -> io::Error {
    io::Error::other(format!(
        "{} завершилась с ошибкой: {}",
        program,
        String::from_utf8_lossy(stderr).trim()
    ))
}

#[cfg(test)]
mod tests {
    use super::link_exists;

    #[test]
    fn вывод_busybox_ip_link_распознаёт_tun_warp() {
        let links = "1: lo: <LOOPBACK,UP,LOWER_UP> mtu 65536 qdisc noqueue state UNKNOWN qlen 1000\n12: z2ktun0: <POINTOPOINT,MULTICAST,NOARP,UP,LOWER_UP> mtu 1280 qdisc fq_codel state UNKNOWN qlen 500\n";
        assert!(link_exists(links, "z2ktun0").unwrap());
        assert!(!link_exists(links, "z2ktun1").unwrap());
    }
}
