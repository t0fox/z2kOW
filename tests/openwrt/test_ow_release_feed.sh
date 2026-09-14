#!/bin/sh
# tests/openwrt/test_ow_release_feed.sh - Stage 7: feed trust primitive + bootstrap.
# R19/R20 (§29/§59-уровень примитива: ephemeral Ed25519 sign/verify sha256sums;
# настоящий packages.adb требует apk(1) из SDK — PARTIAL, не подделываем).
# Bootstrap (§31-33): ключ, feed-URL идемпотентно, apk update/add, запреты.
. "$(dirname "$0")/helper.sh"
_t_plan "ow-release-feed"
REPO="$(cd "$(dirname "$0")/../.." && pwd)"
T="$(mktemp -d "${TMPDIR:-/tmp}/z2k-ow-rfeed.XXXXXX")" || exit 1
trap 'rm -rf "$T"' EXIT INT TERM
BOOT="$REPO/package/openwrt/z2k-feed-bootstrap.sh"

command -v openssl >/dev/null 2>&1 || { echo "FAIL[ow-release-feed]: нет openssl" >&2; exit 1; }
openssl genpkey -algorithm ed25519 -out /dev/null >/dev/null 2>&1 \
    || { echo "FAIL[ow-release-feed]: openssl без ed25519" >&2; exit 1; }

# --- ephemeral feed key (ТОЛЬКО тест; production ключ — офлайн, §65) ---
openssl genpkey -algorithm ed25519 -out "$T/feed.key" 2>/dev/null || exit 1
openssl pkey -in "$T/feed.key" -pubout -out "$T/feed.pub" 2>/dev/null || exit 1
openssl genpkey -algorithm ed25519 -out "$T/other.key" 2>/dev/null || exit 1
openssl pkey -in "$T/other.key" -pubout -out "$T/other.pub" 2>/dev/null || exit 1
printf 'z2k-adapter-0.1.0-r2.apk\nz2k-webpanel-0.1.0-r2.apk\n' > "$T/files.txt"
( cd "$T" && sha256sum files.txt > sha256sums )
# sign: та же примитивная схема, что у payload (pkeyutl -rawin), тем же ключом
# типа, что поставляет оператор для фида (формат ключа фида — см. контракт).
openssl pkeyutl -sign -rawin -inkey "$T/feed.key" \
    -in "$T/sha256sums" -out "$T/sha256sums.sig" 2>/dev/null || exit 1
# R19: правильный ключ принимает
openssl pkeyutl -verify -rawin -pubin -inkey "$T/feed.pub" \
    -in "$T/sha256sums" -sigfile "$T/sha256sums.sig" >/dev/null 2>&1 \
    && _t_ok || _t_bad "R19: правильный ключ не принял подпись"
# R20a: подмена файла — reject (пересчёт + verify)
printf 'TAMPERED\n' >> "$T/files.txt"
( cd "$T" && sha256sum -c sha256sums >/dev/null 2>&1 ) \
    && _t_bad "R20: подмена не замечена sha256sums" || _t_ok
# R20b: чужой ключ — reject
openssl pkeyutl -verify -rawin -pubin -inkey "$T/other.pub" \
    -in "$T/sha256sums" -sigfile "$T/sha256sums.sig" >/dev/null 2>&1 \
    && _t_bad "R20: чужой ключ принял подпись" || _t_ok
# R20c: подпись от другого содержимого — reject
printf 'other-bytes' > "$T/other.txt"
openssl pkeyutl -sign -rawin -inkey "$T/feed.key" \
    -in "$T/other.txt" -out "$T/other.sig" 2>/dev/null || exit 1
openssl pkeyutl -verify -rawin -pubin -inkey "$T/feed.pub" \
    -in "$T/sha256sums" -sigfile "$T/other.sig" >/dev/null 2>&1 \
    && _t_bad "R20: чужая подпись принята" || _t_ok
# production-приватный ключ в репо не лежит (и фикстуры наши — только $T)
if git -C "$REPO" ls-files | grep -Ei 'feed.*\.key$|\.rsa$|apk.*\.key$|feed.*\.pem$' | grep -qv 'z2k-update-pub.pem\|z2k-roots.pem'; then
    _t_bad "приватный ключ фида в репо"
else
    _t_ok
fi

# --- bootstrap: stub apk, изолированный root ---
mkdir -p "$T/sys" "$T/bin"
cat > "$T/bin/apk" <<EOF
#!/bin/sh
printf 'apk:%s\n' "\$*" >> "$T/apk.log"
exit 0
EOF
chmod +x "$T/bin/apk"
export PATH="$T/bin:/usr/bin:/bin"
# без ключа — отказ (production: никакого --allow-untrusted)
: > "$T/apk.log"
sh "$BOOT" --root "$T/sys" >/dev/null 2>&1
assert_eq "bootstrap без ключа rc" "1" "$?"
# с ключом: файлы + вызовы
: > "$T/apk.log"
sh "$BOOT" --root "$T/sys" --key-file "$T/feed.pub" \
    --feed-url "https://feed.example.com/r25" >/dev/null 2>&1
assert_eq "bootstrap rc" "0" "$?"
assert_eq "bootstrap key content" "$(cat "$T/feed.pub")" "$(cat "$T/sys/etc/apk/keys/z2k-feed.pem")"
assert_eq "bootstrap feed line" "https://feed.example.com/r25" "$(cat "$T/sys/etc/apk/repositories.d/z2k.list")"
if grep -q "apk:update" "$T/apk.log" && grep -q "apk:add z2k-adapter" "$T/apk.log"; then
    _t_ok
else
    _t_bad "bootstrap: нет apk update/add"
fi
if grep -qE "apk:.*upgrade|allow-untrusted" "$T/apk.log"; then
    _t_bad "bootstrap: upgrade/untrusted в проде"
else
    _t_ok
fi
assert_eq "bootstrap: distfeeds.list нетронут" "0" "$([ -e "$T/sys/etc/apk/distfeeds.list" ] && echo 1 || echo 0)"
# идемпотентность: второй прогон — строка одна
sh "$BOOT" --root "$T/sys" --key-file "$T/feed.pub" \
    --feed-url "https://feed.example.com/r25" >/dev/null 2>&1
assert_eq "bootstrap idempotent" "1" "$(grep -c . "$T/sys/etc/apk/repositories.d/z2k.list")"
# чужие строки в list не трогаем
printf 'https://other.example.com/x\n' >> "$T/sys/etc/apk/repositories.d/z2k.list"
sh "$BOOT" --root "$T/sys" --key-file "$T/feed.pub" \
    --feed-url "https://feed.example.com/r25" >/dev/null 2>&1
assert_eq "bootstrap чужие строки целы" "2" "$(grep -c . "$T/sys/etc/apk/repositories.d/z2k.list")"
# --insecure-dev-only: только явный dev-путь, громко
: > "$T/apk.log"
_out="$(sh "$BOOT" --root "$T/sys2" --insecure-dev-only 2>&1)"
assert_eq "bootstrap insecure rc" "0" "$?"
case "$_out" in
    *"ВНИМАНИЕ"*) _t_ok ;;
    *) _t_bad "bootstrap insecure молчит" ;;
esac
grep -q "allow-untrusted" "$T/apk.log" && _t_ok || _t_bad "bootstrap insecure не тот путь"

_t_done
