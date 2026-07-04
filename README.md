# Infrastructure

Shared Docker infrastructure for all apps. Traefik reverse proxy + MySQL + Redis running on a single VPS.

## Architecture

```
Internet → Cloudflare (DNS + SSL) → VPS:443 → Traefik
                                                  |
                                      ┌───────────┼───────────┐
                                      |           |           |
                                   nginx        nginx       nginx
                                  (app A)      (app B)     (app C)
                                      |           |           |
                                   php-fpm     php-fpm      node
                                      |           |           |
                                      └───────────┼───────────┘
                                                  |
                                            backend network
                                                  |
                                          MySQL + Redis
```

**Two Docker networks:**
- `traefik-public` — Traefik routes traffic to app nginx containers
- `backend` — apps connect to MySQL and Redis

**SSL:** Cloudflare handles public SSL. Traefik uses a Cloudflare Origin Certificate for the Cloudflare→VPS connection. No Let's Encrypt needed.

**Network security:** Only Cloudflare may reach ports 80/443. This is enforced in **two** places because **Docker's iptables rules bypass UFW**: UFW restricts the host, and `scripts/firewall-docker.sh` adds a `DOCKER-USER` rule (Cloudflare ranges in an ipset) so container-published ports are Cloudflare-only too. A systemd unit re-applies it on every boot. See [Critical Gotchas](#critical-gotchas).

## Repository Structure

```
infrastructure/
├── docker-compose.yml       # Traefik + MySQL + Redis + Uptime Kuma + Autoheal
├── .env.example             # Template for secrets
├── apps/                    # Per-app production compose + .env (gitignored)
│   ├── mega-catering/
│   ├── endlessly/
│   └── phnx-solution/
├── traefik/
│   ├── traefik.yml          # Entrypoints, Cloudflare IPs, Docker provider
│   └── dynamic/
│       └── tls.yml          # Origin Certificate reference
├── mysql/
│   └── my.cnf              # Tuned for 4GB VPS
├── scripts/
│   ├── setup.sh             # One-time VPS provisioning (hardened)
│   ├── verify-setup.sh      # Verify OS-level hardening
│   ├── firewall-docker.sh   # Restrict Docker-published 80/443 to Cloudflare IPs (Docker bypasses UFW)
│   ├── docker-cloudflare-firewall.service  # systemd unit — re-applies the above on every boot
│   ├── migrate-pack.sh      # Pack data for VPS migration
│   ├── migrate-unpack.sh    # Restore data on new VPS
│   └── verify-migration.sh  # Verify migrated data and services
├── backups/
│   ├── backup.sh            # Daily MySQL dumps (14-day retention)
│   └── volume-backup.sh     # Weekly storage backups (30-day retention)
└── templates/
    ├── laravel/             # Docker files for new Laravel apps
    ├── nuxt/                # Docker files for new Nuxt apps
    └── spa/                 # Docker files for new Vite SPAs (Vue/React/Svelte)
```

---

## Critical Gotchas

Hard-won notes from real provisioning + migration. Read these first — each one cost real debugging time.

1. **Ubuntu 22.10+ uses SSH socket activation.** `ssh.socket` owns the listen port and *ignores* the `Port` directive in `sshd_config`. `setup.sh` disables `ssh.socket`, enables `ssh.service`, and `restart`s (not `reload`) so port **41922** actually binds. If you hand-edit SSH, remember this or sshd stays on 22.

2. **Your SSH key must be in _root's_ `authorized_keys` before running `setup.sh`.** The script copies it from root to `deploy`, and `set -euo pipefail` makes it abort if root has no key. Most providers add it for you when you select an SSH key at VPS creation — verify with `cat /root/.ssh/authorized_keys`.

3. **Reboot after `setup.sh`.** It pulls a new kernel, and the old socket-activated `sshd` can linger on port 22 until reboot. **Before** rebooting or closing the root session, confirm `ssh -p 41922 deploy@<ip>` then `sudo whoami` works in a *second* terminal.

4. **The provider-level firewall is separate from UFW.** If your host panel (e.g. Hostinger) has its own firewall, allow **41922, 80, 443** there too — or you lock yourself out / block all web traffic.

5. **Docker bypasses UFW.** Docker writes its own iptables rules, so UFW's "Cloudflare-only" rule does **not** protect container-published ports — without the fix, the origin answers anyone on 80/443. `firewall-docker.sh` (run by `docker-cloudflare-firewall.service` on boot) closes this via the `DOCKER-USER` chain + a Cloudflare ipset. Verify from off-Cloudflare: `curl -I http://<vps-ip>/` should **time out**.

6. **Only `deploy` can SSH** (`AllowUsers deploy`) — other users are rejected even with a valid key. To allow another, edit `AllowUsers` in `setup.sh` (not just on the box, or a re-run overwrites it).

7. **Own the repo as `deploy`; never the volumes.** If you clone/pull/edit `/opt/infrastructure` as root, fix it: `sudo chown -R deploy:deploy /opt/infrastructure`. **Never** `chown -R /opt/volumes` — MySQL/Redis data is owned by container UIDs (`999`) and they refuse data dirs they don't own.

8. **Log into GHCR on the VPS as `deploy`** before pulling app images (see [GHCR login](#log-into-ghcr-on-the-vps)). Without it, `docker compose pull` fails with `unauthorized` and apps never start.

9. **Don't repoint DNS until the apps are actually running on the target box.** With the Cloudflare-only firewall + Traefik, an unknown host just returns 404 — if DNS points at a VPS where the app container isn't up yet, that site is down.

> `cron.allow` is `644` (not `600`) so the setgid `crontab` binary can read it; otherwise `deploy` gets "not allowed to use this program." `setup.sh` already handles this.

10. **DB GUI tunnels need `AllowTcpForwarding local`.** To reach the dockerized MySQL from TablePlus/DBeaver, the tool opens an SSH tunnel (`ssh -L` to `127.0.0.1:3306`). The SSH hardening allows this via `AllowTcpForwarding local` — if it were `no`, the tool logs in but the tunnel is refused with **"Failed to create tunnel."** Tunnel user is **`deploy`**; use a **MySQL** connection type (8.4 uses `caching_sha2_password`, which the MariaDB driver can't auth), SSL **DISABLED** (the tunnel already encrypts). MySQL is published only on `127.0.0.1:3306`, so it's reachable solely through the SSH tunnel.

---

## Deploy to VPS

### Prerequisites

- A VPS with Ubuntu 22.04+ (tested on **Ubuntu 24.04**, Hostinger 4GB/2CPU)
- Root SSH access to the VPS, **with your public key already in `/root/.ssh/authorized_keys`** (see [Gotcha #2](#critical-gotchas))
- A Cloudflare account managing your domain(s), set to **Full (strict)** SSL
- A provider-level firewall (if any) allowing **41922, 80, 443** (see [Gotcha #4](#critical-gotchas))
- This repo pushed to GitHub

### Step 1: Clone the repo and provision the VPS

SSH in as root:

```bash
ssh root@your-vps-ip

# Install git if not present
apt update && apt install -y git

# Clone the repo
mkdir -p /opt
git clone git@github.com:phnxco-solution/infrastructure.git /opt/infrastructure

# Run the setup script
bash /opt/infrastructure/scripts/setup.sh
```

This script:
- Installs Docker, htop, ufw, fail2ban, unattended-upgrades, ipset
- Creates `deploy` user with SSH key + sudo with password
- Disables `ssh.socket` activation (Ubuntu 22.10+) and moves SSH to port **41922**, key-only auth, AllowUsers deploy
- Configures UFW: SSH on 41922, HTTP/HTTPS restricted to Cloudflare IPs only
- Restricts Docker-published 80/443 to Cloudflare IPs (`DOCKER-USER` chain) — Docker bypasses UFW — and installs a systemd unit to persist it across reboots
- Configures fail2ban: SSH jail + recidive jail for repeat offenders
- Applies kernel hardening (SYN flood, IP spoofing, ICMP protection)
- Enables automatic security updates (no auto-reboot)
- Creates the `/opt/` directory structure with correct permissions
- Creates `traefik-public` and `backend` Docker networks
- Sets up 2GB swap
- Disables snapd, restricts cron access (`cron.allow` 644), secures shared memory
- Configures cron for backups and Docker cleanup

**After it finishes — confirm access, then reboot:**

```bash
# In a SECOND terminal (keep the root session open), confirm the new path works:
ssh -p 41922 deploy@your-vps-ip
sudo whoami        # prompts for the deploy password → prints "root"

# Verify hardening
bash /opt/infrastructure/scripts/verify-setup.sh

# If you ran any setup steps as root (git clone/pull, editing files), give the
# repo back to deploy — but NEVER chown /opt/volumes (see Gotcha #7):
sudo chown -R deploy:deploy /opt/infrastructure

# Reboot to load the pending kernel and clear any stale sshd still on port 22
sudo reboot
```

After it comes back, re-run `verify-setup.sh` — it should be all-clear.

> **Warning:** SSH moves to port 41922 and root login is disabled. **Confirm the
> `deploy` login on 41922 in a separate terminal before disconnecting or rebooting.**
> If the provider has its own firewall, it must allow 41922 (see [Gotcha #4](#critical-gotchas)).

### Step 2: Create the .env file

```bash
cp .env.example .env
```

Edit `.env` and fill in real values:

```bash
nano .env
```

**Generate the dashboard password hash:**

```bash
# Install htpasswd if not present
sudo apt install -y apache2-utils

# Generate hash (replace 'your-password' with a real password)
echo $(htpasswd -nB admin) | sed -e 's/\$/\$\$/g'
```

Copy the output into `TRAEFIK_DASHBOARD_AUTH` in `.env`.

**Generate secure passwords for MySQL and Redis:**

```bash
openssl rand -base64 32  # Use for MYSQL_ROOT_PASSWORD
openssl rand -base64 32  # Use for REDIS_PASSWORD
```

> **Important:** Save these passwords somewhere safe. The Redis password is needed in every app's `.env`.

### Step 3: Set up Cloudflare Origin Certificate

1. Go to **Cloudflare Dashboard → your domain → SSL/TLS → Origin Server**
2. Click **Create Certificate**
3. Select the hostnames to cover (use `*.phnx-solution.com` and `phnx-solution.com` to cover all subdomains)
4. Choose validity (15 years is fine for Origin Certs)
5. Copy the **Origin Certificate** → save as `/opt/infrastructure/traefik/certs/origin.pem`
6. Copy the **Private Key** → save as `/opt/infrastructure/traefik/certs/origin-key.pem`

```bash
nano traefik/certs/origin.pem    # Paste certificate
nano traefik/certs/origin-key.pem # Paste private key
chmod 600 traefik/certs/origin-key.pem
```

> **Cloudflare SSL/TLS mode** must be set to **Full (strict)** for Origin Certificates to work.

#### Adding a second domain (separate Cloudflare zone)

The default cert above only covers `phnx-solution.com`. A different apex domain (its own Cloudflare zone) needs its **own** Origin Certificate, served by Traefik via SNI — otherwise you get **`526`** (origin cert fails strict validation).

1. On the new zone: DNS A records → VPS IP (**Proxied**), SSL/TLS → **Full (strict)**.
2. Create an Origin Certificate covering **both** `newdomain.com` **and** `*.newdomain.com` (a wildcard alone does **not** cover the apex).
3. Save to `traefik/certs/newdomain.pem` + `newdomain-key.pem` (`chmod 600` the key).
4. Add it to `traefik/dynamic/tls.yml` under `certificates:` — a **sibling of `stores:`**, both under `tls:`:
   ```yaml
   tls:
     stores:
       default:
         defaultCertificate:
           certFile: /etc/traefik/certs/origin.pem
           keyFile: /etc/traefik/certs/origin-key.pem
     certificates:
       - certFile: /etc/traefik/certs/newdomain.pem
         keyFile: /etc/traefik/certs/newdomain-key.pem
   ```
   Wrong indentation → `field not found, node: [0]` in the logs and Traefik drops the **whole** file (default cert included) → 526 for everything. `docker logs traefik | grep -i error` should be clean after `docker restart traefik`.

> A valid cert with no app yet returns **404** (not 526) — that's expected until an app's compose adds a `Host(\`newdomain.com\`)` router.

### Step 4: Start the infrastructure

```bash
cd /opt/infrastructure
docker compose up -d
```

Verify everything is running:

```bash
docker ps
```

You should see 5 containers: `traefik`, `mysql`, `redis`, `uptime-kuma`, `autoheal` — all with status `healthy`.

**Test the Traefik dashboard:**

Make sure `traefik.phnx-solution.com` points to your VPS IP in Cloudflare DNS (A record, proxied), then visit:

```
https://traefik.phnx-solution.com
```

Log in with the credentials you set in `.env`.

### Step 5: Create app databases

For each Laravel app that needs a database:

```bash
docker exec -it mysql mysql -u root -p

# Inside MySQL shell:
CREATE DATABASE mega_catering;
CREATE USER 'mega_catering'@'%' IDENTIFIED BY 'generate-a-secure-password';
GRANT ALL PRIVILEGES ON mega_catering.* TO 'mega_catering'@'%';
FLUSH PRIVILEGES;
```

Repeat for each app with its own database and user.

---

## Adding a New App

Once the infrastructure is running, follow these steps to add any new app.

### 1. Copy Docker files from templates

Run `init.sh` from your app's repo root. This copies Docker files into the app repo and creates a production compose file in the infrastructure repo's `apps/` directory.

**[Laravel](templates/laravel/)** — full stack Laravel + Vue projects. See [`templates/laravel/README.md`](templates/laravel/README.md) for customization details.

**[Nuxt](templates/nuxt/)** — Nuxt 3/4 SSR apps. See [`templates/nuxt/README.md`](templates/nuxt/README.md) for details.

```bash
# From your app's repo root:
bash /path/to/infrastructure/templates/laravel/init.sh my-app my-app.phnx-solution.com
# or for Nuxt:
bash /path/to/infrastructure/templates/nuxt/init.sh my-app my-app.phnx-solution.com
```

### 2. Set up GitHub Secrets

Add these secrets to your GitHub repo (or at the org level to share across repos):

| Secret | Value |
|--------|-------|
| `VPS_HOST` | Your VPS IP address |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Contents of the deploy user's private SSH key |
| `VPS_PORT` | `41922` |
| `GHCR_PAT` | GitHub Personal Access Token with `read:packages` scope |

**Generate the GHCR PAT:**
1. Go to **GitHub → Settings → Developer Settings → Personal Access Tokens → Tokens (classic)**
2. Create a token with `read:packages` scope
3. Add it as `GHCR_PAT` secret in your repo

### 3. Set up on the VPS

```bash
# Pull the infrastructure repo to get the new compose file (as deploy)
cd /opt/infrastructure && git pull

# Create storage directory
mkdir -p /opt/volumes/apps/<app-name>/storage/{app/public,framework/{cache/data,sessions,views},logs}

# Create the production .env next to the compose file
nano /opt/infrastructure/apps/<app-name>/.env
```

#### Log into GHCR on the VPS

App images are private (`ghcr.io/phnxco-solution/*`), so the VPS must authenticate before it can pull them. **One-time per VPS, run as `deploy`** (the user that runs `docker compose`, so the credentials land in its `~/.docker/config.json`):

```bash
# Create a classic PAT with read:packages scope (authorize SSO for the org if enabled), then:
echo 'ghp_yourtoken' | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
docker pull ghcr.io/phnxco-solution/<app-name>:latest   # confirm it works
```

> Without this, `docker compose pull` (step 6, and `migrate-unpack.sh`) fails with `unauthorized` and the app never starts.

**Key .env changes for Docker:**

```env
DB_HOST=mysql
DB_DATABASE=<your-database>
DB_USERNAME=<your-db-user>
DB_PASSWORD=<your-db-password>

REDIS_HOST=redis
REDIS_PASSWORD=<same password from infrastructure .env>

QUEUE_CONNECTION=redis
CACHE_STORE=redis
SESSION_DRIVER=redis
```

### 4. Create the database

```bash
docker exec -it mysql mysql -u root -p

CREATE DATABASE <app_database>;
CREATE USER '<app_user>'@'%' IDENTIFIED BY '<password>';
GRANT ALL PRIVILEGES ON <app_database>.* TO '<app_user>'@'%';
FLUSH PRIVILEGES;
```

### 5. Point DNS to your VPS

In Cloudflare, add an **A record**:
- Name: `<subdomain>` (e.g., `mega-catering`)
- Content: your VPS IP
- Proxy status: **Proxied** (orange cloud)

### 6. Deploy

Push to the `master` branch. GitHub Actions will build, push, and deploy automatically.

For the first deploy, you can also trigger it manually on the VPS:

```bash
cd /opt/infrastructure/apps/<app-name>
docker compose pull
docker compose up -d
```

> Migrations run automatically via the entrypoint — no separate `docker compose run` needed.

### 7. Verify

```bash
# Check containers are running and healthy
cd /opt/infrastructure/apps/<app-name>
docker compose ps

# Check app responds
curl -f https://<app-domain>/health

# Check logs if something is wrong
docker compose logs app
docker compose logs nginx
docker compose logs worker
```

---

## Migrating an Existing App

If you're moving an app from bare-metal to Docker on the same VPS:

1. **Export the database** from the existing MySQL:
   ```bash
   mysqldump -u root -p <database> > /tmp/dump.sql
   ```

2. **Import into Docker MySQL:**
   ```bash
   docker exec -i mysql mysql -u root -p<password> <database> < /tmp/dump.sql
   ```

3. **Copy storage files:**
   ```bash
   cp -r /path/to/existing/storage/* /opt/volumes/apps/<app-name>/storage/
   chown -R 82:82 /opt/volumes/apps/<app-name>/storage/
   ```
   > UID 82 is `www-data` in Alpine-based PHP images.

4. **Deploy the Docker version** (follow "Adding a New App" above).

5. **Update DNS** in Cloudflare to route through Traefik.

6. **Decommission** the old bare-metal setup once verified.

---

## VPS-to-VPS Migration

Migrate all data, secrets, and volumes from one VPS to another. The new VPS must have `setup.sh` already run and this repo cloned.

### What gets migrated

- `.env` files (infrastructure + all apps)
- TLS certificates (Cloudflare Origin Certificate)
- MySQL databases (per-database dumps)
- Redis data (AOF + RDB)
- Uptime Kuma data (monitors, alerts, history)
- App volumes (uploads, storage, logs)
- App config files (nginx.conf, etc.)

### Step 1: Pack on the old VPS

```bash
# Preview what will be packed
bash /opt/infrastructure/scripts/migrate-pack.sh --dry-run

# Create the migration tarball (apps stop briefly for consistent snapshot)
bash /opt/infrastructure/scripts/migrate-pack.sh
```

Output: `/opt/migration-pack-YYYY-MM-DD.tar.gz`

### Step 2: Transfer to the new VPS

```bash
scp -P 41922 /opt/migration-pack-*.tar.gz deploy@new-vps-ip:/opt/
```

### Step 3: Provision the new VPS

```bash
# On the new VPS as root (your key must already be in /root/.ssh/authorized_keys):
git clone git@github.com:phnxco-solution/infrastructure.git /opt/infrastructure
bash /opt/infrastructure/scripts/setup.sh

# Confirm 41922 login in a second terminal (see Gotcha #2/#3), then:
sudo chown -R deploy:deploy /opt/infrastructure   # repo was cloned as root
sudo reboot                                        # load kernel, clear stale sshd on 22
```

Then **as `deploy`**, log into GHCR so the apps can pull their images during unpack (see [GHCR login](#log-into-ghcr-on-the-vps)):

```bash
echo 'ghp_yourtoken' | docker login ghcr.io -u YOUR_GITHUB_USERNAME --password-stdin
```

> The new VPS also needs the infrastructure `.env`, the TLS cert, and `docker compose up -d` for the base stack **only if** you're not relying on the tarball to provide them — `migrate-unpack.sh` restores the infra `.env`, certs, and starts everything, so on a clean migration you can go straight to unpack after the GHCR login.

### Step 4: Unpack on the new VPS

```bash
# Preview and validate the tarball
bash /opt/infrastructure/scripts/migrate-unpack.sh /opt/migration-pack-*.tar.gz --verify-only

# Restore everything
bash /opt/infrastructure/scripts/migrate-unpack.sh /opt/migration-pack-*.tar.gz
```

This restores all data, starts infrastructure and apps, and creates MySQL users.

### Step 5: Verify

```bash
# OS-level hardening checks
bash /opt/infrastructure/scripts/verify-setup.sh

# Data and service checks
bash /opt/infrastructure/scripts/verify-migration.sh
```

### Step 6: Cut over

> **Only cut over once Step 5 confirms the apps are up and healthy on the new VPS.** Until DNS points at the new box, the apps there are unreachable from the internet (Cloudflare-only firewall), so verify locally first — e.g. `curl -H 'Host: app.megacatering.rs' -k https://127.0.0.1/health` on the new VPS. If you repoint DNS while an app container is down, that site returns 404 (see [Gotcha #9](#critical-gotchas)).

1. Update **Cloudflare DNS** A records to the new VPS IP
2. Update **GitHub Actions secrets** in each app repo:
   - `VPS_HOST` → new IP
   - `VPS_PORT` → `41922`
   - `VPS_SSH_KEY` → new deploy user's key
3. Delete the tarball from both VPS instances (contains secrets)
4. Monitor logs for 24 hours before decommissioning the old VPS

---

## Operations

### View logs

```bash
# Infrastructure
cd /opt/infrastructure && docker compose logs -f traefik
cd /opt/infrastructure && docker compose logs -f mysql
cd /opt/infrastructure && docker compose logs -f redis

# App
cd /opt/infrastructure/apps/<name> && docker compose logs -f app
cd /opt/infrastructure/apps/<name> && docker compose logs -f worker
```

### Run artisan commands

```bash
cd /opt/infrastructure/apps/<name>
docker compose exec app php artisan <command>
```

### Database access

```bash
docker exec -it mysql mysql -u root -p
```

### Manual backup

```bash
# MySQL
/opt/infrastructure/backups/backup.sh

# Storage volumes
/opt/infrastructure/backups/volume-backup.sh
```

### Restart services

```bash
# Restart infrastructure
cd /opt/infrastructure && docker compose restart

# Restart an app
cd /opt/infrastructure/apps/<name> && docker compose restart

# Restart just the worker
cd /opt/infrastructure/apps/<name> && docker compose restart worker
```

### Resource monitoring

```bash
# Container resource usage
docker stats

# Disk usage
df -h
docker system df
```
