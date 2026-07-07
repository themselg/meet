#!/usr/bin/env bash
# Instalador idempotente del appliance "Universal Meeting Room" en AlmaLinux 10.
# Uso: sudo ./install.sh   (re-ejecutable tras un git pull para actualizar)
set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
  echo "Ejecuta como root: sudo ./install.sh" >&2
  exit 1
fi

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR=/opt/meeting-room

echo "==> Paquetes (EPEL: cage y chromium)"
dnf install -y epel-release
dnf install -y cage chromium python3 python3-pip pipewire wireplumber \
  pipewire-pulseaudio xdg-desktop-portal curl \
  mesa-dri-drivers mesa-libEGL mesa-libgbm libinput wayvnc

echo "==> Usuarios"
id -u meeting-room &>/dev/null || \
  useradd --system --home-dir "$APP_DIR" --shell /usr/sbin/nologin meeting-room
id -u kiosk &>/dev/null || useradd --create-home --shell /bin/bash kiosk
usermod -aG video,audio,input,render kiosk

echo "==> Aplicacion en $APP_DIR"
mkdir -p "$APP_DIR"
cp -r "$REPO_DIR/server" "$APP_DIR/"
cp -r "$REPO_DIR/scripts" "$APP_DIR/"
chmod +x "$APP_DIR"/scripts/*.sh

echo "==> Entorno virtual de Python"
[ -d "$APP_DIR/venv" ] || python3 -m venv "$APP_DIR/venv"
"$APP_DIR/venv/bin/pip" install -q --upgrade pip
"$APP_DIR/venv/bin/pip" install -q -r "$APP_DIR/server/requirements.txt"

echo "==> Configuracion"
mkdir -p /etc/meeting-room
# kiosk.env se conserva si ya existe (guarda VM_MODE local)
[ -f /etc/meeting-room/kiosk.env ] || cp "$REPO_DIR/system/kiosk.env" /etc/meeting-room/kiosk.env

mkdir -p /etc/chromium/policies/managed
cp "$REPO_DIR/system/chromium-policy.json" /etc/chromium/policies/managed/meeting-room.json

install -m 0440 "$REPO_DIR/system/sudoers-meeting-room" /etc/sudoers.d/meeting-room
visudo -cf /etc/sudoers.d/meeting-room

echo "==> Direccion mostrada en la pantalla del kiosko"
if [ -f /etc/meeting-room/server.env ]; then
  echo "(/etc/meeting-room/server.env ya existe, se conserva; editalo para cambiarla)"
else
  DISPLAY_CHOICE=1
  if [ -t 0 ]; then
    echo "La pantalla de inicio dice \"abre <direccion> en tu navegador\"."
    echo "  1) Usar la IP del dispositivo (detectada automaticamente)"
    echo "  2) Usar un dominio propio (ej. meet.iaan.mx)"
    read -rp "Opcion [1]: " DISPLAY_CHOICE
    DISPLAY_CHOICE=${DISPLAY_CHOICE:-1}
  fi
  DISPLAY_URL=""
  if [ "$DISPLAY_CHOICE" = "2" ]; then
    read -rp "Dominio (con o sin https://): " DISPLAY_INPUT
    case "$DISPLAY_INPUT" in
      "")                 ;;
      http://*|https://*) DISPLAY_URL="$DISPLAY_INPUT" ;;
      *)                  DISPLAY_URL="https://$DISPLAY_INPUT" ;;
    esac
  fi
  ROOM_NAME=""
  if [ -t 0 ]; then
    read -rp "Nombre del equipo al entrar a reuniones (ej. Oficina IAAN, vacio = ninguno): " ROOM_NAME
  fi
  cat > /etc/meeting-room/server.env <<EOF
# Direccion que muestra la pantalla de inicio del kiosko.
# Vacio = usar la IP del dispositivo detectada automaticamente.
MEETING_DISPLAY_URL=$DISPLAY_URL

# Nombre con el que el equipo entra a reuniones, donde el servicio lo
# acepte por URL (Jitsi, Zoom web). Teams/Meet lo toman de la cuenta
# con la que se inicie sesion en el kiosko, no de esta variable.
MEETING_ROOM_NAME=$ROOM_NAME
EOF
fi

echo "==> Servicios systemd"
cp "$REPO_DIR/system/meeting-room-server.service" /etc/systemd/system/
cp "$REPO_DIR/system/meeting-room-kiosk.service" /etc/systemd/system/
systemctl daemon-reload
systemctl disable getty@tty1.service 2>/dev/null || true
systemctl enable meeting-room-server.service meeting-room-kiosk.service

echo "==> Firewall (puerto 80)"
if systemctl is-active -q firewalld; then
  firewall-cmd --permanent --add-service=http >/dev/null
  firewall-cmd --reload >/dev/null
fi

echo "==> Tema de cursor invisible (control remoto sin retraso de mouse)"
python3 "$REPO_DIR/scripts/make-hidden-cursor.py" /usr/share/icons/meeting-room-hidden

echo "==> SELinux"
command -v restorecon &>/dev/null && restorecon -R "$APP_DIR" || true

systemctl restart meeting-room-server.service

echo
echo "Instalacion completa."
echo " - Backend:  http://$(hostname -I 2>/dev/null | awk '{print $1}')"
echo " - Kiosko:   systemctl start meeting-room-kiosk   (o reinicia el equipo)"
echo " - Si es una VM sin aceleracion 3D: poner VM_MODE=1 en /etc/meeting-room/kiosk.env"
