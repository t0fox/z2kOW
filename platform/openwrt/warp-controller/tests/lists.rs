use std::{fs, path::PathBuf};
use warp_controller::lists::{
    PolicyScope, load_active_domains, load_active_lists, load_mark_policy_inputs,
    normalize_destinations, policy_scope, validate_entries,
};

#[test]
fn validator_matches_current_ip_and_domain_filter() {
    let input = "Example.COM\n*.Example.COM\nxn--e1afmkfd.xn--p1ai\n1.2.3.4/24\n# user note\n*.com\na..b\nhttps://a.com\n010.1.2.3\n::1";
    let result = validate_entries(input);
    assert_eq!(
        result.domains,
        ["example.com", "*.example.com", "xn--e1afmkfd.xn--p1ai"]
    );
    assert_eq!(result.addresses, ["1.2.3.4/24"]);
    assert_eq!(result.invalid, 5);
    assert_eq!(
        result.save_text(),
        "example.com\n*.example.com\nxn--e1afmkfd.xn--p1ai\n1.2.3.4/24\n# user note\n"
    );
}

#[test]
fn destination_ranges_merge_overlaps_and_adjacencies() {
    let input = "1.2.3.0/24\n1.2.3.0/25\n1.2.4.0/24\n1.2.5.0/24";
    assert_eq!(normalize_destinations(input), ["1.2.3.0/24", "1.2.4.0/23"]);
}

#[test]
fn invalid_address_and_domain_entries_never_reach_route_inputs() {
    let result = validate_entries("0.1.2.3\n192.168.1.1\n999.1.1.1\n*.bad-.example\nvalid.example");
    assert!(result.addresses.is_empty());
    assert_eq!(result.domains, ["valid.example"]);
    assert_eq!(result.invalid, 4);
}

#[test]
fn active_user_and_opt_in_game_lists_keep_separate_ownership() {
    let root = temp_dir("active");
    let users = root.join("user-lists/warp");
    let games = root.join("payload/lists/warp/games");
    fs::create_dir_all(&users).unwrap();
    fs::create_dir_all(&games).unwrap();
    fs::write(users.join("mine.txt"), "8.8.8.8\n").unwrap();
    fs::write(users.join("disabled.txt"), "9.9.9.9\n").unwrap();
    fs::write(users.join("devices.txt"), "192.168.1.2\n").unwrap();
    fs::write(users.join(".disabled"), "disabled\n").unwrap();
    fs::write(users.join(".enabled"), "steam\n../escape\n").unwrap();
    fs::write(games.join("steam.txt"), "1.1.1.1\n").unwrap();
    fs::write(games.join("unused.txt"), "2.2.2.2\n").unwrap();

    let snapshot = load_active_lists(
        &users,
        &games,
        &users.join(".enabled"),
        &users.join("devices.txt"),
    )
    .unwrap();
    assert_eq!(snapshot.validation.addresses, ["8.8.8.8", "1.1.1.1"]);
    assert!(snapshot.has_nonempty_input);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn policy_scope_counts_user_txt_files_like_the_shell_glob() {
    let root = temp_dir("scope-shell-glob");
    let users = root.join("user-lists/warp");
    let games = root.join("payload/lists/warp/games");
    fs::create_dir_all(&users).unwrap();
    fs::create_dir_all(&games).unwrap();
    fs::write(users.join("legacy list.txt"), "8.8.8.8\n").unwrap();
    fs::write(users.join(".hidden.txt"), "9.9.9.9\n").unwrap();

    let scope = policy_scope(
        &users,
        &games,
        &users.join(".enabled"),
        &users.join("devices.txt"),
    )
    .unwrap();

    assert_eq!(scope.as_str(), "lists");
    let snapshot = load_active_lists(
        &users,
        &games,
        &users.join(".enabled"),
        &users.join("devices.txt"),
    )
    .unwrap();
    assert_eq!(snapshot.validation.addresses, ["8.8.8.8"]);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn active_domains_ignore_disabled_lists_and_unreadable_device_state() {
    let root = temp_dir("domains");
    let users = root.join("user-lists/warp");
    let games = root.join("payload/lists/warp/games");
    fs::create_dir_all(&users).unwrap();
    fs::create_dir_all(&games).unwrap();
    fs::write(users.join("mine.txt"), "Mine.example\n").unwrap();
    fs::write(users.join("disabled.txt"), "disabled.example\n").unwrap();
    fs::write(users.join(".disabled"), "disabled\n").unwrap();
    fs::write(users.join(".enabled"), "steam\n").unwrap();
    fs::write(games.join("steam.txt"), "Steam.example\n").unwrap();
    fs::write(games.join("unused.txt"), "unused.example\n").unwrap();

    let domains = load_active_domains(&users, &games, &users.join(".enabled")).unwrap();

    assert_eq!(domains, ["mine.example", "steam.example"]);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn mark_policy_scope_and_domains_come_from_one_list_snapshot() {
    let root = temp_dir("mark-policy-inputs");
    let users = root.join("users");
    let games = root.join("games");
    fs::create_dir_all(&users).unwrap();
    fs::create_dir_all(&games).unwrap();
    fs::write(users.join("mine.txt"), "Example.COM\n8.8.8.8\n").unwrap();
    fs::write(users.join("devices.txt"), "192.168.1.9\n").unwrap();

    let inputs = load_mark_policy_inputs(
        &users,
        &games,
        &users.join(".enabled"),
        &users.join("devices.txt"),
    )
    .unwrap();

    assert_eq!(inputs.scope, PolicyScope::Devices);
    assert_eq!(inputs.domains, ["example.com"]);
    fs::remove_dir_all(root).unwrap();
}

#[test]
fn malformed_nonempty_sources_are_reported_instead_of_becoming_empty_desired_state() {
    let root = temp_dir("corrupt");
    fs::create_dir_all(&root).unwrap();
    fs::write(root.join("broken.txt"), "not a route\n").unwrap();
    let snapshot = load_active_lists(
        &root,
        &root.join("missing-games"),
        &root.join("missing-enabled"),
        &root.join("devices.txt"),
    )
    .unwrap();
    assert!(snapshot.validation.addresses.is_empty());
    assert_eq!(snapshot.validation.invalid, 1);
    assert!(snapshot.has_nonempty_input);
    fs::remove_dir_all(root).unwrap();
}

fn temp_dir(label: &str) -> PathBuf {
    let path = std::env::temp_dir().join(format!(
        "z2k-warp-lists-{label}-{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos()
    ));
    fs::create_dir_all(&path).unwrap();
    path
}
