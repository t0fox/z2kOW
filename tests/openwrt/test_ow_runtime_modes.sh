#!/bin/sh
# tests/openwrt/test_ow_runtime_modes.sh - mode contract runtime (live-урок p-84.17).
# create_ipset.sh уехал в пакет 0644 (INSTALL_DATA), хотя EXEC'ится
# ($IPSET_CR "$@"): Permission denied убил ipsets, hook jumps и весь dataplane
# при живом nfqws2 и job success. Closure-тест сверял только пути.
# Два уровня:
#   A. статика (всегда): recipe Makefile ставит mode из contract
#      (INSTALL_BIN=0755 / INSTALL_DATA=0644) для каждого closure-пути.
#   B. динамика (с Z2K_RT_TARBALL): настоящее исполнение recipe-текста
#      Barracoon-стабами в staging + test -x/-r сверка с contract.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-runtime-modes"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
MK="$REPO/package/z2k-runtime/Makefile"
CONTRACT="$REPO/package/z2k-runtime/runtime-mode.contract"
CLOSURE="$REPO/package/z2k-runtime/runtime-closure.txt"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rtmode.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

assert_file "contract существует" "$CONTRACT"
# contract ⊆ closure и closure ⊆ contract (дрейф в любую сторону запрещён).
while IFS= read -r _l; do
    case "$_l" in ''|'#'*) continue;; esac
    _p="${_l%% *}"
    grep -qxF "$_p" "$CLOSURE" 2>/dev/null && _t_ok \
        || _t_bad "contract-путь вне closure: $_p"
done < "$CONTRACT"
while IFS= read -r _e; do
    case "$_e" in ''|'#'*) continue;; esac
    grep -q "^$_e " "$CONTRACT" 2>/dev/null && _t_ok \
        || _t_bad "closure-путь вне contract: $_e"
done < "$CLOSURE"

# --- A. статика recipe ---
_RC="$(sed -n '/^define Package\/z2k-zapret2-runtime\/install$/,/^endef$/p' "$MK" 2>/dev/null)"
[ -n "$_RC" ] || { echo "FAIL[ow-runtime-modes]: нет recipe" >&2; exit 1; }
while IFS= read -r _l; do
    case "$_l" in ''|'#'*) continue;; esac
    _p="${_l%% *}"; _rest="${_l#* }"
    _role="${_rest%% *}"; _mode="${_rest##* }"
    _want="INSTALL_DATA"; [ "$_mode" = "0755" ] && _want="INSTALL_BIN"
    _line="$(printf '%s\n' "$_RC" | grep -F "/opt/zapret2/$_p" | head -1)"
    [ -n "$_line" ] || { _t_bad "recipe не ставит $_p"; continue; }
    case "$_line" in
        *"$_want"*) _t_ok ;;
        *)
            # lua едет shell-редиректом (umask 0644): допустимо только для
            # non-exec ролей; exec обязан быть явным INSTALL_BIN.
            if [ "$_role" = "exec" ]; then
                _t_bad "recipe ставит exec $_p не как INSTALL_BIN: $_line"
            else
                _t_ok
            fi
            ;;
    esac
done < "$CONTRACT"

# --- B. динамика: исполнить recipe-текст в staging ---
if [ -n "${Z2K_RT_TARBALL:-}" ] && [ -f "$Z2K_RT_TARBALL" ]; then
    _bd="$T/build"; _dst="$T/dest"
    mkdir -p "$_bd" "$_dst" || exit 1
    tar -xzf "$Z2K_RT_TARBALL" -C "$_bd" --strip-components=1 2>/dev/null \
        || { echo "FAIL[ow-runtime-modes]: распаковка tarball" >&2; exit 1; }
    # Стабы make-функций; $(1) рецепта -> $D1.
    INSTALL_DIR() { mkdir -p "$@"; }
    INSTALL_BIN() { install -m0755 "$@"; }
    INSTALL_DATA() { install -m0644 "$@"; }
    export PKG_BUILD_DIR="$_bd" D1="$_dst" Z2K_RT_BINARCH="linux-arm64" ARCH="aarch64"
    printf '%s\n' "$_RC" | sed -e '1d' -e '$d' -e 's/\$(INSTALL_DIR)/INSTALL_DIR/g' \
        -e 's/\$(INSTALL_BIN)/INSTALL_BIN/g' -e 's/\$(INSTALL_DATA)/INSTALL_DATA/g' \
        -e 's/\$(PKG_BUILD_DIR)/$PKG_BUILD_DIR/g' -e 's/\$(Z2K_RT_BINARCH)/$Z2K_RT_BINARCH/g' \
        -e 's/\$(ARCH)/$ARCH/g' -e 's/\$(1)/$D1/g' > "$T/recipe.sh"
    ( . "$T/recipe.sh" ) 2>"$T/recipe.err" \
        || { echo "FAIL[ow-runtime-modes]: исполнение recipe:" >&2; cat "$T/recipe.err" >&2; exit 1; }
    _t_ok # recipe исполнился
    while IFS= read -r _l; do
        case "$_l" in ''|'#'*) continue;; esac
        _p="${_l%% *}"; _rest="${_l#* }"
        _role="${_rest%% *}"; _mode="${_rest##* }"
        if [ "$_mode" = "0755" ]; then
            [ -x "$_dst/opt/zapret2/$_p" ] && _t_ok \
                || _t_bad "staging: $_p не executable (role $_role)"
        else
            [ -f "$_dst/opt/zapret2/$_p" ] && [ ! -x "$_dst/opt/zapret2/$_p" ] && _t_ok \
                || _t_bad "staging: $_p отсутствует или executable (role $_role)"
        fi
    done < "$CONTRACT"
else
    echo "SKIP[ow-runtime-modes]: нет Z2K_RT_TARBALL (динамику докажет CI)"
fi

_t_done
