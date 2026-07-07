#!/usr/bin/env bash
# Modo desarrollo local: venv + uvicorn con reload en el puerto 8000 (o $PORT).
set -euo pipefail
cd "$(dirname "$0")/.."

if [ ! -d .venv ]; then
  echo "==> Creando .venv"
  python3 -m venv .venv
fi
.venv/bin/pip install -q -r server/requirements.txt

PORT="${PORT:-8000}"
echo "==> UI remota:  http://localhost:$PORT"
echo "==> Vista kiosko: http://localhost:$PORT/kiosk"
cd server
exec ../.venv/bin/uvicorn main:app --reload --host 0.0.0.0 --port "$PORT"
