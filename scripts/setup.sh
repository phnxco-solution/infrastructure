#!/bin/bash
# VPS provisioning script — hardened for production
# Run once as root on a fresh Ubuntu 22.04+ server
# Safe to re-run (idempotent)
#
# Usage: bash /opt/infrastructure/scripts/setup.sh

set -euo pipefail

# =============================================================================
# Configuration
# =============================================================================

SSH_PORT=41922
DEPLOY_USER="deploy"
SWAP_SIZE="2G"

# Cloudflare IPv4 ranges — restrict HTTP/HTTPS to these only
# Source: https://www.cloudflare.com/ips-v4 (re-run script if these change)
CF_IPV4=(
  173.245.48.0/20
  103.21.244.0/22
  103.22.200.0/22
  103.31.4.0/22
  141.101.64.0/18
  108.162.192.0/18
  190.93.240.0/20
  188.114.96.0/20
  197.234.240.0/22
  198.41.128.0/17
  162.158.0.0/15
  104.16.0.0/13
  104.24.0.0/14
  172.64.0.0/13
  131.0.72.0/22
)

# =============================================================================
# 1. System update + packages
# =============================================================================

echo "=== System update ==="
apt update && apt upgrade -y
apt install -y curl git htop ufw fail2ban apache2-utils unattended-upgrades apt-listchanges

# =============================================================================
# 2. User provisioning
# =============================================================================

echo "=== Setup deploy user ==="
if ! id "$DEPLOY_USER" &>/dev/null; then
  adduser --disabled-password --gecos "" "$DEPLOY_USER"
  echo "Created $DEPLOY_USER user"
else
  echo "$DEPLOY_USER user already exists"
fi

# Always ensure SSH keys are correct (even on re-run)
mkdir -p /home/$DEPLOY_USER/.ssh
cp /root/.ssh/authorized_keys /home/$DEPLOY_USER/.ssh/authorized_keys
chown -R $DEPLOY_USER:$DEPLOY_USER /home/$DEPLOY_USER/.ssh
chmod 700 /home/$DEPLOY_USER/.ssh
chmod 600 /home/$DEPLOY_USER/.ssh/authorized_keys
echo "SSH authorized_keys synced from root"

# Set sudo password (skip if already set)
if passwd -S "$DEPLOY_USER" | grep -q ' P '; then
  echo "Password already set for $DEPLOY_USER — skipping"
else
  if [ -t 0 ]; then
    echo ""
    echo "Set a password for $DEPLOY_USER (used for sudo, not SSH):"
    passwd "$DEPLOY_USER"
  else
    echo "WARNING: stdin is not a TTY — skipping password prompt"
    echo "Set password manually after setup: passwd $DEPLOY_USER"
  fi
fi

# Sudo with password required (no NOPASSWD)
echo "$DEPLOY_USER ALL=(ALL:ALL) ALL" > /etc/sudoers.d/$DEPLOY_USER
chmod 440 /etc/sudoers.d/$DEPLOY_USER
echo "Sudoers configured (password required)"

# =============================================================================
# 3. Docker install + daemon config
# =============================================================================

echo "=== Install Docker ==="
if ! command -v docker &>/dev/null; then
  curl -fsSL https://get.docker.com | sh
  echo "Docker installed"
else
  echo "Docker already installed"
fi

usermod -aG docker $DEPLOY_USER

echo "=== Configure Docker daemon ==="
DAEMON_CONFIG='{
  "log-driver": "json-file",
  "log-opts": {
    "max-size": "10m",
    "max-file": "3"
  },
  "storage-driver": "overlay2"
}'

mkdir -p /etc/docker
if [ -f /etc/docker/daemon.json ] && echo "$DAEMON_CONFIG" | python3 -c "import sys,json; a=json.load(open('/etc/docker/daemon.json')); b=json.load(sys.stdin); sys.exit(0 if a==b else 1)" 2>/dev/null; then
  echo "Docker daemon config unchanged — skipping restart"
else
  echo "$DAEMON_CONFIG" > /etc/docker/daemon.json
  systemctl restart docker
  echo "Docker daemon configured and restarted"
fi

# =============================================================================
# 4. Firewall (UFW) — Cloudflare-only HTTP/HTTPS
# =============================================================================

echo "=== Configure firewall ==="
ufw default deny incoming
ufw default allow outgoing

# Allow new SSH port before any SSH changes (lockout prevention)
ufw allow $SSH_PORT/tcp

# Remove old blanket HTTP/HTTPS rules (from previous setup)
ufw delete allow 80/tcp 2>/dev/null || true
ufw delete allow 443/tcp 2>/dev/null || true
ufw delete allow "Nginx Full" 2>/dev/null || true

# Allow HTTP/HTTPS only from Cloudflare IPs
echo "Adding Cloudflare IP rules (${#CF_IPV4[@]} ranges)..."
for ip in "${CF_IPV4[@]}"; do
  # Delete then add to prevent duplicates on re-run
  ufw delete allow from "$ip" to any port 80 proto tcp 2>/dev/null || true
  ufw delete allow from "$ip" to any port 443 proto tcp 2>/dev/null || true
  ufw allow from "$ip" to any port 80 proto tcp
  ufw allow from "$ip" to any port 443 proto tcp
done

# Disable IPv6 in UFW (no IPv6 traffic expected behind Cloudflare)
sed -i 's/^IPV6=yes/IPV6=no/' /etc/default/ufw

ufw --force enable
echo "Firewall configured — SSH:$SSH_PORT, HTTP/HTTPS:Cloudflare-only"

# =============================================================================
# 5. SSH hardening
# =============================================================================

echo "=== Harden SSH ==="

# Remove conflicting drop-ins (Hostinger/cloud-init may override our settings)
rm -f /etc/ssh/sshd_config.d/50-cloud-init.conf

# Comment out Port in main config (Port is additive — both would listen)
sed -i 's/^Port /#Port /' /etc/ssh/sshd_config

# Write hardening drop-in (00 prefix = read first, wins over other drop-ins)
cat > /etc/ssh/sshd_config.d/00-hardening.conf <<EOF
Port $SSH_PORT
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
AuthenticationMethods publickey
MaxAuthTries 3
LoginGraceTime 30
AllowUsers $DEPLOY_USER
ClientAliveInterval 300
ClientAliveCountMax 2
X11Forwarding no
AllowAgentForwarding no
AllowTcpForwarding no
PermitEmptyPasswords no
Banner /etc/issue.net
EOF

# Validate before applying
if ! sshd -t; then
  echo "FATAL: sshd config validation failed — reverting"
  rm -f /etc/ssh/sshd_config.d/00-hardening.conf
  exit 1
fi

systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null

# Verify new port is listening
sleep 1
if ss -tlnp | grep -q ":$SSH_PORT "; then
  echo "SSH now listening on port $SSH_PORT"
  # Safe to remove old port 22 rule
  ufw delete allow ssh 2>/dev/null || true
  ufw delete allow 22/tcp 2>/dev/null || true
  echo "Port 22 removed from firewall"
  # Verify port 22 is no longer listening
  if ss -tlnp | grep -q ':22 '; then
    echo "WARNING: sshd is still listening on port 22 — check sshd_config for remaining Port directives"
  fi
else
  echo "FATAL: SSH not listening on port $SSH_PORT — reverting"
  ufw allow 22/tcp
  rm -f /etc/ssh/sshd_config.d/00-hardening.conf
  systemctl reload ssh 2>/dev/null || systemctl reload sshd 2>/dev/null
  exit 1
fi

# =============================================================================
# 6. fail2ban configuration
# =============================================================================

echo "=== Configure fail2ban ==="
cat > /etc/fail2ban/jail.local <<EOF
[DEFAULT]
bantime = 3600
findtime = 600
maxretry = 3
banaction = ufw
ignoreip = 127.0.0.1/8

[sshd]
enabled = true
port = $SSH_PORT
logpath = /var/log/auth.log
maxretry = 3

[recidive]
enabled = true
logpath = /var/log/fail2ban.log
banaction = ufw
bantime = 604800
findtime = 86400
maxretry = 3
EOF

systemctl restart fail2ban
echo "fail2ban configured — SSH jail on port $SSH_PORT, recidive enabled"

# =============================================================================
# 7. Kernel hardening (sysctl)
# =============================================================================

echo "=== Kernel hardening ==="
cat > /etc/sysctl.d/99-hardening.conf <<'EOF'
# SYN flood protection
net.ipv4.tcp_syncookies = 1
net.ipv4.tcp_max_syn_backlog = 2048
net.ipv4.tcp_synack_retries = 2
net.ipv4.tcp_syn_retries = 5

# IP spoofing protection
net.ipv4.conf.all.rp_filter = 1
net.ipv4.conf.default.rp_filter = 1

# Ignore ICMP redirects (prevent MITM)
net.ipv4.conf.all.accept_redirects = 0
net.ipv4.conf.default.accept_redirects = 0
net.ipv4.conf.all.send_redirects = 0
net.ipv4.conf.default.send_redirects = 0

# Disable source routing
net.ipv4.conf.all.accept_source_route = 0
net.ipv4.conf.default.accept_source_route = 0

# Log martian packets (spoofed/misrouted)
net.ipv4.conf.all.log_martians = 1
net.ipv4.conf.default.log_martians = 1

# Ignore ICMP echo broadcasts (smurf attack prevention)
net.ipv4.icmp_echo_ignore_broadcasts = 1

# Ignore bogus ICMP error responses
net.ipv4.icmp_ignore_bogus_error_responses = 1

# Swap
vm.swappiness = 10
EOF

sysctl --system > /dev/null
echo "Kernel hardening applied"

# =============================================================================
# 8. Directory structure + permissions
# =============================================================================

echo "=== Create directory structure ==="
mkdir -p /opt/{infrastructure,volumes/{mysql,redis,uptime-kuma},backups/{mysql,volumes}}
mkdir -p /opt/volumes/apps

# Targeted ownership (don't touch volume internals — containers manage their own UIDs)
chown -R $DEPLOY_USER:$DEPLOY_USER /opt/infrastructure /opt/backups
chown $DEPLOY_USER:$DEPLOY_USER /opt/volumes /opt/volumes/apps
chmod 750 /opt/infrastructure /opt/backups
chmod 700 /opt/volumes

# =============================================================================
# 9. Docker networks
# =============================================================================

echo "=== Create Docker networks ==="
docker network create traefik-public 2>/dev/null || echo "traefik-public network already exists"
docker network create backend 2>/dev/null || echo "backend network already exists"

# =============================================================================
# 10. Swap
# =============================================================================

echo "=== Setup swap ($SWAP_SIZE) ==="
if [ ! -f /swapfile ]; then
  fallocate -l $SWAP_SIZE /swapfile
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  grep -q '/swapfile' /etc/fstab || echo '/swapfile none swap sw 0 0' >> /etc/fstab
  echo "Swap configured"
else
  echo "Swap already exists"
fi
sysctl vm.swappiness=10 > /dev/null

# =============================================================================
# 11. Automatic security updates
# =============================================================================

echo "=== Configure automatic security updates ==="
cat > /etc/apt/apt.conf.d/20auto-upgrades <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF

cat > /etc/apt/apt.conf.d/50unattended-upgrades <<'EOF'
Unattended-Upgrade::Allowed-Origins {
    "${distro_id}:${distro_codename}-security";
    "${distro_id}ESMApps:${distro_codename}-apps-security";
    "${distro_id}ESM:${distro_codename}-infra-security";
};
Unattended-Upgrade::AutoFixInterruptedDpkg "true";
Unattended-Upgrade::Remove-Unused-Dependencies "true";
Unattended-Upgrade::Automatic-Reboot "false";
EOF

systemctl enable unattended-upgrades --quiet 2>/dev/null
systemctl restart unattended-upgrades
echo "Automatic security updates enabled (no auto-reboot)"

# =============================================================================
# 12. Service hardening + cleanup
# =============================================================================

echo "=== Service hardening ==="

# Restrict cron access
echo -e "root\n$DEPLOY_USER" > /etc/cron.allow
chmod 600 /etc/cron.allow
echo "Cron restricted to root and $DEPLOY_USER"

# Disable snapd (wastes RAM on a Docker server)
systemctl disable --now snapd.service 2>/dev/null || true
systemctl disable --now snapd.socket 2>/dev/null || true
systemctl disable --now snapd.seeded.service 2>/dev/null || true

# Secure shared memory
if ! grep -q '/run/shm' /etc/fstab; then
  echo 'tmpfs /run/shm tmpfs defaults,noexec,nosuid 0 0' >> /etc/fstab
fi

# Login banner
cat > /etc/issue.net <<'EOF'
Authorized access only. All activity is monitored and logged.
EOF

# =============================================================================
# 13. Cron jobs
# =============================================================================

echo "=== Setup crontab for $DEPLOY_USER ==="
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
echo "$CRON_CONTENT" | crontab -u $DEPLOY_USER -

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "==========================================="
echo "  Setup complete — hardened for production"
echo "==========================================="
echo ""
echo "  SSH port:  $SSH_PORT"
echo "  User:      $DEPLOY_USER (sudo with password)"
echo "  Firewall:  SSH:$SSH_PORT + HTTP/HTTPS:Cloudflare-only"
echo "  fail2ban:  SSH jail + recidive"
echo "  Updates:   Automatic security patches"
echo ""
echo "  Next steps:"
echo "    1. Test SSH:  ssh -p $SSH_PORT $DEPLOY_USER@<server-ip>"
echo "    2. Update GitHub Actions VPS_PORT secret to $SSH_PORT"
echo "    3. Create .env from .env.example and fill in secrets"
echo "    4. Add Cloudflare Origin Certificate to traefik/certs/"
echo "    5. Run: cd /opt/infrastructure && docker compose up -d"
echo ""
