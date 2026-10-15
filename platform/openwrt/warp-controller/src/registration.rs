use std::{fs, io::ErrorKind, path::Path};

use crate::state::Observation;

pub fn attempt_due(stamp_path: &Path, now: u64, retry_seconds: u64) -> Observation<bool> {
    let last_attempt = match fs::read_to_string(stamp_path) {
        Ok(contents) => contents.trim().parse::<u64>().unwrap_or(0),
        Err(error) if error.kind() == ErrorKind::NotFound => 0,
        Err(_) => return Observation::Unreadable,
    };

    Observation::Known(now >= last_attempt && now - last_attempt >= retry_seconds)
}

#[cfg(test)]
mod tests {
    use super::attempt_due;
    use crate::state::Observation;
    use std::{fs, path::PathBuf};

    fn stamp_path(label: &str) -> PathBuf {
        let path = std::env::temp_dir().join(format!(
            "z2k-warp-register-stamp-{}-{label}",
            std::process::id()
        ));
        let _ = fs::remove_file(&path);
        path
    }

    #[test]
    fn missing_and_malformed_stamps_preserve_the_due_fallback() {
        let path = stamp_path("missing");
        assert_eq!(attempt_due(&path, 1000, 300), Observation::Known(true));

        fs::write(&path, "bad epoch\n").expect("повреждённая метка регистрации");
        assert_eq!(attempt_due(&path, 1000, 300), Observation::Known(true));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn recent_and_future_attempts_wait_until_the_retry_interval() {
        let path = stamp_path("recent");
        fs::write(&path, "900\n").expect("актуальная метка регистрации");
        assert_eq!(attempt_due(&path, 1000, 300), Observation::Known(false));
        fs::write(&path, "1100\n").expect("будущая метка регистрации");
        assert_eq!(attempt_due(&path, 1000, 0), Observation::Known(false));
        let _ = fs::remove_file(path);
    }

    #[test]
    fn unreadable_stamp_defers_instead_of_claiming_registration_is_due() {
        let path = stamp_path("unreadable");
        fs::create_dir_all(&path).expect("каталог с некорректным типом stamp");
        assert_eq!(attempt_due(&path, 1000, 300), Observation::Unreadable);
        let _ = fs::remove_dir_all(path);
    }
}
