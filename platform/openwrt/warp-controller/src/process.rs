use std::{
    io::{self, Read},
    process::{Command, Output, Stdio},
    sync::OnceLock,
    thread::{self, JoinHandle},
    time::{Duration, Instant},
};

const OPERATION_LIMIT: Duration = Duration::from_secs(30);
const CHILD_LIMIT: Duration = Duration::from_secs(5);
const POLL_INTERVAL: Duration = Duration::from_millis(10);

static OPERATION_DEADLINE: OnceLock<Instant> = OnceLock::new();

pub fn start_operation() {
    let _ = OPERATION_DEADLINE.get_or_init(|| Instant::now() + OPERATION_LIMIT);
}

pub fn output(command: &mut Command) -> io::Result<Output> {
    output_inner(command, None, operation_deadline(), CHILD_LIMIT)
}

pub fn output_with_input(command: &mut Command, input: &[u8]) -> io::Result<Output> {
    output_inner(command, Some(input), operation_deadline(), CHILD_LIMIT)
}

fn operation_deadline() -> Instant {
    *OPERATION_DEADLINE.get_or_init(|| Instant::now() + OPERATION_LIMIT)
}

fn output_inner(
    command: &mut Command,
    input: Option<&[u8]>,
    operation_deadline: Instant,
    child_limit: Duration,
) -> io::Result<Output> {
    let program = command.get_program().to_string_lossy().into_owned();
    let started = Instant::now();
    if started >= operation_deadline {
        return Err(timeout_error(&program, "истёк общий дедлайн операции"));
    }
    let child_deadline = (started + child_limit).min(operation_deadline);

    command
        .stdin(if input.is_some() {
            Stdio::piped()
        } else {
            Stdio::null()
        })
        .stdout(Stdio::piped())
        .stderr(Stdio::piped());
    let mut child = command.spawn()?;
    let stdin = if input.is_some() {
        match child.stdin.take() {
            Some(stdin) => Some(stdin),
            None => {
                stop(&mut child);
                return Err(io::Error::other(
                    "не удалось открыть stdin дочерней команды",
                ));
            }
        }
    } else {
        None
    };
    let stdout = match child.stdout.take() {
        Some(stdout) => stdout,
        None => {
            stop(&mut child);
            return Err(io::Error::other(
                "не удалось открыть stdout дочерней команды",
            ));
        }
    };
    let stderr = match child.stderr.take() {
        Some(stderr) => stderr,
        None => {
            stop(&mut child);
            return Err(io::Error::other(
                "не удалось открыть stderr дочерней команды",
            ));
        }
    };
    let stdout_reader = read_output(stdout);
    let stderr_reader = read_output(stderr);
    let input_writer = input.zip(stdin).map(|(bytes, mut stdin)| {
        let bytes = bytes.to_vec();
        thread::spawn(move || io::Write::write_all(&mut stdin, &bytes))
    });

    let status = loop {
        match child.try_wait() {
            Ok(Some(status)) => break status,
            Ok(None) => {}
            Err(error) => {
                stop(&mut child);
                let _ = join_reader(stdout_reader);
                let _ = join_reader(stderr_reader);
                if let Some(writer) = input_writer {
                    let _ = writer.join();
                }
                return Err(error);
            }
        }
        let now = Instant::now();
        if now >= child_deadline {
            stop(&mut child);
            let _ = join_reader(stdout_reader);
            let _ = join_reader(stderr_reader);
            if let Some(writer) = input_writer {
                let _ = writer.join();
            }
            let reason = if child_deadline == operation_deadline {
                "истёк общий дедлайн операции"
            } else {
                "превышен лимит времени дочерней команды"
            };
            return Err(timeout_error(&program, reason));
        }
        thread::sleep(POLL_INTERVAL.min(child_deadline - now));
    };

    let stdout = join_reader(stdout_reader)?;
    let stderr = join_reader(stderr_reader)?;
    if let Some(writer) = input_writer {
        let write_result = writer
            .join()
            .map_err(|_| io::Error::other("поток передачи stdin завершился аварийно"))?;
        if status.success() {
            write_result?;
        }
    }
    Ok(Output {
        status,
        stdout,
        stderr,
    })
}

fn stop(child: &mut std::process::Child) {
    let _ = child.kill();
    let _ = child.wait();
}

fn read_output<R: Read + Send + 'static>(mut reader: R) -> JoinHandle<io::Result<Vec<u8>>> {
    thread::spawn(move || {
        let mut output = Vec::new();
        reader.read_to_end(&mut output)?;
        Ok(output)
    })
}

fn join_reader(reader: JoinHandle<io::Result<Vec<u8>>>) -> io::Result<Vec<u8>> {
    reader
        .join()
        .map_err(|_| io::Error::other("поток чтения вывода завершился аварийно"))?
}

fn timeout_error(program: &str, reason: &str) -> io::Error {
    io::Error::new(
        io::ErrorKind::TimedOut,
        format!("тайм-аут команды {program}: {reason}"),
    )
}

#[cfg(test)]
mod tests {
    use super::output_inner;
    use std::{
        process::Command,
        time::{Duration, Instant},
    };

    #[test]
    fn завершает_дочернюю_команду_по_лимиту() {
        let mut command = Command::new("sh");
        command.args(["-c", "exec sleep 30"]);
        let error = output_inner(
            &mut command,
            None,
            Instant::now() + Duration::from_secs(1),
            Duration::from_millis(30),
        )
        .unwrap_err();

        assert_eq!(error.kind(), std::io::ErrorKind::TimedOut);
        assert!(error.to_string().contains("тайм-аут"));
    }
}
