#!/usr/bin/env bash
# Linux setup script for Node-RED + Dashboard + Tailscale + FFmpeg + udev

set -euo pipefail

# ---------- Config ----------
NR_NODES=(
  "node-red-dashboard"
  "node-red-node-serialport@2.0.3"
  "node-red-contrib-modbus"
  "node-red-contrib-mqtt-broker"
  "node-red-contrib-influxdb"
  "node-red-contrib-file"
)

# ---------- Helpers ----------
need_cmd() { command -v "$1" >/dev/null 2>&1; }
SUDO=""
if [ "$(id -u)" -ne 0 ]; then
  if need_cmd sudo; then SUDO="sudo"; else
    echo "This script needs root privileges (sudo). Install sudo or run as root." >&2
    exit 1
  fi
fi

USER_NAME="${SUDO:+$(logname || echo "$USER")}"
USER_NAME="${USER_NAME:-$USER}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_HOME="${USER_HOME:-/home/$USER_NAME}"

echo "Using user: $USER_NAME"
echo "User home:  $USER_HOME"

# ---------- 1) System update & essentials ----------
echo "==> Updating system packages..."
$SUDO apt-get update -y
$SUDO apt-get upgrade -y

echo "==> Installing essentials..."
$SUDO apt-get install -y \
  build-essential python3 python3-pip curl ca-certificates gnupg \
  nano ffmpeg udev

# ---------- 2) Node.js (LTS) via NodeSource ----------
if ! need_cmd node; then
  echo "==> Installing Node.js (LTS) via NodeSource..."
  curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -
  $SUDO apt-get install -y nodejs
else
  echo "Node.js already installed: $(node -v)"
fi

if ! need_cmd npm; then
  echo "npm is missing even though node is present; installing npm..."
  $SUDO apt-get install -y npm
fi

# ---------- 3) Node-RED ----------
if ! need_cmd node-red; then
  echo "==> Installing Node-RED globally..."
  $SUDO npm install -g --unsafe-perm node-red
else
  echo "Node-RED already installed: $(node-red -v || echo 'unknown version')"
fi

NR_USERDIR="$USER_HOME/.node-red"
if [ ! -d "$NR_USERDIR" ]; then
  echo "==> Creating Node-RED userDir at $NR_USERDIR"
  mkdir -p "$NR_USERDIR"
  chown -R "$USER_NAME":"$USER_NAME" "$NR_USERDIR"
fi

echo "==> Installing common Node-RED nodes..."
pushd "$NR_USERDIR" >/dev/null
sudo -u "$USER_NAME" npm pkg set fund=false >/dev/null 2>&1 || true
for pkg in "${NR_NODES[@]}"; do
  echo "   - $pkg"
  sudo -u "$USER_NAME" npm install "$pkg" --no-audit --no-fund || true
done
popd >/dev/null

# ---------- 4) Node-RED systemd service ----------
SERVICE_FILE="/etc/systemd/system/node-red.service"
if [ ! -f "$SERVICE_FILE" ]; then
  echo "==> Creating systemd service..."
  $SUDO tee "$SERVICE_FILE" >/dev/null <<EOF
[Unit]
Description=Node-RED data flow engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER_NAME
Group=$USER_NAME
Environment="NODE_OPTIONS=--max_old_space_size=256"
ExecStart=/usr/bin/env node-red --userDir $NR_USERDIR
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

  $SUDO systemctl daemon-reload
  $SUDO systemctl enable node-red
fi
$SUDO systemctl restart node-red

# ---------- 5) Tailscale ----------
if ! need_cmd tailscale; then
  echo "==> Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
  $SUDO systemctl enable tailscaled --now
else
  echo "Tailscale already installed."
  $SUDO systemctl enable tailscaled --now || true
fi

echo "Tailscale is installed. To bring it online, run:"
echo "  sudo tailscale up"

# ---------- 6) Serial access ----------
echo "==> Ensuring $USER_NAME is in 'dialout'..."
if ! id -nG "$USER_NAME" | grep -qw dialout; then
  $SUDO usermod -aG dialout "$USER_NAME"
  echo "   Added $USER_NAME to dialout (log out/in to take effect)."
fi

RULES_FILE="/etc/udev/rules.d/99-node-red-serial.rules"
$SUDO tee "$RULES_FILE" >/dev/null <<'EOF'
KERNEL=="ttyS0",    MODE="0660", GROUP="dialout"
KERNEL=="ttyS3",    MODE="0660", GROUP="dialout"
KERNEL=="ttyUSB[0-9]*", MODE="0660", GROUP="dialout"
KERNEL=="ttyACM[0-9]*", MODE="0660", GROUP="dialout"
EOF

$SUDO udevadm control --reload-rules
$SUDO udevadm trigger

IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "************************************************"
echo " Node-RED is running as service 'node-red'"
echo "   Service: sudo systemctl status node-red"
echo
echo " Editor:    http://$IP_ADDR:1880"
echo " Dashboard: http://$IP_ADDR:1880/ui"
echo "************************************************"
