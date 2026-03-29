#!/bin/sh
set -e

# ============================================================
# lara - Laravel Installer with Docker (FrankenPHP)
# ============================================================
# Usage:
#   curl -sL https://raw.githubusercontent.com/d2verb/lara/main/install.sh | sh -s myapp
#   curl -sL https://raw.githubusercontent.com/d2verb/lara/main/install.sh | sh -s myapp --vue --pest
# ============================================================

REPO_URL="https://github.com/d2verb/lara"
BRANCH="main"

# --- Colors ---
if [ -t 1 ]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[0;33m'
    BOLD='\033[1m'
    RESET='\033[0m'
else
    RED='' GREEN='' YELLOW='' BOLD='' RESET=''
fi

info()  { printf '%s[lara]%s %s\n' "$GREEN" "$RESET" "$1"; }
warn()  { printf '%s[lara]%s %s\n' "$YELLOW" "$RESET" "$1"; }
error() { printf '%s[lara]%s %s\n' "$RED" "$RESET" "$1" >&2; exit 1; }
step()  { printf '\n%s[%s]%s %s\n' "$BOLD" "$1" "$RESET" "$2"; }

# --- Parse arguments ---
# First non-flag argument is the project name; the rest are passed to `laravel new`
# e.g. `install.sh myapp --vue --pest` → PROJECT_NAME=myapp, LARAVEL_FLAGS="--vue --pest"
PROJECT_NAME=""
LARAVEL_FLAGS=""

for arg in "$@"; do
    if [ -z "$PROJECT_NAME" ] && echo "$arg" | grep -qv '^-'; then
        PROJECT_NAME="$arg"
    else
        LARAVEL_FLAGS="$LARAVEL_FLAGS $arg"
    fi
done

if [ -z "$PROJECT_NAME" ]; then
    printf '%sProject name: %s' "$BOLD" "$RESET" > /dev/tty
    read -r PROJECT_NAME < /dev/tty
fi

if [ -z "$PROJECT_NAME" ]; then
    error "Project name is required."
fi

if ! echo "$PROJECT_NAME" | grep -qE '^[a-zA-Z0-9_-]+$'; then
    error "Project name must only contain letters, numbers, hyphens, and underscores."
fi

if [ -d "$PROJECT_NAME" ]; then
    error "Directory '$PROJECT_NAME' already exists."
fi

# --- Check prerequisites ---
step "1/6" "Checking prerequisites..."

if ! command -v docker > /dev/null 2>&1; then
    error "Docker is not installed. Please install Docker first: https://docs.docker.com/get-docker/"
fi

if ! docker compose version > /dev/null 2>&1; then
    error "Docker Compose V2 is not available. Please update Docker."
fi

if ! docker info > /dev/null 2>&1; then
    error "Docker is not running. Please start Docker and try again."
fi

info "All prerequisites are ready."

# --- Create project directory ---
step "2/6" "Creating project directory..."

PROJECT_DIR="$(pwd)/$PROJECT_NAME"
# On failure, remove the partially created project directory
trap 'if [ $? -ne 0 ] && [ -d "$PROJECT_DIR" ]; then warn "Cleaning up..."; rm -rf "$PROJECT_DIR"; fi' EXIT
mkdir -p "$PROJECT_DIR"

# --- Download templates ---
step "3/6" "Downloading template files..."

if [ -n "$LARA_LOCAL" ]; then
    # Local development: copy from local templates directory
    cp -r "$LARA_LOCAL"/. "$PROJECT_DIR/"
else
    LARA_TMPDIR=$(mktemp -d)
    curl -sL "$REPO_URL/archive/refs/heads/$BRANCH.tar.gz" \
        | tar xz -C "$LARA_TMPDIR" --strip-components=2 "lara-$BRANCH/templates/"
    cp -r "$LARA_TMPDIR"/. "$PROJECT_DIR/"
    rm -rf "$LARA_TMPDIR"
fi

cd "$PROJECT_DIR"

# Generate secrets
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
S3_SECRET_KEY=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
USER_UID=$(id -u)
USER_GID=$(id -g)

info "Template files ready."

# --- Build Docker image ---
step "4/6" "Building Docker image (this may take a few minutes on first run)..."

# No .env file at build time — compose.yaml has defaults for all variables.
USER_UID="$USER_UID" USER_GID="$USER_GID" docker compose build app

info "Docker image built."

# --- Create Laravel project ---
step "5/6" "Creating Laravel project..."

# If stdin is not a TTY (curl | sh), add --no-interaction to prevent hanging prompts
if [ ! -t 0 ]; then
    LARAVEL_FLAGS="$LARAVEL_FLAGS --no-interaction"
fi

# Use `docker run` (not `docker compose run`) to avoid named volume mounts
# that would make /app non-empty and cause `laravel new` to fail.
# --entrypoint "" skips entrypoint.sh (which would run config:cache in non-local mode).
APP_IMAGE="${APP_NAME:-laravel}-app"
mkdir -p src
# shellcheck disable=SC2086
docker run --rm --entrypoint "" -u "$USER_UID:$USER_GID" -v "$(pwd)/src:/app" "$APP_IMAGE" \
    laravel new /app --database=pgsql --bun $LARAVEL_FLAGS

# Install additional packages
docker run --rm --entrypoint "" -u "$USER_UID:$USER_GID" -v "$(pwd)/src:/app" "$APP_IMAGE" \
    sh -c "composer require league/flysystem-aws-s3-v3 --no-interaction && composer require --dev larastan/larastan --no-interaction"

# Larastan config
cat > src/phpstan.neon <<'PHPSTAN'
includes:
    - vendor/larastan/larastan/extension.neon

parameters:
    paths:
        - app/
    level: 5
PHPSTAN

cat >> .gitignore <<'GITIGNORE'
docker-compose.override.yaml
.env
GITIGNORE

info "Laravel project created."

# --- Configure .env for Docker ---
step "6/6" "Configuring .env for Docker..."

# Root .env — read by Docker Compose for service configuration
cat > .env <<ENV_EOF
# Docker Compose variables (used by compose.yaml)
APP_PORT=8080
VITE_PORT=5173
USER_UID=$USER_UID
USER_GID=$USER_GID
XDEBUG_MODE=off
DB_DATABASE=laravel
DB_USERNAME=laravel
DB_PASSWORD=$DB_PASSWORD
DB_FORWARD_PORT=5432
REDIS_FORWARD_PORT=6379
AWS_ACCESS_KEY_ID=laravel
AWS_SECRET_ACCESS_KEY=$S3_SECRET_KEY
AWS_BUCKET=laravel
S3_PORT=9000
S3_CONSOLE_PORT=9001
ENV_EOF

# src/.env — read by Laravel for application configuration
sed -i.bak \
    -e "s|DB_HOST=127.0.0.1|DB_HOST=postgres|" \
    -e "s|DB_HOST=localhost|DB_HOST=postgres|" \
    -e "s|DB_DATABASE=.*|DB_DATABASE=laravel|" \
    -e "s|DB_USERNAME=.*|DB_USERNAME=laravel|" \
    -e "s|DB_PASSWORD=.*|DB_PASSWORD=$DB_PASSWORD|" \
    -e "s|REDIS_HOST=127.0.0.1|REDIS_HOST=redis|" \
    -e "s|REDIS_HOST=localhost|REDIS_HOST=redis|" \
    -e "s|CACHE_STORE=.*|CACHE_STORE=redis|" \
    -e "s|SESSION_DRIVER=.*|SESSION_DRIVER=redis|" \
    -e "s|QUEUE_CONNECTION=.*|QUEUE_CONNECTION=redis|" \
    -e "s|FILESYSTEM_DISK=.*|FILESYSTEM_DISK=s3|" \
    -e "s|AWS_ACCESS_KEY_ID=.*|AWS_ACCESS_KEY_ID=laravel|" \
    -e "s|AWS_SECRET_ACCESS_KEY=.*|AWS_SECRET_ACCESS_KEY=$S3_SECRET_KEY|" \
    -e "s|AWS_DEFAULT_REGION=.*|AWS_DEFAULT_REGION=us-east-1|" \
    -e "s|AWS_BUCKET=.*|AWS_BUCKET=laravel|" \
    -e "s|AWS_USE_PATH_STYLE_ENDPOINT=.*|AWS_USE_PATH_STYLE_ENDPOINT=true|" \
    src/.env && rm -f src/.env.bak

# AWS_ENDPOINT is not in Laravel's default .env, so append it
echo "AWS_ENDPOINT=http://rustfs:9000" >> src/.env

info "Done."

# --- Done ---
cat <<DONE

${GREEN}============================================================${RESET}
${BOLD}  Your Laravel project is ready!${RESET}
${GREEN}============================================================${RESET}

  ${BOLD}Next steps:${RESET}

    cd $PROJECT_NAME
    mise run dev          ${YELLOW}# Start all services${RESET}
    mise run migrate      ${YELLOW}# Run database migrations${RESET}

    Open ${BOLD}http://localhost:8080${RESET} in your browser.

  ${BOLD}Useful commands:${RESET}

    mise run dev          Start all services
    mise run down         Stop all services
    mise run migrate      Run database migrations
    mise run test         Run tests
    mise run tinker       Open Laravel Tinker
    mise run logs         Tail container logs
    mise run shell        Open a shell in the app container
    mise run frontend     Start Vite dev server
    mise run build TAG    Build production Docker image

DONE
