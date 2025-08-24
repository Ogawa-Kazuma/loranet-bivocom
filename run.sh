#!/bin/bash

echo "************************************************"
echo " Combined Node-RED + Dashboard + Tailscale Installation"
echo "************************************************"

# 1. Update system
echo "Updating system packages..."
sudo apt update -y
sudo apt upgrade -y

# 2. Install essential packages
echo "Installing dependencies: build-essential, python3, curl, nano..."
sudo apt install -y build-essential python3 curl nano

# 3. Install NVM (Node Version Manager)
echo "Installing NVM..."
curl -o- https://raw.githubusercontent.com/nvm-sh/nvm/v0.39.1/install.sh | bash

# Load NVM into the current session
export NVM_DIR="$HOME/.nvm"
[ -s "$NVM_DIR/nvm.sh" ] && \. "$NVM_DIR/nvm.sh"

# Verify installation
if ! command -v nvm >/dev/null 2>&1; then
  echo "NVM installation failed—exiting."
  exit 1
fi

# 4. Install Node.js (v18) and Node-RED
echo "Installing Node.js v18 via NVM..."
nvm install 18
nvm use 18
nvm alias default 18

echo "Installing Node-RED globally..."
npm install -g --unsafe-perm node-red

# 5. Install Node-RED extra nodes
cd "/home/$USER/.node-red" || {
  echo "Could not change directory to ~/.node-red—continuing..."
}

echo "Installing Node-RED commonly used modules..."
npm install node-red-dashboard
npm install node-red-node-serialport@2.0.3
npm install node-red-contrib-modbus
npm install node-red-contrib-mqtt-broker
npm install node-red-contrib-influxdb
npm install node-red-contrib-file

cd - >/dev/null

# 6. Create systemd service for Node-RED
echo "Setting up Node-RED as a systemd service..."
sudo tee /etc/systemd/system/node-red.service > /dev/null <<EOF
[Unit]
Description=Node-RED
After=network.target

[Service]
ExecStart=/bin/bash -lc 'nvm use 18 && node-red'
WorkingDirectory=/home/$USER
User=$USER
Group=$USER
Environment="NVM_DIR=/home/$USER/.nvm"
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable node-red.service
sudo systemctl start node-red.service

# 7. Install Tailscale
echo "Installing Tailscale..."
sudo mkdir -p /etc/apt/sources.list.d/
echo 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu focal main' \
  | sudo tee /etc/apt/sources.list.d/tailscale.list > /dev/null

curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.noarmor.gpg \
  | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null

sudo apt update
sudo apt install -y tailscale

echo "Enabling and starting tailscaled service..."
sudo systemctl enable tailscaled --now

echo "************************************************"
echo "✅ Installation complete!"
echo " Node-RED is running as a service."
echo " Installed nodes: dashboard, serialport, modbus, mqtt-broker, influxdb, file."
echo " Tailscale installed & running (use 'sudo tailscale up' to join your tailnet)."
echo " Access Node-RED editor: http://<ip>:1880"
echo " Dashboard UI: http://<ip>:1880/ui"
echo "************************************************"
