#!/bin/sh
# tests/openwrt/test_ow_common_hooks.sh - реестр minimal common hooks.
# Каждый hook: файл + паттерн + доказательство Keenetic-дефолта.
# Новый common hook без записи сюда (и в contract) — провал guard ниже
# через test_ow_upstream_diff (allowlist), здесь — содержимое хуков.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-common-hooks"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
AU="$REPO/lib/auto_update.sh"
CO="$REPO/lib/config_official.sh"
RM="$REPO/lib/release_map.sh"

_hook() {
    # $1 desc, $2 file, $3 hook pattern (ERE), $4 keenetic-default pattern (ERE)
    grep -qE -- "$3" "$2" 2>/dev/null || { _t_bad "$1: нет хука [$3]"; return; }
    if [ -n "$4" ]; then
        grep -qE -- "$4" "$2" 2>/dev/null || { _t_bad "$1: нет Keenetic-дефолта [$4]"; return; }
    fi
    _t_ok
}

_hook "PHASE3 via ZAPRET2_DIR" "$CO" \
    'safe_config_read "Z2K_REFACTOR_PHASE3" "\$\{ZAPRET2_DIR:-/opt/zapret2\}/config"' \
    'ZAPRET2_DIR:-/opt/zapret2'
_hook "release_map dispatcher" "$RM" \
    'z2k_install_paths_for "\$\{Z2K_PLATFORM:-keenetic\}"' \
    'Z2K_PLATFORM:-keenetic'
_hook "targetless fail-safe" "$AU" \
    'no install target for \$repo_path' \
    '\*/builds/\*'
_hook "regen-config path" "$AU" \
    'create_official_config "\$\{Z2K_CONFIG_FILE:' \
    'Z2K_CONFIG_FILE:-\$\{ZAPRET2_DIR\}'
_hook "validate-config path" "$AU" \
    'sh "\$v" "\$\{Z2K_CONFIG_FILE:' \
    'Z2K_CONFIG_FILE:-\$\{ZAPRET2_DIR\}'
_hook "restart ENABLED-check path" "$AU" \
    '_rs_cfg="\$\{Z2K_CONFIG_FILE:' \
    'Z2K_CONFIG_FILE:-\$\{ZAPRET2_DIR:-/opt/zapret2\}/config'
_hook "flags save path" "$AU" \
    'local config_file="\$\{Z2K_CONFIG_FILE:' \
    'Z2K_CONFIG_FILE:-\$\{ZAPRET2_DIR:-/opt/zapret2\}/config'
_hook "merge shipped path" "$AU" \
    'Z2K_EXTRA_DOMAINS_SHIPPED:-\$zd/files/lists/extra-domains.txt' \
    'files/lists/extra-domains.txt'
_hook "merge runtime path" "$AU" \
    'Z2K_EXTRA_DOMAINS_RUNTIME:-\$zd/lists/extra-domains.txt' \
    'lists/extra-domains.txt'
_hook "RAW_BASE default" "$AU" \
    'Z2K_AU_RAW_BASE="\$\{Z2K_AU_RAW_BASE:-https://raw.githubusercontent.com/necronicle/z2k\}"' \
    'necronicle/z2k\}"'
_hook "repo_base via RAW_BASE" "$AU" \
    'printf .%s/%s. "\$\{Z2K_AU_RAW_BASE:' \
    'Z2K_AU_RAW_BASE:-https://raw.githubusercontent.com/necronicle/z2k'
_hook "reinstall pin via RAW_BASE" "$AU" \
    'GITHUB_RAW="\$\{Z2K_AU_RAW_BASE:-https://raw.githubusercontent.com/necronicle/z2k\}/\$Z2K_AU_TARGET_REF' \
    'necronicle/z2k\}/\$Z2K_AU_TARGET_REF'
_hook "reinstall executor hook" "$AU" \
    'Z2K_AU_REINSTALL_EXECUTOR:-\}' \
    'command -v "\$Z2K_AU_REINSTALL_EXECUTOR"'
_hook "rollback restart hook" "$AU" \
    '"\$INIT_SCRIPT" restart' \
    'INIT_SCRIPT:-/opt/etc/init.d/S99zapret2'
_hook "health init hook" "$AU" \
    '"\$\{INIT_SCRIPT:-/opt/etc/init.d/S99zapret2\}" "\$_zd"/lib' \
    'INIT_SCRIPT:-/opt/etc/init.d/S99zapret2'
_hook "fails-counter hook" "$AU" \
    '_ac_fails_file="\$\{Z2K_AU_FAILS_FILE:' \
    'Z2K_AU_FAILS_FILE:-\$\{ZAPRET2_DIR:-/opt/zapret2\}/state/au-delivery-fails'
_hook "platform gate fn" "$AU" \
    '^au_manifest_platform_ok\(\)' \
    'Z2K_PLATFORM:-keenetic'

# --- freeze audit: validator paths + merge/dirty/converge ---
VAL="$REPO/files/z2k-config-validator.sh"
_hook "validator FAKE_DIR" "$VAL" \
    'FAKE_DIR="\$\{Z2K_FAKE_DIR:-\$\{ZAPRET_BASE\}/files/fake\}"' \
    'ZAPRET_BASE\}/files/fake'
_hook "validator lua EXTRA" "$VAL" \
    'Z2K_LUA_EXTRA_DIRS' \
    'ZAPRET_BASE\}/lua'
_hook "merge failure propagates" "$AU" \
    'merge extra-domains: не записался runtime' \
    'return 1'
_hook "converge dirty refusal" "$AU" \
    'au_tree_is_dirty' \
    'нужен reinstall'
_hook "converge TARGET_REF pin" "$AU" \
    'Z2K_AU_TARGET_REF=.*au_manifest_ref' \
    'au_manifest_ref'

_t_done
