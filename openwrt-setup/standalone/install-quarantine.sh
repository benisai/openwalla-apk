#!/bin/sh

# Standalone installer for Openwalla device quarantine.
# Installs and enables the DHCP lease watcher/firewall quarantine service.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SCRIPT_DIR/lib/openwalla-standalone-common.sh"

log "Installing Openwalla device quarantine"

require_file "$FILES_DIR/openwalla-device-quarantine.sh"
require_file "$FILES_DIR/openwalla-device-quarantine.init"
require_file "$FILES_DIR/openwalla.config"
require_file "$RPCD_ACL"

ensure_openwalla_config
ensure_uci_section quarantine quarantine

install_file "$FILES_DIR/openwalla-device-quarantine.sh" /usr/bin/openwalla-device-quarantine 0755
install_file "$FILES_DIR/openwalla-device-quarantine.init" /etc/init.d/openwalla-device-quarantine 0755
install_rpcd_acl

set_uci_default openwalla.quarantine.enabled "0"
set_uci_default openwalla.quarantine.interval "15"
set_uci_default openwalla.quarantine.leases_file "/tmp/dhcp.leases"
set_uci_default openwalla.quarantine.state_file "/tmp/openwalla-quarantine-known.txt"
set_uci_default openwalla.quarantine.rule_prefix "openwalla_quarantine_"
uci commit openwalla

enable_restart_service openwalla-device-quarantine

log "Device quarantine installed."
