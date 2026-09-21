#!/bin/sh

set -u

TORRC="/etc/tor/torrc"
BEGIN_MARKER="# BEGIN OPENWALLA TOR"
END_MARKER="# END OPENWALLA TOR"

cleanup_firewall() {
	for section in openwalla_tor_tcp openwalla_tor_dns; do
		uci -q delete "firewall.$section" >/dev/null 2>&1 || true
	done
}

configure_tor() {
	mkdir -p "$(dirname "$TORRC")"
	[ -f "$TORRC" ] || : >"$TORRC"
	tmp="/tmp/openwalla-torrc.$$"
	awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
		$0 == begin { skip = 1; next }
		$0 == end { skip = 0; next }
		!skip { print }
	' "$TORRC" >"$tmp"
	cat >>"$tmp" <<EOF
$BEGIN_MARKER
AutomapHostsOnResolve 1
AutomapHostsSuffixes .
VirtualAddrNetworkIPv4 172.16.0.0/12
TransPort 0.0.0.0:9040
DNSPort 0.0.0.0:9053
$END_MARKER
EOF
	cp "$tmp" "$TORRC"
	rm -f "$tmp"
}

unconfigure_tor() {
	[ -f "$TORRC" ] || return 0
	tmp="/tmp/openwalla-torrc.$$"
	awk -v begin="$BEGIN_MARKER" -v end="$END_MARKER" '
		$0 == begin { skip = 1; next }
		$0 == end { skip = 0; next }
		!skip { print }
	' "$TORRC" >"$tmp"
	cp "$tmp" "$TORRC"
	rm -f "$tmp"
}

add_scope() {
	section="$1"
	mode="$(uci -q get openwalla.tor.mode || echo none)"
	[ "$mode" = "devices" ] || return 0
	uci -q delete "firewall.$section.src_mac" >/dev/null 2>&1 || true
	found=0
	for mac in $(uci -q get openwalla.tor.device_mac 2>/dev/null || true); do
		[ -n "$mac" ] || continue
		uci add_list "firewall.$section.src_mac=$mac"
		found=1
	done
	[ "$found" = "1" ]
}

add_redirect() {
	section="$1"
	name="$2"
	proto="$3"
	destination="$4"
	source_port="${5:-}"
	uci set "firewall.$section=redirect"
	uci set "firewall.$section.name=$name"
	uci set "firewall.$section.src=lan"
	uci set "firewall.$section.target=DNAT"
	uci set "firewall.$section.proto=$proto"
	uci set "firewall.$section.dest_port=$destination"
	[ -z "$source_port" ] || uci set "firewall.$section.src_dport=$source_port"
	add_scope "$section"
}

apply_rules() {
	mode="$(uci -q get openwalla.tor.mode || echo none)"
	dns="$(uci -q get openwalla.tor.dns_via_tor || echo 0)"
	cleanup_firewall
	case "$mode" in
	none) ;;
	lan)
		add_redirect openwalla_tor_tcp "Openwalla Tor TCP" tcp 9040
		[ "$dns" = "1" ] && add_redirect openwalla_tor_dns "Openwalla Tor DNS" "tcp udp" 9053 53
		;;
	devices)
		if uci -q get openwalla.tor.device_mac >/dev/null 2>&1; then
			add_redirect openwalla_tor_tcp "Openwalla Tor TCP" tcp 9040
			[ "$dns" = "1" ] && add_redirect openwalla_tor_dns "Openwalla Tor DNS" "tcp udp" 9053 53
		else
			uci set openwalla.tor.mode="none"
		fi
		;;
	*)
		echo "Invalid Tor routing mode: $mode" >&2
		return 1
		;;
	esac
	uci commit openwalla
	uci commit firewall
	/etc/init.d/tor enable >/dev/null 2>&1 || true
	/etc/init.d/tor restart >/dev/null 2>&1 || true
	/etc/init.d/firewall reload >/dev/null 2>&1 || /etc/init.d/firewall restart >/dev/null 2>&1
}

show_status() {
	printf 'MODE=%s\n' "$(uci -q get openwalla.tor.mode || echo none)"
	printf 'DNS=%s\n' "$(uci -q get openwalla.tor.dns_via_tor || echo 0)"
	printf 'RUNNING=%s\n' "$(/etc/init.d/tor running >/dev/null 2>&1 && echo 1 || echo 0)"
	for mac in $(uci -q get openwalla.tor.device_mac 2>/dev/null || true); do
		printf 'MAC=%s\n' "$mac"
	done
}

case "${1:-status}" in
configure) configure_tor ;;
unconfigure) unconfigure_tor ;;
apply) configure_tor; apply_rules ;;
disable)
	uci set openwalla.tor.mode="none"
	uci -q delete openwalla.tor.device_mac >/dev/null 2>&1 || true
	apply_rules
	;;
status) show_status ;;
*) echo "Usage: openwalla-tor {configure|unconfigure|apply|disable|status}" >&2; exit 1 ;;
esac
