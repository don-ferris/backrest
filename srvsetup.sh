#!/bin/bash
# SrvSetup - Install Git and SSH keys, clone this repo, ensure .bashrc sources .aliases, optionally run fixnano, set hostname/IP, and optionally install Docker.
# ──────────────────────────────────────────────────────
# Author: Don Ferris
# Created: [18-10-2025]
# Current Revision: v1.1
# ──────────────────────────────────────────────────────

########

set -euo pipefail

echo -e "\n🔧 Starting server setup routine…"

# ┌────────────────────────────────────────────────────────────┐
# │  Step 1: Install latest Git                                │
# └────────────────────────────────────────────────────────────┘
echo -e "\n📦 Installing latest Git…"
apt update && apt install -y git

# ┌────────────────────────────────────────────────────────────┐
# │  Step 2: Copy GitHub SSH keys                              │
# └────────────────────────────────────────────────────────────┘
echo -e "\n🔑 Copying GitHub SSH keys to ~/.ssh…"
mkdir -p ~/.ssh
cp -v /root/github-keys/id_rsa ~/.ssh/id_rsa
cp -v /root/github-keys/id_rsa.pub ~/.ssh/id_rsa.pub
chmod 600 ~/.ssh/id_rsa
chmod 644 ~/.ssh/id_rsa.pub
eval "$(ssh-agent -s)"
ssh-add ~/.ssh/id_rsa

# ┌────────────────────────────────────────────────────────────┐
# │  Step 3: Clone bash-scripts repo                           │
# └────────────────────────────────────────────────────────────┘
echo -e "\n📥 Cloning bash-scripts repo…"
git clone git@github.com:don-ferris/bash-scripts.git

# ┌────────────────────────────────────────────────────────────┐
# │  Step 4: Move repo to ~/scripts                            │
# └────────────────────────────────────────────────────────────┘
echo -e "\n📂 Moving bash-scripts to ~/scripts…"
rm -rf ~/scripts
mv -v bash-scripts ~/scripts

# ┌────────────────────────────────────────────────────────────┐
# │  Step 5: Ensure .bashrc sources .aliases                   │
# └────────────────────────────────────────────────────────────┘
echo -e "\n🧩 Ensuring .bashrc sources .aliases…"
grep -qxF 'source .aliases' ~/.bashrc || echo 'source .aliases' >> ~/.bashrc

# ┌────────────────────────────────────────────────────────────┐
# │  Step 6: Run fixnano.sh                                    │
# └────────────────────────────────────────────────────────────┘
echo -e "\n🛠️ Running fixnano.sh…"
bash ~/scripts/fixnano.sh

# ┌────────────────────────────────────────────────────────────┐
# │  Step 7: Ask to set hostname                               │
# └────────────────────────────────────────────────────────────┘
echo -e "\n🖥️ Do you want to set a new hostname? (y/n)"
read -r hostname_choice

if [[ "$hostname_choice" == "y" || "$hostname_choice" == "Y" ]]; then
  echo -e "\n🔤 Enter new hostname:"
  read -r new_hostname
  echo -e "\n📛 Setting hostname to '$new_hostname'…"
  hostnamectl set-hostname "$new_hostname"
else
  echo -e "\n🚫 Skipping hostname change."
fi

# ┌────────────────────────────────────────────────────────────┐
# │  Step 8: Ask to set static IP                              │
# └────────────────────────────────────────────────────────────┘
echo -e "\n🌐 Do you want to set a static IP address? (y/n)"
read -r ip_choice

if [[ "$ip_choice" == "y" || "$ip_choice" == "Y" ]]; then
  echo -e "\n📡 Running set_static_ip.sh…"
  bash ~/scripts/set_static_ip.sh
else
  echo -e "\n🚫 Skipping static IP configuration."
fi

# ┌────────────────────────────────────────────────────────────┐
# │  Step 9: Ask to install Docker                             │
# └────────────────────────────────────────────────────────────┘
echo -e "\n🐳 Do you want to install Docker? (y/n)"
read -r docker_choice

if [[ "$docker_choice" == "y" || "$docker_choice" == "Y" ]]; then
  echo -e "\n📦 Installing latest Docker…"
  apt install -y ca-certificates curl gnupg
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/ubuntu/gpg | \
    gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo \
    "deb [arch=$(dpkg --print-architecture) \
    signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/ubuntu \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" | \
    tee /etc/apt/sources.list.d/docker.list > /dev/null
  apt update
  apt install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  echo -e "\n📁 Creating ~/docker directory…"
  mkdir -p ~/docker
else
  echo -e "\n🚫 Skipping Docker installation."
fi

echo -e "\n✅ Server setup complete. Welcome aboard, Captain.\n"
