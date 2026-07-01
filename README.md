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

## Staging-Umgebung (saisonmanager.dev)

Staging läuft auf **demselben Server** wie Prod, in **demselben Compose-Projekt**,
aber vollständig isoliert: eigener Rails-Container, eigenes Postgres + Volume,
eigener API-Checkout (Branch `staging`), eigenes Frontend-Verzeichnis und ein
Mailpit-Catcher statt echtem Mailversand. Der nginx-Container wird geteilt –
`saisonmanager.dev` ist ein zusätzlicher Server-Block (`saisonmanager.staging.conf`),
der **serverseitig** in die (untracked) `nginx.prod.conf` eingebunden wird – und
zwar bewusst erst **nach** der Cert-Ausstellung (siehe Einrichtung), damit ein
fehlendes Cert nie einen Prod-`nginx -t`/Deploy umwirft.

| Service | Container | Isolation |
|---|---|---|
| `rails-api-staging` | `saisonmanager_rails_api_staging` | Branch `staging`, neutralisierte Secrets |
| `postgres-staging` | `saisonmanager_postgres_staging` | Volume `postgres_staging_data`, Host-Port 49301 |
| `mailpit` | `saisonmanager_mailpit` | fängt alle Mails, UI unter `/mailpit/` |

Compose-Aufruf (Basis + Prod-Overlay + Staging-Overlay):

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.staging.yml <command>
```

### Einmalige Server-Einrichtung

```bash
# 1) DNS: A-Record saisonmanager.dev -> 178.104.133.109 (beim Registrar)

# 2) Staging-API-Checkout auf Branch `staging`
git clone <api-repo> /opt/saisonmanager/saisonmanager-api-staging
cd /opt/saisonmanager/saisonmanager-api-staging && git checkout staging

# 3) Frontend-Zielverzeichnis anlegen (Staging-App)
mkdir -p /opt/saisonmanager/saisonmanager-frontend-staging

# 4) Staging-Secret setzen (untracked .env im docker-Verzeichnis)
echo "SM_STAGING_SECRET_KEY_BASE=$(openssl rand -hex 64)" \
  >> /opt/saisonmanager/saisonmanager-docker/.env

# 5) Let's-Encrypt-Cert für saisonmanager.dev AUSSTELLEN, BEVOR der Staging-Vhost
#    aktiv ist. Die ACME-Challenge wird in diesem Moment vom Default-:80-Server
#    aus dem Prod-Frontend-Verzeichnis ausgeliefert -> daher dort als Webroot.
#    (.dev ist HSTS-preloaded -> HTTPS ab dem ersten Aufruf Pflicht.)
git -C /opt/saisonmanager/saisonmanager-docker pull origin main   # bringt saisonmanager.staging.conf
certbot certonly --webroot \
  -w /opt/saisonmanager/saisonmanager-frontend \
  -d saisonmanager.dev

# 6) Staging-Vhost ERST JETZT (Cert existiert) serverseitig einbinden:
#    in die untracked nginx.prod.conf den include ergänzen.
grep -q 'saisonmanager.staging.conf' /opt/saisonmanager/saisonmanager-docker/nginx/config/nginx.prod.conf \
  || echo '    include /etc/nginx/saisonmanager.staging.conf;' \
       >> /opt/saisonmanager/saisonmanager-docker/nginx/config/nginx.prod.conf
# (Hinweis: die Zeile muss INNERHALB des http{}-Blocks stehen – ggf. von Hand
#  an die richtige Stelle setzen, analog zum bestehenden saisonmanager.prod.conf-include.)

# 7) Stack hochziehen. nginx einmalig RECREATE (nicht nur reload), damit der
#    neue Staging-FE-Mount tatsächlich im Container landet.
cd /opt/saisonmanager/saisonmanager-docker
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.staging.yml \
  up -d nginx postgres-staging mailpit rails-api-staging

# 8) Staging-DB initial mit anonymisiertem Prod-Klon befüllen
./scripts/staging-db-refresh.sh
```

> Der `include` in Schritt 6 lebt in der **untracked** `nginx.prod.conf` (nicht
> im Repo), damit ein Merge dieses PRs den Prod-nginx nicht verändert. Dadurch
> ist die Aktivierung von Staging vom Merge- und Cert-Timing entkoppelt.

### Laufender Betrieb

```bash
# Staging deployen (Branch `staging`), Prod bleibt unberührt
ssh saisonmanager /opt/saisonmanager/saisonmanager-docker/deploy-staging.sh

# Frontend separat bauen/deployen (im Frontend-Repo)
./build-deploy-staging.sh

# Staging-DB erneut aus Prod auffrischen (anonymisiert).
# Kopiert zusätzlich die ActiveStorage-Dateien (Logos/Banner) von Prod nach
# Staging – sonst zeigt die öffentliche Ansicht gebrochene Logos.
ssh saisonmanager /opt/saisonmanager/saisonmanager-docker/scripts/staging-db-refresh.sh
```

> `staging-db-refresh.sh` setzt über `staging:anonymize` **alle** Login-Passwörter
> auf `staging-password` zurück. Abweichende Test-Passwörter (z. B. für Demo-Logins)
> müssen nach jedem Refresh erneut gesetzt werden.

**Workflow:** PR → Merge nach `staging` → auf `saisonmanager.dev` testen →
erst dann Merge nach `main` → Prod-`deploy.sh`.

Die secret-behaftete `.env` und die (untracked) `docker-compose.prod.yml`
bleiben wie bisher serverseitig und werden nie eingecheckt.
