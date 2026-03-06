#!/bin/bash
# VPS provisioning script — run once as root on a fresh server
# Usage: bash /opt/infrastructure/scripts/setup.sh

set -euo pipefail

echo "=== System update ==="
apt update && apt upgrade -y
apt install -y curl git htop ufw fail2ban apache2-utils

echo "=== Create deploy user ==="
if ! id "deploy" &>/dev/null; then
  adduser --disabled-password --gecos "" deploy
  cp -r /root/.ssh /home/deploy/.ssh
  chown -R deploy:deploy /home/deploy/.ssh
  chmod 700 /home/deploy/.ssh
  chmod 600 /home/deploy/.ssh/*
  chmod 644 /home/deploy/.ssh/*.pub 2>/dev/null || true
  echo "deploy ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/deploy
  echo "Created deploy user with SSH key from root"
else
  echo "deploy user already exists"
fi

echo "=== Configure firewall ==="
ufw default deny incoming
ufw default allow outgoing
ufw allow ssh
ufw allow 80/tcp
ufw allow 443/tcp
ufw --force enable

echo "=== Install Docker ==="
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  echo "Docker installed"
else
  echo "Docker already installed"
fi
usermod -aG docker deploy

echo "=== Configure Docker daemon ==="
mkdir -p /etc/docker
cat > /etc/docker/daemon.json <<'DAEMON'
{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}
DAEMON
systemctl restart docker

echo "=== Create directory structure ==="
mkdir -p /opt/{infrastructure,volumes/{mysql,redis,uptime-kuma},backups/{mysql,volumes}}
mkdir -p /opt/volumes/apps
chown -R deploy:deploy /opt

echo "=== Create Docker networks ==="
docker network create traefik-public 2>/dev/null || echo "traefik-public network already exists"
docker network create backend 2>/dev/null || echo "backend network already exists"

echo "=== Setup swap (2GB) ==="
if [ ! -f /swapfile ]; then
  fallocate -l 2G /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
  sysctl vm.swappiness=10
  echo 'vm.swappiness=10' >> /etc/sysctl.conf
  echo "Swap configured"
else
  echo "Swap already exists"
fi

echo "=== Harden SSH ==="
sed -i 's/#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sed -i 's/#\?PermitRootLogin .*/PermitRootLogin no/' /etc/ssh/sshd_config
systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null

echo "=== Setup crontab for deploy user ==="
CRON_CONTENT=$(cat <<'CRON'
# Daily MySQL backup at 3 AM
0 3 * * * /opt/infrastructure/backups/backup.sh >> /opt/backups/mysql/backup.log 2>&1

# Weekly volume backup on Sunday at 4 AM
0 4 * * 0 /opt/infrastructure/backups/volume-backup.sh >> /opt/backups/volumes/backup.log 2>&1

# Weekly Docker cleanup on Sunday at 5 AM
0 5 * * 0 docker image prune -af --filter "until=168h" >> /var/log/docker-prune.log 2>&1

# Weekly MySQL slow log truncation on Sunday at 2:30 AM
30 2 * * 0 docker exec mysql sh -c 'cat /dev/null > /var/lib/mysql/slow.log' 2>/dev/null

# Daily cleanup of old app log files (14-day retention)
0 2 * * * find /opt/volumes/apps/*/logs -name "app-*.log" -mtime +14 -delete 2>/dev/null
CRON
)
echo "$CRON_CONTENT" | crontab -u deploy -

echo ""
echo "=== Setup complete ==="
echo "Next steps:"
echo "  1. Log out and log back in as: ssh deploy@<server-ip>"
echo "  2. Create .env from .env.example and fill in secrets"
echo "  3. Add Cloudflare Origin Certificate to traefik/certs/"
echo "  4. Run: cd /opt/infrastructure && docker compose up -d"
