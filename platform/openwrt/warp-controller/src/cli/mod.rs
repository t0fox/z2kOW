use std::{env, io, path::PathBuf, process, time::Duration};
use warp_controller::{
    config::{self, MatchOrder},
    devices, domain_state, list_ops, lists,
    lock::MutationLock,
    nft,
    operation::{self, OperationState},
    recovery, route_error,
    state::{
        EngineStatus, Observation, PolicyAction, ProcessStatus, observe_warp_process, plan_policy,
        read_engine_status, warp_process_pids,
    },
};

mod commands;
use commands::*;
pub fn run() -> io::Result<()> {
    let mut args = env::args().skip(1);
    match args.next().as_deref() {
        Some("nft-sync") => run_nft_sets_command(&mut args, true),
        Some("nft-sets-verify") => run_nft_sets_command(&mut args, false),
        Some("nft-set-count") => run_nft_set_count(&mut args),
        Some("nft-chain-clear") => run_nft_chain_clear(&mut args),
        Some("disable-state") => run_disable_state(&mut args),
        Some("status") => {
            if args.next().is_some() {
                return Err(invalid("лишние аргументы status"));
            }
            warp_controller::status::print_status()
        }
        Some("route-proof") => {
            if args.next().is_some() {
                return Err(invalid("лишние аргументы route-proof"));
            }
            warp_controller::status::print_routing_proofs()
        }
        Some("ipset") => warp_controller::service::ipset(&mut args),
        Some("reload-lists") => warp_controller::service::reload_lists(&mut args),
        Some("migrate") => warp_controller::service::migrate_lists(&mut args),
        Some("install") => warp_controller::service::install(&mut args),
        Some("register") => warp_controller::service::register(&mut args),
        Some("lifecycle") => {
            let code = warp_controller::service::user_lifecycle(&mut args)?;
            process::exit(code.clamp(0, 255) as i32);
        }
        Some("engine-refresh") => {
            let code = warp_controller::service::engine_refresh(&mut args)?;
            process::exit(code.clamp(0, 255) as i32);
        }
        Some("license") => {
            let code = warp_controller::service::license(&mut args)?;
            process::exit(code.clamp(0, 255) as i32);
        }
        Some("nft-mark-sync") => warp_controller::service::mark_rules(&mut args, true),
        Some("nft-mark-check") => warp_controller::service::mark_rules(&mut args, false),
        Some("health-check") => warp_controller::service::health_check(&mut args),
        Some("health-observation") => {
            if args.next().is_some() {
                return Err(invalid("лишние аргументы health-observation"));
            }
            println!("{}", warp_controller::health_observation::current()?);
            Ok(())
        }
        Some("event") => warp_controller::service::event(&mut args),
        Some("domain-procd-ready") => warp_controller::service::domain_procd_ready(&mut args),
        Some("nft-warp-remove") => run_nft_warp_remove(&mut args),
        Some("nft-fw4-forward-apply") => run_nft_fw4_forward_apply(&mut args),
        Some("nft-fw4-forward-verify") => run_nft_fw4_forward_verify(&mut args),
        Some("nft-fw4-forward-remove") => run_nft_fw4_forward_remove(&mut args),
        Some("interfaces") => run_interface_list(&mut args),
        Some("device-ips") => {
            let selected = required(&mut args, "файл выбранных устройств")?;
            let leases = required(&mut args, "файл DHCP leases")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы device-ips"));
            }
            for address in devices::resolve_selected_devices(selected.as_ref(), leases.as_ref())? {
                println!("{address}");
            }
            Ok(())
        }
        Some("nft-tun-apply") => {
            let _lock = acquire_global_lock()?;
            let family = required(&mut args, "семейство nft")?;
            let table = required(&mut args, "таблица nft")?;
            let mss_chain = required(&mut args, "MSS-цепочка")?;
            let forward_chain = required(&mut args, "forward-цепочка")?;
            let nat_chain = required(&mut args, "NAT-цепочка")?;
            let interface = required(&mut args, "TUN-интерфейс")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы nft-tun-apply"));
            }
            let batch = nft::render_tun_batch(
                &family,
                &table,
                &mss_chain,
                &forward_chain,
                &nat_chain,
                &interface,
            )?;
            nft::apply_transaction(&batch)
        }
        Some("nft-tun-verify") => {
            let ready = run_nft_tun_verify(&mut args)?;
            println!("ready={}", u8::from(ready));
            Ok(())
        }
        Some("nft-mark-apply") => run_nft_mark(&mut args, true).map(|_| ()),
        Some("nft-mark-verify") => {
            let ready = run_nft_mark(&mut args, false)?;
            println!("ready={}", u8::from(ready));
            Ok(())
        }
        Some("nft-domain-set-ensure") => {
            let _lock = acquire_global_lock()?;
            let family = required(&mut args, "семейство nft")?;
            let table = required(&mut args, "таблица nft")?;
            let set = required(&mut args, "набор доменных пар")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы nft-domain-set-ensure"));
            }
            let table_output = command_output("nft", &["list", "table", &family, &table])?;
            if nft::domain_pair_set_matches(&table_output, &family, &table, &set)?.is_some() {
                return Ok(());
            }
            let batch = nft::render_domain_pair_set_create_batch(&family, &table, &set)?;
            nft::apply_transaction(&batch)
        }
        Some("nft-domain-observer-apply") => {
            let _lock = acquire_global_lock()?;
            let family = required(&mut args, "семейство nft observer")?;
            let table = required(&mut args, "таблица nft observer")?;
            let output_chain = required(&mut args, "output chain observer")?;
            let forward_chain = required(&mut args, "forward chain observer")?;
            let group = required(&mut args, "NFLOG group")?;
            let devices = parse_interface_csv(&required(&mut args, "устройства observer")?)?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы nft-domain-observer-apply"));
            }

            let mut tables_output = command_output("nft", &["list", "tables"])?;
            let mut table_exists = nft_table_exists(&tables_output, &family, &table);
            if !table_exists {
                let batch = nft::render_domain_observer_table_create_batch(&family, &table)?;
                nft::apply_transaction(&batch)?;
                tables_output = command_output("nft", &["list", "tables"])?;
                table_exists = nft_table_exists(&tables_output, &family, &table);
                if !table_exists {
                    return Err(io::Error::new(
                        io::ErrorKind::NotFound,
                        "nft observer table отсутствует после создания",
                    ));
                }
            }
            let table_output = command_output("nft", &["list", "table", &family, &table])?;
            if !nft::domain_observer_table_owned(&table_output, &family, &table)? {
                return Err(io::Error::new(
                    io::ErrorKind::AlreadyExists,
                    "nft observer table занят другим владельцем",
                ));
            }
            let output_exists =
                nft::domain_observer_chain_owned(&table_output, &output_chain, "output")?.is_some();
            let forward_exists =
                nft::domain_observer_chain_owned(&table_output, &forward_chain, "forward")?
                    .is_some();

            let output_matches = if output_exists {
                let output =
                    command_output("nft", &["list", "chain", &family, &table, &output_chain])?;
                nft::domain_observer_chain_rules_match(&output, &output_chain, &devices, &group)
            } else {
                false
            };
            let forward_matches = if forward_exists {
                let output =
                    command_output("nft", &["list", "chain", &family, &table, &forward_chain])?;
                nft::domain_observer_chain_rules_match(&output, &forward_chain, &devices, &group)
            } else {
                false
            };
            if table_exists && output_matches && forward_matches {
                return Ok(());
            }
            let batch = nft::render_domain_observer_batch(&nft::DomainObserverConfig {
                family: &family,
                table: &table,
                output_chain: &output_chain,
                forward_chain: &forward_chain,
                group: &group,
                devices: &devices,
                table_exists,
                output_exists,
                forward_exists,
            })?;
            nft::apply_transaction(&batch)
        }
        Some("nft-domain-verify") => {
            let pair_family = required(&mut args, "семейство nft доменных пар")?;
            let pair_table = required(&mut args, "таблица nft доменных пар")?;
            let pair_set = required(&mut args, "набор nft доменных пар")?;
            let observer_family = required(&mut args, "семейство nft observer")?;
            let observer_table = required(&mut args, "таблица nft observer")?;
            let output_chain = required(&mut args, "output chain observer")?;
            let forward_chain = required(&mut args, "forward chain observer")?;
            let group = required(&mut args, "NFLOG group")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы nft-domain-verify"));
            }
            let ready = nft::verify_domain_observer(&nft::DomainVerifyConfig {
                pair_family: &pair_family,
                pair_table: &pair_table,
                pair_set: &pair_set,
                observer_family: &observer_family,
                observer_table: &observer_table,
                output_chain: &output_chain,
                forward_chain: &forward_chain,
                group: &group,
            })?;
            println!("ready={}", u8::from(ready));
            Ok(())
        }
        Some("nft-domain-remove") => {
            let _lock = acquire_global_lock()?;
            let observer_family = required(&mut args, "семейство nft observer")?;
            let observer_table = required(&mut args, "таблица nft observer")?;
            let pair_family = required(&mut args, "семейство nft доменных пар")?;
            let pair_table = required(&mut args, "таблица nft доменных пар")?;
            let pair_set = required(&mut args, "набор nft доменных пар")?;
            let full = parse_bool(&required(&mut args, "полное удаление")?)?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы nft-domain-remove"));
            }
            remove_domain_nft_state(
                &observer_family,
                &observer_table,
                &pair_family,
                &pair_table,
                &pair_set,
                full,
            )
        }
        Some("route-apply") => run_route_command(&mut args, true),
        Some("route-remove") => run_route_command(&mut args, false),
        Some("route-remove-owned") => run_route_remove_owned_command(&mut args),
        Some("route-reconcile") => run_route_reconcile_command(&mut args),
        Some("route-verify") => run_route_verify_command(&mut args),
        Some("list-save") => {
            let _lock = acquire_global_lock()?;
            let dir = required(&mut args, "каталог списков")?;
            let name = required(&mut args, "имя списка")?;
            let mode = required(&mut args, "режим сохранения")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы list-save"));
            }
            let result = list_ops::save_list(dir.as_ref(), &name, &mode, io::stdin().lock())?;
            println!(
                "saved={} saved_ip={} saved_domain={} skipped_invalid={}",
                result.saved, result.saved_ip, result.saved_domain, result.skipped_invalid
            );
            Ok(())
        }
        Some("list-migrate") => {
            let _lock = acquire_global_lock()?;
            let user_dir = required(&mut args, "каталог пользовательских списков")?;
            let games_dir = required(&mut args, "каталог игровых списков")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы list-migrate"));
            }
            list_ops::migrate_lists(user_dir.as_ref(), games_dir.as_ref())
        }
        Some("list-delete") => {
            let _lock = acquire_global_lock()?;
            let dir = required(&mut args, "каталог списков")?;
            let name = required(&mut args, "имя списка")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы list-delete"));
            }
            list_ops::delete_list(dir.as_ref(), &name)
        }
        Some("list-user-toggle") => {
            let _lock = acquire_global_lock()?;
            let dir = required(&mut args, "каталог списков")?;
            let name = required(&mut args, "имя списка")?;
            let enabled = parse_bool(&required(&mut args, "состояние списка")?)?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы list-user-toggle"));
            }
            list_ops::toggle_user_list(dir.as_ref(), &name, enabled)
        }
        Some("list-game-toggle") => {
            let _lock = acquire_global_lock()?;
            let enabled_file = required(&mut args, "файл включённых игр")?;
            let games_dir = required(&mut args, "каталог игровых списков")?;
            let name = required(&mut args, "имя игры")?;
            let enabled = parse_bool(&required(&mut args, "состояние игры")?)?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы list-game-toggle"));
            }
            list_ops::toggle_game_list(enabled_file.as_ref(), games_dir.as_ref(), &name, enabled)
        }
        Some("devices-save") => {
            let _lock = acquire_global_lock()?;
            let dir = required(&mut args, "каталог списков")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы devices-save"));
            }
            let (entries, dropped) = list_ops::save_devices(dir.as_ref(), io::stdin().lock())?;
            println!("entries={entries} dropped={dropped}");
            Ok(())
        }
        Some("devices-toggle") => {
            let _lock = acquire_global_lock()?;
            let dir = required(&mut args, "каталог списков")?;
            let mac = required(&mut args, "MAC-адрес устройства")?;
            let enabled = parse_bool(&required(&mut args, "состояние устройства")?)?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы devices-toggle"));
            }
            list_ops::toggle_device(dir.as_ref(), &mac, enabled)
        }
        Some("domains-list") => {
            let user_dir = required(&mut args, "каталог пользовательских списков")?;
            let games_dir = required(&mut args, "каталог игровых списков")?;
            let enabled = required(&mut args, "файл включённых игр")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы domains-list"));
            }
            let domains = lists::load_active_domains(
                user_dir.as_ref(),
                games_dir.as_ref(),
                enabled.as_ref(),
            )?;
            for domain in domains
                .into_iter()
                .collect::<std::collections::BTreeSet<_>>()
            {
                println!("{domain}");
            }
            Ok(())
        }
        Some("policy-scope") => {
            let user_dir = required(&mut args, "каталог пользовательских списков")?;
            let games_dir = required(&mut args, "каталог игровых списков")?;
            let enabled = required(&mut args, "файл включённых игр")?;
            let devices = required(&mut args, "файл выбранных устройств")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы policy-scope"));
            }
            let scope = lists::policy_scope(
                user_dir.as_ref(),
                games_dir.as_ref(),
                enabled.as_ref(),
                devices.as_ref(),
            )?;
            println!("{}", scope.as_str());
            Ok(())
        }
        Some("domains-sync") => {
            let _lock = acquire_global_lock()?;
            let user_dir = required(&mut args, "каталог пользовательских списков")?;
            let games_dir = required(&mut args, "каталог игровых списков")?;
            let enabled = required(&mut args, "файл включённых игр")?;
            let rules = required(&mut args, "файл правил domains.v1")?;
            let error = required(&mut args, "файл ошибки domain observer")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы domains-sync"));
            }
            let domains = lists::load_active_domains(
                user_dir.as_ref(),
                games_dir.as_ref(),
                enabled.as_ref(),
            )?;
            let rendered = domain_state::sync_rules_file(rules.as_ref(), error.as_ref(), &domains)?;
            if let Some(error) = rendered.error {
                println!("error={error}");
            }
            Ok(())
        }
        Some("domains-error") => {
            let error = required(&mut args, "файл ошибки domain observer")?;
            let code = required(&mut args, "код ошибки domain observer")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы domains-error"));
            }
            domain_state::set_error_file(error.as_ref(), &code)
        }
        Some("route-error-set") => {
            let _lock = acquire_global_lock()?;
            let error = required(&mut args, "файл ошибки маршрутизации")?;
            let reason = required(&mut args, "код ошибки маршрутизации")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы route-error-set"));
            }
            route_error::set_if_absent(error.as_ref(), &reason)
        }
        Some("route-error-clear") => {
            let _lock = acquire_global_lock()?;
            let error = required(&mut args, "файл ошибки маршрутизации")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы route-error-clear"));
            }
            route_error::clear(error.as_ref())
        }
        Some("op-begin") => {
            let path = required(&mut args, "файл намерения WARP")?;
            let pid = parse_pid(&required(&mut args, "PID действия WARP")?)?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы op-begin"));
            }
            let _lock = acquire_operation_lock(path.as_ref())?;
            operation::begin(path.as_ref(), pid)
        }
        Some("op-current") => {
            let path = required(&mut args, "файл намерения WARP")?;
            let pid = parse_pid(&required(&mut args, "PID действия WARP")?)?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы op-current"));
            }
            let _lock = acquire_operation_lock(path.as_ref())?;
            let state = operation::current(path.as_ref(), pid);
            println!(
                "{}",
                match state {
                    OperationState::Current => "current",
                    OperationState::Superseded => "superseded",
                    OperationState::Unreadable => "unreadable",
                }
            );
            Ok(())
        }
        Some("op-clear") => {
            let path = required(&mut args, "файл намерения WARP")?;
            let pid = parse_pid(&required(&mut args, "PID действия WARP")?)?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы op-clear"));
            }
            let _lock = acquire_operation_lock(path.as_ref())?;
            operation::clear_if_owner(path.as_ref(), pid).map(|_| ())
        }
        Some("procd-recovery-claim") => {
            let path = required(&mut args, "файл маркера восстановления WARP")?;
            let timestamp = required(&mut args, "время попытки восстановления")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы procd-recovery-claim"));
            }
            println!(
                "{}",
                if recovery::claim(path.as_ref(), &timestamp)? {
                    "claimed"
                } else {
                    "exists"
                }
            );
            Ok(())
        }
        Some("procd-recovery-clear") => {
            let path = required(&mut args, "файл маркера восстановления WARP")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы procd-recovery-clear"));
            }
            recovery::clear(path.as_ref())
        }
        Some("register-due") => run_register_due(&mut args),
        Some("state-observe") => {
            let status = required(&mut args, "файл состояния WARP")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы state-observe"));
            }
            match read_engine_status(status.as_ref()) {
                EngineStatus::Ready { iface } => println!("ready {iface}"),
                EngineStatus::NotReady => println!("not-ready"),
                EngineStatus::Unreadable => println!("unreadable"),
            }
            Ok(())
        }
        Some("process-observe") => {
            let proc_root = required(&mut args, "корень procfs")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы process-observe"));
            }
            let status = observe_warp_process(proc_root.as_ref());
            println!(
                "{}",
                match status {
                    ProcessStatus::Present => "present",
                    ProcessStatus::Absent => "absent",
                    ProcessStatus::Unreadable => "unreadable",
                }
            );
            Ok(())
        }
        Some("process-pids") => {
            let proc_root = required(&mut args, "корень procfs")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы process-pids"));
            }
            match warp_process_pids(proc_root.as_ref()) {
                Observation::Known(pids) => {
                    for pid in pids {
                        println!("{pid}");
                    }
                    Ok(())
                }
                Observation::Unreadable => Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "список процессов WARP временно недоступен",
                )),
            }
        }
        Some("runtime-observe") => run_runtime_observe(&mut args),
        Some("ready-observe-since") => run_ready_observe_since(&mut args),
        Some("health-plan") => run_health_plan(&mut args),
        Some("boot-plan") => run_boot_plan(&mut args),
        Some("service-plan") => run_service_plan(&mut args),
        Some("policy-plan") => {
            let enabled = parse_policy_observation(
                &required(&mut args, "состояние WARP")?,
                "enabled",
                "disabled",
            )?;
            let engine = parse_policy_observation(
                &required(&mut args, "состояние движка")?,
                "ready",
                "not-ready",
            )?;
            let policy = parse_policy_observation(
                &required(&mut args, "состояние PBR")?,
                "present",
                "absent",
            )?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы policy-plan"));
            }
            let action = plan_policy(enabled, engine, policy);
            println!(
                "{}",
                match action {
                    PolicyAction::Defer => "defer",
                    PolicyAction::Noop => "noop",
                    PolicyAction::ApplyPolicy => "apply",
                    PolicyAction::RemovePolicy => "remove",
                }
            );
            Ok(())
        }
        Some("lock-acquire") => {
            let pid = required(&mut args, "PID владельца lock")?
                .parse::<u32>()
                .map_err(|_| invalid("неверный PID владельца lock"))?;
            let wait = required(&mut args, "время ожидания lock")?
                .parse::<u64>()
                .map_err(|_| invalid("неверное время ожидания lock"))?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы lock-acquire"));
            }
            let path = env::var_os("Z2K_WARP_LOCK_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/tmp/z2k/warp/mutate.lock"));
            if !MutationLock::acquire_for_process(&path, pid, Duration::from_secs(wait))? {
                return Err(io::Error::new(
                    io::ErrorKind::WouldBlock,
                    "операция WARP уже выполняется",
                ));
            }
            Ok(())
        }
        Some("lock-release") => {
            let pid = required(&mut args, "PID владельца lock")?
                .parse::<u32>()
                .map_err(|_| invalid("неверный PID владельца lock"))?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы lock-release"));
            }
            let path = env::var_os("Z2K_WARP_LOCK_DIR")
                .map(PathBuf::from)
                .unwrap_or_else(|| PathBuf::from("/tmp/z2k/warp/mutate.lock"));
            if !MutationLock::release_for_process(&path, pid)? {
                return Err(io::Error::new(
                    io::ErrorKind::PermissionDenied,
                    "текущий процесс не владеет lock WARP",
                ));
            }
            Ok(())
        }
        Some("config-read") => {
            let path = required(&mut args, "файл конфигурации")?;
            let key = required(&mut args, "ключ конфигурации")?;
            let default = required(&mut args, "значение по умолчанию")?;
            let order = match required(&mut args, "порядок совпадений")?.as_str() {
                "first" => MatchOrder::First,
                "last" => MatchOrder::Last,
                _ => return Err(invalid("порядок совпадений должен быть first или last")),
            };
            if args.next().is_some() {
                return Err(invalid("лишние аргументы config-read"));
            }
            println!(
                "{}",
                config::read_value(path.as_ref(), &key, &default, order)?
            );
            Ok(())
        }
        Some("warp-flag-set") => {
            let path = required(&mut args, "файл конфигурации WARP")?;
            let value = required(&mut args, "значение флага WARP")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы warp-flag-set"));
            }
            config::set_warp_enabled(path.as_ref(), &value)
        }
        Some("config-flag-set") => {
            let path = required(&mut args, "файл конфигурации WARP")?;
            let key = required(&mut args, "ключ настройки WARP")?;
            let value = required(&mut args, "значение флага WARP")?;
            if args.next().is_some() {
                return Err(invalid("лишние аргументы config-flag-set"));
            }
            config::set_config_flag(path.as_ref(), &key, &value)
        }
        Some("version") => {
            println!("{}", env!("CARGO_PKG_VERSION"));
            Ok(())
        }
        _ => Err(invalid("неизвестная команда контроллера WARP")),
    }
}
