use std::{
    collections::BTreeSet,
    fs::{self, OpenOptions},
    io::{self, Write},
    os::unix::fs::PermissionsExt,
    path::{Path, PathBuf},
    time::{SystemTime, UNIX_EPOCH},
};

const MAX_DOMAIN_RULES: usize = 4096;

#[derive(Debug, Eq, PartialEq)]
pub struct RenderedRules {
    pub contents: String,
    pub error: Option<&'static str>,
}

pub fn render_rules(domains: &[String]) -> RenderedRules {
    let domains = domains
        .iter()
        .map(|domain| domain.to_ascii_lowercase())
        .collect::<BTreeSet<_>>();
    if domains.len() > MAX_DOMAIN_RULES {
        return RenderedRules {
            contents: "v1\n".to_owned(),
            error: Some("domain-rule-limit-exceeded"),
        };
    }

    let mut contents = String::from("v1\n");
    for domain in domains {
        contents.push_str(&domain);
        contents.push('\n');
    }
    RenderedRules {
        contents,
        error: None,
    }
}

pub fn sync_rules_file(
    rules_path: &Path,
    error_path: &Path,
    domains: &[String],
) -> io::Result<RenderedRules> {
    let rendered = render_rules(domains);
    atomic_replace_if_changed(rules_path, rendered.contents.as_bytes(), 0o600)?;
    set_error_file(error_path, rendered.error.unwrap_or_default())?;
    Ok(rendered)
}

pub fn set_error_file(path: &Path, error_code: &str) -> io::Result<()> {
    if error_code.bytes().any(|byte| matches!(byte, b'\n' | b'\r')) || error_code.len() > 128 {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "неверный код ошибки domain observer",
        ));
    }
    if error_code.is_empty() {
        return match fs::remove_file(path) {
            Ok(()) => sync_parent(path),
            Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(()),
            Err(error) => Err(error),
        };
    }
    let contents = format!("{error_code}\n");
    atomic_replace_if_changed(path, contents.as_bytes(), 0o600)
}

fn atomic_replace_if_changed(path: &Path, contents: &[u8], mode: u32) -> io::Result<()> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent)?;
    } else {
        return Err(io::Error::new(
            io::ErrorKind::InvalidInput,
            "путь файла доменных правил не содержит каталог",
        ));
    }
    match fs::read(path) {
        Ok(existing) if existing == contents => return Ok(()),
        Ok(_) => {}
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    let parent = path.parent().expect("путь проверен выше");
    let name = path
        .file_name()
        .and_then(|value| value.to_str())
        .ok_or_else(|| io::Error::new(io::ErrorKind::InvalidInput, "неверный путь файла"))?;
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap_or_default()
        .as_nanos();
    let temporary =
        PathBuf::from(parent).join(format!(".{name}.new.{}.{nonce}", std::process::id()));
    let mut file = OpenOptions::new()
        .write(true)
        .create_new(true)
        .open(&temporary)?;
    let write_result = (|| {
        file.write_all(contents)?;
        file.sync_all()?;
        file.set_permissions(fs::Permissions::from_mode(mode))?;
        drop(file);
        fs::rename(&temporary, path)?;
        sync_parent(path)
    })();
    if write_result.is_err() {
        let _ = fs::remove_file(temporary);
    }
    write_result
}

fn sync_parent(path: &Path) -> io::Result<()> {
    let parent = path.parent().ok_or_else(|| {
        io::Error::new(
            io::ErrorKind::InvalidInput,
            "путь без родительского каталога",
        )
    })?;
    fs::File::open(parent)?.sync_all()
}
