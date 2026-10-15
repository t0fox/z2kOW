use std::{
    fs,
    path::{Path, PathBuf},
    process::Command,
    time::{SystemTime, UNIX_EPOCH},
};

fn temporary_path() -> PathBuf {
    let nonce = SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .unwrap()
        .as_nanos();
    std::env::temp_dir().join(format!("z2k-warp-proc-{}-{nonce}", std::process::id()))
}

fn observe(root: &Path) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .arg("process-observe")
        .arg(root)
        .output()
        .expect("запуск CLI-контроллера");
    assert!(
        output.status.success(),
        "CLI завершился с ошибкой: {:?}",
        output
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn pids(root: &Path) -> String {
    let output = Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .arg("process-pids")
        .arg(root)
        .output()
        .expect("запуск CLI-контроллера");
    assert!(
        output.status.success(),
        "CLI завершился с ошибкой: {:?}",
        output
    );
    String::from_utf8(output.stdout).unwrap().trim().to_owned()
}

fn pids_status(root: &Path) -> std::process::ExitStatus {
    Command::new(env!("CARGO_BIN_EXE_z2k-warp-controller"))
        .arg("process-pids")
        .arg(root)
        .status()
        .expect("запуск CLI-контроллера")
}

fn process(root: &Path, pid: &str, comm: &str, cmdline: &[u8]) {
    let directory = root.join(pid);
    fs::create_dir_all(&directory).unwrap();
    fs::write(directory.join("comm"), format!("{comm}\n")).unwrap();
    fs::write(directory.join("cmdline"), cmdline).unwrap();
}

#[test]
fn пустой_proc_root_означает_что_движок_остановлен() {
    let root = temporary_path();
    fs::create_dir(&root).unwrap();

    assert_eq!(observe(&root), "absent");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn только_процесс_z2k_warpd_run_считается_живым_движком() {
    let root = temporary_path();
    fs::create_dir(&root).unwrap();
    process(&root, "101", "z2k-warpd", b"/usr/bin/z2k-warpd\0run\0");

    assert_eq!(observe(&root), "present");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn pids_cli_возвращает_только_процессы_движка_с_командой_run() {
    let root = temporary_path();
    fs::create_dir(&root).unwrap();
    process(&root, "101", "z2k-warpd", b"/usr/bin/z2k-warpd\0run\0");
    process(&root, "102", "z2k-warpd", b"/usr/bin/z2k-warpd\0register\0");
    process(&root, "103", "sleep", b"sleep\0run\0");

    assert_eq!(pids(&root), "101");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn pids_cli_откладывает_действие_при_ошибке_чтения_procfs() {
    let root = temporary_path();
    fs::write(&root, "это файл, а не proc root").unwrap();

    assert!(!pids_status(&root).success());
    fs::remove_file(root).unwrap();
}

#[test]
fn другая_команда_или_режим_движка_не_считается_туннелем() {
    let root = temporary_path();
    fs::create_dir(&root).unwrap();
    process(&root, "101", "sleep", b"sleep\0run\0");
    process(&root, "102", "z2k-warpd", b"/usr/bin/z2k-warpd\0register\0");

    assert_eq!(observe(&root), "absent");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn ошибка_чтения_proc_не_превращается_в_отсутствие_движка() {
    let root = temporary_path();
    fs::write(&root, "это файл, а не proc root").unwrap();

    assert_eq!(observe(&root), "unreadable");
    fs::remove_file(root).unwrap();
}

#[test]
fn ошибка_чтения_cmdline_совпавшего_процесса_не_считается_его_остановкой() {
    let root = temporary_path();
    fs::create_dir(&root).unwrap();
    let process = root.join("101");
    fs::create_dir_all(process.join("cmdline")).unwrap();
    fs::write(process.join("comm"), "z2k-warpd\n").unwrap();

    assert_eq!(observe(&root), "unreadable");
    fs::remove_dir_all(root).unwrap();
}
