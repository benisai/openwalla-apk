#!/bin/sh

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SCRIPT_DIR/lib/openwalla-standalone-common.sh"

log "Installing Tailscale mesh VPN support"
require_file "$FILES_DIR/openwalla-tailscale.sh"
require_file "$FILES_DIR/openwalla.config"
require_file "$RPCD_ACL"

free_kb="$(df -k /overlay 2>/dev/null | awk 'NR == 2 { print $4 }')"
case "$free_kb" in ''|*[!0-9]*) free_kb=0 ;; esac
echo "WARNING: Tailscale is a large package and needs about 20 MB or more of free overlay storage."
if [ "$free_kb" -gt 0 ]; then
	echo "Available overlay storage: $((free_kb / 1024)) MB."
else
	echo "Available overlay storage could not be determined."
fi
if [ "$free_kb" -gt 0 ] && [ "$free_kb" -lt 20000 ]; then
	echo "Tailscale needs about 20 MB of free overlay storage; only $((free_kb / 1024)) MB is available."
	exit 1
fi

detect_pkg_mgr
install_pkg_if_available tailscale || { echo 'Tailscale is unavailable from this router package feed.'; exit 1; }
ensure_openwalla_config
ensure_uci_section tailscale tailscale
install_file "$FILES_DIR/openwalla-tailscale.sh" /usr/bin/openwalla-tailscale 0755
install_rpcd_acl

set_uci openwalla.tailscale.advertise_lan '0'
set_uci openwalla.tailscale.lan_subnet "$(ip -o -4 route show dev br-lan 2>/dev/null | awk '$1 ~ /\// { print $1; exit }')"
set_uci openwalla.tailscale.accept_routes '0'
set_uci openwalla.tailscale.advertise_exit_node '0'
uci commit openwalla
/usr/bin/openwalla-tailscale configure
enable_restart_service tailscale
log 'Tailscale installed. Sign in from the Openwalla Tailscale screen.'
