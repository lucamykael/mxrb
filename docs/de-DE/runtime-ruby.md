# Runtime ohne Java

Der Ruby-Modus startet das Backend ohne Mendix Java Runtime. Beim Öffnen einer
exportierten Anwendung migriert MXRB automatisch eine umgebungsspezifische
SQLite-Datenbank, öffnet den Microflow-Interpreter, registriert Lifecycle-Hooks,
erzwingt die Sicherheit und startet Scheduled Events.

Profile liegen unter `config/environments/`, typischerweise als
`development.env`, `qa.env`, `staging.env` und `production.env`. Die Priorität
lautet Prozessumgebung, Profildatei, `.env.<Profil>`, dann `.env`. Die Auswahl
erfolgt mit `--environment qa` oder `MXRB_ENV=qa`; `mxrb env . --environment qa`
zeigt Quellen und Schlüsselnamen, niemals Werte.

```bash
mxrb run . --environment qa
mxrb test App.mpr smoke.rb --native --environment qa
```

Jedes Profil verwendet standardmäßig `.mxrb/runtime/<Umgebung>.sqlite3`. Die
Migration leitet Entitäten, Attribute, Assoziationen und System-Member ab.
Additive Änderungen sind idempotent, inkompatible Änderungen verwenden einen
transaktionalen Rebuild. Nicht persistente Entitäten bleiben im Speicher.

Die Ruby-API bietet Login und Bearer-Token, Sessions, Schema, Navigation,
Seiten, Microflows, CRUD und Published REST. Rollen, Entitätsregeln,
Member-Rechte und der sichere XPath-Teil werden für jede Anfrage geprüft.
Zugangsdaten stammen aus `MXRB_USERS_JSON` und `MXRB_AUTH_TOKENS` und gehören in
ignorierte lokale Dateien oder den Secret Manager des Deployments.

Scheduled Events laufen im stdlib-basierten MXRB-Scheduler mit Minuten-,
Stunden- und Tagesintervallen, Overlap-Schutz und kontrolliertem Shutdown.
IANA-Zeitzonen wie `Europe/Berlin` verwenden `tzinfo` und berücksichtigen
Sommerzeitwechsel. Unbekannte Zonen führen zu einem Fehler statt unbemerkt auf
UTC zurückzufallen; `UTC`, `local` und numerische Offsets werden ebenfalls
unterstützt.

Java Custom Actions sind bewusst ausgeschlossen und führen zu einer eindeutigen
Fehlermeldung. REST, App Services, SOAP, Mappings und Dokumenterzeugung können
injizierte Ruby-Adapter verwenden. Im Browser bleibt JavaScript/React; Backend
und APIs laufen ohne Java Runtime.
