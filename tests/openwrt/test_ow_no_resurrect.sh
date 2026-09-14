#!/bin/sh
# tests/openwrt/test_ow_no_resurrect.sh - gates G: reconvergence (hotplug rules,
# cron check) запрещена без running+ready. После manual stop/failed start
# ifup/cron НЕ должны пересоздавать redirect/routing state.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-no-resurrect"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-nores.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

mkdir -p "$T/bin" "$T/uci"
export PATH="$T/bin:/usr/bin:/bin"
cat > "$T/bin/nft" <<'EOF'
#!/bin/sh
echo "nft:$*" >> "$CALLS"
exit 0
EOF
chmod +x "$T/bin/nft"
cat > "$T/bin/uci" <<'EOF'
#!/bin/sh
echo "uci:$*" >> "$CALLS"
exit 0
EOF
chmod +x "$T/bin/uci"
cat > "$T/bin/nslookup" <<'EOF'
#!/bin/sh
exit 0
EOF
chmod +x "$T/bin/nslookup"
# INIT_SCRIPT-стаб: running управляется флагом.
cat > "$T/init-stub" <<'EOF'
#!/bin/sh
[ "$1" = "running" ] && { [ -f "$READYFLAG" ] && exit 0 || exit 1; }
exit 0
EOF
chmod +x "$T/init-stub"
export CALLS="$T/calls" READYFLAG="$T/svc-running"
export INIT_SCRIPT="$T/init-stub"
export Z2K_CORE_READY="$T/ready"

export Z2K_ROOT="$REPO" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
mkdir -p "$T/etc" "$T/tmp" "$T/tmp/locks" "$T/root/bin" "$T/proc"
printf 'ENABLED=1\n' > "$T/etc/config"
export Z2K_CONFIG="$T/etc/config" Z2K_LISTS_DIR="$T/root/lists"
export Z2K_PROC_ROOT="$T/proc" Z2K_RT_HEALTH_DIR="$T/tmp/rt-health"
printf '#!/bin/sh\nexit 0\n' > "$T/root/bin/tg-mtproxy-client"
printf '#!/bin/sh\nexit 0\n' > "$T/root/bin/z2k-rt-proxy"
chmod +x "$T/root/bin/tg-mtproxy-client" "$T/root/bin/z2k-rt-proxy"
export Z2K_BIN="$T/root/bin" Z2K_TG_BIN="$T/root/bin/tg-mtproxy-client" Z2K_RT_BIN="$T/root/bin/z2k-rt-proxy"
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/paths.sh" || exit 1
. "$REPO/platform/openwrt/env.sh" || exit 1
. "$REPO/platform/openwrt/tg.sh" || exit 1
. "$REPO/platform/openwrt/rt.sh" || exit 1

_mutations() { grep -cE '^(nft:(add|insert|delete|flush)|uci:(set|delete|commit))' "$T/calls" 2>/dev/null || true; }

# --- 1. not ready (нет файла): rules/check ничего не создают ---
: > "$T/calls"
rm -f "$T/ready" "$T/svc-running"
z2k_ow_tg rules >/dev/null 2>&1
z2k_ow_tg check >/dev/null 2>&1
z2k_ow_rt rules >/dev/null 2>&1
z2k_ow_rt check >/dev/null 2>&1
assert_eq "not-ready: мутаций 0" "0" "$(_mutations)"

# --- 2. ready-файл есть, но сервис не running: тоже ничего ---
: > "$T/calls"
: > "$T/ready"
rm -f "$T/svc-running"
z2k_ow_tg rules >/dev/null 2>&1
z2k_ow_rt rules >/dev/null 2>&1
assert_eq "half-ready: мутаций 0" "0" "$(_mutations)"

# --- 3. running+ready: reconverge работает (гейт не запер штатное) ---
: > "$T/calls"
: > "$T/svc-running"
z2k_ow_tg rules >/dev/null 2>&1
if grep -q '^nft:add' "$T/calls"; then _t_ok
else _t_bad "ready: tg rules не применил правила"; fi

_t_done
