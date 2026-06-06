#!/bin/bash
set -e

COMPOSE="docker compose -f /opt/saisonmanager/saisonmanager-docker/docker-compose.yml -f /opt/saisonmanager/saisonmanager-docker/docker-compose.prod.yml"

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

# Run pending migrations (uses the freshly built image).
$COMPOSE run --rm -e RAILS_ENV=production rails-api bundle exec rails db:migrate

# Recreate containers so the freshly built image is actually used. `restart`
# alone would relaunch the old container from the previous image.
$COMPOSE up -d nginx rails-api

echo "Deployed."
