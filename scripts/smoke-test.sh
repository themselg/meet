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
(cd server && exec ../.venv/bin/uvicorn main:app --host 127.0.0.1 --port $PORT --log-level warning) &
PID=$!
trap 'kill $PID 2>/dev/null || true' EXIT

for _ in $(seq 1 50); do
  curl -fsS "localhost:$PORT/api/status" >/dev/null 2>&1 && break
  sleep 0.2
done

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
check "URL valida (jitsi)"                 200 -X POST -H "$json" -d '{"url":"https://meet.jit.si/prueba-sala"}' "localhost:$PORT/api/meeting"
check "URL valida (subdominio zoom)"       200 -X POST -H "$json" -d '{"url":"https://us05web.zoom.us/j/123?pwd=x"}' "localhost:$PORT/api/meeting"
check "URL valida (dominio arbitrario)"    200 -X POST -H "$json" -d '{"url":"https://example.com/reunion"}' "localhost:$PORT/api/meeting"
check "rechazo: http sin tls"              400 -X POST -H "$json" -d '{"url":"http://meet.google.com/abc"}' "localhost:$PORT/api/meeting"
check "rechazo: sin URL"                   422 -X POST -H "$json" -d '{}' "localhost:$PORT/api/meeting"

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
check "allowlist: dominio permitido"       200 -X POST -H "$json" -d '{"url":"https://zoom.us/j/123"}' "localhost:$PORT2/api/meeting"
check "allowlist: dominio no listado"      400 -X POST -H "$json" -d '{"url":"https://example.com/x"}' "localhost:$PORT2/api/meeting"
check "allowlist: dominio malicioso"       400 -X POST -H "$json" -d '{"url":"https://zoom.us.evil.com/j/1"}' "localhost:$PORT2/api/meeting"

# Transformacion de URLs: mute/nombre en jitsi, cliente web + nombre en zoom
body=$(curl -s -X POST -H "$json" -d '{"url":"https://meet.jit.si/prueba-sala"}' "localhost:$PORT/api/meeting")
if echo "$body" | grep -q 'startWithAudioMuted=true' && echo "$body" | grep -q 'displayName'; then
  echo "OK   jitsi sale con mute y nombre de sala"
else
  echo "FAIL jitsi sin transformar: $body"
  fail=1
fi
body=$(curl -s -X POST -H "$json" -d '{"url":"https://us05web.zoom.us/j/123456789?pwd=abc"}' "localhost:$PORT/api/meeting")
if echo "$body" | grep -q '/wc/join/123456789' && echo "$body" | grep -q 'uname=' && echo "$body" | grep -q 'pwd=abc'; then
  echo "OK   zoom reescrito a cliente web con nombre (conserva pwd)"
else
  echo "FAIL zoom sin transformar: $body"
  fail=1
fi
body=$(curl -s -X POST -H "$json" -d '{"url":"https://teams.microsoft.com/l/meetup-join/xyz"}' "localhost:$PORT/api/meeting")
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
        "ws://localhost:$PORT/api/vnc", subprotocols=["binary"]
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
check "POST /api/end"                      200 -X POST "localhost:$PORT/api/end"

status=$(curl -s "localhost:$PORT/api/status")
if echo "$status" | grep -q '"state":"idle"'; then
  echo "OK   estado vuelve a idle tras /api/end"
else
  echo "FAIL estado no volvio a idle: $status"
  fail=1
fi

[ $fail -eq 0 ] && echo "== Smoke test: TODO OK ==" || echo "== Smoke test: FALLAS =="
exit $fail
