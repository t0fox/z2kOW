use std::{fs, io::Cursor, os::unix::fs::PermissionsExt, path::PathBuf};
use warp_controller::list_ops::{
    delete_list, migrate_lists, save_devices, save_list, toggle_device, toggle_game_list,
    toggle_user_list,
};

#[test]
fn создание_списка_сохраняет_валидные_строки_и_считает_отброшенные() {
    let root = temp_dir("save");
    let result = save_list(
        &root,
        "custom",
        "create",
        Cursor::new("Example.COM\n8.8.8.8\n08.8.8.8\n# note\n"),
    )
    .unwrap();
    assert_eq!(
        (
            result.saved,
            result.saved_ip,
            result.saved_domain,
            result.skipped_invalid
        ),
        (2, 1, 1, 1)
    );
    assert_eq!(
        fs::read_to_string(root.join("custom.txt")).unwrap(),
        "example.com\n8.8.8.8\n# note\n"
    );
    assert!(save_list(&root, "custom", "create", Cursor::new("9.9.9.9\n")).is_err());
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn добавление_и_переключение_списков_идемпотентны() {
    let root = temp_dir("toggle");
    fs::create_dir_all(root.join("games")).unwrap();
    save_list(&root, "custom", "replace", Cursor::new("8.8.8.8")).unwrap();
    toggle_user_list(&root, "custom", false).unwrap();
    toggle_user_list(&root, "custom", false).unwrap();
    assert_eq!(
        fs::read_to_string(root.join(".disabled")).unwrap(),
        "custom\n"
    );
    toggle_user_list(&root, "custom", true).unwrap();
    assert_eq!(fs::read_to_string(root.join(".disabled")).unwrap(), "");

    fs::write(root.join("games/steam.txt"), "1.1.1.1\n").unwrap();
    let enabled = root.join(".enabled");
    toggle_game_list(&enabled, &root.join("games"), "steam", true).unwrap();
    toggle_game_list(&enabled, &root.join("games"), "steam", true).unwrap();
    assert_eq!(fs::read_to_string(enabled).unwrap(), "steam\n");
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn удаление_списка_снимает_его_отметку_выключения() {
    let root = temp_dir("delete");
    save_list(&root, "custom", "replace", Cursor::new("8.8.8.8\n")).unwrap();
    fs::write(root.join(".disabled"), "custom\nother\n").unwrap();
    delete_list(&root, "custom").unwrap();
    delete_list(&root, "custom").unwrap();
    assert_eq!(
        fs::read_to_string(root.join(".disabled")).unwrap(),
        "other\n"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn сохранение_устройств_нормализует_mac_и_отбрасывает_публичные_ip() {
    let root = temp_dir("devices");
    let counts = save_devices(
        &root,
        Cursor::new("AA-BB-CC-DD-EE-FF\n192.168.1.2\n8.8.8.8\ninvalid\n"),
    )
    .unwrap();
    assert_eq!(counts, (2, 2));
    assert_eq!(
        fs::read_to_string(root.join("devices.txt")).unwrap(),
        "aa:bb:cc:dd:ee:ff\n192.168.1.2\n"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn переключение_устройства_сохраняет_ручные_строки() {
    let root = temp_dir("device-toggle");
    let path = root.join("devices.txt");
    fs::write(
        &path,
        "# вручную\nAA-BB-CC-DD-EE-FF\n192.168.1.7\n\nnot-a-mac\n",
    )
    .unwrap();
    toggle_device(&root, "aa:bb:cc:dd:ee:ff", true).unwrap();
    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        "# вручную\n192.168.1.7\n\nnot-a-mac\naa:bb:cc:dd:ee:ff\n"
    );
    toggle_device(&root, "AA-BB-CC-DD-EE-FF", false).unwrap();
    assert_eq!(
        fs::read_to_string(&path).unwrap(),
        "# вручную\n192.168.1.7\n\nnot-a-mac\n"
    );
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn миграция_списков_удаляет_только_устаревшие_агрегаты() {
    let root = temp_dir("migrate");
    let users = root.join("users");
    let games = root.join("games");
    fs::create_dir_all(&users).unwrap();
    let custom = users.join("custom.txt");
    fs::write(&custom, "8.8.8.8\n").unwrap();
    fs::set_permissions(&custom, fs::Permissions::from_mode(0o600)).unwrap();
    for name in [
        "game-warp-ips.txt",
        ".game-warp-ips.base",
        ".game-warp-ips.upstream",
        ".game-warp-ips.removed",
        ".game-warp-ips.san",
    ] {
        fs::write(users.join(name), "legacy\n").unwrap();
    }

    migrate_lists(&users, &games).unwrap();

    assert!(games.is_dir());
    assert!(users.join(".legacy-aggregate-purged").is_file());
    assert_eq!(fs::read_to_string(&custom).unwrap(), "8.8.8.8\n");
    assert_eq!(
        fs::metadata(&custom).unwrap().permissions().mode() & 0o777,
        0o644
    );
    for name in [
        "game-warp-ips.txt",
        ".game-warp-ips.base",
        ".game-warp-ips.upstream",
        ".game-warp-ips.removed",
        ".game-warp-ips.san",
    ] {
        assert!(!users.join(name).exists());
    }
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn маркер_миграции_не_удаляет_созданный_позже_файл() {
    let root = temp_dir("migrate-marked");
    let users = root.join("users");
    let games = root.join("games");
    fs::create_dir_all(&users).unwrap();
    fs::write(users.join(".legacy-aggregate-purged"), "").unwrap();
    let legacy = users.join("game-warp-ips.txt");
    fs::write(&legacy, "user data\n").unwrap();

    migrate_lists(&users, &games).unwrap();

    assert_eq!(fs::read_to_string(legacy).unwrap(), "user data\n");
    fs::remove_dir_all(root).unwrap();
}

fn temp_dir(label: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "z2k-warp-list-ops-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}
