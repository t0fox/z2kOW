use std::{
    fs::{self, OpenOptions},
    io::{self, Read, Write},
    os::unix::fs::{MetadataExt, PermissionsExt},
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use crate::{lists::validate_entries, lock::MutationLock};

pub struct SaveResult {
    pub saved: usize,
    pub saved_ip: usize,
    pub saved_domain: usize,
    pub skipped_invalid: usize,
}

pub fn migrate_lists(user_dir: &Path, games_dir: &Path) -> io::Result<()> {
    fs::create_dir_all(user_dir)?;
    let _lock = acquire_list_lock(user_dir)?;
    let _ = fs::create_dir_all(games_dir);

    let marker = user_dir.join(".legacy-aggregate-purged");
    let purged = match fs::metadata(&marker) {
        Ok(metadata) => metadata.is_file(),
        Err(error) if error.kind() == io::ErrorKind::NotFound => false,
        Err(error) => return Err(error),
    };
    if !purged {
        for name in [
            "game-warp-ips.txt",
            ".game-warp-ips.base",
            ".game-warp-ips.upstream",
            ".game-warp-ips.removed",
            ".game-warp-ips.san",
        ] {
            match fs::remove_file(user_dir.join(name)) {
                Ok(()) => {}
                Err(error) if error.kind() == io::ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
        match OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&marker)
        {
            Ok(file) => {
                file.sync_all()?;
                fs::File::open(user_dir)?.sync_all()?;
            }
            Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {}
            Err(error) => return Err(error),
        }
    }

    if let Ok(entries) = fs::read_dir(user_dir) {
        for entry in entries.flatten() {
            if !entry.file_type().is_ok_and(|kind| kind.is_file())
                || entry.path().extension().and_then(|value| value.to_str()) != Some("txt")
            {
                continue;
            }
            if let Ok(metadata) = entry.metadata() {
                let mut permissions = metadata.permissions();
                permissions.set_mode(0o644);
                let _ = fs::set_permissions(entry.path(), permissions);
            }
        }
    }
    Ok(())
}

pub fn save_list(
    dir: &Path,
    name: &str,
    mode: &str,
    mut input: impl Read,
) -> io::Result<SaveResult> {
    validate_name(name)?;
    if !matches!(mode, "replace" | "append" | "create") {
        return Err(invalid("неверный режим сохранения списка"));
    }
    fs::create_dir_all(dir)?;
    let _lock = acquire_list_lock(dir)?;
    let path = dir.join(format!("{name}.txt"));
    let reserved = mode == "create";
    if reserved {
        OpenOptions::new()
            .write(true)
            .create_new(true)
            .open(&path)
            .map_err(|error| {
                if error.kind() == io::ErrorKind::AlreadyExists {
                    invalid("список с таким именем уже существует")
                } else {
                    error
                }
            })?;
    }

    let result = (|| {
        let mut raw = String::new();
        input.read_to_string(&mut raw)?;
        let validation = validate_entries(&raw);
        let total = raw
            .lines()
            .map(|line| line.trim_matches([' ', '\t', '\r']))
            .filter(|line| !line.is_empty() && !line.starts_with('#'))
            .count();
        let saved = validation.addresses.len() + validation.domains.len();
        let mut contents = validation.save_text();
        if mode == "append" {
            let mut existing = fs::read_to_string(&path).or_else(|error| {
                if error.kind() == io::ErrorKind::NotFound {
                    Ok(String::new())
                } else {
                    Err(error)
                }
            })?;
            if !existing.is_empty() && !existing.ends_with('\n') {
                existing.push('\n');
            }
            contents = existing + &contents;
        }
        atomic_replace(&path, contents.as_bytes())?;
        Ok(SaveResult {
            saved,
            saved_ip: validation.addresses.len(),
            saved_domain: validation.domains.len(),
            skipped_invalid: total.saturating_sub(saved),
        })
    })();
    if result.is_err() && reserved {
        let _ = fs::remove_file(path);
    }
    result
}

pub fn delete_list(dir: &Path, name: &str) -> io::Result<()> {
    validate_name(name)?;
    fs::create_dir_all(dir)?;
    let _lock = acquire_list_lock(dir)?;
    let path = dir.join(format!("{name}.txt"));
    match fs::remove_file(&path) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    }
    remove_name(&dir.join(".disabled"), name)
}

pub fn toggle_user_list(dir: &Path, name: &str, enabled: bool) -> io::Result<()> {
    validate_name(name)?;
    fs::create_dir_all(dir)?;
    let _lock = acquire_list_lock(dir)?;
    let path = dir.join(format!("{name}.txt"));
    if !path.is_file() {
        return Err(io::Error::new(io::ErrorKind::NotFound, "список не найден"));
    }
    toggle_name(&dir.join(".disabled"), name, !enabled)
}

pub fn toggle_game_list(
    enabled_file: &Path,
    games_dir: &Path,
    name: &str,
    enabled: bool,
) -> io::Result<()> {
    validate_name(name)?;
    let dir = enabled_file
        .parent()
        .ok_or_else(|| invalid("файл выбора игр без каталога"))?;
    fs::create_dir_all(dir)?;
    let _lock = acquire_list_lock(dir)?;
    if !games_dir.join(format!("{name}.txt")).is_file() {
        return Err(io::Error::new(
            io::ErrorKind::NotFound,
            "игровой список не найден",
        ));
    }
    toggle_name(enabled_file, name, enabled)
}

pub fn save_devices(dir: &Path, mut input: impl Read) -> io::Result<(usize, usize)> {
    fs::create_dir_all(dir)?;
    let _lock = acquire_list_lock(dir)?;
    let mut raw = String::new();
    input.read_to_string(&mut raw)?;
    let mut output = String::new();
    let mut seen = std::collections::BTreeSet::new();
    let mut dropped = 0;
    for raw_line in raw.lines() {
        let line = raw_line.trim_matches([' ', '\t', '\r']);
        if line.is_empty() || line.starts_with('#') {
            continue;
        }
        let mac = line.to_ascii_lowercase().replace('-', ":");
        let normalized = if valid_mac(&mac) {
            Some(mac)
        } else {
            normalize_private_ip(line)
        };
        if let Some(value) = normalized {
            if seen.insert(value.clone()) {
                output.push_str(&value);
                output.push('\n');
            }
        } else {
            dropped += 1;
        }
    }
    atomic_replace(&dir.join("devices.txt"), output.as_bytes())?;
    Ok((seen.len(), dropped))
}

pub fn toggle_device(dir: &Path, mac: &str, enabled: bool) -> io::Result<()> {
    fs::create_dir_all(dir)?;
    let _lock = acquire_list_lock(dir)?;
    let mac = mac.to_ascii_lowercase().replace('-', ":");
    if !valid_mac(&mac) {
        return Err(invalid("неверный MAC-адрес устройства"));
    }
    let path = dir.join("devices.txt");
    let existing = fs::read_to_string(&path).or_else(|error| {
        if error.kind() == io::ErrorKind::NotFound {
            Ok(String::new())
        } else {
            Err(error)
        }
    })?;
    let mut contents = String::new();
    for line in existing.split_terminator('\n') {
        let normalized = line
            .trim_matches([' ', '\t', '\r'])
            .to_ascii_lowercase()
            .replace('-', ":");
        if normalized != mac {
            contents.push_str(line);
            contents.push('\n');
        }
    }
    if enabled {
        contents.push_str(&mac);
        contents.push('\n');
    }
    atomic_replace(&path, contents.as_bytes())
}

fn acquire_list_lock(dir: &Path) -> io::Result<crate::lock::MutationLock> {
    MutationLock::acquire(
        &dir.join(".controller-lists.lock"),
        std::time::Duration::from_secs(30),
    )?
    .ok_or_else(|| io::Error::new(io::ErrorKind::WouldBlock, "списки заняты другим действием"))
}

fn validate_name(name: &str) -> io::Result<()> {
    if name.is_empty()
        || name.len() > 64
        || name.starts_with(['.', '-'])
        || name == "devices"
        || !name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
    {
        return Err(invalid("неверное имя списка"));
    }
    Ok(())
}

fn toggle_name(path: &Path, name: &str, wanted: bool) -> io::Result<()> {
    let mut names = fs::read_to_string(path)
        .or_else(|error| {
            if error.kind() == io::ErrorKind::NotFound {
                Ok(String::new())
            } else {
                Err(error)
            }
        })?
        .lines()
        .map(str::to_owned)
        .filter(|value| value != name)
        .collect::<Vec<_>>();
    if wanted {
        names.push(name.to_owned());
    }
    let contents = if names.is_empty() {
        String::new()
    } else {
        format!("{}\n", names.join("\n"))
    };
    atomic_replace(path, contents.as_bytes())
}

fn remove_name(path: &Path, name: &str) -> io::Result<()> {
    match fs::metadata(path) {
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    }
    toggle_name(path, name, false)
}

fn atomic_replace(path: &Path, contents: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .ok_or_else(|| invalid("файл списка без каталога"))?;
    fs::create_dir_all(parent)?;
    let old = match fs::metadata(path) {
        Ok(metadata) => Some(metadata),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) => return Err(error),
    };
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| invalid("неверный путь списка"))?;
    let temp = PathBuf::from(parent).join(format!(".{name}.tmp.{}.{nonce}", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temp)?;
    let write_result = (|| {
        file.write_all(contents)?;
        file.sync_all()?;
        if let Some(metadata) = &old {
            let (uid, gid) = effective_ids()?;
            if metadata.uid() != uid || metadata.gid() != gid {
                let owner = format!("{}:{}", metadata.uid(), metadata.gid());
                let status = std::process::Command::new("chown")
                    .arg(owner)
                    .arg(&temp)
                    .status()?;
                if !status.success() {
                    return Err(io::Error::other(
                        "не удалось сохранить владельца файла списка",
                    ));
                }
            }
        }
        let mode = old
            .as_ref()
            .map(|metadata| metadata.permissions().mode() & 0o777)
            .unwrap_or(0o644);
        file.set_permissions(fs::Permissions::from_mode(mode))?;
        drop(file);
        fs::rename(&temp, path)?;
        fs::File::open(parent)?.sync_all()?;
        Ok(())
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(temp);
    }
    write_result
}

fn effective_ids() -> io::Result<(u32, u32)> {
    let status = fs::read_to_string("/proc/self/status")?;
    let mut uid = None;
    let mut gid = None;
    for line in status.lines() {
        if let Some(values) = line.strip_prefix("Uid:") {
            uid = values
                .split_whitespace()
                .next()
                .and_then(|value| value.parse().ok());
        } else if let Some(values) = line.strip_prefix("Gid:") {
            gid = values
                .split_whitespace()
                .next()
                .and_then(|value| value.parse().ok());
        }
    }
    match (uid, gid) {
        (Some(uid), Some(gid)) => Ok((uid, gid)),
        _ => Err(io::Error::new(
            io::ErrorKind::InvalidData,
            "не удалось прочитать владельца процесса",
        )),
    }
}

fn valid_mac(value: &str) -> bool {
    let octets: Vec<&str> = value.split(':').collect();
    octets.len() == 6
        && octets
            .iter()
            .all(|part| part.len() == 2 && part.bytes().all(|byte| byte.is_ascii_hexdigit()))
}

fn normalize_private_ip(value: &str) -> Option<String> {
    let fields: Vec<&str> = value.split('.').collect();
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

fn invalid(message: &str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}
