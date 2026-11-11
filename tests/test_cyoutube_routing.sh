#!/bin/sh
# c.youtube.com направляется через отдельный пул Googlevideo.
set -eu
ROOT=$(CDPATH='' cd -- "$(dirname "$0")/.." && pwd)
TMP=$(mktemp -d "${TMPDIR:-/tmp}/z2k-cyoutube.XXXXXX")
trap 'rm -rf "$TMP"' EXIT INT TERM
ZAPRET2_DIR="$TMP/router"
mkdir -p "$ZAPRET2_DIR/extra_strats/TCP/YT" \
         "$ZAPRET2_DIR/extra_strats/TCP/YT_GV" \
         "$ZAPRET2_DIR/extra_strats/TCP/RKN" \
         "$ZAPRET2_DIR/extra_strats/UDP/YT" "$TMP/work"
Z2K_GEOSITE_SOURCE_ONLY=1 . "$ROOT/files/z2k-geosite.sh"
TMP_DIR="$TMP/work"
YT="$EXTRA/TCP/YT/List.txt"
GV="$EXTRA/TCP/YT_GV/List.txt"
RKN="$EXTRA/TCP/RKN/List.txt"
UDP="$EXTRA/UDP/YT/List.txt"
printf 'youtube.com\nrr1.sn-test.c.youtube.com\nc.youtube.com\n' > "$YT"
printf 'googlevideo.com\ncustom.example\n' > "$GV"
printf 'youtube.com\ngooglevideo.com\nc.youtube.com\nrr2.sn-test.c.youtube.com\nother1.example\nother2.example\nother3.example\nother4.example\nother5.example\n' > "$RKN"
printf 'youtube.com\n' > "$UDP"
subtract_googlevideo_from_yt >/dev/null
grep -qiFx 'c.youtube.com' "$GV"
grep -qxF 'custom.example' "$GV"
printf 'youtube.com\n' > "$TMP/yt.expected"
cmp "$TMP/yt.expected" "$YT"
cmp "$UDP" "$EXTRA/UDP/YT/List.txt"
subtract_yt_from_rkn >/dev/null
printf 'other1.example\nother2.example\nother3.example\nother4.example\nother5.example\n' > "$TMP/rkn.expected"
cmp "$TMP/rkn.expected" "$RKN"
cp "$GV" "$TMP/gv.first"
subtract_googlevideo_from_yt >/dev/null
cmp "$TMP/gv.first" "$GV"
printf '[PASS] c.youtube.com: добавлен в GV, удалён из YT/RKN; локальные записи и UDP сохранены\n'
