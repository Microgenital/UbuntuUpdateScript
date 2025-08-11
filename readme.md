# 🛠 Ubuntu Update Script
Ein robustes, interaktives Bash-Skript für **sichere, vollständige und dokumentierte Systemupdates** unter Debian/Ubuntu (APT) mit optionaler Flatpak-Unterstützung.

---

## 📋 Funktionen

- **Sicheres Lock-Handling**
  Wartet auf freie `apt`-/`dpkg`-Locks, statt sie zu löschen.
- **Vollständige Updates**
  Führt `update`, `upgrade`, `dist-upgrade`, `autoremove`, `autoclean` aus.
- **Kernel-Update-Erkennung**
  Erkennt Kernel-Updates und fragt nur dann nach einem Neustart.
- **Logging**
  Speichert alle Ausgaben in `/var/log/system-update.log` (anpassbar).
- **Sicherheitsprüfungen vor dem Start**
  Root-Check, Internetverbindung, freier Speicherplatz.
- **Backups**
  - Liste aller installierten Pakete
  - Liste der manuell installierten Pakete
  - Optional: Backup von `/etc` als `.tar.gz`
- **Nur Sicherheitsupdates** (optional)
- **Dry-Run-Modus**: Zeigt Updates, ohne Änderungen durchzuführen.
- **Flatpak-Updates** (abschaltbar)
- **Journald-Aufräumen**: Alte Systemlogs löschen (konfigurierbar)
- **Update-Zusammenfassung**: Vorher/Nachher-Vergleich aller Paketversionen.

---

## 📦 Anforderungen

- Debian/Ubuntu oder Derivate
- `bash`
- `apt-get`
- `dpkg`
- (optional) `flatpak`
- (optional) `unattended-upgrades`
- (optional) `journalctl`

---

## 📥 Installation

1. Skript herunterladen:
   ```bash
   curl -O https://raw.githubusercontent.com/<dein-github-user>/<repo-name>/main/system-update.sh
   ```
2. Ausführbar machen:
   ```bash
   chmod +x system-update.sh
   ```
3. Mit Root-Rechten ausführen:
   ```bash
   sudo ./system-update.sh
   ```

---

## ⚙️ Optionen

```text
--no-flatpak           Flatpak-Update überspringen
--security-only        Nur Sicherheitsupdates (via unattended-upgrade)
--dry-run              Nichts installieren, nur anzeigen (APT & Flatpak)
--backup-etc           /etc als Tarball sichern
--min-free-mb N        Mindestfreier Speicher in MB (Default: 1024)
--timeout N            Timeout fürs Warten auf APT/DPKG-Locks in Sekunden (Default: 600)
--journal-days N       journalctl --vacuum-time=N Tage (0 = deaktiviert; Default: 30)
--logfile PATH         Pfad zur Logdatei (Default: /var/log/system-update.log)
--help                 Hilfe anzeigen
```

---

## 🚀 Beispiele

**Standard-Update mit Flatpak:**
```bash
sudo ./system-update.sh
```

**Nur Sicherheitsupdates, ohne Flatpak:**
```bash
sudo ./system-update.sh --security-only --no-flatpak
```

**Trockenlauf (nichts wird installiert):**
```bash
sudo ./system-update.sh --dry-run
```

**Mit `/etc`-Backup und kürzerer Journal-Aufbewahrung:**
```bash
sudo ./system-update.sh --backup-etc --journal-days 14
```

---

## 📊 Beispielausgabe

```text
==== System Update Deluxe gestartet: 2025-08-11 18:23:01 ====
Paketquellen aktualisieren
APT: normales Upgrade (ohne Abhängigkeitsänderungen)
APT: Distribution-Upgrade (inkl. neuer/entfernter Abhängigkeiten)
APT: nicht mehr benötigte Pakete entfernen
APT: Paket-Cache aufräumen
Flatpak: Updates einspielen
Journald: Logs älter als 30 Tage entfernen
Geänderte Pakete:
linux-image-generic                5.15.0-86.96 -> 5.15.0-87.97
...
Kernel-Update erkannt. Jetzt neu starten? [y/N]
```

---

## 🔒 Sicherheitshinweise

- **Keine Locks löschen!** Das Skript wartet, bis der Paketmanager frei ist.
- Führe das Skript **immer mit Root-Rechten** aus.
- Prüfe regelmäßig die Logdatei (`/var/log/system-update.log`) auf Fehler.
- Bei Kernel-Updates ist ein Neustart nötig, um den neuen Kernel zu aktivieren.

---

## 📝 Lizenz

Dieses Skript ist unter der **MIT-Lizenz** veröffentlicht – frei nutzbar, veränderbar und verbreitbar.
Siehe [LICENSE](LICENSE) für Details.

---

## 🤝 Beiträge

Pull Requests und Issues sind willkommen!
Falls du das Skript verbesserst oder für andere Distributionen anpasst, teile es gerne im Repository.
