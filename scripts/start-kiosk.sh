#!/usr/bin/env bash
# Lanzado por meeting-room-kiosk.service. Espera al backend y arranca cage+chromium.
set -u

SERVER_URL="${SERVER_URL:-http://localhost}"
KIOSK_URL="${KIOSK_URL:-$SERVER_URL/kiosk}"
CHROMIUM_BIN="${CHROMIUM_BIN:-/usr/bin/chromium-browser}"

# Cursor invisible: el control remoto usa el cursor local del navegador (sin
# retraso) y la TV no muestra una flecha moviendose sola. Dos frentes, porque
# chromium puede dibujar el cursor via compositor (cursor-shape) o por si mismo
# (tema que lee de la config GTK).
if [ "${KIOSK_HIDE_CURSOR:-1}" = "1" ] && [ -d /usr/share/icons/meeting-room-hidden ]; then
  export XCURSOR_THEME=meeting-room-hidden
  export XCURSOR_SIZE=24
  for gtkdir in gtk-3.0 gtk-4.0; do
    mkdir -p "$HOME/.config/$gtkdir"
    printf '[Settings]\ngtk-cursor-theme-name=meeting-room-hidden\n' \
      > "$HOME/.config/$gtkdir/settings.ini"
  done
else
  rm -f "$HOME/.config/gtk-3.0/settings.ini" "$HOME/.config/gtk-4.0/settings.ini"
fi

echo "Esperando al backend en $SERVER_URL ..."
for _ in $(seq 1 60); do
  if curl -fsS --max-time 2 "$SERVER_URL/api/status" >/dev/null 2>&1; then
    break
  fi
  sleep 1
done

FLAGS=(
  --kiosk
  --no-first-run
  --noerrdialogs
  --disable-infobars
  --disable-session-crashed-bubble
  --autoplay-policy=no-user-gesture-required
  --ozone-platform=wayland
  --enable-features=WebRTCPipeWireCapturer
  --password-store=basic
  # En kiosko la burbuja de permisos cam/mic no se puede aceptar (no hay
  # toolbar); esto auto-concede el permiso. La navegacion ya esta limitada
  # a la allowlist de dominios de reunion.
  --use-fake-ui-for-media-stream
)

if [ "${VM_MODE:-0}" = "1" ]; then
  # VM sin aceleracion 3D: compositor en software puro (pixman, sin EGL)
  # y chromium sin GPU. Evita segfaults de wlroots cuando GL no es usable.
  export WLR_RENDERER="${WLR_RENDERER:-pixman}"
  export WLR_RENDERER_ALLOW_SOFTWARE=1
  export LIBGL_ALWAYS_SOFTWARE=1
  FLAGS+=(--disable-gpu)
  # La VM no tiene camara/microfono: dispositivos falsos de prueba
  # (camara animada + tono) para validar el flujo completo.
  FLAGS+=(--use-fake-device-for-media-stream)
fi

if [ -n "${CHROMIUM_EXTRA_FLAGS:-}" ]; then
  # shellcheck disable=SC2206
  FLAGS+=($CHROMIUM_EXTRA_FLAGS)
fi

# kiosk-session.sh corre dentro de cage: levanta wayvnc (soporte remoto,
# solo localhost) y ejecuta el navegador como proceso principal.
SESSION="$(dirname "$0")/kiosk-session.sh"
exec cage -- "$SESSION" "$CHROMIUM_BIN" "${FLAGS[@]}" "$KIOSK_URL"
