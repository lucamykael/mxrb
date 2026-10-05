# Windows- und Studio-Pro-Validierung mit Omarchy

## Geprüft am 5. Oktober 2026

Die vorhandene Windows-VM auf dem USB-Laufwerk wurde mit dem bereits
installierten Studio Pro 11.12.1 weiterverwendet. Eine Neuinstallation oder
Formatierung ist nicht erforderlich. RDP lief auf einem eigenen Xvfb-Server
(`DISPLAY=:97`), ohne die physischen Bildschirme zu verwenden oder zu ändern.
Zugangsdaten gehören nicht in Befehle oder Berichte. Projekte vor dem Öffnen in
ein lokales Windows-Verzeichnis kopieren: Konvertierung und Schreiben externer
Units können auf einer RDP-Freigabe fehlschlagen.

Alle sechs nativen Builds waren erfolgreich: Original und Ruby-Round-trip der
Fixtures für Verträge, native Darstellung und Core-Widgets. Die native Runtime
lieferte HTTP 200, zeigte die Seite und bestand Erstellen/Lesen/Ändern/Löschen
über die Client-API in Edge Headless. GUI-Prüfungen deckten Popup-Parameter,
gemeinsamen Kontext, das Schließen zweier Fenster und asynchrone Ausführung ab.
VetClinic bestand ebenfalls Builds, Darstellung mit Theme und Client-API-CRUD.
Damit sind nicht sämtliche Formulare, Themes oder mobilen Layouts zertifiziert.

Der [versionierte Bericht](../evidence/native-2026-10-05.json) beschreibt den Umfang.

## Reproduzieren

Unter Linux ein neues Ziel erzeugen und den gesamten Ordner nach Windows
übertragen. Die Installationspfade in den folgenden Befehlen anpassen:

```bash
bundle exec ruby script/studio_pro_batch /tmp/native-batch
```

```powershell
./script/studio_pro_gate.ps1 -BatchDirectory C:\incoming\native-batch `
  -WorkspaceRoot C:\mxrb-projects -StudioVersion 11.12.1
./script/studio_pro_runtime.ps1 `
  -Package C:\incoming\native-batch\results\core-widgets-roundtrip\core-widgets-roundtrip.mda `
  -ToolRoot C:\Mendix\11.12.1 -JavaHome C:\Java\jdk-21 `
  -EvidenceDirectory C:\incoming\runtime-evidence
```

Das Gate prüft Versionen und Signaturen der Programme, alle Datei-Hashes,
den Eigentümer von `mprcontents` und die physische Anzahl der `.mxunit`-Dateien.
Es baut lokale Kopien und prüft anschließend die Eingaben erneut. Vorhandene
Ziele werden abgelehnt. Eine manipulierte Unit wurde vor dem Build erkannt.
Unter `results` stehen Berichte, Logs, Fehler und Pakete. Der Runtime-Test
schreibt zusätzlich `runtime.json` und einen Screenshot. Er beendet nur eigene
Prozesse und verwendet eine temporäre HSQLDB-Datenbank und ein eigenes Edge-Profil.

## CI

[Windows native certification](../../.github/workflows/studio-pro.yml) läuft
wöchentlich, manuell und bei relevanten PRs. Der gehostete Windows-Runner nutzt
das offizielle MxBuild-Archiv 11.12.1 mit festem SHA-256, JDK 21 und Edge Headless.
Die aktuelle Matrix prüft acht Builds (einschließlich Validierungsregeln) und startet Original sowie Rekonstruktion des Core-Pakets.
Evidenz-Artefakte bleiben 14 Tage verfügbar. Die Studio-Pro-GUI wird dabei nicht
installiert; visuelle Prüfungen werden separat dokumentiert.

Ruby-Gates bleiben bei 100 % Zeilen- und Branch-Coverage; Frontend- und
Chromium-Prüfungen bleiben ebenfalls bestehen. Für weitere GUI-Prüfungen die
vorhandene VM über die installierten Omarchy-Befehle starten und ein separates
virtuelles Display verwenden.

## Status aus Evidenz

`script/acceptance_status` erzeugt JSON aus aktuellen Manifesten und Berichten.
Optionen sind wiederholbar. Deklarationskataloge bleiben von ausgeführten Checks
getrennt; ein Manifest allein zertifiziert kein Laufzeitverhalten. Leere Batches,
fehlgeschlagene Starts und unvollständige Coverage werden nicht als bestanden
gewertet. Exit-Code 1 bedeutet fehlgeschlagene Evidenz, 2 ungültige Eingaben.

```bash
bundle exec ruby script/acceptance_status \
  --manifest /tmp/app/.mxrb/ruby-app.json \
  --coverage coverage/coverage.json \
  --native /tmp/native-evidence/summary.json \
  --runtime /tmp/native-evidence/runtime-core-widgets-roundtrip/runtime.json \
  > /tmp/acceptance-status.json
```
