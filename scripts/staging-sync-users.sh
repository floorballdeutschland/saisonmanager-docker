#!/bin/bash
set -euo pipefail

# Benutzerkonten von Prod nach Staging nachziehen – ohne die restliche
# Staging-Datenbank anzufassen.
#
# Wofür: Zwischen zwei vollen Refreshes (scripts/staging-db-refresh.sh) laufen
# die Konten auseinander. Neue SBK-Kolleginnen, geänderte Rollen oder ein neues
# Passwort auf Prod kommen auf Staging erst mit dem nächsten Refresh an, und der
# verwirft alle nur dort aufgebauten Testdaten. Dieses Skript gleicht allein die
# users-Tabelle ab; Ligen, Spiele und Testszenarien auf Staging bleiben stehen.
#
# Ablauf:
#   1. Konten aus dem Prod-Postgres als JSON lesen (reines SELECT, read-only)
#   2. JSON per STDIN an den Rake-Task staging:sync_users im Staging-Container
#      geben (im API-Repo definiert). Der Task entscheidet, was übernommen wird:
#        - Abgleich über user_name, bestehende Konten behalten ihre Staging-ID
#        - demo_*-Konten bleiben unangetastet
#        - reine VM-/TM-/Schiedsrichter-Konten werden nicht neu angelegt
#          (dieselbe Regel wie staging:prune_limited_users)
#        - vorhandene Konten werden auch dann aktualisiert, wenn ihre Rollen
#          weggefallen sind, damit auf Staging keine Rechte überleben
#      Details und Begründungen stehen im Kopf des Rake-Tasks.
#
# Aufruf auf dem Prod-Server:
#   /opt/saisonmanager/saisonmanager-docker/scripts/staging-sync-users.sh
#   /opt/saisonmanager/saisonmanager-docker/scripts/staging-sync-users.sh --dry-run
#
# Die Prod-Datenbank wird nur gelesen. Geschrieben wird ausschließlich in die
# Staging-Datenbank, und dort nur in die users-Tabelle.

DOCKER_DIR="/opt/saisonmanager/saisonmanager-docker"
COMPOSE="docker compose \
  -f $DOCKER_DIR/docker-compose.yml \
  -f $DOCKER_DIR/docker-compose.prod.yml \
  -f $DOCKER_DIR/docker-compose.staging.yml"

PROD_PG="saisonmanager_postgres"
DB="saisonmanager"

# Ein unbekanntes Argument darf nicht stillschweigend zum scharfen Lauf werden:
# Wer sich bei `--dry-run` vertippt, bekäme sonst genau das Gegenteil dessen,
# was er wollte, und als einzigen Hinweis die fehlende Zeile unten.
DRY_RUN="false"
case "${1:-}" in
  --dry-run)
    DRY_RUN="true"
    echo "== Probelauf: der Rake-Task schreibt nichts =="
    ;;
  "") ;;
  *)
    echo "ABBRUCH: unbekanntes Argument '$1'. Erlaubt ist nur --dry-run." >&2
    exit 2
    ;;
esac
if [ "$#" -gt 1 ]; then
  echo "ABBRUCH: zu viele Argumente." >&2
  exit 2
fi

# Der Export enthält die E-Mail-Adressen und Passwort-Hashes aller Prod-Konten.
# mktemp legt ihn mit 0600 an, statt ihn per Umleitung unter der Standard-Umask
# (auf dem Server 0644) für jedes lokale Konto lesbar zu machen.
EXPORT="$(mktemp /tmp/sm_prod_users_XXXXXX.json)"

# Bei JEDEM Abbruch löschen, nicht nur im Erfolgsfall (wie beim Dump in
# staging-db-refresh.sh).
trap 'rm -f "$EXPORT"' EXIT

echo "==> 1/2  Benutzerkonten aus dem Prod-Postgres lesen"
# Nur die Spalten, die der Task übernimmt. Nicht dabei: id (Staging vergibt
# eigene), teams (Team-IDs sind zwischen den Ständen nicht stabil) und die
# Felder laufender Vorgänge (Passwort-Reset, E-Mail-Bestätigung).
# ON_ERROR_STOP, weil `psql -c` einen SQL-Fehler sonst mit Exit 0 quittiert:
# Nach einer umbenannten Spalte stünde hier eine leere Datei und der Abbruch
# unten meldete „Export ist leer" statt der eigentlichen Ursache.
docker exec "$PROD_PG" psql -v ON_ERROR_STOP=1 -U "$DB" -d "$DB" -At -c \
  "SELECT COALESCE(json_agg(t), '[]'::json) FROM (
     SELECT user_name, email, first_name, last_name, password_digest, permissions,
            language, receive_info_mails, privacy_approved, description,
            archived_at, club_id, referee_id
     FROM users
   ) t;" > "$EXPORT"

# Ein leerer oder abgebrochener Export darf nicht als „Prod hat keine Konten"
# durchgehen. Der Task bricht bei einer leeren Liste ebenfalls ab; hier fällt es
# schon vor dem Containerstart auf.
if [ ! -s "$EXPORT" ] || [ "$(head -c 2 "$EXPORT")" = "[]" ]; then
  echo "ABBRUCH: Der Export ist leer – kein plausibler Prod-Stand." >&2
  exit 1
fi

# Abgeschnitten wird sonst erst im Container als „kein gültiges JSON" sichtbar,
# was nach einem Fehler im Task aussieht und nicht nach einem halben Export.
if [ "$(tail -c 2 "$EXPORT" | tr -d '\n')" != "]" ]; then
  echo "ABBRUCH: Der Export endet nicht auf ']' – vermutlich abgeschnitten." >&2
  exit 1
fi

echo "    Export geschrieben ($(wc -c < "$EXPORT") Bytes, $(grep -o '"user_name"' "$EXPORT" | wc -l) Konten)"

echo "==> 2/2  Abgleich in der Staging-Datenbank"
# -T: keine TTY, sonst kommt der Export nicht als STDIN im Container an.
$COMPOSE run --rm -T -e RAILS_ENV=production -e "DRY_RUN=$DRY_RUN" \
  rails-api-staging \
  bundle exec rails staging:sync_users < "$EXPORT"

echo "Benutzerkonten abgeglichen. Der Rest der Staging-Datenbank ist unverändert."
