# ============================================================
# Stage 1: base -- runtime shared between dev and prod
# ============================================================
# PHP 8.5 released Nov 2025. Change to php8.4 if needed.
FROM dunglas/frankenphp:1-php8.5-trixie AS base

ARG USER_UID=1000
ARG USER_GID=1000

# PHP extensions (install-php-extensions pulls build deps and keeps only runtime libs)
RUN install-php-extensions \
    pcntl \
    pdo_pgsql \
    redis \
    zip \
    gd \
    intl \
    opcache \
    bcmath

# Non-root user matching host UID/GID
RUN groupadd --force --gid ${USER_GID} appuser \
    && useradd --non-unique --uid ${USER_UID} --gid ${USER_GID} --create-home appuser \
    && chown -R appuser:appuser /data/caddy /config/caddy

WORKDIR /app

# ============================================================
# Stage 2: tools -- Composer and Bun (dev and build only, not in prod)
# ============================================================
FROM base AS tools

RUN apt-get update && apt-get install -y --no-install-recommends \
    unzip \
    git \
    && rm -rf /var/lib/apt/lists/*

COPY --from=composer:2 /usr/bin/composer /usr/bin/composer
COPY --from=oven/bun:1 /usr/local/bin/bun /usr/local/bin/bun

ENV COMPOSER_HOME=/home/appuser/.composer
RUN mkdir -p ${COMPOSER_HOME} && chown -R appuser:appuser ${COMPOSER_HOME}
ENV PATH="${COMPOSER_HOME}/vendor/bin:${PATH}"

# ============================================================
# Stage 3: dev -- local development
# ============================================================
FROM tools AS dev

RUN install-php-extensions xdebug

# Laravel Installer (only needed in dev for `laravel new`)
USER appuser
RUN composer global require laravel/installer:^5
USER root

COPY docker/app/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER appuser

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]

# ============================================================
# Stage 4: builder -- install deps and build assets for prod
# ============================================================
FROM tools AS builder

ENV COMPOSER_ALLOW_SUPERUSER=1

COPY ./src /app

RUN composer install --no-dev --optimize-autoloader --no-interaction

RUN bun install && bun run build && rm -rf node_modules

# NOTE: config:cache is NOT run at build time because .env is excluded from the
# build context. Runtime env vars would be ignored. Instead, entrypoint.sh
# caches config on first startup in production.
RUN php artisan route:cache \
    && php artisan view:cache \
    && php artisan event:cache

# ============================================================
# Stage 5: prod -- production image (no build tools)
# ============================================================
FROM base AS prod

# Container filesystems are ephemeral; send logs to the platform's log collector
ENV LOG_CHANNEL=stderr

# Base image loads no php.ini, so PHP defaults to display_errors=On
RUN cp "$PHP_INI_DIR/php.ini-production" "$PHP_INI_DIR/php.ini"
COPY docker/app/php/php.ini /usr/local/etc/php/conf.d/app-php.ini
COPY docker/app/Caddyfile.prod /etc/caddy/Caddyfile
COPY docker/app/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Code stays root-owned so a compromised app cannot rewrite itself; only runtime dirs are writable
COPY --from=builder /app /app
RUN chown -R appuser:appuser /app/storage /app/bootstrap/cache

USER appuser

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
