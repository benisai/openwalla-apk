#!/bin/sh

# Openwalla Device Quarantine service
# Detects newly seen DHCP lease MACs and creates firewall reject rules.

set -u

PATH="/usr/sbin:/usr/bin:/sbin:/bin"

DEFAULT_INTERVAL=15
DEFAULT_LEASES_FILE="/tmp/dhcp.leases"
DEFAULT_STATE_FILE="/tmp/openwalla-quarantine-known.txt"
DEFAULT_RULE_PREFIX="openwalla_quarantine_"
DEFAULT_LAN_NETWORK="lan"
DEFAULT_LAN_DEVICE="br-lan"
DEFAULT_NOTIFICATIONS_DB="/tmp/openwalla-notifications.sqlite"
DEFAULT_DEVICES_DB="/tmp/openwalla-devices.sqlite"
LOG_FILE="/tmp/openwalla-device-quarantine.log"

log() {
	local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $*"
	echo "$msg" >>"$LOG_FILE" 2>/dev/null || true
	logger -t openwalla-device-quarantine "$*" 2>/dev/null || true
}

uci_get() {
	uci -q get "$1" 2>/dev/null || true
}

is_enabled_flag() {
	case "$1" in
	1|on|true|yes|enabled) return 0 ;;
	*) return 1 ;;
	esac
}

sanitize_name() {
	echo "$1" | tr '[:upper:]' '[:lower:]' | tr ' ' '_' | sed 's/[^a-z0-9_.-]//g' | cut -c1-24
}

load_config() {
	local v
	v="$(uci_get openwalla.quarantine.enabled)"
	if [ -z "$v" ]; then v="0"; fi
	QUARANTINE_ENABLED="$v"

	v="$(uci_get openwalla.quarantine.interval)"
	case "$v" in ''|*[!0-9]*) v="$DEFAULT_INTERVAL" ;; esac
	if [ "$v" -lt 10 ]; then v=10; fi
	if [ "$v" -gt 3600 ]; then v=3600; fi
	INTERVAL="$v"

	v="$(uci_get openwalla.quarantine.leases_file)"
	if [ -z "$v" ]; then v="$DEFAULT_LEASES_FILE"; fi
	LEASES_FILE="$v"

	v="$(uci_get openwalla.quarantine.state_file)"
	if [ -z "$v" ]; then v="$DEFAULT_STATE_FILE"; fi
	STATE_FILE="$v"

	v="$(uci_get openwalla.quarantine.rule_prefix)"
	if [ -z "$v" ]; then v="$DEFAULT_RULE_PREFIX"; fi
	RULE_PREFIX="$v"

	v="$(uci_get openwalla.quarantine.lan_network)"
	if [ -z "$v" ]; then v="$DEFAULT_LAN_NETWORK"; fi
	LAN_NETWORK="$v"

	v="$(uci_get openwalla.quarantine.lan_device)"
	if [ -z "$v" ]; then v="$(uci_get network.lan.device)"; fi
	if [ -z "$v" ]; then v="$(uci_get network.lan.ifname)"; fi
	if [ -z "$v" ]; then v="$DEFAULT_LAN_DEVICE"; fi
	LAN_DEVICE="$v"

	v="$(uci_get openwalla.notifications.db_path)"
	if [ -z "$v" ]; then v="$DEFAULT_NOTIFICATIONS_DB"; fi
	NOTIFICATIONS_DB="$v"

	v="$(uci_get openwalla.devices.db_path)"
	if [ -z "$v" ]; then v="$DEFAULT_DEVICES_DB"; fi
	DEVICES_DB="$v"
}

service_enabled() {
	is_enabled_flag "$QUARANTINE_ENABLED"
}

collect_leases() {
	if [ ! -f "$LEASES_FILE" ]; then
		return 0
	fi
	awk '{ if ($2 ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) print tolower($2) "|" $3 "|" $4 }' "$LEASES_FILE"
}

collect_arp() {
	# Collect only ARP entries on LAN device (for example br-lan).
	if [ -r /proc/net/arp ]; then
		awk -v dev="$LAN_DEVICE" 'NR>1 {
			ip=$1
			mac=tolower($4)
			ifname=$6
			if (ifname == dev && mac ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/ && mac != "00:00:00:00:00:00") {
				print mac "|" ip "|"
			}
		}' /proc/net/arp
		return 0
	fi

	# Fallback for systems where /proc/net/arp is unavailable/restricted.
	arp -n 2>/dev/null | awk -v dev="$LAN_DEVICE" 'NR>1 {
		ip=$1
		mac=tolower($3)
		ifname=$NF
		if (ifname == dev && mac ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/ && mac != "00:00:00:00:00:00") {
			print mac "|" ip "|"
		}
	}'
}

collect_ip_neigh() {
	# Collect only neighbors on the LAN device (for example br-lan), never apcli/wan side.
	ip neigh show dev "$LAN_DEVICE" 2>/dev/null | awk '{
		ip=$1
		mac=""
		for (i=1; i<=NF; i++) {
			if ($i == "lladdr" && (i+1) <= NF) { mac=$(i+1); break }
		}
		if (mac ~ /^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$/) {
			print tolower(mac) "|" ip "|"
		}
	}'
}

collect_wireless_clients() {
	# Prefer jsonfilter if available. Filter to interfaces attached to LAN network only.
	# Output format: mac|ip|host (ip/host may be empty here).
	command -v jsonfilter >/dev/null 2>&1 || return 0
	command -v ubus >/dev/null 2>&1 || return 0

	local json out
	json="$(ubus call network.wireless status 2>/dev/null || true)"
	[ -n "$json" ] || return 0

	out="$(
		{
			jsonfilter -s "$json" -e "@.*.interfaces[@.config.network='$LAN_NETWORK'].stations[*].mac" 2>/dev/null || true
			jsonfilter -s "$json" -e "@.*.interfaces[@.config.network[0]='$LAN_NETWORK'].stations[*].mac" 2>/dev/null || true
		} | tr ' ' '\n' | sed '/^$/d' | tr '[:upper:]' '[:lower:]' | sort -u
	)"

	[ -n "$out" ] || return 0
	echo "$out" | awk '{ print $1 "||" }'
}

collect_candidates() {
	{
		collect_leases
		collect_arp
		collect_ip_neigh
		collect_wireless_clients
	} | awk -F'|' '
		{
			mac=tolower($1)
			ip=$2
			host=$3
			if (mac ~ /^([0-9a-f]{2}:){5}[0-9a-f]{2}$/) {
				if (!(mac in seen)) {
					seen[mac]=1
					print mac "|" ip "|" host
				}
			}
		}
	'
}

rule_name_for() {
	local mac="$1"
	local host="$2"
	local safe
	safe="$(sanitize_name "$host")"
	if [ -z "$safe" ] || [ "$safe" = "*" ]; then
		safe="$(echo "$mac" | tr -d ':')"
	fi
	echo "${RULE_PREFIX}${safe}"
}

rule_exists_by_name() {
	local name="$1"
	uci -q show firewall | grep -q "name='$name'"
}

sql_escape() {
	printf "%s" "$1" | sed "s/'/''/g"
}

find_sqlite_bin() {
	if command -v sqlite3 >/dev/null 2>&1; then
		printf "%s" "$(command -v sqlite3)"
		return 0
	fi
	if command -v sqlite3-cli >/dev/null 2>&1; then
		printf "%s" "$(command -v sqlite3-cli)"
		return 0
	fi
	return 1
}

notification_db_ready() {
	local sqlite_bin="$1"

	[ -n "$sqlite_bin" ] || return 1
	mkdir -p "$(dirname "$NOTIFICATIONS_DB")" 2>/dev/null || true
	"$sqlite_bin" "$NOTIFICATIONS_DB" <<'SQL' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS notifications (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	timestamp INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
	app TEXT NOT NULL DEFAULT '',
	msg TEXT NOT NULL DEFAULT '',
	archived INTEGER NOT NULL DEFAULT 0,
	"delete" INTEGER NOT NULL DEFAULT 0
);
CREATE INDEX IF NOT EXISTS idx_notifications_timestamp ON notifications(timestamp);
CREATE INDEX IF NOT EXISTS idx_notifications_archived ON notifications(archived);
SQL
}

write_notification() {
	local message="$1"
	local sqlite_bin esc_msg
	sqlite_bin="$(find_sqlite_bin 2>/dev/null || true)"
	if [ -z "$sqlite_bin" ]; then
		log "notification skipped: sqlite3/sqlite3-cli not found"
		return 0
	fi
	if ! notification_db_ready "$sqlite_bin"; then
		log "notification skipped: unable to initialize $NOTIFICATIONS_DB"
		return 0
	fi

	esc_msg="$(sql_escape "$message")"
	if "$sqlite_bin" "$NOTIFICATIONS_DB" "INSERT INTO notifications (app, msg, archived, \"delete\") VALUES ('device-quarantine', '$esc_msg', 0, 0);" >/dev/null 2>&1; then
		log "notification written: $message"
	else
		log "notification failed: unable to insert into $NOTIFICATIONS_DB"
	fi
}

write_device_state() {
	local mac="$1"
	local ip="$2"
	local host="$3"
	local sqlite_bin esc_mac esc_ip esc_host
	sqlite_bin="$(find_sqlite_bin 2>/dev/null || true)"
	[ -n "$sqlite_bin" ] || return 0
	esc_mac="$(sql_escape "$mac")"
	esc_ip="$(sql_escape "$ip")"
	esc_host="$(sql_escape "$host")"
	mkdir -p "$(dirname "$DEVICES_DB")" 2>/dev/null || true
	"$sqlite_bin" "$DEVICES_DB" "CREATE TABLE IF NOT EXISTS devices (mac TEXT PRIMARY KEY, ip TEXT NOT NULL DEFAULT '', hostname TEXT NOT NULL DEFAULT '', vendor TEXT NOT NULL DEFAULT '', quarantined INTEGER NOT NULL DEFAULT 0, last_seen INTEGER NOT NULL DEFAULT 0, total_up INTEGER NOT NULL DEFAULT 0, total_down INTEGER NOT NULL DEFAULT 0, status TEXT NOT NULL DEFAULT 'offline', static_ip TEXT NOT NULL DEFAULT '', icon TEXT NOT NULL DEFAULT '', scheduled_block INTEGER NOT NULL DEFAULT 0, schedule_until TEXT NOT NULL DEFAULT '', hidden INTEGER NOT NULL DEFAULT 0); INSERT INTO devices (mac, ip, hostname, quarantined, last_seen, status) VALUES ('$esc_mac', '$esc_ip', '$esc_host', 1, CAST(strftime('%s','now') AS INTEGER), 'blocked') ON CONFLICT(mac) DO UPDATE SET ip=CASE WHEN excluded.ip != '' THEN excluded.ip ELSE devices.ip END, hostname=CASE WHEN devices.hostname = '' AND excluded.hostname != '' AND excluded.hostname != '*' THEN excluded.hostname ELSE devices.hostname END, quarantined=1, last_seen=excluded.last_seen, status='blocked';" >/dev/null 2>&1 || log "device state update failed for mac=$mac"
}

add_fw_rule() {
	local name="$1"
	local mac="$2"
	local dest="$3"
	local sid
	sid="$(uci add firewall rule 2>/dev/null || true)"
	[ -n "$sid" ] || return 1
	uci set firewall."$sid".name="$name"
	uci set firewall."$sid".src="lan"
	uci set firewall."$sid".dest="$dest"
	uci set firewall."$sid".src_mac="$mac"
	uci set firewall."$sid".proto="all"
	uci set firewall."$sid".target="REJECT"
	uci set firewall."$sid".family="any"
	uci set firewall."$sid".enabled="1"
	return 0
}

quarantine_new_device() {
	local mac="$1"
	local ip="$2"
	local host="$3"
	local base lan wan
	base="$(rule_name_for "$mac" "$host")"
	lan="${base}_lan"
	wan="${base}_wan"

	if ! rule_exists_by_name "$lan"; then
		add_fw_rule "$lan" "$mac" "lan" || true
	fi
	if ! rule_exists_by_name "$wan"; then
		add_fw_rule "$wan" "$mac" "wan" || true
	fi

	log "quarantined new device mac=$mac ip=$ip host=$host rules=[$lan,$wan]"
	write_device_state "$mac" "$ip" "$host"
	write_notification "New device quarantined mac=$mac ip=${ip:-unknown} host=${host:-unknown}"
}

ensure_state_file() {
	local dir
	dir="$(dirname "$STATE_FILE")"
	mkdir -p "$dir" 2>/dev/null || true
	[ -f "$STATE_FILE" ] || : >"$STATE_FILE"
}

discover_once() {
	local changed tmp lease mac ip host
	load_config
	if ! service_enabled; then
		log "quarantine disabled (enabled=$QUARANTINE_ENABLED); skipping scan"
		return 0
	fi

	ensure_state_file

	# First run: seed known list, do not quarantine current devices.
	if [ ! -s "$STATE_FILE" ]; then
		collect_candidates | cut -d'|' -f1 | sort -u >"$STATE_FILE"
		log "initialized known devices state at $STATE_FILE"
		return 0
	fi

	changed=0
	tmp="/tmp/openwalla-quarantine-seen.$$"
	collect_candidates >"$tmp"
	while IFS='|' read -r mac ip host; do
		[ -n "$mac" ] || continue
		if grep -qx "$mac" "$STATE_FILE" 2>/dev/null; then
			continue
		fi
		quarantine_new_device "$mac" "$ip" "$host"
		echo "$mac" >>"$STATE_FILE"
		changed=1
	done <"$tmp"
	rm -f "$tmp"

	if [ "$changed" = "1" ]; then
		uci commit firewall
		/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1 || true
	fi
}

run_daemon() {
	log "starting quarantine daemon"
	while true; do
		load_config
		discover_once
		sleep "$INTERVAL"
	done
}

case "${1:-}" in
--once)
	discover_once
	;;
--daemon|"")
	run_daemon
	;;
*)
	echo "Usage: $0 [--once|--daemon]"
	exit 1
	;;
esac

exit 0
