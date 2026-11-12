#!/bin/bash
set -euo pipefail

# Sicherung der Prod-Datenbank als pg_dump (Custom-Format) auf dem Server.
#
#   scripts/db-backup.sh <anlass> [behalten]
#
#   anlass    Unterordner unter /opt/saisonmanager/backups, z. B. "taeglich"
#             (Cronjob) oder "vor-deploy" (deploy.sh vor db:migrate).
#   behalten  Wie viele Dumps dieses Anlasses bleiben, aeltere werden geloescht.
#             Standard 14.
#
# Warum zusaetzlich zum Hetzner-Backup: Das ist ein Abbild des ganzen Servers,
# eine Wiederherstellung setzt alles zurueck, und die Datenbank wird dabei im
# laufenden Betrieb kopiert. Ein pg_dump ist in sich konsistent und laesst sich
# gezielt zurueckspielen, auch nur in eine Pruefdatenbank. Weil die Dumps auf
# derselben Platte liegen, landen sie ausserdem im naechsten Hetzner-Backup.
# Gegen den Verlust des Servers selbst schuetzen sie NICHT (Ablage ausserhalb
# des Servers ist in api#881 noch offen).
#
# Bricht mit Fehler ab, wenn der Dump fehlschlaegt, verdaechtig klein oder
# nicht lesbar ist. deploy.sh verlaesst sich darauf: ohne Sicherung keine
# Migration.

ANLASS="${1:?Anlass fehlt, z. B. taeglich oder vor-deploy}"
BEHALTEN="${2:-14}"
PG_CONTAINER="${PG_CONTAINER:-saisonmanager_postgres}"
DB="saisonmanager"
BASIS="${BACKUP_BASIS:-/opt/saisonmanager/backups}"
ZIEL="$BASIS/$ANLASS"
# Ein Dump ist rund 120 MB (11/2026). Unter 2 GB frei lieber abbrechen, als die
# Platte vollzuschreiben, auf der auch die Datenbank liegt.
MIN_FREI_KB=$((2 * 1024 * 1024))
# Ein Dump der Prod-DB unter 1 MB ist kaputt (nur Schema o. ae.).
MIN_GROESSE="${MIN_GROESSE:-1000000}"

umask 077
mkdir -p "$ZIEL"
chmod 700 "$BASIS" "$ZIEL"

frei_kb=$(df -Pk "$ZIEL" | awk 'NR==2 {print $4}')
if [ "$frei_kb" -lt "$MIN_FREI_KB" ]; then
  echo "ABBRUCH: nur $((frei_kb / 1024)) MB frei unter $ZIEL" >&2
  exit 1
fi

datei="$ZIEL/$DB-$(date +%F-%H%M%S).dump"
teil="$datei.teil"
trap 'rm -f "$teil"' EXIT

docker exec "$PG_CONTAINER" pg_dump -U "$DB" -Fc "$DB" > "$teil"

groesse=$(stat -c %s "$teil")
if [ "$groesse" -lt "$MIN_GROESSE" ]; then
  echo "ABBRUCH: Dump nur $groesse Bytes" >&2
  exit 1
fi
if ! docker exec -i "$PG_CONTAINER" pg_restore -l < "$teil" | grep -q "TABLE DATA"; then
  echo "ABBRUCH: Dump ist nicht lesbar" >&2
  exit 1
fi

mv "$teil" "$datei"

# Aelteste ueber der Grenze loeschen (Dateinamen sortieren chronologisch).
ls -1 "$ZIEL"/"$DB"-*.dump | sort | head -n -"$BEHALTEN" | xargs -r rm -f

echo "$(date '+%F %T') $datei ($(du -h "$datei" | cut -f1)), $(ls -1 "$ZIEL"/"$DB"-*.dump | wc -l) im Ordner"
