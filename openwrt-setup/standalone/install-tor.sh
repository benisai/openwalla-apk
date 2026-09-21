#!/bin/sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SCRIPT_DIR/lib/openwalla-standalone-common.sh"

log "Installing Tor client support"

require_file "$FILES_DIR/openwalla.config"
require_file "$RPCD_ACL"
require_file "$FILES_DIR/openwalla-tor.sh"

update_package_feeds
install_pkg_if_available "tor"
install_pkg_if_available "tor-geoip" || true
command -v tor >/dev/null 2>&1 || {
	echo "Tor is unavailable from this router's package feeds."
	exit 1
}

ensure_openwalla_config
ensure_uci_section features ui
ensure_uci_section tor tor
install_rpcd_acl
install_file "$FILES_DIR/openwalla-tor.sh" /usr/bin/openwalla-tor 0755

set_uci openwalla.features.tor "1"
uci -q get openwalla.tor.mode >/dev/null 2>&1 || set_uci openwalla.tor.mode "none"
uci -q get openwalla.tor.dns_via_tor >/dev/null 2>&1 || set_uci openwalla.tor.dns_via_tor "0"
uci commit openwalla

/usr/bin/openwalla-tor configure
/usr/bin/openwalla-tor apply
enable_restart_service tor

log "Tor installed. No LAN traffic is routed until a scope is selected."
