#!/bin/sh
# tests/openwrt/test_ow_paths.sh - Step 3: пути централизованы.
. "$(dirname "$0")/helper.sh"
. "$(dirname "$0")/fixture.sh"
_t_plan "ow-paths"
ow_fixture_init || { echo "FAIL[ow-paths]: fixture" >&2; exit 1; }
trap ow_fixture_done EXIT INT TERM

AD="$REPO/platform/openwrt"

# дефолты — в чистой комнате (фикстура экспортирует Z2K_*, они бы победили :-)
(
    unset Z2K_ETC Z2K_CONFIG Z2K_STATE Z2K_USER_LISTS Z2K_CONF_DIR \
          Z2K_ROOT Z2K_BIN Z2K_LIB Z2K_LUA_DIR Z2K_FAKE_DIR Z2K_LISTS_DIR \
          Z2K_EXTRA_STRATS_DIR Z2K_MANIFESTS_DIR Z2K_ADAPTER_DIR \
          Z2K_TMP Z2K_RUN Z2K_LOCKS Z2K_LOG Z2K_DOWNLOADS Z2K_GENERATED \
          Z2K_ZAPRET2_RUNTIME Z2K_NFQWS2
    . "$AD/paths.sh"
    [ "$Z2K_ETC" = "/etc/z2k" ] || { echo "Z2K_ETC=[$Z2K_ETC]" >&2; exit 1; }
    [ "$Z2K_ROOT" = "/usr/lib/z2k" ] || { echo "Z2K_ROOT=[$Z2K_ROOT]" >&2; exit 1; }
    [ "$Z2K_CONFIG" = "/etc/z2k/config" ] || exit 1
    [ "$Z2K_STATE" = "/etc/z2k/state" ] || exit 1
    [ "$Z2K_RUN" = "/tmp/z2k/runtime" ] || exit 1
    [ "$Z2K_LOG" = "/tmp/z2k/logs" ] || exit 1
    [ "$Z2K_TMP" = "/tmp/z2k" ] || exit 1
    [ "$Z2K_BIN" = "/usr/lib/z2k/bin" ] || exit 1
) && _t_ok || _t_bad "дефолты путей"

# override: окружение побеждает дефолты (наследуемые вычищаем — :- их бы взял)
(
    unset Z2K_CONFIG Z2K_STATE Z2K_USER_LISTS Z2K_CONF_DIR \
          Z2K_BIN Z2K_LIB Z2K_LUA_DIR Z2K_FAKE_DIR Z2K_LISTS_DIR \
          Z2K_EXTRA_STRATS_DIR Z2K_MANIFESTS_DIR Z2K_ADAPTER_DIR \
          Z2K_RUN Z2K_LOCKS Z2K_LOG Z2K_DOWNLOADS Z2K_GENERATED \
          Z2K_ZAPRET2_RUNTIME Z2K_NFQWS2
    Z2K_ETC=/x Z2K_ROOT=/y Z2K_TMP=/t
    . "$AD/paths.sh"
    [ "$Z2K_ETC" = "/x" ] && [ "$Z2K_ROOT" = "/y" ] && \
    [ "$Z2K_CONFIG" = "/x/config" ] && [ "$Z2K_RUN" = "/t/runtime" ]
) && _t_ok || _t_bad "env override путей"

# check: проходит на фикстуре, валится на пустом корне
( Z2K_ROOT="$T/root" Z2K_ETC="$T/etc" Z2K_TMP="$T/tmp"
  . "$AD/paths.sh" >/dev/null; z2k_ow_paths_check payload ) \
    && _t_ok || _t_bad "paths_check payload на фикстуре"
( Z2K_ROOT="$T/nonexistent" . "$AD/paths.sh" >/dev/null
  z2k_ow_paths_check payload 2>/dev/null ) \
    && _t_bad "paths_check молчит на отсутствующем корне" || _t_ok

# ни один SHELL-файл адаптера/пакета не содержит ГОЛЫХ литералов путей в КОДЕ
# (комментарии не в счёт): разрешена только bootstrap-форма VAR="${VAR:-<dflt>}".
# Makefile исключён осознанно: пути назначения $(1)/usr/lib/z2k — его работа.
_badpaths=""
for _f in "$REPO"/platform/openwrt/*.sh \
          "$REPO"/package/openwrt/files/etc/init.d/z2k \
          "$REPO"/package/openwrt/files/etc/hotplug.d/iface/90-z2k; do
    [ "$(basename "$_f")" = "paths.sh" ] && continue
    _hits="$(sed 's/#.*$//' "$_f" | grep -nE '/usr/lib/z2k|/etc/z2k|/tmp/z2k' | grep -v ':-' || true)"
    [ -n "$_hits" ] && _badpaths="$_badpaths $_f:$_hits"
done
if [ -z "$_badpaths" ]; then _t_ok; else _t_bad "литералы путей вне paths.sh: $_badpaths"; fi

_t_done
