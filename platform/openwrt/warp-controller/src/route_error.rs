use std::{
    fs::{self, OpenOptions},
    io::{self, ErrorKind, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

pub fn set_if_absent(path: &Path, reason: &str) -> io::Result<()> {
    validate_reason(reason)?;
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "путь ошибки маршрутизации не содержит каталог",
        )
    })?;
    fs::create_dir_all(parent)?;

    match fs::read(path) {
        Ok(contents) if !contents.is_empty() => return Ok(()),
        Ok(_) => {}
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    write(path, reason)
}

pub fn set(path: &Path, reason: &str) -> io::Result<()> {
    validate_reason(reason)?;
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "путь ошибки маршрутизации не содержит каталог",
        )
    })?;
    fs::create_dir_all(parent)?;
    write(path, reason)
}

fn validate_reason(reason: &str) -> io::Result<()> {
    if reason.is_empty()
        || reason.len() > 128
        || !reason.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || byte == b'-' || byte == b'_'
        })
    {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "неверный код ошибки маршрутизации",
        ));
    }
    Ok(())
}

fn write(path: &Path, reason: &str) -> io::Result<()> {
    let timestamp = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    let contents = format!("{reason} {timestamp}\n");
    let temporary = temporary_path(path)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let result = (|| {
        file.write_all(contents.as_bytes())?;
        file.sync_all()?;
        file.set_permissions(fs::Permissions::from_mode(0o600))?;
        drop(file);
        fs::rename(&temporary, path)?;
        sync_parent(path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

pub fn clear(path: &Path) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "путь ошибки маршрутизации не содержит каталог",
        )
    })?;
    let prefix = temp_prefix(path)?;
    let entries = match fs::read_dir(parent) {
        Ok(entries) => entries,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    };
    let mut changed = false;
    match fs::remove_file(path) {
        Ok(()) => changed = true,
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }
    for entry in entries {
        let entry = entry?;
        if entry.file_name().to_string_lossy().starts_with(&prefix) {
            match fs::remove_file(entry.path()) {
                Ok(()) => changed = true,
                Err(error) if error.kind() == ErrorKind::NotFound => {}
                Err(error) => return Err(error),
            }
        }
    }
    if changed {
        sync_parent(path)?;
    }
    Ok(())
}

fn temporary_path(path: &Path) -> io::Result<PathBuf> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "путь ошибки маршрутизации не содержит каталог",
        )
    })?;
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "неверный путь ошибки маршрутизации",
        )
    })?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    Ok(parent.join(format!(
        "{}.new.{}.{nonce}",
        name.to_string_lossy(),
        std::process::id()
    )))
}

fn temp_prefix(path: &Path) -> io::Result<String> {
    let name = path.file_name().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "неверный путь ошибки маршрутизации",
        )
    })?;
    Ok(format!("{}.new.", name.to_string_lossy()))
}

fn sync_parent(path: &Path) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "путь ошибки маршрутизации не содержит каталог",
        )
    })?;
    fs::File::open(parent)?.sync_all()
}

#[cfg(test)]
mod tests {
    use super::set;
    use std::{
        fs,
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    #[test]
    fn set_заменяет_устаревшую_причину_на_текущую() {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "z2k-route-error-set-{}-{nonce}",
            std::process::id()
        ));
        let path: PathBuf = directory.join("route-error");
        fs::create_dir_all(&directory).unwrap();
        fs::write(&path, "old-error 1\n").unwrap();

        set(&path, "warp-disable-cleanup-failed").unwrap();

        let contents = fs::read_to_string(&path).unwrap();
        assert!(contents.starts_with("warp-disable-cleanup-failed "));
        fs::remove_dir_all(directory).unwrap();
    }
}
