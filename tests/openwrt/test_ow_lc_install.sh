#!/bin/sh
# tests/openwrt/test_ow_lc_install.sh - Level C: install-ветка.
# S1 fresh seed=current -> update none (payload/tag нетронуты);
# S2 seed older -> converge дотягивает до current;
# S3 interrupted (нет marker) -> postinst retry сходится;
# S17 tag-missing -> restore из seed.meta + apply через настоящий launcher.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-lc-install"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
LC_REPO="$REPO"; export LC_REPO
. "$(dirname "$0")/lc_harness.sh"
lc_init || { echo "FAIL[ow-lc-install]: init" >&2; exit 1; }
trap 'rm -rf "$LC_T"' EXIT INT TERM

# origin: история p-84.0 -> SEEDTAG, lib/utils.sh новее seed
lc_origin_put "lib/utils.sh" <<'EOF'
#!/bin/sh
# origin newer utils (converge target)
Z2K_LC_ORIGIN_MARKER=1
EOF

# --- S1: fresh install, seed tag == current -> update none ---
lc_fresh_sysroot || { echo "FAIL[ow-lc-install]: sysroot" >&2; exit 1; }
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
printf 'p-84.0|patch|ref840|lib/utils.sh||false|false\n%s|patch|ref847|lib/utils.sh||false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
printf '%s\n' "$SEEDTAG" > "$Z2K_AU_INSTALLED_TAG_FILE"
lc_begin; lc_snap s1-before
lc_apply
assert_eq "S1 rc" "0" "$LC_RC"
assert_eq "S1 tag стоит" "$SEEDTAG" "$(lc_tag)"
assert_eq "S1 payload цел" "$(sha256sum "$Z2K_ROOT/lib/utils.sh" | awk '{print $1}')" \
    "$(git -C "$REPO" show HEAD:lib/utils.sh | sha256sum | awk '{print $1}')"
lc_snap s1-after
lc_mutlog s1-before s1-after "S1 fresh-current none"

# --- S2: seed older -> converge дотягивает ---
printf 'p-84.0\n' > "$Z2K_AU_INSTALLED_TAG_FILE"
lc_begin; lc_snap s2-before
lc_apply
assert_eq "S2 rc" "0" "$LC_RC"
assert_eq "S2 tag=current" "$SEEDTAG" "$(lc_tag)"
assert_contains "S2 payload новый" "$Z2K_ROOT/lib/utils.sh" "Z2K_LC_ORIGIN_MARKER=1"
lc_snap s2-after
lc_mutlog s2-before s2-after "S2 old-seed converge"

# --- S3: interrupted (payload частично + нет marker/tag) -> retry ---
rm -rf "$Z2K_ROOT/lib" "$Z2K_ETC/.payload-initialized" "$Z2K_AU_INSTALLED_TAG_FILE"
mkdir -p "$Z2K_ROOT/lib"
lc_begin; lc_snap s3-before
z2k_ow_seed_ensure >/dev/null 2>&1
assert_eq "S3 retry rc" "0" "$?"
assert_eq "S3 tag=seed" "$SEEDTAG" "$(lc_tag)"
z2k_ow_payload_ok && _t_ok || _t_bad "S3 payload не сошёлся"
lc_snap s3-after
lc_mutlog s3-before s3-after "S3 interrupted retry"

# --- S17: tag-missing -> restore из meta + настоящий launcher in-process ---
# Отдельный свежий sysroot: trust-pin от прошлых сценариев иначе упрётся в
# ratchet (верное security-поведение, но не то, что проверяем здесь).
# update.sh пере-сорсит lib'ы: z2k_fetch уцелел (upstream command -v guard),
# au_manifest_verify — настоящий, поэтому PUBKEY в никуда: идём легальной
# no-key веткой (rc 2, храповик не защёлкнут — как первая установка).
lc_fresh_sysroot || { echo "FAIL[ow-lc-install]: sysroot s17" >&2; exit 1; }
SEEDTAG="$(sed -n 's/^tag=//p' "$Z2K_ROOT/share/seed.meta" | head -1)"
printf 'p-84.0|patch|ref840|lib/utils.sh||false|false\n%s|patch|ref847|lib/utils.sh||false|false\n' \
    "$SEEDTAG" | lc_manifest "$SEEDTAG" || exit 1
rm -f "$Z2K_AU_INSTALLED_TAG_FILE"
lc_begin; lc_snap s17-before
( export Z2K_ROOT Z2K_ETC Z2K_TMP Z2K_AU_MANUAL=1 Z2K_AU_NO_JITTER=1
  export Z2K_AU_PUBKEY=/nonexistent-pubkey.pem
  < /dev/null . "$Z2K_ROOT/platform/openwrt/update.sh" apply >/dev/null 2>&1 )
assert_eq "S17 launcher rc" "0" "$?"
assert_eq "S17 tag восстановлен" "$SEEDTAG" "$(lc_tag)"
lc_snap s17-after
lc_mutlog s17-before s17-after "S17 missing-tag restore"

_t_done
