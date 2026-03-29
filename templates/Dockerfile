# ============================================================
# Stage 1: base -- shared between dev and prod
# ============================================================
# PHP 8.5 released Nov 2025. Change to php8.4 if needed.
FROM dunglas/frankenphp:1-php8.5-bookworm AS base

ARG USER_UID=1000
ARG USER_GID=1000

# System dependencies
RUN apt-get update && apt-get install -y --no-install-recommends \
    unzip \
    git \
    curl \
    libpq-dev \
    libzip-dev \
    libicu-dev \
    libfreetype6-dev \
    libjpeg62-turbo-dev \
    libpng-dev \
    && rm -rf /var/lib/apt/lists/*

# PHP extensions
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
    && setcap CAP_NET_BIND_SERVICE=+eip /usr/local/bin/frankenphp \
    && chown -R appuser:appuser /data/caddy /config/caddy

# Composer
COPY --from=composer:2 /usr/bin/composer /usr/bin/composer

# Bun
RUN curl -fsSL https://bun.sh/install | bash \
    && mv /root/.bun/bin/bun /usr/local/bin/bun \
    && chmod +x /usr/local/bin/bun

ENV COMPOSER_HOME=/home/appuser/.composer
RUN mkdir -p ${COMPOSER_HOME} && chown -R appuser:appuser ${COMPOSER_HOME}
ENV PATH="${COMPOSER_HOME}/vendor/bin:${PATH}"

WORKDIR /app

# Pre-create named volume mount points with correct ownership.
# Without this, Docker creates them as root and appuser can't write to them.
RUN mkdir -p /app/vendor /app/node_modules \
    && chown -R appuser:appuser /app

# ============================================================
# Stage 2: dev -- local development
# ============================================================
FROM base AS dev

RUN install-php-extensions xdebug

# Laravel Installer (only needed in dev for `laravel new`)
USER appuser
RUN composer global require laravel/installer
USER root

RUN echo "xdebug.mode=\${XDEBUG_MODE:-off}" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini \
    && echo "xdebug.client_host=host.docker.internal" >> /usr/local/etc/php/conf.d/docker-php-ext-xdebug.ini

COPY Caddyfile /etc/caddy/Caddyfile
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

USER appuser

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]

# ============================================================
# Stage 3: prod -- production build
# ============================================================
FROM base AS prod

# Copy Caddyfile and entrypoint first (as root, these need root ownership in /etc and /usr/local)
COPY Caddyfile.prod /etc/caddy/Caddyfile
COPY docker/entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

# Switch to non-root user for all app operations
USER appuser

COPY --chown=appuser:appuser . /app

RUN composer install --no-dev --optimize-autoloader --no-interaction

RUN bun install && bun run build

# NOTE: config:cache is NOT run at build time because .env is excluded from the
# build context. Runtime env vars would be ignored. Instead, entrypoint.sh
# caches config/routes/views on first startup in production.
RUN php artisan route:cache \
    && php artisan view:cache \
    && php artisan event:cache

RUN rm -rf tests .git .github node_modules

ENTRYPOINT ["/usr/local/bin/entrypoint.sh"]
CMD ["frankenphp", "run", "--config", "/etc/caddy/Caddyfile"]
