# lara

Production-ready Laravel installer with Docker.

Sets up a Laravel project with FrankenPHP, PostgreSQL, Redis, and RustFS (S3-compatible storage) — ready for local development and production deployment (ECS, Cloud Run, etc.).

## Quick Start

```sh
curl -sL https://raw.githubusercontent.com/d2verb/lara/main/install.sh | sh -s myapp
```

With starter kit options:

```sh
curl -sL https://raw.githubusercontent.com/d2verb/lara/main/install.sh | sh -s myapp --vue --pest
```

When run via `curl | sh`, `--no-interaction` is automatically added. Pass flags explicitly (e.g. `--vue`, `--react`, `--livewire`) to select a starter kit.

## Prerequisites

- [Docker](https://docs.docker.com/get-docker/) (with Compose V2)
- [mise](https://mise.jdx.dev/) (optional, for task runner)

## Project Structure

```
myapp/
├── docker/
│   └── app/
│       ├── Dockerfile       # Multi-stage (dev / prod)
│       ├── entrypoint.sh    # Container entrypoint
│       ├── Caddyfile        # FrankenPHP config (dev)
│       ├── Caddyfile.prod   # FrankenPHP config (prod)
│       └── php/
│           ├── php.ini      # PHP config (opcache, upload limits)
│           └── xdebug.ini   # Xdebug config (dev only)
├── src/                     # Laravel source code
│   ├── app/
│   ├── routes/
│   ├── config/
│   ├── public/
│   └── ...
├── compose.yaml             # Docker Compose services
├── mise.toml                # Task runner
└── .dockerignore
```

Docker configuration lives in `docker/app/`. Laravel code lives in `src/`.

## Usage

```sh
cd myapp

# Start all services
mise run dev

# Run database migrations
mise run migrate

# Open http://localhost:8080 in your browser
# RustFS console: http://localhost:8080:9001
```

## Available Tasks

| Task | Description |
|------|-------------|
| `mise run dev` | Start all services |
| `mise run down` | Stop all services |
| `mise run restart` | Restart all services |
| `mise run migrate` | Run database migrations |
| `mise run migrate-fresh` | Drop all tables and re-run migrations |
| `mise run seed` | Run database seeders |
| `mise run test` | Run test suite |
| `mise run test-coverage` | Run tests with coverage |
| `mise run tinker` | Open Laravel Tinker REPL |
| `mise run shell` | Open a shell in the app container |
| `mise run logs [service]` | Tail container logs |
| `mise run artisan <cmd>` | Run an artisan command |
| `mise run composer <cmd>` | Run a Composer command |
| `mise run bun <cmd>` | Run a Bun command |
| `mise run frontend` | Start Vite dev server |
| `mise run format` | Run Laravel Pint formatter |
| `mise run lint` | Run static analysis (Larastan) |
| `mise run build [tag]` | Build production Docker image |

## Tech Stack

- **[FrankenPHP](https://frankenphp.dev/)** — PHP 8.5, modern application server
- **[PostgreSQL](https://www.postgresql.org/)** 17 — Database
- **[Redis](https://redis.io/)** 7 — Cache, sessions, queues
- **[RustFS](https://rustfs.com/)** — S3-compatible object storage (with web console)
- **[Bun](https://bun.sh/)** — Frontend tooling
- **[mise](https://mise.jdx.dev/)** — Task runner

## Docker Architecture

### Multi-stage Dockerfile

- **base** — PHP extensions, Composer, Bun, non-root user setup
- **dev** — Adds Xdebug, Laravel Installer, mounts source code via bind mount
- **prod** — Copies `src/` only, optimizes autoloader, caches routes/views/events

### Services (compose.yaml)

| Service | Purpose | Port |
|---------|---------|------|
| app | FrankenPHP + Laravel | 80, 5173 |
| postgres | PostgreSQL database | 5432 |
| redis | Cache / Sessions / Queues | 6379 |
| rustfs | S3-compatible storage + web console | 9000, 9001 |
| rustfs-init | One-shot: creates the default S3 bucket | — |

## Production Deployment

Build the production image:

```sh
mise run build myapp:v1.0.0
# or
docker build -f docker/app/Dockerfile --target prod -t myapp:v1.0.0 .
```

The production image contains only `src/` with cached routes, views, events, and compiled frontend assets. Config is cached on first startup via the entrypoint.

Configure environment variables at runtime (switch to real AWS S3 by omitting `AWS_ENDPOINT`):

```sh
docker run -e APP_KEY=base64:... \
  -e DB_HOST=your-rds-endpoint \
  -e REDIS_HOST=your-elasticache-endpoint \
  -e AWS_ACCESS_KEY_ID=... \
  -e AWS_SECRET_ACCESS_KEY=... \
  -p 8080:8080 myapp:v1.0.0
```

## License

MIT
