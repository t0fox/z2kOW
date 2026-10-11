#!/bin/sh
# Обязательная проверка релиза: установить кандидат предыдущим опубликованным движком.
set -eu

if [ "$#" -lt 6 ] || [ "$#" -gt 8 ]; then
    echo "использование: upgrade-acceptance.sh ПРЕДЫДУЩИЙ_МАНИФЕСТ ПОДПИСЬ_ПРЕДЫДУЩЕГО КАНДИДАТ_МАНИФЕСТ КАТАЛОГ_КАНДИДАТА КВИТАНЦИЯ АРХИТЕКТУРА [ПОДПИСЬ_КАНДИДАТА] [legacy-tmpfs-transition]" >&2
    exit 2
fi

previous_manifest=$1
previous_signature=$2
candidate_manifest=$3
candidate_dir=$4
receipt=$5
architecture=$6
candidate_signature=${7:-}
transition_mode=${8:-}
[ -z "$transition_mode" ] || [ "$transition_mode" = legacy-tmpfs-transition ] || {
    echo "неизвестный режим проверки обновления: $transition_mode" >&2
    exit 2
}
previous_archive=$(mktemp "${RUNNER_TEMP:-/tmp}/z2kow-previous-published-rootfs.XXXXXX")
trap 'rm -f "$previous_archive"' EXIT HUP INT TERM

previous_asset=$(python3 - "$previous_manifest" "$architecture" <<'PY'
import json
import re
import sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
arch = sys.argv[2]
record = manifest.get("artifacts", {}).get(arch) if isinstance(manifest.get("artifacts"), dict) else None
if record is None:
    record = manifest.get("artifact")
if not isinstance(record, dict):
    raise SystemExit(f"в предыдущем подписанном манифесте нет архива OpenWrt для {arch}")
url, sha, size, name = (record.get("url"), record.get("sha256"), record.get("size_bytes"), record.get("filename"))
if not isinstance(url, str) or not url.startswith("https://github.com/t0fox/z2kOW/releases/download/"):
    raise SystemExit("URL предыдущего архива не является контролируемым ресурсом релиза GitHub")
if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
    raise SystemExit("неверный формат SHA-256 предыдущего архива")
if not isinstance(size, int) or size <= 0 or not isinstance(name, str):
    raise SystemExit("неверный размер или имя предыдущего архива")
print(f"{url}|{sha}|{size}|{name}")
PY
)
IFS='|' read -r previous_url previous_sha previous_size _previous_name <<EOF_ASSET
$previous_asset
EOF_ASSET

candidate_asset=$(python3 - "$candidate_manifest" "$candidate_dir" "$architecture" "$transition_mode" <<'PY'
import json
import pathlib
import re
import sys
manifest = json.load(open(sys.argv[1], encoding="utf-8"))
directory = pathlib.Path(sys.argv[2])
arch = sys.argv[3]
legacy_transition = len(sys.argv) > 4 and sys.argv[4] == "legacy-tmpfs-transition"
record = manifest.get("artifact") if legacy_transition else None
if record is None:
    record = manifest.get("artifacts", {}).get(arch) if isinstance(manifest.get("artifacts"), dict) else None
if record is None:
    record = manifest.get("artifact")
if not isinstance(record, dict):
    raise SystemExit(f"в манифесте кандидата нет архива OpenWrt для {arch}")
name, sha, size = record.get("filename"), record.get("sha256"), record.get("size_bytes")
if not isinstance(name, str) or pathlib.Path(name).name != name:
    raise SystemExit("неверное имя архива кандидата")
if not isinstance(sha, str) or not re.fullmatch(r"[0-9a-f]{64}", sha):
    raise SystemExit("неверный формат SHA-256 архива кандидата")
if not isinstance(size, int) or size <= 0:
    raise SystemExit("неверный размер архива кандидата")
print(f"{directory / name}|{name}|{sha}|{size}")
PY
)
IFS='|' read -r candidate_archive _candidate_name candidate_sha candidate_size <<EOF_CANDIDATE
$candidate_asset
EOF_CANDIDATE

curl --fail --location --silent --show-error --connect-timeout 10 --max-time 300 \
    -o "$previous_archive" "$previous_url"
[ "$(wc -c < "$previous_archive" | tr -d ' \t\r\n')" = "$previous_size" ] || {
    echo "размер предыдущего опубликованного rootfs не совпадает с подписанным манифестом" >&2
    exit 1
}
if ! printf '%s  %s\n' "$previous_sha" "$previous_archive" | sha256sum -c - >/dev/null; then
    echo "SHA-256 предыдущего rootfs не совпадает с подписанным манифестом" >&2
    exit 1
fi
echo "ПРОВЕРЕНО: подписью подтверждён SHA-256 предыдущего rootfs"
[ "$(wc -c < "$candidate_archive" | tr -d ' \t\r\n')" = "$candidate_size" ] || {
    echo "размер rootfs кандидата не совпадает с его манифестом" >&2
    exit 1
}
if ! printf '%s  %s\n' "$candidate_sha" "$candidate_archive" | sha256sum -c - >/dev/null; then
    echo "SHA-256 rootfs кандидата не совпадает с его манифестом" >&2
    exit 1
fi
echo "ПРОВЕРЕНО: SHA-256 rootfs кандидата совпадает с манифестом"

set -- python3 tests/openwrt/accept_release_upgrade.py \
    --previous-manifest "$previous_manifest" \
    --previous-signature "$previous_signature" \
    --previous-archive "$previous_archive" \
    --candidate-manifest "$candidate_manifest" \
    --candidate-archive "$candidate_archive" \
    --architecture "$architecture" \
    --receipt-output "$receipt"
if [ -n "$candidate_signature" ]; then
    set -- "$@" --candidate-signature "$candidate_signature"
fi
if [ "$transition_mode" = legacy-tmpfs-transition ]; then
    set -- "$@" --legacy-tmpfs-transition
fi
"$@"
