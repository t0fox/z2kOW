use std::{
    fs, io,
    path::{Path, PathBuf},
    thread,
    time::{Duration, Instant, SystemTime, UNIX_EPOCH},
};

pub struct MutationLock {
    path: PathBuf,
    owner: String,
}

impl MutationLock {
    pub fn acquire(path: &Path, wait: Duration) -> io::Result<Option<Self>> {
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let owner = process_identity_for(std::process::id())?;
        let deadline = Instant::now() + wait;

        loop {
            match fs::create_dir(path) {
                Ok(()) => {
                    write_lock_owner(path, &owner)?;
                    return Ok(Some(Self {
                        path: path.to_owned(),
                        owner,
                    }));
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    if reap_if_stale(path)? {
                        continue;
                    }
                    if Instant::now() >= deadline {
                        return Ok(None);
                    }
                    thread::sleep(
                        Duration::from_millis(50)
                            .min(deadline.saturating_duration_since(Instant::now())),
                    );
                }
                Err(error) => return Err(error),
            }
        }
    }

    /// Acquire a lock on behalf of a live shell process. The shell keeps its
    /// PID as the lease owner while this short-lived CLI returns.
    pub fn acquire_for_process(path: &Path, pid: u32, wait: Duration) -> io::Result<bool> {
        if pid == 0 {
            return Err(io::Error::new(
                io::ErrorKind::InvalidInput,
                "PID владельца lock должен быть положительным",
            ));
        }
        if let Some(parent) = path.parent() {
            fs::create_dir_all(parent)?;
        }
        let owner = process_identity_for(pid)?;
        let deadline = Instant::now() + wait;
        loop {
            match fs::create_dir(path) {
                Ok(()) => {
                    write_lock_owner(path, &owner)?;
                    return Ok(true);
                }
                Err(error) if error.kind() == io::ErrorKind::AlreadyExists => {
                    if reap_if_stale(path)? {
                        continue;
                    }
                    if Instant::now() >= deadline {
                        return Ok(false);
                    }
                    thread::sleep(
                        Duration::from_millis(50)
                            .min(deadline.saturating_duration_since(Instant::now())),
                    );
                }
                Err(error) => return Err(error),
            }
        }
    }

    pub fn release_for_process(path: &Path, pid: u32) -> io::Result<bool> {
        let owner = process_identity_for(pid)?;
        if fs::read_to_string(path.join("owner")).ok().as_deref() != Some(owner.as_str()) {
            return Ok(false);
        }
        fs::remove_dir_all(path)?;
        Ok(true)
    }
}

fn write_lock_owner(path: &Path, owner: &str) -> io::Result<()> {
    let pid = owner
        .split_whitespace()
        .next()
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidData, "PID lock owner отсутствует"))?;
    if let Err(error) = fs::write(path.join("owner"), owner) {
        let _ = fs::remove_dir_all(path);
        return Err(error);
    }
    if let Err(error) = fs::write(path.join("pid"), pid) {
        let _ = fs::remove_dir_all(path);
        return Err(error);
    }
    Ok(())
}

impl Drop for MutationLock {
    fn drop(&mut self) {
        if fs::read_to_string(self.path.join("owner")).ok().as_deref() == Some(self.owner.as_str())
        {
            let _ = fs::remove_dir_all(&self.path);
        }
    }
}

fn process_identity_for(pid: u32) -> io::Result<String> {
    let stat = fs::read_to_string(format!("/proc/{pid}/stat"))?;
    let start = process_start_time(&stat).ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidData,
            "не удалось прочитать время запуска процесса",
        )
    })?;
    Ok(format!("{pid} {start}\n"))
}

fn process_start_time(stat: &str) -> Option<&str> {
    let (_, rest) = stat.rsplit_once(')')?;
    rest.split_whitespace().nth(19)
}

fn reap_if_stale(path: &Path) -> io::Result<bool> {
    let metadata = match fs::symlink_metadata(path) {
        Ok(metadata) => metadata,
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(true),
        Err(error) => return Err(error),
    };
    if !metadata.file_type().is_dir() {
        return Ok(false);
    }

    let owner_path = path.join("owner");
    let owner = match fs::read_to_string(&owner_path) {
        Ok(owner) => Some(owner),
        Err(error) if error.kind() == io::ErrorKind::NotFound => None,
        Err(error) if error.kind() == io::ErrorKind::PermissionDenied => return Ok(false),
        Err(error) => return Err(error),
    };
    let pid = match &owner {
        Some(owner) => {
            let mut fields = owner.split_whitespace();
            let (Some(pid), Some(start), None) = (fields.next(), fields.next(), fields.next())
            else {
                return Ok(false);
            };
            let Ok(pid) = pid.parse::<u32>() else {
                return Ok(false);
            };
            if pid == 0 || start.is_empty() {
                return Ok(false);
            }
            let stat_path = format!("/proc/{pid}/stat");
            let stale = match fs::read_to_string(stat_path) {
                Ok(stat) => process_start_time(&stat).is_some_and(|current| current != start),
                Err(error) if error.kind() == io::ErrorKind::NotFound => true,
                Err(error) if error.kind() == io::ErrorKind::PermissionDenied => false,
                Err(error) => return Err(error),
            };
            if !stale {
                return Ok(false);
            }
            fs::read_to_string(path.join("pid")).ok()
        }
        None => match fs::read_to_string(path.join("pid")) {
            Ok(pid) => {
                let Ok(pid_number) = pid.trim().parse::<u32>() else {
                    return Ok(false);
                };
                if pid_number == 0 {
                    return Ok(false);
                }
                match fs::read_to_string(format!("/proc/{pid_number}/stat")) {
                    Ok(_) => return Ok(false),
                    Err(error) if error.kind() == io::ErrorKind::NotFound => Some(pid),
                    Err(error) if error.kind() == io::ErrorKind::PermissionDenied => {
                        return Ok(false);
                    }
                    Err(error) => return Err(error),
                }
            }
            Err(error) if error.kind() == io::ErrorKind::NotFound => {
                let old_enough = metadata
                    .modified()
                    .ok()
                    .and_then(|modified| modified.elapsed().ok())
                    .is_some_and(|age| age >= Duration::from_secs(300));
                if !old_enough {
                    return Ok(false);
                }
                None
            }
            Err(error) if error.kind() == io::ErrorKind::PermissionDenied => return Ok(false),
            Err(error) => return Err(error),
        },
    };

    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let quarantine =
        path.with_file_name(format!(".warp-lock-stale-{}-{nonce}", std::process::id()));
    match fs::rename(path, &quarantine) {
        Ok(()) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => return Ok(true),
        Err(error) => return Err(error),
    }

    let owner_matches = match owner {
        Some(owner) => {
            fs::read_to_string(quarantine.join("owner")).ok().as_deref() == Some(owner.as_str())
        }
        None => {
            !quarantine.join("owner").exists()
                && fs::read_to_string(quarantine.join("pid")).ok() == pid
        }
    };
    if !owner_matches {
        let _ = fs::rename(&quarantine, path);
        return Ok(false);
    }
    fs::remove_dir_all(quarantine)?;
    Ok(true)
}
