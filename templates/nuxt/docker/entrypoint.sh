#!/bin/sh
set -e

if [ "$NODE_ENV" != "production" ]; then
    echo "Running database migrations..."
    ./node_modules/.bin/drizzle-kit migrate
    echo "Migrations completed."
fi

# Persistent daily logging (production only, when /app/logs is mounted)
if [ "$NODE_ENV" = "production" ] && [ -d "/app/logs" ] && [ "$(basename "${1:-}")" = "dumb-init" ]; then
    FIFO="/tmp/logpipe"
    rm -f "$FIFO" && mkfifo "$FIFO"

    # Write to daily log files + stdout (like Laravel's daily channel)
    awk -v dir="/app/logs" '
        BEGIN { "date +%Y-%m-%d" | getline d; close("date +%Y-%m-%d"); f = dir "/app-" d ".log" }
        NR % 100 == 0 { "date +%Y-%m-%d" | getline nd; close("date +%Y-%m-%d"); if (nd != d) { close(f); d = nd; f = dir "/app-" d ".log" } }
        { print >> f; fflush(f); print; fflush() }
    ' < "$FIFO" &

    exec "$@" > "$FIFO" 2>&1
fi

exec "$@"
