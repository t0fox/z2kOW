use std::io;
use std::os::fd::AsRawFd;
use std::time::Duration;

use tokio::net::{TcpSocket, TcpStream, lookup_host};

/// Ошибка исходящего TCP-подключения.
#[derive(Debug, Clone)]
pub struct OutboundError {
    pub reason: String,
    pub timed_out: bool,
    pub dns_failed: bool,
}

impl OutboundError {
    fn failed(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
            timed_out: false,
            dns_failed: false,
        }
    }

    fn dns_failed(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
            timed_out: false,
            dns_failed: true,
        }
    }

    fn timed_out(reason: impl Into<String>) -> Self {
        Self {
            reason: reason.into(),
            timed_out: true,
            dns_failed: false,
        }
    }
}

impl std::fmt::Display for OutboundError {
    fn fmt(&self, f: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        f.write_str(&self.reason)
    }
}

impl std::error::Error for OutboundError {}

pub struct OutboundConnector {
    socket_mark: Option<u32>,
}

impl OutboundConnector {
    pub fn direct() -> Self {
        Self { socket_mark: None }
    }

    pub fn with_socket_mark(mut self, mark: Option<u32>) -> Self {
        self.socket_mark = mark;
        self
    }

    pub async fn connect(
        &self,
        target_host: &str,
        target_port: u16,
        timeout: Duration,
    ) -> Result<TcpStream, OutboundError> {
        match tokio::time::timeout(
            timeout,
            connect_marked_tcp(target_host, target_port, self.socket_mark),
        )
        .await
        {
            Ok(result) => result,
            Err(_) => Err(OutboundError::timed_out("TCP connect timed out")),
        }
    }
}

async fn connect_marked_tcp(
    host: &str,
    port: u16,
    mark: Option<u32>,
) -> Result<TcpStream, OutboundError> {
    let Some(mark) = mark else {
        return TcpStream::connect((host, port)).await.map_err(|error| {
            let reason = format!("Подключение TCP: {error}");
            if error.kind() == io::ErrorKind::NotFound {
                OutboundError::dns_failed(reason)
            } else {
                OutboundError::failed(reason)
            }
        });
    };

    #[cfg(target_os = "linux")]
    {
        let mut last_error = None;
        let addrs = lookup_host((host, port)).await.map_err(|error| {
            OutboundError::dns_failed(format!("Поиск адреса TCP-хоста: {error}"))
        })?;
        let mut found_address = false;
        for address in addrs {
            found_address = true;
            let socket = if address.is_ipv4() {
                TcpSocket::new_v4()
            } else {
                TcpSocket::new_v6()
            }
            .map_err(|error| OutboundError::failed(format!("Создание TCP-сокета: {error}")))?;
            set_socket_mark(&socket, mark)
                .map_err(|error| OutboundError::failed(format!("Метка SO_MARK: {error}")))?;
            match socket.connect(address).await {
                Ok(stream) => return Ok(stream),
                Err(error) => last_error = Some(error),
            }
        }
        let error = last_error.unwrap_or_else(|| {
            io::Error::new(io::ErrorKind::AddrNotAvailable, "DNS не вернул адресов")
        });
        if found_address {
            Err(OutboundError::failed(format!("Подключение TCP: {error}")))
        } else {
            Err(OutboundError::dns_failed(format!(
                "Поиск адреса TCP-хоста: {error}"
            )))
        }
    }
    #[cfg(not(target_os = "linux"))]
    {
        let _ = (host, port, mark);
        Err(OutboundError::failed(
            "Метка SO_MARK поддерживается только в Linux",
        ))
    }
}

#[cfg(target_os = "linux")]
fn set_socket_mark(socket: &TcpSocket, mark: u32) -> io::Result<()> {
    let rc = unsafe {
        libc::setsockopt(
            socket.as_raw_fd(),
            libc::SOL_SOCKET,
            libc::SO_MARK,
            &mark as *const _ as *const libc::c_void,
            std::mem::size_of_val(&mark) as libc::socklen_t,
        )
    };
    if rc == 0 {
        Ok(())
    } else {
        Err(io::Error::last_os_error())
    }
}
