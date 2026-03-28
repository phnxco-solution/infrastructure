#!/bin/bash
# Verify VPS provisioning — run as deploy user after setup.sh
# Usage: bash /opt/infrastructure/scripts/verify-setup.sh

set -uo pipefail

SSH_PORT=41922
DEPLOY_USER="deploy"

PASS=0
FAIL=0
WARN=0

pass() { echo "  ✓ $1"; ((PASS++)); }
fail() { echo "  ✗ $1"; ((FAIL++)); }
warn() { echo "  ! $1"; ((WARN++)); }

check() {
  if eval "$1" &>/dev/null; then
    pass "$2"
  else
    fail "$2"
  fi
}

# =============================================================================
echo "=== User & Sudo ==="
# =============================================================================

check "id $DEPLOY_USER" "$DEPLOY_USER user exists"
check "groups $DEPLOY_USER | grep -q docker" "$DEPLOY_USER is in docker group"
check "test -f /home/$DEPLOY_USER/.ssh/authorized_keys && test -s /home/$DEPLOY_USER/.ssh/authorized_keys" "SSH authorized_keys exists and is non-empty"

# Check permissions
if [ "$(stat -c '%a' /home/$DEPLOY_USER/.ssh 2>/dev/null)" = "700" ]; then
  pass ".ssh directory is 700"
else
  fail ".ssh directory is not 700"
fi

if [ "$(stat -c '%a' /home/$DEPLOY_USER/.ssh/authorized_keys 2>/dev/null)" = "600" ]; then
  pass "authorized_keys is 600"
else
  fail "authorized_keys is not 600"
fi

# Sudoers — password required (no NOPASSWD)
if [ -f /etc/sudoers.d/$DEPLOY_USER ]; then
  if grep -q 'NOPASSWD' /etc/sudoers.d/$DEPLOY_USER; then
    fail "Sudoers has NOPASSWD — password not required for sudo"
  else
    pass "Sudoers requires password for sudo"
  fi
else
  fail "Sudoers file missing for $DEPLOY_USER"
fi

# Check password is set
if passwd -S "$DEPLOY_USER" 2>/dev/null | grep -q ' P '; then
  pass "$DEPLOY_USER has a password set (for sudo)"
else
  fail "$DEPLOY_USER has no password — sudo will not work"
fi

# =============================================================================
echo ""
echo "=== SSH ==="
# =============================================================================

# Port
if ss -tlnp | grep -q ":$SSH_PORT "; then
  pass "sshd listening on port $SSH_PORT"
else
  fail "sshd NOT listening on port $SSH_PORT"
fi

if ss -tlnp | grep -q ':22 '; then
  fail "sshd still listening on port 22"
else
  pass "Port 22 is closed"
fi

# Drop-in config
if [ -f /etc/ssh/sshd_config.d/00-hardening.conf ]; then
  pass "SSH hardening drop-in exists (00-hardening.conf)"

  check "grep -q 'PermitRootLogin no' /etc/ssh/sshd_config.d/00-hardening.conf" "Root login disabled"
  check "grep -q 'PasswordAuthentication no' /etc/ssh/sshd_config.d/00-hardening.conf" "Password authentication disabled"
  check "grep -q 'AllowUsers' /etc/ssh/sshd_config.d/00-hardening.conf" "AllowUsers is set"
  check "grep -q 'MaxAuthTries 3' /etc/ssh/sshd_config.d/00-hardening.conf" "MaxAuthTries is 3"
  check "grep -q 'X11Forwarding no' /etc/ssh/sshd_config.d/00-hardening.conf" "X11 forwarding disabled"
else
  fail "SSH hardening drop-in missing"
fi

# Cloud-init conflict
if [ -f /etc/ssh/sshd_config.d/50-cloud-init.conf ]; then
  warn "50-cloud-init.conf exists — may override SSH hardening"
else
  pass "No conflicting cloud-init SSH config"
fi

# sshd config valid
if sshd -t 2>/dev/null; then
  pass "sshd config is valid"
else
  fail "sshd config has errors (run: sshd -t)"
fi

# Login banner
check "test -f /etc/issue.net && test -s /etc/issue.net" "Login banner configured"

# =============================================================================
echo ""
echo "=== Firewall (UFW) ==="
# =============================================================================

check "ufw status | grep -q 'Status: active'" "UFW is active"
check "ufw status | grep -q '$SSH_PORT/tcp'" "SSH port $SSH_PORT allowed"

# Port 22 should NOT be in UFW
if ufw status | grep -qE '22/tcp|OpenSSH'; then
  fail "Port 22 still allowed in UFW"
else
  pass "Port 22 removed from UFW"
fi

# Blanket 80/443 should NOT exist
if ufw status | grep -E '80/tcp\s+ALLOW\s+Anywhere|443/tcp\s+ALLOW\s+Anywhere' | grep -v 'ALLOW' | grep -q .; then
  # This won't match, so check differently
  :
fi

# Check for blanket rules (no source IP restriction)
HAS_BLANKET=false
while IFS= read -r line; do
  if echo "$line" | grep -qE '(80|443)/tcp' && echo "$line" | grep -q 'ALLOW' && ! echo "$line" | grep -qE '[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+'; then
    HAS_BLANKET=true
    break
  fi
done < <(ufw status)

if $HAS_BLANKET; then
  fail "Blanket HTTP/HTTPS rules exist (should be Cloudflare-only)"
else
  pass "No blanket HTTP/HTTPS rules — Cloudflare-only"
fi

# Count Cloudflare rules
CF_RULE_COUNT=$(ufw status | grep -cE '(80|443).*ALLOW' || true)
if [ "$CF_RULE_COUNT" -ge 30 ]; then
  pass "Cloudflare IP rules present ($CF_RULE_COUNT rules)"
else
  warn "Expected 30+ Cloudflare rules, found $CF_RULE_COUNT"
fi

# IPv6 disabled in UFW
if grep -q '^IPV6=no' /etc/default/ufw; then
  pass "IPv6 disabled in UFW"
else
  fail "IPv6 still enabled in UFW"
fi

# =============================================================================
echo ""
echo "=== fail2ban ==="
# =============================================================================

check "systemctl is-active --quiet fail2ban" "fail2ban is running"

if [ -f /etc/fail2ban/jail.local ]; then
  pass "jail.local exists"
  check "grep -q 'port = $SSH_PORT' /etc/fail2ban/jail.local" "SSH jail on port $SSH_PORT"
  check "grep -q 'banaction = ufw' /etc/fail2ban/jail.local" "Ban action uses UFW"
  check "grep -q '\\[recidive\\]' /etc/fail2ban/jail.local" "Recidive jail configured"
else
  fail "jail.local missing — fail2ban using defaults"
fi

if fail2ban-client status sshd &>/dev/null; then
  pass "SSH jail is active"
else
  fail "SSH jail is not active"
fi

# =============================================================================
echo ""
echo "=== Kernel Hardening ==="
# =============================================================================

check "[ \"$(sysctl -n net.ipv4.tcp_syncookies 2>/dev/null)\" = '1' ]" "SYN cookies enabled"
check "[ \"$(sysctl -n net.ipv4.conf.all.rp_filter 2>/dev/null)\" = '1' ]" "IP spoofing protection (rp_filter)"
check "[ \"$(sysctl -n net.ipv4.conf.all.accept_redirects 2>/dev/null)\" = '0' ]" "ICMP redirects ignored"
check "[ \"$(sysctl -n net.ipv4.conf.all.send_redirects 2>/dev/null)\" = '0' ]" "Send redirects disabled"
check "[ \"$(sysctl -n net.ipv4.conf.all.accept_source_route 2>/dev/null)\" = '0' ]" "Source routing disabled"
check "[ \"$(sysctl -n net.ipv4.conf.all.log_martians 2>/dev/null)\" = '1' ]" "Martian packet logging"
check "[ \"$(sysctl -n net.ipv4.icmp_echo_ignore_broadcasts 2>/dev/null)\" = '1' ]" "ICMP broadcast ignored"
check "[ \"$(sysctl -n vm.swappiness 2>/dev/null)\" = '10' ]" "Swappiness is 10"

check "test -f /etc/sysctl.d/99-hardening.conf" "Sysctl drop-in file exists"

# =============================================================================
echo ""
echo "=== Docker ==="
# =============================================================================

check "systemctl is-active --quiet docker" "Docker daemon is running"
check "docker info &>/dev/null" "Docker is accessible"
check "test -f /etc/docker/daemon.json" "Docker daemon.json exists"

# Logging config
if docker info 2>/dev/null | grep -q 'json-file'; then
  pass "Docker log driver: json-file"
else
  warn "Docker log driver is not json-file"
fi

# Networks
check "docker network inspect traefik-public &>/dev/null" "traefik-public network exists"
check "docker network inspect backend &>/dev/null" "backend network exists"

# =============================================================================
echo ""
echo "=== Directory Structure ==="
# =============================================================================

for dir in /opt/infrastructure /opt/volumes /opt/volumes/mysql /opt/volumes/redis /opt/volumes/uptime-kuma /opt/volumes/apps /opt/backups /opt/backups/mysql /opt/backups/volumes; do
  check "test -d $dir" "$dir exists"
done

# Permissions
INFRA_OWNER=$(stat -c '%U' /opt/infrastructure 2>/dev/null)
if [ "$INFRA_OWNER" = "$DEPLOY_USER" ]; then
  pass "/opt/infrastructure owned by $DEPLOY_USER"
else
  fail "/opt/infrastructure owned by $INFRA_OWNER (expected $DEPLOY_USER)"
fi

VOL_PERMS=$(stat -c '%a' /opt/volumes 2>/dev/null)
if [ "$VOL_PERMS" = "700" ]; then
  pass "/opt/volumes permissions: 700"
else
  warn "/opt/volumes permissions: $VOL_PERMS (expected 700)"
fi

# =============================================================================
echo ""
echo "=== Swap ==="
# =============================================================================

if swapon --show | grep -q '/swapfile'; then
  SWAP_SIZE=$(swapon --show --bytes --noheadings | awk '{print $3}')
  SWAP_GB=$((SWAP_SIZE / 1024 / 1024 / 1024))
  pass "Swap active (${SWAP_GB}G)"
else
  fail "No swap active"
fi

check "grep -q '/swapfile' /etc/fstab" "Swap in fstab (persistent)"

# =============================================================================
echo ""
echo "=== Automatic Updates ==="
# =============================================================================

check "systemctl is-active --quiet unattended-upgrades" "unattended-upgrades is running"
check "test -f /etc/apt/apt.conf.d/20auto-upgrades" "Auto-upgrades config exists"
check "test -f /etc/apt/apt.conf.d/50unattended-upgrades" "Unattended-upgrades config exists"

if grep -q 'Automatic-Reboot "false"' /etc/apt/apt.conf.d/50unattended-upgrades 2>/dev/null; then
  pass "Auto-reboot disabled"
else
  warn "Auto-reboot may be enabled — check 50unattended-upgrades"
fi

# =============================================================================
echo ""
echo "=== Service Hardening ==="
# =============================================================================

# Cron access
if [ -f /etc/cron.allow ]; then
  pass "cron.allow restricts cron access"
  check "grep -q '$DEPLOY_USER' /etc/cron.allow" "$DEPLOY_USER in cron.allow"
else
  warn "No cron.allow — all users can use cron"
fi

# Snapd
if systemctl is-active --quiet snapd 2>/dev/null; then
  warn "snapd is still running (wastes RAM)"
else
  pass "snapd is disabled"
fi

# Shared memory
check "grep -q '/run/shm' /etc/fstab" "Shared memory hardened in fstab"

# =============================================================================
echo ""
echo "=== Cron Jobs ==="
# =============================================================================

CRONTAB=$(crontab -u $DEPLOY_USER -l 2>/dev/null || true)
if [ -n "$CRONTAB" ]; then
  pass "Crontab configured for $DEPLOY_USER"
  check "echo '$CRONTAB' | grep -q 'backup.sh'" "MySQL backup cron present"
  check "echo '$CRONTAB' | grep -q 'volume-backup.sh'" "Volume backup cron present"
  check "echo '$CRONTAB' | grep -q 'docker image prune'" "Docker cleanup cron present"
  check "echo '$CRONTAB' | grep -q 'slow.log'" "MySQL slow log rotation present"
  check "echo '$CRONTAB' | grep -q 'app-.*\\.log'" "App log cleanup cron present"
else
  fail "No crontab for $DEPLOY_USER"
fi

# =============================================================================
# Summary
# =============================================================================

echo ""
echo "==========================================="
TOTAL=$((PASS + FAIL + WARN))
echo "  Results: $PASS passed, $FAIL failed, $WARN warnings (of $TOTAL checks)"
echo "==========================================="

if [ "$FAIL" -gt 0 ]; then
  echo ""
  echo "  FAILED — fix the issues above before going live"
  exit 1
elif [ "$WARN" -gt 0 ]; then
  echo ""
  echo "  PASSED with warnings — review items above"
  exit 0
else
  echo ""
  echo "  ALL CLEAR — VPS is hardened and ready"
  exit 0
fi
