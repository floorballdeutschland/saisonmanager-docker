#!/bin/bash
set -euo pipefail

# Staging-DB mit einem 1:1-Klon der Prod-DB neu befüllen.
#
# Es findet KEINE Anonymisierung mehr statt: Staging spiegelt Prod inkl. echter
# Namen/E-Mails/Passwörter, damit sich Prod-User mit ihrem echten Konto einloggen
# können. Geschützt wird das Zweitsystem ausschließlich durch Basic Auth + noindex;
# ausgehende Mails fängt Mailpit ab (nichts erreicht echte Empfänger).
#
# Auf Staging sollen nur die administrativen Konten (Admin/SBK/RSK/Ansetzer) als
# echte Logins landen. Schritt 3 entfernt daher die reinen VM-/TM-/Schiedsrichter-
# Konten (Datenminimierung). Da der Klon zudem echte Prod-Passwörter einspielt,
# die man nicht kennt, legt Schritt 4 die kuratierten Demo-Konten (ein Login je
# Rolle, bekanntes Passwort) neu an, damit sich beliebige Rollen testen lassen.
#
# Ablauf:
#   1. pg_dump aus dem Prod-Postgres (read-only auf Prod)
#   2. Restore in den isolierten Staging-Postgres (überschreibt Staging-DB)
#   3. Reine VM-/TM-/Schiedsrichter-Konten entfernen via Rails-Rake-Task
#      (staging:prune_limited_users – im API-Repo definiert)
#   4. Demo-/Test-Benutzer je Rolle anlegen via Rails-Rake-Task
#      (staging:seed_demo_users – im API-Repo definiert); die Passwörter kommen
#      aus der gitignorierten .env (siehe env_value unten)
#   5. ActiveStorage-Dateien (Logos/Banner) von Prod nach Staging kopieren
#      – der DB-Klon bringt nur die active_storage_blobs-/-attachments-Records
#        mit, NICHT die Dateien auf der Platte. Ohne diesen Schritt zeigt die
#        öffentliche Ansicht gebrochene Team-/Vereins-Logos (Blob-Path -> 404).
#
# Auf dem Prod-Server ausführen:
#   /opt/saisonmanager/saisonmanager-docker/scripts/staging-db-refresh.sh
#
# ACHTUNG: Schritt 2 verwirft den aktuellen Staging-DB-Inhalt vollständig.

DOCKER_DIR="/opt/saisonmanager/saisonmanager-docker"
COMPOSE="docker compose \
  -f $DOCKER_DIR/docker-compose.yml \
  -f $DOCKER_DIR/docker-compose.prod.yml \
  -f $DOCKER_DIR/docker-compose.staging.yml"

PROD_PG="saisonmanager_postgres"
STAGING_PG="saisonmanager_postgres_staging"
PROD_API="saisonmanager_rails_api"
STAGING_API="saisonmanager_rails_api_staging"
STORAGE_DIR="/app/storage"
DB="saisonmanager"
DUMP="/tmp/sm_prod_dump_$(date +%Y%m%d_%H%M%S).sql.gz"
ENV_FILE="$DOCKER_DIR/.env"

# Passwörter der Demo-Konten (Schritt 4). Die Werte gehören NICHT ins Repo (es
# ist öffentlich) und stehen daher in der gitignorierten .env:
#   STAGING_USER_PASSWORD=...    gemeinsames Passwort aller demo_*-Konten
#   STAGING_ADMIN_PASSWORD=...   abweichendes Passwort nur für demo_admin
# Fehlt ein Wert, greift der Default des Rake-Tasks ('staging-password' bzw.
# das gemeinsame Passwort) – der Task gibt am Ende aus, was gesetzt wurde.
# Gelesen wird gezielt Zeile für Zeile, statt die .env zu sourcen: so landen
# keine unbeteiligten Secrets in der Umgebung dieses Skripts.
env_value() {
  local key="$1"
  [ -f "$ENV_FILE" ] || return 0
  sed -n "s/^[[:space:]]*${key}=//p" "$ENV_FILE" | tail -n1 | sed -e 's/^"\(.*\)"$/\1/' -e "s/^'\(.*\)'$/\1/"
}

STAGING_USER_PASSWORD="$(env_value STAGING_USER_PASSWORD)"
STAGING_ADMIN_PASSWORD="$(env_value STAGING_ADMIN_PASSWORD)"
[ -n "$STAGING_USER_PASSWORD" ] || echo "HINWEIS: STAGING_USER_PASSWORD fehlt in $ENV_FILE – Demo-Konten bekommen das Task-Default-Passwort."

# Der Dump enthält echte personenbezogene Daten – bei JEDEM Abbruch löschen,
# nicht nur im Erfolgsfall (set -e würde sonst den Dump auf der Platte lassen).
trap 'rm -f "$DUMP"' EXIT

echo "==> 1/5  Prod-Dump erstellen ($DUMP)"
docker exec "$PROD_PG" pg_dump -U "$DB" --no-owner --no-privileges --clean --if-exists "$DB" \
  | gzip > "$DUMP"

echo "==> 2/5  Restore in Staging-Postgres"
# Verbindungen kappen und DB frisch aufsetzen, dann Dump einspielen.
docker exec "$STAGING_PG" psql -U "$DB" -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid <> pg_backend_pid();" || true
gunzip -c "$DUMP" | docker exec -i "$STAGING_PG" psql -v ON_ERROR_STOP=1 -U "$DB" -d "$DB"

echo "==> 3/5  Reine VM-/TM-/Schiedsrichter-Konten entfernen"
$COMPOSE run --rm -e RAILS_ENV=production rails-api-staging \
  bundle exec rails staging:prune_limited_users

echo "==> 4/5  Demo-/Test-Benutzer je Rolle anlegen"
$COMPOSE run --rm -e RAILS_ENV=production \
  -e "STAGING_USER_PASSWORD=$STAGING_USER_PASSWORD" \
  -e "STAGING_ADMIN_PASSWORD=$STAGING_ADMIN_PASSWORD" \
  rails-api-staging \
  bundle exec rails staging:seed_demo_users

echo "==> 5/5  ActiveStorage-Dateien Prod -> Staging kopieren"
# Nur die Blob-Records stecken im DB-Dump; die tatsächlichen Dateien liegen bei
# beiden Umgebungen als :local-Disk-Storage unter $STORAGE_DIR. Per tar-Stream
# direkt zwischen den Containern kopieren (kein Zwischenspeicher auf der Platte).
docker exec "$PROD_API" tar -C "$STORAGE_DIR" -cf - . \
  | docker exec -i "$STAGING_API" tar -C "$STORAGE_DIR" -xf -
echo "    Storage-Dateien kopiert: $(docker exec "$STAGING_API" sh -c "find $STORAGE_DIR -type f | wc -l")"

# Dump-Aufräumen übernimmt der EXIT-trap (oben).
echo "Staging-DB als Prod-Klon neu befüllt, reine VM/TM/Schiri-Konten entfernt, Demo-User angelegt, Storage-Dateien synchronisiert."
