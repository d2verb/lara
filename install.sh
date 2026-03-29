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

info()  { printf "${GREEN}[lara]${RESET} %s\n" "$1"; }
warn()  { printf "${YELLOW}[lara]${RESET} %s\n" "$1"; }
error() { printf "${RED}[lara]${RESET} %s\n" "$1" >&2; exit 1; }
step()  { printf "\n${BOLD}[%s]${RESET} %s\n" "$1" "$2"; }

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
    printf "${BOLD}Project name: ${RESET}" > /dev/tty
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

# Generate secrets and configure garage.toml
DB_PASSWORD=$(openssl rand -base64 24 | tr -d '/+=' | head -c 32)
GARAGE_RPC_SECRET=$(openssl rand -hex 32)
GARAGE_ADMIN_TOKEN="lara-admin-$(openssl rand -hex 8)"
USER_UID=$(id -u)
USER_GID=$(id -g)

sed -i.bak -e "s|__GARAGE_RPC_SECRET__|$GARAGE_RPC_SECRET|" -e "s|__GARAGE_ADMIN_TOKEN__|$GARAGE_ADMIN_TOKEN|" docker/garage/garage.toml && rm -f docker/garage/garage.toml.bak

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

docker compose run --rm --no-deps -T app \
    laravel new /app/tmp --database=pgsql --bun $LARAVEL_FLAGS

# Copy Laravel files into the project root.
# - "* .[!.]* ..?*" matches all files including dotfiles (e.g. .env, .gitignore)
# - Docker infra files are skipped (we already placed them in step 3)
# - vendor/node_modules are skipped (they live in named Docker volumes
#   and will be installed by entrypoint.sh on first startup)
# - cp -a instead of mv because some directories already exist (bootstrap/, storage/)
docker compose run --rm --no-deps -T app sh -c '
    cd /app/tmp
    for item in * .[!.]* ..?*; do
        [ -e "$item" ] || continue
        case "$item" in
            Dockerfile|compose.yaml|Caddyfile|Caddyfile.prod|mise.toml|docker|.dockerignore) ;;
            vendor|node_modules) ;;
            *) cp -a "$item" /app/ ;;
        esac
    done
    rm -rf /app/tmp
'

# Install S3 driver for Garage
docker compose run --rm --no-deps -T app composer require league/flysystem-aws-s3-v3 --no-interaction

echo "docker-compose.override.yaml" >> .gitignore

info "Laravel project created."

# --- Configure .env for Docker ---
step "6/6" "Configuring .env for Docker..."

# Patch Laravel-generated .env (already has APP_KEY and Laravel defaults)
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
    .env && rm -f .env.bak

# Append variables that Laravel doesn't generate
cat >> .env <<ENV_EOF

# Docker
APP_PORT=80
VITE_PORT=5173
USER_UID=$USER_UID
USER_GID=$USER_GID
XDEBUG_MODE=off
DB_FORWARD_PORT=5432
REDIS_FORWARD_PORT=6379

# S3 / Garage (credentials are injected at runtime by entrypoint.sh via shared volume)
FILESYSTEM_DISK=s3
AWS_DEFAULT_REGION=garage
AWS_BUCKET=laravel
AWS_ENDPOINT=http://garage:3900
AWS_USE_PATH_STYLE_ENDPOINT=true

# Garage (used by compose.yaml)
GARAGE_S3_PORT=3900
GARAGE_ADMIN_PORT=3903
GARAGE_ADMIN_TOKEN=$GARAGE_ADMIN_TOKEN
GARAGE_RPC_SECRET=$GARAGE_RPC_SECRET
ENV_EOF

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

    Open ${BOLD}http://localhost${RESET} in your browser.

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
