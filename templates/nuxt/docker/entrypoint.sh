#!/bin/sh
set -e

if [ "$NODE_ENV" = "production" ]; then
    echo "Running database migrations..."
    ./node_modules/.bin/drizzle-kit migrate
    echo "Migrations completed."
fi

exec "$@"
