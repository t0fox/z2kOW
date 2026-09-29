#!/bin/sh
# Behavioral contract for the canonical OpenWrt production release bundle.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-release-assets"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-assets.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
TOOL="$REPO/scripts/openwrt/release-assets.py"

# RED until the shared release asset helper exists.
if [ ! -f "$TOOL" ]; then
    _t_bad "missing scripts/openwrt/release-assets.py"
    _t_done
    exit $?
fi
command -v python3 >/dev/null 2>&1 || { _t_bad "python3 required"; _t_done; exit 1; }
command -v openssl >/dev/null 2>&1 || { _t_bad "openssl required for final-signature test"; _t_done; exit 1; }

SHA=0123456789abcdef0123456789abcdef01234567
mkdir -p "$T/dist" "$T/bin"
openssl ecparam -name prime256v1 -genkey -noout -out "$T/release.key" 2>/dev/null || exit 1
openssl ec -in "$T/release.key" -pubout -out "$T/release.pub" 2>/dev/null || exit 1
mkdir -p "$T/keys"
cp "$T/release.pub" "$T/keys/z2k-feed.pem"
cat > "$T/bin/apk" <<'APK'
#!/bin/sh
cmd="$1"; shift
keys_dir=
if [ "$cmd" = --keys-dir ]; then keys_dir="$1"; shift; cmd="$1"; shift; fi
case "$cmd" in
    adbdump)
        case "$1" in
            *packages.adb)
                sed -n -e 's/^P: /P: /p' "$1"
                if grep -q '^APK-INDEX-V1-SIGNED$' "$1"; then
                    printf 'sig fake-signature\n'
                    if [ ! -f "$keys_dir/z2k-feed.pem" ]; then printf 'UNTRUSTED\n'; fi
                fi
                ;;
            *) sed -n -e 's/^name=/name = /p' -e 's/^version=/version = /p' \
                -e 's/^arch=/arch = /p' "$1" ;;
        esac
        ;;
    mkndx)
        out=; files=; signed=0
        while [ "$#" -gt 0 ]; do
            case "$1" in
                -o|--output) out="$2"; shift 2 ;;
                --sign) signed=1; shift 2 ;;
                *.apk)
                    case "$1" in /*) echo "mkndx expects bundle-relative APK paths" >&2; exit 4 ;; esac
                    files="$files $1"; shift ;;
                *) shift ;;
            esac
        done
        [ -n "$out" ] || out=/dev/stdout
        {
            if [ "$signed" -eq 1 ]; then printf 'APK-INDEX-V1-SIGNED\n'; else printf 'APK-INDEX-V1\n'; fi
            for f in $files; do
                sed -n -e 's/^name=/P: /p' -e 's/^version=/V: /p' "$f"
            done
        } > "$out"
        ;;
    verify)
        [ "$#" -eq 1 ] && grep -q '^APK-INDEX-V1-SIGNED$' "$1"
        ;;
    *) echo "fake apk unexpected command: $cmd $*" >&2; exit 2 ;;
esac
APK
chmod +x "$T/bin/apk"

cat > "$T/packages.tsv" <<'EOF'
z2k-adapter|1.2.3-r1
z2k-webpanel|1.2.3-r1
z2k-warp-runtime|85.16.0-r1
z2k-zapret2-runtime|1.0.5.1-r4
EOF
while IFS='|' read -r name version; do
    cat > "$T/dist/$name-$version.apk" <<EOF
name=$name
version=$version
arch=aarch64_cortex-a53
payload=$name fixture
EOF
done < "$T/packages.tsv"
cat > "$T/dist/provenance.json" <<EOF
 {"production_release":true,"ci_snapshot":false,"verified_sdk":true,"seed_ref_verified_remote":true,"source_commit":"$SHA","package_version":"1.2.3","package_release":1,"openwrt_release":"25.12.5","target":"mediatek/filogic","arch":"aarch64_cortex-a53"}
EOF
cat > "$T/CHANGELOG.md" <<'EOF'
## [Unreleased]
- future change

## [1.2.3] - 2026-09-28
- production release note
EOF

run() { python3 "$TOOL" "$@"; }
run prepare --dist "$T/dist" --out "$T/bundle" --version 1.2.3 \
    --source-sha "$SHA" --ci-run-id 42 --changelog "$T/CHANGELOG.md" \
    --apk-tool "$T/bin/apk" --public-key "$T/keys/z2k-feed.pem" \
    --installer-template "$REPO/scripts/openwrt/install.sh" >"$T/prepare.log" 2>&1
_prepare_rc=$?
if [ "$_prepare_rc" -ne 0 ]; then cat "$T/prepare.log" >&2; fi
assert_eq "prepare rc" 0 "$_prepare_rc"
for f in packages.adb release-manifest.json SHA256SUMS RELEASE_NOTES.md \
    provenance.json install.sh z2k-feed.pem; do
    assert_file "prepare emits $f" "$T/bundle/$f"
done
assert_eq "four release APKs" 4 "$(find "$T/bundle" -maxdepth 1 -type f -name '*.apk' | wc -l | tr -d ' ')"
python3 - "$T/bundle/release-manifest.json" "$SHA" <<'PY'
import json, sys
m = json.load(open(sys.argv[1], encoding="utf-8"))
assert m["version"] == "1.2.3"
assert m["source_sha"] == sys.argv[2]
assert str(m["ci_run_id"]) == "42"
assert {a["filename"] for a in m["artifacts"] if a["filename"].endswith(".apk")} == {
    "z2k-adapter-1.2.3-r1.apk", "z2k-webpanel-1.2.3-r1.apk",
    "z2k-warp-runtime-85.16.0-r1.apk", "z2k-zapret2-runtime-1.0.5.1-r4.apk",
}
assert all(a.get("sha256") for a in m["artifacts"])
assert {"packages.adb", "provenance.json", "install.sh", "z2k-feed.pem"} <= {
    a["filename"] for a in m["artifacts"]
}
PY
assert_eq "manifest artifact/provenance fields" 0 "$?"
_key_fp="$(sha256sum "$T/keys/z2k-feed.pem" | awk '{print $1}')"
assert_contains "installer embeds the pinned production key fingerprint" "$T/bundle/install.sh" "EXPECTED_FEED_KEY_SHA256=\"$_key_fp\""
assert_contains "installer pins the candidate commit for key retrieval" "$T/bundle/install.sh" "$SHA"
assert_not_contains "installer has no unrendered key marker" "$T/bundle/install.sh" '@Z2K_'
assert_contains "release notes use version section" "$T/bundle/RELEASE_NOTES.md" "production release note"
assert_not_contains "release notes omit Unreleased" "$T/bundle/RELEASE_NOTES.md" "future change"
assert_contains "release notes include compatibility section" "$T/bundle/RELEASE_NOTES.md" "## Совместимость"
assert_contains "release notes include exact source SHA" "$T/bundle/RELEASE_NOTES.md" "$SHA"
run verify --bundle "$T/bundle" --version 1.2.3 --source-sha "$SHA" \
    --apk-tool "$T/bin/apk" >/dev/null 2>&1
assert_eq "verify prepared bundle" 0 "$?"

mkdir -p "$T/bad-arch-dist"
cp "$T/dist"/*.apk "$T/bad-arch-dist/"
cp "$T/dist/provenance.json" "$T/bad-arch-dist/"
sed -i 's/^arch=aarch64_cortex-a53$/arch=x86_64/' "$T/bad-arch-dist/z2k-adapter-1.2.3-r1.apk"
run prepare --dist "$T/bad-arch-dist" --out "$T/bad-arch-bundle" --version 1.2.3 \
    --source-sha "$SHA" --ci-run-id 42 --changelog "$T/CHANGELOG.md" \
    --apk-tool "$T/bin/apk" --public-key "$T/keys/z2k-feed.pem" \
    --installer-template "$REPO/scripts/openwrt/install.sh" >/dev/null 2>&1
assert_eq "reject APK outside the pinned target architecture" 1 "$?"

mkdir -p "$T/bad-provenance-dist"
cp "$T/dist"/*.apk "$T/bad-provenance-dist/"
cat > "$T/bad-provenance-dist/provenance.json" <<EOF
{"production_release":true,"ci_snapshot":false,"source_commit":"1123456789abcdef0123456789abcdef01234567","package_version":"1.2.3","package_release":1}
EOF
run prepare --dist "$T/bad-provenance-dist" --out "$T/bad-provenance-bundle" --version 1.2.3 \
    --source-sha "$SHA" --ci-run-id 42 --changelog "$T/CHANGELOG.md" \
    --apk-tool "$T/bin/apk" --public-key "$T/keys/z2k-feed.pem" \
    --installer-template "$REPO/scripts/openwrt/install.sh" >/dev/null 2>&1
assert_eq "reject builder provenance from a different SHA" 1 "$?"

cp -R "$T/bundle" "$T/missing-apk"
rm -f "$T/missing-apk/z2k-warp-runtime-85.16.0-r1.apk"
run verify --bundle "$T/missing-apk" --version 1.2.3 --source-sha "$SHA" --apk-tool "$T/bin/apk" >/dev/null 2>&1
assert_eq "reject missing APK" 1 "$?"
cp -R "$T/bundle" "$T/extra-apk"
printf extra > "$T/extra-apk/unexpected.apk"
run verify --bundle "$T/extra-apk" --version 1.2.3 --source-sha "$SHA" --apk-tool "$T/bin/apk" >/dev/null 2>&1
assert_eq "reject extra APK" 1 "$?"
cp -R "$T/bundle" "$T/changed-apk"
printf changed >> "$T/changed-apk/z2k-adapter-1.2.3-r1.apk"
run verify --bundle "$T/changed-apk" --version 1.2.3 --source-sha "$SHA" --apk-tool "$T/bin/apk" >/dev/null 2>&1
assert_eq "reject checksum mismatch" 1 "$?"
run verify --bundle "$T/bundle" --version 9.9.9 --source-sha "$SHA" --apk-tool "$T/bin/apk" >/dev/null 2>&1
assert_eq "reject version mismatch" 1 "$?"
run verify --bundle "$T/bundle" --version 1.2.3 --source-sha 1123456789abcdef0123456789abcdef01234567 --apk-tool "$T/bin/apk" >/dev/null 2>&1
assert_eq "reject source SHA mismatch" 1 "$?"

openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$T/wrong.key" 2>/dev/null || exit 1
openssl pkey -in "$T/wrong.key" -pubout -out "$T/wrong.pub" 2>/dev/null || exit 1
final_verify() ( cd "$T/bundle" && python3 "$TOOL" verify --final --public-key "$1" \
    --apk-tool "$T/bin/apk" --apk-key-dir "${2:-$T/keys}" )
final_verify "$T/release.pub" >/dev/null 2>&1
assert_eq "reject absent final signature" 1 "$?"
run sign --bundle "$T/bundle" --apk-tool "$T/bin/apk" \
    --private-key "$T/release.key" --public-key "$T/keys/z2k-feed.pem" \
    --overlay-out "$T/signature-overlay.tar.gz" >"$T/sign.log" 2>&1
_sign_rc=$?
if [ "$_sign_rc" -ne 0 ]; then cat "$T/sign.log" >&2; fi
assert_eq "offline signer produces verified overlay" 0 "$_sign_rc"
assert_file "offline signer emits bounded overlay" "$T/signature-overlay.tar.gz"
final_verify "$T/keys/z2k-feed.pem" >/dev/null 2>&1
assert_eq "accept pinned release checksum signature" 0 "$?"
python3 - "$T/bundle" "$T/remote-assets.json" <<'PY'
import hashlib, json, pathlib, sys
bundle = pathlib.Path(sys.argv[1])
files = sorted([*bundle.glob("z2k-*.apk"), *(bundle / name for name in (
    "packages.adb", "SHA256SUMS", "SHA256SUMS.sig", "release-manifest.json",
    "provenance.json", "install.sh", "z2k-feed.pem"
))])
json.dump([{"name": path.name, "digest": "sha256:" + hashlib.sha256(path.read_bytes()).hexdigest()}
           for path in files], open(sys.argv[2], "w", encoding="utf-8"))
PY
run verify-remote --bundle "$T/bundle" --remote-assets "$T/remote-assets.json" >/dev/null 2>&1
assert_eq "verify uploaded release asset digests" 0 "$?"
python3 - "$T/remote-assets.json" <<'PY'
import json, sys
assets = json.load(open(sys.argv[1], encoding="utf-8"))
assets[0]["digest"] = "sha256:" + "0" * 64
json.dump(assets, open(sys.argv[1], "w", encoding="utf-8"))
PY
run verify-remote --bundle "$T/bundle" --remote-assets "$T/remote-assets.json" >/dev/null 2>&1
assert_eq "reject uploaded asset with mismatched digest" 1 "$?"
mkdir -p "$T/wrong-keys"
final_verify "$T/keys/z2k-feed.pem" "$T/wrong-keys" >/dev/null 2>&1
assert_eq "reject untrusted APK index signature" 1 "$?"
final_verify "$T/wrong.pub" >/dev/null 2>&1
assert_eq "reject wrong final public key" 1 "$?"

_t_done
