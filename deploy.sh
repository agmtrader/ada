#!/bin/bash

set -euo pipefail

read -p "Enter a name your openclaw (default: openclaw): "
NAME="${NAME:-openclaw}"

KEY_PATH="./keys/$NAME"
REGION="nyc3"
IMAGE="ubuntu-22-04-x64"
SIZE="s-2vcpu-4gb"

echo "=== 1/3 Provision droplet ==="
mkdir -p ./keys
rm -f "$KEY_PATH" "$KEY_PATH.pub"
ssh-keygen -q -t rsa -b 4096 -N "" -f "$KEY_PATH"

doctl auth init

ssh_key_id=$(doctl compute ssh-key import "$NAME" --public-key-file "${KEY_PATH}.pub" --no-header --format ID)
droplet_ip=$(doctl compute droplet create "$NAME" \
  --region "$REGION" \
  --image "$IMAGE" \
  --size "$SIZE" \
  --ssh-keys "$ssh_key_id" \
  --wait \
  --no-header \
  --format PublicIPv4)

echo "Droplet created: $droplet_ip"

echo "=== 2/3 Connect via SSH ==="
for i in {1..20}; do
  if ssh -i "$KEY_PATH" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=10 root@"$droplet_ip" "echo ssh-ok" >/dev/null 2>&1; then
    echo "SSH is ready"
    break
  fi
  echo "Waiting for SSH... ($i/20)"
  sleep 5
done

echo "=== 3/3 Install packages and Docker ==="
ssh -i "$KEY_PATH" \
  -o StrictHostKeyChecking=no \
  -o UserKnownHostsFile=/dev/null \
  root@"$droplet_ip" <<'REMOTE'
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

wait_for_apt() {
  while sudo fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1 || \
        sudo fuser /var/lib/dpkg/lock >/dev/null 2>&1 || \
        pgrep -x apt-get >/dev/null 2>&1 || \
        pgrep -x dpkg >/dev/null 2>&1; do
    echo "Waiting for apt/dpkg lock..."
    sleep 2
  done
}

wait_for_apt
sudo apt-get update
wait_for_apt
sudo apt-get install -y git python3 python3-pip ca-certificates curl gnupg

sudo install -m 0755 -d /etc/apt/keyrings
curl -fsSL https://download.docker.com/linux/ubuntu/gpg | sudo gpg --dearmor -o /etc/apt/keyrings/docker.gpg
sudo chmod a+r /etc/apt/keyrings/docker.gpg

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/ubuntu $(. /etc/os-release && echo "${UBUNTU_CODENAME:-$VERSION_CODENAME}") stable" | sudo tee /etc/apt/sources.list.d/docker.list >/dev/null

wait_for_apt
sudo apt-get update
wait_for_apt
sudo apt-get install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

docker --version
docker compose version

git clone https://github.com/openclaw/openclaw
cd openclaw

openssl rand -hex 32

cp .env.example .env

./docker-setup.sh

REMOTE

echo "Done. Droplet is ready at: $droplet_ip"
