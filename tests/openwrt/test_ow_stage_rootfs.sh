#!/bin/sh
# Раскладка релиза должна содержать все runtime-файлы, нужные установщику.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-stage-rootfs-binaries"
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
for _dep in tar gzip; do
    command -v "$_dep" >/dev/null 2>&1 || {
        echo "SKIP[ow-stage-rootfs-binaries]: $_dep is required for the stage simulation"
        exit 0
    }
done
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-stage-rootfs.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
printf 'probe\n' > "$T/symlink-probe"
if ! ln -s "$T/symlink-probe" "$T/symlink-check" 2>/dev/null || [ ! -L "$T/symlink-check" ]; then
    echo "SKIP[ow-stage-rootfs-binaries]: host cannot create the symlinks required by staged aliases"
    exit 0
fi

R="$T/runtime"
mkdir -p "$R/init.d/openwrt" "$R/common" "$R/ipset" \
    "$R/lua"
for _f in init.d/openwrt/functions common/base.sh common/fwtype.sh \
    common/linux_iphelper.sh common/ipt.sh common/nft.sh common/linux_fw.sh \
    common/linux_daemons.sh common/list.sh common/custom.sh ipset/def.sh; do
    mkdir -p "$R/$(dirname "$_f")"
    : > "$R/$_f"
done
for _arch in arm arm64 mips mipsel riscv64 x86 x86_64; do
    mkdir -p "$R/binaries/linux-$_arch"
    for _binary in nfqws2 ip2net mdig; do
        printf '#!/bin/sh\nexit 0\n' > "$R/binaries/linux-$_arch/$_binary"
        chmod 0755 "$R/binaries/linux-$_arch/$_binary"
    done
done
mkdir -p "$R/ipset"
printf '#!/bin/sh\nexit 0\n' > "$R/ipset/create_ipset.sh"
chmod 0755 "$R/ipset/create_ipset.sh"
for _f in zapret-lib zapret-antidpi zapret-auto; do
    printf 'fixture\n' | gzip -c > "$R/lua/$_f.lua.gz"
done
tar -czf "$T/runtime.tar.gz" -C "$T" runtime || exit 1

for _name in warpd tg rt detect; do mkdir -p "$T/$_name"; done
for _arch in arm64 arm x86_64 x86 mips mipsel riscv64; do
    mkdir -p "$T/warpd/linux-$_arch" "$T/tg/linux-$_arch" \
        "$T/rt/linux-$_arch" "$T/detect/linux-$_arch"
    for _spec in "warpd:z2k-warpd" "tg:tg-mtproxy-client" \
        "rt:z2k-rt-proxy" "detect:z2k-detect"; do
        _kind=${_spec%%:*}; _bin=${_spec#*:}
        printf '#!/bin/sh\nprintf "%%s\\n" "%s-%s" "$*"\n' "$_kind" "$_arch" > "$T/$_kind/linux-$_arch/$_bin"
        chmod 0755 "$T/$_kind/linux-$_arch/$_bin"
    done
done
mkdir -p "$T/release-keys"
openssl genpkey -algorithm Ed25519 -out "$T/release-keys/test.key" >/dev/null 2>&1 || exit 1
openssl pkey -in "$T/release-keys/test.key" -pubout -out "$T/release-keys/test.pub" >/dev/null 2>&1 || exit 1
_key_id="$(openssl pkey -pubin -in "$T/release-keys/test.pub" -outform DER 2>/dev/null | sha256sum | awk '{print $1}')"
mv "$T/release-keys/test.pub" "$T/release-keys/$_key_id.pub"

# An archive missing even one supported architecture must fail before rootfs
# staging can silently publish a router payload without its dataplane.
cp -R "$R" "$T/runtime-incomplete"
rm -rf "$T/runtime-incomplete/binaries/linux-mipsel"
tar -czf "$T/runtime-incomplete.tar.gz" -C "$T" runtime-incomplete || exit 1
mkdir -p "$T/stage-incomplete"
if sh "$ROOT/scripts/openwrt/stage-rootfs.sh" "$T/stage-incomplete" \
    "$T/runtime-incomplete.tar.gz" "$T/warpd" "$T/tg" "$T/rt" "$T/detect" \
    "$T/release-keys" >/dev/null 2>&1; then
    _t_bad "staging rejects an engine archive missing linux-mipsel"
else
    _t_ok
fi

mkdir -p "$T/stage"
sh "$ROOT/scripts/openwrt/stage-rootfs.sh" "$T/stage" "$T/runtime.tar.gz" \
    "$T/warpd" "$T/tg" "$T/rt" "$T/detect" "$T/release-keys" || exit 1

for _binary in nfqws2 ip2net mdig; do
    _path="$T/stage/opt/zapret2/binaries/linux-x86_64/$_binary"
    [ -f "$_path" ] && [ -x "$_path" ] \
        && _t_ok || _t_bad "сборщик сохраняет плоский исполняемый файл upstream: $_binary"
done

tar -czf "$T/openwrt-rootfs.tar.gz" -C "$T/stage" . || exit 1
_release_tag=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["current"])' "$ROOT/UPDATES.json")
_tar_index=$(tar -xOzf "$T/openwrt-rootfs.tar.gz" ./usr/lib/z2k/www/index.html)
printf '%s\n' "$_tar_index" | grep -Fq "app.js?v=$_release_tag" \
    && _t_ok || _t_bad "final payload WebPanel index uses the controlled release cache-buster"
_tar_app=$(tar -xOzf "$T/openwrt-rootfs.tar.gz" ./usr/lib/z2k/www/app.js)
printf '%s\n' "$_tar_app" | grep -Fq "identity.js?v=$_release_tag" \
    && _t_ok || _t_bad "final payload WebPanel scripts use the controlled release cache-buster"
printf '%s\n' "$_tar_index" | grep -Fq 'id="brand-profile-theme"' \
    && _t_ok || _t_bad "final payload retains the branded WebPanel source while stamping cache-busters"
_tar_wan=$(tar -xOzf "$T/openwrt-rootfs.tar.gz" ./usr/lib/z2k/lib/wan.sh)
printf '%s\n' "$_tar_wan" | grep -Fq 'lo) return 0 ;;' \
    && _t_ok || _t_bad "final payload ships shared WAN discovery that accepts routed bridges"
_diag_mode=$(tar -tvzf "$T/openwrt-rootfs.tar.gz" \
    | awk '$NF ~ /platform\/openwrt\/diag\.sh$/ { print $1 }')
assert_eq "final release tarball keeps the OpenWrt diagnostics adapter executable" \
    "-rwxr-xr-x" "$_diag_mode"
_tcp16_probe_mode=$(tar -tvzf "$T/openwrt-rootfs.tar.gz" \
    | awk '$NF ~ /usr\/lib\/z2k\/z2k-tcp16-probe\.sh$/ { print $1 }')
assert_eq "final release tarball includes executable TCP16 probe" \
    "-rwxr-xr-x" "$_tcp16_probe_mode"
for _path in usr/lib/z2k/lua/z2k-tcp16.lua \
    usr/lib/z2k/lists/tcp16_targets.txt usr/lib/z2k/lists/tcp16_nets.txt \
    usr/lib/z2k/lists/sni_wl_candidates.txt \
    usr/lib/z2k/platform/openwrt/tcp16-check.sh; do
    tar -tzf "$T/openwrt-rootfs.tar.gz" | grep -Fxq "./$_path" \
        && _t_ok || _t_bad "final rootfs is missing mandatory TCP16 runtime path $_path"
done
for _path in usr/lib/z2k/z2k-geosite.sh usr/lib/z2k/z2k-update-lists.sh \
    usr/lib/z2k/z2k-dns-check.sh \
    usr/lib/z2k/z2k-blocked-monitor.sh; do
    tar -tzf "$T/openwrt-rootfs.tar.gz" | grep -Fxq "./$_path" \
        && _t_ok || _t_bad "final rootfs is missing upstream runtime executor $_path"
done
if tar -tzf "$T/openwrt-rootfs.tar.gz" | grep -Fq './usr/lib/z2k/z2k-stats-upload.sh'; then
    _t_bad "final rootfs must not ship the retired strategy-stats uploader"
else
    _t_ok
fi
find "$ROOT/files/fake" -type f -print > "$T/fake-inventory"
while IFS= read -r _source; do
    _rel=${_source#"$ROOT/files/fake/"}
    tar -tzf "$T/openwrt-rootfs.tar.gz" | grep -Fxq "./usr/lib/z2k/fake/$_rel" \
        && _t_ok || _t_bad "final rootfs omits registered fake blob $_rel"
    grep -Fq "$_rel" "$ROOT/platform/openwrt/optbase.sh" \
        && _t_ok || _t_bad "fake blob $_rel is not registered by the nfqws2 argv builder"
done < "$T/fake-inventory"

# QUIC probes and nfqws2 must consume the same staged fake directory. The
# x86_64 detector fixture fails unless its wrapper exports that exact path and
# the selected QUIC blob exists there.
_detect="$T/stage/usr/lib/z2k/bin/z2k-detect"
_detect_arch="$T/stage/usr/lib/z2k/bin/linux-x86_64/z2k-detect"
cat > "$_detect_arch" <<'EOF'
#!/bin/sh
[ "$Z2K_FAKE_DIR" = "$Z2K_EXPECT_FAKE_DIR" ] || exit 10
[ -s "$Z2K_FAKE_DIR/quic_initial_www_google_com.bin" ] || exit 11
printf 'fake-dir=%s\n' "$Z2K_FAKE_DIR"
EOF
chmod 0755 "$_detect_arch"
_probe_out="$(Z2K_OW_ARCH=x86_64 Z2K_EXPECT_FAKE_DIR="$T/stage/usr/lib/z2k/fake" \
    "$_detect" blob-path 2>&1)"
printf '%s\n' "$_probe_out" | grep -Fq "fake-dir=$T/stage/usr/lib/z2k/fake" \
    && _t_ok || _t_bad "QUIC detector reads the same /usr/lib/z2k/fake directory staged for nfqws2"
tar -tzf "$T/openwrt-rootfs.tar.gz" | grep -Fxq './usr/lib/z2k/platform/openwrt/list-refresh.sh' \
    && _t_ok || _t_bad "final rootfs inventory omits the native 04:00 list-refresh adapter"
[ -x "$T/stage/usr/lib/z2k/platform/openwrt/list-refresh.sh" ] \
    && _t_ok || _t_bad "native list-refresh adapter is executable in the final rootfs"
for _source in "$ROOT"/files/lua/*.lua; do
    _module=${_source##*/}
    _rel=${_source#"$ROOT/"}
    tar -tzf "$T/openwrt-rootfs.tar.gz" | grep -Fxq "./usr/lib/z2k/lua/$_module" \
        && _t_ok || _t_bad "final rootfs inventory omits upstream Lua module $_module"
    _alias=${_module%.lua}
    grep -qF "$_alias" "$ROOT/platform/openwrt/optbase.sh" \
        && _t_ok || _t_bad "upstream Lua module $_alias is not reached from nfqws2 argv builder"
    grep -Fq "$_rel|" "$ROOT/tests/openwrt/runtime-inventory.tsv" \
        && _t_ok || _t_bad "upstream Lua module $_rel has no completeness inventory row"
done

# Машиночитаемый перечень runtime upstream: каждый прямой runtime-скрипт
# поставляется либо имеет явную причину замены или неприменимости в OpenWrt.
_inventory="$ROOT/tests/openwrt/runtime-inventory.tsv"
while IFS='|' read -r _source _state _member _mode _witness_file _witness _reason; do
    case "$_source" in ''|\#*) continue ;; esac
    [ -f "$ROOT/$_source" ] \
        && _t_ok || _t_bad "runtime inventory source is missing: $_source"
    case "$_state" in
        COMMON|ADAPTED)
            tar -tzf "$T/openwrt-rootfs.tar.gz" | grep -Fxq "$_member" \
                && _t_ok || _t_bad "$_state component $_source is absent from final rootfs at $_member"
            _actual_mode=$(tar -tvzf "$T/openwrt-rootfs.tar.gz" \
                | awk -v member="$_member" '$NF==member { print $1 }')
            assert_eq "$_state component $_source final mode" "$_mode" "$_actual_mode"
            if [ -n "$_witness_file" ] && [ -f "$ROOT/$_witness_file" ]; then
                assert_contains "$_state component $_source runtime wiring" "$ROOT/$_witness_file" "$_witness"
            else
                _t_bad "$_state component $_source has no verifiable runtime wiring witness"
            fi
            ;;
        N/A)
            [ "$_member" = - ] && [ -n "$_reason" ] \
                && _t_ok || _t_bad "N/A component $_source needs a technical reason and no payload target"
            _base=${_source##*/}
            if tar -tzf "$T/openwrt-rootfs.tar.gz" | grep -F "/$_base" >/dev/null 2>&1; then
                _t_bad "N/A source $_source unexpectedly ships in the product rootfs"
            else
                _t_ok
            fi
            ;;
        "MISSING BUG")
            _t_bad "upstream runtime component remains classified MISSING BUG: $_source"
            ;;
        *)
            _t_bad "invalid runtime inventory state [$_state] for $_source"
            ;;
    esac
done < "$_inventory"
for _source in "$ROOT"/files/*.sh "$ROOT"/files/init.d/* "$ROOT"/files/ndm/*.sh \
    "$ROOT"/files/*.awk "$ROOT"/files/S99zapret2.new; do
    [ -f "$_source" ] || continue
    _rel=${_source#"$ROOT/"}
    grep -Fq "$_rel|" "$_inventory" \
        && _t_ok || _t_bad "upstream runtime source $_rel has no completeness inventory row"
done
for _source in "$ROOT"/files/lists/* "$ROOT"/files/lists/extra_strats/*/*/* \
    "$ROOT"/files/lists/extra_strats/*/*/*/*; do
    [ -f "$_source" ] || continue
    _rel=${_source#"$ROOT/"}
    grep -Fq "$_rel|" "$ROOT/tests/openwrt/runtime-inventory.tsv" \
        && _t_ok || _t_bad "upstream list source $_rel has no completeness inventory row"
done
for _source in "$ROOT"/files/etc/*; do
    [ -f "$_source" ] || continue
    _rel=${_source#"$ROOT/"}
    grep -Fq "$_rel|" "$ROOT/tests/openwrt/runtime-inventory.tsv" \
        && _t_ok || _t_bad "upstream runtime trust/TLS source $_rel has no completeness inventory row"
done
_geosite_mode=$(tar -tvzf "$T/openwrt-rootfs.tar.gz" \
    | awk '$NF ~ /usr\/lib\/z2k\/z2k-geosite\.sh$/ { print $1 }')
assert_eq "final release tarball keeps the geosite executor executable" \
    "-rwxr-xr-x" "$_geosite_mode"
_list_update_mode=$(tar -tvzf "$T/openwrt-rootfs.tar.gz" \
    | awk '$NF ~ /usr\/lib\/z2k\/z2k-update-lists\.sh$/ { print $1 }')
assert_eq "final release tarball keeps list updater executable" \
    "-rwxr-xr-x" "$_list_update_mode"
for _script in tg-check.sh rt-check.sh warp-check.sh fw-check.sh list-refresh.sh tcp16-check.sh; do
    _mode=$(tar -tvzf "$T/openwrt-rootfs.tar.gz" \
        | awk -v path="platform/openwrt/$_script" 'index($NF, path) { print $1 }')
    assert_eq "final rootfs makes directly invoked $_script executable" \
        "-rwxr-xr-x" "$_mode"
done
for _script in z2k-tcp16-probe.sh z2k-geosite.sh z2k-update-lists.sh \
    z2k-dns-check.sh z2k-blocked-monitor.sh \
    z2k-insta-ip-refresh.sh; do
    _mode=$(tar -tvzf "$T/openwrt-rootfs.tar.gz" \
        | awk -v path="usr/lib/z2k/$_script" 'index($NF, path) { print $1 }')
    assert_eq "final rootfs makes upstream executor $_script executable" \
        "-rwxr-xr-x" "$_mode"
done
tar -tzf "$T/openwrt-rootfs.tar.gz" | grep -Fxq './usr/lib/z2k/platform/openwrt/insta-ip.sh' \
    && _t_ok || _t_bad "final rootfs omits the OpenWrt dnsmasq adapter for upstream IP refresh"
[ -x "$T/stage/usr/lib/z2k/platform/openwrt/tcp16-check.sh" ] \
    && _t_ok || _t_bad "first-result TCP16 scheduler entrypoint remains executable"
[ -x "$T/stage/usr/lib/z2k/platform/openwrt/update.sh" ] \
    && _t_ok || _t_bad "canonical update.sh remains executable for CLI and cron"
cmp -s "$T/release-keys/$_key_id.pub" \
    "$T/stage/usr/lib/z2k/platform/openwrt/release-keys/$_key_id.pub" \
    && _t_ok || _t_bad "current release trust key is included in the complete payload"
[ ! -e "$T/stage/opt/zapret2/etc/z2k-update-pub.pem" ] \
    && _t_ok || _t_bad "obsolete generic update key is not shipped as a second authority"

for _kind in tg rt detect; do
    case "$_kind" in
        tg) _bin=tg-mtproxy-client ;;
        rt) _bin=z2k-rt-proxy ;;
        detect) _bin=z2k-detect ;;
    esac
    _count=$(find "$T/stage/usr/lib/z2k/bin" -path "*/linux-*/*" -name "$_bin" -type f | wc -l | tr -d ' ')
    assert_eq "all seven $_kind binaries staged" "7" "$_count"
done
printf "DISTRIB_ARCH='mips_24kc'\n" > "$T/openwrt_release"
_out=$(Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release" "$T/stage/usr/lib/z2k/bin/z2k-rt-proxy" argv)
assert_eq "RT wrapper resolves big-endian MIPS from OpenWrt target" "rt-mips
argv" "$_out"
printf "DISTRIB_ARCH='aarch64_cortex-a53'\n" > "$T/openwrt_release"
_out=$(Z2K_OW_OPENWRT_RELEASE_FILE="$T/openwrt_release" "$T/stage/usr/lib/z2k/bin/z2k-detect" argv)
assert_eq "detector wrapper resolves ARM64 from OpenWrt target" "detect-arm64
argv" "$_out"

# Настоящий bootstrap должен связать runtime с обычными исполняемыми файлами,
# а не с каталогами, которые тоже проходят проверку shell -x.
if (
    Z2K_ROOT="$T/stage/usr/lib/z2k"
    Z2K_ETC="$T/bootstrap-etc"
    Z2K_TMP="$T/bootstrap-tmp"
    Z2K_ZAPRET2_RUNTIME="$T/stage/opt/zapret2"
    Z2K_OW_LEGACY_DETECT_INIT="$T/no-legacy-init"
    Z2K_OW_PROC_ROOT="$T/no-proc"
    export Z2K_ROOT Z2K_ETC Z2K_TMP Z2K_ZAPRET2_RUNTIME \
        Z2K_OW_LEGACY_DETECT_INIT Z2K_OW_PROC_ROOT
    . "$ROOT/platform/openwrt/paths.sh"
    . "$ROOT/platform/openwrt/bootstrap.sh"
    z2k_ow_bootstrap || exit 1
    for _pair in nfq2/nfqws2 ip2net/ip2net mdig/mdig; do
        _link="$Z2K_ZAPRET2_RUNTIME/$_pair"
        [ -L "$_link" ] && [ -f "$_link" ] && [ -x "$_link" ] || {
            echo "runtime-ссылка не указывает на исполняемый файл: $_link" >&2
            exit 1
        }
    done
); then
    _t_ok
else
    _t_bad "настоящий bootstrap создаёт рабочие ссылки для всех трёх runtime-бинарников"
fi
_t_done
