#!/bin/sh
# One complete artifact, one state, one install_release(tag) convergence path.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-unified-release"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
. "$REPO/lib/auto_update.sh"
. "$REPO/platform/openwrt/manifest.sh"
. "$REPO/platform/openwrt/release.sh"
Z2K_TEST_PYTHON="${Z2K_TEST_PYTHON:-python3}"
Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
export Z2K_ADAPTER_DIR

jsonfilter() {
    _file="" _expr=""
    while [ "$#" -gt 0 ]; do
        case "$1" in
            -i) _file="$2"; shift 2 ;;
            -e) _expr="$2"; shift 2 ;;
            *) return 2 ;;
        esac
    done
    _path="${_expr#@.}"
    case "$_path" in
        upstream.*) _section=upstream; _key="${_path#upstream.}" ;;
        artifact.*) _section=artifact; _key="${_path#artifact.}" ;;
        signing.*) _section=signing; _key="${_path#signing.}" ;;
        *) _section=root; _key="$_path" ;;
    esac
    awk -v section="$_section" -v key="$_key" '
        section == "root" && $1 == "\"" key "\":" {
            value=$2; gsub(/[",]/, "", value); print value; exit
        }
        section == "upstream" && /^  "upstream"[[:space:]]*:/ { active=1; next }
        section == "artifact" && /^  "artifact"[[:space:]]*:/ { active=1; next }
        section == "signing" && /^  "signing"[[:space:]]*:/ { active=1; next }
        active && /^  [}]/{ active=0 }
        active && $1 == "\"" key "\":" {
            value=$2; gsub(/[",]/, "", value); print value; exit
        }
    ' "$_file"
}

_CURRENT_TAG="$(jsonfilter -i "$REPO/UPDATES.json" -e '@.current')"
_CURRENT_SEQ="$(jsonfilter -i "$REPO/UPDATES.json" -e '@.seq')"
[ -n "$_CURRENT_TAG" ] && [ -n "$_CURRENT_SEQ" ] || { echo 'FAIL[ow-unified-release]: controlled release manifest is unreadable' >&2; exit 1; }

sha256sum() {
    [ "$#" -eq 0 ] && { command sha256sum; return; }
    "$Z2K_TEST_PYTHON" -c 'import hashlib,sys; p=sys.argv[1]; print(hashlib.sha256(open(p,"rb").read()).hexdigest(), p)' "$1"
}

T="$(mktemp -d)" || exit 1
trap 'rm -rf "$T"' EXIT HUP INT TERM
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"
export Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release"
make_artifact() {
    _stage="$1"
    mkdir -p "$_stage/usr/lib/z2k/platform/openwrt" \
        "$_stage/usr/lib/z2k/bin/linux-arm64" "$_stage/usr/lib/z2k/bin/linux-x86_64" \
        "$_stage/usr/lib/z2k/platform/openwrt/bin/linux-arm64" \
        "$_stage/usr/lib/z2k/platform/openwrt/bin/linux-x86_64" \
        "$_stage/opt/zapret2/binaries/linux-arm64" "$_stage/opt/zapret2/binaries/linux-x86_64" \
        "$_stage/usr/bin" "$_stage/usr/sbin" \
        "$_stage/opt/zapret2/etc/z2k" \
        "$_stage/etc/init.d" "$_stage/etc/hotplug.d/iface" \
        "$_stage/etc/sysctl.d" "$_stage/usr/share/nftables.d/chain-pre/forward"
    printf 'release payload\n' > "$_stage/usr/lib/z2k/platform/openwrt/release.sh"
    cp "$REPO/platform/openwrt/arch.sh" "$_stage/usr/lib/z2k/platform/openwrt/arch.sh"
    printf 'arm64 tg\n' > "$_stage/usr/lib/z2k/bin/linux-arm64/tg-mtproxy-client"
    printf 'x86 tg\n' > "$_stage/usr/lib/z2k/bin/linux-x86_64/tg-mtproxy-client"
    printf 'arm64 rt\n' > "$_stage/usr/lib/z2k/bin/linux-arm64/z2k-rt-proxy"
    printf 'x86 rt\n' > "$_stage/usr/lib/z2k/bin/linux-x86_64/z2k-rt-proxy"
    printf 'arm64 detect\n' > "$_stage/usr/lib/z2k/bin/linux-arm64/z2k-detect"
    printf 'x86 detect\n' > "$_stage/usr/lib/z2k/bin/linux-x86_64/z2k-detect"
    printf 'arm64 warp\n' > "$_stage/usr/lib/z2k/platform/openwrt/bin/linux-arm64/z2k-warpd"
    printf 'x86 warp\n' > "$_stage/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd"
    printf 'arm64 dataplane\n' > "$_stage/opt/zapret2/binaries/linux-arm64/nfqws2"
    printf 'x86 dataplane\n' > "$_stage/opt/zapret2/binaries/linux-x86_64/nfqws2"
    printf '#!/bin/sh\nexit 0\n' > "$_stage/usr/lib/z2k/platform/openwrt/bootstrap.sh"
    printf 'release tag %s\n' "$_CURRENT_TAG" > "$_stage/usr/lib/z2k/version.txt"
    printf 'update public key\n' > "$_stage/opt/zapret2/etc/z2k-update-pub.pem"
    printf '#!/bin/sh\nexit 0\n' > "$_stage/usr/bin/z2kow"
    printf '#!/bin/sh\nexit 0\n' > "$_stage/usr/sbin/install_release"
    printf '#!/bin/sh\nexit 0\n' > "$_stage/etc/init.d/z2k"
    printf '#!/bin/sh\nexit 0\n' > "$_stage/etc/init.d/z2k-webpanel"
    printf '# product hotplug\n' > "$_stage/etc/hotplug.d/iface/90-z2k"
    printf 'net.ipv4.ip_forward=1\n' > "$_stage/etc/sysctl.d/99-z2k.conf"
    printf 'table inet z2k-test {}\n' > "$_stage/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft"
}

prepare_manifest() {
    _artifact="$1"; _out="$2"; _url="${3:-https://github.com/t0fox/z2kOW/releases/download/openwrt-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa/openwrt-rootfs.tar.gz}"; _sha=""; _size=""
    _sha="$(sha256sum "$_artifact" | awk '{print $1}')"
    _size="$(wc -c < "$_artifact" | tr -d ' \t\r\n')"
    "$Z2K_TEST_PYTHON" -c 'import json,sys; p,a,o,sha,size,url=sys.argv[1:]; d=json.load(open(p,encoding="utf-8")); d["artifact"]={"filename":"openwrt-rootfs.tar.gz","url":url,"sha256":sha,"size_bytes":int(size)}; d["signing"]={"key_id":"0000000000000000000000000000000000000000000000000000000000000000"}; history=d.pop("history"); f=open(o,"w",encoding="utf-8"); f.write(json.dumps(d,ensure_ascii=False,indent=2)[:-1]+",\n  "+chr(34)+"history"+chr(34)+": [\n"); f.write(",\n".join("    "+json.dumps(entry,ensure_ascii=False,separators=(",",":")) for entry in history)); f.write("\n  ]\n}\n"); f.close()' \
        "$REPO/UPDATES.json" "$_artifact" "$_out" "$_sha" "$_size" "$_url"
}

_state_is_release() {
    grep -qx "tag=$1" "$3" 2>/dev/null && grep -qx "seq=$2" "$3" 2>/dev/null
}

SYS="$T/sys"
STAGE="$T/release-root"
_unsafe_owned_paths=""
mkdir -p "$SYS/etc/z2k/state" "$SYS/etc/z2k" "$SYS/usr/lib/z2k/share" "$SYS/etc/apk/repositories.d" "$SYS/etc/apk/keys"
mkdir -p "$SYS/opt/zapret2"
printf '{"install_id":"legacy-install","priv":"legacy-key"}\n' > "$SYS/opt/zapret2/.z2k-relay-id"
printf 'p-86.2\n' > "$SYS/etc/z2k/state/installed-release"
printf 'keep user config\n' > "$SYS/etc/z2k/config"
printf 'old apk-owned file\n' > "$SYS/usr/lib/z2k/legacy.txt"
printf 'https://github.com/t0fox/z2kOW/releases/latest/download/packages.adb\n' > "$SYS/etc/apk/repositories.d/z2kow.list"
printf 'https://feed.z2k.example.com/openwrt\n' > "$SYS/etc/apk/repositories.d/z2k.list"
printf 'https://downloads.openwrt.org/releases/24.10/packages/aarch64_cortex-a53/base\n' > "$SYS/etc/apk/repositories.d/custom.list"
printf 'https://feed.z2k.example.com/openwrt\nhttps://downloads.openwrt.org/releases/24.10/packages/aarch64_cortex-a53/packages\n' > "$SYS/etc/apk/repositories"
printf 'legacy z2kOW feed key\n' > "$SYS/usr/lib/z2k/share/z2k-feed.pem"
cp "$SYS/usr/lib/z2k/share/z2k-feed.pem" "$SYS/etc/apk/keys/z2k-feed.pem"
printf '%s\n' z2k-adapter z2k-webpanel z2k-zapret2-runtime z2k-warp-runtime > "$T/legacy-packages"
make_artifact "$STAGE"
mkdir -p "$T/dist"
    tar -czf "$T/dist/openwrt-rootfs.tar.gz" -C "$STAGE" usr etc opt
prepare_manifest "$T/dist/openwrt-rootfs.tar.gz" "$T/UPDATES.json"
z2k_ow_manifest_release_ok "$T/UPDATES.json" \
    && _t_ok || _t_bad "technical immutable release URL is valid for the controlled p-86.13 manifest"
cp "$T/UPDATES.json" "$T/untrusted-URL.json"
"$Z2K_TEST_PYTHON" - "$T/untrusted-URL.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
d = json.loads(path.read_text(encoding="utf-8"))
d["artifact"]["url"] = "https://attacker.example/releases/download/openwrt-" + "a" * 40 + "/openwrt-rootfs.tar.gz"
path.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
if z2k_ow_manifest_release_ok "$T/untrusted-URL.json"; then
    _t_bad "manifest artifact URL cannot escape the controlled GitHub repository"
else
    _t_ok
fi
_decision="$(z2k_ow_release_decision "$T/UPDATES.json" "$SYS/etc/z2k/state/installed-release")"
assert_eq "p-86.2 through upstream reinstall release enters controlled full install" \
    "update $_CURRENT_TAG" "$_decision"

apk() {
    printf '%s\n' "$*" >> "$T/apk.log"
    case "$1" in
        info)
            case "$2" in
                -e) grep -qx "$3" "$T/legacy-packages" ;;
                --contents)
                    grep -qx "$3" "$T/legacy-packages" || return 1
                    if [ -n "$_unsafe_owned_paths" ]; then
                        printf '%s\n' "$_unsafe_owned_paths"
                    else
                        printf '%s\n' usr/lib/z2k/legacy.txt
                    fi
                    ;;
                *) return 2 ;;
            esac
            ;;
        add)
            printf '%s\n' "$*" >> "$T/apk.add.log"
            printf '%s\n' 'system dependency install' >> "$T/apk.log"
            ;;
        del)
            shift; [ "$1" = --no-scripts ] || return 9; shift
            for _pkg in "$@"; do
                sed -i "\\|^$_pkg\$|d" "$T/legacy-packages"
                # Model apk removing package-owned files. The transaction must
                # have moved them beside their destinations before apk del.
                rm -f "$SYS/usr/lib/z2k/legacy.txt" "$SYS/usr/bin/z2kow" \
                    "$SYS/usr/sbin/install_release" "$SYS/etc/init.d/z2k" \
                    "$SYS/etc/init.d/z2k-webpanel" "$SYS/etc/hotplug.d/iface/90-z2k" \
                    "$SYS/etc/sysctl.d/99-z2k.conf" \
                    "$SYS/usr/share/nftables.d/chain-pre/forward/90-z2k-warp.nft"
            done
            ;;
        *) return 2 ;;
    esac
}

export Z2K_OW_TESTING=1 Z2K_OW_SYSROOT="$SYS"
export Z2K_ROOT="$SYS/usr/lib/z2k" Z2K_ADAPTER_DIR="$REPO/platform/openwrt"
export Z2K_OW_MANIFEST_PATH="$T/UPDATES.json" Z2K_OW_ARTIFACT_PATH="$T/dist/openwrt-rootfs.tar.gz"
export Z2K_OW_INSTALLED_RELEASE_FILE=/etc/z2k/state/installed-release
export Z2K_OW_INSTALL_WORK=/usr/lib/.z2k-install

_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
_state_ok=0; _old_ok=0; _version_ok=0; _config_ok=0
_state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$SYS/etc/z2k/state/installed-release" && _state_ok=1
_identity_ok=0
grep -q 'legacy-install' "$SYS/etc/z2k/state/relay-id.json" && _identity_ok=1
[ ! -e "$SYS/usr/lib/z2k/legacy.txt" ] && _old_ok=1
grep -q "release tag $_CURRENT_TAG" "$SYS/usr/lib/z2k/version.txt" && _version_ok=1
grep -q 'keep user config' "$SYS/etc/z2k/config" && _config_ok=1
if [ "$_rc" -eq 0 ] && [ "$_state_ok" = 1 ] && [ "$_identity_ok" = 1 ] && [ "$_old_ok" = 1 ] \
    && [ "$_version_ok" = 1 ] && [ "$_config_ok" = 1 ]; then
    _t_ok
else
    _t_bad "legacy p-86.2 full migration to $_CURRENT_TAG: rc=$_rc checks=$_state_ok/$_identity_ok/$_old_ok/$_version_ok/$_config_ok state=$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null) old=$(test -e "$SYS/usr/lib/z2k/legacy.txt" && echo present || echo absent) version=$(cat "$SYS/usr/lib/z2k/version.txt" 2>/dev/null) config=$(cat "$SYS/etc/z2k/config" 2>/dev/null) output=$_out"
fi
if grep -Eq '^add --no-scripts lighttpd([[:space:]]|$)' "$T/apk.add.log"; then
    _t_ok
else
    _t_bad "lighttpd system dependency install must not enable its default LuCI-port daemon"
fi
if [ -f "$SYS/usr/lib/z2k/bin/linux-arm64/tg-mtproxy-client" ] \
    && [ ! -e "$SYS/usr/lib/z2k/bin/linux-x86_64/tg-mtproxy-client" ] \
    && [ -f "$SYS/usr/lib/z2k/platform/openwrt/bin/linux-arm64/z2k-warpd" ] \
    && [ ! -e "$SYS/usr/lib/z2k/platform/openwrt/bin/linux-x86_64/z2k-warpd" ] \
    && [ -f "$SYS/opt/zapret2/binaries/linux-arm64/nfqws2" ] \
    && [ ! -e "$SYS/opt/zapret2/binaries/linux-x86_64/nfqws2" ]; then
    _t_ok
else
    _t_bad "installer did not prune other architecture variants from target staging"
fi

# An absent/empty marker on an otherwise migrated device safely resyncs the
# current tag and never interprets the whole release history as an install.
: > "$SYS/etc/z2k/state/installed-release"
_decision="$(z2k_ow_release_decision "$T/UPDATES.json" "$SYS/etc/z2k/state/installed-release")"
assert_eq "empty installed tag resyncs without reinstall loop" "resync $_CURRENT_TAG" "$_decision"
z2k_ow_release_state_write "$SYS/etc/z2k/state/installed-release" "$T/UPDATES.json"
if [ ! -e "$SYS/etc/apk/repositories.d/z2kow.list" ] \
    && [ ! -e "$SYS/etc/apk/repositories.d/z2k.list" ] \
    && grep -q 'downloads.openwrt.org/releases/24.10/packages/aarch64_cortex-a53/base' "$SYS/etc/apk/repositories.d/custom.list" \
    && ! grep -q 'feed.z2k.example.com/openwrt' "$SYS/etc/apk/repositories" \
    && grep -q 'downloads.openwrt.org/releases/24.10/packages/aarch64_cortex-a53/packages' "$SYS/etc/apk/repositories" \
    && [ ! -e "$SYS/etc/apk/keys/z2k-feed.pem" ] \
    && [ ! -s "$T/legacy-packages" ]; then
    _t_ok
else
    _t_bad "legacy APK/feed ownership remains after migration"
fi

_install_lock="$SYS/usr/lib/.z2k-install.lock"
mkdir -p "$_install_lock"
printf '99999999\n' > "$_install_lock/pid"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] && printf '%s' "$_out" | grep -q "none $_CURRENT_TAG" \
    && [ ! -e "$_install_lock" ]; then
    _t_ok
else
    _t_bad "stale installer lock was not recovered: rc=$_rc output=$_out"
fi
mkdir -p "$_install_lock"
printf '%s\n' "$$" > "$_install_lock/pid"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_out" | grep -q 'another install_release is running' \
    && _state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$SYS/etc/z2k/state/installed-release"; then
    _t_ok
else
    _t_bad "concurrent installer was not rejected safely: rc=$_rc output=$_out"
fi
rm -rf "$_install_lock"

# A malformed legacy package claiming LuCI/uhttpd ownership is rejected before
# apk removal or any protected path mutation.
mkdir -p "$SYS/www/cgi-bin" "$SYS/etc/config"
printf 'keep LuCI entrypoint\n' > "$SYS/www/cgi-bin/luci"
printf 'keep OpenWrt web server config\n' > "$SYS/etc/config/uhttpd"
printf '%s\n' z2k-adapter > "$T/legacy-packages"
_unsafe_owned_paths='www/cgi-bin/luci
etc/config/uhttpd'
: > "$T/apk.log"
_out="$(z2k_ow_legacy_migrate "$SYS/usr/lib/z2k" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] && printf '%s' "$_out" | grep -q 'protected LuCI/uhttpd path' \
    && ! grep -qE '^(add|del) ' "$T/apk.log" \
    && grep -q 'keep LuCI entrypoint' "$SYS/www/cgi-bin/luci" \
    && grep -q 'keep OpenWrt web server config' "$SYS/etc/config/uhttpd"; then
    _t_ok
else
    _t_bad "legacy migration touched or accepted protected LuCI/uhttpd ownership"
fi
_unsafe_owned_paths=""
: > "$T/legacy-packages"

_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
assert_eq "second install is none" "none $_CURRENT_TAG" "$_out"
assert_eq "second install is a no-op" "0" "$_rc"
_decision="$(z2k_ow_release_decision "$T/UPDATES.json" "$SYS/etc/z2k/state/installed-release")"
assert_eq "check after p-86.2 -> $_CURRENT_TAG install is none" "none $_CURRENT_TAG" "$_decision"
assert_eq "installed state has one tag and upstream seq" "2" "$(wc -l < "$SYS/etc/z2k/state/installed-release" | tr -d ' \t\r\n')"

# A deliberate same-version reinstall enters the exact same verified full
# payload transaction. It repairs a release-owned file while retaining the
# one canonical state record and all user-owned settings/lists.
_state_before="$(cat "$SYS/etc/z2k/state/installed-release")"
mkdir -p "$SYS/etc/z2k/user-lists"
printf 'keep user config\n' > "$SYS/etc/z2k/config"
printf 'keep user domains\n' > "$SYS/etc/z2k/user-lists/extra-domains.txt"
printf 'damaged release file\n' > "$SYS/usr/lib/z2k/version.txt"
_out="$(z2k_ow_install_release --reinstall "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && [ "$_out" = "installed $_CURRENT_TAG" ] \
    && grep -q "release tag $_CURRENT_TAG" "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-release")" = "$_state_before" ] \
    && grep -q 'keep user config' "$SYS/etc/z2k/config" \
    && grep -q 'keep user domains' "$SYS/etc/z2k/user-lists/extra-domains.txt"; then
    _t_ok
else
    _t_bad "same-version reinstall did not reconverge while preserving state/settings/lists: rc=$_rc state=$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null) version=$(cat "$SYS/usr/lib/z2k/version.txt" 2>/dev/null) output=$_out"
fi

# Force only skips the equality short-circuit. Hash and size validation still
# reject the same-version artifact before any release-owned file is replaced.
cp "$T/UPDATES.json" "$T/reinstall-bad-hash.json"
"$Z2K_TEST_PYTHON" -c 'import json,sys; d=json.load(open(sys.argv[1],encoding="utf-8")); d["artifact"]["sha256"]="0"*64; json.dump(d,open(sys.argv[2],"w",encoding="utf-8"),ensure_ascii=False)' \
    "$T/UPDATES.json" "$T/reinstall-bad-hash.json"
export Z2K_OW_MANIFEST_PATH="$T/reinstall-bad-hash.json"
printf 'preserve before hash failure\n' > "$SYS/usr/lib/z2k/version.txt"
_out="$(z2k_ow_install_release --reinstall "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && grep -q 'preserve before hash failure' "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-release")" = "$_state_before" ]; then
    _t_ok
else
    _t_bad "same-version reinstall bypassed artifact SHA-256 verification: rc=$_rc output=$_out"
fi
export Z2K_OW_MANIFEST_PATH="$T/UPDATES.json"

cp "$T/UPDATES.json" "$T/reinstall-bad-size.json"
"$Z2K_TEST_PYTHON" -c 'import json,sys; p=sys.argv[1]; d=json.load(open(p,encoding="utf-8")); d["artifact"]["size_bytes"] += 1; json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2)' \
    "$T/reinstall-bad-size.json"
export Z2K_OW_MANIFEST_PATH="$T/reinstall-bad-size.json"
printf 'preserve before size failure\n' > "$SYS/usr/lib/z2k/version.txt"
_out="$(z2k_ow_install_release --reinstall "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && grep -q 'preserve before size failure' "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-release")" = "$_state_before" ]; then
    _t_ok
else
    _t_bad "same-version reinstall bypassed artifact size verification: rc=$_rc output=$_out"
fi
export Z2K_OW_MANIFEST_PATH="$T/UPDATES.json"

# If the controlled release advances between the banner render and manual
# action, install_release must reject the old reinstall target before touching
# even release-owned files. This is the canonical installer race guard.
cp "$T/UPDATES.json" "$T/reinstall-newer.json"
"$Z2K_TEST_PYTHON" - "$T/reinstall-newer.json" <<'PY'
import json, sys
from pathlib import Path
path = Path(sys.argv[1])
d = json.loads(path.read_text(encoding="utf-8"))
d["current"] = "p-86.15"
d["seq"] = 138
d["upstream"]["tag"] = "p-86.15"
path.write_text(json.dumps(d, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
PY
export Z2K_OW_MANIFEST_PATH="$T/reinstall-newer.json"
printf 'preserve on manifest race\n' > "$SYS/usr/lib/z2k/version.txt"
_out="$(z2k_ow_install_release --reinstall "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 3 ] \
    && printf '%s\n' "$_out" | grep -q '^Z2KOW_REINSTALL_UPDATE_AVAILABLE:p-86.15$' \
    && grep -q 'preserve on manifest race' "$SYS/usr/lib/z2k/version.txt" \
    && [ "$(cat "$SYS/etc/z2k/state/installed-release")" = "$_state_before" ]; then
    _t_ok
else
    _t_bad "manifest race installed or obscured the newer release: rc=$_rc output=$_out"
fi
export Z2K_OW_MANIFEST_PATH="$T/UPDATES.json"

# Reinstall must keep production signature verification ahead of the no-op
# decision, and must not move the artifact size/hash gates behind any force
# branch. These ordering assertions guard the production-only trust seam while
# the transaction above exercises the same-version convergence at runtime.
"$Z2K_TEST_PYTHON" - "$REPO/platform/openwrt/release.sh" <<'PY'
import sys
from pathlib import Path
source = Path(sys.argv[1]).read_text(encoding="utf-8")
body = source.split("_z2k_ow_install_release_locked() {", 1)[1].split("\n}", 1)[0]
verify = body.index("z2k_ow_manifest_prepare_production")
reinstall_guard = body.index('if [ "$_reinstall" = 1 ]; then')
same_version = body.index('echo "none $_tag"')
size_check = body.index('[ "$(wc -c < "$_archive"')
hash_check = body.index('[ "$_actual" = "$_sha" ]')
assert verify < reinstall_guard < same_version < size_check < hash_check
assert '[ "$_reinstall" != 1 ]' in body
PY
_rc=$?
[ "$_rc" -eq 0 ] && _t_ok || _t_bad "reinstall force is limited to the same-version early return and preserves trust checks"

# A new shell process models the state observed after reboot.
_out="$(Z2K_ADAPTER_DIR="$REPO/platform/openwrt" z2k_ow_release_decision "$T/UPDATES.json" "$SYS/etc/z2k/state/installed-release")"
assert_eq "reboot simulation retains one installed-release state" "none $_CURRENT_TAG" "$_out"

# Fresh install follows the same function and creates only the one state file.
rm -rf "$SYS"
mkdir -p "$SYS/usr/lib" "$SYS/usr/bin" "$SYS/usr/sbin" "$SYS/etc/z2k/state"
: > "$SYS/etc/z2k/state/installed-release"
export Z2K_OW_SYSROOT="$SYS"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
_state_ok=0; _version_ok=0
_state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$SYS/etc/z2k/state/installed-release" && _state_ok=1
[ -f "$SYS/usr/lib/z2k/version.txt" ] && _version_ok=1
if [ "$_rc" -eq 0 ] && [ "$_state_ok" = 1 ] && [ "$_version_ok" = 1 ]; then
    _t_ok
else
    _t_bad "fresh full install: rc=$_rc state_ok=$_state_ok version_ok=$_version_ok state=$(cat "$SYS/etc/z2k/state/installed-release" 2>/dev/null) version=$(cat "$SYS/usr/lib/z2k/version.txt" 2>/dev/null) output=$_out"
fi
if [ ! -e "$SYS/etc/z2k/state/installed-tag" ] && [ ! -e "$SYS/etc/z2k/state/product-tag" ]; then
    _t_ok
else
    _t_bad "more than one installed release state remains"
fi

# A freshly bootstrapped, explicitly overridden manifest keeps its local
# transport URL through the exact same canonical install_release engine.
BOOTSTRAP_SYS="$T/bootstrap-sys"
BOOTSTRAP_TMP="$T/bootstrap-tmp"
BOOTSTRAP_ENGINE="$T/bootstrap-engine/usr/lib/z2k"
BOOTSTRAP_SERVICE_ENV="$T/bootstrap-service-env"
BOOTSTRAP_URL=http://127.0.0.1:17777/UPDATES.json
mkdir -p "$BOOTSTRAP_SYS/usr/lib" "$BOOTSTRAP_SYS/usr/bin" "$BOOTSTRAP_SYS/usr/sbin" \
    "$BOOTSTRAP_SYS/etc/z2k/state" "$BOOTSTRAP_TMP"
mkdir -p "$BOOTSTRAP_ENGINE/platform"
cp -R "$REPO/platform/openwrt" "$BOOTSTRAP_ENGINE/platform/openwrt"
cp -R "$REPO/lib" "$BOOTSTRAP_ENGINE/lib"
make_artifact "$T/bootstrap-payload"
cat > "$T/bootstrap-payload/etc/init.d/z2k" <<EOF
#!/bin/sh
case "\$1" in
    restart|start|status|running)
        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "\${Z2K_LIB:-}" "\${Z2K_ADAPTER_DIR:-}" "\${Z2K_AU_PUBKEY:-}" \
            "\${Z2K_OW_BOOTSTRAP_MANIFEST:-}" "\${Z2K_OW_BOOTSTRAP_SIGNATURE:-}" \
            "\${Z2K_OW_BOOTSTRAP_ARTIFACT:-}" "\${Z2K_OW_BOOTSTRAP_PUBLIC_KEY:-}" \
            "\${Z2KOW_MANIFEST_URL:-}" "\${Z2KOW_TRUST_KEY:-}" >> "$BOOTSTRAP_SERVICE_ENV"
        exit 0
        ;;
    *) exit 0 ;;
esac
EOF
cat > "$T/bootstrap-payload/etc/init.d/z2k-webpanel" <<EOF
#!/bin/sh
case "\$1" in restart|start|running) exit 0 ;; *) exit 0 ;; esac
EOF
chmod 755 "$T/bootstrap-payload/etc/init.d/z2k" "$T/bootstrap-payload/etc/init.d/z2k-webpanel"
dd if=/dev/zero of="$T/bootstrap-payload/usr/lib/z2k/test-large.bin" bs=1M count=4 2>/dev/null || exit 1
tar -czf "$T/dist/bootstrap-rootfs.tar.gz" -C "$T/bootstrap-payload" usr etc opt
prepare_manifest "$T/dist/bootstrap-rootfs.tar.gz" "$T/bootstrap-UPDATES.json" \
    "http://127.0.0.1:17777/openwrt-rootfs.tar.gz"
openssl genpkey -algorithm Ed25519 -out "$T/bootstrap.key" >/dev/null 2>&1 || exit 1
openssl pkey -in "$T/bootstrap.key" -pubout -out "$T/bootstrap.pub" >/dev/null 2>&1 || exit 1
_bootstrap_key_id="$(openssl pkey -pubin -in "$T/bootstrap.pub" -outform DER 2>/dev/null | command sha256sum | awk '{print $1}')"
"$Z2K_TEST_PYTHON" -c 'import json,sys; p,k=sys.argv[1:]; d=json.load(open(p,encoding="utf-8")); d["signing"]={"key_id":k}; json.dump(d,open(p,"w",encoding="utf-8"),ensure_ascii=False,indent=2); open(p,"a",encoding="utf-8").write("\n")' \
    "$T/bootstrap-UPDATES.json" "$_bootstrap_key_id"
openssl pkeyutl -sign -rawin -inkey "$T/bootstrap.key" -in "$T/bootstrap-UPDATES.json" \
    -out "$T/bootstrap-UPDATES.json.sig" >/dev/null 2>&1 || exit 1
Z2K_OW_BOOTSTRAP_PUBLIC_KEY="$T/bootstrap.pub" \
    z2k_ow_manifest_verify_signature "$T/bootstrap-UPDATES.json" "$T/bootstrap-UPDATES.json.sig" \
    && _t_ok || _t_bad "local bootstrap manifest verifies with its explicit test trust key"
if z2k_ow_manifest_release_ok "$T/bootstrap-UPDATES.json"; then
    _t_bad "local artifact URL is rejected without the explicit bootstrap origin"
else
    _t_ok
fi
z2k_ow_manifest_release_ok "$T/bootstrap-UPDATES.json" \
    http://127.0.0.1:17777/openwrt-rootfs.tar.gz \
    && _t_ok || _t_bad "local artifact URL is accepted only when it matches the explicit bootstrap origin"
export Z2K_OW_SYSROOT="$BOOTSTRAP_SYS" \
    Z2K_OW_INSTALL_TMP="$BOOTSTRAP_TMP" \
    Z2K_ROOT=/usr/lib/z2k \
    Z2K_ADAPTER_DIR="$BOOTSTRAP_ENGINE/platform/openwrt" \
    Z2K_LIB="$BOOTSTRAP_ENGINE/lib" \
    Z2K_AU_PUBKEY="$BOOTSTRAP_TMP/z2k-update-pub.pem" \
    Z2K_OW_BOOTSTRAP_MANIFEST="$T/bootstrap-UPDATES.json" \
    Z2K_OW_BOOTSTRAP_SIGNATURE="$T/bootstrap-UPDATES.json.sig" \
    Z2K_OW_BOOTSTRAP_ARTIFACT="$T/dist/bootstrap-rootfs.tar.gz" \
    Z2K_OW_BOOTSTRAP_PUBLIC_KEY="$T/bootstrap.pub" \
    Z2KOW_MANIFEST_URL="$BOOTSTRAP_URL" \
    Z2KOW_TRUST_KEY="$T/bootstrap.pub" \
    Z2K_TEST_BOOTSTRAP_SERVICE_ENV="$BOOTSTRAP_SERVICE_ENV" \
    Z2K_OW_TEST_HEALTHCHECK=1
df() {
    _probe="$2"
    printf '%s\n' "$_probe" >> "$T/df.calls"
    case "$_probe" in
        "$BOOTSTRAP_TMP"/*)
            printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 400000 100000 300000 25%% /tmp\n'
            ;;
        "$BOOTSTRAP_SYS/usr/lib/.z2k-install")
            printf 'Filesystem 1024-blocks Used Available Use%% Mounted on\nsim 100000 90000 10000 90%% /overlay\n'
            ;;
        *) command df "$@" ;;
    esac
}
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && _state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$BOOTSTRAP_SYS/etc/z2k/state/installed-release" \
    && grep -q "release tag $_CURRENT_TAG" "$BOOTSTRAP_SYS/usr/lib/z2k/version.txt"; then
    _t_ok
else
    _t_bad "signed local bootstrap did not converge through install_release: rc=$_rc output=$_out"
fi
grep -qx "$BOOTSTRAP_TMP/stage" "$T/df.calls" && _t_ok \
    || _t_bad "target payload free-space gate probes tmpfs staging, not flash overlay"
if [ -s "$BOOTSTRAP_SERVICE_ENV" ] \
    && awk '$0 != "||||||||" { bad=1 } END { if (NR == 0 || bad) exit 1 }' "$BOOTSTRAP_SERVICE_ENV"; then
    _t_ok
else
    _t_bad "restarted services inherited temporary bootstrap paths or trust overrides: $(cat "$BOOTSTRAP_SERVICE_ENV" 2>/dev/null)"
fi
unset -f df
unset Z2K_OW_INSTALL_TMP Z2K_OW_BOOTSTRAP_MANIFEST Z2K_OW_BOOTSTRAP_SIGNATURE \
    Z2K_OW_BOOTSTRAP_ARTIFACT Z2K_OW_BOOTSTRAP_PUBLIC_KEY Z2KOW_MANIFEST_URL \
    Z2KOW_TRUST_KEY Z2K_TEST_BOOTSTRAP_SERVICE_ENV Z2K_OW_TEST_HEALTHCHECK \
    Z2K_ADAPTER_DIR Z2K_LIB Z2K_AU_PUBKEY
export Z2K_ADAPTER_DIR="$REPO/platform/openwrt" Z2K_ROOT="$SYS/usr/lib/z2k"
export Z2K_OW_SYSROOT="$SYS"

# The installer must verify the state record after the commit helper returns.
# This catches a helper that exits successfully without persisting tag+seq.
READBACK_SYS="$T/readback-sys"
mkdir -p "$READBACK_SYS/usr/lib" "$READBACK_SYS/usr/bin" "$READBACK_SYS/usr/sbin" \
    "$READBACK_SYS/etc/z2k/state"
export Z2K_OW_SYSROOT="$READBACK_SYS"
_out="$( (
    z2k_ow_release_state_write() { return 0; }
    z2k_ow_install_release "$_CURRENT_TAG"
) 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && [ ! -e "$READBACK_SYS/etc/z2k/state/installed-release" ] \
    && [ ! -e "$READBACK_SYS/usr/lib/z2k/version.txt" ]; then
    _t_ok
else
    _t_bad "installer accepted a successful state writer that persisted no canonical release record: rc=$_rc output=$_out"
fi
export Z2K_OW_SYSROOT="$SYS"

# Tampered artifact hash must fail before legacy cleanup or file mutation.
rm -rf "$SYS"
mkdir -p "$SYS/etc/z2k/state" "$SYS/usr/lib/z2k"
printf 'p-86.2\n' > "$SYS/etc/z2k/state/installed-release"
printf 'old tree\n' > "$SYS/usr/lib/z2k/version.txt"
cp "$T/UPDATES.json" "$T/bad-UPDATES.json"
"$Z2K_TEST_PYTHON" -c 'import json,sys; p,o=sys.argv[1:]; d=json.load(open(p,encoding="utf-8")); d["artifact"]["sha256"]="0"*64; json.dump(d,open(o,"w",encoding="utf-8"),ensure_ascii=False,indent=2)' \
    "$T/UPDATES.json" "$T/bad-UPDATES.json"
export Z2K_OW_MANIFEST_PATH="$T/bad-UPDATES.json"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] && grep -qx 'p-86.2' "$SYS/etc/z2k/state/installed-release" \
    && grep -q 'old tree' "$SYS/usr/lib/z2k/version.txt"; then
_t_ok
else
    _t_bad "hash failure was not fail-closed: rc=$_rc output=$_out"
fi

# When apk removes old package files but the verified release is incomplete,
# the transaction restores the prior files and release state. APK ownership
# stays retired; a retry uses the same full install_release path.
rm -rf "$SYS"
mkdir -p "$SYS/etc/z2k/state" "$SYS/etc/z2k" "$SYS/usr/lib/z2k/share" \
    "$SYS/usr/bin" "$SYS/usr/sbin" "$SYS/etc/init.d" \
    "$SYS/etc/hotplug.d/iface" "$SYS/etc/sysctl.d" \
    "$SYS/usr/share/nftables.d/chain-pre/forward" \
    "$SYS/etc/apk/repositories.d" "$SYS/etc/apk/keys"
printf 'p-86.2\n' > "$SYS/etc/z2k/state/installed-release"
printf 'preserve config\n' > "$SYS/etc/z2k/config"
printf 'old core tree\n' > "$SYS/usr/lib/z2k/legacy.txt"
printf 'old core init\n' > "$SYS/etc/init.d/z2k"
printf 'old panel init\n' > "$SYS/etc/init.d/z2k-webpanel"
printf 'https://github.com/t0fox/z2kOW/releases/latest/download/packages.adb\n' > "$SYS/etc/apk/repositories.d/z2kow.list"
printf 'https://feed.z2k.example.com/openwrt\n' > "$SYS/etc/apk/repositories.d/z2k.list"
printf 'z2kow feed key\n' > "$SYS/usr/lib/z2k/share/z2k-feed.pem"
printf 'z2kow feed key\n' > "$SYS/etc/apk/keys/z2k-feed.pem"
printf '%s\n' z2k-adapter z2k-webpanel > "$T/legacy-packages"
make_artifact "$T/incomplete"
rm -f "$T/incomplete/etc/hotplug.d/iface/90-z2k"
tar -czf "$T/dist/incomplete-rootfs.tar.gz" -C "$T/incomplete" usr etc opt
prepare_manifest "$T/dist/incomplete-rootfs.tar.gz" "$T/incomplete-UPDATES.json"
export Z2K_OW_MANIFEST_PATH="$T/incomplete-UPDATES.json"
export Z2K_OW_ARTIFACT_PATH="$T/dist/incomplete-rootfs.tar.gz"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] && grep -qx 'p-86.2' "$SYS/etc/z2k/state/installed-release" \
    && grep -q 'old core tree' "$SYS/usr/lib/z2k/legacy.txt" \
    && grep -q 'old core init' "$SYS/etc/init.d/z2k" \
    && grep -q 'preserve config' "$SYS/etc/z2k/config" \
    && [ ! -s "$T/legacy-packages" ]; then
    _t_ok
else
    _t_bad "failed migration did not roll back files/state after APK removal: rc=$_rc output=$_out"
fi

# A retry after one-time legacy package/feed removal must still converge.
make_artifact "$T/retry"
tar -czf "$T/dist/retry-rootfs.tar.gz" -C "$T/retry" usr etc opt
prepare_manifest "$T/dist/retry-rootfs.tar.gz" "$T/retry-UPDATES.json"
export Z2K_OW_MANIFEST_PATH="$T/retry-UPDATES.json"
export Z2K_OW_ARTIFACT_PATH="$T/dist/retry-rootfs.tar.gz"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] && _state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$SYS/etc/z2k/state/installed-release" \
    && grep -q "release tag $_CURRENT_TAG" "$SYS/usr/lib/z2k/version.txt"; then
    _t_ok
else
    _t_bad "retry after partial legacy retirement failed: rc=$_rc output=$_out"
fi

# A failed post-replacement health check must roll files and the prior canonical
# release state back together; only the healthy retry may commit the target tag.
HEALTH_SYS="$T/health-sys"
HEALTH_STAGE="$T/health-stage"
HEALTH_FAIL="$T/healthcheck-fails"
HEALTH_SERVICE_FAIL="$T/service-start-fails"
mkdir -p "$HEALTH_SYS/etc/z2k/state" "$HEALTH_SYS/usr/lib/z2k" \
    "$HEALTH_SYS/etc/init.d" "$HEALTH_SYS/usr/lib/.z2k-install"
printf 'tag=p-86.2\nseq=127\n' > "$HEALTH_SYS/etc/z2k/state/installed-release"
printf 'previous payload\n' > "$HEALTH_SYS/usr/lib/z2k/version.txt"
make_artifact "$HEALTH_STAGE"
cat > "$HEALTH_STAGE/etc/init.d/z2k" <<EOF
#!/bin/sh
case "\$1" in
    restart|start)
        if [ -e "$HEALTH_SERVICE_FAIL" ]; then
            echo "mock-z2k-\$1-diagnostic" >&2
            exit 23
        fi
        ;;
    status|running)
        if grep -q 'release tag ' "$HEALTH_SYS/usr/lib/z2k/version.txt" 2>/dev/null; then
            [ ! -e "$HEALTH_FAIL" ]
        else
            exit 0
        fi
        ;;
    *) exit 0 ;;
esac
EOF
cat > "$HEALTH_STAGE/etc/init.d/z2k-webpanel" <<EOF
#!/bin/sh
case "\$1" in
    restart|start) exit 0 ;;
    running)
        if grep -q 'release tag ' "$HEALTH_SYS/usr/lib/z2k/version.txt" 2>/dev/null; then
            [ ! -e "$HEALTH_FAIL" ]
        else
            exit 0
        fi
        ;;
    *) exit 0 ;;
esac
EOF
chmod 755 "$HEALTH_STAGE/etc/init.d/z2k" "$HEALTH_STAGE/etc/init.d/z2k-webpanel"
mkdir -p "$T/dist"
tar -czf "$T/dist/health-rootfs.tar.gz" -C "$HEALTH_STAGE" usr etc opt
prepare_manifest "$T/dist/health-rootfs.tar.gz" "$T/health-UPDATES.json"
export Z2K_OW_SYSROOT="$HEALTH_SYS" Z2K_OW_MANIFEST_PATH="$T/health-UPDATES.json"
export Z2K_OW_ARTIFACT_PATH="$T/dist/health-rootfs.tar.gz" Z2K_OW_TEST_HEALTHCHECK=1
touch "$HEALTH_SERVICE_FAIL"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && _state_is_release p-86.2 127 "$HEALTH_SYS/etc/z2k/state/installed-release" \
    && grep -q 'previous payload' "$HEALTH_SYS/usr/lib/z2k/version.txt" \
    && printf '%s\n' "$_out" | grep -q 'mock-z2k-restart-diagnostic' \
    && printf '%s\n' "$_out" | grep -q 'mock-z2k-start-diagnostic'; then
    _t_ok
else
    _t_bad "service start failure lost diagnostics or rollback: rc=$_rc state=$(cat "$HEALTH_SYS/etc/z2k/state/installed-release" 2>/dev/null) output=$_out"
fi
rm -f "$HEALTH_SERVICE_FAIL"
touch "$HEALTH_FAIL"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -ne 0 ] \
    && _state_is_release p-86.2 127 "$HEALTH_SYS/etc/z2k/state/installed-release" \
    && grep -q 'previous payload' "$HEALTH_SYS/usr/lib/z2k/version.txt" \
    && printf '%s\n' "$_out" | grep -q 'Z2KOW_ROLLBACK=complete'; then
    _t_ok
else
    _t_bad "failed health check committed release state or left target files: rc=$_rc state=$(cat "$HEALTH_SYS/etc/z2k/state/installed-release" 2>/dev/null) output=$_out"
fi
rm -f "$HEALTH_FAIL"
_out="$(z2k_ow_install_release "$_CURRENT_TAG" 2>&1)"; _rc=$?
if [ "$_rc" -eq 0 ] \
    && _state_is_release "$_CURRENT_TAG" "$_CURRENT_SEQ" "$HEALTH_SYS/etc/z2k/state/installed-release" \
    && grep -q "release tag $_CURRENT_TAG" "$HEALTH_SYS/usr/lib/z2k/version.txt"; then
    _t_ok
else
    _t_bad "healthy install did not commit target state: rc=$_rc state=$(cat "$HEALTH_SYS/etc/z2k/state/installed-release" 2>/dev/null) output=$_out"
fi
unset Z2K_OW_SYSROOT Z2K_OW_MANIFEST_PATH Z2K_OW_ARTIFACT_PATH Z2K_OW_TEST_HEALTHCHECK

_t_done
