#!/bin/sh
# package/openwrt/make-seed.sh - сборка share/seed.tar.gz (BUILD-TIME, host).
#
# Проблема: свежий роутер после opkg install должен стартовать, а lib/lua/
# fake/lists принадлежат UPDATER'у (пакет их напрямую не поставляет — иначе
# один файл был бы и package-owned, и updater-overwritten). Решение: пакет
# везёт bootstrap-seed (tarball из этого же дерева), postinst извлекает его
# в /, и с этого момента содержимое — updater-owned (первый же апдейт
# перезапишет подписанным контентом; seed.tar.gz остаётся нетронутым).
#
# Состав seed выводится, а не захардкожен: openwrt-назначения release_map
# минус package-owned из ownership.map. Расхождение — ошибка сборки.
#
# Использование:
#   make-seed.sh --list <tree>    # "repo-path -> dest" (для тестов/сборки)
#   make-seed.sh <tree> <out.tar.gz>

set -e
if [ "$1" = "--list" ]; then
    MODE="--list"
    TREE="$2"
else
    MODE="build"
    TREE="$1"
    OUT="$2"
fi

[ -n "$TREE" ] || { echo "make-seed: нужен корень дерева" >&2; exit 1; }
[ -d "$TREE" ] || { echo "make-seed: нет $TREE" >&2; exit 1; }

# shellcheck disable=SC1090,SC1091
. "$TREE/lib/release_map.sh" || exit 1

_pkg_owned() {
    # $1 — target-path; 0 если package-owned по ownership.map
    grep -qxF "$1 package" "$TREE/package/openwrt/ownership.map" 2>/dev/null
}

_seed_list() {
    # Список "repo-path<TAB>dest" для seed: openwrt-назначения под
    # /usr/lib/z2k/, кроме package-owned (ставятся Makefile напрямую).
    # tracked + untracked (сборка идёт и по незакоммиченному дереву в dev).
    ( cd "$TREE" && git ls-files --cached --others --exclude-standard ) | while IFS= read -r _f; do
        [ -n "$_f" ] || continue
        Z2K_PLATFORM=openwrt z2k_install_paths "$_f" 2>/dev/null | while IFS= read -r _d; do
            [ -n "$_d" ] || continue
            case "$_d" in
                /usr/lib/z2k/*) ;;
                *) continue ;; # /etc/* ставит пакет; user-state создаёт bootstrap
            esac
            _pkg_owned "$_d" && continue
            printf '%s\t%s\n' "$_f" "$_d"
        done
    done
}

if [ "$MODE" = "--list" ]; then
    _seed_list
    exit 0
fi

[ -n "$OUT" ] || { echo "make-seed: нужен выходной tar.gz" >&2; exit 1; }
STAGE="$(mktemp -d)" || exit 1
trap 'rm -rf "$STAGE"' EXIT INT TERM

_seed_list | while IFS="$(printf '\t')" read -r _src _dst; do
    mkdir -p "$STAGE/$(dirname "$_dst")"
    cp -f "$TREE/$_src" "$STAGE/$_dst"
done

# Strategy.txt прематериализуем в staging (payload read-only в рантайме):
# strats-манифесты уже в seed (корень payload), conf — во временный каталог.
_tmpconf="$(mktemp -d)" || exit 1
ZAPRET2_DIR="$STAGE/usr/lib/z2k" CONFIG_DIR="$_tmpconf" LISTS_DIR="$STAGE/usr/lib/z2k/lists" \
sh -c ". '$TREE/lib/utils.sh' >/dev/null 2>&1; . '$TREE/lib/strategies.sh' >/dev/null 2>&1; . '$TREE/platform/openwrt/materialize.sh'; z2k_ow_materialize '$STAGE/usr/lib/z2k'" \
    || { echo "make-seed: материализация стратегий не удалась" >&2; exit 1; }
rm -rf "$_tmpconf"

# seed.meta — локальный факт о содержимом seed (НЕ из remote manifest):
# platform, release-тег (UPDATES.json current дерева сборки — обязан быть
# в истории OpenWrt-линии, иначе первый update упрётся в unknown tag) и
# ref (коммит дерева; должен существовать на remote для immutable-скачивания).
# seed_ensure пишет installed-tag из meta только при ОТСУТСТВИИ tag
# (существующий tag не трогает никогда — иначе package upgrade со старым
# seed откатил бы версию).
_seed_tag="$(sed -n 's/.*"current"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' "$TREE/UPDATES.json" | head -1)"
[ -n "$_seed_tag" ] || { echo "make-seed: нет current в $TREE/UPDATES.json" >&2; exit 1; }
_seed_ref="$(git -C "$TREE" rev-parse --short HEAD 2>/dev/null || printf 'unknown')"
mkdir -p "$STAGE/usr/lib/z2k/share" || exit 1
printf 'platform=openwrt\ntag=%s\nref=%s\n' "$_seed_tag" "$_seed_ref" > "$STAGE/usr/lib/z2k/share/seed.meta" || exit 1

# Alias-симлинки blob-имён (как install.sh на Keenetic): валидатор ищет
# блоб ПО ИМЕНИ (fake/<имя>[.bin]), а часть имён не совпадает с файлами
# (quic_google, tls_max_ru, quic[1456]...). Источник — та же таблица
# "имя:файл" в platform/openwrt/optbase.sh (единственное место правды):
# где имя ≠ файлу — симлинк имя.bin -> файл. tar хранит их как ссылки.
_optbase="$TREE/platform/openwrt/optbase.sh"
if [ -f "$_optbase" ]; then
    grep -o '"[A-Za-z_][A-Za-z0-9_]*:[A-Za-z0-9_.-]*"' "$_optbase" 2>/dev/null \
        | tr -d '"' | while IFS=: read -r _bn _bf; do
        [ -n "$_bn" ] && [ -n "$_bf" ] || continue
        [ "$_bn.bin" = "$_bf" ] && continue
        [ -f "$STAGE/usr/lib/z2k/fake/$_bf" ] || continue
        ln -sf "$_bf" "$STAGE/usr/lib/z2k/fake/$_bn.bin" 2>/dev/null || \
            { echo "make-seed: симлинк $_bn.bin не встал" >&2; exit 1; }
    done || exit 1
fi

tar -czf "$OUT" -C "$STAGE" usr || exit 1
printf 'seed: %s (%s)\n' "$OUT" "$(du -h "$OUT" | cut -f1)"
