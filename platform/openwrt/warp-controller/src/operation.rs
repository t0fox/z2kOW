use std::{
    fs::{self, OpenOptions},
    io::{self, ErrorKind, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum OperationState {
    Current,
    Superseded,
    Unreadable,
}

pub fn begin(path: &Path, pid: u32) -> io::Result<()> {
    if pid == 0 {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "PID действия WARP должен быть положительным",
        ));
    }
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "путь действия WARP не содержит каталог",
        )
    })?;
    fs::create_dir_all(parent)?;
    let contents = format!("{pid}\n");
    if fs::read(path).is_ok_and(|existing| existing == contents.as_bytes()) {
        return Ok(());
    }

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

pub fn current(path: &Path, pid: u32) -> OperationState {
    match fs::read_to_string(path) {
        Err(error) if error.kind() == ErrorKind::NotFound => OperationState::Current,
        Err(_) => OperationState::Unreadable,
        Ok(contents) => {
            let owner = contents.trim_end_matches(['\n', '\r']);
            match owner.parse::<u32>() {
                Ok(owner) if owner == pid => OperationState::Current,
                Ok(_) => OperationState::Superseded,
                Err(_) => OperationState::Unreadable,
            }
        }
    }
}

pub fn clear_if_owner(path: &Path, pid: u32) -> io::Result<bool> {
    if pid == 0 {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "PID действия WARP должен быть положительным",
        ));
    }
    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == ErrorKind::NotFound => return Ok(false),
        Err(error) => return Err(error),
    };
    if contents.trim_end_matches(['\n', '\r']) != pid.to_string() {
        return Ok(false);
    }
    match fs::remove_file(path) {
        Ok(()) => {
            sync_parent(path)?;
            Ok(true)
        }
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(false),
        Err(error) => Err(error),
    }
}

fn temporary_path(path: &Path) -> io::Result<PathBuf> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "путь действия WARP не содержит каталог",
        )
    })?;
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(ErrorKind::InvalidInput, "неверный путь действия WARP"))?;
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
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            ErrorKind::InvalidInput,
            "путь действия WARP не содержит каталог",
        )
    })?;
    fs::File::open(parent)?.sync_all()
}
