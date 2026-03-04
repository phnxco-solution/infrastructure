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
├── docker-compose.yml       # Traefik + MySQL + Redis
├── .env.example             # Template for secrets
├── traefik/
│   ├── traefik.yml          # Entrypoints, Cloudflare IPs, Docker provider
│   └── dynamic/
│       └── tls.yml          # Origin Certificate reference
├── mysql/
│   └── my.cnf              # Tuned for 4GB VPS
├── scripts/
│   └── setup.sh            # One-time VPS provisioning
└── backups/
    ├── backup.sh            # Daily MySQL dumps (14-day retention)
    └── volume-backup.sh     # Weekly storage backups (30-day retention)
```

---

## Deploy to VPS

### Prerequisites

- A VPS with Ubuntu 22.04+ (tested on Hostinger 4GB/2CPU)
- Root SSH access to the VPS
- A Cloudflare account managing your domain(s)
- This repo pushed to GitHub

### Step 1: Provision the VPS

SSH in as root and run the setup script:

```bash
ssh root@your-vps-ip

# Download and run (or copy/paste the script)
bash setup.sh
```

This script:
- Installs Docker, git, htop, ufw, fail2ban
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

### Step 2: Clone the infrastructure repo

```bash
cd /opt
git clone git@github.com:phnxco-solution/infrastructure.git
cd infrastructure
```

### Step 3: Create the .env file

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

### Step 4: Set up Cloudflare Origin Certificate

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

### Step 5: Start the infrastructure

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

### Step 6: Create app databases

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

### 1. Add Docker files to your app repo

Create these files in your app's git repository:

```
your-app/
├── docker/
│   ├── Dockerfile
│   ├── entrypoint.sh
│   ├── nginx.conf
│   └── docker-compose.prod.yml
├── docker-compose.yml              # Optional: local dev
├── .dockerignore                   # Must be in repo root
└── .github/workflows/deploy.yml
```

#### docker/Dockerfile (Laravel + Vue template)

```dockerfile
# Stage 1: Composer dependencies
FROM composer:2 AS composer-deps
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist
COPY . .
RUN composer dump-autoload --optimize

# Stage 2: Frontend build
FROM node:22-alpine AS frontend
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# Stage 3: Production image
FROM php:8.4-fpm-alpine

# System deps — adjust per app needs (remove what you don't need)
RUN apk add --no-cache \
    libzip-dev libpng-dev libjpeg-turbo-dev libwebp-dev freetype-dev \
    icu-dev libxml2-dev oniguruma-dev fontconfig ttf-dejavu

RUN docker-php-ext-configure gd --with-jpeg --with-webp --with-freetype \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql mbstring xml dom zip gd bcmath intl pcntl opcache

# Redis extension
RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install redis && docker-php-ext-enable redis \
    && apk del .build-deps

# OPcache
RUN echo '\
opcache.enable=1\n\
opcache.memory_consumption=128\n\
opcache.interned_strings_buffer=16\n\
opcache.max_accelerated_files=10000\n\
opcache.validate_timestamps=0\n\
opcache.jit=1255\n\
opcache.jit_buffer_size=64M\n\
' > /usr/local/etc/php/conf.d/opcache.ini

# PHP-FPM pool
RUN echo '\
[www]\n\
pm = dynamic\n\
pm.max_children = 15\n\
pm.start_servers = 3\n\
pm.min_spare_servers = 2\n\
pm.max_spare_servers = 5\n\
pm.max_requests = 500\n\
' > /usr/local/etc/php-fpm.d/zz-pool.conf

# Upload limits
RUN echo '\
upload_max_filesize = 64M\n\
post_max_size = 64M\n\
memory_limit = 256M\n\
' > /usr/local/etc/php/conf.d/uploads.ini

WORKDIR /var/www/html
COPY --from=composer-deps /app/vendor ./vendor
COPY . .
COPY --from=frontend /app/public/build ./public/build

RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 775 storage bootstrap/cache

COPY docker/entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

USER www-data
ENTRYPOINT ["entrypoint.sh"]
CMD ["php-fpm"]
```

#### docker/entrypoint.sh

```bash
#!/bin/sh
set -e
php artisan optimize
exec "$@"
```

#### docker/nginx.conf

```nginx
server {
    listen 80;
    server_name _;
    root /var/www/html/public;
    index index.php;

    client_max_body_size 64M;

    location /health {
        access_log off;
        return 200 'ok';
        add_header Content-Type text/plain;
    }

    location /build/ {
        expires 1y;
        access_log off;
        add_header Cache-Control "public, immutable";
        try_files $uri =404;
    }

    location /storage/ {
        expires 7d;
        access_log off;
        add_header Cache-Control "public";
        try_files $uri =404;
    }

    location ~* \.(js|css|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$ {
        expires 7d;
        access_log off;
        try_files $uri =404;
    }

    location / {
        try_files $uri $uri/ /index.php?$query_string;
    }

    location ~ \.php$ {
        fastcgi_pass app:9000;
        fastcgi_param SCRIPT_FILENAME $realpath_root$fastcgi_script_name;
        include fastcgi_params;
        fastcgi_hide_header X-Powered-By;
    }

    location ~ /\.(?!well-known) {
        deny all;
    }
}
```

#### docker/docker-compose.prod.yml

Replace `<app-name>` and `<app-domain>` with your values:

```yaml
services:
  app:
    image: ghcr.io/phnxco-solution/<app-name>:latest
    restart: unless-stopped
    env_file: ../.env
    volumes:
      - app-public:/var/www/html/public
      - /opt/volumes/apps/<app-name>/storage:/var/www/html/storage
    networks:
      - traefik-public
      - backend
    deploy:
      resources:
        limits:
          memory: 256M
    healthcheck:
      test: ["CMD-SHELL", "php-fpm-healthcheck || kill 1"]
      interval: 30s
      timeout: 5s
      retries: 3

  nginx:
    image: nginx:1.27-alpine
    restart: unless-stopped
    volumes:
      - app-public:/var/www/html/public:ro
      - ../docker/nginx.conf:/etc/nginx/conf.d/default.conf:ro
    networks:
      - traefik-public
    depends_on:
      app:
        condition: service_healthy
    labels:
      - "traefik.enable=true"
      - "traefik.http.routers.<app-name>.rule=Host(`<app-domain>`)"
      - "traefik.http.routers.<app-name>.entrypoints=websecure"
      - "traefik.http.routers.<app-name>.tls=true"
      - "traefik.http.services.<app-name>.loadbalancer.server.port=80"
      - "traefik.http.services.<app-name>.loadbalancer.healthcheck.path=/health"
      - "traefik.http.services.<app-name>.loadbalancer.healthcheck.interval=15s"
    deploy:
      resources:
        limits:
          memory: 64M

  worker:
    image: ghcr.io/phnxco-solution/<app-name>:latest
    restart: unless-stopped
    env_file: ../.env
    command: php artisan queue:work redis --max-jobs=1000 --max-time=3600 --tries=3 --timeout=90
    volumes:
      - /opt/volumes/apps/<app-name>/storage:/var/www/html/storage
    networks:
      - backend
    stop_signal: SIGTERM
    stop_grace_period: 30s
    deploy:
      resources:
        limits:
          memory: 128M

volumes:
  app-public:

networks:
  traefik-public:
    external: true
  backend:
    external: true
```

**Optional services to add:**

```yaml
  # Add if the app has scheduled commands
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

#### .dockerignore (in repo root)

```
node_modules
vendor
.git
.env
.env.*
!.env.example
storage/logs/*
storage/framework/cache/data/*
storage/framework/sessions/*
storage/framework/views/*
tests
*.md
.idea
.vscode
docker-compose.yml
```

#### .github/workflows/deploy.yml

Replace `<app-name>` with your app:

```yaml
name: Build & Deploy

on:
  push:
    branches:
      - master

env:
  IMAGE_NAME: ghcr.io/phnxco-solution/<app-name>
  APP_DIR: /opt/apps/<app-name>

jobs:
  build-and-push:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      packages: write

    steps:
      - name: Checkout
        uses: actions/checkout@v4

      - name: Log in to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}

      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3

      - name: Build and push
        uses: docker/build-push-action@v6
        with:
          context: .
          file: docker/Dockerfile
          push: true
          tags: |
            ${{ env.IMAGE_NAME }}:${{ github.sha }}
            ${{ env.IMAGE_NAME }}:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max

  deploy:
    runs-on: ubuntu-latest
    needs: build-and-push

    steps:
      - name: Deploy to VPS
        uses: appleboy/ssh-action@v1
        with:
          host: ${{ secrets.VPS_HOST }}
          username: ${{ secrets.VPS_USER }}
          key: ${{ secrets.VPS_SSH_KEY }}
          port: ${{ secrets.VPS_PORT }}
          script: |
            set -e

            echo "${{ secrets.GHCR_PAT }}" | docker login ghcr.io -u ${{ github.actor }} --password-stdin
            docker pull ${{ env.IMAGE_NAME }}:${{ github.sha }}
            docker tag ${{ env.IMAGE_NAME }}:${{ github.sha }} ${{ env.IMAGE_NAME }}:latest

            cd ${{ env.APP_DIR }}

            docker compose -f docker/docker-compose.prod.yml run --rm --no-deps app php artisan migrate --force
            docker compose -f docker/docker-compose.prod.yml up -d --force-recreate --remove-orphans

            sleep 5
            docker compose -f docker/docker-compose.prod.yml ps

            docker image prune -af --filter "until=168h"
```

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
docker compose -f docker/docker-compose.prod.yml run --rm --no-deps app php artisan migrate --force
docker compose -f docker/docker-compose.prod.yml up -d
```

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
