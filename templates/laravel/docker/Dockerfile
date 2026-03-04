# ── Base stage: shared between dev and prod ──────────────────────────
FROM php:8.4-fpm-alpine AS base

# System dependencies for DomPDF, GD (Intervention Image), Zip (Excel)
RUN apk add --no-cache \
    libzip-dev \
    libpng-dev \
    libjpeg-turbo-dev \
    libwebp-dev \
    freetype-dev \
    icu-dev \
    libxml2-dev \
    oniguruma-dev \
    fcgi \
    # Fonts for DomPDF
    fontconfig \
    ttf-dejavu

# PHP extensions
RUN docker-php-ext-configure gd \
        --with-jpeg \
        --with-webp \
        --with-freetype \
    && docker-php-ext-install -j$(nproc) \
        pdo_mysql \
        mbstring \
        xml \
        dom \
        zip \
        gd \
        bcmath \
        intl \
        pcntl \
        opcache

# Redis extension
RUN apk add --no-cache --virtual .build-deps $PHPIZE_DEPS \
    && pecl install redis \
    && docker-php-ext-enable redis \
    && apk del .build-deps

# PHP-FPM pool configuration
RUN printf '%s\n' \
    '[www]' \
    'pm = dynamic' \
    'pm.max_children = 5' \
    'pm.start_servers = 2' \
    'pm.min_spare_servers = 1' \
    'pm.max_spare_servers = 3' \
    'pm.max_requests = 500' \
    'pm.status_path = /status' \
    'ping.path = /ping' \
    'ping.response = pong' \
    > /usr/local/etc/php-fpm.d/zz-pool.conf

# PHP upload/memory limits
RUN printf '%s\n' \
    'upload_max_filesize = 64M' \
    'post_max_size = 64M' \
    'memory_limit = 256M' \
    > /usr/local/etc/php/conf.d/uploads.ini

WORKDIR /var/www/html

# ── Composer dependencies (only used by production) ──────────────────
FROM composer:2 AS composer-deps
WORKDIR /app
COPY composer.json composer.lock ./
RUN composer install --no-dev --no-scripts --no-autoloader --prefer-dist --ignore-platform-reqs
COPY . .
RUN composer dump-autoload --optimize

# ── Frontend build (only used by production) ─────────────────────────
FROM node:22-alpine AS frontend
WORKDIR /app
COPY package.json package-lock.json ./
RUN npm ci
COPY . .
RUN npm run build

# ── Development target ───────────────────────────────────────────────
FROM base AS development

RUN cp /usr/local/etc/php/php.ini-development /usr/local/etc/php/php.ini

# OPcache: validate timestamps so file changes are picked up instantly
RUN printf '%s\n' \
    'opcache.enable=1' \
    'opcache.memory_consumption=128' \
    'opcache.interned_strings_buffer=16' \
    'opcache.max_accelerated_files=10000' \
    'opcache.validate_timestamps=1' \
    'opcache.revalidate_freq=0' \
    > /usr/local/etc/php/conf.d/opcache.ini

COPY docker/entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

USER www-data

ENTRYPOINT ["entrypoint.sh"]
CMD ["php-fpm"]

# ── Production target ────────────────────────────────────────────────
FROM base AS production

RUN cp /usr/local/etc/php/php.ini-production /usr/local/etc/php/php.ini

# OPcache: no timestamp validation, JIT enabled
RUN printf '%s\n' \
    'opcache.enable=1' \
    'opcache.memory_consumption=128' \
    'opcache.interned_strings_buffer=16' \
    'opcache.max_accelerated_files=10000' \
    'opcache.validate_timestamps=0' \
    'opcache.jit=1255' \
    'opcache.jit_buffer_size=64M' \
    > /usr/local/etc/php/conf.d/opcache.ini

# Copy application
COPY --from=composer-deps /app/vendor ./vendor
COPY app ./app
COPY bootstrap ./bootstrap
COPY config ./config
COPY database ./database
COPY lang ./lang
COPY public ./public
COPY resources ./resources
COPY routes ./routes
COPY storage ./storage
COPY artisan ./artisan
COPY composer.json ./
COPY --from=frontend /app/public/build ./public/build

# Set permissions
RUN chown -R www-data:www-data /var/www/html \
    && chmod -R 775 storage bootstrap/cache

COPY docker/entrypoint.sh /usr/local/bin/
RUN chmod +x /usr/local/bin/entrypoint.sh

USER www-data

ENTRYPOINT ["entrypoint.sh"]
CMD ["php-fpm"]
