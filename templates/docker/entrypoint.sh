#!/bin/sh
set -e

if [ "$APP_ENV" = "local" ] || [ "$APP_ENV" = "development" ]; then
    # Create Laravel storage directories if they don't exist
    for dir in storage/app/public storage/framework/cache storage/framework/sessions storage/framework/views storage/logs bootstrap/cache; do
        mkdir -p "/app/$dir"
    done

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
