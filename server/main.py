"""Universal Meeting Room — backend.

Servidor FastAPI que:
- Sirve la UI remota (/) y la pantalla del kiosko (/kiosk).
- Recibe URLs de reunión desde la LAN y las valida contra una allowlist.
- Notifica al kiosko por Server-Sent Events (/api/events).
- Reinicia el servicio del kiosko al terminar la reunión (/api/end).
"""

import asyncio
import contextlib
import json
import os
import re
import socket
import subprocess
import time
from contextlib import asynccontextmanager
from pathlib import Path
from urllib.parse import quote, urlsplit, urlunsplit

from fastapi import FastAPI, HTTPException, Request, WebSocket, WebSocketDisconnect
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles
from pydantic import BaseModel

VERSION = "1.0.0"

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

# Estado persistente (settings + wallpaper subido). systemd provee
# STATE_DIRECTORY (StateDirectory=meeting-room); en dev cae a .state/ del repo.
_state_env = os.environ.get("STATE_DIRECTORY", "").split(":")[0]
STATE_DIR = Path(_state_env) if _state_env else BASE_DIR.parent / ".state"
SETTINGS_FILE = STATE_DIR / "settings.json"
WALLPAPER_FILE = STATE_DIR / "wallpaper.img"
WALLPAPER_MAX_BYTES = 8 * 1024 * 1024

WALLPAPER_PRESETS = ("oceano", "bosque", "lavanda", "atardecer")
DEFAULT_WALLPAPER = "bosque"

# Restriccion opcional de dominios (separados por coma) via
# MEETING_ALLOWED_DOMAINS en /etc/meeting-room/server.env.
# Vacio o "*" = se acepta cualquier enlace https.
_domains = os.environ.get("MEETING_ALLOWED_DOMAINS", "").strip()
ALLOWED_DOMAINS = (
    tuple(d.strip().lower() for d in _domains.split(",") if d.strip())
    if _domains not in ("", "*")
    else ()
)

KIOSK_SERVICE = "meeting-room-kiosk.service"
SSE_KEEPALIVE_SECONDS = 15

# Direccion fija a mostrar en la pantalla del kiosko (p. ej. https://meet.iaan.mx).
# Vacia = detectar la IP del dispositivo. La define /etc/meeting-room/server.env.
DISPLAY_URL_OVERRIDE = os.environ.get("MEETING_DISPLAY_URL", "").strip() or None

# Nombre con el que el equipo entra a las reuniones (p. ej. "Oficina IAAN").
# Solo aplica en servicios que lo aceptan por URL (Jitsi, Zoom web).
ROOM_NAME = os.environ.get("MEETING_ROOM_NAME", "").strip() or None

# wayvnc del kiosko (solo localhost); /api/vnc lo puentea a WebSocket para noVNC.
VNC_HOST = "127.0.0.1"
VNC_PORT = int(os.environ.get("KIOSK_VNC_PORT", "5900"))

# Conectividad a internet (chequeo de fondo); ping_ms alimenta el diagnostico.
CONNECTIVITY_PROBE = ("1.1.1.1", 443)
CONNECTIVITY_INTERVAL = 30
net_state = {"online": True, "ping_ms": None}


async def _probe_connectivity() -> None:
    start = time.monotonic()
    try:
        _, writer = await asyncio.wait_for(asyncio.open_connection(*CONNECTIVITY_PROBE), 3)
        writer.close()
        net_state.update(online=True, ping_ms=round((time.monotonic() - start) * 1000))
    except (OSError, asyncio.TimeoutError):
        net_state.update(online=False, ping_ms=None)


async def _connectivity_loop() -> None:
    while True:
        await _probe_connectivity()
        await asyncio.sleep(CONNECTIVITY_INTERVAL)


@asynccontextmanager
async def lifespan(_app: FastAPI):
    task = asyncio.create_task(_connectivity_loop())
    yield
    task.cancel()
    with contextlib.suppress(asyncio.CancelledError):
        await task


app = FastAPI(title="Universal Meeting Room", docs_url=None, redoc_url=None, lifespan=lifespan)
app.mount("/novnc", StaticFiles(directory=STATIC_DIR / "novnc"), name="novnc")
app.mount("/fonts", StaticFiles(directory=STATIC_DIR / "fonts"), name="fonts")
app.mount("/vendor", StaticFiles(directory=STATIC_DIR / "vendor"), name="vendor")


class MeetingRequest(BaseModel):
    url: str


class SettingsRequest(BaseModel):
    wallpaper: str


def load_settings() -> dict:
    try:
        return json.loads(SETTINGS_FILE.read_text())
    except (OSError, ValueError):
        return {}


def save_settings(data: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    SETTINGS_FILE.write_text(json.dumps(data))


def wallpaper_state() -> dict:
    """Wallpaper activo (preset o 'custom') + version para cache-bust."""
    settings = load_settings()
    name = settings.get("wallpaper", DEFAULT_WALLPAPER)
    if name == "custom" and not WALLPAPER_FILE.exists():
        name = DEFAULT_WALLPAPER
    if name not in WALLPAPER_PRESETS + ("custom",):
        name = DEFAULT_WALLPAPER
    has_custom = WALLPAPER_FILE.exists()
    version = int(WALLPAPER_FILE.stat().st_mtime) if has_custom else None
    return {"wallpaper": name, "wallpaper_version": version, "wallpaper_has_custom": has_custom}


def image_mime(data: bytes) -> str | None:
    if data.startswith(b"\x89PNG\r\n\x1a\n"):
        return "image/png"
    if data.startswith(b"\xff\xd8\xff"):
        return "image/jpeg"
    if data[:4] == b"RIFF" and data[8:12] == b"WEBP":
        return "image/webp"
    return None


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
    if not ALLOWED_DOMAINS:
        return raw
    for domain in ALLOWED_DOMAINS:
        # Igualdad exacta o subdominio real (".zoom.us"); evita "zoom.us.evil.com"
        if host == domain or host.endswith("." + domain):
            return raw
    raise ValueError(f"Dominio no permitido: {host}")


def prepare_meeting_url(url: str) -> str:
    """Ajusta la URL ya validada segun el servicio: entrar silenciado y con el
    nombre de la sala donde el servicio lo permita por URL.

    - Jitsi: mute de camara/microfono y nombre via fragmento #config/userInfo.
    - Zoom: /j/<id> se reescribe al cliente web /wc/join/<id> (evita la pagina
      "abre la app de Zoom", inutil en un kiosko) y prellena el nombre (uname).
    - Teams / Meet / Webex: sin parametros soportados; se devuelve sin cambios.
    """
    parts = urlsplit(url)
    host = (parts.hostname or "").lower()

    if host == "meet.jit.si" or host.endswith(".meet.jit.si"):
        extras = [
            "config.startWithAudioMuted=true",
            "config.startWithVideoMuted=true",
        ]
        if ROOM_NAME:
            extras.append("userInfo.displayName=" + quote(f'"{ROOM_NAME}"'))
        fragment = parts.fragment
        fragment = (fragment + "&" if fragment else "") + "&".join(extras)
        return urlunsplit((parts.scheme, parts.netloc, parts.path, parts.query, fragment))

    if host == "zoom.us" or host.endswith(".zoom.us"):
        match = re.fullmatch(r"/j/(\d+)", parts.path)
        if match:
            query = parts.query
            if ROOM_NAME:
                query = (query + "&" if query else "") + "uname=" + quote(ROOM_NAME)
            return urlunsplit(
                (parts.scheme, parts.netloc, f"/wc/join/{match.group(1)}", query, parts.fragment)
            )

    return url


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
    if DISPLAY_URL_OVERRIDE:
        display_url = DISPLAY_URL_OVERRIDE
    elif ip:
        display_url = f"http://{ip}" if port in (80, None) else f"http://{ip}:{port}"
    else:
        display_url = None
    return {
        **room.snapshot(),
        **wallpaper_state(),
        "ip": ip,
        "display_url": display_url,
        "allowed_domains": ALLOWED_DOMAINS,
        "online": net_state["online"],
    }


@app.post("/api/settings")
async def update_settings(req: SettingsRequest) -> dict:
    name = req.wallpaper
    if name not in WALLPAPER_PRESETS + ("custom",):
        raise HTTPException(status_code=400, detail=f"Wallpaper desconocido: {name}")
    if name == "custom" and not WALLPAPER_FILE.exists():
        raise HTTPException(status_code=400, detail="No hay imagen subida")
    settings = load_settings()
    settings["wallpaper"] = name
    save_settings(settings)
    state = wallpaper_state()
    await room.broadcast(sse_event("settings", state))
    return {"ok": True, **state}


@app.put("/api/wallpaper")
async def upload_wallpaper(request: Request) -> dict:
    data = await request.body()
    if len(data) > WALLPAPER_MAX_BYTES:
        raise HTTPException(status_code=413, detail="Imagen demasiado grande (máximo 8 MB)")
    mime = image_mime(data)
    if not mime:
        raise HTTPException(status_code=400, detail="Formato no soportado (PNG, JPEG o WebP)")
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    WALLPAPER_FILE.write_bytes(data)
    settings = load_settings()
    settings.update(wallpaper="custom", wallpaper_mime=mime)
    save_settings(settings)
    state = wallpaper_state()
    await room.broadcast(sse_event("settings", state))
    return {"ok": True, **state}


@app.delete("/api/wallpaper")
async def delete_wallpaper() -> dict:
    WALLPAPER_FILE.unlink(missing_ok=True)
    settings = load_settings()
    settings["wallpaper"] = DEFAULT_WALLPAPER
    settings.pop("wallpaper_mime", None)
    save_settings(settings)
    state = wallpaper_state()
    await room.broadcast(sse_event("settings", state))
    return {"ok": True, **state}


@app.get("/wallpaper")
async def serve_wallpaper() -> FileResponse:
    if not WALLPAPER_FILE.exists():
        raise HTTPException(status_code=404, detail="Sin imagen personalizada")
    mime = load_settings().get("wallpaper_mime", "image/jpeg")
    return FileResponse(WALLPAPER_FILE, media_type=mime)


def _cpu_times() -> tuple[int, int]:
    fields = Path("/proc/stat").read_text().splitlines()[0].split()[1:]
    values = [int(v) for v in fields]
    idle = values[3] + (values[4] if len(values) > 4 else 0)
    return idle, sum(values)


def _temperature_c() -> float | None:
    temps = []
    for zone in Path("/sys/class/thermal").glob("thermal_zone*/temp"):
        try:
            temps.append(int(zone.read_text().strip()) / 1000)
        except (OSError, ValueError):
            continue
    return round(max(temps), 1) if temps else None


def _devices() -> dict:
    cameras = []
    for node in sorted(Path("/sys/class/video4linux").glob("video*/name")):
        try:
            name = node.read_text().strip()
        except OSError:
            continue
        if name and name not in cameras:
            cameras.append(name)
    audio = []
    try:
        for line in Path("/proc/asound/cards").read_text().splitlines():
            # " 0 [PCH  ]: HDA-Intel - HDA Intel PCH"
            if "]:" in line and " - " in line:
                audio.append(line.split(" - ", 1)[1].strip())
    except OSError:
        pass
    return {"cameras": cameras, "audio": audio}


@app.get("/api/diagnostics")
async def diagnostics() -> dict:
    idle1, total1 = _cpu_times()
    await asyncio.sleep(0.25)
    idle2, total2 = _cpu_times()
    busy = 1 - (idle2 - idle1) / max(1, total2 - total1)
    uptime = float(Path("/proc/uptime").read_text().split()[0])
    return {
        "online": net_state["online"],
        "ping_ms": net_state["ping_ms"],
        "cpu_percent": round(busy * 100),
        "temp_c": _temperature_c(),
        "uptime_seconds": int(uptime),
        "version": VERSION,
        "devices": _devices(),
    }


@app.post("/api/meeting")
async def create_meeting(req: MeetingRequest) -> dict:
    try:
        url = prepare_meeting_url(validate_meeting_url(req.url))
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


@app.websocket("/api/vnc")
async def vnc_proxy(ws: WebSocket) -> None:
    """Puente WebSocket <-> TCP hacia el wayvnc del kiosko (RFB binario).

    Es lo que hace websockify, pero integrado: noVNC en la pagina de control
    se conecta aqui y ve/controla la pantalla de la sala.
    """
    await ws.accept(subprotocol="binary")
    try:
        reader, writer = await asyncio.open_connection(VNC_HOST, VNC_PORT)
    except OSError:
        await ws.close(code=1011, reason="VNC del kiosko no disponible")
        return

    async def ws_to_tcp() -> None:
        try:
            while True:
                writer.write(await ws.receive_bytes())
                await writer.drain()
        except (WebSocketDisconnect, RuntimeError, OSError):
            pass

    async def tcp_to_ws() -> None:
        try:
            while data := await reader.read(65536):
                await ws.send_bytes(data)
        except (RuntimeError, OSError):
            pass

    tasks = [asyncio.create_task(ws_to_tcp()), asyncio.create_task(tcp_to_ws())]
    try:
        await asyncio.wait(tasks, return_when=asyncio.FIRST_COMPLETED)
    finally:
        for task in tasks:
            task.cancel()
        writer.close()
        try:
            await ws.close()
        except RuntimeError:
            pass


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
