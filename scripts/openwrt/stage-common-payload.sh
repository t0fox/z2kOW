#!/bin/sh
# Materialize upstream/OpenWrt-mapped product files into the one release tree.
set -eu
[ "$#" -eq 2 ] || { echo "usage: stage-common-payload.sh REPOSITORY STAGING_ROOT" >&2; exit 2; }
TREE="$1" STAGE="$2"
[ -d "$TREE" ] || { echo "stage-common-payload: repository is missing" >&2; exit 1; }
mkdir -p "$STAGE/usr/lib/z2k"
. "$TREE/lib/release_map.sh"

_files="$(mktemp)"
trap 'rm -f "$_files"' EXIT HUP INT TERM
(cd "$TREE" && git ls-files --cached --others --exclude-standard) > "$_files"
while IFS= read -r _file; do
    [ -n "$_file" ] || continue
    Z2K_PLATFORM=openwrt z2k_install_paths "$_file" 2>/dev/null \
        | while IFS= read -r _dest; do
            case "$_dest" in /usr/lib/z2k/*) ;; *) continue ;; esac
            [ -f "$TREE/$_file" ] || continue
            mkdir -p "$STAGE$(dirname "$_dest")"
            cp -p "$TREE/$_file" "$STAGE$_dest"
        done
done < "$_files"

_tmpconf="$(mktemp -d)"
trap 'rm -rf "$_tmpconf"; rm -f "$_files"' EXIT HUP INT TERM
ZAPRET2_DIR="$STAGE/usr/lib/z2k" CONFIG_DIR="$_tmpconf" LISTS_DIR="$STAGE/usr/lib/z2k/lists" \
    sh -c ". '$TREE/lib/utils.sh'; . '$TREE/lib/strategies.sh'; . '$TREE/platform/openwrt/materialize.sh'; z2k_ow_materialize '$STAGE/usr/lib/z2k'" \
    || { echo "stage-common-payload: strategy materialization failed" >&2; exit 1; }

# Alias names are source-driven by the same blob table used by optbase.
_map="$TREE/platform/openwrt/optbase.sh"
if [ -f "$_map" ]; then
    grep -o '"[A-Za-z_][A-Za-z0-9_]*:[A-Za-z0-9_.-]*"' "$_map" 2>/dev/null \
        | tr -d '"' | while IFS=: read -r _name _file; do
            [ -n "$_name" ] && [ -n "$_file" ] || continue
            [ "$_name.bin" = "$_file" ] && continue
            [ -f "$STAGE/usr/lib/z2k/fake/$_file" ] || continue
            ln -sf "$_file" "$STAGE/usr/lib/z2k/fake/$_name.bin"
        done
fi
echo "staged common product payload under $STAGE/usr/lib/z2k"
