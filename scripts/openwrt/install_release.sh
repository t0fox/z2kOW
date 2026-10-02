#!/bin/sh
# Canonical OpenWrt deployment command: install_release <controlled-tag>.
set -eu
[ "$#" -eq 1 ] || { echo "usage: install_release <release-tag>" >&2; exit 2; }
Z2K_ROOT="${Z2K_ROOT:-/usr/lib/z2k}"
. "$Z2K_ROOT/platform/openwrt/paths.sh"
. "$Z2K_ROOT/platform/openwrt/env.sh"
. "$Z2K_ROOT/platform/openwrt/release.sh"
z2k_ow_install_release "$1"
