# Openwalla Server

Openwalla Server is the external Detailed Flow collector for Openwalla. It connects to one OpenWrt router's Netify TCP stream, stores hybrid relational and original JSON flow data in SQLite, and exposes it to the Openwalla app through a REST API.

The existing on-router collector remains available. Choose **Local router** or **Openwalla Server** from Flow Settings in the app.

## Router preparation

Netify must listen on the router LAN address instead of only `127.0.0.1`. Openwalla applies this setting when external mode is saved. TCP port `7150` should remain restricted to the LAN.

## Start

Run the bootstrap installer from the directory where Openwalla Server should be installed:

```sh
wget -qO openwalla-server-install.sh https://raw.githubusercontent.com/benisai/Openwalla/main/openwalla-server/install.sh
chmod +x openwalla-server-install.sh
./openwalla-server-install.sh
```

The installer downloads the current runtime files into `./openwalla-server`, creates a persistent `.env`, and runs `docker compose up -d --build`. Edit `openwalla-server/.env` to set the router LAN address and optional API token, then rerun the installer to apply the settings.

For a manual installation, copy `.env.example` to `.env`, update the values, then run:

```sh
docker compose up -d --build
```

The dashboard and API are available at `http://<docker-host>:8080`. Enter that URL under **Network Flows > Flow Settings**.

Set `OPENWALLA_API_TOKEN` to require `Authorization: Bearer <token>`. Enter the same token in the app. Leaving it empty allows LAN access without authentication.

## Configuration

| Variable | Default | Purpose |
| --- | --- | --- |
| `OPENWALLA_NETIFY_HOST` | `192.168.1.1` | Router running Netify |
| `OPENWALLA_NETIFY_PORT` | `7150` | Netify TCP stream port |
| `OPENWALLA_ROUTER_LAN_IP` | empty | Router traffic excluded from stored flows |
| `OPENWALLA_DATABASE_PATH` | `/data/openwalla-netify.sqlite` | SQLite database path |
| `OPENWALLA_RETENTION_HOURS` | `24` | Detailed flow retention |
| `OPENWALLA_API_TOKEN` | empty | Optional REST bearer token |
| `OPENWALLA_UI_USERNAME` | `admin` | Dashboard login name |
| `OPENWALLA_UI_PASSWORD` | empty | Dashboard password; empty disables UI login |
| `OPENWALLA_UI_PASSWORD_HASH` | empty | Scrypt password hash used instead of the plain password |
| `OPENWALLA_SESSION_HOURS` | `24` | Dashboard session lifetime |
| `OPENWALLA_AUTH_MAX_FAILURES` | `5` | Failed logins allowed during the tracking window |
| `OPENWALLA_AUTH_WINDOW_SECONDS` | `900` | Failed-login tracking window |
| `OPENWALLA_AUTH_BAN_SECONDS` | `3600` | Temporary IP ban duration |
| `OPENWALLA_AUTH_TRUST_PROXY` | `false` | Trust the first `X-Forwarded-For` address |
| `OPENWALLA_AUTH_SECURE_COOKIE` | `false` | Send the session cookie over HTTPS only |

## API

- `GET /api/v1/health`
- `GET /api/v1/status`
- `GET /api/v1/dashboard?hours=24`
- `GET /api/v1/tunnel/status`
- `GET /api/v1/flows?limit=250&offset=0&hours=24`
- `GET /api/v1/flows/count?hours=24`
- `POST /api/v1/maintenance/prune`

Flow endpoints also accept `protocol`, `mac`, and `search` query parameters.

The web dashboard displays collector health, reverse-tunnel reachability, flow and device totals, top detected applications, and recent flows. It refreshes every 10 seconds. When `OPENWALLA_API_TOKEN` is configured, the dashboard asks for the token and stores it in the browser on that device.

## Dashboard authentication

Set `OPENWALLA_UI_USERNAME` and either `OPENWALLA_UI_PASSWORD` or `OPENWALLA_UI_PASSWORD_HASH` in `.env`, then recreate the service:

```sh
docker compose up -d --build
```

For a hashed password, generate an scrypt value without placing the password in shell history:

```sh
docker compose exec openwalla-server python -m app.auth
```

Paste the resulting value into `OPENWALLA_UI_PASSWORD_HASH`, leave `OPENWALLA_UI_PASSWORD` empty, and recreate the service. Dashboard sessions use signed `HttpOnly`, `SameSite=Strict` cookies. Set `OPENWALLA_AUTH_SECURE_COOKIE=true` when the dashboard is available exclusively through HTTPS.

The server temporarily bans a client address after the configured number of failed logins. The dashboard Security panel displays the active policy and current temporary bans. Bans are held in memory and clear when the container restarts.

When Traefik is the only path to Openwalla Server, set `OPENWALLA_AUTH_TRUST_PROXY=true` so limits apply to the original client address. Keep it disabled if clients can connect directly, because an untrusted client could forge `X-Forwarded-For`.

`OPENWALLA_API_TOKEN` remains separate from dashboard authentication and should be retained for the Openwalla phone app and other API clients.

## Optional reverse tunnel

Openwalla Server includes an optional SSH gateway for reaching a router behind NAT without opening an inbound router firewall port. The router initiates a key-authenticated outbound SSH connection to the VPS. LuCI is forwarded to port `10080` inside the gateway container and router SSH to port `10022`. Neither forwarded port is published directly by Docker.

The first implementation supports one router per Openwalla Server instance.

### 1. Prepare the router

Download the router installer and run it with the public VPS hostname or IP:

```sh
wget -qO /tmp/install-openwalla-tunnel.sh https://raw.githubusercontent.com/benisai/Openwalla/main/openwalla-server/tunnel/install-router.sh
chmod +x /tmp/install-openwalla-tunnel.sh
OPENWALLA_TUNNEL_HOST=vps.example.com /tmp/install-openwalla-tunnel.sh
```

The installer creates a dedicated key and prints its public key. It does not copy the private key off the router.

### 2. Authorize the router

Paste the printed public-key line into:

```text
openwalla-server/tunnel-data/authorized_keys
```

Make sure the external Docker network used by Traefik exists. The default is `proxy`; change `OPENWALLA_PROXY_NETWORK` in `.env` when your network has another name.

Start the optional gateway:

```sh
docker compose --profile tunnel up -d --build
```

Restart the router connection:

```sh
/etc/init.d/openwalla-tunnel restart
```

The OpenWrt `procd` service reconnects automatically after a network interruption or VPS restart.

### 3. Route LuCI through Traefik

Copy `tunnel/traefik-dynamic.example.yaml` into the Traefik file-provider directory, change `router.example.com`, and configure the desired certificate resolver or TLS options. Traefik must share the Docker network configured by `OPENWALLA_PROXY_NETWORK`.

Protect the router hostname with Traefik authentication or an IP allowlist. The SSH gateway authenticates the router connection, but the LuCI endpoint still needs normal access controls at the reverse proxy.

Useful checks:

```sh
docker compose logs -f openwalla-tunnel
logread -e openwalla-tunnel
```
