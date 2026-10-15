#!/bin/sh
set -eu

ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
CRATE="$ROOT/platform/openwrt/warp-controller"
if [ "${1:-}" = --inside ]; then
    T="$2"
    nft add table inet z2k_warp_controller_test
    trap 'nft delete table inet fw4 2>/dev/null || true; nft delete table inet z2k_warp_controller_test 2>/dev/null || true' EXIT HUP INT TERM
    nft add table inet fw4
    nft add chain inet fw4 forward '{ type filter hook forward priority filter; policy accept; }'
    mkdir -p "$T/list-users" "$T/list-games" "$T/all-users" "$T/full-users"
    printf '1.2.3.4\nexample.com\n' > "$T/list-users/custom.txt"
    : > "$T/list-users/devices.txt"
    printf '192.168.1.9\n' > "$T/full-users/devices.txt"
    _mark_config="$T/mark-config"
    printf 'Z2K_WARP_WDTT=0\n' > "$_mark_config"
    mark_apply() {
        _users="$1" _games="$2" _config="$3" _lan="$4" _servers="$5" _clients="$6"
        "$CRATE/target/debug/z2k-warp-controller" nft-mark-apply \
            inet z2k_warp_controller_test z2k_mark z2k_dst z2k_src z2k_domain \
            "$_users" "$_games" "$_users/.enabled" "$_users/devices.txt" \
            "$_config" "$_lan" "$_servers" "$_clients"
    }
    mark_verify() {
        _users="$1" _games="$2" _config="$3" _lan="$4" _servers="$5" _clients="$6"
        "$CRATE/target/debug/z2k-warp-controller" nft-mark-verify \
            inet z2k_warp_controller_test z2k_mark z2k_dst z2k_src z2k_domain \
            "$_users" "$_games" "$_users/.enabled" "$_users/devices.txt" \
            "$_config" "$_lan" "$_servers" "$_clients"
    }
    "$CRATE/target/debug/z2k-warp-controller" nft-fw4-forward-apply \
        inet fw4 forward z2ktun0 0x80000000 0x80000000 \
        '!z2k: WARP forwarded traffic'
    ready=$("$CRATE/target/debug/z2k-warp-controller" nft-fw4-forward-verify \
        inet fw4 forward z2ktun0 0x80000000 0x80000000 \
        '!z2k: WARP forwarded traffic')
    [ "$ready" = ready=1 ]
    nft list chain inet fw4 forward | grep -F 'oifname "z2ktun0" accept comment "!z2k: WARP forwarded traffic"'
    nft add chain inet fw4 conflict
    nft add rule inet fw4 conflict oifname eth0 accept \
        comment '"!z2k: WARP forwarded traffic"'
    before="$(nft -a list chain inet fw4 conflict)"
    if "$CRATE/target/debug/z2k-warp-controller" nft-fw4-forward-apply \
        inet fw4 conflict z2ktun0 0x80000000 0x80000000 \
        '!z2k: WARP forwarded traffic'; then
        echo "чужое fw4 правило WARP принято за своё" >&2
        exit 1
    fi
    after="$(nft -a list chain inet fw4 conflict)"
    [ "$before" = "$after" ] || { echo "fw4 conflict мутировал цепочку" >&2; exit 1; }
    before="$(nft -a list chain inet fw4 forward)"
    "$CRATE/target/debug/z2k-warp-controller" nft-fw4-forward-apply \
        inet fw4 forward z2ktun0 0x80000000 0x80000000 \
        '!z2k: WARP forwarded traffic'
    after="$(nft -a list chain inet fw4 forward)"
    [ "$before" = "$after" ] || { echo "fw4 правило мутировано без необходимости" >&2; exit 1; }
    printf '%s\n' \
        'add rule inet fw4 forward meta mark & 0x80000000 == 0x80000000 oifname "z2ktun12" accept comment "!z2k: WARP forwarded traffic"' \
        'add rule inet fw4 forward meta mark & 0x80000000 == 0x80000000 oifname "z2ktun*" accept comment "!z2k: WARP forwarded traffic"' \
        | nft -f -
    "$CRATE/target/debug/z2k-warp-controller" nft-fw4-forward-remove \
        inet fw4 forward '!z2k: WARP forwarded traffic'
    after="$(nft list chain inet fw4 forward)"
    printf '%s\n' "$after" | grep -F 'oifname "z2ktun*" accept comment "!z2k: WARP forwarded traffic"'
    if printf '%s\n' "$after" | grep -E 'oifname "z2ktun(0|12)"'; then
        echo "временное fw4 WARP правило осталось после очистки" >&2
        exit 1
    fi
    "$CRATE/target/debug/z2k-warp-controller" nft-domain-set-ensure \
        inet z2k_warp_controller_test z2k_domain
    nft list set inet z2k_warp_controller_test z2k_domain \
        | grep -F 'comment "z2k WARP DNS pairs"'
    before="$(nft -a list table inet z2k_warp_controller_test)"
    "$CRATE/target/debug/z2k-warp-controller" nft-domain-set-ensure \
        inet z2k_warp_controller_test z2k_domain
    after="$(nft -a list table inet z2k_warp_controller_test)"
    [ "$before" = "$after" ] || { echo "nft-набор доменов мутирован без необходимости" >&2; exit 1; }
    nft add set inet z2k_warp_controller_test z2k_foreign \
        '{ type ipv4_addr; comment "foreign"; }'
    if "$CRATE/target/debug/z2k-warp-controller" nft-domain-set-ensure \
        inet z2k_warp_controller_test z2k_foreign; then
        echo "чужой nft-набор принят за принадлежащий WARP" >&2
        exit 1
    fi
    nft list set inet z2k_warp_controller_test z2k_foreign \
        | grep -F 'comment "foreign"'
    "$CRATE/target/debug/z2k-warp-controller" nft-domain-observer-apply \
        inet z2k_warp_dns_test z2k_dns_output z2k_dns_forward 189 br-lan,wlan0
    ready=$("$CRATE/target/debug/z2k-warp-controller" nft-domain-verify \
        inet z2k_warp_controller_test z2k_domain \
        inet z2k_warp_dns_test z2k_dns_output z2k_dns_forward 189)
    [ "$ready" = ready=1 ]
    nft list table inet z2k_warp_dns_test \
        | grep -F 'comment "z2k WARP passive DNS observer"'
    nft list chain inet z2k_warp_dns_test z2k_dns_output \
        | grep -F 'log group 189'
    before="$(nft -a list table inet z2k_warp_dns_test)"
    "$CRATE/target/debug/z2k-warp-controller" nft-domain-observer-apply \
        inet z2k_warp_dns_test z2k_dns_output z2k_dns_forward 189 br-lan,wlan0
    after="$(nft -a list table inet z2k_warp_dns_test)"
    [ "$before" = "$after" ] || { echo "observer nft мутирован без необходимости" >&2; exit 1; }
    "$CRATE/target/debug/z2k-warp-controller" nft-sync \
        "$T/users" "$T/games" "$T/users/.enabled" "$T/users/devices.txt" \
        inet z2k_warp_controller_test z2k_dst z2k_src
    nft list set inet z2k_warp_controller_test z2k_dst | grep -F '1.2.3.4'
    nft list set inet z2k_warp_controller_test z2k_src | grep -F '192.168.1.9'
    before="$(nft -a list table inet z2k_warp_controller_test)"
    "$CRATE/target/debug/z2k-warp-controller" nft-sync \
        "$T/users" "$T/games" "$T/users/.enabled" "$T/users/devices.txt" \
        inet z2k_warp_controller_test z2k_dst z2k_src
    after="$(nft -a list table inet z2k_warp_controller_test)"
    [ "$before" = "$after" ] || { echo "неизменный nft-набор вызвал мутацию" >&2; exit 1; }
    ready=$("$CRATE/target/debug/z2k-warp-controller" nft-sets-verify \
        "$T/users" "$T/games" "$T/users/.enabled" "$T/users/devices.txt" \
        inet z2k_warp_controller_test z2k_dst z2k_src)
    [ "$ready" = ready=1 ]
    nft delete element inet z2k_warp_controller_test z2k_dst '{ 1.2.3.4 }'
    ready=$("$CRATE/target/debug/z2k-warp-controller" nft-sets-verify \
        "$T/users" "$T/games" "$T/users/.enabled" "$T/users/devices.txt" \
        inet z2k_warp_controller_test z2k_dst z2k_src)
    [ "$ready" = ready=0 ]
    "$CRATE/target/debug/z2k-warp-controller" nft-sync \
        "$T/users" "$T/games" "$T/users/.enabled" "$T/users/devices.txt" \
        inet z2k_warp_controller_test z2k_dst z2k_src
    ready=$("$CRATE/target/debug/z2k-warp-controller" nft-sets-verify \
        "$T/users" "$T/games" "$T/users/.enabled" "$T/users/devices.txt" \
        inet z2k_warp_controller_test z2k_dst z2k_src)
    [ "$ready" = ready=1 ]
    mkdir -p "$T/no-nft"
    cat > "$T/no-nft/ip" <<'EOF_IP'
#!/bin/sh
exit 0
EOF_IP
    chmod 0755 "$T/no-nft/ip"
    if output=$(PATH="$T/no-nft" "$CRATE/target/debug/z2k-warp-controller" nft-sets-verify \
        "$T/users" "$T/games" "$T/users/.enabled" "$T/users/devices.txt" \
        inet z2k_warp_controller_test z2k_dst z2k_src 2>&1); then
        echo "ошибка чтения nft принята за подтверждённое состояние наборов" >&2
        exit 1
    fi
    case "$output" in *ready=0*) echo "ошибка nft скрыта как несовпадение sets" >&2; exit 1 ;; esac
    mkdir -p "$T/domain-users" "$T/domain-games"
    printf 'example.com\n' > "$T/domain-users/custom.txt"
    : > "$T/domain-users/devices.txt"
    "$CRATE/target/debug/z2k-warp-controller" nft-sync \
        "$T/domain-users" "$T/domain-games" "$T/domain-users/.enabled" \
        "$T/domain-users/devices.txt" inet z2k_warp_controller_test z2k_dst z2k_src
    ! nft list set inet z2k_warp_controller_test z2k_dst | grep -F '1.2.3.4'
    ! nft list set inet z2k_warp_controller_test z2k_src | grep -F '192.168.1.9'
    before="$(nft -a list table inet z2k_warp_controller_test)"
    "$CRATE/target/debug/z2k-warp-controller" nft-sync \
        "$T/domain-users" "$T/domain-games" "$T/domain-users/.enabled" \
        "$T/domain-users/devices.txt" inet z2k_warp_controller_test z2k_dst z2k_src
    after="$(nft -a list table inet z2k_warp_controller_test)"
    [ "$before" = "$after" ] || { echo "nft-sync доменного списка должен быть идемпотентным" >&2; exit 1; }
    "$CRATE/target/debug/z2k-warp-controller" nft-sync \
        "$T/users" "$T/games" "$T/users/.enabled" "$T/users/devices.txt" \
        inet z2k_warp_controller_test z2k_dst z2k_src
    "$CRATE/target/debug/z2k-warp-controller" nft-tun-apply \
        inet z2k_warp_controller_test z2k_mss z2k_fwd z2k_nat z2ktun0
    ready=$("$CRATE/target/debug/z2k-warp-controller" nft-tun-verify \
        inet z2k_warp_controller_test z2k_mss z2k_fwd z2k_nat z2ktun0)
    [ "$ready" = ready=1 ]
    nft list chain inet z2k_warp_controller_test z2k_mss | grep -F 'maxseg size set rt mtu'
    nft list chain inet z2k_warp_controller_test z2k_mss | grep -F 'maxseg size set 1240'
    nft list chain inet z2k_warp_controller_test z2k_fwd | grep -F 'accept'
    nft list chain inet z2k_warp_controller_test z2k_nat | grep -F 'masquerade'
    "$CRATE/target/debug/z2k-warp-controller" nft-tun-apply \
        inet z2k_warp_controller_test z2k_mss z2k_fwd z2k_nat z2ktun0
    nft add rule inet z2k_warp_controller_test z2k_fwd counter
    ready=$("$CRATE/target/debug/z2k-warp-controller" nft-tun-verify \
        inet z2k_warp_controller_test z2k_mss z2k_fwd z2k_nat z2ktun0)
    [ "$ready" = ready=0 ]
    "$CRATE/target/debug/z2k-warp-controller" nft-tun-apply \
        inet z2k_warp_controller_test z2k_mss z2k_fwd z2k_nat z2ktun0
    ready=$("$CRATE/target/debug/z2k-warp-controller" nft-tun-verify \
        inet z2k_warp_controller_test z2k_mss z2k_fwd z2k_nat z2ktun0)
    [ "$ready" = ready=1 ]
    mkdir -p "$T/no-nft"
    if output="$(PATH="$T/no-nft" "$CRATE/target/debug/z2k-warp-controller" \
        nft-tun-verify inet z2k_warp_controller_test z2k_mss z2k_fwd z2k_nat z2ktun0 2>&1)"; then
        echo "ошибка чтения nft принята за готовое состояние" >&2
        exit 1
    fi
    case "$output" in *ready=0*) echo "ошибка nft скрыта как пустое состояние" >&2; exit 1 ;; esac
    mark_apply "$T/list-users" "$T/list-games" "$_mark_config" "" wgserver0 ""
    ready=$(mark_verify "$T/list-users" "$T/list-games" "$_mark_config" "" wgserver0 "")
    [ "$ready" = ready=1 ] || {
        nft list chain inet z2k_warp_controller_test z2k_mark
        echo "неожиданный результат nft-mark-verify: $ready" >&2
        exit 1
    }
    if output=$(PATH="$T/no-nft" mark_verify \
        "$T/list-users" "$T/list-games" "$_mark_config" "" wgserver0 "" 2>&1); then
        echo "ошибка чтения nft принята как готовое состояние MARK" >&2
        exit 1
    fi
    case "$output" in *ready=0*) echo "ошибка nft скрыта как несовпадение MARK" >&2; exit 1 ;; esac
    mkdir "$T/unreadable-config"
    if output=$(mark_verify \
        "$T/list-users" "$T/list-games" "$T/unreadable-config" "" wgserver0 "" 2>&1); then
        echo "ошибка чтения конфигурации принята как готовое состояние MARK" >&2
        exit 1
    fi
    case "$output" in *ready=0*) echo "ошибка конфигурации скрыта как несовпадение MARK" >&2; exit 1 ;; esac
    before="$(nft -a list chain inet z2k_warp_controller_test z2k_mark)"
    if mark_apply "$T/list-users" "$T/list-games" "$T/unreadable-config" "" wgserver0 ""; then
        echo "nft-mark-apply принял ошибку чтения конфигурации" >&2
        exit 1
    fi
    after="$(nft -a list chain inet z2k_warp_controller_test z2k_mark)"
    [ "$before" = "$after" ] || { echo "ошибка config мутировала MARK-цепь" >&2; exit 1; }
    mkdir -p "$T/broken-users" "$T/broken-games"
    printf '\377' > "$T/broken-users/broken.txt"
    : > "$T/broken-users/devices.txt"
    before="$(nft -a list chain inet z2k_warp_controller_test z2k_mark)"
    if mark_apply "$T/broken-users" "$T/broken-games" "$_mark_config" "" wgserver0 ""; then
        echo "nft-mark-apply принял повреждённый список" >&2
        exit 1
    fi
    after="$(nft -a list chain inet z2k_warp_controller_test z2k_mark)"
    [ "$before" = "$after" ] || { echo "ошибка списка мутировала MARK-цепь" >&2; exit 1; }
    before="$(nft -a list chain inet z2k_warp_controller_test z2k_mark)"
    mark_apply "$T/list-users" "$T/list-games" "$_mark_config" "" wgserver0 ""
    after="$(nft -a list chain inet z2k_warp_controller_test z2k_mark)"
    [ "$before" = "$after" ] || { echo "неизменная MARK-цепь мутирована" >&2; exit 1; }
    nft add rule inet z2k_warp_controller_test z2k_mark counter
    ready=$(mark_verify "$T/list-users" "$T/list-games" "$_mark_config" "" wgserver0 "")
    [ "$ready" = ready=0 ]
    mark_apply "$T/list-users" "$T/list-games" "$_mark_config" "" wgserver0 ""
    ready=$(mark_verify "$T/list-users" "$T/list-games" "$_mark_config" "" wgserver0 "")
    [ "$ready" = ready=1 ]
    nft list chain inet z2k_warp_controller_test z2k_mark | grep -F 'ip daddr @z2k_dst meta mark set'
    nft list chain inet z2k_warp_controller_test z2k_mark \
        | grep -F 'ip saddr . ip daddr @z2k_domain meta mark set'
    nft list chain inet z2k_warp_controller_test z2k_mark | grep -F 'iifname "wgserver0" return'
    _all_config="$T/all-config"
    printf 'Z2K_WARP_WDTT=1\n' > "$_all_config"
    mark_apply "$T/all-users" "$T/list-games" "$_all_config" br-lan,wlan0 wgserver0 ""
    nft list chain inet z2k_warp_controller_test z2k_mark | grep -F 'ip daddr 192.168.0.0/16 return'
    nft list chain inet z2k_warp_controller_test z2k_mark | grep -F 'iifname "br-lan" meta mark set'
    nft list chain inet z2k_warp_controller_test z2k_mark | grep -F 'iifname "wlan0" meta mark set'
    mark_apply "$T/users" "$T/games" "$_all_config" "" wgserver0 wgclient0
    nft list chain inet z2k_warp_controller_test z2k_mark | grep -F 'ip saddr @z2k_src ip daddr @z2k_dst meta mark set'
    nft list chain inet z2k_warp_controller_test z2k_mark | grep -F 'iifname "wgclient0" ip saddr 192.168.0.0/16 ip daddr @z2k_dst'
    mark_apply "$T/full-users" "$T/list-games" "$_mark_config" "" wgserver0 ""
    nft list chain inet z2k_warp_controller_test z2k_mark | grep -F 'ip daddr != 192.168.0.0/16'
    "$CRATE/target/debug/z2k-warp-controller" nft-tun-apply \
        inet z2k_warp_controller_test z2k_mss z2k_fwd z2k_nat z2ktun0
    nft add chain inet z2k_warp_controller_test z2k_foreign
    nft add rule inet z2k_warp_controller_test z2k_foreign counter
    "$CRATE/target/debug/z2k-warp-controller" nft-chain-clear \
        inet z2k_warp_controller_test z2k_mark z2k_mss z2k_fwd z2k_nat
    ! nft list chain inet z2k_warp_controller_test z2k_mark | grep -q 'meta mark set'
    ! nft list chain inet z2k_warp_controller_test z2k_fwd | grep -q 'oifname'
    nft list chain inet z2k_warp_controller_test z2k_foreign | grep -F 'counter'
    before="$(nft -a list table inet z2k_warp_controller_test)"
    "$CRATE/target/debug/z2k-warp-controller" nft-chain-clear \
        inet z2k_warp_controller_test z2k_mark z2k_mss z2k_fwd z2k_nat
    after="$(nft -a list table inet z2k_warp_controller_test)"
    [ "$before" = "$after" ] || { echo "пустые nft-цепочки мутированы повторно" >&2; exit 1; }
    mkdir -p "$T/no-nft"
    if PATH="$T/no-nft" "$CRATE/target/debug/z2k-warp-controller" nft-chain-clear \
        inet z2k_warp_controller_test z2k_mark >/dev/null 2>&1; then
        echo "ошибка чтения nft скрыта при очистке цепочек" >&2
        exit 1
    fi
    "$CRATE/target/debug/z2k-warp-controller" nft-domain-remove \
        inet z2k_warp_dns_test inet z2k_warp_controller_test z2k_domain 0
    ready=$("$CRATE/target/debug/z2k-warp-controller" nft-domain-verify \
        inet z2k_warp_controller_test z2k_domain \
        inet z2k_warp_dns_test z2k_dns_output z2k_dns_forward 189)
    [ "$ready" = ready=0 ]
    if nft list table inet z2k_warp_dns_test >/dev/null 2>&1; then
        echo "owned observer table survived domain removal" >&2
        exit 1
    fi
    nft list set inet z2k_warp_controller_test z2k_domain \
        | grep -F 'comment "z2k WARP DNS pairs"'
    "$CRATE/target/debug/z2k-warp-controller" nft-warp-remove \
        inet z2k_warp_controller_test 0 z2k_mark z2k_mss z2k_fwd z2k_nat \
        z2k_dst z2k_src
    if nft list chain inet z2k_warp_controller_test z2k_mark >/dev/null 2>&1; then
        echo "обычная очистка оставила WARP MARK-цепочку" >&2
        exit 1
    fi
    nft list set inet z2k_warp_controller_test z2k_dst >/dev/null
    nft list chain inet z2k_warp_controller_test z2k_foreign | grep -F 'counter'
    "$CRATE/target/debug/z2k-warp-controller" nft-domain-remove \
        inet z2k_warp_dns_test inet z2k_warp_controller_test z2k_domain 1
    "$CRATE/target/debug/z2k-warp-controller" nft-warp-remove \
        inet z2k_warp_controller_test 1 z2k_mark z2k_mss z2k_fwd z2k_nat \
        z2k_dst z2k_src
    if nft list set inet z2k_warp_controller_test z2k_dst >/dev/null 2>&1; then
        echo "полная очистка оставила WARP-набор" >&2
        exit 1
    fi
    nft list chain inet z2k_warp_controller_test z2k_foreign | grep -F 'counter'
    printf 'SUITE[ow-warp-controller-real-nft]: pass\n'
    exit 0
fi

for tool in cargo unshare nft ip; do
    command -v "$tool" >/dev/null 2>&1 || { echo "требуется реальный инструмент $tool" >&2; exit 1; }
done
cargo build --manifest-path "$CRATE/Cargo.toml" --bin z2k-warp-controller
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-warp-controller-nft.XXXXXX")"
trap 'rm -rf "$T"' EXIT HUP INT TERM
mkdir -p "$T/users" "$T/games"
printf '1.2.3.4\n' > "$T/users/public.txt"
printf '192.168.1.9\n' > "$T/users/devices.txt"
unshare -Urn "$0" --inside "$T"
