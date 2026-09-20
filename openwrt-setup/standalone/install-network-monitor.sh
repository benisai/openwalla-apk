#!/bin/sh

# Standalone installer for the Openwalla network monitor.
# Installs latency, outage, and physical Ethernet link monitoring.

set -u

SCRIPT_DIR="$(cd "$(dirname "$0")" 2>/dev/null && pwd)"
. "$SCRIPT_DIR/lib/openwalla-standalone-common.sh"

log "Installing Openwalla network monitor"

require_file "$FILES_DIR/openwalla-network-monitor.sh"
require_file "$FILES_DIR/openwalla-network-monitor.init"
require_file "$FILES_DIR/openwalla.config"
require_file "$RPCD_ACL"

ensure_openwalla_config
old_target="$(uci -q get openwalla.ping_monitor.target 2>/dev/null || true)"
old_threshold="$(uci -q get openwalla.ping_monitor.threshold 2>/dev/null || true)"
old_interval="$(uci -q get openwalla.ping_monitor.interval 2>/dev/null || true)"
old_output="$(uci -q get openwalla.ping_monitor.output_file 2>/dev/null || true)"

if [ -x /etc/init.d/openwalla-ping-monitor ]; then
	/etc/init.d/openwalla-ping-monitor stop >/dev/null 2>&1 || true
	/etc/init.d/openwalla-ping-monitor disable >/dev/null 2>&1 || true
fi

ensure_uci_section network_monitor network

install_file "$FILES_DIR/openwalla-network-monitor.sh" /usr/bin/openwalla-network-monitor 0755
install_file "$FILES_DIR/openwalla-network-monitor.init" /etc/init.d/openwalla-network-monitor 0755
install_rpcd_acl

set_uci openwalla.network_monitor.enabled "1"
set_uci openwalla.network_monitor.target "${old_target:-1.1.1.1}"
set_uci openwalla.network_monitor.interval "${old_interval:-60}"
set_uci openwalla.network_monitor.threshold "${old_threshold:-100}"
set_uci openwalla.network_monitor.warning_percent "95"
set_uci openwalla.network_monitor.timeout "2"
set_uci openwalla.network_monitor.output_file "/tmp/openwalla-network-monitor.txt"
set_uci openwalla.network_monitor.max_lines "2000"
set_uci openwalla.network_monitor.state_file "/tmp/openwalla-network-monitor.state"
set_uci openwalla.network_monitor.outage_failures "2"
set_uci openwalla.network_monitor.restore_successes "2"
set_uci openwalla.network_monitor.alert_cooldown "1800"
set_uci openwalla.network_monitor.interface_state_file "/tmp/openwalla-interface-monitor.state"
uci -q delete openwalla.ping_monitor >/dev/null 2>&1 || true
uci commit openwalla

if [ -n "$old_output" ] && [ -f "$old_output" ] && [ ! -f /tmp/openwalla-network-monitor.txt ]; then
	cp "$old_output" /tmp/openwalla-network-monitor.txt
fi
rm -f /usr/bin/openwalla-ping-monitor /etc/init.d/openwalla-ping-monitor

/usr/bin/openwalla-network-monitor --once || true
enable_restart_service openwalla-network-monitor

log "Network monitor installed."
