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

## Deploy to VPS

### Prerequisites

- A VPS with Ubuntu 22.04+ (tested on Hostinger 4GB/2CPU)
- Root SSH access to the VPS
- A Cloudflare account managing your domain(s)
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
- Installs Docker, htop, ufw, fail2ban, unattended-upgrades
- Creates `deploy` user with SSH key + sudo with password
- Moves SSH to port **41922**, key-only auth, AllowUsers deploy
- Configures UFW: SSH on 41922, HTTP/HTTPS restricted to Cloudflare IPs only
- Configures fail2ban: SSH jail + recidive jail for repeat offenders
- Applies kernel hardening (SYN flood, IP spoofing, ICMP protection)
- Enables automatic security updates (no auto-reboot)
- Creates the `/opt/` directory structure with correct permissions
- Creates `traefik-public` and `backend` Docker networks
- Sets up 2GB swap
- Disables snapd, restricts cron access, secures shared memory
- Configures cron for backups and Docker cleanup

**After it finishes, verify and log in as deploy:**

```bash
# Verify hardening
bash /opt/infrastructure/scripts/verify-setup.sh

# Log in on the new SSH port
ssh -p 41922 deploy@your-vps-ip
```

> **Warning:** SSH moves to port 41922 and root login is disabled.
> Make sure your SSH key works for the `deploy` user before disconnecting.

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

### Step 4: Start the infrastructure

```bash
cd /opt/infrastructure
docker compose up -d
```

Verify everything is running:

```bash
docker ps
```

You should see 3 containers: `traefik`, `mysql`, `redis` — all with status `healthy`.

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
# Pull the infrastructure repo to get the new compose file
cd /opt/infrastructure && git pull

# Create storage directory
mkdir -p /opt/volumes/apps/<app-name>/storage/{app/public,framework/{cache/data,sessions,views},logs}

# Create the production .env next to the compose file
nano /opt/infrastructure/apps/<app-name>/.env
```

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
# On the new VPS as root:
git clone git@github.com:phnxco-solution/infrastructure.git /opt/infrastructure
bash /opt/infrastructure/scripts/setup.sh
```

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
