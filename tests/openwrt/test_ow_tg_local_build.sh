#!/bin/sh
# Проверяет, что Rust-сборка берёт локальный crate и не обращается к Git.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-tg-local-build"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
BUILDER="$REPO/scripts/openwrt/build_tg_ws_proxy.sh"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-tg-local.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
mkdir -p "$T/bin"
export TEST_LOG_DIR="$T"

cat > "$T/bin/git" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG_DIR/git.log"
exit 93
EOF
cat > "$T/bin/rustup" <<'EOF'
#!/bin/sh
if [ "$1" = toolchain ] && [ "${2:-}" = list ]; then
    printf '%s\n' '1.98.0 (default)'
fi
exit 0
EOF
cat > "$T/bin/cargo" <<'EOF'
#!/bin/sh
printf '%s\n' "$*" >> "$TEST_LOG_DIR/cargo.log"
_target=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = --target ]; then _target="$2"; shift 2; else shift; fi
done
if [ -n "$_target" ]; then
    mkdir -p "$CARGO_TARGET_DIR/$_target/release"
    printf '#!/bin/sh\nexit 0\n' > "$CARGO_TARGET_DIR/$_target/release/tg-ws-proxy"
    chmod 0755 "$CARGO_TARGET_DIR/$_target/release/tg-ws-proxy"
fi
exit 0
EOF
for _tool in aarch64-linux-gnu-gcc cc ar; do
    printf '#!/bin/sh\nexit 0\n' > "$T/bin/$_tool"
    chmod 0755 "$T/bin/$_tool"
done
chmod 0755 "$T/bin/git" "$T/bin/rustup" "$T/bin/cargo"

if PATH="$T/bin:$PATH" sh "$BUILDER" "$T/out" >"$T/build.log" 2>&1; then
    _t_ok
else
    _t_bad "Rust builder completes without Git: $(tail -n 4 "$T/build.log" | tr '\n' ' ')"
fi
for _arch in arm64 x86_64; do
    if [ -x "$T/out/linux-$_arch/tg-ws-proxy" ]; then _t_ok; else _t_bad "builder emits $_arch tg-ws-proxy"; fi
done
if [ ! -s "$T/git.log" ]; then _t_ok; else _t_bad "builder does not invoke Git: $(cat "$T/git.log")"; fi
grep -q -- '--locked' "$T/cargo.log" && grep -q -- '--package z2kow-tg-transparent' "$T/cargo.log" \
    && _t_ok || _t_bad "builder runs locked Cargo commands for the local crate"
grep -q 'crate=platform/openwrt/tg-proxy' "$T/out/PROVENANCE" \
    && _t_ok || _t_bad "provenance identifies the local crate"
assert_file "crate MIT license is packaged" "$T/out/LICENSE"
_t_done
