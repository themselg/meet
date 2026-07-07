#!/usr/bin/env bash
# Lanzado por meeting-room-kiosk.service. Espera al backend y arranca cage+chromium.
set -u

SERVER_URL="${SERVER_URL:-http://localhost}"
KIOSK_URL="${KIOSK_URL:-$SERVER_URL/kiosk}"
CHROMIUM_BIN="${CHROMIUM_BIN:-/usr/bin/chromium-browser}"

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
)

if [ "${VM_MODE:-0}" = "1" ]; then
  # VM sin aceleracion 3D: render por software en cage y chromium
  export WLR_RENDERER_ALLOW_SOFTWARE=1
  export LIBGL_ALWAYS_SOFTWARE=1
  FLAGS+=(--disable-gpu)
fi

if [ -n "${CHROMIUM_EXTRA_FLAGS:-}" ]; then
  # shellcheck disable=SC2206
  FLAGS+=($CHROMIUM_EXTRA_FLAGS)
fi

exec cage -- "$CHROMIUM_BIN" "${FLAGS[@]}" "$KIOSK_URL"
