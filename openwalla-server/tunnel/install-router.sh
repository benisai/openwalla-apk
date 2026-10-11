#!/bin/sh

# Installs a persistent outbound reverse SSH tunnel on OpenWrt.

set -eu

SERVER_HOST="${OPENWALLA_TUNNEL_HOST:-}"
SERVER_PORT="${OPENWALLA_TUNNEL_PORT:-2222}"
SERVER_USER="${OPENWALLA_TUNNEL_USER:-openwalla}"
REMOTE_HTTP_PORT="${OPENWALLA_TUNNEL_HTTP_PORT:-10080}"
REMOTE_SSH_PORT="${OPENWALLA_TUNNEL_REMOTE_SSH_PORT:-10022}"
KEY_FILE=/etc/dropbear/openwalla_tunnel_ed25519
INIT_FILE=/etc/init.d/openwalla-tunnel

log() {
	printf '%s\n' "[openwalla-tunnel] $*"
}

fail() {
	printf '%s\n' "[openwalla-tunnel] ERROR: $*" >&2
	exit 1
}

[ -n "$SERVER_HOST" ] || fail "Set OPENWALLA_TUNNEL_HOST to the VPS hostname or IP."

if ! command -v ssh >/dev/null 2>&1; then
	log "Installing the OpenSSH client."
	if command -v apk >/dev/null 2>&1; then
		apk add openssh-client
	else
		opkg update
		opkg install openssh-client
	fi
fi

if [ ! -s "$KEY_FILE" ]; then
	log "Creating a dedicated router tunnel key."
	ssh-keygen -q -N '' -t ed25519 -f "$KEY_FILE"
fi

cat >"$INIT_FILE" <<EOF
#!/bin/sh /etc/rc.common

USE_PROCD=1
START=95
STOP=10

start_service() {
	procd_open_instance
	procd_set_param command /usr/bin/ssh \\
		-N \\
		-T \\
		-i $KEY_FILE \\
		-p $SERVER_PORT \\
		-o BatchMode=yes \\
		-o ExitOnForwardFailure=yes \\
		-o ServerAliveInterval=30 \\
		-o ServerAliveCountMax=3 \\
		-o StrictHostKeyChecking=accept-new \\
		-R 0.0.0.0:$REMOTE_HTTP_PORT:127.0.0.1:80 \\
		-R 0.0.0.0:$REMOTE_SSH_PORT:127.0.0.1:22 \\
		$SERVER_USER@$SERVER_HOST
	procd_set_param respawn 5 10 0
	procd_set_param stdout 1
	procd_set_param stderr 1
	procd_close_instance
}
EOF

chmod 0755 "$INIT_FILE"
"$INIT_FILE" enable

log "Router key created. Add this single line to openwalla-server/tunnel-data/authorized_keys:"
printf '\n'
cat "$KEY_FILE.pub"
printf '\n'
log "Then start the tunnel service on the server and run: $INIT_FILE restart"
