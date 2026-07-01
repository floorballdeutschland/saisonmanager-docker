#!/bin/bash
set -e

# Staging-Deploy für saisonmanager.dev.
#
# Baut/aktualisiert AUSSCHLIESSLICH die Staging-Services. Prod (rails-api,
# postgres) wird nie angefasst. Der gemeinsame nginx wird nur sanft neu geladen
# (reload), damit Prod keine Downtime bekommt.
#
# Voraussetzungen (einmalig, siehe README):
#   - /opt/saisonmanager/saisonmanager-api-staging  (Checkout, Branch `staging`)
#   - /opt/saisonmanager/saisonmanager-frontend-staging  (Staging-FE-Build)
#   - docker-compose.staging.yml (getrackt) + .env mit SM_STAGING_SECRET_KEY_BASE
#   - LE-Cert für saisonmanager.dev
#   - Staging-DB initial befüllt (staging-db-refresh.sh)

DOCKER_DIR="/opt/saisonmanager/saisonmanager-docker"
API_STAGING_DIR="/opt/saisonmanager/saisonmanager-api-staging"

COMPOSE="docker compose \
  -f $DOCKER_DIR/docker-compose.yml \
  -f $DOCKER_DIR/docker-compose.prod.yml \
  -f $DOCKER_DIR/docker-compose.staging.yml"

# Docker-/nginx-Config aktualisieren (gemeinsames Repo, main).
cd "$DOCKER_DIR"
git pull origin main

# Staging-API-Code auf den staging-Branch zwingen.
cd "$API_STAGING_DIR"
git fetch origin
git reset --hard origin/staging

# Staging-Image neu bauen (Gemfile-Änderungen greifen lassen).
$COMPOSE build rails-api-staging

# Pending Migrations auf der Staging-DB ausführen.
$COMPOSE run --rm -e RAILS_ENV=production rails-api-staging bundle exec rails db:migrate

# Staging-Container (neu) starten – Prod bleibt unberührt.
$COMPOSE up -d postgres-staging mailpit rails-api-staging

# nginx-Config (neue/aktualisierte saisonmanager.dev.conf) sanft neu laden.
# Falls neue Volume-Mounts hinzukamen, einmalig stattdessen:
#   $COMPOSE up -d nginx
docker exec saisonmanager_dev_nginx nginx -t && \
  docker exec saisonmanager_dev_nginx nginx -s reload

echo "Staging deployed."
