#!/usr/bin/env bash
# Smoke test local: levanta el backend en un puerto de prueba y valida los endpoints.
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d .venv ]; then
  python3 -m venv .venv
fi
.venv/bin/pip install -q -r server/requirements.txt

PORT=8123
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
check "rechazo: dominio malicioso"         400 -X POST -H "$json" -d '{"url":"https://zoom.us.evil.com/j/1"}' "localhost:$PORT/api/meeting"
check "rechazo: http sin tls"              400 -X POST -H "$json" -d '{"url":"http://meet.google.com/abc"}' "localhost:$PORT/api/meeting"
check "rechazo: dominio no listado"        400 -X POST -H "$json" -d '{"url":"https://example.com/reunion"}' "localhost:$PORT/api/meeting"
check "rechazo: sin URL"                   422 -X POST -H "$json" -d '{}' "localhost:$PORT/api/meeting"

# SSE: con reunion activa, un cliente nuevo debe recibir el evento de inmediato
sse=$(timeout 3 curl -sN "localhost:$PORT/api/events" | head -n 2 | tr -d '\r' || true)
if echo "$sse" | grep -q 'event: meeting'; then
  echo "OK   SSE reenvia la reunion activa al conectar"
else
  echo "FAIL SSE no reenvio la reunion activa"
  fail=1
fi

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
