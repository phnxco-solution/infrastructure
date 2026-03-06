#!/bin/sh
set -e

if [ "$CONTAINER_ROLE" = "app" ]; then
    echo "Running startup tasks..."

    if [ "$APP_ENV" != "local" ]; then
        php artisan storage:link --quiet 2>/dev/null || true
        php artisan optimize
    else
        php artisan migrate
        php artisan storage:link --quiet 2>/dev/null || true
    fi

    echo "Startup tasks completed."
fi

exec "$@"
