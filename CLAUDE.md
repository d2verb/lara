# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What This Project Is

A Laravel installer (`curl | sh`) that scaffolds new projects with a production-ready Docker setup: FrankenPHP, PostgreSQL, Redis, RustFS (S3), pgweb, Bun, mise. The repo contains only the installer and templates — no Laravel code.

## Repository Structure

```
install.sh              # Entry point: curl | sh
templates/              # Copied into generated projects
  compose.yaml
  mise.toml
  .dockerignore
  docker/app/
    Dockerfile          # Multi-stage: base → dev / prod
    entrypoint.sh
    Caddyfile           # Dev (bind-mounted)
    Caddyfile.prod      # Prod (COPY'd into image)
    php/
      php.ini           # Dev: bind-mounted, Prod: COPY'd
      xdebug.ini        # Dev only (bind-mounted)
```

## Testing Changes Locally

```sh
LARA_LOCAL=./templates ./install.sh testapp --vue --pest
cd testapp && docker compose up -d
# Wait ~50s for entrypoint to install deps, then:
curl -s -o /dev/null -w "%{http_code}" http://localhost:8080  # → 200
docker compose exec app php artisan migrate --force           # → DONE
```

Clean up: `cd testapp && docker compose down -v && cd .. && rm -rf testapp`

Lint: `shellcheck install.sh`

## Key Architecture Decisions

**Two .env files**: Root `.env` is for Docker Compose (`DB_PASSWORD`, ports). `src/.env` is for Laravel (`DB_HOST=postgres`, `REDIS_HOST=redis`). Both have the same `DB_PASSWORD` value but serve different consumers.

**`docker run` vs `docker compose run`**: install.sh uses `docker run --entrypoint ""` for `laravel new` and `composer require` because `docker compose run` applies volume mounts that make `/app` non-empty, causing `laravel new` to fail.

**Container WORKDIR is `/app`**: `src/` separation is host-only. Dev bind-mounts `./src:/app`. Prod copies `./src /app`. Container always sees Laravel at `/app`.

**Config caching deferred to runtime**: `.env` is excluded from Docker build context (`.dockerignore`), so `config:cache` runs in entrypoint.sh on first prod startup. Routes/views/events are cached at build time (environment-agnostic).

**Port 8080 (not 80)**: Avoids `setcap` requirement for non-root user binding to privileged ports. Cloud Run defaults to 8080.

**Dev config files are bind-mounted**: Caddyfile, php.ini, xdebug.ini are mounted `:ro` in compose.yaml for live editing. Only entrypoint.sh is COPY'd into the dev image. Prod COPY's everything.

**No `name:` in compose.yaml**: Docker Compose uses directory name as project name, making volumes unique per project (e.g., `myapp_postgres_data`).

## Gotchas

- **`laravel new` outputs DB connection errors during install** — expected. `DB_CONNECTION=sqlite` is passed to prevent PostgreSQL connection attempts, but the starter kit may still try migrations. Install completes successfully regardless.
- **Vite `--no-ansi` error during install** — Vite 8.x doesn't support this flag. `laravel new` passes it internally. Cosmetic; frontend build runs via `mise run frontend` in dev.
- **`password authentication failed` after migrate** — likely a stale Postgres volume from a previous project. Run `docker compose down -v && docker compose up -d` to reset.
- **`sed` patches in install.sh depend on Laravel's `.env` format** — if Laravel changes variable names in a major version, sed patterns will need updating. Values (`s|VAR=.*|VAR=newval|`) are resilient to default value changes.
