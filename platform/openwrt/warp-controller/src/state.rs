use std::{
    fs,
    io::{ErrorKind, Read},
    os::unix::fs::MetadataExt,
    path::Path,
    time::UNIX_EPOCH,
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum Observation<T> {
    Known(T),
    Unreadable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PolicyAction {
    Defer,
    Noop,
    ApplyPolicy,
    RemovePolicy,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum EngineStatus {
    Ready { iface: String },
    NotReady,
    Unreadable,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ProcessStatus {
    Present,
    Absent,
    Unreadable,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub enum RuntimeReadiness {
    Ready { iface: String },
    NotReady,
    Unreadable,
}

pub fn runtime_readiness(
    process: ProcessStatus,
    engine: EngineStatus,
    iface_present: Option<bool>,
) -> RuntimeReadiness {
    match process {
        ProcessStatus::Absent => return RuntimeReadiness::NotReady,
        ProcessStatus::Unreadable => return RuntimeReadiness::Unreadable,
        ProcessStatus::Present => {}
    }

    match engine {
        EngineStatus::NotReady => RuntimeReadiness::NotReady,
        EngineStatus::Unreadable => RuntimeReadiness::Unreadable,
        EngineStatus::Ready { iface } => match iface_present {
            Some(true) => RuntimeReadiness::Ready { iface },
            Some(false) => RuntimeReadiness::NotReady,
            None => RuntimeReadiness::Unreadable,
        },
    }
}

pub fn observe_warp_process(proc_root: &Path) -> ProcessStatus {
    let (pids, unreadable) = find_warp_pids(proc_root);
    if !pids.is_empty() {
        ProcessStatus::Present
    } else if unreadable {
        ProcessStatus::Unreadable
    } else {
        ProcessStatus::Absent
    }
}

pub fn warp_process_pids(proc_root: &Path) -> Observation<Vec<String>> {
    let (pids, unreadable) = find_warp_pids(proc_root);
    if unreadable {
        Observation::Unreadable
    } else {
        Observation::Known(pids)
    }
}

fn find_warp_pids(proc_root: &Path) -> (Vec<String>, bool) {
    let Ok(entries) = fs::read_dir(proc_root) else {
        return (Vec::new(), true);
    };
    let mut pids = Vec::new();
    let mut unreadable = false;
    for entry in entries {
        let entry = match entry {
            Ok(entry) => entry,
            Err(_) => {
                unreadable = true;
                continue;
            }
        };
        let pid = entry.file_name();
        let pid = pid.to_string_lossy();
        if pid.is_empty() || !pid.bytes().all(|byte| byte.is_ascii_digit()) {
            continue;
        }

        let comm = match fs::read_to_string(entry.path().join("comm")) {
            Ok(comm) => comm,
            Err(error) if error.kind() == ErrorKind::NotFound => continue,
            Err(_) => {
                unreadable = true;
                continue;
            }
        };
        if comm.trim_end_matches(['\r', '\n']) != "z2k-warpd" {
            continue;
        }

        let cmdline = match fs::read(entry.path().join("cmdline")) {
            Ok(cmdline) => cmdline,
            Err(error) if error.kind() == ErrorKind::NotFound => continue,
            Err(_) => {
                unreadable = true;
                continue;
            }
        };
        if cmdline.split(|byte| *byte == 0).any(|arg| arg == b"run") {
            pids.push(pid.into_owned());
        }
    }
    (pids, unreadable)
}

pub fn read_engine_status(path: &Path) -> EngineStatus {
    let Ok(contents) = fs::read(path) else {
        return EngineStatus::Unreadable;
    };
    parse_engine_status(&contents)
}

pub fn read_engine_status_snapshot(path: &Path) -> (EngineStatus, Option<u64>) {
    let Ok(file) = fs::File::open(path) else {
        return (EngineStatus::Unreadable, None);
    };
    read_engine_status_file(file)
}

pub fn read_engine_status_file(mut file: fs::File) -> (EngineStatus, Option<u64>) {
    let Ok(before) = file.metadata() else {
        return (EngineStatus::Unreadable, None);
    };
    let mut contents = Vec::new();
    if file.read_to_end(&mut contents).is_err() {
        return (EngineStatus::Unreadable, None);
    }
    let Ok(after) = file.metadata() else {
        return (EngineStatus::Unreadable, None);
    };
    if before.len() != after.len()
        || before.mtime() != after.mtime()
        || before.mtime_nsec() != after.mtime_nsec()
        || before.ctime() != after.ctime()
        || before.ctime_nsec() != after.ctime_nsec()
    {
        return (EngineStatus::Unreadable, None);
    }
    let Some(modified) = after
        .modified()
        .ok()
        .and_then(|modified| modified.duration_since(UNIX_EPOCH).ok())
        .map(|modified| modified.as_secs())
    else {
        return (EngineStatus::Unreadable, None);
    };
    (parse_engine_status(&contents), Some(modified))
}

fn parse_engine_status(contents: &[u8]) -> EngineStatus {
    let Ok(status) = serde_json::from_slice::<serde_json::Value>(contents) else {
        return EngineStatus::Unreadable;
    };
    match status.get("ready").and_then(serde_json::Value::as_bool) {
        Some(false) => EngineStatus::NotReady,
        Some(true) => match status.get("iface").and_then(serde_json::Value::as_str) {
            Some(iface) if !iface.is_empty() => EngineStatus::Ready {
                iface: iface.to_owned(),
            },
            _ => EngineStatus::Unreadable,
        },
        None => EngineStatus::Unreadable,
    }
}

pub fn plan_policy(
    enabled: Observation<bool>,
    engine_ready: Observation<bool>,
    policy_present: Observation<bool>,
) -> PolicyAction {
    let Observation::Known(enabled) = enabled else {
        return PolicyAction::Defer;
    };
    let Observation::Known(policy_present) = policy_present else {
        return PolicyAction::Defer;
    };

    if !enabled {
        return if policy_present {
            PolicyAction::RemovePolicy
        } else {
            PolicyAction::Noop
        };
    }
    let Observation::Known(engine_ready) = engine_ready else {
        return PolicyAction::Defer;
    };
    if !engine_ready {
        return if policy_present {
            PolicyAction::RemovePolicy
        } else {
            PolicyAction::Noop
        };
    }

    if policy_present {
        PolicyAction::Noop
    } else {
        PolicyAction::ApplyPolicy
    }
}
