#!/usr/bin/env bash
# Smoke test local: levanta el backend en un puerto de prueba y valida los endpoints.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
.venv/bin/pip install -q -r server/requirements.txt

PORT=8123
export MEETING_ROOM_NAME="Sala Test"
export KIOSK_VNC_PORT=59123
rm -rf .state  # estado dev limpio para las pruebas de settings/wallpaper
(cd server && exec ../.venv/bin/uvicorn main:app --host 127.0.0.1 --port $PORT --log-level warning) &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  curl -fsS "localhost:$PORT/api/status" >/dev/null 2>&1 && break
  sleep 0.2
done
PIN=$(curl -fsS "localhost:$PORT/api/status?kiosk=1" | sed -n 's/.*"pairing_pin":"\([^"]*\)".*/\1/p')
if [ -z "$PIN" ]; then
  echo "FAIL no se obtuvo PIN del kiosko local"
  exit 1
fi

fail=0
check() {
  local desc=$1 expected=$2
  shift 2
  local code
  code=$(curl -s -o /dev/null -w '%{http_code}' "$@")
  if [ "$code" = "$expected" ]; then
    echo "OK   $desc ($code)"
  else
    echo "FAIL $desc (esperado $expected, obtuvo $code)"
    fail=1
  fi
}

json='Content-Type: application/json'
check "GET /api/status"                    200 "localhost:$PORT/api/status"
check "GET / (UI remota)"                  200 "localhost:$PORT/"
check "GET /kiosk (pantalla sala)"         200 "localhost:$PORT/kiosk"
check "rechazo: sin PIN"                   403 -X POST -H "$json" -d '{"url":"https://meet.jit.si/prueba-sala"}' "localhost:$PORT/api/meeting"
check "URL valida (jitsi)"                 200 -X POST -H "$json" -d "{\"url\":\"https://meet.jit.si/prueba-sala\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/meeting"
check "URL valida (subdominio zoom)"       200 -X POST -H "$json" -d "{\"url\":\"https://us05web.zoom.us/j/123?pwd=x\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/meeting"
check "URL valida (dominio arbitrario)"    200 -X POST -H "$json" -d "{\"url\":\"https://example.com/reunion\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/meeting"
check "rechazo: http sin tls"              400 -X POST -H "$json" -d "{\"url\":\"http://meet.google.com/abc\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/meeting"
check "rechazo: sin URL"                   422 -X POST -H "$json" -d "{\"pin\":\"$PIN\"}" "localhost:$PORT/api/meeting"

# Con MEETING_ALLOWED_DOMAINS la restriccion opcional debe seguir funcionando
PORT2=8124
(cd server && MEETING_ALLOWED_DOMAINS="zoom.us" exec ../.venv/bin/uvicorn main:app \
  --host 127.0.0.1 --port $PORT2 --log-level warning) &
PID2=$!
trap 'kill $PID $PID2 2>/dev/null || true' EXIT
for _ in $(seq 1 50); do
  curl -fsS "localhost:$PORT2/api/status" >/dev/null 2>&1 && break
  sleep 0.2
done
PIN2=$(curl -fsS "localhost:$PORT2/api/status?kiosk=1" | sed -n 's/.*"pairing_pin":"\([^"]*\)".*/\1/p')
check "allowlist: dominio permitido"       200 -X POST -H "$json" -d "{\"url\":\"https://zoom.us/j/123\",\"pin\":\"$PIN2\"}" "localhost:$PORT2/api/meeting"
check "allowlist: dominio no listado"      400 -X POST -H "$json" -d "{\"url\":\"https://example.com/x\",\"pin\":\"$PIN2\"}" "localhost:$PORT2/api/meeting"
check "allowlist: dominio malicioso"       400 -X POST -H "$json" -d "{\"url\":\"https://zoom.us.evil.com/j/1\",\"pin\":\"$PIN2\"}" "localhost:$PORT2/api/meeting"

# Transformacion de URLs: mute/nombre en jitsi, cliente web + nombre en zoom
body=$(curl -s -X POST -H "$json" -d "{\"url\":\"https://meet.jit.si/prueba-sala\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/meeting")
if echo "$body" | grep -q 'startWithAudioMuted=true' && echo "$body" | grep -q 'displayName'; then
  echo "OK   jitsi sale con mute y nombre de sala"
else
  echo "FAIL jitsi sin transformar: $body"
  fail=1
fi
body=$(curl -s -X POST -H "$json" -d "{\"url\":\"https://us05web.zoom.us/j/123456789?pwd=abc\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/meeting")
if echo "$body" | grep -q '/wc/join/123456789' && echo "$body" | grep -q 'uname=' && echo "$body" | grep -q 'pwd=abc'; then
  echo "OK   zoom reescrito a cliente web con nombre (conserva pwd)"
else
  echo "FAIL zoom sin transformar: $body"
  fail=1
fi
body=$(curl -s -X POST -H "$json" -d "{\"url\":\"https://teams.microsoft.com/l/meetup-join/xyz\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/meeting")
if echo "$body" | grep -q '"url":"https://teams.microsoft.com/l/meetup-join/xyz"'; then
  echo "OK   teams pasa sin cambios"
else
  echo "FAIL teams alterado: $body"
  fail=1
fi

# SSE: con reunion activa, un cliente nuevo debe recibir el evento de inmediato
sse=$(timeout 3 curl -sN "localhost:$PORT/api/events" | head -n 2 | tr -d '\r' || true)
if echo "$sse" | grep -q 'event: meeting'; then
  echo "OK   SSE reenvia la reunion activa al conectar"
else
  echo "FAIL SSE no reenvio la reunion activa"
  fail=1
fi

# Settings y wallpaper (MD3): presets, imagen propia y diagnostico
check "GET /api/diagnostics"               200 "localhost:$PORT/api/diagnostics"
if curl -s "localhost:$PORT/api/diagnostics" | grep -q '"cpu_percent"'; then
  echo "OK   diagnostics trae cpu_percent"
else
  echo "FAIL diagnostics sin campos"; fail=1
fi
check "settings: preset valido"            200 -X POST -H "$json" -d "{\"wallpaper\":\"lavanda\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/settings"
if curl -s "localhost:$PORT/api/status" | grep -q '"wallpaper":"lavanda"'; then
  echo "OK   status refleja wallpaper lavanda"
else
  echo "FAIL status no refleja el preset"; fail=1
fi
check "settings: preset invalido"          400 -X POST -H "$json" -d "{\"wallpaper\":\"neon\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/settings"
check "settings: custom sin imagen"        400 -X POST -H "$json" -d "{\"wallpaper\":\"custom\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/settings"
check "settings: reloj valido"             200 -X POST -H "$json" -d "{\"clock_style\":\"split\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/settings"
if curl -s "localhost:$PORT/api/status" | grep -q '"clock_style":"split"'; then
  echo "OK   status refleja estilo de reloj split"
else
  echo "FAIL status no refleja el estilo de reloj"; fail=1
fi
check "settings: reloj invalido"           400 -X POST -H "$json" -d "{\"clock_style\":\"gigante\",\"pin\":\"$PIN\"}" "localhost:$PORT/api/settings"
# PNG minimo de 1x1 para la subida
printf '\x89PNG\r\n\x1a\n' > /tmp/mini.png
head -c 100 /dev/zero >> /tmp/mini.png
check "wallpaper: subir PNG"               200 -X PUT --data-binary @/tmp/mini.png -H 'Content-Type: image/png' -H "X-Kiosk-Pin: $PIN" "localhost:$PORT/api/wallpaper"
check "wallpaper: servir imagen"           200 "localhost:$PORT/wallpaper"
if curl -s "localhost:$PORT/api/status" | grep -q '"wallpaper":"custom"'; then
  echo "OK   status activa wallpaper custom tras subir"
else
  echo "FAIL status no activo custom"; fail=1
fi
check "wallpaper: body no imagen"          400 -X PUT --data-binary 'hola' -H 'Content-Type: text/plain' -H "X-Kiosk-Pin: $PIN" "localhost:$PORT/api/wallpaper"
check "wallpaper: eliminar"                200 -X DELETE -H "X-Kiosk-Pin: $PIN" "localhost:$PORT/api/wallpaper"
if curl -s "localhost:$PORT/api/status" | grep -q '"wallpaper":"bosque"'; then
  echo "OK   al eliminar vuelve al gradiente predeterminado"
else
  echo "FAIL no volvio al predeterminado"; fail=1
fi
check "wallpaper: 404 sin imagen"          404 "localhost:$PORT/wallpaper"
check "GET /fonts/fonts.css"               200 "localhost:$PORT/fonts/fonts.css"
check "GET /vendor/qrcode.js"              200 "localhost:$PORT/vendor/qrcode.js"

# Puente VNC: un servidor TCP falso responde el saludo RFB y debe llegar por WS
if .venv/bin/python - <<EOF
import asyncio, websockets

async def main():
    async def handler(reader, writer):
        writer.write(b"RFB 003.008\n")
        await writer.drain()
        await asyncio.sleep(0.3)
        writer.close()

    server = await asyncio.start_server(handler, "127.0.0.1", $KIOSK_VNC_PORT)
    async with websockets.connect(
        "ws://localhost:$PORT/api/vnc?pin=$PIN", subprotocols=["binary"]
    ) as ws:
        data = await asyncio.wait_for(ws.recv(), 3)
        assert data.startswith(b"RFB"), data
    server.close()

asyncio.run(main())
EOF
then
  echo "OK   puente WebSocket->VNC transmite RFB"
else
  echo "FAIL puente WebSocket->VNC"
  fail=1
fi

check "GET /novnc/core/rfb.js (visor)"     200 "localhost:$PORT/novnc/core/rfb.js"
check "POST /api/end"                      200 -X POST -H "X-Kiosk-Pin: $PIN" "localhost:$PORT/api/end"

status=$(curl -s "localhost:$PORT/api/status")
if echo "$status" | grep -q '"state":"idle"'; then
  echo "OK   estado vuelve a idle tras /api/end"
else
  echo "FAIL estado no volvio a idle: $status"
  fail=1
fi

[ $fail -eq 0 ] && echo "== Smoke test: TODO OK ==" || echo "== Smoke test: FALLAS =="
exit $fail
