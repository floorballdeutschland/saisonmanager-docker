# Saisonmanager – Docker

Docker Compose setup for local development of the Floorball Saisonmanager.

## Related Repositories

| Repo | Description |
|---|---|
| [saisonmanager](https://github.com/floorballdeutschland/saisonmanager) | Angular frontend |
| [saisonmanager-api](https://github.com/floorballdeutschland/saisonmanager-api) | Rails 7 API backend |
| [saisonmanager-docker](https://github.com/floorballdeutschland/saisonmanager-docker) | This repo – Docker Compose setup |

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

For fully local development, point `apiURL` in `src/environments/environment.ts` to `http://localhost:3001/api/v2/`.

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
3. Restarts `nginx` and `rails-api` containers (`rails-api` pulls up `redis`
   via `depends_on`; the cache service is not named explicitly)

**Production server:** reachable via the `ssh saisonmanager` alias (host, user, and key live in the maintainer's local `~/.ssh/config`; hardware-key auth).
Docker setup lives at `/opt/saisonmanager/saisonmanager-docker/`.

## Host-Konfiguration (Logs)

Dateien unter `host/` gehoeren nicht in einen Container, sondern auf den Server.
Sie liegen hier, damit sie versioniert sind; installiert werden sie als Kopie:

```bash
install -m 644 -o root -g root host/logrotate/saisonmanager-nginx /etc/logrotate.d/saisonmanager-nginx
install -m 644 -o root -g root host/logrotate/saisonmanager-cron /etc/logrotate.d/saisonmanager-cron
install -D -m 644 -o root -g root host/journald/50-saisonmanager-groesse.conf /etc/systemd/journald.conf.d/50-saisonmanager-groesse.conf
systemctl restart systemd-journald
logrotate -d /etc/logrotate.d/saisonmanager-nginx   # Trockenlauf
logrotate -d /etc/logrotate.d/saisonmanager-cron
```

Nach einer Aenderung hier erneut installieren, `deploy.sh` tut das nicht.
Die Container-Logs (json-file) begrenzt `x-logging` in `docker-compose.yml`.

Stand 09.11.2026 vor der Einfuehrung: 85 % Platte, davon 28,9 GB nginx-Zugriffslog,
9 GB Rails-Containerlog, 4 GB Journal. Die Uploads machten nur 3,3 GB aus.

### Plattenplatz: was waechst und wo die Grenze ist

Jede Quelle, die von selbst waechst, braucht eine Grenze. Wer einen neuen
Automatismus einfuehrt (Cronjob mit Logdatei, Dump, Export), traegt ihn hier ein.

| Quelle | Grenze | Wo geregelt |
|---|---|---|
| Container-Logs (json-file) | 200 MB x 10 je Container (2 GB, bei 8 Containern hoechstens 16 GB) | `x-logging` in `docker-compose.yml` |
| nginx-Logs | 14 Tage | `host/logrotate/saisonmanager-nginx` |
| Logs der Cronjobs | 8 Wochen | `host/logrotate/saisonmanager-cron` (feste Liste) |
| Journal | feste Groesse | `host/journald/50-saisonmanager-groesse.conf` |
| Datenbank-Dumps | 10 vor Deploys, 14 taeglich, Abbruch unter 2 GB frei | `scripts/db-backup.sh` |
| Alte Images nach dem Neubau | werden geloescht | Ende von `deploy.sh` / `deploy-staging.sh` |
| Build-Cache | aelter als 7 Tage weg | Cronjob `docker builder prune` (unten) |
| Uploads (ActiveStorage), Datenbank | fachlich, keine feste Grenze | Warnmail bei 80/90 % (`rake system:disk_check`, taeglich) |

Cronjob fuer den Build-Cache (woechentlich, ersetzt die fruehere Monatszeile mit
30 Tagen; ein Rebuild mit neuem Ruby legt mehrere GB Cache an):

```bash
0 3 * * 0 docker builder prune -f --filter until=168h >> /var/log/docker-builder-prune.log 2>&1
```

Zum Nachsehen: `df -h /`, `docker system df`, `du -sh /var/log/* | sort -rh | head`.

## Datenbankzugang

Die Postgres-Ports (49201 Prod, 49301 Staging) sind nur an `127.0.0.1` des
Servers gebunden. Docker schreibt fuer veroeffentlichte Ports eigene
iptables-Regeln und umgeht damit `ufw`; eine Bindung ohne Adresse ist deshalb
aus dem Internet erreichbar, egal was die Firewall sagt. Rails und die Skripte
brauchen die Ports nicht (Docker-Netz bzw. `docker exec`). Fuer ein
Datenbankprogramm auf dem eigenen Rechner:

```bash
ssh -N -L 49201:127.0.0.1:49201 saisonmanager   # dann localhost:49201
```

Die Passwoerter stehen in der untracked `.env` (`SM_DB_PASSWORD`,
`SM_STAGING_DB_PASSWORD`). Der Standard `saisonmanager` aus diesem Repo gilt
nur lokal. `POSTGRES_PASSWORD` wirkt nur beim ersten Start auf ein leeres
Volume; ein neues Passwort fuer eine bestehende Datenbank:

```bash
docker exec saisonmanager_postgres psql -U saisonmanager -c "ALTER ROLE saisonmanager PASSWORD '<neu>'"
# dann SM_DB_PASSWORD in .env setzen und rails-api neu erzeugen:
$COMPOSE up -d rails-api
```

Zwischen `ALTER ROLE` und dem Neuerzeugen scheitern neue Verbindungen von
Rails, also beides direkt nacheinander.

## Datenbanksicherung

`scripts/db-backup.sh <anlass> [behalten]` legt einen `pg_dump` (Custom-Format)
unter `/opt/saisonmanager/backups/<anlass>/` an, prueft ihn und loescht die
aeltesten ueber der Grenze. Zwei Anlaesse:

| Anlass | Ausloeser | behalten |
|---|---|---|
| `vor-deploy` | `deploy.sh`, direkt vor `db:migrate`; ohne Dump keine Migration | 10 |
| `taeglich` | Cronjob auf dem Server | 14 |

Ein Dump hat rund 120 MB. Das Hetzner-Backup (taeglich 10:30) bleibt bestehen
und nimmt die Dumps mit; gegen den Verlust des Servers selbst fehlt noch eine
Ablage ausserhalb (api#881).

Cronjob einmalig eintragen (Server laeuft auf UTC, 01:45 UTC liegt vor den
3-Uhr-Jobs und nach Mitternacht deutscher Zeit):

```bash
(crontab -l; echo "45 1 * * * /opt/saisonmanager/saisonmanager-docker/scripts/db-backup.sh taeglich 14 >> /var/log/db-backup.log 2>&1") | crontab -
```

Zurueckspielen, zuerst immer in eine Pruefdatenbank:

```bash
F=/opt/saisonmanager/backups/vor-deploy/saisonmanager-<zeit>.dump
docker exec saisonmanager_postgres createdb -U saisonmanager pruefung
docker exec -i saisonmanager_postgres pg_restore -U saisonmanager -d pruefung --no-owner < "$F"
# ... pruefen, dann aufraeumen:
docker exec saisonmanager_postgres dropdb -U saisonmanager pruefung
```

Die Produktion selbst zuruecksetzen, etwa nach einer fehlerhaften Migration.
Nicht mit `pg_restore --clean` in die laufende Datenbank: Das entfernt nur, was
im Dump steht, laesst Tabellen der Migration stehen und laeuft nach Fehlern
weiter. Stattdessen Datenbank neu anlegen und in einer Transaktion fuellen:

```bash
set -e
COMPOSE="docker compose -f /opt/saisonmanager/saisonmanager-docker/docker-compose.yml -f /opt/saisonmanager/saisonmanager-docker/docker-compose.prod.yml -f /opt/saisonmanager/saisonmanager-docker/docker-compose.staging.yml"
F=/opt/saisonmanager/backups/vor-deploy/saisonmanager-<zeit>.dump
$COMPOSE stop rails-api
docker exec saisonmanager_postgres dropdb -U saisonmanager saisonmanager
docker exec saisonmanager_postgres createdb -U saisonmanager saisonmanager
docker exec -i saisonmanager_postgres pg_restore -U saisonmanager -d saisonmanager --no-owner --single-transaction --exit-on-error < "$F"
# API-Code auf den Stand vor dem Deploy zuruecksetzen, sonst startet der neue
# Code gegen das alte Schema:
#   cd /opt/saisonmanager/saisonmanager-api && git reset --hard <commit vorher>
#   $COMPOSE build rails-api
docker exec saisonmanager_redis redis-cli flushall   # Cache stammt sonst vom neueren Stand
$COMPOSE up -d rails-api
```

`dropdb` scheitert, solange noch Verbindungen offen sind; dann zuerst pruefen,
wer verbunden ist (`pg_stat_activity`), statt die Verbindungen hart zu trennen.

Ein fehlgeschlagener taeglicher Lauf steht nur in `/var/log/db-backup.log`.
Eine Ueberwachung (z. B. Sentry-Cron-Monitor) fehlt noch.

## Livestream-Waechter (YouTube)

Beendet laufende Uebertragungen des Verbandskanals, wenn seit 15 Minuten kein
Signal mehr anliegt **und** der Spielbericht geschlossen ist. Laeuft als
Cronjob auf dem Produktionshost:

```bash
*/5 * * * * docker exec saisonmanager_rails_api bundle exec rake streaming:watchdog RAILS_ENV=production >> /var/log/streaming-watchdog.log 2>&1
```

Zugangsdaten stehen in der gitignorierten `.env` in diesem Verzeichnis, wie der
Sentry-DSN:

```
YOUTUBE_CLIENT_ID=...
YOUTUBE_CLIENT_SECRET=...
YOUTUBE_REFRESH_TOKEN=...
```

Client-ID und -Secret gehoeren zu einem OAuth-Client "Desktop app" im
Google-Cloud-Projekt des Verbands; das Refresh-Token entsteht einmal am
Arbeitsplatz mit dem Bereich `youtube.force-ssl` und laeuft nicht ab, solange
der Zugang nicht widerrufen wird.

**Nicht auf Staging setzen.** Der Staging-Stack traegt einen anonymisierten
Klon der Produktionsdaten -- mit diesen Zugangsdaten wuerde sein Waechter
echte, laufende Uebertragungen beenden. Ohne die Variablen meldet der Task,
dass kein Zugang eingerichtet ist, und tut nichts.

Vorschau ohne Eingriff:

```bash
docker exec -e DRY_RUN=1 saisonmanager_rails_api bundle exec rake streaming:watchdog RAILS_ENV=production
```

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
| `postgres-staging` | `saisonmanager_postgres_staging` | Volume `postgres_staging_data`, Host-Port 49301 nur auf 127.0.0.1 |
| `mailpit` | `saisonmanager_mailpit` | fängt alle Mails, UI unter `/mailpit/` |

Compose-Aufruf (Basis + Prod-Overlay + Staging-Overlay):

```bash
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.staging.yml <command>
```

### Einmalige Server-Einrichtung

```bash
# 1) DNS: A-Record saisonmanager.dev -> <server-ip> (beim Registrar)

# 2) Staging-API-Checkout auf Branch `staging`
git clone <api-repo> /opt/saisonmanager/saisonmanager-api-staging
cd /opt/saisonmanager/saisonmanager-api-staging && git checkout staging

# 3) Frontend-Zielverzeichnis anlegen (Staging-App)
mkdir -p /opt/saisonmanager/saisonmanager-frontend-staging

# 4) Staging-Secret setzen (untracked .env im docker-Verzeichnis)
echo "SM_STAGING_SECRET_KEY_BASE=$(openssl rand -hex 64)" \
  >> /opt/saisonmanager/saisonmanager-docker/.env

# 4b) Eigene Basic-Auth-Datei für Staging anlegen (untracked, wie /etc/htpasswd
#     für Prod). Bewusst eine ANDERE Datei mit eigenen Zugangsdaten, damit
#     Staging-Credentials nicht versehentlich Prod-Zugriff gewähren.
htpasswd -c /opt/saisonmanager/saisonmanager-docker/nginx/config/htpasswd-staging <staging-user>
#   -> Passwort interaktiv setzen

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
# redis-staging wird ueber depends_on von rails-api-staging mitgestartet.
# Es ist bewusst ein EIGENER Container und nicht der Prod-Redis mit anderem
# Datenbank-Index: maxmemory gilt je Instanz, ein Staging-Lauf haette sonst
# den Prod-Cache verdraengt, und ohne Authentifizierung haette Staging die
# Prod-Eintraege im Klartext lesen koennen.

# 8) Staging-DB initial mit 1:1-Prod-Klon befüllen
./scripts/staging-db-refresh.sh
```

> Der `include` in Schritt 6 lebt in der **untracked** `nginx.prod.conf` (nicht
> im Repo), damit ein Merge dieses PRs den Prod-nginx nicht verändert. Dadurch
> ist die Aktivierung von Staging vom Merge- und Cert-Timing entkoppelt.

### doku.saisonmanager.dev (Staging-Spiegel des Rollenhandbuchs)

Analog zu `doku.saisonmanager.org`: statisches Rollenhandbuch, öffentlich ohne
Basic Auth, aber mit `X-Robots-Tag: noindex`. Eigener Vhost in
`doku.staging.conf`, aus demselben Grund wie `saisonmanager.staging.conf` in
einer **eigenen** Datei statt direkt in der bestehenden Staging-Datei: ein
`ssl_certificate`-Pfad, der beim `nginx -t` noch nicht existiert, würde sonst
den kompletten Prod-nginx umwerfen.

```bash
# 1) DNS: A-Record doku.saisonmanager.dev -> <server-ip> (beim Registrar)

# 2) Cert AUSSTELLEN, BEVOR der Vhost aktiv ist (Webroot wie bei den anderen
#    Vhosts: der Default-:80-Server liefert die ACME-Challenge bereits aus
#    dem Prod-Frontend-Verzeichnis aus, kein separater :80-Block vorab nötig).
git -C /opt/saisonmanager/saisonmanager-docker pull origin main   # bringt doku.staging.conf
certbot certonly --webroot \
  -w /opt/saisonmanager/saisonmanager-frontend \
  -d doku.saisonmanager.dev

# 3) Vhost ERST JETZT (Cert existiert) serverseitig einbinden.
grep -q 'doku.staging.conf' /opt/saisonmanager/saisonmanager-docker/nginx/config/nginx.prod.conf \
  || echo '    include /etc/nginx/doku.staging.conf;' \
       >> /opt/saisonmanager/saisonmanager-docker/nginx/config/nginx.prod.conf
# (Zeile muss INNERHALB des http{}-Blocks stehen, analog zum bestehenden
#  saisonmanager.staging.conf-include.)

# 4) nginx testen und reloaden (kein Recreate nötig, keine neuen Mounts).
docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.staging.yml \
  exec nginx nginx -t -c /etc/nginx/nginx.prod.conf \
  && docker compose -f docker-compose.yml -f docker-compose.prod.yml -f docker-compose.staging.yml \
       exec nginx nginx -s reload -c /etc/nginx/nginx.prod.conf

# 5) Frontend deployen, damit /doku/ im Staging-FE-Verzeichnis existiert
#    (im Frontend-Repo): ./build-deploy-staging.sh
```

### Laufender Betrieb

```bash
# Staging deployen (Branch `staging`), Prod bleibt unberührt
ssh saisonmanager /opt/saisonmanager/saisonmanager-docker/deploy-staging.sh

# Frontend separat bauen/deployen (im Frontend-Repo)
./build-deploy-staging.sh

# Staging-DB erneut aus Prod auffrischen (1:1-Klon, KEINE Anonymisierung).
# Kopiert zusätzlich die ActiveStorage-Dateien (Logos/Banner) von Prod nach
# Staging – sonst zeigt die öffentliche Ansicht gebrochene Logos.
ssh saisonmanager /opt/saisonmanager/saisonmanager-docker/scripts/staging-db-refresh.sh

# Nur die Benutzerkonten nachziehen, Rest der Staging-DB unberührt lassen
ssh saisonmanager /opt/saisonmanager/saisonmanager-docker/scripts/staging-sync-users.sh
ssh saisonmanager /opt/saisonmanager/saisonmanager-docker/scripts/staging-sync-users.sh --dry-run
```

> `staging-db-refresh.sh` spielt Prod **1:1** ein: echte Namen, E-Mails und
> Passwörter. Prod-User loggen sich auf `saisonmanager.dev` mit ihrem echten
> Konto ein – geschützt allein durch Basic Auth + `noindex`, ausgehende Mails
> fängt Mailpit ab. Der komplette Prod-Datenbestand liegt damit auf dem
> Zweitsystem; das ist bewusst so gewählt. Der frühere Anonymisierungsschritt
> (`staging:anonymize`) entfällt.
>
> Auf Staging sollen nur die administrativen Konten (Admin/SBK/RSK/Ansetzer) als
> echte Logins landen. Schritt 3 (`staging:prune_limited_users`) entfernt daher
> nach dem Klon alle Benutzerkonten, die ausschließlich VM, TM oder
> Schiedsrichter sind (Datenminimierung).
>
> Weil der Klon zudem echte Prod-Passwörter einspielt (die man nicht kennt),
> legt Schritt 4 (`staging:seed_demo_users`) die kuratierten Demo-Konten (ein
> Login je Rolle, `demo_*`) neu an – mit dem gemeinsamen Test-Passwort aus
> `STAGING_USER_PASSWORD`; `demo_admin` bekommt abweichend
> `STAGING_ADMIN_PASSWORD` (Vollzugriff nicht mit demselben Passwort wie die
> Rollen-Testkonten). Beide Werte stehen in der gitignorierten `.env` und werden
> von `staging-db-refresh.sh` an den Task durchgereicht; fehlen sie, greift der
> Task-Default (`staging-password`). Diese Demo-Konten sind
> das einzige, das jeder Tester frei benutzen kann; echte Konten brauchen das
> echte Passwort. Neue Demo-Konten werden in `db/staging_demo_users.json`
> (API-Repo) gepflegt.

> **Konten zwischen zwei Refreshes nachziehen:** `staging-sync-users.sh` gleicht
> allein die `users`-Tabelle ab (Prod-Export per `SELECT` → Rake-Task
> `staging:sync_users` im Staging-Container). Gedacht für den Normalfall, dass
> auf Prod ein neues SBK-Konto entstanden ist oder sich Rollen geändert haben,
> die Testdaten auf Staging aber stehen bleiben sollen — ein voller Refresh
> verwirft sie. Abgeglichen wird über `user_name`, bestehende Konten behalten
> ihre Staging-ID (Tracking-Spalten wie `uploaded_by_id` zeigen darauf),
> `demo_*` bleibt unangetastet, und reine VM-/TM-/Schiedsrichter-Konten kommen
> gar nicht erst dazu. Verliert ein Konto auf Prod seine Rolle, wird das auch
> auf Staging nachvollzogen; entfernen lässt es sich danach mit
> `staging:prune_limited_users`. Konten, die es nur noch auf Staging gibt,
> werden gemeldet und nicht gelöscht. `--dry-run` zeigt nur, was passieren
> würde, und prüft dabei mit, ob die Konten überhaupt speicherbar wären.
> Scheitert ein Konto, läuft der Rest durch, die Zusammenfassung nennt es unter
> `FEHLER` und das Skript endet mit einem Fehler-Exit.
>
> Das Skript nutzt den vorhandenen Staging-Container. Der zieht `origin/staging`
> per `reset --hard`, der Rake-Task muss also dort liegen und `deploy-staging.sh`
> gelaufen sein, sonst quittiert es mit „Don't know how to build task".

**Workflow:** PR → Merge nach `staging` → auf `saisonmanager.dev` testen →
erst dann Merge nach `main` → Prod-`deploy.sh`.

Die secret-behaftete `.env` und die (untracked) `docker-compose.prod.yml`
bleiben wie bisher serverseitig und werden nie eingecheckt.
