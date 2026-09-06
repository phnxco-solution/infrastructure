#!/bin/bash
# Activate only after a real Drive download and isolated restore have been verified.
set -euo pipefail

if [ "${1:-}" != "--restore-tested" ]; then
  echo "Usage: sudo bash backups/install.sh --restore-tested"
  echo "First follow backups/README.md and complete the Drive restoration test."
  exit 1
fi
[ "$EUID" -eq 0 ] || { echo "Run this installer as root." >&2; exit 1; }
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
[ "$SCRIPT_DIR" = /opt/infrastructure/backups ] || { echo "Install from /opt/infrastructure/backups on the VPS." >&2; exit 1; }

"$SCRIPT_DIR/backup.sh" check
"$SCRIPT_DIR/backup.sh" health

install -m 644 "$SCRIPT_DIR"/systemd/* /etc/systemd/system/
systemctl daemon-reload
systemd-analyze verify /etc/systemd/system/infrastructure-app-backup*.service /etc/systemd/system/infrastructure-app-backup*.timer
systemctl enable --now infrastructure-app-backup.timer infrastructure-app-backup-upload.timer infrastructure-app-backup-health.timer
echo "App backups enabled at 03:00 Europe/Belgrade, with hourly upload retries and health checks."
