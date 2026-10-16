use std::{
    collections::BTreeMap,
    io::{self, Read},
    net::Ipv4Addr,
    path::PathBuf,
};

#[derive(Debug, Eq, PartialEq)]
pub struct Config {
    pub config_file: PathBuf,
    pub interface: String,
    pub probe_address: String,
    pub table: u32,
    pub user_pref: u32,
    pub probe_pref: u32,
    pub mark: u32,
    pub mask: u32,
    pub pbr_owner: PathBuf,
    pub probe_owner: PathBuf,
    pub route_error_file: PathBuf,
    pub fw4_family: String,
    pub fw4_table: String,
    pub fw4_chain: String,
    pub fw4_comment: String,
    pub nft_family: String,
    pub nft_table: String,
    pub mark_chain: String,
    pub mss_chain: String,
    pub forward_chain: String,
    pub nat_chain: String,
    pub observer_family: String,
    pub observer_table: String,
    pub pair_family: String,
    pub pair_table: String,
    pub pair_set: String,
    pub domain_error_file: PathBuf,
}

impl Config {
    pub fn read(mut input: impl Read) -> io::Result<Self> {
        let mut contents = String::new();
        input.read_to_string(&mut contents)?;
        let mut fields = BTreeMap::new();
        for line in contents.lines() {
            let (name, value) = line
                .split_once('=')
                .ok_or_else(|| invalid("строка disable-state не содержит '='"))?;
            if !matches!(
                name,
                "version"
                    | "config"
                    | "interface"
                    | "probe_address"
                    | "table"
                    | "user_pref"
                    | "probe_pref"
                    | "mark"
                    | "mask"
                    | "pbr_owner"
                    | "probe_owner"
                    | "route_error"
                    | "fw4_family"
                    | "fw4_table"
                    | "fw4_chain"
                    | "fw4_comment"
                    | "nft_family"
                    | "nft_table"
                    | "mark_chain"
                    | "mss_chain"
                    | "forward_chain"
                    | "nat_chain"
                    | "observer_family"
                    | "observer_table"
                    | "pair_family"
                    | "pair_table"
                    | "pair_set"
                    | "domain_error"
            ) {
                return Err(invalid("неизвестное поле disable-state"));
            }
            if fields.insert(name, value.to_owned()).is_some() {
                return Err(invalid("поле disable-state указано повторно"));
            }
        }
        if required(&fields, "version")? != "1" {
            return Err(invalid("неподдерживаемая версия disable-state"));
        }

        let config_file = path_field(&fields, "config")?;
        let interface = required(&fields, "interface")?.to_owned();
        if !interface.is_empty() && !valid_interface(&interface) {
            return Err(invalid("неверный TUN-интерфейс disable-state"));
        }
        let probe_address = required(&fields, "probe_address")?.to_owned();
        if !probe_address.is_empty() && probe_address.parse::<Ipv4Addr>().is_err() {
            return Err(invalid("неверный IPv4-адрес probe disable-state"));
        }

        Ok(Self {
            config_file,
            interface,
            probe_address,
            table: number_field(&fields, "table")?,
            user_pref: number_field(&fields, "user_pref")?,
            probe_pref: number_field(&fields, "probe_pref")?,
            mark: number_field(&fields, "mark")?,
            mask: number_field(&fields, "mask")?,
            pbr_owner: path_field(&fields, "pbr_owner")?,
            probe_owner: path_field(&fields, "probe_owner")?,
            route_error_file: path_field(&fields, "route_error")?,
            fw4_family: string_field(&fields, "fw4_family")?,
            fw4_table: string_field(&fields, "fw4_table")?,
            fw4_chain: string_field(&fields, "fw4_chain")?,
            fw4_comment: string_field(&fields, "fw4_comment")?,
            nft_family: string_field(&fields, "nft_family")?,
            nft_table: string_field(&fields, "nft_table")?,
            mark_chain: string_field(&fields, "mark_chain")?,
            mss_chain: string_field(&fields, "mss_chain")?,
            forward_chain: string_field(&fields, "forward_chain")?,
            nat_chain: string_field(&fields, "nat_chain")?,
            observer_family: string_field(&fields, "observer_family")?,
            observer_table: string_field(&fields, "observer_table")?,
            pair_family: string_field(&fields, "pair_family")?,
            pair_table: string_field(&fields, "pair_table")?,
            pair_set: string_field(&fields, "pair_set")?,
            domain_error_file: path_field(&fields, "domain_error")?,
        })
    }
}

fn required<'a>(fields: &'a BTreeMap<&str, String>, name: &str) -> io::Result<&'a str> {
    fields
        .get(name)
        .map(String::as_str)
        .ok_or_else(|| invalid("не заполнено обязательное поле disable-state"))
}

fn string_field(fields: &BTreeMap<&str, String>, name: &'static str) -> io::Result<String> {
    let value = required(fields, name)?;
    if value.is_empty() {
        return Err(invalid("поле disable-state не может быть пустым"));
    }
    Ok(value.to_owned())
}

fn path_field(fields: &BTreeMap<&str, String>, name: &'static str) -> io::Result<PathBuf> {
    let value = required(fields, name)?;
    if value.is_empty() {
        return Err(invalid("путь disable-state не может быть пустым"));
    }
    Ok(PathBuf::from(value))
}

fn number_field(fields: &BTreeMap<&str, String>, name: &'static str) -> io::Result<u32> {
    let value = required(fields, name)?;
    if let Some(hex) = value
        .strip_prefix("0x")
        .or_else(|| value.strip_prefix("0X"))
    {
        u32::from_str_radix(hex, 16)
            .map_err(|_| invalid("числовое поле disable-state вне диапазона"))
    } else {
        value
            .parse::<u32>()
            .map_err(|_| invalid("числовое поле disable-state вне диапазона"))
    }
}

fn valid_interface(value: &str) -> bool {
    let Some(suffix) = value.strip_prefix("z2ktun") else {
        return false;
    };
    (suffix.len() == 1 || suffix.len() == 2) && suffix.bytes().all(|byte| byte.is_ascii_digit())
}

fn invalid(message: &'static str) -> io::Error {
    io::Error::new(io::ErrorKind::InvalidInput, message)
}

pub trait DisableOperations {
    fn remove_routes(&mut self) -> io::Result<()>;
    fn remove_remaining_state(&mut self) -> Vec<CleanupFailure>;
    fn clear_failure_marker(&mut self) -> io::Result<()>;
    fn commit_disabled(&mut self) -> io::Result<()>;
    fn record_failure(&mut self, reason: &str) -> io::Result<()>;
}

pub struct CleanupFailure {
    pub reason: &'static str,
    pub message: String,
}

pub fn run(operations: &mut impl DisableOperations) -> io::Result<()> {
    prepare(operations)?;

    if let Err(error) = operations.commit_disabled() {
        return fail(
            operations,
            "warp-disable-config-commit-failed",
            format!("флаг WARP: {error}"),
        );
    }

    Ok(())
}

pub fn prepare(operations: &mut impl DisableOperations) -> io::Result<()> {
    if let Err(error) = operations.remove_routes() {
        return fail(
            operations,
            "warp-disable-pbr-remove-failed",
            format!("PBR: {error}"),
        );
    }

    let errors = operations.remove_remaining_state();
    if !errors.is_empty() {
        let reason = errors[0].reason;
        let message = errors
            .into_iter()
            .map(|error| error.message)
            .collect::<Vec<_>>()
            .join("; ");
        return fail(operations, reason, message);
    }

    if let Err(error) = operations.clear_failure_marker() {
        return fail(
            operations,
            "warp-disable-marker-clear-failed",
            format!("маркер ошибки WARP: {error}"),
        );
    }
    Ok(())
}

fn fail(operations: &mut impl DisableOperations, reason: &str, message: String) -> io::Result<()> {
    let message = match operations.record_failure(reason) {
        Ok(()) => message,
        Err(error) => format!("{message}; не удалось сохранить причину: {error}"),
    };
    Err(io::Error::other(message))
}

#[cfg(test)]
mod tests {
    use super::{CleanupFailure, Config, DisableOperations, run};
    use std::io;

    #[derive(Default)]
    struct Operations {
        events: Vec<String>,
        route_error: bool,
        cleanup_error: bool,
        marker_error: bool,
        commit_error: bool,
    }

    impl DisableOperations for Operations {
        fn remove_routes(&mut self) -> io::Result<()> {
            self.events.push("routes".into());
            if self.route_error {
                Err(io::Error::other("маршрут занят"))
            } else {
                Ok(())
            }
        }

        fn remove_remaining_state(&mut self) -> Vec<CleanupFailure> {
            self.events.push("cleanup".into());
            if self.cleanup_error {
                vec![CleanupFailure {
                    reason: "warp-disable-nft-remove-failed",
                    message: "nft: временная ошибка".into(),
                }]
            } else {
                Vec::new()
            }
        }

        fn clear_failure_marker(&mut self) -> io::Result<()> {
            self.events.push("clear-marker".into());
            if self.marker_error {
                Err(io::Error::other("маркер занят"))
            } else {
                Ok(())
            }
        }

        fn commit_disabled(&mut self) -> io::Result<()> {
            self.events.push("commit-disabled".into());
            if self.commit_error {
                Err(io::Error::other("config read-only"))
            } else {
                Ok(())
            }
        }

        fn record_failure(&mut self, reason: &str) -> io::Result<()> {
            self.events.push(format!("record:{reason}"));
            Ok(())
        }
    }

    #[test]
    fn ошибка_pbr_не_фиксирует_выключение_и_не_снимает_прочее_состояние() {
        let mut operations = Operations {
            route_error: true,
            ..Operations::default()
        };

        assert!(run(&mut operations).is_err());
        assert_eq!(
            operations.events,
            ["routes", "record:warp-disable-pbr-remove-failed"]
        );
    }

    #[test]
    fn ошибка_очистки_не_фиксирует_выключение_и_оставляет_причину() {
        let mut operations = Operations {
            cleanup_error: true,
            ..Operations::default()
        };

        assert!(run(&mut operations).is_err());
        assert_eq!(
            operations.events,
            ["routes", "cleanup", "record:warp-disable-nft-remove-failed"]
        );
    }

    #[test]
    fn успешное_выключение_сначала_очищает_сеть_и_маркер() {
        let mut operations = Operations::default();

        run(&mut operations).unwrap();
        assert_eq!(
            operations.events,
            ["routes", "cleanup", "clear-marker", "commit-disabled"]
        );
    }

    #[test]
    fn ошибка_очистки_маркера_не_фиксирует_выключение() {
        let mut operations = Operations {
            marker_error: true,
            ..Operations::default()
        };

        assert!(run(&mut operations).is_err());
        assert_eq!(
            operations.events,
            [
                "routes",
                "cleanup",
                "clear-marker",
                "record:warp-disable-marker-clear-failed"
            ]
        );
    }

    #[test]
    fn ошибка_записи_флага_сохраняет_причину_и_не_повторяет_очистку() {
        let mut operations = Operations {
            commit_error: true,
            ..Operations::default()
        };

        assert!(run(&mut operations).is_err());
        assert_eq!(
            operations.events,
            [
                "routes",
                "cleanup",
                "clear-marker",
                "commit-disabled",
                "record:warp-disable-config-commit-failed"
            ]
        );
    }

    fn config_input() -> String {
        "version=1\n\
         config=/etc/z2k/config\n\
         interface=z2ktun0\n\
         probe_address=172.16.9.9\n\
         table=989\n\
         user_pref=500\n\
         probe_pref=499\n\
         mark=0x80000000\n\
         mask=0x80000000\n\
         pbr_owner=/tmp/z2k/warp/pbr.owner\n\
         probe_owner=/tmp/z2k/warp/probe-route.owner\n\
         route_error=/tmp/z2k/warp/route-error\n\
         fw4_family=inet\n\
         fw4_table=fw4\n\
         fw4_chain=forward\n\
         fw4_comment=!z2k: WARP forwarded traffic\n\
         nft_family=inet\n\
         nft_table=zapret2\n\
         mark_chain=z2k_warp_mark\n\
         mss_chain=z2k_warp_mss\n\
         forward_chain=z2k_warp_fwd\n\
         nat_chain=z2k_warp_nat\n\
         observer_family=inet\n\
         observer_table=z2k_warp_dns\n\
         pair_family=inet\n\
         pair_table=zapret2\n\
         pair_set=z2k_warp_domain4\n\
         domain_error=/tmp/z2k-warp/domain-setup-error\n"
            .to_owned()
    }

    #[test]
    fn именованный_протокол_disable_state_v1_разбирается_в_структуру() {
        let input = config_input();
        let config = Config::read(input.as_bytes()).unwrap();
        assert_eq!(config.config_file, std::path::Path::new("/etc/z2k/config"));
        assert_eq!(config.interface, "z2ktun0");
        assert_eq!(config.probe_address, "172.16.9.9");
        assert_eq!(
            config.pbr_owner,
            std::path::Path::new("/tmp/z2k/warp/pbr.owner")
        );
        assert_eq!(config.table, 989);
        assert_eq!(config.mark, 0x8000_0000);
        assert_eq!(config.nft_table, "zapret2");
        assert_eq!(config.fw4_comment, "!z2k: WARP forwarded traffic");
    }

    #[test]
    fn неизвестная_версия_и_повторные_поля_отклоняются() {
        let version = config_input().replacen("version=1", "version=2", 1);
        assert!(Config::read(version.as_bytes()).is_err());

        let duplicate = format!("{}version=1\n", config_input());
        assert!(Config::read(duplicate.as_bytes()).is_err());
    }
}
