# Universal Meeting Room

Appliance Linux para salas de reuniones: un equipo conectado por HDMI a una TV, con
cámara y micrófono/speakerphone USB, que arranca directo a una pantalla de kiosko.
Desde cualquier computadora de la LAN se abre la IP del dispositivo, se pega un
enlace de Teams / Zoom / Meet / Webex / Jitsi y la sala entra a la reunión.

**Stack:** AlmaLinux 10 · Cage (Wayland kiosk) · Chromium (EPEL) · FastAPI + Uvicorn · PipeWire.

## Cómo funciona

```
[Laptop LAN] --http--> :80  POST /api/meeting ─┐
                                                ▼
                  meeting-room-server.service (uvicorn, user: meeting-room)
                                                │ SSE /api/events
[Kiosko] cage → chromium --kiosk → localhost/kiosk ◄┘
         (meeting-room-kiosk.service en tty1, user: kiosk)
```

- El kiosko muestra `kiosk.html` (reloj + instrucciones) con una conexión SSE abierta.
- `POST /api/meeting` valida la URL (solo `https://`; opcionalmente restringida a
  una lista de dominios) y la empuja por SSE.
- El kiosko navega a la reunión. El botón **Terminar reunión** de la UI remota llama
  `POST /api/end`, que reinicia el servicio del kiosko vía una regla sudoers acotada
  a ese único comando — la sala vuelve limpia a la pantalla de inicio.

## Estructura

| Ruta | Contenido |
|---|---|
| `server/` | Backend FastAPI (`main.py`) y frontend estático (`static/`) |
| `system/` | Unidades systemd, política de Chromium, sudoers, entorno del kiosko |
| `scripts/` | `start-kiosk.sh` (producción), `dev.sh` y `smoke-test.sh` (desarrollo) |
| `install.sh` | Instalador idempotente para AlmaLinux 10 |

## Desarrollo local (cualquier Linux con Python 3.11+)

```bash
make dev     # crea .venv, instala deps y corre uvicorn --reload en :8000
make test    # smoke test: allowlist, SSE, flujo completo
```

- UI remota: <http://localhost:8000>
- Vista del kiosko: <http://localhost:8000/kiosk>

En desarrollo `POST /api/end` no reinicia servicios (no existen); responde con una
nota y la vista del kiosko simplemente recarga.

## Despliegue en el appliance (VM o hardware, AlmaLinux 10 minimal)

```bash
dnf install -y git
git clone <URL_DEL_REPO> meeting-room && cd meeting-room
sudo ./install.sh
reboot
```

El instalador: habilita EPEL e instala `cage`/`chromium`/PipeWire, crea los usuarios
`meeting-room` y `kiosk`, copia la app a `/opt/meeting-room` con su venv, instala la
política de Chromium (auto-permite cámara/micrófono solo en los dominios de reunión),
abre el puerto 80 en firewalld, deshabilita `getty@tty1` y habilita ambos servicios.

Durante la instalación pregunta qué dirección debe mostrar la pantalla de inicio
del kiosko: la IP del dispositivo (automática) o un dominio propio (p. ej.
`meet.iaan.mx`). Queda en `/etc/meeting-room/server.env` (`MEETING_DISPLAY_URL`);
edítalo y reinicia `meeting-room-server` para cambiarla después.

**Actualizar:** `git pull && sudo ./install.sh` (es idempotente; conserva
`/etc/meeting-room/kiosk.env` y `/etc/meeting-room/server.env`).

### Verificación

```bash
systemctl status meeting-room-server meeting-room-kiosk
journalctl -u meeting-room-kiosk -f
```

Desde otra máquina: abrir `http://IP_DEL_DISPOSITIVO`, pegar
`https://meet.jit.si/prueba-sala-123` (Jitsi no pide cuenta) → la TV debe entrar a
la sala en segundos. Probar también **Terminar reunión**.

## Modo VM vs. hardware real

El predeterminado es **hardware real** (`VM_MODE=0`: cage y Chromium usan la GPU).
Para probar en una **VM sin aceleración 3D**, edita `/etc/meeting-room/kiosk.env`
→ `VM_MODE=1` (compositor por software pixman + `--disable-gpu`) y
`systemctl restart meeting-room-kiosk`. El archivo se conserva entre updates.

En hardware real, al estrenar el equipo:

1. Conectar cámara y speakerphone USB; entrar a una sala Jitsi y confirmar que no
   aparece prompt de permisos (lo cubre la política de Chromium) y que hay audio/video.
2. Si el audio no aparece: `systemctl --user -M kiosk@ status pipewire wireplumber`.

## API

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/` | UI remota |
| `GET` | `/kiosk` | Pantalla del kiosko |
| `GET` | `/api/status` | Estado de la sala, IP y dominios permitidos |
| `POST` | `/api/meeting` | `{"url": "https://..."}` → valida y envía a la sala |
| `POST` | `/api/end` | Termina la reunión y reinicia el kiosko |
| `GET` | `/api/events` | Stream SSE (eventos `meeting` y `end`) |

Por defecto se acepta **cualquier enlace `https://`**. Para restringir a ciertos
servicios, define `MEETING_ALLOWED_DOMAINS` en `/etc/meeting-room/server.env`
(separados por coma; cubre también sus subdominios con verificación estricta):

```
MEETING_ALLOWED_DOMAINS=teams.microsoft.com,teams.live.com,zoom.us,meet.google.com,webex.com,meet.jit.si
```

## Entrar silenciado y con nombre de sala

Tras validar, el backend ajusta la URL según lo que cada servicio soporta
(`prepare_meeting_url` en `server/main.py`; el nombre sale de `MEETING_ROOM_NAME`
en `/etc/meeting-room/server.env`):

| Servicio | Cámara/mic apagados | Nombre de sala |
|---|---|---|
| Jitsi | ✅ por URL | ✅ por URL |
| Zoom | ❌ (sin parámetro) | ✅ `uname` (además se reescribe `/j/<id>` → cliente web `/wc/join/<id>`, evitando la página "abre la app") |
| Teams / Meet / Webex | ❌ | ❌ |

Teams y Meet no aceptan nada por URL en el pre-join anónimo: el nombre y el
estado de cámara/mic se fijan en su pantalla previa (requiere teclado/mouse en
la sala), o iniciando sesión una sola vez en el Chromium del kiosko con una
cuenta llamada como la sala — el perfil persiste entre reuniones y ambos toman
el nombre de la cuenta. Automatizar ese pre-join vía extensión queda en fase 2.

## Pantalla de la sala en la página de control

Cuando hay reunión activa, la página de control muestra el escritorio del kiosko
**embebido y con control** (clic y teclado), junto al botón "Terminar reunión".
Sirve para el pre-join de Teams/Meet (nombre, toggles de cámara/mic) sin teclado
en la sala.

Cadena: `wayvnc` corre dentro de la sesión de cage escuchando **solo en
localhost:5900** → el backend lo puentea por WebSocket en `/api/vnc` → el visor
noVNC (vendorizado en `server/static/novnc/`) lo pinta en `index.html`. Nada de
VNC queda expuesto a la red; quien ve la página de control ve la pantalla.

También puedes conectarte con un cliente VNC clásico vía túnel SSH
(`ssh -L 5900:localhost:5900 usuario@appliance` → `vnc://localhost:5900`).
Se desactiva todo con `KIOSK_VNC=0` en `/etc/meeting-room/kiosk.env`.

## Pendiente (fase 2)

- Confirmación en pantalla / PIN antes de abrir la reunión.
- Autenticación de la UI remota.
- Compartir pantalla desde la sala (`xdg-desktop-portal-wlr`).
