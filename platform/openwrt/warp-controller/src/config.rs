use std::{
    fs::{self, OpenOptions},
    io::{self, ErrorKind, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    thread,
    time::{Duration, SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum MatchOrder {
    First,
    Last,
}

pub fn read_value(path: &Path, key: &str, default: &str, order: MatchOrder) -> io::Result<String> {
    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(default.to_owned()),
        Err(error) => return Err(error),
    };
    let mut value = None;
    for line in contents.split_terminator('\n') {
        let mut fields = line.split('=');
        if fields.next() != Some(key) {
            continue;
        }
        let candidate = fields
            .next()
            .unwrap_or_default()
            .chars()
            .filter(|character| !matches!(character, '"' | ' '))
            .collect::<String>();
        match order {
            MatchOrder::First => {
                return Ok(if candidate.is_empty() {
                    default.to_owned()
                } else {
                    candidate
                });
            }
            MatchOrder::Last => value = Some(candidate),
        }
    }
    Ok(value
        .filter(|value| !value.is_empty())
        .unwrap_or_else(|| default.to_owned()))
}

pub fn set_warp_enabled(path: &Path, value: &str) -> io::Result<()> {
    set_config_flag(path, "GAME_WARP_ENABLED", value)
}

pub fn set_config_flag(path: &Path, key: &str, value: &str) -> io::Result<()> {
    if !matches!(key, "GAME_WARP_ENABLED" | "Z2K_WARP_WDTT") {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "неверный ключ настройки WARP",
        ));
    }
    if !matches!(value, "0" | "1") {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "неверный флаг WARP: ожидается 0 или 1",
        ));
    }
    let metadata = fs::metadata(path)?;
    if !metadata.is_file() {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "файл конфигурации WARP не является обычным файлом",
        ));
    }

    let _lock = ConfigFlagLock::acquire(path)?;
    let original = fs::read(path)?;
    let updated = render_config_flag(&original, key, value);
    if updated == original {
        return Ok(());
    }
    atomic_write(path, &updated, metadata.permissions().mode() & 0o7777)
}

fn render_config_flag(contents: &[u8], key: &str, value: &str) -> Vec<u8> {
    let prefix = [key.as_bytes(), b"="].concat();
    let replacement = [prefix.as_slice(), value.as_bytes(), b"\n"].concat();
    let mut updated = Vec::with_capacity(contents.len() + replacement.len());
    let mut found = false;
    for line in contents.split_inclusive(|byte| *byte == b'\n') {
        let body = line.strip_suffix(b"\n").unwrap_or(line);
        if body.starts_with(&prefix) {
            updated.extend_from_slice(&replacement);
            found = true;
        } else {
            updated.extend_from_slice(line);
        }
    }
    if !found {
        if !updated.is_empty() && !updated.ends_with(b"\n") {
            updated.push(b'\n');
        }
        updated.extend_from_slice(&replacement);
    }
    updated
}

struct ConfigFlagLock {
    path: PathBuf,
}

impl ConfigFlagLock {
    fn acquire(config: &Path) -> io::Result<Self> {
        let mut lock_name = config.as_os_str().to_os_string();
        lock_name.push(".z2k-flaglock");
        let path = PathBuf::from(lock_name);
        for attempt in 0..100 {
            match fs::create_dir(&path) {
                Ok(()) => return Ok(Self { path }),
                Err(error) if error.kind() == ErrorKind::AlreadyExists => {
                    let stale = fs::metadata(&path)
                        .ok()
                        .and_then(|metadata| metadata.modified().ok())
                        .and_then(|modified| modified.elapsed().ok())
                        .is_some_and(|age| age >= Duration::from_secs(60));
                    if stale {
                        match fs::remove_dir(&path) {
                            Ok(()) => continue,
                            Err(remove_error) if remove_error.kind() == ErrorKind::NotFound => {
                                continue;
                            }
                            Err(_) => {}
                        }
                    }
                    if attempt == 99 {
                        return Err(io::Error::new(
                            ErrorKind::WouldBlock,
                            format!("config busy: {}", config.display()),
                        ));
                    }
                    thread::sleep(Duration::from_millis(20));
                }
                Err(error) => return Err(error),
            }
        }
        Err(io::Error::new(
            ErrorKind::WouldBlock,
            format!("config busy: {}", config.display()),
        ))
    }
}

impl Drop for ConfigFlagLock {
    fn drop(&mut self) {
        let _ = fs::remove_dir(&self.path);
    }
}

fn atomic_write(path: &Path, contents: &[u8], mode: u32) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "путь конфигурации WARP не содержит каталог",
        )
    })?;
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(ErrorKind::InvalidInput, "неверный путь конфигурации WARP")
    })?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary = parent.join(format!(
        ".{}.z2k-warp-flag.{}.{nonce}",
        name.to_string_lossy(),
        std::process::id()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let result = (|| {
        file.write_all(contents)?;
        file.sync_all()?;
        file.set_permissions(fs::Permissions::from_mode(mode))?;
        drop(file);
        fs::rename(&temporary, path)?;
        fs::File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

#[cfg(test)]
mod tests {
    use super::{MatchOrder, read_value};
    use std::{fs, path::PathBuf, time::SystemTime};

    #[test]
    fn parses_selected_key_without_shell_evaluation() {
        let path = std::env::temp_dir().join(format!(
            "z2k-warp-config-{}-{}",
            std::process::id(),
            SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        fs::write(&path, "KEY=first\nKEY=\" h2 \"\nOTHER=$(false)\n").unwrap();
        assert_eq!(
            read_value(&path, "KEY", "auto", MatchOrder::First).unwrap(),
            "first"
        );
        assert_eq!(
            read_value(&path, "KEY", "auto", MatchOrder::Last).unwrap(),
            "h2"
        );
        assert_eq!(
            read_value(
                &PathBuf::from("/path/that/does/not/exist"),
                "KEY",
                "auto",
                MatchOrder::Last
            )
            .unwrap(),
            "auto"
        );
        let _ = fs::remove_file(path);
    }
}
