use std::{
    env, fs, io,
    path::{Path, PathBuf},
    process::Command,
};

use crate::{
    config::{self, MatchOrder},
    nft::{self, MarkConfig},
    openwrt::{self, InterfaceKind},
    process,
    routing::{self, RouteConfig},
    state::{self, EngineStatus, ProcessStatus},
};

pub fn print_status() -> io::Result<()> {
    require_protocol_v1()?;
    println!("{}", render_status()?);
    Ok(())
}

pub fn print_routing_proofs() -> io::Result<()> {
    require_protocol_v1()?;
    let paths = Paths::from_env();
    let process = state::observe_warp_process(&paths.proc_root);
    let engine = state::read_engine_status(&paths.status);
    let ready = match (&engine, process) {
        (EngineStatus::Ready { iface }, ProcessStatus::Present) => {
            valid_interface(iface) && interface_present(iface) == Some(true)
        }
        _ => false,
    };
    let (proof, route_ready) = routing_proofs(&paths, ready);
    println!(
        "tunnel={} interface={} nft_mark={} tun={} pbr={} owner={} route_error={} route_error_at={}",
        proof.tunnel,
        proof.interface,
        proof.nft_mark,
        proof.tun,
        proof.pbr,
        proof.owner,
        one_line(&proof.error, 120),
        proof.error_at,
    );
    if route_ready {
        Ok(())
    } else {
        Err(io::Error::other("маршрутизация WARP не подтверждена"))
    }
}

pub(crate) fn require_protocol_v1() -> io::Result<()> {
    if env::var("Z2K_WARP_PROTOCOL_VERSION").as_deref() == Ok("1") {
        Ok(())
    } else {
        Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "неподдерживаемая версия протокола контроллера WARP",
        ))
    }
}

fn render_status() -> io::Result<String> {
    let paths = Paths::from_env();
    let enabled = config::read_value(&paths.config, "GAME_WARP_ENABLED", "", MatchOrder::First)
        .unwrap_or_default();
    let enabled_flag = enabled == "1";
    let installed = executable(&paths.warp_bin);
    let process = state::observe_warp_process(&paths.proc_root);
    let running = process == ProcessStatus::Present;
    let engine = state::read_engine_status(&paths.status);
    let ready = match (&engine, process) {
        (EngineStatus::Ready { iface }, ProcessStatus::Present) => {
            valid_interface(iface) && interface_present(iface) == Some(true)
        }
        _ => false,
    };
    let (route, route_ready) = routing_proofs(&paths, ready);
    let error = last_error(&paths, enabled_flag);
    let scope = if enabled_flag {
        lists::scope(&paths).unwrap_or_default()
    } else {
        "off".to_owned()
    };
    let state = if !enabled_flag {
        "off"
    } else if !error.is_empty() {
        "error"
    } else if ready && route_ready {
        "ready"
    } else if ready {
        "tunnel"
    } else if running {
        "connecting"
    } else {
        "recovering"
    };
    let entries = nft_count(&paths.nft_family, &paths.nft_table, &paths.dst_set).unwrap_or(0);
    let devices_count = nft_count(&paths.nft_family, &paths.nft_table, &paths.src_set).unwrap_or(0);
    let account_path = paths.device.parent().unwrap_or(Path::new("/"));
    let account = account_path.join("account.json");
    let license = account_path.join("license");
    let account_data = read_json(&account);
    let plan = account_data
        .get("account_type")
        .and_then(serde_json::Value::as_str)
        .filter(|value| {
            value
                .bytes()
                .all(|byte| byte.is_ascii_lowercase() || byte == b'_')
        })
        .unwrap_or("");
    let plan_error = u8::from(
        account_data
            .get("error")
            .and_then(serde_json::Value::as_str)
            .is_some_and(|value| !value.is_empty()),
    );
    let license_present = u8::from(fs::metadata(&license).is_ok_and(|meta| meta.len() > 0));
    let domain = domain_status(&paths, enabled_flag);
    let engine_data = read_json(&paths.status);
    let transport = json_string(&engine_data, "transport");
    let endpoint = json_string(&engine_data, "endpoint");
    let iface = json_string(&engine_data, "iface");
    let address = json_string(&engine_data, "addr");
    let memory = json_number(&engine_data, "mem_kb");
    let edge_colo = json_string(&engine_data, "edge_colo");
    let edge_country = json_string(&engine_data, "edge_country");
    let edge_rtt = json_number(&engine_data, "edge_rtt_ms");
    let edge_checked = json_number(&engine_data, "edge_checked_at");
    let edge_selection = json_string(&engine_data, "edge_selection");
    let wg_server_available = u8::from(
        openwrt::discover_interfaces(InterfaceKind::WireGuardServers)
            .is_ok_and(|interfaces| !interfaces.is_empty()),
    );

    Ok(format!(
        "installed={} enabled={} running={} ready={} route_ready={} state={} scope={} transport={} endpoint={} iface={} addr={} entries={} devices={} error={} mem={} plan={} plan_err={} license={} domain_active={} domain_rules={} domain_pairs={} domain_skipped={} domain_overflow={} domain_error={} edge_colo={} edge_country={} edge_rtt_ms={} edge_checked_at={} edge_selection={} tunnel={} interface={} nft_mark={} tun={} pbr={} owner={} route_error={} route_error_at={} wg_server_available={}",
        u8::from(installed),
        u8::from(enabled_flag),
        u8::from(running),
        u8::from(ready),
        u8::from(route_ready),
        state,
        scope,
        transport,
        endpoint,
        iface,
        address,
        entries,
        devices_count,
        one_line(&error, 120),
        memory,
        plan,
        plan_error,
        license_present,
        domain.active,
        domain.rules,
        domain.pairs,
        domain.skipped,
        domain.overflow,
        one_line(&domain.error, 120),
        edge_colo,
        edge_country,
        edge_rtt,
        edge_checked,
        edge_selection,
        route.tunnel,
        route.interface,
        route.nft_mark,
        route.tun,
        route.pbr,
        route.owner,
        one_line(&route.error, 120),
        route.error_at,
        wg_server_available,
    ))
}

fn routing_proofs(paths: &Paths, ready: bool) -> (RouteProof, bool) {
    let mut proof = RouteProof::default();
    (proof.error, proof.error_at) = read_route_error(&paths.route_error);
    if !ready {
        proof.tunnel = "not-ready";
        return (proof, false);
    }
    if !available("ip") || !available("nft") {
        proof.set_unavailable();
        return (proof, false);
    }
    proof.tunnel = "present";
    proof.interface = "present";

    let mark = verify_confirm(|| verify_mark(paths));
    proof.nft_mark = if mark { "present" } else { "absent" };
    let tun = verify_confirm(|| verify_tun(paths));
    proof.tun = if tun { "present" } else { "absent" };
    let pbr = verify_confirm(|| verify_pbr(paths));
    proof.pbr = if pbr { "present" } else { "absent" };
    proof.owner = if pbr { "present" } else { "absent" };

    let all_ready = mark && tun && pbr;
    (proof, all_ready)
}

pub fn is_route_ready() -> bool {
    let paths = Paths::from_env();
    let process = state::observe_warp_process(&paths.proc_root);
    let engine = state::read_engine_status(&paths.status);
    let ready = match (&engine, process) {
        (EngineStatus::Ready { iface }, ProcessStatus::Present) => {
            valid_interface(iface) && interface_present(iface) == Some(true)
        }
        _ => false,
    };
    routing_proofs(&paths, ready).1
}

pub(crate) fn verify_mark(paths: &Paths) -> io::Result<bool> {
    let inputs = crate::lists::load_mark_policy_inputs(
        &paths.user_lists,
        &paths.games,
        &paths.enabled_lists,
        &paths.devices,
    )?;
    let wdtt = config::read_value(&paths.config, "Z2K_WARP_WDTT", "0", MatchOrder::Last)? == "1";
    let tables = output("nft", &["list", "tables"])?;
    if !table_exists(&tables, &paths.nft_family, &paths.nft_table) {
        return Ok(false);
    }
    let table = output(
        "nft",
        &["list", "table", &paths.nft_family, &paths.nft_table],
    )?;
    let inventory = nft::parse_set_inventory(
        &table,
        &paths.nft_family,
        &paths.nft_table,
        &paths.dst_set,
        &paths.src_set,
    )?;
    let flags = nft::plan_mark_flags(
        inputs.scope.as_str(),
        wdtt,
        !inputs.domains.is_empty(),
        inventory
            .destinations
            .as_ref()
            .is_some_and(|destinations| !destinations.is_empty()),
    )?;
    let domain_active = !inputs.domains.is_empty() && inputs.scope.as_str() != "all";
    if domain_active
        && nft::domain_pair_set_matches(
            &table,
            &paths.nft_family,
            &paths.nft_table,
            &paths.domain_set,
        )?
        .is_none()
    {
        return Ok(false);
    }
    let lan = if inputs.scope.as_str() == "all" {
        openwrt::discover_interfaces(InterfaceKind::Lan)?
    } else {
        Vec::new()
    };
    let servers = openwrt::discover_interfaces(InterfaceKind::WireGuardServers)?;
    let clients = openwrt::discover_interfaces(InterfaceKind::WireGuardClients)?;
    let expected = nft::render_mark_batch(&MarkConfig {
        family: &paths.nft_family,
        table: &paths.nft_table,
        chain: &paths.mark_chain,
        destination_set: &paths.dst_set,
        source_set: &paths.src_set,
        domain_set: if domain_active { &paths.domain_set } else { "" },
        scope: inputs.scope.as_str(),
        wdtt_active: flags.wdtt_active,
        list_active: flags.list_active,
        lan_ifaces: &lan,
        wireguard_servers: &servers,
        wireguard_clients: &clients,
    })?;
    Ok(nft::mark_chain_matches(
        &table,
        &paths.nft_family,
        &paths.nft_table,
        &paths.mark_chain,
        &expected,
    )? == Some(true))
}

pub(crate) fn verify_tun(paths: &Paths) -> io::Result<bool> {
    let Some(iface) = ready_interface(&paths.status) else {
        return Ok(false);
    };
    let tables = output("nft", &["list", "tables"])?;
    if !table_exists(&tables, &paths.nft_family, &paths.nft_table) {
        return Ok(false);
    }
    let table = output(
        "nft",
        &["list", "table", &paths.nft_family, &paths.nft_table],
    )?;
    if !nft::tun_chains_match(
        &table,
        &paths.nft_family,
        &paths.nft_table,
        &paths.mss_chain,
        &paths.forward_chain,
        &paths.nat_chain,
        &iface,
    )? {
        return Ok(false);
    }
    let fw4 = output(
        "nft",
        &[
            "list",
            "chain",
            &paths.fw4_family,
            &paths.fw4_table,
            &paths.fw4_chain,
        ],
    )?;
    nft::fw4_forward_matches(
        &fw4,
        &paths.fw4_chain,
        &iface,
        &paths.mark_mask,
        &paths.mark,
        &paths.fw4_comment,
    )
}

pub(crate) fn verify_pbr(paths: &Paths) -> io::Result<bool> {
    let Some(iface) = ready_interface(&paths.status) else {
        return Ok(false);
    };
    let address = engine_string(&paths.status, "addr");
    if address.is_empty() {
        return Ok(false);
    }
    let config = RouteConfig {
        interface: &iface,
        probe_address: &address,
        table: paths.route_table,
        user_pref: paths.rule_pref,
        probe_pref: paths.probe_rule_pref,
        mark: parse_mark(&paths.mark).unwrap_or(0),
        mask: parse_mark(&paths.mark_mask).unwrap_or(0),
        pbr_owner: &paths.pbr_owner,
        probe_owner: &paths.probe_owner,
    };
    routing::verify_policy(&config).map_err(io::Error::other)
}

fn verify_confirm(mut verify: impl FnMut() -> io::Result<bool>) -> bool {
    match verify() {
        Ok(true) => true,
        Ok(false) | Err(_) => verify().unwrap_or(false),
    }
}

fn nft_count(family: &str, table: &str, set: &str) -> io::Result<usize> {
    let output = output("nft", &["list", "set", family, table, set])?;
    Ok(nft::count_ipv4_set_elements(&output))
}

fn table_exists(tables: &str, family: &str, table: &str) -> bool {
    tables.lines().any(|line| {
        let mut fields = line.split_whitespace();
        fields.next() == Some("table")
            && fields.next() == Some(family)
            && fields.next() == Some(table)
    })
}

fn output(program: &str, args: &[&str]) -> io::Result<String> {
    let result = process::output(Command::new(program).args(args))?;
    if !result.status.success() {
        return Err(io::Error::other(format!(
            "{program}: {}",
            String::from_utf8_lossy(&result.stderr).trim()
        )));
    }
    String::from_utf8(result.stdout)
        .map_err(|error| io::Error::new(io::ErrorKind::InvalidData, error))
}

fn available(program: &str) -> bool {
    process::output(Command::new(program).arg("--version")).is_ok()
}

fn executable(path: &Path) -> bool {
    use std::os::unix::fs::PermissionsExt;
    fs::metadata(path)
        .is_ok_and(|metadata| metadata.is_file() && metadata.permissions().mode() & 0o111 != 0)
}

fn interface_present(iface: &str) -> Option<bool> {
    match process::output(Command::new("ip").args(["link", "show", "dev", iface])) {
        Ok(result) => Some(result.status.success()),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(_) => None,
    }
}

fn valid_interface(iface: &str) -> bool {
    let Some(suffix) = iface.strip_prefix("z2ktun") else {
        return false;
    };
    (suffix.len() == 1 || suffix.len() == 2) && suffix.bytes().all(|byte| byte.is_ascii_digit())
}

fn ready_interface(path: &Path) -> Option<String> {
    match state::read_engine_status(path) {
        EngineStatus::Ready { iface } if valid_interface(&iface) => Some(iface),
        _ => None,
    }
}

fn engine_string(path: &Path, field: &str) -> String {
    json_string(&read_json(path), field)
}

fn read_json(path: &Path) -> serde_json::Value {
    fs::read(path)
        .ok()
        .and_then(|data| serde_json::from_slice(&data).ok())
        .unwrap_or(serde_json::Value::Null)
}

fn json_string(value: &serde_json::Value, field: &str) -> String {
    value
        .get(field)
        .and_then(serde_json::Value::as_str)
        .unwrap_or("")
        .to_owned()
}

fn json_number(value: &serde_json::Value, field: &str) -> String {
    value
        .get(field)
        .map(ToString::to_string)
        .unwrap_or_default()
}

fn last_error(paths: &Paths, enabled: bool) -> String {
    if !enabled {
        return String::new();
    }
    let status = read_json(&paths.status);
    if let Some(error) = status.get("last_error").and_then(serde_json::Value::as_str)
        && !error.is_empty()
    {
        return error.to_owned();
    }
    let Ok(log) = fs::read_to_string(&paths.log) else {
        return String::new();
    };
    let mut error = String::new();
    for line in log.lines() {
        if line.contains("z2k-warpd ") && line.contains(" starting") {
            error.clear();
        }
        if line.contains("fatal:") && line.contains("/dev/net/tun does not exist") {
            error = "tun_failed".into();
        } else if line.contains("fatal:") && line.contains("device.json:") {
            error = "register_blocked".into();
        }
    }
    error
}

struct RouteProof {
    tunnel: &'static str,
    interface: &'static str,
    nft_mark: &'static str,
    tun: &'static str,
    pbr: &'static str,
    owner: &'static str,
    error: String,
    error_at: String,
}

impl Default for RouteProof {
    fn default() -> Self {
        Self {
            tunnel: "not-observed",
            interface: "not-observed",
            nft_mark: "not-observed",
            tun: "not-observed",
            pbr: "not-observed",
            owner: "not-observed",
            error: "none".into(),
            error_at: "0".into(),
        }
    }
}

impl RouteProof {
    fn set_unavailable(&mut self) {
        self.tunnel = "unavailable";
        self.interface = "unavailable";
        self.nft_mark = "unavailable";
        self.tun = "unavailable";
        self.pbr = "unavailable";
        self.owner = "unavailable";
    }
}

fn read_route_error(path: &Path) -> (String, String) {
    let contents = fs::read_to_string(path).unwrap_or_default();
    let mut fields = contents.split_whitespace();
    let reason = fields
        .next()
        .filter(|value| !value.is_empty())
        .unwrap_or("none");
    let timestamp = fields.next().unwrap_or("0");
    (reason.to_owned(), timestamp.to_owned())
}

fn one_line(value: &str, max_chars: usize) -> String {
    value
        .chars()
        .map(|ch| if ch.is_whitespace() { '_' } else { ch })
        .take(max_chars)
        .collect()
}

struct DomainStatus {
    active: u8,
    rules: usize,
    pairs: usize,
    skipped: usize,
    overflow: usize,
    error: String,
}

fn domain_status(paths: &Paths, enabled: bool) -> DomainStatus {
    let status = read_json(&paths.domain_status);
    let mut active = u8::from(
        status
            .get("active")
            .and_then(serde_json::Value::as_bool)
            .unwrap_or(false),
    );
    let mut rules = json_usize(&status, "rules");
    let pairs = json_usize(&status, "pairs");
    let skipped = json_usize(&status, "skipped");
    let overflow = json_usize(&status, "overflow");
    let mut error = json_string(&status, "error");
    if let Ok(file_error) = fs::read_to_string(&paths.domain_error) {
        if !file_error.is_empty() {
            error = file_error.trim().to_owned();
            active = 0;
        }
    } else if !paths.domain_status.exists() && enabled {
        error = "observer-unavailable".into();
    }
    if let Ok(contents) = fs::read_to_string(&paths.domain_rules) {
        rules = contents.lines().skip(1).count();
    }
    if rules == 0 {
        active = 0;
        if !fs::read_to_string(&paths.domain_error).is_ok_and(|error| !error.is_empty()) {
            error.clear();
        }
    }
    DomainStatus {
        active,
        rules,
        pairs,
        skipped,
        overflow,
        error,
    }
}

fn json_usize(value: &serde_json::Value, field: &str) -> usize {
    value
        .get(field)
        .and_then(serde_json::Value::as_u64)
        .and_then(|number| usize::try_from(number).ok())
        .unwrap_or(0)
}

pub(crate) struct Paths {
    pub(crate) config: PathBuf,
    pub(crate) warp_bin: PathBuf,
    pub(crate) device: PathBuf,
    pub(crate) status: PathBuf,
    pub(crate) log: PathBuf,
    pub(crate) route_error: PathBuf,
    pub(crate) health_observation: PathBuf,
    pub(crate) proc_root: PathBuf,
    pub(crate) user_lists: PathBuf,
    pub(crate) games: PathBuf,
    pub(crate) enabled_lists: PathBuf,
    pub(crate) devices: PathBuf,
    domain_status: PathBuf,
    domain_error: PathBuf,
    domain_rules: PathBuf,
    pub(crate) pbr_owner: PathBuf,
    pub(crate) probe_owner: PathBuf,
    pub(crate) nft_family: String,
    pub(crate) nft_table: String,
    pub(crate) dst_set: String,
    pub(crate) src_set: String,
    pub(crate) domain_set: String,
    pub(crate) mark_chain: String,
    pub(crate) mss_chain: String,
    pub(crate) forward_chain: String,
    pub(crate) nat_chain: String,
    pub(crate) fw4_family: String,
    pub(crate) fw4_table: String,
    pub(crate) fw4_chain: String,
    pub(crate) fw4_comment: String,
    pub(crate) route_table: u32,
    pub(crate) rule_pref: u32,
    pub(crate) probe_rule_pref: u32,
    pub(crate) mark: String,
    pub(crate) mark_mask: String,
}

impl Paths {
    pub(crate) fn from_env() -> Self {
        let z2k_root = env_path("Z2K_ROOT", "/usr/lib/z2k");
        let z2k_etc = env_path("Z2K_ETC", "/etc/z2k");
        let z2k_tmp = env_path("Z2K_TMP", "/tmp/z2k");
        let state = env_path("Z2K_STATE", &z2k_etc.join("state").to_string_lossy());
        let list_root = env_path("Z2K_LISTS_DIR", &z2k_root.join("lists").to_string_lossy());
        let user_lists = env_path(
            "WARP_LISTS_DIR",
            &z2k_etc.join("user-lists/warp").to_string_lossy(),
        );
        let games = env_path(
            "WARP_GAMES_DIR",
            &list_root.join("warp/games").to_string_lossy(),
        );
        let device = env_path(
            "WARP_DEVICE",
            &state.join("warp/device.json").to_string_lossy(),
        );
        Self {
            config: env_path("CONFIG_FILE", &z2k_etc.join("config").to_string_lossy()),
            warp_bin: env_path(
                "WARP_BIN",
                &z2k_root
                    .join("platform/openwrt/bin/linux-unsupported/z2k-warpd")
                    .to_string_lossy(),
            ),
            device,
            status: env_path(
                "WARP_STATUS",
                &z2k_tmp.join("warp/status.json").to_string_lossy(),
            ),
            log: env_path(
                "WARP_LOG",
                &z2k_tmp.join("warp/warpd.log").to_string_lossy(),
            ),
            route_error: env_path(
                "WARP_ROUTE_ERROR_FILE",
                &z2k_tmp.join("warp/route-error").to_string_lossy(),
            ),
            health_observation: env_path(
                "WARP_HEALTH_OBSERVATION",
                &z2k_tmp
                    .join("warp/health-observation.json")
                    .to_string_lossy(),
            ),
            proc_root: env_path("Z2K_PROC_ROOT", "/proc"),
            user_lists: user_lists.clone(),
            games,
            enabled_lists: env_path(
                "WARP_ENABLED_FILE",
                &user_lists.join(".enabled").to_string_lossy(),
            ),
            devices: env_path(
                "WARP_DEVICES_FILE",
                &user_lists.join("devices.txt").to_string_lossy(),
            ),
            domain_status: env_path("WARP_DOMAIN_STATUS", "/tmp/z2k-warp/domain-status.json"),
            domain_error: env_path("WARP_DOMAIN_ERROR", "/tmp/z2k-warp/domain-setup-error"),
            domain_rules: env_path("WARP_DOMAIN_RULES", "/tmp/z2k-warp/domains.v1"),
            pbr_owner: env_path(
                "WARP_PBR_OWNER",
                &z2k_tmp.join("warp/pbr.owner").to_string_lossy(),
            ),
            probe_owner: env_path(
                "WARP_PROBE_OWNER",
                &z2k_tmp.join("warp/probe-route.owner").to_string_lossy(),
            ),
            nft_family: env_string("Z2K_WARP_NFT_FAMILY", "inet"),
            nft_table: env_string("Z2K_WARP_NFT_TABLE", "zapret2"),
            dst_set: env_string("WARP_SET", "z2k_warp_dst4"),
            src_set: env_string("WARP_SET_SRC", "z2k_warp_src4"),
            domain_set: env_string("WARP_DOMAIN_SET", "z2k_warp_domain4"),
            mark_chain: env_string("WARP_CHAIN_MARK", "z2k_warp_mark"),
            mss_chain: env_string("WARP_CHAIN_MSS", "z2k_warp_mss"),
            forward_chain: env_string("WARP_CHAIN_FWD", "z2k_warp_fwd"),
            nat_chain: env_string("WARP_CHAIN_NAT", "z2k_warp_nat"),
            fw4_family: env_string("WARP_FW4_FAMILY", "inet"),
            fw4_table: env_string("WARP_FW4_TABLE", "fw4"),
            fw4_chain: env_string("WARP_FW4_CHAIN", "forward"),
            fw4_comment: env_string("WARP_FW4_RULE_COMMENT", "!z2k: WARP forwarded traffic"),
            route_table: env_number("WARP_TABLE", 989),
            rule_pref: env_number("WARP_RULE_PREF", 500),
            probe_rule_pref: env_number("WARP_PROBE_RULE_PREF", 499),
            mark: env_string("WARP_MARK", "0x80000000"),
            mark_mask: env_string("WARP_MASK", "0x80000000"),
        }
    }
}

fn env_string(name: &str, default: &str) -> String {
    env::var(name).unwrap_or_else(|_| default.to_owned())
}

fn env_path(name: &str, default: &str) -> PathBuf {
    env::var_os(name)
        .map(PathBuf::from)
        .unwrap_or_else(|| default.into())
}

fn env_number(name: &str, default: u32) -> u32 {
    env::var(name)
        .ok()
        .and_then(|value| parse_mark(&value))
        .unwrap_or(default)
}

fn parse_mark(value: &str) -> Option<u32> {
    value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
        .map(|hex| u32::from_str_radix(hex, 16).ok())
        .unwrap_or_else(|| value.parse().ok())
}

mod lists {
    pub fn scope(paths: &super::Paths) -> io::Result<String> {
        let scope = crate::lists::policy_scope(
            &paths.user_lists,
            &paths.games,
            &paths.enabled_lists,
            &paths.devices,
        )?;
        Ok(match scope.as_str() {
            "all" => "all",
            "full" | "devices" => "devices",
            "lists" => "lists",
            _ => return Err(io::Error::other("неизвестная область WARP")),
        }
        .to_owned())
    }

    use std::io;
}

#[cfg(test)]
mod tests {
    use super::one_line;

    #[test]
    fn status_fields_are_single_line_and_bounded() {
        assert_eq!(
            one_line("temporary error\nwith details", 120),
            "temporary_error_with_details"
        );
        assert_eq!(one_line("abcdefgh", 5), "abcde");
    }
}
