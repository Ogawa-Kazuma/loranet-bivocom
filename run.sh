#!/bin/bash

echo "************************************************"
echo " Combined Node-RED & Tailscale Installation Script"
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

echo "Installing Node-RED nodes (node-red-node-serialport@2.0.3)..."
cd "/home/$USER/.node-red" || {
  echo "Could not change directory to ~/.node-red—continuing..."
}
npm install node-red-node-serialport@2.0.3
cd - >/dev/null

# 5. Create systemd service for Node-RED
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

# 6. Install Tailscale
echo "Installing Tailscale..."
# Add Tailscale repository
sudo mkdir -p /etc/apt/sources.list.d/
echo 'deb [signed-by=/usr/share/keyrings/tailscale-archive-keyring.gpg] https://pkgs.tailscale.com/stable/ubuntu focal main' \
  | sudo tee /etc/apt/sources.list.d/tailscale.list > /dev/null

curl -fsSL https://pkgs.tailscale.com/stable/ubuntu/focal.noarmor.gpg \
  | sudo tee /usr/share/keyrings/tailscale-archive-keyring.gpg > /dev/null

sudo apt update
sudo apt install -y tailscale

# Enable and start Tailscale daemon
echo "Enabling and starting tailscaled service..."
sudo systemctl enable tailscaled --now

# Optionally prompt user to run `tailscale up`
echo "To finalize Tailscale setup, run 'sudo tailscale up' when ready."

echo "************************************************"
echo " Installation complete! Node-RED and Tailscale are now set up."
echo " Node-RED should be running as a service."
echo " To access Node-RED: http://<your-server-ip>:1880 (within your network or via Tailscale VPN)."
echo "************************************************"
