#!/bin/sh

# Standalone installer for Openwalla Multi-WAN support.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SCRIPT_DIR/lib/openwalla-standalone-common.sh"

log "Installing mwan3 Multi-WAN support"

require_file "$FILES_DIR/openwalla.config"
require_file "$RPCD_ACL"

update_package_feeds
install_pkg_if_available "mwan3"
install_pkg_if_available "luci-app-mwan3" || true

# Official mwan3 uses the nft compatibility layer on firewall4 releases.
if [ -x /sbin/fw4 ] || command -v fw4 >/dev/null 2>&1; then
	install_pkg_if_available "iptables-nft" || true
	install_pkg_if_available "ip6tables-nft" || true
fi

if [ ! -x /etc/init.d/mwan3 ] || ! command -v mwan3 >/dev/null 2>&1; then
	echo "mwan3 is unavailable from this router's configured package feeds."
	exit 1
fi

ensure_openwalla_config
ensure_uci_section features ui
install_rpcd_acl

set_uci openwalla.features.mwan3 "1"
uci commit openwalla

enable_restart_service mwan3

log "Multi-WAN support installed. Configure at least two working WAN interfaces before creating policies."
