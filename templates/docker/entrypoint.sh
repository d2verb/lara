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

    # Garage S3 credentials flow:
    # 1. garage-init creates a bucket and access key via Garage's admin API
    # 2. It writes the generated AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY
    #    to /tmp/garage/credentials (a shared Docker volume)
    # 3. This entrypoint appends those credentials to .env so Laravel can use them
    if ! grep -q "^AWS_ACCESS_KEY_ID=GK" /app/.env 2>/dev/null; then
        # Wait up to 15s for garage-init to finish
        for _ in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do
            [ -f /tmp/garage/credentials ] && break
            sleep 1
        done
        if [ -f /tmp/garage/credentials ]; then
            cat /tmp/garage/credentials >> /app/.env
        else
            echo "WARN: Garage S3 credentials not found. S3 storage will not work until garage-init completes." >&2
        fi
    fi
else
    # Production: cache config on first startup (not at build time,
    # because .env is excluded from the Docker build context)
    if [ -f /app/artisan ] && [ ! -f /app/bootstrap/cache/config.php ]; then
        php artisan config:cache
    fi
fi

exec "$@"
