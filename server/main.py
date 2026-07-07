"""Universal Meeting Room — backend.

Servidor FastAPI que:
- Sirve la UI remota (/) y la pantalla del kiosko (/kiosk).
- Recibe URLs de reunión desde la LAN y las valida contra una allowlist.
- Notifica al kiosko por Server-Sent Events (/api/events).
- Reinicia el servicio del kiosko al terminar la reunión (/api/end).
"""

import asyncio
import json
import socket
import subprocess
import time
from pathlib import Path
from urllib.parse import urlsplit

from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import FileResponse, StreamingResponse
from pydantic import BaseModel

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

ALLOWED_DOMAINS = (
    "teams.microsoft.com",
    "teams.live.com",
    "zoom.us",
    "app.zoom.us",
    "meet.google.com",
    "webex.com",
    "meet.jit.si",
)

KIOSK_SERVICE = "meeting-room-kiosk.service"
SSE_KEEPALIVE_SECONDS = 15

app = FastAPI(title="Universal Meeting Room", docs_url=None, redoc_url=None)


class MeetingRequest(BaseModel):
    url: str


class Room:
    """Estado de la sala y suscriptores SSE (una cola por cliente conectado)."""

    def __init__(self) -> None:
        self.state = "idle"
        self.url: str | None = None
        self.since: float | None = None
        self.subscribers: set[asyncio.Queue] = set()

    def snapshot(self) -> dict:
        return {"state": self.state, "url": self.url, "since": self.since}

    def set_meeting(self, url: str) -> None:
        self.state = "meeting"
        self.url = url
        self.since = time.time()

    def reset(self) -> None:
        self.state = "idle"
        self.url = None
        self.since = None

    async def broadcast(self, event: str) -> None:
        for queue in list(self.subscribers):
            queue.put_nowait(event)


room = Room()


def validate_meeting_url(raw: str) -> str:
    """Devuelve la URL normalizada o lanza ValueError con el motivo del rechazo."""
    raw = raw.strip()
    parts = urlsplit(raw)
    if parts.scheme != "https":
        raise ValueError("Solo se aceptan URLs https://")
    host = (parts.hostname or "").lower()
    if not host:
        raise ValueError("La URL no tiene un dominio válido")
    for domain in ALLOWED_DOMAINS:
        # Igualdad exacta o subdominio real (".zoom.us"); evita "zoom.us.evil.com"
        if host == domain or host.endswith("." + domain):
            return raw
    raise ValueError(f"Dominio no permitido: {host}")


def sse_event(name: str, data: dict) -> str:
    return f"event: {name}\ndata: {json.dumps(data)}\n\n"


def get_local_ip() -> str | None:
    """IP primaria del dispositivo (sin enviar tráfico: connect() sobre UDP)."""
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    try:
        sock.connect(("192.0.2.1", 80))
        return sock.getsockname()[0]
    except OSError:
        return None
    finally:
        sock.close()


def restart_kiosk() -> str:
    """Reinicia el servicio del kiosko vía sudo (regla acotada en sudoers)."""
    cmd = ["sudo", "-n", "/usr/bin/systemctl", "restart", KIOSK_SERVICE]
    try:
        proc = subprocess.run(cmd, capture_output=True, text=True, timeout=15)
    except (FileNotFoundError, subprocess.TimeoutExpired) as exc:
        return f"no disponible ({exc.__class__.__name__}) — ¿modo desarrollo?"
    if proc.returncode != 0:
        detail = proc.stderr.strip() or proc.stdout.strip() or "systemctl falló"
        return f"no disponible: {detail} — ¿modo desarrollo?"
    return "ok"


@app.get("/")
async def remote_ui() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


@app.get("/kiosk")
async def kiosk_ui() -> FileResponse:
    return FileResponse(STATIC_DIR / "kiosk.html")


@app.get("/api/status")
async def status(request: Request) -> dict:
    server = request.scope.get("server") or (None, None)
    port = server[1]
    ip = get_local_ip()
    if ip:
        display_url = f"http://{ip}" if port in (80, None) else f"http://{ip}:{port}"
    else:
        display_url = None
    return {
        **room.snapshot(),
        "ip": ip,
        "display_url": display_url,
        "allowed_domains": ALLOWED_DOMAINS,
    }


@app.post("/api/meeting")
async def create_meeting(req: MeetingRequest) -> dict:
    try:
        url = validate_meeting_url(req.url)
    except ValueError as exc:
        raise HTTPException(status_code=400, detail=str(exc)) from exc
    room.set_meeting(url)
    await room.broadcast(sse_event("meeting", {"url": url}))
    return {"ok": True, "url": url}


@app.post("/api/end")
async def end_meeting() -> dict:
    room.reset()
    await room.broadcast(sse_event("end", {}))
    return {"ok": True, "kiosk_restart": restart_kiosk()}


@app.get("/api/events")
async def events() -> StreamingResponse:
    queue: asyncio.Queue = asyncio.Queue()
    room.subscribers.add(queue)

    async def stream():
        try:
            # Si el kiosko (re)conecta con reunión ya activa, se la reenviamos.
            if room.state == "meeting" and room.url:
                yield sse_event("meeting", {"url": room.url})
            while True:
                try:
                    yield await asyncio.wait_for(queue.get(), SSE_KEEPALIVE_SECONDS)
                except asyncio.TimeoutError:
                    # Comentario SSE: mantiene viva la conexión y detecta clientes idos.
                    yield ": keepalive\n\n"
        finally:
            room.subscribers.discard(queue)

    return StreamingResponse(
        stream(),
        media_type="text/event-stream",
        headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"},
    )
