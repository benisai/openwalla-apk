#!/bin/sh

# Installs OpenWrt Dynamic DNS support used by the Openwalla DDNS screen.

set -u

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
. "$SCRIPT_DIR/lib/openwalla-standalone-common.sh"

log "Installing OpenWrt Dynamic DNS support"

install_pkg_if_available "ddns-scripts"
install_pkg_if_available "ddns-scripts-services"
install_pkg_if_available "luci-app-ddns"

ensure_uci_section features features
set_uci openwalla.features.ddns "1"
commit_uci

if [ -x /etc/init.d/ddns ]; then
	/etc/init.d/ddns enable >/dev/null 2>&1 || true
fi

log "Dynamic DNS support installed."
