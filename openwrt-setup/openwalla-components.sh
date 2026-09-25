#!/bin/sh

# Verifies and updates Openwalla-managed router helper files without changing
# packages, UCI feature settings, databases, or monitoring history.

set -u

COMPONENT_VERSION="2026.09.24.1"
RAW_BASE="${OPENWALLA_RAW_BASE:-https://raw.githubusercontent.com/benisai/openwalla-apk/main/openwrt-setup}"
ACTION="${1:-status}"
TMP_DIR="/tmp/openwalla-component-update.$$"
UPDATED=0
CURRENT=0
MANAGED=0
FAILED=0
TOUCHED_SERVICES=""

cleanup() {
	rm -rf "$TMP_DIR"
}
trap cleanup EXIT INT TERM

download() {
	url="$1"
	dst="$2"
	if command -v wget >/dev/null 2>&1; then
		wget -qO "$dst" "$url"
	elif command -v curl >/dev/null 2>&1; then
		curl -fsSL "$url" -o "$dst"
	else
		echo "ERROR|Neither wget nor curl is available"
		return 1
	fi
}

checksum() {
	if command -v sha256sum >/dev/null 2>&1; then
		sha256sum "$1" | awk '{print $1}'
	elif command -v openssl >/dev/null 2>&1; then
		openssl dgst -sha256 "$1" | awk '{print $NF}'
	else
		cksum "$1" | awk '{print $1 ":" $2}'
	fi
}

touch_service() {
	service="$1"
	[ -n "$service" ] || return 0
	case " $TOUCHED_SERVICES " in
	*" $service "*) ;;
	*) TOUCHED_SERVICES="$TOUCHED_SERVICES $service" ;;
	esac
}

check_file() {
	source_path="$1"
	destination="$2"
	mode="$3"
	service="$4"

	# Components that were never selected in Router Setup remain untouched.
	[ -e "$destination" ] || return 0
	MANAGED=$((MANAGED + 1))
	temporary="$TMP_DIR/$(basename "$destination").$MANAGED"
	if ! download "$RAW_BASE/$source_path" "$temporary"; then
		echo "FAILED|$destination|download failed"
		FAILED=$((FAILED + 1))
		return 0
	fi

	if [ "$(checksum "$temporary")" = "$(checksum "$destination")" ]; then
		CURRENT=$((CURRENT + 1))
		return 0
	fi

	echo "OUTDATED|$destination"
	[ "$ACTION" = "update" ] || return 0
	if cp "$temporary" "$destination" && chmod "$mode" "$destination"; then
		echo "UPDATED|$destination"
		UPDATED=$((UPDATED + 1))
		touch_service "$service"
	else
		echo "FAILED|$destination|install failed"
		FAILED=$((FAILED + 1))
	fi
}

mkdir -p "$TMP_DIR"
echo "AVAILABLE_VERSION|$COMPONENT_VERSION"
echo "INSTALLED_VERSION|$(uci -q get openwalla.core.component_version 2>/dev/null || echo unknown)"

while IFS='|' read -r source_path destination mode service; do
	[ -n "$source_path" ] || continue
	check_file "$source_path" "$destination" "$mode" "$service"
done <<'EOF'
files/openwalla-network-monitor.sh|/usr/bin/openwalla-network-monitor|0755|openwalla-network-monitor
files/openwalla-network-monitor.init|/etc/init.d/openwalla-network-monitor|0755|openwalla-network-monitor
files/openwalla-dns-monitor.sh|/usr/bin/openwalla-dns-monitor|0755|openwalla-dns-monitor
files/openwalla-dns-monitor.init|/etc/init.d/openwalla-dns-monitor|0755|openwalla-dns-monitor
files/openwalla-speedtest-monitor.sh|/usr/bin/openwalla-speedtest-monitor|0755|
files/openwalla-notifications-db.sh|/usr/bin/openwalla-notifications-db|0755|
files/openwalla-devices-collector.sh|/usr/bin/openwalla-devices-collector|0755|openwalla-devices-collector
files/openwalla-devices-collector.init|/etc/init.d/openwalla-devices-collector|0755|openwalla-devices-collector
files/openwalla-device-bandwidth-collector.sh|/usr/bin/openwalla-device-bandwidth-collector|0755|openwalla-device-bandwidth-collector
files/openwalla-device-bandwidth-collector.init|/etc/init.d/openwalla-device-bandwidth-collector|0755|openwalla-device-bandwidth-collector
files/openwalla-device-traffic-summary.sh|/usr/bin/openwalla-device-traffic-summary|0755|
files/openwalla-paternal-pause.sh|/usr/bin/openwalla-paternal-pause|0755|
files/openwalla-scheduler.sh|/usr/bin/openwalla-scheduler|0755|
files/openwalla-parental.sh|/usr/bin/openwalla-parental|0755|
files/openwalla-device-quarantine.sh|/usr/bin/openwalla-device-quarantine|0755|openwalla-device-quarantine
files/openwalla-device-quarantine.init|/etc/init.d/openwalla-device-quarantine|0755|openwalla-device-quarantine
files/openwalla-state-sync.sh|/usr/bin/openwalla-state-sync|0755|openwalla-state-sync
files/openwalla-state-sync.init|/etc/init.d/openwalla-state-sync|0755|openwalla-state-sync
files/openwalla-connection-flow-collector.sh|/usr/bin/openwalla-connection-flow-collector|0755|openwalla-connection-flows-collector
files/openwalla-connection-flows-collector.init|/etc/init.d/openwalla-connection-flows-collector|0755|openwalla-connection-flows-collector
files/openwalla-netify-collector.sh|/usr/bin/openwalla-netify-collector|0755|openwalla-netify-collector
files/openwalla-netify-collector.init|/etc/init.d/openwalla-netify-collector|0755|openwalla-netify-collector
files/openwalla-tailscale.sh|/usr/bin/openwalla-tailscale|0755|
files/openwalla-tor.sh|/usr/bin/openwalla-tor|0755|
rpcd-acl.json|/usr/share/rpcd/acl.d/openwalla.json|0644|rpcd
EOF

if [ "$ACTION" = "update" ] && [ "$FAILED" -eq 0 ]; then
	for service in $TOUCHED_SERVICES; do
		[ -x "/etc/init.d/$service" ] || continue
		/etc/init.d/"$service" restart >/dev/null 2>&1 || true
	done
	uci -q get openwalla.core >/dev/null 2>&1 || uci set openwalla.core='core'
	uci set openwalla.core.component_version="$COMPONENT_VERSION"
	uci commit openwalla
fi

echo "SUMMARY|managed=$MANAGED|current=$CURRENT|updated=$UPDATED|failed=$FAILED"
[ "$FAILED" -eq 0 ]
