# Bewertung der Mendix-API-Integration

Datum: 1. August 2026. Quelle: offizieller [Mendix-API- und SDK-Index](https://docs.mendix.com/apidocs-mxsdk/).

## Entscheidungsmatrix

| API oder SDK | Verwendung in MXRB | Entscheidung |
| --- | --- | --- |
| Projects API | zugängliche Apps und Projektmetadaten | als `team-server projects` integriert; standardmäßig lesend |
| App Repository API | Repository-Info, Branches und Commits | in Team-Server-Erkennung und Clone integriert |
| Marketplace Content API | Module/Widgets finden und laden | in Marketplace-Operationen integriert |
| Build API | natives Artefakt mit offiziellem Cloud-Build vergleichen | optionale Prüfung; nie Abhängigkeit des nativen Builds |
| Deploy API v4 | Apps/Umgebungen vor Release-Prüfung inventarisieren | lesender Adapter vorgeschlagen; Änderungen nur nach Bestätigung |
| Pipelines API | bestehende CI/CD-Pipeline starten und beobachten | Opt-in-Adapter mit Idempotenz und Statusabfrage vorgeschlagen |
| Backups API v2 | Snapshots vor Deployment auflisten/erstellen/laden | Sicherheitsadapter vorgeschlagen; Restore/Delete bleiben explizit |
| Runtime API 11 | eigenes Java kompilieren und Runtime-Verträge prüfen | Vertrag für Proxy-Erzeugung; Java-API, kein REST-Ersatz |
| Client- und Pluggable-Widget-APIs | Dojo-/React-/Data-Grid-Verträge | Referenz für Webartefakte, kein HTTP-Client |
| Catalog APIs | kontrollierte Datenquellen verwalten | zukünftiges Plugin; außerhalb von Build/Runtime |
| Model/Platform SDKs und Studio-Pro-Erweiterung | Apps remote modellieren oder Studio Pro erweitern | bewusst keine Pflicht; MXRB bleibt mit Ruby/SQLite/BSON eigenständig |

## Integrationsregeln

- Remote-Aufrufe sind explizit; `generate`, `compile`, `validate` und `db up` kontaktieren nie die Mendix Cloud.
- PATs/API-Schlüssel stammen aus geschützter Datei oder Umgebung und werden nie in Berichte, Logs, Projekte oder Git geschrieben.
- Lesen ist Standard. Build, Deploy, Pipeline, Restore, Mitgliedschaft und Löschen benötigen eigene Befehle und Bestätigung.
- Die Build API gilt nur für Mendix-Cloud-Apps und verwendet Account-API-Keys; sie ersetzt den lokalen Compiler nicht.
- Versionierte Runtime-/Frontend-APIs dienen als Kompatibilitätsnachweis. MXRB verwendet exakte Schemas/Seeds und schlägt ohne passenden Vertrag oder Launcher geschlossen fehl.

## Empfohlene Reihenfolge

1. App-Repository-Branches/Commits in `team-server` auflisten.
2. Lesendes Deploy-Inventar und optionales Build-Vergleichsgate.
3. Pipeline-Status/Start mit Idempotenz und begrenztem Polling.
4. Backup-Listen/Erstellen/Download vor Cloud-Änderungen.

Catalog und Studio-Pro-Erweiterungen bleiben getrennte Adapter, da sie das Risiko des nativen Kerns nicht senken.
