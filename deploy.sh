#!/bin/bash
set -e

# docker-compose.staging.yml MUSS mit eingebunden werden, obwohl dieses Skript
# nur Prod-Services anfasst: der geteilte nginx bekommt dort seine Staging-
# Volume-Mounts (saisonmanager-frontend-staging). Ohne die Datei erstellt ein
# Prod-Deploy den nginx-Container ohne diese Mounts neu und saisonmanager.dev
# liefert 500 (so geschehen am 2026-07-01).
COMPOSE="docker compose -f /opt/saisonmanager/saisonmanager-docker/docker-compose.yml -f /opt/saisonmanager/saisonmanager-docker/docker-compose.prod.yml -f /opt/saisonmanager/saisonmanager-docker/docker-compose.staging.yml"

# Pull docker-compose config (nginx config, etc.)
cd /opt/saisonmanager/saisonmanager-docker
git pull origin main

# Pull API code (force-sync to origin/main after PRs are merged)
cd /opt/saisonmanager/saisonmanager-api
git fetch origin
git reset --hard origin/main

# Rebuild the API image so Gemfile/Gemfile.lock changes (new/updated gems) take
# effect. Without this, the container keeps the previously baked-in bundle and a
# changed Gemfile.lock makes `bundle exec` fail with "Could not find <gem>".
$COMPOSE build rails-api

# Sicherung direkt vor der Migration: Eine fehlerhafte Migration laesst sich
# sonst nicht gezielt zuruecknehmen (api#881). Schlaegt der Dump fehl, bricht
# set -e hier ab; die laufenden Container bleiben dann auf dem alten Stand.
# Laeuft bei jedem Deploy, auch ohne neue Migration: ein Dump kostet rund eine
# Minute, und die Pruefung "gibt es eine?" waere selbst ein Rails-Start.
/opt/saisonmanager/saisonmanager-docker/scripts/db-backup.sh vor-deploy 10

# Run pending migrations (uses the freshly built image).
$COMPOSE run --rm -e RAILS_ENV=production rails-api bundle exec rails db:migrate

# Recreate containers so the freshly built image is actually used. `restart`
# alone would relaunch the old container from the previous image.
$COMPOSE up -d nginx rails-api

echo "Deployed."
