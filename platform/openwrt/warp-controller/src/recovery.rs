use std::{
    fs::{self, OpenOptions},
    io::{self, ErrorKind, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::{Duration, SystemTime, UNIX_EPOCH},
};

use crate::lock::MutationLock;

pub fn claim(path: &Path, timestamp: &str) -> io::Result<bool> {
    if timestamp.is_empty() || !timestamp.bytes().all(|byte| byte.is_ascii_digit()) {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "неверное время попытки восстановления WARP",
        ));
    }
    let parent = parent(path)?;
    fs::create_dir_all(parent)?;
    let _lock = acquire_lock(path)?;
    match fs::symlink_metadata(path) {
        Ok(_) => return Ok(false),
        Err(error) if error.kind() == ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    let temporary = temporary_path(path)?;
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o666)
        .open(&temporary)?;
    let result = (|| {
        writeln!(file, "attempted {timestamp}")?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)?;
        sync_parent(path)
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result.map(|()| true)
}

pub fn clear(path: &Path) -> io::Result<()> {
    let parent = parent(path)?;
    match fs::symlink_metadata(parent) {
        Ok(_) => {}
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(()),
        Err(error) => return Err(error),
    }
    let _lock = acquire_lock(path)?;
    match fs::remove_file(path) {
        Ok(()) => sync_parent(path),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(()),
        Err(error) => Err(error),
    }
}

fn acquire_lock(path: &Path) -> io::Result<MutationLock> {
    let parent = parent(path)?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(ErrorKind::InvalidInput, "неверный путь маркера WARP"))?;
    let lock_path = parent.join(format!(".{}.mutate.lock", name.to_string_lossy()));
    MutationLock::acquire(&lock_path, Duration::from_secs(5))?.ok_or_else(|| {
        io::Error::new(
            ErrorKind::WouldBlock,
            "изменение маркера восстановления WARP уже выполняется",
        )
    })
}

fn parent(path: &Path) -> io::Result<&Path> {
    path.parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .or(Some(Path::new(".")))
        .ok_or_else(|| io::Error::new(ErrorKind::InvalidInput, "неверный путь маркера WARP"))
}

fn temporary_path(path: &Path) -> io::Result<PathBuf> {
    let parent = parent(path)?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(ErrorKind::InvalidInput, "неверный путь маркера WARP"))?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    Ok(parent.join(format!(
        ".{}.new.{}.{nonce}",
        name.to_string_lossy(),
        std::process::id()
    )))
}

fn sync_parent(path: &Path) -> io::Result<()> {
    fs::File::open(parent(path)?)?.sync_all()
}
