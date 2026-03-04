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
├── traefik/
│   ├── traefik.yml          # Entrypoints, Cloudflare IPs, Docker provider
│   └── dynamic/
│       └── tls.yml          # Origin Certificate reference
├── mysql/
│   └── my.cnf              # Tuned for 4GB VPS
├── scripts/
│   └── setup.sh            # One-time VPS provisioning
├── backups/
│   ├── backup.sh            # Daily MySQL dumps (14-day retention)
│   └── volume-backup.sh     # Weekly storage backups (30-day retention)
└── templates/
    └── laravel/             # Copyable Docker files for new Laravel apps
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
- Installs Docker, htop, ufw, fail2ban
- Creates a `deploy` user with your SSH key (copies from root)
- Configures firewall (only SSH + 80 + 443)
- Creates the `/opt/` directory structure
- Creates `traefik-public` and `backend` Docker networks
- Sets up 2GB swap
- Hardens SSH (disables password auth and root login)
- Configures cron for backups and Docker cleanup

**After it finishes, log out and log back in as the deploy user:**

```bash
ssh deploy@your-vps-ip
```

> **Warning:** The script disables root login and password authentication.
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

```bash
# Set your app name and domain
APP_NAME="my-app"
APP_DOMAIN="my-app.phnx-solution.com"

# From your app's repo root:
cp -r /opt/infrastructure/templates/laravel/docker ./docker
cp /opt/infrastructure/templates/laravel/.dockerignore ./.dockerignore
cp /opt/infrastructure/templates/laravel/docker-compose.yml ./docker-compose.yml
mkdir -p .github/workflows
cp /opt/infrastructure/templates/laravel/.github/workflows/deploy.yml .github/workflows/deploy.yml

# Replace placeholders
sed -i "s/{{APP_NAME}}/$APP_NAME/g" docker/docker-compose.prod.yml .github/workflows/deploy.yml
sed -i "s/{{APP_DOMAIN}}/$APP_DOMAIN/g" docker/docker-compose.prod.yml
```

**What each file does:**

| File | Purpose |
|------|---------|
| `docker/Dockerfile` | Multi-target PHP image (dev + production), OPcache with JIT, Redis, GD |
| `docker/Dockerfile.nginx` | Nginx image with baked-in frontend assets (no shared volumes needed) |
| `docker/entrypoint.sh` | Runs migrations, storage link, and optimize on container start |
| `docker/nginx.conf` | Gzip, fastcgi buffering, static asset caching, `/health` endpoint |
| `docker/docker-compose.prod.yml` | Production: app (backend network), nginx (Traefik labels), worker |
| `docker-compose.yml` | Local dev: app, vite, nginx, worker, mysql, redis |
| `.dockerignore` | Keeps Docker context small (excludes vendor, node_modules, tests) |
| `.github/workflows/deploy.yml` | Builds 2 images (app + nginx), deploys via SSH to VPS |

**What to customize:**
- **Dockerfile** — remove PHP extensions you don't need (gd, intl, bcmath, etc.)
- **docker-compose.prod.yml** — adjust memory limits, add a scheduler if needed:

```yaml
  scheduler:
    image: ghcr.io/phnxco-solution/<app-name>:latest
    restart: unless-stopped
    env_file: ../.env
    command: php artisan schedule:work
    networks:
      - backend
    deploy:
      resources:
        limits:
          memory: 64M
```

> See [`templates/laravel/README.md`](templates/laravel/README.md) for full customization details.

### 2. Set up GitHub Secrets

Add these secrets to your GitHub repo (or at the org level to share across repos):

| Secret | Value |
|--------|-------|
| `VPS_HOST` | Your VPS IP address |
| `VPS_USER` | `deploy` |
| `VPS_SSH_KEY` | Contents of the deploy user's private SSH key |
| `VPS_PORT` | `22` (or your custom SSH port) |
| `GHCR_PAT` | GitHub Personal Access Token with `read:packages` scope |

**Generate the GHCR PAT:**
1. Go to **GitHub → Settings → Developer Settings → Personal Access Tokens → Tokens (classic)**
2. Create a token with `read:packages` scope
3. Add it as `GHCR_PAT` secret in your repo

### 3. Set up on the VPS

```bash
# Create the app directory and clone the repo
cd /opt/apps
git clone git@github.com:phnxco-solution/<app-name>.git
cd <app-name>

# Create storage directory
mkdir -p /opt/volumes/apps/<app-name>/storage/{app/public,framework/{cache/data,sessions,views},logs}

# Create the production .env
cp .env.example .env
nano .env
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
cd /opt/apps/<app-name>
docker compose -f docker/docker-compose.prod.yml pull
docker compose -f docker/docker-compose.prod.yml up -d
```

> Migrations run automatically via the entrypoint — no separate `docker compose run` needed.

### 7. Verify

```bash
# Check containers are running and healthy
docker compose -f docker/docker-compose.prod.yml ps

# Check app responds
curl -f https://<app-domain>/health

# Check logs if something is wrong
docker compose -f docker/docker-compose.prod.yml logs app
docker compose -f docker/docker-compose.prod.yml logs nginx
docker compose -f docker/docker-compose.prod.yml logs worker
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

## Operations

### View logs

```bash
# Infrastructure
cd /opt/infrastructure && docker compose logs -f traefik
cd /opt/infrastructure && docker compose logs -f mysql
cd /opt/infrastructure && docker compose logs -f redis

# App
cd /opt/apps/<name> && docker compose -f docker/docker-compose.prod.yml logs -f app
cd /opt/apps/<name> && docker compose -f docker/docker-compose.prod.yml logs -f worker
```

### Run artisan commands

```bash
cd /opt/apps/<name>
docker compose -f docker/docker-compose.prod.yml exec app php artisan <command>
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
cd /opt/apps/<name> && docker compose -f docker/docker-compose.prod.yml restart

# Restart just the worker
cd /opt/apps/<name> && docker compose -f docker/docker-compose.prod.yml restart worker
```

### Resource monitoring

```bash
# Container resource usage
docker stats

# Disk usage
df -h
docker system df
```
