#!/bin/sh

# Installs OpenWrt Dynamic DNS support used by the Openwalla DDNS screen.

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/lib/openwalla-standalone-common.sh"

log "Installing OpenWrt Dynamic DNS support"

update_package_feeds
if ! install_pkg_if_available "ddns-scripts"; then
	echo "DDNS installation failed: ddns-scripts is unavailable from this router package feed."
	exit 1
fi
install_pkg_if_available "ddns-scripts-services" || true
install_pkg_if_available "luci-app-ddns" || true

ensure_uci_section features features
set_uci openwalla.features.ddns "1"
commit_uci

if [ -x /etc/init.d/ddns ]; then
	/etc/init.d/ddns enable >/dev/null 2>&1 || true
fi

log "Dynamic DNS support installed."
