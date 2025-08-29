#!/usr/bin/env bash
# Linux setup: Node-RED + common nodes + systemd + Tailscale + FFmpeg + serial udev
set -euo pipefail

# ---- helper ----
need() { command -v "$1" >/dev/null 2>&1; }
SUDO=""; [ "$(id -u)" -ne 0 ] && { need sudo || { echo "Need sudo or run as root"; exit 1; }; SUDO="sudo"; }
USER_NAME="${SUDO:+$(logname || echo "$USER")}"
USER_NAME="${USER_NAME:-$USER}"
USER_HOME="$(getent passwd "$USER_NAME" | cut -d: -f6)"
USER_HOME="${USER_HOME:-/home/$USER_NAME}"
NR_DIR="$USER_HOME/.node-red"

echo "==> Using user: $USER_NAME  home: $USER_HOME"

# ---- 1) base packages ----
$SUDO apt-get update -y
$SUDO apt-get upgrade -y
$SUDO apt-get install -y build-essential python3 python3-pip curl ca-certificates gnupg nano ffmpeg udev

# ---- 2) Node.js LTS (NodeSource) ----
if ! need node; then
  curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -
  $SUDO apt-get install -y nodejs
fi
if ! need npm; then $SUDO apt-get install -y npm; fi
echo "Node: $(node -v)  npm: $(npm -v)"

# ---- 3) Node-RED global & userDir ----
if ! need node-red; then
  $SUDO npm install -g --unsafe-perm node-red
fi
mkdir -p "$NR_DIR"
$SUDO chown -R "$USER_NAME:$USER_NAME" "$NR_DIR"

echo "==> Installing common Node-RED nodes..."
pushd "$NR_DIR" >/dev/null
sudo -u "$USER_NAME" npm pkg set fund=false >/dev/null 2>&1 || true
for pkg in \
  node-red-dashboard \
  node-red-node-serialport@2.0.3 \
  node-red-contrib-modbus \
  node-red-contrib-mqtt-broker \
  node-red-contrib-influxdb \
  node-red-contrib-file
do
  echo "   - $pkg"
  sudo -u "$USER_NAME" npm install "$pkg" --no-audit --no-fund || true
done
popd >/dev/null

# ---- 4) systemd service ----
SERVICE=/etc/systemd/system/node-red.service
if [ ! -f "$SERVICE" ]; then
  echo "==> Creating systemd service"
  $SUDO tee "$SERVICE" >/dev/null <<EOF
[Unit]
Description=Node-RED data flow engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=$USER_NAME
Group=$USER_NAME
Environment=NODE_OPTIONS=--max_old_space_size=256
ExecStart=/usr/bin/env node-red --userDir $NR_DIR
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable node-red
fi
$SUDO systemctl restart node-red

# ---- 5) Tailscale ----
if ! need tailscale; then
  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
fi
$SUDO systemctl enable tailscaled --now || true
echo "Tailscale installed. Bring it online with:  sudo tailscale up"

# ---- 6) serial permissions & udev ----
if ! id -nG "$USER_NAME" | grep -qw dialout; then
  $SUDO usermod -aG dialout "$USER_NAME"
  echo "Added $USER_NAME to 'dialout' (log out/in to take effect)."
fi

RULES=/etc/udev/rules.d/99-node-red-serial.rules
$SUDO tee "$RULES" >/dev/null <<'EOF'
KERNEL=="ttyS0",        MODE="0660", GROUP="dialout"
KERNEL=="ttyS3",        MODE="0660", GROUP="dialout"
KERNEL=="ttyUSB[0-9]*", MODE="0660", GROUP="dialout"
KERNEL=="ttyACM[0-9]*", MODE="0660", GROUP="dialout"
EOF
$SUDO udevadm control --reload-rules
$SUDO udevadm trigger

IP="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "************************************************"
echo " Node-RED service: sudo systemctl status node-red"
echo " Editor:           http://$IP:1880"
echo " Dashboard:        http://$IP:1880/ui"
echo "************************************************"
