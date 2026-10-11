from __future__ import annotations

import os
from dataclasses import dataclass
from pathlib import Path


def _integer(name: str, default: int, minimum: int, maximum: int) -> int:
    try:
        value = int(os.getenv(name, str(default)))
    except ValueError:
        value = default
    return max(minimum, min(maximum, value))


def _boolean(name: str, default: bool = False) -> bool:
    value = os.getenv(name)
    if value is None:
        return default
    return value.strip().lower() in {"1", "true", "yes", "on"}


@dataclass(frozen=True)
class Settings:
    netify_host: str
    netify_port: int
    database_path: Path
    retention_hours: int
    api_token: str
    excluded_protocols: frozenset[str]
    router_lan_ip: str
    reconnect_seconds: int
    tunnel_host: str
    tunnel_http_port: int
    tunnel_ssh_port: int
    ui_username: str
    ui_password: str
    ui_password_hash: str
    session_secret: str
    session_hours: int
    auth_max_failures: int
    auth_window_seconds: int
    auth_ban_seconds: int
    auth_trust_proxy: bool
    auth_secure_cookie: bool
    auth_ban_path: Path

    @classmethod
    def from_environment(cls) -> "Settings":
        protocols = os.getenv(
            "OPENWALLA_EXCLUDE_PROTOCOLS", "MDNS,DNS,QUIC,DHCPv6,ICMP"
        )
        return cls(
            netify_host=os.getenv("OPENWALLA_NETIFY_HOST", "192.168.1.1").strip(),
            netify_port=_integer("OPENWALLA_NETIFY_PORT", 7150, 1, 65535),
            database_path=Path(
                os.getenv("OPENWALLA_DATABASE_PATH", "/data/openwalla-netify.sqlite")
            ),
            retention_hours=_integer("OPENWALLA_RETENTION_HOURS", 24, 1, 8760),
            api_token=os.getenv("OPENWALLA_API_TOKEN", "").strip(),
            excluded_protocols=frozenset(
                value.strip().upper() for value in protocols.split(",") if value.strip()
            ),
            router_lan_ip=os.getenv("OPENWALLA_ROUTER_LAN_IP", "").strip(),
            reconnect_seconds=_integer("OPENWALLA_RECONNECT_SECONDS", 5, 1, 300),
            tunnel_host=os.getenv(
                "OPENWALLA_TUNNEL_STATUS_HOST", "openwalla-tunnel"
            ).strip(),
            tunnel_http_port=_integer(
                "OPENWALLA_TUNNEL_HTTP_PORT", 10080, 1, 65535
            ),
            tunnel_ssh_port=_integer(
                "OPENWALLA_TUNNEL_REMOTE_SSH_PORT", 10022, 1, 65535
            ),
            ui_username=os.getenv("OPENWALLA_UI_USERNAME", "admin").strip()
            or "admin",
            ui_password=os.getenv("OPENWALLA_UI_PASSWORD", ""),
            ui_password_hash=os.getenv("OPENWALLA_UI_PASSWORD_HASH", "").strip(),
            session_secret=os.getenv("OPENWALLA_SESSION_SECRET", "").strip(),
            session_hours=_integer("OPENWALLA_SESSION_HOURS", 24, 1, 720),
            auth_max_failures=_integer("OPENWALLA_AUTH_MAX_FAILURES", 5, 2, 100),
            auth_window_seconds=_integer(
                "OPENWALLA_AUTH_WINDOW_SECONDS", 900, 30, 86400
            ),
            auth_ban_seconds=_integer(
                "OPENWALLA_AUTH_BAN_SECONDS", 3600, 30, 604800
            ),
            auth_trust_proxy=_boolean("OPENWALLA_AUTH_TRUST_PROXY"),
            auth_secure_cookie=_boolean("OPENWALLA_AUTH_SECURE_COOKIE"),
            auth_ban_path=Path(
                os.getenv(
                    "OPENWALLA_AUTH_BAN_PATH", "/data/openwalla-auth-bans.json"
                )
            ),
        )
