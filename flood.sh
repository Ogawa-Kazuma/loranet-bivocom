#!/usr/bin/env bash
# Unified Installer (Node-RED + Tailscale)
set -eu

############################################
# Features:
# - Node.js via NVM (per target user)
# - Node-RED + common palettes
# - Systemd service (auto-start on boot)
# - Tailscale install (distro-aware)
# - Serial group & optional udev rules
############################################

: "${NODE_VERSION:=18}"
: "${NVM_VERSION:=v0.39.7}"
: "${NR_SERVICE:=node-red}"

NR_USER="${SUDO_USER:-${USER}}"

say() { printf "\n\033[1;32m==> %s\033[0m\n" "$*"; }
die() { printf "\n\033[1;31mERROR: %s\033[0m\n" "$*" >&2; exit 1; }
as_user() { sudo -u "$NR_USER" -H bash -lc "$*"; }

[ "$(id -u)" -eq 0 ] || die "Please run as root (sudo)."
id -u "$NR_USER" >/dev/null 2>&1 || die "User '$NR_USER' not found."

NR_HOME="$(getent passwd "$NR_USER" | cut -d: -f6)"
[ -n "$NR_HOME" ] || die "Could not resolve home for '$NR_USER'."
NVM_DIR="${NR_HOME}/.nvm"
USER_NODE_RED_DIR="${NR_HOME}/.node-red"

say "Target user: ${NR_USER}"
say "Home: ${NR_HOME}"
say "Node.js: Node ${NODE_VERSION}, via NVM ${NVM_VERSION}"

# ---- Base packages
say "Updating apt and installing base packages..."
export DEBIAN_FRONTEND=noninteractive
apt-get update -y
apt-get upgrade -y
apt-get install -y curl ca-certificates git nano build-essential python3 ffmpeg

# ---- Serial group
say "Ensuring ${NR_USER} is in 'dialout' group..."
usermod -aG dialout "$NR_USER" || true

# ---- NVM + Node.js
if [ ! -s "${NVM_DIR}/nvm.sh" ]; then
  say "Installing NVM ${NVM_VERSION} for ${NR_USER}..."
  as_user "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
else
  say "NVM already present for ${NR_USER}."
fi

say "Installing Node.js ${NODE_VERSION} via NVM..."
as_user "export NVM_DIR='${NVM_DIR}'; . \"\$NVM_DIR/nvm.sh\" && \
  nvm install ${NODE_VERSION} && nvm alias default ${NODE_VERSION} && nvm use ${NODE_VERSION}"

# ---- Node-RED + palettes
say "Installing Node-RED globally..."
as_user "export NVM_DIR='${NVM_DIR}'; . \"\$NVM_DIR/nvm.sh\" && \
  npm install -g --unsafe-perm node-red"

say "Preparing ${USER_NODE_RED_DIR} and installing palettes..."
as_user "mkdir -p '${USER_NODE_RED_DIR}'"
as_user "export NVM_DIR='${NVM_DIR}'; . \"\$NVM_DIR/nvm.sh\" && \
  cd '${USER_NODE_RED_DIR}' && \
  npm install --no-audit --no-fund \
    node-red-dashboard \
    node-red-node-serialport@2.0.3 \
    node-red-contrib-modbus \
    node-red-contrib-mqtt-broker \
    node-red-contrib-influxdb \
    node-red-contrib-file"

# ---- systemd service
say "Creating systemd service: ${NR_SERVICE}.service"
cat >/etc/systemd/system/${NR_SERVICE}.service <<EOF
[Unit]
Description=Node-RED (flows for ${NR_USER})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${NR_USER}
Group=${NR_USER}
Environment=HOME=${NR_HOME}
Environment=NVM_DIR=${NVM_DIR}
ExecStart=/bin/bash -lc 'source ${NVM_DIR}/nvm.sh && node-red --userDir ${USER_NODE_RED_DIR}'
Restart=on-failure
SyslogIdentifier=node-red
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable "${NR_SERVICE}"
systemctl restart "${NR_SERVICE}"
say "Node-RED started. UI: http://<host>:1880  |  Dashboard: /ui"

# ---- Tailscale
say "Installing Tailscale..."
[ -r /etc/os-release ] || die "/etc/os-release not found."
. /etc/os-release
CODENAME="${VERSION_CODENAME:-}"
[ -n "$CODENAME" ] || die "Could not determine Ubuntu/Debian codename."

install -m 0755 -d /usr/share/keyrings
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg

cat >/etc/apt/sources.list.d/tailscale.list <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${CODENAME} main
EOF

apt-get update -y
apt-get install -y tailscale
systemctl enable tailscaled --now
say "Tailscale daemon is running. Join with:  sudo tailscale up --ssh"

# ---- Optional udev hints
say "Installing example udev rules for serial ports (optional)..."
UDEV_FILE="/etc/udev/rules.d/99-node-red-serial.rules"
cat >"${UDEV_FILE}" <<'EOF'
# Adjust these to your hardware; these are just examples.
KERNEL=="ttyS0",   MODE="0660", GROUP="dialout", SYMLINK+="serial_primary"
KERNEL=="ttyS3",   MODE="0660", GROUP="dialout", SYMLINK+="serial_secondary"
KERNEL=="ttyUSB0", MODE="0660", GROUP="dialout", SYMLINK+="usb_serial0"
EOF
udevadm control --reload && udevadm trigger || true

say "All done!"
echo " Service:   sudo systemctl status ${NR_SERVICE}"
echo " Editor:    http://<this-host>:1880"
echo " Dashboard: http://<this-host>:1880/ui"
echo " Tailscale: sudo tailscale up --ssh"
