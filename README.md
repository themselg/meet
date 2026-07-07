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
- `POST /api/meeting` valida la URL contra la allowlist (solo `https://` y dominios
  de reunión conocidos, con verificación estricta de subdominios) y la empuja por SSE.
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

**Actualizar:** `git pull && sudo ./install.sh` (es idempotente; conserva
`/etc/meeting-room/kiosk.env`).

### Verificación

```bash
systemctl status meeting-room-server meeting-room-kiosk
journalctl -u meeting-room-kiosk -f
```

Desde otra máquina: abrir `http://IP_DEL_DISPOSITIVO`, pegar
`https://meet.jit.si/prueba-sala-123` (Jitsi no pide cuenta) → la TV debe entrar a
la sala en segundos. Probar también **Terminar reunión**.

## Pasar de VM a hardware real

1. Editar `/etc/meeting-room/kiosk.env` → `VM_MODE=0` (activa aceleración GPU real).
2. `systemctl restart meeting-room-kiosk`.
3. Conectar cámara y speakerphone USB; entrar a una sala Jitsi y confirmar que no
   aparece prompt de permisos (lo cubre la política de Chromium) y que hay audio/video.
4. Si el audio no aparece: `systemctl --user -M kiosk@ status pipewire wireplumber`.

## API

| Método | Ruta | Descripción |
|---|---|---|
| `GET` | `/` | UI remota |
| `GET` | `/kiosk` | Pantalla del kiosko |
| `GET` | `/api/status` | Estado de la sala, IP y dominios permitidos |
| `POST` | `/api/meeting` | `{"url": "https://..."}` → valida y envía a la sala |
| `POST` | `/api/end` | Termina la reunión y reinicia el kiosko |
| `GET` | `/api/events` | Stream SSE (eventos `meeting` y `end`) |

Dominios permitidos: `teams.microsoft.com`, `teams.live.com`, `zoom.us`,
`app.zoom.us`, `meet.google.com`, `webex.com`, `meet.jit.si` (y sus subdominios).

## Pendiente (fase 2)

- Confirmación en pantalla / PIN antes de abrir la reunión.
- Autenticación de la UI remota.
- Compartir pantalla desde la sala (`xdg-desktop-portal-wlr`).
