#!/bin/bash
set -uo pipefail

# Liegt auf docker01 als /usr/local/bin/saisonmanager-portscan und ist der
# EINZIGE Befehl, den der Schluessel des Saisonmanager-Servers dort ausfuehren
# darf (authorized_keys mit command=..., siehe README, Abschnitt
# Portpruefung). Uebergebene Argumente werden ignoriert.
#
# Scannt alle TCP-Ports von saisonmanager.de ueber IPv4 und, falls docker01
# IPv6 kann, ueber IPv6. Ausgabe je offenem Port "OFFEN <adresse> <port>",
# am Ende "FERTIG". Die Bewertung macht scripts/port-pruefung.sh auf dem
# Saisonmanager-Server.

ZIEL="saisonmanager.de"

scan() {
  local adresse="$1" ausgabe port; shift
  # Erst ganz einsammeln: Ein gescheitertes nmap muss als Fehler zaehlen,
  # "keine offenen Ports" dagegen nicht (grep ohne Treffer ist kein Fehler).
  ausgabe="$(nmap -Pn -T4 -p- --open -oG - "$@" "$adresse")" || return 1
  grep -q '^# Nmap done' <<< "$ausgabe" || return 1
  for port in $(grep -o '[0-9]*/open/tcp' <<< "$ausgabe" | cut -d/ -f1); do
    echo "OFFEN $adresse $port"
  done
}

v4="$(getent ahostsv4 "$ZIEL" | awk 'NR==1 {print $1}')"
[ -n "$v4" ] || { echo "FEHLER: keine IPv4-Adresse fuer $ZIEL"; exit 1; }
scan "$v4" || exit 1

v6="$(getent ahostsv6 "$ZIEL" | awk '$1 ~ /:/ && NR==1 {print $1}')"
if [ -n "$v6" ] && ip -6 route get "$v6" >/dev/null 2>&1; then
  scan "$v6" -6 || exit 1
else
  echo "HINWEIS: IPv6 nicht geprueft"
fi

echo "FERTIG"
