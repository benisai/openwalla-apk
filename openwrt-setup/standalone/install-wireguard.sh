#!/bin/sh

# Standalone installer for Openwalla WireGuard support.
# Installs only the standard OpenWrt WireGuard userspace package. Its package
# dependencies provide the matching kernel and netifd support for the firmware.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SCRIPT_DIR/lib/openwalla-standalone-common.sh"

log "Installing OpenWrt WireGuard package support"

if command -v wg >/dev/null 2>&1; then
	log "WireGuard is already available. No package or configuration changes were made."
	exit 0
fi

update_package_feeds
if ! install_pkg_if_available "wireguard-tools"; then
	echo "Unable to install wireguard-tools from this router's configured package feeds."
	exit 1
fi

if ! command -v wg >/dev/null 2>&1; then
	echo "wireguard-tools installed, but the wg command is unavailable."
	exit 1
fi

log "WireGuard package support installed. No VPN configuration was changed."
