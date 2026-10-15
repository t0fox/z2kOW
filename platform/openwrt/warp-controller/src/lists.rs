use std::{fs, io, net::Ipv4Addr, path::Path};

#[derive(Debug, Default, Eq, PartialEq)]
pub struct ListValidation {
    pub addresses: Vec<String>,
    pub domains: Vec<String>,
    pub entries: Vec<String>,
    pub invalid: usize,
}

#[derive(Debug, Default, Eq, PartialEq)]
pub struct ActiveLists {
    pub validation: ListValidation,
    pub has_nonempty_input: bool,
    pub device_sources: String,
}

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum PolicyScope {
    All,
    FullDevice,
    Devices,
    Lists,
}

#[derive(Debug, Eq, PartialEq)]
pub struct MarkPolicyInputs {
    pub scope: PolicyScope,
    pub domains: Vec<String>,
}

impl PolicyScope {
    pub fn as_str(self) -> &'static str {
        match self {
            Self::All => "all",
            Self::FullDevice => "full",
            Self::Devices => "devices",
            Self::Lists => "lists",
        }
    }
}

/// Load user-owned lists and explicitly enabled game lists.
/// Missing optional directories/files match the shell contract; existing but
/// unreadable sources are errors so a transient read failure cannot clear nft sets.
pub fn load_active_lists(
    user_dir: &Path,
    games_dir: &Path,
    enabled_file: &Path,
    devices_file: &Path,
) -> io::Result<ActiveLists> {
    let (combined, mut has_nonempty_input, _, _) =
        read_active_list_contents(user_dir, games_dir, enabled_file, Some(devices_file))?;
    let device_sources = read_optional(devices_file)?.unwrap_or_default();
    has_nonempty_input |= !device_sources.is_empty();

    Ok(ActiveLists {
        validation: validate_entries(&combined),
        has_nonempty_input,
        device_sources,
    })
}

pub fn load_active_domains(
    user_dir: &Path,
    games_dir: &Path,
    enabled_file: &Path,
) -> io::Result<Vec<String>> {
    let (combined, _, _, _) = read_active_list_contents(user_dir, games_dir, enabled_file, None)?;
    Ok(validate_entries(&combined).domains)
}

pub fn policy_scope(
    user_dir: &Path,
    games_dir: &Path,
    enabled_file: &Path,
    devices_file: &Path,
) -> io::Result<PolicyScope> {
    let (_, _, has_active_lists, has_enabled_selection) =
        read_active_list_contents(user_dir, games_dir, enabled_file, Some(devices_file))?;
    let devices = read_optional(devices_file)?.unwrap_or_default();
    let has_device_selection = has_selected_lines(&devices);
    Ok(select_scope(
        has_device_selection,
        has_enabled_selection,
        has_active_lists,
    ))
}

pub fn load_mark_policy_inputs(
    user_dir: &Path,
    games_dir: &Path,
    enabled_file: &Path,
    devices_file: &Path,
) -> io::Result<MarkPolicyInputs> {
    let (combined, _, has_active_lists, has_enabled_selection) =
        read_active_list_contents(user_dir, games_dir, enabled_file, Some(devices_file))?;
    let devices = read_optional(devices_file)?.unwrap_or_default();
    let scope = select_scope(
        has_selected_lines(&devices),
        has_enabled_selection,
        has_active_lists,
    );
    let domains = validate_entries(&combined).domains;
    Ok(MarkPolicyInputs { scope, domains })
}

fn select_scope(
    has_device_selection: bool,
    has_enabled_selection: bool,
    has_active_lists: bool,
) -> PolicyScope {
    if has_device_selection {
        if !has_enabled_selection && !has_active_lists {
            PolicyScope::FullDevice
        } else {
            PolicyScope::Devices
        }
    } else if !has_enabled_selection && !has_active_lists {
        PolicyScope::All
    } else {
        PolicyScope::Lists
    }
}

fn has_selected_lines(contents: &str) -> bool {
    contents.lines().any(|line| {
        let line = line.trim_matches([' ', '\t', '\r']);
        !line.is_empty() && !line.starts_with('#')
    })
}

fn read_active_list_contents(
    user_dir: &Path,
    games_dir: &Path,
    enabled_file: &Path,
    devices_file: Option<&Path>,
) -> io::Result<(String, bool, bool, bool)> {
    let mut selected = Vec::new();
    let disabled_path = user_dir.join(".disabled");
    let disabled = read_optional(&disabled_path)?
        .unwrap_or_default()
        .lines()
        .map(str::to_owned)
        .collect::<Vec<_>>();

    match fs::read_dir(user_dir) {
        Ok(entries) => {
            for entry in entries {
                let entry = entry?;
                let path = entry.path();
                if devices_file.is_some_and(|devices| path == devices)
                    || path.extension().is_none_or(|x| x != "txt")
                {
                    continue;
                }
                match fs::metadata(&path) {
                    Ok(metadata) if metadata.is_file() => {}
                    Ok(_) => continue,
                    Err(error) if error.kind() == io::ErrorKind::NotFound => continue,
                    Err(error) => return Err(error),
                }
                let Some(name) = path.file_stem().and_then(|x| x.to_str()) else {
                    continue;
                };
                if name.starts_with('.') || disabled.iter().any(|value| value == name) {
                    continue;
                }
                selected.push(path);
            }
        }
        Err(error) if error.kind() == io::ErrorKind::NotFound => {}
        Err(error) => return Err(error),
    }

    let enabled = read_optional(enabled_file)?.unwrap_or_default();
    let has_enabled_selection = has_selected_lines(&enabled);
    for raw in enabled.lines() {
        let name = raw
            .chars()
            .filter(|c| !matches!(c, ' ' | '\t' | '\r'))
            .collect::<String>();
        if !valid_list_name(&name) {
            continue;
        }
        let path = games_dir.join(format!("{name}.txt"));
        if path.is_file() {
            selected.push(path);
        }
    }

    let mut combined = String::new();
    let mut has_nonempty_input = false;
    let has_active_lists = !selected.is_empty();
    for path in selected {
        let contents = fs::read_to_string(path)?;
        has_nonempty_input |= !contents.is_empty();
        combined.push_str(&contents);
        if !contents.ends_with('\n') {
            combined.push('\n');
        }
    }
    Ok((
        combined,
        has_nonempty_input,
        has_active_lists,
        has_enabled_selection,
    ))
}

fn read_optional(path: &Path) -> io::Result<Option<String>> {
    match fs::read_to_string(path) {
        Ok(contents) => Ok(Some(contents)),
        Err(error) if error.kind() == io::ErrorKind::NotFound => Ok(None),
        Err(error) => Err(error),
    }
}

fn valid_list_name(name: &str) -> bool {
    !name.is_empty()
        && name.len() <= 64
        && !name.starts_with(['.', '-'])
        && name != "devices"
        && name
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || matches!(b, b'.' | b'_' | b'-'))
}

impl ListValidation {
    pub fn save_text(&self) -> String {
        let mut output = self.entries.join("\n");
        if !self.entries.is_empty() {
            output.push('\n');
        }
        output
    }
}

pub fn validate_entries(input: &str) -> ListValidation {
    let mut result = ListValidation::default();
    for raw in input.lines() {
        let line = raw.trim_end_matches('\r').trim_matches([' ', '\t']);
        if line.is_empty() {
            continue;
        }
        if line.starts_with('#') {
            result.entries.push(line.to_owned());
            continue;
        }
        if valid_ipv4_cidr(line) {
            result.addresses.push(line.to_owned());
            result.entries.push(line.to_owned());
        } else if valid_domain(line) {
            let normalized = line.to_ascii_lowercase();
            result.domains.push(normalized.clone());
            result.entries.push(normalized);
        } else {
            result.invalid += 1;
        }
    }
    result
}

pub fn normalize_destinations(input: &str) -> Vec<String> {
    let addresses = validate_entries(input).addresses;
    let mut ranges: Vec<(u64, u64)> = addresses
        .iter()
        .filter_map(|entry| ipv4_range(entry))
        .collect();
    ranges.sort_unstable_by(|a, b| a.0.cmp(&b.0).then_with(|| b.1.cmp(&a.1)));

    let mut merged: Vec<(u64, u64)> = Vec::new();
    for (low, high) in ranges {
        if let Some(last) = merged.last_mut()
            && low <= last.1 + 1
        {
            last.1 = last.1.max(high);
            continue;
        }
        merged.push((low, high));
    }

    merged
        .into_iter()
        .flat_map(|(low, high)| cidr_cover(low, high))
        .collect()
}

fn valid_ipv4_cidr(entry: &str) -> bool {
    let mut cidr = entry.split('/');
    let Some(address) = cidr.next() else {
        return false;
    };
    let prefix = match cidr.next() {
        Some(prefix) if !prefix.is_empty() && prefix.bytes().all(|b| b.is_ascii_digit()) => {
            match prefix.parse::<u8>() {
                Ok(value @ 1..=32) if prefix == value.to_string() => value,
                _ => return false,
            }
        }
        Some(_) => return false,
        None => 32,
    };
    if cidr.next().is_some() {
        return false;
    }

    let octets: Vec<&str> = address.split('.').collect();
    if octets.len() != 4
        || octets.iter().any(|octet| {
            octet.is_empty()
                || octet.len() > 3
                || !octet.bytes().all(|byte| byte.is_ascii_digit())
                || (octet.len() > 1 && octet.starts_with('0'))
        })
        || !(1..=9).contains(&octets[0].len())
        || octets[0].starts_with('0')
    {
        return false;
    }
    let Ok(ip) = address.parse::<Ipv4Addr>() else {
        return false;
    };
    let [a, b, c, _] = ip.octets();
    if a == 0
        || a == 10
        || a == 127
        || a >= 224
        || (a == 100 && (64..=127).contains(&b))
        || (a == 169 && b == 254)
        || (a == 172 && (16..=31).contains(&b))
        || (a == 192 && b == 168)
        || (a == 192 && b == 0 && (c == 0 || c == 2))
        || (a == 198 && (b == 18 || b == 19))
        || (a == 198 && b == 51 && c == 100)
        || (a == 203 && b == 0 && c == 113)
    {
        return false;
    }
    let _ = prefix;
    true
}

fn valid_domain(domain: &str) -> bool {
    if domain.len() > 255
        || !domain
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'*' | b'-'))
    {
        return false;
    }
    let domain = domain.strip_prefix("*.").unwrap_or(domain);
    if domain.contains('*') || !(4..=253).contains(&domain.len()) {
        return false;
    }
    let labels: Vec<&str> = domain.split('.').collect();
    if labels.len() < 2
        || labels.iter().any(|label| {
            label.is_empty()
                || label.len() > 63
                || !label.as_bytes()[0].is_ascii_alphanumeric()
                || !label.as_bytes()[label.len() - 1].is_ascii_alphanumeric()
                || !label
                    .bytes()
                    .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-')
        })
    {
        return false;
    }
    let tld = labels[labels.len() - 1];
    tld.bytes().all(|byte| byte.is_ascii_alphabetic())
        || (tld.starts_with("xn--")
            && tld.len() > 4
            && tld
                .bytes()
                .all(|byte| byte.is_ascii_alphanumeric() || byte == b'-'))
}

fn ipv4_range(cidr: &str) -> Option<(u64, u64)> {
    let (address, prefix) = cidr.split_once('/').unwrap_or((cidr, "32"));
    let address = u32::from(address.parse::<Ipv4Addr>().ok()?);
    let prefix = prefix.parse::<u32>().ok()?;
    let size = 1_u64 << (32 - prefix);
    let low = (u64::from(address) / size) * size;
    Some((low, low + size - 1))
}

fn cidr_cover(mut low: u64, high: u64) -> Vec<String> {
    let mut result = Vec::new();
    while low <= high {
        let aligned_bits = if low == 0 { 32 } else { low.trailing_zeros() };
        let remaining_bits = 63 - (high - low + 1).leading_zeros();
        let host_bits = aligned_bits.min(remaining_bits);
        let size = 1_u64 << host_bits;
        let address = Ipv4Addr::from(low as u32);
        result.push(format!("{address}/{}", 32 - host_bits));
        low += size;
    }
    result
}

#[cfg(test)]
mod tests {
    use super::{PolicyScope, has_selected_lines, select_scope};

    #[test]
    fn scope_preserves_empty_selection_intent() {
        assert_eq!(select_scope(false, false, false), PolicyScope::All);
        assert_eq!(select_scope(true, false, false), PolicyScope::FullDevice);
        assert_eq!(select_scope(true, false, true), PolicyScope::Devices);
        assert_eq!(select_scope(false, true, false), PolicyScope::Lists);
        assert_eq!(select_scope(false, false, true), PolicyScope::Lists);
    }

    #[test]
    fn only_non_comment_lines_count_as_user_selection() {
        assert!(!has_selected_lines("\n # comment\r\n  \t\n"));
        assert!(has_selected_lines("# comment\nselected\r\n"));
    }
}
