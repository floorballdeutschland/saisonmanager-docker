#!/bin/bash
set -euo pipefail

# Staging-DB mit einem ANONYMISIERTEN Klon der Prod-DB neu befüllen.
#
# Ablauf:
#   1. pg_dump aus dem Prod-Postgres (read-only auf Prod)
#   2. Restore in den isolierten Staging-Postgres (überschreibt Staging-DB)
#   3. Anonymisierung personenbezogener Daten via Rails-Rake-Task
#      (staging:anonymize – im API-Repo definiert) und Reset der Test-Logins
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
DB="saisonmanager"
DUMP="/tmp/sm_prod_dump_$(date +%Y%m%d_%H%M%S).sql.gz"

# Der Dump enthält echte personenbezogene Daten – bei JEDEM Abbruch löschen,
# nicht nur im Erfolgsfall (set -e würde sonst den Dump auf der Platte lassen).
trap 'rm -f "$DUMP"' EXIT

echo "==> 1/3  Prod-Dump erstellen ($DUMP)"
docker exec "$PROD_PG" pg_dump -U "$DB" --no-owner --no-privileges --clean --if-exists "$DB" \
  | gzip > "$DUMP"

echo "==> 2/3  Restore in Staging-Postgres"
# Verbindungen kappen und DB frisch aufsetzen, dann Dump einspielen.
docker exec "$STAGING_PG" psql -U "$DB" -d postgres -c \
  "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname='$DB' AND pid <> pg_backend_pid();" || true
gunzip -c "$DUMP" | docker exec -i "$STAGING_PG" psql -v ON_ERROR_STOP=1 -U "$DB" -d "$DB"

echo "==> 3/3  Anonymisierung + Test-Logins"
$COMPOSE run --rm -e RAILS_ENV=production rails-api-staging \
  bundle exec rails staging:anonymize

# Dump-Aufräumen übernimmt der EXIT-trap (oben).
echo "Staging-DB neu befüllt und anonymisiert."
