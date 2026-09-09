#!/bin/sh

# Shared helpers for Openwalla standalone OpenWrt installers.
# Provides repo/file path resolution, package install helpers, UCI setup,
# file installation, service enable/start helpers, and rpcd ACL installation.

set -u

if [ "$(id -u)" != "0" ]; then
	echo "Run as root."
	exit 1
fi

SCRIPT_PATH="$0"
SCRIPT_DIR="$(cd "$(dirname "$SCRIPT_PATH")" 2>/dev/null && pwd)"
OPENWALLA_SETUP_DIR="$(cd "$SCRIPT_DIR/.." 2>/dev/null && pwd)"
case "$(basename "$SCRIPT_DIR")" in
lib)
	OPENWALLA_SETUP_DIR="$(cd "$SCRIPT_DIR/../.." 2>/dev/null && pwd)"
	;;
esac
FILES_DIR="$OPENWALLA_SETUP_DIR/files"
RPCD_ACL="$OPENWALLA_SETUP_DIR/rpcd-acl.json"
OPENWALLA_RAW_BASE="${OPENWALLA_RAW_BASE:-https://raw.githubusercontent.com/benisai/openwalla-apk/main/openwrt-setup}"
PKG_MGR=""

log() {
	echo "[openwalla-standalone] $*"
}

have_cmd() {
	command -v "$1" >/dev/null 2>&1
}

download_file() {
	url="$1"
	dst="$2"
	mkdir -p "$(dirname "$dst")"
	if have_cmd wget; then
		wget -qO "$dst" "$url" && return 0
	fi
	if have_cmd curl; then
		curl -fsSL "$url" -o "$dst" && return 0
	fi
	return 1
}

fetch_missing_file() {
	path="$1"
	case "$path" in
	"$FILES_DIR"/*)
		name="${path#$FILES_DIR/}"
		download_file "$OPENWALLA_RAW_BASE/files/$name" "$path"
		;;
	"$RPCD_ACL")
		download_file "$OPENWALLA_RAW_BASE/rpcd-acl.json" "$path"
		;;
	*)
		return 1
		;;
	esac
}

require_file() {
	if [ ! -f "$1" ]; then
		log "Fetching missing file: $1"
		if ! fetch_missing_file "$1"; then
			echo "Missing required file: $1"
			exit 1
		fi
	fi
}

install_file() {
	src="$1"
	dst="$2"
	mode="$3"
	require_file "$src"
	mkdir -p "$(dirname "$dst")"
	cp "$src" "$dst"
	chmod "$mode" "$dst"
	log "Installed $dst"
}

detect_pkg_mgr() {
	if have_cmd opkg; then
		PKG_MGR="opkg"
	elif have_cmd apk; then
		PKG_MGR="apk"
	else
		PKG_MGR=""
	fi
}

update_package_feeds() {
	detect_pkg_mgr
	if [ "${OPENWALLA_PACKAGE_FEEDS_UPDATED:-0}" = "1" ]; then
		log "Package feeds already updated; skipping package feed refresh."
		return 0
	fi
	case "$PKG_MGR" in
	opkg) opkg update ;;
	apk) apk update ;;
	*) log "No supported package manager found (opkg/apk). Package install steps will be skipped." ;;
	esac
	export OPENWALLA_PACKAGE_FEEDS_UPDATED=1
}

install_pkg_if_available() {
	pkg="$1"
	case "$PKG_MGR" in
	opkg)
		if opkg list-installed | grep -q "^$pkg -"; then
			log "Package already installed: $pkg"
			return 0
		fi
		if ! opkg list | grep -q "^$pkg -"; then
			log "Package unavailable in current feed, skipping: $pkg"
			return 1
		fi
		opkg install "$pkg" && log "Installed package: $pkg" && return 0
		log "Failed to install package: $pkg"
		return 1
		;;
	apk)
		if apk info -e "$pkg" >/dev/null 2>&1; then
			log "Package already installed: $pkg"
			return 0
		fi
		if ! apk search -x "$pkg" >/dev/null 2>&1; then
			log "Package unavailable in current feed, skipping: $pkg"
			return 1
		fi
		apk add "$pkg" && log "Installed package: $pkg" && return 0
		log "Failed to install package: $pkg"
		return 1
		;;
	*)
		log "No supported package manager available; skipping package: $pkg"
		return 1
		;;
	esac
}

install_first_available_pkg() {
	label="$1"
	shift
	for candidate in "$@"; do
		[ -n "$candidate" ] || continue
		if install_pkg_if_available "$candidate"; then
			log "Using package for $label: $candidate"
			return 0
		fi
	done
	log "No installable package found for $label"
	return 1
}

set_uci() {
	key="$1"
	value="$2"
	value="${value#\'}"
	value="${value%\'}"
	value="${value#\"}"
	value="${value%\"}"
	uci set "$key=$value"
}

ensure_openwalla_config() {
	if [ ! -f /etc/config/openwalla ]; then
		install_file "$FILES_DIR/openwalla.config" /etc/config/openwalla 0644
	fi
}

ensure_uci_section() {
	section="$1"
	type="$2"
	uci -q get "openwalla.$section" >/dev/null 2>&1 || uci set "openwalla.$section=$type"
}

install_rpcd_acl() {
	install_file "$RPCD_ACL" /usr/share/rpcd/acl.d/openwalla.json 0644
	/etc/init.d/rpcd restart || true
}

enable_restart_service() {
	svc="$1"
	if [ -x "/etc/init.d/$svc" ]; then
		/etc/init.d/"$svc" enable || true
		/etc/init.d/"$svc" restart || true
		log "Service restarted: $svc"
	else
		log "Service not found, skipping: $svc"
	fi
}

reload_cron() {
	/bin/sh -c '/etc/init.d/cron reload 2>/dev/null || /etc/init.d/cron restart 2>/dev/null || /etc/init.d/crond reload 2>/dev/null || /etc/init.d/crond restart 2>/dev/null || killall -HUP crond 2>/dev/null || true'
}
