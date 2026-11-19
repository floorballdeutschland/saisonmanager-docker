#!/bin/bash
set -euo pipefail

# Prueft, ob der Server mehr Ports ins Netz stellt als vorgesehen (docker#51).
#
#   scripts/port-pruefung.sh intern   taeglich, auf dem Server selbst
#   scripts/port-pruefung.sh extern   woechentlich, Scan von docker01 aus
#
# Anlass: Am 12.11.2026 standen die Postgres-Ports 49201/49301 offen im Netz,
# weil Docker veroeffentlichte Ports an der Host-Firewall vorbei freigibt. Eine
# solche Fehlkonfiguration soll innerhalb eines Tages auffallen.
#
# intern  liest `docker ps` und `ss` (nur lesend). Erlaubt sind auf allen
#         Schnittstellen nur 80 und 443 (nginx), 22 (sshd, nicht Docker) und
#         UDP 68 (DHCP-Client).
#         Alles auf 127.0.0.0/8 oder ::1 ist unkritisch.
# extern  laesst docker01 per SSH einen Portscan auf diesen Server machen
#         (Schluessel mit festem Befehl, siehe host/portpruefung/). Erwartet
#         sind nur 22, 80 und 443. Das ist die eigentliche Probe: Sie sieht,
#         was ein Angreifer sieht, auch wenn intern etwas uebersehen wird.
#
# Bei einem Fund geht eine Mail an SystemHealthMailer::NOTIFY_EMAIL (dasselbe
# Postfach wie die Plattenwarnung), verschickt ueber die Rails-App, weil der
# Server kein eigenes Mailprogramm hat. Ergebnisse landen nur in
# /var/log/port-pruefung.log auf dem Server, bewusst NICHT in GitHub Actions:
# Dieses Repo ist oeffentlich.
#
# Rueckgabe: 0 unauffaellig, 1 Fund, 2 Pruefung selbst gescheitert. Auch Fall 2
# schickt eine Mail, sonst faellt eine kaputte Pruefung nie auf.

# Cron startet mit minimalem PATH.
export PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin

MODUS="${1:-}"
ERLAUBT_DOCKER=" 80 443 "
ERLAUBT_HOST=" 22 80 443 "
# DHCP-Client von Hetzner (lauscht auf der oeffentlichen Adresse, ist aber
# kein Dienst, der von aussen angesprochen wird).
ERLAUBT_HOST_UDP=" 68 "
ERLAUBT_EXTERN=" 22 80 443 "
RAILS_CONTAINER="${RAILS_CONTAINER:-saisonmanager_rails_api}"
SSH_SCHLUESSEL="${SSH_SCHLUESSEL:-/root/.ssh/portpruefung}"
SCAN_HOST="${SCAN_HOST:-116.203.113.70}"   # docker01 (Saisonmanager-Archiv)

melden() {
  local betreff="$1" text="$2"
  echo "$text"
  if ! printf '%s\n' "$text" | docker exec -i -e BETREFF="$betreff" "$RAILS_CONTAINER" \
      bundle exec rails runner -e production '
        ActionMailer::Base.mail(
          from: ApplicationMailer.default[:from],
          to: SystemHealthMailer::NOTIFY_EMAIL,
          subject: ENV.fetch("BETREFF"),
          body: $stdin.read
        ).deliver_now'; then
    echo "FEHLER: Mail konnte nicht verschickt werden" >&2
  fi
}

# Zerlegt "127.0.0.1:49201", "[::]:80", "*:22", "0.0.0.0:443", "127.0.0.53%lo:53"
# in Adresse und Port und sagt, ob die Adresse nur lokal erreichbar ist.
nur_lokal() {
  local addr="$1"
  addr="${addr#[}"; addr="${addr%]}"; addr="${addr%%%*}"
  [[ "$addr" == 127.* || "$addr" == "::1" || "$addr" == fe80:* ]]
}

pruefe_intern() {
  local funde=() name ports p host addr port lokal

  # 1. Von Docker veroeffentlichte Ports. Formen: 0.0.0.0:80->80/tcp,
  #    [::]:80->80/tcp, :::80->80/tcp, 127.0.0.1:49201->5432/tcp, 5432/tcp
  local docker_ausgabe
  docker_ausgabe="$(docker ps --format '{{.Names}}|{{.Ports}}')"
  while IFS='|' read -r name ports; do
    [ -n "$ports" ] || continue
    IFS=',' read -ra liste <<< "$ports"
    for p in "${liste[@]}"; do
      p="${p# }"
      [[ "$p" == *"->"* ]] || continue
      host="${p%%->*}"
      addr="${host%:*}"; port="${host##*:}"
      nur_lokal "$addr" && continue
      [[ "$ERLAUBT_DOCKER" == *" $port "* ]] && continue
      funde+=("Container $name veroeffentlicht $p")
    done
  done <<< "$docker_ausgabe"

  # 2. Alles, was auf dem Host lauscht (auch Dienste ausserhalb von Docker).
  local ss_ausgabe proto lokal_spalte
  ss_ausgabe="$(ss -H -tuln)"
  while read -r proto _ _ _ lokal_spalte _; do
    addr="${lokal_spalte%:*}"; port="${lokal_spalte##*:}"
    nur_lokal "$addr" && continue
    [[ "$proto" == tcp && "$ERLAUBT_HOST" == *" $port "* ]] && continue
    [[ "$proto" == udp && "$ERLAUBT_HOST_UDP" == *" $port "* ]] && continue
    funde+=("Host lauscht auf $proto $lokal_spalte")
  done <<< "$ss_ausgabe"

  if [ "${#funde[@]}" -gt 0 ]; then
    melden "Saisonmanager: unerwartet offene Ports auf $(hostname)" \
      "$(date '+%F %T') Portpruefung intern auf $(hostname): ${#funde[@]} Fund(e)
$(printf '  %s\n' "${funde[@]}")

Erlaubt sind nur 80/443 (nginx) und 22 (sshd). Docker umgeht die Host-Firewall,
Ports in Compose deshalb immer mit 127.0.0.1: veroeffentlichen."
    return 1
  fi
  echo "$(date '+%F %T') intern unauffaellig"
}

pruefe_extern() {
  local ausgabe offen=() zeile port
  # Der Befehl steht fest im authorized_keys von docker01, hier wird nichts
  # uebergeben. BatchMode: ohne Schluessel nicht haengen bleiben. -n: sonst
  # liest ssh die Standardeingabe des Aufrufers leer (z. B. ein Heredoc).
  ausgabe="$(ssh -n -i "$SSH_SCHLUESSEL" -o BatchMode=yes -o ConnectTimeout=20 \
    -o StrictHostKeyChecking=yes "root@$SCAN_HOST" 2>&1)" || {
    melden "Saisonmanager: Portpruefung von aussen gescheitert" \
      "$(date '+%F %T') Der Scan von $SCAN_HOST aus lief nicht:
$ausgabe"
    return 2
  }
  # Zeilen der Form "OFFEN <adresse> <port>" (host/portpruefung/scan-von-aussen.sh)
  while read -r zeile; do
    [[ "$zeile" == OFFEN\ * ]] || continue
    port="${zeile##* }"
    [[ "$ERLAUBT_EXTERN" == *" $port "* ]] && continue
    offen+=("${zeile#OFFEN }")
  done <<< "$ausgabe"
  if ! grep -q '^FERTIG' <<< "$ausgabe"; then
    melden "Saisonmanager: Portpruefung von aussen unvollstaendig" \
      "$(date '+%F %T') Der Scan von $SCAN_HOST meldete kein FERTIG:
$ausgabe"
    return 2
  fi
  if [ "${#offen[@]}" -gt 0 ]; then
    melden "Saisonmanager: von aussen erreichbare Ports" \
      "$(date '+%F %T') Portscan von $SCAN_HOST aus: ${#offen[@]} unerwartet offen
$(printf '  %s\n' "${offen[@]}")

Erwartet sind nur 22, 80 und 443."
    return 1
  fi
  echo "$(date '+%F %T') extern unauffaellig"
}

case "$MODUS" in
  intern) pruefe_intern || exit $? ;;
  extern) pruefe_extern || exit $? ;;
  *) echo "Aufruf: $0 intern|extern" >&2; exit 2 ;;
esac
