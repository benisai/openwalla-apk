#!/bin/sh

# Standalone installer for baseline Openwalla OpenWrt packages.
# Installs ubus, sqlite, usage, conntrack, and QR code dependencies used by the app.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SCRIPT_DIR/lib/openwalla-standalone-common.sh"

log "Installing standard Openwrt applications for Openwalla"

require_file "$FILES_DIR/openwalla.config"
require_file "$RPCD_ACL"

update_package_feeds
install_pkg_if_available "uhttpd-mod-ubus"
install_pkg_if_available "nlbwmon"
install_first_available_pkg "vnstat" vnstat2 vnstat
install_first_available_pkg "sqlite-cli" sqlite3-cli sqlite3
install_pkg_if_available "conntrack"
install_pkg_if_available "qrencode"

ensure_openwalla_config
install_rpcd_acl

if uci -q get uhttpd.main >/dev/null 2>&1; then
	set_uci uhttpd.main.home "/www"
	uci commit uhttpd
fi

configure_vnstat_interface "br-lan"
enable_restart_service vnstat
enable_restart_service nlbwmon

log "Standard Openwrt applications installed."
