#!/bin/sh
set -e

# Fix ownership of named volumes (Docker creates them as root)
if [ "$(id -u)" = "0" ]; then
    chown appuser:appuser /app/vendor /app/node_modules
    exec gosu appuser "$0" "$@"
fi

if [ "$APP_ENV" = "local" ] || [ "$APP_ENV" = "development" ]; then
    # Install dependencies if named volumes are empty (first run)
    if [ -f /app/composer.json ] && [ ! -f /app/vendor/autoload.php ]; then
        echo "Installing Composer dependencies..."
        composer install --no-interaction
    fi

    if [ -f /app/package.json ] && [ ! -d /app/node_modules/.bin ]; then
        echo "Installing Node dependencies..."
        bun install
    fi
else
    # Production: cache config on first startup (not at build time,
    # because .env is excluded from the Docker build context)
    if [ -f /app/artisan ] && [ ! -f /app/bootstrap/cache/config.php ]; then
        php artisan config:cache
    fi
fi

exec "$@"
