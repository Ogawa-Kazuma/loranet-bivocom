#!/usr/bin/env bash
# Linux setup: Node-RED + Dashboard + Tailscale + FFmpeg + udev (Debian/Ubuntu)
# Safe, idempotent-ish, and runs Node-RED as the invoking user via systemd.

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
  # Detect codename; default to "current" if detection fails
  if need_cmd lsb_release; then
    DIST_CODENAME="$(lsb_release -sc || true)"
  else
    DIST_CODENAME=""
  fi
  # NodeSource LTS repo
  curl -fsSL https://deb.nodesource.com/setup_lts.x | $SUDO -E bash -
  $SUDO apt-get install -y nodejs
else
  echo "Node.js already installed: $(node -v)"
fi

# Ensure npm exists
if ! need_cmd npm; then
  echo "npm is missing even though node is present; installing npm..."
  $SUDO apt-get install -y npm
fi

# ---------- 3) Node-RED (global) ----------
if ! need_cmd node-red; then
  echo "==> Installing Node-RED globally..."
  # --unsafe-perm needed on some platforms (e.g., Pi) to build native deps
  $SUDO npm install -g --unsafe-perm node-red
else
  echo "Node-RED already installed: $(node-red -v || echo 'unknown version')"
fi

# Prepare userDir for Node-RED
NR_USERDIR="$USER_HOME/.node-red"
if [ ! -d "$NR_USERDIR" ]; then
  echo "==> Creating Node-RED userDir at $NR_USERDIR"
  mkdir -p "$NR_USERDIR"
  chown -R "$USER_NAME":"$USER_NAME" "$NR_USERDIR"
fi

# ---------- 4) Common Node-RED nodes ----------
echo "==> Installing common Node-RED nodes into $NR_USERDIR"
pushd "$NR_USERDIR" >/dev/null
# Use user's npm cache/permissions
sudo -u "$USER_NAME" npm pkg set fund=false >/dev/null 2>&1 || true
for pkg in "${NR_NODES[@]}"; do
  echo "   - $pkg"
  sudo -u "$USER_NAME" npm install "$pkg" --no-audit --no-fund || true
done
popd >/dev/null

# ---------- 5) systemd service for Node-RED ----------
SERVICE_FILE="/etc/systemd/system/node-red.service"
if [ ! -f "$SERVICE_FILE" ]; then
  echo "==> Creating systemd service: $SERVICE_FILE"
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
Nice=5
# Give it access to serial by ensuring the user is in dialout

[Install]
WantedBy=multi-user.target
EOF

  echo "==> Reloading systemd and enabling Node-RED..."
  $SUDO systemctl daemon-reload
  $SUDO systemctl enable node-red
fi

echo "==> Starting (or restarting) Node-RED..."
$SUDO systemctl restart node-red

# ---------- 6) Tailscale (optional, as per original) ----------
if ! need_cmd tailscale; then
  echo "==> Installing Tailscale..."
  curl -fsSL https://tailscale.com/install.sh | $SUDO sh
  $SUDO systemctl enable tailscaled --now
else
  echo "Tailscale already installed."
  $SUDO systemctl enable tailscaled --now || true
fi

# NOTE: You still need to run `tailscale up` once (manually or via auth key)
echo "Tailscale is installed. To bring it online, run:"
echo "  sudo tailscale up  # or use --authkey=<TS_AUTH_KEY> in headless setups"

# ---------- 7) Serial access & udev rules ----------
echo "==> Ensuring $USER_NAME is in 'dialout' for serial access..."
if ! id -nG "$USER_NAME" | grep -qw dialout; then
  $SUDO usermod -aG dialout "$USER_NAME"
  echo "   Added $USER_NAME to dialout (log out/in to take effect)."
fi

RULES_FILE="/etc/udev/rules.d/99-node-red-serial.rules"
echo "==> Adding udev rules at $RULES_FILE"
$SUDO tee "$RULES_FILE" >/dev/null <<'EOF'
# Make common serial devices accessible to dialout (Node-RED user should be in dialout)
KERNEL=="ttyS0",    MODE="0660", GROUP="dialout", TAG+="systemd"
KERNEL=="ttyS3",    MODE="0660", GROUP="dialout", TAG+="systemd"
KERNEL=="ttyUSB[0-9]*", MODE="0660", GROUP="dialout", TAG+="systemd"
KERNEL=="ttyACM[0-9]*", MODE="0660", GROUP="dialout", TAG+="systemd"

# Optional stable symlinks (uncomment and customize if you like)
# SUBSYSTEM=="tty", ATTRS{idVendor}=="0403", ATTRS{idProduct}=="6001", SYMLINK+="usb_ftdi0"
EOF

echo "==> Reloading udev rules..."
$SUDO udevadm control --reload-rules
$SUDO udevadm trigger

# ---------- 8) Final info ----------
IP_ADDR="$(hostname -I 2>/dev/null | awk '{print $1}')"
echo "************************************************"
echo " Node-RED is running as service 'node-red'"
echo "   Service control: sudo systemctl [status|restart|stop] node-red"
echo
echo " Dashboard: http://$IP_ADDR:1880/ui"
echo " Editor:    http://$IP_ADDR:1880"
echo
echo " If Dashboard/Editor are not reachable, confirm firewall rules."
echo "************************************************"
