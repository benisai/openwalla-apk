#!/bin/sh

# Standalone installer for Openwalla WireGuard support.
# Installs the standard OpenWrt WireGuard userspace package and LuCI protocol
# handler. Package dependencies provide matching kernel and netifd support.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SCRIPT_DIR/lib/openwalla-standalone-common.sh"

log "Installing OpenWrt WireGuard package support"

update_package_feeds
if ! install_pkg_if_available "wireguard-tools"; then
	echo "Unable to install wireguard-tools from this router's configured package feeds."
	exit 1
fi

if ! install_pkg_if_available "luci-proto-wireguard"; then
	echo "Unable to install luci-proto-wireguard from this router's configured package feeds."
	exit 1
fi

if ! command -v wg >/dev/null 2>&1; then
	echo "wireguard-tools installed, but the wg command is unavailable."
	exit 1
fi

log "WireGuard and LuCI protocol support installed. No VPN configuration was changed."
