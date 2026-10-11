#!/bin/sh

set -eu

TUNNEL_USER="${OPENWALLA_TUNNEL_USER:-openwalla}"
KEY_DIRECTORY=/etc/ssh/keys
AUTHORIZED_KEYS=/config/authorized_keys

if [ ! -s "$AUTHORIZED_KEYS" ]; then
	printf '%s\n' "[openwalla-tunnel] No router public key found at $AUTHORIZED_KEYS." >&2
	exit 1
fi

if ! id "$TUNNEL_USER" >/dev/null 2>&1; then
	adduser -D -H -s /sbin/nologin "$TUNNEL_USER"
	# sshd rejects a locked account before checking authorized_keys. Set an
	# unusable random password while password authentication remains disabled.
	unnel_password="$(od -An -N24 -tx1 /dev/urandom | tr -d ' \n')"
	printf '%s:%s\n' "$TUNNEL_USER" "$tunnel_password" | chpasswd
fi

install -d -m 0700 "/home/$TUNNEL_USER/.ssh" "$KEY_DIRECTORY"
install -m 0600 "$AUTHORIZED_KEYS" "/home/$TUNNEL_USER/.ssh/authorized_keys"
chown -R "$TUNNEL_USER:$TUNNEL_USER" "/home/$TUNNEL_USER"

for type in ed25519 rsa; do
	key="$KEY_DIRECTORY/ssh_host_${type}_key"
	if [ ! -s "$key" ]; then
		ssh-keygen -q -N '' -t "$type" -f "$key"
	fi
done

cat >/etc/ssh/sshd_config <<EOF
Port 22
HostKey $KEY_DIRECTORY/ssh_host_ed25519_key
HostKey $KEY_DIRECTORY/ssh_host_rsa_key
PasswordAuthentication no
KbdInteractiveAuthentication no
PermitRootLogin no
AllowUsers $TUNNEL_USER
AllowTcpForwarding remote
GatewayPorts clientspecified
PermitListen 0.0.0.0:10080 0.0.0.0:10022
PermitTunnel no
PermitTTY no
X11Forwarding no
AllowAgentForwarding no
ClientAliveInterval 30
ClientAliveCountMax 3
LogLevel VERBOSE
EOF

printf '%s\n' "[openwalla-tunnel] Accepting reverse tunnels for $TUNNEL_USER."
exec /usr/sbin/sshd -D -e
