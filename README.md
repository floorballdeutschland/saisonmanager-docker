# Saisonmanager – Docker

Docker Compose setup for local development of the Floorball Saisonmanager.

## Related Repositories

| Repo | Description |
|---|---|
| [saisonmanager](https://github.com/floorballverband-deutschland/saisonmanager) | Angular 18 frontend |
| [saisonmanager-api](https://github.com/floorballverband-deutschland/saisonmanager-api) | Rails 7 API backend |
| [saisonmanager-docker](https://github.com/floorballverband-deutschland/saisonmanager-docker) | This repo – Docker Compose setup |

## Services

| Service | Port | Description |
|---|---|---|
| `rails-api` | 3001 | Rails 7 API |
| `postgres` | 5432 | PostgreSQL database |
| `nginx` | 80/443 | Reverse proxy (production/staging only) |

## Prerequisites

- Docker and Docker Compose
- The three repos checked out as siblings:

```
~/saisonmanager/          ← Angular frontend
~/saisonmanager-api/      ← Rails API
~/saisonmanager-docker/   ← This repo
```

## Quick Start

```bash
cd ~/saisonmanager-docker

# Start the database
docker compose -f docker-compose.yml -f docker-compose.dev.yml up postgres -d

# Start the API (→ http://localhost:3001)
docker compose -f docker-compose.yml -f docker-compose.dev.yml up rails-api -d

# First-time database setup
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm rails-api \
  bundle exec rails db:migrate RAILS_ENV=development

docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm rails-api \
  bundle exec rails db:seed RAILS_ENV=development

# Start the frontend (separate terminal, in ~/saisonmanager)
npm start   # → http://localhost:4200
```

The frontend by default points to `https://sm.jholocal.de/api/v2/`. For fully local development, change `apiURL` in `src/environments/environment.ts` to `http://localhost:3001/api/v2/`.

## Compose Files

| File | Purpose |
|---|---|
| `docker-compose.yml` | Base service definitions (production-compatible) |
| `docker-compose.dev.yml` | Dev overrides: volume mounts, port bindings, dev env vars |

Always layer both files for local development:

```bash
docker compose -f docker-compose.yml -f docker-compose.dev.yml <command>
```

## Common Operations

```bash
# Run a one-off Rails command
docker compose -f docker-compose.yml -f docker-compose.dev.yml run --rm rails-api \
  bundle exec rails <command> RAILS_ENV=development

# View API logs
docker compose -f docker-compose.yml -f docker-compose.dev.yml logs -f rails-api

# Stop everything
docker compose -f docker-compose.yml -f docker-compose.dev.yml down

# Restart just the API (e.g. after code changes)
docker compose -f docker-compose.yml -f docker-compose.dev.yml restart rails-api
```

## Database Notes

- Use `rails db:migrate`, not `rails db:schema:load` — the schema was bootstrapped from the initial migration file, and `db:schema:load` fails in Docker due to a Unix socket issue.
- The database runs on the default PostgreSQL port 5432 inside the container network.

## Production Deployment

Production uses the base `docker-compose.yml` only (no dev overrides). After pushing changes to GitHub, deploy via:

```bash
ssh saisonmanager /opt/saisonmanager/deploy.sh
```

The deploy script:
1. `git pull` on this repo
2. `git reset --hard origin/main` on `saisonmanager-api`
3. Restarts `nginx` and `rails-api` containers

**Production server:** `root@178.104.133.109` (SSH via YubiKey `~/.ssh/yubikey`)
Docker setup lives at `/opt/saisonmanager/saisonmanager-docker/`.
