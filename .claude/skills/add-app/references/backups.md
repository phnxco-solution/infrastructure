# Backup coverage when adding an app

Read `<infra>/backups/README.md` for the current backup contract. The `apps` mapping
in the backup configuration is the explicit inclusion list. Creating an app's Compose
file does not register it, and pulling the repository does not update the active VPS
configuration.

## Decide and record coverage

Add each new project to backups during onboarding. Ask the user if coverage is unclear
or an exclusion is proposed; do not silently leave it out. Record the outcome in the
app README and deployment handoff. `phnx-solution` is already explicitly excluded by
the user; keep its deployed app and do not re-add its backup entry.

An included app gets its database, persistent `storage/`, and app configuration in an
encrypted archive. Redis, shared infrastructure, logs, and rebuildable caches are
excluded. Keep apps/workers online during backup; app restoration stops the selected
app's services. Do not change retention, schedule, or restore behavior while onboarding.

## Register the included app

1. Add its entry to `<infra>/backups/config.example.json` under `apps`. For example:

   ```json
   "<app>": {"database": "auto", "owner": [1000, 1000]}
   ```

   Use `"auto"` for a supported MySQL-backed app, or `null` for an app confirmed to
   have no database. A database name can be pinned when necessary. Verify the actual
   container UID:GID: Laravel Alpine commonly uses `[82, 82]`, Node `[1000, 1000]`.
   These values control restored storage ownership; do not infer them from host users.

2. Confirm persistent data fits the supported layout:
   `/opt/volumes/apps/<app>/storage`. Create that directory with the correct ownership
   even for a database-free app. Additional persistent paths, writable named volumes,
   external databases, and unsupported database engines require deliberate backup
   support before claiming that the app is covered. A `null` mapping does not turn an
   unsupported database into backed-up data.

3. On the VPS, merge the same app entry into
   `/etc/infrastructure-backup/config.json`, as root. Preserve the existing public age
   recipients, Drive remote/path, server name, webhook, and every unrelated setting.
   Do not overwrite an existing configuration with the template, reset rclone, or copy
   a recovery private key onto the server for onboarding. Keep configuration private.

   Perform this through the authorized deployment workflow, or include the exact
   entry and edit command in the manual VPS handoff:

   ```bash
   sudo nano /etc/infrastructure-backup/config.json
   ```

4. Once Compose configuration, storage, and the database are ready, run on the VPS:

   ```bash
   sudo /opt/infrastructure/backups/backup.sh check
   ```

   Verify the output lists the new app with its expected database and owner and ends
   with `Preflight passed; no app data changed`. Preflight does not pause apps. Avoid
   printing resolved Compose environment or configuration files into the transcript.

Every non-system database in the shared MySQL container must map to exactly one
included app. An excluded app that still has such a database will fail preflight;
omitting the app or setting its database to `null` does not bypass that check. Explain
this limitation and resolve the backup/support decision with the user. Do not delete
its database or weaken coverage checks just to make onboarding pass.

## Verify the first uploaded archive

After deployment, use an authorized manual backup run or the next scheduled run to
confirm coverage. A manual run backs up all configured apps, with apps still online:

```bash
sudo /opt/infrastructure/backups/backup.sh run
sudo /opt/infrastructure/backups/backup.sh list --source drive --app <app>
```

Record the successful uploaded run ID in the handoff. If the user performs these steps
later, mark them pending and provide these exact commands. A preflight or template
edit alone does not prove an archive has reached Drive. Follow the operational guide
for recovery testing; never restore over a live app merely to validate onboarding.
