#!/bin/sh
# scripts/openwrt/write-provenance.sh - Stage 7: provenance.json (§24).
# Отдельный скрипт (а не inline в build-release.sh), чтобы форматом
# владел юнит-тест. Все входы — окружением, всё явное.
#
# Входы (обязательные): OW_RELEASE SDK_URL SDK_SHA256 SDK_DIR TARGET ARCH
#   SRC_COMMIT PKG_VERSION PKG_RELEASE ADAPTER_API SEED_TAG SEED_REF
#   VERIFIED_REMOTE(true|false) MANIFEST_CURRENT OUT(provenance.json path)
#   CI_SNAPSHOT(true|false) PRODUCTION_RELEASE(true|false) VERIFIED_SDK(true|false)
#   RUNTIME_TAG RUNTIME_URL RUNTIME_SHA256 (pin внешнего dataplane, §3)
#   UPSTREAM_PAYLOAD_SHA WARP_RUNTIME_SOURCE_SHA (independent source pins)
# Использование: VAR=... sh scripts/openwrt/write-provenance.sh
# POSIX sh + python3.

set -e
for _v in OW_RELEASE SDK_URL SDK_SHA256 SDK_DIR TARGET ARCH SRC_COMMIT \
         PKG_VERSION PKG_RELEASE ADAPTER_API SEED_TAG SEED_REF \
         VERIFIED_REMOTE MANIFEST_CURRENT OUT \
         CI_SNAPSHOT PRODUCTION_RELEASE VERIFIED_SDK \
         RUNTIME_TAG RUNTIME_URL RUNTIME_SHA256 \
         UPSTREAM_PAYLOAD_SHA WARP_RUNTIME_SOURCE_SHA; do
    eval "_val=\${$_v:-}"
    if [ -z "$_val" ]; then
        printf 'write-provenance: нет %s\n' "$_v" >&2
        exit 1
    fi
done
for _b in VERIFIED_REMOTE CI_SNAPSHOT PRODUCTION_RELEASE VERIFIED_SDK; do
    eval "_bv=\${$_b:-}"
    case "$_bv" in
        true|false) ;;
        *) printf 'write-provenance: %s только true|false\n' "$_b" >&2; exit 1 ;;
    esac
done
command -v python3 >/dev/null 2>&1 || { printf 'write-provenance: нужен python3\n' >&2; exit 1; }

python3 - <<'PYEOF'
import json, sys, datetime, os
# Канонические имена ключей (§24) — НЕ lower() env-имён (OW_RELEASE ->
# openwrt_release и т.д.): формат стабилен независимо от имён переменных.
keymap = (('OW_RELEASE', 'openwrt_release'), ('SDK_URL', 'sdk_url'),
          ('SDK_SHA256', 'sdk_sha256'), ('SDK_DIR', 'sdk_dir'),
          ('TARGET', 'target'), ('ARCH', 'arch'),
          ('SRC_COMMIT', 'source_commit'), ('PKG_VERSION', 'package_version'),
          ('PKG_RELEASE', 'package_release'), ('ADAPTER_API', 'adapter_api'),
          ('SEED_TAG', 'seed_tag'), ('SEED_REF', 'seed_ref'),
          ('MANIFEST_CURRENT', 'manifest_current'),
          ('RUNTIME_TAG', 'runtime_tag'), ('RUNTIME_URL', 'runtime_url'),
          ('RUNTIME_SHA256', 'runtime_sha256'),
          ('UPSTREAM_PAYLOAD_SHA', 'upstream_payload_sha'),
          ('WARP_RUNTIME_SOURCE_SHA', 'warp_runtime_source_sha'))
vals = {dst: os.environ[src] for src, dst in keymap}
vals['seed_ref_verified_remote'] = (os.environ['VERIFIED_REMOTE'] == 'true')
vals['ci_snapshot'] = (os.environ['CI_SNAPSHOT'] == 'true')
vals['production_release'] = (os.environ['PRODUCTION_RELEASE'] == 'true')
vals['verified_sdk'] = (os.environ['VERIFIED_SDK'] == 'true')
vals['built_at_utc'] = datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
out = os.environ['OUT']
d = open(out, 'w', encoding='utf-8')
json.dump(vals, d, indent=2, ensure_ascii=False)
d.write('\n')
PYEOF
printf 'write-provenance: %s\n' "$OUT"
