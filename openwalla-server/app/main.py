from __future__ import annotations

import logging
import socket
from contextlib import asynccontextmanager
from pathlib import Path
from typing import Annotated

from fastapi import Depends, FastAPI, Header, HTTPException, Query
from fastapi.responses import FileResponse

from .collector import NetifyCollector
from .config import Settings
from .database import FlowDatabase


logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
settings = Settings.from_environment()
database = FlowDatabase(settings.database_path)
collector = NetifyCollector(settings, database)
STATIC_DIRECTORY = Path(__file__).parent / "static"


def authorize(authorization: Annotated[str | None, Header()] = None) -> None:
    if not settings.api_token:
        return
    if authorization != f"Bearer {settings.api_token}":
        raise HTTPException(status_code=401, detail="Invalid API token")


@asynccontextmanager
async def lifespan(_: FastAPI):
    collector.start()
    try:
        yield
    finally:
        collector.stop()
        database.close()


app = FastAPI(title="Openwalla Server", version="1.0.0", lifespan=lifespan)


def _port_reachable(host: str, port: int) -> bool:
    try:
        with socket.create_connection((host, port), timeout=0.4):
            return True
    except (OSError, TimeoutError):
        return False


def _tunnel_status() -> dict[str, object]:
    luci_available = _port_reachable(settings.tunnel_host, settings.tunnel_http_port)
    ssh_available = _port_reachable(settings.tunnel_host, settings.tunnel_ssh_port)
    return {
        "connected": luci_available or ssh_available,
        "host": settings.tunnel_host,
        "luci": {
            "available": luci_available,
            "port": settings.tunnel_http_port,
        },
        "ssh": {
            "available": ssh_available,
            "port": settings.tunnel_ssh_port,
        },
    }


@app.get("/", include_in_schema=False)
def dashboard_page() -> FileResponse:
    return FileResponse(STATIC_DIRECTORY / "dashboard.html")


@app.get("/api/v1/health")
def health() -> dict[str, object]:
    return {"ok": True, "collector_connected": collector.status.connected}


@app.get("/api/v1/status", dependencies=[Depends(authorize)])
def status() -> dict[str, object]:
    state = collector.status
    return {
        "collector_connected": state.connected,
        "netify_host": settings.netify_host,
        "netify_port": settings.netify_port,
        "received": state.received,
        "stored": state.stored,
        "discarded": state.discarded,
        "last_event_at": state.last_event_at,
        "last_error": state.last_error,
        "retention_hours": settings.retention_hours,
    }


@app.get("/api/v1/tunnel/status", dependencies=[Depends(authorize)])
def tunnel_status() -> dict[str, object]:
    return _tunnel_status()


@app.get("/api/v1/dashboard", dependencies=[Depends(authorize)])
def dashboard(hours: Annotated[int, Query(ge=1, le=168)] = 24) -> dict[str, object]:
    state = collector.status
    return {
        "collector": {
            "connected": state.connected,
            "host": settings.netify_host,
            "port": settings.netify_port,
            "received": state.received,
            "stored": state.stored,
            "discarded": state.discarded,
            "last_event_at": state.last_event_at,
            "last_error": state.last_error,
        },
        "tunnel": _tunnel_status(),
        "flows": database.dashboard_summary(hours),
        "retention_hours": settings.retention_hours,
    }


@app.get("/api/v1/flows", dependencies=[Depends(authorize)])
def flows(
    limit: Annotated[int, Query(ge=1, le=250)] = 250,
    offset: Annotated[int, Query(ge=0)] = 0,
    protocol: str | None = None,
    mac: str | None = None,
    search: str | None = None,
    hours: Annotated[int | None, Query(ge=1, le=168)] = None,
) -> dict[str, object]:
    return {
        "items": database.list_flows(
            limit=limit,
            offset=offset,
            protocol=protocol,
            mac=mac,
            search=search,
            hours=hours,
        )
    }


@app.get("/api/v1/flows/count", dependencies=[Depends(authorize)])
def flow_count(
    protocol: str | None = None,
    mac: str | None = None,
    search: str | None = None,
    hours: Annotated[int | None, Query(ge=1, le=168)] = None,
) -> dict[str, int]:
    return {
        "count": database.count_flows(
            protocol=protocol, mac=mac, search=search, hours=hours
        )
    }


@app.post("/api/v1/maintenance/prune", dependencies=[Depends(authorize)])
def prune() -> dict[str, int]:
    return {"removed": database.prune(settings.retention_hours)}
