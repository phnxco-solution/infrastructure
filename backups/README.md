# App backups and recovery

The backup system captures the configured apps' databases, `storage/` files and app-specific configuration while apps and workers stay online. It excludes shared infrastructure, Redis, Uptime Kuma, infrastructure secrets/certificates, app logs and rebuildable Laravel caches. It never restores Redis. `phnx-solution` is intentionally excluded from the backup app list at the user's request; its deployment remains in this repository.

Every successful run produces one independent `.tar.gz.age` archive per app and immediately uploads the whole set to Google Drive. The newest **two complete sets** remain on the VPS. Older local sets are removed only after verifying their remote copy. Pending uploads and restore safety archives are never automatically deleted. **There is no Drive deletion, synchronization or retention job.**

Invoking `backup.sh` without arguments runs the same capture and upload workflow as `backup.sh run`. Complete the one-time setup below to configure Google Drive and enable automatic backups.

## Layout and timing

```text
Google Drive: Infrastructure Backups/production-vps/
VPS:         /opt/backups/apps/sets/
└── 2026/09/06/20260906T010000Z-a7b219e3/
    ├── apps/
    │   ├── mega-catering__20260906T010000Z-a7b219e3.tar.gz.age
    │   └── ...one archive per app...
    ├── manifest.json
    ├── SHA256SUMS
    └── COMPLETE
```

Year/month/day folders use **Europe/Belgrade**. Run IDs use UTC with a random suffix to distinguish manual runs. The readable manifest includes local time, database names, sizes and ciphertext checksums, never credentials. Each encrypted archive also includes its own manifest and checksums, so a single manually downloaded archive is enough to unpack.

The nightly timer runs at **03:00 Europe/Belgrade**, including seasonal clock changes. Upload retry and health timers run hourly. Health checks report backups older than 26 hours, low VPS disk space and Drive usage at or above 80%. Drive usage is shared with the account's other data: no cleanup means eventual growth to the account limit. At 5 GB/day, 1 TB lasts roughly 200 days before accounting for other files.

Apps are never paused for capture. InnoDB dumps use `--single-transaction`; concurrent schema migrations must be avoided. Files changing during copying are retried, then fail the run rather than being silently omitted. SQL and files are **not an atomic snapshot** of one moment. Symlinks and special files inside storage/configuration are rejected. Only the declared app storage is backed up; additional persistent paths need explicit support.

## One-time setup on the VPS

Run production commands as root via `sudo`: container-owned volumes and app secrets require it. Plaintext staging and backup state are private, and staging is removed after completion or ordinary failures. Do not print configuration files or credentials into logs.

1. Install Python 3.10+, `age`/`age-keygen` and timezone data with `sudo apt install python3 age tzdata`. Install the **current stable rclone release** using [rclone's official Linux installation instructions](https://rclone.org/install/#linux-installation), and confirm it with `rclone version`. [Ubuntu 22.04's packaged rclone](https://packages.ubuntu.com/en/jammy/net/rclone) is 1.53.3; its headless Google authorization flow predates the [OAuth change in rclone 1.58](https://rclone.org/changelog/#v1-58-0-2022-03-18). Use Docker with Compose v2 and the existing authenticated installation for app images.
2. On your own computer, run `age-keygen -o recovery-key.txt`, then `age-keygen -y recovery-key.txt` to display the public recipient. Save the private key in your password manager, with an independent recovery copy. Put **only the public recipient** on the VPS. Restoring requires exporting the private key temporarily; backups do not require it.
3. Create a dedicated Google OAuth **Desktop app** client and enable the Google Drive API using [rclone's Drive setup](https://rclone.org/drive/#making-your-own-client-id). Supply your own client ID and secret; the shared rclone client ID is being retired. Select the `drive.file` scope to limit access to rclone-created files. These files remain browsable/downloadable in Drive; files uploaded through the browser are not visible to that limited token. The local `--file` workflow handles archives transferred to the VPS manually. For an External OAuth app, publish it to **Production before authorization**: Testing refresh tokens for Drive expire after seven days, per [Google's token policy](https://developers.google.com/identity/protocols/oauth2#expiration).

When `rclone config` on the VPS asks to open a browser, answer **N**. Run the exact `rclone authorize` command it supplies on your own computer with the same rclone version, complete Google sign-in there, and paste the returned token directly into the VPS prompt. See [rclone's headless setup](https://rclone.org/remote_setup/#configuring-using-rclone-authorize). Name the remote `gdrive` to match the example configuration. Keep authorization tokens out of shared logs.

```bash
sudo install -d -m 755 /etc/infrastructure-backup
sudo rclone config --config /etc/infrastructure-backup/rclone.conf
sudo chmod 600 /etc/infrastructure-backup/rclone.conf
sudo rclone mkdir 'gdrive:Infrastructure Backups' \
  --config /etc/infrastructure-backup/rclone.conf
sudo install -m 600 /opt/infrastructure/backups/config.example.json \
  /etc/infrastructure-backup/config.json
```

Edit `/etc/infrastructure-backup/config.json`: set the public recipient, remote name/path, server label and selected apps. The `apps` mapping is a required, nonempty inclusion list: only listed apps are captured, and a listed app must have an existing Compose file. Removing an app from this mapping excludes it; new app directories are not automatically included. The app database is discovered from Compose's resolved `DB_DATABASE`, `DB_NAME` or MySQL `DATABASE_URL` environment, without printing secrets. Explicit `database` overrides accept a name or `null`. Every non-system MySQL database must map to exactly one selected app; unmapped/shared databases fail preflight. An included app without a database still gets its storage/config archive. Omitting a database-backed app does not bypass database coverage checks.

When adding a project, add its entry to both `backups/config.example.json` and the active VPS configuration, or ask the user for a backup decision and document any explicit exclusion in the app's README. Preserve the active configuration's recipients, Drive destination and other settings. A Git pull only updates the template; it does not change `/etc/infrastructure-backup/config.json`. After provisioning the app's database and storage, run `backups/backup.sh check` and verify that the first uploaded set contains the new app.

Owners default to `82:82` for Laravel and `1000:1000` for Node. The example pins owners for current apps. These numeric IDs are used for restored storage, never a username inferred from the host. `config_files` defaults to `.env`, `docker-compose.yml`, and `nginx.conf` if present; optional `excludes` extend the built-in storage exclusions.

4. Put a Slack-compatible HTTPS webhook URL into `/etc/infrastructure-backup/alert-webhook.txt`, mode `600`. Alternatively remove `alert_webhook_file` to use stderr/journald only. Alerts are not delivered until an endpoint is configured. The health timer runs on the VPS; use external monitoring as well if you need notification when the VPS itself is unavailable.
5. Validate and make the first backup:

```bash
cd /opt/infrastructure
sudo ./backups/backup.sh check
sudo ./backups/backup.sh run
sudo ./backups/backup.sh list --source drive
sudo ./backups/backup.sh health
```

6. Download and unpack a real Drive archive. On a disposable test server, perform an actual database/file restoration and application check. `restore --verify-only` validates the archive and target but does **not** prove SQL imports or that the app works. Do not activate the timers until that recovery test passes.
7. Activate with `sudo ./backups/install.sh --restore-tested`. The installer validates configuration and current backup health, then installs, verifies and enables the backup, upload retry and health timers. Run `scripts/verify-setup.sh` to check that all three timers are enabled and active.

## Commands

All commands accept `--config /path/to/config.json`. Local is the default source. Use `list` to copy the exact run ID; omitted `--run` means `latest` for download/unpack/restore. `list` can filter `--date YYYY-MM-DD` and `--app NAME`.

```bash
# Create and immediately upload all app backups; retry pending uploads separately
sudo ./backups/backup.sh run
sudo ./backups/backup.sh upload

# Browse local or Drive sets
sudo ./backups/backup.sh list
sudo ./backups/backup.sh list --source drive --date 2026-09-06 --app mega-catering

# Download just one encrypted archive; destination must not already exist
sudo ./backups/backup.sh download --source drive --app mega-catering \
  --run 20260906T010000Z-a7b219e3 --to /tmp/mega-catering.tar.gz.age

# Unpack a manually downloaded file; no Google authorization or live database required
./backups/backup.sh unpack --file /tmp/mega-catering.tar.gz.age \
  --identity /secure/recovery-key.txt --to /tmp/recovered-app

# Download from Drive, decrypt, verify and unpack in one command
sudo ./backups/backup.sh unpack --source drive --app mega-catering \
  --run 20260906T010000Z-a7b219e3 --identity /secure/recovery-key.txt \
  --to /tmp/recovered-app

# Validate a restore without stopping services or modifying live data
sudo ./backups/backup.sh restore --app mega-catering --run latest \
  --identity /secure/recovery-key.txt --verify-only

# Restore the newest local backup, or select a specific Drive backup
sudo ./backups/backup.sh restore --app mega-catering \
  --identity /secure/recovery-key.txt
sudo ./backups/backup.sh restore --source drive --app mega-catering \
  --run 20260906T010000Z-a7b219e3 --identity /secure/recovery-key.txt

# Restore an independent archive uploaded manually to the VPS (including a safety archive)
sudo ./backups/backup.sh restore --app mega-catering --file /tmp/backup.tar.gz.age \
  --identity /secure/recovery-key.txt
```

`BACKUP_IDENTITY_FILE` can supply the identity path instead of `--identity`. The destination parent for download/unpack must exist and must not be a symlink; the destination itself must not exist. An incomplete remote set is never offered in listings. A manually supplied archive is decrypted and validated against its internal manifest without requiring sidecar files.

## Applying a restore

`unpack` only extracts into a new private directory. `restore` explicitly targets one app, verifies its database mapping and recorded container image IDs, and asks the operator to type `RESTORE <app>`. There is no unattended bypass for replacing live data.

After confirmation, restore stops **all services in that app's Compose project**, including Laravel app, queue/Horizon workers, scheduler and nginx. Services waiting for an automatic restart count as active; already stopped services stay stopped after recovery. Paused/removing or unknown orphan containers must be resolved before restoring. This deliberately uses the agreed stop option for Laravel as well as Node; Laravel maintenance mode alone would not stop workers. Configured shutdown grace periods are respected, including long-running Horizon jobs. Other Compose projects, MySQL and Redis stay running.

An encrypted safety archive of the selected app's current data is made after it stops. The selected database is recreated with its original charset/collation and imported, and storage is replaced rather than merged. Current operational logs are preserved; Laravel runtime directories are recreated. App configuration is preserved unless `--with-config` is explicitly given. That option validates the proposed configuration before stopping services: database connections and the resolved service/image/mount topology must stay the same. Configuration that moves data or changes the app deployment must be unpacked and reviewed separately. The Compose project stays fixed to the app name, and recreated services use the exact local image IDs checked during preflight, so a changed `latest` tag cannot silently select different code. It does not recreate MySQL login credentials: on a replacement server, provision the app/database/account and infrastructure first.

SQL imports run under an account limited to the selected database, not the MySQL root account. Stored-object definers emitted by mysqldump are normalized to that scoped account. The account is locked after a successful import and retained so restored views/routines/triggers remain executable. It has no access to another app's database. Repeated restores can leave these locked `restore_*` accounts; account cleanup is a separate administrative task. See [MySQL account locking](https://dev.mysql.com/doc/refman/8.4/en/account-locking.html).

If a backup contains functions/triggers and MySQL's binary-log policy forbids their creation by a scoped account, restore fails during preflight, before stopping services. The script does not change global MySQL security settings. Archives containing MySQL scheduled events can be unpacked, but automatic apply is refused so old events cannot execute partway through a restore; those need a reviewed database recovery. These are MySQL database events, distinct from the app's Laravel scheduler/queue services. Both limitations are checked before changing live data.

Image mismatches fail before stopping the app. Review schema/code compatibility and make the appropriate image available; use `--allow-image-mismatch` only when intentionally restoring across versions. Backup archives contain data/configuration and image IDs, not Docker images or source repositories.

Only previously active services restart after successful import; success requires them to pass their health checks. If anything fails after data replacement starts, the app remains stopped. The safety archive and a phase journal remain in `/opt/backups/apps/safety/`; failures after storage replacement may also retain `.pre-restore-*` storage beside the app's storage directory. Recover with the safety archive after inspecting the journal. Safety archives are never automatically deleted or counted toward the two regular backup sets.

Redis is neither captured, rewound nor cleared. Existing queue/session/cache state therefore remains current when the database is rolled back. Review app-specific queued work before restoring an older database; the script does not make Redis and the database consistent with each other.

## Verification and operations

```bash
python3 -m unittest discover -s backups -p 'test_*.py' -v
systemctl list-timers 'infrastructure-app-backup*'
journalctl -u infrastructure-app-backup.service -n 100
journalctl -u infrastructure-app-backup-upload.service -n 100
journalctl -u infrastructure-app-backup-health.service -n 100
```

Automated tests use disposable fixtures and real age/rclone binaries. Docker/application state is controlled in those tests; a real production-compatible MySQL/app restore is still required before activation. Subprocess failures are deliberately reported without raw stderr because database output and Compose diagnostics can expose secrets.

The opt-in SQL tests exercise real MySQL 8.4 dumps/imports, BLOB data, views/procedures,
locked definers and rejection of SQL targeting another database. Start a labeled,
disposable container (no host volumes or published ports), wait until `mysqladmin ping`
succeeds, then run them:

```bash
docker run -d --name backup-test-mysql --label infrastructure.backup.test=true \
  -e MYSQL_ROOT_PASSWORD=disposable-test-only mysql:8.4
docker exec backup-test-mysql mysqladmin ping -uroot -pdisposable-test-only
BACKUP_TEST_MYSQL_CONTAINER=backup-test-mysql \
  python3 -m unittest discover -s backups -p 'test_*.py' -v
docker rm -f backup-test-mysql
```

These tests refuse a container without the test name prefix and label. Remove the
fixture after testing. They do not validate production credentials or Google OAuth.

No restore success is inferred from merely creating or uploading an archive. Repeat a Drive download and isolated application recovery periodically. Preserve the recovery key and Google access outside the VPS.

To pause automatic scheduling, run `sudo systemctl disable --now infrastructure-app-backup.timer infrastructure-app-backup-upload.timer infrastructure-app-backup-health.timer`. To resume, run the installer after checking backup health.
