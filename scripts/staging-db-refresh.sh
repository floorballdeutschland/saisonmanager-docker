#!/bin/bash
set -euo pipefail

# Staging-DB mit einem ANONYMISIERTEN Klon der Prod-DB neu befüllen.
#
# Ablauf:
#   1. pg_dump aus dem Prod-Postgres (read-only auf Prod)
#   2. Restore in den isolierten Staging-Postgres (überschreibt Staging-DB)
#   3. Anonymisierung personenbezogener Daten via Rails-Rake-Task
#      (staging:anonymize – im API-Repo definiert) und Reset der Test-Logins
#   4. ActiveStorage-Dateien (Logos/Banner) von Prod nach Staging kopieren
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

# Der Dump enthält echte personenbezogene Daten – bei JEDEM Abbruch löschen,
# nicht nur im Erfolgsfall (set -e würde sonst den Dump auf der Platte lassen).
trap 'rm -f "$DUMP"' EXIT

echo "==> 1/4  Prod-Dump erstellen ($DUMP)"
docker exec "$PROD_PG" pg_dump -U "$DB" --no-owner --no-privileges --clean --if-exists "$DB" \
  | gzip > "$DUMP"

echo "==> 2/4  Restore in Staging-Postgres"
# Verbindungen kappen und DB frisch aufsetzen, dann Dump einspielen.
docker exec "$STAGING_PG" psql -U "$DB" -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid <> pg_backend_pid();" || true
gunzip -c "$DUMP" | docker exec -i "$STAGING_PG" psql -v ON_ERROR_STOP=1 -U "$DB" -d "$DB"

echo "==> 3/4  Anonymisierung + Test-Logins"
$COMPOSE run --rm -e RAILS_ENV=production rails-api-staging \
  bundle exec rails staging:anonymize

echo "==> 4/4  ActiveStorage-Dateien Prod -> Staging kopieren"
# Nur die Blob-Records stecken im DB-Dump; die tatsächlichen Dateien liegen bei
# beiden Umgebungen als :local-Disk-Storage unter $STORAGE_DIR. Per tar-Stream
# direkt zwischen den Containern kopieren (kein Zwischenspeicher auf der Platte).
docker exec "$PROD_API" tar -C "$STORAGE_DIR" -cf - . \
  | docker exec -i "$STAGING_API" tar -C "$STORAGE_DIR" -xf -
echo "    Storage-Dateien kopiert: $(docker exec "$STAGING_API" sh -c "find $STORAGE_DIR -type f | wc -l")"

# Dump-Aufräumen übernimmt der EXIT-trap (oben).
echo "Staging-DB neu befüllt und anonymisiert, Storage-Dateien synchronisiert."
