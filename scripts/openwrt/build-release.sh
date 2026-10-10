#!/bin/sh
# Build OpenWrt rootfs transport artifacts; never builds z2k APKs.
set -eu
ROOT="$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)"
OUT=""
_legacy_rootfs=0
while [ "$#" -gt 0 ]; do
    case "$1" in
        --out) [ "$#" -ge 2 ] || { echo "--out requires a directory" >&2; exit 2; }; OUT="$2"; shift 2 ;;
        --legacy-rootfs) _legacy_rootfs=1; shift ;;
        *) echo "usage: build-release.sh --out DIR [--legacy-rootfs]" >&2; exit 2 ;;
    esac
done
[ -n "$OUT" ] || { echo "usage: build-release.sh --out DIR [--legacy-rootfs]" >&2; exit 2; }
command -v python3 >/dev/null 2>&1 || { echo "build-release: python3 is required" >&2; exit 1; }
command -v go >/dev/null 2>&1 || { echo "build-release: Go is required" >&2; exit 1; }
_release_tag="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1],encoding="utf-8"))["current"])' "$ROOT/UPDATES.json")"
[ -n "$_release_tag" ] || { echo "build-release: UPDATES.json has no current release" >&2; exit 1; }
_source_sha="${GITHUB_SHA:-$(git -C "$ROOT" rev-parse HEAD)}"
case "$_source_sha" in *[!0-9a-f]*|'') echo "build-release: source commit must be a full lowercase SHA-1" >&2; exit 1 ;; esac
[ "${#_source_sha}" -eq 40 ] || { echo "build-release: source commit must be a full lowercase SHA-1" >&2; exit 1; }

_pin="$ROOT/platform/openwrt/runtime-pin"
_url="$(sed -n 's/^URL=//p' "$_pin" | head -1 | tr -d '\r\n')"
_sha="$(sed -n 's/^SHA256=//p' "$_pin" | head -1 | tr -d '\r\n')"
[ -n "$_url" ] && [ "${#_sha}" -eq 64 ] || { echo "build-release: runtime pin is malformed" >&2; exit 1; }

_tmp="$(mktemp -d "${TMPDIR:-/tmp}/z2k-release.XXXXXX")"
trap 'rm -rf "$_tmp"' EXIT HUP INT TERM
_runtime="$_tmp/zapret2-runtime.tar.gz"
if command -v curl >/dev/null 2>&1; then
    curl --fail --location --silent --show-error --connect-timeout 10 --max-time 300 -o "$_runtime" "$_url"
elif command -v wget >/dev/null 2>&1; then
    wget -q -T 30 -O "$_runtime" "$_url"
else
    echo "build-release: curl or wget is required" >&2; exit 1
fi
_got="$(sha256sum "$_runtime" | awk '{print $1}')"
[ "$_got" = "$_sha" ] || { echo "build-release: pinned zapret2 runtime hash mismatch" >&2; exit 1; }
Z2K_RUNTIME_ARCHIVE="$_runtime" sh "$ROOT/tests/openwrt/test_ow_runtime_artifact.sh"

_warpd="$_tmp/z2k-warpd"
mkdir -p "$_warpd"
(
    cd "$ROOT/z2k-warpd"
    GOTOOLCHAIN=local go test -tags openwrt -overlay openwrt-overlay/overlay.json ./...
    # Match the architecture folders shipped by the pinned upstream runtime.
    # mips64le is intentionally omitted: the pinned zapret2 payload has only
    # linux-mips64 (big endian), so advertising it would ship a broken router.
    for arch in arm64:arm64 arm:arm amd64:x86_64 386:x86 mips:mips mipsle:mipsel riscv64:riscv64; do
        goarch=${arch%%:*}
        runtime_arch=${arch#*:}
        mkdir -p "$_warpd/linux-$runtime_arch"
        case "$goarch" in
            mips|mipsle) GOTOOLCHAIN=local GOOS=linux GOARCH="$goarch" GOMIPS=softfloat CGO_ENABLED=0 \
                go build -tags openwrt -overlay openwrt-overlay/overlay.json -trimpath -buildvcs=false \
                -ldflags="-s -w -X main.version=$_release_tag" \
                -o "$_warpd/linux-$runtime_arch/z2k-warpd" ./cmd/z2k-warpd || exit 1 ;;
            *) GOTOOLCHAIN=local GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 \
                go build -tags openwrt -overlay openwrt-overlay/overlay.json -trimpath -buildvcs=false \
                -ldflags="-s -w -X main.version=$_release_tag" \
                -o "$_warpd/linux-$runtime_arch/z2k-warpd" ./cmd/z2k-warpd || exit 1 ;;
        esac
    done
)

# TG's upstream executable has a per-build default relay secret injected into
# the official binary. Test the adapted source, then ship only the matching
# upstream release binaries verified against that release's files_sha256.
_tg="$_tmp/tg-mtproxy-client"
(
    cd "$ROOT/mtproxy-client"
    GOTOOLCHAIN=local go test ./...
)
python3 "$ROOT/scripts/openwrt/fetch_upstream_tg.py" --manifest "$ROOT/UPDATES.json" --output "$_tg"

# These executables remain in the same complete payload as the selected TG and
# WARP binaries. Tiny dispatch wrappers choose OpenWrt's precise target ABI.
_rt="$_tmp/z2k-rt-proxy"
_detect="$_tmp/z2k-detect"
mkdir -p "$_rt" "$_detect"
(
    cd "$ROOT/rt-proxy"
    GOTOOLCHAIN=local go test ./...
    for arch in arm64:arm64 arm:arm amd64:x86_64 386:x86 mips:mips mipsle:mipsel riscv64:riscv64; do
        goarch=${arch%%:*}; runtime_arch=${arch#*:}; mkdir -p "$_rt/linux-$runtime_arch"
        case "$goarch" in
            arm) GOOS=linux GOARCH=arm GOARM=7 CGO_ENABLED=0 GOTOOLCHAIN=local \
                go build -trimpath -buildvcs=false -ldflags="-s -w" \
                -o "$_rt/linux-$runtime_arch/z2k-rt-proxy" . || exit 1 ;;
            mips|mipsle) GOOS=linux GOARCH="$goarch" GOMIPS=softfloat CGO_ENABLED=0 GOTOOLCHAIN=local \
                go build -trimpath -buildvcs=false -ldflags="-s -w" \
                -o "$_rt/linux-$runtime_arch/z2k-rt-proxy" . || exit 1 ;;
            *) GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 GOTOOLCHAIN=local \
                go build -trimpath -buildvcs=false -ldflags="-s -w" \
                -o "$_rt/linux-$runtime_arch/z2k-rt-proxy" . || exit 1 ;;
        esac
    done
)
(
    cd "$ROOT/z2k-detect"
    GOTOOLCHAIN=local go test ./...
    for arch in arm64:arm64 arm:arm amd64:x86_64 386:x86 mips:mips mipsle:mipsel riscv64:riscv64; do
        goarch=${arch%%:*}; runtime_arch=${arch#*:}; mkdir -p "$_detect/linux-$runtime_arch"
        case "$goarch" in
            arm) GOOS=linux GOARCH=arm GOARM=5 CGO_ENABLED=0 GOTOOLCHAIN=local \
                go build -trimpath -buildvcs=false -ldflags="-s -w" \
                -o "$_detect/linux-$runtime_arch/z2k-detect" ./cmd/z2k-detect || exit 1 ;;
            mips|mipsle) GOOS=linux GOARCH="$goarch" GOMIPS=softfloat CGO_ENABLED=0 GOTOOLCHAIN=local \
                go build -trimpath -buildvcs=false -ldflags="-s -w" \
                -o "$_detect/linux-$runtime_arch/z2k-detect" ./cmd/z2k-detect || exit 1 ;;
            *) GOOS=linux GOARCH="$goarch" CGO_ENABLED=0 GOTOOLCHAIN=local \
                go build -trimpath -buildvcs=false -ldflags="-s -w" \
                -o "$_detect/linux-$runtime_arch/z2k-detect" ./cmd/z2k-detect || exit 1 ;;
        esac
    done
)

OUT="$(mkdir -p "$OUT" && CDPATH= cd -- "$OUT" && pwd)"
_stage="$_tmp/rootfs"
mkdir -p "$_stage"
sh "$ROOT/scripts/openwrt/stage-rootfs.sh" "$_stage" "$_runtime" "$_warpd" "$_tg" "$_rt" "$_detect"
for arch in arm64 arm x86_64 x86 mips mipsel riscv64; do
    python3 "$ROOT/scripts/openwrt/rootfs_bundle.py" --root "$_stage" \
        --output "$OUT/openwrt-rootfs-$arch.tar.gz" --arch "$arch"
done
if [ "$_legacy_rootfs" -eq 1 ]; then
    python3 "$ROOT/scripts/openwrt/rootfs_bundle.py" --root "$_stage" --output "$OUT/openwrt-rootfs.tar.gz"
fi

python3 - "$ROOT" "$OUT/UPDATES.json" <<'PY'
import sys
from pathlib import Path

sys.path.insert(0, str(Path(sys.argv[1]) / "scripts" / "openwrt"))
from controlled_release import copy_unsigned_candidate_manifest

copy_unsigned_candidate_manifest(Path(sys.argv[1]) / "UPDATES.json", Path(sys.argv[2]))
PY
if [ "$_legacy_rootfs" -eq 1 ]; then
    python3 "$ROOT/scripts/openwrt/controlled_release.py" attach \
        --manifest "$OUT/UPDATES.json" \
        --artifact "$OUT/openwrt-rootfs.tar.gz" \
        --url "https://github.com/t0fox/z2kOW/releases/download/openwrt-$_source_sha/openwrt-rootfs.tar.gz"
fi
printf 'candidates: %s/openwrt-rootfs-<arch>.tar.gz\nmanifest: %s/UPDATES.json (unsigned; do not publish until trusted signing)\n' "$OUT" "$OUT"
