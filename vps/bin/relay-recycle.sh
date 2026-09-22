#!/bin/sh
# Ночная проверка памяти: подготовить здоровый экземпляр, затем drain старого.
set -eu
LIMIT_MB="${LIMIT_MB:-900}"
rss_kb=$(ps -o rss= -C z2k-vps-relay 2>/dev/null | awk '{s+=$1} END{print s+0}')
rss_mb=$((rss_kb / 1024))
if [ "$rss_mb" -ge "$LIMIT_MB" ]; then
    logger -t z2k-relay-recycle "RSS ${rss_mb}MB >= ${LIMIT_MB}MB: switching with drain"
    exec /opt/z2k-vps/bin/relay-switch.sh
fi
logger -t z2k-relay-recycle "RSS ${rss_mb}MB below ${LIMIT_MB}MB: no switch needed"
