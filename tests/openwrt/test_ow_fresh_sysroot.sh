#!/bin/sh
# tests/openwrt/test_ow_fresh_sysroot.sh - fresh install end-to-end в sysroot.
#
# Пустой rootfs -> seed extract -> ensure-binaries -> preflight, БЕЗ ambient
# /opt хоста (все пути — через env-override в $T; хостовый /opt не читается).
# Слои:
#   A. fixture runtime: preflight PASS/FAIL обе ветки (fail — с runtime_missing);
#   B. настоящий seed (make-seed.sh) расп feedbackаковывается в sysroot;
#   C. ensure-binaries offline: fixture-манифест + stub z2k_fetch —
#      missing->install, valid->NOOP (fetch вообще не зовётся),
#      corrupt->replace, warpd-absent->skip, owner start НЕ вызывается;
#   D. init wiring: preflight-fail блокирует procd_open_instance;
#   E. настоящий tarball (только с Z2K_RT_TARBALL): closure -> preflight PASS.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-fresh-sysroot"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-sysroot.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM

SR="$T/sysroot"
mkdir -p "$SR/usr/lib/z2k/bin" "$SR/usr/lib/z2k/platform/openwrt" \
         "$SR/etc/z2k" "$SR/tmp/z2k" "$T/bin" "$T/repo" "$T/au-tmp"
export PATH="$T/bin:/usr/bin:/bin"
# required binaries fixture (preflight требует TG/RT/detect как completeness;
# rt-стаб so-mark capable — иначе preflight требует capability, см. contract).
for _b in tg-mtproxy-client z2k-rt-proxy z2k-detect; do
    printf '#!/bin/sh\n# so-mark\nexit 0\n' > "$SR/usr/lib/z2k/bin/$_b"
    chmod +x "$SR/usr/lib/z2k/bin/$_b"
done

# --- ambient /opt хоста не используется: все runtime-пути ниже — в $T ---
export Z2K_PLATFORM=openwrt
export Z2K_ROOT="$SR/usr/lib/z2k" Z2K_ETC="$SR/etc/z2k" Z2K_TMP="$SR/tmp/z2k"
export Z2K_CONFIG="$SR/etc/z2k/config" Z2K_BIN="$SR/usr/lib/z2k/bin"
export Z2K_ZAPRET2_RUNTIME="$T/rt"
export Z2K_NFQWS2="$T/rt/nfq2/nfqws2"
export Z2K_AU_TMP_DIR="$T/au-tmp" Z2K_AU_LOG_FILE="$T/au.log"
export Z2K_AU_SBIN="$Z2K_BIN"
export Z2K_LIB="$REPO/lib"
export Z2K_RUN="$SR/tmp/z2k/runtime"
mkdir -p "$Z2K_RUN"

# --- A. fixture runtime + preflight обе ветки ---
# Фикстура моделирует УСТАНОВЛЕННЫЙ пакет (mode contract): exec-файлы +x.
mkdir -p "$T/rt/nfq2" "$T/rt/ip2net" "$T/rt/mdig" "$T/rt/init.d/openwrt" "$T/rt/lua" "$T/rt/ipset"
for _b in nfq2/nfqws2 ip2net/ip2net mdig/mdig; do
    printf '#!/bin/sh\nexit 0\n' > "$T/rt/$_b"
    chmod +x "$T/rt/$_b"
done
printf '#!/bin/sh\nexit 0\n' > "$T/rt/ipset/create_ipset.sh"
chmod +x "$T/rt/ipset/create_ipset.sh"
: > "$T/rt/init.d/openwrt/functions"
for _l in zapret-lib.lua zapret-antidpi.lua zapret-auto.lua; do
    : > "$T/rt/lua/$_l"
done
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/firewall.sh" || { echo "FAIL[ow-fresh-sysroot]: source firewall" >&2; exit 1; }
if z2k_ow_runtime_preflight 2>"$T/pre.out"; then _t_ok
else _t_bad "preflight на полном fixture runtime: $(cat "$T/pre.out")"; fi
rm -f "$T/rt/nfq2/nfqws2"
if z2k_ow_runtime_preflight 2>"$T/pre.out"; then
    _t_bad "preflight без nfqws2 прошёл"
else
    _t_ok
    case "$(cat "$T/pre.out")" in
        *runtime_missing*nfqws2*) _t_ok ;;
        *) _t_bad "preflight без nfqws2: нет runtime_missing (got: $(cat "$T/pre.out"))" ;;
    esac
fi
printf '#!/bin/sh\nexit 0\n' > "$T/rt/nfqws2.tmp"
chmod +x "$T/rt/nfqws2.tmp"
mv -f "$T/rt/nfqws2.tmp" "$T/rt/nfq2/nfqws2"
rm -f "$T/rt/lua/zapret-auto.lua"
if z2k_ow_runtime_preflight 2>"$T/pre.out"; then
    _t_bad "preflight без lua прошёл"
else
    _t_ok
    case "$(cat "$T/pre.out")" in
        *runtime_missing*zapret-auto.lua*) _t_ok ;;
        *) _t_bad "preflight без lua: нет runtime_missing" ;;
    esac
fi
: > "$T/rt/lua/zapret-auto.lua"
# required binaries: отсутствие любого роняет preflight (completeness).
rm -f "$SR/usr/lib/z2k/bin/tg-mtproxy-client"
if z2k_ow_runtime_preflight 2>"$T/pre.out"; then
    _t_bad "preflight без tg-mtproxy-client прошёл"
else
    _t_ok
    case "$(cat "$T/pre.out")" in
        *missing*required*binary*tg-mtproxy-client*) _t_ok ;;
        *) _t_bad "preflight без tg: нет missing required binary" ;;
    esac
fi
printf '#!/bin/sh\nexit 0\n' > "$SR/usr/lib/z2k/bin/tg-mtproxy-client"
chmod +x "$SR/usr/lib/z2k/bin/tg-mtproxy-client"

# --- B. настоящий seed в sysroot ---
sh "$REPO/package/openwrt/make-seed.sh" "$REPO" "$T/seed.tar.gz" >/dev/null 2>&1 \
    || { echo "FAIL[ow-fresh-sysroot]: make-seed" >&2; exit 1; }
tar -xzf "$T/seed.tar.gz" -C "$SR" || { echo "FAIL[ow-fresh-sysroot]: seed extract" >&2; exit 1; }
for _r in lib/utils.sh lib/config_official.sh webpanel/cgi/api.sh share/seed.meta; do
    if [ -s "$SR/usr/lib/z2k/$_r" ]; then _t_ok
    else _t_bad "seed: нет $_r в sysroot"; fi
done

# --- C. ensure-binaries offline (fixture manifest + stub fetch) ---
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/utils.sh" || { echo "FAIL[ow-fresh-sysroot]: source utils" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091
. "$REPO/lib/auto_update.sh" || { echo "FAIL[ow-fresh-sysroot]: source auto_update" >&2; exit 1; }
# shellcheck disable=SC1090,SC1091
. "$REPO/platform/openwrt/binaries.sh" || { echo "FAIL[ow-fresh-sysroot]: source binaries" >&2; exit 1; }
. "$REPO/platform/openwrt/manifest.sh" || { echo "FAIL[ow-fresh-sysroot]: source manifest" >&2; exit 1; }
_goarch="$(au_bin_goarch)"
[ -n "$_goarch" ] || { echo "FAIL[ow-fresh-sysroot]: goarch пуст на хосте" >&2; exit 1; }
_mkbin() { # $1 dest-name -> fixture manifest path; пишет тело, печатает "path sha"
    _mb="mtproxy-client/builds/$1-linux-${_goarch}"
    case "$1" in z2k-detect) _mb="z2k-detect/builds/$1-linux-${_goarch}" ;; esac
    # rt-фикстура so-mark capable (preflight capability, см. contract).
    if [ "$1" = "z2k-rt-proxy" ]; then
        printf '#!/bin/sh\necho fixture-%s\n# so-mark\n' "$1" > "$T/repo/$1-linux-${_goarch}"
    else
        printf '#!/bin/sh\necho fixture-%s\n' "$1" > "$T/repo/$1-linux-${_goarch}"
    fi
    printf '%s %s\n' "$_mb" "$(sha256sum "$T/repo/$1-linux-${_goarch}" | awk '{print $1}')"
}
: > "$T/man.entries"
for _n in tg-mtproxy-client z2k-rt-proxy z2k-detect; do
    _me="$(_mkbin "$_n")" || { echo "FAIL[ow-fresh-sysroot]: mkbin $_n" >&2; exit 1; }
    printf '"%s": "%s",\n' "${_me%% *}" "${_me##* }" >> "$T/man.entries"
done
_mw="$(_mkbin "z2k-warpd" | sed 's|^mtproxy-client/builds/|z2k-warpd/builds/|')" || exit 1
printf '"%s": "%s"\n' "${_mw%% *}" "${_mw##* }" >> "$T/man.entries"
# fixture-файл warpd лежит под mtproxy-именем; manifest ждёт z2k-warpd-путь —
# fetch-стаб маппит по basename, warpd всё равно пропускается (absent+optional).
{ printf '{"current":"p-fixture","platform":"openwrt","install_map":{},"files_sha256": {\n'; cat "$T/man.entries"; printf '},"history":[]}\n'; } > "$T/au-tmp/UPDATES.json"
# Production mode now always resolves a signed manifest pair when no embedded
# snapshot is present.  Keep the test offline by serving the fixture through
# that exact common fetch/verify boundary.
cp -f "$T/au-tmp/UPDATES.json" "$T/fixture-manifest.json"
au_fetch_pair() {
    cp -f "$T/fixture-manifest.json" "$3" || return 1
    printf 'signed\n' > "$4"
}
au_manifest_verify() { return 0; }
# stub fetch: по basename URL отдаёт fixture-файл; считает вызовы.
z2k_fetch() { # $1 url $2 dest — fixture transport (считает вызовы)
    printf 'x\n' >> "$T/fetch.calls"
    _b="$(basename "$1" | sed 's/?z2kcb=.*//')"
    [ -f "$T/repo/$_b" ] || return 1
    cp -f "$T/repo/$_b" "$2" || return 1
    return 0
}
# owner bounce запрещён флагом: +x стабы в sysroot обязаны НЕ вызваться.
for _s in rt-proc.sh warp-proc.sh; do
    printf '#!/bin/sh\necho BOUNCED >> "$T/bounced"\nexit 0\n' > "$SR/usr/lib/z2k/platform/openwrt/$_s"
    chmod +x "$SR/usr/lib/z2k/platform/openwrt/$_s"
done
: > "$T/fetch.calls"; : > "$T/bounced"
export Z2K_AU_TMP_DIR Z2K_AU_SBIN Z2K_BIN Z2K_PLATFORM Z2K_ROOT
if z2k_ow_ensure_binaries >"$T/ensure.log" 2>&1; then _t_ok
else _t_bad "ensure-binaries на пустом bin: $(tail -2 "$T/ensure.log" | tr '\n' '|')"; fi
for _n in tg-mtproxy-client z2k-rt-proxy z2k-detect; do
    if [ -x "$Z2K_BIN/$_n" ]; then _t_ok
    else _t_bad "ensure: нет $Z2K_BIN/$_n"; fi
done
if [ -e "$Z2K_BIN/z2k-warpd" ]; then
    _t_bad "ensure: warpd поставился без кнопки"
else
    _t_ok
fi
if [ -s "$T/bounced" ]; then
    _t_bad "ensure: owner bounce вызвался (флаг не сработал)"
else
    _t_ok
fi
# NOOP: fetch умирает — второй прогон обязан пройти без единого вызова.
z2k_fetch() { printf 'x\n' >> "$T/fetch.calls"; return 1; }
_calls_before="$(wc -l < "$T/fetch.calls" | tr -d ' ')"
if z2k_ow_ensure_binaries >"$T/ensure2.log" 2>&1; then _t_ok
else _t_bad "ensure NOOP упал"; fi
_calls_after="$(wc -l < "$T/fetch.calls" | tr -d ' ')"
assert_eq "ensure NOOP: fetch не вызывался" "$_calls_before" "$_calls_after"
# corrupt -> replace: бьём tg, возвращаем рабочий fetch.
printf 'garbage' > "$Z2K_BIN/tg-mtproxy-client"
z2k_fetch() {
    printf 'x\n' >> "$T/fetch.calls"
    _b="$(basename "$1" | sed 's/?z2kcb=.*//')"
    [ -f "$T/repo/$_b" ] || return 1
    cp -f "$T/repo/$_b" "$2" || return 1
    return 0
}
if z2k_ow_ensure_binaries >"$T/ensure3.log" 2>&1; then _t_ok
else _t_bad "ensure replace упал"; fi
_tg_want="$(sha256sum "$T/repo/tg-mtproxy-client-linux-${_goarch}" | awk '{print $1}')"
assert_eq "ensure replace: sha сошлась" "$_tg_want" "$(sha256sum "$Z2K_BIN/tg-mtproxy-client" | awk '{print $1}')"
# manifest отсутствует + fetch мёртв -> громкий rc!=0, файлы целы.
mv "$T/au-tmp/UPDATES.json" "$T/au-tmp/UPDATES.json.bak"
au_fetch_pair() { return 1; }
z2k_fetch() { return 1; }
_before_tg="$(sha256sum "$Z2K_BIN/tg-mtproxy-client" | awk '{print $1}')"
if z2k_ow_ensure_binaries >"$T/ensure4.log" 2>&1; then
    _t_bad "ensure без манифеста/сети прошёл"
else
    _t_ok
fi
assert_eq "ensure fail: файлы не тронуты" "$_before_tg" "$(sha256sum "$Z2K_BIN/tg-mtproxy-client" | awk '{print $1}')"
mv "$T/au-tmp/UPDATES.json.bak" "$T/au-tmp/UPDATES.json"
au_fetch_pair() {
    cp -f "$T/fixture-manifest.json" "$3" || return 1
    printf 'signed\n' > "$4"
}

# --- D. init wiring: preflight-fail блокирует procd_open_instance ---
# shellcheck disable=SC1090,SC1091
. "$REPO/package/openwrt/files/etc/init.d/z2k" || { echo "FAIL[ow-fresh-sysroot]: source init" >&2; exit 1; }
printf 'ENABLED=1\n' > "$Z2K_CONFIG"
z2k_load_adapter() { return 0; }
z2k_ow_lan() { printf '192.168.1.1\n'; }
z2k_ow_bootstrap() { return 0; }
z2k_ow_generate() { return 0; }
z2k_ow_optbase() { printf 'OPTBASE-STUB\n'; return 0; }
procd_open_instance() { printf 'PROCD-CALLED\n' >> "$T/procd.calls"; }
procd_set_param() { return 0; }
procd_close_instance() { return 0; }
z2k_ow_fw_apply() { return 0; }
# Порядок, а не fw-семантика (она — в start_gate с настоящим verify):
# consumer-wait и verify здесь стабы, иначе тест упирается в фикстуру nft.
_z2k_ow_wait_consumer() { return 0; }
z2k_ow_fw_verify() { return 0; }
z2k_ow_tg_verify() { return 0; }
z2k_ow_rt_verify() { return 0; }
z2k_ow_custom_daemons() { return 0; }
z2k_ow_tg() { return 0; }
z2k_ow_rt() { return 0; }
z2k_ow_warp() { return 0; }
export Z2K_ROOT Z2K_ETC Z2K_CONFIG
rm -f "$T/rt/nfq2/nfqws2"
: > "$T/procd.calls"
if start_service 2>/dev/null; then
    _t_bad "start_service без runtime прошёл"
else
    _t_ok
fi
if [ -s "$T/procd.calls" ]; then
    _t_bad "start_service без runtime дошёл до procd"
else
    _t_ok
fi
printf '#!/bin/sh\nexit 0\n' > "$T/rt/nfqws2.tmp"
chmod +x "$T/rt/nfqws2.tmp"
mv -f "$T/rt/nfqws2.tmp" "$T/rt/nfq2/nfqws2"
: > "$T/procd.calls"
if start_service 2>/dev/null; then _t_ok
else _t_bad "start_service с runtime упал"; fi
if grep -q PROCD-CALLED "$T/procd.calls" 2>/dev/null; then _t_ok
else _t_bad "start_service с runtime не дошёл до procd"; fi

# --- E. настоящий tarball (только с Z2K_RT_TARBALL): closure -> preflight ---
# Раскладка — как ставит ПАКЕТ (mode contract): exec-файлам +x вручную,
# т.к. tarball хранит их без битов, а +x даёт recipe (INSTALL_BIN).
# Именно это расхождение скрывало live-баг §12 от тестов.
if [ -n "${Z2K_RT_TARBALL:-}" ] && [ -f "$Z2K_RT_TARBALL" ]; then
    mkdir -p "$T/rtreal"
    tar -xzf "$Z2K_RT_TARBALL" -C "$T/rtreal" || { echo "FAIL[ow-fresh-sysroot]: tarball extract" >&2; exit 1; }
    _rd="$T/rtreal/$(tar -tzf "$Z2K_RT_TARBALL" 2>/dev/null | sed -n 's|^\([^/]*\)/$|\1|p' | head -1)"
    [ -n "$_rd" ] && [ -d "$_rd" ] || { echo "FAIL[ow-fresh-sysroot]: tarball topdir" >&2; exit 1; }
    mkdir -p "$T/rtreal-rt/nfq2" "$T/rtreal-rt/ip2net" "$T/rtreal-rt/mdig" \
             "$T/rtreal-rt/init.d/openwrt" "$T/rtreal-rt/lua" "$T/rtreal-rt/ipset"
    cp -f "$_rd/binaries/linux-arm64/nfqws2" "$T/rtreal-rt/nfq2/" 2>/dev/null \
        || { echo "FAIL[ow-fresh-sysroot]: нет arm64 nfqws2 в tarball" >&2; exit 1; }
    cp -f "$_rd/binaries/linux-arm64/ip2net" "$T/rtreal-rt/ip2net/" 2>/dev/null || exit 1
    cp -f "$_rd/binaries/linux-arm64/mdig" "$T/rtreal-rt/mdig/" 2>/dev/null || exit 1
    cp -f "$_rd/init.d/openwrt/functions" "$T/rtreal-rt/init.d/openwrt/" || exit 1
    cp -f "$_rd/ipset/create_ipset.sh" "$T/rtreal-rt/ipset/" 2>/dev/null \
        || { echo "FAIL[ow-fresh-sysroot]: нет create_ipset.sh в tarball" >&2; exit 1; }
    # +x — ровно exec-ролям из runtime-mode.contract (INSTALL_BIN в пакете).
    chmod +x "$T/rtreal-rt/nfq2/nfqws2" "$T/rtreal-rt/ip2net/ip2net" \
             "$T/rtreal-rt/mdig/mdig" "$T/rtreal-rt/ipset/create_ipset.sh"
    ( cd "$_rd/lua" && for _l in zapret-lib.lua.gz zapret-antidpi.lua.gz zapret-auto.lua.gz; do
        gzip -dc "$_l" > "$T/rtreal-rt/lua/${_l%.gz}" || exit 1
    done ) || { echo "FAIL[ow-fresh-sysroot]: lua unpack" >&2; exit 1; }
    _save_rt="$Z2K_ZAPRET2_RUNTIME"
    Z2K_ZAPRET2_RUNTIME="$T/rtreal-rt"; export Z2K_ZAPRET2_RUNTIME
    if z2k_ow_runtime_preflight 2>"$T/pre-real.out"; then _t_ok
    else _t_bad "preflight на настоящем tarball: $(cat "$T/pre-real.out")"; fi
    Z2K_ZAPRET2_RUNTIME="$_save_rt"; export Z2K_ZAPRET2_RUNTIME
else
    echo "SKIP[ow-fresh-sysroot]: нет Z2K_RT_TARBALL (релизный tarball; в CI подкладывается)"
    echo "SUITE-SECTION[ow-fresh-sysroot-realtarball]: skipped"
fi

_t_done
