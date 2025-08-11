#!/usr/bin/env bash
set -Eeuo pipefail

# ==========================
#   Linux-Update-Script
# ==========================
# Features:
# - Sicheres Warten auf APT/DPKG-Locks (kein rm -rf)
# - Logging nach /var/log/system-update.log (anpassbar)
# - Root-, Internet- und Speicherprüfungen
# - Backups: Paketliste & optional /etc
# - APT: update, (dist-)upgrade, autoremove, autoclean
# - Optional: nur Sicherheitsupdates (unattended-upgrade)
# - Flatpak-Updates (abschaltbar)
# - Dry-Run-Modus
# - Journald-Aufräumen (konfigurierbar)
# - Zusammenfassung der geänderten Pakete

# ===== Defaults =====
LOGFILE="/var/log/system-update.log"
TIMEOUT=600              # Sekunden bis apt/dpkg-Locks frei sein müssen
MIN_FREE_MB=1024         # Mindestfreier Speicher auf /
DO_FLATPAK=true
SECURITY_ONLY=false
DRY_RUN=false
BACKUP_ETC=false
JOURNAL_VACUUM_DAYS=30   # 0 = deaktiviert (kein Vacuum)
APT_LOCK_TIMEOUT=30      # Sekunden (APT-intern)
# =====================

GREEN="\e[92m"; GRAY="\e[39m"; RED="\e[91m"; YELLOW="\e[93m"
log() { echo -e "${GREEN}$*${GRAY}"; }
warn() { echo -e "${YELLOW}$*${GRAY}"; }
err() { echo -e "${RED}$*${GRAY}" >&2; }

usage() {
  cat <<EOF
Usage: sudo $0 [OPTIONS]

Options:
  --no-flatpak           Flatpak-Update überspringen
  --security-only        Nur Sicherheitsupdates (via unattended-upgrade)
  --dry-run              Nichts installieren, nur anzeigen (APT & Flatpak)
  --backup-etc           /etc als Tarball sichern
  --min-free-mb N        Mindestfreier Speicher in MB (Default: ${MIN_FREE_MB})
  --timeout N            Timeout fürs Warten auf APT/DPKG-Locks in Sekunden (Default: ${TIMEOUT})
  --journal-days N       journalctl --vacuum-time=N Tage (0 = deaktiviert; Default: ${JOURNAL_VACUUM_DAYS})
  --logfile PATH         Pfad zur Logdatei (Default: ${LOGFILE})
  --help                 Diese Hilfe

Beispiele:
  sudo $0
  sudo $0 --dry-run
  sudo $0 --security-only --no-flatpak
  sudo $0 --backup-etc --journal-days 14
EOF
}

# ===== Arg-Parsing =====
while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-flatpak) DO_FLATPAK=false; shift ;;
    --security-only) SECURITY_ONLY=true; shift ;;
    --dry-run) DRY_RUN=true; shift ;;
    --backup-etc) BACKUP_ETC=true; shift ;;
    --min-free-mb) MIN_FREE_MB="${2:?}"; shift 2 ;;
    --timeout) TIMEOUT="${2:?}"; shift 2 ;;
    --journal-days) JOURNAL_VACUUM_DAYS="${2:?}"; shift 2 ;;
    --logfile) LOGFILE="${2:?}"; shift 2 ;;
    --help|-h) usage; exit 0 ;;
    *) err "Unbekannte Option: $1"; usage; exit 2 ;;
  esac
done

# ===== Logging einrichten =====
# Logdatei anlegen und sowohl STDOUT als auch STDERR dorthin duplizieren.
mkdir -p "$(dirname "$LOGFILE")"
touch "$LOGFILE"
chmod 640 "$LOGFILE"
exec > >(tee -a "$LOGFILE") 2>&1

log "==== System Update Deluxe gestartet: $(date '+%Y-%m-%d %H:%M:%S') ===="

# ===== Guards & Helpers =====
require_root() {
  if [[ ${EUID:-$(id -u)} -ne 0 ]]; then
    err "Bitte als root ausführen (sudo)."
    exit 1
  fi
}

check_internet() {
  log "Prüfe Internetverbindung…"
  if ping -c1 -W2 deb.debian.org >/dev/null 2>&1 || ping -c1 -W2 1.1.1.1 >/dev/null 2>&1; then
    log "Internetverbindung ok."
  else
    err "Keine Internetverbindung. Abbruch."
    exit 1
  fi
}

check_disk_space() {
  log "Prüfe freien Speicher auf / (min. ${MIN_FREE_MB} MB)…"
  local free_kb
  free_kb=$(df --output=avail / | tail -1)
  local need_kb=$(( MIN_FREE_MB * 1024 ))
  if (( free_kb < need_kb )); then
    err "Nicht genug freier Speicher (frei: $((free_kb/1024)) MB). Abbruch."
    exit 1
  fi
  log "Freier Speicher ok: $((free_kb/1024)) MB."
}

wait_for_apt() {
  local timeout="${1:-600}"
  local waited=0
  local step=3
  local locks=(/var/lib/dpkg/lock-frontend /var/lib/dpkg/lock /var/lib/apt/lists/lock /var/cache/apt/archives/lock)
  log "Prüfe auf laufende Paketvorgänge und Locks (Timeout ${timeout}s)…"
  while true; do
    if pgrep -x apt >/dev/null || pgrep -x apt-get >/dev/null || pgrep -x dpkg >/dev/null; then
      : # busy
    else
      local busy=false
      for f in "${locks[@]}"; do
        if [[ -e "$f" ]] && lsof "$f" &>/dev/null; then
          busy=true; break
        fi
      done
      if [[ "$busy" == false ]]; then
        break
      fi
    fi
    if (( waited >= timeout )); then
      err "Timeout: Paketmanager weiterhin belegt. Bitte später erneut versuchen."
      exit 1
    fi
    sleep "$step"; waited=$(( waited + step ))
  done
  log "Locks sind frei."
}

apt_safe() {
  # Einheitliche APT-Aufrufe (non-interactive + kurzer Lock-Timeout)
  DEBIAN_FRONTEND=noninteractive \
  apt-get --option=DPkg::Lock::Timeout=${APT_LOCK_TIMEOUT} "$@"
}

# Fehlerbehandlung: unkonfigurierte Pakete zu Ende konfigurieren
trap 'err "Fehler aufgetreten. Versuche, dpkg zu reparieren…"; dpkg --configure -a || true' ERR

# ===== Vorbereitungen =====
require_root
check_internet
check_disk_space
wait_for_apt "$TIMEOUT"

# ===== Backups =====
STAMP="$(date +%F_%H%M%S)"
PKG_BACKUP="/root/installed-packages-${STAMP}.list"
MANUAL_BACKUP="/root/manual-packages-${STAMP}.list"
ETC_BACKUP="/root/etc-backup-${STAMP}.tar.gz"

log "Sichere Paketliste nach ${PKG_BACKUP}"
dpkg --get-selections > "$PKG_BACKUP" || warn "Konnte Paketliste nicht sichern."

log "Sichere manuell installierte Pakete nach ${MANUAL_BACKUP}"
if command -v apt-mark >/dev/null 2>&1; then
  apt-mark showmanual > "$MANUAL_BACKUP" || warn "Konnte manuelle Paketliste nicht sichern."
else
  warn "apt-mark nicht gefunden – überspringe manuelle Paketliste."
fi

if $BACKUP_ETC; then
  log "Sichere /etc nach ${ETC_BACKUP} (dies kann etwas dauern)…"
  tar -czf "$ETC_BACKUP" /etc || warn "Sicherung von /etc fehlgeschlagen."
fi

# ===== Snapshots für Zusammenfassung =====
TMPDIR="$(mktemp -d)"
PRE_SNAPSHOT="${TMPDIR}/packages-before.txt"
POST_SNAPSHOT="${TMPDIR}/packages-after.txt"

dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$PRE_SNAPSHOT" || true

# ===== APT: Update + (Security-)Upgrades =====
log "APT: Paketquellen aktualisieren"
apt_safe update

if $DRY_RUN; then
  log "DRY-RUN: zeige verfügbare Upgrades"
  apt list --upgradable 2>/dev/null | sed '1{/Listing/d;}' || true
else
  if $SECURITY_ONLY; then
    log "Nur Sicherheitsupdates: verwende unattended-upgrade"
    if ! command -v unattended-upgrade >/dev/null 2>&1; then
      log "Installiere unattended-upgrades…"
      apt_safe install -y unattended-upgrades
    fi
    # Hinweis: nutzt die Konfiguration in /etc/apt/apt.conf.d/50unattended-upgrades
    unattended-upgrade -v || err "unattended-upgrade meldete einen Fehler."
  else
    log "APT: normales Upgrade (ohne Abhängigkeitsänderungen)"
    apt_safe upgrade -y
    log "APT: Distribution-Upgrade (inkl. neuer/entfernter Abhängigkeiten)"
    apt_safe dist-upgrade -y
  fi

  log "APT: nicht mehr benötigte Pakete entfernen"
  apt_safe autoremove -y

  log "APT: Paket-Cache aufräumen"
  apt_safe autoclean -y
fi

# ===== Flatpak =====
if $DO_FLATPAK; then
  if command -v flatpak >/dev/null 2>&1; then
    if $DRY_RUN; then
      log "DRY-RUN: zeige verfügbare Flatpak-Updates"
      flatpak remote-ls --updates || warn "Konnte Flatpak-Updates nicht auflisten."
    else
      log "Flatpak: Updates einspielen"
      flatpak update -y || warn "Flatpak-Update meldete einen Fehler."
    fi
  else
    warn "Flatpak nicht installiert – Schritt übersprungen."
  fi
else
  log "Flatpak-Updates deaktiviert (--no-flatpak)."
fi

# ===== Journald-Aufräumen =====
if (( JOURNAL_VACUUM_DAYS > 0 )); then
  if command -v journalctl >/dev/null 2>&1; then
    log "Journald: Logs älter als ${JOURNAL_VACUUM_DAYS} Tage entfernen"
    journalctl --vacuum-time="${JOURNAL_VACUUM_DAYS}d" || warn "journald-Vacuum fehlgeschlagen."
  fi
fi

# ===== Zusammenfassung =====
if ! $DRY_RUN; then
  dpkg-query -W -f='${binary:Package}\t${Version}\n' | sort > "$POST_SNAPSHOT" || true
  log "Erstelle Paket-Änderungsübersicht…"

  CHANGES_TSV="${TMPDIR}/changes.tsv"
  CHANGES_PRETTY="${TMPDIR}/changes.txt"

  # Maschinell lesbare Änderungsliste (TSV: pkg<TAB>old<TAB>new)
  join -a1 -a2 -e "N/A" -o '0,1.2,2.2' -t $'\t' "$PRE_SNAPSHOT" "$POST_SNAPSHOT" \
    | awk -F '\t' '$2 != $3 {print $1 "\t" $2 "\t" $3}' > "$CHANGES_TSV"

  # Hübsche Ausgabe in menschenlesbar
  if [[ -s "$CHANGES_TSV" ]]; then
    awk -F '\t' '{ printf "%-40s %s -> %s\n", $1, $2, $3 }' "$CHANGES_TSV" | tee "$CHANGES_PRETTY" >/dev/null
    log "Geänderte Pakete:"
    cat "$CHANGES_PRETTY"
  else
    log "Keine Paketänderungen ermittelt (möglicherweise nur Flatpak/Security/Config)."
  fi
else
  log "DRY-RUN beendet. Es wurden keine Änderungen durchgeführt."
fi

# ===== Kernel-Update-Erkennung =====
# Erfasst typische Kernel-Paketnamen (Ubuntu/Debian-Varianten).
KERNEL_UPDATED=false
if [[ -f "$CHANGES_TSV" && -s "$CHANGES_TSV" ]]; then
  if grep -Eiq $'^(linux-(image|headers|modules|modules-extra|generic|virtual|signed|aws|gcp|azure|oem|kvm)|linux-image-[0-9])\t' "$CHANGES_TSV"; then
    KERNEL_UPDATED=true
  fi
fi

# ===== Neustart-Logik =====
# Info-Hinweis, wenn das System generell einen Reboot fordert:
if [[ -f /var/run/reboot-required ]]; then
  warn "System signalisiert: Neustart erforderlich (/var/run/reboot-required vorhanden)."
fi

# Nur fragen, wenn *Kernel* aktualisiert wurde und wir interaktiv laufen (kein Cron).
is_tty() { [[ -t 0 && -t 1 ]]; }
if ! $DRY_RUN && $KERNEL_UPDATED && is_tty; then
  echo
  read -r -p $'\e[93mKernel-Update erkannt. Jetzt neu starten? [y/N] \e[39m' REBOOT_ANS
  case "${REBOOT_ANS:-N}" in
    y|Y|yes|YES)
      log "Starte jetzt neu…"
      systemctl reboot || reboot
      ;;
    *)
      warn "Neustart übersprungen. Bitte zeitnah manuell neu starten, damit der neue Kernel aktiv wird."
      ;;
  esac
else
  # Falls kein Kernel-Update: kein Prompt, nur ggf. Hinweis.
  if ! $DRY_RUN && ! $KERNEL_UPDATED; then
    log "Kein Kernel-Update erkannt – kein Neustart-Prompt."
  fi
fi

log "==== Fertig: $(date '+%Y-%m-%d %H:%M:%S') ===="
# Aufräumen
rm -rf "$TMPDIR"
