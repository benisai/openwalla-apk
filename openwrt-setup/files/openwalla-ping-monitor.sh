#!/bin/sh

# Openwalla Ping Monitor
# Runs continuously on OpenWrt and writes ping samples to /tmp/openwalla-ping-monitor.txt

set -u

DEFAULT_TARGET="1.1.1.1"
DEFAULT_INTERVAL="60"
DEFAULT_TIMEOUT="2"
DEFAULT_OUTPUT="/tmp/openwalla-ping-monitor.txt"
DEFAULT_MAX_LINES="2000"
DEFAULT_THRESHOLD="100"
DEFAULT_NOTIFICATIONS_DB="/tmp/openwalla-notifications.sqlite"
DEFAULT_STATE_FILE="/tmp/openwalla-ping-monitor.state"
DEFAULT_OUTAGE_FAILURES="2"
DEFAULT_RESTORE_SUCCESSES="2"
DEFAULT_ALERT_COOLDOWN="1800"

PING_TARGET="$DEFAULT_TARGET"
PING_INTERVAL="$DEFAULT_INTERVAL"
PING_TIMEOUT="$DEFAULT_TIMEOUT"
PING_OUTPUT="$DEFAULT_OUTPUT"
PING_MAX_LINES="$DEFAULT_MAX_LINES"
PING_THRESHOLD="$DEFAULT_THRESHOLD"
NOTIFICATIONS_DB="$DEFAULT_NOTIFICATIONS_DB"
STATE_FILE="$DEFAULT_STATE_FILE"
OUTAGE_FAILURES="$DEFAULT_OUTAGE_FAILURES"
RESTORE_SUCCESSES="$DEFAULT_RESTORE_SUCCESSES"
ALERT_COOLDOWN="$DEFAULT_ALERT_COOLDOWN"
SQLITE_BIN=""

log() {
	logger -t openwalla-ping-monitor "$*"
}

load_config() {
	if command -v uci >/dev/null 2>&1; then
		local value
		value="$(uci -q get openwalla.ping_monitor.target 2>/dev/null || true)"
		[ -n "$value" ] && PING_TARGET="$value"

		value="$(uci -q get openwalla.ping_monitor.interval 2>/dev/null || true)"
		[ -n "$value" ] && PING_INTERVAL="$value"

		value="$(uci -q get openwalla.ping_monitor.timeout 2>/dev/null || true)"
		[ -n "$value" ] && PING_TIMEOUT="$value"

		value="$(uci -q get openwalla.ping_monitor.output_file 2>/dev/null || true)"
		[ -n "$value" ] && PING_OUTPUT="$value"

		value="$(uci -q get openwalla.ping_monitor.max_lines 2>/dev/null || true)"
		[ -n "$value" ] && PING_MAX_LINES="$value"

		value="$(uci -q get openwalla.ping_monitor.threshold 2>/dev/null || true)"
		[ -n "$value" ] && PING_THRESHOLD="$value"

		value="$(uci -q get openwalla.ping_monitor.state_file 2>/dev/null || true)"
		[ -n "$value" ] && STATE_FILE="$value"

		value="$(uci -q get openwalla.ping_monitor.outage_failures 2>/dev/null || true)"
		[ -n "$value" ] && OUTAGE_FAILURES="$value"

		value="$(uci -q get openwalla.ping_monitor.restore_successes 2>/dev/null || true)"
		[ -n "$value" ] && RESTORE_SUCCESSES="$value"

		value="$(uci -q get openwalla.ping_monitor.alert_cooldown 2>/dev/null || true)"
		[ -n "$value" ] && ALERT_COOLDOWN="$value"

		value="$(uci -q get openwalla.notifications.db_path 2>/dev/null || true)"
		[ -n "$value" ] && NOTIFICATIONS_DB="$value"
	fi
}

refresh_runtime_config() {
	load_config
	PING_INTERVAL="$(sanitize_int "$PING_INTERVAL" "$DEFAULT_INTERVAL")"
	PING_TIMEOUT="$(sanitize_int "$PING_TIMEOUT" "$DEFAULT_TIMEOUT")"
	PING_MAX_LINES="$(sanitize_int "$PING_MAX_LINES" "$DEFAULT_MAX_LINES")"
	PING_THRESHOLD="$(sanitize_int "$PING_THRESHOLD" "$DEFAULT_THRESHOLD")"
	OUTAGE_FAILURES="$(sanitize_int "$OUTAGE_FAILURES" "$DEFAULT_OUTAGE_FAILURES")"
	RESTORE_SUCCESSES="$(sanitize_int "$RESTORE_SUCCESSES" "$DEFAULT_RESTORE_SUCCESSES")"
	ALERT_COOLDOWN="$(sanitize_int "$ALERT_COOLDOWN" "$DEFAULT_ALERT_COOLDOWN")"
	ensure_output_file
	detect_sqlite
}

detect_sqlite() {
	if command -v sqlite3 >/dev/null 2>&1; then
		SQLITE_BIN="$(command -v sqlite3)"
	elif command -v sqlite3-cli >/dev/null 2>&1; then
		SQLITE_BIN="$(command -v sqlite3-cli)"
	else
		SQLITE_BIN=""
	fi
}

notification_db_ready() {
	[ -n "$SQLITE_BIN" ] || return 1
	mkdir -p "$(dirname "$NOTIFICATIONS_DB")"
	"$SQLITE_BIN" "$NOTIFICATIONS_DB" <<'SQL' >/dev/null 2>&1
CREATE TABLE IF NOT EXISTS notifications (
	id INTEGER PRIMARY KEY AUTOINCREMENT,
	timestamp INTEGER NOT NULL DEFAULT (CAST(strftime('%s','now') AS INTEGER)),
	app TEXT NOT NULL DEFAULT '',
	msg TEXT NOT NULL DEFAULT '',
	archived INTEGER NOT NULL DEFAULT 0,
	"delete" INTEGER NOT NULL DEFAULT 0,
	category TEXT NOT NULL DEFAULT '',
	severity TEXT NOT NULL DEFAULT '',
	title TEXT NOT NULL DEFAULT '',
	details TEXT NOT NULL DEFAULT '',
	metadata TEXT NOT NULL DEFAULT ''
);
SQL
	local column name
	for column in \
		"category TEXT NOT NULL DEFAULT ''" \
		"severity TEXT NOT NULL DEFAULT ''" \
		"title TEXT NOT NULL DEFAULT ''" \
		"details TEXT NOT NULL DEFAULT ''" \
		"metadata TEXT NOT NULL DEFAULT ''"; do
		name="${column%% *}"
		"$SQLITE_BIN" "$NOTIFICATIONS_DB" "SELECT $name FROM notifications LIMIT 0;" >/dev/null 2>&1 || \
			"$SQLITE_BIN" "$NOTIFICATIONS_DB" "ALTER TABLE notifications ADD COLUMN $column;" >/dev/null 2>&1 || true
	done
}

write_notification() {
	local severity="$1"
	local title="$2"
	local details="$3"
	local metadata="${4:-}"
	notification_db_ready || return 0

	local esc_title esc_details esc_metadata
	esc_title="$(printf "%s" "$title" | sed "s/'/''/g")"
	esc_details="$(printf "%s" "$details" | sed "s/'/''/g")"
	esc_metadata="$(printf "%s" "$metadata" | sed "s/'/''/g")"

	"$SQLITE_BIN" "$NOTIFICATIONS_DB" \
		"INSERT INTO notifications (app, msg, archived, \"delete\", category, severity, title, details, metadata) VALUES ('ping-monitor', '$esc_details', 0, 0, 'network_health', '$severity', '$esc_title', '$esc_details', '$esc_metadata');" >/dev/null 2>&1 || true
}

load_state() {
	NETWORK_STATE="unknown"
	DOWN_SINCE="0"
	FAILURE_COUNT="0"
	SUCCESS_COUNT="0"
	LAST_LATENCY_ALERT="0"
	[ -f "$STATE_FILE" ] && . "$STATE_FILE"
}

save_state() {
	mkdir -p "$(dirname "$STATE_FILE")"
	cat >"$STATE_FILE" <<EOF
NETWORK_STATE='$NETWORK_STATE'
DOWN_SINCE='$DOWN_SINCE'
FAILURE_COUNT='$FAILURE_COUNT'
SUCCESS_COUNT='$SUCCESS_COUNT'
LAST_LATENCY_ALERT='$LAST_LATENCY_ALERT'
EOF
}

format_duration() {
	local seconds="$1" minutes
	seconds="$(sanitize_int "$seconds" "0")"
	if [ "$seconds" -lt 60 ]; then
		echo "${seconds}s"
		return
	fi
	minutes=$((seconds / 60))
	if [ "$minutes" -lt 60 ]; then
		echo "${minutes}m"
	else
		echo "$((minutes / 60))h $((minutes % 60))m"
	fi
}

sanitize_int() {
	case "${1:-}" in
		'' | *[!0-9]*)
			echo "$2"
			;;
		*)
			echo "$1"
			;;
	esac
}

ensure_output_file() {
	local dir
	dir="$(dirname "$PING_OUTPUT")"
	mkdir -p "$dir"
	[ -f "$PING_OUTPUT" ] || : >"$PING_OUTPUT"
}

extract_latency() {
	local input="$1"
	echo "$input" | sed -n 's/.*time[=<]\([0-9.][0-9.]*\).*/\1/p' | head -n 1
}

append_sample() {
	local ts="$1"
	local target="$2"
	local status="$3"
	local latency="$4"
	local msg="$5"

	printf "%s|%s|%s|%s|%s\n" "$ts" "$target" "$status" "$latency" "$msg" >>"$PING_OUTPUT"
}

prune_file() {
	local max_lines
	max_lines="$(sanitize_int "$PING_MAX_LINES" "$DEFAULT_MAX_LINES")"
	local current
	current="$(wc -l <"$PING_OUTPUT" 2>/dev/null || echo 0)"
	current="$(sanitize_int "$current" "0")"

	if [ "$current" -gt "$max_lines" ]; then
		tail -n "$max_lines" "$PING_OUTPUT" >"${PING_OUTPUT}.tmp" && mv "${PING_OUTPUT}.tmp" "$PING_OUTPUT"
	fi
}

run_ping_once() {
	local now now_epoch output latency status message latency_int outage_duration
	now="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"
	now_epoch="$(date +%s)"
	load_state

	output="$(ping -c 1 -W "$PING_TIMEOUT" "$PING_TARGET" 2>&1 || true)"
	latency="$(extract_latency "$output")"

	if [ -n "$latency" ]; then
		status="OK"
		message="reply"
	else
		status="ERROR"
		latency="N/A"
		message="$(echo "$output" | tail -n 1 | tr '|' ' ' | tr -s ' ')"
		[ -z "$message" ] && message="timeout"
	fi

	append_sample "$now" "$PING_TARGET" "$status" "$latency" "$message"

	if [ "$status" = "OK" ]; then
		FAILURE_COUNT="0"
		SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
		if [ "$NETWORK_STATE" = "down" ] && [ "$SUCCESS_COUNT" -ge "$RESTORE_SUCCESSES" ]; then
			outage_duration=$((now_epoch - DOWN_SINCE))
			write_notification "resolved" "Internet connection restored" \
				"Connectivity to $PING_TARGET was restored after $(format_duration "$outage_duration"). Current latency is ${latency} ms." \
				"target=$PING_TARGET;latency_ms=$latency;duration_seconds=$outage_duration"
			NETWORK_STATE="up"
			DOWN_SINCE="0"
		elif [ "$NETWORK_STATE" = "unknown" ]; then
			NETWORK_STATE="up"
		fi
		latency_int="$(printf '%s' "$latency" | cut -d '.' -f1)"
		latency_int="$(sanitize_int "$latency_int" "0")"
		if [ "$latency_int" -ge "$PING_THRESHOLD" ] && \
			[ $((now_epoch - LAST_LATENCY_ALERT)) -ge "$ALERT_COOLDOWN" ]; then
			write_notification "warning" "High latency detected" \
				"Latency to $PING_TARGET reached ${latency} ms. The configured threshold is ${PING_THRESHOLD} ms." \
				"target=$PING_TARGET;latency_ms=$latency;threshold_ms=$PING_THRESHOLD"
			LAST_LATENCY_ALERT="$now_epoch"
		fi
	else
		SUCCESS_COUNT="0"
		FAILURE_COUNT=$((FAILURE_COUNT + 1))
		if [ "$NETWORK_STATE" != "down" ] && [ "$FAILURE_COUNT" -ge "$OUTAGE_FAILURES" ]; then
			DOWN_SINCE=$((now_epoch - ((FAILURE_COUNT - 1) * PING_INTERVAL)))
			NETWORK_STATE="down"
			write_notification "critical" "Internet connection lost" \
				"Openwalla could not reach $PING_TARGET after $FAILURE_COUNT consecutive checks. Last result: ${message:-timeout}." \
				"target=$PING_TARGET;reason=${message:-timeout};failures=$FAILURE_COUNT"
		fi
	fi

	save_state
	prune_file
}

run_forever() {
	refresh_runtime_config
	log "starting target=$PING_TARGET interval=${PING_INTERVAL}s output=$PING_OUTPUT"
	while true; do
		refresh_runtime_config
		run_ping_once
		sleep "$PING_INTERVAL"
	done
}

main() {
	refresh_runtime_config

	case "${1:-}" in
		--once)
			run_ping_once
			;;
		*)
			run_forever
			;;
	esac
}

main "$@"
