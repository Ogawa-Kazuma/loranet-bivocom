#!/usr/bin/env bash
set -euo pipefail

# ============================================================
# Unified installer: Node-RED (Node 18 via NVM) + Tailscale
# ============================================================

# ---------- config (you can override with --user) -----------
NR_USER_DEFAULT="${SUDO_USER:-${USER}}"
NR_USER="${NR_USER_DEFAULT}"
NODE_VERSION="${NODE_VERSION:-18}"
NVM_VERSION="${NVM_VERSION:-v0.39.7}"   # recent nvm
INSTALL_SERIALPORT="${INSTALL_SERIALPORT:-1}"
# ------------------------------------------------------------

usage() {
  echo "Usage: $0 [--user <linux-username>]"
  exit 1
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --user)
      shift
      [[ $# -gt 0 ]] || usage
      NR_USER="$1"
      shift
      ;;
    -h|--help) usage ;;
    *) echo "Unknown arg: $1"; usage ;;
  esac
done

if [[ "$EUID" -ne 0 ]]; then
  echo "Please run as root (use: sudo $0 ...)"
  exit 1
fi

# Verify user exists
if ! id -u "$NR_USER" >/dev/null 2>&1; then
  echo "User '$NR_USER' not found. Create it first or pass a valid user with --user."
  exit 1
fi

echo "==> Running installer as root; Node-RED will run as user: $NR_USER"
echo "==> Node.js via NVM: $NODE_VERSION ; NVM: $NVM_VERSION"

# ---------- apt basics ----------
echo "==> Updating system packages..."
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y

echo "==> Installing base tools (curl, nano, git, build-essential, python3, ca-certificates)..."
apt-get install -y curl nano git build-essential python3 ca-certificates

# ---------- install NVM + Node for the target user ----------
as_user() {
  sudo -u "$NR_USER" -H bash -lc "$*"
}

NVM_DIR="/home/${NR_USER}/.nvm"
if [[ ! -s "${NVM_DIR}/nvm.sh" ]]; then
  echo "==> Installing NVM for ${NR_USER} (${NVM_VERSION})..."
  as_user "curl -fsSL https://raw.githubusercontent.com/nvm-sh/nvm/${NVM_VERSION}/install.sh | bash"
else
  echo "==> NVM already present for ${NR_USER}."
fi

echo "==> Installing Node ${NODE_VERSION} via NVM..."
as_user "export NVM_DIR='${NVM_DIR}'; . \"\$NVM_DIR/nvm.sh\" && nvm install ${NODE_VERSION} && nvm alias default ${NODE_VERSION} && nvm use ${NODE_VERSION}"

# ---------- Node-RED install ----------
echo '==> Installing Node-RED globally (unsafe-perm so native modules build correctly)...'
as_user "export NVM_DIR='${NVM_DIR}'; . \"\$NVM_DIR/nvm.sh\" && npm install -g --unsafe-perm node-red"

# Prepare ~/.node-red
as_user "mkdir -p /home/${NR_USER}/.node-red"

# ---------- Node-RED extra nodes ----------
echo "==> Installing additional Node-RED nodes in ${NR_USER}'s ~/.node-red..."
as_user "export NVM_DIR='${NVM_DIR}'; . \"\$NVM_DIR/nvm.sh\" && \
  cd ~/.node-red && \
  npm install --no-audit --no-fund \
    node-red-dashboard \
    node-red-node-serialport@2.0.3 \
    node-red-contrib-modbus \
    node-red-contrib-mqtt-broker \
    node-red-contrib-influxdb \
    node-red-contrib-file"

# ---------- systemd service for Node-RED ----------
SERVICE_PATH="/etc/systemd/system/node-red.service"
echo "==> Creating systemd service at ${SERVICE_PATH}..."
cat > "${SERVICE_PATH}" <<EOF
[Unit]
Description=Node-RED data flow engine
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${NR_USER}
Group=${NR_USER}
Environment=HOME=/home/${NR_USER}
Environment=NVM_DIR=/home/${NR_USER}/.nvm
ExecStart=/bin/bash -lc 'source /home/${NR_USER}/.nvm/nvm.sh && node-red --userDir /home/${NR_USER}/.node-red'
Restart=on-failure
SyslogIdentifier=node-red
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable node-red
systemctl restart node-red
echo "==> Node-RED service enabled & started (port 1880 by default)."

# ---------- Tailscale install ----------
echo "==> Installing Tailscale..."
. /etc/os-release
CODENAME="${VERSION_CODENAME:-focal}"

install -m 0755 -d /usr/share/keyrings
curl -fsSL "https://pkgs.tailscale.com/stable/ubuntu/${CODENAME}.noarmor.gpg" \
  -o /usr/share/keyrings/tailscale-archive-keyring.gpg

cat >/etc/apt/sources.list.d/tailscale.list <<EOF
deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu ${CODENAME} main
EOF

apt-get update -y
apt-get install -y tailscale
systemctl enable tailscaled --now

echo "==> Tailscale installed and daemon started."
echo "==> To bring the node onto your tailnet, run (as root):"
echo "      tailscale up --ssh"
echo "    …and follow the auth URL."

# ---------- Final info ----------
echo
echo "=============================================="
echo " Installation complete!"
echo " - Node-RED runs as: ${NR_USER}"
echo "   Service:  sudo systemctl status node-red"
echo "   UI:       http://<this-host>:1880"
echo " - Tailscale daemon: sudo systemctl status tailscaled"
echo "   Join tailnet:      sudo tailscale up --ssh"
echo "=============================================="
