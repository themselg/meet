#!/usr/bin/env bash
# Actualizacion rapida del appliance: git pull + sincronizacion de archivos.
# No instala paquetes ni dependencias Python salvo que se pase --with-deps.
set -euo pipefail

APP_DIR="${MEETING_APP_DIR:-/opt/meeting-room}"
CONFIG_DIR=/etc/meeting-room
UPDATE_ENV="$CONFIG_DIR/update.env"
WITH_DEPS=0
RUN_RESTORECON=0

for arg in "$@"; do
  case "$arg" in
    --with-deps) WITH_DEPS=1 ;;
    --restorecon) RUN_RESTORECON=1 ;;
    --from-panel) ;;
    *)
      echo "Uso: $0 [--with-deps] [--restorecon] [--from-panel]" >&2
      exit 2
      ;;
  esac
done

if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecuta como root: sudo ./update.sh" >&2
  exit 1
fi

require_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Falta comando requerido: $1" >&2
    exit 1
  fi
}

require_cmd git
require_cmd systemctl
require_cmd cp
require_cmd install

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
MEETING_ROOM_REPO_DIR="${MEETING_ROOM_REPO_DIR:-}"
if [ -f "$UPDATE_ENV" ]; then
  # shellcheck disable=SC1090
  source "$UPDATE_ENV"
fi

REPO_DIR=""
for candidate in "${MEETING_ROOM_REPO_DIR:-}" "$SCRIPT_DIR" /home/meet/meet /home/*/meet /home/*/meeting-room /root/meet; do
  [ -n "$candidate" ] || continue
  if [ -d "$candidate/.git" ]; then
    REPO_DIR="$candidate"
    break
  fi
done

if [ -z "$REPO_DIR" ]; then
  echo "No encuentro un repo git para actualizar." >&2
  echo "Revise candidatos: ${MEETING_ROOM_REPO_DIR:-<sin update.env>}, $SCRIPT_DIR, /home/meet/meet, /home/*/meet" >&2
  echo "Define MEETING_ROOM_REPO_DIR en $UPDATE_ENV" >&2
  exit 1
fi

echo "==> Actualizando repo en $REPO_DIR"
git -C "$REPO_DIR" -c safe.directory="$REPO_DIR" pull --ff-only

echo "==> Sincronizando aplicacion en $APP_DIR"
install -d "$APP_DIR"

sync_dir() {
  local src=$1 dst=$2
  if command -v rsync >/dev/null 2>&1; then
    rsync -a --delete "$src/" "$dst/"
  else
    rm -rf "$dst"
    cp -a "$src" "$dst"
  fi
}

sync_dir "$REPO_DIR/server" "$APP_DIR/server"
sync_dir "$REPO_DIR/scripts" "$APP_DIR/scripts"
chmod +x "$APP_DIR"/scripts/*.sh
install -m 0755 "$REPO_DIR/update.sh" "$APP_DIR/update.sh"

if [ "$WITH_DEPS" = "1" ]; then
  echo "==> Actualizando dependencias Python"
  [ -d "$APP_DIR/venv" ] || python3 -m venv "$APP_DIR/venv"
  "$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/server/requirements.txt"
else
  echo "==> Dependencias: omitidas (usar --with-deps si cambian requirements)"
fi

echo "==> Configuracion del sistema"
install -d "$CONFIG_DIR"
[ -f "$CONFIG_DIR/kiosk.env" ] || cp "$REPO_DIR/system/kiosk.env" "$CONFIG_DIR/kiosk.env"
cat > "$UPDATE_ENV" <<EOF
# Repo fuente usado por /opt/meeting-room/update.sh para git pull.
MEETING_ROOM_REPO_DIR=$REPO_DIR
EOF

install -m 0644 "$REPO_DIR/system/meeting-room-server.service" /etc/systemd/system/
install -m 0644 "$REPO_DIR/system/meeting-room-kiosk.service" /etc/systemd/system/
install -m 0440 "$REPO_DIR/system/sudoers-meeting-room" /etc/sudoers.d/meeting-room
command -v visudo >/dev/null 2>&1 && visudo -cf /etc/sudoers.d/meeting-room

if [ "$RUN_RESTORECON" = "1" ] && command -v restorecon >/dev/null 2>&1; then
  echo "==> SELinux (restorecon acotado)"
  restorecon -R "$APP_DIR/server" "$APP_DIR/scripts" "$APP_DIR/update.sh" || true
else
  echo "==> SELinux: omitido (usar --restorecon si hace falta)"
fi

echo "==> Reiniciando servicios"
systemctl daemon-reload
systemctl try-restart meeting-room-kiosk.service || true
systemctl restart meeting-room-server.service

echo "Actualizacion completa."
