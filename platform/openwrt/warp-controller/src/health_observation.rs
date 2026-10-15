use std::{
    fs::{self, OpenOptions},
    io::{self, ErrorKind, Write},
    os::unix::fs::OpenOptionsExt,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

use serde_json::{Value, json};

use crate::{health::HealthAction, status::Paths};

const VERSION: u64 = 1;

pub fn record(
    path: &Path,
    action: HealthAction,
    defer_reason: Option<&str>,
    now: u64,
) -> io::Result<()> {
    let previous = read(path)?;
    let last_success_at = if action == HealthAction::Defer {
        previous
            .as_ref()
            .and_then(|record| record.get("last_success_at"))
            .and_then(Value::as_u64)
    } else {
        Some(now)
    };
    let (state, default_reason) = match action {
        HealthAction::Defer => ("unknown", "state-unreadable"),
        HealthAction::Disabled => ("disabled", "explicitly-disabled"),
        HealthAction::Ready => ("ready", "ready"),
        HealthAction::BinaryMissing => ("degraded", "warp-binary-missing"),
        HealthAction::DeviceMissing => ("degraded", "device-identity-missing"),
        HealthAction::ProcessAbsent => ("degraded", "daemon-not-running"),
        HealthAction::NotReady => ("degraded", "tunnel-not-ready"),
    };
    let reason = defer_reason.unwrap_or(default_reason);
    if !valid_token(reason) {
        return Err(io::Error::new(
            ErrorKind::InvalidInput,
            "неверная причина наблюдения WARP",
        ));
    }
    let record = json!({
        "version": VERSION,
        "state": state,
        "observed_at": now,
        "last_success_at": last_success_at,
        "source": "health-check",
        "reason": reason,
    });
    let mut contents = serde_json::to_vec(&record)
        .map_err(|error| io::Error::new(ErrorKind::InvalidData, error))?;
    contents.push(b'\n');
    atomic_replace(path, &contents)
}

pub fn render(path: &Path, now: u64) -> io::Result<String> {
    let Some(record) = read(path)? else {
        return Ok(
            "state=UNKNOWN observed_at=unknown last_success_age_s=never source=none reason=no-observation"
                .to_owned(),
        );
    };
    let version = record.get("version").and_then(Value::as_u64);
    let state = record.get("state").and_then(Value::as_str);
    let observed_at = record.get("observed_at").and_then(Value::as_u64);
    let source = record.get("source").and_then(Value::as_str);
    let reason = record.get("reason").and_then(Value::as_str);
    let last_success_at = record.get("last_success_at");
    if version != Some(VERSION)
        || !matches!(state, Some("unknown" | "disabled" | "degraded" | "ready"))
        || observed_at.is_none()
        || !source.is_some_and(valid_token)
        || !reason.is_some_and(valid_token)
    {
        return Err(io::Error::new(
            ErrorKind::InvalidData,
            "повреждён снимок наблюдения WARP",
        ));
    }
    let age = match last_success_at {
        Some(Value::Number(number)) => number
            .as_u64()
            .map(|timestamp| now.saturating_sub(timestamp).to_string())
            .ok_or_else(|| {
                io::Error::new(ErrorKind::InvalidData, "неверное время health-check WARP")
            })?,
        Some(Value::Null) => "never".to_owned(),
        _ => {
            return Err(io::Error::new(
                ErrorKind::InvalidData,
                "неверное время health-check WARP",
            ));
        }
    };
    Ok(format!(
        "state={} observed_at={} last_success_age_s={} source={} reason={}",
        state.unwrap_or("unknown").to_ascii_uppercase(),
        observed_at.unwrap_or_default(),
        age,
        source.unwrap_or("unknown"),
        reason.unwrap_or("unknown"),
    ))
}

pub fn render_current(path: &Path) -> io::Result<String> {
    let now = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_secs();
    render(path, now)
}

pub fn current() -> io::Result<String> {
    crate::status::require_protocol_v1()?;
    let paths = Paths::from_env();
    render_current(&paths.health_observation)
}

fn read(path: &Path) -> io::Result<Option<Value>> {
    match fs::read(path) {
        Ok(contents) => serde_json::from_slice(&contents)
            .map(Some)
            .map_err(|error| io::Error::new(ErrorKind::InvalidData, error)),
        Err(error) if error.kind() == ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

fn atomic_replace(path: &Path, contents: &[u8]) -> io::Result<()> {
    let parent = path
        .parent()
        .filter(|parent| !parent.as_os_str().is_empty())
        .unwrap_or(Path::new("."));
    fs::create_dir_all(parent)?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let name = path
        .file_name()
        .ok_or_else(|| io::Error::new(ErrorKind::InvalidInput, "неверный путь наблюдения WARP"))?;
    let temporary: PathBuf = parent.join(format!(
        ".{}.new.{}.{nonce}",
        name.to_string_lossy(),
        std::process::id()
    ));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .mode(0o600)
        .open(&temporary)?;
    let result = (|| {
        file.write_all(contents)?;
        file.sync_all()?;
        drop(file);
        fs::rename(&temporary, path)?;
        fs::File::open(parent)?.sync_all()
    })();
    if result.is_err() {
        let _ = fs::remove_file(&temporary);
    }
    result
}

fn valid_token(value: &str) -> bool {
    !value.is_empty()
        && value.len() <= 96
        && value.bytes().all(|byte| {
            byte.is_ascii_lowercase() || byte.is_ascii_digit() || matches!(byte, b'-' | b'_')
        })
}

#[cfg(test)]
mod tests {
    use super::{HealthAction, record, render};
    use std::{
        fs,
        os::unix::fs::PermissionsExt,
        path::PathBuf,
        time::{SystemTime, UNIX_EPOCH},
    };

    fn path(name: &str) -> (PathBuf, PathBuf) {
        let nonce = SystemTime::now()
            .duration_since(UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let directory = std::env::temp_dir().join(format!(
            "z2k-warp-health-observation-{}-{nonce}",
            std::process::id()
        ));
        (directory.join(name), directory)
    }

    #[test]
    fn defer_preserves_last_success_age_and_reports_source_and_reason() {
        let (path, directory) = path("health.json");
        record(&path, HealthAction::Ready, None, 100).unwrap();
        record(&path, HealthAction::Defer, Some("proc-unreadable"), 130).unwrap();

        assert_eq!(
            render(&path, 160).unwrap(),
            "state=UNKNOWN observed_at=130 last_success_age_s=60 source=health-check reason=proc-unreadable"
        );
        assert_eq!(
            fs::metadata(&path).unwrap().permissions().mode() & 0o777,
            0o600
        );
        fs::remove_dir_all(directory).unwrap();
    }

    #[test]
    fn missing_record_is_unknown_without_a_last_success() {
        let (path, directory) = path("missing.json");

        assert_eq!(
            render(&path, 160).unwrap(),
            "state=UNKNOWN observed_at=unknown last_success_age_s=never source=none reason=no-observation"
        );
        fs::remove_dir_all(directory).unwrap_or(());
    }

    #[test]
    fn known_unready_state_is_degraded() {
        let (path, directory) = path("health.json");
        record(&path, HealthAction::NotReady, None, 100).unwrap();

        assert_eq!(
            render(&path, 120).unwrap(),
            "state=DEGRADED observed_at=100 last_success_age_s=20 source=health-check reason=tunnel-not-ready"
        );
        fs::remove_dir_all(directory).unwrap();
    }
}
