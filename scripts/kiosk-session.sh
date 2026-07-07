#!/usr/bin/env bash
# Se ejecuta DENTRO de cage (con WAYLAND_DISPLAY definido): arranca el VNC de
# soporte remoto (si esta habilitado) y luego el navegador como proceso principal.
set -u

if [ "${KIOSK_VNC:-1}" = "1" ] && command -v wayvnc >/dev/null 2>&1; then
  # Solo localhost: el acceso remoto es via tunel SSH (ssh -L 5900:localhost:5900)
  wayvnc "${KIOSK_VNC_ADDR:-127.0.0.1}" "${KIOSK_VNC_PORT:-5900}" &
fi

exec "$@"
